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
  AST,
  Scope;

type
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

    // 클래스 관련
    fTypeBuilders: Dictionary<string, TypeBuilder>;  // 클래스명 → TypeBuilder
    fBuiltTypes:   Dictionary<string, System.Type>;  // 클래스명 → 완성된 Type
    fFieldBuilders: Dictionary<string, Dictionary<string, FieldBuilder>>; // 클래스명 → 필드명 → FieldBuilder
    fInstanceMethods: Dictionary<string, Dictionary<string, MethodBuilder>>; // 클래스명 → 메서드명 → MB
    fAbstractMethods: Dictionary<string, List<string>>; // [Stage 53] 클래스명 → abstract로 선언된 메서드명 목록
    fClassParents: Dictionary<string, string>; // 클래스명 → 부모 클래스명 ('' 이면 없음)
    fMethodReturnTypes: Dictionary<string, Dictionary<string, TVarType>>; // 클래스명/인터페이스명 → 메서드명 → 반환타입
    fMethodParamClrTypes: Dictionary<string, Dictionary<string, array of System.Type>>; // 클래스명 → 메서드명 → 매개변수 CLR 타입 배열
    fCtorBuilders: Dictionary<string, ConstructorBuilder>; // 클래스명 → 기본 생성자 (CreateType 전에도 참조 가능하도록 보관)
    fCtorParamClrTypes: Dictionary<string, array of System.Type>; // [Stage 47] 클래스명 → 생성자 매개변수 CLR 타입 배열

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
        else Result:=typeof(System.Object);
      end
      else if t=vtInterface then
      begin
        if fBuiltInterfaces.ContainsKey(cn) then Result:=fBuiltInterfaces[cn]
        else Result:=typeof(System.Object);
      end
      else Result:=typeof(integer);
    end;

    function GetVarType(name: string): TVarType;
    begin
      if fLocalScope.Has(name) then Result:=fLocalScope.GetVType(name)
      else if fGlobalScope.Has(name) then Result:=fGlobalScope.GetVType(name)
      else Result:=vtInteger;
    end;

    function GetVarClassName(name: string): string;
    begin
      if fLocalScope.Has(name) then Result:=fLocalScope.GetClassName(name)
      else if fGlobalScope.Has(name) then Result:=fGlobalScope.GetClassName(name)
      else Result:='';
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
        if fClassParents.ContainsKey(c) then c:=fClassParents[c] else c:='';
      end;
      raise new Exception('필드를 찾을 수 없음: '+startClass+'.'+fname);
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
        if fClassParents.ContainsKey(c) then c:=fClassParents[c] else c:='';
      end;
      Result:=false;
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
        if fClassParents.ContainsKey(c) then c:=fClassParents[c] else c:='';
      end;
      Result:=nil;
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
        if fClassParents.ContainsKey(c) then c:=fClassParents[c] else c:='';
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
        if fClassParents.ContainsKey(c) then c:=fClassParents[c] else c:='';
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
        if fClassParents.ContainsKey(c) then c:=fClassParents[c] else c:='';
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
        if fClassParents.ContainsKey(c) then c:=fClassParents[c] else c:='';
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
      if e is TIntLiteralNode then Result:=vtInteger
      else if e is TRealLiteralNode  then Result:=vtReal   // [Phase 1]
      else if e is TCharLiteralNode  then Result:=vtChar   // [Phase 1]
      else if e is TInt64LiteralNode then Result:=vtInt64  // [Phase 1]
      else if e is TEnumValueExprNode then Result:=vtEnum  // [Stage 51]
      else if e is TNilLiteralNode then Result:=vtObject // [Stage 29]
      else if e is TStrLiteralNode then Result:=vtString
      else if e is TIntToStrNode then Result:=vtString
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
            var _pi:=_extType.GetProperty(_fr.FieldName);
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
        if _mc4.ObjName='' then // [Stage 30] Self.Method(...) / 암시적 self 호출 — 지역 메서드 우선, 없으면 외부 조상 타입
        begin
          if fMethodReturnTypes.ContainsKey(fCurClassName) and fMethodReturnTypes[fCurClassName].ContainsKey(_mc4.MethodName) then
            Result:=FindMethodReturnType(fCurClassName, _mc4.MethodName)
          else
          begin
            var _extSelf:=FindExternalAncestorType(fCurClassName);
            if _extSelf<>nil then
            begin
              var _pi4c:=_extSelf.GetProperty(_mc4.MethodName);
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
          var _pi4b:=_effType4.GetProperty(_mc4.MethodName);
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
              var _extPi4c:=_extAnc4c.GetProperty(_mc4.MethodName);
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
          var _pi4:=_effType4b.GetProperty(_mc4.MethodName);
          if (_pi4<>nil) and (_pi4.PropertyType=typeof(string)) then Result:=vtString
          else
          begin
            var _mi4:=ResolveMethodByArity(_effType4b, _mc4.MethodName, _mc4.Args, false);
            if (_mi4<>nil) and (_mi4.ReturnType=typeof(string)) then Result:=vtString
            else Result:=vtInteger;
          end;
        end
        else Result:=vtInteger;
      end
      // [Stage 37 버그 수정] 이전에는 배열이 실제로 array of string이어도 무조건 vtInteger로
      // 추론해서, Writeln(strArr[i]) 같은 식이 Console.WriteLine(int) 오버로드로 잘못 디스패치됐다.
      else if e is TArrayIndexExprNode then
      begin
        if GetVarType(TArrayIndexExprNode(e).ArrName)=vtStrArray then Result:=vtString
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
        else Result:=vtInteger;
      end
      else if e is TExceptionMsgExprNode then Result:=vtString // E.Message는 항상 string
      else if e is TStaticMemberExprNode then
      begin
        var _sm4:=TStaticMemberExprNode(e);
        var _smType4:=ResolveExternalType(_sm4.TypeName);
        var _smPi4:=_smType4.GetProperty(_sm4.MemberName);
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
      else if e is TBinOpNode then
      begin
        b:=TBinOpNode(e);
        // [Stage 66] 두 피연산자 모두 vtObject면(연산자 오버로딩 대상) 결과도 vtObject —
        // 실제 오버로딩이 등록되어 있는지는 EmitExpr에서 검증하고, 여기서는 타입 모양만 전달한다.
        if (InferType(b.Left)=vtObject) and (InferType(b.Right)=vtObject) then Result:=vtObject
        // [Stage 63] 피연산자 중 하나라도 집합이면 결과도 집합 (합집합/차집합/교집합)
        else if (InferType(b.Left)=vtSet) or (InferType(b.Right)=vtSet) then Result:=vtSet
        else if (InferType(b.Left)=vtString) or (InferType(b.Right)=vtString) then
          Result:=vtString
        else Result:=vtInteger;
      end
      else if e is TSelfExprNode then Result:=vtObject // [Stage 30]
      else if e is TAsCastExprNode then // [Stage 30]
      begin
        var _ac:=TAsCastExprNode(e);
        if fBuiltInterfaces.ContainsKey(_ac.TargetType) then Result:=vtInterface
        else Result:=vtObject;
      end
      else if e is TInheritedCallExprNode then // [Stage 30]
      begin
        var _ih:=TInheritedCallExprNode(e);
        var _pc:='';
        if fClassParents.ContainsKey(fCurClassName) then _pc:=fClassParents[fCurClassName];
        if _pc<>'' then Result:=FindMethodReturnType(_pc, _ih.MethodName)
        else Result:=vtInteger;
      end
      else Result:=vtInteger;
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
      startCls3:='';
      if fClassParents.ContainsKey(fCurClassName) then startCls3:=fClassParents[fCurClassName];

      aIL.Emit(OpCodes.Ldarg_0); // self

      if (startCls3<>'') and fCtorBuilders.ContainsKey(startCls3) then
      begin
        // [Stage 47] 로컬 부모 클래스도 이제 매개변수 있는 생성자를 지원한다.
        // [버그 수정] ConstructorBuilder.GetParameters()는 CreateType 전에는 예외를 던지므로
        // 정의 시점에 미리 계산해 둔 fCtorParamClrTypes를 대신 사용한다.
        var _parentCtorParams3: array of System.Type;
        if fCtorParamClrTypes.ContainsKey(startCls3) then _parentCtorParams3:=fCtorParamClrTypes[startCls3]
        else _parentCtorParams3:=nil;
        EmitArgsCoerced(aIL, args, _parentCtorParams3);
        aIL.Emit(OpCodes.Call, fCtorBuilders[startCls3]);
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

      startCls:='';
      if fClassParents.ContainsKey(fCurClassName) then startCls:=fClassParents[fCurClassName];
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

    procedure EmitExpr(aIL: ILGenerator; e: TExprNode);
    var
      lit: TIntLiteralNode; slit: TStrLiteralNode; vr: TVarRefNode;
      b: TBinOpNode; cmp: TCompareNode; fc: TFuncCallExprNode;
      its: TIntToStrNode; ai: TArrayIndexExprNode; le: TLengthExprNode;
      neo: TNewObjectExprNode; mc: TMethodCallExprNode; fr: TFieldReadExprNode;
      loc: LocalBuilder; mb: MethodBuilder; imb: MethodBuilder;
      ae: TExprNode; ts, cat: MethodInfo; lt, rt, at2: TVarType;
      fb: FieldBuilder;
      ctor: ConstructorInfo; cn: string; vtVar: TVarType;
      _argIdx48: integer; // [Stage 48]
    begin
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

      else if e is TLengthExprNode then
      begin
        le:=TLengthExprNode(e);
        if fLocalScope.Has(le.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(le.ArrName))
        else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(le.ArrName));
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
          var _pi:=_extType.GetProperty(fr.FieldName);
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
        if neo.IsExternalType then
        begin
          var _extCtorType:=ResolveExternalType(neo.ClassName);
          if neo.Args.Count=0 then
          begin
            var _extCtor:=_extCtorType.GetConstructor(System.Type.EmptyTypes);
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
          ctor:=fCtorBuilders[neo.ClassName];
          var _ctorParamsLocal: array of System.Type;
          if fCtorParamClrTypes.ContainsKey(neo.ClassName) then _ctorParamsLocal:=fCtorParamClrTypes[neo.ClassName]
          else _ctorParamsLocal:=nil;
          EmitArgsCoerced(aIL, neo.Args, _ctorParamsLocal);
          aIL.Emit(OpCodes.Newobj, ctor);
        end;
      end

      else if e is TMethodCallExprNode then
      begin
        // c.GetValue → Ldloc c + Call TCounter::GetValue
        mc:=TMethodCallExprNode(e);
        if (fLocalScope.Has(mc.ObjName) or fGlobalScope.Has(mc.ObjName))
           and (fLocalScope.HasClrType(mc.ObjName) or fGlobalScope.HasClrType(mc.ObjName)) then
        begin
          // sender/e 같은, 외부(또는 객체) 타입 매개변수/지역변수를 통한 접근.
          // 우리가 만든 클래스가 아니라 Reflection으로 속성/메서드를 찾는다.
          if fLocalScope.Has(mc.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(mc.ObjName))
          else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(mc.ObjName)); // [전역 var 버그 수정] 항상 fLocals만 읽던 문제
          var _qType2: System.Type;
          if fLocalScope.HasClrType(mc.ObjName) then _qType2:=fLocalScope.GetClrType(mc.ObjName)
          else _qType2:=fGlobalScope.GetClrType(mc.ObjName);
          if mc.ObjCastType<>'' then
          begin
            _qType2:=ResolveExternalType(mc.ObjCastType);
            aIL.Emit(OpCodes.Castclass, _qType2);
          end;
          var _pi6:=_qType2.GetProperty(mc.MethodName);
          if (mc.Args.Count=0) and (_pi6<>nil) and (_pi6.GetGetMethod<>nil) then
            aIL.Emit(OpCodes.Callvirt, _pi6.GetGetMethod)
          else
          begin
            var _emi6:=ResolveMethodByArity(_qType2, mc.MethodName, mc.Args, false);
            if _emi6=nil then
              raise new Exception('타입 "'+_qType2.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
            var _emi6Params:=_emi6.GetParameters;
            for var _emi6Ai:=0 to mc.Args.Count-1 do
              EmitArgForParamType(aIL, mc.Args[_emi6Ai], _emi6Params[_emi6Ai].ParameterType);
            aIL.Emit(OpCodes.Callvirt, _emi6);
          end;
        end
        else if fLocalScope.Has(mc.ObjName) or fGlobalScope.Has(mc.ObjName) then
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
          else
          begin
            if fRecordNames.Contains(cn) then aIL.Emit(OpCodes.Ldloca, fGlobalScope.GetLoc(mc.ObjName))
            else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(mc.ObjName));
          end;
          if cn='' then raise new Exception('알 수 없는 메서드 "'+cn+'.'+mc.MethodName+'"');
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
              var _extPi:=_extAnc.GetProperty(mc.MethodName);
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
                if _extFi=nil then
                  raise new Exception('외부 타입 "'+_extAnc.FullName+'"에 필드/속성 "'+mc.MethodName+'"가 없습니다.');
                aIL.Emit(OpCodes.Ldfld, _extFi);
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
              EmitArgsCoerced(aIL, mc.Args, FindInstanceMethodParamTypes(cn, mc.MethodName));
              // virtual 메서드이므로 Callvirt 사용 (다형성 대비)
              aIL.Emit(OpCodes.Callvirt, imb);
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
          var _pi5:=_qType.GetProperty(mc.MethodName);
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
        end
        else raise new Exception('알 수 없는 변수 "'+mc.ObjName+'"');
      end

      else if e is TArrayIndexExprNode then
      begin
        ai:=TArrayIndexExprNode(e);
        if fLocalScope.Has(ai.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(ai.ArrName))
        else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(ai.ArrName));
        EmitExpr(aIL, ai.Index);
        // [Stage 37 버그 수정] 이전에는 배열 종류와 무관하게 항상 Ldelem_I4를 썼다 —
        // array of integer는 우연히 맞았지만 array of string은 참조(포인터)를 4바이트
        // 정수로 잘못 읽어 쓰레기 값이 나왔다. 원소를 쓰는 쪽(Stelem, 아래 TArrayAssignStmtNode)은
        // 이미 배열 타입을 보고 Stelem_Ref/Stelem_I4를 갈라 쓰고 있었으므로 읽는 쪽도 맞춘다.
        if GetVarType(ai.ArrName)=vtStrArray then aIL.Emit(OpCodes.Ldelem_Ref)
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
        if fLocalScope.Has(vr.VarName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(vr.VarName))
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
          else if b.Op=boMod then aIL.Emit(OpCodes.Rem);
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
        if not fMethods.ContainsKey(fc.FuncName) then
          raise new Exception('알 수 없는 함수 "'+fc.FuncName+'"');
        mb:=fMethods[fc.FuncName];
        var _fcParams: array of System.Type;
        if fTopParamClrTypes.ContainsKey(fc.FuncName) then _fcParams:=fTopParamClrTypes[fc.FuncName]
        else _fcParams:=nil;
        EmitArgsCoerced(aIL, fc.Args, _fcParams);
        aIL.Emit(OpCodes.Call, mb);
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

      else if e is TStaticMemberExprNode then
      begin
        // TypeName.MemberName — 정적 필드/속성 읽기 (예: System.EventArgs.Empty)
        var sm:=TStaticMemberExprNode(e);
        var smType:=ResolveExternalType(sm.TypeName);
        var smPi:=smType.GetProperty(sm.MemberName);
        if (smPi<>nil) and (smPi.GetGetMethod<>nil) then
          aIL.Emit(OpCodes.Call, smPi.GetGetMethod) // 정적 프로퍼티 getter는 Call(비가상)
        else
        begin
          var smFi:=smType.GetField(sm.MemberName);
          if smFi=nil then
            raise new Exception('타입 "'+smType.FullName+'"에 정적 필드/속성 "'+sm.MemberName+'"가 없습니다.');
          aIL.Emit(OpCodes.Ldsfld, smFi); // 정적 필드는 Ldsfld
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

      else if e is TInheritedCallExprNode then
      begin
        var ihe:=TInheritedCallExprNode(e);
        EmitInheritedCall(aIL, ihe.MethodName, ihe.Args, true);
      end

      else raise new Exception('알 수 없는 식 노드: '+e.GetType.Name);
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
      if s is TWritelnStringStmtNode then
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
        else
        begin
          wlI:=typeof(Console).GetMethod('WriteLine',[typeof(integer)]);
          EmitExpr(aIL, we.Arg); aIL.Emit(OpCodes.Call, wlI);
        end;
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
          propInfo:=extType.GetProperty(fas.FieldName);
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
        var ivVt:=InferType(ivs.ValueExpr);
        var ivClrType: System.Type;
        var ivClassName: string; var ivIsExternal: boolean;
        ivClassName:=''; ivIsExternal:=false;
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
        else
          ivClrType:=VTC(ivVt, '');
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
        EmitExpr(aIL, ivs.ValueExpr);
        aIL.Emit(OpCodes.Stloc, ivLoc);
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
        if mcs.ObjName='' then
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
        end
        else if (fLocalScope.Has(mcs.ObjName) or fGlobalScope.Has(mcs.ObjName))
                and (fLocalScope.HasClrType(mcs.ObjName) or fGlobalScope.HasClrType(mcs.ObjName)) then
        begin
          // sender.Focus(); 같은, 외부(객체) 타입 매개변수/지역변수를 통한 호출.
          if fLocalScope.Has(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(mcs.ObjName))
          else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(mcs.ObjName)); // [전역 var 버그 수정]
          if fLocalScope.HasClrType(mcs.ObjName) then qTargetType:=fLocalScope.GetClrType(mcs.ObjName)
          else qTargetType:=fGlobalScope.GetClrType(mcs.ObjName);
          if mcs.ObjCastType<>'' then
          begin
            qTargetType:=ResolveExternalType(mcs.ObjCastType);
            aIL.Emit(OpCodes.Castclass, qTargetType);
          end;
          var _getP2:=qTargetType.GetProperty(mcs.MethodName);
          if (mcs.Args.Count=0) and (_getP2<>nil) and (_getP2.GetGetMethod<>nil) then
          begin
            aIL.Emit(OpCodes.Callvirt, _getP2.GetGetMethod);
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
            aIL.Emit(OpCodes.Callvirt, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
        end
        else if fLocalScope.Has(mcs.ObjName) or fGlobalScope.Has(mcs.ObjName) then
        begin
          // c.Init(10) → Ldloc c + args + Call
          cn:=GetVarClassName(mcs.ObjName);
          vtVar:=GetVarType(mcs.ObjName);
          if fLocalScope.Has(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(mcs.ObjName))
          else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(mcs.ObjName));
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
            imb:=FindInstanceMethod(cn, mcs.MethodName);
            EmitArgsCoerced(aIL, mcs.Args, FindInstanceMethodParamTypes(cn, mcs.MethodName));
            aIL.Emit(OpCodes.Callvirt, imb);
            // void 메서드가 아닌 경우 반환값 버리기
            if imb.ReturnType<>typeof(System.Void) then
              aIL.Emit(OpCodes.Pop);
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
          var _getP:=qTargetType.GetProperty(mcs.MethodName);
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
          var lamMB:=EmitLambdaAsStaticMethod(evs.Lambda);
          var lamInvoke:=evInfo.EventHandlerType.GetMethod('Invoke');
          if (lamInvoke<>nil) and (lamInvoke.GetParameters.Length<>evs.Lambda.LamParams.Count) then
            raise new Exception('람다 매개변수 개수('+evs.Lambda.LamParams.Count.ToString+'개)가 이벤트 "'
              +evs.EventName+'"의 델리게이트 시그니처('+lamInvoke.GetParameters.Length.ToString+'개)와 다릅니다.');
          aIL.Emit(OpCodes.Ldnull);
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
        else
          rm:=typeof(System.Array).GetMethod('Resize').MakeGenericMethod([typeof(integer)]);
        aIL.Emit(OpCodes.Call, rm);
      end

      else if s is TArrayAssignStmtNode then
      begin
        aa:=TArrayAssignStmtNode(s); at2:=vtIntArray;
        if fGlobalScope.Has(aa.ArrName) then at2:=fGlobalScope.GetVType(aa.ArrName)
        else if fLocalScope.Has(aa.ArrName) then at2:=fLocalScope.GetVType(aa.ArrName);
        if fLocalScope.Has(aa.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(aa.ArrName))
        else aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(aa.ArrName));
        // [Stage 57] arr[i] := 'a'; 에서 arr가 문자열 배열이면 char 리터럴을 문자열로
        // 승격해야 한다 — 안 그러면 정수(문자코드)가 그대로 Stelem_Ref로 들어가
        // 힙 참조로 오인되어 GC/접근 시 크래시가 난다.
        EmitExpr(aIL, aa.Index);
        if at2=vtStrArray then EmitValueForVType(aIL, aa.ValueExpr, vtString)
        else EmitExpr(aIL, aa.ValueExpr);
        if at2=vtStrArray then aIL.Emit(OpCodes.Stelem_Ref)
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
        if not fMethods.ContainsKey(pc.ProcName) then
          raise new Exception('알 수 없는 프로시저 "'+pc.ProcName+'"');
        mb:=fMethods[pc.ProcName];
        var _pcParams: array of System.Type;
        if fTopParamClrTypes.ContainsKey(pc.ProcName) then _pcParams:=fTopParamClrTypes[pc.ProcName]
        else _pcParams:=nil;
        EmitArgsCoerced(aIL, pc.Args, _pcParams);
        aIL.Emit(OpCodes.Call, mb);
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

      else raise new Exception('알 수 없는 문장 노드: '+s.GetType.Name);
    end;

    // 메서드 시그니처의 i번째 매개변수의 실제 CLR 타입을 결정한다 (기본/지역클래스/외부타입 모두 포함)
    function ResolveParamClrType(sig: TMethodSignature; i: integer): System.Type;
    begin
      if (sig.ParamTypes[i]=vtObject) and (i<sig.ParamIsExternal.Count) and sig.ParamIsExternal[i] then
        Result:=ResolveExternalType(sig.ParamClassNames[i])
      else if sig.ParamTypes[i]=vtObject then
        Result:=VTC(vtObject, sig.ParamClassNames[i])
      else
        Result:=VTC(sig.ParamTypes[i], '');
    end;

    // [Stage 31] 최상위 함수/프로시저(TParamDef)의 매개변수 실제 CLR 타입을 결정한다.
    // ResolveParamClrType(TMethodSignature용)과 동일한 패턴이지만 TParamDef를 입력으로 받는다.
    function ResolveTopParamClrType(p: TParamDef): System.Type;
    begin
      if (p.ParamType=vtObject) and p.IsExternal then Result:=ResolveExternalType(p.ClassName)
      else if p.ParamType=vtObject then Result:=VTC(vtObject, p.ClassName)
      else if p.ParamType=vtInterface then Result:=VTC(vtInterface, p.ClassName)
      else if p.ParamType=vtEnum then Result:=VTC(vtEnum, p.ClassName) // [Phase 1]
      else Result:=VTC(p.ParamType, '');
    end;

    // [Stage 64] 람다(익명 메서드) 본문을 새 static 메서드(Program.__LambdaN)로 컴파일하고
    // 그 MethodBuilder를 돌려준다. 클로저가 없으므로(1차 범위) 지역 스코프를 통째로 새 것
    // (부모=fGlobalScope, 즉 전역 변수/함수는 보이지만 바깥 메서드의 지역변수는 안 보임)으로
    // 바꿔치기한 뒤 컴파일하고 끝나면 원래대로 되돌린다 — 이렇게 하면 본문 안에서 바깥
    // 메서드의 지역변수를 참조하려는 시도가 여기서 "선언되지 않은 변수" 오류로 자연스럽게
    // 걸러진다(별도의 캡처 검사 코드가 필요 없다). self/inherited도 지원하지 않는다 — 정적
    // 메서드라 인스턴스가 없으므로, 람다 본문에서 이들을 쓰면 정의되지 않은 동작이다(1차 제약).
    function EmitLambdaAsStaticMethod(lam: TLambdaExprNode): MethodBuilder;
    var paramTypes: array of System.Type; li: integer; lmb: MethodBuilder; lil: ILGenerator;
        savedLocalScope: TScope; lloc: LocalBuilder;
    begin
      fLambdaCounter:=fLambdaCounter+1;
      paramTypes:=new System.Type[lam.LamParams.Count];
      for li:=0 to lam.LamParams.Count-1 do paramTypes[li]:=ResolveTopParamClrType(lam.LamParams[li]);
      lmb:=fMainTB.DefineMethod('__Lambda'+fLambdaCounter.ToString,
        MethodAttributes.Public or MethodAttributes.Static, typeof(System.Void), paramTypes);
      lil:=lmb.GetILGenerator;

      savedLocalScope:=fLocalScope;
      fLocalScope:=new TScope('lambda', fGlobalScope); // [Stage 64] 클로저 차단
      for li:=0 to lam.LamParams.Count-1 do
      begin
        lloc:=lil.DeclareLocal(paramTypes[li]);
        fLocalScope.Declare(lam.LamParams[li].Name, lloc, lam.LamParams[li].ParamType);
        if (lam.LamParams[li].ParamType=vtObject) or (lam.LamParams[li].ParamType=vtInterface) then
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

      fLocalScope:=savedLocalScope; // 바깥 메서드 컴파일을 이어서 할 수 있도록 복원
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

        if sig.IsFunction then
          mb:=tb.DefineMethod(sig.Name, methAttrs, VTC(sig.ReturnType, ''), paramTypes)
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
    function ResolveExternalType(dottedName: string): System.Type;
    var asm: Assembly; t: System.Type; prefix, candidate: string; candidates: array of string;
    begin
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

      raise new Exception('외부 타입 "'+dottedName+'"을(를) 찾을 수 없습니다. '+
        '기본 프레임워크(WinForms/WPF/System.*)가 아니라면 {$reference 어셈블리명.dll} 지시문으로 '+
        '해당 타입이 들어있는 어셈블리를 먼저 등록했는지 확인하세요.');
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
          vt:=InferType(e);
          case vt of
            vtString: Result:=typeof(string);
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
    function ResolveMethodByArity(t: System.Type; mname: string; args: List<TExprNode>; isStatic: boolean): MethodInfo;
    var flags: BindingFlags; mi: MethodInfo; argCount: integer;
      bestScore: integer; bestMi: MethodInfo; found: boolean;
    begin
      if isStatic then flags:=BindingFlags.Public or BindingFlags.Static
      else flags:=BindingFlags.Public or BindingFlags.Instance;
      argCount:=args.Count;
      bestScore:=System.Int32.MinValue; bestMi:=nil; found:=false;
      foreach mi in t.GetMethods(flags) do
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
      foreach ci in t.GetConstructors(BindingFlags.Public or BindingFlags.Instance) do
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
      EmitExpr(aIL, argExpr);
    end;

    // aIL 스택에 target 참조가 이미 로드되어 있다고 가정하고, 그 위에
    // targetType의 memberName 속성(setter)이나 필드에 valueExpr 값을 설정한다.
    procedure EmitPropertyOrFieldSet(aIL: ILGenerator; targetType: System.Type; memberName: string; valueExpr: TExprNode);
    var pi: PropertyInfo; fi: System.Reflection.FieldInfo; setr: MethodInfo;
    begin
      // [Stage 57] Button1.Text := 'a'; 같은 Qualifier.Field 대입 경로. 목표 속성/필드의
      // 실제 CLR 타입을 이미 알고 있으므로 EmitArgForParamType으로 char→string 승격.
      pi:=targetType.GetProperty(memberName);
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

    // 정적 필드/속성 설정 (예: System.Console.Title := '...'). 인스턴스 리시버가 없으므로
    // Callvirt/Stfld가 아니라 Call/Stsfld를 쓴다.
    procedure EmitStaticPropertyOrFieldSet(aIL: ILGenerator; targetType: System.Type; memberName: string; valueExpr: TExprNode);
    var pi2: PropertyInfo; fi2: System.Reflection.FieldInfo; setr2: MethodInfo;
    begin
      // [Stage 57] System.Console.Title := 'a'; 같은 정적 속성/필드 대입 경로도 동일하게 처리.
      pi2:=targetType.GetProperty(memberName);
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

      // [Phase 1] 프로퍼티 — CLR PropertyBuilder + get/set 메서드 쌍으로 방출
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
          // ReadName은 반드시 같은 클래스에 선언된 필드 이름이어야 한다.
          if fFieldBuilders.ContainsKey(cd.Name) and fFieldBuilders[cd.Name].ContainsKey(ps.ReadName) then
          begin
            gIL.Emit(OpCodes.Ldarg_0);
            gIL.Emit(OpCodes.Ldfld, fFieldBuilders[cd.Name][ps.ReadName]);
          end
          else
            raise new Exception('프로퍼티 "'+cd.Name+'.'+ps.Name+'" getter: 필드 "'+ps.ReadName+'"을 찾을 수 없습니다');
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
            sIL.Emit(OpCodes.Ldarg_0);
            sIL.Emit(OpCodes.Ldarg_1);
            sIL.Emit(OpCodes.Stfld, fFieldBuilders[cd.Name][ps.WriteName]);
          end
          else
            raise new Exception('프로퍼티 "'+cd.Name+'.'+ps.Name+'" setter: 필드 "'+ps.WriteName+'"을 찾을 수 없습니다');
          sIL.Emit(OpCodes.Ret);
          pb.SetSetMethod(setM);
          fInstanceMethods[cd.Name]['set_'+ps.Name]:=setM;
        end;
      end;

      // 메서드 시그니처만 정의
      // 모두 Virtual + HideBySig로 정의: 자식 클래스에서 같은 이름/시그니처의
      // 메서드를 정의하면 CLR이 이름/시그니처 매칭으로 자동 override(슬롯 재사용) 처리한다.
      // (virtual/override 지시자는 이미 이 기본 동작과 일치하므로 별도 분기가 필요 없다.
      //  abstract만 실제로 다르다: 본문이 없으므로 MethodAttributes.Abstract를 추가한다.)
      methAttrs:=MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig;
      foreach sig in cd.Methods do
      begin
        paramTypes:=new System.Type[sig.ParamNames.Count];
        for i:=0 to sig.ParamNames.Count-1 do
          paramTypes[i]:=ResolveParamClrType(sig, i);
        var thisMethAttrs:=methAttrs;
        if sig.IsAbstract then thisMethAttrs:=thisMethAttrs or MethodAttributes.Abstract;
        if sig.IsFunction then
          mb:=tb.DefineMethod(sig.Name, thisMethAttrs, VTC(sig.ReturnType, ''), paramTypes)
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

      // 기본 생성자 추가 (부모 생성자 호출로 체이닝)
      // [Stage 47] 클래스 선언부에 "constructor Create(...)"로 매개변수가 선언돼 있으면
      // 그 시그니처 그대로 정의한다 (선언 없으면 cd.ConstructorParams는 빈 목록 → 기존과 동일).
      var ctorParamTypes:=new System.Type[cd.ConstructorParams.Count];
      for i:=0 to cd.ConstructorParams.Count-1 do
        ctorParamTypes[i]:=ResolveTopParamClrType(cd.ConstructorParams[i]);
      fCtorParamClrTypes[cd.Name]:=ctorParamTypes;
      var ctorBuilder:=tb.DefineConstructor(
        MethodAttributes.Public,
        CallingConventions.Standard,
        ctorParamTypes);
      fCtorBuilders[cd.Name]:=ctorBuilder;
      // [Stage 42] 사용자가 "constructor Create;"를 직접 선언한 클래스는 본문을 여기서 채우지
      // 않는다 — 이후 BuildConstructorBody가 ConstructorImpls에서 실제로 작성된 본문을
      // 컴파일해 넣는다 (inherited Create(...) 호출을 그 본문 안에서 원하는 위치에 직접
      // 쓸 수 있어야 하므로, 여기서 미리 "부모 호출 + Ret"를 넣어버리면 안 된다).
      if not cd.HasUserConstructor then
      begin
        var ctorIL:=ctorBuilder.GetILGenerator;
        ctorIL.Emit(OpCodes.Ldarg_0);
        if (cd.ParentName<>'') and fCtorBuilders.ContainsKey(cd.ParentName) then
          // 부모가 아직 CreateType되지 않았으므로 GetConstructor 대신
          // 만들어둔 ConstructorBuilder를 그대로 재사용 (.NET Core는 미완성
          // TypeBuilder에 대한 GetConstructor 호출을 지원하지 않음)
          parentCtor:=fCtorBuilders[cd.ParentName]
        else
        begin
          // 로컬에서 만든 클래스가 아니면(System.Object 또는 외부 어셈블리 타입)
          // parentType에서 직접 매개변수 없는 public 생성자를 찾는다.
          parentCtor:=parentType.GetConstructor(System.Type.EmptyTypes);
          if parentCtor=nil then
            raise new Exception('부모 타입 "'+parentType.FullName+'"에 매개변수 없는 public 생성자가 없습니다.');
        end;
        ctorIL.Emit(OpCodes.Call, parentCtor);
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
    begin
      if not fCtorBuilders.ContainsKey(impl.ClassName) then
        raise new Exception('생성자를 찾을 수 없음: '+impl.ClassName+'.Create');

      il:=fCtorBuilders[impl.ClassName].GetILGenerator;

      savedLocalScope:=fLocalScope;
      svResult:=fResultLocal; svResultType:=fResultType;
      svCurClass:=fCurClassName;

      fLocalScope:=new TScope('local(ctor)', fGlobalScope);
      fResultLocal:=nil; // 생성자는 반환값이 없음
      fCurClassName:=impl.ClassName;

      // [Stage 47] 생성자 매개변수를 로컬 슬롯에 복사 (Ldarg_1, Ldarg_2, ... — Ldarg_0은 self).
      // BuildMethodBody의 매개변수 바인딩과 동일한 패턴. CLR 타입은 BuildClassShell이
      // cd.ConstructorParams로부터 미리 계산해 둔 fCtorParamClrTypes를 사용한다(시그니처 일관성 유지).
      for i:=0 to impl.Parameters.Count-1 do
      begin
        p:=impl.Parameters[i].Name;
        var pClrType:=typeof(integer);
        if fCtorParamClrTypes.ContainsKey(impl.ClassName) and (i<fCtorParamClrTypes[impl.ClassName].Length) then
          pClrType:=fCtorParamClrTypes[impl.ClassName][i];
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
        end;
        // [Stage 67] vtMatrix의 원소 타입 이름을 ClassName에 보존 (GetVarClassName이 참조)
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 생성자 본문의 지역 const 선언 처리
      foreach var cd61 in impl.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);

      foreach st in impl.Body.Statements do EmitStatement(il, st);
      il.Emit(OpCodes.Ret);

      fLocalScope:=savedLocalScope;
      fResultLocal:=svResult; fResultType:=svResultType;
      fCurClassName:=svCurClass;
    end;

    // 클래스 메서드 본문 IL 생성
    procedure BuildMethodBody(impl: TMethodImplNode);
    var
      mb: MethodBuilder; il: ILGenerator;
      i: integer; p: string;
      savedLocalScope: TScope; // [Phase 2]
      svResult: LocalBuilder; svResultType: TVarType;
      svCurClass: string; st: TStmtNode;
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

      fLocalScope:=new TScope('local(method)', fGlobalScope);
      fCurClassName:=impl.ClassName;

      if impl.IsFunction then
      begin
        fResultType:=impl.ReturnType;
        fResultLocal:=il.DeclareLocal(VTC(impl.ReturnType, ''));
      end
      else
      begin
        fResultType:=vtInteger;
        fResultLocal:=nil;
      end;

      // 매개변수를 로컬 슬롯에 복사 (Ldarg_1, Ldarg_2, ... — Ldarg_0은 self)
      for i:=0 to impl.ParamNames.Count-1 do
      begin
        p:=impl.ParamNames[i];
        var pClrType:=typeof(integer);
        if fMethodParamClrTypes.ContainsKey(impl.ClassName)
           and fMethodParamClrTypes[impl.ClassName].ContainsKey(impl.MethodName)
           and (i<fMethodParamClrTypes[impl.ClassName][impl.MethodName].Length) then
          pClrType:=fMethodParamClrTypes[impl.ClassName][impl.MethodName][i];
        var loc:=il.DeclareLocal(pClrType);
        // [버그 수정] 예전에는 인스턴스 메서드의 매개변수 타입을 무조건 vtInteger로 기록해서,
        // GetVarType()에 의존하는 배열 원소 접근(Ldelem_I4 vs Ldelem_Ref 선택, Writeln 오버로드
        // 선택 등)이 array of string 매개변수에서도 항상 정수로 취급됐다 — 문자열 배열 원소를
        // 4바이트로 잘못 읽어 포인터가 깨지고 쓰레기 값이 출력되는 원인이었다. 이제 단형화 단계가
        // 이미 채워 둔 impl.ParamTypes[i](구체 타입)를 그대로 사용한다.
        if i<impl.ParamTypes.Count then fLocalScope.Declare(p, loc, impl.ParamTypes[i])
        else fLocalScope.Declare(p, loc, vtInteger);
        if pClrType<>typeof(integer) then fLocalScope.SetClrType(p, pClrType);
        // self=Ldarg_0 이므로 매개변수는 Ldarg_1부터
        if i=0 then il.Emit(OpCodes.Ldarg_1)
        else if i=1 then il.Emit(OpCodes.Ldarg_2)
        else if i=2 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i+1));
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
        end;
        // [Stage 67] vtMatrix 원소 타입 이름 보존
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 메서드 본문의 지역 const 선언 처리
      foreach var cd61 in impl.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);

      foreach st in impl.Body.Statements do EmitStatement(il, st);

      if impl.IsFunction then
      begin
        il.Emit(OpCodes.Ldloc, fResultLocal);
      end;
      il.Emit(OpCodes.Ret);

      fLocalScope:=savedLocalScope;
      fResultLocal:=svResult; fResultType:=svResultType;
      fCurClassName:=svCurClass;
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
    procedure DeclareStaticFunc(tb: TypeBuilder; d: TFuncDeclNode);
    var pt: array of System.Type; i: integer; mb: MethodBuilder; retClrType: System.Type; retCn66: string;
    begin
      pt:=new System.Type[d.Parameters.Count];
      for i:=0 to d.Parameters.Count-1 do pt[i]:=ResolveTopParamClrType(d.Parameters[i]);
      // [Stage 66] 연산자 오버로딩으로 맹글링된 함수는 System.Object가 아니라 실제 레코드/클래스
      // 반환 타입으로 선언해야 한다 — 특히 레코드는 값 타입이라 System.Object로 선언하면 박싱되어
      // 필드 접근(Ldflda 등)이 깨진다.
      retCn66:='';
      if fOperatorFuncRetClass.ContainsKey(d.Name) then retCn66:=fOperatorFuncRetClass[d.Name];
      retClrType:=VTC(d.ReturnType, retCn66);
      mb:=tb.DefineMethod(d.Name, MethodAttributes.Public or MethodAttributes.Static,
        retClrType, pt);
      fMethods[d.Name]:=mb; fTopParamClrTypes[d.Name]:=pt; fFuncReturnTypes[d.Name]:=d.ReturnType;
      foreach var nf65 in d.NestedFuncs do DeclareStaticFunc(tb, nf65);
      foreach var np65 in d.NestedProcs do DeclareStaticProc(tb, np65);
    end;

    procedure DeclareStaticProc(tb: TypeBuilder; d: TProcDeclNode);
    var pt: array of System.Type; i: integer; mb: MethodBuilder;
    begin
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
    begin
      // [Stage 65b] 시그니처는 DeclareStaticFunc 패스에서 이미 등록되어 있다.
      // 여기서는 등록된 MethodBuilder를 가져와 본문만 방출한다.
      mb:=fMethods[d.Name];
      pt:=fTopParamClrTypes[d.Name];
      // [Stage 66] DeclareStaticFunc와 동일한 이유로 연산자 오버로딩 맹글링 함수는
      // 실제 반환 클래스/레코드 타입을 사용한다.
      var retCn66b:='';
      if fOperatorFuncRetClass.ContainsKey(d.Name) then retCn66b:=fOperatorFuncRetClass[d.Name];
      retClrType:=VTC(d.ReturnType, retCn66b);
      il:=mb.GetILGenerator;

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
        end;
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
        end;
        // [Stage 67] vtMatrix 원소 타입 이름 보존
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 함수 본문의 지역 const 선언 처리
      foreach var cd61 in d.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.Emit(OpCodes.Ldloc, fResultLocal); il.Emit(OpCodes.Ret);
      fLocalScope:=savedLocalScope; fResultLocal:=svR; fResultType:=svRT;
    end;

    procedure BuildStaticProc(tb: TypeBuilder; d: TProcDeclNode);
    var
      pt: array of System.Type; i: integer; mb: MethodBuilder; il: ILGenerator;
      savedLocalScope: TScope; // [Phase 2]
      svR: LocalBuilder; svRT: TVarType; st: TStmtNode;
    begin
      // [Stage 65b] 시그니처는 DeclareStaticProc 패스에서 이미 등록되어 있다.
      mb:=fMethods[d.Name];
      pt:=fTopParamClrTypes[d.Name];
      il:=mb.GetILGenerator;

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
        end;
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
        end;
        // [Stage 67] vtMatrix 원소 타입 이름 보존
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 프로시저 본문의 지역 const 선언 처리
      foreach var cd61 in d.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.Emit(OpCodes.Ret);
      fLocalScope:=savedLocalScope; fResultLocal:=svR; fResultType:=svRT;
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
      fFuncReturnTypes:=new Dictionary<string, TVarType>;
      fTypeBuilders:=new Dictionary<string, TypeBuilder>;
      fBuiltTypes:=new Dictionary<string, System.Type>;
      fFieldBuilders:=new Dictionary<string, Dictionary<string, FieldBuilder>>;
      fInstanceMethods:=new Dictionary<string, Dictionary<string, MethodBuilder>>;
      fAbstractMethods:=new Dictionary<string, List<string>>; // [Stage 53]
      fClassParents:=new Dictionary<string, string>;
      fMethodReturnTypes:=new Dictionary<string, Dictionary<string, TVarType>>;
      fMethodParamClrTypes:=new Dictionary<string, Dictionary<string, array of System.Type>>;
      fCtorBuilders:=new Dictionary<string, ConstructorBuilder>;
      fCtorParamClrTypes:=new Dictionary<string, array of System.Type>; // [Stage 47]
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
      fLoadedAssemblies:=new List<Assembly>;
      fClassExternalParentType:=new Dictionary<string, System.Type>;
      fResultLocal:=nil; fResultType:=vtInteger; fCurClassName:='';
      // [Stage 60]
      fLoopBreakLabels:=new List<&Label>;
      fLoopContinueLabels:=new List<&Label>;
      fLoopExceptDepths:=new List<integer>;
      fCurExceptDepth:=0;

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
      fAutoAssemblyMap['System.Xaml']:=
        ['System.Xaml','System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'];
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
    var asm: Assembly; shortName: string; loadErr: string;
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

      // -2. [Phase 1] 열거형을 가장 먼저 빌드 (인터페이스·클래스 필드 타입으로 참조됨)
      BuildEnumTypes(modB);

      // -1.5. [Stage 62] 레코드(값 타입)를 열거형 다음, 인터페이스/클래스보다 먼저 완전히 빌드한다.
      // 메서드가 없어 클래스처럼 나중 단계를 기다릴 필요가 없으므로 여기서 CreateType까지 끝낸다.
      BuildRecordTypes(modB);

      // -1. 인터페이스 타입을 클래스보다 먼저 완전히 빌드 (CreateType까지)
      //     클래스의 AddInterfaceImplementation에는 완성된 Type이 필요하기 때문
      foreach id in fProg.InterfaceDecls do
        BuildInterfaceShell(modB, id);

      // 0. 클래스 상속 관계 등록 (부모가 먼저 선언되어 있어야 함)
      foreach cd in fProg.ClassDecls do
        fClassParents[cd.Name]:=cd.ParentName;

      // 1. 클래스 TypeBuilder 생성 (껍데기 + 필드 + 메서드 시그니처)
      // ClassDecls는 소스에 선언된 순서(부모가 항상 자식보다 먼저)이므로
      // 부모 TypeBuilder가 자식보다 먼저 만들어짐이 보장된다.
      foreach cd in fProg.ClassDecls do
        BuildClassShell(modB, cd);

      // 2. 메인 프로그램 타입 (static 메서드들을 담을 타입)
      mainTB:=modB.DefineType('Program', TypeAttributes.Public);
      fMainTB:=mainTB; // [Stage 64] 람다가 EmitStatement에서도 static 메서드를 여기 추가할 수 있도록

      // 3. 일반 static 함수/프로시저 빌드
      // [Stage 65b] 최상위 함수/프로시저도 선언 순서와 무관하게 서로 호출할 수
      // 있도록, 먼저 모든 시그니처를 등록한 뒤(3-1) 본문을 만든다(3-2).
      foreach fd in fProg.FuncDecls do DeclareStaticFunc(mainTB, fd);
      foreach pd in fProg.ProcDecls do DeclareStaticProc(mainTB, pd);
      foreach fd in fProg.FuncDecls do BuildStaticFunc(mainTB, fd);
      foreach pd in fProg.ProcDecls do BuildStaticProc(mainTB, pd);

      // 4. 클래스 메서드 본문 IL 생성
      foreach impl in fProg.MethodImpls do BuildMethodBody(impl);

      // 4-1. [Stage 42] 사용자 정의 생성자 본문 IL 생성 (constructor Create; ... end;)
      foreach ctorImpl in fProg.ConstructorImpls do BuildConstructorBody(ctorImpl);
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

      // 5. 클래스 타입 완성 (CreateType)
      foreach cd in fProg.ClassDecls do
      begin
        fBuiltTypes[cd.Name]:=fTypeBuilders[cd.Name].CreateType;
      end;

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

        // [Stage 61] 전역 const 선언 처리. var 슬롯이 모두 준비된 뒤,
        // 최상위 begin...end 문장을 실행하기 전에 선언 순서대로 초기값을 대입한다.
        foreach var cd61 in fProg.ConstDecls do EmitConstDecl(il, fGlobalScope, cd61);

        foreach st in fProg.Statements do EmitStatement(il, st);

        rk:=typeof(Console).GetMethod('ReadKey', System.Type.EmptyTypes);
        il.Emit(OpCodes.Call, rk); il.Emit(OpCodes.Pop); il.Emit(OpCodes.Ret);
      end;

      mainTB.CreateType;
      if not fProg.IsLibrary then
        ab.SetEntryPoint(mm, PEFileKinds.ConsoleApplication);
      ab.Save(outName);
    end;
  end;

implementation

end.