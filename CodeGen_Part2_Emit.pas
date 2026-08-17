// ============================================================
// CodeGen_Part2_Emit.pas
// [분할 2/2] CodeGen.pas(원래 9000줄+)를 3조각으로 나눈 것 중 하나입니다.
// EmitExpr(식 IL 방출) + EmitStatement(문장 IL 방출) 등 IL 방출의 핵심 — 어제 잡은 try/except 중첩 버그가 이 파일에 있습니다
// CodeGen.pas가 `{$include CodeGen_Part2_Emit.pas}`로 이 파일을 그 자리에 그대로 끌어와 붙이므로
// (텍스트 삽입 — 이 컴파일러가 partial class를 지원하지 않아서 쓰는 방식입니다),
// 컴파일 결과(IL)는 분할 전과 100% 동일합니다.
// 반드시 CodeGen.pas와 같은 폴더에 두어야 합니다. 이 파일만 단독으로 컴파일할 수
// 없습니다(TCodeGenerator의 필드/다른 부분에 의존).
// ============================================================

    // [Stage 108 버그 수정] 1차원 배열 원소 CLR 타입을 안전하게 얻는다. Stage 107에서
    // 배열 인덱싱 읽기/쓰기에 LocalType.GetElementType/FieldType.GetElementType을 무조건
    // 호출했는데, 아직 CreateType되지 않은 제네릭 인스턴스(예: 자기 자신의 미해결 제네릭
    // 메서드 타입 매개변수를 포함한 Dictionary<string, Dictionary<string, TV>> 같은
    // TypeBuilderInstantiation)는 배열이 전혀 아닌데도 GetElementType 호출 자체가
    // System.NotSupportedException을 던진다(자기컴파일 실제 재현: TParser.DictDictHas<TV>의
    // 매개변수 d — Parser.pas의 `d[k1]`이 배열 인덱싱 경로를 타면서 발생). 위쪽
    // IsRefElementType(Stage 96)이 이미 같은 이유로 GetElementType 호출을 try/except로
    // 감쌌던 것과 동일한 패턴 — 여기서도 IsArray를 먼저 확인하고, 그 확인 자체나
    // GetElementType 호출이 예외를 던지면 조용히 nil(=원소 타입 모름, 기존 Ldelem_I4/
    // Stelem_I4 기본값 경로로 폴백)을 돌려준다.
    function SafeArrayElemType(t: System.Type): System.Type;
    begin
      Result:=nil;
      if t=nil then exit;
      try
        if t.IsArray then Result:=t.GetElementType;
      except
        Result:=nil;
      end;
    end;

    // [Stage 142 버그 수정 — 자기컴파일 IL 손상] Stage 141에서 EmitExpr의 바깥쪽
    // try/finally(재귀깊이 카운터)를 EmitExprDispatch 밖으로 뺐는데도 Stage 110 self 로그가
    // 여전히 EmitExprDispatch 진입 직후 BadImageFormatException으로 죽었다. 원인은
    // EmitExprDispatch "자기 자신의 몸통 안"에 인라인 try/except가 4곳(mc.ObjName 정적 타입
    // 조회 3곳 + ResolveOrEmitStaticChain 1곳)과 인라인 foreach가 1곳(ExtraIndices 순회) 그대로
    // 남아있었던 것 — 이 프로젝트에서 반복 확인된 "큰 함수 + try/except/foreach 동거" 패턴이
    // try/finally를 빼낸 뒤에도 그대로 재현된 것이다. SafeArrayElemType과 동일한 방식으로
    // try/except를 별도의 작은 Safe* 함수로 뽑아 EmitExprDispatch 몸통에서 완전히 제거한다.
    function SafeResolveExternalType(typeName: string): System.Type;
    begin
      Result:=nil;
      try
        Result:=ResolveExternalType(typeName);
      except
        Result:=nil;
      end;
    end;

    function SafeResolveOrEmitStaticChain(aIL: ILGenerator; objName: string; var isInst: boolean): System.Type;
    begin
      Result:=nil;
      isInst:=false;
      try
        Result:=ResolveOrEmitStaticChain(aIL, objName, isInst);
      except
        Result:=nil;
      end;
    end;

    // [Stage 142] EmitExprDispatch 몸통 안의 인라인 foreach(obj[i][j][k]... 추가 인덱스 체인)도
    // 같은 이유로 별도 함수로 뽑는다.
    function EmitExtraIndicesChain(aIL: ILGenerator; extraIndices: List<TExprNode>; startType: System.Type): System.Type;
    var t: System.Type;
    begin
      t:=startType;
      foreach var eiExtra96 in extraIndices do
        t:=EmitIndexerGet(aIL, t, eiExtra96);
      Result:=t;
    end;

    // [Stage 141 분할 — 자기컴파일 IL 손상 수정] EmitExpr 자체가 ~1600줄짜리 단일 함수였고,
    // 그 전체가 fEmitDepth 재귀깊이 카운터를 위한 try/finally 하나로 통째로 감싸여 있었다
    // (EmitStatement가 Stage 112에서 겪었던 것과 완전히 같은 모양 — "거대한 함수 + 그 전체를
    // 감싸는 try/finally"). 이 프로젝트에서 반복 확인된 자기컴파일 IL 손상 패턴의 정석적인
    // 사례라, gen1(자기컴파일 결과물)이 이 함수에 처음 진입하는 순간(EmitQualifierChainLoad
    // 호출 이전, 즉 이 함수 자신의 dispatch 코드 안에서) BadImageFormatException으로
    // 죽는 것으로 확인됐다 — Stage 110 self 로그에서 InferTypeMethodCallAChain 계열은
    // 전부 정상 통과하고, EmitExpr 진입 이후 아무 마크도 없이 바로 크래시가 난다.
    // EmitStatement 때와 동일한 해법 — try/finally를 몸통 전체가 아니라 얇은 래퍼
    // EmitExpr에만 남기고, 실제 분기 로직(원본과 100% 동일)은 EmitExprDispatch로
    // 옮겨 try/finally 밖에 둔다. (EmitExprDispatch 자체는 여전히 크므로, 이후 단계에서
    // EmitStatementMethodCall처럼 재귀 호출이 없는 분기들을 추가로 뽑아내는 후속 분할이
    // 필요할 수 있다 — 우선 try/finally 중첩부터 제거해 검증한다.)
    // [Stage 143 분할 — 자기컴파일 IL 손상 추가 수정] Stage 142에서 EmitExprDispatch 몸통의
    // try/except·foreach를 전부 제거했는데도 Stage 110 self 로그가 정확히 같은 지점(이 함수
    // 진입 직후, EmitQualifierChainLoad 호출 이전)에서 여전히 BadImageFormatException으로
    // 죽었다 — try/except·foreach 동거뿐 아니라 "메서드 자체의 크기"도 gen1 JIT 시점 IL 손상의
    // 원인이 될 수 있다는 뜻으로 판단. EmitExprDispatch 안에서 압도적으로 큰 단일 분기인
    // TMethodCallExprNode 처리부(~700줄)를, EmitStatement에서 EmitStatementMethodCall을 뽑아냈던
    // 것과 똑같은 방식으로 별도 함수로 분리한다. 내용은 원본과 100% 동일 — 위치만 옮겼다.
    // ============================================================
    // [Stage 144 분할 - 자기컴파일 IL 손상 추가 수정] Stage 143에서 EmitExprDispatch의
    // TMethodCallExprNode 처리부(~700줄)를 EmitExprMethodCallBranch로 뽑아냈지만, Stage 110
    // self 로그가 여전히 정확히 이 함수의 프레임(BadImageFormatException, 스택 맨 위가
    // EmitExprMethodCallBranch)에서 죽었다 - 이 프로젝트에서 반복 확인된 "큰 함수 자체가
    // gen1 JIT 시점에 IL을 깨뜨린다" 패턴(EmitStatement/EmitExprDispatch와 동일)이 여기서도
    // 재현된 것. EmitExprMethodCallBranch 몸통의 최상위 if/else if 7갈래(원본과 100% 동일한
    // 조건/순서)를 각각 별도의 작은 함수로 뽑아내고, EmitExprMethodCallBranch 자신은 그
    // 조건을 그대로 재평가해 알맞은 함수를 호출하는 얇은 디스패처만 남긴다.
    // (참고: EmitStatementDataOps1/EmitStatementMethodCall/EmitStatementDataOps2는 각각
    // 500줄 안팎인데도 gen1에서 정상 동작하는 것으로 확인되어, 아래 각 조각은 그보다도
    // 훨씬 작게 유지했다.)
    // ============================================================

    // 갈래 1: mc.ObjName이 점(.)으로 연결된 체인 (예: "MainMenu.Items.Count.ToString").
    procedure EmitMCB_QualifiedChain(aIL: ILGenerator; mc: TMethodCallExprNode);
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
              // [버그 수정] _chainTypeE가 아직 CreateType되지 않은 "로컬" 클래스의 TypeBuilder일
              // 수 있다 — 예: "_sse.Lambda.ParamName" (Lambda: TExprLambdaNode, 이 컴파일러가
              // 만드는 로컬 클래스). EmitQualifierChainLoad는 체인의 중간 세그먼트("_sse"→"Lambda")를
              // 지나며 로컬 클래스 여부를 이미 확인하지만(localClsName78 역조회 → fFieldBuilders/
              // fInstanceMethods), 체인의 "마지막" 세그먼트(mc.MethodName, 여기서는 "ParamName")는
              // 이 분기까지 오면 무조건 SafeGetProperty/ResolveMethodByArity(순수 리플렉션 전용)로
              // 넘어갔다 — TypeBuilder는 아직 완성되지 않아 리플렉션 조회가 안 되므로(또는 필드를
              // 아예 못 찾으므로) "타입에 메서드가 없습니다"로 잘못 실패했다. EmitQualifierChainLoad
              // 내부와 동일한 방식으로 먼저 로컬 클래스 멤버인지 확인한다.
              // [110번째 자기컴파일 버그 수정] 인라인 foreach 대신 FindLocalClassNameForTypeBuilder 재사용.
              var _localClsE:='';
              if _chainTypeE is TypeBuilder then
                _localClsE:=FindLocalClassNameForTypeBuilder(_chainTypeE);

              if (_localClsE<>'') and fInstanceMethods.ContainsKey(_localClsE)
                 and fInstanceMethods[_localClsE].ContainsKey('get_'+mc.MethodName) and (mc.Args.Count=0) then
              begin
                aIL.Emit(OpCodes.Callvirt, fInstanceMethods[_localClsE]['get_'+mc.MethodName]);
              end
              else if (_localClsE<>'') and fFieldBuilders.ContainsKey(_localClsE)
                 and fFieldBuilders[_localClsE].ContainsKey(mc.MethodName) and (mc.Args.Count=0) then
              begin
                aIL.Emit(OpCodes.Ldfld, fFieldBuilders[_localClsE][mc.MethodName]);
              end
              else if (_localClsE<>'') and fInstanceMethods.ContainsKey(_localClsE)
                 and fInstanceMethods[_localClsE].ContainsKey(mc.MethodName) then
              begin
                var _localME:=fInstanceMethods[_localClsE][mc.MethodName];
                var _localMEParams:=_localME.GetParameters;
                for var _lmeAi:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_lmeAi], _localMEParams[_lmeAi].ParameterType);
                aIL.Emit(OpCodes.Callvirt, _localME);
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
            var _staticTE: System.Type := SafeResolveExternalType(mc.ObjName);

            if (_staticTE=nil) and (mc.Args.Count=1) then
            begin
              var _castTE92: System.Type := SafeResolveExternalType(mc.ObjName+'.'+mc.MethodName);
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
              _staticTE:=SafeResolveOrEmitStaticChain(aIL, mc.ObjName, _isInstTE);

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
                raise new Exception('타입 "'+_staticTE.FullName+'"에 인스턴스 멤버 "'+mc.MethodName+'"가 없습니다 (경로: '+mc.ObjName+'.'+mc.MethodName+').');
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
                  raise new Exception('외부 타입 "'+_staticTE.FullName+'"에 정적 멤버 "'+mc.MethodName+'"가 없습니다 (경로: '+mc.ObjName+'.'+mc.MethodName+').');
                var _smiEParams:=_smiE.GetParameters;
                for var _smiEAi:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_smiEAi], _smiEParams[_smiEAi].ParameterType);
                aIL.Emit(OpCodes.Call, _smiE);
              end;
            end;
          end;
    end;

    // 갈래 2: mc.ObjName=='' - 암시적 self 호출 (예: 식 위치의 "IsKeywordAllowedAsMemberName(t.Kind)").
    procedure EmitMCB_ImplicitSelfCall(aIL: ILGenerator; mc: TMethodCallExprNode);
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
              raise new Exception('외부 타입 "'+_extTypeEC93.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
            var _emiEC93Params:=_emiEC93.GetParameters;
            for var _emiEC93Ai:=0 to mc.Args.Count-1 do
              EmitArgForParamType(aIL, mc.Args[_emiEC93Ai], _emiEC93Params[_emiEC93Ai].ParameterType);
            aIL.Emit(OpCodes.Callvirt, _emiEC93);
          end;
    end;

    // 갈래 3: mc.ObjName이 CLR 타입이 붙은 지역/전역 변수(sender/e 같은 외부 타입 매개변수 등).
    procedure EmitMCB_ClrTypedVar(aIL: ILGenerator; mc: TMethodCallExprNode);
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
              raise new Exception('타입 "'+_qType2.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
            var _emi6Params:=_emi6.GetParameters;
            for var _emi6Ai:=0 to mc.Args.Count-1 do
              EmitArgForParamType(aIL, mc.Args[_emi6Ai], _emi6Params[_emi6Ai].ParameterType);
            if _isValType2 then aIL.Emit(OpCodes.Call, _emi6)
            else aIL.Emit(OpCodes.Callvirt, _emi6);
          end;
          end;
    end;

    // 갈래 4: mc.ObjName이 (CLR 타입 아닌) 지역/전역 변수 또는 전역 const.
    procedure EmitMCB_LocalVarOrConst(aIL: ILGenerator; mc: TMethodCallExprNode);
    var cn: string; vtVar: TVarType; imb: MethodBuilder; fb: FieldBuilder;
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
                  raise new Exception('타입 "System.String"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
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
            else if (fLocalScope.Has(mc.ObjName) and fLocalScope.HasClrType(mc.ObjName))
                    or (fGlobalScope.Has(mc.ObjName) and fGlobalScope.HasClrType(mc.ObjName)) then
            begin
              // [자기컴파일 버그 수정] cn=''이지만 vtVar가 string/배열/원시 스칼라 중 어느 것도
              // 아닌 경우 — 즉 TInlineVarStmtNode가 "var x:=SomeHelperCall(...)" 같은 식에서
              // ivIsExternal=true로 판단해 ClassName 없이 SetClrType만으로 등록해 둔 vtObject
              // 변수(예: "var _mi4:=ResolveMethodByArity(...)"가 담은 MethodInfo/MethodBuilder,
              // 또는 FindInstanceMethod/SafeGetProperty 등 다른 헬퍼가 돌려주는 리플렉션 객체).
              // 이런 변수는 사용자 정의 클래스도 아니고 위의 string/배열/원시타입 특수 케이스에도
              // 안 걸려 곧장 "알 수 없는 메서드"로 오인됐다 — 실제로는 SetClrType으로 기록해 둔
              // 실제 CLR 타입이 있으므로, FindExternalAncestorType 폴백(아래쪽 cn<>'' 분기)과
              // 동일하게 SafeGetProperty/ResolveMethodByArity로 일반적인 리플렉션 조회를 하면 된다.
              var _genClr100: System.Type;
              if fLocalScope.Has(mc.ObjName) and fLocalScope.HasClrType(mc.ObjName) then
                _genClr100:=fLocalScope.GetClrType(mc.ObjName)
              else
                _genClr100:=fGlobalScope.GetClrType(mc.ObjName);
              var _genPi100:=SafeGetProperty(_genClr100, mc.MethodName);
              if (mc.Args.Count=0) and (_genPi100<>nil) and (_genPi100.GetGetMethod<>nil) then
                aIL.Emit(OpCodes.Callvirt, _genPi100.GetGetMethod)
              else
              begin
                var _genMi100:=ResolveMethodByArity(_genClr100, mc.MethodName, mc.Args, false);
                if _genMi100=nil then
                  raise new Exception('타입 "'+_genClr100.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
                var _genMiParams100:=_genMi100.GetParameters;
                for var _genAi100:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_genAi100], _genMiParams100[_genAi100].ParameterType);
                aIL.Emit(OpCodes.Callvirt, _genMi100);
              end;
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
            if DictDictHas(fInstanceMethods, cn, 'get_'+mc.MethodName) then
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
                  raise new Exception('속성 "'+_extAnc.FullName+'.'+mc.MethodName+'"에 getter가 없습니다 (쓰기 전용, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
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
                  var _P2EmptyTypesLocal2: array of System.Type;
                  _P2EmptyTypesLocal2:=System.Type.EmptyTypes;
                  var _extMi77:=_extAnc.GetMethod(mc.MethodName, _P2EmptyTypesLocal2);
                  if _extMi77=nil then
                    raise new Exception('외부 타입 "'+_extAnc.FullName+'"에 필드/속성/메서드 "'+mc.MethodName+'"가 없습니다 (경로: '+mc.ObjName+'.'+mc.MethodName+').');
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
    end;

    // 갈래 5: mc.ObjName이 현재 클래스의 필드(fb는 호출부에서 TryFindFieldBuilder로 이미 찾아
    // 넘겨준다 - 조건 판정과 실제 사용이 원본에서도 같은 fb였던 것과 동일).
    procedure EmitMCB_FieldAccess(aIL: ILGenerator; mc: TMethodCallExprNode; fb: FieldBuilder);
    begin
          // Button1.Text (필드를 통한 속성 읽기) 또는 Button1.SomeMethod() (필드를 통한 메서드 호출)
          aIL.Emit(OpCodes.Ldarg_0);
          aIL.Emit(OpCodes.Ldfld, fb);        // ← fLine 필드의 "원시 int32 값"을 스택에 직접 로드
          var _qType:=fb.FieldType;           // = typeof(integer)
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
          // [110번째 자기컴파일 버그 수정] 인라인 foreach(암묵적 try/finally) 대신
          // FindLocalClassNameForTypeBuilder 재사용 — 큰 함수 안 인라인 foreach가
          // gen1 JIT 시점에 IL을 깨뜨리는 문제(Stage 111/112/113 계열) 예방.
          var _localClsExpr98:string:='';
          if _qType is TypeBuilder then
            _localClsExpr98:=FindLocalClassNameForTypeBuilder(_qType);

          if _localClsExpr98<>'' then
          begin
            var _imbExpr98: MethodBuilder;
            if (mc.Args.Count=0) and DictDictHas(fFieldBuilders, _localClsExpr98, mc.MethodName) then
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
                  raise new Exception('로컬 클래스 "'+_localClsExpr98+'"(외부 조상 "'+_extAncExpr98.FullName+'")에 메서드/필드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
                var _emiParamsExpr98:=_emiExpr98.GetParameters;
                for var _emiAiExpr98:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_emiAiExpr98], _emiParamsExpr98[_emiAiExpr98].ParameterType);
                aIL.Emit(OpCodes.Callvirt, _emiExpr98);
              end;
            end
            else
              raise new Exception('로컬 클래스 "'+_localClsExpr98+'"에 메서드/필드 "'+mc.MethodName+'"가 없습니다 (경로: '+mc.ObjName+'.'+mc.MethodName+').');
          end
          else
          begin
            if _qType.IsValueType then
            begin
              // [버그 수정] 필드가 값 타입(예: fLine: integer)이면 Ldfld로 올라온 원시값 위에
              // 곧장 Callvirt하면 안 된다 — Box 후 System.Object 기준으로 메서드를 찾는다.
              aIL.Emit(OpCodes.Box, _qType);
              var _objType5:=typeof(System.Object);
              var _emi5b:=ResolveMethodByArity(_objType5, mc.MethodName, mc.Args, false);
              if _emi5b=nil then
                raise new Exception('System.Object에 메서드 "'+mc.MethodName+'"가 없습니다 (값 타입 필드 Box 후 경로: '+mc.ObjName+'.'+mc.MethodName+')');
              var _emi5bParams:=_emi5b.GetParameters;
              for var _emi5bAi:=0 to mc.Args.Count-1 do
                EmitArgForParamType(aIL, mc.Args[_emi5bAi], _emi5bParams[_emi5bAi].ParameterType);
              aIL.Emit(OpCodes.Callvirt, _emi5b);
            end
            else
            begin
              var _pi5:=SafeGetProperty(_qType, mc.MethodName);   // ToString은 프로퍼티가 아니므로 nil
              if (mc.Args.Count=0) and (_pi5<>nil) and (_pi5.GetGetMethod<>nil) then
                aIL.Emit(OpCodes.Callvirt, _pi5.GetGetMethod)
              else
              begin
                var _emi5:=ResolveMethodByArity(_qType, mc.MethodName, mc.Args, false); // Int32.ToString() 찾음
                if _emi5=nil then
                  raise new Exception('타입 "'+_qType.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
                var _emi5Params:=_emi5.GetParameters;
                for var _emi5Ai:=0 to mc.Args.Count-1 do
                  EmitArgForParamType(aIL, mc.Args[_emi5Ai], _emi5Params[_emi5Ai].ParameterType);
                aIL.Emit(OpCodes.Callvirt, _emi5);
              end;
            end;
          end;
    end;

    // 갈래 6: mc.ObjName이 self가 상속한 외부 타입의 프로퍼티(예: "Controls.Count").
    procedure EmitMCB_ExternalAncestorProp(aIL: ILGenerator; mc: TMethodCallExprNode);
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
                raise new Exception('타입 "'+_qType7.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
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
                raise new Exception('타입 "'+_qType7.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개, 경로: '+mc.ObjName+'.'+mc.MethodName+').');
              var _emi7Params:=_emi7.GetParameters;
              for var _emi7Ai:=0 to mc.Args.Count-1 do
                EmitArgForParamType(aIL, mc.Args[_emi7Ai], _emi7Params[_emi7Ai].ParameterType);
              aIL.Emit(OpCodes.Callvirt, _emi7);
            end;
          end;
    end;

    // 갈래 7: mc.ObjName이 self의 무인자 인스턴스 메서드(예: "Cur.Kind"의 Cur).
    // imbSelf100은 호출부에서 TryFindInstanceMethod로 이미 찾아 넘겨준다.
    procedure EmitMCB_SelfNoArgMethod(aIL: ILGenerator; mc: TMethodCallExprNode; imbSelf100: MethodBuilder);
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
    end;

    // 갈래 8(폴백): 위 어디에도 안 걸리면 점 없는 단일 이름의 외부 정적 타입(주로 enum)을 시도.
    procedure EmitMCB_Fallback(aIL: ILGenerator; mc: TMethodCallExprNode);
    begin
          // [버그 수정] ObjName이 필드/지역변수/외부 조상 프로퍼티/self 무인자 메서드
          // 어디에도 없으면, 마지막으로 점 없는 단일 이름의 외부 정적 타입(주로 enum, 예:
          // ColumnHeaderStyle)일 가능성을 시도한다. 기존에는 이 케이스를 아예 시도하지
          // 않고 곧장 "알 수 없는 변수"로 던졌다 (ObjName 자체에 '.'이 있는 체인 케이스만
          // 위쪽 1364번째 줄 분기에서 static 타입 경로를 탔었음).
          var _bareStaticT: System.Type := SafeResolveExternalType(mc.ObjName);
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
                  raise new Exception('외부 타입 "'+_bareStaticT.FullName+'"에 정적 멤버 "'+mc.MethodName+'"가 없습니다 (경로: '+mc.ObjName+'.'+mc.MethodName+').');
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

    // [Stage 143] EmitExprDispatch 안에서 압도적으로 큰 단일 분기인 TMethodCallExprNode
    // 처리부(~700줄)를 별도 함수로 분리. 내용은 원본과 100% 동일 - 위치만 옮겼다.
    // [Stage 144] 위 7갈래를 각각 별도 함수로 추가 분할 - 이 함수는 조건을 그대로 재평가해
    // 알맞은 함수를 호출하는 얇은 디스패처만 남긴다.
    procedure EmitExprMethodCallBranch(aIL: ILGenerator; e: TExprNode);
    var mc: TMethodCallExprNode; fb144: FieldBuilder; imbSelf144: MethodBuilder;
    begin
        mc:=TMethodCallExprNode(e);
        if (mc.ObjName<>'') and (mc.ObjName.IndexOf('.')>=0) and (mc.ObjCastType='') then
          EmitMCB_QualifiedChain(aIL, mc)
        else if mc.ObjName='' then
          EmitMCB_ImplicitSelfCall(aIL, mc)
        else if (fLocalScope.Has(mc.ObjName) or fGlobalScope.Has(mc.ObjName))
           and (fLocalScope.HasClrType(mc.ObjName) or fGlobalScope.HasClrType(mc.ObjName)) then
          EmitMCB_ClrTypedVar(aIL, mc)
        else if fLocalScope.Has(mc.ObjName) or fGlobalScope.Has(mc.ObjName)
                or fGlobalConstFields.ContainsKey(mc.ObjName) then
          EmitMCB_LocalVarOrConst(aIL, mc)
        else if TryFindFieldBuilder(fCurClassName, mc.ObjName, fb144) then
          EmitMCB_FieldAccess(aIL, mc, fb144)
        else if (FindExternalAncestorType(fCurClassName)<>nil)
                and (SafeGetProperty(FindExternalAncestorType(fCurClassName), mc.ObjName)<>nil) then
          EmitMCB_ExternalAncestorProp(aIL, mc)
        else if (fCurClassName<>'') and (mc.ObjCastType='')
                and TryFindInstanceMethod(fCurClassName, mc.ObjName, imbSelf144)
                and ((FindInstanceMethodParamTypes(fCurClassName, mc.ObjName)=nil)
                     or (FindInstanceMethodParamTypes(fCurClassName, mc.ObjName).Length=0)) then
          EmitMCB_SelfNoArgMethod(aIL, mc, imbSelf144)
        else
          EmitMCB_Fallback(aIL, mc);
    end;

    procedure EmitExprDispatch(aIL: ILGenerator; e: TExprNode);
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
            var _P2EmptyTypesLocal1: array of System.Type;
            _P2EmptyTypesLocal1:=System.Type.EmptyTypes;
            var _extCtor:=SafeGetConstructor(_extCtorType, _P2EmptyTypesLocal1);
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
          // [버그 수정] PascalABC.NET의 and 완전 평가(non-short-circuit) — neo.ClassName이
          // fAbstractMethods에 없을 때도 인덱싱이 그대로 평가되어 KeyNotFoundException을
          // 던지던 문제. ContainsKey일 때만 Count를 보는 단계적 if로 바꾼다.
          if fAbstractMethods.ContainsKey(neo.ClassName) then
          begin
            if fAbstractMethods[neo.ClassName].Count>0 then
              raise new Exception('"'+neo.ClassName+'"은(는) abstract 메서드를 갖고 있어 인스턴스를 생성할 수 없습니다 (abstract 클래스).');
          end;
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
        EmitExprMethodCallBranch(aIL, e)
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
          eiResultType:=EmitExtraIndicesChain(aIL, eiN.ExtraIndices, eiResultType);
        if (eiN.MemberName<>'') and (eiN.MethodArgs<>nil) then
        begin
          // [Stage 95] obj[i].Method(args) — 인덱싱 결과(스택에 이미 올라와 있음)에 대해
          // 일반 외부 메서드 호출과 동일한 리플렉션 기반 오버로드 해석/인자 강제변환을 적용한다.
          var eiMi95:=ResolveMethodByArity(eiResultType, eiN.MemberName, eiN.MethodArgs, false);
          if eiMi95=nil then
            raise new Exception('타입 "'+eiResultType.FullName+'"에 메서드 "'+eiN.MemberName+'"가 없습니다 (인자 '+eiN.MethodArgs.Count.ToString+'개, 경로: '+eiN.Qualifier+'.'+eiN.MemberName+').');
          var eiParams95:=eiMi95.GetParameters;
          for var eiAi95:=0 to eiN.MethodArgs.Count-1 do
            EmitArgForParamType(aIL, eiN.MethodArgs[eiAi95], eiParams95[eiAi95].ParameterType);
          aIL.Emit(OpCodes.Callvirt, eiMi95);
        end
        else if eiN.MemberName<>'' then
        begin
          // [자기컴파일 버그 수정] eiResultType이 아직 CreateType 안 된 로컬 클래스의
          // TypeBuilder면 .GetField(name, BindingFlags) 2개짜리 오버로드가 NotSupportedException을
          // 던진다 — SafeGetField로 우회한다.
          var eiFi:=SafeGetField(eiResultType, eiN.MemberName);
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
        // [Stage 101 버그 수정] chType90이 아직 CreateType되지 않은 로컬(자기 컴파일 대상) 클래스의
        // TypeBuilder이면(예: "PeekAt(1).Kind" — PeekAt의 반환 타입 TToken이 아직 완성 전인 자기
        // 컴파일 대상 클래스), 아래 SafeGetProperty/GetField/ResolveMethodByArity가 쓰는 리플렉션
        // 조회는 TypeBuilder에 대해 NotSupportedException("유형이 만들어지기 전에 호출된 멤버는
        // 지원되지 않습니다")을 던진다(셀프호스팅 컴파일 실제 사례) — EmitQualifierChainLoad와
        // 동일하게 fInstanceMethods/fFieldBuilders에서 직접 가져오는 경로로 우회한다.
        var chLocalCls101:=FindLocalClassNameForTypeBuilder(chType90);
        if ch90.IsCall and (chLocalCls101<>'') and fInstanceMethods.ContainsKey(chLocalCls101)
           and fInstanceMethods[chLocalCls101].ContainsKey(ch90.MemberName) then
        begin
          var chLocalMi101:=fInstanceMethods[chLocalCls101][ch90.MemberName];
          EmitArgsCoerced(aIL, ch90.Args, FindInstanceMethodParamTypes(chLocalCls101, ch90.MemberName));
          if chIsVal90 then aIL.Emit(OpCodes.Call, chLocalMi101)
          else aIL.Emit(OpCodes.Callvirt, chLocalMi101);
        end
        else if (not ch90.IsCall) and (chLocalCls101<>'') and fInstanceMethods.ContainsKey(chLocalCls101)
           and fInstanceMethods[chLocalCls101].ContainsKey('get_'+ch90.MemberName) then
        begin
          if chIsVal90 then aIL.Emit(OpCodes.Call, fInstanceMethods[chLocalCls101]['get_'+ch90.MemberName])
          else aIL.Emit(OpCodes.Callvirt, fInstanceMethods[chLocalCls101]['get_'+ch90.MemberName]);
        end
        else if (not ch90.IsCall) and (chLocalCls101<>'') and fFieldBuilders.ContainsKey(chLocalCls101)
           and fFieldBuilders[chLocalCls101].ContainsKey(ch90.MemberName) then
          aIL.Emit(OpCodes.Ldfld, fFieldBuilders[chLocalCls101][ch90.MemberName])
        else if (not ch90.IsCall) and (chLocalCls101<>'') and fInstanceMethods.ContainsKey(chLocalCls101)
           and fInstanceMethods[chLocalCls101].ContainsKey(ch90.MemberName) then
        begin
          if chIsVal90 then aIL.Emit(OpCodes.Call, fInstanceMethods[chLocalCls101][ch90.MemberName])
          else aIL.Emit(OpCodes.Callvirt, fInstanceMethods[chLocalCls101][ch90.MemberName]);
        end
        else if not ch90.IsCall then
        begin
          var chPi90:=SafeGetProperty(chType90, ch90.MemberName);
          if (chPi90<>nil) and (chPi90.GetGetMethod<>nil) then
          begin
            if chIsVal90 then aIL.Emit(OpCodes.Call, chPi90.GetGetMethod)
            else aIL.Emit(OpCodes.Callvirt, chPi90.GetGetMethod);
          end
          else
          begin
            // [자기컴파일 버그 수정] chType90이 아직 CreateType되지 않은 로컬 TypeBuilder이고
            // 그 필드가 chLocalCls101 자신이 아니라 부모 클래스에서 상속된 것이면(위 993행대
            // 분기들은 chLocalCls101 자기 자신의 fFieldBuilders만 확인하고 부모는 안 봤다),
            // 여기까지 떨어져 내려와 raw chType90.GetField(...)를 부르게 되는데 이건
            // TypeBuilder.GetField(name, BindingFlags) 내부 오버로드로 위임되어
            // NotSupportedException("유형이 만들어지기 전에 호출된 멤버는 지원되지 않습니다")을
            // 던진다(실제 사례: TCodeGenerator 자신의 생성자 본문 생성 중). 먼저 부모 체인까지
            // 훑는 TryFindFieldBuilder로 로컬 필드를 찾고, 그래도 없으면 예외를 삼키는
            // SafeGetField로 리플렉션을 시도한다(raw GetField는 더 이상 직접 부르지 않는다).
            var chFi90: FieldInfo;
            var chFb90: FieldBuilder;
            if (chLocalCls101<>'') and TryFindFieldBuilder(chLocalCls101, ch90.MemberName, chFb90) then
              chFi90:=chFb90
            else
              chFi90:=SafeGetField(chType90, ch90.MemberName);
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
          // [Stage 104] chMi90이 확장 메서드(IsStatic=true)면 첫 파라미터는 "this"(이미
          // 스택에 올라간 인스턴스)이므로 건너뛰고, 실제 호출 인자(ch90.Args)는
          // 두 번째 파라미터부터 대응시킨다.
          var chParamOff90:=0;
          if chMi90.IsStatic then chParamOff90:=1;
          for var chAi90:=0 to ch90.Args.Count-1 do
            EmitArgForParamType(aIL, ch90.Args[chAi90], chMiParams90[chAi90+chParamOff90].ParameterType);
          if chMi90.IsStatic then aIL.Emit(OpCodes.Call, chMi90) // 확장 메서드는 항상 정적 Call
          else if chIsVal90 then aIL.Emit(OpCodes.Call, chMi90)
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
        var aiElemClrType: System.Type; // [Stage 107 버그 수정]
        var aiVarClrType: System.Type := nil; // [자기컴파일 버그 수정 2026.08] 진짜 배열인지 판별용
        if fLocalScope.Has(ai.ArrName) then
        begin
          aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(ai.ArrName));
          aiIsRefElem:=(GetVarType(ai.ArrName)=vtStrArray) or (GetVarType(ai.ArrName)=vtObjArray);
          aiVarClrType:=fLocalScope.GetLoc(ai.ArrName).LocalType;
          aiElemClrType:=SafeArrayElemType(aiVarClrType);
        end
        else if fGlobalScope.Has(ai.ArrName) then
        begin
          aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(ai.ArrName));
          aiIsRefElem:=(GetVarType(ai.ArrName)=vtStrArray) or (GetVarType(ai.ArrName)=vtObjArray);
          aiVarClrType:=fGlobalScope.GetLoc(ai.ArrName).LocalType;
          aiElemClrType:=SafeArrayElemType(aiVarClrType);
        end
        else
        begin
          var aiFb: FieldBuilder;
          if TryFindFieldBuilder(fCurClassName, ai.ArrName, aiFb) then
          begin
            aIL.Emit(OpCodes.Ldarg_0);
            aIL.Emit(OpCodes.Ldfld, aiFb);
            aiIsRefElem:=IsRefElementType(aiFb.FieldType); // [Stage 96 버그 수정] TypeBuilderInstantiation 예외 흡수
            aiVarClrType:=aiFb.FieldType;
            aiElemClrType:=SafeArrayElemType(aiVarClrType);
          end
          else
            raise new Exception('알 수 없는 변수 "'+ai.ArrName+'" (배열 인덱싱 대상을 지역/전역 변수도, "'
              +fCurClassName+'" 클래스의 필드도 아닌 곳에서 찾을 수 없습니다).');
        end;
        // [자기컴파일 버그 수정 2026.08] ArrName이 진짜 CLR 배열(T[])이 아니라 List<T>/
        // Dictionary 등 "Item" 인덱서를 쓰는 외부 제네릭 컬렉션이면(예: lst1[0], order[order.Count-1]),
        // 지금까지는 이 사실을 전혀 확인하지 않고 아래에서 무조건 Ldelem_*를 방출해 컬렉션
        // 객체 참조를 마치 SZArray인 것처럼 읽어들였다. 이는 CLR 검증기를 통과할 수 없는
        // 잘못된 IL이라 실행 시 .NET 예외로 잡히지 못하고 그대로 네이티브 접근 위반
        // (0xc0000005, clr.dll 크래시, 이벤트 뷰어 예외 코드 80131506)으로 프로세스가
        // 죽는다 — 자기컴파일 실제 재현 사례(Test_ListBug.pas, Main.pas의 order[...] 등).
        // TChainedIndexExprNode가 이미 쓰고 있는 EmitIndexerGet(배열이면 Ldelem, 아니면
        // 리플렉션으로 Item 인덱서의 get을 Callvirt)으로 위임해 이 경우를 올바르게 처리한다.
        if (aiVarClrType<>nil) and (not aiVarClrType.IsArray) then
          EmitIndexerGet(aIL, aiVarClrType, ai.Index)
        else
        begin
          EmitExpr(aIL, ai.Index);
          // [Stage 37 버그 수정] 이전에는 배열 종류와 무관하게 항상 Ldelem_I4를 썼다 —
          // array of integer는 우연히 맞았지만 array of string은 참조(포인터)를 4바이트
          // 정수로 잘못 읽어 쓰레기 값이 나왔다. 원소를 쓰는 쪽(Stelem, 아래 TArrayAssignStmtNode)은
          // 이미 배열 타입을 보고 Stelem_Ref/Stelem_I4를 갈라 쓰고 있었으므로 읽는 쪽도 맞춘다.
          // [Stage 90] array of object도 문자열 배열과 마찬가지로 참조 타입 원소이므로 Ldelem_Ref.
          //
          // [Stage 107 버그 수정] 위 aiIsRefElem 분기는 "참조냐 아니냐"만 갈랐다 — 참조가 아닌
          // 값 타입 원소는 전부 Ldelem_I4(4바이트 폭)로 읽었는데, char 배열(원소 2바이트, 예:
          // sourceCode.ToCharArray로 만든 array of char)이나 real/int64 배열처럼 실제 CLR
          // 원소 크기가 4바이트가 아니면 Ldelem_I4가 잘못된 stride(4바이트 간격)로 주소를
          // 계산해 배열 실제 메모리 범위를 넘어 읽는다 — 작은 배열은 우연히 힙 안쪽이라
          // 조용히 쓰레기 값만 나오지만, 큰 배열(자기컴파일 시 Main.pas 전체를 읽어들인
          // chars: array of char 등)은 계산된 주소가 힙 세그먼트 밖으로 넘어가
          // AccessViolationException으로 그대로 죽는다. aiElemClrType(로컬/전역 슬롯 또는
          // 필드의 실제 CLR 배열 원소 타입)을 직접 보고 폭에 맞는 Ldelem_* opcode를 고른다.
          if aiIsRefElem or ((aiElemClrType<>nil) and not aiElemClrType.IsValueType) then
            aIL.Emit(OpCodes.Ldelem_Ref)
          else if (aiElemClrType<>nil) and (aiElemClrType=typeof(char)) then
            aIL.Emit(OpCodes.Ldelem_U2)
          else if (aiElemClrType<>nil) and (aiElemClrType=typeof(double)) then
            aIL.Emit(OpCodes.Ldelem_R8)
          else if (aiElemClrType<>nil) and (aiElemClrType=typeof(single)) then
            aIL.Emit(OpCodes.Ldelem_R4)
          else if (aiElemClrType<>nil) and (aiElemClrType=typeof(int64)) then
            aIL.Emit(OpCodes.Ldelem_I8)
          else
            aIL.Emit(OpCodes.Ldelem_I4);
        end;
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
        // [Stage 106 버그 수정] Object Pascal은 인자 0개 함수를 괄호 없이 호출하는 문법을
        // 허용한다(예: "inputPath := ResolveInputPath;"). Parser는 이 패턴을 사용자 정의
        // 함수(fFuncNames)에 대해서는 TFuncCallExprNode로 승격하는 분기가 없어(Stage 93은
        // 표준 라이브러리 니라딕 함수만 처리) 그냥 TVarRefNode로 만들어버린다 — 그 결과
        // 여기서 "선언되지 않은 변수"로 잘못 실패했다. vr.VarName이 지역/전역 변수도 아니고
        // 매개변수 0개짜리 최상위 함수로 등록돼 있으면, 변수 로드 대신 그 함수를 호출한다.
        else if fMethods.ContainsKey(vr.VarName) and
           ((not fTopParamClrTypes.ContainsKey(vr.VarName)) or (fTopParamClrTypes[vr.VarName].Length=0)) then
          aIL.Emit(OpCodes.Call, fMethods[vr.VarName])
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
        // [자기컴파일 버그 수정 2026.08] 아래 단락평가(short-circuit) 분기는 진짜 Pascal
        // boolean 식(예: "(i < chars.Length) and (chars[i] <> '}')")에서만 타야 한다.
        // 그런데 이 조건이 b.Op만 보고 무조건 걸려서, "RegexOptions.Singleline or
        // RegexOptions.IgnoreCase"처럼 enum 플래그를 비트 OR로 합치는 식도 똑같이
        // Brtrue/Brfalse 단락평가를 태웠다 — enum 값(예: Singleline=16)은 0이 아니므로
        // boOr의 Brtrue가 항상 "참"으로 판정해 오른쪽(IgnoreCase) 평가 자체를 생략하고
        // 결과로 하드코딩된 Ldc_I4_1(그냥 리터럴 1)을 내놓는다 — 실제로는 어느 쪽 플래그도
        // 아닌 값이 되어(우연히 IgnoreCase=1과 겹쳐 보일 뿐) Singleline이 통째로 사라진다
        // (실제 재현: Main.pas의 ExtractUsesNames가 여러 줄에 걸친 uses 절을 못 찾고
        // 엉뚱한 위치에 정규식이 매칭됨). 진짜 boolean(lt/rt 둘 다 vtBoolean)일 때만
        // 단락평가로 가고, 그 외(enum/정수 비트 연산 등)는 아래 일반 분기의 완전평가
        // And/Or(OpCodes.And/Or)로 흘러가게 한다.
        if ((b.Op=boAnd) or (b.Op=boOr)) and (lt=vtBoolean) and (rt=vtBoolean) then
        begin
          // [버그 수정] 기존에는 이 분기까지 오지 못하고 아래쪽 일반 산술 처리 분기(현재
          // 1330~1331행 근처의 "else if b.Op=boAnd then aIL.Emit(OpCodes.And)")에서 처리됐는데,
          // 그 경로는 Left/Right를 항상 "둘 다" 먼저 평가한 뒤 비트 And/Or를 적용하는 완전
          // 평가(non-short-circuit) 방식이었다. 이 컴파일러 자신의 실제 소스 코드
          // (Main.pas의 StripCommentsForUsesScan 등)는
          //   while (i < chars.Length) and (chars[i] <> '}') do i := i + 1;
          // 처럼 "왼쪽 조건이 거짓이면 오른쪽은 평가되지 않는다"는 단락 평가(short-circuit)를
          // 전제로 작성되어 있어서, 완전 평가로 실행하면 i가 배열 끝에 도달했을 때도
          // chars[i]가 그대로 평가되어 IndexOutOfRangeException으로 죽는다(자기컴파일
          // 2세대 실행 시 실제로 재현됨). if/while의 조건뿐 아니라 모든 and/or 표현식이
          // EmitExpr의 이 지점을 거치므로, 여기서 진짜 단락 평가(Brfalse/Brtrue 분기)로
          // 바꾼다.
          var scShortL:=aIL.DefineLabel; var scEndL:=aIL.DefineLabel;
          EmitExpr(aIL, b.Left);
          if b.Op=boAnd then
          begin
            aIL.Emit(OpCodes.Brfalse, scShortL); // 왼쪽이 거짓 → 오른쪽 평가 생략, 결과=거짓(0)
            EmitExpr(aIL, b.Right);
            aIL.Emit(OpCodes.Br, scEndL);
            aIL.MarkLabel(scShortL);
            aIL.Emit(OpCodes.Ldc_I4_0);
            aIL.MarkLabel(scEndL);
          end
          else
          begin
            aIL.Emit(OpCodes.Brtrue, scShortL); // 왼쪽이 참 → 오른쪽 평가 생략, 결과=참(1)
            EmitExpr(aIL, b.Right);
            aIL.Emit(OpCodes.Br, scEndL);
            aIL.MarkLabel(scShortL);
            aIL.Emit(OpCodes.Ldc_I4_1);
            aIL.MarkLabel(scEndL);
          end;
        end
        else if (lt=vtObject) and (rt=vtObject) then // [Stage 66] 연산자 오버로딩
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
        // [Stage 116 버그 수정] char+char(둘 다 vtChar, 둘 다 아직 vtString이 아닌 경우)도
        // 문자열 연결 경로로 보낸다 — 예전엔 이 조건이 없어 char+char가 곧장 아래 else의
        // 순수 정수 덧셈(OpCodes.Add)으로 떨어져, 문자 코드가 숫자로 더해진 값이 string
        // 자리(예: TToken 생성자 인자)에 그대로 들어가는 자기컴파일 전용 버그를 냈다
        // (Lexer.pas의 `#39+_qlast+#39`에서 재현, 39+32+39=110).
        else if (b.Op=boAdd) and ((lt=vtString) or (rt=vtString) or ((lt=vtChar) and (rt=vtChar))) then
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
        cmp:=TCompareNode(e);
        // [자기컴파일 버그 수정 — 실제 사례] 문자열 비교("System.IO.Path.GetExtension(x).ToLower
        // = '.pabcproj'" 같은 식)를 지금까지는 숫자 비교와 똑같이 raw Ceq로 방출했다.
        // Ceq는 값 타입엔 값 비교지만, string은 참조 타입이라 CLR의 ceq는 "참조가 같은가"만
        // 본다 — 리터럴 문자열은 어셈블리 내에서 인턴되어 같은 참조를 공유하는 경우가
        // 많아 우연히 맞는 것처럼 보이지만, ToLower/Trim/Substring/Concat 등 런타임에
        // 새로 만들어진 문자열은 내용이 같아도 별개 인스턴스라 항상 false로 나온다.
        // 이 때문에 자기컴파일된 실행파일의 ".pabcproj 확장자 검사" 같은 실제 조건문이
        // 늘 거짓으로 평가되는 조용한 논리 오류가 있었다(컴파일 자체는 성공하니 지금까지
        // 드러나지 않았다). 피연산자 중 하나라도 string이면 String.Equals(문자열,문자열)
        // (동등)이나 String.CompareOrdinal(문자열,문자열)(대소 비교)을 대신 호출한다.
        var _cmpLt90:=GetExprClrType(cmp.Left);
        var _cmpRt90:=GetExprClrType(cmp.Right);
        var _cmpIsStr90:=((_cmpLt90<>nil) and (_cmpLt90=typeof(string)))
                       or ((_cmpRt90<>nil) and (_cmpRt90=typeof(string)));
        EmitExpr(aIL, cmp.Left); EmitExpr(aIL, cmp.Right);
        if _cmpIsStr90 and ((cmp.Op=cmpEq) or (cmp.Op=cmpNeq)) then
        begin
          var _seqMi90:=typeof(string).GetMethod('Equals', [typeof(string), typeof(string)]);
          aIL.Emit(OpCodes.Call, _seqMi90);
          if cmp.Op=cmpNeq then
          begin aIL.Emit(OpCodes.Ldc_I4_0); aIL.Emit(OpCodes.Ceq); end;
        end
        else if _cmpIsStr90 and ((cmp.Op=cmpLt) or (cmp.Op=cmpGt) or (cmp.Op=cmpLe) or (cmp.Op=cmpGe)) then
        begin
          var _scmpMi90:=typeof(string).GetMethod('CompareOrdinal', [typeof(string), typeof(string)]);
          aIL.Emit(OpCodes.Call, _scmpMi90);
          aIL.Emit(OpCodes.Ldc_I4_0);
          if cmp.Op=cmpLt then aIL.Emit(OpCodes.Clt)
          else if cmp.Op=cmpGt then aIL.Emit(OpCodes.Cgt)
          else if cmp.Op=cmpLe then
            begin aIL.Emit(OpCodes.Cgt); aIL.Emit(OpCodes.Ldc_I4_0); aIL.Emit(OpCodes.Ceq); end
          else if cmp.Op=cmpGe then
            begin aIL.Emit(OpCodes.Clt); aIL.Emit(OpCodes.Ldc_I4_0); aIL.Emit(OpCodes.Ceq); end;
        end
        else if cmp.Op=cmpEq then aIL.Emit(OpCodes.Ceq)
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
        var _P2EmptyTypesLocal3: array of System.Type;
        _P2EmptyTypesLocal3:=System.Type.EmptyTypes;
        var getTypeMI:=typeof(System.Object).GetMethod('GetType', _P2EmptyTypesLocal3);
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

      else if e is TArrayLiteralExprNode then
      begin
        // [Stage 105 버그 수정] TArrayLiteralExprNode는 여태 EmitArgForParamType(함수 호출
        // 인자 자리)에서만 처리됐다 — "extClasses := [typeof(A), typeof(B)];"처럼 대입문의
        // 우변(EmitValueForVType → EmitExpr 경로)이나 그 밖의 일반 식 위치에 오면 여기까지
        // 떨어지지 않고 "알 수 없는 식 노드"로 실패했다(자기컴파일 실제 사례:
        // TCodeGenerator 생성자 안의 "array of System.Type" 필드 대입). EmitExpr은 대입
        // 대상의 정확한 CLR 원소 타입을 모르므로, 원소 자신의 CLR 타입(주로 typeof(...)이면
        // System.Type)을 InferArgClrType으로 추정해 그 타입의 배열을 만든다 — 원소가
        // 비어있거나 타입을 못 정하면 System.Object로 폴백한다.
        var al105:=TArrayLiteralExprNode(e);
        var alElemT105:=typeof(System.Object);
        if al105.Elements.Count>0 then
        begin
          var alFirstT105:=InferArgClrType(al105.Elements[0]);
          if alFirstT105<>nil then alElemT105:=alFirstT105;
        end;
        aIL.Emit(OpCodes.Ldc_I4, al105.Elements.Count);
        aIL.Emit(OpCodes.Newarr, alElemT105);
        for var alI105:=0 to al105.Elements.Count-1 do
        begin
          aIL.Emit(OpCodes.Dup);
          aIL.Emit(OpCodes.Ldc_I4, alI105);
          EmitArgForParamType(aIL, al105.Elements[alI105], alElemT105);
          if alElemT105.IsValueType then aIL.Emit(OpCodes.Stelem, alElemT105)
          else aIL.Emit(OpCodes.Stelem_Ref);
        end;
      end

      else raise new Exception('알 수 없는 식 노드: '+e.GetType.Name);
    end;

    procedure EmitExpr(aIL: ILGenerator; e: TExprNode);
    begin
      fEmitDepth:=fEmitDepth+1;
      if fEmitDepth>5000 then
        raise new Exception('[진단] EmitExpr 재귀 깊이 초과(5000) — 폭주 의심 노드: '+e.GetType.Name);
      try
        EmitExprDispatch(aIL, e);
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
        var _P2EmptyTypesLocal4: array of System.Type;
        _P2EmptyTypesLocal4:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Newobj, listT.GetConstructor(_P2EmptyTypesLocal4));
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
        var _P2EmptyTypesLocal5: array of System.Type;
        _P2EmptyTypesLocal5:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Newobj, listT.GetConstructor(_P2EmptyTypesLocal5));
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
        var _P2EmptyTypesLocal6: array of System.Type;
        _P2EmptyTypesLocal6:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Newobj, listT.GetConstructor(_P2EmptyTypesLocal6));
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
        var _P2EmptyTypesLocal7: array of System.Type;
        _P2EmptyTypesLocal7:=System.Type.EmptyTypes;
        randCtor:=typeof(System.Random).GetConstructor(_P2EmptyTypesLocal7);
        if node.Args.Count=0 then
        begin
          aIL.Emit(OpCodes.Newobj, randCtor);
          var _P2EmptyTypesLocal8: array of System.Type;
          _P2EmptyTypesLocal8:=System.Type.EmptyTypes;
          aIL.Emit(OpCodes.Callvirt, typeof(System.Random).GetMethod('NextDouble', _P2EmptyTypesLocal8));
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
        var _P2EmptyTypesLocal9: array of System.Type;
        _P2EmptyTypesLocal9:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Callvirt, typeof(string).GetMethod('ToUpper', _P2EmptyTypesLocal9));
      end

      else if node.Name='LowerCase' then
      begin
        if node.Args.Count<>1 then raise new Exception('LowerCase()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        var _P2EmptyTypesLocal10: array of System.Type;
        _P2EmptyTypesLocal10:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Callvirt, typeof(string).GetMethod('ToLower', _P2EmptyTypesLocal10));
      end

      else if node.Name='Trim' then
      begin
        if node.Args.Count<>1 then raise new Exception('Trim()는 인자가 1개 필요합니다 (Stage 72)');
        EmitExpr(aIL, node.Args[0]);
        var _P2EmptyTypesLocal11: array of System.Type;
        _P2EmptyTypesLocal11:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Callvirt, typeof(string).GetMethod('Trim', _P2EmptyTypesLocal11));
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
        var _P2EmptyTypesLocal12: array of System.Type;
        _P2EmptyTypesLocal12:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Call, typeof(System.Console).GetMethod('ReadLine', _P2EmptyTypesLocal12));
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
        var _P2EmptyTypesLocal13: array of System.Type;
        _P2EmptyTypesLocal13:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Call, typeof(System.IO.Directory).GetMethod('GetCurrentDirectory', _P2EmptyTypesLocal13));
      end

      // [Stage 96] ParamCount — 커맨드라인 인자 개수. Environment.GetCommandLineArgs()의
      // 0번째는 실행 파일 경로 자신이므로, Pascal 관례(ParamStr(0)=실행파일, ParamStr(1..N)=인자)에
      // 맞춰 배열 길이에서 1을 뺀 값을 돌려준다.
      else if node.Name='ParamCount' then
      begin
        if node.Args.Count<>0 then raise new Exception('ParamCount는 인자가 없어야 합니다 (Stage 96)');
        var _P2EmptyTypesLocal14: array of System.Type;
        _P2EmptyTypesLocal14:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Call, typeof(System.Environment).GetMethod('GetCommandLineArgs', _P2EmptyTypesLocal14));
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
        var _P2EmptyTypesLocal15: array of System.Type;
        _P2EmptyTypesLocal15:=System.Type.EmptyTypes;
        aIL.Emit(OpCodes.Call, typeof(System.Environment).GetMethod('GetCommandLineArgs', _P2EmptyTypesLocal15));
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

    // [버그 수정] "foreach var x in y do" 원소 타입 추론에서, Dictionary<TKey,TValue>류를
    // 실제로 KeyValuePair<TKey,TValue>를 순회하는 컬렉션으로 식별하기 위한 헬퍼.
    // GetGenericTypeDefinition의 짧은 이름(Dictionary`2/SortedDictionary`2/SortedList`2/
    // IDictionary`2/IReadOnlyDictionary`2)으로 판별한다 — 네임스페이스까지는 비교하지
    // 않는다(전부 System.Collections.Generic 표준 컬렉션이므로 이름만으로 충분하고,
    // 사용자 정의 "Dictionary<,>" 같은 오검출 가능성은 이 프로젝트 범위 밖으로 무시한다).
    function IsDictionaryLikeType102(t: System.Type): boolean;
    var defName: string;
    begin
      Result:=false;
      if (t=nil) or (not t.IsGenericType) then exit;
      defName:=t.GetGenericTypeDefinition.Name;
      if (defName='Dictionary`2') or (defName='SortedDictionary`2')
        or (defName='SortedList`2') or (defName='IDictionary`2')
        or (defName='IReadOnlyDictionary`2') or (defName='ConcurrentDictionary`2') then
        Result:=true;
    end;

    // [Stage 112 리팩터] EmitStatement가 self-compile 시 System.BadImageFormatException으로
    // 로드조차 안 되는 문제(단일 try/finally 안에 33개의 s-is 분기, 1800줄 이상이 들어있어
    // self-compile 코드생성기가 메서드 전체를 손상된 IL로 만드는 것으로 추정 — Stage 111의
    // ParsePrimary와 동일한 증상/원인)을 완화하기 위해, 재귀호출(EmitStatement 자기 자신을
    // 다시 부르는 제어흐름 분기)이 없는 분기들을 별도 함수로 분리했다. 로직은 원본과
    // 완전히 동일하다 — 처리했으면 True, 이 함수가 담당하지 않는 문장이면 False를 돌려준다.
    function EmitStatementDataOps1(aIL: ILGenerator; s: TStmtNode): boolean;
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
      Result:=true;
      if s is TReadlnStmtNode then
      begin
        var rln := TReadlnStmtNode(s);
        var _P2EmptyTypesLocal16: array of System.Type;
        _P2EmptyTypesLocal16:=System.Type.EmptyTypes;
        var rlnM: MethodInfo := typeof(Console).GetMethod('ReadLine', _P2EmptyTypesLocal16);
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
          // [자기컴파일 버그 수정] "var closedTypes74e:=new System.Type[n];"처럼 ArraySizeExpr가
          // 있는 배열 생성(new Type[n])은 위에서 구한 게 원소 타입(예: System.Type)일 뿐인데,
          // 이 분기가 ArraySizeExpr를 전혀 확인하지 않아 지역변수가 배열이 아니라 스칼라
          // 원소 타입으로 선언됐다 — 그 결과 "closedTypes74e[i]:=x" 같은 배열 원소 대입이
          // 인덱서 setter(set_Item) 호출로 오인되어 "타입 System.Type에 메서드 set_Item이
          // 없습니다"로 실패했다(자기컴파일 중 실제 재현됨). GetExprClrType의 TNewObjectExprNode
          // 처리(2033행 부근)와 동일하게 MakeArrayType으로 배열 타입으로 감싼다.
          if (ivNeo.ArraySizeExpr<>nil) and (ivClrType<>nil) then
            ivClrType:=ivClrType.MakeArrayType();
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
        else if ivs.ValueExpr is TAsCastExprNode then
        begin
          // [셀프 컴파일 버그 수정] "var _fr:=TFieldReadExprNode(e);"처럼 우리가 만든
          // 로컬 클래스로의 하드 캐스트(예: CodeGen.InferType 자신의 소스)는
          // TExternalCastExprNode가 아니라 TAsCastExprNode(IsExternalType=false)로 파싱된다
          // (Stage: 로컬 클래스 하드캐스트도 as-cast 노드로 통일). 이 분기가 없으면 위
          // TExternalCastExprNode 분기를 안 타고 곧장 VTC(vtObject,'') 폴백(System.Object)으로
          // 떨어져, 이후 "_fr.FieldName" 같은 멤버 접근이 "System.Object에 멤버가 없습니다"로
          // 실패했다. GetExprClrType은 이미 TAsCastExprNode를 로컬(fBuiltInterfaces/fBuiltTypes/
          // fTypeBuilders)/외부(ResolveExternalType) 양쪽 다 정확히 추론하므로 재사용한다.
          var ivAsCastT:=GetExprClrType(ivs.ValueExpr);
          if (ivAsCastT<>nil) and (ivAsCastT<>typeof(System.Object)) then
          begin
            ivClrType:=ivAsCastT; ivIsExternal:=true; ivVt:=vtObject;
          end
          else ivClrType:=VTC(ivVt, '');
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
        else if ivs.ValueExpr is TFuncCallExprNode then
        begin
          // [셀프 컴파일 버그 수정] "var _mi4:=ResolveMethodByArity(...);"처럼, 클래스 안에
          // 중첩 선언된 헬퍼 함수(호이스트되어 fMethods에 MethodBuilder로 등록됨, 예:
          // ResolveMethodByArity가 InferType/EmitQualifierChainLoad 등 다른 메서드에서
          // 한정자 없이 불리는 경우)를 호출한 결과를 담는 지역 변수. InferType(TFuncCallExprNode)는
          // fFuncReturnTypes(최상위 함수 전용 표)에서만 찾고 fMethods는 몰라서, 이런 헬퍼
          // 호출은 항상 vtInteger로 폴백해 int32 지역 슬롯으로 선언되었다 — 이후
          // "_mi4.ReturnType"이 "타입 System.Object에 메서드 ReturnType이 없습니다"가 아니라
          // 아예 원시 int32 취급이라 "알 수 없는 메서드 .ReturnType"로 실패했다(cn=''
          // 원시타입 폴백 경로). GetExprClrType은 이미 fMethods[FuncName].ReturnType으로
          // 정확히 추론하므로(InferArgClrType의 TFuncCallExprNode 분기와 동일 패턴) 재사용한다.
          var ivFcT:=GetExprClrType(ivs.ValueExpr);
          if (ivFcT<>nil) and (ivFcT<>typeof(System.Object)) and (ivFcT<>typeof(System.Void)) then
          begin
            ivClrType:=ivFcT; ivIsExternal:=true; ivVt:=vtObject;
          end
          else ivClrType:=VTC(ivVt, '');
        end
        else if ivs.ValueExpr is TExternalIndexExprNode then
        begin
          // [버그 수정] "var x := dict[key];" 처럼 Dictionary/List 인덱서 결과를 담는
          // 지역변수: 기존에는 InferType이 TExternalIndexExprNode를 못 알아채고 vtInteger로
          // 폴백해 int32 슬롯으로 선언되었다 — 이후 x.Count 같은 호출이 "알 수 없는 메서드"로
          // 실패했다. GetExprClrType은 이미 이 노드 타입을 정확히 추론하므로 재사용한다.
          var ivIdxT:=GetExprClrType(ivs.ValueExpr);
          if (ivIdxT<>nil) and (ivIdxT<>typeof(System.Object)) then
          begin
            ivClrType:=ivIdxT; ivIsExternal:=true; ivVt:=vtObject;
          end
          else ivClrType:=VTC(ivVt, '');
        end
        else if ivs.ValueExpr is TArrayIndexExprNode then
        begin
          // [버그 수정] "var x := someField[key];" — someField가 fArrayNames에 등록된
          // List<T>/Dictionary<K,V> 등 외부 제네릭 컬렉션 "필드"(예: Parser.pas의
          // fClassGenericConstraint: Dictionary<string,List<string>>)일 때, 파서는
          // 이런 필드 인덱싱을 TExternalIndexExprNode가 아니라 TArrayIndexExprNode로
          // 만든다(Parser.pas [Stage 98] fArrayNames 등록 참고). 기존에는 이 케이스가
          // 여기서 분기되지 않아 InferType 폴백(vtInteger)으로 떨어져 x.Count가 "알 수
          // 없는 메서드"로 실패했다(자기컴파일 중 Parser.ResolveGenericInstantiation의
          // "var constraints:=fClassGenericConstraint[templateName];" 뒤 constraints.Count
          // 에서 실제로 재현됨). GetExprClrType은 이미 TArrayIndexExprNode도 정확히
          // 추론하므로(6718행 부근) 재사용한다.
          var ivArrIdxT:=GetExprClrType(ivs.ValueExpr);
          if (ivArrIdxT<>nil) and (ivArrIdxT<>typeof(System.Object)) then
          begin
            ivClrType:=ivArrIdxT; ivIsExternal:=true; ivVt:=vtObject;
          end
          else ivClrType:=VTC(ivVt, '');
        end
        else if ivs.ValueExpr is TTypeOfExprNode then
        begin
          // [Stage 101 버그 수정] "var pClrType:=typeof(integer);"처럼 typeof(...) 결과를
          // 담는 지역 변수. InferType(TTypeOfExprNode)는 vtObject로만 태깅하고(vtType이
          // 따로 없어서), 여기서 그 vtObject를 그대로 VTC(vtObject,'')에 넘기면 CLR 타입이
          // System.Object로 폴백되어 버렸다 — 그 결과 이후 "pClrType.IsByRef" 같은 멤버
          // 접근이 "타입 System.Object에 메서드 IsByRef가 없습니다"로 실패했다(자기컴파일
          // 중 BuildMethodBody 자신의 소스에서 실제로 재현됨). typeof(...)의 결과는 항상
          // 정확히 System.Type이므로 그대로 못박아 둔다.
          ivClrType:=typeof(System.Type); ivIsExternal:=true; ivVt:=vtObject;
        end
        else if ivs.ValueExpr is TChainedIndexExprNode then
        begin
          // [자기컴파일 버그 수정] "var _getMB4c:=fInstanceMethods[cn]['get_'+name];"처럼
          // 이중 인덱싱(바깥 인덱싱 결과를 다시 인덱싱, 예: Dictionary<string,Dictionary
          // <string,MethodBuilder>>)으로 얻은 값을 담는 지역 변수는 TChainedIndexExprNode로
          // 파싱된다. 기존에는 이 케이스가 여기서 분기되지 않아 InferType 폴백(vtInteger)으로
          // 떨어져 int32 슬롯으로 선언되고, 이후 "_getMB4c.ReturnType" 같은 멤버 접근이
          // cn=''인 원시타입 취급으로 "알 수 없는 메서드 \".ReturnType\""로 실패했다
          // (InferType 자기 자신의 본문에서 실제로 재현됨). GetExprClrType은 이미
          // TChainedIndexExprNode를 정확히 추론하므로(TArrayIndexExprNode/TExternalIndexExprNode와
          // 동일한 패턴) 재사용한다.
          var ivCixT100:=GetExprClrType(ivs.ValueExpr);
          if (ivCixT100<>nil) and (ivCixT100<>typeof(System.Object)) then
          begin
            ivClrType:=ivCixT100; ivIsExternal:=true; ivVt:=vtObject;
          end
          else ivClrType:=VTC(ivVt, '');
        end
        else if ivs.ValueExpr is TChainedMemberExprNode then
        begin
          // [자기컴파일 버그 수정] "var _strPi79:=typeof(string).GetProperty(mc.MethodName);"
          // 처럼 체인 식(Inner.Member 또는 Inner.Method(args))의 결과를 담는 지역 변수는
          // TChainedMemberExprNode로 파싱된다. 기존에는 이 케이스가 여기서 분기되지 않아
          // VTC(vtObject,'') 폴백(System.Object)으로 떨어졌다 — 그 결과 바로 다음 줄의
          // "_strPi79.GetGetMethod"가 "타입 System.Object에 메서드 GetGetMethod가 없습니다"로
          // 실패했다(자기컴파일 중 EmitExpr 자신의 소스에서 실제로 재현됨). GetExprClrType은
          // 이미 TChainedMemberExprNode를 정확히 추론하므로(TChainedIndexExprNode/TVarRefNode와
          // 동일한 패턴) 재사용한다.
          var ivChmT100:=GetExprClrType(ivs.ValueExpr);
          if (ivChmT100<>nil) and (ivChmT100<>typeof(System.Object)) then
          begin
            ivClrType:=ivChmT100; ivIsExternal:=true; ivVt:=vtObject;
          end
          else ivClrType:=VTC(ivVt, '');
        end
        else if ivs.ValueExpr is TVarRefNode then
        begin
          // [셀프 컴파일 버그 수정] "var _reflT100:=curType;"처럼 다른 지역/전역 변수를
          // 그대로 옮겨 담는 경우 — curType이 System.Type 같은 외부 CLR 타입으로 이미
          // fLocalScope/fGlobalScope에 SetClrType 되어 있어도, 위 분기들 중 어느 것과도
          // 안 맞아 곧장 VTC(vtObject,'') 폴백(System.Object)으로 떨어졌다. 그 결과
          // "_reflT100.GetField(...)"가 System.Object 위에서 GetField를 찾다가
          // "타입 System.Object에 메서드 GetField가 없습니다"로 실패했다. GetExprClrType은
          // 이미 TVarRefNode를 fLocalScope/fGlobalScope의 ClrType으로 정확히 추론하므로 재사용한다.
          var ivVrT:=GetExprClrType(ivs.ValueExpr);
          if (ivVrT<>nil) and (ivVrT<>typeof(System.Object)) then
          begin
            ivClrType:=ivVrT; ivIsExternal:=true; ivVt:=vtObject;
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
        end
        // [버그 수정] array of <외부 타입>(vtObjArray)/array of char·real·int64 등(vtGenericArray)으로
        // 명시적 타입 선언된 인라인 var("var mainParamTypes: array of System.Type;")는 위 분기가
        // vtObject/vtInterface만 걸러 SetClrType이 전혀 호출되지 않았다 — impl.LocalVars 등록
        // 루프(생성자/메서드/이터레이터/전역함수/전역프로시저 5곳)에 이미 적용한 것과 동일한
        // 이유로, 여기서도 등록이 빠지면 IsChainStartSegment가 이 변수를 체인 시작점으로
        // 인식 못해 "mainParamTypes.Length" 전체를 외부 정적 타입 이름으로 오인해 실패한다
        // (self-compile 중 TCodeGenerator.GenerateExe 자신의 소스에서 실제로 재현됨).
        else if (ivVt=vtObjArray) or (ivVt=vtGenericArray) then
          fLocalScope.SetClrType(ivs.VarName, ivClrType);
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
      else Result:=false;
    end;

    // [Stage 112 리팩터] EmitStatement가 self-compile 시 System.BadImageFormatException으로
    // 로드조차 안 되는 문제(단일 try/finally 안에 33개의 s-is 분기, 1800줄 이상이 들어있어
    // self-compile 코드생성기가 메서드 전체를 손상된 IL로 만드는 것으로 추정 — Stage 111의
    // ParsePrimary와 동일한 증상/원인)을 완화하기 위해, 재귀호출(EmitStatement 자기 자신을
    // 다시 부르는 제어흐름 분기)이 없는 분기들을 별도 함수로 분리했다. 로직은 원본과
    // 완전히 동일하다 — 처리했으면 True, 이 함수가 담당하지 않는 문장이면 False를 돌려준다.
    // ============================================================
    // [Stage 145 분할 - 자기컴파일 IL 손상 추가 수정] Stage 110 self 로그에서
    // EmitExprMethodCallBranch 분할(Stage 144) 이후 그 지점은 통과했지만, 바로 위
    // 호출부인 EmitStatementMethodCall(474줄, 그 안에 인라인 try/except 2곳까지 포함)에서
    // 정확히 같은 증상(BadImageFormatException, 스택 맨 위가 이 함수 자신)으로 다시 죽었다.
    // TMethodCallStmtNode 처리부 안의 최상위 if/else if 7갈래(원본과 100% 동일한 조건/순서)를
    // EmitMCB_*와 동일한 방식으로 각각 별도 함수로 뽑아내고, 인라인 try/except 2곳은
    // EmitExprMethodCallBranch 쪽에서 이미 쓰고 있는 SafeResolveExternalType/
    // SafeResolveOrEmitStaticChain을 그대로 재사용해 제거한다.
    // ============================================================

    // 갈래 1: mcs.ObjName이 점(.)으로 연결된 체인.
    procedure EmitSMC_QualifiedChain(aIL: ILGenerator; mcs: TMethodCallStmtNode);
    begin
          var chainSegs:=SplitByDot(mcs.ObjName);
          var chainType: System.Type;
          EmitQualifierChainLoad(aIL, chainSegs, chainType);

          // [Stage 79 수정] chainType이 아직 CreateType() 전인 로컬 클래스의 TypeBuilder이면
          // GetProperty가 NotSupportedException을 던진다 (예: f.Editor.OpenFile(...)에서
          // Editor 필드 타입 TCodeEditorPanel이 로컬 클래스인 경우). 2689번째 줄 근처의
          // 단일 필드 분기에 적용한 것과 동일한 우회를 여기(다중 세그먼트 체인)에도 적용한다.
          // [110번째 자기컴파일 버그 수정] 인라인 foreach 대신 FindLocalClassNameForTypeBuilder 재사용.
          var chainLocalCls:string:='';
          if chainType is TypeBuilder then
            chainLocalCls:=FindLocalClassNameForTypeBuilder(chainType);

          if chainLocalCls<>'' then
          begin
            var imbChain:=FindInstanceMethod(chainLocalCls, mcs.MethodName);
            if imbChain<>nil then
            begin
              EmitArgsCoerced(aIL, mcs.Args, FindInstanceMethodParamTypes(chainLocalCls, mcs.MethodName));
              aIL.Emit(OpCodes.Callvirt, imbChain);
              if imbChain.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end
            else if DictDictHas(fFieldBuilders, chainLocalCls, mcs.MethodName) then
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
    end;

    // 갈래 2: mcs.ObjName=='' - 암시적 self 호출.
    procedure EmitSMC_ImplicitSelfCall(aIL: ILGenerator; mcs: TMethodCallStmtNode);
    var imb: MethodBuilder; extType: System.Type; emi: MethodInfo;
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
              raise new Exception('외부 타입 "'+extType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: '+mcs.ObjName+'.'+mcs.MethodName+').');
            var _emiParams0:=emi.GetParameters;
            for var _emiAi0:=0 to mcs.Args.Count-1 do
              EmitArgForParamType(aIL, mcs.Args[_emiAi0], _emiParams0[_emiAi0].ParameterType);
            aIL.Emit(OpCodes.Callvirt, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
          end;
    end;

    // 갈래 3: "Result.Add(x);"처럼 함수 자신의 반환값(Result) 위에서 메서드 호출.
    procedure EmitSMC_ResultCall(aIL: ILGenerator; mcs: TMethodCallStmtNode);
    var qTargetType: System.Type;
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
    end;

    // 갈래 4: mcs.ObjName이 CLR 타입이 붙은 지역/전역 변수(sender 등).
    procedure EmitSMC_ClrTypedVar(aIL: ILGenerator; mcs: TMethodCallStmtNode);
    var emi: MethodInfo; qTargetType: System.Type;
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
              raise new Exception('타입 "'+qTargetType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: '+mcs.ObjName+'.'+mcs.MethodName+').');
            var _emiParams2:=emi.GetParameters;
            for var _emiAi2:=0 to mcs.Args.Count-1 do
              EmitArgForParamType(aIL, mcs.Args[_emiAi2], _emiParams2[_emiAi2].ParameterType);
            if _isValTypeS then aIL.Emit(OpCodes.Call, emi)
            else aIL.Emit(OpCodes.Callvirt, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
    end;

    // 갈래 5: mcs.ObjName이 (CLR 타입 아닌) 지역/전역 변수 또는 전역 const.
    procedure EmitSMC_LocalVarOrConst(aIL: ILGenerator; mcs: TMethodCallStmtNode);
    var imb: MethodBuilder; cn: string; vtVar: TVarType;
    begin
          // c.Init(10) → Ldloc c + args + Call
          cn:=GetVarClassName(mcs.ObjName);
          vtVar:=GetVarType(mcs.ObjName);
          if fLocalScope.Has(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(mcs.ObjName))
          else if fGlobalScope.Has(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(mcs.ObjName))
          else aIL.Emit(OpCodes.Ldsfld, fGlobalConstFields[mcs.ObjName]);  // [Stage 96] 전역 const
          if (cn='') and ((fLocalScope.Has(mcs.ObjName) and fLocalScope.HasClrType(mcs.ObjName))
                          or (fGlobalScope.Has(mcs.ObjName) and fGlobalScope.HasClrType(mcs.ObjName))) then
          begin
            // [자기컴파일 버그 수정] EmitExpr의 TMethodCallExprNode 쪽과 동일한 패턴 —
            // cn=''이지만 SetClrType으로 실제 CLR 타입이 기록돼 있는 vtObject 변수(예:
            // "var _mi4:=ResolveMethodByArity(...)"의 결과를 문장으로 호출하는 경우)는
            // 곧장 "알 수 없는 메서드"로 오인하지 말고 그 CLR 타입 기준으로 일반
            // 리플렉션 조회를 해야 한다.
            var _genClrS100: System.Type;
            if fLocalScope.Has(mcs.ObjName) and fLocalScope.HasClrType(mcs.ObjName) then
              _genClrS100:=fLocalScope.GetClrType(mcs.ObjName)
            else
              _genClrS100:=fGlobalScope.GetClrType(mcs.ObjName);
            var _genPiS100:=SafeGetProperty(_genClrS100, mcs.MethodName);
            if (mcs.Args.Count=0) and (_genPiS100<>nil) and (_genPiS100.GetGetMethod<>nil) then
            begin
              aIL.Emit(OpCodes.Callvirt, _genPiS100.GetGetMethod);
              aIL.Emit(OpCodes.Pop); // 프로퍼티 getter는 항상 값을 반환하므로 문장 컨텍스트에선 버림
            end
            else
            begin
              var _genMiS100:=ResolveMethodByArity(_genClrS100, mcs.MethodName, mcs.Args, false);
              if _genMiS100=nil then
                raise new Exception('타입 "'+_genClrS100.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: '+mcs.ObjName+'.'+mcs.MethodName+').');
              var _genMiParamsS100:=_genMiS100.GetParameters;
              for var _genAiS100:=0 to mcs.Args.Count-1 do
                EmitArgForParamType(aIL, mcs.Args[_genAiS100], _genMiParamsS100[_genAiS100].ParameterType);
              aIL.Emit(OpCodes.Callvirt, _genMiS100);
              if _genMiS100.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end;
          end
          else if cn='' then raise new Exception('알 수 없는 메서드 "'+mcs.ObjName+'.'+mcs.MethodName
            +'" (VarType='+GetVarType(mcs.ObjName).ToString+', 인자 '+mcs.Args.Count.ToString+'개)')
          else
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
                raise new Exception('알 수 없는 메서드 "'+mcs.ObjName+'.'+mcs.MethodName
                  +'" (cn="'+cn+'", 인자 '+mcs.Args.Count.ToString+'개)');
              var cnEmi:=ResolveMethodByArity(cnExtType, mcs.MethodName, mcs.Args, false);
              if cnEmi=nil then
                raise new Exception('외부 타입 "'+cnExtType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: '+mcs.ObjName+'.'+mcs.MethodName+').');
              var cnEmiParams:=cnEmi.GetParameters;
              for var cnEmiAi:=0 to mcs.Args.Count-1 do
                EmitArgForParamType(aIL, mcs.Args[cnEmiAi], cnEmiParams[cnEmiAi].ParameterType);
              aIL.Emit(OpCodes.Callvirt, cnEmi);
              if cnEmi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end;
          end;
    end;

    // 갈래 6: mcs.ObjName이 현재 클래스의 필드.
    procedure EmitSMC_FieldBuilder(aIL: ILGenerator; mcs: TMethodCallStmtNode; qfb: FieldBuilder);
    var emi: MethodInfo; qTargetType: System.Type;
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
          // [110번째 자기컴파일 버그 수정] 인라인 foreach 대신 FindLocalClassNameForTypeBuilder 재사용.
          var localClsNameFB:string:='';
          if qTargetType is TypeBuilder then
            localClsNameFB:=FindLocalClassNameForTypeBuilder(qTargetType);

          if localClsNameFB<>'' then
          begin
            var imbFB: MethodBuilder;
            if TryFindInstanceMethod(localClsNameFB, mcs.MethodName, imbFB) then
            begin
              EmitArgsCoerced(aIL, mcs.Args, FindInstanceMethodParamTypes(localClsNameFB, mcs.MethodName));
              aIL.Emit(OpCodes.Callvirt, imbFB);
              if imbFB.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end
            else if DictDictHas(fFieldBuilders, localClsNameFB, mcs.MethodName) then
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
                  raise new Exception('로컬 클래스 "'+localClsNameFB+'"(외부 조상 "'+_extAncFB94.FullName+'")에 메서드/필드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: '+mcs.ObjName+'.'+mcs.MethodName+').');
                var _emiParamsFB94:=_emiFB94.GetParameters;
                for var _emiAiFB94:=0 to mcs.Args.Count-1 do
                  EmitArgForParamType(aIL, mcs.Args[_emiAiFB94], _emiParamsFB94[_emiAiFB94].ParameterType);
                aIL.Emit(OpCodes.Callvirt, _emiFB94);
                if _emiFB94.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
              end;
            end
            else
              raise new Exception('로컬 클래스 "'+localClsNameFB+'"에 메서드/필드 "'+mcs.MethodName+'"가 없습니다 (경로: '+mcs.ObjName+'.'+mcs.MethodName+').');
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
                raise new Exception('타입 "'+qTargetType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: '+mcs.ObjName+'.'+mcs.MethodName+').');
              var _emiParams3:=emi.GetParameters;
              for var _emiAi3:=0 to mcs.Args.Count-1 do
                EmitArgForParamType(aIL, mcs.Args[_emiAi3], _emiParams3[_emiAi3].ParameterType);
              aIL.Emit(OpCodes.Callvirt, emi);
              if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
            end;
          end;
    end;

    // 갈래 7: mcs.ObjName이 self가 상속한 외부 타입의 프로퍼티(예: "Controls.Add(...)").
    procedure EmitSMC_ExternalAncestorProp(aIL: ILGenerator; mcs: TMethodCallStmtNode);
    var extType: System.Type; propInfo: PropertyInfo; emi: MethodInfo; qTargetType: System.Type;
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
              raise new Exception('타입 "'+qTargetType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: '+mcs.ObjName+'.'+mcs.MethodName+').');
            var _emiParams5:=emi.GetParameters;
            for var _emiAi5:=0 to mcs.Args.Count-1 do
              EmitArgForParamType(aIL, mcs.Args[_emiAi5], _emiParams5[_emiAi5].ParameterType);
            aIL.Emit(OpCodes.Callvirt, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
    end;

    // 갈래 8(폴백): 외부 타입의 정적(static) 멤버 호출. 원래 인라인 try/except 2곳이 있었으나
    // SafeResolveExternalType/SafeResolveOrEmitStaticChain(EmitExprMethodCallBranch에서
    // 이미 쓰는 헬퍼)을 재사용해 try/except 없이 동일한 동작을 낸다.
    procedure EmitSMC_StaticFallback(aIL: ILGenerator; mcs: TMethodCallStmtNode);
    var extType: System.Type; emi: MethodInfo;
    begin
          // 로컬/전역 변수가 아니면 System.Windows.Forms.Application.Run(f) 처럼
          // 외부 타입의 정적(static) 멤버 호출로 간주한다. 정적 호출은 인스턴스를
          // 먼저 로드하지 않고 인자만 쌓은 뒤 Call(비가상)로 호출한다.
          // [버그 수정] "System.Console.Out.Flush;"처럼 한정자 경로 중간에 무인자
          // 정적 프로퍼티/메서드(Out)가 섞인 문장 호출은, ObjName 전체("System.Console.Out")가
          // 그 자체로는 타입이 아니라서 ResolveExternalType이 곧장 실패했다(자기컴파일 중
          // TCodeGenerator.LogGenStep의 "System.Console.Out.Flush;"에서 실제 재현됨). EmitExpr의
          // TMethodCallExprNode 쪽(약 354행, _staticTE=nil일 때 ResolveOrEmitStaticChain 재시도)과
          // 동일한 로직을 문장 위치에도 적용한다 — 성공하면 이미 체인 앞부분의 IL(Out 프로퍼티
          // getter 호출 등)이 방출되어 스택에 인스턴스가 로드된 상태이므로, 이후 mcs.MethodName은
          // 정적이 아니라 인스턴스 멤버로 호출해야 한다.
          // [Stage 145 버그 수정] 인라인 try/except 2곳을 EmitExprMethodCallBranch 쪽에서
          // 이미 쓰고 있는 SafeResolveExternalType/SafeResolveOrEmitStaticChain으로 교체 —
          // 이 프로젝트에서 반복 확인된 "큰 함수 + try/except 동거" 패턴을 예방한다.
          var _stmtStaticT: System.Type := SafeResolveExternalType(mcs.ObjName);
          var _stmtIsInst: boolean := false;
          if _stmtStaticT=nil then
            _stmtStaticT:=SafeResolveOrEmitStaticChain(aIL, mcs.ObjName, _stmtIsInst);

          if _stmtStaticT=nil then
            raise new Exception('외부 타입 "'+mcs.ObjName+'"을(를) 찾을 수 없습니다. 기본 프레임워크(WinForms/WPF/System.*)가 아니라면 {$reference 어셈블리명.dll} 지시문으로 해당 타입이 들어있는 어셈블리를 먼저 등록했는지 확인하세요.');

          extType:=_stmtStaticT;
          var _stmtGetP:=SafeGetProperty(extType, mcs.MethodName);
          if (mcs.Args.Count=0) and (_stmtGetP<>nil) and (_stmtGetP.GetGetMethod<>nil) then
          begin
            if _stmtIsInst then aIL.Emit(OpCodes.Callvirt, _stmtGetP.GetGetMethod)
            else aIL.Emit(OpCodes.Call, _stmtGetP.GetGetMethod);
            if _stmtGetP.PropertyType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            emi:=ResolveMethodByArity(extType, mcs.MethodName, mcs.Args, not _stmtIsInst);
            if emi=nil then
            begin
              var _stmtKindDesc:='';
              if not _stmtIsInst then _stmtKindDesc:='정적 ';
              raise new Exception('외부 타입 "'+extType.FullName+'"에 '+_stmtKindDesc+'메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개, 경로: '+mcs.ObjName+'.'+mcs.MethodName+').');
            end;
            var _emiParams4:=emi.GetParameters;
            for var _emiAi4:=0 to mcs.Args.Count-1 do
              EmitArgForParamType(aIL, mcs.Args[_emiAi4], _emiParams4[_emiAi4].ParameterType);
            if _stmtIsInst then aIL.Emit(OpCodes.Callvirt, emi)
            else aIL.Emit(OpCodes.Call, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
    end;

    // [Stage 112] EmitStatement에서 재귀호출 없는 분기를 뽑아낸 함수 중 하나 — TMethodCallStmtNode
    // 처리부만 담당. 로직은 원본과 완전히 동일 — 처리했으면 True, 아니면 False.
    // [Stage 145] 내부의 7갈래 if/else if를 각각 별도 함수로 분리 — 이 함수는 조건을 그대로
    // 재평가해 알맞은 함수를 호출하는 얇은 디스패처만 남긴다.
    function EmitStatementMethodCall(aIL: ILGenerator; s: TStmtNode): boolean;
    var mcs: TMethodCallStmtNode; qfb145: FieldBuilder; imb145: MethodBuilder;
    begin
      Result:=true;
      if s is TMethodCallStmtNode then
      begin
        mcs:=TMethodCallStmtNode(s);
        if (mcs.ObjName<>'') and (mcs.ObjName.IndexOf('.')>=0) and (mcs.ObjCastType='')
           and IsChainStartSegment(SplitByDot(mcs.ObjName)[0]) then
          EmitSMC_QualifiedChain(aIL, mcs)
        else if mcs.ObjName='' then
          EmitSMC_ImplicitSelfCall(aIL, mcs)
        else if (mcs.ObjName='Result') and (fResultLocal<>nil) then
          EmitSMC_ResultCall(aIL, mcs)
        else if (fLocalScope.Has(mcs.ObjName) or fGlobalScope.Has(mcs.ObjName))
                and (fLocalScope.HasClrType(mcs.ObjName) or fGlobalScope.HasClrType(mcs.ObjName)) then
          EmitSMC_ClrTypedVar(aIL, mcs)
        else if fLocalScope.Has(mcs.ObjName) or fGlobalScope.Has(mcs.ObjName)
                or fGlobalConstFields.ContainsKey(mcs.ObjName) then
          EmitSMC_LocalVarOrConst(aIL, mcs)
        else if TryFindFieldBuilder(fCurClassName, mcs.ObjName, qfb145) then
          EmitSMC_FieldBuilder(aIL, mcs, qfb145)
        else if (FindExternalAncestorType(fCurClassName)<>nil)
                and (SafeGetProperty(FindExternalAncestorType(fCurClassName), mcs.ObjName)<>nil) then
          EmitSMC_ExternalAncestorProp(aIL, mcs)
        else
          EmitSMC_StaticFallback(aIL, mcs);
      end
      else Result:=false;
    end;

    // 완전히 동일하다 — 처리했으면 True, 이 함수가 담당하지 않는 문장이면 False를 돌려준다.
    function EmitStatementDataOps2(aIL: ILGenerator; s: TStmtNode): boolean;
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
      Result:=true;
      if s is TEventSubscribeStmtNode then
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
        var aaElemClrType: System.Type; // [Stage 107 버그 수정]
        var aaVarClrType: System.Type := nil; // [자기컴파일 버그 수정 2026.08] 진짜 배열인지 판별용
        if fGlobalScope.Has(aa.ArrName) then
        begin
          at2:=fGlobalScope.GetVType(aa.ArrName);
          aaVarClrType:=fGlobalScope.GetLoc(aa.ArrName).LocalType;
          aaElemClrType:=SafeArrayElemType(aaVarClrType);
        end
        else if fLocalScope.Has(aa.ArrName) then
        begin
          at2:=fLocalScope.GetVType(aa.ArrName);
          aaVarClrType:=fLocalScope.GetLoc(aa.ArrName).LocalType;
          aaElemClrType:=SafeArrayElemType(aaVarClrType);
        end
        else if TryFindFieldBuilder(fCurClassName, aa.ArrName, aaFb) then
        begin
          if IsRefElementType(aaFb.FieldType) then // [Stage 96 버그 수정] TypeBuilderInstantiation 예외 흡수
            at2:=vtStrArray
          else
            at2:=vtIntArray;
          aaVarClrType:=aaFb.FieldType;
          aaElemClrType:=SafeArrayElemType(aaVarClrType);
        end
        else
          raise new Exception('알 수 없는 변수 "'+aa.ArrName+'" (배열 대입 대상을 지역/전역 변수도, "'
            +fCurClassName+'" 클래스의 필드도 아닌 곳에서 찾을 수 없습니다).');
        if fLocalScope.Has(aa.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocalScope.GetLoc(aa.ArrName))
        else if fGlobalScope.Has(aa.ArrName) then aIL.Emit(OpCodes.Ldloc, fGlobalScope.GetLoc(aa.ArrName))
        else begin aIL.Emit(OpCodes.Ldarg_0); aIL.Emit(OpCodes.Ldfld, aaFb); end;
        // [자기컴파일 버그 수정 2026.08] ArrName이 진짜 CLR 배열(T[])이 아니라 List<T>/
        // Dictionary 등 "Item" 인덱서를 쓰는 외부 제네릭 컬렉션이면(예: lst[0] := s;), 지금까지는
        // 이 사실을 확인하지 않고 무조건 Stelem_*를 방출해 컬렉션 객체 참조를 마치 SZArray인
        // 것처럼 덮어썼다. 이는 검증 불가능한 IL이라 실행 시 예외로 잡히지 못하고 네이티브
        // 접근 위반(0xc0000005, clr.dll 크래시)으로 죽거나 힙을 조용히 손상시킨다. 읽기 쪽
        // EmitIndexerGet과 대칭되는 "Item" 세터를 리플렉션으로 찾아 위임한다(패턴은 위
        // TExternalDoubleIndexAssignStmtNode의 두 번째 단계 set_Item 처리와 동일).
        if (aaVarClrType<>nil) and (not aaVarClrType.IsArray) then
        begin
          var aaIdxArgType:=InferArgClrType(aa.Index);
          var aaItemProp: PropertyInfo := nil;
          var aaBestScore:=System.Int32.MinValue;
          if aaVarClrType.GetType().Name = 'TypeBuilderInstantiation' then
          begin
            var aaSafeProp:=SafeGetProperty(aaVarClrType, 'Item');
            if (aaSafeProp<>nil) and (aaSafeProp.GetSetMethod<>nil) then aaItemProp:=aaSafeProp;
          end
          else
            foreach var aaCand in aaVarClrType.GetProperties(BindingFlags.Public or BindingFlags.Instance) do
            begin
              if (aaCand.Name='Item') and (aaCand.GetIndexParameters.Length=1) and (aaCand.GetSetMethod<>nil) then
              begin
                var aaScore:=ScoreParamMatch(aaCand.GetIndexParameters()[0].ParameterType, aaIdxArgType);
                if (aaItemProp=nil) or (aaScore>aaBestScore) then
                begin aaBestScore:=aaScore; aaItemProp:=aaCand; end;
              end;
            end;
          if aaItemProp=nil then
            raise new Exception('타입 "'+aaVarClrType.FullName+'"에는 인덱서(Item) 세터가 없습니다. (변수 "'+aa.ArrName+'")');
          var aaIdxParams:=aaItemProp.GetIndexParameters();
          EmitArgForParamType(aIL, aa.Index, aaIdxParams[0].ParameterType);
          EmitArgForParamType(aIL, aa.ValueExpr, aaItemProp.PropertyType);
          aIL.Emit(OpCodes.Callvirt, aaItemProp.GetSetMethod);
        end
        else
        begin
          // [Stage 57] arr[i] := 'a'; 에서 arr가 문자열 배열이면 char 리터럴을 문자열로
          // 승격해야 한다 — 안 그러면 정수(문자코드)가 그대로 Stelem_Ref로 들어가
          // 힙 참조로 오인되어 GC/접근 시 크래시가 난다.
          EmitExpr(aIL, aa.Index);
          if at2=vtStrArray then EmitValueForVType(aIL, aa.ValueExpr, vtString)
          else if (aaElemClrType<>nil) and (aaElemClrType=typeof(char)) then EmitValueForVType(aIL, aa.ValueExpr, vtChar)
          else if (aaElemClrType<>nil) and (aaElemClrType=typeof(double)) then EmitValueForVType(aIL, aa.ValueExpr, vtReal)
          else if (aaElemClrType<>nil) and (aaElemClrType=typeof(int64)) then EmitValueForVType(aIL, aa.ValueExpr, vtInt64)
          else EmitExpr(aIL, aa.ValueExpr);
          // [Stage 90] array of object 원소 쓰기도 문자열과 마찬가지로 참조 타입이라 Stelem_Ref.
          // [Stage 107 버그 수정] 읽기 쪽(TArrayIndexExprNode)과 동일한 이유 — 값 타입 원소를
          // 전부 Stelem_I4(4바이트 폭)로 쓰면 char/real/int64 배열은 stride가 틀어져 배열
          // 밖의 메모리를 덮어써 힙을 손상시킨다(느리게 발현되는 AccessViolationException/
          // 손상의 근본 원인이 되기 쉽다). 실제 CLR 원소 타입(aaElemClrType)을 보고 고른다.
          if (at2=vtStrArray) or (at2=vtObjArray) or ((aaElemClrType<>nil) and not aaElemClrType.IsValueType) then
            aIL.Emit(OpCodes.Stelem_Ref)
          else if (aaElemClrType<>nil) and (aaElemClrType=typeof(char)) then
            aIL.Emit(OpCodes.Stelem_I2)
          else if (aaElemClrType<>nil) and (aaElemClrType=typeof(double)) then
            aIL.Emit(OpCodes.Stelem_R8)
          else if (aaElemClrType<>nil) and (aaElemClrType=typeof(single)) then
            aIL.Emit(OpCodes.Stelem_R4)
          else if (aaElemClrType<>nil) and (aaElemClrType=typeof(int64)) then
            aIL.Emit(OpCodes.Stelem_I8)
          else
            aIL.Emit(OpCodes.Stelem_I4);
        end;
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
        // [버그 수정] ediaInnerType이 TypeBuilderInstantiation(원소가 아직 CreateType 안 된
        // 로컬 클래스인 제네릭 컬렉션)이면 GetProperties가 NotSupportedException을 던진다 —
        // InferIndexerResultType과 동일한 이유로 SafeGetProperty(TBoundGenericPropertyInfo
        // 우회)로 위임한다. 일반 BCL 컬렉션은 기존과 동일하게 동작한다(SafeGetProperty가
        // TypeBuilderInstantiation이 아니면 t.GetProperty(name)으로 폴백).
        if ediaInnerType.GetType().Name = 'TypeBuilderInstantiation' then
        begin
          var ediaSafeProp:=SafeGetProperty(ediaInnerType, 'Item');
          if (ediaSafeProp<>nil) and (ediaSafeProp.GetSetMethod<>nil) then ediaItemProp:=ediaSafeProp;
        end
        else
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
          raise new Exception('타입 "'+eimcInnerType.FullName+'"에 메서드 "'+eimc.MethodName+'"가 없습니다 (인자 '+eimc.Args.Count.ToString+'개, 경로: '+eimc.Qualifier+'.'+eimc.MethodName+').');
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
        // [자기컴파일 버그 수정] eifaInnerType이 아직 CreateType 안 된 로컬 클래스의
        // TypeBuilder면 .GetField(name, BindingFlags) 2개짜리 오버로드가 NotSupportedException을
        // 던진다(실제 사례: TScope.SetClassName) — SafeGetField로 우회한다.
        var eifaFi:=SafeGetField(eifaInnerType, eifa.FieldName);
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

      // [자기컴파일 버그 수정] 인자 있는 암시적 self 메서드 호출의 반환값에 필드/프로퍼티
      // 대입: GetOrCreate(cn).ParentName := pn; — 위 TExternalIndexFieldAssignStmtNode와
      // 형제 노드다. self(Ldarg_0)로 로컬 메서드를 호출해 반환값을 스택에 남겨 두고,
      // 그 반환 타입(아직 CreateType 안 된 로컬 클래스일 수 있음 — SafeGetField/
      // SafeGetProperty로 우회)에서 필드를 먼저 찾고 없으면 프로퍼티 세터로 폴백한다.
      // 로컬 메서드가 아니면(외부 상속 타입 메서드) FindExternalAncestorType로 폴백한다.
      else if s is TSelfCallFieldAssignStmtNode then
      begin
        var scfa:=TSelfCallFieldAssignStmtNode(s);
        aIL.Emit(OpCodes.Ldarg_0); // self
        var scfaRetType: System.Type;
        if TryFindInstanceMethod(fCurClassName, scfa.MethodName, imb) then
        begin
          EmitArgsCoerced(aIL, scfa.Args, FindInstanceMethodParamTypes(fCurClassName, scfa.MethodName));
          aIL.Emit(OpCodes.Callvirt, imb);
          scfaRetType:=imb.ReturnType;
        end
        else
        begin
          extType:=FindExternalAncestorType(fCurClassName);
          if extType=nil then
            raise new Exception('알 수 없는 메서드 "'+fCurClassName+'.'+scfa.MethodName+'"');
          emi:=ResolveMethodByArity(extType, scfa.MethodName, scfa.Args, false);
          if emi=nil then
            raise new Exception('외부 타입 "'+extType.FullName+'"에 메서드 "'+scfa.MethodName+'"가 없습니다 (인자 '+scfa.Args.Count.ToString+'개).');
          var scfaParams:=emi.GetParameters;
          for var scfaAi:=0 to scfa.Args.Count-1 do
            EmitArgForParamType(aIL, scfa.Args[scfaAi], scfaParams[scfaAi].ParameterType);
          aIL.Emit(OpCodes.Callvirt, emi);
          scfaRetType:=emi.ReturnType;
        end;
        if scfaRetType=typeof(System.Void) then
          raise new Exception('메서드 "'+scfa.MethodName+'"는 반환값이 없어 그 결과의 필드/프로퍼티에 대입할 수 없습니다.');
        var scfaFi:=SafeGetField(scfaRetType, scfa.FieldName);
        if scfaFi<>nil then
        begin
          EmitArgForParamType(aIL, scfa.ValueExpr, scfaFi.FieldType);
          aIL.Emit(OpCodes.Stfld, scfaFi);
        end
        else
        begin
          var scfaPi:=SafeGetProperty(scfaRetType, scfa.FieldName);
          if (scfaPi=nil) or (scfaPi.GetSetMethod=nil) then
            raise new Exception('타입 "'+scfaRetType.FullName+'"에 필드/프로퍼티 "'+scfa.FieldName+'"가 없습니다.');
          EmitArgForParamType(aIL, scfa.ValueExpr, scfaPi.PropertyType);
          aIL.Emit(OpCodes.Callvirt, scfaPi.GetSetMethod);
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
      else Result:=false;
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
      handled: boolean;
    begin
      fEmitDepth:=fEmitDepth+1;
      if fEmitDepth>5000 then
        raise new Exception('[진단] EmitStatement 재귀 깊이 초과(5000) — 폭주 의심 노드: '+s.GetType.Name);
      try
      // [Stage 112 리팩터] 재귀 없는 분기는 EmitStatementDataOps1/EmitStatementMethodCall/
      // EmitStatementDataOps2로 이동했다 — 이 메서드에는 자기 자신을 재귀 호출하는
      // 제어흐름 계열 분기만 남겨서 메서드 크기를 줄였다 (BadImageFormatException 대응).
      handled:=EmitStatementDataOps1(aIL, s);
      if not handled then handled:=EmitStatementMethodCall(aIL, s);
      if not handled then handled:=EmitStatementDataOps2(aIL, s);
      if not handled then
      begin
      if s is TCompoundStmtNode then
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
        else
        begin
          // [Stage 102 버그 수정] "for var i:=A to B do" — Parser.pas가 카운터 변수를 var
          // 섹션이 아니라 for문 자리에서 바로 선언하는 문법(Parser.pas Stage 101 주석 참고)을
          // 지원하지만, 그 이름은 fCurParams(파서 자체의 이름 인식용 목록)에만 등록되고
          // impl.LocalVars(실제 지역변수 선언 목록)에는 추가되지 않는다 — 그래서 CodeGen은
          // 지금까지 "이 변수는 항상 미리 선언돼 있다"고 가정해 "for 변수 선언 안 됨"으로
          // 실패했다(셀프호스팅 컴파일 실제 사례 — 이 파일 자체에 "for var X:=0 to N do"
          // 형태가 수백 곳에 쓰인다). for 카운터는 언어 문법상 항상 정수이므로, 여기서
          // 즉석으로 정수 로컬을 만들어 등록한다.
          forVarLoc:=aIL.DeclareLocal(typeof(integer));
          fLocalScope.Declare(fs.VarName, forVarLoc, vtInteger);
        end;
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
        var forInVarClrType: System.Type;
        if fLocalScope.Has(fis.VarName) then
        begin
          forInVarLoc:=fLocalScope.GetLoc(fis.VarName);
          forInVarClrType:=VTC(GetVarType(fis.VarName), GetVarClassName(fis.VarName));
        end
        else if fGlobalScope.Has(fis.VarName) then
        begin
          forInVarLoc:=fGlobalScope.GetLoc(fis.VarName);
          forInVarClrType:=VTC(GetVarType(fis.VarName), GetVarClassName(fis.VarName));
        end
        else
        begin
          // [Stage 102 버그 수정] "foreach var x in y do" — 위 TForStmtNode와 동일한 사유로
          // 순회 변수가 미리 선언돼 있지 않다. 이 변수의 타입은 카운터와 달리 컬렉션의 실제
          // 원소 타입에서 추론해야 한다: 배열이면 GetElementType, 제네릭 컬렉션(List<T>/
          // IEnumerable<T> 등, 예: "foreach var ns in namespaceList do")이면 첫 번째 타입
          // 인자, 그 외(비제네릭 컬렉션 등)는 object로 폴백한다 — 아래의 기존 Current
          // Unbox_Any/Castclass 로직이 forInVarClrType을 그대로 쓰므로 그것과 맞아떨어진다.
          //
          // [버그 수정] Dictionary<TKey,TValue>(및 SortedDictionary/SortedList/IDictionary/
          // IReadOnlyDictionary 등 TKey,TValue 2개짜리 딕셔너리류)는 실제로는
          // KeyValuePair<TKey,TValue>를 순회한다 — "그 외 제네릭 컬렉션은 첫 번째 타입
          // 인자" 규칙을 그대로 적용하면 원소 타입이 TKey(예: string)로 잘못 추론되어,
          // 그 뒤 ".Value"/".Key" 접근이 "System.String에 메서드가 없습니다"로 깨진다
          // (예: foreach var kv in fTypeBuilders do ... kv.Value ... — fTypeBuilders:
          // Dictionary<string, TypeBuilder>). GetGenericArguments()[0]을 쓰기 전에
          // 딕셔너리류인지 먼저 판별해 KeyValuePair<TKey,TValue>를 조립한다.
          var forInCollType102:=GetExprClrType(fis.CollExpr);
          if (forInCollType102<>nil) and forInCollType102.IsArray then
            forInVarClrType:=forInCollType102.GetElementType
          else if (forInCollType102<>nil) and forInCollType102.IsGenericType
             and (forInCollType102.GetGenericArguments.Length=2)
             and IsDictionaryLikeType102(forInCollType102) then
            forInVarClrType:=typeof(System.Collections.Generic.KeyValuePair<System.Object,System.Object>)
              .GetGenericTypeDefinition.MakeGenericType(forInCollType102.GetGenericArguments)
          else if (forInCollType102<>nil) and forInCollType102.IsGenericType
             and (forInCollType102.GetGenericArguments.Length>=1) then
            forInVarClrType:=forInCollType102.GetGenericArguments()[0]
          else
            forInVarClrType:=typeof(System.Object);
          forInVarLoc:=aIL.DeclareLocal(forInVarClrType);
          var forInVt102:=VarTypeTagFromClrType(forInVarClrType);
          fLocalScope.Declare(fis.VarName, forInVarLoc, forInVt102);
          if forInVt102=vtObject then fLocalScope.SetClrType(fis.VarName, forInVarClrType);
          // [버그 수정] foreach 원소 타입이 로컬(자기 자신 소스에 정의된) 클래스의
          // TypeBuilder일 때 SetClrType만 등록하고 SetClassName은 등록하지 않아서,
          // InferType이 HasClrType 분기(리플렉션 프로퍼티/메서드만 확인, 로컬 클래스의
          // FieldBuilder 필드는 못 찾음)로 먼저 걸려버렸다. 그 결과 "foreach var ps in
          // list_of_local_class do ... ps.StringField ..." 형태의 문자열 필드 읽기가
          // vtInteger로 오판되어 Convert.ToString(int32)가 문자열 참조 위에 잘못 호출되고,
          // self-host 빌드 시 그 메서드의 IL 자체가 스택 타입 불일치로 깨져
          // BadImageFormatException을 유발했다 (실제 사례: BuildClassShell_Properties의
          // "foreach var ps in cd.Properties do ... ps.Name ..."). 일반 매개변수/지역변수와
          // 동일하게 SetClassName도 등록해 TryFindFieldBuilder 경로를 타게 한다.
          if forInVarClrType is TypeBuilder then
          begin
            // [110번째 자기컴파일 버그 수정] 인라인 foreach 대신 FindLocalClassNameForTypeBuilder 재사용.
            var _forInLocalCls102:=FindLocalClassNameForTypeBuilder(forInVarClrType);
            if _forInLocalCls102<>'' then
              fLocalScope.SetClassName(fis.VarName, _forInLocalCls102);
          end;
        end;

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
        // [버그 수정] 중첩된 try/except가 서로 같은 이름(예: 'ex')의 예외 변수를 쓰면
        // (자기 완결 컴파일러 테스트에서 실제로 발생 — 바깥 try의 본문 안에 또 다른
        // try...except on ex: Exception do ... 가 들어있는 경우), 안쪽 try가 끝나며
        // fLocalScope에서 'ex'를 무조건 지워버려서(Remove) 바깥쪽 try의 예외 변수까지
        // 함께 사라졌다 — 그 뒤 바깥쪽 except 블록이 ex.Message를 쓰면 "선언되지 않은
        // 예외 변수 ex" 오류로 이어졌다. 진입 전에 같은 이름의 항목이 이미 있었는지
        // 저장해두고, 이 try가 끝나면 무조건 지우는 대신 바깥쪽 항목을 그대로 복원한다
        // (없었으면 기존처럼 제거).
        var hadPrevExEntry:=false;
        var prevExLoc: LocalBuilder := nil;
        var prevExVType: TVarType := vtString;
        var prevExClassName: string := '';
        var prevExClrType: System.Type := nil;
        if (ts2.ExVarName<>'') and (ts2.ExceptStmts<>nil) then
        begin
          if fLocalScope.Has(ts2.ExVarName) then
          begin
            hadPrevExEntry:=true;
            prevExLoc:=fLocalScope.GetLoc(ts2.ExVarName);
            prevExVType:=fLocalScope.GetVType(ts2.ExVarName);
            prevExClassName:=fLocalScope.GetClassName(ts2.ExVarName);
            prevExClrType:=fLocalScope.GetClrType(ts2.ExVarName);
          end;
          exLoc:=aIL.DeclareLocal(typeof(Exception));
          fLocalScope.Declare(ts2.ExVarName, exLoc, vtString); // 내부 타입은 string으로 (Message는 string)
          // [Stage 49] .Message는 TExceptionMsgExprNode가 전용으로 처리하지만, .ToString()
          // 같은 다른 멤버는 이게 없으면 "외부 타입 로컬 변수" 경로를 못 타서
          // "알 수 없는 메서드"로 막혔다 — 실제 예외 객체 타입을 등록해 리플렉션 경로를 열어준다.
          fLocalScope.SetClrType(ts2.ExVarName, typeof(Exception));
        end;

        // [버그 수정 - ildasm으로 확인됨] try가 if/else(또는 case, loop 등) 분기의 "첫 번째 문장"이면,
        // 그 분기 진입을 위해 밖에서 뛰어드는 브랜치(brfalse/br 등)의 목적지가 .try 블록의 바로 그
        // 첫 명령과 겹쳐버린다. CLR은 보호영역(try/catch/finally)에 "낙하(fall-through)"로만 진입할 수
        // 있고 브랜치로 뛰어드는 것은 불법이라, JIT가 이 메서드를 로드하는 순간 BadImageFormatException을
        // 던진다 (실제 재현: InferTypeMethodCall, self-host 빌드). Nop을 완충 지점으로 하나 끼워 넣으면
        // 바깥의 브랜치는 이 Nop을 목적지로 삼고, .try는 그다음 명령을 낙하로 자연스럽게 얻는다.
        aIL.Emit(OpCodes.Nop);
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

        // 예외 변수 이름을 로컬 스코프에서 정리 (스코프 종료)
        if (ts2.ExVarName<>'') and (ts2.ExceptStmts<>nil) then
        begin
          if hadPrevExEntry then
          begin
            // 바깥쪽(또는 이전) 항목 복원 — 같은 이름을 재사용하는 중첩/연속 try가
            // 서로를 지우지 않도록 한다.
            fLocalScope.Declare(ts2.ExVarName, prevExLoc, prevExVType);
            if prevExClassName<>'' then fLocalScope.SetClassName(ts2.ExVarName, prevExClassName);
            if prevExClrType<>nil then fLocalScope.SetClrType(ts2.ExVarName, prevExClrType);
          end
          else
            fLocalScope.Remove(ts2.ExVarName); // 이전에 없었으면 그냥 제거
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
      end;
      finally
        fEmitDepth:=fEmitDepth-1;
      end;
    end;

    // 메서드 시그니처의 i번째 매개변수의 실제 CLR 타입을 결정한다 (기본/지역클래스/외부타입 모두 포함)
    // [Stage 100] var/const 참조 매개변수는 CLR ByRef 타입(예: string&)으로 내보낸다.
    // ByRef 타입이면 원소(실제 값) 타입을, 아니면 그대로 돌려준다 — 로컬 슬롯 선언, 역참조
    // 읽기(Ldobj)/역참조 쓰기(Stobj)에서 실제 값 타입이 필요할 때 이 함수를 거친다.