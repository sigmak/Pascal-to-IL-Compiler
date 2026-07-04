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

    // 일반 static 함수/프로시저
    fMethods:     Dictionary<string, MethodBuilder>;

    // 클래스 관련
    fTypeBuilders: Dictionary<string, TypeBuilder>;  // 클래스명 → TypeBuilder
    fBuiltTypes:   Dictionary<string, System.Type>;  // 클래스명 → 완성된 Type
    fFieldBuilders: Dictionary<string, Dictionary<string, FieldBuilder>>; // 클래스명 → 필드명 → FieldBuilder
    fInstanceMethods: Dictionary<string, Dictionary<string, MethodBuilder>>; // 클래스명 → 메서드명 → MB
    fClassParents: Dictionary<string, string>; // 클래스명 → 부모 클래스명 ('' 이면 없음)
    fMethodReturnTypes: Dictionary<string, Dictionary<string, TVarType>>; // 클래스명/인터페이스명 → 메서드명 → 반환타입
    fCtorBuilders: Dictionary<string, ConstructorBuilder>; // 클래스명 → 기본 생성자 (CreateType 전에도 참조 가능하도록 보관)

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
      else if e is TStrLiteralNode then Result:=vtString
      else if e is TIntToStrNode then Result:=vtString
      else if e is TLengthExprNode then Result:=vtInteger
      else if e is TResultRefNode then Result:=fResultType
      else if e is TNewObjectExprNode then Result:=vtObject
      else if e is TFieldReadExprNode then Result:=vtInteger // 단순화: 필드는 정수
      else if e is TMethodCallExprNode then
        Result:=FindMethodReturnType(GetVarClassName(TMethodCallExprNode(e).ObjName),
                                      TMethodCallExprNode(e).MethodName)
      else if e is TArrayIndexExprNode then Result:=vtInteger
      else if e is TVarRefNode then Result:=GetVarType(TVarRefNode(e).VarName)
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
        // self.fieldName 읽기 (인스턴스 메서드 안)
        fr:=TFieldReadExprNode(e);
        aIL.Emit(OpCodes.Ldarg_0); // self
        fb:=FindFieldBuilder(fCurClassName, fr.FieldName);
        aIL.Emit(OpCodes.Ldfld, fb);
      end

      else if e is TNewObjectExprNode then
      begin
        // TCounter.Create → Newobj
        neo:=TNewObjectExprNode(e);
        if not fCtorBuilders.ContainsKey(neo.ClassName) then
          raise new Exception('알 수 없는 클래스 "'+neo.ClassName+'"');
        ctor:=fCtorBuilders[neo.ClassName];
        aIL.Emit(OpCodes.Newobj, ctor);
      end

      else if e is TMethodCallExprNode then
      begin
        // c.GetValue → Ldloc c + Call TCounter::GetValue
        mc:=TMethodCallExprNode(e);
        cn:=GetVarClassName(mc.ObjName);
        vtVar:=GetVarType(mc.ObjName);
        if fLocals.ContainsKey(mc.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocals[mc.ObjName])
        else if fGlobals.ContainsKey(mc.ObjName) then aIL.Emit(OpCodes.Ldloc, fGlobals[mc.ObjName])
        else raise new Exception('알 수 없는 변수 "'+mc.ObjName+'"');
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
        // self.fieldName := 식
        fas:=TFieldAssignStmtNode(s);
        aIL.Emit(OpCodes.Ldarg_0); // self
        EmitExpr(aIL, fas.ValueExpr);
        fb:=FindFieldBuilder(fCurClassName, fas.FieldName);
        aIL.Emit(OpCodes.Stfld, fb);
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
        // c.Init(10) → Ldloc c + args + Call
        mcs:=TMethodCallStmtNode(s);
        cn:=GetVarClassName(mcs.ObjName);
        vtVar:=GetVarType(mcs.ObjName);
        if fLocals.ContainsKey(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fLocals[mcs.ObjName])
        else if fGlobals.ContainsKey(mcs.ObjName) then aIL.Emit(OpCodes.Ldloc, fGlobals[mcs.ObjName])
        else raise new Exception('알 수 없는 변수 "'+mcs.ObjName+'"');
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
          paramTypes[i]:=typeof(integer); // 단순화: 매개변수는 정수

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
      if (cd.ParentName<>'') and fTypeBuilders.ContainsKey(cd.ParentName) then
        parentType:=fTypeBuilders[cd.ParentName]
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
        fb:=tb.DefineField(fd.Name, typeof(integer), FieldAttributes.Public);
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
          paramTypes[i]:=typeof(integer); // 단순화: 매개변수는 정수
        if sig.IsFunction then
          mb:=tb.DefineMethod(sig.Name, methAttrs, VTC(sig.ReturnType, ''), paramTypes)
        else
          mb:=tb.DefineMethod(sig.Name, methAttrs, typeof(System.Void), paramTypes);
        fInstanceMethods[cd.Name][sig.Name]:=mb;
        if not fMethodReturnTypes.ContainsKey(cd.Name) then
          fMethodReturnTypes[cd.Name]:=new Dictionary<string, TVarType>;
        fMethodReturnTypes[cd.Name][sig.Name]:=sig.ReturnType;
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
        parentCtor:=typeof(System.Object).GetConstructor(System.Type.EmptyTypes);
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
      svResult: LocalBuilder; svResultType: TVarType;
      svCurClass: string; st: TStmtNode;
    begin
      if not (fInstanceMethods.ContainsKey(impl.ClassName)
        and fInstanceMethods[impl.ClassName].ContainsKey(impl.MethodName)) then
        raise new Exception('메서드를 찾을 수 없음: '+impl.ClassName+'.'+impl.MethodName);

      mb:=fInstanceMethods[impl.ClassName][impl.MethodName];
      il:=mb.GetILGenerator;

      svLocals:=fLocals; svLocalTypes:=fLocalTypes;
      svResult:=fResultLocal; svResultType:=fResultType;
      svCurClass:=fCurClassName;

      fLocals:=new Dictionary<string, LocalBuilder>;
      fLocalTypes:=new Dictionary<string, TVarType>;
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
        var loc:=il.DeclareLocal(typeof(integer));
        fLocals[p]:=loc; fLocalTypes[p]:=vtInteger;
        // self=Ldarg_0 이므로 매개변수는 Ldarg_1부터
        if i=0 then il.Emit(OpCodes.Ldarg_1)
        else if i=1 then il.Emit(OpCodes.Ldarg_2)
        else if i=2 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i+1));
        il.Emit(OpCodes.Stloc, loc);
      end;

      foreach st in impl.Body.Statements do EmitStatement(il, st);

      if impl.IsFunction then
      begin
        il.Emit(OpCodes.Ldloc, fResultLocal);
      end;
      il.Emit(OpCodes.Ret);

      fLocals:=svLocals; fLocalTypes:=svLocalTypes;
      fResultLocal:=svResult; fResultType:=svResultType;
      fCurClassName:=svCurClass;
    end;

    procedure BuildStaticFunc(tb: TypeBuilder; d: TFuncDeclNode);
    var
      pt: array of System.Type; i: integer; mb: MethodBuilder; il: ILGenerator;
      svL: Dictionary<string, LocalBuilder>; svLT: Dictionary<string, TVarType>;
      svR: LocalBuilder; svRT: TVarType; st: TStmtNode;
    begin
      pt:=new System.Type[d.Parameters.Count];
      for i:=0 to d.Parameters.Count-1 do pt[i]:=typeof(integer);
      mb:=tb.DefineMethod(d.Name, MethodAttributes.Public or MethodAttributes.Static,
        typeof(integer), pt);
      fMethods[d.Name]:=mb; il:=mb.GetILGenerator;
      svL:=fLocals; svLT:=fLocalTypes; svR:=fResultLocal; svRT:=fResultType;
      fLocals:=new Dictionary<string,LocalBuilder>; fLocalTypes:=new Dictionary<string,TVarType>;
      fResultType:=d.ReturnType; fResultLocal:=il.DeclareLocal(typeof(integer));
      for i:=0 to d.Parameters.Count-1 do
      begin
        var loc:=il.DeclareLocal(typeof(integer));
        fLocals[d.Parameters[i].Name]:=loc; fLocalTypes[d.Parameters[i].Name]:=vtInteger;
        if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
        else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i));
        il.Emit(OpCodes.Stloc, loc);
      end;
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.Emit(OpCodes.Ldloc, fResultLocal); il.Emit(OpCodes.Ret);
      fLocals:=svL; fLocalTypes:=svLT; fResultLocal:=svR; fResultType:=svRT;
    end;

    procedure BuildStaticProc(tb: TypeBuilder; d: TProcDeclNode);
    var
      pt: array of System.Type; i: integer; mb: MethodBuilder; il: ILGenerator;
      svL: Dictionary<string, LocalBuilder>; svLT: Dictionary<string, TVarType>;
      svR: LocalBuilder; svRT: TVarType; st: TStmtNode;
    begin
      pt:=new System.Type[d.Parameters.Count];
      for i:=0 to d.Parameters.Count-1 do pt[i]:=typeof(integer);
      mb:=tb.DefineMethod(d.Name, MethodAttributes.Public or MethodAttributes.Static,
        typeof(System.Void), pt);
      fMethods[d.Name]:=mb; il:=mb.GetILGenerator;
      svL:=fLocals; svLT:=fLocalTypes; svR:=fResultLocal; svRT:=fResultType;
      fLocals:=new Dictionary<string,LocalBuilder>; fLocalTypes:=new Dictionary<string,TVarType>;
      fResultLocal:=nil;
      for i:=0 to d.Parameters.Count-1 do
      begin
        var loc:=il.DeclareLocal(typeof(integer));
        fLocals[d.Parameters[i].Name]:=loc; fLocalTypes[d.Parameters[i].Name]:=vtInteger;
        if i=0 then il.Emit(OpCodes.Ldarg_0) else if i=1 then il.Emit(OpCodes.Ldarg_1)
        else if i=2 then il.Emit(OpCodes.Ldarg_2) else if i=3 then il.Emit(OpCodes.Ldarg_3)
        else il.Emit(OpCodes.Ldarg_S, byte(i));
        il.Emit(OpCodes.Stloc, loc);
      end;
      foreach st in d.Body.Statements do EmitStatement(il, st);
      il.Emit(OpCodes.Ret);
      fLocals:=svL; fLocalTypes:=svLT; fResultLocal:=svR; fResultType:=svRT;
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
      fMethods:=new Dictionary<string, MethodBuilder>;
      fTypeBuilders:=new Dictionary<string, TypeBuilder>;
      fBuiltTypes:=new Dictionary<string, System.Type>;
      fFieldBuilders:=new Dictionary<string, Dictionary<string, FieldBuilder>>;
      fInstanceMethods:=new Dictionary<string, Dictionary<string, MethodBuilder>>;
      fClassParents:=new Dictionary<string, string>;
      fMethodReturnTypes:=new Dictionary<string, Dictionary<string, TVarType>>;
      fCtorBuilders:=new Dictionary<string, ConstructorBuilder>;
      fInterfaceBuilders:=new Dictionary<string, TypeBuilder>;
      fBuiltInterfaces:=new Dictionary<string, System.Type>;
      fResultLocal:=nil; fResultType:=vtInteger; fCurClassName:='';
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
        else clrType:=typeof(integer);
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