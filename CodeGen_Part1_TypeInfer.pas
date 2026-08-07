// ============================================================
// CodeGen_Part1_TypeInfer.pas
// [분할 2/2] CodeGen.pas(원래 9000줄+)를 3조각으로 나눈 것 중 하나입니다.
// 필드 선언 + 스코프/필드 조회 helper + InferType(식의 Pascal 타입 추론) 계열
// CodeGen.pas가 `{$include CodeGen_Part1_TypeInfer.pas}`로 이 파일을 그 자리에 그대로 끌어와 붙이므로
// (텍스트 삽입 — 이 컴파일러가 partial class를 지원하지 않아서 쓰는 방식입니다),
// 컴파일 결과(IL)는 분할 전과 100% 동일합니다.
// 반드시 CodeGen.pas와 같은 폴더에 두어야 합니다. 이 파일만 단독으로 컴파일할 수
// 없습니다(TCodeGenerator의 필드/다른 부분에 의존).
// ============================================================

    fProg: TProgramNode;

    // [Phase 2] 전역/로컬 변수 스코프 — 예전에는 이름당 4개 Dictionary(Locals/Types/Class/ClrTypes) ×
    // (전역/로컬) = 8개로 흩어져 있던 것을 TScope 두 개(체인: fLocalScope.Parent=fGlobalScope)로 정리.
    // fLocalClrTypes를 fLocalClass와 분리했던 이유(TypeBuilder에 Reflection 걸면 터지는 문제)는
    // TScopeEntry.ClassName / .ClrType으로 그대로 보존된다 — 항목 하나에 둘 다 들어있을 뿐 의미는 그대로.
    fGlobalScope: TScope;
    fLocalScope:  TScope;

    // 일반 static 함수/프로시저
    fMethods:     Dictionary<string, MethodBuilder>;
    fFuncReturnTypes: Dictionary<string, TVarType>; // [Stage 27] 최상위 함수명 → 반환타입 (InferType이 함수 호출식의 타입을 알 수 있도록)
    // [버그 수정] MethodBuilder.GetParameters()는 소속 TypeBuilder가 CreateType되기 전에는
    // NotSupportedException("Type has not been created.")을 던진다. 최상위 함수/프로시저는
    // 전부 같은 모듈 타입 안에 있고, 그 타입은 모든 메서드 본문을 다 만든 뒤에야 CreateType되므로
    // 코드 생성 도중(다른 함수 본문 안에서 호출식을 만들 때)에는 항상 "아직 안 만들어진" 상태다.
    // 그래서 정의 시점에 이미 계산해 둔 매개변수 CLR 타입을 따로 보관해 뒀다가 그걸 쓴다.
    fTopParamClrTypes: Dictionary<string, array of System.Type>; // 함수/프로시저명 → 매개변수 CLR 타입 배열

    // [Stage 71] true open generic — 몸체를 컴파일하는 동안만 유효한 "타입 매개변수 이름 → 실제
    // GenericTypeParameterBuilder(또는 닫힌 호출부에서는 실제 CLR 타입)" 치환표. nil이면 제네릭
    // 컨텍스트 밖(보통의 static 함수/메서드 본문)이라는 뜻 — VTC가 vtGeneric을 만나면 이 표를 본다.
    fCurGenericSubst: Dictionary<string, System.Type>;
    // [Stage 71] DeclareStaticFunc/Proc가 만든 "타입 매개변수 이름 → GenericTypeParameterBuilder"
    // 치환표를 함수/프로시저 이름별로 보관해 뒀다가, BuildStaticFunc/Proc가 본문을 컴파일할 때
    // 다시 fCurGenericSubst에 꽂아 쓴다(선언 패스와 빌드 패스가 서로 다른 시점에 실행되므로).
    fOpenGenericSubstOf: Dictionary<string, Dictionary<string, System.Type>>;
    // [Stage 71] Monomorphize가 단형화하지 않고 "그대로 진짜 오픈 제네릭으로 남겨 둔" 템플릿의 호출
    // 요청들. Parser는 예전과 동일하게 맹글링된 구체 이름(예: "Identity_integer")으로 호출 노드를
    // 만들어 두므로, fMethods에 그 이름이 없을 때(=단형화되지 않고 오픈 제네릭으로 처리된 경우)
    // 이 표를 통해 원본 템플릿 이름 + 실제 타입 인자를 되찾아 MakeGenericMethod로 호출한다.
    // key: 맹글링된 구체 이름(예: "Identity_integer") → 그 인스턴스화 요청 레코드.
    fOpenGenericCallMap: Dictionary<string, TGenericFuncInstantiation>;
    // [Stage 74] 클래스 안의 자체 제네릭 메서드(TFoo.Bar<T>)용 치환표 — fOpenGenericSubstOf와
    // 같은 목적이지만 key가 "ClassName.MethodName"이라는 점만 다르다(메서드는 클래스 소속이므로
    // 이름만으로는 구분이 안 될 수 있음).
    fMethodOpenGenericSubstOf: Dictionary<string, Dictionary<string, System.Type>>;

    // 클래스 관련
    fTypeBuilders: Dictionary<string, TypeBuilder>;  // 클래스명 → TypeBuilder
    fBuiltTypes:   Dictionary<string, System.Type>;  // 클래스명 → 완성된 Type
    fFieldBuilders: Dictionary<string, Dictionary<string, FieldBuilder>>; // 클래스명 → 필드명 → FieldBuilder
    fInstanceMethods: Dictionary<string, Dictionary<string, MethodBuilder>>; // 클래스명 → 메서드명 → MB
    fAbstractMethods: Dictionary<string, List<string>>; // [Stage 53] 클래스명 → abstract로 선언된 메서드명 목록
    fClasses: TClassTable; // [Symbols.pas 1단계] 클래스명 → TClassSymbol. 현재는 ParentName만 이관됨(구 fClassParents)
    // [성능] SafeGetMethods/SafeGetConstructors의 "완성된(외부 CLR) 타입"용 GetMethods/
    // GetConstructors 결과 캐시. ResolveMethodByArity/ResolveConstructorByArity가 오버로드를
    // 고를 때마다 같은 타입(예: System.Windows.Forms.Form처럼 멤버가 수백 개인 외부 타입)에
    // 대해 리플렉션 전체 스캔을 매번 새로 하던 것을 1회로 줄인다. TypeBuilder/
    // TypeBuilderInstantiation(아직 CreateType 전인 우리 자신의 로컬 클래스)은 멤버가 계속
    // 늘어날 수 있어 캐시하면 stale해질 수 있으므로, 이미 완성된 외부 타입 분기에서만 쓴다.
    fMethodsCache: Dictionary<string, array of MethodInfo>; // key: 타입.AssemblyQualifiedName+"|"+flags
    fCtorsCache: Dictionary<string, array of ConstructorInfo>; // key: 타입.AssemblyQualifiedName
    // [진단] StackOverflowException은 .NET에서 절대 catch할 수 없고 어느 위치인지도 전혀
    // 남기지 않는다(프로세스가 그냥 강제 종료됨). EmitExpr/EmitStatement가 예상 밖으로
    // 깊게(또는 무한히) 재귀할 때, 실제 OS 스택이 터지기 훨씬 전인 안전한 문턱값에서 먼저
    // "잡을 수 있는" 예외로 바꿔치기해 어떤 노드 타입에서 멈췄는지 드러내기 위한 카운터.
    // 정상적인 코드는 이 함수들의 재귀 호출 체인이 수백 단계를 넘을 일이 거의 없으므로,
    // 5000이라는 문턱값은 실제 정상 케이스를 오탐할 가능성은 낮으면서 진짜 폭주(무한재귀
    // 또는 비정상적으로 깊은 재귀)는 훨씬 일찍 잡아낸다.
    fEmitDepth: integer;
    fMethodReturnTypes: Dictionary<string, Dictionary<string, TVarType>>; // 클래스명/인터페이스명 → 메서드명 → 반환타입
    fMethodParamClrTypes: Dictionary<string, Dictionary<string, array of System.Type>>; // 클래스명 → 메서드명 → 매개변수 CLR 타입 배열
    // [Stage 99] 클래스당 생성자가 1개뿐이라고 가정했던 예전 구조(값 하나)를, 오버로드된
    // 생성자를 여러 개 담을 수 있도록 리스트로 바꿨다. 두 딕셔너리는 항상 같은 순서로
    // 나란히 채워진다(i번째 ConstructorBuilder의 매개변수 타입이 fCtorParamClrTypes[cn][i]).
    // 생성자가 1개뿐인(오버로드 없는) 기존 클래스들은 그냥 리스트에 원소가 1개 있는
    // 것으로 취급되므로 동작이 그대로 유지된다.
    fCtorBuilders: Dictionary<string, List<ConstructorBuilder>>; // 클래스명 → 생성자 목록 (CreateType 전에도 참조 가능하도록 보관)
    fCtorParamClrTypes: Dictionary<string, List<array of System.Type>>; // [Stage 47/99] 클래스명 → 각 생성자의 매개변수 CLR 타입 배열

    // 외부 .NET 어셈블리 (WPF/WinForm/Avalonia 등) — GenerateExe 전에 AddReferenceAssembly로 채워짐
    fLoadedAssemblies: List<Assembly>;
    // [Stage 51] 자동 참조 해결: 네임스페이스 접두사 → GAC에서 시도해볼 어셈블리 짧은 이름 후보 목록.
    // {$reference}가 없어도 System.Windows.Forms.Form 같은 "기본적인" BCL/프레임워크 타입은
    // 이 표를 보고 자동으로 Assembly.Load를 시도한다. Avalonia처럼 GAC에 없는 서드파티 DLL은
    // 여전히 {$reference 경로.dll}로 명시해야 한다(자동표에 없으면 기존처럼 예외 발생).
    fAutoAssemblyMap: Dictionary<string, array of string>;
    // 자동 로드를 이미 실패한 어셈블리 짧은 이름은 다시 시도하지 않는다(반복 예외로 인한 지연 방지).
    fFailedAutoLoads: HashSet<string>;
    // 클래스명 → 그 클래스가 직접 상속한 "외부" 부모의 실제 System.Type
    // (외부 타입 자신의 조상 체인은 Reflection이 알아서 다 검색해주므로 1단계만 기록하면 충분)
    fClassExternalParentType: Dictionary<string, System.Type>;
    // [Stage 86] class(IDisposable)처럼 괄호 안 이름이 실제로는 클래스가 아니라 외부(.NET)
    // "인터페이스"였던 경우 — 클래스명 → 그 인터페이스의 실제 System.Type.
    // TypeBuilder.DefineType의 parent 자리에는 넣을 수 없으므로(인터페이스면 예외) 따로 보관해뒀다가
    // AddInterfaceImplementation으로 등록한다.
    fClassExternalInterfaceType: Dictionary<string, System.Type>;

    // 인터페이스 관련 (클래스보다 먼저 완전히 빌드됨)
    fInterfaceBuilders: Dictionary<string, TypeBuilder>;  // 인터페이스명 → TypeBuilder
    fBuiltInterfaces:   Dictionary<string, System.Type>;  // 인터페이스명 → 완성된 Type
    // [Phase 1] 열거형 관련
    fBuiltEnums: Dictionary<string, System.Type>; // 열거형명 → 완성된 Type
    // [Stage 62] 레코드(값 타입) 이름 집합. 레코드는 fBuiltTypes/fFieldBuilders를 클래스와
    // 공유하지만(타입 CLR 조회 경로 재사용), 필드를 읽고/쓸 때 Ldloc(값 복사) 대신
    // Ldloca(주소)가 필요하다는 점이 다르다 — 그 분기를 위해서만 이 집합을 따로 둔다.
    fRecordNames: HashSet<string>;
    // [Stage 66] 연산자 오버로딩 레지스트리. "기호|타입이름" → 맹글링된 최상위 함수 이름
    // (fMethods에서 바로 찾아 Call할 수 있다), 그리고 그 맹글링된 함수 이름 → 반환 타입의
    // 클래스/레코드 이름(함수 시그니처를 System.Object가 아니라 실제 타입으로 선언하기 위함 —
    // 특히 레코드는 값 타입이라 System.Object로 방출하면 박싱되어 필드 접근이 깨진다).
    fOperatorOverloadFuncs: Dictionary<string, string>;
    fOperatorFuncRetClass:  Dictionary<string, string>;
    // [Stage 66] 클래스/레코드명 → 필드명 → 그 필드가 vtObject일 때의 클래스/레코드 이름.
    // TBinOpNode 피연산자가 "self.필드" 또는 "obj.필드" 형태일 때 연산자 오버로딩 대상
    // 타입을 판별하는 데만 쓰인다 (TryGetObjClassName).
    fFieldObjClassName: Dictionary<string, Dictionary<string, string>>;
    // [Stage 64] 익명 메서드(람다)는 'Program' 정적 메서드 컨테이너(mainTB)에 새 static 메서드로
    // 하나씩 추가된다. GenerateExe 안의 지역변수였던 mainTB를 EmitStatement에서도 쓸 수 있도록
    // 인스턴스 필드로 승격해 둔다. fLambdaCounter는 매번 다른 메서드 이름(__Lambda1, __Lambda2, ...)을
    // 만들기 위한 일련번호.
    fMainTB: TypeBuilder;
    fLambdaCounter: integer;
    // [Stage 96] 전역 const를 Program 타입의 static readonly 필드로 올려 모든 함수에서
    // Ldsfld로 접근 가능하게 한다. EmitConstDecl(Main 전용 로컬 슬롯)과 달리 어느
    // 메서드 ILGenerator에서도 읽을 수 있다.
    fGlobalConstFields: Dictionary<string, FieldBuilder>;
    fGlobalConstVTypes: Dictionary<string, TVarType>;
    // [Stage 68] 클로저(변수 캡처) 있는 람다가 __ClosureN 클래스를 최상위 타입으로
    // 만들 때 필요 — fMainTB처럼 GenerateExe의 지역변수였던 modB를 인스턴스 필드로 승격.
    fModB: ModuleBuilder;

    // 현재 메서드 컨텍스트
    fResultLocal:  LocalBuilder;
    fResultType:   TVarType;
    fCurClassName: string; // 인스턴스 메서드 안에서 self 타입

    // [Stage 60] break/continue 지원. 병렬 리스트 3개를 스택처럼 사용한다(Add=push,
    // RemoveAt(Count-1)=pop) — 프로젝트 전반에서 List<T>를 스택 대용으로 쓰는 기존 관례를 따름.
    // 루프에 진입할 때(for/while/repeat) 탈출 라벨(break)과 이어달리기 라벨(continue)을 push하고,
    // 루프를 벗어나면 pop한다. break/continue는 항상 "가장 안쪽" 루프, 즉 리스트의 마지막 항목을 사용한다.
    // fLoopExceptDepths는 그 루프가 시작된 시점의 try 중첩 깊이(fCurExceptDepth)를 같이 저장해 둔다 —
    // break/continue가 try/except/finally 블록 "밖"으로 점프해야 하면(중첩 깊이가 그때보다 깊으면)
    // 단순 Br이 아니라 Leave를 써야 CLR이 finally 블록을 정상적으로 실행하고 스택을 되감기 때문.
    fLoopBreakLabels:    List<&Label>;
    fLoopContinueLabels: List<&Label>;
    fLoopExceptDepths:   List<integer>;
    fCurExceptDepth: integer; // 현재 try/except/finally 중첩 깊이 (BeginExceptionBlock/EndExceptionBlock에서 증감)

    // [Stage 78] exit — 현재 컴파일 중인 프로시저/함수/메서드/생성자의 "몸체 끝" 라벨.
    // break/continue의 fLoopBreakLabels와 같은 원리이지만 루프가 아니라 서브프로그램
    // 단위이므로 스택이 아니라 단일 필드로 충분하다(중첩 함수/프로시저 본문은 재귀 호출이
    // 완전히 끝난 뒤에야 바깥쪽 본문 방출로 돌아오므로 저장/복원만으로 정확함 — fResultLocal과
    // 동일한 패턴). exit 문은 이 라벨로 Br(또는 try/except/finally 블록 안이면 fCurExceptDepth>0
    // 이므로 Leave)한다. 라벨이 가리키는 지점에서 함수면 Result를 로드하고 Ret한다(정상 종료와 동일).
    fMethodExitLabel: &Label;

    // [Stage 69] yield / sequence of T — 함수 하나가 "__IterN"이라는 숨은 클래스로 컴파일된다.
    // 그 클래스는 매개변수+지역변수를 전부 필드로 갖고(호출 사이 상태 보존), 상태 정수 필드
    // (<>state)와 현재 값 필드(<>current)를 더 가진다. MoveNext는 <>state로 "어디서 멈췄는지"
    // 판단해 그 지점으로 goto한 뒤 이어서 실행하다가 다음 yield에서 다시 멈춘다.
    fIterCounter: integer; // __Iter1, __Iter2, ... 이름 일련번호
    fIterTypes:  Dictionary<string, TypeBuilder>;   // 최상위 함수명 → 생성된 이터레이터 클래스
    fIterCtors:  Dictionary<string, ConstructorBuilder>; // 최상위 함수명 → 그 클래스의 생성자(매개변수 = 원함수 매개변수)
    fIterElemClrType: Dictionary<string, System.Type>; // 최상위 함수명 → 원소 CLR 타입
    // [Stage 70] fIterElemClrType과 같은 자리에서 함께 채워지는, "원소 CLR 타입"이 아니라
    // "원소의 Pascal TVarType" 버전 — LINQ 스타일 확장 메서드(Where/Select/...)가 소스 시퀀스의
    // 원소 타입을 CodeGen 쪽 타입 체계(TVarType)로 알아야 할 때(예: 새 로컬 선언, InferType 재귀)
    // fIterElemClrType(System.Type)만으로는 vtInteger/vtInt64 등을 역으로 구분하기 번거로워 따로 둔다.
    fIterElemVarType: Dictionary<string, TVarType>;
    fIterStateFieldOf:   Dictionary<string, FieldBuilder>; // 최상위 함수명 → <>state 필드
    fIterCurrentFieldOf: Dictionary<string, FieldBuilder>; // 최상위 함수명 → <>current 필드
    fIterCapFieldsOf: Dictionary<string, Dictionary<string, FieldBuilder>>; // 최상위 함수명 → (매개변수/지역변수명 → 필드)
    // 아래 4개는 "지금 빌드 중인" 이터레이터 하나에 대한 컨텍스트 — BuildIteratorMoveNext 안에서만 유효.
    fInIterator: boolean;
    fCurIterStateField:   FieldBuilder;
    fCurIterCurrentField: FieldBuilder;
    fCurIterFields: Dictionary<string, FieldBuilder>; // 캡처된 변수명(매개변수+지역변수) → 필드
    fCurIterYieldState: Dictionary<TYieldStmtNode, integer>; // yield 문 인스턴스 → 재개 상태 번호(1부터)
    fCurIterYieldLabel: Dictionary<integer, &Label>;          // 재개 상태 번호 → 그 지점의 IL 라벨

    // [버그 수정] PascalABC.NET은 and/or를 완전 평가(non-short-circuit)한다. 코드 곳곳에
    // "outer.ContainsKey(k1) and outer[k1].ContainsKey(k2)" 형태로 중첩 Dictionary를
    // 조회하던 자리들은, outer에 k1이 없을 때도 outer[k1]을 그대로 평가해
    // KeyNotFoundException을 던졌다. GetExprClrType처럼 함수 전체를 try/except로 감싼
    // 호출부에서는 이 예외가 조용히 삼켜져 결과가 System.Object로 잘못 폴백되는(자기컴파일
    // 실제 사례: Scope.pas의 HasClrType/HasClassName과 동일한 근본 원인) 버그로 이어졌다.
    // 이 제네릭 헬퍼로 통일해, k1이 없으면 k2를 아예 조회하지 않도록 한다.
    function DictDictHas<TV>(d: Dictionary<string, Dictionary<string, TV>>; k1, k2: string): boolean;
    var _ddHasKey: boolean;
    begin
      _ddHasKey:=d.ContainsKey(k1);
      if _ddHasKey then
        Result:=d[k1].ContainsKey(k2)
      else
        Result:=false;
    end;

    function VTC(t: TVarType; cn: string): System.Type;
    begin
      if t=vtString then Result:=typeof(string)
      else if t=vtBoolean then Result:=typeof(boolean)
      // [Phase 1] 새 기본 타입
      else if t=vtReal  then Result:=typeof(double)
      else if t=vtChar  then Result:=typeof(char)
      else if t=vtInt64 then Result:=typeof(int64)
      else if t=vtEnum  then
      begin
        // 열거형은 BuildEnumTypes 단계에서 완성된 Type이 fBuiltEnums에 등록된다.
        if fBuiltEnums.ContainsKey(cn) then Result:=fBuiltEnums[cn]
        else Result:=typeof(integer); // 아직 빌드 전이면 int32로 폴백
      end
      // [Stage 63] set of X — 런타임 표현은 항상 System.Int32 비트마스크(어떤 열거형이든 동일).
      else if t=vtSet then Result:=typeof(integer)
      else if t=vtIntArray then Result:=typeof(integer).MakeArrayType()
      else if t=vtStrArray then Result:=typeof(string).MakeArrayType()
      // [Stage 90] array of object → object[] (예: Assembly.GetCustomAttributes 반환값을 담는 지역변수)
      // [자기컴파일] array of System.Type 처럼 cn이 "TypeName[]" 형태이면 그 외부 타입의 배열로 해석.
      else if t=vtObjArray then
      begin
        // cn이 "SomeName[]" 형태이면 원소 타입을 찾아 배열 타입을 만든다
        if (cn<>'') and cn.EndsWith('[]') then
        begin
          var _elemName:=cn.Substring(0, cn.Length-2);
          var _elemType:=ResolveExternalType(_elemName);
          if _elemType<>nil then Result:=_elemType.MakeArrayType()
          else Result:=typeof(System.Object).MakeArrayType();
        end
        else Result:=typeof(System.Object).MakeArrayType();
      end
      // [Stage 67] vtMatrix: array of array of <elemtype> → CLR jagged array (elemtype)[][]
      else if t=vtMatrix then
      begin
        var elemClr: System.Type;
        if (cn='real') or (cn='double') then elemClr:=typeof(double)
        else if cn='char' then elemClr:=typeof(char)
        else if cn='int64' then elemClr:=typeof(int64)
        else if cn='string' then elemClr:=typeof(string)
        else elemClr:=typeof(integer); // 기본: integer
        Result:=elemClr.MakeArrayType().MakeArrayType(); // (elemtype)[][]
      end
      else if t=vtObject then
      begin
        if fBuiltTypes.ContainsKey(cn) then Result:=fBuiltTypes[cn]
        else if fTypeBuilders.ContainsKey(cn) then Result:=fTypeBuilders[cn]
        // [버그 수정] cn이 사용자 정의 Pascal 클래스가 아니라 'ListViewItem'처럼
        // 외부 CLR 타입 이름일 수 있다. 이 경우를 처리하지 않고 바로 System.Object로
        // 폴백해 버리면, 예를 들어 "function MakeItem(...): ListViewItem;" 같은
        // 최상위 함수의 MethodBuilder.ReturnType이 System.Object로 등록된다.
        // 그러면 InferArgClrType의 TFuncCallExprNode 분기가 MakeItem(...) 호출의
        // 인자 타입을 System.Object로 돌려주고, ScoreParamMatch가
        // Items.Add(string)/Items.Add(ListViewItem) 두 오버로드 모두를 매치 실패(-100)로
        // 동점 처리해 GetMethods() 나열 순서상 우연히 앞선 Add(string)이 선택되었다.
        // 그 결과 IL이 ListViewItem 인스턴스를 String으로 castclass하게 되어
        // 런타임에 "'ListviewItem' 형식 개체를 'String' 형식으로 캐스팅할 수 없습니다"
        // InvalidCastException이 발생했다. 여기서 ResolveExternalType으로 한 번 더
        // 실제 CLR 타입을 찾아본다.
        else if cn<>'' then
        begin
          try Result:=ResolveExternalType(cn);
          except Result:=typeof(System.Object); end;
        end
        else Result:=typeof(System.Object);
      end
      else if t=vtInterface then
      begin
        if fBuiltInterfaces.ContainsKey(cn) then Result:=fBuiltInterfaces[cn]
        else Result:=typeof(System.Object);
      end
      // [Stage 71] true open generic 함수/프로시저 본문 컴파일 중에만 의미가 있다. cn에는 타입
      // 매개변수 이름(예: 'T')이 들어있고, fCurGenericSubst가 그 이름을 실제 GenericTypeParameterBuilder
      // (선언부 컴파일 중) 또는 닫힌 실제 타입(호출부)으로 풀어준다. 예전처럼 vtGeneric이 여기 도달하는
      // 경우는 전부 Monomorphize가 미리 제거했었지만, 이제 "1차 제약을 만족하는" 제네릭 함수/프로시저는
      // 단형화되지 않고 그대로 남아 CodeGen이 직접 vtGeneric을 다뤄야 한다.
      else if t=vtGeneric then
      begin
        if (fCurGenericSubst<>nil) and fCurGenericSubst.ContainsKey(cn) then Result:=fCurGenericSubst[cn]
        else Result:=typeof(System.Object); // 방어적 폴백(정상 경로라면 도달하지 않아야 함)
      end
      else Result:=typeof(integer);
    end;

    function GetVarType(name: string): TVarType;
    begin
      if fLocalScope.Has(name) then Result:=fLocalScope.GetVType(name)
      else if fGlobalScope.Has(name) then Result:=fGlobalScope.GetVType(name)
      // [Stage 96] 전역 const는 Scope 슬롯이 없고 fGlobalConstVTypes에 타입 정보가 있다.
      else if fGlobalConstVTypes.ContainsKey(name) then Result:=fGlobalConstVTypes[name]
      else Result:=vtInteger;
    end;

    function GetVarClassName(name: string): string;
    begin
      if fLocalScope.Has(name) then Result:=fLocalScope.GetClassName(name)
      else if fGlobalScope.Has(name) then Result:=fGlobalScope.GetClassName(name)
      else Result:='';
    end;

    // [Stage 71] vtGeneric으로 추론된 식 e의 실제 CLR 타입(현재 컴파일 중인 open generic
    // 메서드 안에서의 GenericTypeParameterBuilder)을 알아낸다. 1차 제약: e가 변수/매개변수
    // 참조(TVarRefNode)일 때만 정확히 찾아준다 — 그 외(예: 제네릭 함수를 호출한 결과를 다시
    // 다른 제네릭 함수에 넘기는 식 등)는 System.Object로 방어적 폴백한다(box는 여전히 안전하게
    // 동작하지만, 값 타입이면 이미 한 번 박싱된 상태로 다시 취급될 뿐 — 드문 경로라 1차 범위 밖).
    function GetGenericExprClrType(e: TExprNode): System.Type;
    var genName: string;
    begin
      if (e is TVarRefNode) and (fCurGenericSubst<>nil) then
      begin
        genName:=GetVarClassName(TVarRefNode(e).VarName);
        if (genName<>'') and fCurGenericSubst.ContainsKey(genName) then
        begin Result:=fCurGenericSubst[genName]; exit; end;
      end;
      Result:=typeof(System.Object);
    end;

    // [Stage 66] TBinOpKind → 소스에 쓰인 연산자 기호 문자열. 연산자 오버로딩 레지스트리
    // (fOperatorOverloadFuncs)의 키를 만드는 데 쓰인다. 문자열/집합 연산 등 이미 다른 의미로
    // 쓰이는 boAdd/boSub/boMul을 여기서는 순수하게 "소스 기호"로만 취급한다.
    function OpKindSymbol(k: TBinOpKind): string;
    begin
      if k=boAdd then Result:='+'
      else if k=boSub then Result:='-'
      else if k=boMul then Result:='*'
      else if k=boDiv then Result:='/'
      else Result:='';
    end;

    // [Stage 66] 식 하나가 "연산자 오버로딩 대상이 될 수 있는 vtObject 값"이면 그 클래스/레코드
    // 이름을 outCn에 채우고 true를 돌려준다. 지원 범위는 일부러 좁게 잡았다 — 지역변수/매개변수,
    // self 필드(TFieldReadExprNode), obj.필드(TMethodCallExprNode 0-인자 필드읽기), 그리고
    // 이미 연산자 오버로딩으로 해석되는 중첩 TBinOpNode(체이닝, 예: a+b+c) 네 가지뿐이다.
    // 이 이상(임의의 메서드 호출 반환값 등)은 이 컴파일러가 애초에 값의 클래스 이름을 추적하지
    // 않는 경우가 대부분이라(함수 반환 타입에 ClassName이 없음, Stage 66 범위 밖) 지원하지 않는다.
    function TryGetObjClassName(ex: TExprNode; var outCn: string): boolean;
    var _fr66: TFieldReadExprNode; _mc66: TMethodCallExprNode; _vr66: TVarRefNode; _bo66: TBinOpNode;
        _ownerCn66, _lcn66, _rcn66, _sym66: string;
    begin
      outCn:='';
      if ex is TVarRefNode then
      begin
        _vr66:=TVarRefNode(ex);
        outCn:=GetVarClassName(_vr66.VarName);
        Result:=outCn<>'';
      end
      else if ex is TFieldReadExprNode then
      begin
        _fr66:=TFieldReadExprNode(ex);
        if DictDictHas(fFieldObjClassName, fCurClassName, _fr66.FieldName) then
        begin outCn:=fFieldObjClassName[fCurClassName][_fr66.FieldName]; Result:=true; end
        else Result:=false;
      end
      else if (ex is TMethodCallExprNode) and (TMethodCallExprNode(ex).Args.Count=0) and (TMethodCallExprNode(ex).ObjName<>'') then
      begin
        _mc66:=TMethodCallExprNode(ex);
        _ownerCn66:=GetVarClassName(_mc66.ObjName);
        if (_ownerCn66<>'') and DictDictHas(fFieldObjClassName, _ownerCn66, _mc66.MethodName) then
        begin outCn:=fFieldObjClassName[_ownerCn66][_mc66.MethodName]; Result:=true; end
        else Result:=false;
      end
      else if ex is TBinOpNode then
      begin
        _bo66:=TBinOpNode(ex);
        if TryGetObjClassName(_bo66.Left, _lcn66) and TryGetObjClassName(_bo66.Right, _rcn66) and (_lcn66=_rcn66) and (_lcn66<>'') then
        begin
          _sym66:=OpKindSymbol(_bo66.Op);
          if fOperatorOverloadFuncs.ContainsKey(_sym66+'|'+_lcn66) then
          begin outCn:=_lcn66; Result:=true; end
          else Result:=false;
        end
        else Result:=false;
      end
      else Result:=false;
    end;

    // 클래스 계층을 따라 올라가며 필드를 정의한 (진짜 소유) 클래스의 FieldBuilder 탐색
    function FindFieldBuilder(startClass, fname: string): FieldBuilder;
    var c: string;
    begin
      c:=startClass;
      while c<>'' do
      begin
        if DictDictHas(fFieldBuilders, c, fname) then
        begin Result:=fFieldBuilders[c][fname]; exit; end;
        c:=fClasses.GetParentName(c);
      end;
      raise new Exception('필드를 찾을 수 없음: '+startClass+'.'+fname);
    end;

    // [Stage 100 버그 수정] "외부 CLR 타입이겠거니" 하고 SafeGetProperty/ResolveMethodByArity
    // (순수 리플렉션 경로)로 넘기기 전에, 사실은 우리가 직접 만들고 있는(아직 CreateType 안
    // 된) 로컬 클래스인지부터 확인해야 한다 — 그렇지 않으면 TypeBuilder.GetMethods 등이
    // "유형이 만들어지기 전에 호출된 멤버는 지원되지 않습니다"(NotSupportedException)로
    // 죽는다. 이 역조회는 원래 EmitExpr 안의 한 지점(TChainedIndexExprNode/체이닝 멤버
    // 접근 처리부)에만 인라인으로 있었는데, fLocalScope/fGlobalScope에 저장된 ClrType이
    // 로컬 클래스인 경우(예: "var t: TToken"으로 선언된 변수의 메서드 호출)에도 똑같이
    // 필요해서 재사용 가능하게 뽑아냈다. 못 찾으면 빈 문자열.
    function FindLocalClassNameForTypeBuilder(t: System.Type): string;
    begin
      Result:='';
      if t=nil then exit;
      // [자기컴파일 버그 수정] 제네릭 컬렉션(List<TToken> 등)의 아직 CreateType 안 된
      // 로컬 클래스 원소 타입을 TypeBuilder.GetMethod로 바인딩해 얻으면, 반환되는 Type
      // 객체가 fTypeBuilders에 든 원본과 참조가 달라진다(반드시 "t is TypeBuilder"도
      // 아닐 수 있다 — CLR이 내부적으로 다른 래퍼 타입으로 감싸기도 함). 이전에는
      // "t is TypeBuilder"이고 참조가 정확히 같을 때만 매칭했는데, 이 경우 매칭에
      // 실패해 실제로는 아는 로컬 클래스인데도 못 찾은 것으로 처리됐다(실제 사례:
      // PreScanNestedSubprograms의 "fTokens[fPos].Kind" — fTokens: List<TToken>).
      // 참조 비교뿐 아니라 이름 비교도 허용해 이런 래퍼 타입도 원본 로컬 클래스로
      // 되돌릴 수 있게 한다.
      foreach var _tbKvp100 in fTypeBuilders do
        if (_tbKvp100.Value = t) or (t.Name = _tbKvp100.Key) then
        begin Result:=_tbKvp100.Key; break; end;
    end;

    // [자기컴파일 버그 수정] TypeBuilder.GetField(name, BindingFlags) — 2개짜리 오버로드 —는
    // 아직 CreateType 되지 않은 TypeBuilder에서 System.NotSupportedException("유형이
    // 만들어지기 전에 호출된 멤버는 지원되지 않습니다")을 던진다(1개짜리 GetField(name)
    // 오버로드는 자신이 정의한 필드를 CreateType 전에도 찾아주지만, BindingFlags까지
    // 받는 버전은 지원하지 않는다 — .NET Reflection.Emit의 알려진 제약). obj[i].FieldName
    // 처럼 EmitIndexerGet 등에서 얻은 타입이 자기컴파일 대상 로컬 클래스(아직 미완성
    // TypeBuilder)일 때 이 예외로 죽는 실제 사례가 있었다(TScope.SetClassName 등).
    // t가 우리가 아는 로컬 클래스면 리플렉션 없이 fFieldBuilders에서 바로 찾고, 아니면
    // 기존처럼 리플렉션을 시도하되 예외는 조용히 nil로 흡수한다.
    function SafeGetField(t: System.Type; fname: string): FieldInfo;
    var _sgfCls: string;
    begin
      Result:=nil;
      if t=nil then exit;
      _sgfCls:=FindLocalClassNameForTypeBuilder(t);
      if (_sgfCls<>'') and DictDictHas(fFieldBuilders, _sgfCls, fname) then
      begin Result:=fFieldBuilders[_sgfCls][fname]; exit; end;
      try
        Result:=t.GetField(fname, BindingFlags.Public or BindingFlags.Instance);
      except
        Result:=nil;
      end;
    end;

    // 위 FindLocalClassNameForTypeBuilder로 찾은 로컬 클래스에 대해, mc.MethodName을
    // 필드(0-인자)/인스턴스 메서드/외부 상속 조상 타입 순으로 찾아 호출/로드하는 공통 로직.
    // EmitExpr 여러 지점에서 "외부 타입인 줄 알았는데 사실 로컬 클래스였다"를 처리할 때
    // 재사용한다.
    procedure EmitLocalClassMemberAccess(aIL: ILGenerator; localCls: string; mc: TMethodCallExprNode);
    var _imb100: MethodBuilder;
    begin
      if (mc.Args.Count=0) and DictDictHas(fFieldBuilders, localCls, mc.MethodName) then
        aIL.Emit(OpCodes.Ldfld, fFieldBuilders[localCls][mc.MethodName])
      else if TryFindInstanceMethod(localCls, mc.MethodName, _imb100) then
      begin
        EmitArgsCoerced(aIL, mc.Args, FindInstanceMethodParamTypes(localCls, mc.MethodName));
        aIL.Emit(OpCodes.Callvirt, _imb100);
      end
      else if FindExternalAncestorType(localCls)<>nil then
      begin
        var _extAnc100:=FindExternalAncestorType(localCls);
        var _getP100:=SafeGetProperty(_extAnc100, mc.MethodName);
        if (mc.Args.Count=0) and (_getP100<>nil) and (_getP100.GetGetMethod<>nil) then
          aIL.Emit(OpCodes.Callvirt, _getP100.GetGetMethod)
        else
        begin
          var _emi100:=ResolveMethodByArity(_extAnc100, mc.MethodName, mc.Args, false);
          if _emi100=nil then
            raise new Exception('로컬 클래스 "'+localCls+'"(외부 조상 "'+_extAnc100.FullName+'")에 메서드/필드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
          var _emi100Params:=_emi100.GetParameters;
          for var _emi100Ai:=0 to mc.Args.Count-1 do
            EmitArgForParamType(aIL, mc.Args[_emi100Ai], _emi100Params[_emi100Ai].ParameterType);
          aIL.Emit(OpCodes.Callvirt, _emi100);
        end;
      end
      else
        raise new Exception('로컬 클래스 "'+localCls+'"에 메서드/필드 "'+mc.MethodName+'"가 없습니다.');
    end;

    // 예외를 던지지 않는 버전 (외부 속성 폴백 판단용)
    function TryFindFieldBuilder(startClass, fname: string; var fb: FieldBuilder): boolean;
    var c: string;
    begin
      c:=startClass;
      while c<>'' do
      begin
        if DictDictHas(fFieldBuilders, c, fname) then
        begin fb:=fFieldBuilders[c][fname]; Result:=true; exit; end;
        c:=fClasses.GetParentName(c);
      end;
      Result:=false;
    end;

    // [Stage 96 버그 수정] TypeBuilder로 만들고 있는(아직 CreateType 안 된) 제네릭 클래스가
    // 배열 필드의 원소 타입으로 들어가면, 그 FieldType이 완전한 배열 Type이 아니라
    // System.Reflection.Emit 내부의 TypeBuilderInstantiation으로 남아있을 수 있다.
    // TypeBuilderInstantiation은 배열이든 아니든 상관없이 GetElementType() 같은 대부분의
    // Type 멤버를 구현하지 않고 무조건 NotSupportedException을 던진다(.NET Reflection.Emit의
    // 알려진 제약 — CreateType()으로 완성되기 전까지는 "확정된" Type이 아니기 때문).
    // 예전 코드는 이 호출 결과를 그대로 믿고 aiFb.FieldType.GetElementType을 두 번(nil 체크 +
    // IsValueType 체크) 호출했는데, 이 예외가 나면 EmitExpr/EmitStatement 전체가 그대로
    // 죽어버렸다(CodeGen.pas:2330, CodeGen.pas:3994). 여기서 예외를 흡수하고, 원소 타입
    // 이름으로 값/참조 여부를 최대한 추정한다 — 판단이 안 서면 참조로 간주한다(정수 배열을
    // 참조로 오판하면 Ldelem_Ref가 바로 실패해 눈에 띄지만, 반대로 참조 배열을 값 타입으로
    // 오판하면 Ldelem_I4가 조용히 쓰레기 값을 읽어 디버깅이 훨씬 어려워지므로 더 안전한
    // 쪽을 기본값으로 잡는다).
    function IsRefElementType(fieldType: System.Type): boolean;
    var elemT: System.Type; tn: string;
    begin
      try
        elemT:=fieldType.GetElementType;
        if elemT=nil then begin Result:=true; exit; end;
        try
          Result:=not elemT.IsValueType;
        except
          Result:=true; // 원소 타입 자체도 미완성 TypeBuilder라 IsValueType 조회가 실패하는 경우
        end;
      except
        on E: System.NotSupportedException do
        begin
          // TypeBuilderInstantiation이라도 ToString은 보통 동작하므로, 이름에서 흔한 값
          // 타입 원소가 보이면 값 배열로, 그 외에는 (클래스/제네릭 인스턴스 등) 참조 배열로 취급.
          tn:=fieldType.ToString;
          if tn.Contains('Int32') or tn.Contains('Int64') or tn.Contains('Double')
            or tn.Contains('Single') or tn.Contains('Boolean') or tn.Contains('Char')
            or tn.Contains('Byte') then
            Result:=false
          else
            Result:=true;
        end;
      end;
    end;

    // startClass부터 지역 상속 체인을 따라 올라가며, "외부 어셈블리 타입을 직접
    // 상속한" 클래스를 만나면 그 실제 System.Type을 반환한다 (없으면 nil).
    // 그 이후의 조상들(예: Form의 부모인 ContainerControl, Control, ...)은
    // .NET Reflection 자체가 알아서 찾아주므로 여기서 더 올라갈 필요 없음.
    function FindExternalAncestorType(startClass: string): System.Type;
    var c: string;
    begin
      c:=startClass;
      while c<>'' do
      begin
        if fClassExternalParentType.ContainsKey(c) then
        begin Result:=fClassExternalParentType[c]; exit; end;
        c:=fClasses.GetParentName(c);
      end;
      Result:=nil;
    end;

    // [Stage 76] 한정자 체인의 "첫 세그먼트"가 실제로 필드/지역변수/전역변수/self가 상속한
    // 외부 타입의 프로퍼티인지만 미리 판별한다(아무것도 방출하지 않음). "System.Windows.Forms.
    // Application.Run(f)"처럼 첫 세그먼트가 완전정규화된 외부 정적 타입의 네임스페이스 일부인
    // 경우와, "MainMenu.Items.Add(x)"처럼 진짜 변수로 시작하는 체인을 구분하기 위한 용도 —
    // 이 판별 없이는 전자를 후자로 오인해 EmitQualifierChainLoad가 "System"을 변수로 찾다가
    // 실패한다.
    function IsChainStartSegment(first: string): boolean;
    var dummyFb: FieldBuilder;
    begin
      // [자기컴파일] Result.FuncNames.AddRange(...); 처럼 함수의 Result 값에서 시작하는
      // 체인도 인식한다 — Result는 fResultLocal이라는 별도 CLR 로컬이라 필드/변수 조회로는
      // 못 찾아서 그동안 "알 수 없는 한정자"로 빠졌었다.
      if (first='Result') and (fResultLocal<>nil) then begin Result:=true; exit; end;
      if TryFindFieldBuilder(fCurClassName, first, dummyFb) then begin Result:=true; exit; end;
      if (fLocalScope.Has(first) or fGlobalScope.Has(first))
         and (fLocalScope.HasClrType(first) or fGlobalScope.HasClrType(first)) then
      begin Result:=true; exit; end;
      // [Stage 85 후속 수정] "c.Value.ToString" (c: Counter, Counter는 로컬에서 정의한 클래스)에서
      // "c.Value" 부분이 점(.)을 포함한 ObjName으로 넘어오면 InferType의 체인 분기가 이 함수로
      // 첫 세그먼트("c")가 체인 시작점인지 묻는다. 그런데 "c"는 외부 CLR 타입이 아니라 로컬에서
      // 정의한 클래스(Counter)의 인스턴스라 HasClrType은 false를 반환한다 — GetVarClassName으로
      // 로컬 클래스 인스턴스 변수인지도 확인해야 한다. 이게 없으면 "c"가 체인 시작점이 아니라고
      // 오판되어, "c.Value"를 통째로 외부 네임스페이스/타입 경로로 오인해 ResolveExternalType이
      // 호출되고 "외부 타입 'c.Value'을(를) 찾을 수 없습니다" 예외가 난다.
      if (fLocalScope.Has(first) or fGlobalScope.Has(first)) and (GetVarClassName(first)<>'') then
      begin Result:=true; exit; end;
      // [버그 수정] incName[1]처럼 원시 타입(vtString 등) 지역/전역 변수를 그대로 인덱싱/체이닝하는
      // 경우 — 원시 타입 변수는 ClrType도 ClassName도 스코프에 기록되지 않아(주석 참고, GetExprClrType의
      // 동일한 문제와 같은 사유) 지금까지는 체인 시작점으로 인식되지 못해 "알 수 없는 한정자/인덱서
      // 대상"으로 실패했다. GetVarType으로 실제 원시 타입을 확인해 통과시킨다.
      if (fLocalScope.Has(first) or fGlobalScope.Has(first))
         and ((GetVarType(first)=vtString) or (GetVarType(first)=vtInteger)
              or (GetVarType(first)=vtInt64) or (GetVarType(first)=vtReal)
              or (GetVarType(first)=vtBoolean) or (GetVarType(first)=vtChar)) then
      begin Result:=true; exit; end;
      if (FindExternalAncestorType(fCurClassName)<>nil)
         and (SafeGetProperty(FindExternalAncestorType(fCurClassName), first)<>nil) then
      begin Result:=true; exit; end;
      // [버그 수정] "Cur.Line.ToString"처럼 체인의 첫 세그먼트가 필드/변수가 아니라
      // 괄호 없이 호출하는 인자 없는 로컬 인스턴스 메서드(예: function Cur: TToken;)인
      // 경우도 체인 시작점으로 인정한다. 이게 없으면 "Cur"가 어디에도 걸리지 않아
      // "Cur.Line" 전체가 외부 정적 타입 경로로 오인된다.
      // [버그 수정/자기컴파일] fInstanceMethods[..][first].GetParameters()는 아직 CreateType되지
      // 않은(우리가 만드는 중인) 타입의 MethodBuilder에 대해서는 NotSupportedException
      // ("형식이 만들어지지 않았습니다")을 던진다 — FindInstanceMethodParamTypes와 동일한 이유로,
      // 정의 시점에 이미 계산해 둔 fMethodParamClrTypes를 대신 사용해 리플렉션 호출을 피한다.
      if fInstanceMethods.ContainsKey(fCurClassName)
         and fInstanceMethods[fCurClassName].ContainsKey(first)
         and fMethodParamClrTypes.ContainsKey(fCurClassName)
         and fMethodParamClrTypes[fCurClassName].ContainsKey(first)
         and (fMethodParamClrTypes[fCurClassName][first].Length=0) then
      begin Result:=true; exit; end;
      Result:=false;
    end;

    // [Stage 76] "MainMenu.Items.Add(x)" 같은 문장에서 파서는 마지막 세그먼트(Add)를 제외한
    // 나머지("MainMenu.Items")를 점(.)으로 이어붙인 문자열 하나로 넘겨준다. 여기서 그 문자열을
    // 다시 세그먼트 목록으로 쪼갠다. (이 파일은 실제 완전한 PascalABC.NET/.NET으로 컴파일되므로
    // string.IndexOf/Substring 같은 표준 API를 그대로 쓸 수 있다 — 우리가 만드는 컴파일러의
    // 기능 제약과는 무관하다.)
    function SplitByDot(s: string): List<string>;
    var idx: integer; rest: string;
    begin
      Result:=new List<string>;
      rest:=s;
      idx:=rest.IndexOf('.');
      while idx>=0 do
      begin
        Result.Add(rest.Substring(0, idx));
        rest:=rest.Substring(idx+1);
        idx:=rest.IndexOf('.');
      end;
      Result.Add(rest);
    end;

    // [Stage 76] 점(.)으로 연결된 한정자 체인("MainMenu.Items", "FileMenu.DropDownItems" 등)을
    // 첫 세그먼트부터 차례로 로드한다. 첫 세그먼트는 기존 단일 세그먼트 판별 순서(필드 →
    // 지역/전역 변수(외부 CLR 타입) → self가 상속한 외부 타입의 프로퍼티)를 그대로 따르고,
    // 이후 세그먼트들은 직전 결과 타입 위에서 프로퍼티(우선) 또는 필드를 순서대로 읽어
    // 내려간다. 끝나고 나면 스택엔 마지막 세그먼트가 가리키는 값이 남고, finalType은 그 값의
    // 실제 CLR 타입이다 — 호출부는 이 타입 위에서 메서드/프로퍼티를 마저 찾으면 된다.
    procedure EmitQualifierChainLoad(aIL: ILGenerator; segs: List<string>; var finalType: System.Type);
    var i: integer; curType: System.Type; pi: PropertyInfo; fi: System.Reflection.FieldInfo;
        firstFb: FieldBuilder; first: string; extSelf: System.Type;
        localClsName78: string; tbKvp78: System.Collections.Generic.KeyValuePair<string, TypeBuilder>;
        mi101: MethodInfo; // [버그 수정] 외부 CLR 타입의 괄호 없는 무인자 메서드(예: sb.ToString.Trim)용
    begin
      first:=segs[0];
      if (first='Result') and (fResultLocal<>nil) then
      begin
        aIL.Emit(OpCodes.Ldloc, fResultLocal);
        curType:=fResultLocal.LocalType;
      end
      else if TryFindFieldBuilder(fCurClassName, first, firstFb) then
      begin
        aIL.Emit(OpCodes.Ldarg_0);
        aIL.Emit(OpCodes.Ldfld, firstFb);
        curType:=firstFb.FieldType;
      end
      else if (fLocalScope.Has(first) or fGlobalScope.Has(first))
              and (fLocalScope.HasClrType(first) or fGlobalScope.HasClrType(first)) then
      begin
        if fLocalScope.Has(first) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(first))
        else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(first));
        if fLocalScope.HasClrType(first) then curType:=fLocalScope.GetClrType(first)
        else curType:=fGlobalScope.GetClrType(first);
      end
      // [Stage 85 후속 수정] first가 외부 CLR 타입(HasClrType)이 아니라 로컬에서 정의한
      // 클래스의 인스턴스 변수(예: c: Counter)일 수 있다 — GetVarClassName으로 확인하고
      // fTypeBuilders에서 그 클래스의 TypeBuilder를 curType으로 쓴다. 이게 없으면
      // "c.Value" 같은 체인의 첫 세그먼트가 이도저도 아니라고 오판돼 아래 else의
      // "self가 상속한 외부 타입" 경로로 빠지고 결국 알 수 없는 한정자 예외가 난다.
      else if (fLocalScope.Has(first) or fGlobalScope.Has(first))
              and (GetVarClassName(first)<>'') and fTypeBuilders.ContainsKey(GetVarClassName(first)) then
      begin
        if fLocalScope.Has(first) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(first))
        else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(first));
        curType:=fTypeBuilders[GetVarClassName(first)];
      end
      // [버그 수정] IsChainStartSegment와 동일 — incName[1]처럼 원시 타입 지역/전역 변수가
      // 체인의 시작점인 경우, ClrType/ClassName 둘 다 스코프에 없으므로 실제 로드 코드도
      // 여기서 새로 내야 한다(원시 타입 로컬은 Ldloc + VTC(GetVarType) 매핑으로 충분).
      else if (fLocalScope.Has(first) or fGlobalScope.Has(first))
              and ((GetVarType(first)=vtString) or (GetVarType(first)=vtInteger)
                   or (GetVarType(first)=vtInt64) or (GetVarType(first)=vtReal)
                   or (GetVarType(first)=vtBoolean) or (GetVarType(first)=vtChar)) then
      begin
        if fLocalScope.Has(first) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(first))
        else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(first));
        curType:=VTC(GetVarType(first), '');
      end
      else
      begin
        extSelf:=FindExternalAncestorType(fCurClassName);
        if (extSelf<>nil) and (SafeGetProperty(extSelf, first)<>nil) then
        begin
          aIL.Emit(OpCodes.Ldarg_0);
          pi:=SafeGetProperty(extSelf, first);
          aIL.Emit(OpCodes.Callvirt, pi.GetGetMethod);
          curType:=pi.PropertyType;
        end
        else if fInstanceMethods.ContainsKey(fCurClassName)
                and fInstanceMethods[fCurClassName].ContainsKey(first)
                and fMethodParamClrTypes.ContainsKey(fCurClassName)
                and fMethodParamClrTypes[fCurClassName].ContainsKey(first)
                and (fMethodParamClrTypes[fCurClassName][first].Length=0) then
        begin
          // [버그 수정] IsChainStartSegment와 동일한 이유 — "Cur.Line"처럼 체인의
          // 첫 세그먼트가 괄호 없이 호출하는 인자 없는 로컬 인스턴스 메서드인 경우.
          // (GetParameters() 대신 fMethodParamClrTypes로 판별 — 미완성 TypeBuilder라 리플렉션 불가)
          aIL.Emit(OpCodes.Ldarg_0);
          aIL.Emit(OpCodes.Callvirt, fInstanceMethods[fCurClassName][first]);
          curType:=fInstanceMethods[fCurClassName][first].ReturnType;
        end
        else
          raise new Exception('알 수 없는 한정자 "'+first+'" (연쇄 속성 접근의 시작점을 찾을 수 없습니다)');
      end;

      for i:=1 to segs.Count-1 do
      begin
        // [Stage 78 수정] curType이 아직 CreateType되지 않은 로컬 TypeBuilder이면
        // GetProperty/GetField가 NotSupportedException을 던진다.
        // fTypeBuilders를 역방향으로 조회해 클래스명을 찾고, fFieldBuilders에서 직접 FieldBuilder를 가져온다.
        localClsName78:='';
        if curType is TypeBuilder then
          foreach tbKvp78 in fTypeBuilders do
            if tbKvp78.Value = TypeBuilder(curType) then
            begin localClsName78:=tbKvp78.Key; break; end;

        if (localClsName78<>'') and fInstanceMethods.ContainsKey(localClsName78)
           and fInstanceMethods[localClsName78].ContainsKey('get_'+segs[i]) then
        begin
          // [Stage 85] 로컬 클래스의 프로퍼티 getter (필드가 아니라 read 접근자 메서드를
          // 호출해야 하는 경우, 예: property Enabled: boolean read FEnabled write SetEnabled;)
          var localGetM85: MethodBuilder := fInstanceMethods[localClsName78]['get_'+segs[i]];
          aIL.Emit(OpCodes.Callvirt, localGetM85);
          curType:=localGetM85.ReturnType;
        end
        // [Stage 89] 괄호 없이 부른 인자 없는 메서드 — 예: w.GetValue.ToString처럼 Pascal
        // 관례상 인자 없는 함수는 괄호를 생략할 수 있다. 프로퍼티(get_ 접두)도 필드도 아니고
        // 실제 메서드 이름과 일치하면 그냥 호출한다(인자 개수 불일치는 원래 소스가 괄호 없이
        // 쓸 수 있는 진짜 무인자 메서드라는 전제하에 검사하지 않는다).
        else if (localClsName78<>'') and fInstanceMethods.ContainsKey(localClsName78)
           and fInstanceMethods[localClsName78].ContainsKey(segs[i]) then
        begin
          var localM89: MethodBuilder := fInstanceMethods[localClsName78][segs[i]];
          aIL.Emit(OpCodes.Callvirt, localM89);
          curType:=localM89.ReturnType;
        end
        else if (localClsName78<>'') and fFieldBuilders.ContainsKey(localClsName78)
           and fFieldBuilders[localClsName78].ContainsKey(segs[i]) then
        begin
          // 로컬 클래스의 필드 — FieldBuilder로 Ldfld (private 접근도 같은 어셈블리 안에서 IL 수준으로는 허용)
          var localFb78: FieldBuilder := fFieldBuilders[localClsName78][segs[i]];
          aIL.Emit(OpCodes.Ldfld, localFb78);
          curType:=localFb78.FieldType;
        end
        else
        begin
          // 외부 CLR 타입(TreeView 등) — 기존 GetProperty/GetField 경로
          // [Stage 100] curType이 로컬 TypeBuilder인데(localClsName78<>'') 위 세 검사(로컬
          // getter/무인자메서드/필드)에 다 안 걸렸다면, 이 멤버는 로컬 클래스가 상속만 받은
          // 외부 조상 타입(예: FormChild : DockContent의 DockPanel 프로퍼티)의 것이다.
          // curType(아직 CreateType 전인 TypeBuilder) 그대로 GetProperty/GetField를 부르면
          // TypeBuilder는 리플렉션 조회 자체를 지원하지 않아 NotSupportedException
          // ("The invoked member is not supported in a dynamic module.")이 난다 — 외부 조상
          // 타입으로 바꿔서 조회한다.
          // [버그 수정 - Stage 93] TableLayoutPanel.Controls처럼 파생 타입이 'new'로 같은
          // 이름의 프로퍼티를 다른 반환 타입으로 가리는 경우 curType.GetProperty(name)이
          // AmbiguousMatchException을 던진다 — SafeGetProperty가 가장 파생된 선언으로
          // 소거해서 찾아준다.
          var _reflT100:=curType;
          if (localClsName78<>'') and (FindExternalAncestorType(localClsName78)<>nil) then
            _reflT100:=FindExternalAncestorType(localClsName78);

          pi:=SafeGetProperty(_reflT100, segs[i]);
          if pi<>nil then
          begin
            aIL.Emit(OpCodes.Callvirt, pi.GetGetMethod);
            curType:=pi.PropertyType;
          end
          else
          begin
            fi:=_reflT100.GetField(segs[i]);
            if fi<>nil then
            begin
              aIL.Emit(OpCodes.Ldfld, fi);
              curType:=fi.FieldType;
            end
            else
            begin
              // [버그 수정] 프로퍼티도 필드도 아니면, Pascal 관례상 괄호를 생략한 인자 없는
              // 메서드일 수 있다 (예: dirSb.ToString.Trim — StringBuilder.ToString()은 프로퍼티가
              // 아니라 메서드다). 로컬 클래스에는 이미 이 처리(위 [Stage 89])가 있었지만 외부
              // CLR 타입에는 빠져 있어서 곧장 "속성/필드가 없습니다"로 실패했다.
              mi101:=_reflT100.GetMethod(segs[i], System.Type.EmptyTypes);
              if mi101=nil then
                raise new Exception('타입 "'+_reflT100.FullName+'"에 속성/필드/무인자 메서드 "'+segs[i]+'"가 없습니다 (연쇄 접근 중 — 경로: '+string.Join('.', segs)+')');
              aIL.Emit(OpCodes.Callvirt, mi101);
              curType:=mi101.ReturnType;
            end;
          end;
        end;
      end;
      finalType:=curType;
    end;

    // [Stage 76 확장] EmitQualifierChainLoad와 완전히 같은 판별 순서를 따르되, IL을 전혀 방출하지
    // 않고 최종 타입만 계산한다. InferType은 aIL을 받지 않으므로(방출 시점이 아니라 타입 추론
    // 시점이므로) IL을 섞어 넣으면 명령 스트림이 깨진다 — 그래서 별도 함수로 분리했다.
    function InferQualifierChainType(segs: List<string>): System.Type;
    var i: integer; curType: System.Type; pi: PropertyInfo; fi: System.Reflection.FieldInfo;
        firstFb: FieldBuilder; first: string; extSelf: System.Type;
        localClsName78: string; tbKvp78: System.Collections.Generic.KeyValuePair<string, TypeBuilder>;
        mi101: MethodInfo; // [버그 수정] EmitQualifierChainLoad와 동일 — 괄호 없는 무인자 메서드 지원
    begin
      first:=segs[0];
      if TryFindFieldBuilder(fCurClassName, first, firstFb) then curType:=firstFb.FieldType
      else if (fLocalScope.Has(first) or fGlobalScope.Has(first))
              and (fLocalScope.HasClrType(first) or fGlobalScope.HasClrType(first)) then
      begin
        if fLocalScope.HasClrType(first) then curType:=fLocalScope.GetClrType(first)
        else curType:=fGlobalScope.GetClrType(first);
      end
      // [Stage 85 후속 수정] EmitQualifierChainLoad와 동일한 사유 — first가 로컬 클래스
      // 인스턴스 변수일 수 있으므로 GetVarClassName/fTypeBuilders로도 확인한다.
      else if (fLocalScope.Has(first) or fGlobalScope.Has(first))
              and (GetVarClassName(first)<>'') and fTypeBuilders.ContainsKey(GetVarClassName(first)) then
        curType:=fTypeBuilders[GetVarClassName(first)]
      // [버그 수정] EmitQualifierChainLoad/IsChainStartSegment와 동일 — incName[1]처럼
      // 원시 타입 지역/전역 변수가 체인 시작점인 경우의 폴백.
      else if (fLocalScope.Has(first) or fGlobalScope.Has(first))
              and ((GetVarType(first)=vtString) or (GetVarType(first)=vtInteger)
                   or (GetVarType(first)=vtInt64) or (GetVarType(first)=vtReal)
                   or (GetVarType(first)=vtBoolean) or (GetVarType(first)=vtChar)) then
        curType:=VTC(GetVarType(first), '')
      else
      begin
        extSelf:=FindExternalAncestorType(fCurClassName);
        if (extSelf<>nil) and (SafeGetProperty(extSelf, first)<>nil) then curType:=SafeGetProperty(extSelf, first).PropertyType
        // [버그 수정] EmitQualifierChainLoad/IsChainStartSegment와 동일 — "Cur.Line"처럼
        // 체인 시작점이 인자 없는 로컬 인스턴스 메서드인 경우.
        else if fInstanceMethods.ContainsKey(fCurClassName)
                and fInstanceMethods[fCurClassName].ContainsKey(first)
                and fMethodParamClrTypes.ContainsKey(fCurClassName)
                and fMethodParamClrTypes[fCurClassName].ContainsKey(first)
                and (fMethodParamClrTypes[fCurClassName][first].Length=0) then
          curType:=fInstanceMethods[fCurClassName][first].ReturnType
        else raise new Exception('알 수 없는 한정자 "'+first+'" (연쇄 속성 접근의 시작점을 찾을 수 없습니다)');
      end;

      for i:=1 to segs.Count-1 do
      begin
        // [Stage 78 수정] curType이 아직 CreateType되지 않은 로컬 TypeBuilder이면
        // GetProperty/GetField가 NotSupportedException을 던진다.
        // fTypeBuilders를 역방향으로 조회해 클래스명을 찾고, fFieldBuilders에서 직접 타입을 가져온다.
        localClsName78:='';
        if curType is TypeBuilder then
          foreach tbKvp78 in fTypeBuilders do
            if tbKvp78.Value = TypeBuilder(curType) then
            begin localClsName78:=tbKvp78.Key; break; end;

        if (localClsName78<>'') and fInstanceMethods.ContainsKey(localClsName78)
           and fInstanceMethods[localClsName78].ContainsKey('get_'+segs[i]) then
          // [Stage 85] 로컬 클래스의 프로퍼티 getter
          curType:=fInstanceMethods[localClsName78]['get_'+segs[i]].ReturnType
        // [Stage 89] 괄호 없이 부른 인자 없는 메서드 — EmitQualifierChainLoad와 동일한 사유
        else if (localClsName78<>'') and fInstanceMethods.ContainsKey(localClsName78)
           and fInstanceMethods[localClsName78].ContainsKey(segs[i]) then
          curType:=fInstanceMethods[localClsName78][segs[i]].ReturnType
        else if (localClsName78<>'') and fFieldBuilders.ContainsKey(localClsName78)
           and fFieldBuilders[localClsName78].ContainsKey(segs[i]) then
          curType:=fFieldBuilders[localClsName78][segs[i]].FieldType
        else
        begin
          // 외부 CLR 타입 — 기존 GetProperty/GetField 경로 (Stage 93: SafeGetProperty로
          // AmbiguousMatchException 방지, EmitQualifierChainLoad와 동일한 이유)
          pi:=SafeGetProperty(curType, segs[i]);
          if pi<>nil then curType:=pi.PropertyType
          else
          begin
            fi:=curType.GetField(segs[i]);
            if fi<>nil then curType:=fi.FieldType
            else
            begin
              // [버그 수정] EmitQualifierChainLoad와 동일 — 프로퍼티/필드가 아니면 괄호 없는
              // 무인자 메서드일 수 있다 (예: dirSb.ToString.Trim).
              mi101:=curType.GetMethod(segs[i], System.Type.EmptyTypes);
              if mi101=nil then
                raise new Exception('타입 "'+curType.FullName+'"에 속성/필드/무인자 메서드 "'+segs[i]+'"가 없습니다 (연쇄 접근 중 — 경로: '+string.Join('.', segs)+')');
              curType:=mi101.ReturnType;
            end;
          end;
        end;
      end;
      Result:=curType;
    end;


    // 클래스 계층을 따라 올라가며 메서드를 정의한 (진짜 소유/override) 클래스의 MethodBuilder 탐색
    function FindInstanceMethod(startClass, mname: string): MethodBuilder;
    var c: string;
    begin
      c:=startClass;
      while c<>'' do
      begin
        if DictDictHas(fInstanceMethods, c, mname) then
        begin Result:=fInstanceMethods[c][mname]; exit; end;
        c:=fClasses.GetParentName(c);
      end;
      raise new Exception('알 수 없는 메서드 "'+startClass+'.'+mname+'"');
    end;

    // 예외를 던지지 않는 버전 (외부 메서드 폴백 판단용)
    function TryFindInstanceMethod(startClass, mname: string; var mb: MethodBuilder): boolean;
    var c: string;
    begin
      c:=startClass;
      while c<>'' do
      begin
        if DictDictHas(fInstanceMethods, c, mname) then
        begin mb:=fInstanceMethods[c][mname]; Result:=true; exit; end;
        c:=fClasses.GetParentName(c);
      end;
      Result:=false;
    end;

    // [버그 수정] FindInstanceMethod/TryFindInstanceMethod가 돌려주는 MethodBuilder는
    // 아직 CreateType되지 않은(우리가 만드는 중인) 타입 소속이라 .GetParameters()를 호출하면
    // NotSupportedException("Type has not been created.")이 난다. 대신 메서드를 정의할 때
    // 이미 계산해 둔 fMethodParamClrTypes를, FindInstanceMethod와 동일하게 상속 체인을
    // 따라 올라가며 찾는다. 못 찾으면 nil을 돌려주고, 호출부는 그러면 그냥 EmitExpr로 폴백한다.
    function FindInstanceMethodParamTypes(startClass, mname: string): array of System.Type;
    var c: string;
    begin
      c:=startClass;
      while c<>'' do
      begin
        if DictDictHas(fMethodParamClrTypes, c, mname) then
        begin Result:=fMethodParamClrTypes[c][mname]; exit; end;
        c:=fClasses.GetParentName(c);
      end;
      Result:=nil;
    end;

    // 이미 알고 있는(또는 nil일 수 있는) 매개변수 CLR 타입 배열을 이용해 인자들을 순서대로
    // 스택에 올린다. paramTypes가 nil이거나 길이가 모자라면 그 인자는 그냥 EmitExpr로 폴백한다
    // (기존 동작과 동일하게 유지 — coercion은 "할 수 있을 때만" 보너스로 적용).
    procedure EmitArgsCoerced(aIL: ILGenerator; args: List<TExprNode>; paramTypes: array of System.Type);
    var _eacI: integer;
    begin
      for _eacI:=0 to args.Count-1 do
      begin
        if (paramTypes<>nil) and (_eacI<paramTypes.Length) then
          EmitArgForParamType(aIL, args[_eacI], paramTypes[_eacI])
        else
          EmitExpr(aIL, args[_eacI]);
      end;
    end;

    // 클래스 계층을 따라 올라가며 메서드의 선언된 반환 타입 탐색 (없으면 vtInteger)
    function FindMethodReturnType(startClass, mname: string): TVarType;
    var c: string;
    begin
      c:=startClass;
      while c<>'' do
      begin
        if DictDictHas(fMethodReturnTypes, c, mname) then
        begin Result:=fMethodReturnTypes[c][mname]; exit; end;
        c:=fClasses.GetParentName(c);
      end;
      Result:=vtInteger;
    end;

    // 완성된 인터페이스 Type에서 메서드의 MethodInfo 조회
    function FindInterfaceMethod(ifname, mname: string): MethodInfo;
    begin
      if not fBuiltInterfaces.ContainsKey(ifname) then
        raise new Exception('알 수 없는 인터페이스 "'+ifname+'"');
      Result:=fBuiltInterfaces[ifname].GetMethod(mname);
      if Result=nil then
        raise new Exception('인터페이스에 없는 메서드 "'+ifname+'.'+mname+'"');
    end;

    function InferType(e: TExprNode): TVarType;
    var b: TBinOpNode;
    begin
      // [Stage 96] EmitExpr/EmitStatement와 같은 재귀 깊이 카운터(fEmitDepth)를 공유한다 —
      // InferType은 TBinOpNode에서 자기 자신을 여러 번 재귀 호출하므로(왼쪽/오른쪽 각각
      // 여러 조건에서 반복 평가) 깊이 중첩된 식에서 스택을 크게 소모할 수 있다. 임계치를
      // 넘으면 잡을 수 없는 StackOverflowException 대신 진단 가능한 예외를 던진다.
      fEmitDepth:=fEmitDepth+1;
      if fEmitDepth>5000 then
      begin
        fEmitDepth:=fEmitDepth-1;
        raise new Exception('[진단] InferType 재귀 깊이 초과(5000) — 폭주 의심 노드: '+e.GetType.Name);
      end;
      try

      if e is TIntLiteralNode then Result:=vtInteger
      else if e is TRealLiteralNode  then Result:=vtReal   // [Phase 1]
      else if e is TCharLiteralNode  then Result:=vtChar   // [Phase 1]
      else if e is TInt64LiteralNode then Result:=vtInt64  // [Phase 1]
      else if e is TEnumValueExprNode then Result:=vtEnum  // [Stage 51]
      else if e is TNilLiteralNode then Result:=vtObject // [Stage 29]
      else if e is TStrLiteralNode then Result:=vtString
      else if e is TIntToStrNode then Result:=vtString
      else if e is TBoolToStrNode then Result:=vtString
      else if e is TLengthExprNode then Result:=vtInteger
      else if e is TResultRefNode then Result:=fResultType
      else if e is TNewObjectExprNode then Result:=vtObject
      else if e is TFieldReadExprNode then
      begin
        // 지역 필드는 기존처럼 단순화(정수로 간주, 기존 동작 유지).
        // 외부 상속 타입의 속성/필드면 실제 CLR 타입을 봐서 string 여부만 구분한다
        // (Writeln 등에서 string/정수 분기가 정확해야 하므로).
        var _fr:=TFieldReadExprNode(e); var _fb: FieldBuilder;
        if TryFindFieldBuilder(fCurClassName, _fr.FieldName, _fb) then
        begin
          // [Stage 30 fix] 이전에는 로컬 필드를 무조건 vtInteger로 간주했다.
          // fName: string 같은 문자열 필드가 문자열 연결식(TBinOpNode boAdd)에 쓰이면
          // lt=vtInteger로 오판되어 Convert.ToString(int32)가 문자열 참조에 호출되고,
          // 그 결과 객체 참조값이 정수로 해석되어 엉뚱한 숫자가 출력되는 버그가 있었다.
          // FieldBuilder.FieldType을 실제로 확인해 string이면 vtString으로 판정한다.
          if _fb.FieldType=typeof(string) then Result:=vtString
          else if _fb.FieldType=typeof(boolean) then Result:=vtBoolean
          else if _fb.FieldType=typeof(double)  then Result:=vtReal   // [Phase 1]
          else if _fb.FieldType=typeof(char)    then Result:=vtChar   // [Phase 1]
          else if _fb.FieldType=typeof(int64)   then Result:=vtInt64  // [Phase 1]
          else Result:=vtInteger;
        end
        else
        begin
          var _extType:=FindExternalAncestorType(fCurClassName);
          if _extType<>nil then
          begin
            var _pi:=SafeGetProperty(_extType, _fr.FieldName);
            if (_pi<>nil) and (_pi.PropertyType=typeof(string)) then Result:=vtString
            else if (_pi<>nil) and (_pi.PropertyType=typeof(boolean)) then Result:=vtBoolean
            else
            begin
              var _fi:=_extType.GetField(_fr.FieldName);
              if (_fi<>nil) and (_fi.FieldType=typeof(string)) then Result:=vtString
              else if (_fi<>nil) and (_fi.FieldType=typeof(boolean)) then Result:=vtBoolean
              else if (_fi<>nil) and (_fi.FieldType=typeof(double)) then Result:=vtReal   // [Phase 1]
              else if (_fi<>nil) and (_fi.FieldType=typeof(char))   then Result:=vtChar   // [Phase 1]
              else if (_fi<>nil) and (_fi.FieldType=typeof(int64))  then Result:=vtInt64  // [Phase 1]
              else Result:=vtInteger;
            end;
          end
          else Result:=vtInteger;
        end;
      end
      else if e is TMethodCallExprNode then
      begin
        var _mc4:=TMethodCallExprNode(e); var _qfb4: FieldBuilder;
        // [Stage 76 확장] ObjName 자체가 점(.)으로 연결된 체인이면(예: "MainMenu.Items.Count")
        // 아래의 단일 세그먼트 판별 분기들보다 먼저 처리한다 — 안 그러면 마지막 else의
        // "외부 정적 타입"으로 오인되어 존재하지 않는 타입 조회로 실패한다(Stage 76 실전 버그).
        if (_mc4.ObjName<>'') and (_mc4.ObjName.IndexOf('.')>=0) and (_mc4.ObjCastType='') then
        begin
          var _chainSegs4:=SplitByDot(_mc4.ObjName);
          if IsChainStartSegment(_chainSegs4[0]) then
          begin
            // 첫 세그먼트가 실제 필드/변수/self 상속 프로퍼티 — 체인을 끝까지 타입만 추적한다.
            var _chainType4:=InferQualifierChainType(_chainSegs4);
            var _cpi4:=SafeGetProperty(_chainType4, _mc4.MethodName);
            if (_cpi4<>nil) and (_cpi4.PropertyType=typeof(string)) then Result:=vtString
            else
            begin
              var _cmi4:=ResolveMethodByArity(_chainType4, _mc4.MethodName, _mc4.Args, false);
              if (_cmi4<>nil) and (_cmi4.ReturnType=typeof(string)) then Result:=vtString
              else Result:=vtInteger;
            end;
          end
          else
          begin
            // 첫 세그먼트가 진짜 외부 네임스페이스/타입 경로 — 기존 TStaticMemberExprNode와
            // 동일한 방식으로 정적 필드/프로퍼티를 조회한다 (예: System.EventArgs.Empty).
            var _staticT4: System.Type;
            try _staticT4:=ResolveExternalType(_mc4.ObjName); except _staticT4:=nil; end;
            // [Stage 99 버그 수정] "System.Reflection.Assembly.GetExecutingAssembly"처럼
            // ObjName 전체가 타입이 아니라 타입+무인자 정적 메서드 체인일 수 있다 — EmitExpr의
            // 동일한 경로와 같은 방식으로 재시도한다(aIL=nil이므로 IL은 방출하지 않고 최종
            // CLR 타입만 알아낸다).
            if _staticT4=nil then
            begin
              var _isInst4: boolean;
              try _staticT4:=ResolveOrEmitStaticChain(nil, _mc4.ObjName, _isInst4); except _staticT4:=nil; end;
            end;
            if _staticT4=nil then begin Result:=vtInteger; exit; end;
            var _spi4:=SafeGetProperty(_staticT4, _mc4.MethodName);
            if (_spi4<>nil) and (_spi4.PropertyType=typeof(string)) then Result:=vtString
            else
            begin
              var _sfi4:=_staticT4.GetField(_mc4.MethodName);
              if (_sfi4<>nil) and (_sfi4.FieldType=typeof(string)) then Result:=vtString
              else Result:=vtInteger;
            end;
          end;
        end
        else if _mc4.ObjName='' then // [Stage 30] Self.Method(...) / 암시적 self 호출 — 지역 메서드 우선, 없으면 외부 조상 타입
        begin
          if DictDictHas(fMethodReturnTypes, fCurClassName, _mc4.MethodName) then
            Result:=FindMethodReturnType(fCurClassName, _mc4.MethodName)
          else
          begin
            var _extSelf:=FindExternalAncestorType(fCurClassName);
            if _extSelf<>nil then
            begin
              var _pi4c:=SafeGetProperty(_extSelf, _mc4.MethodName);
              if (_pi4c<>nil) and (_pi4c.PropertyType=typeof(string)) then Result:=vtString
              else
              begin
                var _mi4c:=ResolveMethodByArity(_extSelf, _mc4.MethodName, _mc4.Args, false);
                if (_mi4c<>nil) and (_mi4c.ReturnType=typeof(string)) then Result:=vtString
                else Result:=vtInteger;
              end;
            end
            else Result:=vtInteger;
          end;
        end
        else if fLocalScope.HasClrType(_mc4.ObjName) or fGlobalScope.HasClrType(_mc4.ObjName) then
        begin
          var _effType4: System.Type;
          if fLocalScope.HasClrType(_mc4.ObjName) then _effType4:=fLocalScope.GetClrType(_mc4.ObjName)
          else _effType4:=fGlobalScope.GetClrType(_mc4.ObjName);
          if _mc4.ObjCastType<>'' then _effType4:=ResolveExternalType(_mc4.ObjCastType);
          var _pi4b:=SafeGetProperty(_effType4, _mc4.MethodName);
          if (_pi4b<>nil) and (_pi4b.PropertyType=typeof(string)) then Result:=vtString
          else
          begin
            // 프로퍼티가 아니면 메서드일 수 있으므로 실제 반환 타입을 확인한다.
            // (예: sender.ToString() → GetProperty는 nil이지만 메서드 반환타입은 string)
            var _mi4b:=ResolveMethodByArity(_effType4, _mc4.MethodName, _mc4.Args, false);
            if (_mi4b<>nil) and (_mi4b.ReturnType=typeof(string)) then Result:=vtString
            else Result:=vtInteger;
          end;
        end
        else if (_mc4.ObjCastType='') and (GetVarClassName(_mc4.ObjName)<>'') then
        begin
          // [버그 수정] EmitExpr에서 고친 것과 같은 문제 — obj.FieldName(괄호 없음, 인자 없음)은
          // 메서드가 아니라 필드일 수 있다. 여기서 먼저 확인하지 않으면 FindMethodReturnType이
          // "메서드 아님"으로 판단해 기본값 vtInteger를 돌려주고, 문자열 필드가 Writeln 등에서
          // 정수로 오인되어 참조값이 숫자로 찍히는 버그가 생긴다.
          var _cn4c:=GetVarClassName(_mc4.ObjName);
          var _fb4c: FieldBuilder;
          if (_mc4.Args.Count=0) and TryFindFieldBuilder(_cn4c, _mc4.MethodName, _fb4c) then
          begin
            if _fb4c.FieldType=typeof(string) then Result:=vtString
            else if _fb4c.FieldType=typeof(boolean) then Result:=vtBoolean
            else if _fb4c.FieldType=typeof(double)  then Result:=vtReal   // [Phase 1]
            else if _fb4c.FieldType=typeof(char)    then Result:=vtChar   // [Phase 1]
            else if _fb4c.FieldType=typeof(int64)   then Result:=vtInt64  // [Phase 1]
            else Result:=vtInteger;
          end
          else if (_mc4.Args.Count=0) and DictDictHas(fInstanceMethods, _cn4c, 'get_'+_mc4.MethodName) then
          begin
            // [Stage 51] 로컬 클래스의 프로퍼티(get_X) — 실제 getter의 반환 CLR 타입으로 판정한다.
            var _getMB4c:=fInstanceMethods[_cn4c]['get_'+_mc4.MethodName];
            if _getMB4c.ReturnType=typeof(string) then Result:=vtString
            else if _getMB4c.ReturnType=typeof(boolean) then Result:=vtBoolean
            else if _getMB4c.ReturnType=typeof(double)  then Result:=vtReal
            else if _getMB4c.ReturnType=typeof(char)    then Result:=vtChar
            else if _getMB4c.ReturnType=typeof(int64)   then Result:=vtInt64
            else Result:=vtInteger;
          end
          else if (_mc4.Args.Count=0) and (not DictDictHas(fMethodReturnTypes, _cn4c, _mc4.MethodName)) then
          begin
            // [Stage 46] 로컬 필드도 로컬 메서드도 아니면 외부 상속 타입(예: WPF Window)의
            // 프로퍼티/필드일 수 있다 (예: w.Title). FindMethodReturnType은 로컬 메서드만 뒤져서
            // 못 찾으면 무조건 vtInteger 기본값을 돌려주므로, 여기서 외부 조상 타입을 먼저 확인한다.
            var _extAnc4c:=FindExternalAncestorType(_cn4c);
            if _extAnc4c<>nil then
            begin
              var _extPi4c:=SafeGetProperty(_extAnc4c, _mc4.MethodName);
              if (_extPi4c<>nil) and (_extPi4c.PropertyType=typeof(string)) then Result:=vtString
              else if (_extPi4c<>nil) and (_extPi4c.PropertyType=typeof(boolean)) then Result:=vtBoolean
              else
              begin
                var _extFi4c:=_extAnc4c.GetField(_mc4.MethodName);
                if (_extFi4c<>nil) and (_extFi4c.FieldType=typeof(string)) then Result:=vtString
                else if (_extFi4c<>nil) and (_extFi4c.FieldType=typeof(boolean)) then Result:=vtBoolean
                else if (_extFi4c<>nil) and (_extFi4c.FieldType=typeof(double))  then Result:=vtReal  // [Phase 1]
                else if (_extFi4c<>nil) and (_extFi4c.FieldType=typeof(char))    then Result:=vtChar  // [Phase 1]
                else if (_extFi4c<>nil) and (_extFi4c.FieldType=typeof(int64))   then Result:=vtInt64 // [Phase 1]
                else Result:=vtInteger;
              end;
            end
            else Result:=vtInteger;
          end
          else
            Result:=FindMethodReturnType(_cn4c, _mc4.MethodName);
        end
        else if TryFindFieldBuilder(fCurClassName, _mc4.ObjName, _qfb4) then
        begin
          var _effType4b:=_qfb4.FieldType;
          if _mc4.ObjCastType<>'' then _effType4b:=ResolveExternalType(_mc4.ObjCastType);
          // [Stage 101] _effType4b가 아직 CreateType 전인 로컬 TypeBuilder(예: DockContent를
          // 상속하는 FormChild)면, 아래 SafeGetProperty/ResolveMethodByArity(순수 리플렉션)가
          // TypeBuilder에 대해 NotSupportedException("The invoked member is not supported in
          // a dynamic module.")을 던진다(예: formChild1.Pane의 타입을 추론하려는 경우). 이
          // 함수는 타입 추론 전용이라 IL은 안 건드리니, 외부 조상 타입으로 바꿔서 조회한다
          // (EmitQualifierChainLoad에 적용한 것과 같은 방식).
          if _effType4b is TypeBuilder then
          begin
            var _localCls101:='';
            foreach var _tbKvp101 in fTypeBuilders do
              if _tbKvp101.Value = TypeBuilder(_effType4b) then
              begin _localCls101:=_tbKvp101.Key; break; end;
            if (_localCls101<>'') and (FindExternalAncestorType(_localCls101)<>nil) then
              _effType4b:=FindExternalAncestorType(_localCls101);
          end;
          var _pi4:=SafeGetProperty(_effType4b, _mc4.MethodName);
          if (_pi4<>nil) and (_pi4.PropertyType=typeof(string)) then Result:=vtString
          else
          begin
            var _mi4:=ResolveMethodByArity(_effType4b, _mc4.MethodName, _mc4.Args, false);
            if (_mi4<>nil) and (_mi4.ReturnType=typeof(string)) then Result:=vtString
            else Result:=vtInteger;
          end;
        end
        // [버그 수정] 지역/전역 원시 타입 변수(integer, real, boolean 등)의 .ToString() 호출.
        // 예: sum.ToString (sum: integer) — ObjName이 fLocalScope/fGlobalScope에 있고
        // MethodName이 'ToString'이면 결과는 항상 string이다.
        // 이전에는 이 케이스가 아래의 else Result:=vtInteger로 폴백되어, 문자열 연결식
        // ('Add(3,4) = ' + sum.ToString)에서 rt=vtInteger로 오판되고, 실제로는 string이
        // 스택에 올라와 있는데도 Convert.ToString(int32)가 다시 호출되어 string 참조값을
        // 정수로 읽어 쓰레기값(메모리 주소)이 출력됐다.
        else if (fLocalScope.Has(_mc4.ObjName) or fGlobalScope.Has(_mc4.ObjName))
                and (_mc4.Args.Count=0) and (_mc4.ObjCastType='')
                and (_mc4.MethodName.ToLower='tostring') then
          Result:=vtString
        else Result:=vtInteger;
      end
      // [Stage 37 버그 수정] 이전에는 배열이 실제로 array of string이어도 무조건 vtInteger로
      // 추론해서, Writeln(strArr[i]) 같은 식이 Console.WriteLine(int) 오버로드로 잘못 디스패치됐다.
      else if e is TArrayIndexExprNode then
      begin
        if GetVarType(TArrayIndexExprNode(e).ArrName)=vtStrArray then Result:=vtString
        // [Stage 90] array of object 원소 읽기는 vtObject로 추론
        else if GetVarType(TArrayIndexExprNode(e).ArrName)=vtObjArray then Result:=vtObject
        else Result:=vtInteger;
      end
      // [Stage 67] 2차원 배열 원소 읽기 타입 추론
      else if e is TMatrix2DIndexExprNode then
      begin
        var _m2n:=TMatrix2DIndexExprNode(e);
        var _m2etn:=GetVarClassName(_m2n.ArrName); // 원소 타입 이름
        if _m2etn='string' then Result:=vtString
        else if (_m2etn='real') or (_m2etn='double') then Result:=vtReal
        else if _m2etn='char' then Result:=vtChar
        else if _m2etn='int64' then Result:=vtInt64
        else Result:=vtInteger;
      end
      else if e is TVarRefNode then Result:=GetVarType(TVarRefNode(e).VarName)
      else if e is TFuncCallExprNode then
      begin
        // [Stage 27] 이전에는 이 분기 자체가 없어 최상위 함수 호출식은 항상
        // vtInteger로 취급됐다 — 'x: ' + Greet(name) 같은 식에서 Greet()가
        // string을 반환해도 정수 변환 경로를 타 값이 깨졌다.
        var _fc4:=TFuncCallExprNode(e);
        if fFuncReturnTypes.ContainsKey(_fc4.FuncName) then Result:=fFuncReturnTypes[_fc4.FuncName]
        // [Stage 71] 단형화되지 않고 오픈 제네릭으로 남은 템플릿의 맹글링된 호출이면
        // fFuncReturnTypes에는 (구체 이름이 아니라) 템플릿 이름만 등록돼 있으므로 직접 계산한다.
        else if fOpenGenericCallMap.ContainsKey(_fc4.FuncName) then
          Result:=ResolveOpenGenericFuncReturnType(fOpenGenericCallMap[_fc4.FuncName])
        // [셀프 컴파일 버그 수정] fFuncReturnTypes는 최상위 함수/프로시저 전용 표라서,
        // 클래스 안에 중첩 선언된 뒤 호이스트되어 fMethods에만 등록된 헬퍼 함수(예:
        // ResolveMethodByArity — InferType 자신이 한정자 없이 호출)는 여기서 못 찾고
        // 무조건 vtInteger로 폴백했다. 그 결과 "var _mi4:=ResolveMethodByArity(...)"가
        // int32 지역 슬롯으로 잘못 선언되어 이후 "_mi4.ReturnType"이 "알 수 없는 메서드
        // .ReturnType"으로 실패했다. fMethods에 등록되어 있고 반환 타입이 string이면
        // vtString으로, 그 외 참조 타입(void 아님)이면 vtObject로 바로잡는다 — 나머지
        // 원시 스칼라 판별(int64/real/bool/char)까지는 여기서 다루지 않아도 EmitExpr/
        // TInlineVarStmtNode 쪽이 GetExprClrType으로 실제 CLR 타입을 다시 정확히 구하므로
        // 안전하다(이 함수는 어디까지나 "대략적인 모양"만 알려주는 용도).
        else if fMethods.ContainsKey(_fc4.FuncName) then
        begin
          var _fc4Ret:=fMethods[_fc4.FuncName].ReturnType;
          if _fc4Ret=typeof(string) then Result:=vtString
          else if (_fc4Ret<>typeof(System.Void)) and (not _fc4Ret.IsPrimitive) then Result:=vtObject
          else Result:=vtInteger;
        end
        else Result:=vtInteger;
      end
      else if e is TExceptionMsgExprNode then Result:=vtString // E.Message는 항상 string
      else if e is TRuntimeTypeNameExprNode then Result:=vtString // [Stage 75] obj.GetType.FullName/.Name도 항상 string
      else if e is TStaticMemberExprNode then
      begin
        var _sm4:=TStaticMemberExprNode(e);
        var _smType4:=ResolveExternalType(_sm4.TypeName);
        var _smPi4:=SafeGetProperty(_smType4, _sm4.MemberName);
        if (_smPi4<>nil) and (_smPi4.PropertyType=typeof(string)) then Result:=vtString
        else
        begin
          var _smFi4:=_smType4.GetField(_sm4.MemberName);
          if (_smFi4<>nil) and (_smFi4.FieldType=typeof(string)) then Result:=vtString
          else Result:=vtInteger;
        end;
      end
      else if e is TCompareNode then // [Stage 41 수정 2026.07.11]
        Result:=vtBoolean
      // [Stage 63] 집합 리터럴/멤버십 검사
      else if e is TSetLiteralExprNode then Result:=vtSet
      else if e is TInExprNode then Result:=vtBoolean
      // [Stage 96] 일반 배열 리터럴 — 실제 CLR 배열 타입은 문맥(대입 대상/매개변수 타입)에 따라
      // 달라지므로 여기서는 "참조 타입"이라는 것만 표시해둔다(EmitArgForParamType/EmitExpr이
      // 실제 원소 타입까지 보고 Newarr/Stelem을 낸다).
      else if e is TArrayLiteralExprNode then Result:=vtObject
      else if e is TBinOpNode then
      begin
        b:=TBinOpNode(e);
        // [성능 수정 2026.08] 예전엔 이 분기에서 InferType(b.Left)/InferType(b.Right)를
        // 조건마다(최대 5번씩, 총 최대 10회) 다시 호출했다. b.Left/b.Right 자체가 또
        // TBinOpNode면 그 재귀 호출들이 각자 다시 최대 10개씩 하위 InferType을 부르므로
        // 중첩된 이항식(예: 실제 컴파일러 소스에 흔한 a+b+c+d+... 나 여러 개의 and/or로
        // 이어진 조건식)에서 호출 횟수가 트리 깊이에 대해 지수적으로 폭증했다
        // (깊이 d일 때 대략 9^d 자릿수). 이게 "4단계 컴파일이 끝없이 오래 걸리는" 현상의
        // 근본 원인이었다 — 심볼 테이블 문제가 아니라 캐싱 없는 재귀 타입 추론 문제.
        // 좌/우 타입을 딱 한 번씩만 계산해서 지역변수에 담아두고 재사용한다.
        var _binLt:=InferType(b.Left);
        var _binRt:=InferType(b.Right);
        // [Stage 66] 두 피연산자 모두 vtObject면(연산자 오버로딩 대상) 결과도 vtObject —
        // 실제 오버로딩이 등록되어 있는지는 EmitExpr에서 검증하고, 여기서는 타입 모양만 전달한다.
        if (_binLt=vtObject) and (_binRt=vtObject) then Result:=vtObject
        // [Stage 63] 피연산자 중 하나라도 집합이면 결과도 집합 (합집합/차집합/교집합)
        else if (_binLt=vtSet) or (_binRt=vtSet) then Result:=vtSet
        else if (_binLt=vtString) or (_binRt=vtString) then
          Result:=vtString
        // [버그 수정] 예전엔 이 분기가 없어서 real/int64가 섞인 이항연산(예: -3.7, 1.5+2)이
        // 전부 vtInteger로 잘못 추론됐다 — 실제 IL 생성(EmitExpr의 isReal 승격 로직, 이 파일
        // 위쪽)은 이미 올바르게 real로 처리하고 있었으니 InferType만 뒤처져 있던 것.
        // Writeln(-3.7)처럼 InferType 결과로 어떤 WriteLine 오버로드를 호출할지 고르는
        // 자리에서 int32 오버로드가 선택되어 스택의 double 값과 어긋나 런타임에 깨졌다.
        else if (_binLt=vtReal) or (_binRt=vtReal) then Result:=vtReal
        else if (_binLt=vtInt64) or (_binRt=vtInt64) then Result:=vtInt64
        else Result:=vtInteger;
      end
      else if e is TSelfExprNode then Result:=vtObject // [Stage 30]
      else if e is TAsCastExprNode then // [Stage 30]
      begin
        var _ac:=TAsCastExprNode(e);
        if fBuiltInterfaces.ContainsKey(_ac.TargetType) then Result:=vtInterface
        else Result:=vtObject;
      end
      else if e is TIsCheckExprNode then Result:=vtBoolean // [Stage 93c] <식> is <TypeName> → 항상 bool
      else if e is TInheritedCallExprNode then // [Stage 30]
      begin
        var _ih:=TInheritedCallExprNode(e);
        var _pc:=fClasses.GetParentName(fCurClassName);
        if _pc<>'' then Result:=FindMethodReturnType(_pc, _ih.MethodName)
        else Result:=vtInteger;
      end
      // [Stage 70] LINQ 스타일 확장 메서드. Where/Select 자체(중간 결과)는 1차 제약으로 값으로
      // 직접 저장/사용하지 않는 것이 원칙(더 체이닝하거나 for-in의 컬렉션 자리에만 씀)이라 vtObject로
      // 폴백해 둔다. Sum/Count/ToArray는 최종(terminal) 연산이라 실제로 의미 있는 타입을 돌려준다.
      else if e is TSeqExtCallExprNode then
      begin
        var _se70:=TSeqExtCallExprNode(e);
        if _se70.MethodName='Count' then Result:=vtInteger
        else if _se70.MethodName='Sum' then Result:=GetSeqElemType(_se70.Source)
        else if _se70.MethodName='ToArray' then
        begin
          var _elemT70:=GetSeqElemType(_se70.Source);
          if _elemT70=vtString then Result:=vtStrArray else Result:=vtIntArray;
        end
        else Result:=vtObject; // Where/Select 중간 결과
      end
      // [Stage 72] PABCSystem 표준 라이브러리 함수 호출의 결과 타입.
      else if e is TBuiltinCallExprNode then
      begin
        var _bc72:=TBuiltinCallExprNode(e);
        if (_bc72.Name='Abs') or (_bc72.Name='Sqr') then
        begin
          if _bc72.Args.Count>0 then Result:=InferType(_bc72.Args[0]) else Result:=vtInteger;
        end
        else if (_bc72.Name='Sqrt') or (_bc72.Name='StrToFloat') then Result:=vtReal
        else if (_bc72.Name='Round') or (_bc72.Name='Trunc') or (_bc72.Name='StrToInt') or (_bc72.Name='Ord') then
          Result:=vtInteger
        else if _bc72.Name='Random' then
        begin
          if _bc72.Args.Count=0 then Result:=vtReal else Result:=vtInteger;
        end
        else if (_bc72.Name='UpperCase') or (_bc72.Name='LowerCase') or (_bc72.Name='Trim')
                or (_bc72.Name='Copy') or (_bc72.Name='FloatToStr') or (_bc72.Name='ReadLn')
                or (_bc72.Name='Format') or (_bc72.Name='GetCurrentDir') or (_bc72.Name='ParamStr') then // [Stage 90/93/96]
          Result:=vtString
        else if _bc72.Name='Pos' then Result:=vtInteger
        else if _bc72.Name='Chr' then Result:=vtChar
        else if _bc72.Name='ParamCount' then Result:=vtInteger // [Stage 96]
        else Result:=vtInteger; // 방어적 폴백(정상 경로면 도달하지 않음)
      end
      // [Stage 91] typeof(...)의 결과(System.Type)는 별도 vtType이 없으므로 vtObject로 취급.
      else if e is TTypeOfExprNode then Result:=vtObject
      // [Stage 90] TargetType(expr) 캐스트 결과 — 캐스트 대상 타입 자체가 곧 결과 타입.
      // vtObject로 취급하고 클래스 이름은 GetExprClrType/ObjCastType 경로에서 다시 조회되므로
      // 여기서는 "객체"라는 사실만 전달하면 충분하다.
      else if e is TExternalCastExprNode then Result:=vtObject
      // [Stage 90] a.GetName().Version.ToString() 같은 체인의 결과 타입 — 실제 CLR 반환
      // 타입을 리플렉션으로 추론해 가장 가까운 Pascal 타입으로 매핑한다(예: string→vtString).
      else if e is TChainedMemberExprNode then
      begin
        var _chT90:=GetExprClrType(e);
        if _chT90=typeof(string) then Result:=vtString
        else if _chT90=typeof(integer) then Result:=vtInteger
        else if _chT90=typeof(int64) then Result:=vtInt64
        else if _chT90=typeof(double) then Result:=vtReal
        else if _chT90=typeof(boolean) then Result:=vtBoolean
        else if _chT90=typeof(char) then Result:=vtChar
        else Result:=vtObject;
      end
      else Result:=vtInteger;
      finally
        fEmitDepth:=fEmitDepth-1;
      end;
    end;

    // [Stage 70] "시퀀스처럼 취급 가능한 식" e의 원소 Pascal 타입을 알아낸다.
    // 1차 제약: e는 (a) sequence of T 함수 호출(TFuncCallExprNode, fIterElemVarType에 등록됨)이거나
    // (b) 그 자체가 Where/Select 체인(TSeqExtCallExprNode)이어야 한다 — 지역 변수/필드에 저장된
    // 시퀀스는 아직 지원하지 않는다(향후 단계에서 vtSequence 같은 정식 타입을 도입하면 확장 가능).
    function GetSeqElemType(e: TExprNode): TVarType;
    begin
      if (e is TFuncCallExprNode) and fIterElemVarType.ContainsKey(TFuncCallExprNode(e).FuncName) then
        Result:=fIterElemVarType[TFuncCallExprNode(e).FuncName]
      else if e is TSeqExtCallExprNode then
      begin
        var _sse:=TSeqExtCallExprNode(e);
        if _sse.MethodName='Where' then
          Result:=GetSeqElemType(_sse.Source) // 필터는 원소 타입을 바꾸지 않는다
        else if _sse.MethodName='Select' then
        begin
          // selector 본문의 결과 타입 = 이 체인의 새 원소 타입. 매개변수를 임시로 지역
          // 스코프에 등록해 두고(실제 IL 로컬은 필요 없음 — InferType은 VType만 읽으므로
          // Loc=nil로 안전) selector 본문을 평범한 식으로 타입 추론한다.
          var _srcElem:=GetSeqElemType(_sse.Source);
          var _hadEntry:=fLocalScope.Has(_sse.Lambda.ParamName);
          fLocalScope.Declare(_sse.Lambda.ParamName, nil, _srcElem);
          Result:=InferType(_sse.Lambda.Body);
          if not _hadEntry then fLocalScope.Remove(_sse.Lambda.ParamName);
        end
        else
          // Sum/Count/ToArray는 시퀀스가 아니라 최종 스칼라/배열 값이므로 그 위에 다시
          // Where/Select/... 를 체이닝할 수 없다 — 파서가 걸러주지 못한 경우를 대비한 방어.
          raise new Exception('"'+_sse.MethodName+'"의 결과에는 더 이상 시퀀스 확장 메서드를 체이닝할 수 없습니다 (Stage 70, 1차 제약)');
      end
      else
        raise new Exception('시퀀스로 취급할 수 없는 식입니다: '+e.GetType.Name
          +' (Stage 70, 1차 제약: sequence of T 함수 호출 또는 Where/Select 체인만 지원)');
    end;

    // [Stage 30] inherited MethodName(args) 공통 구현. 식/문장 양쪽에서 재사용.
    // 1) 지역 부모 클래스 체인에서 먼저 찾는다 — 찾으면 Call(비가상)로 그 MethodBuilder를
    //    직접 호출해 가상 디스패치(자기 자신의 override)를 우회한다.
    // 2) 없으면(지역 부모가 없거나, 부모 체인에 그 메서드가 없으면) 외부 조상 타입
    //    (WPF Window 등)에서 이름+인자개수로 찾아 마찬가지로 Call(비가상)로 호출한다.
    // keepReturnValue=true(식으로 쓰임)면 반환값을 스택에 남기고, false(문장)면 버린다.
    // [Stage 42] inherited Create(...) 처리 — 현재 클래스의 부모 생성자를 호출한다.
    // 부모가 로컬 클래스면 fCtorBuilders에 이미 만들어 둔 ConstructorBuilder를 그대로 쓰고
    // (아직 CreateType 전이라 GetConstructor를 쓸 수 없음), 외부 타입이면 인자 개수로 찾는다.
    procedure EmitInheritedCtorCall(aIL: ILGenerator; args: List<TExprNode>);
    var startCls3: string; parentCtor3: ConstructorInfo; extType3: System.Type; ae3: TExprNode;
    begin
      startCls3:=fClasses.GetParentName(fCurClassName);

      aIL.Emit(OpCodes.Ldarg_0); // self

      if (startCls3<>'') and fCtorBuilders.ContainsKey(startCls3) then
      begin
        // [Stage 47] 로컬 부모 클래스도 이제 매개변수 있는 생성자를 지원한다.
        // [버그 수정] ConstructorBuilder.GetParameters()는 CreateType 전에는 예외를 던지므로
        // 정의 시점에 미리 계산해 둔 fCtorParamClrTypes를 대신 사용한다.
        // [Stage 99] 부모가 생성자를 여러 개(오버로드) 가질 수 있으므로, 이 호출의 인자
        // 개수와 일치하는 것을 FindLocalCtorIndex로 골라 그 생성자를 호출한다.
        var _parentCtorIdx3:=FindLocalCtorIndex(startCls3, args.Count);
        if _parentCtorIdx3<0 then
          raise new Exception('inherited Create: 부모 클래스 "'+startCls3+'"에 인자 '+args.Count.ToString+'개짜리 생성자가 없습니다.');
        var _parentCtorParams3:=fCtorParamClrTypes[startCls3][_parentCtorIdx3];
        EmitArgsCoerced(aIL, args, _parentCtorParams3);
        aIL.Emit(OpCodes.Call, fCtorBuilders[startCls3][_parentCtorIdx3]);
      end
      else
      begin
        extType3:=FindExternalAncestorType(fCurClassName);
        if extType3=nil then
          raise new Exception('inherited Create: 클래스 "'+fCurClassName+'"에서 부모/외부 조상 타입을 찾을 수 없습니다.');
        if args.Count=0 then
        begin
          parentCtor3:=extType3.GetConstructor(System.Type.EmptyTypes);
          if parentCtor3=nil then
            raise new Exception('외부 조상 타입 "'+extType3.FullName+'"에 매개변수 없는 public 생성자가 없습니다.');
        end
        else
        begin
          parentCtor3:=ResolveConstructorByArity(extType3, args);
          if parentCtor3=nil then
            raise new Exception('외부 조상 타입 "'+extType3.FullName+'"에 인자 '+args.Count.ToString+'개짜리 public 생성자가 없습니다.');
        end;
        var _parentCtorParams3b:=parentCtor3.GetParameters;
        for var _pcAi3b:=0 to args.Count-1 do
          EmitArgForParamType(aIL, args[_pcAi3b], _parentCtorParams3b[_pcAi3b].ParameterType);
        aIL.Emit(OpCodes.Call, parentCtor3);
      end;
    end;

    procedure EmitInheritedCall(aIL: ILGenerator; mname: string; args: List<TExprNode>; keepReturnValue: boolean);
    var startCls: string; imb2: MethodBuilder; extType2: System.Type; emi2: MethodInfo;
        ae2: TExprNode; found: boolean;
    begin
      // [Stage 42] inherited Create(...) — 일반 메서드 호출이 아니라 부모 생성자 호출.
      // 부모에는 "Create"라는 이름의 인스턴스 메서드가 없으므로(생성자는 fCtorBuilders/
      // 리플렉션 생성자 조회로 별도 관리됨) 여기서 갈라서 처리한다.
      if mname='Create' then
      begin
        EmitInheritedCtorCall(aIL, args);
        exit;
      end;

      startCls:=fClasses.GetParentName(fCurClassName);
      found:=false;
      if startCls<>'' then found:=TryFindInstanceMethod(startCls, mname, imb2);

      aIL.Emit(OpCodes.Ldarg_0); // self

      if found then
      begin
        EmitArgsCoerced(aIL, args, FindInstanceMethodParamTypes(startCls, mname));
        aIL.Emit(OpCodes.Call, imb2); // 비가상 호출 — 부모의 실제 구현을 직접 호출
        if keepReturnValue then
        begin
          if imb2.ReturnType=typeof(System.Void) then
            raise new Exception('inherited '+mname+'는 값을 반환하지 않습니다(procedure) — 식으로 사용할 수 없습니다.');
        end
        else if imb2.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
      end
      else
      begin
        extType2:=FindExternalAncestorType(fCurClassName);
        if extType2=nil then
          raise new Exception('inherited '+mname+': 클래스 "'+fCurClassName+'"에서 부모/외부 조상 타입을 찾을 수 없습니다.');
        emi2:=ResolveMethodByArity(extType2, mname, args, false);
        if emi2=nil then
          raise new Exception('외부 조상 타입 "'+extType2.FullName+'"에 메서드 "'+mname+'"가 없습니다 (인자 '+args.Count.ToString+'개).');
        var _emi2Params:=emi2.GetParameters;
        for var _emi2Ai:=0 to args.Count-1 do
          EmitArgForParamType(aIL, args[_emi2Ai], _emi2Params[_emi2Ai].ParameterType);
        aIL.Emit(OpCodes.Call, emi2); // 비가상 호출
        if keepReturnValue then
        begin
          if emi2.ReturnType=typeof(System.Void) then
            raise new Exception('inherited '+mname+'는 값을 반환하지 않습니다(procedure) — 식으로 사용할 수 없습니다.');
        end
        else if emi2.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
      end;
    end;

    // [Stage 71] finst.TemplateName에 해당하는, 단형화되지 않고 그대로 남은 최상위 제네릭
    // 함수 템플릿을 찾아 이 호출식의 반환 타입을 계산한다(InferType이 이 정보를 몰라도 되게
    // fFuncReturnTypes에는 맹글링된 구체 이름이 아니라 템플릿 이름 하나만 등록돼 있으므로).
    // 함수 목록은 짧고 호출식마다 한 번뿐인 조회라 선형 탐색으로 충분하다.
    function ResolveOpenGenericFuncReturnType(finst: TGenericFuncInstantiation): TVarType;
    var tmpl71: TFuncDeclNode; i71: integer;
    begin
      tmpl71:=nil;
      foreach var fd71 in fProg.FuncDecls do
        if fd71.Name=finst.TemplateName then begin tmpl71:=fd71; break; end;
      if tmpl71=nil then begin Result:=vtInteger; exit; end; // 방어적 폴백(정상 경로면 항상 찾음)
      if tmpl71.ReturnType<>vtGeneric then begin Result:=tmpl71.ReturnType; exit; end;
      Result:=vtInteger;
      for i71:=0 to tmpl71.GenericParamNames.Count-1 do
        if tmpl71.GenericParamNames[i71]=tmpl71.ReturnGenericName then
        begin Result:=finst.ArgTypes[i71]; exit; end;
    end;

    // [Stage 71] true open generic으로 남은 함수/프로시저 호출 하나를 실제로 컴파일한다.
    // finst.TemplateName으로 등록된 열린 제네릭 MethodBuilder를 실제 타입 인자로
    // MakeGenericMethod한 뒤 Call한다. EmitArgsCoerced는 paramTypes=nil로 호출해 인자를
    // 있는 그대로 컴파일한다 — 1차 제약: 제네릭 매개변수 자리에서 int→real 같은 자동 승격은
    // 지원하지 않는다(호출 시 타입 인자와 정확히 같은 타입의 값을 넘겨야 함).
    procedure EmitOpenGenericCall(aIL: ILGenerator; finst: TGenericFuncInstantiation; args: List<TExprNode>);
    var baseMB: MethodBuilder; closedTypes: array of System.Type; i: integer; closedMI: MethodInfo;
    begin
      if not fMethods.ContainsKey(finst.TemplateName) then
        raise new Exception('알 수 없는 오픈 제네릭 템플릿 "'+finst.TemplateName+'" (Stage 71)');
      baseMB:=fMethods[finst.TemplateName];
      closedTypes:=new System.Type[finst.ArgTypes.Count];
      for i:=0 to finst.ArgTypes.Count-1 do
        closedTypes[i]:=VTC(finst.ArgTypes[i], finst.ArgClassNames[i]);
      closedMI:=baseMB.MakeGenericMethod(closedTypes);
      EmitArgsCoerced(aIL, args, nil);
      aIL.Emit(OpCodes.Call, closedMI);
    end;