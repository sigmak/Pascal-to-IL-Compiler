// ============================================================
// CodeGen_Part3_Build.pas
// [분할 2/2] CodeGen.pas(원래 9000줄+)를 3조각으로 나눈 것 중 하나입니다.
// 람다/타입해석/리플렉션 + 클래스·이터레이터·정적함수 빌드 + 공개 API(constructor, GenerateExe) — 오늘 잡은 TryResolveMethodCallClrType 버그가 이 파일에 있습니다
// CodeGen.pas가 `{$include CodeGen_Part3_Build.pas}`로 이 파일을 그 자리에 그대로 끌어와 붙이므로
// (텍스트 삽입 — 이 컴파일러가 partial class를 지원하지 않아서 쓰는 방식입니다),
// 컴파일 결과(IL)는 분할 전과 100% 동일합니다.
// 반드시 CodeGen.pas와 같은 폴더에 두어야 합니다. 이 파일만 단독으로 컴파일할 수
// 없습니다(TCodeGenerator의 필드/다른 부분에 의존).
// ============================================================

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
      // [버그 수정] vtObjArray("array of GenericTypeParameterBuilder" 같은 array of <외부 타입>)를
      // 포함해 그 외 배열류(vtIntArray/vtStrArray/vtGenericArray/vtMatrix)도, 위 분기들처럼
      // sig.ParamClassNames[i]를 그대로 넘겨야 한다. 예전에는 이 마지막 else가 무조건 ''를
      // 넘겨서, VTC(vtObjArray, '')가 원소 타입 이름을 몰라 object[]로 조용히 폴백했다 — 그 결과
      // "gpBuilders: array of GenericTypeParameterBuilder" 매개변수가 실제로는
      // GenericTypeParameterBuilder[]가 아니라 object[]로 선언되어, 이후
      // "gpBuilders[i].SetGenericParameterAttributes(...)"가 원소 타입을 System.Object로
      // 오인해 "타입 System.Object에 메서드 SetGenericParameterAttributes가 없습니다"로
      // 실패했다(자기컴파일 중 실제 재현됨). VTC 자체는 cn이 필요 없는 타입(vtIntArray 등)에서는
      // cn을 무시하므로, 항상 넘겨도 다른 경우엔 영향이 없다.
      else
        Result:=VTC(sig.ParamTypes[i], sig.ParamClassNames[i]);
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
      // [버그 수정] ResolveParamClrType과 동일한 이유 — array of <외부 타입>(vtObjArray)/
      // array of T(vtGenericArray)/2차원 배열(vtMatrix) 매개변수도 p.ClassName(Parser가
      // fLastGenericName으로 채워 둔 원소 타입 이름)을 넘겨야 한다. 예전처럼 무조건 ''를
      // 넘기면 VTC가 원소 타입을 몰라 object[]로 조용히 폴백한다.
      else Result:=VTC(p.ParamType, p.ClassName);
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
        // [버그 수정] "List<TVarType>"처럼 제네릭 타입 인자가 우리 컴파일러 자신이 빌드한
        // 열거형(예: TVarType)인 경우 — 열거형은 클래스와 별도로 fBuiltEnums에 등록되므로
        // (BuildEnumTypes/fBuiltEnums 참고) 위 fBuiltTypes/fTypeBuilders 조회에서는 항상 빠졌다.
        // 그 결과 이 함수가 곧장 ResolveExternalType(tag)로 떨어져 "외부 타입 TVarType을(를)
        // 찾을 수 없습니다"류의 실패(또는 상위에서 System.Object 폴백)로 이어졌다(셀프호스팅
        // 컴파일 실제 사례 — Parser.pas의 "argTypes: List<TVarType>" 지역변수). VTC(216행
        // 부근)가 이미 쓰는 것과 동일한 fBuiltEnums 조회를 여기도 추가한다.
        else if fBuiltEnums.ContainsKey(tag) then Result:=fBuiltEnums[tag]
        // [버그 수정] "Dictionary<string, Dictionary<string, TV>>"처럼 현재 빌드 중인
        // 제네릭 메서드/함수 자신의 타입 매개변수(TV 등)가 다른 외부 제네릭 타입의
        // 인자 자리에 "중첩"되어 나타나는 경우 — 이 함수는 지금까지 fCurGenericSubst
        // (BuildClassShell의 sig.IsGeneric 분기, ApplyGenericParamConstraints 등이
        // 미리 채워 둔 "타입 매개변수 이름 → GenericTypeParameterBuilder" 표)를 전혀
        // 확인하지 않고 곧장 ResolveExternalType(tag)로 떨어졌다. 타입 매개변수가
        // 매개변수 자리에 직접 오는 경우(x: TV)는 ResolveParamClrType의 vtGeneric
        // 분기가 VTC를 통해 fCurGenericSubst를 이미 확인하지만, 이렇게 다른 제네릭
        // 타입 안에 인자로 중첩된 경우는 이 함수가 유일한 경로라 그 확인이 빠져 있었다
        // (자기컴파일 실제 사례 — Parser.pas의
        // "DictDictHas<TV>(d: Dictionary<string, Dictionary<string, TV>>; ...)").
        // ResolveExternalType을 시도하기 전에 먼저 fCurGenericSubst부터 확인한다.
        else if (fCurGenericSubst<>nil) and fCurGenericSubst.ContainsKey(tag) then Result:=fCurGenericSubst[tag]
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
      // [Stage 109 재적용] sb.Append(chars[i])처럼 배열 인덱싱 결과(chars[i])가 오버로드
      // 함수의 인자로 직접 쓰이는 경우 — 지금까지 이 분기가 아예 없어서 InferArgClrType이
      // nil(중립)을 돌려줬고, StringBuilder.Append처럼 오버로드가 많은 메서드에서
      // ScoreParamMatch가 모든 후보를 동점 처리해 GetMethods() 나열 순서상 우연히 걸린
      // (char가 아닌) 오버로드가 선택됐다 — 실제 스택엔 Ldelem_U2로 정확히 올라온 char
      // 원시값 하나뿐인데 콜리는 다른 타입(예: object/string)을 기대해 그 작은 정수를
      // 참조처럼 역참조하다가 NullReferenceException/AccessViolationException으로 죽었다
      // (자기컴파일 실제 재현: StripCommentsForUsesScan, ExpandIncludes의 chars[i]).
      // TChainedIndexExprNode와 동일한 패턴으로 GetExprClrType을 그대로 재사용한다.
      else if e is TArrayIndexExprNode then
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
      // [버그 수정] "fChars:=src.ToCharArray;"처럼 obj.Method(...) 형태의 메서드 호출 식
      // (TMethodCallExprNode)이 배열 매개변수/필드 대입 자리의 인자로 직접 쓰이는 경우 —
      // 지금까지 InferArgClrType에 TMethodCallExprNode 분기가 전혀 없어서 항상 nil(중립)로
      // 떨어졌다. EmitArgForParamType의 "paramType.IsArray and InferArgClrType(argExpr)=nil"
      // 분기는 이걸 "배열이 아니라 스칼라 값 하나"로 오인해, char[] 등을 돌려주는 메서드
      // 호출 결과(사실은 배열 참조)를 1개짜리 새 배열의 원소 자리에 억지로 Stelem으로
      // 밀어넣는 손상된 IL을 방출했다 — 그 결과 fChars 필드에 잘못된(손상된) 배열이
      // 대입되어 이후 fChars 참조 시점에 NullReferenceException으로 이어졌다
      // (자기컴파일 실제 재현: TLexer.Create의 "fChars:=src.ToCharArray"). 이미 존재하는
      // TryResolveMethodCallClrType(1658행)으로 메서드의 정확한 CLR 반환 타입을 구해
      // 이 문제를 해결한다.
      else if e is TMethodCallExprNode then
      begin
        try
          Result:=TryResolveMethodCallClrType(TMethodCallExprNode(e));
        except
          Result:=nil;
        end;
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
        var _seenNames100b := new HashSet<string>;
        if fInstanceMethods.ContainsKey(_localCls100b) then
          foreach var _mbKvp100b in fInstanceMethods[_localCls100b] do
          begin
            _bound100b.Add(_mbKvp100b.Value);
            _seenNames100b.Add(_mbKvp100b.Key);
          end;
        // [자기컴파일 버그 수정] 위 목록은 이 로컬 클래스가 "직접 선언한" 메서드만 담는다 —
        // GetType/ToString/Equals/GetHashCode처럼 System.Object에서 물려받아 재정의하지
        // 않은 멤버는 여기 전혀 없어서, obj.GetType처럼 흔한 호출도 "메서드가 없습니다"로
        // 실패했다(실제 사례: impl.Body.Statements[i].GetType). 이름이 겹치지 않는 한
        // System.Object의 public 인스턴스 메서드를 폴백으로 추가한다(재정의된 이름은
        // 이미 위에서 담겼으므로 중복 추가하지 않는다).
        if flags = (BindingFlags.Public or BindingFlags.Instance) then
          foreach var _objMi100b in typeof(System.Object).GetMethods(flags) do
            if not _seenNames100b.Contains(_objMi100b.Name) then
              _bound100b.Add(_objMi100b);
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

    // [Stage 101 버그 수정] baseType.GetProperties(...)를 직접 부르면, baseType이
    // TypeBuilderInstantiation(예: List<TToken>처럼 원소 타입이 아직 CreateType되지
    // 않은 로컬 클래스인 BCL 제네릭 컬렉션)일 때 System.NotSupportedException
    // ("지정한 메서드가 지원되지 않습니다")을 던진다 — Reflection.Emit이 TypeBuilder로
    // 만든 제네릭 인스턴스화에는 GetProperties/GetMethods 같은 조회 API를 직접 지원하지
    // 않기 때문이다(SafeGetMethods/SafeGetConstructors/SafeGetProperty가 이미 이 문제를
    // 우회하고 있음 — 바로 위 참고). EmitIndexerGet의 "Item" 프로퍼티 탐색(obj[i])만은
    // 이 우회를 안 거치고 baseType.GetProperties를 그대로 불러 List<TToken>[i]처럼
    // 로컬 클래스를 원소로 갖는 컬렉션을 인덱싱할 때 이 예외로 죽었다. SafeGetMethods와
    // 동일한 패턴(열린 제네릭 정의에서 프로퍼티를 찾고 TypeBuilder.GetMethod로 그
    // get/set 접근자만 닫힌 버전에 바인딩, TBoundGenericPropertyInfo로 감싸기)을 적용한다.
    function SafeGetProperties(t: System.Type; flags: BindingFlags): array of PropertyInfo;
    begin
      if t.GetType().Name = 'TypeBuilderInstantiation' then
      begin
        var openT101 := t.GetGenericTypeDefinition();
        var openProps101 := openT101.GetProperties(flags);
        var bound101 := new System.Collections.Generic.List<PropertyInfo>();
        for var i101 := 0 to openProps101.Length-1 do
          if openProps101[i101].DeclaringType = openT101 then
          begin
            var g101: MethodInfo := nil;
            var s101: MethodInfo := nil;
            if openProps101[i101].GetGetMethod(true) <> nil then
              g101 := TypeBuilder.GetMethod(t, openProps101[i101].GetGetMethod(true));
            if openProps101[i101].GetSetMethod(true) <> nil then
              s101 := TypeBuilder.GetMethod(t, openProps101[i101].GetSetMethod(true));
            bound101.Add(new TBoundGenericPropertyInfo(openProps101[i101], t, g101, s101));
          end;
        Result := bound101.ToArray();
      end
      // [Stage 101] TypeBuilderInstantiation이 아니라 아직 CreateType 안 된 로컬 클래스의
      // TypeBuilder 자체가 넘어온 경우(SafeGetMethods의 Stage 100 분기와 동일한 상황)도
      // t.GetProperties가 똑같이 NotSupportedException을 던진다. 이 컴파일러가 만드는
      // 로컬 클래스는 지금까지 인덱서(Item 프로퍼티)를 정의하지 않으므로 빈 배열로 충분하다.
      else if (t.GetType().Name = 'TypeBuilder') and (FindLocalClassNameForTypeBuilder(t) <> '') then
        Result := new PropertyInfo[0]
      else
        Result := t.GetProperties(flags);
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
      foreach var cand in SafeGetProperties(baseType, BindingFlags.Public or BindingFlags.Instance) do
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
      // [자기컴파일 버그 수정] baseType이 TypeBuilderInstantiation(예:
      // "fTemplateImpls: Dictionary<string, List<TMethodImplNode>>"처럼, 값 타입이 아직
      // CreateType 안 된 로컬 클래스를 담은 제네릭 컬렉션)이면 itemProp.PropertyType(위
      // SafeGetProperties가 TypeBuilder.GetMethod로 바인딩해 얻은 getter의 ReturnType)은
      // fTypeBuilders에 든 원본 TypeBuilder와 참조가 다른 래퍼 타입이라 .FullName이 비어
      // 있다 — 그 결과 이어지는 "....Add(x)" 같은 메서드 호출이 "타입 ""에 메서드 Add가
      // 없습니다"로 실패한다(자기컴파일 실제 사례: TMonomorphizer.Run의
      // "fTemplateImpls[impl.ClassName].Add(impl)"). InferIndexerResultType에 적용한 것과
      // 동일하게, GetGenericArguments()로 MakeGenericType에 넘겼던 원본 타입 인자를
      // 그대로 얻어(참조 보존) Result로 우선 사용한다.
      if baseType.GetType().Name = 'TypeBuilderInstantiation' then
      begin
        var _eig102 := baseType.GetGenericArguments();
        if _eig102.Length >= 1 then Result := _eig102[_eig102.Length - 1]
        else Result := itemProp.PropertyType;
      end
      else
        Result := itemProp.PropertyType;
    end;

    function ResolveMethodByArity(t: System.Type; mname: string; args: List<TExprNode>; isStatic: boolean): MethodInfo;
    var flags: BindingFlags; mi: MethodInfo; argCount: integer;
      bestScore: integer; bestMi: MethodInfo; found: boolean;
      _localClsRMBA: string; _isUncreatedLocal: boolean;
    begin
      if isStatic then flags:=BindingFlags.Public or BindingFlags.Static
      else flags:=BindingFlags.Public or BindingFlags.Instance;
      argCount:=args.Count;
      bestScore:=System.Int32.MinValue; bestMi:=nil; found:=false;
      // [셀프 컴파일 버그 수정] t가 아직 CreateType 안 된 로컬 클래스의 TypeBuilder이면
      // SafeGetMethods가 반환하는 MethodInfo들은 실제로는 MethodBuilder라서 그 위에서
      // mi.GetParameters()를 호출하면 "형식이 만들어지지 않았습니다"(NotSupportedException)가
      // 난다. 이런 경우는 리플렉션 대신 선언 시점에 이미 기록해 둔
      // fMethodParamClrTypes[클래스명][메서드명]을 그대로 파라미터 타입 목록으로 쓴다.
      _localClsRMBA:=FindLocalClassNameForTypeBuilder(t);
      _isUncreatedLocal:=(_localClsRMBA<>'') and (t.GetType().Name='TypeBuilder');
      foreach mi in SafeGetMethods(t, flags) do
        if mi.Name=mname then
        begin
          var ps50: array of System.Type;
          if _isUncreatedLocal and fMethodParamClrTypes.ContainsKey(_localClsRMBA)
             and fMethodParamClrTypes[_localClsRMBA].ContainsKey(mi.Name) then
            ps50:=fMethodParamClrTypes[_localClsRMBA][mi.Name]
          else
          begin
            var psInfo50:=mi.GetParameters;
            ps50:=new System.Type[psInfo50.Length];
            for var _pj50:=0 to psInfo50.Length-1 do
              ps50[_pj50]:=psInfo50[_pj50].ParameterType;
          end;
          if ps50.Length=argCount then
          begin
            var score50:=0;
            var i50:=0;
            while i50<argCount do
            begin
              var argType50:=InferArgClrType(args[i50]);
              score50:=score50+ScoreParamMatch(ps50[i50], argType50);
              i50:=i50+1;
            end;
            if (not found) or (score50>bestScore) then
            begin bestScore:=score50; bestMi:=mi; found:=true; end;
          end;
        end;
      Result:=bestMi;
      // [Stage 104] t에 인스턴스/정적 메서드로 mname(args)가 없으면, .NET 확장 메서드
      // (this 매개변수를 첫 인자로 받는 정적 메서드 — 예: Assembly.GetCustomAttribute)에서
      // 한 번 더 찾는다. PascalABC.NET/C#은 "instance.ExtensionMethod(args)" 호출 문법을
      // 정식 지원하지만, 우리 리졸버는 여태 t 타입에 직접 선언된 멤버만 리플렉션으로
      // 찾았기 때문에 확장 메서드는 전부 "메서드가 없습니다"로 실패했었다(자기호스팅
      // 실제 사례: GetExecutingAssembly().GetCustomAttribute(typeof(X))).
      if Result=nil then
        Result:=TryResolveExtensionMethod(t, mname, args);
    end;

    // [Stage 104] 확장 메서드 폴백 — 반환된 MethodInfo.IsStatic=true이므로, 호출부는
    // 이미 스택에 올라간 인스턴스를 그대로 첫 인자로 삼아 Call(정적 호출)로 방출하면
    // 된다(별도 인자 재배치 불필요). 단, 파라미터 목록을 읽을 때는 첫 번째(this) 파라미터를
    // 건너뛰고 나머지를 실제 호출 인자(args)와 맞춰야 한다 — 호출부에서 처리.
    function TryResolveExtensionMethod(t: System.Type; mname: string; args: List<TExprNode>): MethodInfo;
    var
      extClasses: array of System.Type;
      ec: System.Type; mi: MethodInfo;
      argCount, i: integer; ps: array of ParameterInfo;
      bestScore: integer; bestMi: MethodInfo; found: boolean;
      score: integer;
    begin
      Result:=nil;
      // 실전 코드에서 마주치는 확장 메서드 컨테이너 클래스를 여기 계속 추가해 나간다.
      extClasses:=[
        typeof(System.Reflection.CustomAttributeExtensions),
        typeof(System.Linq.Enumerable)
      ];
      argCount:=args.Count;
      bestScore:=System.Int32.MinValue; bestMi:=nil; found:=false;
      foreach ec in extClasses do
        foreach mi in ec.GetMethods(BindingFlags.Public or BindingFlags.Static) do
          if (mi.Name=mname) and mi.IsDefined(typeof(System.Runtime.CompilerServices.ExtensionAttribute), false)
             and (not mi.IsGenericMethodDefinition) then // 제네릭 확장메서드(Select 등)는 이후 별도 처리
          begin
            ps:=mi.GetParameters;
            if (ps.Length=argCount+1) and ps[0].ParameterType.IsAssignableFrom(t) then
            begin
              score:=0;
              i:=0;
              while i<argCount do
              begin
                score:=score+ScoreParamMatch(ps[i+1].ParameterType, InferArgClrType(args[i]));
                i:=i+1;
              end;
              if (not found) or (score>bestScore) then
              begin bestScore:=score; bestMi:=mi; found:=true; end;
            end;
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
        qTypeIsStatic92: boolean; // [버그 수정] 아래 static-chain 폴백(ResolveOrEmitStaticChain) 경로용 — 주석 참고
    begin
      Result:=nil;
      qTypeIsStatic92:=true; // 기본값: 기존 동작(ObjName에 점이 있으면 정적 호출로 간주)과 동일
      try
        if mc.ObjCastType<>'' then
        begin
          qType:=ResolveExternalType(mc.ObjCastType);
        end
        else if (mc.ObjName<>'') and (mc.ObjName.IndexOf('.')>=0) then
        begin
          var chainSegs52:=SplitByDot(mc.ObjName);
          if IsChainStartSegment(chainSegs52[0]) then
            // [버그 수정] "evInfo.EventHandlerType.GetMethod('Invoke')"처럼 ObjName 자체가
            // 지역변수로 시작하는 체인(예: evInfo.EventHandlerType)인 경우, 예전에는 여기서
            // 그냥 exit해 버려 Result가 nil로 남았다. 그러면 var 타입 추론 분기(TInlineVarStmtNode)가
            // InferType(TMethodCallExprNode)의 기본 폴백(vtInteger→Int32)으로 지역변수
            // "lamInvoke"를 System.Int32로 잘못 DeclareLocal 했고, 이후
            // "lamInvoke.GetParameters"가 "타입 System.Int32에 메서드 GetParameters가
            // 없습니다"로 실패했다(자기컴파일 중 실제 재현됨). EmitQualifierChainLoad와
            // 완전히 같은 판별을 IL 방출 없이 수행하는 InferQualifierChainType이 정확히
            // 이 목적으로 이미 존재하므로(1052행, 1945행에서 이미 재사용 중), 여기서도
            // 재사용해 체인의 최종 타입(qType)을 구하고 아래 mc.MethodName 조회 로직으로
            // 계속 이어간다 — 실패하면 이 함수를 감싼 try/except가 기존과 동일하게 nil로
            // 조용히 폴백한다.
            begin
              qType:=InferQualifierChainType(chainSegs52);
              // 체인의 시작점이 지역/전역 변수·필드(인스턴스)이므로, 아래 421행 부근의
              // "ObjName에 점이 있으면 정적 호출"이라는 (진짜 정적 타입 체인만을 위한) 기본
              // 가정이 이 경우엔 틀리다 — qType은 인스턴스이지 정적 타입 자체가 아니므로
              // ResolveMethodByArity를 인스턴스 호출로 수행해야 한다.
              qTypeIsStatic92:=false;
            end
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
            // [버그 수정] ObjName 자체가 타입이 아니라 "타입.정적프로퍼티" 형태의 다단계
            // 정적 체인(예: "System.AppDomain.CurrentDomain" — AppDomain 타입의 CurrentDomain
            // 정적 프로퍼티)이면 위 ResolveExternalType(mc.ObjName) 시도는 무조건 실패해
            // qType이 nil로 남는다. 그 결과 이 함수 전체가 nil을 반환해 GetExprClrType이
            // System.Object로 폴백하고, "System.AppDomain.CurrentDomain.GetAssemblies()"의
            // 결과 타입(Assembly[])을 몰라 foreach 순회 변수가 System.Object로 선언되어
            // 버렸다(_asm.GetType(name)처럼 1-인자 GetType 호출이 System.Object에는
            // 없다는 오류로 이어짐 — 셀프호스팅 컴파일 실제 사례). EmitExpr의 정적 체인
            // 호출 경로(1138행 부근)와 동일하게 ResolveOrEmitStaticChain으로 재시도한다
            // (aIL=nil이면 IL을 방출하지 않고 타입만 계산한다).
            if qType=nil then
            begin
              var _chainIsInst92: boolean;
              try qType:=ResolveOrEmitStaticChain(nil, mc.ObjName, _chainIsInst92); except qType:=nil; end;
              // ResolveOrEmitStaticChain은 성공하면 항상 "체인의 마지막 세그먼트가 프로퍼티/메서드를
              // 거쳐 나온 인스턴스"를 돌려준다(예: AppDomain 타입 자체가 아니라 그 CurrentDomain
              // 프로퍼티가 돌려주는 AppDomain 인스턴스) — 그 위의 mc.MethodName 호출은 항상 인스턴스
              // 호출이어야 한다. 아래 481행 부근의 기존 판별식(mc.ObjName에 점이 있으면 무조건 정적
              // 호출)을 그대로 쓰면 "System.AppDomain.CurrentDomain.GetAssemblies()"의 GetAssemblies를
              // (존재하지 않는) 정적 메서드로 찾다가 실패해 nil을 반환 → GetExprClrType이 다시
              // System.Object로 폴백하는 문제가 있었다.
              if (qType<>nil) and _chainIsInst92 then qTypeIsStatic92:=false;
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
        begin
          // [자기컴파일 버그 수정] cimpl89.Parameters처럼 로컬(우리가 만드는) 클래스 인스턴스의
          // 필드/프로퍼티를 곧장 참조하는 식은, 여기서 곧장 FindExternalAncestorType으로
          // 넘어가면(원래 이 분기는 "w.Title"처럼 외부 상속 타입의 멤버를 찾기 위한 것) 그
          // 클래스 자신의 필드는 못 찾고 System.Object로 폴백해버린다(EmitExpr의 실제 방출
          // 경로 — 2156행 부근 TryFindFieldBuilder(cn,...) — 는 이미 이걸 올바르게 처리하는데
          // 타입 추론 전용인 이 함수만 그 경로가 없었다). TryFindFieldBuilder/fInstanceMethods로
          // 먼저 로컬 클래스 자신의 필드/getter/메서드를 찾고, 없을 때만 기존처럼 외부 조상
          // 타입에서 찾는다.
          var _mcCn:=fLocalScope.GetClassName(mc.ObjName);
          var _mcFb: FieldBuilder;
          if (mc.Args.Count=0) and TryFindFieldBuilder(_mcCn, mc.MethodName, _mcFb) then
          begin Result:=_mcFb.FieldType; exit; end;
          if DictDictHas(fInstanceMethods, _mcCn, 'get_'+mc.MethodName) then
          begin Result:=fInstanceMethods[_mcCn]['get_'+mc.MethodName].ReturnType; exit; end;
          var _mcMb: MethodBuilder;
          if TryFindInstanceMethod(_mcCn, mc.MethodName, _mcMb) then
          begin Result:=_mcMb.ReturnType; exit; end;
          qType:=FindExternalAncestorType(_mcCn);
        end
        else if fGlobalScope.Has(mc.ObjName) and fGlobalScope.HasClassName(mc.ObjName) then
        begin
          var _mcCnG:=fGlobalScope.GetClassName(mc.ObjName);
          var _mcFbG: FieldBuilder;
          if (mc.Args.Count=0) and TryFindFieldBuilder(_mcCnG, mc.MethodName, _mcFbG) then
          begin Result:=_mcFbG.FieldType; exit; end;
          if DictDictHas(fInstanceMethods, _mcCnG, 'get_'+mc.MethodName) then
          begin Result:=fInstanceMethods[_mcCnG]['get_'+mc.MethodName].ReturnType; exit; end;
          var _mcMbG: MethodBuilder;
          if TryFindInstanceMethod(_mcCnG, mc.MethodName, _mcMbG) then
          begin Result:=_mcMbG.ReturnType; exit; end;
          qType:=FindExternalAncestorType(_mcCnG);
        end
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
        // [Stage 100 버그 수정] mc.ObjName=''인 암시적 self 메서드 호출(예: "PeekAt(1).Kind"의 PeekAt(1))은 여기서
        // 전혀 처리되지 않아 그냥 마지막 else exit로 떨어지고(qType가 정해지지 않음) Result가 함수 첫줄의
        // 기본값 typeof(System.Object)로 그대로 남아 버려진다 — 그 결과 "PeekAt(1).Kind"의 Inner 타입이 항상
        // System.Object로 폴백되어 ".Kind"가 "타입 System.Object에 멤버 Kind가 없습니다"로 실패했다(셀프호스팅
        // 컴파일 실제 사례). EmitExpr의 TMethodCallExprNode/ObjName='' 분기(위 1975행 부근)와 동일한 순서로
        // "자기 클래스(상속 포함) 인스턴스 메서드" → "외부 상속 타입의 메서드/프로퍼티" 순서로 찾는다.
        else if mc.ObjName='' then
        begin
          var _selfMb100: MethodBuilder;
          if TryFindInstanceMethod(fCurClassName, mc.MethodName, _selfMb100) then
          begin
            Result:=_selfMb100.ReturnType;
            exit;
          end;
          var _selfExtType100:=FindExternalAncestorType(fCurClassName);
          if _selfExtType100<>nil then
          begin
            var _selfPi100:=SafeGetProperty(_selfExtType100, mc.MethodName);
            if (mc.Args.Count=0) and (_selfPi100<>nil) and (_selfPi100.GetGetMethod<>nil) then
            begin Result:=_selfPi100.PropertyType; exit; end;
            var _selfMi100:=ResolveMethodByArity(_selfExtType100, mc.MethodName, mc.Args, false);
            if _selfMi100<>nil then Result:=_selfMi100.ReturnType;
          end;
          exit;
        end
        else
          exit;

        if qType=nil then exit;
        // [자기컴파일 버그 수정] qType이 아직 CreateType되지 않은 로컬(우리가 지금 만들고
        // 있는) 클래스의 TypeBuilder이면, 바로 아래 SafeGetProperty/ResolveMethodByArity가
        // NotSupportedException을 던진다(TypeBuilder는 CreateType 전엔 완전한 리플렉션을
        // 지원하지 않음) — 그러면 이 함수를 감싼 try/except가 조용히 Result:=nil로
        // 빠지고, 호출부인 GetExprClrType은 결국 typeof(System.Object)로 잘못 단정해버린다
        // (실제 사례: "foreach var _cd68 in fProg.ClassDecls do" — fProg 필드의 타입이
        // 우리가 만들고 있는 로컬 클래스 TProgramNode라 ClassDecls 필드를 못 찾고
        // System.Object로 폴백 → 이후 "_cd68.Name"이 "타입 System.Object에 메서드 Name가
        // 없습니다"로 실패). TChainedMemberExprNode 분기(Stage 101 수정)와 동일하게,
        // SafeGetProperty를 시도하기 전에 로컬 클래스 딕셔너리(fInstanceMethods/
        // fFieldBuilders)로 먼저 조회한다.
        var _mcLocalCls100:=FindLocalClassNameForTypeBuilder(qType);
        if (_mcLocalCls100<>'') and fInstanceMethods.ContainsKey(_mcLocalCls100) then
        begin
          if (mc.Args.Count=0) and fInstanceMethods[_mcLocalCls100].ContainsKey('get_'+mc.MethodName) then
          begin Result:=fInstanceMethods[_mcLocalCls100]['get_'+mc.MethodName].ReturnType; exit; end;
          var _mcFb100: FieldBuilder;
          if TryFindFieldBuilder(_mcLocalCls100, mc.MethodName, _mcFb100) then
          begin Result:=_mcFb100.FieldType; exit; end;
          if fInstanceMethods[_mcLocalCls100].ContainsKey(mc.MethodName) then
          begin Result:=fInstanceMethods[_mcLocalCls100][mc.MethodName].ReturnType; exit; end;
        end;
        pi:=SafeGetProperty(qType, mc.MethodName);
        if (mc.Args.Count=0) and (pi<>nil) and (pi.GetGetMethod<>nil) then
        begin Result:=pi.PropertyType; exit; end;
        mi:=ResolveMethodByArity(qType, mc.MethodName, mc.Args, qTypeIsStatic92 and (mc.ObjName.IndexOf('.')>=0));
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
    var idxArgType97: System.Type; itemProp97: PropertyInfo; bestScore97: integer; _isTBI97: boolean;
    begin
      Result:=nil;
      if baseType=nil then exit;
      if baseType=typeof(string) then begin Result:=typeof(char); exit; end;
      if baseType.IsArray then begin Result:=baseType.GetElementType; exit; end;
      idxArgType97:=InferArgClrType(idxExpr);
      // [버그 수정] baseType이 TypeBuilderInstantiation(예: "fTokens: List<TToken>"처럼,
      // 원소 타입 TToken이 자기컴파일 대상이라 아직 CreateType 안 된 로컬 클래스인 제네릭
      // 컬렉션)이면 .NET Reflection.Emit이 baseType.GetProperties(...) 호출 자체를
      // NotSupportedException("유형이 만들어지기 전에 호출된 멤버는 지원되지 않습니다")으로
      // 막는다. 이 예외는 GetExprClrType의 바깥쪽 try/except에 조용히 먹혀 Result가
      // System.Object로 잘못 폴백되고, 그 결과 "fTokens[fPos].Kind"처럼 인덱싱 뒤에
      // 멤버가 이어지는 식이 전부 "타입 System.Object에 멤버 X가 없습니다"로 실패했다
      // (자기컴파일 실제 사례 — PreScanNestedSubprograms).
      //
      // [추가 버그 수정] 처음에는 SafeGetProperty(TBoundGenericPropertyInfo — 열린 제네릭의
      // get_Item을 TypeBuilder.GetMethod로 닫힌 버전에 바인딩)로 우회했으나, 이 바인딩
      // 경로가 돌려주는 ReturnType은 fTypeBuilders에 든 원본 TypeBuilder(TToken)와는 다른
      // 별개의 래퍼 Type 객체였다 — 참조도 다르고 .FullName도 null, 심지어 .Name 비교로도
      // 못 되돌릴 수 있어(실제로 재현됨), 그 다음 멤버 조회가 계속 실패했다.
      // 더 안전한 방법은 TypeBuilderInstantiation.GetGenericArguments()를 쓰는 것이다 —
      // 이건 MakeGenericType 호출 시 넘겼던 타입 인자를 그대로(=원본 TypeBuilder 참조 그대로)
      // 돌려주는, 리플렉션 제약이 없는 단순 데이터 조회라서 CreateType 여부와 무관하게 항상
      // 안전하다. List<T>/IList<T>처럼 타입 인자가 1개면 그게 바로 Item의 결과 타입이고,
      // Dictionary<K,V>/IDictionary<K,V>처럼 2개면 마지막 인자(V)가 Item의 결과 타입이다
      // (컬렉션 인덱서 관례상 항상 "값" 타입 인자가 마지막에 옴). 그 외 케이스나 이 방법이
      // 실패하면 기존 SafeGetProperty 경로로 폴백한다.
      _isTBI97 := baseType.GetType().Name = 'TypeBuilderInstantiation';
      if _isTBI97 then
      begin
        var _genArgs97 := baseType.GetGenericArguments();
        if _genArgs97.Length >= 1 then
          Result := _genArgs97[_genArgs97.Length - 1]
        else
        begin
          itemProp97 := SafeGetProperty(baseType, 'Item');
          if (itemProp97<>nil) and (itemProp97.GetGetMethod<>nil) then Result:=itemProp97.PropertyType;
        end;
        exit;
      end;
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
        // [자기컴파일 버그 수정] <식> as <TypeName> 뿐 아니라 이제 Parser가 로컬 클래스로의
        // TypeName(expr) 하드 캐스트도 TAsCastExprNode(IsExternalType=false)로 만든다
        // (Parser.pas의 "TVarRefNode(x).VarName" 같은 패턴). 지금까지 GetExprClrType에
        // TAsCastExprNode 분기가 아예 없어서 캐스트 결과가 무조건 System.Object로 폴백해
        // 뒤이은 ".VarName" 멤버 접근이 실패했다. EmitExpr의 TAsCastExprNode 처리부(Castclass
        // 대상 타입 조회)와 동일한 순서로 조회한다.
        else if e is TAsCastExprNode then
        begin
          var _asc90:=TAsCastExprNode(e);
          if _asc90.IsExternalType then Result:=ResolveExternalType(_asc90.TargetType)
          else if fBuiltInterfaces.ContainsKey(_asc90.TargetType) then Result:=fBuiltInterfaces[_asc90.TargetType]
          else if fBuiltTypes.ContainsKey(_asc90.TargetType) then Result:=fBuiltTypes[_asc90.TargetType]
          else if fTypeBuilders.ContainsKey(_asc90.TargetType) then Result:=fTypeBuilders[_asc90.TargetType];
        end
        else if e is TChainedMemberExprNode then
        begin
          var _ch90:=TChainedMemberExprNode(e);
          var _innerT90:=GetExprClrType(_ch90.Inner);
          if _innerT90=nil then exit;
          // [Stage 101] _innerT90이 아직 CreateType되지 않은 로컬 클래스의 TypeBuilder이면
          // 아래 SafeGetProperty/GetField가 예외를 던진다(이 함수 전체가 try/except로 감싸여
          // 있어 크래시는 안 나지만, 그대로면 System.Object로 조용히 폴백해 타입 추론이
          // 틀려버린다) — EmitExpr의 TChainedMemberExprNode와 동일하게 로컬 딕셔너리로 먼저 조회한다.
          var _chLocalCls101:=FindLocalClassNameForTypeBuilder(_innerT90);
          if (_chLocalCls101<>'') and fInstanceMethods.ContainsKey(_chLocalCls101) then
          begin
            if (not _ch90.IsCall) and fInstanceMethods[_chLocalCls101].ContainsKey('get_'+_ch90.MemberName) then
            begin Result:=fInstanceMethods[_chLocalCls101]['get_'+_ch90.MemberName].ReturnType; exit; end;
            if DictDictHas(fFieldBuilders, _chLocalCls101, _ch90.MemberName) then
            begin Result:=fFieldBuilders[_chLocalCls101][_ch90.MemberName].FieldType; exit; end;
            if fInstanceMethods[_chLocalCls101].ContainsKey(_ch90.MemberName) then
            begin Result:=fInstanceMethods[_chLocalCls101][_ch90.MemberName].ReturnType; exit; end;
          end;
          var _pi90:=SafeGetProperty(_innerT90, _ch90.MemberName);
          if (not _ch90.IsCall) and (_pi90<>nil) and (_pi90.GetGetMethod<>nil) then
          begin Result:=_pi90.PropertyType; exit; end;
          if not _ch90.IsCall then
          begin
            // [자기컴파일 버그 수정] EmitExpr의 동일 지점(위 993행대 주석 참고)과 같은 이유로
            // raw _innerT90.GetField(...)는 아직 CreateType 안 된 로컬 TypeBuilder에서
            // NotSupportedException을 던진다. 이 함수 전체가 try/except로 감싸여 있어 죽지는
            // 않지만, 예외가 나는 즉시 Result가 기본값(System.Object)에 머물러 타입 추론이
            // 틀려버린다(실제 사례: "X.GetType.Name"에서 "X.GetType"의 타입이 System.Type이
            // 아니라 System.Object로 잘못 추론되어, 그 다음 ".Name" 단계가 "System.Object에
            // 멤버 Name이 없습니다"로 실패). 부모 체인까지 훑는 TryFindFieldBuilder로 먼저
            // 찾고, 그래도 없으면 예외를 삼키는 SafeGetField로 대체한다.
            var _fbCh101: FieldBuilder;
            var _fiCh101: FieldInfo;
            if (_chLocalCls101<>'') and TryFindFieldBuilder(_chLocalCls101, _ch90.MemberName, _fbCh101) then
              _fiCh101:=_fbCh101
            else
              _fiCh101:=SafeGetField(_innerT90, _ch90.MemberName);
            if _fiCh101<>nil then begin Result:=_fiCh101.FieldType; exit; end;
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
        // [버그 수정] Target[Index] 인덱싱 결과의 타입 — Target이 TArrayIndexExprNode(ArrName[Index]) 형태인
        // 경우. 지금까지 GetExprClrType에 이 분기가 없어서 "fClassGenericParam[templateName].Count"처럼
        // 필드에 담긴 Dictionary<string,List<string>> 등을 ArrName 인덱싱으로 표현한 식(자기컴파일 파서가
        // 실제로 생성하는 패턴) 뒤에 ".Member"가 이어지면 System.Object로 폴백해 "타입 System.Object에
        // 멤버 Count가 없습니다"로 실패했다(셀프호스팅 컴파일 실제 사례). EmitExpr의 TArrayIndexExprNode
        // 처리부(2632행 부근)와 동일한 순서로 ArrName의 실제 CLR 타입을 찾은 뒤, 배열이면 원소 타입,
        // 그 외(List<T>/Dictionary<K,V> 등)는 InferIndexerResultType의 Item 인덱서 판별 로직을 재사용한다.
        else if e is TArrayIndexExprNode then
        begin
          var _aiG90:=TArrayIndexExprNode(e);
          var _aiBaseT90: System.Type := nil;
          var _aiFb90: FieldBuilder;
          // [Stage 109 재적용] HasClrType은 SetClrType이 호출된 적 있는 변수만 true다 —
          // "chars: array of char := s.ToCharArray" 같은 array-of 지역/전역 변수는
          // 선언 시 SetClrType이 호출된 적이 없어 HasClrType이 항상 false였고, 그러면
          // 아래 두 분기가 전부 스킵되어 _aiBaseT90이 nil로 남아 System.Object로
          // 잘못 폴백했다(자기컴파일 실제 재현: StripCommentsForUsesScan/ExpandIncludes의
          // chars[i]). HasClrType이 실패해도 Loc.LocalType(선언된 CLR 타입, 항상 존재)을
          // 마지막 수단으로 직접 조회한다.
          if fLocalScope.Has(_aiG90.ArrName) then
          begin
            if fLocalScope.HasClrType(_aiG90.ArrName) then
              _aiBaseT90:=fLocalScope.GetClrType(_aiG90.ArrName)
            else
              _aiBaseT90:=fLocalScope.GetLoc(_aiG90.ArrName).LocalType;
          end
          else if fGlobalScope.Has(_aiG90.ArrName) then
          begin
            if fGlobalScope.HasClrType(_aiG90.ArrName) then
              _aiBaseT90:=fGlobalScope.GetClrType(_aiG90.ArrName)
            else
              _aiBaseT90:=fGlobalScope.GetLoc(_aiG90.ArrName).LocalType;
          end
          else if (fCurClassName<>'') and TryFindFieldBuilder(fCurClassName, _aiG90.ArrName, _aiFb90) then
            _aiBaseT90:=_aiFb90.FieldType;
          if _aiBaseT90<>nil then Result:=InferIndexerResultType(_aiBaseT90, _aiG90.Index);
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
        // [자기컴파일 버그 수정] (a - b).ToString / (a + b).Foo 처럼 산술 이항식 바로 뒤에
        // 멤버/메서드가 체이닝되는 경우 — GetExprClrType에 TBinOpNode 분기가 아예 없어서
        // 지금까지 무조건 맨 위 기본값 System.Object로 폴백했다. EmitExpr의
        // TChainedMemberExprNode 처리부는 이 타입을 보고 "값 타입이면 지역변수에 담아
        // 주소를 취해 Call, 아니면 Callvirt"를 결정하는데(1013행대), System.Object는
        // IsValueType=false이므로 박싱/주소 취득 과정을 건너뛰고 스택에 그대로 남아있는
        // 원시 int32 값 위에 곧바로 Callvirt를 걸어버렸다 — 참조가 아닌 원시값을 객체
        // 포인터로 오인하는 손상된 IL이라, 실행 시 관리되는 예외조차 못 띄우고 프로세스가
        // 아무 메시지 없이 죽는다(실제 재현: Main.pas의 "(compileOrder.Count - 1).ToString").
        // InferType의 TBinOpNode 분기(문자열 > 실수 > int64 > 정수 승격, boAnd/boOr는
        // 항상 논리형)와 동일한 규칙을 CLR 타입으로 그대로 옮긴다.
        else if e is TBinOpNode then
        begin
          var _bo90:=TBinOpNode(e);
          var _boLt90:=GetExprClrType(_bo90.Left);
          var _boRt90:=GetExprClrType(_bo90.Right);
          if (_bo90.Op=boAnd) or (_bo90.Op=boOr) then Result:=typeof(boolean)
          else if (_boLt90=typeof(string)) or (_boRt90=typeof(string)) then Result:=typeof(string)
          else if (_boLt90=typeof(double)) or (_boRt90=typeof(double)) then Result:=typeof(double)
          else if (_boLt90=typeof(int64)) or (_boRt90=typeof(int64)) then Result:=typeof(int64)
          else Result:=typeof(integer);
        end
        else if e is TStrLiteralNode then Result:=typeof(string)
        else if e is TIntLiteralNode then Result:=typeof(integer)
        else if e is TRealLiteralNode then Result:=typeof(double)
        else if e is TInt64LiteralNode then Result:=typeof(int64)
        else if e is TBoolLiteralNode then Result:=typeof(boolean)
        else if e is TCharLiteralNode then Result:=typeof(char)
        else if e is TLengthExprNode then Result:=typeof(integer)   // ← 추가: Length(x).Method 체이닝 시 필요
        else if e is TIntToStrNode then Result:=typeof(string)      // ← 추가: 
        else if e is TBoolToStrNode then Result:=typeof(string);    // ← 추가: 
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
      // [Stage 106 버그 수정] var/const 참조 매개변수(ByRef, 예: string&) 자리에 변수를
      // 인자로 넘기는 호출부가 지금까지 EmitExpr로 그 변수의 "값"만 스택에 올렸다.
      // 콜리(callee, BuildStaticProc/BuildMethodBody의 Stage 100 진입부)는 스택에 올라온
      // 것을 무조건 "주소"로 여겨 Ldarg+Ldobj로 역참조하므로, 넘긴 지역/전역 변수가 아직
      // 값이 대입되기 전(참조 타입이면 기본값 null)이면 그 진입부에서 곧바로
      // NullReferenceException이 터진다 — 실제 재현 사례: Main.pas의
      // ResolveProject(projPath, var mainFile, var outputFileName) 호출부에서
      // projMainFile/projOutName이 호출 시점에 아직 미대입(null) 상태로 넘어가 크래시.
      // paramType이 ByRef면 EmitExpr(값 로드) 대신 그 변수의 "주소"(Ldloca)를 올려야 한다.
      if paramType.IsByRef then
      begin
        if argExpr is TVarRefNode then
        begin
          var _brName106:=TVarRefNode(argExpr).VarName;
          if fLocalScope.Has(_brName106) then aIL.Emit(OpCodes.Ldloca, fLocalScope.GetLoc(_brName106))
          else if fGlobalScope.Has(_brName106) then aIL.Emit(OpCodes.Ldloca, fGlobalScope.GetLoc(_brName106))
          else raise new Exception('var/const 인자로 쓸 수 없는 변수 "'+_brName106+'"');
        end
        else
          raise new Exception('var/const 매개변수에는 변수만 인자로 전달할 수 있습니다 (식은 불가).');
        exit;
      end;
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
      // [자기컴파일 버그 수정] params 배열 매개변수(예: string.Split(params char[] separator))
      // 자리에 배열이 아니라 스칼라 값 하나(예: 문자 리터럴 ',')가 인자로 온 경우 — 지금까지
      // 이 분기 위쪽 어디에도 걸리지 않고 그냥 맨 아래 EmitExpr(aIL, argExpr)로 흘러가,
      // 문자 하나의 원시값(예: ','의 코드 44)을 그대로 스택에 얹은 채 char[] 배열 참조를
      // 요구하는 Callvirt에 넘겨버렸다. 이는 검증 불가능한 IL이라 실행 시 어떤 관리되는
      // 예외도 던지지 못하고(스택의 정수값을 배열 포인터로 역참조하려다) 프로세스가 아무
      // 메시지도 없이 곧바로 죽는다 — 자기호스팅 컴파일 중 "raw.Split(',')" 호출부에서
      // 실제로 재현된 증상(로그가 그 직전 줄에서 뚝 끊기고 셸 프롬프트로 복귀). 목표
      // 매개변수가 배열이고 인자 식 자체가 배열 리터럴이 아니며, 인자의 CLR 타입이 그
      // 배열 타입에 대입 불가능하면(=스칼라 원소 하나) 1개짜리 배열로 감싸서 넘긴다.
      if paramType.IsArray and not (argExpr is TArrayLiteralExprNode) then
      begin
        var _argClrT48s:=InferArgClrType(argExpr);
        // [Stage 110 진단] EmitArgForParamType이 목표 타입=배열인데 인자 식의 실제 CLR
        // 타입을 어떻게 추론했는지 컴파일 시점(self-compile 중 Lexer.pas를 컴파일하는
        // 단계)에 그대로 콘솔에 찍는다. _argClrT48s가 NIL이거나 목표 타입과 다르면
        // 바로 아래 "1개짜리 배열로 감싸기" 분기가 실행돼 손상된 IL이 나온다 — 어느 쪽인지
        // 여기서 직접 확인한다. 확인 후엔 이 블록 전체를 지워도 된다.
        if argExpr is TMethodCallExprNode then
        begin
          var _diagMc110:=TMethodCallExprNode(argExpr);
          var _diagTypeName110: string;
          if _argClrT48s=nil then _diagTypeName110:='NIL' else _diagTypeName110:=_argClrT48s.FullName;
          Writeln('[진단-EAFPT] 메서드호출 인자: ObjName="' + _diagMc110.ObjName + '", MethodName="' +
            _diagMc110.MethodName + '", 목표paramType=' + paramType.FullName + ', 추론된_argClrT48s=' +
            _diagTypeName110);
        end;
        // [자기컴파일 버그 수정 - 배열 유형 불일치 안전장치] 인자의 추론된 CLR 타입이
        // 이미 배열(예: string.ToCharArray()가 돌려주는 char[])인데 목표 매개변수/필드
        // 타입과 원소 타입이 어긋나면(예: 필드가 실제로는 다른 원소 타입의 배열로 잘못
        // 만들어진 경우), 예전 코드는 이 경우를 "배열이 아니라 스칼라 값 하나"로 오인해
        // 1개짜리 배열에 억지로 감싸는 코드로 빠졌다 — 실제로는 배열 참조(포인터)인 값을
        // 스칼라 원소값인 것처럼 Stelem으로 밀어넣어 검증 불가능한(unverifiable) IL이
        // 됐고, 실행 시 필드가 손상된 배열로 채워져 그 필드를 다시 읽는 시점에 엉뚱한
        // NullReferenceException/AccessViolationException으로 이어졌다 (실제 재현:
        // TLexer.Create의 "fChars:=src.ToCharArray" — fChars 필드의 실제 CLR 타입이
        // char[]가 아니게 잘못 만들어졌던 게 근본 원인). 그 근본 원인이 무엇이든, 여기서
        // 미리 막아 손상된 IL 대신 명확한 컴파일 타임 예외로 원인을 즉시 드러낸다.
        if (_argClrT48s<>nil) and _argClrT48s.IsArray and (not paramType.IsAssignableFrom(_argClrT48s)) then
        begin
          var _mismatchDesc48s:='(식 종류: '+argExpr.GetType.Name+')';
          if argExpr is TMethodCallExprNode then
            _mismatchDesc48s:='"'+TMethodCallExprNode(argExpr).ObjName+'.'+TMethodCallExprNode(argExpr).MethodName+'(...)"';
          raise new Exception('[내부 오류] 배열 타입 불일치: 대상 타입 "'+paramType.FullName
            +'"에 실제 배열 타입 "'+_argClrT48s.FullName+'"을(를) 대입할 수 없습니다 (원소 타입이 다름). '
            +'식: '+_mismatchDesc48s+'. 필드/매개변수 선언에서 배열 원소 타입 해석(ClassName/VTC)을 확인하세요.');
        end;
        if (_argClrT48s=nil) or (not paramType.IsAssignableFrom(_argClrT48s)) then
        begin
          var _elemT48s:=paramType.GetElementType;
          aIL.Emit(OpCodes.Ldc_I4, 1);
          aIL.Emit(OpCodes.Newarr, _elemT48s);
          aIL.Emit(OpCodes.Dup);
          aIL.Emit(OpCodes.Ldc_I4, 0);
          EmitArgForParamType(aIL, argExpr, _elemT48s);
          if _elemT48s.IsValueType then aIL.Emit(OpCodes.Stelem, _elemT48s)
          else aIL.Emit(OpCodes.Stelem_Ref);
          exit;
        end;
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
      // [진단] "array of char/real/int64/object" 같은 클래스 필드는 VTC(vtGenericArray/
      // vtObjArray, cn)가 원소 타입 이름(cn)을 알아야 정확한 배열 타입(예: char[])을
      // 만든다. cn이 비어 있으면 VTC는 조용히 int32[]/object[]로 폴백한다 — 이게 바로
      // "fChars: array of char" 필드가 char[]가 아니라 다른 배열로 잘못 만들어져
      // "fChars:=src.ToCharArray"에서 손상된 IL로 이어졌던 유력한 원인이다. Parser 쪽
      // 필드 선언 파싱에서 원소 타입 이름을 못 채워주는 경로가 남아있는지 바로 눈에
      // 보이도록 경고를 남긴다(원인 확인 후 이 블록은 지워도 된다).
      if ((fd.FieldType=vtGenericArray) or (fd.FieldType=vtObjArray)) and (fd.ClassName='') then
        Writeln('[진단-경고] 필드 "'+fd.Name+'"이(가) 배열 타입인데 원소 타입 이름(ClassName)이 비어 있습니다 — VTC가 int32[]/object[]로 잘못 폴백할 수 있습니다.');
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
    // [리팩터링] BuildClassShell이 로컬 50개, IL 4.8KB짜리 단일 메서드로 비대해지면서
    // BadImageFormatException(메서드 호출 시점에 즉시 발생 — 본문이 한 줄도 실행되기 전에
    // 터짐, 즉 IL 자체가 손상된 것으로 보임)을 유발하는 것으로 의심되어, 책임을 5개의
    // 작은 프로시저로 쪼갰다. 로직/진단 로그는 전부 그대로 옮기기만 했고 변경하지 않았다.

    // 1) 부모 타입 결정 + TypeBuilder.DefineType + 내부 딕셔너리 초기화 + 인터페이스 등록
    function BuildClassShell_DefineType(modBuilder: ModuleBuilder; cd: TClassDeclNode; var parentTypeOut: System.Type): TypeBuilder;
    var tb: TypeBuilder; parentType: System.Type;
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

      Writeln('[MARK-BCS-1] parentType 결정 완료="'+parentType.FullName+'", classHasAbstractMethod='+classHasAbstractMethod.ToString+' — DefineType 호출 직전');
      tb:=modBuilder.DefineType(cd.Name, classTypeAttrs, parentType);
      Writeln('[MARK-BCS-2] modBuilder.DefineType 완료');
      fTypeBuilders[cd.Name]:=tb;
      fFieldBuilders[cd.Name]:=new Dictionary<string, FieldBuilder>;
      fInstanceMethods[cd.Name]:=new Dictionary<string, MethodBuilder>;
      fInstanceMethodsByArity[cd.Name]:=new Dictionary<string, MethodBuilder>; // [버그 수정] 오버로드 구분용
      Writeln('[MARK-BCS-3] 내부 딕셔너리 초기화 완료');

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

      parentTypeOut:=parentType;
      Result:=tb;
    end;

    // 2) 필드 정의
    procedure BuildClassShell_Fields(tb: TypeBuilder; cd: TClassDeclNode);
    var fd: TFieldDeclNode; fb: FieldBuilder;
    begin
      Writeln('[MARK-BCS-4] 필드 루프 시작, cd.Fields.Count='+cd.Fields.Count.ToString);
      foreach fd in cd.Fields do
      begin
        Writeln('[MARK-BCS-4a] 필드 "'+fd.Name+'" ResolveFieldClrType 호출 직전');
        var _fdClrType:=ResolveFieldClrType(fd);
        Writeln('[MARK-BCS-4b] 필드 "'+fd.Name+'" ResolveFieldClrType 완료 -> "'+_fdClrType.FullName+'", DefineField 호출 직전');
        fb:=tb.DefineField(fd.Name, _fdClrType, FieldAttributes.Public);
        Writeln('[MARK-BCS-4c] 필드 "'+fd.Name+'" DefineField 완료');
        fFieldBuilders[cd.Name][fd.Name]:=fb;
        // [Stage 66] self.필드/obj.필드 형태의 연산자 오버로딩 대상 판별용
        if (fd.FieldType=vtObject) and (not fd.IsExternalType) and (fd.ClassName<>'') then
        begin
          if not fFieldObjClassName.ContainsKey(cd.Name) then
            fFieldObjClassName[cd.Name]:=new Dictionary<string, string>;
          fFieldObjClassName[cd.Name][fd.Name]:=fd.ClassName;
        end;
      end;
    end;

    // 3) 메서드 시그니처만 정의 (본문은 이후 BuildMethodBody가 채운다)
    procedure BuildClassShell_Methods(tb: TypeBuilder; cd: TClassDeclNode);
    var sig: TMethodSignature; mb: MethodBuilder;
        paramTypes: array of System.Type; i: integer; methAttrs: MethodAttributes;
    begin
      // [Stage 85] 프로퍼티(PropertyBuilder) 방출은 메서드 시그니처가 모두 정의된
      // 다음으로 옮겼다 — read/write 접근자가 필드가 아니라 메서드를 가리키는 경우
      // (예: property Enabled: boolean read FEnabled write SetEnabled;) 그 메서드의
      // MethodBuilder가 이미 존재해야 get/set 프로퍼티 메서드 본문에서 호출(Callvirt)할
      // 수 있기 때문이다. 실제 방출 코드는 아래 "메서드 시그니처만 정의" 블록 다음에 있다.

      // 모두 Virtual + HideBySig로 정의: 자식 클래스에서 같은 이름/시그니처의
      // 메서드를 정의하면 CLR이 이름/시그니처 매칭으로 자동 override(슬롯 재사용) 처리한다.
      // (virtual/override 지시자는 이미 이 기본 동작과 일치하므로 별도 분기가 필요 없다.
      //  abstract만 실제로 다르다: 본문이 없으므로 MethodAttributes.Abstract를 추가한다.)
      Writeln('[MARK-BCS-5] 필드 루프 종료, 메서드 시그니처 루프 시작, cd.Methods.Count='+cd.Methods.Count.ToString);
      methAttrs:=MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig;
      foreach sig in cd.Methods do
      begin
        Writeln('[MARK-BCS-5a] 메서드 시그니처 "'+sig.Name+'" 처리 시작, IsGeneric='+sig.IsGeneric.ToString);
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
          fInstanceMethodsByArity[cd.Name][sig.Name+'#'+sig.ParamNames.Count.ToString]:=mb; // [버그 수정] 오버로드 구분용
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
          fInstanceMethodsByArity[cd.Name][sig.Name+'#'+sig.ParamNames.Count.ToString]:=mb; // [버그 수정] 오버로드 구분용
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
    end;

    // 4) 프로퍼티(PropertyBuilder + get/set 메서드 쌍) 방출
    procedure BuildClassShell_Properties(tb: TypeBuilder; cd: TClassDeclNode);
    begin
      Writeln('[MARK-BCS-6] 메서드 시그니처 루프 종료, 프로퍼티 루프 시작, cd.Properties.Count='+cd.Properties.Count.ToString);
      // [Phase 1, Stage 85 확장] 프로퍼티 — CLR PropertyBuilder + get/set 메서드 쌍으로 방출.
      // 메서드 시그니처 정의가 끝난 뒤에 처리하므로, read/write가 필드가 아니라
      // 메서드 이름을 가리키는 경우(예: property Enabled: boolean read FEnabled
      // write SetEnabled;)에도 그 메서드의 MethodBuilder를 이미 찾을 수 있다.
      foreach var ps in cd.Properties do
      begin
        Writeln('[MARK-BCS-6a] 프로퍼티 "'+ps.Name+'" 처리 시작');
        var propClrType: System.Type;
        if (ps.PropType=vtObject) and ps.IsExternalType then
          propClrType:=ResolveExternalType(ps.PropClassName)
        else
          propClrType:=VTC(ps.PropType, ps.PropClassName);

        var pb:=tb.DefineProperty(ps.Name, PropertyAttributes.None, propClrType, nil);

        // getter
        if ps.ReadName<>'' then
        begin
          // [진단] System.Type.EmptyTypes를 DefineMethod 인자 자리에 바로 인라인으로 넣으면
          // gen1에서 newarr+stelem.ref로 잘못 감싸져서 ArrayTypeMismatchException이 난다
          // (Console.ReadKey GetMethod 건과 동일한 근본 원인). 지역변수로 우회.
          var getterParamTypes: array of System.Type;
          getterParamTypes:=System.Type.EmptyTypes;
          var getM:=tb.DefineMethod('get_'+ps.Name,
            MethodAttributes.Public or MethodAttributes.SpecialName or
            MethodAttributes.HideBySig or MethodAttributes.Virtual,
            propClrType, getterParamTypes);
          var gIL:=getM.GetILGenerator;
          if DictDictHas(fFieldBuilders, cd.Name, ps.ReadName) then
          begin
            // ReadName이 같은 클래스에 선언된 필드 이름인 경우 (기존 동작)
            gIL.Emit(OpCodes.Ldarg_0);
            gIL.Emit(OpCodes.Ldfld, fFieldBuilders[cd.Name][ps.ReadName]);
          end
          else if DictDictHas(fInstanceMethods, cd.Name, ps.ReadName) then
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
          // [진단] DefineMethod 인자 자리에 배열 리터럴을 바로 인라인으로 넣으면
          // newarr+stelem.ref가 잘못 감싸져서 self-host 빌드 시 이 메서드 자체의 IL이
          // 깨진다 (getter의 EmptyTypes 건과 동일 근본 원인). 지역변수로 우회.
          var setterParamTypes: array of System.Type;
          setterParamTypes:=[propClrType];
          var setM:=tb.DefineMethod('set_'+ps.Name,
            MethodAttributes.Public or MethodAttributes.SpecialName or
            MethodAttributes.HideBySig or MethodAttributes.Virtual,
            typeof(System.Void), setterParamTypes);
          var sIL:=setM.GetILGenerator;
          if DictDictHas(fFieldBuilders, cd.Name, ps.WriteName) then
          begin
            // WriteName이 같은 클래스에 선언된 필드 이름인 경우 (기존 동작)
            sIL.Emit(OpCodes.Ldarg_0);
            sIL.Emit(OpCodes.Ldarg_1);
            sIL.Emit(OpCodes.Stfld, fFieldBuilders[cd.Name][ps.WriteName]);
          end
          else if DictDictHas(fInstanceMethods, cd.Name, ps.WriteName) then
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
          fMethodParamClrTypes[cd.Name]['set_'+ps.Name]:=setterParamTypes;
        end;
      end;
    end;

    // 5) 생성자(오버로드 전부) 정의 + 사용자 생성자가 없으면 기본(부모 체이닝) 본문까지 방출
    procedure BuildClassShell_Constructors(tb: TypeBuilder; cd: TClassDeclNode; parentType: System.Type);
    var parentCtor: ConstructorInfo; i: integer;
    begin
      // 기본 생성자 추가 (부모 생성자 호출로 체이닝)
      // [Stage 47] 클래스 선언부에 "constructor Create(...)"로 매개변수가 선언돼 있으면
      // 그 시그니처 그대로 정의한다 (선언 없으면 빈 매개변수 목록 → 기존과 동일).
      // [Stage 99] 오버로드된 생성자를 전부 지원하기 위해, "클래스 하나당 시그니처 하나"라고
      // 가정했던 cd.ConstructorParams(모든 오버로드가 뒤섞인 리스트) 대신 fProg.ConstructorImpls
      // 에서 이 클래스(cd.Name) 소유의 항목들을 그대로 가져와 "그 개수만큼" ConstructorBuilder를
      // 만든다 — Parser.pas Stage 99 수정 이후 각 impl은 자기 자신의 Parameters만 정확히
      // 갖고 있으므로 이게 곧 실제 오버로드 목록이다(순서=소스에 나온 순서).
      Writeln('[MARK-BCS-7] 프로퍼티 루프 종료, 생성자 섹션 시작, cd.HasUserConstructor='+cd.HasUserConstructor.ToString);
      var thisClassCtorImpls:=new List<TConstructorImplNode>;
      if cd.HasUserConstructor then
        foreach var _ci99 in fProg.ConstructorImpls do
          if _ci99.ClassName=cd.Name then thisClassCtorImpls.Add(_ci99);

      Writeln('[MARK-BCS-7a] thisClassCtorImpls.Count='+thisClassCtorImpls.Count.ToString);
      var ctorBuilderList:=new List<ConstructorBuilder>;
      var ctorParamTypeList:=new List<array of System.Type>;

      if thisClassCtorImpls.Count>0 then
      begin
        foreach var _ci99b in thisClassCtorImpls do
        begin
          Writeln('[MARK-BCS-7b] 사용자 생성자 오버로드 처리, Parameters.Count='+_ci99b.Parameters.Count.ToString+' — 매개변수 CLR 타입 해석 직전');
          var _ctorParamTypes99:=new System.Type[_ci99b.Parameters.Count];
          for i:=0 to _ci99b.Parameters.Count-1 do
            _ctorParamTypes99[i]:=ResolveTopParamClrType(_ci99b.Parameters[i]);
          Writeln('[MARK-BCS-7c] 매개변수 CLR 타입 해석 완료 — DefineConstructor 호출 직전');
          var _ctorBuilder99:=tb.DefineConstructor(
            MethodAttributes.Public, CallingConventions.Standard, _ctorParamTypes99);
          Writeln('[MARK-BCS-7d] DefineConstructor 완료');
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

      Writeln('[MARK-BCS-8] 생성자 오버로드 루프 종료, ctorBuilderList.Count='+ctorBuilderList.Count.ToString);
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
          // [진단] System.Type.EmptyTypes 인라인 인자 우회 (동일 근본 원인, Console.ReadKey 건 참고)
          var parentCtorParamTypes: array of System.Type;
          parentCtorParamTypes:=System.Type.EmptyTypes;
          parentCtor:=parentType.GetConstructor(parentCtorParamTypes);
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
        Writeln('[MARK-BCS-9] 기본 생성자(부모 체이닝) IL 방출 완료');
      end;
    end;

    procedure BuildClassShell(modBuilder: ModuleBuilder; cd: TClassDeclNode);
    var tb: TypeBuilder; parentType: System.Type;
    begin
      Writeln('[MARK-BCS-0] BuildClassShell 진입, cd.Name="'+cd.Name+'"');
      tb:=BuildClassShell_DefineType(modBuilder, cd, parentType);
      BuildClassShell_Fields(tb, cd);
      BuildClassShell_Methods(tb, cd);
      BuildClassShell_Properties(tb, cd);
      BuildClassShell_Constructors(tb, cd, parentType);
      Writeln('[MARK-BCS-10] BuildClassShell 정상 반환, cd.Name="'+cd.Name+'"');
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
        // [버그 수정] BuildMethodBody의 인스턴스 메서드 매개변수 등록(위 2890행 부근)과 동일한
        // 이유 — 생성자 매개변수도 우리 컴파일러 자신의 로컬 클래스(아직 CreateType되지 않은
        // TypeBuilder)일 수 있으므로, 무조건 SetClrType하면 이후 그 매개변수를 통한 메서드
        // 호출이 완성되지 않은 TypeBuilder를 리플렉션으로 조회하다가 "형식이 만들어지지
        // 않았습니다"로 실패할 수 있다. FindLocalClassNameForTypeBuilder로 로컬 클래스인지
        // 먼저 확인한다.
        if pClrType<>typeof(integer) then
        begin
          var pLocalCls99c:=FindLocalClassNameForTypeBuilder(pClrType);
          if pLocalCls99c<>'' then fLocalScope.SetClassName(p, pLocalCls99c)
          else fLocalScope.SetClrType(p, pClrType);
        end;
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
          fLocalScope.SetClrType(lv.Name, lvClrType)
        // [버그 수정] array of <외부 타입>(vtObjArray) 지역변수 — ClrType을 채워야 GetExprClrType이
        // 원소 접근(lv[i].Member) 시 원소의 실제 CLR 타입을 찾을 수 있다. 이게 빠지면 HasClrType이
        // 항상 false로 남아 System.Object로 조용히 폴백한다(자기컴파일 실제 사례 — CodeGen.pas의
        // "ps: array of ParameterInfo;" 지역변수, foreach var cand in ps do cand.Name 등).
        else if (lv.VarType=vtObjArray) or (lv.VarType=vtGenericArray) then // [버그 수정] array of char/real/int64(vtGenericArray)도 ClrType 등록 누락돼 있었음
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
      // [임시 진단] "inherited Create;"(괄호 없는 무인자 호출)가 명시적으로 있는데도
      // hasExplicitInherited가 false로 나오는 사례(자기컴파일 중 TBoundGenericPropertyInfo에서
      // 실제 재현)의 원인을 확정하기 위해, 문제되는 클래스의 생성자 본문 첫 문장 타입을
      // 그대로 출력한다. 원인 확인 후 이 블록은 지워도 된다.
      if impl.ClassName='TBoundGenericPropertyInfo' then
      begin
        Writeln('  [진단] ' + impl.ClassName + ' 생성자 본문 문장 수: ' + impl.Body.Statements.Count.ToString);
        if impl.Body.Statements.Count>0 then
          Writeln('  [진단] 첫 문장 타입: ' + impl.Body.Statements[0].GetType.Name);
      end;
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
          // [버그 수정] GetConstructor(Type.EmptyTypes)만 쓰면 PUBLIC 생성자만 찾는다.
          // System.Reflection.PropertyInfo처럼 무인자 생성자가 protected인 외부 타입은
          // (자기컴파일 실제 사례 — TBoundGenericPropertyInfo : PropertyInfo) 이 호출이 nil을
          // 돌려줘 "public 생성자가 없다"는 오류로 이어졌다 — 소스에 "inherited Create();"를
          // 명시해도 파서의 감지 결과와 무관하게 항상 이 경로를 정확히 동작시키기 위해,
          // BindingFlags에 NonPublic도 포함해 protected/internal 생성자까지 찾는다.
          // IL의 OpCodes.Call은 C#과 달리 접근 제한자를 컴파일타임에 강제하지 않으므로
          // ConstructorInfo만 얻으면 protected 생성자도 문제없이 호출할 수 있다.
          begin
            // [진단] System.Type.EmptyTypes 인라인 인자 우회 (동일 근본 원인)
            var _P3EmptyTypesLocalA: array of System.Type;
            _P3EmptyTypesLocalA:=System.Type.EmptyTypes;
            autoParentCtor:=fClassExternalParentType[impl.ClassName].GetConstructor(
              BindingFlags.Instance or BindingFlags.Public or BindingFlags.NonPublic,
              nil, _P3EmptyTypesLocalA, nil);
          end
        else
          // [버그수정] cd.ParentName이 실은 인터페이스였던 경우(예: class(IDisposable))
          // BuildClassShell은 실제 CLR 부모를 System.Object로 두고 인터페이스는
          // AddInterfaceImplementation으로 별도 등록한다 — fClasses에는 여전히
          // "IDisposable"이라는 원래 이름이 남아있어서, 그 이름으로 생성자를 찾으려 하면
          // (인터페이스는 생성자가 없으므로) 항상 실패했다. ParentName이 없거나 인터페이스로
          // 판명된 경우엔 진짜 부모인 System.Object의 기본 생성자를 쓴다.
          begin
            var _P3EmptyTypesLocalB: array of System.Type;
            _P3EmptyTypesLocalB:=System.Type.EmptyTypes;
            autoParentCtor:=typeof(System.Object).GetConstructor(_P3EmptyTypesLocalB);
          end;
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
      if not DictDictHas(fInstanceMethods, impl.ClassName, impl.MethodName) then
        raise new Exception('메서드를 찾을 수 없음: '+impl.ClassName+'.'+impl.MethodName);

      // [Stage 53] abstract 메서드는 본문이 있으면 안 된다 — CLR도 이를 금지하지만
      // (Reflection.Emit에서 GetILGenerator 호출 시 알아보기 힘든 예외가 남) 여기서 먼저
      // 명확한 한국어 오류로 알려준다.
      // [버그 수정] PascalABC.NET의 and 완전 평가로 인해 impl.ClassName이 fAbstractMethods에
      // 없을 때도 인덱싱이 평가되어 KeyNotFoundException을 던지던 문제 — 단계적 if로 교체.
      if fAbstractMethods.ContainsKey(impl.ClassName) then
      begin
        if fAbstractMethods[impl.ClassName].Contains(impl.MethodName) then
          raise new Exception('"'+impl.ClassName+'.'+impl.MethodName+'"은(는) abstract로 선언되어 본문(구현)을 가질 수 없습니다');
      end;

      // [버그 수정] fInstanceMethods는 메서드명 하나에 MethodBuilder 하나만 저장하므로,
      // 같은 이름의 오버로드(예: GetCustomAttributes(bool) / GetCustomAttributes(Type,bool))가
      // 있으면 나중에 등록된 쪽이 앞의 것을 덮어써, 두 구현부(impl) 모두 같은 MethodBuilder를
      // 가리키게 되고 다른 하나는 본문이 채워지지 않은 채 남아 CreateType이 "메서드 본문이
      // 없습니다"로 실패했다(자기컴파일 실제 사례 — TBoundGenericPropertyInfo:PropertyInfo).
      // fInstanceMethodsByArity("메서드명#매개변수개수")로 먼저 정확히 찾고, 오버로드가 없어
      // 거기 없으면(절대다수의 경우) 기존 방식으로 그대로 폴백한다.
      var _mbArityKey99d:=impl.MethodName+'#'+impl.ParamNames.Count.ToString;
      if DictDictHas(fInstanceMethodsByArity, impl.ClassName, _mbArityKey99d) then
        mb:=fInstanceMethodsByArity[impl.ClassName][_mbArityKey99d]
      else
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
        if pElemType100<>typeof(integer) then
        begin
          // [버그 수정] "aScope: TScope" 처럼 매개변수가 우리 컴파일러 자신이 짓고 있는
          // 로컬 클래스(아직 CreateType되지 않은 TypeBuilder)이면, 무조건 SetClrType으로
          // 등록해서는 안 된다 — 지역변수 등록 루프(2919행 부근)는 이미 이 구분(fTypeBuilders/
          // fBuiltTypes면 SetClassName, 아니면 SetClrType)을 하고 있는데 매개변수 등록
          // 루프만 빠져 있었다. ClrType으로 등록되면 이후 "aScope.Declare(...)" 같은 호출이
          // EmitStatement의 "ClrType이 알려진 외부 타입 인스턴스" 경로로 잘못 빠져
          // ResolveMethodByArity가 완성되지 않은 TypeBuilder에서 MethodBuilder를 찾고,
          // 그 MethodBuilder.GetParameters()가 "형식이 만들어지지 않았습니다"
          // (NotSupportedException)로 실패했다(자기컴파일 중 실제 재현됨: EmitConstDecl의
          // aScope 매개변수). 로컬 클래스면 FindLocalClassNameForTypeBuilder로 클래스명을
          // 되찾아 SetClassName(메타데이터 기반 경로)으로 등록한다.
          var pLocalCls100:=FindLocalClassNameForTypeBuilder(pElemType100);
          if pLocalCls100<>'' then fLocalScope.SetClassName(p, pLocalCls100)
          else fLocalScope.SetClrType(p, pElemType100); // [Stage 100] pClrType→pElemType100
        end;
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
          fLocalScope.SetClrType(lv.Name, lvClrType)
        // [버그 수정] array of <외부 타입>(vtObjArray) 지역변수도 ClrType을 등록한다 (2819행 부근과 동일 이유).
        else if (lv.VarType=vtObjArray) or (lv.VarType=vtGenericArray) then // [버그 수정] array of char/real/int64(vtGenericArray)도 ClrType 등록 누락돼 있었음
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
      var _P3EmptyTypesLocalC1: array of System.Type;
      _P3EmptyTypesLocalC1:=System.Type.EmptyTypes;
      cil.Emit(OpCodes.Call, typeof(System.Object).GetConstructor(_P3EmptyTypesLocalC1));
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
      var _P3EmptyTypesLocalC2: array of System.Type;
      _P3EmptyTypesLocalC2:=System.Type.EmptyTypes;
      mnb:=clTB.DefineMethod('MoveNext', MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig,
        typeof(boolean), _P3EmptyTypesLocalC2);
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
          fLocalScope.SetClrType(pd69.Name, capFields[pd69.Name].FieldType)
        // [버그 수정] array of X(vtObjArray/vtGenericArray) 캡처 매개변수도 ClrType 등록 누락돼 있었음
        else if (pd69.ParamType=vtObjArray) or (pd69.ParamType=vtGenericArray) then
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
          fLocalScope.SetClrType(lv69c.Name, lvClrType69)
        else if (lv69c.VarType=vtObjArray) or (lv69c.VarType=vtGenericArray) then fLocalScope.SetClrType(lv69c.Name, lvClrType69); // [버그 수정] vtGenericArray 누락
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
      var _P3EmptyTypesLocalC3: array of System.Type;
      _P3EmptyTypesLocalC3:=System.Type.EmptyTypes;
      var getCurNG:=clTB.DefineMethod('<>get_Current_NG', MethodAttributes.Private or MethodAttributes.Virtual or
        MethodAttributes.Final or MethodAttributes.NewSlot or MethodAttributes.HideBySig or MethodAttributes.SpecialName,
        typeof(System.Object), _P3EmptyTypesLocalC3);
      var ngIl:=getCurNG.GetILGenerator;
      ngIl.Emit(OpCodes.Ldarg_0); ngIl.Emit(OpCodes.Ldfld, curFB);
      if elemClrType.IsValueType then ngIl.Emit(OpCodes.Box, elemClrType);
      ngIl.Emit(OpCodes.Ret);
      clTB.DefineMethodOverride(getCurNG, typeof(System.Collections.IEnumerator).GetProperty('Current').GetGetMethod);

      // ---- Current: IEnumerator<T>.Current — T 그대로 반환(박싱 없음) ----
      var ienumeratorOpenT2:=System.Type.GetType('System.Collections.Generic.IEnumerator`1');
      var ienumeratorT2:=ienumeratorOpenT2.MakeGenericType(elemClrType);
      var _P3EmptyTypesLocalC4: array of System.Type;
      _P3EmptyTypesLocalC4:=System.Type.EmptyTypes;
      var getCurG:=clTB.DefineMethod('<>get_Current_G', MethodAttributes.Private or MethodAttributes.Virtual or
        MethodAttributes.Final or MethodAttributes.NewSlot or MethodAttributes.HideBySig or MethodAttributes.SpecialName,
        elemClrType, _P3EmptyTypesLocalC4);
      var gIl:=getCurG.GetILGenerator;
      gIl.Emit(OpCodes.Ldarg_0); gIl.Emit(OpCodes.Ldfld, curFB); gIl.Emit(OpCodes.Ret);
      clTB.DefineMethodOverride(getCurG, ienumeratorT2.GetProperty('Current').GetGetMethod);

      // ---- GetEnumerator: IEnumerable(비제네릭) — 1차 제약: 재사용 없이 자기 자신을 그대로 돌려준다
      // (한 번만 순회 가능 — 같은 시퀀스를 두 번 foreach하면 이미 소진된 상태를 공유한다. 다시 순회하려면
      //  원래 함수를 다시 호출해 새 시퀀스를 만들 것. 2차에서 상태 복제/Reset으로 개선 예정).
      var _P3EmptyTypesLocalC5: array of System.Type;
      _P3EmptyTypesLocalC5:=System.Type.EmptyTypes;
      var getEnumNG:=clTB.DefineMethod('<>GetEnumerator_NG', MethodAttributes.Private or MethodAttributes.Virtual or
        MethodAttributes.Final or MethodAttributes.NewSlot or MethodAttributes.HideBySig,
        typeof(System.Collections.IEnumerator), _P3EmptyTypesLocalC5);
      var geNgIl:=getEnumNG.GetILGenerator;
      geNgIl.Emit(OpCodes.Ldarg_0); geNgIl.Emit(OpCodes.Ret);
      clTB.DefineMethodOverride(getEnumNG, typeof(System.Collections.IEnumerable).GetMethod('GetEnumerator'));

      // ---- GetEnumerator: IEnumerable<T> ----
      var ienumOpenT2:=System.Type.GetType('System.Collections.Generic.IEnumerable`1');
      var ienumT2:=ienumOpenT2.MakeGenericType(elemClrType);
      var _P3EmptyTypesLocalC6: array of System.Type;
      _P3EmptyTypesLocalC6:=System.Type.EmptyTypes;
      var getEnumG:=clTB.DefineMethod('<>GetEnumerator_G', MethodAttributes.Private or MethodAttributes.Virtual or
        MethodAttributes.Final or MethodAttributes.NewSlot or MethodAttributes.HideBySig,
        ienumeratorT2, _P3EmptyTypesLocalC6);
      var geGIl:=getEnumG.GetILGenerator;
      geGIl.Emit(OpCodes.Ldarg_0); geGIl.Emit(OpCodes.Ret);
      clTB.DefineMethodOverride(getEnumG, ienumT2.GetMethod('GetEnumerator'));

      // ---- Reset() — 순방향 전용 lazy 시퀀스라 지원하지 않는다(BCL의 흔한 관례와 동일) ----
      var _P3EmptyTypesLocalC7: array of System.Type;
      _P3EmptyTypesLocalC7:=System.Type.EmptyTypes;
      var resetMB:=clTB.DefineMethod('Reset', MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig,
        typeof(System.Void), _P3EmptyTypesLocalC7);
      var rIl:=resetMB.GetILGenerator;
      var _P3EmptyTypesLocalC8: array of System.Type;
      _P3EmptyTypesLocalC8:=System.Type.EmptyTypes;
      rIl.Emit(OpCodes.Newobj, typeof(System.NotSupportedException).GetConstructor(_P3EmptyTypesLocalC8));
      rIl.Emit(OpCodes.Throw);

      // ---- Dispose() — 정리할 외부 리소스가 없으므로 아무 것도 안 한다 ----
      var _P3EmptyTypesLocalC9: array of System.Type;
      _P3EmptyTypesLocalC9:=System.Type.EmptyTypes;
      var disposeMB:=clTB.DefineMethod('Dispose', MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig,
        typeof(System.Void), _P3EmptyTypesLocalC9);
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
      pParamIsByRef100: List<boolean>; pParamElemType100: List<System.Type>; // [버그 수정, Stage 100과 동일 패턴]
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
      // [버그 수정] BuildStaticProc과 동일한 이유 — 전역 function의 var/const 매개변수도
      // 지금까지 호출자에게 값을 되돌려주지 못했다. 동일한 복사-진입/복사-반환 전략 적용.
      pParamIsByRef100:=new List<boolean>; pParamElemType100:=new List<System.Type>;
      for i:=0 to d.Parameters.Count-1 do
      begin
        var pdef:=d.Parameters[i];
        var pIsByRef100:=pt[i].IsByRef;
        var pElemType100:=ElemTypeIfByRef(pt[i]);
        pParamIsByRef100.Add(pIsByRef100); pParamElemType100.Add(pElemType100);
        var loc:=il.DeclareLocal(pElemType100);
        fLocalScope.Declare(pdef.Name, loc, pdef.ParamType);
        // [Stage 31] 지역 변수(var 섹션)와 동일한 원칙: 우리 컴파일러가 만든 로컬 클래스면
        // 아직 CreateType() 전일 수 있으므로 fLocalClass(메타데이터 기반 조회)로,
        // 외부 .NET 타입이면 기존처럼 fLocalClrTypes(Reflection 기반 조회)로 보낸다.
        if (pdef.ParamType=vtObject) or (pdef.ParamType=vtInterface) then
        begin
          if fTypeBuilders.ContainsKey(pdef.ClassName) or fBuiltTypes.ContainsKey(pdef.ClassName) then
            fLocalScope.SetClassName(pdef.Name, pdef.ClassName)
          else
            fLocalScope.SetClrType(pdef.Name, pElemType100);
        end
        // [Stage 71] vtGeneric 매개변수(x: T)도 ClassName에 타입 매개변수 이름('T' 등)을
        // 기록해 둔다 — GetVarClassName으로 되찾아 fCurGenericSubst[genName]을 다시 조회할
        // 수 있어야(예: Writeln(x)가 실제 T의 CLR 타입을 알아내 box하는 데) 쓸모가 있다.
        else if pdef.ParamType=vtGeneric then
          fLocalScope.SetClassName(pdef.Name, pdef.ClassName)
        // [버그 수정] enum 타입 매개변수 — ClrType을 채워 HasClrType 리플렉션 경로로 라우팅한다.
        else if pdef.ParamType=vtEnum then
          fLocalScope.SetClrType(pdef.Name, pElemType100)
        // [버그 수정] array of X(vtObjArray/vtGenericArray) 매개변수도 ClrType 등록 누락돼 있었음 —
        // chars.Length 같은 지역변수 버전과 동일한 원인의 버그가 매개변수에도 있었다.
        else if (pdef.ParamType=vtObjArray) or (pdef.ParamType=vtGenericArray) then
          fLocalScope.SetClrType(pdef.Name, pElemType100);
        if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
        else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i));
        if pIsByRef100 then il.Emit(OpCodes.Ldobj, pElemType100); // [버그 수정] 주소 역참조 → 값
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
          fLocalScope.SetClrType(lv.Name, lvClrType)
        // [버그 수정] array of <외부 타입>(vtObjArray) 지역변수도 ClrType을 등록한다 (2819행 부근과 동일 이유).
        else if (lv.VarType=vtObjArray) or (lv.VarType=vtGenericArray) then // [버그 수정] array of char/real/int64(vtGenericArray)도 ClrType 등록 누락돼 있었음
          fLocalScope.SetClrType(lv.Name, lvClrType);
        // [Stage 67] vtMatrix 원소 타입 이름 보존
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 함수 본문의 지역 const 선언 처리
      foreach var cd61 in d.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.MarkLabel(fMethodExitLabel); // [Stage 78] exit 문의 착지점
      // [버그 수정] var/const 매개변수 복사-반환 — BuildStaticProc과 동일한 이유.
      // Result를 스택에 올리기(Ldloc fResultLocal) 전에 먼저 처리해야 스택이 꼬이지 않는다.
      for i:=0 to d.Parameters.Count-1 do
        if (i<pParamIsByRef100.Count) and pParamIsByRef100[i] then
        begin
          if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
          else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
          else il.Emit(OpCodes.Ldarg_S, byte(i));
          il.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(d.Parameters[i].Name));
          il.Emit(OpCodes.Stobj, pParamElemType100[i]);
        end;
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
      pParamIsByRef100: List<boolean>; pParamElemType100: List<System.Type>; // [Stage 100 버그수정]
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
      // [버그 수정] 전역 procedure의 var/const 매개변수(ByRef)가 지금까지 호출자에게
      // 값을 되돌려주지 못하던 버그 수정 — 인스턴스 메서드(BuildMethodBody, Stage 100)와
      // 동일한 "값 복사 진입(Ldobj) / 값 복사 반환(Stobj)" 전략을 그대로 적용한다.
      pParamIsByRef100:=new List<boolean>; pParamElemType100:=new List<System.Type>;
      for i:=0 to d.Parameters.Count-1 do
      begin
        var pdef:=d.Parameters[i];
        var pIsByRef100:=pt[i].IsByRef;
        var pElemType100:=ElemTypeIfByRef(pt[i]);
        pParamIsByRef100.Add(pIsByRef100); pParamElemType100.Add(pElemType100);
        var loc:=il.DeclareLocal(pElemType100);
        fLocalScope.Declare(pdef.Name, loc, pdef.ParamType);
        if (pdef.ParamType=vtObject) or (pdef.ParamType=vtInterface) then
        begin
          if fTypeBuilders.ContainsKey(pdef.ClassName) or fBuiltTypes.ContainsKey(pdef.ClassName) then
            fLocalScope.SetClassName(pdef.Name, pdef.ClassName)
          else
            fLocalScope.SetClrType(pdef.Name, pElemType100);
        end
        // [Stage 71] BuildStaticFunc와 동일한 이유 — vtGeneric 매개변수도 타입 매개변수 이름을 기록.
        else if pdef.ParamType=vtGeneric then
          fLocalScope.SetClassName(pdef.Name, pdef.ClassName)
        // [버그 수정] enum 타입 매개변수 — ClrType을 채워 HasClrType 리플렉션 경로로 라우팅한다.
        else if pdef.ParamType=vtEnum then
          fLocalScope.SetClrType(pdef.Name, pElemType100)
        // [버그 수정] array of X(vtObjArray/vtGenericArray) 매개변수도 ClrType 등록 누락돼 있었음 —
        // chars.Length 같은 지역변수 버전과 동일한 원인의 버그가 매개변수에도 있었다.
        else if (pdef.ParamType=vtObjArray) or (pdef.ParamType=vtGenericArray) then
          fLocalScope.SetClrType(pdef.Name, pElemType100);
        if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
        else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i));
        if pIsByRef100 then il.Emit(OpCodes.Ldobj, pElemType100); // [버그 수정] 주소 역참조 → 값
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
          fLocalScope.SetClrType(lv.Name, lvClrType)
        // [버그 수정] array of <외부 타입>(vtObjArray) 지역변수도 ClrType을 등록한다 (2819행 부근과 동일 이유).
        else if (lv.VarType=vtObjArray) or (lv.VarType=vtGenericArray) then // [버그 수정] array of char/real/int64(vtGenericArray)도 ClrType 등록 누락돼 있었음
          fLocalScope.SetClrType(lv.Name, lvClrType);
        // [Stage 67] vtMatrix 원소 타입 이름 보존
        if (lv.VarType=vtMatrix) and (lv.ClassName<>'') then
          fLocalScope.SetClassName(lv.Name, lv.ClassName);
      end;

      // [Stage 61] 프로시저 본문의 지역 const 선언 처리
      foreach var cd61 in d.ConstDecls do EmitConstDecl(il, fLocalScope, cd61);
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.MarkLabel(fMethodExitLabel); // [Stage 78] exit 문의 착지점
      // [버그 수정] var/const 매개변수 복사-반환: 로컬 슬롯의 최종 값을 원래 주소에 다시 써준다
      // (BuildMethodBody의 Stage 100과 동일한 전략 — exit 문으로 일찍 빠져나온 경우도
      // fMethodExitLabel 착지점을 거치므로 여기 한 곳에서 처리하면 모든 경로를 커버한다).
      for i:=0 to d.Parameters.Count-1 do
        if (i<pParamIsByRef100.Count) and pParamIsByRef100[i] then
        begin
          if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
          else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
          else il.Emit(OpCodes.Ldarg_S, byte(i));
          il.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(d.Parameters[i].Name));
          il.Emit(OpCodes.Stobj, pParamElemType100[i]);
        end;
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
      fInstanceMethodsByArity:=new Dictionary<string, Dictionary<string, MethodBuilder>>; // [버그 수정] 오버로드 구분용
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
        // [Stage 103 버그 수정] Stage 102에서 "System.Attribute.GetCustomAttribute(selfAsm,
        // typeof(...))" 형태(정적 타입에 점이 2개, 인자 2개)로 바꿔봤지만 여전히 같은
        // "System.Reflection.Assembly에 메서드 GetCustomAttribute가 없습니다 (인자 1개)"
        // 오류가 재현되었다 — 셀프호스팅 파서가 다중 점(.) 정적 타입 경로 + 다중 인자
        // 정적 호출 조합 자체를 여전히 불안정하게 처리하는 것으로 보인다. 아예 그 조합을
        // 타지 않도록, 이미 이 컴파일러 소스 다른 곳(CodeGen.pas의 GetCustomAttributes
        // override)에서도 검증된 "인스턴스.GetCustomAttributes(typeof(X), bool)" — 단수가
        // 아니라 복수형 — 인스턴스 메서드 체인으로 완전히 바꾼다. selfAsm은 평범한 지역
        // 변수이고 체인은 "selfAsm.GetCustomAttributes(...)" 한 단계뿐이라, 다중 점 정적
        // 경로도 다중 인자 정적 호출도 전혀 발생하지 않는다.
        var selfAsm:=System.Reflection.Assembly.GetExecutingAssembly();
        var selfAttrs:=selfAsm.GetCustomAttributes(typeof(System.Runtime.Versioning.TargetFrameworkAttribute), false);
        // [Stage 103] 캐스트와 .FrameworkName 읽기를 한 식으로 합쳐 "TypeName(expr).member"
        // 캐스트-읽기 패턴(Parser.pas의 System.Windows.Forms.Button(sender).Text 예시와 동일
        // 모양)으로 만든다 — 별도 지역변수(selfTfa)에 "as" 캐스트로 담지 않으므로 그 변수의
        // 타입 추론에 기대지 않는다.
        if selfAttrs.Length>0 then
          tfaVersionString:=System.Runtime.Versioning.TargetFrameworkAttribute(selfAttrs[0]).FrameworkName;
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
        var _P3EmptyTypesLocalC10: array of System.Type;
        _P3EmptyTypesLocalC10:=System.Type.EmptyTypes;
        var cctorMB: MethodBuilder := mainTB.DefineMethod('.cctor',
          MethodAttributes.Private or MethodAttributes.Static or
          MethodAttributes.HideBySig or MethodAttributes.SpecialName or MethodAttributes.RTSpecialName,
          // [Stage 111 버그 수정] .NET Framework에서는 nil(=null)을 "매개변수 없음"으로 관대하게
          // 받아줬지만, 이 프로젝트가 돌아가는 .NET(Core/5+)의 TypeBuilder.DefineMethod는 null을
          // 그대로 거부하고 ArgumentNullException(parameterTypes)을 던진다 — 빈 배열을 명시해야 한다.
          typeof(System.Void), _P3EmptyTypesLocalC10);
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
        // [진단] self-host gen1에서 GenerateExe 안 ArrayTypeMismatchException 위치를
        // 좁히기 위한 패치. "System.Type.EmptyTypes"를 함수 호출 인자 자리에 바로
        // 인라인으로 넣던 것을, 지역변수로 분리하고 각 단계를 개별 try/except +
        // LogGenStep으로 감싸서 정확히 어느 줄에서 터지는지 다음 self-compile
        // 로그에서 바로 드러나게 한다. (기존 STAThread try/except와 동일한 패턴)
        var mainParamTypes: array of System.Type;
        try
          mainParamTypes:=System.Type.EmptyTypes;
          LogGenStep('6단계 진행 — mainParamTypes:=System.Type.EmptyTypes 완료, Length='
            +mainParamTypes.Length.ToString);
        except
          on E6p: Exception do
          begin
            LogGenStep('실패 — mainParamTypes(System.Type.EmptyTypes) 초기화 중: '
              +E6p.GetType.FullName+': '+E6p.Message);
            raise;
          end;
        end;
        
        try
          mm:=mainTB.DefineMethod('Main',
            MethodAttributes.Public or MethodAttributes.Static,
            // [Stage 111 버그 수정] 위 .cctor와 동일한 이유 — nil 대신 빈 배열을 명시한다.
            typeof(System.Void), mainParamTypes);
          LogGenStep('6단계 진행 — mainTB.DefineMethod(Main) 완료');
        except
          on E6d: Exception do
          begin
            LogGenStep('실패 — mainTB.DefineMethod(Main) 중: '
              +E6d.GetType.FullName+': '+E6d.Message);
            raise;
          end;
        end;
        
        // WinForm/WPF의 Application.Run 등 STA(단일 스레드 아파트먼트)가 필요한 호출을
        // 위해 항상 [STAThread]를 붙여둔다 (콘솔/일반 프로그램에는 영향 없음).
        // [진단] STAThread 커스텀 속성 부여 — ArrayTypeMismatchException 등 진단을 위해
        // 개별 try/except로 감싸서 정확히 이 지점에서 터지는지 확인한다. 여기서도
        // System.Type.EmptyTypes와 빈 args 배열([])을 지역변수로 분리해 동일하게 진단한다.
        var staCtorParamTypes: array of System.Type;
        var staCtorArgs: array of System.Object;
        try
          staCtorParamTypes:=System.Type.EmptyTypes;
          staCtorArgs:=new System.Object[0];
          LogGenStep('6단계 진행 — STA 생성자 파라미터/인자 배열 준비 완료');
          mm.SetCustomAttribute(new CustomAttributeBuilder(
            typeof(System.STAThreadAttribute).GetConstructor(staCtorParamTypes), staCtorArgs));
        except
          on E6a: Exception do
          begin
            LogGenStep('실패 — STAThread 커스텀 속성 부여 중: '+E6a.GetType.FullName+': '+E6a.Message);
            raise;
          end;
        end;
        LogGenStep('6단계 진행 — STAThread 속성 부여 완료');

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
        LogGenStep('6단계 진행 — 전역 var 루프 완료 ('+fProg.VarDecls.Count.ToString+'개)');

        // [Stage 96] 전역 const는 cctor(Program 타입의 정적 생성자)에서 static 필드로
        // 초기화된다 — Main보다 먼저 실행되고 모든 함수에서 Ldsfld로 읽을 수 있다.
        // 예전의 EmitConstDecl(Main 전용 로컬 슬롯) 루프는 제거한다.

        // [진단] 최상위 begin...end 문장을 하나씩 이미트하며, 몇 번째 문장에서
        // 어떤 예외 타입이 나는지 정확히 찍는다 (ArrayTypeMismatchException 등).
        for var stIdx6:=0 to fProg.Statements.Count-1 do
        begin
          try
            EmitStatement(il, fProg.Statements[stIdx6]);
          except
            on E6b: Exception do
            begin
              LogGenStep('실패 — 최상위 문장 #'+stIdx6.ToString+' ('
                +fProg.Statements[stIdx6].GetType.Name+') 이미트 중: '
                +E6b.GetType.FullName+': '+E6b.Message);
              raise;
            end;
          end;
        end;
        LogGenStep('6단계 진행 — 최상위 문장 이미트 완료 ('+fProg.Statements.Count.ToString+'개)');

        // [Stage 69] windows 앱(예: WinForms)은 콘솔이 아예 없거나(콘솔창 자체를 안 만드는 경우)
        // Application.Run이 이미 사용자 입력을 다 처리했으므로, 여기서 ReadKey로 다시
        // 키 입력을 기다리면 창이 닫힌 뒤에도 프로세스가 멈춰있는 것처럼 보인다.
        if fProg.AppType<>'windows' then
        begin
          try
            // [진단] 위 mainParamTypes/staCtorParamTypes와 동일한 이유 — "System.Type.EmptyTypes"를
            // GetMethod 호출 인자 자리에 바로 인라인으로 넣으면 gen1에서 ArrayTypeMismatchException이
            // 난다. 지역변수로 분리해서 우회한다.
            var readKeyParamTypes: array of System.Type;
            readKeyParamTypes:=System.Type.EmptyTypes;
            rk:=typeof(Console).GetMethod('ReadKey', readKeyParamTypes);
            if rk=nil then
              LogGenStep('6-2단계 — Console.ReadKey MethodInfo 획득 완료 (경고: nil!)')
            else
              LogGenStep('6-2단계 — Console.ReadKey MethodInfo 획득 완료');
          except
            on E6c: Exception do
            begin
              LogGenStep('실패 — Console.ReadKey GetMethod 조회 중: '+E6c.GetType.FullName+': '+E6c.Message);
              raise;
            end;
          end;
          try
            il.Emit(OpCodes.Call, rk);
            LogGenStep('6-3단계 — ReadKey Call 방출 완료');
          except
            on E6d: Exception do
            begin
              LogGenStep('실패 — ReadKey Call 방출 중: '+E6d.GetType.FullName+': '+E6d.Message);
              raise;
            end;
          end;
          try
            il.Emit(OpCodes.Pop);
            LogGenStep('6-4단계 — ReadKey 결과 Pop 방출 완료');
          except
            on E6e: Exception do
            begin
              LogGenStep('실패 — ReadKey 결과 Pop 방출 중: '+E6e.GetType.FullName+': '+E6e.Message);
              raise;
            end;
          end;
        end;
        try
          il.Emit(OpCodes.Ret);
          LogGenStep('6-5단계 — Main Ret 방출 완료');
        except
          on E6f: Exception do
          begin
            LogGenStep('실패 — Main Ret 방출 중: '+E6f.GetType.FullName+': '+E6f.Message);
            raise;
          end;
        end;
        LogGenStep('6단계 완료 — Main 메서드 IL 생성 완료');
      end;

      try
        mainTB.CreateType;
      except
        on E7: Exception do
        begin
          LogGenStep('실패 — Program(mainTB) CreateType 중: '+E7.GetType.FullName+': '+E7.Message);
          raise;
        end;
      end;
      LogGenStep('7단계 — Program(mainTB) CreateType 완료');

      if not fProg.IsLibrary then
      begin
        // [Stage 69] {$apptype windows}면 WindowApplication으로 저장 — PE 서브시스템이
        // GUI로 표시되어 탐색기에서 실행해도 콘솔(도스) 창이 뜨지 않는다.
        // 지시문이 없으면(기본값 'console') 기존과 동일하게 콘솔 앱으로 생성한다.
        try
          if fProg.AppType='windows' then
            ab.SetEntryPoint(mm, PEFileKinds.WindowApplication)
          else
            ab.SetEntryPoint(mm, PEFileKinds.ConsoleApplication);
        except
          on E8: Exception do
          begin
            LogGenStep('실패 — SetEntryPoint 중: '+E8.GetType.FullName+': '+E8.Message);
            raise;
          end;
        end;
      end;
      LogGenStep('8단계 — SetEntryPoint 완료');

      try
        ab.Save(outName);
      except
        on E9: Exception do
        begin
          LogGenStep('실패 — ab.Save("'+outName+'") 중: '+E9.GetType.FullName+': '+E9.Message);
          raise;
        end;
      end;
      LogGenStep('9단계 — ab.Save 완료: '+outName);
    end;