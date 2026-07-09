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
  AST;

type
  TCodeGenerator = class
  private
    fProg: TProgramNode;

    // 전역 변수
    fGlobals:     Dictionary<string, LocalBuilder>;
    fGlobalTypes: Dictionary<string, TVarType>;
    fGlobalClass: Dictionary<string, string>; // 변수명 → 클래스명

    // 현재 함수/메서드 로컬 변수
    fLocals:      Dictionary<string, LocalBuilder>;
    fLocalTypes:  Dictionary<string, TVarType>;
    fLocalClrTypes: Dictionary<string, System.Type>; // object/외부타입 지역변수·매개변수의 실제 CLR 타입

    // 일반 static 함수/프로시저
    fMethods:     Dictionary<string, MethodBuilder>;
    fFuncReturnTypes: Dictionary<string, TVarType>; // [Stage 27] 최상위 함수명 → 반환타입 (InferType이 함수 호출식의 타입을 알 수 있도록)

    // 클래스 관련
    fTypeBuilders: Dictionary<string, TypeBuilder>;  // 클래스명 → TypeBuilder
    fBuiltTypes:   Dictionary<string, System.Type>;  // 클래스명 → 완성된 Type
    fFieldBuilders: Dictionary<string, Dictionary<string, FieldBuilder>>; // 클래스명 → 필드명 → FieldBuilder
    fInstanceMethods: Dictionary<string, Dictionary<string, MethodBuilder>>; // 클래스명 → 메서드명 → MB
    fClassParents: Dictionary<string, string>; // 클래스명 → 부모 클래스명 ('' 이면 없음)
    fMethodReturnTypes: Dictionary<string, Dictionary<string, TVarType>>; // 클래스명/인터페이스명 → 메서드명 → 반환타입
    fMethodParamClrTypes: Dictionary<string, Dictionary<string, array of System.Type>>; // 클래스명 → 메서드명 → 매개변수 CLR 타입 배열
    fCtorBuilders: Dictionary<string, ConstructorBuilder>; // 클래스명 → 기본 생성자 (CreateType 전에도 참조 가능하도록 보관)

    // 외부 .NET 어셈블리 (WPF/WinForm/Avalonia 등) — GenerateExe 전에 AddReferenceAssembly로 채워짐
    fLoadedAssemblies: List<Assembly>;
    // 클래스명 → 그 클래스가 직접 상속한 "외부" 부모의 실제 System.Type
    // (외부 타입 자신의 조상 체인은 Reflection이 알아서 다 검색해주므로 1단계만 기록하면 충분)
    fClassExternalParentType: Dictionary<string, System.Type>;

    // 인터페이스 관련 (클래스보다 먼저 완전히 빌드됨)
    fInterfaceBuilders: Dictionary<string, TypeBuilder>;  // 인터페이스명 → TypeBuilder
    fBuiltInterfaces:   Dictionary<string, System.Type>;  // 인터페이스명 → 완성된 Type

    // 현재 메서드 컨텍스트
    fResultLocal:  LocalBuilder;
    fResultType:   TVarType;
    fCurClassName: string; // 인스턴스 메서드 안에서 self 타입

    function VTC(t: TVarType; cn: string): System.Type;
    begin
      if t=vtString then Result:=typeof(string)
      else if t=vtBoolean then Result:=typeof(boolean)
      else if t=vtIntArray then Result:=typeof(integer).MakeArrayType() //typeof(integer[])
      else if t=vtStrArray then Result:=typeof(string).MakeArrayType() //typeof(string[])
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
      if fLocalTypes.ContainsKey(name) then Result:=fLocalTypes[name]
      else if fGlobalTypes.ContainsKey(name) then Result:=fGlobalTypes[name]
      else Result:=vtInteger;
    end;

    function GetVarClassName(name: string): string;
    begin
      if fGlobalClass.ContainsKey(name) then Result:=fGlobalClass[name]
      else Result:='';
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
          Result:=vtInteger
        else
        begin
          var _extType:=FindExternalAncestorType(fCurClassName);
          if _extType<>nil then
          begin
            var _pi:=_extType.GetProperty(_fr.FieldName);
            if (_pi<>nil) and (_pi.PropertyType=typeof(string)) then Result:=vtString
            else
            begin
              var _fi:=_extType.GetField(_fr.FieldName);
              if (_fi<>nil) and (_fi.FieldType=typeof(string)) then Result:=vtString
              else Result:=vtInteger;
            end;
          end
          else Result:=vtInteger;
        end;
      end
      else if e is TMethodCallExprNode then
      begin
        var _mc4:=TMethodCallExprNode(e); var _qfb4: FieldBuilder;
        if fLocalClrTypes.ContainsKey(_mc4.ObjName) then
        begin
          var _effType4:=fLocalClrTypes[_mc4.ObjName];
          if _mc4.ObjCastType<>'' then _effType4:=ResolveExternalType(_mc4.ObjCastType);
          var _pi4b:=_effType4.GetProperty(_mc4.MethodName);
          if (_pi4b<>nil) and (_pi4b.PropertyType=typeof(string)) then Result:=vtString
          else
          begin
            // 프로퍼티가 아니면 메서드일 수 있으므로 실제 반환 타입을 확인한다.
            // (예: sender.ToString() → GetProperty는 nil이지만 메서드 반환타입은 string)
            var _mi4b:=ResolveMethodByArity(_effType4, _mc4.MethodName, _mc4.Args.Count, false);
            if (_mi4b<>nil) and (_mi4b.ReturnType=typeof(string)) then Result:=vtString
            else Result:=vtInteger;
          end;
        end
        else if (_mc4.ObjCastType='') and (GetVarClassName(_mc4.ObjName)<>'') then
          Result:=FindMethodReturnType(GetVarClassName(_mc4.ObjName), _mc4.MethodName)
        else if TryFindFieldBuilder(fCurClassName, _mc4.ObjName, _qfb4) then
        begin
          var _effType4b:=_qfb4.FieldType;
          if _mc4.ObjCastType<>'' then _effType4b:=ResolveExternalType(_mc4.ObjCastType);
          var _pi4:=_effType4b.GetProperty(_mc4.MethodName);
          if (_pi4<>nil) and (_pi4.PropertyType=typeof(string)) then Result:=vtString
          else
          begin
            var _mi4:=ResolveMethodByArity(_effType4b, _mc4.MethodName, _mc4.Args.Count, false);
            if (_mi4<>nil) and (_mi4.ReturnType=typeof(string)) then Result:=vtString
            else Result:=vtInteger;
          end;
        end
        else Result:=vtInteger;
      end
      else if e is TArrayIndexExprNode then Result:=vtInteger
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
      else if e is TBinOpNode then
      begin
        b:=TBinOpNode(e);
        if (InferType(b.Left)=vtString) or (InferType(b.Right)=vtString) then
          Result:=vtString
        else Result:=vtInteger;
      end
      else Result:=vtInteger;
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
    begin
      if e is TIntLiteralNode then
      begin lit:=TIntLiteralNode(e); aIL.Emit(OpCodes.Ldc_I4, lit.Value); end

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
        if fLocals.ContainsKey(le.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocals[le.ArrName])
        else aIL.Emit(OpCodes.Ldloc, fGlobals[le.ArrName]);
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
        // TCounter.Create → Newobj (지역 클래스 또는 외부 타입 모두 지원)
        neo:=TNewObjectExprNode(e);
        if neo.IsExternalType then
        begin
          var _extCtorType:=ResolveExternalType(neo.ClassName);
          var _extCtor:=_extCtorType.GetConstructor(System.Type.EmptyTypes);
          if _extCtor=nil then
            raise new Exception('외부 타입 "'+_extCtorType.FullName+'"에 매개변수 없는 public 생성자가 없습니다.');
          aIL.Emit(OpCodes.Newobj, _extCtor);
        end
        else
        begin
          if not fCtorBuilders.ContainsKey(neo.ClassName) then
            raise new Exception('알 수 없는 클래스 "'+neo.ClassName+'"');
          ctor:=fCtorBuilders[neo.ClassName];
          aIL.Emit(OpCodes.Newobj, ctor);
        end;
      end

      else if e is TMethodCallExprNode then
      begin
        // c.GetValue → Ldloc c + Call TCounter::GetValue
        mc:=TMethodCallExprNode(e);
        if (fLocals.ContainsKey(mc.ObjName) or fGlobals.ContainsKey(mc.ObjName))
           and fLocalClrTypes.ContainsKey(mc.ObjName) then
        begin
          // sender/e 같은, 외부(또는 객체) 타입 매개변수/지역변수를 통한 접근.
          // 우리가 만든 클래스가 아니라 Reflection으로 속성/메서드를 찾는다.
          aIL.Emit(OpCodes.Ldloc, fLocals[mc.ObjName]);
          var _qType2:=fLocalClrTypes[mc.ObjName];
          if mc.ObjCastType<>'' then
          begin
            _qType2:=ResolveExternalType(mc.ObjCastType);
            aIL.Emit(OpCodes.Castclass, _qType2);
          end;
          foreach ae in mc.Args do EmitExpr(aIL, ae);
          var _pi6:=_qType2.GetProperty(mc.MethodName);
          if (mc.Args.Count=0) and (_pi6<>nil) and (_pi6.GetGetMethod<>nil) then
            aIL.Emit(OpCodes.Callvirt, _pi6.GetGetMethod)
          else
          begin
            var _emi6:=ResolveMethodByArity(_qType2, mc.MethodName, mc.Args.Count, false);
            if _emi6=nil then
              raise new Exception('타입 "'+_qType2.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
            aIL.Emit(OpCodes.Callvirt, _emi6);
          end;
        end
        else if fLocals.ContainsKey(mc.ObjName) or fGlobals.ContainsKey(mc.ObjName) then
        begin
          cn:=GetVarClassName(mc.ObjName);
          vtVar:=GetVarType(mc.ObjName);
          if fLocals.ContainsKey(mc.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocals[mc.ObjName])
          else aIL.Emit(OpCodes.Ldloc, fGlobals[mc.ObjName]);
          foreach ae in mc.Args do EmitExpr(aIL, ae);
          if cn='' then raise new Exception('알 수 없는 메서드 "'+cn+'.'+mc.MethodName+'"');
          // 인터페이스 타입 변수면 인터페이스 메서드로, 아니면 클래스 상속 체인에서 탐색
          if vtVar=vtInterface then
          begin
            var imi:=FindInterfaceMethod(cn, mc.MethodName);
            aIL.Emit(OpCodes.Callvirt, imi);
          end
          else
          begin
            imb:=FindInstanceMethod(cn, mc.MethodName);
            // virtual 메서드이므로 Callvirt 사용 (다형성 대비)
            aIL.Emit(OpCodes.Callvirt, imb);
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
          foreach ae in mc.Args do EmitExpr(aIL, ae);
          var _pi5:=_qType.GetProperty(mc.MethodName);
          if (mc.Args.Count=0) and (_pi5<>nil) and (_pi5.GetGetMethod<>nil) then
            aIL.Emit(OpCodes.Callvirt, _pi5.GetGetMethod)
          else
          begin
            var _emi5:=ResolveMethodByArity(_qType, mc.MethodName, mc.Args.Count, false);
            if _emi5=nil then
              raise new Exception('타입 "'+_qType.FullName+'"에 메서드 "'+mc.MethodName+'"가 없습니다 (인자 '+mc.Args.Count.ToString+'개).');
            aIL.Emit(OpCodes.Callvirt, _emi5);
          end;
        end
        else raise new Exception('알 수 없는 변수 "'+mc.ObjName+'"');
      end

      else if e is TArrayIndexExprNode then
      begin
        ai:=TArrayIndexExprNode(e);
        if fLocals.ContainsKey(ai.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocals[ai.ArrName])
        else aIL.Emit(OpCodes.Ldloc, fGlobals[ai.ArrName]);
        EmitExpr(aIL, ai.Index);
        aIL.Emit(OpCodes.Ldelem_I4);
      end

      else if e is TVarRefNode then
      begin
        vr:=TVarRefNode(e);
        if fLocals.ContainsKey(vr.VarName) then aIL.Emit(OpCodes.Ldloc, fLocals[vr.VarName])
        else if fGlobals.ContainsKey(vr.VarName) then aIL.Emit(OpCodes.Ldloc, fGlobals[vr.VarName])
        else raise new Exception('선언되지 않은 변수 "'+vr.VarName+'"');
      end

      else if e is TBinOpNode then
      begin
        b:=TBinOpNode(e); lt:=InferType(b.Left); rt:=InferType(b.Right);
        if (b.Op=boAdd) and ((lt=vtString) or (rt=vtString)) then
        begin
          EmitExpr(aIL, b.Left);
          if lt=vtInteger then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(integer)]); aIL.Emit(OpCodes.Call,ts); end;
          EmitExpr(aIL, b.Right);
          if rt=vtInteger then
          begin ts:=typeof(System.Convert).GetMethod('ToString',[typeof(integer)]); aIL.Emit(OpCodes.Call,ts); end;
          cat:=typeof(string).GetMethod('Concat',[typeof(string),typeof(string)]);
          aIL.Emit(OpCodes.Call, cat);
        end
        else
        begin
          EmitExpr(aIL, b.Left); EmitExpr(aIL, b.Right);
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
        foreach ae in fc.Args do EmitExpr(aIL, ae);
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
        if fLocals.ContainsKey(emn.VarName) then
          aIL.Emit(OpCodes.Ldloc, fLocals[emn.VarName])
        else if fGlobals.ContainsKey(emn.VarName) then
          aIL.Emit(OpCodes.Ldloc, fGlobals[emn.VarName])
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

      else raise new Exception('알 수 없는 식 노드: '+e.GetType.Name);
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
        else
        begin
          wlI:=typeof(Console).GetMethod('WriteLine',[typeof(integer)]);
          EmitExpr(aIL, we.Arg); aIL.Emit(OpCodes.Call, wlI);
        end;
      end

      else if s is TResultAssignStmtNode then
      begin
        ra:=TResultAssignStmtNode(s);
        if fResultLocal=nil then raise new Exception('Result는 함수 안에서만');
        EmitExpr(aIL, ra.ValueExpr); aIL.Emit(OpCodes.Stloc, fResultLocal);
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
          else if (fLocals.ContainsKey(fas.Qualifier) or fGlobals.ContainsKey(fas.Qualifier))
                  and fLocalClrTypes.ContainsKey(fas.Qualifier) then
          begin
            // 매개변수/지역변수가 외부(객체) 타입인 경우 — Reflection 기반 처리
            aIL.Emit(OpCodes.Ldloc, fLocals[fas.Qualifier]);
            qTargetType:=fLocalClrTypes[fas.Qualifier];
            if fas.QualifierCastType<>'' then
            begin
              qTargetType:=ResolveExternalType(fas.QualifierCastType);
              aIL.Emit(OpCodes.Castclass, qTargetType);
            end;
            EmitPropertyOrFieldSet(aIL, qTargetType, fas.FieldName, fas.ValueExpr);
          end
          else if fLocals.ContainsKey(fas.Qualifier) or fGlobals.ContainsKey(fas.Qualifier) then
          begin
            cn:=GetVarClassName(fas.Qualifier);
            if fLocals.ContainsKey(fas.Qualifier) then aIL.Emit(OpCodes.Ldloc, fLocals[fas.Qualifier])
            else aIL.Emit(OpCodes.Ldloc, fGlobals[fas.Qualifier]);
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
        if TryFindFieldBuilder(fCurClassName, fas.FieldName, fb) then
        begin
          aIL.Emit(OpCodes.Ldarg_0); // self
          EmitExpr(aIL, fas.ValueExpr);
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
            EmitExpr(aIL, fas.ValueExpr);
            aIL.Emit(OpCodes.Callvirt, setter);
          end
          else
          begin
            extFld:=extType.GetField(fas.FieldName);
            if extFld=nil then
              raise new Exception('외부 타입 "'+extType.FullName+'"에 필드/속성 "'+fas.FieldName+'"가 없습니다.');
            aIL.Emit(OpCodes.Ldarg_0);
            EmitExpr(aIL, fas.ValueExpr);
            aIL.Emit(OpCodes.Stfld, extFld);
          end;
        end;
      end

      else if s is TAssignStmtNode then
      begin
        asg:=TAssignStmtNode(s); EmitExpr(aIL, asg.ValueExpr);
        if fLocals.ContainsKey(asg.VarName) then
          aIL.Emit(OpCodes.Stloc, fLocals[asg.VarName])
        else if fGlobals.ContainsKey(asg.VarName) then
          aIL.Emit(OpCodes.Stloc, fGlobals[asg.VarName])
        else raise new Exception('선언되지 않은 변수 "'+asg.VarName+'"');
      end

      else if s is TMethodCallStmtNode then
      begin
        mcs:=TMethodCallStmtNode(s);
        if mcs.ObjName='' then
        begin
          // 암시적 self 호출: Show; Close(); 등 — 지역 메서드 우선, 없으면 외부 상속 타입에서 탐색
          aIL.Emit(OpCodes.Ldarg_0); // self
          foreach ae in mcs.Args do EmitExpr(aIL, ae);
          if TryFindInstanceMethod(fCurClassName, mcs.MethodName, imb) then
          begin
            aIL.Emit(OpCodes.Callvirt, imb);
            if imb.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            extType:=FindExternalAncestorType(fCurClassName);
            if extType=nil then
              raise new Exception('알 수 없는 메서드 "'+fCurClassName+'.'+mcs.MethodName+'"');
            emi:=ResolveMethodByArity(extType, mcs.MethodName, mcs.Args.Count, false);
            if emi=nil then
              raise new Exception('외부 타입 "'+extType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
            aIL.Emit(OpCodes.Callvirt, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
        end
        else if (fLocals.ContainsKey(mcs.ObjName) or fGlobals.ContainsKey(mcs.ObjName))
                and fLocalClrTypes.ContainsKey(mcs.ObjName) then
        begin
          // sender.Focus(); 같은, 외부(객체) 타입 매개변수/지역변수를 통한 호출.
          aIL.Emit(OpCodes.Ldloc, fLocals[mcs.ObjName]);
          qTargetType:=fLocalClrTypes[mcs.ObjName];
          if mcs.ObjCastType<>'' then
          begin
            qTargetType:=ResolveExternalType(mcs.ObjCastType);
            aIL.Emit(OpCodes.Castclass, qTargetType);
          end;
          foreach ae in mcs.Args do EmitExpr(aIL, ae);
          var _getP2:=qTargetType.GetProperty(mcs.MethodName);
          if (mcs.Args.Count=0) and (_getP2<>nil) and (_getP2.GetGetMethod<>nil) then
          begin
            aIL.Emit(OpCodes.Callvirt, _getP2.GetGetMethod);
            aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            emi:=ResolveMethodByArity(qTargetType, mcs.MethodName, mcs.Args.Count, false);
            if emi=nil then
              raise new Exception('타입 "'+qTargetType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
            aIL.Emit(OpCodes.Callvirt, emi);
            if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end;
        end
        else if fLocals.ContainsKey(mcs.ObjName) or fGlobals.ContainsKey(mcs.ObjName) then
        begin
          // c.Init(10) → Ldloc c + args + Call
          cn:=GetVarClassName(mcs.ObjName);
          vtVar:=GetVarType(mcs.ObjName);
          if fLocals.ContainsKey(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocals[mcs.ObjName])
          else aIL.Emit(OpCodes.Ldloc, fGlobals[mcs.ObjName]);
          foreach ae in mcs.Args do EmitExpr(aIL, ae);
          if cn='' then raise new Exception('알 수 없는 메서드 "'+cn+'.'+mcs.MethodName+'"');
          // 인터페이스 타입 변수면 인터페이스 메서드로, 아니면 클래스 상속 체인에서 탐색
          // (Stage 10에서는 fInstanceMethods[cn] 직접 조회 + Call만 사용해 상속받은
          //  메서드 호출 시 실패할 수 있었는데, FindInstanceMethod + Callvirt로 통일)
          if vtVar=vtInterface then
          begin
            var imi:=FindInterfaceMethod(cn, mcs.MethodName);
            aIL.Emit(OpCodes.Callvirt, imi);
            if imi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            imb:=FindInstanceMethod(cn, mcs.MethodName);
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
          foreach ae in mcs.Args do EmitExpr(aIL, ae);
          var _getP:=qTargetType.GetProperty(mcs.MethodName);
          if (mcs.Args.Count=0) and (_getP<>nil) and (_getP.GetGetMethod<>nil) then
          begin
            aIL.Emit(OpCodes.Callvirt, _getP.GetGetMethod);
            aIL.Emit(OpCodes.Pop);
          end
          else
          begin
            emi:=ResolveMethodByArity(qTargetType, mcs.MethodName, mcs.Args.Count, false);
            if emi=nil then
              raise new Exception('타입 "'+qTargetType.FullName+'"에 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
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
          foreach ae in mcs.Args do EmitExpr(aIL, ae);
          emi:=ResolveMethodByArity(extType, mcs.MethodName, mcs.Args.Count, true);
          if emi=nil then
            raise new Exception('외부 타입 "'+extType.FullName+'"에 정적 메서드 "'+mcs.MethodName+'"가 없습니다 (인자 '+mcs.Args.Count.ToString+'개).');
          aIL.Emit(OpCodes.Call, emi);
          if emi.ReturnType<>typeof(System.Void) then aIL.Emit(OpCodes.Pop);
        end;
      end

      else if s is TEventSubscribeStmtNode then
      begin
        // Button1.Click += Button1_Click;
        evs:=TEventSubscribeStmtNode(s);

        // 1) 리시버(Button1) 로드 — 필드 우선, 그다음 로컬/전역 변수
        if TryFindFieldBuilder(fCurClassName, evs.Qualifier, qfb) then
        begin
          aIL.Emit(OpCodes.Ldarg_0); aIL.Emit(OpCodes.Ldfld, qfb);
          qTargetType:=qfb.FieldType;
        end
        else if fLocals.ContainsKey(evs.Qualifier) or fGlobals.ContainsKey(evs.Qualifier) then
        begin
          if fLocals.ContainsKey(evs.Qualifier) then aIL.Emit(OpCodes.Ldloc, fLocals[evs.Qualifier])
          else aIL.Emit(OpCodes.Ldloc, fGlobals[evs.Qualifier]);
          if fLocalClrTypes.ContainsKey(evs.Qualifier) then qTargetType:=fLocalClrTypes[evs.Qualifier]
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

        // 3) 델리게이트 생성: self(핸들러의 target) + 핸들러 메서드 포인터 → Newobj
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

        // 4) add_XXX(delegate) 호출 — 스택: [리시버, 델리게이트]
        emi:=evInfo.GetAddMethod;
        if emi=nil then
          raise new Exception('이벤트 "'+evs.EventName+'"의 add 메서드를 찾을 수 없습니다.');
        aIL.Emit(OpCodes.Callvirt, emi);
      end

      else if s is TSetLengthStmtNode then
      begin
        sl:=TSetLengthStmtNode(s); at2:=vtIntArray;
        if fGlobalTypes.ContainsKey(sl.ArrName) then at2:=fGlobalTypes[sl.ArrName]
        else if fLocalTypes.ContainsKey(sl.ArrName) then at2:=fLocalTypes[sl.ArrName];
        if fLocals.ContainsKey(sl.ArrName) then aIL.Emit(OpCodes.Ldloca, fLocals[sl.ArrName])
        else aIL.Emit(OpCodes.Ldloca, fGlobals[sl.ArrName]);
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
        if fGlobalTypes.ContainsKey(aa.ArrName) then at2:=fGlobalTypes[aa.ArrName]
        else if fLocalTypes.ContainsKey(aa.ArrName) then at2:=fLocalTypes[aa.ArrName];
        if fLocals.ContainsKey(aa.ArrName) then aIL.Emit(OpCodes.Ldloc, fLocals[aa.ArrName])
        else aIL.Emit(OpCodes.Ldloc, fGlobals[aa.ArrName]);
        EmitExpr(aIL, aa.Index); EmitExpr(aIL, aa.ValueExpr);
        if at2=vtStrArray then aIL.Emit(OpCodes.Stelem_Ref)
        else aIL.Emit(OpCodes.Stelem_I4);
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
        aIL.Emit(OpCodes.Br, ckL); aIL.MarkLabel(bdL);
        EmitStatement(aIL, whs.Body);
        aIL.MarkLabel(ckL); EmitExpr(aIL, whs.Condition);
        aIL.Emit(OpCodes.Brtrue, bdL);
      end

      else if s is TProcCallStmtNode then
      begin
        pc:=TProcCallStmtNode(s);
        if not fMethods.ContainsKey(pc.ProcName) then
          raise new Exception('알 수 없는 프로시저 "'+pc.ProcName+'"');
        mb:=fMethods[pc.ProcName];
        foreach ae in pc.Args do EmitExpr(aIL, ae);
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
        if fLocals.ContainsKey(fs.VarName) then forVarLoc:=fLocals[fs.VarName]
        else if fGlobals.ContainsKey(fs.VarName) then forVarLoc:=fGlobals[fs.VarName]
        else raise new Exception('for 변수 선언 안 됨: '+fs.VarName);
        // end값을 임시 로컬에 저장 (매 반복 재평가 방지)
        var endValLoc:=aIL.DeclareLocal(typeof(integer));
        EmitExpr(aIL, fs.StartExpr);
        aIL.Emit(OpCodes.Stloc, forVarLoc);
        EmitExpr(aIL, fs.EndExpr);
        aIL.Emit(OpCodes.Stloc, endValLoc);
        var forCkL:=aIL.DefineLabel; var forBdL:=aIL.DefineLabel;
        aIL.Emit(OpCodes.Br, forCkL);
        aIL.MarkLabel(forBdL);
        EmitStatement(aIL, fs.Body);
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
      end

      else if s is TTryStmtNode then
      begin
        var ts2:=TTryStmtNode(s);
        // 예외 변수 로컬 선언 (on E: Exception do 가 있는 경우)
        var exLoc: LocalBuilder := nil;
        if (ts2.ExVarName<>'') and (ts2.ExceptStmts<>nil) then
        begin
          exLoc:=aIL.DeclareLocal(typeof(Exception));
          fLocals[ts2.ExVarName]:=exLoc;
          fLocalTypes[ts2.ExVarName]:=vtString; // 내부 타입은 string으로 (Message는 string)
        end;

        aIL.BeginExceptionBlock;

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

        // 예외 변수 이름을 로컬에서 제거 (스코프 종료)
        if ts2.ExVarName<>'' then
          fLocals.Remove(ts2.ExVarName);
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

    // 인터페이스 TypeBuilder 생성 + 즉시 완성(CreateType)
    // 인터페이스는 클래스처럼 나중에 몸체를 채울 필요가 없으므로(메서드 시그니처뿐)
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
    var asm: Assembly; t: System.Type;
    begin
      // 1) 어셈블리 지정 없이 바로 찾히는 경우 (mscorlib/coreLib에 있는 타입 등)
      t:=System.Type.GetType(dottedName);
      if t<>nil then begin Result:=t; exit; end;

      // 2) 등록된 참조 어셈블리들을 순서대로 검색
      foreach asm in fLoadedAssemblies do
      begin
        t:=asm.GetType(dottedName);
        if t<>nil then begin Result:=t; exit; end;
      end;

      raise new Exception('외부 타입 "'+dottedName+'"을(를) 찾을 수 없습니다. '+
        'AddReferenceAssembly로 해당 타입이 들어있는 어셈블리를 먼저 등록했는지 확인하세요.');
    end;

    // 외부 타입에서 이름+인자개수로 메서드를 찾는다 (엄격한 타입 일치 대신 개수만 맞춰서
    // 찾음 — 우리가 만든 파생 클래스 인스턴스를 부모 타입 매개변수에 넘기는 경우
    // System.Type.GetMethod(name, exactArgTypes)로는 정확히 일치하지 않아 못 찾기 때문).
    // 오버로드가 여러 개면 그중 인자 개수가 맞는 첫 번째를 사용한다 (단순화).
    function ResolveMethodByArity(t: System.Type; mname: string; argCount: integer; isStatic: boolean): MethodInfo;
    var flags: BindingFlags; mi: MethodInfo;
    begin
      if isStatic then flags:=BindingFlags.Public or BindingFlags.Static
      else flags:=BindingFlags.Public or BindingFlags.Instance;
      Result:=nil;
      foreach mi in t.GetMethods(flags) do
        if (mi.Name=mname) and (mi.GetParameters.Length=argCount) then
        begin Result:=mi; exit; end;
    end;

    // aIL 스택에 target 참조가 이미 로드되어 있다고 가정하고, 그 위에
    // targetType의 memberName 속성(setter)이나 필드에 valueExpr 값을 설정한다.
    procedure EmitPropertyOrFieldSet(aIL: ILGenerator; targetType: System.Type; memberName: string; valueExpr: TExprNode);
    var pi: PropertyInfo; fi: System.Reflection.FieldInfo; setr: MethodInfo;
    begin
      pi:=targetType.GetProperty(memberName);
      if pi<>nil then
      begin
        setr:=pi.GetSetMethod;
        if setr=nil then
          raise new Exception('속성 "'+targetType.FullName+'.'+memberName+'"에 setter가 없습니다 (읽기 전용).');
        EmitExpr(aIL, valueExpr);
        aIL.Emit(OpCodes.Callvirt, setr);
      end
      else
      begin
        fi:=targetType.GetField(memberName);
        if fi=nil then
          raise new Exception('타입 "'+targetType.FullName+'"에 필드/속성 "'+memberName+'"가 없습니다.');
        EmitExpr(aIL, valueExpr);
        aIL.Emit(OpCodes.Stfld, fi);
      end;
    end;

    // 정적 필드/속성 설정 (예: System.Console.Title := '...'). 인스턴스 리시버가 없으므로
    // Callvirt/Stfld가 아니라 Call/Stsfld를 쓴다.
    procedure EmitStaticPropertyOrFieldSet(aIL: ILGenerator; targetType: System.Type; memberName: string; valueExpr: TExprNode);
    var pi2: PropertyInfo; fi2: System.Reflection.FieldInfo; setr2: MethodInfo;
    begin
      pi2:=targetType.GetProperty(memberName);
      if (pi2<>nil) and (pi2.GetSetMethod<>nil) then
      begin
        setr2:=pi2.GetSetMethod;
        EmitExpr(aIL, valueExpr);
        aIL.Emit(OpCodes.Call, setr2);
      end
      else
      begin
        fi2:=targetType.GetField(memberName);
        if fi2=nil then
          raise new Exception('타입 "'+targetType.FullName+'"에 정적 필드/속성 "'+memberName+'"가 없습니다 (또는 읽기 전용).');
        EmitExpr(aIL, valueExpr);
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

      tb:=modBuilder.DefineType(cd.Name,
        TypeAttributes.Public or TypeAttributes.Class,
        parentType);
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
      end;

      // 메서드 시그니처만 정의
      // 모두 Virtual + HideBySig로 정의: 자식 클래스에서 같은 이름/시그니처의
      // 메서드를 정의하면 CLR이 이름/시그니처 매칭으로 자동 override(슬롯 재사용) 처리한다.
      methAttrs:=MethodAttributes.Public or MethodAttributes.Virtual or MethodAttributes.HideBySig;
      foreach sig in cd.Methods do
      begin
        paramTypes:=new System.Type[sig.ParamNames.Count];
        for i:=0 to sig.ParamNames.Count-1 do
          paramTypes[i]:=ResolveParamClrType(sig, i);
        if sig.IsFunction then
          mb:=tb.DefineMethod(sig.Name, methAttrs, VTC(sig.ReturnType, ''), paramTypes)
        else
          mb:=tb.DefineMethod(sig.Name, methAttrs, typeof(System.Void), paramTypes);
        fInstanceMethods[cd.Name][sig.Name]:=mb;
        if not fMethodReturnTypes.ContainsKey(cd.Name) then
          fMethodReturnTypes[cd.Name]:=new Dictionary<string, TVarType>;
        fMethodReturnTypes[cd.Name][sig.Name]:=sig.ReturnType;
        if not fMethodParamClrTypes.ContainsKey(cd.Name) then
          fMethodParamClrTypes[cd.Name]:=new Dictionary<string, array of System.Type>;
        fMethodParamClrTypes[cd.Name][sig.Name]:=paramTypes;
      end;

      // 기본 생성자 추가 (부모 생성자 호출로 체이닝)
      var ctorBuilder:=tb.DefineConstructor(
        MethodAttributes.Public,
        CallingConventions.Standard,
        System.Type.EmptyTypes);
      fCtorBuilders[cd.Name]:=ctorBuilder;
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

    // 클래스 메서드 본문 IL 생성
    procedure BuildMethodBody(impl: TMethodImplNode);
    var
      mb: MethodBuilder; il: ILGenerator;
      i: integer; p: string;
      svLocals: Dictionary<string, LocalBuilder>;
      svLocalTypes: Dictionary<string, TVarType>;
      svLocalClrTypes: Dictionary<string, System.Type>;
      svResult: LocalBuilder; svResultType: TVarType;
      svCurClass: string; st: TStmtNode;
    begin
      if not (fInstanceMethods.ContainsKey(impl.ClassName)
        and fInstanceMethods[impl.ClassName].ContainsKey(impl.MethodName)) then
        raise new Exception('메서드를 찾을 수 없음: '+impl.ClassName+'.'+impl.MethodName);

      mb:=fInstanceMethods[impl.ClassName][impl.MethodName];
      il:=mb.GetILGenerator;

      svLocals:=fLocals; svLocalTypes:=fLocalTypes; svLocalClrTypes:=fLocalClrTypes;
      svResult:=fResultLocal; svResultType:=fResultType;
      svCurClass:=fCurClassName;

      fLocals:=new Dictionary<string, LocalBuilder>;
      fLocalTypes:=new Dictionary<string, TVarType>;
      fLocalClrTypes:=new Dictionary<string, System.Type>;
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
        fLocals[p]:=loc; fLocalTypes[p]:=vtInteger;
        if pClrType<>typeof(integer) then fLocalClrTypes[p]:=pClrType;
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
        var lvClrType:=VTC(lv.VarType, lv.ClassName);
        var lvLoc:=il.DeclareLocal(lvClrType);
        fLocals[lv.Name]:=lvLoc; fLocalTypes[lv.Name]:=lv.VarType;
        if (lv.VarType=vtObject) or (lv.VarType=vtInterface) then fLocalClrTypes[lv.Name]:=lvClrType;
      end;

      foreach st in impl.Body.Statements do EmitStatement(il, st);

      if impl.IsFunction then
      begin
        il.Emit(OpCodes.Ldloc, fResultLocal);
      end;
      il.Emit(OpCodes.Ret);

      fLocals:=svLocals; fLocalTypes:=svLocalTypes; fLocalClrTypes:=svLocalClrTypes;
      fResultLocal:=svResult; fResultType:=svResultType;
      fCurClassName:=svCurClass;
    end;

    // [Stage 27] 이전에는 최상위 함수/프로시저의 모든 매개변수·반환값을 무조건
    // typeof(integer)로 방출했다 — string/boolean/array 매개변수를 받는 함수는
    // 인자를 올바른 CLR 타입으로 스택에 올려도 시그니처가 int32로 선언되어 있어
    // IL 검증에서 깨지거나 값이 깨졌다. 이제 Parser가 이미 채워둔
    // d.Parameters[i].ParamType/d.ReturnType을 VTC로 변환해 그대로 사용한다.
    // (클래스/인터페이스 타입 매개변수는 TParamDef가 ClassName을 보관하지 않아
    // 아직 범위 밖 — 향후 단계 과제로 남긴다.)
    procedure BuildStaticFunc(tb: TypeBuilder; d: TFuncDeclNode);
    var
      pt: array of System.Type; i: integer; mb: MethodBuilder; il: ILGenerator;
      svL: Dictionary<string, LocalBuilder>; svLT: Dictionary<string, TVarType>;
      svLC: Dictionary<string, System.Type>;
      svR: LocalBuilder; svRT: TVarType; st: TStmtNode; retClrType: System.Type;
    begin
      pt:=new System.Type[d.Parameters.Count];
      for i:=0 to d.Parameters.Count-1 do pt[i]:=VTC(d.Parameters[i].ParamType, '');
      retClrType:=VTC(d.ReturnType, '');
      mb:=tb.DefineMethod(d.Name, MethodAttributes.Public or MethodAttributes.Static,
        retClrType, pt);
      fMethods[d.Name]:=mb; fFuncReturnTypes[d.Name]:=d.ReturnType; il:=mb.GetILGenerator;
      svL:=fLocals; svLT:=fLocalTypes; svLC:=fLocalClrTypes; svR:=fResultLocal; svRT:=fResultType;
      fLocals:=new Dictionary<string,LocalBuilder>; fLocalTypes:=new Dictionary<string,TVarType>;
      fLocalClrTypes:=new Dictionary<string,System.Type>;
      fResultType:=d.ReturnType; fResultLocal:=il.DeclareLocal(retClrType);
      for i:=0 to d.Parameters.Count-1 do
      begin
        var loc:=il.DeclareLocal(pt[i]);
        fLocals[d.Parameters[i].Name]:=loc; fLocalTypes[d.Parameters[i].Name]:=d.Parameters[i].ParamType;
        if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
        else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i));
        il.Emit(OpCodes.Stloc, loc);
      end;
      // [Stage 28] 함수 본문의 지역 변수 선언(var 섹션) 처리 — BuildMethodBody와 동일 패턴.
      foreach var lv in d.LocalVars do
      begin
        var lvClrType:=VTC(lv.VarType, lv.ClassName);
        var lvLoc:=il.DeclareLocal(lvClrType);
        fLocals[lv.Name]:=lvLoc; fLocalTypes[lv.Name]:=lv.VarType;
        if (lv.VarType=vtObject) or (lv.VarType=vtInterface) then fLocalClrTypes[lv.Name]:=lvClrType;
      end;
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.Emit(OpCodes.Ldloc, fResultLocal); il.Emit(OpCodes.Ret);
      fLocals:=svL; fLocalTypes:=svLT; fLocalClrTypes:=svLC; fResultLocal:=svR; fResultType:=svRT;
    end;

    procedure BuildStaticProc(tb: TypeBuilder; d: TProcDeclNode);
    var
      pt: array of System.Type; i: integer; mb: MethodBuilder; il: ILGenerator;
      svL: Dictionary<string, LocalBuilder>; svLT: Dictionary<string, TVarType>;
      svLC: Dictionary<string, System.Type>;
      svR: LocalBuilder; svRT: TVarType; st: TStmtNode;
    begin
      pt:=new System.Type[d.Parameters.Count];
      for i:=0 to d.Parameters.Count-1 do pt[i]:=VTC(d.Parameters[i].ParamType, '');
      mb:=tb.DefineMethod(d.Name, MethodAttributes.Public or MethodAttributes.Static,
        typeof(System.Void), pt);
      fMethods[d.Name]:=mb; il:=mb.GetILGenerator;
      svL:=fLocals; svLT:=fLocalTypes; svLC:=fLocalClrTypes; svR:=fResultLocal; svRT:=fResultType;
      fLocals:=new Dictionary<string,LocalBuilder>; fLocalTypes:=new Dictionary<string,TVarType>;
      fLocalClrTypes:=new Dictionary<string,System.Type>;
      fResultLocal:=nil;
      for i:=0 to d.Parameters.Count-1 do
      begin
        var loc:=il.DeclareLocal(pt[i]);
        fLocals[d.Parameters[i].Name]:=loc; fLocalTypes[d.Parameters[i].Name]:=d.Parameters[i].ParamType;
        if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
        else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i));
        il.Emit(OpCodes.Stloc, loc);
      end;
      // [Stage 28] 프로시저 본문의 지역 변수 선언(var 섹션) 처리.
      foreach var lv in d.LocalVars do
      begin
        var lvClrType:=VTC(lv.VarType, lv.ClassName);
        var lvLoc:=il.DeclareLocal(lvClrType);
        fLocals[lv.Name]:=lvLoc; fLocalTypes[lv.Name]:=lv.VarType;
        if (lv.VarType=vtObject) or (lv.VarType=vtInterface) then fLocalClrTypes[lv.Name]:=lvClrType;
      end;
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.Emit(OpCodes.Ret);
      fLocals:=svL; fLocalTypes:=svLT; fLocalClrTypes:=svLC; fResultLocal:=svR; fResultType:=svRT;
    end;

  public
    constructor Create(p: TProgramNode);
    begin
      fProg:=p;
      fGlobals:=new Dictionary<string, LocalBuilder>;
      fGlobalTypes:=new Dictionary<string, TVarType>;
      fGlobalClass:=new Dictionary<string, string>;
      fLocals:=new Dictionary<string, LocalBuilder>;
      fLocalTypes:=new Dictionary<string, TVarType>;
      fLocalClrTypes:=new Dictionary<string, System.Type>;
      fMethods:=new Dictionary<string, MethodBuilder>;
      fFuncReturnTypes:=new Dictionary<string, TVarType>;
      fTypeBuilders:=new Dictionary<string, TypeBuilder>;
      fBuiltTypes:=new Dictionary<string, System.Type>;
      fFieldBuilders:=new Dictionary<string, Dictionary<string, FieldBuilder>>;
      fInstanceMethods:=new Dictionary<string, Dictionary<string, MethodBuilder>>;
      fClassParents:=new Dictionary<string, string>;
      fMethodReturnTypes:=new Dictionary<string, Dictionary<string, TVarType>>;
      fMethodParamClrTypes:=new Dictionary<string, Dictionary<string, array of System.Type>>;
      fCtorBuilders:=new Dictionary<string, ConstructorBuilder>;
      fInterfaceBuilders:=new Dictionary<string, TypeBuilder>;
      fBuiltInterfaces:=new Dictionary<string, System.Type>;
      fLoadedAssemblies:=new List<Assembly>;
      fClassExternalParentType:=new Dictionary<string, System.Type>;
      fResultLocal:=nil; fResultType:=vtInteger; fCurClassName:='';
    end;

    // WPF는 'PresentationFramework','PresentationCore','WindowsBase' (GAC),
    // WinForm은 'System.Windows.Forms','System.Drawing' (GAC),
    // AvaloniaUI는 GAC에 없으므로 dll 전체 경로를 넘겨야 함 (예: 'C:\...\Avalonia.Controls.dll').
    // 주의: .NET Framework GAC는 짧은 이름만으로는 바인딩 실패할 수 있음 — 실패하면
    // 'System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089'
    // 처럼 Version/Culture/PublicKeyToken까지 포함한 정식 이름으로 재시도할 것.
    // 어떤 프레임워크를 쓸지는 호출하는 쪽(디자이너)이 결정해서 이 메서드로 등록한다.
    procedure AddReferenceAssembly(nameOrPath: string);
    var asm: Assembly;
    begin
      asm:=nil;
      try
        if nameOrPath.ToLower.EndsWith('.dll') then
          asm:=Assembly.LoadFrom(nameOrPath)
        else
          asm:=Assembly.Load(nameOrPath);
      except
        on E: Exception do
          raise new Exception('어셈블리 "'+nameOrPath+'" 로드 실패: '+E.Message);
      end;
      if asm<>nil then fLoadedAssemblies.Add(asm);
    end;

    procedure GenerateExe(outName: string);
    var
      an: AssemblyName; ab: AssemblyBuilder;
      modB: ModuleBuilder; mainTB: TypeBuilder;
      mm: MethodBuilder; il: ILGenerator;
      rk: MethodInfo; vd: TVarDecl; st: TStmtNode;
      cd: TClassDeclNode; impl: TMethodImplNode; id: TInterfaceDeclNode;
      fd: TFuncDeclNode; pd: TProcDeclNode;
    begin
      an:=new AssemblyName(fProg.Name);
      ab:=AssemblyBuilder.DefineDynamicAssembly(an, AssemblyBuilderAccess.RunAndSave);
      modB:=ab.DefineDynamicModule(fProg.Name, outName);

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

      // 3. 일반 static 함수/프로시저 빌드
      foreach fd in fProg.FuncDecls do BuildStaticFunc(mainTB, fd);
      foreach pd in fProg.ProcDecls do BuildStaticProc(mainTB, pd);

      // 4. 클래스 메서드 본문 IL 생성
      foreach impl in fProg.MethodImpls do BuildMethodBody(impl);

      // 5. 클래스 타입 완성 (CreateType)
      foreach cd in fProg.ClassDecls do
      begin
        fBuiltTypes[cd.Name]:=fTypeBuilders[cd.Name].CreateType;
      end;

      // 6. Main 메서드
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
        if vd.VarType=vtObject then
        begin
          if fBuiltTypes.ContainsKey(vd.ClassName) then
            clrType:=fBuiltTypes[vd.ClassName]
          else
            clrType:=typeof(System.Object);
          fGlobalClass[vd.Name]:=vd.ClassName;
        end
        else if vd.VarType=vtInterface then
        begin
          if fBuiltInterfaces.ContainsKey(vd.ClassName) then
            clrType:=fBuiltInterfaces[vd.ClassName]
          else
            clrType:=typeof(System.Object);
          fGlobalClass[vd.Name]:=vd.ClassName;
        end
        // [Stage 27] string/boolean/array 전역 변수도 예전에는 무조건 typeof(integer)로
        // 선언되어 있었다 — fGlobalTypes만 올바르고 실제 LocalBuilder 슬롯 타입은 틀려서
        // 대입 시 IL 검증에서 깨졌다. object/interface가 아닌 나머지는 VTC로 위임한다.
        else clrType:=VTC(vd.VarType, '');
        fGlobals[vd.Name]:=il.DeclareLocal(clrType);
        fGlobalTypes[vd.Name]:=vd.VarType;
      end;

      foreach st in fProg.Statements do EmitStatement(il, st);

      rk:=typeof(Console).GetMethod('ReadKey', System.Type.EmptyTypes);
      il.Emit(OpCodes.Call, rk); il.Emit(OpCodes.Pop); il.Emit(OpCodes.Ret);

      mainTB.CreateType;
      ab.SetEntryPoint(mm, PEFileKinds.ConsoleApplication);
      ab.Save(outName);
    end;
  end;

implementation

end.