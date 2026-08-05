// ============================================================
// CodeGen.pas — 목적코드(IL) 생성 (TCodeGenerator)
// AST.pas(노드 타입)에 의존, System.Reflection.Emit으로 실제 IL 방출.
// 새 기능(클래스, 예외, 제네릭 등)의 "실행 가능한 구현체"가 여기 모임.
// 지금 프로젝트에서 가장 자주 바뀌는 파일 = 현재의 실질적 병목 지점.
// ============================================================
unit CodeGen;

interface

uses
  System.Text,
  System.Collections.Generic,
  System.Reflection,
  System.Reflection.Emit,
  System.Globalization,
  AST,
  Scope,
  Symbols;

type
  // [Stage 99 버그 수정] TypeBuilderInstantiation(예: List<TToken>처럼, 원소 타입이 아직
  // CreateType되지 않은 로컬 클래스인 BCL 제네릭 컬렉션)의 프로퍼티(Count, Item 등)에
  // 접근하려면 .NET Reflection.Emit의 공식 우회법 — 열린 제네릭 정의(List<>)에서 멤버를
  // 찾고 TypeBuilder.GetMethod로 그 접근자(get_.../set_...)만 닫힌 버전에 바인딩 — 이
  // 필요하다(SafeGetMethods/SafeGetConstructor(s)가 이미 메서드/생성자에 이 방식을 쓰고
  // 있음, 아래 참고). 다만 PropertyInfo 자체는 공개 API로 직접 만들 수 없는 추상 클래스라,
  // 바인딩된 get/set MethodInfo만 감싸는 최소 래퍼가 필요하다. CodeGen.pas 안에서 실제로
  // 쓰이는 멤버는 PropertyType/GetGetMethod/GetSetMethod/Name/DeclaringType 뿐이고,
  // GetValue/SetValue(런타임 호출)나 커스텀 특성 조회는 IL 방출 중에는 쓰이지 않으므로
  // 지원하지 않는다(호출 시 예외).
  TBoundGenericPropertyInfo = class(PropertyInfo)
  private
    fName: string;
    fDeclType, fPropType: System.Type;
    fGetter, fSetter: MethodInfo;
    fIndexParams: array of ParameterInfo;
    fAttrs: PropertyAttributes;
    function GetCanRead0: boolean;
    begin Result := fGetter <> nil; end;
    function GetCanWrite0: boolean;
    begin Result := fSetter <> nil; end;
  public
    constructor Create(openProp: PropertyInfo; declType: System.Type; getter, setter: MethodInfo);
    begin
      fName := openProp.Name;
      fDeclType := declType;
      fGetter := getter;
      fSetter := setter;
      fAttrs := openProp.Attributes;
      if getter <> nil then
      begin
        fPropType := getter.ReturnType;
        fIndexParams := getter.GetParameters;
      end
      else if setter <> nil then
      begin
        var sp99 := setter.GetParameters;
        if sp99.Length > 0 then fPropType := sp99[sp99.Length - 1].ParameterType
        else fPropType := typeof(System.Object);
        var res99 := new List<ParameterInfo>;
        for var ip99 := 0 to sp99.Length - 2 do res99.Add(sp99[ip99]);
        fIndexParams := res99.ToArray;
      end
      else
      begin
        fPropType := typeof(System.Object);
        fIndexParams := new ParameterInfo[0];
      end;
    end;

    property Name: string read fName; override;
    property DeclaringType: System.Type read fDeclType; override;
    property ReflectedType: System.Type read fDeclType; override;
    property PropertyType: System.Type read fPropType; override;
    property Attributes: PropertyAttributes read fAttrs; override;
    property CanRead: boolean read GetCanRead0; override;
    property CanWrite: boolean read GetCanWrite0; override;

    function GetAccessors(nonPublic: boolean): array of MethodInfo; override;
    begin
      var lst99 := new List<MethodInfo>;
      if fGetter <> nil then lst99.Add(fGetter);
      if fSetter <> nil then lst99.Add(fSetter);
      Result := lst99.ToArray;
    end;

    function GetGetMethod(nonPublic: boolean): MethodInfo; override;
    begin Result := fGetter; end;

    function GetSetMethod(nonPublic: boolean): MethodInfo; override;
    begin Result := fSetter; end;

    function GetIndexParameters: array of ParameterInfo; override;
    begin Result := fIndexParams; end;

    // [버그 수정] PropertyInfo에서 실제로 추상인 오버로드는 이 5개짜리(BindingFlags/Binder/
    // CultureInfo까지 받는) 버전이다 — 2/3개짜리 GetValue(obj,index)/SetValue(obj,value,index)는
    // 이 버전을 호출하는 비추상 편의 메서드일 뿐이라, 그것만 override해서는 추상 멤버가
    // 여전히 남아 "추상 클래스는 인스턴스화할 수 없습니다" 오류가 난다.
    function GetValue(obj: System.Object; invokeAttr: BindingFlags; binder: Binder;
      index: array of System.Object; culture: CultureInfo): System.Object; override;
    begin
      raise new System.NotSupportedException('TBoundGenericPropertyInfo.GetValue는 지원되지 않습니다 (코드생성 전용 래퍼입니다).');
    end;

    procedure SetValue(obj: System.Object; value: System.Object; invokeAttr: BindingFlags; binder: Binder;
      index: array of System.Object; culture: CultureInfo); override;
    begin
      raise new System.NotSupportedException('TBoundGenericPropertyInfo.SetValue는 지원되지 않습니다 (코드생성 전용 래퍼입니다).');
    end;

    function GetCustomAttributes(inherit: boolean): array of System.Object; override;
    begin Result := new System.Object[0]; end;

    function GetCustomAttributes(attributeType: System.Type; inherit: boolean): array of System.Object; override;
    begin Result := new System.Object[0]; end;

    function IsDefined(attributeType: System.Type; inherit: boolean): boolean; override;
    begin Result := false; end;
  end;

  TCodeGenerator = class
  private
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
        if fFieldObjClassName.ContainsKey(fCurClassName) and fFieldObjClassName[fCurClassName].ContainsKey(_fr66.FieldName) then
        begin outCn:=fFieldObjClassName[fCurClassName][_fr66.FieldName]; Result:=true; end
        else Result:=false;
      end
      else if (ex is TMethodCallExprNode) and (TMethodCallExprNode(ex).Args.Count=0) and (TMethodCallExprNode(ex).ObjName<>'') then
      begin
        _mc66:=TMethodCallExprNode(ex);
        _ownerCn66:=GetVarClassName(_mc66.ObjName);
        if (_ownerCn66<>'') and fFieldObjClassName.ContainsKey(_ownerCn66) and fFieldObjClassName[_ownerCn66].ContainsKey(_mc66.MethodName) then
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
        if fFieldBuilders.ContainsKey(c) and fFieldBuilders[c].ContainsKey(fname) then
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
      if t is TypeBuilder then
        foreach var _tbKvp100 in fTypeBuilders do
          if _tbKvp100.Value = TypeBuilder(t) then
          begin Result:=_tbKvp100.Key; break; end;
    end;

    // 위 FindLocalClassNameForTypeBuilder로 찾은 로컬 클래스에 대해, mc.MethodName을
    // 필드(0-인자)/인스턴스 메서드/외부 상속 조상 타입 순으로 찾아 호출/로드하는 공통 로직.
    // EmitExpr 여러 지점에서 "외부 타입인 줄 알았는데 사실 로컬 클래스였다"를 처리할 때
    // 재사용한다.
    procedure EmitLocalClassMemberAccess(aIL: ILGenerator; localCls: string; mc: TMethodCallExprNode);
    var _imb100: MethodBuilder;
    begin
      if (mc.Args.Count=0) and fFieldBuilders.ContainsKey(localCls) and fFieldBuilders[localCls].ContainsKey(mc.MethodName) then
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
        if fFieldBuilders.ContainsKey(c) and fFieldBuilders[c].ContainsKey(fname) then
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
        if fInstanceMethods.ContainsKey(c) and fInstanceMethods[c].ContainsKey(mname) then
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
        if fInstanceMethods.ContainsKey(c) and fInstanceMethods[c].ContainsKey(mname) then
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
        if fMethodParamClrTypes.ContainsKey(c) and fMethodParamClrTypes[c].ContainsKey(mname) then
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
        if fMethodReturnTypes.ContainsKey(c) and fMethodReturnTypes[c].ContainsKey(mname) then
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
          if fMethodReturnTypes.ContainsKey(fCurClassName) and fMethodReturnTypes[fCurClassName].ContainsKey(_mc4.MethodName) then
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
          else if (_mc4.Args.Count=0) and fInstanceMethods.ContainsKey(_cn4c) and fInstanceMethods[_cn4c].ContainsKey('get_'+_mc4.MethodName) then
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
          else if (_mc4.Args.Count=0) and (not (fMethodReturnTypes.ContainsKey(_cn4c) and fMethodReturnTypes[_cn4c].ContainsKey(_mc4.MethodName))) then
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

    procedure EmitExpr(aIL: ILGenerator; e: TExprNode);
    var
      lit: TIntLiteralNode; slit: TStrLiteralNode; vr: TVarRefNode;
      b: TBinOpNode; cmp: TCompareNode; fc: TFuncCallExprNode;
      its: TIntToStrNode; bts: TBoolToStrNode; ai: TArrayIndexExprNode; le: TLengthExprNode;
      neo: TNewObjectExprNode; mc: TMethodCallExprNode; fr: TFieldReadExprNode;
      loc: LocalBuilder; mb: MethodBuilder; imb: MethodBuilder;
      ae: TExprNode; ts, cat: MethodInfo; lt, rt, at2: TVarType;
      fb: FieldBuilder;
      ctor: ConstructorInfo; cn: string; vtVar: TVarType;
      _argIdx48: integer; // [Stage 48]
      imbSelf100: MethodBuilder; // [버그 수정] Cur.Kind처럼 self의 무인자 메서드 호출 체인용
    begin
      fEmitDepth:=fEmitDepth+1;
      if fEmitDepth>5000 then
        raise new Exception('[진단] EmitExpr 재귀 깊이 초과(5000) — 폭주 의심 노드: '+e.GetType.Name);
      try
      if e is TIntLiteralNode then
      begin lit:=TIntLiteralNode(e); aIL.Emit(OpCodes.Ldc_I4, lit.Value); end

      // [Phase 1] 새 리터럴 노드
      else if e is TRealLiteralNode then
        aIL.Emit(OpCodes.Ldc_R8, TRealLiteralNode(e).Value)

      else if e is TCharLiteralNode then
        aIL.Emit(OpCodes.Ldc_I4, integer(TCharLiteralNode(e).Value))

      else if e is TInt64LiteralNode then
        aIL.Emit(OpCodes.Ldc_I8, TInt64LiteralNode(e).Value)

      else if e is TEnumValueExprNode then
        // [Stage 51] 열거형 값(North 등)은 CLR에서 int32 기반 Enum이므로 서수를 그대로 Ldc_I4로 방출한다.
        aIL.Emit(OpCodes.Ldc_I4, TEnumValueExprNode(e).Ordinal)

      else if e is TNilLiteralNode then
        aIL.Emit(OpCodes.Ldnull) // [Stage 29] — 참조 타입 지역/필드 변수와만 비교·대입에 사용

      else if e is TStrLiteralNode then
      begin slit:=TStrLiteralNode(e); aIL.Emit(OpCodes.Ldstr, slit.Value); end

      else if e is TResultRefNode then
      begin
        if fResultLocal=nil then raise new Exception('Result는 함수 안에서만');
        aIL.Emit(OpCodes.Ldloc, fResultLocal);
      end

      else if e is TIntToStrNode then
      begin
        its:=TIntToStrNode(e); EmitExpr(aIL, its.Arg);
        ts:=typeof(System.Convert).GetMethod('ToString', [typeof(integer)]);
        aIL.Emit(OpCodes.Call, ts);
      end

      // [Stage 76] BoolToStr(expr): boolean -> 'True'/'False' 문자열
      // [버그 수정] boolean은 값 타입(struct)이라 bool.ToString()을 인스턴스 메서드로
      // Call하려면 스택에 "값의 주소"가 있어야 하는데, 이전 코드는 값(int32 0/1) 자체를
      // 스택에 둔 채 Call했다 — CLR이 그 int32를 this 포인터로 오인해 역참조하면서
      // NullReferenceException 발생. IntToStr과 동일하게 정적 메서드
      // Convert.ToString(Boolean)을 쓰면 값 그대로(파스칼 bool의 IL 표현 = int32) 넘겨도 안전하다.
      else if e is TBoolToStrNode then
      begin
        bts:=TBoolToStrNode(e);
        EmitExpr(aIL, bts.Arg);
        var _boolToStr:=typeof(System.Convert).GetMethod('ToString', [typeof(boolean)]);
        aIL.Emit(OpCodes.Call, _boolToStr);
      end

      else if e is TLengthExprNode then
      begin
        le:=TLengthExprNode(e);
        // [버그 수정] Length(x)에서 x가 지역변수도 전역변수도 아니라 클래스 필드인 배열
        // (예: 메서드 본문 안에서 자기 클래스의 배열 필드를 Length()로 재는 경우)이면,
        // 예전에는 무조건 fGlobalScope.GetLoc(le.ArrName)를 호출해 존재하지 않는 키로
        // KeyNotFoundException이 그대로 터졌다(호출부까지 예외 타입/메시지가 그대로
        // 전파되어 "알 수 없는 변수" 같은 우리 쪽 진단 메시지도 못 남겼다). 다른 배열
        // 접근부(TArrayIndexExprNode 등)와 마찬가지로 필드 폴백(Ldarg_0+Ldfld)을 추가한다.
        if fLocalScope.Has(le.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(le.ArrName))
        else if fGlobalScope.Has(le.ArrName) then aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(le.ArrName))
        else
        begin
          var leFb: FieldBuilder;
          if TryFindFieldBuilder(fCurClassName, le.ArrName, leFb) then
          begin
            aIL.Emit(OpCodes.Ldarg_0);
            aIL.Emit(OpCodes.Ldfld, leFb);
          end
          else
            raise new Exception('알 수 없는 변수 "'+le.ArrName+'" (Length 인자로 쓰인 배열을 지역/전역 변수도, "'
              +fCurClassName+'" 클래스의 필드도 아닌 곳에서 찾을 수 없습니다).');
        end;
        aIL.Emit(OpCodes.Ldlen); aIL.Emit(OpCodes.Conv_I4);
      end

      else if e is TFieldReadExprNode then
      begin
        // self.fieldName 읽기 (인스턴스 메서드 안) — 지역 필드 또는 외부 상속 타입의 속성/필드
        fr:=TFieldReadExprNode(e);
        if TryFindFieldBuilder(fCurClassName, fr.FieldName, fb) then
        begin
          aIL.Emit(OpCodes.Ldarg_0); // self
          aIL.Emit(OpCodes.Ldfld, fb);
        end
        else
        begin
          var _extType:=FindExternalAncestorType(fCurClassName);
          if _extType=nil then
            raise new Exception('필드/속성을 찾을 수 없음: '+fCurClassName+'.'+fr.FieldName);
          var _pi:=SafeGetProperty(_extType, fr.FieldName);
          if _pi<>nil then
          begin
            var _getter:=_pi.GetGetMethod;
            if _getter=nil then
              raise new Exception('속성 "'+_extType.FullName+'.'+fr.FieldName+'"에 getter가 없습니다 (쓰기 전용).');
            aIL.Emit(OpCodes.Ldarg_0);
            aIL.Emit(OpCodes.Callvirt, _getter);
          end
          else
          begin
            var _fi:=_extType.GetField(fr.FieldName);
            if _fi=nil then
              raise new Exception('외부 타입 "'+_extType.FullName+'"에 필드/속성 "'+fr.FieldName+'"가 없습니다.');
            aIL.Emit(OpCodes.Ldarg_0);
            aIL.Emit(OpCodes.Ldfld, _fi);
          end;
        end;
      end

      else if e is TNewObjectExprNode then
      begin
        // TCounter.Create / new TCounter / new System.IO.FileStream(a,b,c) → Newobj
        // (지역 클래스 또는 외부 타입 모두 지원. [Stage 40] 인자 있는 외부 생성자 추가)
        neo:=TNewObjectExprNode(e);
        if neo.ArraySizeExpr<>nil then
        begin
          // [Stage 96 버그 수정] new Type[N](e1,...,eN) — 배열 생성 리터럴. Stage 92에서
          // Parser는 이 문법(ArraySizeExpr)을 인식하도록 고쳐졌지만 CodeGen 쪽은
          // ArraySizeExpr를 아예 확인하지 않고 그냥 "생성자 인자 N개"로 오인해서
          // N-인자 생성자를 찾다가 실패했다 — WinForms 디자이너가 흔히 내보내는
          // "new System.Windows.Forms.ToolStripItem[9](a, b, ..., i)"(요소 9개를 그대로
          // 채운 ToolStripItem[] 배열)에서 실제로 터졌다. Newarr로 배열을 만들고
          // 인자들을 Stelem으로 채워 넣는다.
          var _arrElemT96: System.Type;
          if neo.IsExternalType then _arrElemT96:=ResolveExternalType(neo.ClassName)
          else if fBuiltTypes.ContainsKey(neo.ClassName) then _arrElemT96:=fBuiltTypes[neo.ClassName]
          else raise new Exception('배열 원소 타입 "'+neo.ClassName+'"을(를) 찾을 수 없습니다 (new '+neo.ClassName+'[...] 배열 생성).');
          EmitExpr(aIL, neo.ArraySizeExpr);
          aIL.Emit(OpCodes.Newarr, _arrElemT96);
          for var _arrI96:=0 to neo.Args.Count-1 do
          begin
            aIL.Emit(OpCodes.Dup);
            aIL.Emit(OpCodes.Ldc_I4, _arrI96);
            EmitArgForParamType(aIL, neo.Args[_arrI96], _arrElemT96);
            if _arrElemT96.IsValueType then aIL.Emit(OpCodes.Stelem, _arrElemT96)
            else aIL.Emit(OpCodes.Stelem_Ref);
          end;
        end
        else if neo.IsExternalType then
        begin
          var _extCtorType:=ResolveExternalType(neo.ClassName);
          if neo.Args.Count=0 then
          begin
            var _extCtor:=SafeGetConstructor(_extCtorType, System.Type.EmptyTypes);
            if _extCtor=nil then
              raise new Exception('외부 타입 "'+_extCtorType.FullName+'"에 매개변수 없는 public 생성자가 없습니다.');
            aIL.Emit(OpCodes.Newobj, _extCtor);
          end
          else
          begin
            var _extCtorN:=ResolveConstructorByArity(_extCtorType, neo.Args);
            if _extCtorN=nil then
              raise new Exception('외부 타입 "'+_extCtorType.FullName+'"에 인자 '+neo.Args.Count.ToString+'개짜리 public 생성자가 없습니다.');
            var _ctorParams48:=_extCtorN.GetParameters();
            for _argIdx48:=0 to neo.Args.Count-1 do
              EmitArgForParamType(aIL, neo.Args[_argIdx48], _ctorParams48[_argIdx48].ParameterType);
            aIL.Emit(OpCodes.Newobj, _extCtorN);
          end;
        end
        else
        begin
          if not fCtorBuilders.ContainsKey(neo.ClassName) then
            raise new Exception('알 수 없는 클래스 "'+neo.ClassName+'"');
          // [Stage 53] abstract 메서드가 있는 클래스는 인스턴스화할 수 없다. CLR도 런타임에
          // MemberAccessException으로 막긴 하지만, 실행 시점이 아니라 지금(컴파일 시점)
          // 알려주는 게 훨씬 낫다.
          if fAbstractMethods.ContainsKey(neo.ClassName) and (fAbstractMethods[neo.ClassName].Count>0) then
            raise new Exception('"'+neo.ClassName+'"은(는) abstract 메서드를 갖고 있어 인스턴스를 생성할 수 없습니다 (abstract 클래스).');
          // [Stage 47] 로컬(우리 컴파일러가 만든) 클래스도 매개변수 있는 생성자를 지원한다.
          // [Stage 99] 생성자가 여러 개(오버로드)일 수 있으므로 인자 개수로 맞는 것을 고른다.
          var _localCtorIdx:=FindLocalCtorIndex(neo.ClassName, neo.Args.Count);
          if _localCtorIdx<0 then
            raise new Exception('"'+neo.ClassName+'"에 인자 '+neo.Args.Count.ToString+'개짜리 생성자가 없습니다.');
          ctor:=fCtorBuilders[neo.ClassName][_localCtorIdx];
          var _ctorParamsLocal:=fCtorParamClrTypes[neo.ClassName][_localCtorIdx];
          EmitArgsCoerced(aIL, neo.Args, _ctorParamsLocal);
          aIL.Emit(OpCodes.Newobj, ctor);
        end;
      end

      else if e is TMethodCallExprNode then
      begin
        // c.GetValue → Ldloc c + Call TCounter::GetValue
        mc:=TMethodCallExprNode(e);
        // [Stage 76 확장] ObjName 자체가 점(.)으로 연결된 체인이면(예: "MainMenu.Items.Count")
        // 아래의 단일 세그먼트 판별 분기들보다 먼저 처리한다 — EmitStatement의 TMethodCallStmtNode
        // 처리(Stage 76)와 동일한 원리를 식(expression) 자리에도 적용한 것.
        if (mc.ObjName<>'') and (mc.ObjName.IndexOf('.')>=0) and (mc.ObjCastType='') then
        begin
          var _chainSegsE:=SplitByDot(mc.ObjName);
          if IsChainStartSegment(_chainSegsE[0]) then
          begin
            var _chainTypeE: System.Type;
            EmitQualifierChainLoad(aIL, _chainSegsE, _chainTypeE);
            // [버그 수정] chainTypeE가 값 타입(예: Count가 반환하는 int32)이면 이후 Callvirt는
            // 박싱된 참조를 요구한다 — Box 없이 그대로 Callvirt하면 스택에 있는 값 타입의
            // 원시값(정수)을 객체 참조로 오인해 실행 시 잘못된 메모리를 역참조한다
            // (MainMenu.Items.Count.ToString에서 실제로 NullReferenceException으로 재현됨).
            // 참조 타입이면 Box는 그대로 통과되므로 항상 걸어도 안전하다.
            // [Stage 76 수정] 값 타입이면 Box 후 스택은 System.Object 참조가 된다.
            // 이 상태에서 원래 값 타입(_chainTypeE)의 MethodInfo로 Callvirt하면
            // vtable 슬롯이 달라 쓰레기값이 나온다(Count=127611752 등).
            // Box 후에는 반드시 typeof(System.Object) 기준으로 메서드를 탐색해야 한다.
            // 참조 타입이면 Box 없이 _chainTypeE에서 그대로 탐색한다.
            if _chainTypeE.IsValueType then
            begin
              aIL.Emit(OpCodes.Box, _chainTypeE);
              // Box 후 스택 타입은 object — object의 가상 메서드로 Callvirt해야 올바르다.
              var _objTypeE := typeof(System.Object);
              var _cmiBoxedE := ResolveMethodByArity(_objTypeE, mc.MethodName, mc.Args, false);
              if _cmiBoxedE = nil then
                raise new Exception('System.Object에 메서드 "'+mc.MethodName+'"가 없습니다 (값 타입 Box 후 경로: '+mc.ObjName+'.'+mc.MethodName+')');
              var _cmiBoxedEParams := _cmiBoxedE.GetParameters;
              for var _cmiBAi := 0 to mc.Args.Count-1 do
                EmitArgForParamType(aIL, mc.Args[_cmiBAi], _cmiBoxedEParams[_cmiBAi].ParameterType);
              aIL.Emit(OpCodes.Callvirt, _cmiBoxedE);
            end
            else
            begin
              var _cpiE:=SafeGetProperty(_chainTypeE, mc.MethodName);
              if (mc.Args.Count=0) and (_cpiE<>nil) and (_cpiE.GetGetMethod<>nil) then
                aIL.Emit(OpCodes.Callvirt, _cpiE.GetGetMethod)
              else
              begin
                var _cmiE:=ResolveMethodByArity(_chainTypeE, mc.MethodName, mc.Args, false);
                if _cmiE=nil then
                  raise new Exception('타입 "'+_chainTypeE.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+')');
                var _cmiEParams:=_cmiE.GetParameters;
                for var _cmiEAi:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_cmiEAi], _cmiEParams[_cmiEAi].ParameterType);
                aIL.Emit(OpCodes.Callvirt, _cmiE);
              end;
            end;
          end
          else
          begin
            // 첫 세그먼트가 진짜 외부 정적 타입 경로 — 기존 TStaticMemberExprNode와 동일한 동작.
            // [Stage 92] Parser는 "TypeName(expr).member"가 바로 뒤에 '.'로 이어질 때만 캐스트로
            // 인식한다. "(TypeName(expr)).member"처럼 캐스트가 추가 괄호에 한 번 더 싸여 있으면
            // 괄호가 먼저 닫혀버려 캐스트인지 정적 호출인지 파싱 시점엔 구분이 안 되고, 일단
            // 정적 호출(ObjName=한정자, MethodName=마지막 세그먼트)로 넘어온다. 이때 ObjName이
            // 실제 타입이 아니라 네임스페이스뿐이면(예: "System.Reflection") 아래
            // ResolveExternalType(mc.ObjName)이 실패한다 — 그 경우 ObjName+'.'+MethodName
            // 전체를 하나의 타입 이름으로 재시도해서 캐스트로 처리한다.
            var _staticTE: System.Type := nil;
            try _staticTE:=ResolveExternalType(mc.ObjName); except end;

            if (_staticTE=nil) and (mc.Args.Count=1) then
            begin
              var _castTE92: System.Type := nil;
              try _castTE92:=ResolveExternalType(mc.ObjName+'.'+mc.MethodName); except end;
              if _castTE92<>nil then
              begin
                EmitExpr(aIL, mc.Args[0]);
                if _castTE92.IsValueType then
                begin
                  var _cnFN92:=_castTE92.FullName;
                  if _cnFN92='System.Byte' then aIL.Emit(OpCodes.Conv_U1)
                  else if _cnFN92='System.SByte' then aIL.Emit(OpCodes.Conv_I1)
                  else if _cnFN92='System.Int16' then aIL.Emit(OpCodes.Conv_I2)
                  else if _cnFN92='System.UInt16' then aIL.Emit(OpCodes.Conv_U2)
                  else if _cnFN92='System.Int32' then aIL.Emit(OpCodes.Conv_I4)
                  else if _cnFN92='System.UInt32' then aIL.Emit(OpCodes.Conv_U4)
                  else if _cnFN92='System.Int64' then aIL.Emit(OpCodes.Conv_I8)
                  else if _cnFN92='System.UInt64' then aIL.Emit(OpCodes.Conv_U8)
                  else if _cnFN92='System.Single' then aIL.Emit(OpCodes.Conv_R4)
                  else if _cnFN92='System.Double' then aIL.Emit(OpCodes.Conv_R8)
                  else if _cnFN92='System.Char' then aIL.Emit(OpCodes.Conv_U2);
                end
                else
                  aIL.Emit(OpCodes.Castclass, _castTE92);
                exit;
              end;
            end;

            // [Stage 99 버그 수정] mc.ObjName 전체가 타입 이름으로 안 풀리면(예:
            // "System.Reflection.Assembly.GetExecutingAssembly"), 마지막 세그먼트가
            // 실제로는 타입의 무인자 정적 메서드/프로퍼티일 수 있다 — ResolveOrEmitStaticChain으로
            // 재시도한다. 성공하면 이미 IL로 그 호출까지 방출되어 스택에 인스턴스가 로드된
            // 상태이므로, 이후 mc.MethodName은 정적이 아니라 인스턴스 멤버로 조회해야 한다.
            var _isInstTE: boolean := false;
            if _staticTE=nil then
              try _staticTE:=ResolveOrEmitStaticChain(aIL, mc.ObjName, _isInstTE); except _staticTE:=nil; end;

            if _staticTE=nil then
              raise new Exception('외부 타입 "'+mc.ObjName+'"을(를) 찾을 수 없습니다. 기본 프레임워크(WinForms/WPF/System.*)가 아니라면 {$reference 어셈블리명.dll} 지시문으로 해당 타입이 들어있는 어셈블리를 먼저 등록했는지 확인하세요.');

            var _spiE:=SafeGetProperty(_staticTE, mc.MethodName);
            if (mc.Args.Count=0) and (_spiE<>nil) and (_spiE.GetGetMethod<>nil) then
              aIL.Emit(OpCodes.Call, _spiE.GetGetMethod)
            else if _isInstTE then
            begin
              // 체인이 이미 인스턴스를 스택에 올려둔 상태 — GetField/Ldsfld(순수 정적 필드
              // 전용)는 의미가 없으므로 건너뛰고 바로 인스턴스 메서드로 조회한다.
              var _smiEI:=ResolveMethodByArity(_staticTE, mc.MethodName, mc.Args, false);
              if _smiEI=nil then
                raise new Exception('타입 "'+_staticTE.FullName+'"에 인스턴스 멤버 "'+mc.MethodName+'"가 없습니다.');
              var _smiEIParams:=_smiEI.GetParameters;
              for var _smiEIAi:=0 to mc.Args.Count-1 do
                EmitArgForParamType(aIL, mc.Args[_smiEIAi], _smiEIParams[_smiEIAi].ParameterType);
              aIL.Emit(OpCodes.Callvirt, _smiEI);
            end
            else
            begin
              var _sfiE:=_staticTE.GetField(mc.MethodName);
              if (mc.Args.Count=0) and (_sfiE<>nil) then
              begin
                // [Stage 76] enum 멤버(예: DockStyle.Top)는 실제로는 컴파일타임 상수(literal)
                // 필드라 런타임 저장 공간이 없다 — Ldsfld를 쓰면 MissingFieldException이 난다.
                // 리터럴 필드는 GetRawConstantValue로 실제 정수값을 꺼내 Ldc_I4로 직접 올려야 한다.
                // (기존 TStaticMemberExprNode 경로에 있던 처리를 여기로 옮겨왔다 — 이전 패치에서
                // TMethodCallExprNode로 통합하면서 이 부분을 빠뜨렸던 회귀 버그.)
                if _sfiE.IsLiteral then
                  aIL.Emit(OpCodes.Ldc_I4, System.Convert.ToInt32(_sfiE.GetRawConstantValue))
                else
                  aIL.Emit(OpCodes.Ldsfld, _sfiE);
              end
              else
              begin
                var _smiE:=ResolveMethodByArity(_staticTE, mc.MethodName, mc.Args, true);
                if _smiE=nil then
                  raise new Exception('외부 타입 "'+_staticTE.FullName+'"에 정적 멤버 "'+mc.MethodName+'"가 없습니다.');
                var _smiEParams:=_smiE.GetParameters;
                for var _smiEAi:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_smiEAi], _smiEParams[_smiEAi].ParameterType);
                aIL.Emit(OpCodes.Call, _smiE);
              end;
            end;
          end;
        end
        else if mc.ObjName='' then
        begin
          // [버그 수정] 식(expression) 위치에서 쓰이는 암시적 self 호출(예: "A or B or
          // IsKeywordAllowedAsMemberName(t.Kind)")이 여태 처리되지 않았다 — 문장(statement)
          // 위치의 동일 패턴(TMethodCallStmtNode, ObjName='' 분기)은 이미 있었지만 식 위치의
          // TMethodCallExprNode 쪽엔 대응하는 분기가 아예 빠져 있어서, 지역변수/필드/외부
          // 정적 타입 어디에도 안 걸리고 결국 "알 수 없는 변수 \"\""로 실패했다. 로직은
          // 문장 버전과 동일(지역 메서드 우선, 없으면 외부 상속 타입에서 탐색)하되, 문장
          // 버전과 달리 반환값을 Pop하지 않고 스택에 남겨 식의 값으로 쓴다.
          aIL.Emit(OpCodes.Ldarg_0); // self
          var _imbEC93: MethodBuilder;
          if TryFindInstanceMethod(fCurClassName, mc.MethodName, _imbEC93) then
          begin
            EmitArgsCoerced(aIL, mc.Args, FindInstanceMethodParamTypes(fCurClassName, mc.MethodName));
            aIL.Emit(OpCodes.Callvirt, _imbEC93);
          end
          else
          begin
            var _extTypeEC93:=FindExternalAncestorType(fCurClassName);
            if _extTypeEC93=nil then
              raise new Exception('알 수 없는 메서드 "'+fCurClassName+'.'+mc.MethodName+'"');
            var _emiEC93:=ResolveMethodByArity(_extTypeEC93, mc.MethodName, mc.Args, false);
            if _emiEC93=nil then
              raise new Exception('외부 타입 "'+_extTypeEC93.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
            var _emiEC93Params:=_emiEC93.GetParameters;
            for var _emiEC93Ai:=0 to mc.Args.Count-1 do
              EmitArgForParamType(aIL, mc.Args[_emiEC93Ai], _emiEC93Params[_emiEC93Ai].ParameterType);
            aIL.Emit(OpCodes.Callvirt, _emiEC93);
          end;
        end
        else if (fLocalScope.Has(mc.ObjName) or fGlobalScope.Has(mc.ObjName))
           and (fLocalScope.HasClrType(mc.ObjName) or fGlobalScope.HasClrType(mc.ObjName)) then
        begin
          // sender/e 같은, 외부(또는 객체) 타입 매개변수/지역변수를 통한 접근.
          // 우리가 만든 클래스가 아니라 Reflection으로 속성/메서드를 찾는다.
          var _qType2: System.Type;
          if fLocalScope.HasClrType(mc.ObjName) then _qType2:=fLocalScope.GetClrType(mc.ObjName)
          else _qType2:=fGlobalScope.GetClrType(mc.ObjName);
          // [버그 수정 - Stage 77] _qType2가 값 타입(예: ShowDialog가 돌려주는 DialogResult
          // 같은 enum, Point/Size 같은 구조체)이면 Ldloc으로 값 자체를 스택에 올린 뒤
          // Callvirt하면 안 된다 — Callvirt는 객체 참조를 요구하는데 여기 올라간 건 원시 값
          // (예: enum 밑바탕의 int32)이라, 그 값을 객체 포인터로 오인해 잘못된 메모리를
          // 역참조한다(작은 정수값이면 특히 NullReferenceException으로 나타난다 — 실제로
          // "var res := dlg.ShowDialog; ... res.ToString"에서 재현됨: DialogResult.None=0이
          // "this" 자리에 그대로 올라가 널 참조 예외가 됨). 값 타입이면 Ldloca로 그 지역
          // 슬롯의 "주소"를 올리고 Call(관리 포인터를 this로 받는 비가상 호출)을 쓴다 —
          // C# 컴파일러가 구조체 인스턴스 메서드를 부를 때 쓰는 것과 동일한 패턴.
          var _isValType2:=(mc.ObjCastType='') and _qType2.IsValueType;
          if _isValType2 then
          begin
            if fLocalScope.Has(mc.ObjName) then aIL.Emit(OpCodes.Ldloca, fLocalScope.GetLoc(mc.ObjName))
            else aIL.Emit(OpCodes.Ldloca, fGlobalScope.GetLoc(mc.ObjName));
          end
          else
          begin
            if fLocalScope.Has(mc.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(mc.ObjName))
            else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(mc.ObjName)); // [전역 var 버그 수정] 항상 fLocals만 읽던 문제
          end;
          if mc.ObjCastType<>'' then
          begin
            _qType2:=ResolveExternalType(mc.ObjCastType);
            aIL.Emit(OpCodes.Castclass, _qType2);
          end;
          // [Stage 100 버그 수정] "sender/e 같은 외부 타입 매개변수/지역변수"라는 주석과
          // 달리, ClrType이 우리가 직접 만들고 있는(아직 CreateType 안 된) 로컬 클래스인
          // 경우도 이 분기를 탄다(예: "var t: TToken; ... t.SomeMethod"). 그 상태에서
          // SafeGetProperty/ResolveMethodByArity(순수 리플렉션 경로)로 넘기면 TypeBuilder가
          // NotSupportedException("유형이 만들어지기 전에 호출된 멤버는 지원되지 않습니다")을
          // 던진다 — TryFindFieldBuilder 분기(위쪽)에 이미 있던 것과 동일한 로컬 클래스
          // 역조회로 먼저 걸러낸다.
          var _localCls100:=FindLocalClassNameForTypeBuilder(_qType2);
          if _localCls100<>'' then
          begin
            EmitLocalClassMemberAccess(aIL, _localCls100, mc);
          end
          else
          begin
          var _pi6:=SafeGetProperty(_qType2, mc.MethodName);
          if (mc.Args.Count=0) and (_pi6<>nil) and (_pi6.GetGetMethod<>nil) then
          begin
            if _isValType2 then aIL.Emit(OpCodes.Call, _pi6.GetGetMethod)
            else aIL.Emit(OpCodes.Callvirt, _pi6.GetGetMethod);
          end
          else
          begin
            var _emi6:=ResolveMethodByArity(_qType2, mc.MethodName, mc.Args, false);
            if _emi6=nil then
              raise new Exception('타입 "'+_qType2.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
            var _emi6Params:=_emi6.GetParameters;
            for var _emi6Ai:=0 to mc.Args.Count-1 do
              EmitArgForParamType(aIL, mc.Args[_emi6Ai], _emi6Params[_emi6Ai].ParameterType);
            if _isValType2 then aIL.Emit(OpCodes.Call, _emi6)
            else aIL.Emit(OpCodes.Callvirt, _emi6);
          end;
          end;
        end
        else if fLocalScope.Has(mc.ObjName) or fGlobalScope.Has(mc.ObjName)
                or fGlobalConstFields.ContainsKey(mc.ObjName) then  // [Stage 96] 전역 const도 허용
        begin
          cn:=GetVarClassName(mc.ObjName);
          vtVar:=GetVarType(mc.ObjName);
          // [Stage 62] cn이 레코드(값 타입)면 Ldfld가 값이 아니라 주소를 요구하므로 Ldloca를 쓴다.
          // (레코드는 메서드가 없어 이 분기가 성공하는 유일한 경로는 바로 아래 필드 읽기뿐이다.)
          if fLocalScope.Has(mc.ObjName) then
          begin
            if fRecordNames.Contains(cn) then aIL.Emit(OpCodes.Ldloca, fLocalScope.GetLoc(mc.ObjName))
            else aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(mc.ObjName));
          end
          else if fGlobalScope.Has(mc.ObjName) then
          begin
            if fRecordNames.Contains(cn) then aIL.Emit(OpCodes.Ldloca, fGlobalScope.GetLoc(mc.ObjName))
            else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(mc.ObjName));
          end
          else
          begin
            // [Stage 96] 전역 const — static 필드에서 Ldsfld로 값을 로드한다.
            // const는 항상 문자열/정수/실수 등 원시 타입이므로 레코드 분기 불필요.
            aIL.Emit(OpCodes.Ldsfld, fGlobalConstFields[mc.ObjName]);
          end;
          if cn='' then
          begin
            // [Stage 79 수정] cn이 빈 문자열이면 사용자 정의 클래스가 아니라 내장 원시
            // 타입(예: string) 지역/전역 변수다 — 예: content.Length (content: string).
            // 이전에는 곧장 "알 수 없는 메서드" 예외를 던졌는데, string은 참조 타입이라
            // 이미 스택에 로드된 참조(위 Ldloc) 그대로 typeof(string) 기준 Reflection
            // 경로(프로퍼티/메서드)로 처리할 수 있다. (정수/불린 등 값 타입은 Callvirt에
            // Box 또는 Ldloca+Call이 추가로 필요해 이번 수정 범위에서는 제외한다.)
            if vtVar=vtString then
            begin
              var _strPi79:=typeof(string).GetProperty(mc.MethodName);
              if (mc.Args.Count=0) and (_strPi79<>nil) and (_strPi79.GetGetMethod<>nil) then
                aIL.Emit(OpCodes.Callvirt, _strPi79.GetGetMethod)
              else
              begin
                var _strMi79:=ResolveMethodByArity(typeof(string), mc.MethodName, mc.Args, false);
                if _strMi79=nil then
                  raise new Exception('타입 "System.String"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
                var _strMiParams79:=_strMi79.GetParameters;
                for var _strAi79:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_strAi79], _strMiParams79[_strAi79].ParameterType);
                aIL.Emit(OpCodes.Callvirt, _strMi79);
              end;
            end
            else if (mc.Args.Count=0) and (mc.MethodName='Length')
                    and ((vtVar=vtIntArray) or (vtVar=vtStrArray) or (vtVar=vtObjArray)
                         or (vtVar=vtGenericArray) or (vtVar=vtMatrix)) then
            begin
              // [버그 수정] 배열 지역/전역 변수(예: parts: array of string)에 .Length를
              // 호출하는 경우를 이전에는 처리하지 않고 곧장 "알 수 없는 메서드"로 던졌다.
              // 배열은 System.Array 파생 CLR 배열이라 Reflection으로 프로퍼티를 찾을 필요 없이
              // Ldlen(스택 최상단 배열 참조 → 네이티브 uint 길이) + Conv_I4로 바로 계산할 수 있다
              // (C#의 arr.Length가 컴파일되는 것과 동일한 IL 관용구). 위에서 이미 Ldloc/Ldsfld로
              // 배열 참조가 스택에 올라가 있는 상태다.
              aIL.Emit(OpCodes.Ldlen);
              aIL.Emit(OpCodes.Conv_I4);
            end
            else if (mc.Args.Count=0) and (mc.MethodName='ToString')
                    and ((vtVar=vtInteger) or (vtVar=vtInt64) or (vtVar=vtReal) or (vtVar=vtBoolean) or (vtVar=vtChar)) then
            begin
              // [버그 수정] 정수/int64/실수/불린/문자 같은 원시 값 타입의 지역/전역 변수에
              // 명시적으로 .ToString()을 호출하는 경우(예: "sum.ToString", sum: integer)를
              // 이전에는 처리하지 않고 곧장 "알 수 없는 메서드"로 던졌다. 위에서 이미
              // Ldloc으로 그 변수의 값 자체를 스택에 올려둔 상태이므로, IntToStr/BoolToStr가
              // 쓰는 것과 동일하게 Convert.ToString(T) 정적 메서드를 그대로 호출하면 된다
              // (박싱/Ldloca 불필요 — 값 그대로 정적 메서드 인자로 전달 가능).
              var _valToStrType: System.Type;
              if vtVar=vtInteger then _valToStrType:=typeof(integer)
              else if vtVar=vtInt64 then _valToStrType:=typeof(int64)
              else if vtVar=vtReal then _valToStrType:=typeof(double)
              else if vtVar=vtBoolean then _valToStrType:=typeof(boolean)
              else _valToStrType:=typeof(char);
              var _valToStr:=typeof(System.Convert).GetMethod('ToString', [_valToStrType]);
              aIL.Emit(OpCodes.Call, _valToStr);
            end
            else
              raise new Exception('알 수 없는 메서드 "'+cn+'.'+mc.MethodName+'"');
          end
          else
          // [버그 수정] obj.FieldName(괄호 없음, 인자 없음)은 메서드가 아니라 필드/속성 읽기일
          // 수도 있다 — 이전에는 무조건 FindInstanceMethod로 보내서 실제로는 필드인데
          // "알 수 없는 메서드"로 오인했다 (예: Writeln(app.Label1) — app이 전역/지역 변수인 경우).
          if (mc.Args.Count=0) and TryFindFieldBuilder(cn, mc.MethodName, fb) then
            aIL.Emit(OpCodes.Ldfld, fb)
          else if (mc.Args.Count=0) and (vtVar<>vtInterface) and (not TryFindInstanceMethod(cn, mc.MethodName, imb)) then
          begin
            // [Stage 51] 로컬(우리 컴파일러가 만든) 클래스의 프로퍼티 읽기.
            // property X: T read FX ... 는 get_X 라는 이름의 메서드로 등록되어 있어서
            // TryFindInstanceMethod(cn, 'X', ...)로는 못 찾는다 — 여기서 'get_'+X로 먼저 확인한다.
            if fInstanceMethods.ContainsKey(cn) and fInstanceMethods[cn].ContainsKey('get_'+mc.MethodName) then
              aIL.Emit(OpCodes.Callvirt, fInstanceMethods[cn]['get_'+mc.MethodName])
            else
            begin
              // [Stage 46] 로컬 필드도 로컬 메서드도 아니면 외부 상속 타입(예: WPF Window)의
              // 프로퍼티/필드일 수 있다 (예: w.Title). 객체 참조는 이미 스택에 로드돼 있다(위 Ldloc).
              var _extAnc:=FindExternalAncestorType(cn);
              if _extAnc=nil then
                raise new Exception('알 수 없는 메서드 "'+cn+'.'+mc.MethodName+'"');
              var _extPi:=SafeGetProperty(_extAnc, mc.MethodName);
              if _extPi<>nil then
              begin
                var _extGetter:=_extPi.GetGetMethod;
                if _extGetter=nil then
                  raise new Exception('속성 "'+_extAnc.FullName+'.'+mc.MethodName+'"에 getter가 없습니다 (쓰기 전용).');
                aIL.Emit(OpCodes.Callvirt, _extGetter);
              end
              else
              begin
                var _extFi:=_extAnc.GetField(mc.MethodName);
                if _extFi<>nil then
                  aIL.Emit(OpCodes.Ldfld, _extFi)
                else
                begin
                  // [Stage 77] ShowDialog()처럼 인자 없는 "진짜 메서드"(프로퍼티도 필드도 아님)를
                  // 상속받은 외부 조상 타입에서 호출하는 경우 — 지금까지는 GetProperty/GetField만
                  // 시도하고 둘 다 실패하면 곧장 "필드/속성 없음" 예외를 던져서 이런 호출 자체가
                  // 불가능했다. 마지막으로 인자 0개 메서드를 시도한다.
                  var _extMi77:=_extAnc.GetMethod(mc.MethodName, System.Type.EmptyTypes);
                  if _extMi77=nil then
                    raise new Exception('외부 타입 "'+_extAnc.FullName+'"에 필드/속성/메서드 "'+mc.MethodName+'"가 없습니다.');
                  aIL.Emit(OpCodes.Callvirt, _extMi77);
                end;
              end;
            end;
          end
          else
          begin
            // 인터페이스 타입 변수면 인터페이스 메서드로, 아니면 클래스 상속 체인에서 탐색
            if vtVar=vtInterface then
            begin
              var imi:=FindInterfaceMethod(cn, mc.MethodName);
              var _imiParams:=imi.GetParameters;
              for var _imiAi:=0 to mc.Args.Count-1 do
                EmitArgForParamType(aIL, mc.Args[_imiAi], _imiParams[_imiAi].ParameterType);
              aIL.Emit(OpCodes.Callvirt, imi);
            end
            else
            begin
              imb:=FindInstanceMethod(cn, mc.MethodName);
              if mc.GenericArgTypes.Count>0 then
              begin
                // [Stage 74] obj.Method<T,U>(...) — 명시적 타입 인자로 닫은 뒤 그 닫힌 메서드를 호출한다.
                var closedTypes74e:=new System.Type[mc.GenericArgTypes.Count];
                for var gi74e:=0 to mc.GenericArgTypes.Count-1 do
                  closedTypes74e[gi74e]:=VTC(mc.GenericArgTypes[gi74e], mc.GenericArgClassNames[gi74e]);
                var closedMI74e:=imb.MakeGenericMethod(closedTypes74e);
                EmitArgsCoerced(aIL, mc.Args, nil);
                aIL.Emit(OpCodes.Callvirt, closedMI74e);
              end
              else
              begin
                EmitArgsCoerced(aIL, mc.Args, FindInstanceMethodParamTypes(cn, mc.MethodName));
                // virtual 메서드이므로 Callvirt 사용 (다형성 대비)
                aIL.Emit(OpCodes.Callvirt, imb);
              end;
            end;
          end;
        end
        else if TryFindFieldBuilder(fCurClassName, mc.ObjName, fb) then
        begin
          // Button1.Text (필드를 통한 속성 읽기) 또는 Button1.SomeMethod() (필드를 통한 메서드 호출)
          aIL.Emit(OpCodes.Ldarg_0);
          aIL.Emit(OpCodes.Ldfld, fb);
          var _qType:=fb.FieldType;
          if mc.ObjCastType<>'' then
          begin
            _qType:=ResolveExternalType(mc.ObjCastType);
            aIL.Emit(OpCodes.Castclass, _qType);
          end;
          // [Stage 98] _qType이 아직 CreateType되지 않은 로컬(사용자 정의) 클래스의
          // TypeBuilder이면 아래 SafeGetProperty/ResolveMethodByArity(순수 리플렉션 경로)가
          // TypeBuilder에 대해 NotSupportedException("Type has not been created.")을 던진다
          // (예: 식 위치에서 값으로 쓰이는 formChild1.Pane — DockContent를 상속하는 FormChild
          // 필드의 프로퍼티를 다른 호출의 인자로 넘기는 경우). 문장 위치의 동일한 문제(위쪽
          // TryFindFieldBuilder(fCurClassName, mcs.ObjName, qfb) 분기)와 같은 방식으로, 로컬
          // 클래스 이름을 fTypeBuilders에서 역조회해 메타데이터 기반 경로
          // (FindInstanceMethod/FindExternalAncestorType)로 처리한다.
          var _localClsExpr98:string:='';
          if _qType is TypeBuilder then
            foreach var _tbKvpExpr98 in fTypeBuilders do
              if _tbKvpExpr98.Value = TypeBuilder(_qType) then
              begin _localClsExpr98:=_tbKvpExpr98.Key; break; end;

          if _localClsExpr98<>'' then
          begin
            var _imbExpr98: MethodBuilder;
            if (mc.Args.Count=0) and fFieldBuilders.ContainsKey(_localClsExpr98) and fFieldBuilders[_localClsExpr98].ContainsKey(mc.MethodName) then
              aIL.Emit(OpCodes.Ldfld, fFieldBuilders[_localClsExpr98][mc.MethodName])
            else if TryFindInstanceMethod(_localClsExpr98, mc.MethodName, _imbExpr98) then
            begin
              EmitArgsCoerced(aIL, mc.Args, FindInstanceMethodParamTypes(_localClsExpr98, mc.MethodName));
              aIL.Emit(OpCodes.Callvirt, _imbExpr98);
            end
            else if FindExternalAncestorType(_localClsExpr98)<>nil then
            begin
              var _extAncExpr98:=FindExternalAncestorType(_localClsExpr98);
              var _getPExpr98:=SafeGetProperty(_extAncExpr98, mc.MethodName);
              if (mc.Args.Count=0) and (_getPExpr98<>nil) and (_getPExpr98.GetGetMethod<>nil) then
                aIL.Emit(OpCodes.Callvirt, _getPExpr98.GetGetMethod)
              else
              begin
                var _emiExpr98:=ResolveMethodByArity(_extAncExpr98, mc.MethodName, mc.Args, false);
                if _emiExpr98=nil then
                  raise new Exception('로컬 클래스 "'+_localClsExpr98+'"(외부 조상 "'+_extAncExpr98.FullName+'")에 메서드/필드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
                var _emiParamsExpr98:=_emiExpr98.GetParameters;
                for var _emiAiExpr98:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_emiAiExpr98], _emiParamsExpr98[_emiAiExpr98].ParameterType);
                aIL.Emit(OpCodes.Callvirt, _emiExpr98);
              end;
            end
            else
              raise new Exception('로컬 클래스 "'+_localClsExpr98+'"에 메서드/필드 "'+mc.MethodName+'"가 없습니다.');
          end
          else
          begin
            var _pi5:=SafeGetProperty(_qType, mc.MethodName);
            if (mc.Args.Count=0) and (_pi5<>nil) and (_pi5.GetGetMethod<>nil) then
              aIL.Emit(OpCodes.Callvirt, _pi5.GetGetMethod)
            else
            begin
              var _emi5:=ResolveMethodByArity(_qType, mc.MethodName, mc.Args, false);
              if _emi5=nil then
                raise new Exception('타입 "'+_qType.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
              var _emi5Params:=_emi5.GetParameters;
              for var _emi5Ai:=0 to mc.Args.Count-1 do
                EmitArgForParamType(aIL, mc.Args[_emi5Ai], _emi5Params[_emi5Ai].ParameterType);
              aIL.Emit(OpCodes.Callvirt, _emi5);
            end;
          end;
        end
        else if (FindExternalAncestorType(fCurClassName)<>nil)
                and (SafeGetProperty(FindExternalAncestorType(fCurClassName), mc.ObjName)<>nil) then
        begin
          // [버그 수정] Controls.Count 처럼, 한정자(qualifier) 자체가 로컬변수/필드가 아니라
          // self가 상속받은 외부 타입(Form 등)의 프로퍼티이고, 그 결과를 값으로 쓰는 경우
          // (statement 위치의 Controls.Add(...)는 이미 별도 분기에서 처리되고 있었으나,
          // 식 위치에서 값을 리턴받는 이 경로가 빠져 있었다).
          var _extAnc7:=FindExternalAncestorType(fCurClassName);
          var _extPi7:=SafeGetProperty(_extAnc7, mc.ObjName);
          aIL.Emit(OpCodes.Ldarg_0);
          aIL.Emit(OpCodes.Callvirt, _extPi7.GetGetMethod);
          var _qType7:=_extPi7.PropertyType;
          // [버그 수정] ClientSize.Width 처럼 중간 결과(_qType7)가 값 타입(struct, 예:
          // System.Drawing.Size)이면, 방금 스택에 올라온 건 "값 자체"라 그 위에 바로
          // Callvirt로 하위 멤버(Width 등)를 부르면 안 된다 — 값 타입 인스턴스 호출은
          // this로 "그 값의 주소"가 필요하다. 로컬 변수에 저장한 뒤 Ldloca로 주소를 얻고,
          // 값 타입 인스턴스 호출이므로 Callvirt가 아니라 Call을 써야 한다
          // (Callvirt는 object 참조를 요구해 검증에서 걸리거나, 여기처럼 값을 그대로
          // this로 써서 AccessViolationException/메모리 손상을 일으킨다).
          if _qType7.IsValueType then
          begin
            var _tmpLoc7:=aIL.DeclareLocal(_qType7);
            aIL.Emit(OpCodes.Stloc, _tmpLoc7);
            aIL.Emit(OpCodes.Ldloca, _tmpLoc7);
            var _pi7v:=SafeGetProperty(_qType7, mc.MethodName);
            if (mc.Args.Count=0) and (_pi7v<>nil) and (_pi7v.GetGetMethod<>nil) then
              aIL.Emit(OpCodes.Call, _pi7v.GetGetMethod)
            else
            begin
              var _emi7v:=ResolveMethodByArity(_qType7, mc.MethodName, mc.Args, false);
              if _emi7v=nil then
                raise new Exception('타입 "'+_qType7.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
              var _emi7vParams:=_emi7v.GetParameters;
              for var _emi7vAi:=0 to mc.Args.Count-1 do
                EmitArgForParamType(aIL, mc.Args[_emi7vAi], _emi7vParams[_emi7vAi].ParameterType);
              aIL.Emit(OpCodes.Call, _emi7v);
            end;
          end
          else
          begin
            var _pi7:=SafeGetProperty(_qType7, mc.MethodName);
            if (mc.Args.Count=0) and (_pi7<>nil) and (_pi7.GetGetMethod<>nil) then
              aIL.Emit(OpCodes.Callvirt, _pi7.GetGetMethod)
            else
            begin
              var _emi7:=ResolveMethodByArity(_qType7, mc.MethodName, mc.Args, false);
              if _emi7=nil then
                raise new Exception('타입 "'+_qType7.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
              var _emi7Params:=_emi7.GetParameters;
              for var _emi7Ai:=0 to mc.Args.Count-1 do
                EmitArgForParamType(aIL, mc.Args[_emi7Ai], _emi7Params[_emi7Ai].ParameterType);
              aIL.Emit(OpCodes.Callvirt, _emi7);
            end;
          end;
        end
        // [버그 수정] Cur.Kind 처럼 ObjName 자체가 필드/지역변수가 아니라 self의 무인자
        // (괄호 없이 부르는 관례) 인스턴스 메서드 호출(예: function Cur: TToken)이고,
        // 그 반환값에 다시 멤버 접근(.Kind 등)을 하는 경우. 이전에는 필드/지역변수/외부
        // 조상 프로퍼티 어디에도 안 걸려 곧장 "알 수 없는 변수"로 던져졌다.
        // TryFindInstanceMethod가 돌려주는 MethodBuilder는 아직 CreateType 전이라
        // GetParameters()가 NotSupportedException을 던지므로, "무인자인가"는 반드시
        // FindInstanceMethodParamTypes(길이 0 또는 nil)로 판단해야 한다.
        else if (fCurClassName<>'') and (mc.ObjCastType='')
                and TryFindInstanceMethod(fCurClassName, mc.ObjName, imbSelf100)
                and ((FindInstanceMethodParamTypes(fCurClassName, mc.ObjName)=nil)
                     or (FindInstanceMethodParamTypes(fCurClassName, mc.ObjName).Length=0)) then
        begin
          aIL.Emit(OpCodes.Ldarg_0);
          aIL.Emit(OpCodes.Callvirt, imbSelf100);
          var _retT100:=imbSelf100.ReturnType;
          // 반환 타입이 우리가 만든 로컬 클래스(TToken 등)면 EmitLocalClassMemberAccess를
          // 재사용(필드/메서드/외부조상 순으로 이미 처리해 줌). 외부 CLR 타입이면 Reflection.
          var _localClsSelf100:=FindLocalClassNameForTypeBuilder(_retT100);
          if _localClsSelf100<>'' then
            EmitLocalClassMemberAccess(aIL, _localClsSelf100, mc)
          else
          begin
            var _piSelf100:=SafeGetProperty(_retT100, mc.MethodName);
            if (mc.Args.Count=0) and (_piSelf100<>nil) and (_piSelf100.GetGetMethod<>nil) then
              aIL.Emit(OpCodes.Callvirt, _piSelf100.GetGetMethod)
            else
            begin
              var _emiSelf100:=ResolveMethodByArity(_retT100, mc.MethodName, mc.Args, false);
              if _emiSelf100=nil then
                raise new Exception('타입 "'+_retT100.FullName+'"에 메서드 "'+mc.MethodName
                  +'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
              var _emiSelf100Params:=_emiSelf100.GetParameters;
              for var _emiSelf100Ai:=0 to mc.Args.Count-1 do
                EmitArgForParamType(aIL, mc.Args[_emiSelf100Ai], _emiSelf100Params[_emiSelf100Ai].ParameterType);
              aIL.Emit(OpCodes.Callvirt, _emiSelf100);
            end;
          end;
        end
        else
        begin
          // [버그 수정] ObjName이 필드/지역변수/외부 조상 프로퍼티/self 무인자 메서드
          // 어디에도 없으면, 마지막으로 점 없는 단일 이름의 외부 정적 타입(주로 enum, 예:
          // ColumnHeaderStyle)일 가능성을 시도한다. 기존에는 이 케이스를 아예 시도하지
          // 않고 곧장 "알 수 없는 변수"로 던졌다 (ObjName 자체에 '.'이 있는 체인 케이스만
          // 위쪽 1364번째 줄 분기에서 static 타입 경로를 탔었음).
          var _bareStaticT: System.Type := nil;
          try _bareStaticT := ResolveExternalType(mc.ObjName); except end;
          if _bareStaticT <> nil then
          begin
            var _bareSpi := SafeGetProperty(_bareStaticT, mc.MethodName);
            if (mc.Args.Count=0) and (_bareSpi<>nil) and (_bareSpi.GetGetMethod<>nil) then
              aIL.Emit(OpCodes.Call, _bareSpi.GetGetMethod)
            else
            begin
              var _bareSfi := _bareStaticT.GetField(mc.MethodName);
              if (mc.Args.Count=0) and (_bareSfi<>nil) then
              begin
                // enum 멤버는 리터럴(상수) 필드라 런타임 저장 공간이 없다 — Ldsfld를 쓰면
                // MissingFieldException. GetRawConstantValue로 실제 정수값을 꺼내
                // Ldc_I4로 직접 올려야 한다 (Stage 76에서 체인 경로에 적용했던 것과 동일).
                if _bareSfi.IsLiteral then
                  aIL.Emit(OpCodes.Ldc_I4, System.Convert.ToInt32(_bareSfi.GetRawConstantValue))
                else
                  aIL.Emit(OpCodes.Ldsfld, _bareSfi);
              end
              else
              begin
                var _bareSmi := ResolveMethodByArity(_bareStaticT, mc.MethodName, mc.Args, true);
                if _bareSmi=nil then
                  raise new Exception('외부 타입 "'+_bareStaticT.FullName+'"에 정적 멤버 "'+mc.MethodName+'"가 없습니다.');
                var _bareSmiParams:=_bareSmi.GetParameters;
                for var _bareSmiAi:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_bareSmiAi], _bareSmiParams[_bareSmiAi].ParameterType);
                aIL.Emit(OpCodes.Call, _bareSmi);
              end;
            end;
          end
          else
            raise new Exception('알 수 없는 변수 "'+mc.ObjName+'"');
        end;
      end

      else if e is TExternalIndexExprNode then
      begin
        // [Stage 78] obj[i] — 대부분의 .NET 컬렉션이 따르는 관례(기본 인덱서 = "Item"
        // 프로퍼티, TreeNodeCollection 포함)를 리플렉션으로 찾아 get_Item(i)을 호출한다.
        // Qualifier(예: "Tree.Nodes")는 기존 체인 로딩 메커니즘을 그대로 재사용한다.
        // [버그 수정] EmitIndexerGet으로 추출 + IndexExpr2가 있으면(obj[i][j]) 첫 인덱싱
        // 결과 타입에 대해 다시 한 번 적용하고, MemberName이 있으면(obj[i].Field) 그
        // 필드/프로퍼티를 읽는다(둘은 파서가 상호 배타적으로만 채운다).
        var eiN:=TExternalIndexExprNode(e);
        var eiSegs:=SplitByDot(eiN.Qualifier);
        var eiBaseType: System.Type;
        if not IsChainStartSegment(eiSegs[0]) then
          raise new Exception('알 수 없는 인덱서 대상 "'+eiN.Qualifier+'"');
        EmitQualifierChainLoad(aIL, eiSegs, eiBaseType);
        var eiResultType:=EmitIndexerGet(aIL, eiBaseType, eiN.IndexExpr);
        if eiN.IndexExpr2<>nil then
          eiResultType:=EmitIndexerGet(aIL, eiResultType, eiN.IndexExpr2);
        if eiN.ExtraIndices<>nil then
          foreach var eiExtra96 in eiN.ExtraIndices do
            eiResultType:=EmitIndexerGet(aIL, eiResultType, eiExtra96);
        if (eiN.MemberName<>'') and (eiN.MethodArgs<>nil) then
        begin
          // [Stage 95] obj[i].Method(args) — 인덱싱 결과(스택에 이미 올라와 있음)에 대해
          // 일반 외부 메서드 호출과 동일한 리플렉션 기반 오버로드 해석/인자 강제변환을 적용한다.
          var eiMi95:=ResolveMethodByArity(eiResultType, eiN.MemberName, eiN.MethodArgs, false);
          if eiMi95=nil then
            raise new Exception('타입 "'+eiResultType.FullName+'"에 메서드 "'+eiN.MemberName+'"가 없습니다 (인자 '+eiN.MethodArgs.Count.ToString+'개).');
          var eiParams95:=eiMi95.GetParameters;
          for var eiAi95:=0 to eiN.MethodArgs.Count-1 do
            EmitArgForParamType(aIL, eiN.MethodArgs[eiAi95], eiParams95[eiAi95].ParameterType);
          aIL.Emit(OpCodes.Callvirt, eiMi95);
        end
        else if eiN.MemberName<>'' then
        begin
          var eiFi:=eiResultType.GetField(eiN.MemberName, BindingFlags.Public or BindingFlags.Instance);
          if eiFi<>nil then aIL.Emit(OpCodes.Ldfld, eiFi)
          else
          begin
            var eiPi:=SafeGetProperty(eiResultType, eiN.MemberName);
            if (eiPi=nil) or (eiPi.GetGetMethod=nil) then
              raise new Exception('타입 "'+eiResultType.FullName+'"에 필드/프로퍼티 "'+eiN.MemberName+'"가 없습니다.');
            aIL.Emit(OpCodes.Callvirt, eiPi.GetGetMethod);
          end;
        end;
      end

      // [Stage 91] typeof(TypeName) — IL로는 Ldtoken(타입) 다음 Type.GetTypeFromHandle 호출.
      else if e is TTypeOfExprNode then
      begin
        var to91:=TTypeOfExprNode(e);
        aIL.Emit(OpCodes.Ldtoken, ResolveExternalType(to91.TypeName));
        aIL.Emit(OpCodes.Call, typeof(System.Type).GetMethod('GetTypeFromHandle',[typeof(System.RuntimeTypeHandle)]));
      end

      // [Stage 90] TargetType(InnerExpr) — 임의의 식을 외부 타입으로 캐스트. Inner를 평가해 스택에
      // 올린다. 참조 타입이면 Castclass, [Stage 92] byte(x)/(byte)(x)처럼 대상이 원시 값 타입이면
      // Castclass는 값 타입에 쓸 수 없으므로(검증 오류) 대신 알맞은 숫자 변환 명령을 낸다.
      else if e is TExternalCastExprNode then
      begin
        var ec90:=TExternalCastExprNode(e);
        EmitExpr(aIL, ec90.InnerExpr);
        var ec90Type:=ResolveExternalType(ec90.TargetType);
        if ec90Type.IsValueType then
        begin
          var ec90FN:=ec90Type.FullName;
          if ec90FN='System.Byte' then aIL.Emit(OpCodes.Conv_U1)
          else if ec90FN='System.SByte' then aIL.Emit(OpCodes.Conv_I1)
          else if ec90FN='System.Int16' then aIL.Emit(OpCodes.Conv_I2)
          else if ec90FN='System.UInt16' then aIL.Emit(OpCodes.Conv_U2)
          else if ec90FN='System.Int32' then aIL.Emit(OpCodes.Conv_I4)
          else if ec90FN='System.UInt32' then aIL.Emit(OpCodes.Conv_U4)
          else if ec90FN='System.Int64' then aIL.Emit(OpCodes.Conv_I8)
          else if ec90FN='System.UInt64' then aIL.Emit(OpCodes.Conv_U8)
          else if ec90FN='System.Single' then aIL.Emit(OpCodes.Conv_R4)
          else if ec90FN='System.Double' then aIL.Emit(OpCodes.Conv_R8)
          else if ec90FN='System.Char' then aIL.Emit(OpCodes.Conv_U2);
          // 그 외(사용자 struct/enum 등) 값 타입은 변환 없이 그대로 둔다 — 소스 값이 이미
          // 호환 가능한 표현이라고 가정한다.
        end
        else
          aIL.Emit(OpCodes.Castclass, ec90Type);
      end

      // [Stage 90] Inner.MemberName / Inner.MemberName(args) — 메서드 호출 결과 위에 이어지는
      // 일반 멤버 접근/메서드 호출 체인 (예: a.GetName().Version.ToString()).
      // Inner를 먼저 평가해 스택에 올리고, Inner의 실제 CLR 타입을 GetExprClrType으로 추론해
      // 그 타입 위에서 리플렉션으로 멤버(속성/필드/메서드)를 찾는다. Inner가 값 타입(struct/enum)이면
      // Callvirt가 요구하는 "주소"가 없으므로 임시 지역변수에 저장한 뒤 Ldloca+Call로 처리한다.
      else if e is TChainedMemberExprNode then
      begin
        var ch90:=TChainedMemberExprNode(e);
        EmitExpr(aIL, ch90.Inner);
        var chType90:=GetExprClrType(ch90.Inner);
        var chIsVal90:=chType90.IsValueType;
        if chIsVal90 then
        begin
          var chTmp90:=aIL.DeclareLocal(chType90);
          aIL.Emit(OpCodes.Stloc, chTmp90);
          aIL.Emit(OpCodes.Ldloca, chTmp90);
        end;
        if not ch90.IsCall then
        begin
          var chPi90:=SafeGetProperty(chType90, ch90.MemberName);
          if (chPi90<>nil) and (chPi90.GetGetMethod<>nil) then
          begin
            if chIsVal90 then aIL.Emit(OpCodes.Call, chPi90.GetGetMethod)
            else aIL.Emit(OpCodes.Callvirt, chPi90.GetGetMethod);
          end
          else
          begin
            var chFi90:=chType90.GetField(ch90.MemberName);
            if chFi90<>nil then
              aIL.Emit(OpCodes.Ldfld, chFi90)
            else
            begin
              // [버그 수정] Object Pascal은 괄호 없는 무인자 메서드 호출을 허용한다
              // (예: s.Trim, s.ToUpper — 파서는 '.' 뒤에 '('가 안 보이면 IsCall=false로
              // TChainedMemberExprNode를 만든다. Parser.pas 1770행 부근 참고). 여태는 이
              // 경우 프로퍼티/필드만 찾고 실패하면 바로 에러를 던져, string.Trim처럼 실제로는
              // "인자 없는 메서드"인 멤버가 전부 "멤버가 없습니다" 오류로 막혔다. 프로퍼티/필드에서
              // 못 찾으면 무인자 메서드로도 한 번 더 시도한다.
              var chMi90Noargs:=ResolveMethodByArity(chType90, ch90.MemberName, new List<TExprNode>, false);
              if chMi90Noargs=nil then
                // [진단] chType90가 System.Object이면 십중팔구 GetExprClrType이 Inner의 실제
                // 타입을 추론하지 못해 조용히 폴백한 것이다(진짜로 System.Object 타입인
                // 식에 .Value 등을 쓴 경우는 드묾) — DescribeExprChain으로 어떤 식이었는지 밝힌다.
                raise new Exception('타입 "'+chType90.FullName+'"에 멤버 "'+ch90.MemberName
                  +'"가 없습니다. (식: '+DescribeExprChain(ch90.Inner)+'.'+ch90.MemberName
                  +' — Inner 타입 추론 결과: '+chType90.FullName+')');
              if chIsVal90 then aIL.Emit(OpCodes.Call, chMi90Noargs)
              else aIL.Emit(OpCodes.Callvirt, chMi90Noargs);
            end;
          end;
        end
        else
        begin
          var chMi90:=ResolveMethodByArity(chType90, ch90.MemberName, ch90.Args, false);
          if chMi90=nil then
            raise new Exception('타입 "'+chType90.FullName+'"에 메서드 "'+ch90.MemberName+'"가 없습니다 (인자 '+ch90.Args.Count.ToString
              +'개). (식: '+DescribeExprChain(ch90.Inner)+'.'+ch90.MemberName+'(...))');
          var chMiParams90:=chMi90.GetParameters;
          for var chAi90:=0 to ch90.Args.Count-1 do
            EmitArgForParamType(aIL, ch90.Args[chAi90], chMiParams90[chAi90].ParameterType);
          if chIsVal90 then aIL.Emit(OpCodes.Call, chMi90)
          else aIL.Emit(OpCodes.Callvirt, chMi90);
        end;
      end

      // [버그 수정] Target[Index] — Target이 함수 호출 결과, 캐스트, 체이닝된 멤버 접근 등
      // "이미 파싱된 임의의 식"인 후위 인덱싱(예: GetIndexParameters()[0], SplitByDot(x)[0],
      // TCast(e).Args[i]). Target을 먼저 Emit해 스택에 올린 뒤, GetExprClrType으로 추론한
      // 실제 CLR 타입을 EmitIndexerGet에 넘긴다 — 그 함수가 배열(Ldelem)/컬렉션(get_Item)
      // 여부를 이미 판별해주므로 여기서는 재구현하지 않는다.
      else if e is TChainedIndexExprNode then
      begin
        var cix90:=TChainedIndexExprNode(e);
        EmitExpr(aIL, cix90.Target);
        var cixType90:=GetExprClrType(cix90.Target);
        EmitIndexerGet(aIL, cixType90, cix90.IndexExpr);
      end

      else if e is TArrayIndexExprNode then
      begin
        ai:=TArrayIndexExprNode(e);
        // [버그 수정] Length()에서 고쳤던 것과 동일한 패턴 — ai.ArrName이 지역변수도
        // 전역변수도 아니라 클래스 필드인 배열(자기 클래스의 배열 필드를 인덱싱하는 경우)
        // 이면, 예전에는 무조건 fGlobalScope.GetLoc을 호출해 KeyNotFoundException으로
        // 죽었다. 필드 폴백(Ldarg_0+Ldfld)을 추가한다. 이 경로에서는 GetVarType(스코프
        // 전용이라 필드 이름은 모두 기본값 vtInteger로 오판)을 쓸 수 없으므로, 원소가
        // 참조 타입인지는 FieldBuilder의 실제 CLR 배열 원소 타입(IsValueType)으로 판단한다.
        var aiIsRefElem: boolean;
        if fLocalScope.Has(ai.ArrName) then
        begin
          aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(ai.ArrName));
          aiIsRefElem:=(GetVarType(ai.ArrName)=vtStrArray) or (GetVarType(ai.ArrName)=vtObjArray);
        end
        else if fGlobalScope.Has(ai.ArrName) then
        begin
          aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(ai.ArrName));
          aiIsRefElem:=(GetVarType(ai.ArrName)=vtStrArray) or (GetVarType(ai.ArrName)=vtObjArray);
        end
        else
        begin
          var aiFb: FieldBuilder;
          if TryFindFieldBuilder(fCurClassName, ai.ArrName, aiFb) then
          begin
            aIL.Emit(OpCodes.Ldarg_0);
            aIL.Emit(OpCodes.Ldfld, aiFb);
            aiIsRefElem:=IsRefElementType(aiFb.FieldType); // [Stage 96 버그 수정] TypeBuilderInstantiation 예외 흡수
          end
          else
            raise new Exception('알 수 없는 변수 "'+ai.ArrName+'" (배열 인덱싱 대상을 지역/전역 변수도, "'
              +fCurClassName+'" 클래스의 필드도 아닌 곳에서 찾을 수 없습니다).');
        end;
        EmitExpr(aIL, ai.Index);
        // [Stage 37 버그 수정] 이전에는 배열 종류와 무관하게 항상 Ldelem_I4를 썼다 —
        // array of integer는 우연히 맞았지만 array of string은 참조(포인터)를 4바이트
        // 정수로 잘못 읽어 쓰레기 값이 나왔다. 원소를 쓰는 쪽(Stelem, 아래 TArrayAssignStmtNode)은
        // 이미 배열 타입을 보고 Stelem_Ref/Stelem_I4를 갈라 쓰고 있었으므로 읽는 쪽도 맞춘다.
        // [Stage 90] array of object도 문자열 배열과 마찬가지로 참조 타입 원소이므로 Ldelem_Ref.
        if aiIsRefElem then aIL.Emit(OpCodes.Ldelem_Ref)
        else aIL.Emit(OpCodes.Ldelem_I4);
      end

      // [Stage 67] 2차원 배열 원소 읽기: arr[i][j]
      // CLR jagged array: 먼저 arr[i]로 행 배열(T[])을 로드, 그 뒤 [j]로 원소를 로드.
      else if e is TMatrix2DIndexExprNode then
      begin
        var m2r:=TMatrix2DIndexExprNode(e);
        if fLocalScope.Has(m2r.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(m2r.ArrName))
        else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(m2r.ArrName));
        EmitExpr(aIL, m2r.Row);
        aIL.Emit(OpCodes.Ldelem_Ref); // arr[i] → T[]
        EmitExpr(aIL, m2r.Col);
        var _m2etn2:=GetVarClassName(m2r.ArrName);
        if _m2etn2='string' then aIL.Emit(OpCodes.Ldelem_Ref)
        else if (_m2etn2='real') or (_m2etn2='double') then aIL.Emit(OpCodes.Ldelem_R8)
        else if _m2etn2='char' then aIL.Emit(OpCodes.Ldelem_U2)
        else if _m2etn2='int64' then aIL.Emit(OpCodes.Ldelem_I8)
        else aIL.Emit(OpCodes.Ldelem_I4); // integer 기본
      end

      else if e is TVarRefNode then
      begin
        vr:=TVarRefNode(e);
        // [Stage 96] 전역 const는 Program 타입의 static readonly 필드 — Ldsfld로 읽는다.
        // fLocalScope/fGlobalScope(로컬 슬롯)보다 먼저 확인해야 한다.
        if fGlobalConstFields.ContainsKey(vr.VarName) then
          aIL.Emit(OpCodes.Ldsfld, fGlobalConstFields[vr.VarName])
        else if fLocalScope.Has(vr.VarName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(vr.VarName))
        else if fGlobalScope.Has(vr.VarName) then aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(vr.VarName))
        else raise new Exception('선언되지 않은 변수 "'+vr.VarName+'"');
      end

      else if e is TSetLiteralExprNode then // [Stage 63]
        aIL.Emit(OpCodes.Ldc_I4, TSetLiteralExprNode(e).Mask)

      else if e is TInExprNode then // [Stage 63] Elem in SetExpr → (SetExpr and (1 shl Elem)) 부호없이 0보다 큼
      begin
        var _inE:=TInExprNode(e);
        EmitExpr(aIL, _inE.SetExpr);
        aIL.Emit(OpCodes.Ldc_I4_1);
        EmitExpr(aIL, _inE.Elem);
        aIL.Emit(OpCodes.Shl);
        aIL.Emit(OpCodes.And);
        aIL.Emit(OpCodes.Ldc_I4_0);
        aIL.Emit(OpCodes.Cgt_Un);
      end

      else if e is TBinOpNode then
      begin
        b:=TBinOpNode(e); lt:=InferType(b.Left); rt:=InferType(b.Right);
        if (lt=vtObject) and (rt=vtObject) then // [Stage 66] 연산자 오버로딩
        begin
          var _opLcn66, _opRcn66: string;
          if TryGetObjClassName(b.Left, _opLcn66) and TryGetObjClassName(b.Right, _opRcn66)
             and (_opLcn66=_opRcn66) and (_opLcn66<>'') then
          begin
            var _opSym66:=OpKindSymbol(b.Op);
            var _opKey66:=_opSym66+'|'+_opLcn66;
            if fOperatorOverloadFuncs.ContainsKey(_opKey66) then
            begin
              EmitExpr(aIL, b.Left);
              EmitExpr(aIL, b.Right);
              aIL.Emit(OpCodes.Call, fMethods[fOperatorOverloadFuncs[_opKey66]]);
            end
            else raise new Exception('타입 "'+_opLcn66+'"에는 연산자 "'+_opSym66+'"가 정의되어 있지 않습니다 (Stage 66)');
          end
          else raise new Exception('연산자 오버로딩 대상 식을 판별할 수 없습니다 (Stage 66) — '
            +'지역변수/필드, 또는 이미 오버로딩된 연산식끼리만 조합할 수 있습니다');
        end
        else if (lt=vtSet) or (rt=vtSet) then // [Stage 63] 집합 연산: + 합집합, - 차집합, * 교집합
        begin
          EmitExpr(aIL, b.Left);
          EmitExpr(aIL, b.Right);
          if b.Op=boAdd then aIL.Emit(OpCodes.Or)
          else if b.Op=boMul then aIL.Emit(OpCodes.And)
          else if b.Op=boSub then begin aIL.Emit(OpCodes.Not); aIL.Emit(OpCodes.And); end
          else raise new Exception('집합에는 +(합집합), -(차집합), *(교집합)만 지원합니다 (Stage 63)');
        end
        else if (b.Op=boAdd) and ((lt=vtString) or (rt=vtString)) then
        begin
          // 문자열 연결: 피연산자를 string으로 변환 후 Concat
          EmitExpr(aIL, b.Left);
          if lt=vtInteger then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(integer)]); aIL.Emit(OpCodes.Call,ts); end
          else if lt=vtReal then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(double)]); aIL.Emit(OpCodes.Call,ts); end
          else if lt=vtChar then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(char)]); aIL.Emit(OpCodes.Call,ts); end
          else if lt=vtInt64 then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(int64)]); aIL.Emit(OpCodes.Call,ts); end;
          EmitExpr(aIL, b.Right);
          if rt=vtInteger then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(integer)]); aIL.Emit(OpCodes.Call,ts); end
          else if rt=vtReal then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(double)]); aIL.Emit(OpCodes.Call,ts); end
          else if rt=vtChar then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(char)]); aIL.Emit(OpCodes.Call,ts); end
          else if rt=vtInt64 then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(int64)]); aIL.Emit(OpCodes.Call,ts); end;
          cat:=typeof(string).GetMethod('Concat',[typeof(string),typeof(string)]);
          aIL.Emit(OpCodes.Call, cat);
        end
        else
        begin
          // [Phase 1] real 혼합 산술: 한쪽이 real이면 다른 쪽을 double로 승격
          var isReal:=(lt=vtReal) or (rt=vtReal);
          EmitExpr(aIL, b.Left);
          if isReal and (lt=vtInteger) then aIL.Emit(OpCodes.Conv_R8)
          else if isReal and (lt=vtInt64) then aIL.Emit(OpCodes.Conv_R8);
          EmitExpr(aIL, b.Right);
          if isReal and (rt=vtInteger) then aIL.Emit(OpCodes.Conv_R8)
          else if isReal and (rt=vtInt64) then aIL.Emit(OpCodes.Conv_R8);
          if b.Op=boAdd then aIL.Emit(OpCodes.Add)
          else if b.Op=boSub then aIL.Emit(OpCodes.Sub)
          else if b.Op=boMul then aIL.Emit(OpCodes.Mul)
          else if b.Op=boDiv then aIL.Emit(OpCodes.Div)
          else if b.Op=boMod then aIL.Emit(OpCodes.Rem)
          // [Stage 72 버그수정] boAnd/boOr(논리 and/or)가 여기서 하나도 매칭되지 않아
          // Left/Right를 스택에 push만 해두고 아무 명령도 방출하지 않던 버그.
          // Pascal boolean은 0/1(int32)로 표현되므로 비트 And/Or가 논리 And/Or와 동치이다.
          else if b.Op=boAnd then aIL.Emit(OpCodes.And)
          else if b.Op=boOr then aIL.Emit(OpCodes.Or)
          // [버그 수정] shl/shr는 파서(ParseMulDivMod)가 이미 인식하고 있었는데 여기 IL 방출
          // 체인에 대응하는 분기가 없어서, boShl/boShr 값이 들어와도 그냥 Left/Right만 스택에
          // push된 채 아무 명령도 안 나가고 있었다. shr는 표준 Pascal 관례대로 부호 없는(논리)
          // 오른쪽 시프트로 방출한다(Delphi/FPC의 shr와 동일). 시프트 횟수는 IL 규약상 항상
          // int32로 취급되므로 위쪽의 Conv_R8 보정과는 무관하다.
          else if b.Op=boShl then aIL.Emit(OpCodes.Shl)
          else if b.Op=boShr then aIL.Emit(OpCodes.Shr_Un);
        end;
      end

      else if e is TCompareNode then
      begin
        cmp:=TCompareNode(e); EmitExpr(aIL, cmp.Left); EmitExpr(aIL, cmp.Right);
        if cmp.Op=cmpEq then aIL.Emit(OpCodes.Ceq)
        else if cmp.Op=cmpLt then aIL.Emit(OpCodes.Clt)
        else if cmp.Op=cmpGt then aIL.Emit(OpCodes.Cgt)
        else if cmp.Op=cmpNeq then
          begin aIL.Emit(OpCodes.Ceq); aIL.Emit(OpCodes.Ldc_I4_0); aIL.Emit(OpCodes.Ceq); end
        else if cmp.Op=cmpLe then
          begin aIL.Emit(OpCodes.Cgt); aIL.Emit(OpCodes.Ldc_I4_0); aIL.Emit(OpCodes.Ceq); end
        else if cmp.Op=cmpGe then
          begin aIL.Emit(OpCodes.Clt); aIL.Emit(OpCodes.Ldc_I4_0); aIL.Emit(OpCodes.Ceq); end;
      end

      else if e is TFuncCallExprNode then
      begin
        fc:=TFuncCallExprNode(e);
        if fMethods.ContainsKey(fc.FuncName) then
        begin
          mb:=fMethods[fc.FuncName];
          var _fcParams: array of System.Type;
          if fTopParamClrTypes.ContainsKey(fc.FuncName) then _fcParams:=fTopParamClrTypes[fc.FuncName]
          else _fcParams:=nil;
          EmitArgsCoerced(aIL, fc.Args, _fcParams);
          aIL.Emit(OpCodes.Call, mb);
        end
        // [Stage 71] fMethods에 없다면 단형화되지 않고 진짜 오픈 제네릭으로 남은 템플릿의
        // 맹글링된 호출일 수 있다 — Parser는 예전과 똑같이 "Identity_integer" 같은 구체
        // 이름으로 이 노드를 만들어 두므로, fOpenGenericCallMap으로 원본 요청을 되찾는다.
        else if fOpenGenericCallMap.ContainsKey(fc.FuncName) then
          EmitOpenGenericCall(aIL, fOpenGenericCallMap[fc.FuncName], fc.Args)
        else
          raise new Exception('알 수 없는 함수 "'+fc.FuncName+'"');
      end

      else if e is TBoolLiteralNode then
      begin
        if TBoolLiteralNode(e).Value then aIL.Emit(OpCodes.Ldc_I4_1)
        else aIL.Emit(OpCodes.Ldc_I4_0);
      end

      else if e is TNotExprNode then
      begin
        EmitExpr(aIL, TNotExprNode(e).Expr);
        aIL.Emit(OpCodes.Ldc_I4_0);
        aIL.Emit(OpCodes.Ceq); // 0과 같으면 1, 아니면 0 → 논리 not
      end

      else if e is TExceptionMsgExprNode then
      begin
        // E.Message — 예외 변수(로컬)를 로드하고 get_Message 호출
        var emn:=TExceptionMsgExprNode(e);
        if fLocalScope.Has(emn.VarName) then
          aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(emn.VarName))
        else if fGlobalScope.Has(emn.VarName) then
          aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(emn.VarName))
        else raise new Exception('선언되지 않은 예외 변수 "'+emn.VarName+'"');
        var getMsgMI:=typeof(Exception).GetMethod('get_Message');
        if getMsgMI=nil then
          getMsgMI:=typeof(Exception).GetProperty('Message').GetGetMethod;
        aIL.Emit(OpCodes.Callvirt, getMsgMI);
      end

      else if e is TRuntimeTypeNameExprNode then
      begin
        // [Stage 75] obj.GetType.FullName / obj.GetType.Name — 변수를 로드하고
        // Object.GetType()을 호출한 뒤(항상 System.Type을 반환) get_FullName/get_Name으로 읽는다.
        var rtn:=TRuntimeTypeNameExprNode(e);
        if fLocalScope.Has(rtn.VarName) then
          aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(rtn.VarName))
        else if fGlobalScope.Has(rtn.VarName) then
          aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(rtn.VarName))
        else raise new Exception('선언되지 않은 변수 "'+rtn.VarName+'"');
        var getTypeMI:=typeof(System.Object).GetMethod('GetType', System.Type.EmptyTypes);
        aIL.Emit(OpCodes.Callvirt, getTypeMI);
        var typeNamePropName:='Name';
        if rtn.WantFullName then typeNamePropName:='FullName';
        var typeNameGetMI:=typeof(System.Type).GetProperty(typeNamePropName).GetGetMethod;
        aIL.Emit(OpCodes.Callvirt, typeNameGetMI);
      end

      else if e is TStaticMemberExprNode then
      begin
        // TypeName.MemberName — 정적 필드/속성 읽기 (예: System.EventArgs.Empty)
        var sm:=TStaticMemberExprNode(e);
        var smType:=ResolveExternalType(sm.TypeName);
        var smPi:=SafeGetProperty(smType, sm.MemberName);
        if (smPi<>nil) and (smPi.GetGetMethod<>nil) then
          aIL.Emit(OpCodes.Call, smPi.GetGetMethod) // 정적 프로퍼티 getter는 Call(비가상)
        else
        begin
          var smFi:=smType.GetField(sm.MemberName);
          if smFi=nil then
            raise new Exception('타입 "'+smType.FullName+'"에 정적 필드/속성 "'+sm.MemberName+'"가 없습니다.');
          // [Stage 76] enum 멤버(예: DockStyle.Top)는 실제로는 컴파일타임 상수(literal) 필드라
          // 런타임 저장 공간이 없다 — Ldsfld를 쓰면 MissingFieldException이 난다. 리터럴 필드는
          // GetRawConstantValue로 실제 정수값을 꺼내 Ldc_I4로 직접 스택에 올려야 한다.
          if smFi.IsLiteral then
            aIL.Emit(OpCodes.Ldc_I4, System.Convert.ToInt32(smFi.GetRawConstantValue))
          else
            aIL.Emit(OpCodes.Ldsfld, smFi); // 진짜 정적 필드(저장 공간 있음)는 기존처럼 Ldsfld
        end;
      end

      else if e is TSelfExprNode then
        aIL.Emit(OpCodes.Ldarg_0) // [Stage 30] self 값 자체 (인자 전달, as 캐스트 대상 등)

      else if e is TAsCastExprNode then
      begin
        // [Stage 30] <식> as <TypeName> — Castclass로 구현 (실패 시 InvalidCastException,
        // Delphi as의 "실패하면 예외" 의미론과 일치. TypeName(expr) 캐스트와 IL은 같지만
        // '식 전체'에 적용 가능하다는 점이 다르다 — TypeName(expr) 캐스트는 바로 뒤 멤버
        // 접근 패턴에서만 파서가 인식한다).
        var asc:=TAsCastExprNode(e);
        EmitExpr(aIL, asc.Expr);
        var targetT: System.Type;
        if asc.IsExternalType then targetT:=ResolveExternalType(asc.TargetType)
        else if fBuiltInterfaces.ContainsKey(asc.TargetType) then targetT:=fBuiltInterfaces[asc.TargetType]
        else if fBuiltTypes.ContainsKey(asc.TargetType) then targetT:=fBuiltTypes[asc.TargetType]
        else if fTypeBuilders.ContainsKey(asc.TargetType) then targetT:=fTypeBuilders[asc.TargetType]
        else raise new Exception('as 캐스트 대상 타입을 찾을 수 없음: "'+asc.TargetType+'"');
        aIL.Emit(OpCodes.Castclass, targetT);
      end

      else if e is TIsCheckExprNode then
      begin
        // [Stage 93c] <식> is <TypeName> — Isinst는 캐스트 성공 시 그 참조를, 실패 시 null을
        // 남긴다(Castclass와 달리 예외를 던지지 않음). null 여부만 bool로 뽑아내면 되므로
        // Isinst → Ldnull → Cgt_Un(부호 없는 비교: null(0)보다 크면 true, 즉 null이 아니면 true)
        // 순서로 구현한다. 대상 타입 조회 로직은 바로 위 TAsCastExprNode와 완전히 동일하다.
        var isc:=TIsCheckExprNode(e);
        EmitExpr(aIL, isc.Expr);
        var isTargetT: System.Type;
        if isc.IsExternalType then isTargetT:=ResolveExternalType(isc.TargetType)
        else if fBuiltInterfaces.ContainsKey(isc.TargetType) then isTargetT:=fBuiltInterfaces[isc.TargetType]
        else if fBuiltTypes.ContainsKey(isc.TargetType) then isTargetT:=fBuiltTypes[isc.TargetType]
        else if fTypeBuilders.ContainsKey(isc.TargetType) then isTargetT:=fTypeBuilders[isc.TargetType]
        else raise new Exception('is 타입 체크 대상 타입을 찾을 수 없음: "'+isc.TargetType+'"');
        aIL.Emit(OpCodes.Isinst, isTargetT);
        aIL.Emit(OpCodes.Ldnull);
        aIL.Emit(OpCodes.Cgt_Un);
      end

      else if e is TInheritedCallExprNode then
      begin
        var ihe:=TInheritedCallExprNode(e);
        EmitInheritedCall(aIL, ihe.MethodName, ihe.Args, true);
      end

      else if e is TSeqExtCallExprNode then // [Stage 70]
        EmitSeqExtCall(aIL, TSeqExtCallExprNode(e))

      else if e is TBuiltinCallExprNode then // [Stage 72]
        EmitBuiltinCall(aIL, TBuiltinCallExprNode(e))

      else raise new Exception('알 수 없는 식 노드: '+e.GetType.Name);
      finally
        fEmitDepth:=fEmitDepth-1;
      end;
    end;

    // [Stage 70] LINQ 스타일 확장 메서드 하나(Where/Select/Sum/Count/ToArray)를 실제로 컴파일한다.
    // 다섯 경우 모두 "소스를 IEnumerable(비제네릭)로 순회하며 원소를 하나씩 처리"하는 뼈대는
    // Stage 54/69 for-in desugar(GetEnumerator/MoveNext/Current)와 동일하다 — 결과를 어떻게
    // 모으는지만 다르므로 공용 추상화 대신 케이스마다 그대로 풀어 쓴다(이 파일 전반의 관례).
    // 결과 표현: Where/Select → List<원소타입> 참조(1차 제약: 더 체이닝하거나 for-in의 컬렉션
    // 자리에 바로 쓰는 용도로만 — 지역변수에 저장해 재사용하는 것은 아직 지원 안 함),
    // Sum → 스칼라(원소 타입 그대로), Count → integer, ToArray → T[](정수/문자열 원소만 1차 지원).
    procedure EmitSeqExtCall(aIL: ILGenerator; node: TSeqExtCallExprNode);
    var
      srcElemType: TVarType; srcElemClr, listOpenT, listT: System.Type;
      enumLoc, elemLoc, resultLoc: LocalBuilder;
      ckL, bdL, endL: &Label;
      getEnumMI, getCurMI, moveNextMI: MethodInfo;
      hadParamEntry: boolean;
    begin
      srcElemType:=GetSeqElemType(node.Source);
      srcElemClr:=VTC(srcElemType, '');

      // ---- 공통 준비: 소스를 순회할 (비제네릭) 이터레이터를 얻는다 ----
      EmitExpr(aIL, node.Source);
      getEnumMI:=typeof(System.Collections.IEnumerable).GetMethod('GetEnumerator');
      aIL.Emit(OpCodes.Callvirt, getEnumMI);
      enumLoc:=aIL.DeclareLocal(typeof(System.Collections.IEnumerator));
      aIL.Emit(OpCodes.Stloc, enumLoc);
      getCurMI:=typeof(System.Collections.IEnumerator).GetProperty('Current').GetGetMethod;
      moveNextMI:=typeof(System.Collections.IEnumerator).GetMethod('MoveNext');
      listOpenT:=System.Type.GetType('System.Collections.Generic.List`1');

      if node.MethodName='Where' then
      begin
        // 원소 타입은 그대로, 조건을 만족하는 것만 새 List에 담는다.
        listT:=listOpenT.MakeGenericType(srcElemClr);
        resultLoc:=aIL.DeclareLocal(listT);
        aIL.Emit(OpCodes.Newobj, listT.GetConstructor(System.Type.EmptyTypes));
        aIL.Emit(OpCodes.Stloc, resultLoc);
        elemLoc:=aIL.DeclareLocal(srcElemClr);
        hadParamEntry:=fLocalScope.Has(node.Lambda.ParamName);
        fLocalScope.Declare(node.Lambda.ParamName, elemLoc, srcElemType);

        ckL:=aIL.DefineLabel; bdL:=aIL.DefineLabel; endL:=aIL.DefineLabel;
        aIL.Emit(OpCodes.Br, ckL);
        aIL.MarkLabel(bdL);
        aIL.Emit(OpCodes.Ldloc, enumLoc);
        aIL.Emit(OpCodes.Callvirt, getCurMI);
        if srcElemClr.IsValueType then aIL.Emit(OpCodes.Unbox_Any, srcElemClr) else aIL.Emit(OpCodes.Castclass, srcElemClr);
        aIL.Emit(OpCodes.Stloc, elemLoc);

        EmitExpr(aIL, node.Lambda.Body); // predicate → 0/1 (int32)
        var skipL:=aIL.DefineLabel;
        aIL.Emit(OpCodes.Brfalse, skipL);
        aIL.Emit(OpCodes.Ldloc, resultLoc);
        aIL.Emit(OpCodes.Ldloc, elemLoc);
        aIL.Emit(OpCodes.Callvirt, listT.GetMethod('Add'));
        aIL.MarkLabel(skipL);

        aIL.MarkLabel(ckL);
        aIL.Emit(OpCodes.Ldloc, enumLoc);
        aIL.Emit(OpCodes.Callvirt, moveNextMI);
        aIL.Emit(OpCodes.Brtrue, bdL);
        aIL.MarkLabel(endL);
        if not hadParamEntry then fLocalScope.Remove(node.Lambda.ParamName);

        aIL.Emit(OpCodes.Ldloc, resultLoc);
      end

      else if node.MethodName='Select' then
      begin
        elemLoc:=aIL.DeclareLocal(srcElemClr);
        hadParamEntry:=fLocalScope.Has(node.Lambda.ParamName);
        fLocalScope.Declare(node.Lambda.ParamName, elemLoc, srcElemType);
        // selector 본문의 결과 타입 = 새 원소 타입 — 결과 List<T>의 T를 정하려면 루프를
        // 열기 전에 미리 알아야 한다(InferType은 IL을 방출하지 않으므로 미리 호출해도 안전).
        var dstElemType:=InferType(node.Lambda.Body);
        var dstElemClr:=VTC(dstElemType, '');
        listT:=listOpenT.MakeGenericType(dstElemClr);
        resultLoc:=aIL.DeclareLocal(listT);
        aIL.Emit(OpCodes.Newobj, listT.GetConstructor(System.Type.EmptyTypes));
        aIL.Emit(OpCodes.Stloc, resultLoc);

        ckL:=aIL.DefineLabel; bdL:=aIL.DefineLabel; endL:=aIL.DefineLabel;
        aIL.Emit(OpCodes.Br, ckL);
        aIL.MarkLabel(bdL);
        aIL.Emit(OpCodes.Ldloc, enumLoc);
        aIL.Emit(OpCodes.Callvirt, getCurMI);
        if srcElemClr.IsValueType then aIL.Emit(OpCodes.Unbox_Any, srcElemClr) else aIL.Emit(OpCodes.Castclass, srcElemClr);
        aIL.Emit(OpCodes.Stloc, elemLoc);

        aIL.Emit(OpCodes.Ldloc, resultLoc);
        EmitExpr(aIL, node.Lambda.Body); // selector 결과(dstElemClr 타입)
        aIL.Emit(OpCodes.Callvirt, listT.GetMethod('Add'));

        aIL.MarkLabel(ckL);
        aIL.Emit(OpCodes.Ldloc, enumLoc);
        aIL.Emit(OpCodes.Callvirt, moveNextMI);
        aIL.Emit(OpCodes.Brtrue, bdL);
        aIL.MarkLabel(endL);
        if not hadParamEntry then fLocalScope.Remove(node.Lambda.ParamName);

        aIL.Emit(OpCodes.Ldloc, resultLoc);
      end

      else if node.MethodName='Sum' then
      begin
        if (srcElemType<>vtInteger) and (srcElemType<>vtReal) and (srcElemType<>vtInt64) then
          raise new Exception('Sum()은 integer/real/int64 원소 시퀀스에만 사용할 수 있습니다 (Stage 70, 1차 제약)');
        resultLoc:=aIL.DeclareLocal(srcElemClr);
        if srcElemType=vtReal then aIL.Emit(OpCodes.Ldc_R8, double(0))
        else if srcElemType=vtInt64 then aIL.Emit(OpCodes.Ldc_I8, int64(0))
        else aIL.Emit(OpCodes.Ldc_I4_0);
        aIL.Emit(OpCodes.Stloc, resultLoc);
        elemLoc:=aIL.DeclareLocal(srcElemClr);

        ckL:=aIL.DefineLabel; bdL:=aIL.DefineLabel; endL:=aIL.DefineLabel;
        aIL.Emit(OpCodes.Br, ckL);
        aIL.MarkLabel(bdL);
        aIL.Emit(OpCodes.Ldloc, enumLoc);
        aIL.Emit(OpCodes.Callvirt, getCurMI);
        if srcElemClr.IsValueType then aIL.Emit(OpCodes.Unbox_Any, srcElemClr) else aIL.Emit(OpCodes.Castclass, srcElemClr);
        aIL.Emit(OpCodes.Stloc, elemLoc);
        aIL.Emit(OpCodes.Ldloc, resultLoc);
        aIL.Emit(OpCodes.Ldloc, elemLoc);
        aIL.Emit(OpCodes.Add);
        aIL.Emit(OpCodes.Stloc, resultLoc);

        aIL.MarkLabel(ckL);
        aIL.Emit(OpCodes.Ldloc, enumLoc);
        aIL.Emit(OpCodes.Callvirt, moveNextMI);
        aIL.Emit(OpCodes.Brtrue, bdL);
        aIL.MarkLabel(endL);

        aIL.Emit(OpCodes.Ldloc, resultLoc);
      end

      else if node.MethodName='Count' then
      begin
        resultLoc:=aIL.DeclareLocal(typeof(integer));
        aIL.Emit(OpCodes.Ldc_I4_0);
        aIL.Emit(OpCodes.Stloc, resultLoc);

        ckL:=aIL.DefineLabel; bdL:=aIL.DefineLabel; endL:=aIL.DefineLabel;
        aIL.Emit(OpCodes.Br, ckL);
        aIL.MarkLabel(bdL);
        aIL.Emit(OpCodes.Ldloc, resultLoc);
        aIL.Emit(OpCodes.Ldc_I4_1);
        aIL.Emit(OpCodes.Add);
        aIL.Emit(OpCodes.Stloc, resultLoc);

        aIL.MarkLabel(ckL);
        aIL.Emit(OpCodes.Ldloc, enumLoc);
        aIL.Emit(OpCodes.Callvirt, moveNextMI);
        aIL.Emit(OpCodes.Brtrue, bdL);
        aIL.MarkLabel(endL);

        aIL.Emit(OpCodes.Ldloc, resultLoc);
      end

      else if node.MethodName='ToArray' then
      begin
        if (srcElemType<>vtInteger) and (srcElemType<>vtString) then
          raise new Exception('ToArray()는 1차 제약으로 integer/string 원소 시퀀스만 지원합니다 (Stage 70)');
        listT:=listOpenT.MakeGenericType(srcElemClr);
        resultLoc:=aIL.DeclareLocal(listT);
        aIL.Emit(OpCodes.Newobj, listT.GetConstructor(System.Type.EmptyTypes));
        aIL.Emit(OpCodes.Stloc, resultLoc);
        elemLoc:=aIL.DeclareLocal(srcElemClr);

        ckL:=aIL.DefineLabel; bdL:=aIL.DefineLabel; endL:=aIL.DefineLabel;
        aIL.Emit(OpCodes.Br, ckL);
        aIL.MarkLabel(bdL);
        aIL.Emit(OpCodes.Ldloc, enumLoc);
        aIL.Emit(OpCodes.Callvirt, getCurMI);
        if srcElemClr.IsValueType then aIL.Emit(OpCodes.Unbox_Any, srcElemClr) else aIL.Emit(OpCodes.Castclass, srcElemClr);
        aIL.Emit(OpCodes.Stloc, elemLoc);
        aIL.Emit(OpCodes.Ldloc, resultLoc);
        aIL.Emit(OpCodes.Ldloc, elemLoc);
        aIL.Emit(OpCodes.Callvirt, listT.GetMethod('Add'));

        aIL.MarkLabel(ckL);
        aIL.Emit(OpCodes.Ldloc, enumLoc);
        aIL.Emit(OpCodes.Callvirt, moveNextMI);
        aIL.Emit(OpCodes.Brtrue, bdL);
        aIL.MarkLabel(endL);

        aIL.Emit(OpCodes.Ldloc, resultLoc);
        aIL.Emit(OpCodes.Callvirt, listT.GetMethod('ToArray'));
      end

      else
        raise new Exception('알 수 없는 시퀀스 확장 메서드 "'+node.MethodName+'" (Stage 70)');
    end;

    // [Stage 72] PABCSystem 표준 라이브러리 함수 하나(Abs/Sqrt/UpperCase/Copy/StrToInt/...)를
    // 실제로 컴파일한다. 함수마다 인자 개수를 직접 검사해 맞지 않으면 바로 에러를 낸다.
    procedure EmitBuiltinCall(aIL: ILGenerator; node: TBuiltinCallExprNode);
    var argT: TVarType; mi: MethodInfo; randCtor: ConstructorInfo;
    begin
      if node.Name='Abs' then
      begin
        if node.Args.Count<>1 then raise new Exception('Abs()는 인자가 1개 필요합니다 (Stage 72)');
        argT:=InferType(node.Args[0]);
        EmitExpr(aIL, node.Args[0]);
        if argT=vtReal then mi:=typeof(System.Math).GetMethod('Abs', [typeof(double)])
        else if argT=vtInt64 then mi:=typeof(System.Math).GetMethod('Abs', [typeof(int64)])
        else mi:=typeof(System.Math).GetMethod('Abs', [typeof(integer)]);
        aIL.Emit(OpCodes.Call, mi);
      end

      else if node.Name='Sqr' then
      begin
        // System.Math에는 Sqr가 없다 — x*x는 어떤 수치 타입에서도 Dup+Mul로 충분하다.
        if node.Args.Count<>1 then raise new Exception('Sqr()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        aIL.Emit(OpCodes.Dup);
        aIL.Emit(OpCodes.Mul);
      end

      else if node.Name='Sqrt' then
      begin
        if node.Args.Count<>1 then raise new Exception('Sqrt()는 인자가 1개 필요합니다 (Stage 72)');
        argT:=InferType(node.Args[0]);
        EmitExpr(aIL, node.Args[0]);
        if argT<>vtReal then aIL.Emit(OpCodes.Conv_R8); // integer/int64 → double로 승격
        aIL.Emit(OpCodes.Call, typeof(System.Math).GetMethod('Sqrt', [typeof(double)]));
      end

      else if node.Name='Round' then
      begin
        // Convert.ToInt32(double)는 가장 가까운 정수로 반올림한다(동률이면 짝수 쪽 — 은행가
        // 반올림). integer 인자는 반올림할 게 없으므로 그대로 통과시킨다.
        if node.Args.Count<>1 then raise new Exception('Round()는 인자가 1개 필요합니다 (Stage 72)');
        argT:=InferType(node.Args[0]);
        EmitExpr(aIL, node.Args[0]);
        if argT=vtReal then aIL.Emit(OpCodes.Call, typeof(System.Convert).GetMethod('ToInt32', [typeof(double)]));
      end

      else if node.Name='Trunc' then
      begin
        // conv.i4는 0을 향해 자르므로(음수도 마찬가지) Pascal Trunc와 정확히 같다.
        if node.Args.Count<>1 then raise new Exception('Trunc()는 인자가 1개 필요합니다 (Stage 72)');
        argT:=InferType(node.Args[0]);
        EmitExpr(aIL, node.Args[0]);
        if argT=vtReal then aIL.Emit(OpCodes.Conv_I4);
      end

      else if node.Name='Random' then
      begin
        // [1차 제약] 호출마다 새 System.Random 인스턴스를 만든다(공유 시드 필드를 두지
        // 않음) — 최신 .NET에서는 인스턴스 시드가 시각뿐 아니라 GUID 기반 엔트로피도
        // 섞이므로 짧은 시간에 여러 번 불러도 실제로 문제되는 경우는 드물다.
        randCtor:=typeof(System.Random).GetConstructor(System.Type.EmptyTypes);
        if node.Args.Count=0 then
        begin
          aIL.Emit(OpCodes.Newobj, randCtor);
          aIL.Emit(OpCodes.Callvirt, typeof(System.Random).GetMethod('NextDouble', System.Type.EmptyTypes));
        end
        else
        begin
          if node.Args.Count<>1 then raise new Exception('Random()는 인자가 0개 또는 1개여야 합니다 (Stage 72)');
          aIL.Emit(OpCodes.Newobj, randCtor);
          EmitExpr(aIL, node.Args[0]);
          aIL.Emit(OpCodes.Callvirt, typeof(System.Random).GetMethod('Next', [typeof(integer)]));
        end;
      end

      else if node.Name='UpperCase' then
      begin
        if node.Args.Count<>1 then raise new Exception('UpperCase()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        aIL.Emit(OpCodes.Callvirt, typeof(string).GetMethod('ToUpper', System.Type.EmptyTypes));
      end

      else if node.Name='LowerCase' then
      begin
        if node.Args.Count<>1 then raise new Exception('LowerCase()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        aIL.Emit(OpCodes.Callvirt, typeof(string).GetMethod('ToLower', System.Type.EmptyTypes));
      end

      else if node.Name='Trim' then
      begin
        if node.Args.Count<>1 then raise new Exception('Trim()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        aIL.Emit(OpCodes.Callvirt, typeof(string).GetMethod('Trim', System.Type.EmptyTypes));
      end

      else if node.Name='Copy' then
      begin
        // Pascal Copy(s, index, count) — index는 1부터. .NET Substring(startIndex, length)는
        // 0부터이므로 index에서 1을 뺀다.
        if node.Args.Count<>3 then raise new Exception('Copy()는 인자가 3개(s, index, count) 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        EmitExpr(aIL, node.Args[1]);
        aIL.Emit(OpCodes.Ldc_I4_1);
        aIL.Emit(OpCodes.Sub);
        EmitExpr(aIL, node.Args[2]);
        aIL.Emit(OpCodes.Callvirt, typeof(string).GetMethod('Substring', [typeof(integer), typeof(integer)]));
      end

      else if node.Name='Pos' then
      begin
        // Pascal Pos(sub, s) — 1부터 시작하는 위치, 못 찾으면 0.
        // .NET s.IndexOf(sub)는 0부터, 못 찾으면 -1 — 결과에 1을 더하면 두 경우 모두 맞는다
        // (찾음: 0-based k → k+1. 못 찾음: -1 → 0).
        if node.Args.Count<>2 then raise new Exception('Pos()는 인자가 2개(부분 문자열, 대상 문자열) 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[1]); // s
        EmitExpr(aIL, node.Args[0]); // sub
        aIL.Emit(OpCodes.Callvirt, typeof(string).GetMethod('IndexOf', [typeof(string)]));
        aIL.Emit(OpCodes.Ldc_I4_1);
        aIL.Emit(OpCodes.Add);
      end

      else if node.Name='StrToInt' then
      begin
        if node.Args.Count<>1 then raise new Exception('StrToInt()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        aIL.Emit(OpCodes.Call, typeof(System.Convert).GetMethod('ToInt32', [typeof(string)]));
      end

      else if node.Name='StrToFloat' then
      begin
        if node.Args.Count<>1 then raise new Exception('StrToFloat()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        aIL.Emit(OpCodes.Call, typeof(System.Convert).GetMethod('ToDouble', [typeof(string)]));
      end

      else if node.Name='FloatToStr' then
      begin
        if node.Args.Count<>1 then raise new Exception('FloatToStr()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        aIL.Emit(OpCodes.Call, typeof(System.Convert).GetMethod('ToString', [typeof(double)]));
      end

      else if (node.Name='Ord') or (node.Name='Chr') then
      begin
        // [Stage 72] char는 이 컴파일러에서(그리고 CIL 실행 스택 자체에서도) int32와 호환되는
        // 표현을 쓴다 — Ord(char→integer)/Chr(integer→char) 둘 다 변환 명령이 필요 없고,
        // 값을 그대로 로드하기만 하면 목표 타입(정수/문자) 자리에 맞게 들어간다.
        if node.Args.Count<>1 then raise new Exception(node.Name+'()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
      end

      else if node.Name='ReadLn' then
      begin
        if node.Args.Count<>0 then raise new Exception('ReadLn()는 인자 없이 써야 합니다 (Stage 72, 1차 제약: 변수로 직접 읽어들이는 형태는 아직 미지원)');
        aIL.Emit(OpCodes.Call, typeof(System.Console).GetMethod('ReadLine', System.Type.EmptyTypes));
      end

      else if node.Name='Format' then
      begin
        // [Stage 93] Format('{0}, {1}', a, b, ...) → System.String.Format(fmt, object[]).
        // 파서(NormalizeBuiltinFuncName, Stage 90)는 이미 이 이름을 인식해 TBuiltinCallExprNode로
        // 넘겨주고 있었지만 여기 EmitBuiltinCall에는 실제 구현이 빠져 있었다.
        // .NET string.Format은 {0},{1}.. 자리표시자를 그대로 쓰므로 형식 문자열은 변환 없이
        // 그대로 넘긴다. 나머지 인자는 object[]에 담아 전달하는데, 값 타입 인자
        // (integer/int64/real/boolean/char)는 Box하지 않으면 원시값이 그대로 object 참조
        // 슬롯에 들어가 실행 시 손상된다 — string 등 참조 타입은 Box 불필요.
        if node.Args.Count<1 then
          raise new Exception('Format()는 인자가 최소 1개(형식 문자열) 필요합니다 (Stage 93)');
        EmitExpr(aIL, node.Args[0]); // 형식 문자열
        var _fmtArgCount:=node.Args.Count-1;
        aIL.Emit(OpCodes.Ldc_I4, _fmtArgCount);
        aIL.Emit(OpCodes.Newarr, typeof(System.Object));
        for var _fmtI:=0 to _fmtArgCount-1 do
        begin
          aIL.Emit(OpCodes.Dup);
          aIL.Emit(OpCodes.Ldc_I4, _fmtI);
          var _fmtArgT:=InferType(node.Args[_fmtI+1]);
          EmitExpr(aIL, node.Args[_fmtI+1]);
          if _fmtArgT=vtInteger then aIL.Emit(OpCodes.Box, typeof(integer))
          else if _fmtArgT=vtInt64 then aIL.Emit(OpCodes.Box, typeof(int64))
          else if _fmtArgT=vtReal then aIL.Emit(OpCodes.Box, typeof(double))
          else if _fmtArgT=vtBoolean then aIL.Emit(OpCodes.Box, typeof(boolean))
          else if _fmtArgT=vtChar then aIL.Emit(OpCodes.Box, typeof(char));
          aIL.Emit(OpCodes.Stelem_Ref);
        end;
        aIL.Emit(OpCodes.Call, typeof(System.String).GetMethod('Format',
          [typeof(string), typeof(System.Object).MakeArrayType()]));
      end

      else if node.Name='GetCurrentDir' then
      begin
        // [Stage 93] appPath := GetCurrentDir; — 괄호 없이 쓰는 무인자 표준 함수.
        // .NET에는 System.IO.Directory.GetCurrentDirectory()가 동일한 역할을 한다.
        if node.Args.Count<>0 then raise new Exception('GetCurrentDir()는 인자가 없어야 합니다 (Stage 93)');
        aIL.Emit(OpCodes.Call, typeof(System.IO.Directory).GetMethod('GetCurrentDirectory', System.Type.EmptyTypes));
      end

      // [Stage 96] ParamCount — 커맨드라인 인자 개수. Environment.GetCommandLineArgs()의
      // 0번째는 실행 파일 경로 자신이므로, Pascal 관례(ParamStr(0)=실행파일, ParamStr(1..N)=인자)에
      // 맞춰 배열 길이에서 1을 뺀 값을 돌려준다.
      else if node.Name='ParamCount' then
      begin
        if node.Args.Count<>0 then raise new Exception('ParamCount는 인자가 없어야 합니다 (Stage 96)');
        aIL.Emit(OpCodes.Call, typeof(System.Environment).GetMethod('GetCommandLineArgs', System.Type.EmptyTypes));
        aIL.Emit(OpCodes.Ldlen);
        aIL.Emit(OpCodes.Conv_I4);
        aIL.Emit(OpCodes.Ldc_I4_1);
        aIL.Emit(OpCodes.Sub);
      end

      // [Stage 96] ParamStr(n) — n번째 커맨드라인 인자. GetCommandLineArgs()[0]이 실행 파일
      // 경로 자신이므로 ParamStr(1)은 그 배열의 인덱스 1과 정확히 일치해 별도 보정이 필요없다.
      else if node.Name='ParamStr' then
      begin
        if node.Args.Count<>1 then raise new Exception('ParamStr()는 인자가 1개 필요합니다 (Stage 96)');
        aIL.Emit(OpCodes.Call, typeof(System.Environment).GetMethod('GetCommandLineArgs', System.Type.EmptyTypes));
        argT:=InferType(node.Args[0]);
        EmitExpr(aIL, node.Args[0]);
        if argT<>vtInteger then aIL.Emit(OpCodes.Call, typeof(System.Convert).GetMethod('ToInt32', [typeof(double)]));
        aIL.Emit(OpCodes.Ldelem_Ref);
      end

      else
        raise new Exception('알 수 없는 표준 라이브러리 함수 "'+node.Name+'" (Stage 72)');
    end;

    // [Stage 60] break/continue 공용 헬퍼. isBreak=true면 가장 안쪽 루프의 탈출 라벨로,
    // false면 이어달리기(continue) 라벨로 점프한다. 루프가 하나도 열려 있지 않으면(스택이 비어있으면)
    // "루프 밖에서 break/continue 사용" 오류로 처리한다.
    // try/except/finally 블록 "안"에서 그 블록 밖으로(또는 걸쳐서) 점프해야 하는 경우 —
    // 즉 현재 try 중첩 깊이(fCurExceptDepth)가 루프 진입 시점의 깊이보다 깊은 경우 —
    // 단순 Br이 아니라 Leave를 써야 한다. Reflection.Emit에서 보호된(try/catch/finally) 영역을
    // Br로 그냥 빠져나가면 finally가 실행되지 않거나 검증(PEVerify) 실패로 이어질 수 있다.
    procedure EmitLoopExit(aIL: ILGenerator; isBreak: boolean);
    var targetLbl: &Label; loopDepth: integer;
    begin
      if fLoopBreakLabels.Count=0 then
        raise new Exception('break/continue는 for/while/repeat 루프 안에서만 사용할 수 있습니다');
      if isBreak then targetLbl:=fLoopBreakLabels[fLoopBreakLabels.Count-1]
      else targetLbl:=fLoopContinueLabels[fLoopContinueLabels.Count-1];
      loopDepth:=fLoopExceptDepths[fLoopExceptDepths.Count-1];
      if fCurExceptDepth>loopDepth then aIL.Emit(OpCodes.Leave, targetLbl)
      else aIL.Emit(OpCodes.Br, targetLbl);
    end;

    // [Stage 78] exit — 현재 서브프로그램의 몸체 끝(fMethodExitLabel)으로 점프한다.
    // try/except/finally 블록 "안"에서 그 블록을 벗어나 점프해야 하면(fCurExceptDepth>0)
    // EmitLoopExit과 동일한 이유로 Br이 아니라 Leave를 써야 한다.
    procedure EmitMethodExit(aIL: ILGenerator);
    begin
      if fCurExceptDepth>0 then aIL.Emit(OpCodes.Leave, fMethodExitLabel)
      else aIL.Emit(OpCodes.Br, fMethodExitLabel);
    end;

    // [Stage 90] writeln(a, b, c, ...)의 인자 하나를 출력한다. useNewLine=false면 Console.Write
    // (줄바꿈 없이 이어붙임), true면 Console.WriteLine(마지막 인자에서 줄바꿈까지 포함).
    // 기존 TWritelnExprStmtNode(인자 1개, 항상 WriteLine)와 동일한 타입별 오버로드 선택 로직을
    // Write/WriteLine 양쪽에 공통으로 쓸 수 있게 메서드 이름만 매개변수로 뺐다.
    procedure EmitWriteArg(aIL: ILGenerator; argExpr: TExprNode; useNewLine: boolean);
    var wMethodName: string; wet: TVarType;
    begin
      if useNewLine then wMethodName:='WriteLine' else wMethodName:='Write';
      wet:=InferType(argExpr);
      if wet=vtString then
      begin
        EmitExpr(aIL, argExpr);
        aIL.Emit(OpCodes.Call, typeof(Console).GetMethod(wMethodName,[typeof(string)]));
      end
      else if wet=vtBoolean then
      begin
        EmitExpr(aIL, argExpr);
        aIL.Emit(OpCodes.Call, typeof(Console).GetMethod(wMethodName,[typeof(boolean)]));
      end
      else if wet=vtReal then
      begin
        EmitExpr(aIL, argExpr);
        aIL.Emit(OpCodes.Call, typeof(Console).GetMethod(wMethodName,[typeof(double)]));
      end
      else if wet=vtChar then
      begin
        EmitExpr(aIL, argExpr);
        aIL.Emit(OpCodes.Call, typeof(Console).GetMethod(wMethodName,[typeof(char)]));
      end
      else if wet=vtInt64 then
      begin
        EmitExpr(aIL, argExpr);
        aIL.Emit(OpCodes.Call, typeof(Console).GetMethod(wMethodName,[typeof(int64)]));
      end
      else if wet=vtGeneric then
      begin
        EmitExpr(aIL, argExpr);
        aIL.Emit(OpCodes.Box, GetGenericExprClrType(argExpr));
        aIL.Emit(OpCodes.Call, typeof(Console).GetMethod(wMethodName,[typeof(System.Object)]));
      end
      // [Stage 90] vtObject(예: assembly.FullName처럼 정확한 타입을 못 잡는 외부 멤버, 또는
      // 실제로 object인 값) — object 오버로드로 내보내면 CLR이 알아서 ToString()을 호출해준다.
      else if wet=vtObject then
      begin
        EmitExpr(aIL, argExpr);
        aIL.Emit(OpCodes.Call, typeof(Console).GetMethod(wMethodName,[typeof(System.Object)]));
      end
      else
      begin
        EmitExpr(aIL, argExpr);
        aIL.Emit(OpCodes.Call, typeof(Console).GetMethod(wMethodName,[typeof(integer)]));
      end;
    end;

    procedure EmitStatement(aIL: ILGenerator; s: TStmtNode);
    var
      we: TWritelnExprStmtNode; ws: TWritelnStringStmtNode;
      asg: TAssignStmtNode; ra: TResultAssignStmtNode;
      comp: TCompoundStmtNode; ifs: TIfStmtNode; whs: TWhileStmtNode;
      pc: TProcCallStmtNode; sl: TSetLengthStmtNode; aa: TArrayAssignStmtNode;
      mcs: TMethodCallStmtNode; fas: TFieldAssignStmtNode;
      loc: LocalBuilder; mb: MethodBuilder; imb: MethodBuilder;
      ae: TExprNode; wlS, wlI, rm: MethodInfo;
      et, at2: TVarType; fb: FieldBuilder; cn: string; vtVar: TVarType;
      eL, endL, ckL, bdL: &Label;
      extType: System.Type; propInfo: PropertyInfo; extFld: System.Reflection.FieldInfo;
      setter, emi: MethodInfo; qfb: FieldBuilder; qTargetType: System.Type;
      evs: TEventSubscribeStmtNode; evInfo: EventInfo; delCtor: ConstructorInfo;
    begin
      fEmitDepth:=fEmitDepth+1;
      if fEmitDepth>5000 then
        raise new Exception('[진단] EmitStatement 재귀 깊이 초과(5000) — 폭주 의심 노드: '+s.GetType.Name);
      try
      // [Stage 75] Readln; → Console.ReadLine() 호출 후 반환값 버림.
      // Readln(v) → Console.ReadLine() 결과를 문자열 변수 v에 대입.
      if s is TReadlnStmtNode then
      begin
        var rln := TReadlnStmtNode(s);
        var rlnM: MethodInfo := typeof(Console).GetMethod('ReadLine', System.Type.EmptyTypes);
        aIL.Emit(OpCodes.Call, rlnM);
        if rln.Arg = nil then
          aIL.Emit(OpCodes.Pop) // 반환값(string) 버림 — 순수 Enter 대기
        else if rln.Arg is TVarRefNode then
        begin
          var vname := TVarRefNode(rln.Arg).VarName;
          if fLocalScope.Has(vname) then
            aIL.Emit(OpCodes.Stloc, fLocalScope.GetLoc(vname))
          else if fGlobalScope.Has(vname) then
            aIL.Emit(OpCodes.Stloc, fGlobalScope.GetLoc(vname))
          else
            aIL.Emit(OpCodes.Pop); // 알 수 없는 변수 — 버림
        end
        else
          aIL.Emit(OpCodes.Pop); // 복잡한 식 대상 — 현재는 버림
      end

      else if s is TWritelnStringStmtNode then
      begin
        ws:=TWritelnStringStmtNode(s);
        wlS:=typeof(Console).GetMethod('WriteLine',[typeof(string)]);
        aIL.Emit(OpCodes.Ldstr, ws.Text); aIL.Emit(OpCodes.Call, wlS);
      end

      else if s is TWritelnExprStmtNode then
      begin
        we:=TWritelnExprStmtNode(s); et:=InferType(we.Arg);
        if et=vtString then
        begin
          wlS:=typeof(Console).GetMethod('WriteLine',[typeof(string)]);
          EmitExpr(aIL, we.Arg); aIL.Emit(OpCodes.Call, wlS);
        end
        else if et=vtBoolean then
        begin
          wlS:=typeof(Console).GetMethod('WriteLine',[typeof(boolean)]);
          EmitExpr(aIL, we.Arg); aIL.Emit(OpCodes.Call, wlS);
        end
        // [Phase 1] 새 타입별 Writeln 오버로드
        else if et=vtReal then
        begin
          EmitExpr(aIL, we.Arg);
          aIL.Emit(OpCodes.Call, typeof(Console).GetMethod('WriteLine',[typeof(double)]));
        end
        else if et=vtChar then
        begin
          EmitExpr(aIL, we.Arg);
          aIL.Emit(OpCodes.Call, typeof(Console).GetMethod('WriteLine',[typeof(char)]));
        end
        else if et=vtInt64 then
        begin
          EmitExpr(aIL, we.Arg);
          aIL.Emit(OpCodes.Call, typeof(Console).GetMethod('WriteLine',[typeof(int64)]));
        end
        // [Stage 71] Writeln(x)에서 x: T(제네릭 매개변수)이면 컴파일 시점에는 실제 타입(정수/문자열/
        // bool 등 무엇이든)을 알 수 없다 — open generic 메서드 본문은 모든 T에 대해 딱 한 번만
        // 컴파일되기 때문이다. box는 T가 값 타입이면 실제 박싱을, 참조 타입이면 아무 일도 하지
        // 않는(no-op) CLR의 특별 규칙이 있어 이 상황에 정확히 들어맞는다 — box한 뒤 WriteLine(object)
        // 오버로드를 호출하면 어떤 T가 오더라도 항상 올바르게 동작한다.
        else if et=vtGeneric then
        begin
          EmitExpr(aIL, we.Arg);
          aIL.Emit(OpCodes.Box, GetGenericExprClrType(we.Arg));
          aIL.Emit(OpCodes.Call, typeof(Console).GetMethod('WriteLine',[typeof(System.Object)]));
        end
        else
        begin
          wlI:=typeof(Console).GetMethod('WriteLine',[typeof(integer)]);
          EmitExpr(aIL, we.Arg); aIL.Emit(OpCodes.Call, wlI);
        end;
      end

      // [Stage 90] writeln(a, b, c, ...) — 마지막 인자 전까지는 Console.Write(줄바꿈 없음)로
      // 이어붙이고, 마지막 인자만 Console.WriteLine으로 내보내 표준 Pascal writeln과 같은
      // "다 이어붙인 뒤 한 번 줄바꿈" 동작을 만든다.
      else if s is TWritelnArgsStmtNode then
      begin
        var wa90:=TWritelnArgsStmtNode(s);
        for var wi90:=0 to wa90.Args.Count-1 do
          EmitWriteArg(aIL, wa90.Args[wi90], wi90=wa90.Args.Count-1);
      end

      else if s is TResultAssignStmtNode then
      begin
        // [Stage 57] Result := 'a'; 에서 함수 반환형이 string이면 char 리터럴을
        // 문자열로 승격해야 한다 (fResultType이 함수 선언의 반환 타입을 들고 있다).
        ra:=TResultAssignStmtNode(s);
        if fResultLocal=nil then raise new Exception('Result는 함수 안에서만');
        EmitValueForVType(aIL, ra.ValueExpr, fResultType); aIL.Emit(OpCodes.Stloc, fResultLocal);
      end

      else if s is TFieldAssignStmtNode then
      begin
        fas:=TFieldAssignStmtNode(s);
        if fas.Qualifier<>'' then
        begin
          // Qualifier.FieldName := 식  (예: Button1.Text := '...')
          // Qualifier는 현재 클래스의 필드인 경우가 가장 흔하다 (지역/전역 변수도 지원).
          if TryFindFieldBuilder(fCurClassName, fas.Qualifier, qfb) then
          begin
            aIL.Emit(OpCodes.Ldarg_0);
            aIL.Emit(OpCodes.Ldfld, qfb);
            qTargetType:=qfb.FieldType;
            if fas.QualifierCastType<>'' then
            begin
              qTargetType:=ResolveExternalType(fas.QualifierCastType);
              aIL.Emit(OpCodes.Castclass, qTargetType);
            end;
            EmitPropertyOrFieldSet(aIL, qTargetType, fas.FieldName, fas.ValueExpr);
          end
          else if (fLocalScope.Has(fas.Qualifier) or fGlobalScope.Has(fas.Qualifier))
                  and (fLocalScope.HasClrType(fas.Qualifier) or fGlobalScope.HasClrType(fas.Qualifier)) then
          begin
            // 매개변수/지역변수가 외부(객체) 타입인 경우 — Reflection 기반 처리
            if fLocalScope.Has(fas.Qualifier) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(fas.Qualifier))
            else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(fas.Qualifier)); // [전역 var 버그 수정]
            if fLocalScope.HasClrType(fas.Qualifier) then qTargetType:=fLocalScope.GetClrType(fas.Qualifier)
            else qTargetType:=fGlobalScope.GetClrType(fas.Qualifier);
            if fas.QualifierCastType<>'' then
            begin
              qTargetType:=ResolveExternalType(fas.QualifierCastType);
              aIL.Emit(OpCodes.Castclass, qTargetType);
            end;
            EmitPropertyOrFieldSet(aIL, qTargetType, fas.FieldName, fas.ValueExpr);
          end
          else if fLocalScope.Has(fas.Qualifier) or fGlobalScope.Has(fas.Qualifier) then
          begin
            cn:=GetVarClassName(fas.Qualifier);
            // [Stage 62] cn이 레코드(값 타입)면 Stfld가 값이 아니라 주소를 요구하므로 Ldloca를 쓴다.
            if fLocalScope.Has(fas.Qualifier) then
            begin
              if fRecordNames.Contains(cn) then aIL.Emit(OpCodes.Ldloca, fLocalScope.GetLoc(fas.Qualifier))
              else aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(fas.Qualifier));
            end
            else
            begin
              if fRecordNames.Contains(cn) then aIL.Emit(OpCodes.Ldloca, fGlobalScope.GetLoc(fas.Qualifier))
              else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(fas.Qualifier));
            end;
            if fBuiltTypes.ContainsKey(cn) then qTargetType:=fBuiltTypes[cn]
            else if fTypeBuilders.ContainsKey(cn) then qTargetType:=fTypeBuilders[cn]
            else raise new Exception('알 수 없는 타입 "'+cn+'" (변수 "'+fas.Qualifier+'")');
            if fas.QualifierCastType<>'' then
            begin
              qTargetType:=ResolveExternalType(fas.QualifierCastType);
              aIL.Emit(OpCodes.Castclass, qTargetType);
            end;
            EmitPropertyOrFieldSet(aIL, qTargetType, fas.FieldName, fas.ValueExpr);
          end
          else if fas.Qualifier.Contains('.') then
          begin
            // [Stage 99] fas.Qualifier가 "formChild2.DockPanel"처럼 점(.)을 포함한 실제 체인이면
            // (필드/변수로 시작해서 프로퍼티를 타고 내려가는 경우), 통째로 외부 정적 타입 이름인 줄
            // 알고 ResolveExternalType에 그대로 넘기면 안 된다(예: "외부 타입
            // 'formChild2.DockPanel'을(를) 찾을 수 없습니다" 에러). EmitQualifierChainLoad로
            // 체인을 한 세그먼트씩 제대로 따라가며 로드한 뒤, 그 결과 타입에 최종
            // 필드/프로퍼티를 설정한다.
            var _chainSegs99:=new List<string>(fas.Qualifier.Split('.'));
            EmitQualifierChainLoad(aIL, _chainSegs99, qTargetType);
            if fas.QualifierCastType<>'' then
            begin
              qTargetType:=ResolveExternalType(fas.QualifierCastType);
              aIL.Emit(OpCodes.Castclass, qTargetType);
            end;
            EmitPropertyOrFieldSet(aIL, qTargetType, fas.FieldName, fas.ValueExpr);
          end
          else
            EmitStaticPropertyOrFieldSet(aIL, ResolveExternalType(fas.Qualifier), fas.FieldName, fas.ValueExpr);
        end
        else
        // self.fieldName := 식  (지역 필드) 또는 외부 상속 타입의 속성/필드 설정
        // [Stage 57] self.field := 'a'; / 상속받은 외부 속성·필드 대입에서도 필드/속성/
        // setter의 실제 CLR 타입이 string이면 char 리터럴을 문자열로 승격해야 한다.
        // EmitArgForParamType이 이미 (paramType=typeof(string) and TCharLiteralNode) 규칙을
        // 갖고 있으므로 그대로 재사용한다.
        if TryFindFieldBuilder(fCurClassName, fas.FieldName, fb) then
        begin
          aIL.Emit(OpCodes.Ldarg_0); // self
          EmitArgForParamType(aIL, fas.ValueExpr, fb.FieldType);
          aIL.Emit(OpCodes.Stfld, fb);
        end
        else
        begin
          extType:=FindExternalAncestorType(fCurClassName);
          if extType=nil then
            raise new Exception('필드/속성을 찾을 수 없음: '+fCurClassName+'.'+fas.FieldName);
          propInfo:=SafeGetProperty(extType, fas.FieldName);
          if propInfo<>nil then
          begin
            setter:=propInfo.GetSetMethod;
            if setter=nil then
              raise new Exception('속성 "'+extType.FullName+'.'+fas.FieldName+'"에 setter가 없습니다 (읽기 전용).');
            aIL.Emit(OpCodes.Ldarg_0);
            EmitArgForParamType(aIL, fas.ValueExpr, propInfo.PropertyType);
            aIL.Emit(OpCodes.Callvirt, setter);
          end
          else
          begin
            extFld:=extType.GetField(fas.FieldName);
            if extFld=nil then
              raise new Exception('외부 타입 "'+extType.FullName+'"에 필드/속성 "'+fas.FieldName+'"가 없습니다.');
            aIL.Emit(OpCodes.Ldarg_0);
            EmitArgForParamType(aIL, fas.ValueExpr, extFld.FieldType);
            aIL.Emit(OpCodes.Stfld, extFld);
          end;
        end;
      end

      // [Stage 48] var x := 식; — 문장 중간에서 새 지역 변수를 선언과 동시에 대입.
      // 미리 만들어둔 "var 섹션" 루프를 거치지 않으므로, 여기서 그때그때 타입을 추론해
      // DeclareLocal 한다 (IL에서는 메서드 어디서든 DeclareLocal을 호출해도 된다).
      else if s is TInlineVarStmtNode then
      begin
        var ivs:=TInlineVarStmtNode(s);
        var ivVt: TVarType;
        var ivClrType: System.Type;
        var ivClassName: string; var ivIsExternal: boolean;
        ivClassName:=''; ivIsExternal:=false;
        if ivs.HasExplicitType then
        begin
          // [자기컴파일] "var x: Type;" / "var x: Type := 식;" — 타입이 명시돼 있으므로
          // ValueExpr을 굳이 추론하지 않고, 지역변수 선언(TVarDecl) 경로가 이미 쓰던
          // ResolveLocalVarClrType을 그대로 재사용해 정확한 CLR 타입을 얻는다.
          ivVt:=ivs.ExplicitVarType; ivClassName:=ivs.ExplicitClassName; ivIsExternal:=ivs.ExplicitIsExternal;
          var ivExplicitDecl:=new TVarDecl(ivs.VarName, ivVt, ivClassName, ivIsExternal);
          ivClrType:=ResolveLocalVarClrType(ivExplicitDecl);
        end
        else
        begin
        ivVt:=InferType(ivs.ValueExpr);
        if ivs.ValueExpr is TNewObjectExprNode then
        begin
          // new Type(...) 표현식이면 그 노드가 이미 정확한 클래스명/외부 여부를 들고 있다 —
          // InferType은 vtObject라는 것만 알려주므로 여기서 직접 가져오는 게 가장 정확하다.
          var ivNeo:=TNewObjectExprNode(ivs.ValueExpr);
          ivClassName:=ivNeo.ClassName; ivIsExternal:=ivNeo.IsExternalType;
          if ivIsExternal then ivClrType:=ResolveExternalType(ivClassName)
          else if fBuiltTypes.ContainsKey(ivClassName) then ivClrType:=fBuiltTypes[ivClassName]
          else if fTypeBuilders.ContainsKey(ivClassName) then ivClrType:=fTypeBuilders[ivClassName]
          else ivClrType:=typeof(System.Object);
        end
        else if ivs.ValueExpr is TExternalCastExprNode then
        begin
          // [버그수정] TabControl(sender) 같은 외부타입 캐스트식은 InferType이
          // vtObject라는 것만 알려줄 뿐 실제 캐스트 대상 타입(TargetType)은 모른다.
          // 이 분기가 없으면 아래 else 폴백(VTC(ivVt,''))이 System.Object로
          // DeclareLocal 해버려서, 이후 "tabControl.SelectedTab"처럼 캐스트 결과에
          // 멤버 접근을 하면 System.Object에 그 멤버가 없다고 터진다.
          var ivExtCast:=TExternalCastExprNode(ivs.ValueExpr);
          ivClrType:=ResolveExternalType(ivExtCast.TargetType);
          ivIsExternal:=true;
        end
        else if ivs.ValueExpr is TMethodCallExprNode then
        begin
          // [Stage 76 버그수정 #3] 외부 메서드 호출(예: Image.FromFile) 결과를 담는 지역
          // 변수는, 실제 반환 타입을 찾을 수 있으면 그 타입으로, 못 찾으면(예: 우리가 만든
          // 클래스의 메서드거나 판별 불가) 기존과 동일하게 VTC 폴백을 쓴다.
          var ivResolvedT:=TryResolveMethodCallClrType(TMethodCallExprNode(ivs.ValueExpr));
          if ivResolvedT<>nil then
          begin
            ivClrType:=ivResolvedT; ivIsExternal:=true;
            // InferType(TMethodCallExprNode)는 string/bool/real/char/int64 외엔 항상
            // vtInteger를 돌려주도록 되어 있어(설계상 스칼라 판별용), 여기서 바로잡지
            // 않으면 아래의 "ivVt=vtObject일 때만 SetClrType" 게이트를 못 넘고, 이 변수가
            // 나중에 다른 외부 메서드의 인자로 오버로드 판별에 쓰일 때 정수로 오인된다.
            // 지역 슬롯 자체는 이미 ivClrType(정확한 타입)으로 선언되므로 값 자체는
            // 안전하지만, 타입 태그를 실제(vtObject)로 맞춰줘야 이후 조회들이 일관된다.
            ivVt:=vtObject;
          end
          else ivClrType:=VTC(ivVt, '');
        end
        else
          ivClrType:=VTC(ivVt, '');
        end; // [자기컴파일] HasExplicitType else 종료
        var ivLoc:=aIL.DeclareLocal(ivClrType);
        fLocalScope.Declare(ivs.VarName, ivLoc, ivVt);
        if (ivVt=vtObject) or (ivVt=vtInterface) then
        begin
          if ivIsExternal then fLocalScope.SetClrType(ivs.VarName, ivClrType)
          else if (ivClassName<>'') and (fTypeBuilders.ContainsKey(ivClassName) or fBuiltTypes.ContainsKey(ivClassName)) then
            fLocalScope.SetClassName(ivs.VarName, ivClassName)
          else
            fLocalScope.SetClrType(ivs.VarName, ivClrType);
        end;
        // [자기컴파일] "var x: Type;" (초기화식 없음)이면 대입을 생략한다 — CLR 로컬은
        // 기본적으로 0/false/nil로 초기화되므로(.locals init) Pascal의 "선언만" 의미와 일치한다.
        if ivs.ValueExpr<>nil then
        begin
          EmitExpr(aIL, ivs.ValueExpr);
          aIL.Emit(OpCodes.Stloc, ivLoc);
        end;
      end

      else if s is TAssignStmtNode then
      begin
        // [Stage 57] x := 'a'; 에서 x가 string 변수면, EmitExpr이 'a'를 문자 코드로
        // 스택에 올리기 전에 목표 타입(vtString)을 먼저 확인해 Ldstr로 로드해야 한다.
        // Stloc은 그대로 유지되므로, "어떤 값을 로드할지"만 EmitValueForVType으로 바꾼다.
        asg:=TAssignStmtNode(s);
        if fLocalScope.Has(asg.VarName) then
        begin
          EmitValueForVType(aIL, asg.ValueExpr, fLocalScope.GetVType(asg.VarName));
          aIL.Emit(OpCodes.Stloc, fLocalScope.GetLoc(asg.VarName));
        end
        else if fGlobalScope.Has(asg.VarName) then
        begin
          EmitValueForVType(aIL, asg.ValueExpr, fGlobalScope.GetVType(asg.VarName));
          aIL.Emit(OpCodes.Stloc, fGlobalScope.GetLoc(asg.VarName));
        end
        else raise new Exception('선언되지 않은 변수 "'+asg.VarName+'"');
      end

      else if s is TMethodCallStmtNode then
      begin
        mcs:=TMethodCallStmtNode(s);
        // [Stage 76] "MainMenu.Items.Add(x)" 처럼 한정자 자체가 점(.)으로 연결된 체인이면
        // (지역변수/필드.프로퍼티.프로퍼티...) 아래의 단일 세그먼트 판별 분기들보다 먼저
        // 처리한다 — 안 그러면 마지막 else의 "외부 정적 타입"으로 오인되어
        // ResolveExternalType("MainMenu.Items") 같은 존재하지 않는 타입 조회로 실패한다.
        if (mcs.ObjName<>'') and (mcs.ObjName.IndexOf('.')>=0) and (mcs.ObjCastType='')
           and IsChainStartSegment(SplitByDot(mcs.ObjName)[0]) then
        begin
          var chainSegs:=SplitByDot(mcs.ObjName);
          var chainType: System.Type;
          EmitQualifierChainLoad(aIL, chainSegs, chainType);

          // [Stage 79 수정] chainType이 아직 CreateType() 전인 로컬 클래스의 TypeBuilder이면
          // GetProperty가 NotSupportedException을 던진다 (예: f.Editor.OpenFile(...)에서
          // Editor 필드 타입 TCodeEditorPanel이 로컬 클래스인 경우). 2689번째 줄 근처의
          // 단일 필드 분기에 적용한 것과 동일한 우회를 여기(다중 세그먼트 체인)에도 적용한다.
          var chainLocalCls:string:='';
          if chainType is TypeBuilder then
            foreach var tbKvpChain in fTypeBuilders do
              if tbKvpChain.Value = TypeBuilder(chainType) then
              begin chainLocalCls:=tbKvpChain.Key; break; end;

          if chainLocalCls<>'' then
          begin
            var imbChain:=FindInstanceMethod(chainLocalCls, mcs.MethodName);
            if imbChain<>nil then
            begin
              EmitArgsCoerced(aIL, mcs.Args, FindInstanceMethodParamTypes(chainLocalCls, mcs.MethodName));
              aIL.Emit(OpCodes.Callvirt, imbChain);
              if imbChain.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end
            else if fFieldBuilders.ContainsKey(chainLocalCls) and fFieldBuilders[chainLocalCls].ContainsKey(mcs.MethodName) then
            begin
              aIL.Emit(OpCodes.Ldfld, fFieldBuilders[chainLocalCls][mcs.MethodName]);
              aIL.Emit(OpCodes.Pop);
            end
            else
              raise new Exception('로컬 클래스 "'+chainLocalCls+'"에 메서드/필드 "'+mcs.MethodName+'"가 없습니다 (경로: '+mcs.ObjName+'.'+mcs.MethodName+')');
          end
          else
          begin
            var _getPC:=SafeGetProperty(chainType, mcs.MethodName);
            if (mcs.Args.Count=0) and (_getPC<>nil) and (_getPC.GetGetMethod<>nil) then
            begin
              aIL.Emit(OpCodes.Callvirt, _getPC.GetGetMethod);
              aIL.Emit(OpCodes.Pop);
            end
            else
            begin
              var _emiC:=ResolveMethodByArity(chainType, mcs.MethodName, mcs.Args, false);
              if _emiC=nil then
                raise new Exception('타입 "'+chainType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: '+mcs.ObjName+'.'+mcs.MethodName+')');
              var _emiCParams:=_emiC.GetParameters;
              for var _emiCAi:=0 to mcs.Args.Count-1 do
                EmitArgForParamType(aIL, mcs.Args[_emiCAi], _emiCParams[_emiCAi].ParameterType);
              aIL.Emit(OpCodes.Callvirt, _emiC);
              if _emiC.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end;
          end;
        end
        else if mcs.ObjName='' then
        begin
          // [버그수정] Halt / Halt(exitCode) — 파스칼 내장 프로시저. Writeln/Readln/Exit와
          // 달리 전용 AST 노드가 없어서 지금까지는 일반 메서드 호출로 파싱되어 여기
          // "암시적 self 호출" 분기로 흘러들었고, Form1(및 조상 타입 Form)에 "Halt"라는
          // 메서드가 없어 "외부 타입 ... 에 메서드 Halt가 없습니다" 예외로 이어졌다.
          // System.Environment.Exit(int32)로 매핑해 프로그램을 즉시 종료시킨다.
          if mcs.MethodName.ToUpper()='HALT' then
          begin
            if mcs.Args.Count>0 then
              EmitArgForParamType(aIL, mcs.Args[0], typeof(integer))
            else
              aIL.Emit(OpCodes.Ldc_I4_0);
            aIL.Emit(OpCodes.Call, typeof(System.Environment).GetMethod('Exit', [typeof(integer)]));
          end
          else
          begin
          // 암시적 self 호출: Show; Close(); 등 — 지역 메서드 우선, 없으면 외부 상속 타입에서 탐색
          aIL.Emit(OpCodes.Ldarg_0); // self
          if TryFindInstanceMethod(fCurClassName, mcs.MethodName, imb) then
          begin
            EmitArgsCoerced(aIL, mcs.Args, FindInstanceMethodParamTypes(fCurClassName, mcs.MethodName));
            aIL.Emit(OpCodes.Callvirt, imb);
            if imb.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            extType:=FindExternalAncestorType(fCurClassName);
            if extType=nil then
              raise new Exception('알 수 없는 메서드 "'+fCurClassName+'.'+mcs.MethodName+'"');
            emi:=ResolveMethodByArity(extType, mcs.MethodName, mcs.Args, false);
            if emi=nil then
              raise new Exception('외부 타입 "'+extType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
            var _emiParams0:=emi.GetParameters;
            for var _emiAi0:=0 to mcs.Args.Count-1 do
              EmitArgForParamType(aIL, mcs.Args[_emiAi0], _emiParams0[_emiAi0].ParameterType);
            aIL.Emit(OpCodes.Callvirt, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
          end;
        end
        // [버그 수정] "Result.Add(x);"처럼 함수 자신의 반환값(Result) 위에서 메서드를 호출하는
        // 문장(식이 아니라 문장 위치) — EmitExpr/EmitQualifierChainLoad 쪽은 'Result' 세그먼트를
        // fResultLocal로 이미 특별 취급하지만, TMethodCallStmtNode 쪽엔 이 분기가 없었다. 그래서
        // Result는 fLocalScope/fGlobalScope 어디에도 없으니 모든 분기를 다 지나쳐 맨 아래
        // "외부 정적 타입" 폴백까지 흘러가 ResolveExternalType('Result')가 "외부 타입 Result를
        // 찾을 수 없습니다"로 실패했다. fLocalScope/fGlobalScope 분기(바로 아래)와 동일한 패턴을
        // fResultLocal에 대해 그대로 적용한다.
        else if (mcs.ObjName='Result') and (fResultLocal<>nil) then
        begin
          qTargetType:=fResultLocal.LocalType;
          aIL.Emit(OpCodes.Ldloc, fResultLocal);
          if mcs.ObjCastType<>'' then
          begin
            qTargetType:=ResolveExternalType(mcs.ObjCastType);
            aIL.Emit(OpCodes.Castclass, qTargetType);
          end;
          var _getPR:=SafeGetProperty(qTargetType, mcs.MethodName);
          if (mcs.Args.Count=0) and (_getPR<>nil) and (_getPR.GetGetMethod<>nil) then
          begin
            aIL.Emit(OpCodes.Callvirt, _getPR.GetGetMethod);
            aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            var emiR:=ResolveMethodByArity(qTargetType, mcs.MethodName, mcs.Args, false);
            if emiR=nil then
              raise new Exception('타입 "'+qTargetType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: Result.'+mcs.MethodName+')');
            var _emiParamsR:=emiR.GetParameters;
            for var _emiAiR:=0 to mcs.Args.Count-1 do
              EmitArgForParamType(aIL, mcs.Args[_emiAiR], _emiParamsR[_emiAiR].ParameterType);
            aIL.Emit(OpCodes.Callvirt, emiR);
            if emiR.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
        end
        else if (fLocalScope.Has(mcs.ObjName) or fGlobalScope.Has(mcs.ObjName))
                and (fLocalScope.HasClrType(mcs.ObjName) or fGlobalScope.HasClrType(mcs.ObjName)) then
        begin
          // sender.Focus(); 같은, 외부(객체) 타입 매개변수/지역변수를 통한 호출.
          if fLocalScope.HasClrType(mcs.ObjName) then qTargetType:=fLocalScope.GetClrType(mcs.ObjName)
          else qTargetType:=fGlobalScope.GetClrType(mcs.ObjName);
          // [버그 수정 - Stage 77] EmitExpr의 TMethodCallExprNode 쪽과 동일한 이유 —
          // qTargetType이 값 타입이면 Ldloc(값)+Callvirt 대신 Ldloca(주소)+Call을 써야
          // NullReferenceException(값의 원시 비트를 객체 포인터로 오인)을 피한다.
          var _isValTypeS:=(mcs.ObjCastType='') and qTargetType.IsValueType;
          if _isValTypeS then
          begin
            if fLocalScope.Has(mcs.ObjName) then aIL.Emit(OpCodes.Ldloca, fLocalScope.GetLoc(mcs.ObjName))
            else aIL.Emit(OpCodes.Ldloca, fGlobalScope.GetLoc(mcs.ObjName));
          end
          else
          begin
            if fLocalScope.Has(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(mcs.ObjName))
            else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(mcs.ObjName)); // [전역 var 버그 수정]
          end;
          if mcs.ObjCastType<>'' then
          begin
            qTargetType:=ResolveExternalType(mcs.ObjCastType);
            aIL.Emit(OpCodes.Castclass, qTargetType);
          end;
          var _getP2:=SafeGetProperty(qTargetType, mcs.MethodName);
          if (mcs.Args.Count=0) and (_getP2<>nil) and (_getP2.GetGetMethod<>nil) then
          begin
            if _isValTypeS then aIL.Emit(OpCodes.Call, _getP2.GetGetMethod)
            else aIL.Emit(OpCodes.Callvirt, _getP2.GetGetMethod);
            aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            emi:=ResolveMethodByArity(qTargetType, mcs.MethodName, mcs.Args, false);
            if emi=nil then
              raise new Exception('타입 "'+qTargetType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
            var _emiParams2:=emi.GetParameters;
            for var _emiAi2:=0 to mcs.Args.Count-1 do
              EmitArgForParamType(aIL, mcs.Args[_emiAi2], _emiParams2[_emiAi2].ParameterType);
            if _isValTypeS then aIL.Emit(OpCodes.Call, emi)
            else aIL.Emit(OpCodes.Callvirt, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
        end
        else if fLocalScope.Has(mcs.ObjName) or fGlobalScope.Has(mcs.ObjName)
                or fGlobalConstFields.ContainsKey(mcs.ObjName) then  // [Stage 96] 전역 const도 허용
        begin
          // c.Init(10) → Ldloc c + args + Call
          cn:=GetVarClassName(mcs.ObjName);
          vtVar:=GetVarType(mcs.ObjName);
          if fLocalScope.Has(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(mcs.ObjName))
          else if fGlobalScope.Has(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(mcs.ObjName))
          else aIL.Emit(OpCodes.Ldsfld, fGlobalConstFields[mcs.ObjName]);  // [Stage 96] 전역 const
          if cn='' then raise new Exception('알 수 없는 메서드 "'+cn+'.'+mcs.MethodName+'"');
          // 인터페이스 타입 변수면 인터페이스 메서드로, 아니면 클래스 상속 체인에서 탐색
          // (Stage 10에서는 fInstanceMethods[cn] 직접 조회 + Call만 사용해 상속받은
          //  메서드 호출 시 실패할 수 있었는데, FindInstanceMethod + Callvirt로 통일)
          if vtVar=vtInterface then
          begin
            var imi:=FindInterfaceMethod(cn, mcs.MethodName);
            var _imiParams2:=imi.GetParameters;
            for var _imiAi2:=0 to mcs.Args.Count-1 do
              EmitArgForParamType(aIL, mcs.Args[_imiAi2], _imiParams2[_imiAi2].ParameterType);
            aIL.Emit(OpCodes.Callvirt, imi);
            if imi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            // [버그수정] cn(예: TAboutBox)이 자체적으로 mcs.MethodName(예: ShowDialog)을
            // 정의하지 않고 외부 조상 타입(Form 등)에서 상속받은 경우, FindInstanceMethod는
            // 로컬(파스칼) 클래스 계층(fClasses의 ParentName 체인)만 훑고 예외를 던진다 — "암시적 self
            // 호출" 분기(3144번째 줄 부근)에서 이미 쓰는 것과 동일한 외부 조상 타입 폴백을
            // 여기(지역변수를 통한 호출)에도 추가한다.
            if TryFindInstanceMethod(cn, mcs.MethodName, imb) then
            begin
            if mcs.GenericArgTypes.Count>0 then
            begin
              // [Stage 74] obj.Method<T,U>(...) — 명시적 타입 인자로 닫은 뒤 그 닫힌 메서드를 호출한다.
              var closedTypes74s:=new System.Type[mcs.GenericArgTypes.Count];
              for var gi74s:=0 to mcs.GenericArgTypes.Count-1 do
                closedTypes74s[gi74s]:=VTC(mcs.GenericArgTypes[gi74s], mcs.GenericArgClassNames[gi74s]);
              var closedMI74s:=imb.MakeGenericMethod(closedTypes74s);
              EmitArgsCoerced(aIL, mcs.Args, nil);
              aIL.Emit(OpCodes.Callvirt, closedMI74s);
              if closedMI74s.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end
            else
            begin
              EmitArgsCoerced(aIL, mcs.Args, FindInstanceMethodParamTypes(cn, mcs.MethodName));
              aIL.Emit(OpCodes.Callvirt, imb);
              // void 메서드가 아닌 경우 반환값 버리기
              if imb.ReturnType<>typeof(System.Void) then
                aIL.Emit(OpCodes.Pop);
            end;
            end
            else
            begin
              var cnExtType:=FindExternalAncestorType(cn);
              if cnExtType=nil then
                raise new Exception('알 수 없는 메서드 "'+cn+'.'+mcs.MethodName+'"');
              var cnEmi:=ResolveMethodByArity(cnExtType, mcs.MethodName, mcs.Args, false);
              if cnEmi=nil then
                raise new Exception('외부 타입 "'+cnExtType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
              var cnEmiParams:=cnEmi.GetParameters;
              for var cnEmiAi:=0 to mcs.Args.Count-1 do
                EmitArgForParamType(aIL, mcs.Args[cnEmiAi], cnEmiParams[cnEmiAi].ParameterType);
              aIL.Emit(OpCodes.Callvirt, cnEmi);
              if cnEmi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end;
          end;
        end
        else if TryFindFieldBuilder(fCurClassName, mcs.ObjName, qfb) then
        begin
          // Button1.Focus(); 처럼 필드를 통한 메서드 호출. 인자 0개면 프로퍼티
          // 게터일 가능성도 먼저 확인한다 (문장 위치에서 값은 버림).
          aIL.Emit(OpCodes.Ldarg_0);
          aIL.Emit(OpCodes.Ldfld, qfb);
          qTargetType:=qfb.FieldType;
          if mcs.ObjCastType<>'' then
          begin
            qTargetType:=ResolveExternalType(mcs.ObjCastType);
            aIL.Emit(OpCodes.Castclass, qTargetType);
          end;
          // [Stage 78 수정] qTargetType이 로컬(사용자 정의) 클래스의 TypeBuilder이면
          // 아직 CreateType() 전이라 GetProperty가 NotSupportedException을 던진다
          // (예: Explorer: TProjectExplorer 필드에 대해 Explorer.LoadFolder(...) 호출).
          // fTypeBuilders를 역방향 조회해 클래스명을 찾고, 그 경우엔 Reflection
          // (GetProperty/ResolveMethodByArity) 대신 메타데이터 기반 경로
          // (FindInstanceMethod/FindInstanceMethodParamTypes)로 처리한다.
          var localClsNameFB:string:='';
          if qTargetType is TypeBuilder then
            foreach var tbKvpFB in fTypeBuilders do
              if tbKvpFB.Value = TypeBuilder(qTargetType) then
              begin localClsNameFB:=tbKvpFB.Key; break; end;

          if localClsNameFB<>'' then
          begin
            var imbFB: MethodBuilder;
            if TryFindInstanceMethod(localClsNameFB, mcs.MethodName, imbFB) then
            begin
              EmitArgsCoerced(aIL, mcs.Args, FindInstanceMethodParamTypes(localClsNameFB, mcs.MethodName));
              aIL.Emit(OpCodes.Callvirt, imbFB);
              if imbFB.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end
            else if fFieldBuilders.ContainsKey(localClsNameFB) and fFieldBuilders[localClsNameFB].ContainsKey(mcs.MethodName) then
            begin
              // 인자 없는 필드 읽기 (문장 위치이므로 결과값은 버림)
              aIL.Emit(OpCodes.Ldfld, fFieldBuilders[localClsNameFB][mcs.MethodName]);
              aIL.Emit(OpCodes.Pop);
            end
            else if FindExternalAncestorType(localClsNameFB)<>nil then
            begin
              // [Stage 98] FormChild(로컬 클래스) : DockContent(외부 조상, WeifenLuo)처럼, 로컬
              // 클래스가 상속만 받고 오버라이드하지 않은 외부 조상 메서드(예:
              // formChild1.Show(dockPanelMain, DockState.DockLeft))는 fInstanceMethods/
              // fFieldBuilders 어디에도 없어서 위 두 분기가 다 실패해 "알 수 없는 메서드"로
              // 잘못 죽는다. 객체 참조는 이미 스택에 로드돼 있으니(위의 Ldarg_0; Ldfld qfb 등),
              // 외부 조상 타입에서 리플렉션으로 실제 메서드를 찾아 그대로 호출한다
              // (아래쪽 "self가 상속한 외부 프로퍼티" 분기와 동일한 방식).
              var _extAncFB94:=FindExternalAncestorType(localClsNameFB);
              var _getPFB94:=SafeGetProperty(_extAncFB94, mcs.MethodName);
              if (mcs.Args.Count=0) and (_getPFB94<>nil) and (_getPFB94.GetGetMethod<>nil) then
              begin
                aIL.Emit(OpCodes.Callvirt, _getPFB94.GetGetMethod);
                aIL.Emit(OpCodes.Pop);
              end
              else
              begin
                var _emiFB94:=ResolveMethodByArity(_extAncFB94, mcs.MethodName, mcs.Args, false);
                if _emiFB94=nil then
                  raise new Exception('로컬 클래스 "'+localClsNameFB+'"(외부 조상 "'+_extAncFB94.FullName+'")에 메서드/필드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
                var _emiParamsFB94:=_emiFB94.GetParameters;
                for var _emiAiFB94:=0 to mcs.Args.Count-1 do
                  EmitArgForParamType(aIL, mcs.Args[_emiAiFB94], _emiParamsFB94[_emiAiFB94].ParameterType);
                aIL.Emit(OpCodes.Callvirt, _emiFB94);
                if _emiFB94.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
              end;
            end
            else
              raise new Exception('로컬 클래스 "'+localClsNameFB+'"에 메서드/필드 "'+mcs.MethodName+'"가 없습니다.');
          end
          else
          begin
            var _getP:=SafeGetProperty(qTargetType, mcs.MethodName);
            if (mcs.Args.Count=0) and (_getP<>nil) and (_getP.GetGetMethod<>nil) then
            begin
              aIL.Emit(OpCodes.Callvirt, _getP.GetGetMethod);
              aIL.Emit(OpCodes.Pop);
            end
            else
            begin
              emi:=ResolveMethodByArity(qTargetType, mcs.MethodName, mcs.Args, false);
              if emi=nil then
                raise new Exception('타입 "'+qTargetType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
              var _emiParams3:=emi.GetParameters;
              for var _emiAi3:=0 to mcs.Args.Count-1 do
                EmitArgForParamType(aIL, mcs.Args[_emiAi3], _emiParams3[_emiAi3].ParameterType);
              aIL.Emit(OpCodes.Callvirt, emi);
              if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end;
          end;
        end
        else if (FindExternalAncestorType(fCurClassName)<>nil)
                and (SafeGetProperty(FindExternalAncestorType(fCurClassName), mcs.ObjName)<>nil) then
        begin
          // [Stage 68 재확인] Controls.Add(Button1); 처럼, 한정자(qualifier) 자체가
          // 로컬변수/필드가 아니라 self가 상속받은 외부 타입(Form 등)의 프로퍼티인 경우.
          // self를 로드하고 그 프로퍼티의 게터를 호출해 얻은 값(예: Form.Controls의
          // ControlCollection 인스턴스)에 대고 실제 메서드(Add 등)를 호출한다.
          extType:=FindExternalAncestorType(fCurClassName);
          propInfo:=SafeGetProperty(extType, mcs.ObjName);
          aIL.Emit(OpCodes.Ldarg_0);
          aIL.Emit(OpCodes.Callvirt, propInfo.GetGetMethod);
          qTargetType:=propInfo.PropertyType;
          var _getP5:=SafeGetProperty(qTargetType, mcs.MethodName);
          if (mcs.Args.Count=0) and (_getP5<>nil) and (_getP5.GetGetMethod<>nil) then
          begin
            aIL.Emit(OpCodes.Callvirt, _getP5.GetGetMethod);
            aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            emi:=ResolveMethodByArity(qTargetType, mcs.MethodName, mcs.Args, false);
            if emi=nil then
              raise new Exception('타입 "'+qTargetType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
            var _emiParams5:=emi.GetParameters;
            for var _emiAi5:=0 to mcs.Args.Count-1 do
              EmitArgForParamType(aIL, mcs.Args[_emiAi5], _emiParams5[_emiAi5].ParameterType);
            aIL.Emit(OpCodes.Callvirt, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
        end
        else
        begin
          // 로컬/전역 변수가 아니면 System.Windows.Forms.Application.Run(f) 처럼
          // 외부 타입의 정적(static) 멤버 호출로 간주한다. 정적 호출은 인스턴스를
          // 먼저 로드하지 않고 인자만 쌓은 뒤 Call(비가상)로 호출한다.
          extType:=ResolveExternalType(mcs.ObjName);
          emi:=ResolveMethodByArity(extType, mcs.MethodName, mcs.Args, true);
          if emi=nil then
            raise new Exception('외부 타입 "'+extType.FullName+'"에 정적 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
          var _emiParams4:=emi.GetParameters;
          for var _emiAi4:=0 to mcs.Args.Count-1 do
            EmitArgForParamType(aIL, mcs.Args[_emiAi4], _emiParams4[_emiAi4].ParameterType);
          aIL.Emit(OpCodes.Call, emi);
          if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
        end;
      end

      else if s is TEventSubscribeStmtNode then
      begin
        // Button1.Click += Button1_Click;
        evs:=TEventSubscribeStmtNode(s);

        // 1) 리시버(Button1) 로드 — 필드 우선, 그다음 로컬/전역 변수
        // [Stage 30] Qualifier=''  → self.Event += Handler; (예: WPF Window 자신의 Loaded 이벤트).
        // 로컬 클래스에는 직접 정의한 이벤트가 없으므로 언제나 외부 조상 타입에서 찾는다.
        if evs.Qualifier='' then
        begin
          aIL.Emit(OpCodes.Ldarg_0); // self
          qTargetType:=FindExternalAncestorType(fCurClassName);
          if qTargetType=nil then
            raise new Exception('self 이벤트 구독 실패: 클래스 "'+fCurClassName+'"에 외부 조상 타입이 없습니다.');
        end
        else if TryFindFieldBuilder(fCurClassName, evs.Qualifier, qfb) then
        begin
          aIL.Emit(OpCodes.Ldarg_0); aIL.Emit(OpCodes.Ldfld, qfb);
          qTargetType:=qfb.FieldType;
        end
        else if fLocalScope.Has(evs.Qualifier) or fGlobalScope.Has(evs.Qualifier) then
        begin
          if fLocalScope.Has(evs.Qualifier) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(evs.Qualifier))
          else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(evs.Qualifier));
          if fLocalScope.HasClrType(evs.Qualifier) then qTargetType:=fLocalScope.GetClrType(evs.Qualifier)
          else if fGlobalScope.HasClrType(evs.Qualifier) then qTargetType:=fGlobalScope.GetClrType(evs.Qualifier)
          else
          begin
            cn:=GetVarClassName(evs.Qualifier);
            if fBuiltTypes.ContainsKey(cn) then qTargetType:=fBuiltTypes[cn]
            else if fTypeBuilders.ContainsKey(cn) then qTargetType:=fTypeBuilders[cn]
            else raise new Exception('알 수 없는 타입 "'+cn+'" (변수 "'+evs.Qualifier+'")');
          end;
        end
        else if (evs.Qualifier.IndexOf('.')>=0) and IsChainStartSegment(SplitByDot(evs.Qualifier)[0]) then
        begin
          // [Stage 78] "Explorer.Tree.DoubleClick += Handler;"처럼 필드/변수 체인을 통해
          // 자식 객체가 소유한 외부 컨트롤의 이벤트를 구독하는 경우 대응.
          EmitQualifierChainLoad(aIL, SplitByDot(evs.Qualifier), qTargetType);
        end
        else
          raise new Exception('알 수 없는 대상 "'+evs.Qualifier+'" — 필드/지역변수/전역변수가 아닙니다.');

        if evs.QualifierCastType<>'' then
        begin
          qTargetType:=ResolveExternalType(evs.QualifierCastType);
          aIL.Emit(OpCodes.Castclass, qTargetType);
        end;

        // 2) 이벤트 정보 조회 (예: Click → EventHandler 델리게이트 타입)
        evInfo:=qTargetType.GetEvent(evs.EventName);
        if evInfo=nil then
          raise new Exception('타입 "'+qTargetType.FullName+'"에 이벤트 "'+evs.EventName+'"가 없습니다.');
        delCtor:=evInfo.EventHandlerType.GetConstructor([typeof(System.Object), typeof(System.IntPtr)]);
        if delCtor=nil then
          raise new Exception('델리게이트 "'+evInfo.EventHandlerType.FullName+'"의 생성자를 찾을 수 없습니다.');

        // 3) 델리게이트 생성.
        // [Stage 64] 람다면: 이미 방금 만든 static 메서드를 가리키는 델리게이트이므로 target이
        // 없다(Ldnull) — Ldftn(비가상)이면 충분하고 Ldvirtftn/Ldarg_0 두 번이 필요 없다.
        if evs.Lambda<>nil then
        begin
          // [Stage 68] 델리게이트 Invoke 시그니처를 먼저 조회한다 — 개수 검증뿐 아니라,
          // 람다 매개변수에 타입 명시가 없을 때(vtInferred) 위치별 실제 CLR 타입을
          // EmitLambdaAsStaticMethod에 넘겨 추론시키기 위해서다.
          var lamInvoke:=evInfo.EventHandlerType.GetMethod('Invoke');
          if (lamInvoke<>nil) and (lamInvoke.GetParameters.Length<>evs.Lambda.LamParams.Count) then
            raise new Exception('람다 매개변수 개수('+evs.Lambda.LamParams.Count.ToString+'개)가 이벤트 "'
              +evs.EventName+'"의 델리게이트 시그니처('+lamInvoke.GetParameters.Length.ToString+'개)와 다릅니다.');
          var lamExpectedTypes: array of System.Type;
          if lamInvoke<>nil then
          begin
            var lamInvokeParams:=lamInvoke.GetParameters;
            lamExpectedTypes:=new System.Type[lamInvokeParams.Length];
            for var lpi:=0 to lamInvokeParams.Length-1 do lamExpectedTypes[lpi]:=lamInvokeParams[lpi].ParameterType;
          end
          else lamExpectedTypes:=nil;
          // [Stage 68] EmitLambdaAsStaticMethod가 캡처 여부를 스스로 판단해 aIL에
          // 델리게이트 target(캡처 없으면 Ldnull, 있으면 새 __ClosureN 인스턴스)까지
          // 이미 남겨 놓으므로, 여기서는 그 뒤를 이어 Ldftn/Newobj만 하면 된다.
          var lamMB:=EmitLambdaAsStaticMethod(aIL, evs.Lambda, lamExpectedTypes);
          aIL.Emit(OpCodes.Ldftn, lamMB);
          aIL.Emit(OpCodes.Newobj, delCtor);
        end
        else
        begin
          // 핸들러 메서드는 (다른 모든 메서드와 마찬가지로) virtual로 정의되어 있으므로
          // Ldftn이 아니라 Ldvirtftn을 써야 한다 — 이때는 대상 참조를 두 번 로드해야
          // 한다: 하나는 델리게이트의 target 인자로 남고, 하나는 Ldvirtftn이 소비해서
          // 가상 디스패치로 실제 메서드 포인터를 구한다.
          if not TryFindInstanceMethod(fCurClassName, evs.HandlerName, imb) then
            raise new Exception('핸들러 메서드를 찾을 수 없음: '+fCurClassName+'.'+evs.HandlerName);
          aIL.Emit(OpCodes.Ldarg_0); // target (newobj용, 남겨둠)
          aIL.Emit(OpCodes.Ldarg_0); // ldvirtftn이 소비할 참조
          aIL.Emit(OpCodes.Ldvirtftn, imb);
          aIL.Emit(OpCodes.Newobj, delCtor);
        end;

        // 4) add_XXX(delegate) 호출 — 스택: [리시버, 델리게이트]
        emi:=evInfo.GetAddMethod;
        if emi=nil then
          raise new Exception('이벤트 "'+evs.EventName+'"의 add 메서드를 찾을 수 없습니다.');
        aIL.Emit(OpCodes.Callvirt, emi);
      end

      else if s is TSetLengthStmtNode then
      begin
        sl:=TSetLengthStmtNode(s); at2:=vtIntArray;
        if fGlobalScope.Has(sl.ArrName) then at2:=fGlobalScope.GetVType(sl.ArrName)
        else if fLocalScope.Has(sl.ArrName) then at2:=fLocalScope.GetVType(sl.ArrName);
        if fLocalScope.Has(sl.ArrName) then aIL.Emit(OpCodes.Ldloca, fLocalScope.GetLoc(sl.ArrName))
        else aIL.Emit(OpCodes.Ldloca, fGlobalScope.GetLoc(sl.ArrName));
        EmitExpr(aIL, sl.NewSize);
        if at2=vtStrArray then
          rm:=typeof(System.Array).GetMethod('Resize').MakeGenericMethod([typeof(string)])
        // [Stage 90] array of object
        else if at2=vtObjArray then
          rm:=typeof(System.Array).GetMethod('Resize').MakeGenericMethod([typeof(System.Object)])
        else
          rm:=typeof(System.Array).GetMethod('Resize').MakeGenericMethod([typeof(integer)]);
        aIL.Emit(OpCodes.Call, rm);
      end

      else if s is TArrayAssignStmtNode then
      begin
        aa:=TArrayAssignStmtNode(s); at2:=vtIntArray;
        // [버그 수정] 읽기 쪽(TArrayIndexExprNode)과 동일한 패턴 — aa.ArrName이 지역/전역
        // 변수가 아니라 클래스 필드인 배열이면 예전에는 fGlobalScope.GetLoc이 그대로
        // KeyNotFoundException을 던졌다. 필드 폴백을 추가하고, 필드일 때는 GetVType(스코프
        // 전용이라 필드는 조회 불가)이 아니라 FieldBuilder의 실제 CLR 원소 타입으로
        // 참조/값 타입 여부(및 EmitValueForVType에 넘길 at2)를 판단한다.
        var aaFb: FieldBuilder;
        if fGlobalScope.Has(aa.ArrName) then at2:=fGlobalScope.GetVType(aa.ArrName)
        else if fLocalScope.Has(aa.ArrName) then at2:=fLocalScope.GetVType(aa.ArrName)
        else if TryFindFieldBuilder(fCurClassName, aa.ArrName, aaFb) then
        begin
          if IsRefElementType(aaFb.FieldType) then // [Stage 96 버그 수정] TypeBuilderInstantiation 예외 흡수
            at2:=vtStrArray
          else
            at2:=vtIntArray;
        end
        else
          raise new Exception('알 수 없는 변수 "'+aa.ArrName+'" (배열 대입 대상을 지역/전역 변수도, "'
            +fCurClassName+'" 클래스의 필드도 아닌 곳에서 찾을 수 없습니다).');
        if fLocalScope.Has(aa.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(aa.ArrName))
        else if fGlobalScope.Has(aa.ArrName) then aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(aa.ArrName))
        else begin aIL.Emit(OpCodes.Ldarg_0); aIL.Emit(OpCodes.Ldfld, aaFb); end;
        // [Stage 57] arr[i] := 'a'; 에서 arr가 문자열 배열이면 char 리터럴을 문자열로
        // 승격해야 한다 — 안 그러면 정수(문자코드)가 그대로 Stelem_Ref로 들어가
        // 힙 참조로 오인되어 GC/접근 시 크래시가 난다.
        EmitExpr(aIL, aa.Index);
        if at2=vtStrArray then EmitValueForVType(aIL, aa.ValueExpr, vtString)
        else EmitExpr(aIL, aa.ValueExpr);
        // [Stage 90] array of object 원소 쓰기도 문자열과 마찬가지로 참조 타입이라 Stelem_Ref.
        if (at2=vtStrArray) or (at2=vtObjArray) then aIL.Emit(OpCodes.Stelem_Ref)
        else aIL.Emit(OpCodes.Stelem_I4);
      end

      // [Stage 67] 2차원 배열 원소 쓰기: arr[i][j] := val
      // 패턴: Ldloc arr → Ldelem_Ref (행 배열) → EmitIdx j → EmitVal → Stelem_<T>
      else if s is TMatrix2DAssignStmtNode then
      begin
        var m2a:=TMatrix2DAssignStmtNode(s);
        // 원소 타입 이름 스코프에서 조회
        var _m2aetn:=GetVarClassName(m2a.ArrName);
        // 외부 배열(행 배열 참조) 로드
        if fLocalScope.Has(m2a.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(m2a.ArrName))
        else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(m2a.ArrName));
        EmitExpr(aIL, m2a.Row);
        aIL.Emit(OpCodes.Ldelem_Ref); // arr[i] → T[]
        EmitExpr(aIL, m2a.Col);
        // 값 emit (타입별 강제 변환)
        if _m2aetn='string' then EmitValueForVType(aIL, m2a.ValueExpr, vtString)
        else if (_m2aetn='real') or (_m2aetn='double') then EmitValueForVType(aIL, m2a.ValueExpr, vtReal)
        else if _m2aetn='int64' then EmitValueForVType(aIL, m2a.ValueExpr, vtInt64)
        else EmitExpr(aIL, m2a.ValueExpr);
        // Stelem
        if _m2aetn='string' then aIL.Emit(OpCodes.Stelem_Ref)
        else if (_m2aetn='real') or (_m2aetn='double') then aIL.Emit(OpCodes.Stelem_R8)
        else if _m2aetn='char' then aIL.Emit(OpCodes.Stelem_I2)
        else if _m2aetn='int64' then aIL.Emit(OpCodes.Stelem_I8)
        else aIL.Emit(OpCodes.Stelem_I4); // integer 기본
      end

      // [버그 수정] 외부 컬렉션 이중 인덱서 대입: Qualifier[Idx1][Idx2] := Value
      // (예: fClassMethods[cn][mname]:=isFunc). 첫 인덱싱은 get(내부 컬렉션을 얻음),
      // 마지막 인덱싱만 set — EmitIndexerGet으로 얻은 중간 타입에 대해 다시 "Item" 세터를
      // 리플렉션으로 찾아 적용한다(EmitIndexerGet과 대칭되는 set 버전을 여기서 인라인으로 짠다 —
      // 재사용 지점이 한 곳뿐이라 별도 함수로 뽑지 않았다).
      else if s is TExternalDoubleIndexAssignStmtNode then
      begin
        var edia:=TExternalDoubleIndexAssignStmtNode(s);
        var ediaSegs:=SplitByDot(edia.Qualifier);
        var ediaBaseType: System.Type;
        if not IsChainStartSegment(ediaSegs[0]) then
          raise new Exception('알 수 없는 인덱서 대상 "'+edia.Qualifier+'"');
        EmitQualifierChainLoad(aIL, ediaSegs, ediaBaseType);
        var ediaInnerType:=EmitIndexerGet(aIL, ediaBaseType, edia.Idx1); // 첫 단계: get → 내부 컬렉션
        // 두 번째 단계: 내부 컬렉션의 "Item" 세터를 찾아 set_Item(Idx2, Value) 호출
        var ediaIdxArgType:=InferArgClrType(edia.Idx2);
        var ediaItemProp: PropertyInfo := nil;
        var ediaBestScore:=System.Int32.MinValue;
        foreach var ediaCand in ediaInnerType.GetProperties(BindingFlags.Public or BindingFlags.Instance) do
        begin
          if (ediaCand.Name='Item') and (ediaCand.GetIndexParameters.Length=1) and (ediaCand.GetSetMethod<>nil) then
          begin
            var ediaScore:=ScoreParamMatch(ediaCand.GetIndexParameters()[0].ParameterType, ediaIdxArgType);
            if (ediaItemProp=nil) or (ediaScore>ediaBestScore) then
            begin ediaBestScore:=ediaScore; ediaItemProp:=ediaCand; end;
          end;
        end;
        if ediaItemProp=nil then
          raise new Exception('타입 "'+ediaInnerType.FullName+'"에는 인덱서(Item) 세터가 없습니다.');
        var ediaIdxParams:=ediaItemProp.GetIndexParameters();
        EmitArgForParamType(aIL, edia.Idx2, ediaIdxParams[0].ParameterType);
        EmitArgForParamType(aIL, edia.ValueExpr, ediaItemProp.PropertyType);
        aIL.Emit(OpCodes.Callvirt, ediaItemProp.GetSetMethod);
      end

      // [버그 수정] 외부 컬렉션 인덱서 결과에 메서드 호출(문장): Qualifier[IndexExpr].MethodName(Args)
      // (예: fClassFields[cn].Add(propName)). EmitIndexerGet으로 인덱싱 결과(내부 컬렉션)를
      // 스택에 올린 뒤, 이미 검증된 ResolveMethodByArity/EmitArgForParamType 경로로 그대로
      // 넘긴다 — 일반 외부 메서드 호출과 동일한 오버로드 해석을 재사용한다.
      else if s is TExternalIndexMethodCallStmtNode then
      begin
        var eimc:=TExternalIndexMethodCallStmtNode(s);
        var eimcSegs:=SplitByDot(eimc.Qualifier);
        var eimcBaseType: System.Type;
        if not IsChainStartSegment(eimcSegs[0]) then
          raise new Exception('알 수 없는 인덱서 대상 "'+eimc.Qualifier+'"');
        EmitQualifierChainLoad(aIL, eimcSegs, eimcBaseType);
        var eimcInnerType:=EmitIndexerGet(aIL, eimcBaseType, eimc.IndexExpr);
        var eimcMi:=ResolveMethodByArity(eimcInnerType, eimc.MethodName, eimc.Args, false);
        if eimcMi=nil then
          raise new Exception('타입 "'+eimcInnerType.FullName+'"에 메서드 "'+eimc.MethodName+'"가 없습니다 (인자 '+eimc.Args.Count.ToString+'개).');
        var eimcParams:=eimcMi.GetParameters;
        for var eimcAi:=0 to eimc.Args.Count-1 do
          EmitArgForParamType(aIL, eimc.Args[eimcAi], eimcParams[eimcAi].ParameterType);
        aIL.Emit(OpCodes.Callvirt, eimcMi);
        if eimcMi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop); // 문장이므로 반환값 버림
      end

      // [버그 수정] 외부 컬렉션 인덱서 결과의 필드/프로퍼티 대입: Qualifier[IndexExpr].FieldName := Value
      // (예: Entries[vn].ClassName:=cn — TScopeEntry.ClassName은 진짜 필드, 프로퍼티가 아니다).
      // EmitIndexerGet으로 인덱싱 결과(객체 참조)를 스택에 올린 뒤, 그 타입에서 이름으로
      // 먼저 필드를 찾고(Stfld), 없으면 프로퍼티 세터로 폴백한다(Callvirt set_Xxx).
      else if s is TExternalIndexFieldAssignStmtNode then
      begin
        var eifa:=TExternalIndexFieldAssignStmtNode(s);
        var eifaSegs:=SplitByDot(eifa.Qualifier);
        var eifaBaseType: System.Type;
        if not IsChainStartSegment(eifaSegs[0]) then
          raise new Exception('알 수 없는 인덱서 대상 "'+eifa.Qualifier+'"');
        EmitQualifierChainLoad(aIL, eifaSegs, eifaBaseType);
        var eifaInnerType:=EmitIndexerGet(aIL, eifaBaseType, eifa.IndexExpr);
        var eifaFi:=eifaInnerType.GetField(eifa.FieldName, BindingFlags.Public or BindingFlags.Instance);
        if eifaFi<>nil then
        begin
          EmitArgForParamType(aIL, eifa.ValueExpr, eifaFi.FieldType);
          aIL.Emit(OpCodes.Stfld, eifaFi);
        end
        else
        begin
          var eifaPi:=SafeGetProperty(eifaInnerType, eifa.FieldName);
          if (eifaPi=nil) or (eifaPi.GetSetMethod=nil) then
            raise new Exception('타입 "'+eifaInnerType.FullName+'"에 필드/프로퍼티 "'+eifa.FieldName+'"가 없습니다.');
          EmitArgForParamType(aIL, eifa.ValueExpr, eifaPi.PropertyType);
          aIL.Emit(OpCodes.Callvirt, eifaPi.GetSetMethod);
        end;
      end

      // [Stage 67] 2차원 배열 초기화: SetLength(arr, rows, cols)
      // 전략:
      //   1) Newarr (행 배열) → arr에 저장
      //   2) for i := 0 to rows-1: arr[i] := Newarr (열 배열)
      // CLR for 루프를 직접 IL로 방출한다 (재귀적 EmitStatement 없이).
      else if s is TSetLengthMatrix2DStmtNode then
      begin
        var m2sl:=TSetLengthMatrix2DStmtNode(s);
        var _m2stn:=GetVarClassName(m2sl.ArrName);
        // 원소 CLR 타입 결정
        var _m2sElemClr: System.Type;
        if _m2stn='string' then _m2sElemClr:=typeof(string)
        else if (_m2stn='real') or (_m2stn='double') then _m2sElemClr:=typeof(double)
        else if _m2stn='char' then _m2sElemClr:=typeof(char)
        else if _m2stn='int64' then _m2sElemClr:=typeof(int64)
        else _m2sElemClr:=typeof(integer);
        var _m2sRowClr:=_m2sElemClr.MakeArrayType(); // T[]

        // 임시 지역변수: 루프 카운터 i, rows 값, cols 값
        var _iLoc:=aIL.DeclareLocal(typeof(integer));
        var _rowsLoc:=aIL.DeclareLocal(typeof(integer));
        var _colsLoc:=aIL.DeclareLocal(typeof(integer));

        // rows, cols 값을 임시 변수에 저장
        EmitExpr(aIL, m2sl.Rows); aIL.Emit(OpCodes.Stloc, _rowsLoc);
        EmitExpr(aIL, m2sl.Cols); aIL.Emit(OpCodes.Stloc, _colsLoc);

        // 1) 바깥 배열 생성: arr = new T[][rows]
        aIL.Emit(OpCodes.Ldloc, _rowsLoc);
        aIL.Emit(OpCodes.Newarr, _m2sRowClr);
        if fLocalScope.Has(m2sl.ArrName) then aIL.Emit(OpCodes.Stloc, fLocalScope.GetLoc(m2sl.ArrName))
        else aIL.Emit(OpCodes.Stloc, fGlobalScope.GetLoc(m2sl.ArrName));

        // 2) for i := 0 to rows-1: arr[i] = new T[cols]
        aIL.Emit(OpCodes.Ldc_I4_0); aIL.Emit(OpCodes.Stloc, _iLoc);
        var _loopStart:=aIL.DefineLabel;
        var _loopEnd:=aIL.DefineLabel;
        aIL.MarkLabel(_loopStart);
        aIL.Emit(OpCodes.Ldloc, _iLoc);
        aIL.Emit(OpCodes.Ldloc, _rowsLoc);
        aIL.Emit(OpCodes.Bge, _loopEnd); // i >= rows → 종료
        // arr[i] = new T[cols]
        if fLocalScope.Has(m2sl.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(m2sl.ArrName))
        else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(m2sl.ArrName));
        aIL.Emit(OpCodes.Ldloc, _iLoc);
        aIL.Emit(OpCodes.Ldloc, _colsLoc);
        aIL.Emit(OpCodes.Newarr, _m2sElemClr);
        aIL.Emit(OpCodes.Stelem_Ref);
        // i++
        aIL.Emit(OpCodes.Ldloc, _iLoc);
        aIL.Emit(OpCodes.Ldc_I4_1);
        aIL.Emit(OpCodes.Add);
        aIL.Emit(OpCodes.Stloc, _iLoc);
        aIL.Emit(OpCodes.Br, _loopStart);
        aIL.MarkLabel(_loopEnd);
      end

      else if s is TCompoundStmtNode then
      begin
        comp:=TCompoundStmtNode(s);
        foreach var st in comp.Statements do EmitStatement(aIL, st);
      end

      else if s is TIfStmtNode then
      begin
        ifs:=TIfStmtNode(s); eL:=aIL.DefineLabel; endL:=aIL.DefineLabel;
        EmitExpr(aIL, ifs.Condition); aIL.Emit(OpCodes.Brfalse, eL);
        EmitStatement(aIL, ifs.ThenStmt); aIL.Emit(OpCodes.Br, endL);
        aIL.MarkLabel(eL);
        if ifs.ElseStmt<>nil then EmitStatement(aIL, ifs.ElseStmt);
        aIL.MarkLabel(endL);
      end

      else if s is TWhileStmtNode then
      begin
        whs:=TWhileStmtNode(s); ckL:=aIL.DefineLabel; bdL:=aIL.DefineLabel;
        // [Stage 60] continue → 조건 검사(ckL)로, break → 루프 뒤(whEndL)로.
        var whEndL:=aIL.DefineLabel;
        fLoopBreakLabels.Add(whEndL); fLoopContinueLabels.Add(ckL); fLoopExceptDepths.Add(fCurExceptDepth);
        aIL.Emit(OpCodes.Br, ckL); aIL.MarkLabel(bdL);
        EmitStatement(aIL, whs.Body);
        aIL.MarkLabel(ckL); EmitExpr(aIL, whs.Condition);
        aIL.Emit(OpCodes.Brtrue, bdL);
        aIL.MarkLabel(whEndL);
        fLoopBreakLabels.RemoveAt(fLoopBreakLabels.Count-1);
        fLoopContinueLabels.RemoveAt(fLoopContinueLabels.Count-1);
        fLoopExceptDepths.RemoveAt(fLoopExceptDepths.Count-1);
      end

      else if s is TCaseStmtNode then
      begin
        // [Stage 59] case Selector of 라벨...: 문장; ... [else 문장들] end
        // 점프 테이블 최적화 없이 분기를 순서대로 검사하는 조건 체인으로 desugar한다:
        //   sel := Selector (임시 로컬에 한 번만 저장, 반복 평가 방지)
        //   각 분기: 라벨 중 하나라도 맞으면 caseBodyL로 점프, 다 안 맞으면 caseNextL로 통과
        //     caseBodyL: 문장; goto caseEndL;
        //     caseNextL: (다음 분기 검사로 이어짐)
        //   모든 분기가 안 맞으면 else문장들(있으면) 실행
        //   caseEndL:
        // 단일값 라벨은 Ceq, 범위(lo..hi) 라벨은 Clt/Cgt 조합으로 "범위 밖이면 실패" 판정.
        var cse:=TCaseStmtNode(s);
        var caseSelClrType: System.Type;
        if cse.Selector is TVarRefNode then
          caseSelClrType:=VTC(GetVarType(TVarRefNode(cse.Selector).VarName), GetVarClassName(TVarRefNode(cse.Selector).VarName))
        else
          caseSelClrType:=VTC(InferType(cse.Selector), '');
        var caseSelLoc:=aIL.DeclareLocal(caseSelClrType);
        EmitExpr(aIL, cse.Selector);
        aIL.Emit(OpCodes.Stloc, caseSelLoc);

        var caseEndL:=aIL.DefineLabel;
        foreach var cbr in cse.Branches do
        begin
          var caseBodyL:=aIL.DefineLabel;
          var caseNextL:=aIL.DefineLabel;
          foreach var clbl in cbr.Labels do
          begin
            if clbl.HighExpr=nil then
            begin
              aIL.Emit(OpCodes.Ldloc, caseSelLoc);
              EmitExpr(aIL, clbl.LowExpr);
              aIL.Emit(OpCodes.Ceq);
              aIL.Emit(OpCodes.Brtrue, caseBodyL);
            end
            else
            begin
              var caseRangeFailL:=aIL.DefineLabel;
              aIL.Emit(OpCodes.Ldloc, caseSelLoc);
              EmitExpr(aIL, clbl.LowExpr);
              aIL.Emit(OpCodes.Clt);
              aIL.Emit(OpCodes.Brtrue, caseRangeFailL); // sel < low → 범위 밖
              aIL.Emit(OpCodes.Ldloc, caseSelLoc);
              EmitExpr(aIL, clbl.HighExpr);
              aIL.Emit(OpCodes.Cgt);
              aIL.Emit(OpCodes.Brtrue, caseRangeFailL); // sel > high → 범위 밖
              aIL.Emit(OpCodes.Br, caseBodyL);
              aIL.MarkLabel(caseRangeFailL);
            end;
          end;
          aIL.Emit(OpCodes.Br, caseNextL);
          aIL.MarkLabel(caseBodyL);
          EmitStatement(aIL, cbr.Stmt);
          aIL.Emit(OpCodes.Br, caseEndL);
          aIL.MarkLabel(caseNextL);
        end;
        if cse.ElseStmts<>nil then
          foreach var celS in cse.ElseStmts do EmitStatement(aIL, celS);
        aIL.MarkLabel(caseEndL);
      end

      else if s is TProcCallStmtNode then
      begin
        pc:=TProcCallStmtNode(s);
        if fMethods.ContainsKey(pc.ProcName) then
        begin
          mb:=fMethods[pc.ProcName];
          var _pcParams: array of System.Type;
          if fTopParamClrTypes.ContainsKey(pc.ProcName) then _pcParams:=fTopParamClrTypes[pc.ProcName]
          else _pcParams:=nil;
          EmitArgsCoerced(aIL, pc.Args, _pcParams);
          aIL.Emit(OpCodes.Call, mb);
        end
        // [Stage 71] EmitExpr의 TFuncCallExprNode 분기와 동일한 이유 — 오픈 제네릭 프로시저 호출.
        else if fOpenGenericCallMap.ContainsKey(pc.ProcName) then
          EmitOpenGenericCall(aIL, fOpenGenericCallMap[pc.ProcName], pc.Args)
        else
          raise new Exception('알 수 없는 프로시저 "'+pc.ProcName+'"');
      end

      else if s is TForStmtNode then
      begin
        // for VarName := Start (to|downto) End do Body
        // IL 패턴: i=Start; endVal=End; goto ckL;
        //   bdL: Body; if isDownto then i-- else i++;
        //   ckL: if isDownto then (i>=endVal) else (i<=endVal) → brtrue bdL
        var fs:=TForStmtNode(s);
        var forVarLoc: LocalBuilder;
        if fLocalScope.Has(fs.VarName) then forVarLoc:=fLocalScope.GetLoc(fs.VarName)
        else if fGlobalScope.Has(fs.VarName) then forVarLoc:=fGlobalScope.GetLoc(fs.VarName)
        else raise new Exception('for 변수 선언 안 됨: '+fs.VarName);
        // end값을 임시 로컬에 저장 (매 반복 재평가 방지)
        var endValLoc:=aIL.DeclareLocal(typeof(integer));
        EmitExpr(aIL, fs.StartExpr);
        aIL.Emit(OpCodes.Stloc, forVarLoc);
        EmitExpr(aIL, fs.EndExpr);
        aIL.Emit(OpCodes.Stloc, endValLoc);
        var forCkL:=aIL.DefineLabel; var forBdL:=aIL.DefineLabel;
        // [Stage 60] continue는 본문 나머지를 건너뛰되 증감(i++/i--)은 그대로 해야 하므로
        // 증감 코드 바로 앞에 별도 라벨(forIncL)을 둔다. break는 루프 완전히 밖(forEndL)으로.
        var forIncL:=aIL.DefineLabel; var forEndL:=aIL.DefineLabel;
        fLoopBreakLabels.Add(forEndL); fLoopContinueLabels.Add(forIncL); fLoopExceptDepths.Add(fCurExceptDepth);
        aIL.Emit(OpCodes.Br, forCkL);
        aIL.MarkLabel(forBdL);
        EmitStatement(aIL, fs.Body);
        aIL.MarkLabel(forIncL);
        // i++ 또는 i--
        aIL.Emit(OpCodes.Ldloc, forVarLoc);
        aIL.Emit(OpCodes.Ldc_I4_1);
        if fs.IsDownto then aIL.Emit(OpCodes.Sub) else aIL.Emit(OpCodes.Add);
        aIL.Emit(OpCodes.Stloc, forVarLoc);
        aIL.MarkLabel(forCkL);
        // 조건: to → i<=endVal (Cgt+Ldc_I4_0+Ceq), downto → i>=endVal (Clt+Ldc_I4_0+Ceq)
        aIL.Emit(OpCodes.Ldloc, forVarLoc);
        aIL.Emit(OpCodes.Ldloc, endValLoc);
        if fs.IsDownto then
        begin aIL.Emit(OpCodes.Clt); aIL.Emit(OpCodes.Ldc_I4_0); aIL.Emit(OpCodes.Ceq); end
        else
        begin aIL.Emit(OpCodes.Cgt); aIL.Emit(OpCodes.Ldc_I4_0); aIL.Emit(OpCodes.Ceq); end;
        aIL.Emit(OpCodes.Brtrue, forBdL);
        aIL.MarkLabel(forEndL);
        fLoopBreakLabels.RemoveAt(fLoopBreakLabels.Count-1);
        fLoopContinueLabels.RemoveAt(fLoopContinueLabels.Count-1);
        fLoopExceptDepths.RemoveAt(fLoopExceptDepths.Count-1);
      end

      else if s is TForInStmtNode then
      begin
        // [Stage 54] for VarName in CollExpr do Body
        // "중간" 단계: 배열(T[])이든 List<T> 같은 외부 컬렉션이든, .NET IEnumerable을
        // 구현하는 값이면 무엇이든 동일한 방식으로 순회한다 — 원소마다 특수 케이스를
        // 나누는 대신, System.Collections.IEnumerable / IEnumerator의 (비제네릭)
        // GetEnumerator/MoveNext/Current 3종 멤버만으로 desugar한다:
        //
        //   var _e := CollExpr.GetEnumerator();
        //   goto ckL;
        //   bdL: VarName := (T)_e.Current; Body;
        //   ckL: if _e.MoveNext() then goto bdL;
        //
        // Current가 object를 돌려주므로 값 타입(정수 등)은 Unbox_Any, 참조 타입은
        // Castclass로 VarName의 선언된 타입으로 되돌린다. 배열도 CLR에서는 참조
        // 타입(IEnumerable 구현체)이라 별도 분기 없이 이 경로를 그대로 탄다.
        // (배열의 값 타입 원소를 Current로 꺼낼 때 매 반복 boxing이 발생하는 점은
        // "중간" 단계의 알려진 트레이드오프 — 다음 단계에서 IEnumerator<T> 특수화로
        // 제거할 수 있다.)
        var fis:=TForInStmtNode(s);
        var forInVarLoc: LocalBuilder;
        if fLocalScope.Has(fis.VarName) then forInVarLoc:=fLocalScope.GetLoc(fis.VarName)
        else if fGlobalScope.Has(fis.VarName) then forInVarLoc:=fGlobalScope.GetLoc(fis.VarName)
        else raise new Exception('for-in 변수 선언 안 됨: '+fis.VarName);

        var forInVarClrType:=VTC(GetVarType(fis.VarName), GetVarClassName(fis.VarName));

        EmitExpr(aIL, fis.CollExpr); // 컬렉션 참조를 스택에 올린다
        var getEnumMI:=typeof(System.Collections.IEnumerable).GetMethod('GetEnumerator');
        aIL.Emit(OpCodes.Callvirt, getEnumMI);
        var forInEnumLoc:=aIL.DeclareLocal(typeof(System.Collections.IEnumerator));
        aIL.Emit(OpCodes.Stloc, forInEnumLoc);

        var forInCkL:=aIL.DefineLabel; var forInBdL:=aIL.DefineLabel;
        // [Stage 60] continue → MoveNext 검사(forInCkL)로, break → 루프 뒤(forInEndL)로.
        var forInEndL:=aIL.DefineLabel;
        fLoopBreakLabels.Add(forInEndL); fLoopContinueLabels.Add(forInCkL); fLoopExceptDepths.Add(fCurExceptDepth);
        aIL.Emit(OpCodes.Br, forInCkL);
        aIL.MarkLabel(forInBdL);

        // VarName := (T)_e.Current;
        aIL.Emit(OpCodes.Ldloc, forInEnumLoc);
        var getCurMI:=typeof(System.Collections.IEnumerator).GetProperty('Current').GetGetMethod;
        aIL.Emit(OpCodes.Callvirt, getCurMI);
        if forInVarClrType.IsValueType then aIL.Emit(OpCodes.Unbox_Any, forInVarClrType)
        else aIL.Emit(OpCodes.Castclass, forInVarClrType);
        aIL.Emit(OpCodes.Stloc, forInVarLoc);

        EmitStatement(aIL, fis.Body);

        aIL.MarkLabel(forInCkL);
        aIL.Emit(OpCodes.Ldloc, forInEnumLoc);
        var moveNextMI:=typeof(System.Collections.IEnumerator).GetMethod('MoveNext');
        aIL.Emit(OpCodes.Callvirt, moveNextMI);
        aIL.Emit(OpCodes.Brtrue, forInBdL);
        aIL.MarkLabel(forInEndL);
        fLoopBreakLabels.RemoveAt(fLoopBreakLabels.Count-1);
        fLoopContinueLabels.RemoveAt(fLoopContinueLabels.Count-1);
        fLoopExceptDepths.RemoveAt(fLoopExceptDepths.Count-1);
      end

      else if s is TRepeatStmtNode then
      begin
        // [Stage 60] repeat 문장들 until Condition
        // IL 패턴: bdL: 문장들; ckL(continue 대상): if not Condition then goto bdL;
        //   endL(break 대상):
        // while과 반대로 조건이 '참'이면 멈춘다 — 그래서 Condition 평가 후 Brfalse로 되돈다.
        // 최초 진입 시 무조건 본문을 한 번 실행하므로(= "do...while" 형태) while처럼 진입 전
        // 조건 검사로 건너뛰는 Br이 없다.
        var reps:=TRepeatStmtNode(s);
        var repBdL:=aIL.DefineLabel; var repCkL:=aIL.DefineLabel; var repEndL:=aIL.DefineLabel;
        fLoopBreakLabels.Add(repEndL); fLoopContinueLabels.Add(repCkL); fLoopExceptDepths.Add(fCurExceptDepth);
        aIL.MarkLabel(repBdL);
        foreach var repSt in reps.Statements do EmitStatement(aIL, repSt);
        aIL.MarkLabel(repCkL);
        EmitExpr(aIL, reps.Condition);
        aIL.Emit(OpCodes.Brfalse, repBdL);
        aIL.MarkLabel(repEndL);
        fLoopBreakLabels.RemoveAt(fLoopBreakLabels.Count-1);
        fLoopContinueLabels.RemoveAt(fLoopContinueLabels.Count-1);
        fLoopExceptDepths.RemoveAt(fLoopExceptDepths.Count-1);
      end

      else if s is TBreakStmtNode then
        EmitLoopExit(aIL, true)

      else if s is TContinueStmtNode then
        EmitLoopExit(aIL, false)

      else if s is TExitStmtNode then
        EmitMethodExit(aIL) // [Stage 78]

      else if s is TTryStmtNode then
      begin
        var ts2:=TTryStmtNode(s);
        // 예외 변수 로컬 선언 (on E: Exception do 가 있는 경우)
        var exLoc: LocalBuilder := nil;
        if (ts2.ExVarName<>'') and (ts2.ExceptStmts<>nil) then
        begin
          exLoc:=aIL.DeclareLocal(typeof(Exception));
          fLocalScope.Declare(ts2.ExVarName, exLoc, vtString); // 내부 타입은 string으로 (Message는 string)
          // [Stage 49] .Message는 TExceptionMsgExprNode가 전용으로 처리하지만, .ToString()
          // 같은 다른 멤버는 이게 없으면 "외부 타입 로컬 변수" 경로를 못 타서
          // "알 수 없는 메서드"로 막혔다 — 실제 예외 객체 타입을 등록해 리플렉션 경로를 열어준다.
          fLocalScope.SetClrType(ts2.ExVarName, typeof(Exception));
        end;

        aIL.BeginExceptionBlock;
        fCurExceptDepth:=fCurExceptDepth+1; // [Stage 60] break/continue가 이 블록을 벗어나면 Leave를 써야 함을 표시

        // try 본문
        foreach var bs in ts2.BodyStmts do EmitStatement(aIL, bs);

        // except 블록
        if ts2.ExceptStmts<>nil then
        begin
          // catch(Exception)
          aIL.BeginCatchBlock(typeof(Exception));
          if exLoc<>nil then
            aIL.Emit(OpCodes.Stloc, exLoc) // 예외 객체 저장
          else
            aIL.Emit(OpCodes.Pop); // 예외 객체 버리기
          foreach var es in ts2.ExceptStmts do EmitStatement(aIL, es);
        end;

        // finally 블록
        if ts2.FinallyStmts<>nil then
        begin
          aIL.BeginFinallyBlock;
          foreach var fs2 in ts2.FinallyStmts do EmitStatement(aIL, fs2);
        end;

        aIL.EndExceptionBlock;
        fCurExceptDepth:=fCurExceptDepth-1; // [Stage 60]

        // 예외 변수 이름을 로컬에서 제거 (스코프 종료)
        if ts2.ExVarName<>'' then
        begin
          fLocalScope.Remove(ts2.ExVarName); // [Stage 49] ClrType도 같은 항목 안에 있으므로 한 번에 제거됨
        end;
      end

      else if s is TRaiseStmtNode then
      begin
        var rs:=TRaiseStmtNode(s);
        if rs.Expr=nil then
          aIL.Emit(OpCodes.Rethrow) // raise; → rethrow
        else
        begin
          EmitExpr(aIL, rs.Expr);
          aIL.Emit(OpCodes.Throw);
        end;
      end

      else if s is TInheritedCallStmtNode then // [Stage 30]
      begin
        var ihs3:=TInheritedCallStmtNode(s);
        EmitInheritedCall(aIL, ihs3.MethodName, ihs3.Args, false);
      end

      // [Stage 69] yield <식>; — "function ...: sequence of T;"(이터레이터) 본문의 MoveNext 안에서만
      // 유효하다. BuildIteratorMoveNext가 이 지점의 상태번호/재개라벨을 CollectYieldPoints로 미리
      // 배정해 두었어야 한다(try/case 안의 yield는 1차 제약으로 배정되지 않는다 — 그 경우 아래에서
      // 명확한 오류를 낸다). 값 저장 → 지역변수를 필드로 되돌려 씀(다음 호출을 위한 상태 보존) →
      // 상태번호 기록 → true 반환 → 다음 호출이 재개할 라벨을 바로 뒤에 표시.
      else if s is TYieldStmtNode then
      begin
        var ys69:=TYieldStmtNode(s);
        if not fInIterator then
          raise new Exception('yield는 "function ...: sequence of T;" 본문 밖에서는 쓸 수 없습니다 (Stage 69)');
        if not fCurIterYieldState.ContainsKey(ys69) then
          raise new Exception('이 yield는 아직 지원하지 않는 문맥(try/case 등) 안에 있습니다 (Stage 69, 1차 제약)');
        var yState:=fCurIterYieldState[ys69];
        var yLabel:=fCurIterYieldLabel[yState];

        aIL.Emit(OpCodes.Ldarg_0);
        EmitArgForParamType(aIL, ys69.Expr, fCurIterCurrentField.FieldType);
        aIL.Emit(OpCodes.Stfld, fCurIterCurrentField);

        // 지금까지의 지역 슬롯 값을 전부 필드로 되돌려 쓴다 — 이 메서드 호출은 곧 return하므로
        // (일시정지), 다음 MoveNext 호출이 이 값들을 다시 필드→지역으로 복원해 이어갈 수 있어야 한다.
        foreach var kv69b in fCurIterFields do
        begin
          if fLocalScope.Has(kv69b.Key) then
          begin
            aIL.Emit(OpCodes.Ldarg_0);
            aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(kv69b.Key));
            aIL.Emit(OpCodes.Stfld, kv69b.Value);
          end;
        end;

        aIL.Emit(OpCodes.Ldarg_0);
        aIL.Emit(OpCodes.Ldc_I4, yState);
        aIL.Emit(OpCodes.Stfld, fCurIterStateField);
        aIL.Emit(OpCodes.Ldc_I4_1);
        aIL.Emit(OpCodes.Ret);
        aIL.MarkLabel(yLabel);
      end

      else raise new Exception('알 수 없는 문장 노드: '+s.GetType.Name);
      finally
        fEmitDepth:=fEmitDepth-1;
      end;
    end;

    // 메서드 시그니처의 i번째 매개변수의 실제 CLR 타입을 결정한다 (기본/지역클래스/외부타입 모두 포함)
    // [Stage 100] var/const 참조 매개변수는 CLR ByRef 타입(예: string&)으로 내보낸다.
    // ByRef 타입이면 원소(실제 값) 타입을, 아니면 그대로 돌려준다 — 로컬 슬롯 선언, 역참조
    // 읽기(Ldobj)/역참조 쓰기(Stobj)에서 실제 값 타입이 필요할 때 이 함수를 거친다.
    function ElemTypeIfByRef(t: System.Type): System.Type;
    begin
      if t.IsByRef then Result:=t.GetElementType else Result:=t;
    end;

    function ResolveParamClrType(sig: TMethodSignature; i: integer): System.Type;
    begin
      if (sig.ParamTypes[i]=vtObject) and (i<sig.ParamIsExternal.Count) and sig.ParamIsExternal[i] then
        Result:=ResolveExternalType(sig.ParamClassNames[i])
      else if sig.ParamTypes[i]=vtObject then
        Result:=VTC(vtObject, sig.ParamClassNames[i])
      else if sig.ParamTypes[i]=vtGeneric then
        Result:=VTC(vtGeneric, sig.ParamClassNames[i])
      // [버그 수정] enum 타입 매개변수 — ClassName(열거형 이름)을 VTC에 넘겨야 fBuiltEnums에서
      // 실제 Type을 찾는다. 이게 없으면 cn=''로 떨어져 typeof(integer)로 조용히 폴백하고,
      // 이후 EmitExpr의 HasClrType 라우팅이 빠져 "알 수 없는 메서드 ".ToString"" 등으로 이어진다.
      else if sig.ParamTypes[i]=vtEnum then
        Result:=VTC(vtEnum, sig.ParamClassNames[i])
      else
        Result:=VTC(sig.ParamTypes[i], '');
      if (i<sig.ParamIsByRef.Count) and sig.ParamIsByRef[i] then Result:=Result.MakeByRefType;
    end;

    // [Stage 31] 최상위 함수/프로시저(TParamDef)의 매개변수 실제 CLR 타입을 결정한다.
    // ResolveParamClrType(TMethodSignature용)과 동일한 패턴이지만 TParamDef를 입력으로 받는다.
    function ResolveTopParamClrType(p: TParamDef): System.Type;
    begin
      if (p.ParamType=vtObject) and p.IsExternal then Result:=ResolveExternalType(p.ClassName)
      else if p.ParamType=vtObject then Result:=VTC(vtObject, p.ClassName)
      else if p.ParamType=vtInterface then Result:=VTC(vtInterface, p.ClassName)
      else if p.ParamType=vtEnum then Result:=VTC(vtEnum, p.ClassName) // [Phase 1]
      // [Stage 71] vtGeneric일 때 p.ClassName에 타입 매개변수 이름('T' 등)이 들어있다 — 예전에는
      // 이 분기가 없어 VTC(p.ParamType, '')로 떨어져 그 이름이 통째로 유실됐지만(당시엔 vtGeneric
      // 매개변수가 CodeGen까지 온 적이 없어 무해했다), true open generic 지원을 위해 명시한다.
      else if p.ParamType=vtGeneric then Result:=VTC(vtGeneric, p.ClassName)
      else Result:=VTC(p.ParamType, '');
      // [Stage 100] var/const 매개변수 — ByRef 타입으로 감싼다.
      if p.IsByRef then Result:=Result.MakeByRefType;
    end;

    // [Stage 68] 람다 매개변수에 타입 명시가 없을 때(vtInferred), 델리게이트 Invoke 시그니처에서
    // 가져온 실제 CLR 타입을 스코프에 태깅하기 위한 TVarType 근사값을 구한다. 이 태그는 이후
    // 식/문 컴파일에서 "이 변수가 어떤 연산을 지원하는가"를 판단하는 용도로만 쓰이고, 실제 로컬
    // 슬롯의 CLR 타입은 항상 델리게이트가 알려준 그대로(paramTypes[li])를 사용한다.
    function VarTypeTagFromClrType(t: System.Type): TVarType;
    begin
      if t=typeof(integer) then Result:=vtInteger
      else if t=typeof(string) then Result:=vtString
      else if t=typeof(boolean) then Result:=vtBoolean
      else if t=typeof(double) then Result:=vtReal
      else if t=typeof(char) then Result:=vtChar
      else if t=typeof(int64) then Result:=vtInt64
      else if t.IsInterface then Result:=vtInterface
      else Result:=vtObject; // 클래스/구조체 등 그 외 참조·값 타입은 vtObject로 취급하고
                             // ClassName은 비워 둔 채 SetClrType으로 실제 타입을 스코프에 기록한다.
    end;

    // [Stage 68] 캡처 분석 1단계 — 식 안에 등장하는 "이름"들을 모두 names에 모은다.
    // 여기서는 아직 그 이름이 실제로 바깥 지역변수인지 판단하지 않는다(그건 호출부에서
    // fLocalScope.Has로 거른다) — 그냥 후보를 넓게 모으기만 한다. 존재하지 않는 노드
    // 타입 분기는 없다(AST.pas의 모든 TExprNode 자손을 다룬다).
    procedure CollectVarNamesInExpr(e: TExprNode; names: List<string>);
    var i: integer;
    begin
      if e=nil then exit;
      if e is TVarRefNode then names.Add(TVarRefNode(e).VarName)
      else if e is TArrayIndexExprNode then
      begin
        names.Add(TArrayIndexExprNode(e).ArrName);
        CollectVarNamesInExpr(TArrayIndexExprNode(e).Index, names);
      end
      else if e is TLengthExprNode then names.Add(TLengthExprNode(e).ArrName)
      else if e is TAsCastExprNode then CollectVarNamesInExpr(TAsCastExprNode(e).Expr, names)
      else if e is TIsCheckExprNode then CollectVarNamesInExpr(TIsCheckExprNode(e).Expr, names)
      else if e is TInheritedCallExprNode then
        for i:=0 to TInheritedCallExprNode(e).Args.Count-1 do
          CollectVarNamesInExpr(TInheritedCallExprNode(e).Args[i], names)
      else if e is TIntToStrNode then CollectVarNamesInExpr(TIntToStrNode(e).Arg, names)
      else if e is TBoolToStrNode then CollectVarNamesInExpr(TBoolToStrNode(e).Arg, names)
      else if e is TNewObjectExprNode then
        for i:=0 to TNewObjectExprNode(e).Args.Count-1 do
          CollectVarNamesInExpr(TNewObjectExprNode(e).Args[i], names)
      else if e is TMethodCallExprNode then
      begin
        names.Add(TMethodCallExprNode(e).ObjName);
        for i:=0 to TMethodCallExprNode(e).Args.Count-1 do
          CollectVarNamesInExpr(TMethodCallExprNode(e).Args[i], names);
      end
      // [Stage 90] TargetType(expr) 캐스트 대상 안의 변수도 클로저 캡처 대상에 포함
      else if e is TExternalCastExprNode then
        CollectVarNamesInExpr(TExternalCastExprNode(e).InnerExpr, names)
      // [Stage 90] a.GetName().Version.ToString() 같은 체인 안의 변수도 클로저 캡처 대상에 포함
      else if e is TChainedMemberExprNode then
      begin
        CollectVarNamesInExpr(TChainedMemberExprNode(e).Inner, names);
        for i:=0 to TChainedMemberExprNode(e).Args.Count-1 do
          CollectVarNamesInExpr(TChainedMemberExprNode(e).Args[i], names);
      end
      // [버그 수정] Target[Index] 후위 인덱싱(예: SplitByDot(x)[0]) 안의 변수도 클로저 캡처 대상에 포함
      else if e is TChainedIndexExprNode then
      begin
        CollectVarNamesInExpr(TChainedIndexExprNode(e).Target, names);
        CollectVarNamesInExpr(TChainedIndexExprNode(e).IndexExpr, names);
      end
      else if e is TBinOpNode then
      begin
        CollectVarNamesInExpr(TBinOpNode(e).Left, names);
        CollectVarNamesInExpr(TBinOpNode(e).Right, names);
      end
      else if e is TCompareNode then
      begin
        CollectVarNamesInExpr(TCompareNode(e).Left, names);
        CollectVarNamesInExpr(TCompareNode(e).Right, names);
      end
      else if e is TInExprNode then
      begin
        CollectVarNamesInExpr(TInExprNode(e).Elem, names);
        CollectVarNamesInExpr(TInExprNode(e).SetExpr, names);
      end
      else if e is TNotExprNode then CollectVarNamesInExpr(TNotExprNode(e).Expr, names)
      else if e is TFuncCallExprNode then
      begin
        names.Add(TFuncCallExprNode(e).FuncName); // 함수형 변수(델리게이트)일 수도 있으므로 후보에 포함
        for i:=0 to TFuncCallExprNode(e).Args.Count-1 do
          CollectVarNamesInExpr(TFuncCallExprNode(e).Args[i], names);
      end
      else if e is TMatrix2DIndexExprNode then
      begin
        names.Add(TMatrix2DIndexExprNode(e).ArrName);
        CollectVarNamesInExpr(TMatrix2DIndexExprNode(e).Row, names);
        CollectVarNamesInExpr(TMatrix2DIndexExprNode(e).Col, names);
      end;
      // 나머지(리터럴, self, nil, 필드읽기, 정적 멤버 등)는 바깥 지역변수를 참조할 수 없으므로 무시.
    end;

    // [Stage 68] 캡처 분석 2단계 — 문장 트리를 훑으며 참조 이름 후보(names)와, 람다
    // 본문 "안에서" 새로 선언되는 이름(boundNames — for 루프 변수, inline var, except 변수)을
    // 모은다. boundNames에 있는 이름은 바깥 캡처 대상에서 제외된다(자기 자신의 지역 슬롯이므로).
    procedure CollectVarNamesInStmt(s: TStmtNode; names: List<string>; boundNames: List<string>);
    var i: integer; branch: TCaseBranchNode; lbl: TCaseLabel;
    begin
      if s=nil then exit;
      if s is TWritelnExprStmtNode then CollectVarNamesInExpr(TWritelnExprStmtNode(s).Arg, names)
      // [Stage 90] writeln(a, b, c, ...)의 각 인자 안의 변수도 클로저 캡처 대상에 포함
      else if s is TWritelnArgsStmtNode then
        for i:=0 to TWritelnArgsStmtNode(s).Args.Count-1 do
          CollectVarNamesInExpr(TWritelnArgsStmtNode(s).Args[i], names)
      else if s is TAssignStmtNode then
      begin
        names.Add(TAssignStmtNode(s).VarName);
        CollectVarNamesInExpr(TAssignStmtNode(s).ValueExpr, names);
      end
      else if s is TResultAssignStmtNode then CollectVarNamesInExpr(TResultAssignStmtNode(s).ValueExpr, names)
      else if s is TCompoundStmtNode then
        for i:=0 to TCompoundStmtNode(s).Statements.Count-1 do
          CollectVarNamesInStmt(TCompoundStmtNode(s).Statements[i], names, boundNames)
      else if s is TIfStmtNode then
      begin
        CollectVarNamesInExpr(TIfStmtNode(s).Condition, names);
        CollectVarNamesInStmt(TIfStmtNode(s).ThenStmt, names, boundNames);
        CollectVarNamesInStmt(TIfStmtNode(s).ElseStmt, names, boundNames);
      end
      else if s is TWhileStmtNode then
      begin
        CollectVarNamesInExpr(TWhileStmtNode(s).Condition, names);
        CollectVarNamesInStmt(TWhileStmtNode(s).Body, names, boundNames);
      end
      else if s is TForStmtNode then
      begin
        if not boundNames.Contains(TForStmtNode(s).VarName) then boundNames.Add(TForStmtNode(s).VarName);
        CollectVarNamesInExpr(TForStmtNode(s).StartExpr, names);
        CollectVarNamesInExpr(TForStmtNode(s).EndExpr, names);
        CollectVarNamesInStmt(TForStmtNode(s).Body, names, boundNames);
      end
      else if s is TForInStmtNode then
      begin
        if not boundNames.Contains(TForInStmtNode(s).VarName) then boundNames.Add(TForInStmtNode(s).VarName);
        CollectVarNamesInExpr(TForInStmtNode(s).CollExpr, names);
        CollectVarNamesInStmt(TForInStmtNode(s).Body, names, boundNames);
      end
      else if s is TRepeatStmtNode then
      begin
        for i:=0 to TRepeatStmtNode(s).Statements.Count-1 do
          CollectVarNamesInStmt(TRepeatStmtNode(s).Statements[i], names, boundNames);
        CollectVarNamesInExpr(TRepeatStmtNode(s).Condition, names);
      end
      else if s is TCaseStmtNode then
      begin
        CollectVarNamesInExpr(TCaseStmtNode(s).Selector, names);
        foreach branch in TCaseStmtNode(s).Branches do
        begin
          foreach lbl in branch.Labels do
          begin
            CollectVarNamesInExpr(lbl.LowExpr, names);
            CollectVarNamesInExpr(lbl.HighExpr, names);
          end;
          CollectVarNamesInStmt(branch.Stmt, names, boundNames);
        end;
        if TCaseStmtNode(s).ElseStmts<>nil then
          for i:=0 to TCaseStmtNode(s).ElseStmts.Count-1 do
            CollectVarNamesInStmt(TCaseStmtNode(s).ElseStmts[i], names, boundNames);
      end
      else if s is TProcCallStmtNode then
      begin
        names.Add(TProcCallStmtNode(s).ProcName);
        for i:=0 to TProcCallStmtNode(s).Args.Count-1 do
          CollectVarNamesInExpr(TProcCallStmtNode(s).Args[i], names);
      end
      else if s is TSetLengthStmtNode then
      begin
        names.Add(TSetLengthStmtNode(s).ArrName);
        CollectVarNamesInExpr(TSetLengthStmtNode(s).NewSize, names);
      end
      else if s is TArrayAssignStmtNode then
      begin
        names.Add(TArrayAssignStmtNode(s).ArrName);
        CollectVarNamesInExpr(TArrayAssignStmtNode(s).Index, names);
        CollectVarNamesInExpr(TArrayAssignStmtNode(s).ValueExpr, names);
      end
      else if s is TMatrix2DAssignStmtNode then
      begin
        names.Add(TMatrix2DAssignStmtNode(s).ArrName);
        CollectVarNamesInExpr(TMatrix2DAssignStmtNode(s).Row, names);
        CollectVarNamesInExpr(TMatrix2DAssignStmtNode(s).Col, names);
        CollectVarNamesInExpr(TMatrix2DAssignStmtNode(s).ValueExpr, names);
      end
      else if s is TSetLengthMatrix2DStmtNode then
      begin
        names.Add(TSetLengthMatrix2DStmtNode(s).ArrName);
        CollectVarNamesInExpr(TSetLengthMatrix2DStmtNode(s).Rows, names);
        CollectVarNamesInExpr(TSetLengthMatrix2DStmtNode(s).Cols, names);
      end
      else if s is TMethodCallStmtNode then
      begin
        names.Add(TMethodCallStmtNode(s).ObjName);
        for i:=0 to TMethodCallStmtNode(s).Args.Count-1 do
          CollectVarNamesInExpr(TMethodCallStmtNode(s).Args[i], names);
      end
      else if s is TFieldAssignStmtNode then
      begin
        if TFieldAssignStmtNode(s).Qualifier<>'' then names.Add(TFieldAssignStmtNode(s).Qualifier);
        CollectVarNamesInExpr(TFieldAssignStmtNode(s).ValueExpr, names);
      end
      else if s is TInlineVarStmtNode then
      begin
        if not boundNames.Contains(TInlineVarStmtNode(s).VarName) then boundNames.Add(TInlineVarStmtNode(s).VarName);
        CollectVarNamesInExpr(TInlineVarStmtNode(s).ValueExpr, names);
      end
      else if s is TTryStmtNode then
      begin
        for i:=0 to TTryStmtNode(s).BodyStmts.Count-1 do
          CollectVarNamesInStmt(TTryStmtNode(s).BodyStmts[i], names, boundNames);
        if TTryStmtNode(s).ExVarName<>'' then
          if not boundNames.Contains(TTryStmtNode(s).ExVarName) then boundNames.Add(TTryStmtNode(s).ExVarName);
        if TTryStmtNode(s).ExceptStmts<>nil then
          for i:=0 to TTryStmtNode(s).ExceptStmts.Count-1 do
            CollectVarNamesInStmt(TTryStmtNode(s).ExceptStmts[i], names, boundNames);
        if TTryStmtNode(s).FinallyStmts<>nil then
          for i:=0 to TTryStmtNode(s).FinallyStmts.Count-1 do
            CollectVarNamesInStmt(TTryStmtNode(s).FinallyStmts[i], names, boundNames);
      end
      else if s is TRaiseStmtNode then CollectVarNamesInExpr(TRaiseStmtNode(s).Expr, names)
      else if s is TInheritedCallStmtNode then
        for i:=0 to TInheritedCallStmtNode(s).Args.Count-1 do
          CollectVarNamesInExpr(TInheritedCallStmtNode(s).Args[i], names)
      else if s is TEventSubscribeStmtNode then
      begin
        if TEventSubscribeStmtNode(s).Qualifier<>'' then names.Add(TEventSubscribeStmtNode(s).Qualifier);
        // 람다 안에 또 람다(중첩 클로저)를 구독하는 경우는 이번 단계 범위 밖 — 안쪽 람다는
        // 여전히 "캡처 없음" 규칙(부모=fGlobalScope)으로 컴파일되어 바깥 값 참조 시 오류가 난다.
      end;
    end;

    // [Stage 64→68] 람다(익명 메서드) 본문을 컴파일한다. 캡처하는 바깥 지역변수가 없으면
    // 예전처럼 Program.__LambdaN이라는 static 메서드가 되고, aIL(호출부 IL)에는 Ldnull만
    // 남긴다. 캡처하는 변수가 있으면 __ClosureN이라는 작은 클래스를 새로 만들어 캡처 변수를
    // 그 인스턴스 필드로 담고, 람다 본문은 그 클래스의 인스턴스 메서드 Invoke가 된다 — aIL에는
    // 그 인스턴스를 새로 만들어 캡처 값들을 필드에 채워 넣은 뒤 그 인스턴스 참조를 남긴다
    // (곧이어 호출부가 Ldftn/Newobj로 델리게이트를 완성한다).
    // 캡처는 "델리게이트 생성 시점의 값 복사"로 이루어진다 — Invoke 시작 시 필드값을 지역
    // 슬롯으로 복사해 쓰고, 끝나면 다시 필드에 되돌려 쓴다. 그래서 같은 델리게이트 인스턴스가
    // 여러 번 호출돼도(예: 버튼을 여러 번 클릭) 그 사이의 값 변화(예: 클릭 횟수 누적)는
    // 유지되지만, 바깥 메서드의 원래 지역변수 자체와는 생성 시점에 이미 분리된 별도의
    // 복사본이라 델리게이트 생성 "이후" 서로의 변경이 반영되지는 않는다 — 진짜 참조 캡처가
    // 아니라 "인스턴스별로 유지되는 값 캡처"다. self/inherited는 여전히 지원하지 않는다.
    function EmitLambdaAsStaticMethod(aIL: ILGenerator; lam: TLambdaExprNode; expectedParamTypes: array of System.Type): MethodBuilder;
    var paramTypes: array of System.Type; effTags: array of TVarType; li: integer; lmb: MethodBuilder; lil: ILGenerator;
        savedLocalScope: TScope; lloc: LocalBuilder;
        names, boundNames, captured: List<string>; nm: string;
        clTB: TypeBuilder; clFields: Dictionary<string, FieldBuilder>; clCtor: ConstructorBuilder;
        clLoc: LocalBuilder; entry: TScopeEntry; capturedLocs: Dictionary<string, LocalBuilder>;
    begin
      fLambdaCounter:=fLambdaCounter+1;
      paramTypes:=new System.Type[lam.LamParams.Count];
      effTags:=new TVarType[lam.LamParams.Count];
      for li:=0 to lam.LamParams.Count-1 do
      begin
        if lam.LamParams[li].ParamType=vtInferred then
        begin
          // [Stage 68] 타입 미표기 매개변수 — 델리게이트 Invoke 시그니처(위치별)에서 CLR 타입을 가져온다.
          if (expectedParamTypes=nil) or (li>=expectedParamTypes.Length) then
            raise new Exception('람다 매개변수 "'+lam.LamParams[li].Name
              +'"의 타입을 추론할 수 없습니다 — 이벤트 구독 등 델리게이트 시그니처를 알 수 있는 문맥이 아닙니다. '
              +'타입을 명시하세요 (예: '+lam.LamParams[li].Name+': T).');
          paramTypes[li]:=expectedParamTypes[li];
          effTags[li]:=VarTypeTagFromClrType(paramTypes[li]);
        end
        else
        begin
          paramTypes[li]:=ResolveTopParamClrType(lam.LamParams[li]);
          effTags[li]:=lam.LamParams[li].ParamType;
        end;
      end;

      // [Stage 68] 캡처 분석: 람다 매개변수도 아니고 람다 안에서 새로 선언되지도 않으면서
      // 바깥(현재 컴파일 중인) 메서드의 지역 스코프에 실제로 존재하는 이름만 캡처 대상이다.
      names:=new List<string>;
      boundNames:=new List<string>;
      for li:=0 to lam.LamParams.Count-1 do boundNames.Add(lam.LamParams[li].Name);
      CollectVarNamesInStmt(lam.Body, names, boundNames);
      captured:=new List<string>;
      foreach nm in names do
        if fLocalScope.Has(nm) and (not boundNames.Contains(nm)) and (not captured.Contains(nm)) then
          captured.Add(nm);

      if captured.Count=0 then
      begin
        // ---- 캡처 없음: 예전과 동일한 static 메서드 ----
        aIL.Emit(OpCodes.Ldnull);
        lmb:=fMainTB.DefineMethod('__Lambda'+fLambdaCounter.ToString,
          MethodAttributes.Public or MethodAttributes.Static, typeof(System.Void), paramTypes);
        lil:=lmb.GetILGenerator;

        savedLocalScope:=fLocalScope;
        fLocalScope:=new TScope('lambda', fGlobalScope);
        for li:=0 to lam.LamParams.Count-1 do
        begin
          lloc:=lil.DeclareLocal(paramTypes[li]);
          fLocalScope.Declare(lam.LamParams[li].Name, lloc, effTags[li]);
          if (effTags[li]=vtObject) or (effTags[li]=vtInterface) then
          begin
            if fTypeBuilders.ContainsKey(lam.LamParams[li].ClassName) or fBuiltTypes.ContainsKey(lam.LamParams[li].ClassName) then
              fLocalScope.SetClassName(lam.LamParams[li].Name, lam.LamParams[li].ClassName)
            else
              fLocalScope.SetClrType(lam.LamParams[li].Name, paramTypes[li]);
          end;
          if li=0 then lil.Emit(OpCodes.Ldarg_0) else if li=1 then lil.Emit(OpCodes.Ldarg_1)
          else if li=2 then lil.Emit(OpCodes.Ldarg_2) else if li=3 then lil.Emit(OpCodes.Ldarg_3)
          else lil.Emit(OpCodes.Ldarg_S, byte(li));
          lil.Emit(OpCodes.Stloc, lloc);
        end;

        EmitStatement(lil, lam.Body);
        lil.Emit(OpCodes.Ret);

        fLocalScope:=savedLocalScope;
        Result:=lmb;
        exit;
      end;

      // ---- 캡처 있음: __ClosureN 클래스 생성 ----
      clTB:=fModB.DefineType('__Closure'+fLambdaCounter.ToString, TypeAttributes.Public, typeof(System.Object));
      clFields:=new Dictionary<string, FieldBuilder>;
      foreach nm in captured do
        clFields[nm]:=clTB.DefineField(nm, fLocalScope.GetLoc(nm).LocalType, FieldAttributes.Public);
      clCtor:=clTB.DefineDefaultConstructor(MethodAttributes.Public);

      // 1) 캡처 시점 — 바깥(호출부) IL에 인스턴스를 만들고 현재 지역변수 값들을 필드로 복사한다.
      clLoc:=aIL.DeclareLocal(clTB);
      aIL.Emit(OpCodes.Newobj, clCtor);
      aIL.Emit(OpCodes.Stloc, clLoc);
      foreach nm in captured do
      begin
        aIL.Emit(OpCodes.Ldloc, clLoc);
        aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(nm));
        aIL.Emit(OpCodes.Stfld, clFields[nm]);
      end;
      aIL.Emit(OpCodes.Ldloc, clLoc); // 델리게이트 target 인자로 스택에 남겨둠 (호출부가 이어서 Ldftn/Newobj)

      // 2) 인스턴스 메서드 Invoke 본문 컴파일
      lmb:=clTB.DefineMethod('Invoke', MethodAttributes.Public, typeof(System.Void), paramTypes);
      lil:=lmb.GetILGenerator;

      savedLocalScope:=fLocalScope;
      fLocalScope:=new TScope('lambda', fGlobalScope);

      capturedLocs:=new Dictionary<string, LocalBuilder>;
      foreach nm in captured do
      begin
        entry:=nil; savedLocalScope.TryResolve(nm, entry);
        lloc:=lil.DeclareLocal(clFields[nm].FieldType);
        lil.Emit(OpCodes.Ldarg_0); // this
        lil.Emit(OpCodes.Ldfld, clFields[nm]);
        lil.Emit(OpCodes.Stloc, lloc);
        fLocalScope.Declare(nm, lloc, entry.VType);
        if entry.ClassName<>'' then fLocalScope.SetClassName(nm, entry.ClassName);
        if entry.ClrType<>nil then fLocalScope.SetClrType(nm, entry.ClrType);
        capturedLocs[nm]:=lloc;
      end;

      for li:=0 to lam.LamParams.Count-1 do
      begin
        lloc:=lil.DeclareLocal(paramTypes[li]);
        fLocalScope.Declare(lam.LamParams[li].Name, lloc, effTags[li]);
        if (effTags[li]=vtObject) or (effTags[li]=vtInterface) then
        begin
          if fTypeBuilders.ContainsKey(lam.LamParams[li].ClassName) or fBuiltTypes.ContainsKey(lam.LamParams[li].ClassName) then
            fLocalScope.SetClassName(lam.LamParams[li].Name, lam.LamParams[li].ClassName)
          else
            fLocalScope.SetClrType(lam.LamParams[li].Name, paramTypes[li]);
        end;
        // 인스턴스 메서드라 arg0=this, 실제 람다 매개변수는 arg1부터 시작한다.
        if li=0 then lil.Emit(OpCodes.Ldarg_1) else if li=1 then lil.Emit(OpCodes.Ldarg_2)
        else if li=2 then lil.Emit(OpCodes.Ldarg_3)
        else lil.Emit(OpCodes.Ldarg_S, byte(li+1));
        lil.Emit(OpCodes.Stloc, lloc);
      end;

      EmitStatement(lil, lam.Body);

      // 3) 실행 후 지역 슬롯 값을 다시 필드에 되돌려 쓴다 — 같은 델리게이트의 다음 호출에서도 유지되도록.
      foreach nm in captured do
      begin
        lil.Emit(OpCodes.Ldarg_0);
        lil.Emit(OpCodes.Ldloc, capturedLocs[nm]);
        lil.Emit(OpCodes.Stfld, clFields[nm]);
      end;

      lil.Emit(OpCodes.Ret);
      fLocalScope:=savedLocalScope;

      clTB.CreateType;
      Result:=lmb;
    end;

    // [Stage 41] 지역 변수(TVarDecl)의 실제 CLR 타입을 결정한다. ResolveTopParamClrType과 동일한 패턴 —
    // VarType=vtObject이고 IsExternal이면(예: var sb: System.Text.StringBuilder;) 점(.)으로 연결된
    // 외부 .NET 타입 이름을 ResolveExternalType으로 실제 로드된 Type으로 바꾼다. 이전에는 VTC가
    // 로컬 클래스(fBuiltTypes/fTypeBuilders)만 알아서, 외부 타입 지역변수는 전부 System.Object로
    // 선언되어 그 위에서 멤버 호출/속성 접근을 할 수 없었다.
    function ResolveLocalVarClrType(lv: TVarDecl): System.Type;
    begin
      if (lv.VarType=vtObject) and lv.IsExternal then Result:=ResolveExternalType(lv.ClassName)
      else Result:=VTC(lv.VarType, lv.ClassName);
    end;

    // [Stage 61] const 선언 하나를 aScope(fLocalScope 또는 fGlobalScope)에 슬롯으로 선언하고
    // 그 자리에서 곧바로 초기값을 대입한다. "var x := 식;"(TInlineVarStmtNode) 처리와 같은
    // 패턴을 재사용한다 — 타입 명시가 없으면(HasExplicitType=false) InferType으로 추론하고,
    // 있으면 그 타입을 그대로 쓴다. 전역/지역 모두 결국 "선언 직후 한 번 대입하는 슬롯"으로
    // 구현되므로(재대입을 막는 검사는 아직 하지 않음) 같은 헬퍼를 공유할 수 있다.
    procedure EmitConstDecl(aIL: ILGenerator; aScope: TScope; cd: TConstDecl);
    var vt: TVarType; clrType: System.Type; clsName: string; isExtT: boolean; loc: LocalBuilder;
    begin
      clsName:=cd.ClassName; isExtT:=cd.IsExternal;
      if cd.HasExplicitType then
      begin
        vt:=cd.VarType;
        if (vt=vtObject) and isExtT then clrType:=ResolveExternalType(clsName)
        else clrType:=VTC(vt, clsName);
      end
      else
      begin
        vt:=InferType(cd.ValueExpr);
        if cd.ValueExpr is TNewObjectExprNode then
        begin
          // new Type(...) 이면 정확한 클래스명/외부 여부를 그 노드에서 직접 가져온다
          // (InferType은 vtObject라는 것만 알려줌 — TInlineVarStmtNode 처리와 동일한 이유).
          var neo:=TNewObjectExprNode(cd.ValueExpr);
          clsName:=neo.ClassName; isExtT:=neo.IsExternalType;
          if isExtT then clrType:=ResolveExternalType(clsName)
          else if fBuiltTypes.ContainsKey(clsName) then clrType:=fBuiltTypes[clsName]
          else if fTypeBuilders.ContainsKey(clsName) then clrType:=fTypeBuilders[clsName]
          else clrType:=typeof(System.Object);
        end
        else if cd.ValueExpr is TExternalCastExprNode then
        begin
          // TInlineVarStmtNode 쪽과 동일한 버그: SomeType(expr) 캐스트식의 실제
          // 타입을 반영하지 않으면 System.Object로 선언되어 이후 멤버 접근이 깨진다.
          var extCast:=TExternalCastExprNode(cd.ValueExpr);
          clrType:=ResolveExternalType(extCast.TargetType);
          isExtT:=true;
        end
        else
          clrType:=VTC(vt, '');
      end;
      loc:=aIL.DeclareLocal(clrType);
      aScope.Declare(cd.Name, loc, vt);
      if (vt=vtObject) or (vt=vtInterface) then
      begin
        if isExtT then aScope.SetClrType(cd.Name, clrType)
        else if (clsName<>'') and (fTypeBuilders.ContainsKey(clsName) or fBuiltTypes.ContainsKey(clsName)) then
          aScope.SetClassName(cd.Name, clsName)
        else
          aScope.SetClrType(cd.Name, clrType);
      end;
      EmitValueForVType(aIL, cd.ValueExpr, vt);
      aIL.Emit(OpCodes.Stloc, loc);
    end;

    // 인터페이스 TypeBuilder 생성 + 즉시 완성(CreateType)
    // 인터페이스는 클래스처럼 나중에 몸체를 채울 필요가 없으므로(메서드 시그니처뿐)
    // [Phase 1] 열거형을 Reflection.Emit으로 빌드한다.
    // 인터페이스·클래스보다 먼저 완성시켜야 필드/매개변수 타입으로 참조할 수 있다.
    procedure BuildEnumTypes(modBuilder: ModuleBuilder);
    var ed: TEnumDeclNode; eb: EnumBuilder; i: integer;
    begin
      foreach ed in fProg.EnumDecls do
      begin
        // EnumBuilder는 ModuleBuilder.DefineEnum으로 생성. int32 기반.
        eb:=modBuilder.DefineEnum(ed.Name, TypeAttributes.Public, typeof(integer));
        for i:=0 to ed.Members.Count-1 do
          eb.DefineLiteral(ed.Members[i], integer(i));
        fBuiltEnums[ed.Name]:=eb.CreateType;
      end;
    end;

    // [Stage 62] 레코드(값 타입)를 System.ValueType을 상속하는 TypeBuilder로 빌드한다.
    // 열거형 바로 다음, 인터페이스/클래스보다 먼저 완성시킨다 — 필드 타입은 지금 단계에서
    // 기본 타입/열거형/외부 .NET 타입으로만 제한되므로(Parser가 이미 검증) 이 시점에
    // 이미 열거형만 준비되어 있으면 충분하다. 메서드가 없으므로 클래스처럼 "껍데기 먼저,
    // 본문은 나중에" 두 단계로 나눌 필요가 없어 필드를 정의하자마자 곧바로 CreateType한다.
    //
    // 값 타입이므로 지역변수/매개변수 슬롯에 Ldloc/Stloc(또는 인자로 전달)만 해도 CLR이
    // 필드 전체를 그대로 복사해준다 — "대입 시 복사"라는 값 타입 의미론은 별도 코드 없이
    // 여기서 공짜로 따라온다. 다만 필드 자체를 읽거나 쓸 때는(예: p.X, p.X := 5) Ldfld/Stfld가
    // 값이 아니라 객체 참조 또는 관리 포인터를 요구하므로, 그 지점(EmitExpr의 TMethodCallExprNode
    // 0-인자 필드읽기, TFieldAssignStmtNode)에서는 Ldloc 대신 Ldloca를 써야 한다 — fRecordNames로 분기.
    procedure BuildRecordTypes(modBuilder: ModuleBuilder);
    var rd: TRecordDeclNode; rfd: TFieldDeclNode; rtb: TypeBuilder; rfb: FieldBuilder;
    begin
      foreach rd in fProg.RecordDecls do
      begin
        rtb:=modBuilder.DefineType(rd.Name,
          TypeAttributes.Public or TypeAttributes.SequentialLayout or TypeAttributes.Sealed,
          typeof(System.ValueType));
        fFieldBuilders[rd.Name]:=new Dictionary<string, FieldBuilder>;
        foreach rfd in rd.Fields do
        begin
          rfb:=rtb.DefineField(rfd.Name, ResolveFieldClrType(rfd), FieldAttributes.Public);
          fFieldBuilders[rd.Name][rfd.Name]:=rfb;
          // [Stage 66] 레코드 필드도 클래스와 동일하게 연산자 오버로딩 대상 판별용으로 기록
          if (rfd.FieldType=vtObject) and (not rfd.IsExternalType) and (rfd.ClassName<>'') then
          begin
            if not fFieldObjClassName.ContainsKey(rd.Name) then
              fFieldObjClassName[rd.Name]:=new Dictionary<string, string>;
            fFieldObjClassName[rd.Name][rfd.Name]:=rfd.ClassName;
          end;
        end;
        fBuiltTypes[rd.Name]:=rtb.CreateType;
        fRecordNames.Add(rd.Name);
      end;
    end;

    // 클래스들보다 먼저 완전히 빌드해둔다. 클래스가 AddInterfaceImplementation을
    // 호출할 때 완성된(Type, TypeBuilder 아님) 인터페이스 타입이 필요하기 때문.
    procedure BuildInterfaceShell(modBuilder: ModuleBuilder; id: TInterfaceDeclNode);
    var
      tb: TypeBuilder; sig: TMethodSignature; mb: MethodBuilder;
      paramTypes: array of System.Type; i: integer;
      methAttrs: MethodAttributes;
    begin
      tb:=modBuilder.DefineType(id.Name,
        TypeAttributes.Public or TypeAttributes.Interface or TypeAttributes.Abstract,
        nil);
      fInterfaceBuilders[id.Name]:=tb;

      // 인터페이스 메서드: 본문 없음 → Abstract + Virtual + NewSlot
      methAttrs:=MethodAttributes.Public or MethodAttributes.Abstract
        or MethodAttributes.Virtual or MethodAttributes.NewSlot or MethodAttributes.HideBySig;

      foreach sig in id.Methods do
      begin
        paramTypes:=new System.Type[sig.ParamNames.Count];
        for i:=0 to sig.ParamNames.Count-1 do
          paramTypes[i]:=ResolveParamClrType(sig, i);

        // [버그 수정] 반환 타입이 로컬 클래스(vtObject)면 sig.ReturnClassName을 VTC에 넘겨야
        // 정확한 CLR 타입을 얻는다 — ''를 넘기면 System.Object로 조용히 폴백한다.
        if sig.IsFunction then
          mb:=tb.DefineMethod(sig.Name, methAttrs, VTC(sig.ReturnType, sig.ReturnClassName), paramTypes)
        else
          mb:=tb.DefineMethod(sig.Name, methAttrs, typeof(System.Void), paramTypes);

        if not fMethodReturnTypes.ContainsKey(id.Name) then
          fMethodReturnTypes[id.Name]:=new Dictionary<string, TVarType>;
        fMethodReturnTypes[id.Name][sig.Name]:=sig.ReturnType;
      end;

      fBuiltInterfaces[id.Name]:=tb.CreateType;
    end;

    // 외부 어셈블리(WPF/WinForm/Avalonia 등)에서 dottedName(예: System.Windows.Window)에
    // 해당하는 Type을 찾는다. AddReferenceAssembly로 미리 등록된 어셈블리만 검색한다.
    // [Stage 86] class(IDisposable)처럼 네임스페이스 없이 짧게 쓴 이름 — 실제 레포 코드가
    // 흔히 쓰는 몇몇 기본 BCL 인터페이스/타입만 화이트리스트로 완전한 이름으로 바꿔준다.
    // 목록에 없으면 원래 이름 그대로 돌려주고(변화 없음), 이후 단계에서 필요해지면 추가한다.
    function ResolveWellKnownShortName(name: string): string;
    begin
      // [Stage 86] 기존 인터페이스 단축 이름
      if name='IDisposable' then Result:='System.IDisposable'
      else if name='IComparable' then Result:='System.IComparable'
      else if name='ICloneable' then Result:='System.ICloneable'
      else if name='IFormattable' then Result:='System.IFormattable'
      else if name='IEnumerable' then Result:='System.Collections.IEnumerable'
      else if name='IEnumerator' then Result:='System.Collections.IEnumerator'
      // [Stage 87] System.Windows.Forms 단축 이름
      else if name='Form'                then Result:='System.Windows.Forms.Form'
      else if name='Label'               then Result:='System.Windows.Forms.Label'
      else if name='Button'              then Result:='System.Windows.Forms.Button'
      else if name='TextBox'             then Result:='System.Windows.Forms.TextBox'
      else if name='Panel'               then Result:='System.Windows.Forms.Panel'
      else if name='GroupBox'            then Result:='System.Windows.Forms.GroupBox'
      else if name='ComboBox'            then Result:='System.Windows.Forms.ComboBox'
      else if name='ListBox'             then Result:='System.Windows.Forms.ListBox'
      else if name='CheckBox'            then Result:='System.Windows.Forms.CheckBox'
      else if name='RadioButton'         then Result:='System.Windows.Forms.RadioButton'
      else if name='PictureBox'          then Result:='System.Windows.Forms.PictureBox'
      else if name='TabControl'          then Result:='System.Windows.Forms.TabControl'
      else if name='TabPage'             then Result:='System.Windows.Forms.TabPage'
      else if name='TreeView'            then Result:='System.Windows.Forms.TreeView'
      else if name='ListView'            then Result:='System.Windows.Forms.ListView'
      else if name='ListViewItem'        then Result:='System.Windows.Forms.ListViewItem'
      else if name='ColumnHeader'        then Result:='System.Windows.Forms.ColumnHeader'
      else if name='ListViewGroup'       then Result:='System.Windows.Forms.ListViewGroup'
      else if name='MenuStrip'           then Result:='System.Windows.Forms.MenuStrip'
      else if name='ToolStrip'           then Result:='System.Windows.Forms.ToolStrip'
      else if name='StatusStrip'         then Result:='System.Windows.Forms.StatusStrip'
      else if name='ToolStripMenuItem'   then Result:='System.Windows.Forms.ToolStripMenuItem'
      else if name='ContextMenuStrip'    then Result:='System.Windows.Forms.ContextMenuStrip'
      else if name='TableLayoutPanel'    then Result:='System.Windows.Forms.TableLayoutPanel'
      else if name='FlowLayoutPanel'     then Result:='System.Windows.Forms.FlowLayoutPanel'
      else if name='SplitContainer'      then Result:='System.Windows.Forms.SplitContainer'
      else if name='SplitterPanel'       then Result:='System.Windows.Forms.SplitterPanel'
      else if name='DataGridView'        then Result:='System.Windows.Forms.DataGridView'
      else if name='RichTextBox'         then Result:='System.Windows.Forms.RichTextBox'
      else if name='NumericUpDown'       then Result:='System.Windows.Forms.NumericUpDown'
      else if name='TrackBar'            then Result:='System.Windows.Forms.TrackBar'
      else if name='ProgressBar'         then Result:='System.Windows.Forms.ProgressBar'
      else if name='Timer'               then Result:='System.Windows.Forms.Timer'
      else if name='OpenFileDialog'      then Result:='System.Windows.Forms.OpenFileDialog'
      else if name='SaveFileDialog'      then Result:='System.Windows.Forms.SaveFileDialog'
      else if name='FolderBrowserDialog' then Result:='System.Windows.Forms.FolderBrowserDialog'
      else if name='ColorDialog'         then Result:='System.Windows.Forms.ColorDialog'
      else if name='FontDialog'          then Result:='System.Windows.Forms.FontDialog'
      else if name='MessageBox'          then Result:='System.Windows.Forms.MessageBox'
      else if name='Application'         then Result:='System.Windows.Forms.Application'
      else if name='Control'             then Result:='System.Windows.Forms.Control'
      else if name='UserControl'         then Result:='System.Windows.Forms.UserControl'
      else if name='ContainerControl'    then Result:='System.Windows.Forms.ContainerControl'
      else if name='ScrollableControl'   then Result:='System.Windows.Forms.ScrollableControl'
      else if name='ToolStripPanel'      then Result:='System.Windows.Forms.ToolStripPanel'
      // [Stage 87] System.Drawing 단축 이름
      else if name='Font'                then Result:='System.Drawing.Font'
      else if name='FontFamily'          then Result:='System.Drawing.FontFamily'
      else if name='Color'               then Result:='System.Drawing.Color'
      else if name='Bitmap'              then Result:='System.Drawing.Bitmap'
      else if name='Image'               then Result:='System.Drawing.Image'
      else if name='Pen'                 then Result:='System.Drawing.Pen'
      else if name='Brush'               then Result:='System.Drawing.Brush'
      else if name='SolidBrush'          then Result:='System.Drawing.SolidBrush'
      else if name='Graphics'            then Result:='System.Drawing.Graphics'
      else if name='Icon'                then Result:='System.Drawing.Icon'
      // [Stage 87] System 단축 이름
      else if name='EventArgs'           then Result:='System.EventArgs'
      else if name='EventHandler'        then Result:='System.EventHandler'
      else if name='Exception'           then Result:='System.Exception'
      else if name='Object'              then Result:='System.Object'
      else if name='String'              then Result:='System.String'
      else if name='string'              then Result:='System.String' // [Stage 96] new string(ch, count) 등
      // [Stage 92] byte(x)/(byte)(x) 같은 .NET 원시 값 타입 캐스트가 쓸 소문자 별칭들.
      // Parser의 IsPrimitiveCastTypeName 화이트리스트와 짝을 이룬다.
      else if name='byte'                then Result:='System.Byte'
      else if name='sbyte'               then Result:='System.SByte'
      else if name='short'               then Result:='System.Int16'
      else if name='ushort'              then Result:='System.UInt16'
      else if name='int'                 then Result:='System.Int32'
      // [버그 수정] 이 컴파일러 자신의 소스(Lexer.pas/Parser.pas/Main.pas)는 .NET 별칭
      // 'int'가 아니라 파스칼 고유 타입명 'integer'/'int64'를 그대로 "integer.Parse(...)",
      // "int64.Parse(...)" 형태의 정적 호출 한정자로 쓴다. 'int'/'long'만 화이트리스트에
      // 있고 'integer'/'int64'가 빠져 있어서, ResolveWellKnownShortName이 이름을 그대로
      // 돌려주고(else Result:=name) System.Type.GetType('integer')/('int64')가 실패해
      // "외부 타입 integer를 찾을 수 없습니다" → (식 위치에서는) "알 수 없는 변수 integer"로
      // 이어졌다. 'int'/'long'과 동일한 CLR 타입으로 매핑한다.
      else if name='integer'             then Result:='System.Int32'
      else if name='int64'               then Result:='System.Int64'
      else if name='uint'                then Result:='System.UInt32'
      else if name='long'                then Result:='System.Int64'
      else if name='ulong'               then Result:='System.UInt64'
      else if name='single'              then Result:='System.Single'
      else if name='double'              then Result:='System.Double'
      else if name='decimal'             then Result:='System.Decimal'
      else if name='char'                then Result:='System.Char'
      else if (name='bool') or (name='boolean') then Result:='System.Boolean'
      else if name='object'              then Result:='System.Object'
      else Result:=name;
    end;

    function ResolveExternalType(dottedName: string): System.Type;
    var asm: Assembly; t: System.Type; prefix, candidate: string; candidates: array of string;
    begin
      // [Stage 86] "Dictionary<string,FileChangeWatcher>" 같은 외부 제네릭 타입 이름은
      // 별도 함수(ResolveExternalGenericType)에서 베이스 이름 + 타입 인자로 나눠 재귀적으로 조립한다.
      if dottedName.Contains('<') then begin Result:=ResolveExternalGenericType(dottedName); exit; end;

      // [Stage 86] 점(.)이 없는 이름이면 먼저 잘 알려진 짧은 이름 표에서 찾아본다.
      if not dottedName.Contains('.') then
        dottedName:=ResolveWellKnownShortName(dottedName);

      // 1) 어셈블리 지정 없이 바로 찾히는 경우 (mscorlib/coreLib에 있는 타입 등)
      t:=System.Type.GetType(dottedName);
      if t<>nil then begin Result:=t; exit; end;

      // 2) 이미 등록된(수동 {$reference} 포함) 참조 어셈블리들을 순서대로 검색
      foreach asm in fLoadedAssemblies do
      begin
        t:=asm.GetType(dottedName);
        if t<>nil then begin Result:=t; exit; end;
      end;

      // 3) [Stage 51] {$reference}가 없어도, dottedName이 "기본" 프레임워크 네임스페이스에
      // 속하면 GAC 어셈블리를 자동으로 Assembly.Load 시도한다. 가장 구체적인(긴) 접두사가
      // 우선하도록(예: "System.Windows.Forms"가 "System.Windows"보다 먼저) 직접 최장일치를 찾는다.
      var _bestPrefix:='';
      foreach prefix in fAutoAssemblyMap.Keys do
        if ((dottedName=prefix) or dottedName.StartsWith(prefix+'.')) and (prefix.Length>_bestPrefix.Length) then
          _bestPrefix:=prefix;

      if _bestPrefix<>'' then
      begin
        candidates:=fAutoAssemblyMap[_bestPrefix];
        foreach candidate in candidates do
        begin
          if fFailedAutoLoads.Contains(candidate) then continue;
          try
            asm:=Assembly.Load(candidate);
            fLoadedAssemblies.Add(asm);
            t:=asm.GetType(dottedName);
            if t<>nil then begin Result:=t; exit; end;
          except
            on E: Exception do fFailedAutoLoads.Add(candidate); // 이 어셈블리는 GAC에 없음 — 다음부터 재시도 안 함
          end;
        end;
      end;

      // [Stage 87] 화이트리스트와 fAutoAssemblyMap 모두에서 못 찾은 경우 —
      // 현재 AppDomain에 로드된 모든 어셈블리를 뒤져 단순 이름(점 없음) 또는 전체 경로로 탐색.
      // uses 절의 네임스페이스 탐색을 CodeGen 레벨에서 보완한다.
      foreach var _asm87cg in System.AppDomain.CurrentDomain.GetAssemblies() do
      begin
        try
          t:=_asm87cg.GetType(dottedName);
          if t<>nil then begin Result:=t; exit; end;
          // 단순 이름인 경우 어셈블리의 타입 목록에서 이름 끝 부분 일치로 탐색
          if not dottedName.Contains('.') then
            foreach var _tp87cg in _asm87cg.GetExportedTypes() do
              if _tp87cg.Name=dottedName then begin Result:=_tp87cg; exit; end;
        except
        end;
      end;

      raise new Exception('외부 타입 "'+dottedName+'"을(를) 찾을 수 없습니다. '+
        '기본 프레임워크(WinForms/WPF/System.*)가 아니라면 {$reference 어셈블리명.dll} 지시문으로 '+
        '해당 타입이 들어있는 어셈블리를 먼저 등록했는지 확인하세요.');
    end;

    // [Stage 99 버그 수정] "System.Reflection.Assembly.GetExecutingAssembly.Location"처럼
    // 정적 타입 경로 중간에 무인자 정적 메서드/프로퍼티 호출이 섞인 체인 — 예전에는
    // TMethodCallExprNode의 ObjName 전체("System.Reflection.Assembly.GetExecutingAssembly")를
    // 통째로 타입 이름으로 보고 ResolveExternalType을 호출해 항상 실패했다("...
    // GetExecutingAssembly을(를) 찾을 수 없습니다" — GetExecutingAssembly은 타입이 아니라
    // System.Reflection.Assembly의 무인자 정적 메서드이기 때문). 마지막 세그먼트(예: "Location")는
    // 호출부(EmitExpr/InferType)가 이미 mc.MethodName으로 별도 처리하므로 여기서는 다루지 않는다.
    //
    // 점으로 구분된 세그먼트를 뒤에서부터 하나씩 떼어내며, "떼어낸 나머지가 실제 타입으로
    // 해석되는지" 시도한다 — 해석되면 그 뒤에 남은 세그먼트들을 순서대로 무인자
    // 정적/인스턴스 멤버(프로퍼티 우선, 아니면 메서드)로 적용해 최종 CLR 타입을 얻는다.
    // aIL가 nil이 아니면 실제로 그 호출들의 IL도 함께 방출한다(InferType처럼 타입만
    // 필요할 때는 nil로 호출해 방출 없이 타입만 알아낸다). 성공하면 isInstance를 true로
    // 설정해 호출자에게 "이제 스택에 인스턴스가 로드된 상태"임을 알려준다 — 호출자가
    // 이어서 mc.MethodName을 정적이 아니라 인스턴스 멤버로 조회해야 하기 때문이다.
    function ResolveOrEmitStaticChain(aIL: ILGenerator; dottedPath: string; var isInstance: boolean): System.Type;
    var segs: array of string; splitAt, i: integer; prefix, seg: string;
        curType: System.Type; ok: boolean; emptyArgs: List<TExprNode>;
        pi99: PropertyInfo; mi99: MethodInfo; isStaticStep: boolean;
    begin
      Result:=nil; isInstance:=false;
      segs:=dottedPath.Split('.');
      if segs.Length<2 then exit;
      for splitAt:=segs.Length-1 downto 1 do
      begin
        prefix:=string.Join('.', segs, 0, splitAt);
        try curType:=ResolveExternalType(prefix); except curType:=nil; end;
        if curType=nil then continue;

        isStaticStep:=true;
        ok:=true;
        emptyArgs:=new List<TExprNode>;
        for i:=splitAt to segs.Length-1 do
        begin
          seg:=segs[i];
          pi99:=SafeGetProperty(curType, seg);
          if (pi99<>nil) and (pi99.GetGetMethod<>nil) then
          begin
            if aIL<>nil then
            begin
              if isStaticStep then aIL.Emit(OpCodes.Call, pi99.GetGetMethod)
              else aIL.Emit(OpCodes.Callvirt, pi99.GetGetMethod);
            end;
            curType:=pi99.PropertyType;
          end
          else
          begin
            mi99:=ResolveMethodByArity(curType, seg, emptyArgs, isStaticStep);
            if mi99=nil then begin ok:=false; break; end;
            if aIL<>nil then
            begin
              if isStaticStep then aIL.Emit(OpCodes.Call, mi99)
              else aIL.Emit(OpCodes.Callvirt, mi99);
            end;
            curType:=mi99.ReturnType;
          end;
          isStaticStep:=false;
        end;
        if ok then
        begin
          Result:=curType;
          isInstance:=true; // splitAt<segs.Length이므로 세그먼트를 최소 1개는 소비함 — 항상 인스턴스 상태
          exit;
        end;
      end;
    end;

    // [Stage 86] "Dictionary" 처럼 네임스페이스 없이 쓴 이름을 CLR 제네릭 오픈 타입의
    // 정식 이름(예: "System.Collections.Generic.Dictionary`2")으로 바꿔 ResolveExternalType으로
    // 찾는다. 이미 점(.)이 포함된 이름(예: "My.Custom.Namespace.Foo")은 그대로 arity만 붙인다.
    function ResolveExternalOpenGenericType(baseName: string; arity: integer): System.Type;
    var fq: string;
    begin
      if baseName.Contains('.') then
        fq:=baseName+'`'+arity.ToString
      else
      begin
        var _isWellKnownGenericColl:=
          (baseName='List') or (baseName='Queue') or (baseName='Stack') or (baseName='HashSet')
          or (baseName='LinkedList') or (baseName='SortedSet')
          or (baseName='IEnumerable') or (baseName='IEnumerator') or (baseName='IList')
          or (baseName='ICollection') or (baseName='IReadOnlyList') or (baseName='IReadOnlyCollection')
          or (baseName='Comparer') or (baseName='EqualityComparer')
          or (baseName='Dictionary') or (baseName='SortedList') or (baseName='SortedDictionary')
          or (baseName='KeyValuePair') or (baseName='IDictionary') or (baseName='IReadOnlyDictionary');
        if baseName='Nullable' then
          fq:='System.Nullable`'+arity.ToString
        else if _isWellKnownGenericColl then
          fq:='System.Collections.Generic.'+baseName+'`'+arity.ToString
        else
          // 알려진 짧은 이름이 아니면 mscorlib/coreLib에 바로 있을 가능성에 기대어
          // 이름 그대로 arity만 붙여 시도한다 (실패하면 ResolveExternalType이 명확한 오류를 낸다).
          fq:=baseName+'`'+arity.ToString;
      end;
      Result:=ResolveExternalType(fq);
    end;

    // [Stage 86] 제네릭 타입 인자 문자열 하나(예: "string", "FileChangeWatcher",
    // "System.Diagnostics.Process", 또는 중첩 제네릭 "List<string>")를 실제 CLR 타입으로 해석한다.
    function ResolveGenericArgClrType(tag: string): System.Type;
    begin
      tag:=tag.Trim;
      if tag.Contains('<') then begin Result:=ResolveExternalGenericType(tag); exit; end;
      // [Stage 98 버그 수정] "string[]"/"integer[]"/"FileChangeWatcher[]" 등 — 제네릭 타입
      // 인자 자리에 array of <T> 가 온 경우(ParseExternalGenericTypeArg가 "elemType[]" 형태의
      // 문자열로 인코딩해 넘긴다). 이전에는 이 "[]" 접미사를 전혀 인식하지 못하고 그대로
      // ResolveExternalType("string[]")을 호출해 "외부 타입 string[] 을(를) 찾을 수 없습니다"로
      // 실패했다 — VTC의 vtObjArray 분기만 "[]" 접미사를 이해했고 여기는 몰랐다. 원소 타입을
      // 재귀적으로 먼저 해석한 뒤 MakeArrayType으로 배열 CLR 타입을 조립한다.
      if tag.EndsWith('[]') then
      begin
        var _elemTag:=tag.Substring(0, tag.Length-2);
        Result:=ResolveGenericArgClrType(_elemTag).MakeArrayType;
        exit;
      end;
      if tag='integer' then Result:=typeof(integer)
      else if tag='string' then Result:=typeof(string)
      else if tag='boolean' then Result:=typeof(boolean)
      else if (tag='real') or (tag='double') then Result:=typeof(double)
      else if tag='char' then Result:=typeof(char)
      else if tag='int64' then Result:=typeof(int64)
      else
      begin
        // 로컬(사용자 정의) 클래스 — 아직 CreateType 전이라도 TypeBuilder를 제네릭 타입 인자로
        // 쓸 수 있으므로(Reflection.Emit이 허용) 완성된 타입을 우선하고, 없으면 TypeBuilder를 쓴다.
        if fBuiltTypes.ContainsKey(tag) then Result:=fBuiltTypes[tag]
        else if fTypeBuilders.ContainsKey(tag) then Result:=fTypeBuilders[tag]
        else Result:=ResolveExternalType(tag); // 외부 타입 이름 (기본/짧은 이름/점으로 연결된 이름)
      end;
    end;

    // [Stage 86] "Dictionary<string,FileChangeWatcher>" 같은 표기를 베이스 이름과 콤마로 구분된
    // 타입 인자 목록으로 나눈다 — 인자 자신이 중첩 제네릭(예: List<string>)일 수 있으므로
    // 괄호(<,>) 깊이를 추적해 최상위 콤마에서만 나눈다.
    function ResolveExternalGenericType(genericName: string): System.Type;
    var ltPos, gtPos, depth, i: integer; baseName, argsStr, curArg: string;
        argNames: List<string>; argTypes: array of System.Type; openType: System.Type;
    begin
      ltPos:=genericName.IndexOf('<');
      gtPos:=genericName.LastIndexOf('>');
      if (ltPos<0) or (gtPos<0) or (gtPos<ltPos) then
        raise new Exception('제네릭 타입 이름 형식이 올바르지 않습니다: "'+genericName+'"');
      baseName:=genericName.Substring(0, ltPos);
      argsStr:=genericName.Substring(ltPos+1, gtPos-ltPos-1);

      argNames:=new List<string>;
      curArg:=''; depth:=0;
      var argsChars:=argsStr.ToCharArray; // [주의] 문자열 s[i]는 1-based라 0-based 배열로 변환 후 순회 (Lexer.pas와 동일한 관례)
      for i:=0 to argsChars.Length-1 do
      begin
        if argsChars[i]='<' then begin depth:=depth+1; curArg:=curArg+argsChars[i].ToString; end
        else if argsChars[i]='>' then begin depth:=depth-1; curArg:=curArg+argsChars[i].ToString; end
        else if (argsChars[i]=',') and (depth=0) then
        begin argNames.Add(curArg); curArg:=''; end
        else curArg:=curArg+argsChars[i].ToString;
      end;
      if curArg.Trim<>'' then argNames.Add(curArg);

      argTypes:=new System.Type[argNames.Count];
      for i:=0 to argNames.Count-1 do
        argTypes[i]:=ResolveGenericArgClrType(argNames[i]);

      openType:=ResolveExternalOpenGenericType(baseName, argNames.Count);
      Result:=openType.MakeGenericType(argTypes);
    end;

    // [Stage 50] 인자 식(expr)이 런타임에 어떤 CLR 타입일지 최대한 추정한다.
    // 확신할 수 없으면 nil을 돌려주는데, 이는 오버로드 점수 계산에서 "중립"(감점도 가점도 없음)으로 처리된다.
    // 리터럴/지역변수(fLocalClrTypes, fLocalClass)는 정확히 알 수 있고, 그 외에는 InferType의
    // 대략적인 TVarType(string/boolean/integer)을 대표 CLR 타입으로 환산해서 쓴다.
    function InferArgClrType(e: TExprNode): System.Type;
    var vt: TVarType;
    begin
      Result:=nil;
      if e is TStrLiteralNode then Result:=typeof(string)
      else if e is TIntLiteralNode then Result:=typeof(integer)
      else if e is TBoolLiteralNode then Result:=typeof(boolean)
      else if e is TNilLiteralNode then Result:=nil // nil은 어떤 참조 타입에도 들어갈 수 있으므로 중립
      else if e is TVarRefNode then
      begin
        var vn50:=TVarRefNode(e).VarName;
        if fLocalScope.HasClrType(vn50) then Result:=fLocalScope.GetClrType(vn50)
        else if fGlobalScope.HasClrType(vn50) then Result:=fGlobalScope.GetClrType(vn50) // [전역 var 버그 수정]
        else if fLocalScope.HasClassName(vn50) then
        begin
          var cn50:=fLocalScope.GetClassName(vn50);
          if fBuiltTypes.ContainsKey(cn50) then Result:=fBuiltTypes[cn50]
          else if fTypeBuilders.ContainsKey(cn50) then Result:=fTypeBuilders[cn50];
        end
        else if fGlobalScope.HasClassName(vn50) then // [전역 var 버그 수정]
        begin
          var cn50b:=fGlobalScope.GetClassName(vn50);
          if fBuiltTypes.ContainsKey(cn50b) then Result:=fBuiltTypes[cn50b]
          else if fTypeBuilders.ContainsKey(cn50b) then Result:=fTypeBuilders[cn50b];
        end
        else
        begin
          // [버그 수정] vn50이 지역/전역 변수가 아니라 Self(현재 클래스)의 필드인 경우 —
          // 기존엔 여기서 바로 vtString/vtBoolean/vtInteger 셋만 보고 나머지(예: 외부 CLR
          // 타입 필드)는 전부 nil로 떨어졌다. nil은 ScoreParamMatch에서 "중립(0점)"으로
          // 처리되므로, 오버로드가 여러 개인 외부 메서드(예: ToolStripItemCollection.Add:
          // Add(string)/Add(Image)/Add(ToolStripItem))에 필드를 인자로 넘기면 모든 후보가
          // 동점이 되어 t.GetMethods() 나열 순서상 우연히 먼저 나온(엉뚱한) 오버로드가
          // 선택되는 문제가 있었다. Self 필드의 실제 FieldBuilder.FieldType을 먼저 확인해서
          // 이 경로로 정확한 타입을 돌려준다.
          var argFb50: FieldBuilder;
          if (fCurClassName<>'') and TryFindFieldBuilder(fCurClassName, vn50, argFb50) then
            Result:=argFb50.FieldType
          else
          begin
            vt:=InferType(e);
            case vt of
              vtString: Result:=typeof(string);
              vtBoolean: Result:=typeof(boolean);
              vtInteger: Result:=typeof(integer);
            end;
          end;
        end;
      end
      else if e is TFieldReadExprNode then
      begin
        // [Stage 76 버그수정 #2] "MainMenu.Items.Add(FileMenu)"처럼 인자가 한정자 없는
        // 필드 이름 하나("FileMenu")면, Parser는 이걸 TVarRefNode가 아니라
        // TFieldReadExprNode로 만든다(메서드 본문에서 매개변수/지역변수가 아닌 식별자는
        // 전부 이 노드가 됨 — Parser.pas 1039줄 참고). 그런데 바로 위 TVarRefNode 분기에
        // 있던 "Self 필드면 FieldBuilder.FieldType을 찾는다" 수정은 TVarRefNode만 처리해서
        // 실제로 필드 인자가 오는 이 경로(TFieldReadExprNode)는 여전히 못 잡고 있었다 —
        // 그 결과 InferType 폴백(vtString/vtBoolean/vtInteger 외엔 전부 nil=중립)으로
        // 떨어져 오버로드가 전부 동점 처리되고, GetMethods() 나열 순서상 우연히 먼저 나온
        // Add(string)이 선택돼 FileMenu가 실제로는 MainMenu.Items에 들어가지 않는 문제가
        // 있었다(FileMenu.Owner/GetCurrentParent가 계속 nil로 남음). 여기서 실제
        // FieldBuilder.FieldType을 찾아 정확한 타입을 돌려준다.
        var argFb52: FieldBuilder;
        var fn52:=TFieldReadExprNode(e).FieldName;
        if (fCurClassName<>'') and TryFindFieldBuilder(fCurClassName, fn52, argFb52) then
          Result:=argFb52.FieldType
        else
        begin
          // Self 필드가 아니면(예: 외부 상속 타입의 프로퍼티) 그 프로퍼티 타입도 확인해본다.
          var extSelf52:=FindExternalAncestorType(fCurClassName);
          if (extSelf52<>nil) and (SafeGetProperty(extSelf52, fn52)<>nil) then
            Result:=SafeGetProperty(extSelf52, fn52).PropertyType
          else
          begin
            vt:=InferType(e);
            case vt of
              vtString: Result:=typeof(string);
              vtBoolean: Result:=typeof(boolean);
              vtInteger: Result:=typeof(integer);
            end;
          end;
        end;
      end
      else if (e is TNewObjectExprNode) and TNewObjectExprNode(e).IsExternalType then
      begin
        // [Stage 76 버그수정] "new System.Drawing.PointF(...)" 같은 외부 타입 생성자 호출이
        // 인자로 쓰이면 그동안 이 함수가 nil(중립)을 돌려줬다. 그 결과 인자 개수는 같지만
        // 해당 자리 매개변수 타입이 다른 오버로드들(예: Graphics.DrawString의 PointF 버전과
        // RectangleF 버전)이 전부 동점 처리되어, GetMethods() 나열 순서상 우연히 먼저 나온
        // (때로는 값형식 레이아웃이 다른, 즉 호환 안 되는) 오버로드가 선택될 수 있었다.
        // 이 경우 스택에는 실제로 작은 구조체(PointF, 8바이트)만 쌓였는데 큰 구조체
        // (RectangleF, 16바이트)를 받는 메서드가 호출되어 인자 레이아웃이 어긋나
        // AccessViolationException으로 이어졌다. 생성자가 가리키는 실제 CLR 타입을
        // 정확히 돌려줘서 오버로드 점수 계산이 이 자리를 더 이상 중립으로 보지 않게 한다.
        try
          Result:=ResolveExternalType(TNewObjectExprNode(e).ClassName);
        except
          Result:=nil; // 타입을 못 찾아도 기존과 동일하게 중립 폴백
        end;
      end
      // [Stage 91] typeof(...)가 다른 호출의 인자로 쓰이는 경우(예: GetCustomAttributes(typeof(X), false))
      // — 정확히 System.Type을 돌려줘야 그 타입을 받는 오버로드가 올바르게 선택된다.
      else if e is TTypeOfExprNode then Result:=typeof(System.Type)
      // [Stage 90] TargetType(expr) 캐스트 결과가 다른 호출의 인자로 쓰이는 경우 — 캐스트 대상
      // 타입 자체가 정확한 CLR 타입이므로 오버로드 점수 계산에 그대로 쓸 수 있다.
      else if e is TExternalCastExprNode then
      begin
        try
          Result:=ResolveExternalType(TExternalCastExprNode(e).TargetType);
        except
          Result:=nil;
        end;
      end
      // [Stage 90] a.GetName().Version.ToString() 같은 체인이 다른 호출의 인자로 쓰이는 경우 —
      // GetExprClrType으로 실제 CLR 반환 타입을 정확히 돌려줘서 오버로드 점수 계산이 중립으로
      // 처리되지 않게 한다.
      else if e is TChainedMemberExprNode then
      begin
        try
          Result:=GetExprClrType(e);
        except
          Result:=nil;
        end;
      end
      // [버그 수정] SplitByDot(x)[0]처럼 후위 인덱싱 결과가 다른 호출의 인자로 쓰이는 경우도
      // TChainedMemberExprNode와 동일하게 GetExprClrType으로 정확한 타입을 구한다.
      else if e is TChainedIndexExprNode then
      begin
        try
          Result:=GetExprClrType(e);
        except
          Result:=nil;
        end;
      end
      // [버그 수정] MakeItem(...) 처럼 최상위 함수 호출 결과를 직접 다른 메서드의 인자로
      // 넘길 때(예: dgvModules.Items.Add(MakeItem(...))) InferArgClrType에 TFuncCallExprNode
      // 분기가 없어 마지막 else 폴백으로 떨어졌다. InferType은 vtObject를 반환하지만
      // case vt of 안에 vtObject 케이스가 없으므로 Result가 nil(중립)로 남았고,
      // ScoreParamMatch가 Add(string)/Add(ListViewItem) 양쪽을 모두 0점 동점으로 처리해
      // GetMethods() 나열 순서상 먼저 나온 Add(string)이 선택됐다. 그 결과 IL이
      // ListViewItem을 String으로 castclass하는 코드를 방출해 런타임에
      // InvalidCastException이 발생했다.
      // fMethods에 등록된 MethodBuilder.ReturnType으로 정확한 CLR 반환 타입을 구해
      // 오버로드 점수 계산이 올바른 후보를 선택하도록 한다.
      else if e is TFuncCallExprNode then
      begin
        var _fc50:=TFuncCallExprNode(e);
        try
          if fMethods.ContainsKey(_fc50.FuncName) then
          begin
            var _mbRet50:=fMethods[_fc50.FuncName].ReturnType;
            if (_mbRet50<>nil) and (_mbRet50<>typeof(System.Void)) then
              Result:=_mbRet50;
            // Result가 nil로 남으면 아래 공통 폴백(InferType)이 이어받는다
          end;
        except
          Result:=nil;
        end;
        // MethodBuilder에서 반환 타입을 못 찾은 경우 기존 InferType 폴백
        if Result=nil then
        begin
          vt:=InferType(e);
          case vt of
            vtString:  Result:=typeof(string);
            vtBoolean: Result:=typeof(boolean);
            vtInteger: Result:=typeof(integer);
          end;
        end;
      end
      else
      begin
        vt:=InferType(e);
        case vt of
          vtString: Result:=typeof(string);
          vtBoolean: Result:=typeof(boolean);
          vtInteger: Result:=typeof(integer);
        end;
      end;
    end;

    // [Stage 50] 매개변수 타입과 추정된 인자 타입의 궁합을 점수로 매긴다.
    // 높을수록 더 잘 맞음. argType이 nil(추정 불가/신뢰 불가)이면 중립(0)을 준다.
    function ScoreParamMatch(paramType, argType: System.Type): integer;
    begin
      if argType=nil then begin Result:=0; exit; end;
      if paramType=argType then begin Result:=3; exit; end; // 정확히 일치
      try
        if paramType.IsAssignableFrom(argType) then begin Result:=2; exit; end; // 상속/인터페이스로 대입 가능
      except
        // argType이 아직 CreateType()되지 않은 TypeBuilder라 IsAssignableFrom이 지원 안 될 수 있다.
        // 이 경우 판단을 내릴 수 없으므로 감점하지 않고 중립으로 취급한다.
        Result:=0; exit;
      end;
      // 흔한 값형식 폭 넓히기 변환(int→long/double 등)은 이 컴파일러가 아직 int 하나만 다루므로
      // 별도 처리 없이, 나머지는 전부 "명백히 안 맞음"으로 크게 감점한다(하드 실격은 아님 —
      // 다른 후보가 전혀 없을 때를 대비해 여전히 폴백은 가능하게 둔다).
      Result:=-100;
    end;

    // 외부 타입에서 이름+인자개수로 메서드를 찾는다. [Stage 50] 개수만 보던 것에서
    // 나아가, 개수가 같은 후보가 여럿이면 각 인자의 추정 타입과 매개변수 타입을 비교해
    // 가장 궁합이 좋은 오버로드를 고른다(예: Show(string)과 Show(Window) 중 문자열 인자면 전자를 선택).
    // 타입을 전혀 추정할 수 없는 경우(예: 인자 없음, 혹은 모든 인자가 nil)에는 개수만 맞는
    // 첫 번째 후보를 그대로 쓰는 기존 동작과 동일하게 동작한다.
    // ---------------------------------------------------------------
    // [Stage 86] TypeBuilderInstantiation 안전 래퍼
    //
    // TypeBuilderInstantiation(예: Dictionary<Box,Box>)은 .NET Reflection.Emit의
    // internal 타입으로, GetProperty/GetMethods/GetConstructor/GetConstructors 등
    // 대부분의 리플렉션 메서드를 NotSupportedException으로 막아 놓는다.
    // 열린 제네릭 정의(GetGenericTypeDefinition())에서 멤버를 찾은 뒤
    // TypeBuilder.GetMethod / TypeBuilder.GetConstructor 로 닫힌 버전을 얻는 것이
    // .NET이 공식으로 제공하는 우회 방법이다.
    //
    // DeclaringType 필터 이유:
    //   TypeBuilder.GetMethod/GetConstructor의 제약 —
    //   method/ctor의 DeclaringType이 반드시 열린 제네릭 타입 정의 자체여야 한다.
    //   Object 등 상위 클래스에서 상속된 멤버는 DeclaringType이 다르므로 건너뜀.
    // ---------------------------------------------------------------
    function SafeGetProperty(t: System.Type; name: string): PropertyInfo;
    var curT91: System.Type; props91: array of PropertyInfo; p91: PropertyInfo;
    begin
      if t.GetType().Name = 'TypeBuilderInstantiation' then
      begin
        // [Stage 99 버그 수정] 예전에는 여기서 곧바로 nil을 돌려줘서 List<TToken>.Count처럼
        // 원소 타입이 아직 CreateType 안 된 로컬 클래스인 제네릭 컬렉션의 프로퍼티 접근이
        // 전부 "메서드가 없습니다" 오류로 실패했다. SafeGetMethods/SafeGetConstructor(s)와
        // 동일한 우회법(열린 제네릭 정의에서 멤버를 찾고 TypeBuilder.GetMethod로 그 접근자
        // 만 닫힌 버전에 바인딩)을 get_/set_ 메서드에 적용해 TBoundGenericPropertyInfo로
        // 감싸 돌려준다.
        var openT99 := t.GetGenericTypeDefinition();
        var openProp99: PropertyInfo := nil;
        foreach var op99 in openT99.GetProperties(BindingFlags.Public or BindingFlags.NonPublic or
                                                    BindingFlags.Instance or BindingFlags.Static) do
          if (op99.Name = name) and (op99.DeclaringType = openT99) then
          begin openProp99 := op99; break; end;
        if openProp99 = nil then begin Result := nil; exit; end;

        var boundGetter99: MethodInfo := nil;
        var boundSetter99: MethodInfo := nil;
        if openProp99.GetGetMethod(true) <> nil then
          boundGetter99 := TypeBuilder.GetMethod(t, openProp99.GetGetMethod(true));
        if openProp99.GetSetMethod(true) <> nil then
          boundSetter99 := TypeBuilder.GetMethod(t, openProp99.GetSetMethod(true));

        Result := new TBoundGenericPropertyInfo(openProp99, t, boundGetter99, boundSetter99);
        exit;
      end;
      try
        Result := t.GetProperty(name);
      except
        // [버그 수정] 이전에는 System.Reflection.AmbiguousMatchException만 잡았다. 그런데
        // GroupCollection.Item처럼 이름은 같고 인자 타입만 다른(int/string) 인덱서가 두 개
        // 이상 있을 때 t.GetProperty(name)이 실제로 AmbiguousMatchException을 던지는 게
        // 맞지만, 만에 하나 여기서 그 특정 타입과 정확히 매치되지 않는 경우(어셈블리 로드
        // 컨텍스트 차이 등) 예외가 이 on절을 통과하지 못하고 그대로 위로 전파되어, 이 함수를
        // 부르는 GetExprClrType의 바깥쪽 포괄 except가 조용히 System.Object로 폴백해버린다
        // (그 결과 m.Groups[2].Value처럼 실제로는 존재하는 멤버가 "System.Object에 멤버
        // ...가 없습니다"로 잘못 보고된다). 어떤 예외든 동일한 DeclaredOnly 폴백을 타도록
        // on절 없는 포괄 except로 넓힌다 — 아래 로직 자체는 기존 AmbiguousMatchException
        // 대응과 동일하다(가장 파생된 타입에서 이름이 일치하는 첫 선언을 사용).
        Result := nil;
        curT91 := t;
        while curT91 <> nil do
        begin
          try
            props91 := curT91.GetProperties(BindingFlags.Public or BindingFlags.NonPublic or
                                              BindingFlags.Instance or BindingFlags.Static or
                                              BindingFlags.DeclaredOnly);
            foreach p91 in props91 do
              if p91.Name = name then begin Result := p91; break; end;
          except
          end;
          if Result <> nil then break;
          curT91 := curT91.BaseType;
        end;
      end;
    end;

    function SafeGetMethods(t: System.Type; flags: BindingFlags): array of MethodInfo;
    begin
      if t.GetType().Name = 'TypeBuilderInstantiation' then
      begin
        var openT := t.GetGenericTypeDefinition();
        var openMis := openT.GetMethods(flags);
        var bound := new System.Collections.Generic.List<MethodInfo>();
        for var i86 := 0 to openMis.Length-1 do
          if openMis[i86].DeclaringType = openT then
            bound.Add(TypeBuilder.GetMethod(t, openMis[i86]));
        Result := bound.ToArray();
      end
      // [Stage 100 버그 수정] TypeBuilderInstantiation이 아니라 "그냥" 아직 CreateType 안
      // 된 로컬 클래스의 TypeBuilder 자체가 넘어온 경우도 t.GetMethods가 똑같이
      // NotSupportedException을 던진다. 이런 경우는 우리가 이미 fInstanceMethods에
      // 그 클래스의 메서드를 다 알고 있으니, 리플렉션 없이 바로 그걸 돌려준다.
      else if (t.GetType().Name = 'TypeBuilder') and (FindLocalClassNameForTypeBuilder(t) <> '') then
      begin
        var _localCls100b := FindLocalClassNameForTypeBuilder(t);
        var _bound100b := new System.Collections.Generic.List<MethodInfo>();
        if fInstanceMethods.ContainsKey(_localCls100b) then
          foreach var _mbKvp100b in fInstanceMethods[_localCls100b] do
            _bound100b.Add(_mbKvp100b.Value);
        Result := _bound100b.ToArray();
      end
      else
      begin
        // [성능] 완성된 외부 타입에서의 GetMethods(flags)는 같은 (타입,flags) 조합에 대해
        // 결과가 변하지 않으므로 캐시한다. AssemblyQualifiedName이 nil인 특수한 경우(드묾)엔
        // 캐시를 건너뛰고 항상 직접 조회한다.
        if t.AssemblyQualifiedName <> nil then
        begin
          var _mCacheKey := t.AssemblyQualifiedName + '|' + flags.ToString;
          if fMethodsCache.ContainsKey(_mCacheKey) then
            Result := fMethodsCache[_mCacheKey]
          else
          begin
            Result := t.GetMethods(flags);
            fMethodsCache[_mCacheKey] := Result;
          end;
        end
        else
          Result := t.GetMethods(flags);
      end;
    end;

    // GetConstructor(Type[]) 대용 — 인자 타입 배열로 생성자를 찾는다.
    function SafeGetConstructor(t: System.Type; paramTypes: array of System.Type): ConstructorInfo;
    begin
      if t.GetType().Name = 'TypeBuilderInstantiation' then
      begin
        var openT := t.GetGenericTypeDefinition();
        var openCtors := openT.GetConstructors(BindingFlags.Public or BindingFlags.Instance);
        for var ic := 0 to openCtors.Length-1 do
          if (openCtors[ic].DeclaringType = openT) and (openCtors[ic].GetParameters.Length = paramTypes.Length) then
          begin
            Result := TypeBuilder.GetConstructor(t, openCtors[ic]);
            exit;
          end;
        Result := nil;
      end
      else
        Result := t.GetConstructor(paramTypes);
    end;

    // GetConstructors 대용 — 모든 public 인스턴스 생성자를 반환한다.
    function SafeGetConstructors(t: System.Type): array of ConstructorInfo;
    begin
      if t.GetType().Name = 'TypeBuilderInstantiation' then
      begin
        var openT := t.GetGenericTypeDefinition();
        var openCtors := openT.GetConstructors(BindingFlags.Public or BindingFlags.Instance);
        var bound := new System.Collections.Generic.List<ConstructorInfo>();
        for var ic := 0 to openCtors.Length-1 do
          if openCtors[ic].DeclaringType = openT then
            bound.Add(TypeBuilder.GetConstructor(t, openCtors[ic]));
        Result := bound.ToArray();
      end
      else
      begin
        // [성능] SafeGetMethods와 동일한 이유로 완성된 외부 타입의 생성자 목록을 캐시한다.
        if t.AssemblyQualifiedName <> nil then
        begin
          if fCtorsCache.ContainsKey(t.AssemblyQualifiedName) then
            Result := fCtorsCache[t.AssemblyQualifiedName]
          else
          begin
            Result := t.GetConstructors(BindingFlags.Public or BindingFlags.Instance);
            fCtorsCache[t.AssemblyQualifiedName] := Result;
          end;
        end
        else
          Result := t.GetConstructors(BindingFlags.Public or BindingFlags.Instance);
      end;
    end;

    // [버그 수정] obj[i] 형태의 외부 컬렉션 인덱서 getter 호출을 하나의 함수로 뽑아냈다 —
    // 기존에는 TExternalIndexExprNode 처리부에 이 로직이 한 번만 인라인돼 있었는데, a[i][j]
    // (이중 인덱싱) 지원을 위해 같은 로직을 두 번 적용해야 해서 재사용 가능하게 분리했다.
    // 호출 전에 baseType 값의 인스턴스가 이미 스택에 올라가 있어야 하며, 호출 후에는
    // get_Item 결과(다음 단계 인덱싱 또는 최종 값)가 스택에 남는다. Result는 그 결과의 CLR 타입.
    function EmitIndexerGet(aIL: ILGenerator; baseType: System.Type; idxExpr: TExprNode): System.Type;
    var idxArgType: System.Type; itemProp: PropertyInfo; bestScore: integer;
    begin
      // [버그 수정] s[i] — Pascal 문자열 변수를 직접 인덱싱하는 경우(예: incName[1]).
      // 두 가지가 배열/일반 컬렉션과 다르다: (1) Pascal 문자열은 1-based인데 .NET
      // String의 실제 인덱서는 0-based이므로 인덱스에서 1을 빼야 한다. (2) System.String의
      // 기본 인덱서는 [IndexerName("Chars")]로 선언되어 있어 프로퍼티 이름이 "Item"이
      // 아니라 "Chars"다 — 아래의 범용 "Item" 프로퍼티 탐색은 String에서는 절대 못
      // 찾으므로 여기서 먼저 처리한다.
      if baseType=typeof(string) then
      begin
        EmitArgForParamType(aIL, idxExpr, typeof(integer));
        aIL.Emit(OpCodes.Ldc_I4_1);
        aIL.Emit(OpCodes.Sub);
        aIL.Emit(OpCodes.Callvirt, typeof(string).GetMethod('get_Chars', [typeof(integer)]));
        Result:=typeof(char);
        exit;
      end;
      // [Stage 96 버그 수정] baseType이 진짜 CLR 배열(T[], 예: "array of System.Type" 필드가
      // Dictionary 체인 인덱싱 뒤에 다시 인덱싱되는 경우, fMethodParamClrTypes[cn][mn][i])이면
      // 배열은 리플렉션 "Item" 프로퍼티를 노출하지 않으므로(IL 수준에서 ldelem으로 직접 처리되는
      // 컴파일러 내장 기능) 아래 프로퍼티 탐색은 항상 실패한다 — 여기서 먼저 배열이면 ldelem으로
      // 처리하고 원소 타입을 돌려준다.
      if baseType.IsArray then
      begin
        EmitArgForParamType(aIL, idxExpr, typeof(integer));
        var elemT96:=baseType.GetElementType;
        if not elemT96.IsValueType then aIL.Emit(OpCodes.Ldelem_Ref)
        else if elemT96=typeof(char) then aIL.Emit(OpCodes.Ldelem_I2)
        else if (elemT96=typeof(double)) then aIL.Emit(OpCodes.Ldelem_R8)
        else if elemT96=typeof(int64) then aIL.Emit(OpCodes.Ldelem_I8)
        else aIL.Emit(OpCodes.Ldelem_I4);
        Result:=elemT96;
        exit;
      end;
      idxArgType:=InferArgClrType(idxExpr);
      itemProp:=nil; bestScore:=System.Int32.MinValue;
      foreach var cand in baseType.GetProperties(BindingFlags.Public or BindingFlags.Instance) do
      begin
        if (cand.Name='Item') and (cand.GetIndexParameters.Length=1) and (cand.GetGetMethod<>nil) then
        begin
          var score:=ScoreParamMatch(cand.GetIndexParameters()[0].ParameterType, idxArgType);
          if (itemProp=nil) or (score>bestScore) then begin bestScore:=score; itemProp:=cand; end;
        end;
      end;
      if itemProp=nil then
        raise new Exception('타입 "'+baseType.FullName+'"에는 인덱서(Item)가 없습니다.');
      var idxParams:=itemProp.GetIndexParameters();
      EmitArgForParamType(aIL, idxExpr, idxParams[0].ParameterType);
      aIL.Emit(OpCodes.Callvirt, itemProp.GetGetMethod);
      Result:=itemProp.PropertyType;
    end;

    function ResolveMethodByArity(t: System.Type; mname: string; args: List<TExprNode>; isStatic: boolean): MethodInfo;
    var flags: BindingFlags; mi: MethodInfo; argCount: integer;
      bestScore: integer; bestMi: MethodInfo; found: boolean;
    begin
      if isStatic then flags:=BindingFlags.Public or BindingFlags.Static
      else flags:=BindingFlags.Public or BindingFlags.Instance;
      argCount:=args.Count;
      bestScore:=System.Int32.MinValue; bestMi:=nil; found:=false;
      foreach mi in SafeGetMethods(t, flags) do
        if (mi.Name=mname) and (mi.GetParameters.Length=argCount) then
        begin
          var ps50:=mi.GetParameters;
          var score50:=0;
          var i50:=0;
          while i50<argCount do
          begin
            var argType50:=InferArgClrType(args[i50]);
            score50:=score50+ScoreParamMatch(ps50[i50].ParameterType, argType50);
            i50:=i50+1;
          end;
          if (not found) or (score50>bestScore) then
          begin bestScore:=score50; bestMi:=mi; found:=true; end;
        end;
      Result:=bestMi;
    end;

    // [Stage 40] 외부 타입에서 인자 개수로 생성자를 찾는다. [Stage 50] 메서드와 동일하게
    // 인자 타입 궁합 점수까지 반영해서 여러 오버로드 중 가장 잘 맞는 것을 고른다.
    function ResolveConstructorByArity(t: System.Type; args: List<TExprNode>): ConstructorInfo;
    var ci: ConstructorInfo; argCount: integer;
      bestScore: integer; bestCi: ConstructorInfo; found: boolean;
    begin
      argCount:=args.Count;
      bestScore:=System.Int32.MinValue; bestCi:=nil; found:=false;
      foreach ci in SafeGetConstructors(t) do
        if ci.GetParameters.Length=argCount then
        begin
          var ps51:=ci.GetParameters;
          var score51:=0;
          var i51:=0;
          while i51<argCount do
          begin
            var argType51:=InferArgClrType(args[i51]);
            score51:=score51+ScoreParamMatch(ps51[i51].ParameterType, argType51);
            i51:=i51+1;
          end;
          if (not found) or (score51>bestScore) then
          begin bestScore:=score51; bestCi:=ci; found:=true; end;
        end;
      Result:=bestCi;
    end;

    // [Stage 99] 로컬(우리 컴파일러가 직접 정의한) 클래스의 생성자 오버로드 중에서
    // 인자 개수가 일치하는 것의 인덱스를 fCtorBuilders[className]/fCtorParamClrTypes[className]
    // 기준으로 찾는다. 같은 인자 개수의 오버로드가 여럿이면(타입만 다른 경우) 그중 첫
    // 번째를 고른다 — ResolveConstructorByArity(외부 .NET 타입용)처럼 인자 타입까지
    // 점수화하지는 않는다. 지금까지 실제로 나온 경우는 전부 인자 "개수"만으로 구분되므로
    // (예: TRangeExprNode의 Create(lo) vs Create(lo,hi)) 우선은 이 정도로 충분하고,
    // 같은 개수·다른 타입의 오버로드가 실제로 필요해지면 그때 타입 점수화를 추가한다.
    // 못 찾으면 -1.
    function FindLocalCtorIndex(className: string; argCount: integer): integer;
    var lst: List<array of System.Type>; i: integer;
    begin
      Result:=-1;
      if not fCtorParamClrTypes.ContainsKey(className) then exit;
      lst:=fCtorParamClrTypes[className];
      for i:=0 to lst.Count-1 do
        if lst[i].Length=argCount then begin Result:=i; exit; end;
    end;

    // [Stage 76 버그수정 #3] "var img := System.Drawing.Image.FromFile(path);"처럼 외부
    // static/instance 메서드 호출 결과를 지역 변수에 담을 때, 그동안 TInlineVarStmtNode
    // 처리부는 이 경우(ValueExpr이 TNewObjectExprNode가 아닌 TMethodCallExprNode)를
    // 별도로 보지 않고 VTC(vtObject, '') 폴백으로 무조건 System.Object 타입 지역 변수를
    // 만들었다. 그러면 IL 지역 슬롯의 선언 타입이 System.Object로 굳어져서, 이후
    // "NewToolButton.Image := img;"처럼 더 구체적인 타입(System.Drawing.Image)을 기대하는
    // 자리에 Ldloc으로 그 값을 올리면 검증기가 보는 스택 타입은 여전히 System.Object라
    // 명시적 Castclass 없이는 대입이 안 맞아 실행 시 InvalidProgramException으로 이어질
    // 수 있었다(아이콘 로드처럼 객체를 반환하는 외부 메서드 호출을 변수에 담아 재사용하는
    // 패턴에서 특히 발생하기 쉬움). 여기서 실제 반환 타입을 리플렉션으로 미리 찾아준다.
    // 흔한 경로(외부 정적 타입.메서드, 필드/지역변수.메서드)만 다루고, 판별 불가능한
    // 경우엔 기존과 동일하게 nil을 돌려줘 호출부가 기존 폴백을 쓰도록 한다.
    function TryResolveMethodCallClrType(mc: TMethodCallExprNode): System.Type;
    var qType: System.Type; pi: PropertyInfo; mi: MethodInfo; fb52: FieldBuilder;
    begin
      Result:=nil;
      try
        if mc.ObjCastType<>'' then
        begin
          qType:=ResolveExternalType(mc.ObjCastType);
        end
        else if (mc.ObjName<>'') and (mc.ObjName.IndexOf('.')>=0) then
        begin
          var chainSegs52:=SplitByDot(mc.ObjName);
          if IsChainStartSegment(chainSegs52[0]) then
            exit // 체인(예: MainMenu.Items.xxx)은 미리 계산하려면 IL을 실제로 방출해야
                 // 하므로(EmitQualifierChainLoad) 여기서는 다루지 않고 기존 폴백에 맡긴다.
          else
          begin
            qType:=nil;
            try qType:=ResolveExternalType(mc.ObjName); except end; // 외부 정적 타입 경로 (예: System.Drawing.Image)
            // [Stage 92] "(TypeName(expr)).member"가 괄호로 한 번 더 싸여 있으면 Parser가
            // 캐스트를 정적 호출(ObjName=한정자, MethodName=마지막 세그먼트)로 잘못 넘긴다
            // (EmitExpr의 TMethodCallExprNode 처리에 있는 것과 짝을 이루는 보정). ObjName이
            // 실제 타입이 아니라 네임스페이스뿐이면 위에서 qType이 nil이 되는데, 이때
            // ObjName+MethodName 전체가 진짜 타입이면 이 식 자체가 "그 타입으로의 캐스트"이므로
            // CLR 타입은 qType 위의 멤버가 아니라 캐스트 대상 타입 그 자체다.
            if (qType=nil) and (mc.Args.Count=1) then
            begin
              var _castT92: System.Type := nil;
              try _castT92:=ResolveExternalType(mc.ObjName+'.'+mc.MethodName); except end;
              if _castT92<>nil then begin Result:=_castT92; exit; end;
            end;
          end;
        end
        else if fLocalScope.Has(mc.ObjName) and fLocalScope.HasClrType(mc.ObjName) then
          qType:=fLocalScope.GetClrType(mc.ObjName)
        else if fGlobalScope.Has(mc.ObjName) and fGlobalScope.HasClrType(mc.ObjName) then
          qType:=fGlobalScope.GetClrType(mc.ObjName)
        else if (fCurClassName<>'') and TryFindFieldBuilder(fCurClassName, mc.ObjName, fb52) then
          qType:=fb52.FieldType
        // [Stage 77] "var dlg := new TNewProjectDialog;" 처럼 사용자 정의 클래스의 인스턴스는
        // ClrType이 아니라 ClassName으로만 스코프에 기록된다(TypeBuilder는 CreateType() 전엔
        // GetMethods/GetProperty가 온전히 동작하지 않으므로). 그래서 "var res := dlg.ShowDialog;"
        // 처럼 그 위에서 상속받은 외부 메서드(Form.ShowDialog 등)를 호출한 결과를 담을 때는
        // 이 함수가 무조건 nil로 빠져 잘못된 기본 타입(vtInteger→Int32)으로 지역 변수가
        // 선언됐다. 사용자 클래스의 외부 조상 타입(FindExternalAncestorType, 이미 완성된
        // 진짜 reflection Type이라 TypeBuilder 제약이 없다)에서 대신 찾는다.
        else if fLocalScope.Has(mc.ObjName) and fLocalScope.HasClassName(mc.ObjName) then
          qType:=FindExternalAncestorType(fLocalScope.GetClassName(mc.ObjName))
        else if fGlobalScope.Has(mc.ObjName) and fGlobalScope.HasClassName(mc.ObjName) then
          qType:=FindExternalAncestorType(fGlobalScope.GetClassName(mc.ObjName))
        // [버그 수정] string/정수/실수 등 원시 타입 지역·전역 변수는 ClrType도 ClassName도
        // 스코프에 기록되지 않는다(BuildStaticFunc 등의 지역변수 등록 루프가 vtObject/vtInterface일
        // 때만 채워 넣기 때문 — GetVarType 자체는 항상 정확하다). 그래서 "dirText.Substring(1).Trim"
        // 처럼 원시 타입 메서드 호출 결과 위에 체이닝이 이어지면, 이 함수가 무조건 nil로 빠져
        // GetExprClrType이 System.Object로 폴백하고, 그 위에서 Trim을 찾다가 "타입
        // System.Object에 멤버 Trim가 없습니다"로 실패했다. VTC(GetVarType(...), '')와 동일한
        // 매핑으로 실제 CLR 타입을 채워준다.
        else if (fLocalScope.Has(mc.ObjName) or fGlobalScope.Has(mc.ObjName))
                and ((GetVarType(mc.ObjName)=vtString) or (GetVarType(mc.ObjName)=vtInteger)
                     or (GetVarType(mc.ObjName)=vtInt64) or (GetVarType(mc.ObjName)=vtReal)
                     or (GetVarType(mc.ObjName)=vtBoolean) or (GetVarType(mc.ObjName)=vtChar)) then
          qType:=VTC(GetVarType(mc.ObjName), '')
        else
          exit;

        if qType=nil then exit;
        pi:=SafeGetProperty(qType, mc.MethodName);
        if (mc.Args.Count=0) and (pi<>nil) and (pi.GetGetMethod<>nil) then
        begin Result:=pi.PropertyType; exit; end;
        mi:=ResolveMethodByArity(qType, mc.MethodName, mc.Args, mc.ObjName.IndexOf('.')>=0);
        if mi<>nil then Result:=mi.ReturnType;
      except
        Result:=nil; // 무엇이든 실패하면 조용히 중립 폴백(기존 동작 유지)
      end;
    end;

    // [진단] TExternalIndexExprNode(obj[i]) 타입 추론용 — EmitIndexerGet(5630행 부근)과 정확히
    // 같은 "배열이면 원소 타입, 아니면 Item 인덱서 프로퍼티" 판별 로직이지만 IL을 방출하지
    // 않고 결과 타입만 계산한다. GetExprClrType은 EmitExpr처럼 IL 스트림에 명령을 낼 수 없는
    // 순수 타입 추론 함수라 EmitIndexerGet을 직접 재사용할 수 없어서 별도로 둔다.
    function InferIndexerResultType(baseType: System.Type; idxExpr: TExprNode): System.Type;
    var idxArgType97: System.Type; itemProp97: PropertyInfo; bestScore97: integer;
    begin
      Result:=nil;
      if baseType=nil then exit;
      if baseType=typeof(string) then begin Result:=typeof(char); exit; end;
      if baseType.IsArray then begin Result:=baseType.GetElementType; exit; end;
      idxArgType97:=InferArgClrType(idxExpr);
      itemProp97:=nil; bestScore97:=System.Int32.MinValue;
      foreach var cand97 in baseType.GetProperties(BindingFlags.Public or BindingFlags.Instance) do
        if (cand97.Name='Item') and (cand97.GetIndexParameters.Length=1) and (cand97.GetGetMethod<>nil) then
        begin
          var score97:=ScoreParamMatch(cand97.GetIndexParameters()[0].ParameterType, idxArgType97);
          if (itemProp97=nil) or (score97>bestScore97) then begin bestScore97:=score97; itemProp97:=cand97; end;
        end;
      if itemProp97<>nil then Result:=itemProp97.PropertyType;
    end;

    // [진단용] TStmtNode/TExprNode에는 소스 줄 번호가 없어서, "타입 System.Object에
    // 멤버 X가 없습니다" 같은 런타임 예외만으로는 소스의 어느 식이 문제인지 전혀 알 수
    // 없다(이번 오류가 바로 그 사례 — chType90가 System.Object로 폴백된 실제 원인 식을
    // 특정할 방법이 없었다). 줄 번호 추적을 AST 전체에 새로 넣는 대신, 체인을 사람이
    // 읽을 수 있는 형태(예: "dlg.Owner.Value", "self.fList[...]")로 재구성해 예외 메시지에
    // 실어 보낸다 — 소스에서 grep으로 바로 위치를 찾을 수 있게 하려는 목적뿐이므로 완벽할
    // 필요는 없고, 실패해도 조용히 "<?>"로 폴백한다.
    function DescribeExprChain(e: TExprNode): string;
    begin
      try
        if e = nil then begin Result:='<?>'; exit; end;
        if e is TVarRefNode then Result:=TVarRefNode(e).VarName
        else if e is TFieldReadExprNode then Result:='self.'+TFieldReadExprNode(e).FieldName
        else if e is TResultRefNode then Result:='Result'
        else if e is TChainedMemberExprNode then
        begin
          var _dc90:=TChainedMemberExprNode(e);
          if _dc90.IsCall then Result:=DescribeExprChain(_dc90.Inner)+'.'+_dc90.MemberName+'(...)'
          else Result:=DescribeExprChain(_dc90.Inner)+'.'+_dc90.MemberName;
        end
        else if e is TMethodCallExprNode then
          Result:=TMethodCallExprNode(e).ObjName+'.'+TMethodCallExprNode(e).MethodName+'(...)'
        else if e is TFuncCallExprNode then
          Result:=TFuncCallExprNode(e).FuncName+'(...)'
        else if e is TChainedIndexExprNode then
          Result:=DescribeExprChain(TChainedIndexExprNode(e).Target)+'[...]'
        else if e is TExternalIndexExprNode then
        begin
          var _dei90:=TExternalIndexExprNode(e);
          Result:=_dei90.Qualifier+'[...]';
          if _dei90.IndexExpr2<>nil then Result:=Result+'[...]';
          if _dei90.MemberName<>'' then Result:=Result+'.'+_dei90.MemberName;
        end
        else if e is TExternalCastExprNode then
          Result:=TExternalCastExprNode(e).TargetType+'('+DescribeExprChain(TExternalCastExprNode(e).InnerExpr)+')'
        else if e is TStrLiteralNode then Result:='<문자열리터럴>'
        else Result:='<'+e.GetType.Name+'>';
      except
        Result:='<?>';
      end;
    end;

    // [Stage 90] 임의의 식 e를 평가했을 때 스택에 올라오는 값의 실제 CLR Type을(가능한 한도까지)
    // 정적으로 추론한다 — TChainedMemberExprNode(예: a.GetName().Version)가 이어지는 멤버를
    // 리플렉션으로 찾으려면 그 왼쪽(Inner) 식의 CLR 타입을 먼저 알아야 하기 때문에 필요하다.
    // 판별 불가능하면 typeof(System.Object)로 안전하게 폴백한다(호출부가 멤버를 못 찾으면
    // 어차피 명확한 예외를 던지도록 되어 있으므로, 여기서 잘못 단정하는 것보다 안전하다).
    function GetExprClrType(e: TExprNode): System.Type;
    var _fb90: FieldBuilder;
    begin
      Result:=typeof(System.Object);
      try
        if e is TTypeOfExprNode then
        begin
          // [Stage 91] typeof(...)의 결과는 항상 System.Type.
          Result:=typeof(System.Type);
        end
        // [버그 수정] Result.Contains(x)처럼 함수 자신의 반환값(Result) 위에서 체이닝하는
        // 식 — 지금까지 GetExprClrType에 TResultRefNode 분기가 아예 없어서 무조건
        // System.Object로 폴백해 "타입 System.Object에 메서드 Contains가 없습니다"로
        // 실패했다. EmitQualifierChainLoad의 'Result' 세그먼트 처리와 동일하게
        // fResultLocal.LocalType을 그대로 돌려준다.
        else if e is TResultRefNode then
        begin
          if fResultLocal<>nil then Result:=fResultLocal.LocalType;
        end
        else if e is TExternalCastExprNode then
        begin
          // [Stage 90] TargetType(inner) — 캐스트 결과의 CLR 타입은 항상 TargetType 자체.
          Result:=ResolveExternalType(TExternalCastExprNode(e).TargetType);
        end
        else if e is TChainedMemberExprNode then
        begin
          var _ch90:=TChainedMemberExprNode(e);
          var _innerT90:=GetExprClrType(_ch90.Inner);
          if _innerT90=nil then exit;
          var _pi90:=SafeGetProperty(_innerT90, _ch90.MemberName);
          if (not _ch90.IsCall) and (_pi90<>nil) and (_pi90.GetGetMethod<>nil) then
          begin Result:=_pi90.PropertyType; exit; end;
          if not _ch90.IsCall then
          begin
            var _fi90:=_innerT90.GetField(_ch90.MemberName);
            if _fi90<>nil then begin Result:=_fi90.FieldType; exit; end;
          end;
          var _mi90:=ResolveMethodByArity(_innerT90, _ch90.MemberName, _ch90.Args, false);
          if _mi90<>nil then Result:=_mi90.ReturnType;
        end
        else if e is TMethodCallExprNode then
        begin
          var _rt90:=TryResolveMethodCallClrType(TMethodCallExprNode(e));
          if _rt90<>nil then Result:=_rt90;
        end
        // [버그 수정] SplitByDot(x)[0]처럼 최상위 지역 함수 호출 결과에 이어서 인덱싱/체이닝하려면
        // 먼저 그 함수의 실제 CLR 반환 타입을 알아야 한다 — InferArgClrType의 TFuncCallExprNode
        // 분기와 동일하게 fMethods에 등록된 MethodBuilder.ReturnType을 그대로 재사용한다.
        else if e is TFuncCallExprNode then
        begin
          var _fcn90:=TFuncCallExprNode(e);
          if fMethods.ContainsKey(_fcn90.FuncName) then
          begin
            var _fcnRet90:=fMethods[_fcn90.FuncName].ReturnType;
            if (_fcnRet90<>nil) and (_fcnRet90<>typeof(System.Void)) then Result:=_fcnRet90;
          end;
        end
        // [버그 수정] Target[Index] 인덱싱 결과의 타입 — Target이 배열이면 원소 타입,
        // 컬렉션(Item 인덱서)이면 그 프로퍼티 타입. 뒤에 또 '.Member'나 '[j]'가 이어지는
        // 3단 이상 체이닝(예: GetIndexParameters()[0].ParameterType)에서 필요하다.
        else if e is TChainedIndexExprNode then
        begin
          var _cix90:=TChainedIndexExprNode(e);
          var _cixT90:=GetExprClrType(_cix90.Target);
          if _cixT90<>nil then
          begin
            if _cixT90.IsArray then Result:=_cixT90.GetElementType
            else
            begin
              var _cixPi90:=SafeGetProperty(_cixT90, 'Item');
              if (_cixPi90<>nil) and (_cixPi90.GetGetMethod<>nil) then Result:=_cixPi90.PropertyType;
            end;
          end;
        end
        // [진단/버그 수정] Qualifier[Index] (obj[i], obj[i][j], obj[i].Field 등) — 지금까지
        // GetExprClrType에 이 분기가 아예 없어서, obj[i] 뒤에 .Member가 체이닝되는 식(예:
        // "map[key].Value")은 무조건 System.Object로 폴백해 "타입 System.Object에 멤버
        // Value가 없습니다"로 실패했다(DescribeExprChain으로 처음 확인된 실제 사례).
        // EmitExpr의 TExternalIndexExprNode 처리부와 동일한 순서로(Qualifier 체인 →
        // 인덱싱 → IndexExpr2/ExtraIndices → MemberName) 타입만 추론한다.
        else if e is TExternalIndexExprNode then
        begin
          var _eiG90:=TExternalIndexExprNode(e);
          var _eiSegs90:=SplitByDot(_eiG90.Qualifier);
          if IsChainStartSegment(_eiSegs90[0]) then
          begin
            var _eiBaseT90:=InferQualifierChainType(_eiSegs90);
            var _eiResT90:=InferIndexerResultType(_eiBaseT90, _eiG90.IndexExpr);
            if _eiG90.IndexExpr2<>nil then _eiResT90:=InferIndexerResultType(_eiResT90, _eiG90.IndexExpr2);
            if _eiG90.ExtraIndices<>nil then
              foreach var _eiExtra90 in _eiG90.ExtraIndices do
                _eiResT90:=InferIndexerResultType(_eiResT90, _eiExtra90);
            if _eiResT90<>nil then
            begin
              if _eiG90.MemberName='' then Result:=_eiResT90
              else
              begin
                var _eiPi90:=SafeGetProperty(_eiResT90, _eiG90.MemberName);
                if _eiPi90<>nil then Result:=_eiPi90.PropertyType
                else
                begin
                  var _eiFi90:=_eiResT90.GetField(_eiG90.MemberName);
                  if _eiFi90<>nil then Result:=_eiFi90.FieldType;
                end;
              end;
            end;
          end;
        end
        else if e is TVarRefNode then
        begin
          var _vn90:=TVarRefNode(e).VarName;
          if fLocalScope.Has(_vn90) and fLocalScope.HasClrType(_vn90) then Result:=fLocalScope.GetClrType(_vn90)
          else if fGlobalScope.Has(_vn90) and fGlobalScope.HasClrType(_vn90) then Result:=fGlobalScope.GetClrType(_vn90)
          else if fLocalScope.Has(_vn90) and fLocalScope.HasClassName(_vn90) then Result:=FindExternalAncestorType(fLocalScope.GetClassName(_vn90))
          else if fGlobalScope.Has(_vn90) and fGlobalScope.HasClassName(_vn90) then Result:=FindExternalAncestorType(fGlobalScope.GetClassName(_vn90));
        end
        else if e is TFieldReadExprNode then
        begin
          var _fnm90:=TFieldReadExprNode(e).FieldName;
          if TryFindFieldBuilder(fCurClassName, _fnm90, _fb90) then Result:=_fb90.FieldType
          else
          begin
            // [Stage 95 버그 수정] ClientSize처럼 자기 클래스가 직접 선언한 필드가 아니라
            // 외부 상속 타입(Form → ScrollableControl → Control 등)의 프로퍼티/필드일 때
            // 폴백이 없어서 함수 맨 위의 기본값 System.Object로 그냥 떨어졌다. 그 결과
            // "self.ClientSize.Height"처럼 체인으로 이어지는 바깥쪽 .Height가 System.Object
            // 위에서 Height를 찾다가 "타입 System.Object에 멤버 Height가 없습니다"로 터졌다.
            // IsChainStartSegment/EmitQualifierChainLoad가 이미 쓰는 것과 같은
            // FindExternalAncestorType 폴백을 여기도 추가한다.
            var _extAnc90:=FindExternalAncestorType(fCurClassName);
            if _extAnc90<>nil then
            begin
              var _extPi90:=SafeGetProperty(_extAnc90, _fnm90);
              if _extPi90<>nil then Result:=_extPi90.PropertyType
              else
              begin
                var _extFi90:=_extAnc90.GetField(_fnm90);
                if _extFi90<>nil then Result:=_extFi90.FieldType;
              end;
            end;
          end;
        end
        else if e is TNewObjectExprNode then
        begin
          var _no90:=TNewObjectExprNode(e);
          var _no90ElemT: System.Type;
          if _no90.IsExternalType then _no90ElemT:=ResolveExternalType(_no90.ClassName)
          else if fBuiltTypes.ContainsKey(_no90.ClassName) then _no90ElemT:=fBuiltTypes[_no90.ClassName]
          else _no90ElemT:=nil;
          if _no90ElemT<>nil then
          begin
            // [Stage 96] new Type[N](...)는 원소 타입이 아니라 배열 타입(Type[])을 낳는다 —
            // TChainedMemberExprNode 등이 이 노드를 Inner로 삼아 체인을 이어갈 때
            // (예: new T[N](...).Length) 잘못된 타입으로 멤버를 찾지 않도록 한다.
            if _no90.ArraySizeExpr<>nil then Result:=_no90ElemT.MakeArrayType()
            else Result:=_no90ElemT;
          end;
        end
        else if e is TStrLiteralNode then Result:=typeof(string)
        else if e is TIntLiteralNode then Result:=typeof(integer)
        else if e is TRealLiteralNode then Result:=typeof(double)
        else if e is TInt64LiteralNode then Result:=typeof(int64)
        else if e is TBoolLiteralNode then Result:=typeof(boolean)
        else if e is TCharLiteralNode then Result:=typeof(char);
      except
        Result:=typeof(System.Object); // 실패하면 안전한 폴백(멤버를 못 찾으면 호출부가 명확한 예외를 던짐)
      end;
      if Result=nil then Result:=typeof(System.Object);
    end;

    // [Stage 48] 외부 생성자/메서드에 인자를 하나씩 넣을 때, 기대하는 매개변수 타입이
    // 델리게이트(예: System.Threading.ThreadStart)이고 실제 인자가 최상위 프로시저
    // 이름 하나뿐이면(예: "new System.Threading.Thread(RunApp)") 그 이름을 호출하는 게
    // 아니라 델리게이트 인스턴스로 변환해서 넘긴다.
    //
    // [Stage 57] EmitArgForParamType과 같은 문제를, 목표 타입이 CLR System.Type이 아니라
    // TVarType(vtString 등)으로 추적되는 자리(지역/전역 변수 대입, Result 대입, 문자열
    // 배열 원소 대입)에서도 겪는다. 매개변수는 EmitArgForParamType이 이미 처리하지만
    // 그 함수는 System.Type을 받으므로, 여기서는 TVarType 버전을 별도로 둔다.
    // 대입문 규칙: 목표가 vtString이고 값이 TCharLiteralNode('a' 같은 한 글자 리터럴로
    // 오인식된 문자열 리터럴)면 Ldc_I4(문자코드) 대신 Ldstr(문자열)로 로드한다.
    procedure EmitValueForVType(aIL: ILGenerator; valueExpr: TExprNode; targetVType: TVarType);
    begin
      if (targetVType=vtString) and (valueExpr is TCharLiteralNode) then
        aIL.Emit(OpCodes.Ldstr, TCharLiteralNode(valueExpr).Value.ToString)
      else
        EmitExpr(aIL, valueExpr);
    end;

    // [버그 수정] Lexer가 따옴표 안이 정확히 한 글자면 무조건 tkCharLiteral로 만들기
    // 때문에('a' 처럼), string 매개변수 자리에 한 글자짜리 문자열을 넘기면
    // TCharLiteralNode가 되어 EmitExpr이 문자 코드값을 32비트 정수로 스택에 올려버렸다.
    // 그 정수값이 그대로 string 참조 자리에 들어가면서(예: ShowBoth<string>('a','b'))
    // 호출된 쪽에서 그 값을 문자열 객체 포인터로 잘못 역참조해 NullReferenceException이
    // 발생했다. 여기서 기대 타입이 string이고 인자가 char 리터럴이면 문자열로 승격한다.
    procedure EmitArgForParamType(aIL: ILGenerator; argExpr: TExprNode; paramType: System.Type);
    var _vr48: TVarRefNode; _delCtor48: ConstructorInfo;
    begin
      // [Stage 96] 일반 배열 리터럴([typeof(x), ...] 등)이 배열 매개변수 자리에 오는 경우 —
      // Newarr로 목표 매개변수의 실제 원소 타입(paramType.GetElementType)에 맞춰 배열을 만들고,
      // 각 원소는 재귀적으로 EmitArgForParamType에 맡긴다(원소 자체가 typeof(...)/문자열/변수 등
      // 임의의 식일 수 있으므로). Stage 92의 "new Type[n](e1,...)" 패턴과 동일한 Newarr/Stelem 관용구.
      if (argExpr is TArrayLiteralExprNode) and paramType.IsArray then
      begin
        var _alElemT96:=paramType.GetElementType;
        var _alElems96:=TArrayLiteralExprNode(argExpr).Elements;
        aIL.Emit(OpCodes.Ldc_I4, _alElems96.Count);
        aIL.Emit(OpCodes.Newarr, _alElemT96);
        for var _alI96:=0 to _alElems96.Count-1 do
        begin
          aIL.Emit(OpCodes.Dup);
          aIL.Emit(OpCodes.Ldc_I4, _alI96);
          EmitArgForParamType(aIL, _alElems96[_alI96], _alElemT96);
          if _alElemT96.IsValueType then aIL.Emit(OpCodes.Stelem, _alElemT96)
          else aIL.Emit(OpCodes.Stelem_Ref);
        end;
        exit;
      end;
      // [Stage 96] 빈 집합 리터럴 []은(Mask=0, EnumName='') 파서가 구분할 수 없는 경우(예:
      // GetMethod(name, [])처럼 "빈 배열"의 의미로 쓰였을 수도 있음) 배열 매개변수 자리에서는
      // 그냥 길이 0 배열로 취급한다.
      if (argExpr is TSetLiteralExprNode) and (TSetLiteralExprNode(argExpr).EnumName='')
         and (TSetLiteralExprNode(argExpr).Mask=0) and paramType.IsArray then
      begin
        aIL.Emit(OpCodes.Ldc_I4, 0);
        aIL.Emit(OpCodes.Newarr, paramType.GetElementType);
        exit;
      end;
      if (paramType=typeof(string)) and (argExpr is TCharLiteralNode) then
      begin
        aIL.Emit(OpCodes.Ldstr, TCharLiteralNode(argExpr).Value.ToString);
        exit;
      end;
      if (argExpr is TVarRefNode) and typeof(System.Delegate).IsAssignableFrom(paramType) then
      begin
        _vr48:=TVarRefNode(argExpr);
        if fMethods.ContainsKey(_vr48.VarName) and not fLocalScope.Has(_vr48.VarName)
           and not fGlobalScope.Has(_vr48.VarName) then
        begin
          // static 메서드를 가리키는 델리게이트이므로 대상 인스턴스는 없다(Ldnull).
          aIL.Emit(OpCodes.Ldnull);
          aIL.Emit(OpCodes.Ldftn, fMethods[_vr48.VarName]);
          _delCtor48:=paramType.GetConstructor([typeof(System.Object), typeof(System.IntPtr)]);
          if _delCtor48=nil then
            raise new Exception('델리게이트 타입 "'+paramType.FullName+'"의 생성자를 찾을 수 없습니다.');
          aIL.Emit(OpCodes.Newobj, _delCtor48);
          exit;
        end;
      end;
      // [Stage 76] emSize처럼 매개변수가 System.Single/Double(부동소수)인데 인자가 정수
      // 리터럴/식(vtInteger)이거나 실수 리터럴(vtReal, 항상 Ldc_R8로 8바이트로 실린다)이면
      // 폭 변환 없이 그대로 스택에 얹었었다 — 정수 4바이트를 그대로 float 슬롯으로 읽어버려
      // (예: new Font('맑은 고딕', 9) → emSize가 9가 아니라 사실상 0으로 들어감) 값이 깨졌다.
      // Conv_R4/Conv_R8로 명시적으로 변환해야 한다.
      if paramType=typeof(System.Single) then
      begin
        var _argVt76:=InferType(argExpr);
        EmitExpr(aIL, argExpr);
        if (_argVt76=vtInteger) or (_argVt76=vtReal) then aIL.Emit(OpCodes.Conv_R4);
        exit;
      end;
      if paramType=typeof(System.Double) then
      begin
        var _argVt76b:=InferType(argExpr);
        EmitExpr(aIL, argExpr);
        if _argVt76b=vtInteger then aIL.Emit(OpCodes.Conv_R8);
        exit;
      end;
      EmitExpr(aIL, argExpr);
      // [Stage 76 버그수정 #4] 방어적 안전망: 우리가 추적하는 인자의 CLR 타입(InferArgClrType)이
      // 목표 매개변수 타입보다 더 막연하면(nil이거나 System.Object로만 알고 있는 경우 — 예:
      // 아직 타입을 정확히 못 뒤쫓는 표현식 경로), 방금 스택에 올라간 값의 검증기 타입은
      // 실제로 System.Object로 남는다. 이 상태에서 목표가 더 구체적인 참조 타입이면(예:
      // System.Drawing.Image) Castclass 없이 그대로 Call/Callvirt에 넘길 경우 실행 시
      // InvalidProgramException으로 이어질 수 있다. paramType이 값형식/byref/제네릭
      // 매개변수/System.Object 자체가 아니고, 인자가 nil 리터럴도 아닐 때만 안전하게
      // Castclass를 끼워 넣는다 — 이미 정확한 타입이면 이 캐스트는 그냥 통과(무해)한다.
      if (not paramType.IsValueType) and (not paramType.IsByRef) and (not paramType.IsGenericParameter)
         and (paramType<>typeof(System.Object)) and (not (argExpr is TNilLiteralNode)) then
      begin
        var _knownArgT80:=InferArgClrType(argExpr);
        if (_knownArgT80=nil) or (_knownArgT80=typeof(System.Object)) then
          aIL.Emit(OpCodes.Castclass, paramType);
      end;
    end;

    // aIL 스택에 target 참조가 이미 로드되어 있다고 가정하고, 그 위에
    // targetType의 memberName 속성(setter)이나 필드에 valueExpr 값을 설정한다.
    procedure EmitPropertyOrFieldSet(aIL: ILGenerator; targetType: System.Type; memberName: string; valueExpr: TExprNode);
    var pi: PropertyInfo; fi: System.Reflection.FieldInfo; setr: MethodInfo;
        localClsName85: string; tbKvp85: System.Collections.Generic.KeyValuePair<string, TypeBuilder>;
    begin
      // [Stage 57] Button1.Text := 'a'; 같은 Qualifier.Field 대입 경로. 목표 속성/필드의
      // 실제 CLR 타입을 이미 알고 있으므로 EmitArgForParamType으로 char→string 승격.
      //
      // [Stage 85 수정] targetType이 아직 CreateType되지 않은 로컬 TypeBuilder(예:
      // fcw.Enabled := false; 에서 fcw: FileChangeWatcher — 사용자가 직접 정의한 클래스)이면
      // targetType.GetProperty/GetField가 NotSupportedException("Type has not been created.")을
      // 던진다. Stage 78에서 EmitQualifierChainLoad/InferQualifierChainType 두 곳은 이미
      // fTypeBuilders 역방향 조회로 고쳤지만, 여기(대입 경로)는 그대로 남아있던 알려진 취약점이다.
      // 같은 패턴으로: fTypeBuilders를 역방향 조회해 클래스명을 찾고, 프로퍼티 setter
      // (set_MemberName)나 일반 필드를 fInstanceMethods/fFieldBuilders에서 직접 찾는다.
      localClsName85:='';
      if targetType is TypeBuilder then
        foreach tbKvp85 in fTypeBuilders do
          if tbKvp85.Value = TypeBuilder(targetType) then
          begin localClsName85:=tbKvp85.Key; break; end;

      if (localClsName85<>'') and fInstanceMethods.ContainsKey(localClsName85)
         and fInstanceMethods[localClsName85].ContainsKey('set_'+memberName) then
      begin
        // 로컬 클래스의 프로퍼티 setter (필드가 아니라 write 접근자 메서드를 호출해야 하는 경우)
        var localSetM85: MethodBuilder := fInstanceMethods[localClsName85]['set_'+memberName];
        var localSetParamType85: System.Type := typeof(System.Object);
        if fMethodParamClrTypes.ContainsKey(localClsName85)
           and fMethodParamClrTypes[localClsName85].ContainsKey('set_'+memberName) then
          localSetParamType85:=fMethodParamClrTypes[localClsName85]['set_'+memberName][0];
        EmitArgForParamType(aIL, valueExpr, localSetParamType85);
        aIL.Emit(OpCodes.Callvirt, localSetM85);
      end
      else if (localClsName85<>'') and fFieldBuilders.ContainsKey(localClsName85)
         and fFieldBuilders[localClsName85].ContainsKey(memberName) then
      begin
        // 로컬 클래스의 (프로퍼티가 아닌) 공개 필드에 직접 대입하는 경우
        var localFb85: FieldBuilder := fFieldBuilders[localClsName85][memberName];
        EmitArgForParamType(aIL, valueExpr, localFb85.FieldType);
        aIL.Emit(OpCodes.Stfld, localFb85);
      end
      else if (localClsName85<>'') and (FindExternalAncestorType(localClsName85)<>nil) then
      begin
        // [Stage 98 버그 수정] targetType이 아직 CreateType되지 않은 로컬 TypeBuilder인데
        // memberName이 그 클래스가 직접 선언한 setter/필드가 아니라 외부 상속 타입(예:
        // FormChild : Form → Control의 Text)에서 물려받은 프로퍼티/필드인 경우 —
        // 위의 두 분기 모두 못 찾고 예전에는 곧장 targetType(TypeBuilder) 위에서
        // GetProperty를 불렀는데, TypeBuilder는 CreateType 전까지 리플렉션 조회 자체를
        // 지원하지 않아 "The invoked member is not supported in a dynamic module"으로
        // 터졌다. 외부 조상 타입 쪽에서 프로퍼티/필드를 찾고, 그 setter를 (가상 디스패치라
        // 인스턴스의 실제 런타임 타입과 무관하게 동작하는) Callvirt로 호출하면 된다.
        var _ancT98:=FindExternalAncestorType(localClsName85);
        var _ancPi98:=SafeGetProperty(_ancT98, memberName);
        if (_ancPi98<>nil) and (_ancPi98.GetSetMethod<>nil) then
        begin
          EmitArgForParamType(aIL, valueExpr, _ancPi98.PropertyType);
          aIL.Emit(OpCodes.Callvirt, _ancPi98.GetSetMethod);
        end
        else
        begin
          var _ancFi98:=_ancT98.GetField(memberName);
          if _ancFi98=nil then
            raise new Exception('타입 "'+localClsName85+'"(및 조상 "'+_ancT98.FullName+'")에 필드/속성 "'+memberName+'"가 없습니다.');
          EmitArgForParamType(aIL, valueExpr, _ancFi98.FieldType);
          aIL.Emit(OpCodes.Stfld, _ancFi98);
        end;
      end
      else
      begin
        // 기존 경로: 외부 CLR 타입, 또는 이미 CreateType된 타입
        pi:=SafeGetProperty(targetType, memberName);
        if pi<>nil then
        begin
          setr:=pi.GetSetMethod;
          if setr=nil then
            raise new Exception('속성 "'+targetType.FullName+'.'+memberName+'"에 setter가 없습니다 (읽기 전용).');
          EmitArgForParamType(aIL, valueExpr, pi.PropertyType);
          aIL.Emit(OpCodes.Callvirt, setr);
        end
        else
        begin
          fi:=targetType.GetField(memberName);
          if fi=nil then
            raise new Exception('타입 "'+targetType.FullName+'"에 필드/속성 "'+memberName+'"가 없습니다.');
          EmitArgForParamType(aIL, valueExpr, fi.FieldType);
          aIL.Emit(OpCodes.Stfld, fi);
        end;
      end;
    end;

    // 정적 필드/속성 설정 (예: System.Console.Title := '...'). 인스턴스 리시버가 없으므로
    // Callvirt/Stfld가 아니라 Call/Stsfld를 쓴다.
    procedure EmitStaticPropertyOrFieldSet(aIL: ILGenerator; targetType: System.Type; memberName: string; valueExpr: TExprNode);
    var pi2: PropertyInfo; fi2: System.Reflection.FieldInfo; setr2: MethodInfo;
    begin
      // [Stage 57] System.Console.Title := 'a'; 같은 정적 속성/필드 대입 경로도 동일하게 처리.
      pi2:=SafeGetProperty(targetType, memberName);
      if (pi2<>nil) and (pi2.GetSetMethod<>nil) then
      begin
        setr2:=pi2.GetSetMethod;
        EmitArgForParamType(aIL, valueExpr, pi2.PropertyType);
        aIL.Emit(OpCodes.Call, setr2);
      end
      else
      begin
        fi2:=targetType.GetField(memberName);
        if fi2=nil then
          raise new Exception('타입 "'+targetType.FullName+'"에 정적 필드/속성 "'+memberName+'"가 없습니다 (또는 읽기 전용).');
        EmitArgForParamType(aIL, valueExpr, fi2.FieldType);
        aIL.Emit(OpCodes.Stsfld, fi2);
      end;
    end;

    // 필드 선언의 실제 CLR 타입을 결정한다 (기본 타입/지역 클래스/외부 타입 모두 포함)
    function ResolveFieldClrType(fd: TFieldDeclNode): System.Type;
    begin
      if (fd.FieldType=vtObject) and fd.IsExternalType then
        Result:=ResolveExternalType(fd.ClassName)
      else
        Result:=VTC(fd.FieldType, fd.ClassName);
    end;

    // [Stage 83] 클래스 필드 인라인 기본값 초기화: className의 각 필드 중 DefaultValueExpr가
    // 있는 것들을 선언 순서대로 "Ldarg_0; <식>; Stfld"로 방출한다. 생성자 IL의 맨 앞부분에서
    // 호출되며(사용자 생성자가 있든 없든 동일), 필드 선언 순서를 그대로 대입 순서로 쓴다.
    // 1차 제약: 이 식이 실행되는 시점은 항상 생성자 본문의 맨 처음이다 — 사용자가 작성한
    // "inherited Create(...)" 호출이 본문 중간/끝에 있어도 그보다 먼저 실행된다(대부분의
    // 실제 코드는 inherited를 맨 앞에 두므로 실무상 차이가 없지만, 정확한 필드 초기화
    // 순서가 base 생성자 부작용에 의존하는 드문 경우는 1차 제약으로 남겨둔다).
    procedure EmitClassFieldDefaults(il: ILGenerator; className: string);
    var cd83: TClassDeclNode; fd83: TFieldDeclNode; fb83: FieldBuilder;
    begin
      cd83:=nil;
      foreach var c83 in fProg.ClassDecls do
        if c83.Name=className then begin cd83:=c83; break; end;
      if cd83=nil then exit; // 로컬 클래스가 아니면(있을 수 없지만 방어적으로) 그냥 무시
      foreach fd83 in cd83.Fields do
      begin
        if fd83.DefaultValueExpr=nil then continue;
        if not TryFindFieldBuilder(className, fd83.Name, fb83) then
          raise new Exception('필드를 찾을 수 없음(내부 오류): '+className+'.'+fd83.Name);
        il.Emit(OpCodes.Ldarg_0); // self
        EmitArgForParamType(il, fd83.DefaultValueExpr, fb83.FieldType);
        il.Emit(OpCodes.Stfld, fb83);
      end;
    end;

    // 클래스 TypeBuilder 생성 (필드 + 메서드 정의만, 본문은 아직)
    procedure BuildClassShell(modBuilder: ModuleBuilder; cd: TClassDeclNode);
    var
      tb: TypeBuilder; fd: TFieldDeclNode; sig: TMethodSignature;
      fb: FieldBuilder; mb: MethodBuilder;
      paramTypes: array of System.Type; i: integer;
      parentType: System.Type; parentCtor: ConstructorInfo;
      methAttrs: MethodAttributes;
    begin
      // 부모 클래스가 있으면 그 TypeBuilder를 기반 타입으로 사용
      // 로컬 클래스가 아니면(IsExternalParent) 참조된 외부 어셈블리에서 Reflection으로 찾는다
      if (cd.ParentName<>'') and fTypeBuilders.ContainsKey(cd.ParentName) then
        parentType:=fTypeBuilders[cd.ParentName]
      else if (cd.ParentName<>'') and cd.IsExternalParent then
      begin
        parentType:=ResolveExternalType(cd.ParentName);
        // [Stage 86] class(IDisposable) 같은 표기 — Parser는 "로컬 클래스도 로컬
        // 인터페이스도 아닌 이름"을 모두 IsExternalParent로 뭉뚱그리므로, 실제로 외부
        // 타입이 인터페이스인지 클래스인지는 여기서 리플렉션으로 갈라야 한다.
        // TypeBuilder.DefineType의 parent 인자에 인터페이스를 넣으면 예외가 나므로
        // (인터페이스는 상속이 아니라 "구현"), 그 경우 실제 부모는 System.Object로 두고
        // AddInterfaceImplementation으로 별도 등록한다(아래, tb 생성 직후).
        if parentType.IsInterface then
        begin
          fClassExternalInterfaceType[cd.Name]:=parentType;
          parentType:=typeof(System.Object);
        end
        else
          fClassExternalParentType[cd.Name]:=parentType;
      end
      else
        parentType:=typeof(System.Object);

      // [Stage 53] 이 클래스에 abstract 메서드가 하나라도 있으면 타입 자체도 Abstract여야 한다
      // (CLR 규칙: abstract 메서드를 가진 타입은 반드시 Abstract 타입이어야 CreateType()이 통과한다).
      var classHasAbstractMethod:=false;
      foreach var sigChk in cd.Methods do
        if sigChk.IsAbstract then classHasAbstractMethod:=true;

      var classTypeAttrs:=TypeAttributes.Public or TypeAttributes.Class;
      if classHasAbstractMethod then classTypeAttrs:=classTypeAttrs or TypeAttributes.Abstract;

      tb:=modBuilder.DefineType(cd.Name, classTypeAttrs, parentType);
      fTypeBuilders[cd.Name]:=tb;
      fFieldBuilders[cd.Name]:=new Dictionary<string, FieldBuilder>;
      fInstanceMethods[cd.Name]:=new Dictionary<string, MethodBuilder>;

      // 인터페이스 구현 등록 (완성된 인터페이스 Type이 필요 — 이미 위에서 다 만들어둠)
      // 이 클래스의 public+virtual 메서드가 이름/시그니처로 인터페이스 메서드와
      // 자동 매칭되어 암시적으로 구현된다 (별도의 DefineMethodOverride 불필요).
      if cd.InterfaceName<>'' then
      begin
        if not fBuiltInterfaces.ContainsKey(cd.InterfaceName) then
          raise new Exception('알 수 없는 인터페이스 "'+cd.InterfaceName+'"');
        tb.AddInterfaceImplementation(fBuiltInterfaces[cd.InterfaceName]);
      end;
      // [Stage 86] class(IDisposable)처럼 외부 인터페이스를 구현하는 경우 — 위에서
      // parentType 대신 별도로 보관해 둔 인터페이스 Type을 여기서 등록한다. 이 클래스가
      // (예: procedure Dispose;처럼) 이름/시그니처가 일치하는 public 메서드를 두면
      // CLR이 이름/시그니처로 자동 매칭해 암시적으로 구현한다 — 로컬 인터페이스와 동일한 방식.
      if fClassExternalInterfaceType.ContainsKey(cd.Name) then
        tb.AddInterfaceImplementation(fClassExternalInterfaceType[cd.Name]);

      // 필드
      foreach fd in cd.Fields do
      begin
        fb:=tb.DefineField(fd.Name, ResolveFieldClrType(fd), FieldAttributes.Public);
        fFieldBuilders[cd.Name][fd.Name]:=fb;
        // [Stage 66] self.필드/obj.필드 형태의 연산자 오버로딩 대상 판별용
        if (fd.FieldType=vtObject) and (not fd.IsExternalType) and (fd.ClassName<>'') then
        begin
          if not fFieldObjClassName.ContainsKey(cd.Name) then
            fFieldObjClassName[cd.Name]:=new Dictionary<string, string>;
          fFieldObjClassName[cd.Name][fd.Name]:=fd.ClassName;
        end;
      end;

      // [Stage 85] 프로퍼티(PropertyBuilder) 방출은 메서드 시그니처가 모두 정의된
      // 다음으로 옮겼다 — read/write 접근자가 필드가 아니라 메서드를 가리키는 경우
      // (예: property Enabled: boolean read FEnabled write SetEnabled;) 그 메서드의
      // MethodBuilder가 이미 존재해야 get/set 프로퍼티 메서드 본문에서 호출(Callvirt)할
      // 수 있기 때문이다. 실제 방출 코드는 아래 "메서드 시그니처만 정의" 블록 다음에 있다.

      // 메서드 시그니처만 정의
      // 모두 Virtual + HideBySig로 정의: 자식 클래스에서 같은 이름/시그니처의
      // 메서드를 정의하면 CLR이 이름/시그니처 매칭으로 자동 override(슬롯 재사용) 처리한다.
      // (virtual/override 지시자는 이미 이 기본 동작과 일치하므로 별도 분기가 필요 없다.
      //  abstract만 실제로 다르다: 본문이 없으므로 MethodAttributes.Abstract를 추가한다.)
      methAttrs:=MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig;
      foreach sig in cd.Methods do
      begin
        // [Stage 74] 메서드 자신의 오픈 제네릭 타입 매개변수(function Foo<T>(...))가 있으면
        // Stage71의 top-level 제네릭 함수와 같은 원리로 DefineGenericParameters 이후에야
        // 매개변수/반환 타입을 알 수 있다 — SetParameters/SetReturnType으로 나중에 지정한다.
        // (virtual/override/abstract와의 조합은 Parser가 이미 막아 두었다.)
        if sig.IsGeneric then
        begin
          mb:=tb.DefineMethod(sig.Name, methAttrs);
          var gpBuilders74:=mb.DefineGenericParameters(sig.GenericParamNames.ToArray);
          ApplyGenericParamConstraints(gpBuilders74, sig.GenericParamConstraints);
          var savedSubst74:=fCurGenericSubst;
          fCurGenericSubst:=new Dictionary<string, System.Type>;
          for i:=0 to sig.GenericParamNames.Count-1 do fCurGenericSubst[sig.GenericParamNames[i]]:=gpBuilders74[i];

          paramTypes:=new System.Type[sig.ParamNames.Count];
          for i:=0 to sig.ParamNames.Count-1 do paramTypes[i]:=ResolveParamClrType(sig, i);
          var retClrType74: System.Type;
          if sig.ReturnType=vtGeneric then retClrType74:=VTC(vtGeneric, sig.ReturnGenericName)
          // [버그 수정] vtObject(로컬 클래스) 반환 타입도 ReturnClassName을 넘겨야 한다.
          else if sig.IsFunction then retClrType74:=VTC(sig.ReturnType, sig.ReturnClassName)
          else retClrType74:=typeof(System.Void);
          mb.SetParameters(paramTypes);
          mb.SetReturnType(retClrType74);

          fInstanceMethods[cd.Name][sig.Name]:=mb;
          if not fMethodReturnTypes.ContainsKey(cd.Name) then
            fMethodReturnTypes[cd.Name]:=new Dictionary<string, TVarType>;
          fMethodReturnTypes[cd.Name][sig.Name]:=sig.ReturnType;
          if not fMethodParamClrTypes.ContainsKey(cd.Name) then
            fMethodParamClrTypes[cd.Name]:=new Dictionary<string, array of System.Type>;
          fMethodParamClrTypes[cd.Name][sig.Name]:=paramTypes;
          fMethodOpenGenericSubstOf[cd.Name+'.'+sig.Name]:=fCurGenericSubst; // [Stage 74] 빌드 패스가 재사용
          fCurGenericSubst:=savedSubst74;
        end
        else
        begin
          paramTypes:=new System.Type[sig.ParamNames.Count];
          for i:=0 to sig.ParamNames.Count-1 do
            paramTypes[i]:=ResolveParamClrType(sig, i);
          var thisMethAttrs:=methAttrs;
          if sig.IsAbstract then thisMethAttrs:=thisMethAttrs or MethodAttributes.Abstract;
          // [버그 수정] vtObject(로컬 클래스) 반환 타입도 ReturnClassName을 넘겨야 한다 —
          // ''를 넘기면 fBuiltTypes/fTypeBuilders 조회가 실패해 System.Object로 조용히
          // 폴백하고(예: function Cur: TToken), 이후 그 반환값에 체인 접근할 때
          // "타입 System.Object에 메서드 X가 없습니다"로 실패한다.
          if sig.IsFunction then
            mb:=tb.DefineMethod(sig.Name, thisMethAttrs, VTC(sig.ReturnType, sig.ReturnClassName), paramTypes)
          else
            mb:=tb.DefineMethod(sig.Name, thisMethAttrs, typeof(System.Void), paramTypes);
          fInstanceMethods[cd.Name][sig.Name]:=mb;
          if not fMethodReturnTypes.ContainsKey(cd.Name) then
            fMethodReturnTypes[cd.Name]:=new Dictionary<string, TVarType>;
          fMethodReturnTypes[cd.Name][sig.Name]:=sig.ReturnType;
          if not fMethodParamClrTypes.ContainsKey(cd.Name) then
            fMethodParamClrTypes[cd.Name]:=new Dictionary<string, array of System.Type>;
          fMethodParamClrTypes[cd.Name][sig.Name]:=paramTypes;
          // [Stage 53] abstract 메서드는 본문이 없다 — 사용자가 실수로 구현을 작성했을 때
          // BuildMethodBody가 GetILGenerator()를 부르면 Reflection.Emit이 알아보기 힘든
          // 예외를 던지므로, 여기서 미리 표시해두고 BuildMethodBody 쪽에서 친절한 오류를 낸다.
          if sig.IsAbstract then
          begin
            if not fAbstractMethods.ContainsKey(cd.Name) then
              fAbstractMethods[cd.Name]:=new List<string>;
            fAbstractMethods[cd.Name].Add(sig.Name);
          end;
        end;
      end;

      // [Phase 1, Stage 85 확장] 프로퍼티 — CLR PropertyBuilder + get/set 메서드 쌍으로 방출.
      // 메서드 시그니처 정의가 끝난 뒤에 처리하므로, read/write가 필드가 아니라
      // 메서드 이름을 가리키는 경우(예: property Enabled: boolean read FEnabled
      // write SetEnabled;)에도 그 메서드의 MethodBuilder를 이미 찾을 수 있다.
      foreach var ps in cd.Properties do
      begin
        var propClrType: System.Type;
        if (ps.PropType=vtObject) and ps.IsExternalType then
          propClrType:=ResolveExternalType(ps.PropClassName)
        else
          propClrType:=VTC(ps.PropType, ps.PropClassName);

        var pb:=tb.DefineProperty(ps.Name, PropertyAttributes.None, propClrType, nil);

        // getter
        if ps.ReadName<>'' then
        begin
          var getM:=tb.DefineMethod('get_'+ps.Name,
            MethodAttributes.Public or MethodAttributes.SpecialName or
            MethodAttributes.HideBySig or MethodAttributes.Virtual,
            propClrType, System.Type.EmptyTypes);
          var gIL:=getM.GetILGenerator;
          if fFieldBuilders.ContainsKey(cd.Name) and fFieldBuilders[cd.Name].ContainsKey(ps.ReadName) then
          begin
            // ReadName이 같은 클래스에 선언된 필드 이름인 경우 (기존 동작)
            gIL.Emit(OpCodes.Ldarg_0);
            gIL.Emit(OpCodes.Ldfld, fFieldBuilders[cd.Name][ps.ReadName]);
          end
          else if fInstanceMethods.ContainsKey(cd.Name) and fInstanceMethods[cd.Name].ContainsKey(ps.ReadName) then
          begin
            // [Stage 85] ReadName이 필드가 아니라 매개변수 없는 메서드(getter 함수)를
            // 가리키는 경우 — 그 메서드를 호출한 결과를 그대로 반환한다.
            gIL.Emit(OpCodes.Ldarg_0);
            gIL.Emit(OpCodes.Callvirt, fInstanceMethods[cd.Name][ps.ReadName]);
          end
          else
            raise new Exception('프로퍼티 "'+cd.Name+'.'+ps.Name+'" getter: 필드/메서드 "'+ps.ReadName+'"을 찾을 수 없습니다 (Stage 85)');
          gIL.Emit(OpCodes.Ret);
          pb.SetGetMethod(getM);
          fInstanceMethods[cd.Name]['get_'+ps.Name]:=getM;
        end;

        // setter
        if ps.WriteName<>'' then
        begin
          var setM:=tb.DefineMethod('set_'+ps.Name,
            MethodAttributes.Public or MethodAttributes.SpecialName or
            MethodAttributes.HideBySig or MethodAttributes.Virtual,
            typeof(System.Void), [propClrType]);
          var sIL:=setM.GetILGenerator;
          if fFieldBuilders.ContainsKey(cd.Name) and fFieldBuilders[cd.Name].ContainsKey(ps.WriteName) then
          begin
            // WriteName이 같은 클래스에 선언된 필드 이름인 경우 (기존 동작)
            sIL.Emit(OpCodes.Ldarg_0);
            sIL.Emit(OpCodes.Ldarg_1);
            sIL.Emit(OpCodes.Stfld, fFieldBuilders[cd.Name][ps.WriteName]);
          end
          else if fInstanceMethods.ContainsKey(cd.Name) and fInstanceMethods[cd.Name].ContainsKey(ps.WriteName) then
          begin
            // [Stage 85] WriteName이 필드가 아니라 매개변수 1개짜리 메서드(setter 메서드)를
            // 가리키는 경우 (예: property Enabled: boolean read FEnabled write SetEnabled;)
            // — 대입되는 값을 그대로 그 메서드에 넘겨 호출한다.
            sIL.Emit(OpCodes.Ldarg_0);
            sIL.Emit(OpCodes.Ldarg_1);
            sIL.Emit(OpCodes.Callvirt, fInstanceMethods[cd.Name][ps.WriteName]);
          end
          else
            raise new Exception('프로퍼티 "'+cd.Name+'.'+ps.Name+'" setter: 필드/메서드 "'+ps.WriteName+'"을 찾을 수 없습니다 (Stage 85)');
          sIL.Emit(OpCodes.Ret);
          pb.SetSetMethod(setM);
          fInstanceMethods[cd.Name]['set_'+ps.Name]:=setM;
          // [Stage 85] EmitPropertyOrFieldSet이 obj.Prop := val 대입 시 setter의 매개변수
          // CLR 타입을 알아야 하는데, MethodBuilder는 아직 CreateType 전이라 GetParameters가
          // 믿을 수 없다 — 여기서 미리 계산해 둔 propClrType을 등록해 재사용한다.
          if not fMethodParamClrTypes.ContainsKey(cd.Name) then
            fMethodParamClrTypes[cd.Name]:=new Dictionary<string, array of System.Type>;
          fMethodParamClrTypes[cd.Name]['set_'+ps.Name]:=[propClrType];
        end;
      end;

      // 기본 생성자 추가 (부모 생성자 호출로 체이닝)
      // [Stage 47] 클래스 선언부에 "constructor Create(...)"로 매개변수가 선언돼 있으면
      // 그 시그니처 그대로 정의한다 (선언 없으면 빈 매개변수 목록 → 기존과 동일).
      // [Stage 99] 오버로드된 생성자를 전부 지원하기 위해, "클래스 하나당 시그니처 하나"라고
      // 가정했던 cd.ConstructorParams(모든 오버로드가 뒤섞인 리스트) 대신 fProg.ConstructorImpls
      // 에서 이 클래스(cd.Name) 소유의 항목들을 그대로 가져와 "그 개수만큼" ConstructorBuilder를
      // 만든다 — Parser.pas Stage 99 수정 이후 각 impl은 자기 자신의 Parameters만 정확히
      // 갖고 있으므로 이게 곧 실제 오버로드 목록이다(순서=소스에 나온 순서).
      var thisClassCtorImpls:=new List<TConstructorImplNode>;
      if cd.HasUserConstructor then
        foreach var _ci99 in fProg.ConstructorImpls do
          if _ci99.ClassName=cd.Name then thisClassCtorImpls.Add(_ci99);

      var ctorBuilderList:=new List<ConstructorBuilder>;
      var ctorParamTypeList:=new List<array of System.Type>;

      if thisClassCtorImpls.Count>0 then
      begin
        foreach var _ci99b in thisClassCtorImpls do
        begin
          var _ctorParamTypes99:=new System.Type[_ci99b.Parameters.Count];
          for i:=0 to _ci99b.Parameters.Count-1 do
            _ctorParamTypes99[i]:=ResolveTopParamClrType(_ci99b.Parameters[i]);
          var _ctorBuilder99:=tb.DefineConstructor(
            MethodAttributes.Public, CallingConventions.Standard, _ctorParamTypes99);
          ctorBuilderList.Add(_ctorBuilder99);
          ctorParamTypeList.Add(_ctorParamTypes99);
        end;
      end
      else
      begin
        // 사용자 생성자 선언이 없는(HasUserConstructor=false) 경우: 예전과 동일하게
        // 매개변수 없는 생성자 1개만 만든다.
        var _ctorParamTypes99:=new System.Type[0];
        var _ctorBuilder99:=tb.DefineConstructor(
          MethodAttributes.Public, CallingConventions.Standard, _ctorParamTypes99);
        ctorBuilderList.Add(_ctorBuilder99);
        ctorParamTypeList.Add(_ctorParamTypes99);
      end;

      fCtorBuilders[cd.Name]:=ctorBuilderList;
      fCtorParamClrTypes[cd.Name]:=ctorParamTypeList;

      // [Stage 42] 사용자가 "constructor Create;"를 직접 선언한 클래스는 본문을 여기서 채우지
      // 않는다 — 이후 BuildConstructorBody가 ConstructorImpls에서 실제로 작성된 본문을
      // 컴파일해 넣는다 (inherited Create(...) 호출을 그 본문 안에서 원하는 위치에 직접
      // 쓸 수 있어야 하므로, 여기서 미리 "부모 호출 + Ret"를 넣어버리면 안 된다).
      if not cd.HasUserConstructor then
      begin
        var ctorIL:=ctorBuilderList[0].GetILGenerator;
        ctorIL.Emit(OpCodes.Ldarg_0);
        if (cd.ParentName<>'') and fCtorBuilders.ContainsKey(cd.ParentName) then
        begin
          // 부모가 아직 CreateType되지 않았으므로 GetConstructor 대신
          // 만들어둔 ConstructorBuilder를 그대로 재사용 (.NET Core는 미완성
          // TypeBuilder에 대한 GetConstructor 호출을 지원하지 않음)
          // [Stage 99] 부모도 생성자를 여러 개(오버로드) 가질 수 있으므로, 자동 체이닝은
          // 항상 매개변수 없는(0개) 오버로드를 찾아 호출한다.
          var _parentIdx99:=FindLocalCtorIndex(cd.ParentName, 0);
          if _parentIdx99<0 then
            raise new Exception('부모 클래스 "'+cd.ParentName+'"에 매개변수 없는 생성자가 없어 자식 클래스 "'+cd.Name
              +'"의 기본 생성자를 자동 생성할 수 없습니다. 자식 클래스에 생성자를 직접 선언하고 inherited Create(...)를 명시해주세요.');
          parentCtor:=fCtorBuilders[cd.ParentName][_parentIdx99];
        end
        else
        begin
          // 로컬에서 만든 클래스가 아니면(System.Object 또는 외부 어셈블리 타입)
          // parentType에서 직접 매개변수 없는 public 생성자를 찾는다.
          parentCtor:=parentType.GetConstructor(System.Type.EmptyTypes);
          if parentCtor=nil then
            raise new Exception('부모 타입 "'+parentType.FullName+'"에 매개변수 없는 public 생성자가 없습니다.');
        end;
        ctorIL.Emit(OpCodes.Call, parentCtor);
        // [Stage 83] 사용자 생성자가 없는 클래스도 필드 인라인 기본값은 적용돼야 한다.
        // 이 시점(클래스 껍데기 빌드 단계)에는 아직 fLocalScope가 만들어져 있지 않으므로
        // (메서드/생성자 본문 빌드 때만 생성됨) EmitArgForParamType이 혹시라도 지역 스코프를
        // 참조할 경우를 대비해 임시로 빈 스코프를 만들어 준다.
        var svCurClass83:=fCurClassName; fCurClassName:=cd.Name;
        var svLocalScope83:=fLocalScope; fLocalScope:=new TScope('local(field-defaults)', fGlobalScope);
        EmitClassFieldDefaults(ctorIL, cd.Name);
        fLocalScope:=svLocalScope83;
        fCurClassName:=svCurClass83;
        ctorIL.Emit(OpCodes.Ret);
      end;
    end;

    // [Stage 42] 사용자가 작성한 생성자 본문(constructor ClassName.Create; begin...end;)을
    // BuildClassShell이 미리 만들어 둔 ConstructorBuilder에 채워 넣는다. BuildMethodBody와
    // 거의 같은 구조이지만 매개변수/Result가 없고, 몸체 끝에 항상 Ret로 마무리한다.
    procedure BuildConstructorBody(impl: TConstructorImplNode);
    var
      il: ILGenerator; st: TStmtNode; i: integer; p: string;
      savedLocalScope: TScope; // [Phase 2] 예전의 sv4종 Dictionary를 스코프 객체 하나로
      svResult: LocalBuilder; svResultType: TVarType;
      svCurClass: string;
      svExitLabel78: &Label; // [Stage 78]
    begin
      if not fCtorBuilders.ContainsKey(impl.ClassName) then
        raise new Exception('생성자를 찾을 수 없음: '+impl.ClassName+'.Create');

      // [Stage 99] 이 클래스에 오버로드된 생성자가 여러 개 있을 수 있으므로, 지금 채워
      // 넣으려는 이 구현부(impl)의 매개변수 개수와 일치하는 ConstructorBuilder를 골라야
      // 한다 — BuildClassShell이 fProg.ConstructorImpls와 "같은 순서"로 만들어 뒀으므로
      // FindLocalCtorIndex(개수 매칭)로 정확히 대응되는 하나를 찾는다.
      var _implCtorIdx99:=FindLocalCtorIndex(impl.ClassName, impl.Parameters.Count);
      if _implCtorIdx99<0 then
        raise new Exception('생성자를 찾을 수 없음: '+impl.ClassName+'.Create('+impl.Parameters.Count.ToString+'개 인자)');

      il:=fCtorBuilders[impl.ClassName][_implCtorIdx99].GetILGenerator;

      savedLocalScope:=fLocalScope;
      svResult:=fResultLocal; svResultType:=fResultType;
      svCurClass:=fCurClassName;
      svExitLabel78:=fMethodExitLabel; // [Stage 78]

      fLocalScope:=new TScope('local(ctor)', fGlobalScope);
      fResultLocal:=nil; // 생성자는 반환값이 없음
      fCurClassName:=impl.ClassName;
      fMethodExitLabel:=il.DefineLabel; // [Stage 78] exit는 이 라벨로 점프

      // [Stage 47] 생성자 매개변수를 로컬 슬롯에 복사 (Ldarg_1, Ldarg_2, ... — Ldarg_0은 self).
      // BuildMethodBody의 매개변수 바인딩과 동일한 패턴. CLR 타입은 BuildClassShell이
      // 이 오버로드(impl)에 대해 미리 계산해 둔 fCtorParamClrTypes[..][_implCtorIdx99]를 사용한다
      // (시그니처 일관성 유지) — [Stage 99] 오버로드가 여러 개면 반드시 같은 인덱스여야 한다.
      var _implCtorParamTypes99:=fCtorParamClrTypes[impl.ClassName][_implCtorIdx99];
      for i:=0 to impl.Parameters.Count-1 do
      begin
        p:=impl.Parameters[i].Name;
        var pClrType:=typeof(integer);
        if i<_implCtorParamTypes99.Length then
          pClrType:=_implCtorParamTypes99[i];
        var loc:=il.DeclareLocal(pClrType);
        fLocalScope.Declare(p, loc, impl.Parameters[i].ParamType);
        if pClrType<>typeof(integer) then fLocalScope.SetClrType(p, pClrType);
        if i=0 then il.Emit(OpCodes.Ldarg_1)
        else if i=1 then il.Emit(OpCodes.Ldarg_2)
        else if i=2 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i+1));
        il.Emit(OpCodes.Stloc, loc);
      end;

      foreach var lv in impl.LocalVars do
      begin
        var lvClrType: System.Type;
        if lv.IsExternal then lvClrType:=ResolveExternalType(lv.ClassName)
        else lvClrType:=VTC(lv.VarType, lv.ClassName);
        var lvLoc:=il.DeclareLocal(lvClrType);
        fLocalScope.Declare(lv.Name, lvLoc, lv.VarType);
        if (lv.VarType=vtObject) or (lv.VarType=vtInterface) then
        begin
          if lv.IsExternal then
            fLocalScope.SetClrType(lv.Name, lvClrType)
          else if fTypeBuilders.ContainsKey(lv.ClassName) or fBuiltTypes.ContainsKey(lv.ClassName) then
            fLocalScope.SetClassName(lv.Name, lv.ClassName)
          else
            fLocalScope.SetClrType(lv.Name, lvClrType);
        end
        // [버그 수정] enum 타입 지역변수(예: vt: TVarType)는 여기서 ClassName/ClrType이 전혀
        // 채워지지 않아 GetVarClassName이 ''을 돌려주고, EmitExpr의 cn='' 폴백 경로(원시타입
        // 전용)에는 vtEnum이 없어 "알 수 없는 메서드 ".ToString"" 같은 오류로 이어졌다.
        // ClrType을 채워 HasClrType 리플렉션 경로(값타입 Ldloca+Call 포함)로 라우팅한다.
        else if lv.VarType=vtEnum then
          fLocalScope.SetClrType(lv.Name, lvClrType);
        // [Stage 67] vtMatrix의 원소 타입 이름을 ClassName에 보존 (GetVarClassName이 참조)
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 생성자 본문의 지역 const 선언 처리
      foreach var cd61 in impl.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);

      // [버그수정] 사용자가 "constructor Create; begin InitializeComponent; ... end;"처럼
      // 생성자 본문에 "inherited Create(...)"를 직접 쓰지 않으면, 지금까지는 부모(예:
      // System.Windows.Forms.Form) 생성자가 전혀 실행되지 않았다. Form/Control의 내부
      // 상태(RightToLeft 등 CreateParams 계산에 쓰이는 필드들)가 초기화되지 않은 채로
      // InitializeComponent가 self.ClientSize := ... 를 실행하면
      // Control.get_RightToLeft() 안에서 NullReferenceException이 터진다 — C#에서
      // 파생 클래스 생성자가 base(...)를 안 쓰면 컴파일러가 자동으로 부모의 매개변수
      // 없는 생성자를 호출해주는 것과 동일한 처리를 여기서 해준다.
      var hasExplicitInherited: boolean := false;
      foreach st in impl.Body.Statements do
        if st is TInheritedCallStmtNode then begin hasExplicitInherited:=true; break; end;
      if not hasExplicitInherited then
      begin
        var autoParentCtor: ConstructorInfo;
        var autoParentName: string:=fClasses.GetParentName(impl.ClassName);
        if (autoParentName<>'') and fCtorBuilders.ContainsKey(autoParentName) then
        begin
          // [Stage 99] 부모도 생성자가 여러 개(오버로드)일 수 있으므로, 암묵적 자동
          // 체이닝은 항상 매개변수 없는(0개) 오버로드를 고른다 — 부모가 무인자 생성자를
          // 안 두고 있으면 아래에서 nil로 남아 기존과 동일하게 에러 메시지로 안내한다.
          var _autoParentIdx99:=FindLocalCtorIndex(autoParentName, 0);
          if _autoParentIdx99>=0 then
            autoParentCtor:=fCtorBuilders[autoParentName][_autoParentIdx99]
          else
            autoParentCtor:=nil;
        end
        else if fClassExternalParentType.ContainsKey(impl.ClassName) then
          // 실제 외부 부모 클래스(예: class(TSomeExternalBase)) — BuildClassShell이
          // 이미 리플렉션으로 확인해 둔 진짜 부모 타입을 그대로 쓴다.
          autoParentCtor:=fClassExternalParentType[impl.ClassName].GetConstructor(System.Type.EmptyTypes)
        else
          // [버그수정] cd.ParentName이 실은 인터페이스였던 경우(예: class(IDisposable))
          // BuildClassShell은 실제 CLR 부모를 System.Object로 두고 인터페이스는
          // AddInterfaceImplementation으로 별도 등록한다 — fClasses에는 여전히
          // "IDisposable"이라는 원래 이름이 남아있어서, 그 이름으로 생성자를 찾으려 하면
          // (인터페이스는 생성자가 없으므로) 항상 실패했다. ParentName이 없거나 인터페이스로
          // 판명된 경우엔 진짜 부모인 System.Object의 기본 생성자를 쓴다.
          autoParentCtor:=typeof(System.Object).GetConstructor(System.Type.EmptyTypes);
        if autoParentCtor=nil then
          raise new Exception('클래스 "'+impl.ClassName+'"의 부모 "'+autoParentName+'"에 매개변수 없는 public 생성자가 없어 자동으로 상속 생성자를 호출할 수 없습니다. 본문에 "inherited Create(...)"를 직접 써주세요.');
        il.Emit(OpCodes.Ldarg_0);
        il.Emit(OpCodes.Call, autoParentCtor);
      end;

      // [Stage 83] 필드 인라인 기본값 초기화를 사용자 본문 실행 전에 대입한다.
      // (본문 안의 "inherited Create(...)"가 이보다 먼저 실행돼야 하는 드문 경우는
      // 위 EmitClassFieldDefaults 주석에 적어둔 1차 제약으로 남겨둔다.)
      EmitClassFieldDefaults(il, impl.ClassName);

      foreach st in impl.Body.Statements do EmitStatement(il, st);
      il.MarkLabel(fMethodExitLabel); // [Stage 78] exit 문의 착지점
      il.Emit(OpCodes.Ret);

      fLocalScope:=savedLocalScope;
      fResultLocal:=svResult; fResultType:=svResultType;
      fCurClassName:=svCurClass;
      fMethodExitLabel:=svExitLabel78; // [Stage 78]
    end;

    // 클래스 메서드 본문 IL 생성
    procedure BuildMethodBody(impl: TMethodImplNode);
    var
      mb: MethodBuilder; il: ILGenerator;
      i: integer; p: string;
      savedLocalScope: TScope; // [Phase 2]
      svResult: LocalBuilder; svResultType: TVarType;
      svCurClass: string; st: TStmtNode;
      svExitLabel78: &Label; // [Stage 78]
      mParamIsByRef100: List<boolean>; mParamElemType100: List<System.Type>; // [Stage 100]
    begin
      if not (fInstanceMethods.ContainsKey(impl.ClassName)
        and fInstanceMethods[impl.ClassName].ContainsKey(impl.MethodName)) then
        raise new Exception('메서드를 찾을 수 없음: '+impl.ClassName+'.'+impl.MethodName);

      // [Stage 53] abstract 메서드는 본문이 있으면 안 된다 — CLR도 이를 금지하지만
      // (Reflection.Emit에서 GetILGenerator 호출 시 알아보기 힘든 예외가 남) 여기서 먼저
      // 명확한 한국어 오류로 알려준다.
      if fAbstractMethods.ContainsKey(impl.ClassName) and fAbstractMethods[impl.ClassName].Contains(impl.MethodName) then
        raise new Exception('"'+impl.ClassName+'.'+impl.MethodName+'"은(는) abstract로 선언되어 본문(구현)을 가질 수 없습니다');

      mb:=fInstanceMethods[impl.ClassName][impl.MethodName];
      il:=mb.GetILGenerator;

      savedLocalScope:=fLocalScope;
      svResult:=fResultLocal; svResultType:=fResultType;
      svCurClass:=fCurClassName;
      svExitLabel78:=fMethodExitLabel; // [Stage 78]

      fLocalScope:=new TScope('local(method)', fGlobalScope);
      fCurClassName:=impl.ClassName;
      fMethodExitLabel:=il.DefineLabel; // [Stage 78] exit는 이 라벨로 점프

      // [Stage 74] 메서드 자신이 오픈 제네릭이면(BuildClassShell이 fMethodOpenGenericSubstOf에
      // 저장해 둔 치환표가 있으면) 본문을 컴파일하는 동안 fCurGenericSubst를 그 표로 맞춰야
      // VTC가 vtGeneric(매개변수 x: T, 지역변수, 반환 타입)을 올바르게 풀 수 있다.
      var savedMethodGenSubst74:=fCurGenericSubst;
      if impl.IsGeneric and fMethodOpenGenericSubstOf.ContainsKey(impl.ClassName+'.'+impl.MethodName) then
        fCurGenericSubst:=fMethodOpenGenericSubstOf[impl.ClassName+'.'+impl.MethodName]
      else
        fCurGenericSubst:=nil;

      if impl.IsFunction then
      begin
        fResultType:=impl.ReturnType;
        // [Stage 74] 반환 타입이 vtGeneric(예: T)이면 ReturnGenericName을 넘겨야 fCurGenericSubst
        // 조회가 성공한다 — ''을 넘기면 조용히 System.Object로 폴백해버린다(ResolveParamClrType의
        // 예전 버그와 같은 종류).
        if impl.ReturnType=vtGeneric then
          fResultLocal:=il.DeclareLocal(VTC(vtGeneric, impl.ReturnGenericName))
        // [버그 수정] vtObject(로컬 클래스) 반환 타입도 impl.ReturnClassName을 넘겨야 한다.
        // ''를 넘기면 Result 지역변수가 System.Object로 선언되어, 메서드 시그니처의 실제
        // 반환 타입(예: TToken)과 어긋나 IL이 깨지거나(스택 타입 불일치) 본문 안에서
        // Result의 멤버 접근이 실패한다.
        else
          fResultLocal:=il.DeclareLocal(VTC(impl.ReturnType, impl.ReturnClassName));
      end
      else
      begin
        fResultType:=vtInteger;
        fResultLocal:=nil;
      end;

      // 매개변수를 로컬 슬롯에 복사 (Ldarg_1, Ldarg_2, ... — Ldarg_0은 self)
      mParamIsByRef100:=new List<boolean>; mParamElemType100:=new List<System.Type>; // [Stage 100]
      for i:=0 to impl.ParamNames.Count-1 do
      begin
        p:=impl.ParamNames[i];
        var pClrType:=typeof(integer);
        if fMethodParamClrTypes.ContainsKey(impl.ClassName)
           and fMethodParamClrTypes[impl.ClassName].ContainsKey(impl.MethodName)
           and (i<fMethodParamClrTypes[impl.ClassName][impl.MethodName].Length) then
          pClrType:=fMethodParamClrTypes[impl.ClassName][impl.MethodName][i];
        // [Stage 100] var/const 매개변수는 pClrType이 ByRef 타입 — 로컬 슬롯 자체는 원소(값) 타입으로
        // 만들고("복사 진입/복사 반환" 전략, 기존 코드 전체가 Ldloc/Stloc으로 값 슬롯을 다루는
        // 전제를 그대로 재사용하기 위함), 진입 시 주소를 역참조(Ldobj)해서 그 값을 로컬에 복사해 넣는다.
        var pIsByRef100:=pClrType.IsByRef;
        var pElemType100:=ElemTypeIfByRef(pClrType);
        mParamIsByRef100.Add(pIsByRef100); mParamElemType100.Add(pElemType100);
        var loc:=il.DeclareLocal(pElemType100);
        // [버그 수정] 예전에는 인스턴스 메서드의 매개변수 타입을 무조건 vtInteger로 기록해서,
        // GetVarType()에 의존하는 배열 원소 접근(Ldelem_I4 vs Ldelem_Ref 선택, Writeln 오버로드
        // 선택 등)이 array of string 매개변수에서도 항상 정수로 취급됐다 — 문자열 배열 원소를
        // 4바이트로 잘못 읽어 포인터가 깨지고 쓰레기 값이 출력되는 원인이었다. 이제 단형화 단계가
        // 이미 채워 둔 impl.ParamTypes[i](구체 타입)를 그대로 사용한다.
        if i<impl.ParamTypes.Count then fLocalScope.Declare(p, loc, impl.ParamTypes[i])
        else fLocalScope.Declare(p, loc, vtInteger);
        if pElemType100<>typeof(integer) then fLocalScope.SetClrType(p, pElemType100); // [Stage 100] pClrType→pElemType100
        // [Stage 74] vtGeneric 매개변수(x: T)도 ClassName에 타입 매개변수 이름을 기록해 둔다 —
        // GetVarClassName으로 되찾아 fCurGenericSubst[genName]을 다시 조회할 수 있어야
        // (예: Writeln(x)가 실제 T의 CLR 타입을 알아내 box하는 데) 쓸모가 있다.
        // (top-level 제네릭 함수의 BuildStaticFunc와 동일한 원리, Stage 71 참고)
        if (i<impl.ParamTypes.Count) and (impl.ParamTypes[i]=vtGeneric) and (i<impl.ParamGenericNames.Count) then
          fLocalScope.SetClassName(p, impl.ParamGenericNames[i]);
        // self=Ldarg_0 이므로 매개변수는 Ldarg_1부터
        if i=0 then il.Emit(OpCodes.Ldarg_1)
        else if i=1 then il.Emit(OpCodes.Ldarg_2)
        else if i=2 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i+1));
        if pIsByRef100 then il.Emit(OpCodes.Ldobj, pElemType100); // [Stage 100] 주소 역참조 → 값
        il.Emit(OpCodes.Stloc, loc);
      end;

      // [Stage 28] 메서드 본문의 지역 변수 선언(var 섹션) 처리.
      // 전역 var 섹션과 같은 방식으로 VTC를 이용해 실제 CLR 타입으로 슬롯을 만들고,
      // object/interface 타입이면 fLocalClrTypes에도 등록해 메서드 호출 대상 해석이
      // (InferType/EmitExpr의 TMethodCallExprNode 처리와) 그대로 맞물리게 한다.
      foreach var lv in impl.LocalVars do
      begin
        var lvClrType:=ResolveLocalVarClrType(lv); // [Stage 41]
        var lvLoc:=il.DeclareLocal(lvClrType);
        fLocalScope.Declare(lv.Name, lvLoc, lv.VarType);
        if (lv.VarType=vtObject) or (lv.VarType=vtInterface) then
        begin
          // [Stage 30 fix] 우리 컴파일러가 만든 로컬 클래스면(TypeBuilder/완성타입이 이미 등록돼 있으면)
          // 아직 CreateType() 전일 수 있으므로 Reflection 경로(fLocalClrTypes) 대신
          // 메타데이터 기반 경로(fLocalClass → GetVarClassName)로 보낸다.
          if fTypeBuilders.ContainsKey(lv.ClassName) or fBuiltTypes.ContainsKey(lv.ClassName) then
            fLocalScope.SetClassName(lv.Name, lv.ClassName)
          else
            fLocalScope.SetClrType(lv.Name, lvClrType);
        end
        // [버그 수정] enum 타입 지역변수 — ClrType을 채워 HasClrType 리플렉션 경로로 라우팅한다.
        else if lv.VarType=vtEnum then
          fLocalScope.SetClrType(lv.Name, lvClrType);
        // [Stage 67] vtMatrix 원소 타입 이름 보존
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 메서드 본문의 지역 const 선언 처리
      foreach var cd61 in impl.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);

      foreach st in impl.Body.Statements do EmitStatement(il, st);

      il.MarkLabel(fMethodExitLabel); // [Stage 78] exit 문의 착지점 — 정상 종료와 동일하게 처리
      // [Stage 100] var/const 매개변수 복사-반환: 로컬 슬롯의 최종 값을 원래 주소에 다시 써준다.
      for i:=0 to impl.ParamNames.Count-1 do
        if (i<mParamIsByRef100.Count) and mParamIsByRef100[i] then
        begin
          if i=0 then il.Emit(OpCodes.Ldarg_1)
          else if i=1 then il.Emit(OpCodes.Ldarg_2)
          else if i=2 then il.Emit(OpCodes.Ldarg_3)
          else il.Emit(OpCodes.Ldarg_S, byte(i+1));
          il.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(impl.ParamNames[i]));
          il.Emit(OpCodes.Stobj, mParamElemType100[i]);
        end;
      if impl.IsFunction then
      begin
        il.Emit(OpCodes.Ldloc, fResultLocal);
      end;
      il.Emit(OpCodes.Ret);

      fLocalScope:=savedLocalScope;
      fResultLocal:=svResult; fResultType:=svResultType;
      fCurClassName:=svCurClass;
      fMethodExitLabel:=svExitLabel78; // [Stage 78]
      fCurGenericSubst:=savedMethodGenSubst74; // [Stage 74]
    end;

    // [Stage 27] 이전에는 최상위 함수/프로시저의 모든 매개변수·반환값을 무조건
    // typeof(integer)로 방출했다 — string/boolean/array 매개변수를 받는 함수는
    // 인자를 올바른 CLR 타입으로 스택에 올려도 시그니처가 int32로 선언되어 있어
    // IL 검증에서 깨지거나 값이 깨졌다. 이제 Parser가 이미 채워둔
    // d.Parameters[i].ParamType/d.ReturnType을 VTC로 변환해 그대로 사용한다.
    // [Stage 31] TParamDef에 ClassName/IsExternal을 추가해 클래스/인터페이스/외부 .NET
    // 타입 매개변수도 지원한다 (ResolveTopParamClrType 사용).
    // [Stage 65b] 시그니처만 먼저 등록한다 (본문은 만들지 않음).
    // 같은 레벨의 지역 서브프로그램들이 선언 순서와 무관하게 서로를 호출할 수
    // 있으려면, "형제 전체의 시그니처 등록"이 "형제 아무나의 본문 생성"보다
    // 반드시 먼저 끝나 있어야 한다. 재귀적으로 자신의 지역 서브프로그램들도
    // 시그니처만 먼저 등록해 둔다(본문은 이후 BuildStaticFunc/Proc 패스에서).
    // [Stage 69] "function Name(...): sequence of T;"의 숨은 클래스 껍데기(필드+생성자)만 먼저
    // 만든다. 팩토리 함수(DeclareStaticFunc가 만드는, 원래 이름의 static 메서드)의 반환 타입으로
    // 이 클래스가 필요하므로 DeclareStaticFunc보다 반드시 먼저 실행되어야 한다. 실제
    // MoveNext/GetEnumerator/Current 등의 "본문"은 나중에 BuildIteratorMoveNext가 채운다.
    procedure DeclareIteratorShell(fd: TFuncDeclNode);
    var
      clTB: TypeBuilder; elemClrType: System.Type; capFields: Dictionary<string, FieldBuilder>;
      ienumT, ienumeratorT: System.Type; ctorParamTypes: array of System.Type; i: integer;
      ctorB: ConstructorBuilder; stateFB, curFB: FieldBuilder;
    begin
      fIterCounter:=fIterCounter+1;
      elemClrType:=VTC(fd.IterElemType, '');
      fIterElemClrType[fd.Name]:=elemClrType;
      fIterElemVarType[fd.Name]:=fd.IterElemType; // [Stage 70]

      var ienumOpenT:=System.Type.GetType('System.Collections.Generic.IEnumerable`1');
      var ienumeratorOpenT:=System.Type.GetType('System.Collections.Generic.IEnumerator`1');
      ienumT:=ienumOpenT.MakeGenericType(elemClrType);
      ienumeratorT:=ienumeratorOpenT.MakeGenericType(elemClrType);

      clTB:=fModB.DefineType('__Iter'+fIterCounter.ToString, TypeAttributes.Public, typeof(System.Object),
        [typeof(System.Collections.IEnumerable), typeof(System.Collections.IEnumerator),
         ienumT, ienumeratorT, typeof(System.IDisposable)]);

      // 상태/현재값 필드. 이름을 '<>'로 시작시켜 사용자 매개변수/지역변수 이름과 절대 충돌하지 않게 한다
      // (Pascal 식별자는 '<' '>' 를 쓸 수 없으므로 안전).
      stateFB:=clTB.DefineField('<>state', typeof(integer), FieldAttributes.Private);
      curFB:=clTB.DefineField('<>current', elemClrType, FieldAttributes.Private);

      // 캡처 필드: 매개변수 + 지역변수 전부 — MoveNext 호출 사이에도 값이 유지되어야 하므로
      // (Reflection.Emit의 IL 지역변수는 메서드 호출마다 새로 잡혀 이 목적에 못 씀) 인스턴스 필드로 둔다.
      capFields:=new Dictionary<string, FieldBuilder>;
      foreach var p69 in fd.Parameters do
        capFields[p69.Name]:=clTB.DefineField(p69.Name, ResolveTopParamClrType(p69), FieldAttributes.Private);
      foreach var lv69 in fd.LocalVars do
        capFields[lv69.Name]:=clTB.DefineField(lv69.Name, ResolveLocalVarClrType(lv69), FieldAttributes.Private);

      // 생성자: 매개변수를 그대로 받아 필드로 저장한다(지역변수는 CLR 기본값 0/nil/false로 시작 —
      // 첫 MoveNext 호출에서 본문이 실행되며 채워짐). <>state는 CLR이 이미 0으로 초기화해주는데,
      // 0은 "맨 처음부터 실행 재개"라는 뜻이라 우리가 원하는 초기값과 정확히 같다 — 따로 안 채워도 됨.
      ctorParamTypes:=new System.Type[fd.Parameters.Count];
      for i:=0 to fd.Parameters.Count-1 do ctorParamTypes[i]:=ResolveTopParamClrType(fd.Parameters[i]);
      ctorB:=clTB.DefineConstructor(MethodAttributes.Public, CallingConventions.Standard, ctorParamTypes);
      var cil:=ctorB.GetILGenerator;
      cil.Emit(OpCodes.Ldarg_0);
      cil.Emit(OpCodes.Call, typeof(System.Object).GetConstructor(System.Type.EmptyTypes));
      for i:=0 to fd.Parameters.Count-1 do
      begin
        cil.Emit(OpCodes.Ldarg_0);
        if i=0 then cil.Emit(OpCodes.Ldarg_1) else if i=1 then cil.Emit(OpCodes.Ldarg_2)
        else if i=2 then cil.Emit(OpCodes.Ldarg_3) else cil.Emit(OpCodes.Ldarg_S, byte(i+1));
        cil.Emit(OpCodes.Stfld, capFields[fd.Parameters[i].Name]);
      end;
      cil.Emit(OpCodes.Ret);

      fIterTypes[fd.Name]:=clTB;
      fIterCtors[fd.Name]:=ctorB;
      fIterStateFieldOf[fd.Name]:=stateFB;
      fIterCurrentFieldOf[fd.Name]:=curFB;
      fIterCapFieldsOf[fd.Name]:=capFields;
    end;

    // [Stage 69] yield 지점 사전 조사 — MoveNext의 IL을 실제로 방출하기 "전에" 모든 yield 문에
    // 재개용 상태번호(1부터)와 그 지점을 가리킬 IL 라벨을 미리 배정해 둔다. 라벨은 아직 위치가
    // 정해지지 않아도(MarkLabel 전에도) branch 명령의 대상으로 미리 쓸 수 있으므로, 맨 위의 상태
    // 분기표를 실제 본문보다 먼저 방출할 수 있다. try/case 안의 yield는 1차 제약으로 훑지 않는다
    // (실행되면 EmitStatement의 TYieldStmtNode 분기가 "상태 미배정" 오류로 명확히 알려준다).
    procedure CollectYieldPoints(s: TStmtNode; il: ILGenerator; ids: Dictionary<TYieldStmtNode, integer>;
      labels: Dictionary<integer, &Label>; var counter: integer);
    var branch: TCaseBranchNode;
    begin
      if s=nil then exit;
      if s is TYieldStmtNode then
      begin
        counter:=counter+1;
        ids[TYieldStmtNode(s)]:=counter;
        labels[counter]:=il.DefineLabel;
      end
      else if s is TCompoundStmtNode then
      begin
        foreach var cs69 in TCompoundStmtNode(s).Statements do CollectYieldPoints(cs69, il, ids, labels, counter);
      end
      else if s is TIfStmtNode then
      begin
        CollectYieldPoints(TIfStmtNode(s).ThenStmt, il, ids, labels, counter);
        CollectYieldPoints(TIfStmtNode(s).ElseStmt, il, ids, labels, counter);
      end
      else if s is TWhileStmtNode then CollectYieldPoints(TWhileStmtNode(s).Body, il, ids, labels, counter)
      else if s is TForStmtNode then CollectYieldPoints(TForStmtNode(s).Body, il, ids, labels, counter)
      else if s is TForInStmtNode then CollectYieldPoints(TForInStmtNode(s).Body, il, ids, labels, counter)
      else if s is TRepeatStmtNode then
      begin
        foreach var rs69 in TRepeatStmtNode(s).Statements do CollectYieldPoints(rs69, il, ids, labels, counter);
      end
      else if s is TCaseStmtNode then
      begin
        // [1차 제약] case 분기 안의 yield는 아직 지원하지 않는다 — 여기서 일부러 훑지 않으므로
        // 상태번호가 배정되지 않고, 실제로 쓰이면 EmitStatement에서 명확한 오류가 난다.
      end;
      // 그 외(대입/proc호출/inline var 등 leaf 문장)는 yield를 담을 수 없으므로 무시.
    end;

    // [Stage 69] 이터레이터 클래스의 실제 몸통 — MoveNext / GetEnumerator(비제네릭+제네릭 명시적 구현) /
    // Current(비제네릭+제네릭 명시적 구현) / Reset / Dispose를 채우고 CreateType까지 마무리한다.
    // MoveNext 본문은 원래 함수(d.Body)의 문장들을 EmitStatement로 "그대로" 컴파일한다 — if/while/
    // for/repeat 제어 흐름은 손대지 않고 완전히 재사용하고, TYieldStmtNode만 EmitStatement 쪽에
    // 새로 추가한 분기가 가로챈다. 그래서 yield가 어떤 깊이의 루프/분기 안에 있어도(1차 제약인
    // try/case만 아니면) 그대로 동작한다 — 재개 라벨이 물리적으로 그 루프/분기의 IL 한가운데
    // 위치하게 될 뿐, CLR 입장에서는 그냥 유효한 goto 대상이다(그 지점의 평가 스택이 항상
    // 비어 있으므로 — 문장과 문장 사이는 항상 스택이 빈 상태라 이 점프가 항상 안전하다).
    procedure BuildIteratorMoveNext(d: TFuncDeclNode);
    var
      clTB: TypeBuilder; elemClrType: System.Type; capFields: Dictionary<string, FieldBuilder>;
      stateFB, curFB: FieldBuilder; mnb: MethodBuilder; il: ILGenerator;
      savedLocalScope: TScope; savedInIter: boolean;
      savedStateField, savedCurField: FieldBuilder; savedCapFields: Dictionary<string, FieldBuilder>;
      savedYieldState: Dictionary<TYieldStmtNode, integer>; savedYieldLabel: Dictionary<integer, &Label>;
      counter: integer;
    begin
      clTB:=fIterTypes[d.Name];
      elemClrType:=fIterElemClrType[d.Name];
      capFields:=fIterCapFieldsOf[d.Name];
      stateFB:=fIterStateFieldOf[d.Name];
      curFB:=fIterCurrentFieldOf[d.Name];

      // ---- MoveNext() ----
      mnb:=clTB.DefineMethod('MoveNext', MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig,
        typeof(boolean), System.Type.EmptyTypes);
      il:=mnb.GetILGenerator;

      // 컨텍스트 저장/복원 — 이터레이터는 중첩(재진입) 지원 대상이 아니지만(파서가 sequence of를
      // 최상위 함수 반환 자리에만 허용), 프로젝트 전반의 원칙(fResultLocal 등)을 그대로 따른다.
      savedLocalScope:=fLocalScope; savedInIter:=fInIterator;
      savedStateField:=fCurIterStateField; savedCurField:=fCurIterCurrentField; savedCapFields:=fCurIterFields;
      savedYieldState:=fCurIterYieldState; savedYieldLabel:=fCurIterYieldLabel;

      fInIterator:=true;
      fCurIterStateField:=stateFB; fCurIterCurrentField:=curFB; fCurIterFields:=capFields;
      fCurIterYieldState:=new Dictionary<TYieldStmtNode, integer>;
      fCurIterYieldLabel:=new Dictionary<integer, &Label>;

      // 1) yield 지점 사전 조사 — 라벨을 본문 방출 "전에" 미리 만들어 둬야 맨 위 상태 분기표에서 쓸 수 있다.
      counter:=0;
      foreach var st69 in d.Body.Statements do
        CollectYieldPoints(st69, il, fCurIterYieldState, fCurIterYieldLabel, counter);

      // 2) 지역 슬롯 준비 + 필드→지역 복사. MoveNext가 호출될 때마다(재개든 처음이든) 항상 여기서부터
      //    시작한다 — 직전 호출이 필드에 저장해 둔 값(캡처값)을 그대로 복원해 지역 슬롯에 채워 넣는다.
      fLocalScope:=new TScope('local(iter)', fGlobalScope);
      foreach var pd69 in d.Parameters do
      begin
        var floc:=il.DeclareLocal(capFields[pd69.Name].FieldType);
        fLocalScope.Declare(pd69.Name, floc, pd69.ParamType);
        if (pd69.ParamType=vtObject) or (pd69.ParamType=vtInterface) then
        begin
          if fTypeBuilders.ContainsKey(pd69.ClassName) or fBuiltTypes.ContainsKey(pd69.ClassName) then
            fLocalScope.SetClassName(pd69.Name, pd69.ClassName)
          else
            fLocalScope.SetClrType(pd69.Name, capFields[pd69.Name].FieldType);
        end
        // [버그 수정] enum 타입 캡처 매개변수 — ClrType을 채워 HasClrType 리플렉션 경로로 라우팅한다.
        else if pd69.ParamType=vtEnum then
          fLocalScope.SetClrType(pd69.Name, capFields[pd69.Name].FieldType);
        il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldfld, capFields[pd69.Name]); il.Emit(OpCodes.Stloc, floc);
      end;
      foreach var lv69c in d.LocalVars do
      begin
        var lvClrType69:=capFields[lv69c.Name].FieldType;
        var floc2:=il.DeclareLocal(lvClrType69);
        fLocalScope.Declare(lv69c.Name, floc2, lv69c.VarType);
        if (lv69c.VarType=vtObject) or (lv69c.VarType=vtInterface) then
        begin
          if fTypeBuilders.ContainsKey(lv69c.ClassName) or fBuiltTypes.ContainsKey(lv69c.ClassName) then
            fLocalScope.SetClassName(lv69c.Name, lv69c.ClassName)
          else
            fLocalScope.SetClrType(lv69c.Name, lvClrType69);
        end
        // [버그 수정] enum 타입 캡처 지역변수 — ClrType을 채워 HasClrType 리플렉션 경로로 라우팅한다.
        else if lv69c.VarType=vtEnum then
          fLocalScope.SetClrType(lv69c.Name, lvClrType69);
        if (lv69c.VarType=vtMatrix) and (lv69c.ClassName<>'') then fLocalScope.SetClassName(lv69c.Name, lv69c.ClassName);
        il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldfld, capFields[lv69c.Name]); il.Emit(OpCodes.Stloc, floc2);
      end;

      // 3) 상태 분기표: <>state가 이미 끝(-1)이면 즉시 false. 그 외 yield 상태번호(K)와 일치하면
      //    해당 재개 라벨로 점프. 아무 것도 안 걸리면(=0, 맨 처음) 그냥 아래로 흘러 들어가 본문을
      //    처음부터 실행한다.
      var contLabel:=il.DefineLabel;
      il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldfld, stateFB);
      il.Emit(OpCodes.Ldc_I4, -1);
      il.Emit(OpCodes.Bne_Un, contLabel);
      il.Emit(OpCodes.Ldc_I4_0);
      il.Emit(OpCodes.Ret);
      il.MarkLabel(contLabel);
      foreach var kv69 in fCurIterYieldLabel do
      begin
        il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldfld, stateFB);
        il.Emit(OpCodes.Ldc_I4, kv69.Key);
        il.Emit(OpCodes.Beq, kv69.Value);
      end;

      // 4) 본문 — yield는 EmitStatement의 TYieldStmtNode 분기가 처리한다.
      foreach var cd69 in d.ConstDecls do EmitConstDecl(il, fLocalScope, cd69);
      foreach var st69b in d.Body.Statements do EmitStatement(il, st69b);

      // 5) 끝까지 자연스럽게 다 실행됨 = 더 이상 값 없음.
      il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Ldc_I4, -1); il.Emit(OpCodes.Stfld, stateFB);
      il.Emit(OpCodes.Ldc_I4_0);
      il.Emit(OpCodes.Ret);

      // ---- Current: IEnumerator(비제네릭).Current — object 반환, 값 타입이면 박싱해서 돌려준다.
      // 명시적 구현(private + DefineMethodOverride)인 이유: 같은 클래스 안에 이름은 같지만 반환
      // 타입이 다른 "제네릭" Current(T get_Current)도 함께 둬야 해서(IL은 반환타입까지 시그니처에
      // 포함하므로 공존 가능하지만, public으로 그냥 두 개를 만들면 어느 쪽이 어느 인터페이스용인지
      // CLR이 모호해한다 — C# 컴파일러가 명시적 인터페이스 구현에 쓰는 것과 동일한 패턴).
      var getCurNG:=clTB.DefineMethod('<>get_Current_NG', MethodAttributes.Private or MethodAttributes.Virtual or
        MethodAttributes.Final or MethodAttributes.NewSlot or MethodAttributes.HideBySig or MethodAttributes.SpecialName,
        typeof(System.Object), System.Type.EmptyTypes);
      var ngIl:=getCurNG.GetILGenerator;
      ngIl.Emit(OpCodes.Ldarg_0); ngIl.Emit(OpCodes.Ldfld, curFB);
      if elemClrType.IsValueType then ngIl.Emit(OpCodes.Box, elemClrType);
      ngIl.Emit(OpCodes.Ret);
      clTB.DefineMethodOverride(getCurNG, typeof(System.Collections.IEnumerator).GetProperty('Current').GetGetMethod);

      // ---- Current: IEnumerator<T>.Current — T 그대로 반환(박싱 없음) ----
      var ienumeratorOpenT2:=System.Type.GetType('System.Collections.Generic.IEnumerator`1');
      var ienumeratorT2:=ienumeratorOpenT2.MakeGenericType(elemClrType);
      var getCurG:=clTB.DefineMethod('<>get_Current_G', MethodAttributes.Private or MethodAttributes.Virtual or
        MethodAttributes.Final or MethodAttributes.NewSlot or MethodAttributes.HideBySig or MethodAttributes.SpecialName,
        elemClrType, System.Type.EmptyTypes);
      var gIl:=getCurG.GetILGenerator;
      gIl.Emit(OpCodes.Ldarg_0); gIl.Emit(OpCodes.Ldfld, curFB); gIl.Emit(OpCodes.Ret);
      clTB.DefineMethodOverride(getCurG, ienumeratorT2.GetProperty('Current').GetGetMethod);

      // ---- GetEnumerator: IEnumerable(비제네릭) — 1차 제약: 재사용 없이 자기 자신을 그대로 돌려준다
      // (한 번만 순회 가능 — 같은 시퀀스를 두 번 foreach하면 이미 소진된 상태를 공유한다. 다시 순회하려면
      //  원래 함수를 다시 호출해 새 시퀀스를 만들 것. 2차에서 상태 복제/Reset으로 개선 예정).
      var getEnumNG:=clTB.DefineMethod('<>GetEnumerator_NG', MethodAttributes.Private or MethodAttributes.Virtual or
        MethodAttributes.Final or MethodAttributes.NewSlot or MethodAttributes.HideBySig,
        typeof(System.Collections.IEnumerator), System.Type.EmptyTypes);
      var geNgIl:=getEnumNG.GetILGenerator;
      geNgIl.Emit(OpCodes.Ldarg_0); geNgIl.Emit(OpCodes.Ret);
      clTB.DefineMethodOverride(getEnumNG, typeof(System.Collections.IEnumerable).GetMethod('GetEnumerator'));

      // ---- GetEnumerator: IEnumerable<T> ----
      var ienumOpenT2:=System.Type.GetType('System.Collections.Generic.IEnumerable`1');
      var ienumT2:=ienumOpenT2.MakeGenericType(elemClrType);
      var getEnumG:=clTB.DefineMethod('<>GetEnumerator_G', MethodAttributes.Private or MethodAttributes.Virtual or
        MethodAttributes.Final or MethodAttributes.NewSlot or MethodAttributes.HideBySig,
        ienumeratorT2, System.Type.EmptyTypes);
      var geGIl:=getEnumG.GetILGenerator;
      geGIl.Emit(OpCodes.Ldarg_0); geGIl.Emit(OpCodes.Ret);
      clTB.DefineMethodOverride(getEnumG, ienumT2.GetMethod('GetEnumerator'));

      // ---- Reset() — 순방향 전용 lazy 시퀀스라 지원하지 않는다(BCL의 흔한 관례와 동일) ----
      var resetMB:=clTB.DefineMethod('Reset', MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig,
        typeof(System.Void), System.Type.EmptyTypes);
      var rIl:=resetMB.GetILGenerator;
      rIl.Emit(OpCodes.Newobj, typeof(System.NotSupportedException).GetConstructor(System.Type.EmptyTypes));
      rIl.Emit(OpCodes.Throw);

      // ---- Dispose() — 정리할 외부 리소스가 없으므로 아무 것도 안 한다 ----
      var disposeMB:=clTB.DefineMethod('Dispose', MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig,
        typeof(System.Void), System.Type.EmptyTypes);
      disposeMB.GetILGenerator.Emit(OpCodes.Ret);

      clTB.CreateType;

      fLocalScope:=savedLocalScope; fInIterator:=savedInIter;
      fCurIterStateField:=savedStateField; fCurIterCurrentField:=savedCurField; fCurIterFields:=savedCapFields;
      fCurIterYieldState:=savedYieldState; fCurIterYieldLabel:=savedYieldLabel;
    end;

    // [Stage 73] DefineGenericParameters가 돌려준 GenericTypeParameterBuilder 배열에
    // 선언부의 제약조건 문자열(''=제약없음, 'class'=참조타입 전용, 그 외=클래스/인터페이스 이름)을
    // 실제 CLR 제약으로 건다. 이름 → 타입 해석은 fBuiltInterfaces/fInterfaceBuilders(인터페이스)
    // 를 먼저 보고, 아니면 fBuiltTypes/fTypeBuilders(클래스)를 본다 — 이 시점(정적 함수/프로시저
    // 선언 패스, GenerateExe 3단계)에는 인터페이스는 이미 CreateType까지 끝나 있고, 클래스는
    // TypeBuilder만 있는 상태(아직 CreateType 전)인데, Reflection.Emit은 제약 대상으로
    // 완성되지 않은 TypeBuilder를 참조하는 것을 허용하므로 문제없다.
    procedure ApplyGenericParamConstraints(gpBuilders: array of GenericTypeParameterBuilder; constraints: List<string>);
    var i73: integer; cName73: string; cType73: System.Type;
    begin
      for i73:=0 to constraints.Count-1 do
      begin
        cName73:=constraints[i73];
        if cName73='' then continue;
        if cName73='class' then
          gpBuilders[i73].SetGenericParameterAttributes(GenericParameterAttributes.ReferenceTypeConstraint)
        else if fBuiltInterfaces.ContainsKey(cName73) or fInterfaceBuilders.ContainsKey(cName73) then
        begin
          if fBuiltInterfaces.ContainsKey(cName73) then cType73:=fBuiltInterfaces[cName73]
          else cType73:=fInterfaceBuilders[cName73];
          gpBuilders[i73].SetInterfaceConstraints([cType73]);
        end
        else if fBuiltTypes.ContainsKey(cName73) or fTypeBuilders.ContainsKey(cName73) then
        begin
          if fBuiltTypes.ContainsKey(cName73) then cType73:=fBuiltTypes[cName73]
          else cType73:=fTypeBuilders[cName73];
          gpBuilders[i73].SetBaseTypeConstraint(cType73);
        end
        else
          raise new Exception('제네릭 제약조건 "'+cName73+'"에 대응하는 클래스/인터페이스를 찾을 수 없습니다 (Stage 73)');
      end;
    end;

    procedure DeclareStaticFunc(tb: TypeBuilder; d: TFuncDeclNode);
    var pt: array of System.Type; i: integer; mb: MethodBuilder; retClrType: System.Type; retCn66: string;
    begin
      // [Stage 71] true open generic — Monomorphize가 1차 제약을 만족한다고 판단해 단형화하지
      // 않고 그대로 남겨 둔 제네릭 함수는 실제 CLR 제네릭 메서드(DefineGenericParameters)로
      // 선언한다. 일반 함수와 달리 매개변수/반환 타입을 먼저 SetParameters/SetReturnType으로
      // 나중에 지정해야 한다 — GenericTypeParameterBuilder가 DefineGenericParameters 호출
      // "이후"에만 존재하기 때문에 DefineMethod 시점엔 아직 그 타입들을 만들 수 없다.
      if d.IsGeneric then
      begin
        mb:=tb.DefineMethod(d.Name, MethodAttributes.Public or MethodAttributes.Static);
        var gpBuilders71:=mb.DefineGenericParameters(d.GenericParamNames.ToArray);
        ApplyGenericParamConstraints(gpBuilders71, d.GenericParamConstraints); // [Stage 73]
        var savedSubst71:=fCurGenericSubst;
        fCurGenericSubst:=new Dictionary<string, System.Type>;
        for i:=0 to d.GenericParamNames.Count-1 do fCurGenericSubst[d.GenericParamNames[i]]:=gpBuilders71[i];

        pt:=new System.Type[d.Parameters.Count];
        for i:=0 to d.Parameters.Count-1 do pt[i]:=ResolveTopParamClrType(d.Parameters[i]);
        // ReturnType=vtGeneric이면 ReturnGenericName이 그 타입 매개변수 이름 — 아니면(제네릭
        // 함수라도 반환 타입 자체는 구체적일 수 있다, 예: function IsEmpty<T>(x: T): boolean;) 그대로 VTC.
        // [버그 수정] vtObject(로컬 클래스) 반환 타입도 d.ReturnClassName을 넘겨야 한다 —
        // 아래 비제네릭 DeclareStaticFunc/BuildStaticFunc에는 이미 있던 폴백이 제네릭
        // 함수 경로에는 빠져 있었다.
        if d.ReturnType=vtGeneric then retClrType:=VTC(vtGeneric, d.ReturnGenericName)
        else retClrType:=VTC(d.ReturnType, d.ReturnClassName);
        mb.SetParameters(pt);
        mb.SetReturnType(retClrType);

        fMethods[d.Name]:=mb; fTopParamClrTypes[d.Name]:=pt; fFuncReturnTypes[d.Name]:=d.ReturnType;
        fOpenGenericSubstOf[d.Name]:=fCurGenericSubst; // [Stage 71] 빌드 패스가 재사용
        fCurGenericSubst:=savedSubst71; // 선언(시그니처) 패스는 여기서 끝 — 본문은 BuildStaticFunc가 다시 설정
        exit; // 1차 제약: 제네릭 함수는 NestedFuncs/NestedProcs를 갖지 않는다(Monomorphize가 걸러줌)
      end;

      pt:=new System.Type[d.Parameters.Count];
      for i:=0 to d.Parameters.Count-1 do pt[i]:=ResolveTopParamClrType(d.Parameters[i]);
      // [Stage 69] sequence of T 함수는 반환 타입이 DeclareIteratorShell이 미리 만들어 둔
      // 숨은 이터레이터 클래스다 — 일반 VTC 경로를 타지 않는다.
      if d.IsIterator then
        retClrType:=fIterTypes[d.Name]
      else
      begin
        // [Stage 66] 연산자 오버로딩으로 맹글링된 함수는 System.Object가 아니라 실제 레코드/클래스
        // 반환 타입으로 선언해야 한다 — 특히 레코드는 값 타입이라 System.Object로 선언하면 박싱되어
        // 필드 접근(Ldflda 등)이 깨진다.
        retCn66:='';
        if fOperatorFuncRetClass.ContainsKey(d.Name) then retCn66:=fOperatorFuncRetClass[d.Name];
        // [버그 수정] 연산자 오버로딩이 아닌 일반 함수도 ReturnType=vtObject이면
        // ReturnClassName(예: 'ListViewItem')을 VTC에 넘겨야 정확한 CLR 반환 타입을 얻는다.
        // 그래야 fMethods[d.Name].ReturnType이 System.Object가 아니라 실제 타입이 되고,
        // InferArgClrType의 TFuncCallExprNode 분기와 EmitArgForParamType 안전망이
        // 올바른 오버로드를 선택하게 된다.
        if (retCn66='') and (d.ReturnType=vtObject) and (d.ReturnClassName<>'') then
          retCn66:=d.ReturnClassName;
        retClrType:=VTC(d.ReturnType, retCn66);
      end;
      mb:=tb.DefineMethod(d.Name, MethodAttributes.Public or MethodAttributes.Static,
        retClrType, pt);
      fMethods[d.Name]:=mb; fTopParamClrTypes[d.Name]:=pt; fFuncReturnTypes[d.Name]:=d.ReturnType;
      foreach var nf65 in d.NestedFuncs do DeclareStaticFunc(tb, nf65);
      foreach var np65 in d.NestedProcs do DeclareStaticProc(tb, np65);
    end;

    procedure DeclareStaticProc(tb: TypeBuilder; d: TProcDeclNode);
    var pt: array of System.Type; i: integer; mb: MethodBuilder;
    begin
      // [Stage 71] DeclareStaticFunc와 동일한 원리 — 반환 타입만 없다(항상 void).
      if d.IsGeneric then
      begin
        mb:=tb.DefineMethod(d.Name, MethodAttributes.Public or MethodAttributes.Static);
        var gpBuilders71p:=mb.DefineGenericParameters(d.GenericParamNames.ToArray);
        ApplyGenericParamConstraints(gpBuilders71p, d.GenericParamConstraints); // [Stage 73]
        var savedSubst71p:=fCurGenericSubst;
        fCurGenericSubst:=new Dictionary<string, System.Type>;
        for i:=0 to d.GenericParamNames.Count-1 do fCurGenericSubst[d.GenericParamNames[i]]:=gpBuilders71p[i];

        pt:=new System.Type[d.Parameters.Count];
        for i:=0 to d.Parameters.Count-1 do pt[i]:=ResolveTopParamClrType(d.Parameters[i]);
        mb.SetParameters(pt);
        mb.SetReturnType(typeof(System.Void));

        fMethods[d.Name]:=mb; fTopParamClrTypes[d.Name]:=pt;
        fOpenGenericSubstOf[d.Name]:=fCurGenericSubst; // [Stage 71]
        fCurGenericSubst:=savedSubst71p;
        exit;
      end;

      pt:=new System.Type[d.Parameters.Count];
      for i:=0 to d.Parameters.Count-1 do pt[i]:=ResolveTopParamClrType(d.Parameters[i]);
      mb:=tb.DefineMethod(d.Name, MethodAttributes.Public or MethodAttributes.Static,
        typeof(System.Void), pt);
      fMethods[d.Name]:=mb; fTopParamClrTypes[d.Name]:=pt;
      foreach var nf65 in d.NestedFuncs do DeclareStaticFunc(tb, nf65);
      foreach var np65 in d.NestedProcs do DeclareStaticProc(tb, np65);
    end;

    procedure BuildStaticFunc(tb: TypeBuilder; d: TFuncDeclNode);
    var
      pt: array of System.Type; mb: MethodBuilder; il: ILGenerator;
      savedLocalScope: TScope; // [Phase 2]
      svR: LocalBuilder; svRT: TVarType; st: TStmtNode; retClrType: System.Type; i: integer;
      savedGenSubst71: Dictionary<string, System.Type>; // [Stage 71]
      svExitLabel78: &Label; // [Stage 78]
      bParamIsByRef100: List<boolean>; // [Stage 100]
    begin
      // [Stage 71] 이 함수가 true open generic이면(DeclareStaticFunc가 fOpenGenericSubstOf에
      // 저장해 둔 치환표가 있으면) 본문을 컴파일하는 동안 fCurGenericSubst를 그 표로 맞춰
      // 둬야 VTC가 vtGeneric(예: 매개변수 x: T, 지역변수, 반환 타입)을 올바르게 풀 수 있다.
      savedGenSubst71:=fCurGenericSubst;
      if d.IsGeneric and fOpenGenericSubstOf.ContainsKey(d.Name) then
        fCurGenericSubst:=fOpenGenericSubstOf[d.Name];

      // [Stage 65b] 시그니처는 DeclareStaticFunc 패스에서 이미 등록되어 있다.
      // 여기서는 등록된 MethodBuilder를 가져와 본문만 방출한다.
      mb:=fMethods[d.Name];
      pt:=fTopParamClrTypes[d.Name];

      // [Stage 69] sequence of T 함수는 본문이 완전히 다르다 — 원래 함수 본문(d.Body)은 여기서
      // 실행되지 않고(팩토리는 그냥 인스턴스만 만들어 돌려준다), 실제 로직은 BuildIteratorMoveNext가
      // 이터레이터 클래스의 MoveNext 안에 옮겨 넣는다(그 안에서 비로소 EmitStatement로 컴파일됨).
      if d.IsIterator then
      begin
        il:=mb.GetILGenerator;
        for i:=0 to d.Parameters.Count-1 do
        begin
          if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
          else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
          else il.Emit(OpCodes.Ldarg_S, byte(i));
        end;
        il.Emit(OpCodes.Newobj, fIterCtors[d.Name]);
        il.Emit(OpCodes.Ret);
        BuildIteratorMoveNext(d);
        fCurGenericSubst:=savedGenSubst71; // [Stage 71]
        exit;
      end;

      // [Stage 66] DeclareStaticFunc와 동일한 이유로 연산자 오버로딩 맹글링 함수는
      // 실제 반환 클래스/레코드 타입을 사용한다.
      // [Stage 71 버그 수정] d.ReturnType=vtGeneric인 경우(예: function Identity<T>(x: T): T)
      // VTC(vtGeneric, cn)의 cn 자리에는 "타입 매개변수 이름"이 와야 하는데, 이 분기가
      // retCn66b(연산자 오버로딩용, 대부분 '')를 그대로 넘기고 있었다 — 그러면 VTC가
      // fCurGenericSubst['']를 찾다 못 찾아 방어적 폴백(System.Object)으로 떨어지고, Result
      // 로컬이 실제 T가 아니라 object로 선언되어 반환값 처리가 깨진다. DeclareStaticFunc의
      // 시그니처 계산(위 4017번째 줄 부근)과 동일하게 ReturnGenericName을 넘기도록 맞춘다.
      var retCn66b:='';
      if fOperatorFuncRetClass.ContainsKey(d.Name) then retCn66b:=fOperatorFuncRetClass[d.Name];
      // [버그 수정] DeclareStaticFunc(시그니처 계산부)는 retCn66이 비어 있으면
      // d.ReturnClassName(예: 'List<string>', 'ListViewItem')으로 채워 정확한 CLR 반환
      // 타입을 얻는데, 여기(본문의 Result 지역변수 선언)는 그 폴백이 빠져 있었다. 그 결과
      // "function ExtractUsesNames(...): List<string>;" 같은 함수의 MethodBuilder.ReturnType은
      // 정확히 List<string>이지만, 본문 안의 Result 지역변수는 VTC(vtObject,'')가 방어적으로
      // 돌려주는 System.Object로 선언되어 "Result.Contains(...)"가 "타입 System.Object에
      // 메서드 Contains가 없습니다"로 실패했다. DeclareStaticFunc와 동일한 폴백을 추가한다.
      if (retCn66b='') and (d.ReturnType=vtObject) and (d.ReturnClassName<>'') then
        retCn66b:=d.ReturnClassName;
      if d.ReturnType=vtGeneric then retClrType:=VTC(vtGeneric, d.ReturnGenericName)
      else retClrType:=VTC(d.ReturnType, retCn66b);
      il:=mb.GetILGenerator;
      svExitLabel78:=fMethodExitLabel; // [Stage 78] (중첩 함수 재귀 호출 전에 미리 저장/전환)
      fMethodExitLabel:=il.DefineLabel;

      // [Stage 65b] 지역(중첩) 함수/프로시저의 "본문"을 만든다. 시그니처는 이미
      // (형제 전체가) 등록되어 있으므로, 선언 순서와 무관하게 서로 호출 가능하다.
      foreach var nf65 in d.NestedFuncs do BuildStaticFunc(tb, nf65);
      foreach var np65 in d.NestedProcs do BuildStaticProc(tb, np65);

      savedLocalScope:=fLocalScope; svR:=fResultLocal; svRT:=fResultType;
      fLocalScope:=new TScope('local(func)', fGlobalScope);
      fResultType:=d.ReturnType; fResultLocal:=il.DeclareLocal(retClrType);
      for i:=0 to d.Parameters.Count-1 do
      begin
        var loc:=il.DeclareLocal(pt[i]);
        var pdef:=d.Parameters[i];
        fLocalScope.Declare(pdef.Name, loc, pdef.ParamType);
        // [Stage 31] 지역 변수(var 섹션)와 동일한 원칙: 우리 컴파일러가 만든 로컬 클래스면
        // 아직 CreateType() 전일 수 있으므로 fLocalClass(메타데이터 기반 조회)로,
        // 외부 .NET 타입이면 기존처럼 fLocalClrTypes(Reflection 기반 조회)로 보낸다.
        if (pdef.ParamType=vtObject) or (pdef.ParamType=vtInterface) then
        begin
          if fTypeBuilders.ContainsKey(pdef.ClassName) or fBuiltTypes.ContainsKey(pdef.ClassName) then
            fLocalScope.SetClassName(pdef.Name, pdef.ClassName)
          else
            fLocalScope.SetClrType(pdef.Name, pt[i]);
        end
        // [Stage 71] vtGeneric 매개변수(x: T)도 ClassName에 타입 매개변수 이름('T' 등)을
        // 기록해 둔다 — GetVarClassName으로 되찾아 fCurGenericSubst[genName]을 다시 조회할
        // 수 있어야(예: Writeln(x)가 실제 T의 CLR 타입을 알아내 box하는 데) 쓸모가 있다.
        else if pdef.ParamType=vtGeneric then
          fLocalScope.SetClassName(pdef.Name, pdef.ClassName)
        // [버그 수정] enum 타입 매개변수 — ClrType을 채워 HasClrType 리플렉션 경로로 라우팅한다.
        else if pdef.ParamType=vtEnum then
          fLocalScope.SetClrType(pdef.Name, pt[i]);
        if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
        else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i));
        il.Emit(OpCodes.Stloc, loc);
      end;
      foreach var lv in d.LocalVars do
      begin
        var lvClrType:=ResolveLocalVarClrType(lv); // [Stage 41]
        var lvLoc:=il.DeclareLocal(lvClrType);
        fLocalScope.Declare(lv.Name, lvLoc, lv.VarType);
        if (lv.VarType=vtObject) or (lv.VarType=vtInterface) then
        begin
          // [Stage 30 fix] 우리 컴파일러가 만든 로컬 클래스면(TypeBuilder/완성타입이 이미 등록돼 있으면)
          // 아직 CreateType() 전일 수 있으므로 Reflection 경로(fLocalClrTypes) 대신
          // 메타데이터 기반 경로(fLocalClass → GetVarClassName)로 보낸다.
          if fTypeBuilders.ContainsKey(lv.ClassName) or fBuiltTypes.ContainsKey(lv.ClassName) then
            fLocalScope.SetClassName(lv.Name, lv.ClassName)
          else
            fLocalScope.SetClrType(lv.Name, lvClrType);
        end
        // [버그 수정] enum 타입 지역변수 — ClrType을 채워 HasClrType 리플렉션 경로로 라우팅한다.
        else if lv.VarType=vtEnum then
          fLocalScope.SetClrType(lv.Name, lvClrType);
        // [Stage 67] vtMatrix 원소 타입 이름 보존
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 함수 본문의 지역 const 선언 처리
      foreach var cd61 in d.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.MarkLabel(fMethodExitLabel); // [Stage 78] exit 문의 착지점
      il.Emit(OpCodes.Ldloc, fResultLocal); il.Emit(OpCodes.Ret);
      fLocalScope:=savedLocalScope; fResultLocal:=svR; fResultType:=svRT;
      fMethodExitLabel:=svExitLabel78; // [Stage 78]
      fCurGenericSubst:=savedGenSubst71; // [Stage 71]
    end;

    procedure BuildStaticProc(tb: TypeBuilder; d: TProcDeclNode);
    var
      pt: array of System.Type; i: integer; mb: MethodBuilder; il: ILGenerator;
      savedLocalScope: TScope; // [Phase 2]
      svR: LocalBuilder; svRT: TVarType; st: TStmtNode;
      savedGenSubst71: Dictionary<string, System.Type>; // [Stage 71]
      svExitLabel78: &Label; // [Stage 78]
    begin
      // [Stage 71] BuildStaticFunc와 동일한 원리 — 자세한 설명은 그쪽 주석 참고.
      savedGenSubst71:=fCurGenericSubst;
      if d.IsGeneric and fOpenGenericSubstOf.ContainsKey(d.Name) then
        fCurGenericSubst:=fOpenGenericSubstOf[d.Name];

      // [Stage 65b] 시그니처는 DeclareStaticProc 패스에서 이미 등록되어 있다.
      mb:=fMethods[d.Name];
      pt:=fTopParamClrTypes[d.Name];
      il:=mb.GetILGenerator;
      svExitLabel78:=fMethodExitLabel; // [Stage 78]
      fMethodExitLabel:=il.DefineLabel;

      // [Stage 65b] BuildStaticFunc의 동일 위치 주석 참고 — 여기서는 본문만 만든다.
      foreach var nf65 in d.NestedFuncs do BuildStaticFunc(tb, nf65);
      foreach var np65 in d.NestedProcs do BuildStaticProc(tb, np65);

      savedLocalScope:=fLocalScope; svR:=fResultLocal; svRT:=fResultType;
      fLocalScope:=new TScope('local(proc)', fGlobalScope);
      fResultLocal:=nil;
      for i:=0 to d.Parameters.Count-1 do
      begin
        var loc:=il.DeclareLocal(pt[i]);
        var pdef:=d.Parameters[i];
        fLocalScope.Declare(pdef.Name, loc, pdef.ParamType);
        if (pdef.ParamType=vtObject) or (pdef.ParamType=vtInterface) then
        begin
          if fTypeBuilders.ContainsKey(pdef.ClassName) or fBuiltTypes.ContainsKey(pdef.ClassName) then
            fLocalScope.SetClassName(pdef.Name, pdef.ClassName)
          else
            fLocalScope.SetClrType(pdef.Name, pt[i]);
        end
        // [Stage 71] BuildStaticFunc와 동일한 이유 — vtGeneric 매개변수도 타입 매개변수 이름을 기록.
        else if pdef.ParamType=vtGeneric then
          fLocalScope.SetClassName(pdef.Name, pdef.ClassName)
        // [버그 수정] enum 타입 매개변수 — ClrType을 채워 HasClrType 리플렉션 경로로 라우팅한다.
        else if pdef.ParamType=vtEnum then
          fLocalScope.SetClrType(pdef.Name, pt[i]);
        if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
        else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i));
        il.Emit(OpCodes.Stloc, loc);
      end;
      // [Stage 28] 프로시저 본문의 지역 변수 선언(var 섹션) 처리.
      foreach var lv in d.LocalVars do
      begin
        var lvClrType:=ResolveLocalVarClrType(lv); // [Stage 41]
        var lvLoc:=il.DeclareLocal(lvClrType);
        fLocalScope.Declare(lv.Name, lvLoc, lv.VarType);
        if (lv.VarType=vtObject) or (lv.VarType=vtInterface) then
        begin
          // [Stage 30 fix] 우리 컴파일러가 만든 로컬 클래스면(TypeBuilder/완성타입이 이미 등록돼 있으면)
          // 아직 CreateType() 전일 수 있으므로 Reflection 경로(fLocalClrTypes) 대신
          // 메타데이터 기반 경로(fLocalClass → GetVarClassName)로 보낸다.
          if fTypeBuilders.ContainsKey(lv.ClassName) or fBuiltTypes.ContainsKey(lv.ClassName) then
            fLocalScope.SetClassName(lv.Name, lv.ClassName)
          else
            fLocalScope.SetClrType(lv.Name, lvClrType);
        end
        // [버그 수정] enum 타입 지역변수 — ClrType을 채워 HasClrType 리플렉션 경로로 라우팅한다.
        else if lv.VarType=vtEnum then
          fLocalScope.SetClrType(lv.Name, lvClrType);
        // [Stage 67] vtMatrix 원소 타입 이름 보존
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 프로시저 본문의 지역 const 선언 처리
      foreach var cd61 in d.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.MarkLabel(fMethodExitLabel); // [Stage 78] exit 문의 착지점
      il.Emit(OpCodes.Ret);
      fLocalScope:=savedLocalScope; fResultLocal:=svR; fResultType:=svRT;
      fMethodExitLabel:=svExitLabel78; // [Stage 78]
      fCurGenericSubst:=savedGenSubst71; // [Stage 71]
    end;

  public
    constructor Create(p: TProgramNode);
    begin
      fProg:=p;
      // [Phase 2] 전역/로컬 변수 스코프 — fLocalScope.Parent=fGlobalScope로 체인 연결.
      fGlobalScope:=new TScope('global', nil);
      fLocalScope:=new TScope('local', fGlobalScope);
      fMethods:=new Dictionary<string, MethodBuilder>;
      fTopParamClrTypes:=new Dictionary<string, array of System.Type>;
      // [Stage 71] true open generic 호출 매핑 — Monomorphize가 단형화하지 않고 그대로 남겨 둔
      // 제네릭 템플릿의 인스턴스화 요청들을 맹글링된 이름으로 색인해 둔다(자세한 설명은 필드 선언부 참고).
      fCurGenericSubst:=nil;
      fOpenGenericSubstOf:=new Dictionary<string, Dictionary<string, System.Type>>;
      fMethodOpenGenericSubstOf:=new Dictionary<string, Dictionary<string, System.Type>>; // [Stage 74]
      fOpenGenericCallMap:=new Dictionary<string, TGenericFuncInstantiation>;
      foreach var finst71 in fProg.GenericFuncInstantiations do
        fOpenGenericCallMap[finst71.ConcreteName]:=finst71;
      fFuncReturnTypes:=new Dictionary<string, TVarType>;
      fTypeBuilders:=new Dictionary<string, TypeBuilder>;
      fBuiltTypes:=new Dictionary<string, System.Type>;
      fFieldBuilders:=new Dictionary<string, Dictionary<string, FieldBuilder>>;
      fInstanceMethods:=new Dictionary<string, Dictionary<string, MethodBuilder>>;
      fMethodsCache:=new Dictionary<string, array of MethodInfo>; // [성능]
      fCtorsCache:=new Dictionary<string, array of ConstructorInfo>; // [성능]
      fAbstractMethods:=new Dictionary<string, List<string>>; // [Stage 53]
      fClasses:=new TClassTable;
      fMethodReturnTypes:=new Dictionary<string, Dictionary<string, TVarType>>;
      fMethodParamClrTypes:=new Dictionary<string, Dictionary<string, array of System.Type>>;
      fCtorBuilders:=new Dictionary<string, List<ConstructorBuilder>>;
      fCtorParamClrTypes:=new Dictionary<string, List<array of System.Type>>; // [Stage 47/99]
      fInterfaceBuilders:=new Dictionary<string, TypeBuilder>;
      fBuiltInterfaces:=new Dictionary<string, System.Type>;
      fBuiltEnums:=new Dictionary<string, System.Type>; // [Phase 1]
      fRecordNames:=new HashSet<string>; // [Stage 62]
      // [Stage 66] 연산자 오버로딩 레지스트리를 미리 채워둔다 — DeclareStaticFunc/BuildStaticFunc가
      // 맹글링된 함수의 반환 CLR 타입을 결정할 때(System.Object로 박싱되지 않도록) 필요하다.
      fOperatorOverloadFuncs:=new Dictionary<string, string>;
      fOperatorFuncRetClass:=new Dictionary<string, string>;
      foreach var oo66 in fProg.OperatorOverloads do
      begin
        fOperatorOverloadFuncs[oo66.OpSymbol+'|'+oo66.TypeName]:=oo66.FuncName;
        fOperatorFuncRetClass[oo66.FuncName]:=oo66.TypeName;
      end;
      fFieldObjClassName:=new Dictionary<string, Dictionary<string, string>>;
      fLambdaCounter:=0; // [Stage 64]
      fGlobalConstFields:=new Dictionary<string, FieldBuilder>; // [Stage 96]
      fGlobalConstVTypes:=new Dictionary<string, TVarType>;     // [Stage 96]
      fLoadedAssemblies:=new List<Assembly>;
      fClassExternalParentType:=new Dictionary<string, System.Type>;
      fClassExternalInterfaceType:=new Dictionary<string, System.Type>;
      fResultLocal:=nil; fResultType:=vtInteger; fCurClassName:='';
      // [Stage 60]
      fLoopBreakLabels:=new List<&Label>;
      fLoopContinueLabels:=new List<&Label>;
      fLoopExceptDepths:=new List<integer>;
      fCurExceptDepth:=0;

      // [Stage 69]
      fIterCounter:=0;
      fIterTypes:=new Dictionary<string, TypeBuilder>;
      fIterCtors:=new Dictionary<string, ConstructorBuilder>;
      fIterElemClrType:=new Dictionary<string, System.Type>;
      fIterElemVarType:=new Dictionary<string, TVarType>; // [Stage 70]
      fIterStateFieldOf:=new Dictionary<string, FieldBuilder>;
      fIterCurrentFieldOf:=new Dictionary<string, FieldBuilder>;
      fIterCapFieldsOf:=new Dictionary<string, Dictionary<string, FieldBuilder>>;
      fInIterator:=false;
      fCurIterFields:=nil;
      fCurIterYieldState:=nil;
      fCurIterYieldLabel:=nil;

      // [Stage 51] GAC에 항상 있다고 볼 수 있는 "기본" 프레임워크들의 네임스페이스 접두사 표.
      // 접두사는 가장 구체적인 것부터 매칭되도록 ResolveExternalType에서 길이 내림차순으로 검사한다.
      // 값은 해당 접두사의 타입이 실제로 들어있을 만한 어셈블리 이름 후보들 — 각각 "짧은 이름"을
      // 먼저 시도하고, .NET Framework GAC 환경에서는 짧은 이름만으로 바인딩이 실패할 수 있으므로
      // (AddReferenceAssembly 주석 참고) Version/Culture/PublicKeyToken까지 포함한 정식 강명(strong name)을
      // 바로 다음 후보로 넣어 자동 재시도되게 한다.
      fAutoAssemblyMap:=new Dictionary<string, array of string>;
      fAutoAssemblyMap['System.Windows.Forms']:=
        ['System.Windows.Forms','System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      fAutoAssemblyMap['System.Drawing']:=
        ['System.Drawing','System.Drawing, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a'];
      fAutoAssemblyMap['System.Data']:=
        ['System.Data','System.Data, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      fAutoAssemblyMap['System.Xml.Linq']:=
        ['System.Xml.Linq','System.Xml.Linq, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      fAutoAssemblyMap['System.Xml']:=
        ['System.Xml','System.Xml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      fAutoAssemblyMap['System.Net.Http']:=
        ['System.Net.Http','System.Net.Http, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a'];
      fAutoAssemblyMap['System.Net']:=
        ['System','System, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      fAutoAssemblyMap['System.Text.RegularExpressions']:=
        ['System','System, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      fAutoAssemblyMap['System.Timers']:=
        ['System','System, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      // [Stage 87] System.IO.FileSystemWatcher/FileSystemEventArgs 등 — System.IO 네임스페이스의
      // 대부분(Path/File/Directory)은 mscorlib에 있어 1단계에서 바로 찾히지만, FileSystemWatcher는
      // System.ComponentModel.Component를 상속하는 컴포넌트라 System.dll(짧은 이름 "System")에 있다.
      fAutoAssemblyMap['System.IO']:=
        ['System','System, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      fAutoAssemblyMap['System.Xaml']:=
        ['System.Xaml','System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      // [Stage 84] System.Diagnostics.Process 등 — .NET(Core 이후)에서는 별도 어셈블리
      // "System.Diagnostics.Process"로 분리돼 있고, .NET Framework에서는 "System"에 들어있으므로
      // 둘 다 후보로 넣어 둘 중 실제로 로드되는 쪽을 쓴다.
      fAutoAssemblyMap['System.Diagnostics']:=
        ['System.Diagnostics.Process','System.Diagnostics.Process, Version=4.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51',
         'System','System, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      // WPF: 네임스페이스 System.Windows.* 가 PresentationFramework/PresentationCore/WindowsBase에 흩어져 있음.
      // WPF 계열 GAC 어셈블리는 PublicKeyToken이 BCL과 다르다(31bf3856ad364e35).
      fAutoAssemblyMap['System.Windows']:=
        ['PresentationFramework','PresentationFramework, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35',
         'PresentationCore','PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35',
         'WindowsBase','WindowsBase, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35',
         'System.Xaml','System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
      fFailedAutoLoads:=new HashSet<string>;
    end;

    // WPF는 'PresentationFramework','PresentationCore','WindowsBase' (GAC),
    // WinForm은 'System.Windows.Forms','System.Drawing' (GAC),
    // AvaloniaUI는 GAC에 없으므로 dll 전체 경로를 넘겨야 함 (예: 'C:\...\Avalonia.Controls.dll').
    // 주의: .NET Framework GAC는 짧은 이름만으로는 바인딩 실패할 수 있음 — 실패하면
    // 'System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'
    // 처럼 Version/Culture/PublicKeyToken까지 포함한 정식 이름으로 재시도할 것.
    // 어떤 프레임워크를 쓸지는 호출하는 쪽(디자이너)이 결정해서 이 메서드로 등록한다.
    procedure AddReferenceAssembly(nameOrPath: string);
    var asm: Assembly; shortName: string; loadErr: string; candidate: string;
    begin
      asm:=nil; loadErr:='';
      if nameOrPath.ToLower.EndsWith('.dll') then
      begin
        // [Stage 45] {$reference PresentationFramework.dll} 처럼 디자이너가 내보내는 지시문은
        // 실제 파일 경로가 아니라 GAC/프레임워크 어셈블리의 "짧은 이름 + .dll"인 경우가 대부분이다.
        // 그래서 .dll을 뗀 짧은 이름으로 Assembly.Load(GAC/참조 어셈블리 경로)를 먼저 시도하고,
        // 실패하면 (Avalonia처럼 GAC에 없는 경우를 위해) 원래 문자열을 실제 파일 경로로 보고
        // LoadFrom을 시도한다.
        shortName:=nameOrPath.Substring(0, nameOrPath.Length-4);
        try
          asm:=Assembly.Load(shortName);
        except
          on E1: Exception do loadErr:=loadErr+'Assembly.Load("'+shortName+'"): '+E1.Message+' | ';
        end;

        // [재확인] 짧은 이름 로드가 실패했는데, 이 이름이 fAutoAssemblyMap에 등록된 "기본
        // 프레임워크"(WinForms/WPF/System.* 등)라면, {$reference} 없이 타입을 찾을 때
        // (ResolveExternalType, Stage 51)와 똑같이 Version/Culture/PublicKeyToken까지 포함한
        // 정식 강명 후보들로도 재시도한다. 지금까지 이 재시도 로직이 ResolveExternalType
        // 쪽에만 있고 여기(명시적 {$reference} 경로)에는 없어서, {$reference}를 직접 쓴
        // 소스에서는 GAC 바인딩이 실패해도 강명 재시도 없이 곧바로 LoadFrom(파일 경로)으로
        // 넘어가 버렸다 — Avalonia 같은 진짜 로컬 dll이 아니라 System.Windows.Forms 같은
        // GAC 어셈블리인 경우 그 경로에 파일이 있을 리 없어 결국 실패했다.
        if (asm=nil) and fAutoAssemblyMap.ContainsKey(shortName) then
          foreach candidate in fAutoAssemblyMap[shortName] do
          begin
            if asm<>nil then break;
            try
              asm:=Assembly.Load(candidate);
            except
              on E1b: Exception do loadErr:=loadErr+'Assembly.Load("'+candidate+'"): '+E1b.Message+' | ';
            end;
          end;

        if asm=nil then
        try
          asm:=Assembly.LoadFrom(nameOrPath);
        except
          on E2: Exception do loadErr:=loadErr+'Assembly.LoadFrom("'+nameOrPath+'"): '+E2.Message;
        end;
      end
      else
      try
        asm:=Assembly.Load(nameOrPath);
      except
        on E3: Exception do loadErr:=loadErr+'Assembly.Load("'+nameOrPath+'"): '+E3.Message;
      end;
      if asm=nil then
        raise new Exception('어셈블리 "'+nameOrPath+'" 로드 실패: '+loadErr);
      fLoadedAssemblies.Add(asm);
    end;

    // [진단용] [4/4] 코드생성 단계 진행 상황을 즉시 콘솔/리다이렉트된 로그 파일에 기록한다.
    // Console.Out은 파일로 리다이렉트되면 버퍼링되어, Writeln만 호출해서는 실제로
    // 로그 파일에 언제 쓰여질지 보장되지 않는다 — 매번 Flush를 강제해서, 컴파일이
    // 도중에 멈추거나 예외로 죽어도 "어디까지 진행됐는지"가 로그에 즉시 남게 한다.
    procedure LogGenStep(msg: string);
    begin
      Writeln('  [4/4 진행] ' + msg);
      System.Console.Out.Flush;
    end;

    procedure GenerateExe(outName: string);
    var
      an: AssemblyName; ab: AssemblyBuilder;
      modB: ModuleBuilder; mainTB: TypeBuilder;
      mm: MethodBuilder; il: ILGenerator;
      rk: MethodInfo; vd: TVarDecl; st: TStmtNode;
      cd: TClassDeclNode; impl: TMethodImplNode; id: TInterfaceDeclNode;
      fd: TFuncDeclNode; pd: TProcDeclNode; ctorImpl: TConstructorImplNode; // [Stage 42]
    begin
      an:=new AssemblyName(fProg.Name);
      ab:=AssemblyBuilder.DefineDynamicAssembly(an, AssemblyBuilderAccess.RunAndSave);
      modB:=ab.DefineDynamicModule(fProg.Name, outName);
      fModB:=modB; // [Stage 68] 클로저 클래스 정의에 사용

      // [Stage 76 버그수정] 생성된 어셈블리에 TargetFrameworkAttribute가 없으면
      // .NET Framework가 이를 legacy(.NET 4.0 이전) 어셈블리로 간주해 프로세스 전체에
      // 구버전 호환성 퀵스 모드를 적용한다. 이 모드에서는 순수 관리 코드(프로퍼티 설정,
      // GDI+ 배경 채우기 등)는 정상 동작하지만, WinForms ToolStrip/MenuStrip/StatusStrip류의
      // 오너드로우 텍스트 렌더링 경로가 깨져 텍스트만 그려지지 않는 증상이 발생한다.
      // 컴파일러 자신을 실행 중인 CLR에 붙어있는 TargetFrameworkAttribute를 그대로 복사해서
      // 생성 어셈블리에도 부여함으로써, 실제 설치된 .NET Framework 버전과 항상 일치시킨다.
      try
        var tfaCtor:=typeof(System.Runtime.Versioning.TargetFrameworkAttribute).GetConstructor([typeof(string)]);
        var tfaVersionString: string:='.NETFramework,Version=v4.7.2'; // 폴백값
        var selfTfa:=System.Reflection.Assembly.GetExecutingAssembly().GetCustomAttribute(
          typeof(System.Runtime.Versioning.TargetFrameworkAttribute))
          as System.Runtime.Versioning.TargetFrameworkAttribute;
        if selfTfa<>nil then
          tfaVersionString:=selfTfa.FrameworkName;
        var tfaArgs: array of object:=new object[1];
        tfaArgs[0]:=tfaVersionString;
        ab.SetCustomAttribute(new CustomAttributeBuilder(tfaCtor, tfaArgs));
      except
        on ETfa: Exception do
          Writeln('[경고] TargetFrameworkAttribute 부여 실패 (무시하고 계속): '+ETfa.Message);
      end;

      // -2. [Phase 1] 열거형을 가장 먼저 빌드 (인터페이스·클래스 필드 타입으로 참조됨)
      LogGenStep('열거형 빌드 시작');
      try
        BuildEnumTypes(modB);
      except
        on E: Exception do
        begin
          LogGenStep('실패 — 열거형 빌드 중: '+E.Message);
          raise;
        end;
      end;
      LogGenStep('열거형 빌드 완료');

      // -1.5. [Stage 62] 레코드(값 타입)를 열거형 다음, 인터페이스/클래스보다 먼저 완전히 빌드한다.
      // 메서드가 없어 클래스처럼 나중 단계를 기다릴 필요가 없으므로 여기서 CreateType까지 끝낸다.
      LogGenStep('레코드 빌드 시작');
      try
        BuildRecordTypes(modB);
      except
        on E: Exception do
        begin
          LogGenStep('실패 — 레코드 빌드 중: '+E.Message);
          raise;
        end;
      end;
      LogGenStep('레코드 빌드 완료');

      // -1. 인터페이스 타입을 클래스보다 먼저 완전히 빌드 (CreateType까지)
      //     클래스의 AddInterfaceImplementation에는 완성된 Type이 필요하기 때문
      foreach id in fProg.InterfaceDecls do
      try
        BuildInterfaceShell(modB, id);
      except
        on E: Exception do
        begin
          LogGenStep('실패 — 인터페이스 "'+id.Name+'" 빌드 중: '+E.Message);
          raise;
        end;
      end;

      // 0. 클래스 상속 관계 등록 (부모가 먼저 선언되어 있어야 함)
      foreach cd in fProg.ClassDecls do
        fClasses.SetParentName(cd.Name, cd.ParentName);

      // 1. 클래스 TypeBuilder 생성 (껍데기 + 필드 + 메서드 시그니처)
      // ClassDecls는 소스에 선언된 순서(부모가 항상 자식보다 먼저)이므로
      // 부모 TypeBuilder가 자식보다 먼저 만들어짐이 보장된다.
      LogGenStep('1단계 시작 — 클래스 껍데기 '+fProg.ClassDecls.Count.ToString+'개');
      foreach cd in fProg.ClassDecls do
      try
        BuildClassShell(modB, cd);
      except
        on E: Exception do
        begin
          LogGenStep('실패 — 클래스 "'+cd.Name+'" 껍데기 빌드 중: '+E.Message);
          raise;
        end;
      end;
      LogGenStep('1단계 완료 — 클래스 껍데기 '+fProg.ClassDecls.Count.ToString+'개');

      // 2. 메인 프로그램 타입 (static 메서드들을 담을 타입)
      mainTB:=modB.DefineType('Program', TypeAttributes.Public);
      fMainTB:=mainTB; // [Stage 64] 람다가 EmitStatement에서도 static 메서드를 여기 추가할 수 있도록

      // 2-1. [Stage 96] 전역 const를 Program 타입의 static readonly 필드로 정의한다.
      // EmitConstDecl은 Main 메서드의 ILGenerator에 로컬 슬롯을 잡기 때문에 다른
      // 함수/프로시저에서는 그 슬롯이 보이지 않는다 — static 필드로 올리면
      // 모든 메서드에서 Ldsfld 한 번으로 값을 읽을 수 있다.
      // cctor(정적 생성자, beforefieldinit)에서 초기화한다 — 가장 먼저 실행되어
      // Main보다 앞서 값이 채워진다.
      if (not fProg.IsLibrary) and (fProg.ConstDecls.Count > 0) then
      begin
        var cctorMB: MethodBuilder := mainTB.DefineMethod('.cctor',
          MethodAttributes.Private or MethodAttributes.Static or
          MethodAttributes.HideBySig or MethodAttributes.SpecialName or MethodAttributes.RTSpecialName,
          typeof(System.Void), nil);
        var cctorIL: ILGenerator := cctorMB.GetILGenerator;
        // 각 const를 static 필드로 선언하고 cctor에서 초기화한다.
        var savedLocalScope96: TScope := fLocalScope;
        fLocalScope := new TScope('cctor_const', fGlobalScope);
        foreach var cd96 in fProg.ConstDecls do
        begin
          // 필드 CLR 타입 결정 (EmitConstDecl과 동일한 로직)
          var vt96: TVarType;
          var clrType96: System.Type;
          var clsName96: string := cd96.ClassName;
          var isExt96: boolean := cd96.IsExternal;
          if cd96.HasExplicitType then
          begin
            vt96 := cd96.VarType;
            if (vt96 = vtObject) and isExt96 then clrType96 := ResolveExternalType(clsName96)
            else clrType96 := VTC(vt96, clsName96);
          end
          else
          begin
            vt96 := InferType(cd96.ValueExpr);
            if cd96.ValueExpr is TNewObjectExprNode then
            begin
              var neo96 := TNewObjectExprNode(cd96.ValueExpr);
              clsName96 := neo96.ClassName; isExt96 := neo96.IsExternalType;
              if isExt96 then clrType96 := ResolveExternalType(clsName96)
              else if fBuiltTypes.ContainsKey(clsName96) then clrType96 := fBuiltTypes[clsName96]
              else if fTypeBuilders.ContainsKey(clsName96) then clrType96 := fTypeBuilders[clsName96]
              else clrType96 := typeof(System.Object);
            end
            else if cd96.ValueExpr is TExternalCastExprNode then
            begin
              var extCast96 := TExternalCastExprNode(cd96.ValueExpr);
              clrType96 := ResolveExternalType(extCast96.TargetType);
              isExt96 := true;
            end
            else
              clrType96 := VTC(vt96, '');
          end;
          // static readonly 필드 정의
          var fb96: FieldBuilder := mainTB.DefineField(cd96.Name, clrType96,
            FieldAttributes.Public or FieldAttributes.Static or FieldAttributes.InitOnly);
          fGlobalConstFields[cd96.Name] := fb96;
          fGlobalConstVTypes[cd96.Name] := vt96;
          // cctor에서 초기화 값 emit 후 Stsfld
          EmitValueForVType(cctorIL, cd96.ValueExpr, vt96);
          cctorIL.Emit(OpCodes.Stsfld, fb96);
        end;
        fLocalScope := savedLocalScope96;
        cctorIL.Emit(OpCodes.Ret);
      end;

      // 3. 일반 static 함수/프로시저 빌드
      // [Stage 65b] 최상위 함수/프로시저도 선언 순서와 무관하게 서로 호출할 수
      // 있도록, 먼저 모든 시그니처를 등록한 뒤(3-1) 본문을 만든다(3-2).
      // [Stage 69] sequence of T 함수(이터레이터)는 팩토리 함수 자체의 반환 타입이 "숨은 클래스"이므로,
      // 그 클래스 껍데기(필드+생성자)를 일반 함수 시그니처 등록보다 먼저 만들어 둬야 한다.
      foreach fd in fProg.FuncDecls do
        if fd.IsIterator then DeclareIteratorShell(fd);
      foreach fd in fProg.FuncDecls do DeclareStaticFunc(mainTB, fd);
      foreach pd in fProg.ProcDecls do DeclareStaticProc(mainTB, pd);
      LogGenStep('3단계 시작 — 최상위 함수/프로시저 본문 '
        +fProg.FuncDecls.Count.ToString+'/'+fProg.ProcDecls.Count.ToString+'개');
      foreach fd in fProg.FuncDecls do
      try
        BuildStaticFunc(mainTB, fd);
      except
        on E: Exception do
        begin
          LogGenStep('실패 — 함수 "'+fd.Name+'" 본문 생성 중: '+E.Message);
          raise;
        end;
      end;
      foreach pd in fProg.ProcDecls do
      try
        BuildStaticProc(mainTB, pd);
      except
        on E: Exception do
        begin
          LogGenStep('실패 — 프로시저 "'+pd.Name+'" 본문 생성 중: '+E.Message);
          raise;
        end;
      end;
      LogGenStep('3단계 완료 — 최상위 함수/프로시저 본문');

      // 4. 클래스 메서드 본문 IL 생성
      LogGenStep('4단계 시작 — 클래스 메서드 본문 '+fProg.MethodImpls.Count.ToString+'개');
      foreach impl in fProg.MethodImpls do
      try
        BuildMethodBody(impl);
      except
        on E: Exception do
        begin
          LogGenStep('실패 — 클래스 "'+impl.ClassName+'"의 메서드 "'+impl.MethodName+'" 본문 생성 중: '+E.Message);
          raise;
        end;
      end;
      LogGenStep('4단계 완료 — 클래스 메서드 본문 '+fProg.MethodImpls.Count.ToString+'개');

      // 4-1. [Stage 42] 사용자 정의 생성자 본문 IL 생성 (constructor Create; ... end;)
      LogGenStep('4-1단계 시작 — 생성자 본문 '+fProg.ConstructorImpls.Count.ToString+'개');
      foreach ctorImpl in fProg.ConstructorImpls do
      try
        BuildConstructorBody(ctorImpl);
      except
        on E: Exception do
        begin
          LogGenStep('실패 — 클래스 "'+ctorImpl.ClassName+'"의 생성자 본문 생성 중: '+E.Message);
          raise;
        end;
      end;
      // constructor Create;를 선언해 놓고 실제 구현(constructor ClassName.Create; begin...end;)을
      // 빠뜨리면 그 생성자의 IL에 Ret가 없는 채로 남는다 — CreateType 전에 미리 잡아준다.
      foreach cd in fProg.ClassDecls do
        if cd.HasUserConstructor then
        begin
          var hasImpl:=false;
          foreach ctorImpl in fProg.ConstructorImpls do
            if ctorImpl.ClassName=cd.Name then begin hasImpl:=true; break; end;
          if not hasImpl then
            raise new Exception('클래스 "'+cd.Name+'"에 "constructor Create;" 선언은 있지만 구현'
              +'("constructor '+cd.Name+'.Create; begin...end;")이 없습니다.');
        end;
      LogGenStep('4-1단계 완료 — 생성자 본문');

      // 5. 클래스 타입 완성 (CreateType)
      LogGenStep('5단계 시작 — CreateType '+fProg.ClassDecls.Count.ToString+'개');
      foreach cd in fProg.ClassDecls do
      try
        fBuiltTypes[cd.Name]:=fTypeBuilders[cd.Name].CreateType;
      except
        on E: Exception do
        begin
          LogGenStep('실패 — 클래스 "'+cd.Name+'" CreateType 중: '+E.Message);
          raise;
        end;
      end;
      LogGenStep('5단계 완료 — CreateType');

      // 6. Main 메서드
      // [Stage 44] library는 진입점(Main)이 없다 — dll로 저장할 뿐 실행 파일이 아니다.
      // 전역 var/최상위 문장은 지금 구조상 전부 Main의 IL 안에 지역변수로 얹히는 방식이라
      // (fGlobals가 실은 "Main 메서드의 로컬 슬롯" 딕셔너리) Main 자체가 없는 library에서는
      // 애초에 표현할 방법이 없다 — 실제 디자이너 산출물도 library에 begin...end 블록이나
      // 전역 var를 두지 않으므로, 여기선 명확한 에러로 안내한다.
      if fProg.IsLibrary then
      begin
        if fProg.VarDecls.Count>0 then
          raise new Exception('library는 지금 전역 var 섹션을 지원하지 않습니다 (Stage 44).');
        if fProg.ConstDecls.Count>0 then
          raise new Exception('library는 지금 전역 const 섹션을 지원하지 않습니다 (Stage 44/61).'); // [Stage 61]
        if fProg.Statements.Count>0 then
          raise new Exception('library는 지금 begin...end 초기화 블록을 지원하지 않습니다 (Stage 44).');
      end
      else
      begin
        mm:=mainTB.DefineMethod('Main',
          MethodAttributes.Public or MethodAttributes.Static,
          typeof(System.Void), nil);
        // WinForm/WPF의 Application.Run 등 STA(단일 스레드 아파트먼트)가 필요한 호출을
        // 위해 항상 [STAThread]를 붙여둔다 (콘솔/일반 프로그램에는 영향 없음).
        mm.SetCustomAttribute(new CustomAttributeBuilder(
          typeof(System.STAThreadAttribute).GetConstructor(System.Type.EmptyTypes), []));
        il:=mm.GetILGenerator;

        foreach vd in fProg.VarDecls do
        begin
          var clrType: System.Type;
          var vdIsClrTyped:=false; var vdClrType: System.Type:=nil;
          var vdIsClassNamed:=false;
          if (vd.VarType=vtObject) and vd.IsExternal then
          begin
            // [전역 var 버그 수정] System.Text.StringBuilder 같은 외부 .NET 타입 전역변수.
            // 로컬/매개변수의 fLocalClrTypes와 같은 역할을 하는 fGlobalClrTypes에 등록해야
            // 메서드/속성 호출 시 Reflection 기반 조회 경로를 탈 수 있다.
            clrType:=ResolveExternalType(vd.ClassName);
            vdIsClrTyped:=true; vdClrType:=clrType;
          end
          else if vd.VarType=vtObject then
          begin
            if fBuiltTypes.ContainsKey(vd.ClassName) then
              clrType:=fBuiltTypes[vd.ClassName]
            else
              clrType:=typeof(System.Object);
            vdIsClassNamed:=true;
          end
          else if vd.VarType=vtInterface then
          begin
            if fBuiltInterfaces.ContainsKey(vd.ClassName) then
              clrType:=fBuiltInterfaces[vd.ClassName]
            else
              clrType:=typeof(System.Object);
            vdIsClassNamed:=true;
          end
          // [버그 수정] enum 타입 전역 변수 — 이전에는 vtObject/vtInterface만 처리해서
          // ClassName/ClrType이 전혀 안 채워졌고, 그 변수에 .ToString() 등을 호출하면
          // EmitExpr의 cn='' 폴백 경로(원시타입 전용)에 안 걸려 "알 수 없는 메서드" 오류가 났다.
          // ClrType을 채워 HasClrType 리플렉션 경로(값타입 Ldloca+Call 포함)로 라우팅한다.
          else if vd.VarType=vtEnum then
          begin
            clrType:=VTC(vd.VarType, vd.ClassName);
            vdIsClrTyped:=true; vdClrType:=clrType;
          end
          // [Stage 27] string/boolean/array 전역 변수도 예전에는 무조건 typeof(integer)로
          // 선언되어 있었다 — fGlobalTypes만 올바르고 실제 LocalBuilder 슬롯 타입은 틀려서
          // 대입 시 IL 검증에서 깨졌다. object/interface가 아닌 나머지는 VTC로 위임한다.
          else clrType:=VTC(vd.VarType, vd.ClassName); // [Stage 67] vtMatrix는 ClassName(원소 타입)을 넘겨야 T[][] 반환
          // [Phase 2] TScope.Declare로 항목을 먼저 만든 뒤에 SetClrType/SetClassName으로 채운다
          // (예전엔 4개 딕셔너리가 독립적이라 순서가 상관없었지만, 이제는 한 항목이라 Declare가 먼저다).
          fGlobalScope.Declare(vd.Name, il.DeclareLocal(clrType), vd.VarType);
          if vdIsClrTyped then fGlobalScope.SetClrType(vd.Name, vdClrType);
          if vdIsClassNamed then fGlobalScope.SetClassName(vd.Name, vd.ClassName);
          // [Stage 67] vtMatrix 전역 변수의 원소 타입 이름 보존
          if (vd.VarType=vtMatrix) and (vd.ClassName<>'') then
            fGlobalScope.SetClassName(vd.Name, vd.ClassName);
        end;

        // [Stage 96] 전역 const는 cctor(Program 타입의 정적 생성자)에서 static 필드로
        // 초기화된다 — Main보다 먼저 실행되고 모든 함수에서 Ldsfld로 읽을 수 있다.
        // 예전의 EmitConstDecl(Main 전용 로컬 슬롯) 루프는 제거한다.

        foreach st in fProg.Statements do EmitStatement(il, st);

        // [Stage 69] windows 앱(예: WinForms)은 콘솔이 아예 없거나(콘솔창 자체를 안 만드는 경우)
        // Application.Run이 이미 사용자 입력을 다 처리했으므로, 여기서 ReadKey로 다시
        // 키 입력을 기다리면 창이 닫힌 뒤에도 프로세스가 멈춰있는 것처럼 보인다.
        if fProg.AppType<>'windows' then
        begin
          rk:=typeof(Console).GetMethod('ReadKey', System.Type.EmptyTypes);
          il.Emit(OpCodes.Call, rk); il.Emit(OpCodes.Pop);
        end;
        il.Emit(OpCodes.Ret);
      end;

      mainTB.CreateType;
      if not fProg.IsLibrary then
      begin
        // [Stage 69] {$apptype windows}면 WindowApplication으로 저장 — PE 서브시스템이
        // GUI로 표시되어 탐색기에서 실행해도 콘솔(도스) 창이 뜨지 않는다.
        // 지시문이 없으면(기본값 'console') 기존과 동일하게 콘솔 앱으로 생성한다.
        if fProg.AppType='windows' then
          ab.SetEntryPoint(mm, PEFileKinds.WindowApplication)
        else
          ab.SetEntryPoint(mm, PEFileKinds.ConsoleApplication);
      end;
      ab.Save(outName);
    end;
  end;

implementation

end.