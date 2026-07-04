// ============================================================
// Parser.pas — 구문 분석 (TParser)
// AST.pas(노드 타입), Lexer.pas(TToken/TTokenKind)에 의존.
// 새 문법(try/except, 제네릭 등)이 생길 때마다 이 파일이 바뀜.
// 최근 여러 Stage에 걸쳐 이 파일 변경이 잦다면 = 현재 병목이 여기라는 뜻.
// ============================================================
unit Parser;

interface

uses
  System.Text,
  System.Collections.Generic,
  AST,
  Lexer;

type
  TParser = class
  private
    fTokens: List<TToken>; fPos: integer;
    fCurFunc: string;
    fCurClass: string; // 현재 파싱 중인 메서드의 클래스 이름
    fFuncNames, fProcNames, fArrayNames: List<string>;
    fClassNames: List<string>; // 선언된 클래스 이름 목록
    fInterfaceNames: List<string>; // 선언된 인터페이스 이름 목록
    // 클래스별 필드 이름 목록 (메서드 본문에서 필드 vs 변수 구분) — 상속받은 필드 포함
    fClassFields: Dictionary<string, List<string>>;
    // 클래스별 메서드 이름 → isFunction — 상속받은 메서드 포함
    fClassMethods: Dictionary<string, Dictionary<string, boolean>>;
    // 클래스별 부모 클래스 이름 ('' 이면 없음)
    fClassParent: Dictionary<string, string>;

    function Cur: TToken; begin Result:=fTokens[fPos]; end;

    function Expect(k: TTokenKind): TToken;
    var t: TToken;
    begin
      t:=Cur;
      if t.Kind<>k then
        raise new Exception('줄 '+t.Line.ToString+': 예상 '+k.ToString
          +' 실제 '+t.Kind.ToString+' ("'+t.Text+'")');
      fPos:=fPos+1; Result:=t;
    end;

    function ParseVarType: TVarType;
    begin
      if Cur.Kind=tkInteger then begin fPos:=fPos+1; Result:=vtInteger; end
      else if Cur.Kind=tkStringType then begin fPos:=fPos+1; Result:=vtString; end
      else if Cur.Kind=tkBoolean then begin fPos:=fPos+1; Result:=vtBoolean; end
      else if Cur.Kind=tkArray then
      begin
        fPos:=fPos+1; Expect(tkOf);
        if Cur.Kind=tkInteger then begin fPos:=fPos+1; Result:=vtIntArray; end
        else if Cur.Kind=tkStringType then begin fPos:=fPos+1; Result:=vtStrArray; end
        else raise new Exception('줄 '+Cur.Line.ToString+': array of integer/string만 지원');
      end
      else if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
      begin
        fPos:=fPos+1; Result:=vtObject;
      end
      else raise new Exception('줄 '+Cur.Line.ToString+': 타입이 와야 합니다 ("'+Cur.Text+'")');
    end;

    // ---- 식 파싱 (ParsePrimary 안에서는 ParseAddSub만 호출) ----

    function ParsePrimary: TExprNode;
    var t: TToken; inner, argE, idxE: TExprNode;
        cn: TFuncCallExprNode; mc: TMethodCallExprNode;
    begin
      t:=Cur;

      if t.Kind=tkIntLiteral then
        begin fPos:=fPos+1; Result:=new TIntLiteralNode(integer.Parse(t.Text)); end

      else if t.Kind=tkString then
        begin fPos:=fPos+1; Result:=new TStrLiteralNode(t.Text); end

      else if t.Kind=tkResult then
        begin fPos:=fPos+1; Result:=new TResultRefNode; end

      else if t.Kind=tkTrue then
        begin fPos:=fPos+1; Result:=new TBoolLiteralNode(true); end

      else if t.Kind=tkFalse then
        begin fPos:=fPos+1; Result:=new TBoolLiteralNode(false); end

      else if t.Kind=tkNot then
        begin fPos:=fPos+1; Result:=new TNotExprNode(ParsePrimary); end

      else if t.Kind=tkIntToStr then
      begin
        fPos:=fPos+1; Expect(tkLParen);
        argE:=ParseAddSub; Expect(tkRParen);
        Result:=new TIntToStrNode(argE);
      end

      else if t.Kind=tkLength then
      begin
        fPos:=fPos+1; Expect(tkLParen);
        var nt:=Expect(tkIdent); Expect(tkRParen);
        Result:=new TLengthExprNode(nt.Text);
      end

      else if t.Kind=tkIdent then
      begin
        fPos:=fPos+1;

        // 클래스명.Create → TNewObjectExprNode
        if (Cur.Kind=tkDot) and fClassNames.Contains(t.Text) then
        begin
          fPos:=fPos+1; // '.' 소비
          var mname:=Expect(tkIdent);
          if mname.Text.ToLower='create' then
          begin
            Result:=new TNewObjectExprNode(t.Text);
          end
          else
          begin
            // 클래스명.메서드 (함수 호출로서 식)
            mc:=new TMethodCallExprNode(t.Text, mname.Text);
            if Cur.Kind=tkLParen then
            begin
              fPos:=fPos+1;
              if Cur.Kind<>tkRParen then
              begin
                mc.Args.Add(ParseAddSub);
                while Cur.Kind=tkComma do begin fPos:=fPos+1; mc.Args.Add(ParseAddSub); end;
              end;
              Expect(tkRParen);
            end;
            Result:=mc;
          end;
        end

        // 변수.메서드 (인스턴스 메서드 호출) 또는 변수.Message (예외 프로퍼티)
        else if Cur.Kind=tkDot then
        begin
          fPos:=fPos+1; // '.' 소비
          var mname:=Expect(tkIdent);
          // E.Message 패턴 → TExceptionMsgExprNode
          if mname.Text.ToLower='message' then
          begin
            Result:=new TExceptionMsgExprNode(t.Text);
          end
          else
          begin
            mc:=new TMethodCallExprNode(t.Text, mname.Text);
            if Cur.Kind=tkLParen then
            begin
              fPos:=fPos+1;
              if Cur.Kind<>tkRParen then
              begin
                mc.Args.Add(ParseAddSub);
                while Cur.Kind=tkComma do begin fPos:=fPos+1; mc.Args.Add(ParseAddSub); end;
              end;
              Expect(tkRParen);
            end;
            Result:=mc;
          end;
        end

        // 배열 인덱스
        else if (Cur.Kind=tkLBracket) and fArrayNames.Contains(t.Text) then
        begin
          fPos:=fPos+1; idxE:=ParseAddSub; Expect(tkRBracket);
          Result:=new TArrayIndexExprNode(t.Text, idxE);
        end

        // 일반 함수 호출
        else if (Cur.Kind=tkLParen) and fFuncNames.Contains(t.Text) then
        begin
          cn:=new TFuncCallExprNode(t.Text); fPos:=fPos+1;
          if Cur.Kind<>tkRParen then
          begin
            cn.Args.Add(ParseAddSub);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; cn.Args.Add(ParseAddSub); end;
          end;
          Expect(tkRParen); Result:=cn;
        end

        else
        begin
          // 현재 클래스 메서드 안에서 필드 참조인지 확인
          if (fCurClass<>'') and fClassFields.ContainsKey(fCurClass)
             and fClassFields[fCurClass].Contains(t.Text) then
            Result:=new TFieldReadExprNode(t.Text)
          else
            Result:=new TVarRefNode(t.Text);
        end;
      end

      else if t.Kind=tkLParen then
      begin
        fPos:=fPos+1; inner:=ParseAddSub; Expect(tkRParen); Result:=inner;
      end

      else
        raise new Exception('줄 '+t.Line.ToString+': 식이 와야 하는데 "'+t.Text+'"');
    end;

    function ParseMulDivMod: TExprNode;
    var left: TExprNode; op: TBinOpKind;
    begin
      left:=ParsePrimary;
      while (Cur.Kind=tkStar) or (Cur.Kind=tkSlash) or (Cur.Kind=tkMod) or (Cur.Kind=tkAnd) do
      begin
        if Cur.Kind=tkStar then op:=boMul
        else if Cur.Kind=tkSlash then op:=boDiv
        else if Cur.Kind=tkMod then op:=boMod
        else op:=boAnd; // tkAnd — 표준 Pascal에서 and는 *,/,mod와 같은 우선순위
        fPos:=fPos+1; left:=new TBinOpNode(op, left, ParsePrimary);
      end;
      Result:=left;
    end;

    function ParseAddSub: TExprNode;
    var left: TExprNode; op: TBinOpKind;
    begin
      left:=ParseMulDivMod;
      while (Cur.Kind=tkPlus) or (Cur.Kind=tkMinus) or (Cur.Kind=tkOr) do
      begin
        if Cur.Kind=tkPlus then op:=boAdd
        else if Cur.Kind=tkMinus then op:=boSub
        else op:=boOr; // tkOr — 표준 Pascal에서 or는 +,-와 같은 우선순위
        fPos:=fPos+1; left:=new TBinOpNode(op, left, ParseMulDivMod);
      end;
      Result:=left;
    end;

    function ParseExpr: TExprNode;
    var left: TExprNode; ck: TCompareKind; has: boolean;
    begin
      left:=ParseAddSub; has:=true;
      if      Cur.Kind=tkEq  then ck:=cmpEq
      else if Cur.Kind=tkNeq then ck:=cmpNeq
      else if Cur.Kind=tkLt  then ck:=cmpLt
      else if Cur.Kind=tkGt  then ck:=cmpGt
      else if Cur.Kind=tkLe  then ck:=cmpLe
      else if Cur.Kind=tkGe  then ck:=cmpGe
      else has:=false;
      if has then begin fPos:=fPos+1; Result:=new TCompareNode(ck, left, ParseAddSub); end
      else Result:=left;
    end;

    // ---- 문장 파싱 ----
    function ParseStatement: TStmtNode;
    var
      nt: TToken; rhs, idx, sz: TExprNode;
      comp: TCompoundStmtNode; cond: TExprNode;
      tS, eS, bS: TStmtNode; pcn: TProcCallStmtNode;
      mcs: TMethodCallStmtNode;
    begin
      if Cur.Kind=tkWriteln then
      begin
        fPos:=fPos+1; Expect(tkLParen); rhs:=ParseExpr; Expect(tkRParen);
        if rhs is TStrLiteralNode then
          Result:=new TWritelnStringStmtNode(TStrLiteralNode(rhs).Value)
        else Result:=new TWritelnExprStmtNode(rhs);
      end

      else if Cur.Kind=tkResult then
      begin
        fPos:=fPos+1; Expect(tkAssign);
        Result:=new TResultAssignStmtNode(ParseExpr);
      end

      else if Cur.Kind=tkSetLength then
      begin
        fPos:=fPos+1; Expect(tkLParen);
        nt:=Expect(tkIdent); Expect(tkComma);
        sz:=ParseExpr; Expect(tkRParen);
        Result:=new TSetLengthStmtNode(nt.Text, sz);
      end

      else if Cur.Kind=tkIdent then
      begin
        nt:=Cur; fPos:=fPos+1;

        // 변수.메서드 → 메서드 호출 문장 (반환값 버림)
        if Cur.Kind=tkDot then
        begin
          fPos:=fPos+1;
          var mname:=Expect(tkIdent);
          mcs:=new TMethodCallStmtNode(nt.Text, mname.Text);
          if Cur.Kind=tkLParen then
          begin
            fPos:=fPos+1;
            if Cur.Kind<>tkRParen then
            begin
              mcs.Args.Add(ParseExpr);
              while Cur.Kind=tkComma do begin fPos:=fPos+1; mcs.Args.Add(ParseExpr); end;
            end;
            Expect(tkRParen);
          end;
          Result:=mcs;
        end

        // 배열 원소 대입
        else if (Cur.Kind=tkLBracket) and fArrayNames.Contains(nt.Text) then
        begin
          fPos:=fPos+1; idx:=ParseExpr; Expect(tkRBracket);
          Expect(tkAssign); rhs:=ParseExpr;
          Result:=new TArrayAssignStmtNode(nt.Text, idx, rhs);
        end

        // 프로시저 호출
        else if (Cur.Kind=tkLParen) and fProcNames.Contains(nt.Text) then
        begin
          pcn:=new TProcCallStmtNode(nt.Text); fPos:=fPos+1;
          if Cur.Kind<>tkRParen then
          begin
            pcn.Args.Add(ParseExpr);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; pcn.Args.Add(ParseExpr); end;
          end;
          Expect(tkRParen); Result:=pcn;
        end

        // 대입문 (일반 변수 또는 필드)
        else
        begin
          Expect(tkAssign); rhs:=ParseExpr;
          // 현재 클래스 메서드 안이고, 필드 이름이면 TFieldAssignStmtNode
          if (fCurClass<>'') and fClassFields.ContainsKey(fCurClass)
             and fClassFields[fCurClass].Contains(nt.Text) then
            Result:=new TFieldAssignStmtNode(nt.Text, rhs)
          else
            Result:=new TAssignStmtNode(nt.Text, rhs);
        end;
      end

      else if Cur.Kind=tkBegin then
      begin
        fPos:=fPos+1; comp:=new TCompoundStmtNode;
        while Cur.Kind<>tkEnd do
        begin comp.Statements.Add(ParseStatement); if Cur.Kind=tkSemicolon then fPos:=fPos+1; end;
        Expect(tkEnd); Result:=comp;
      end

      else if Cur.Kind=tkIf then
      begin
        fPos:=fPos+1; cond:=ParseExpr; Expect(tkThen); tS:=ParseStatement;
        eS:=nil;
        if Cur.Kind=tkElse then begin fPos:=fPos+1; eS:=ParseStatement; end;
        Result:=new TIfStmtNode(cond, tS, eS);
      end

      else if Cur.Kind=tkWhile then
      begin
        fPos:=fPos+1; cond:=ParseExpr; Expect(tkDo); bS:=ParseStatement;
        Result:=new TWhileStmtNode(cond, bS);
      end

      else if Cur.Kind=tkFor then
      begin
        fPos:=fPos+1;
        var vn:=Expect(tkIdent).Text;
        Expect(tkAssign);
        var seE:=ParseExpr;
        var isDown:=false;
        if Cur.Kind=tkTo then fPos:=fPos+1
        else if Cur.Kind=tkDownto then begin isDown:=true; fPos:=fPos+1; end
        else raise new Exception('줄 '+Cur.Line.ToString+': for문에는 to 또는 downto가 와야 합니다');
        var eeE:=ParseExpr;
        Expect(tkDo);
        var forBody:=ParseStatement;
        Result:=new TForStmtNode(vn, seE, eeE, isDown, forBody);
      end

      else if Cur.Kind=tkTry then
      begin
        // try <stmts> (except [on E: Type do <stmt>] | finally <stmts>) end
        fPos:=fPos+1;
        var tryNode:=new TTryStmtNode;
        // try 본문 파싱 (except/finally 키워드가 나올 때까지)
        while (Cur.Kind<>tkExcept) and (Cur.Kind<>tkFinally) and (Cur.Kind<>tkEnd) do
        begin
          tryNode.BodyStmts.Add(ParseStatement);
          if Cur.Kind=tkSemicolon then fPos:=fPos+1;
        end;
        if Cur.Kind=tkExcept then
        begin
          fPos:=fPos+1; // 'except' 소비
          tryNode.ExceptStmts:=new List<TStmtNode>;
          // on E: ExceptionType do <stmt>
          if Cur.Kind=tkOn then
          begin
            fPos:=fPos+1; // 'on' 소비
            tryNode.ExVarName:=Expect(tkIdent).Text;
            Expect(tkColon);
            tryNode.ExTypeName:=Expect(tkIdent).Text;
            Expect(tkDo);
            tryNode.ExceptStmts.Add(ParseStatement);
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end
          else
          begin
            // on 없이 bare except
            while (Cur.Kind<>tkEnd) and (Cur.Kind<>tkFinally) do
            begin
              tryNode.ExceptStmts.Add(ParseStatement);
              if Cur.Kind=tkSemicolon then fPos:=fPos+1;
            end;
          end;
          // 선택적 finally after except
          if Cur.Kind=tkFinally then
          begin
            fPos:=fPos+1;
            tryNode.FinallyStmts:=new List<TStmtNode>;
            while Cur.Kind<>tkEnd do
            begin
              tryNode.FinallyStmts.Add(ParseStatement);
              if Cur.Kind=tkSemicolon then fPos:=fPos+1;
            end;
          end;
        end
        else if Cur.Kind=tkFinally then
        begin
          fPos:=fPos+1; // 'finally' 소비
          tryNode.FinallyStmts:=new List<TStmtNode>;
          while Cur.Kind<>tkEnd do
          begin
            tryNode.FinallyStmts.Add(ParseStatement);
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end;
        end;
        Expect(tkEnd);
        Result:=tryNode;
      end

      else if Cur.Kind=tkRaise then
      begin
        fPos:=fPos+1; // 'raise' 소비
        // raise; (세미콜론 또는 end 면 re-raise)
        if (Cur.Kind=tkSemicolon) or (Cur.Kind=tkEnd) or (Cur.Kind=tkExcept) then
          Result:=new TRaiseStmtNode(nil)
        else
          Result:=new TRaiseStmtNode(ParseExpr);
      end

      else
        raise new Exception('줄 '+Cur.Line.ToString+': 알 수 없는 문장 ("'+Cur.Text+'")');
    end;

    // 인터페이스 안의 메서드 시그니처 하나 파싱 (본문 없음)
    function ParseInterfaceMethodSig: TMethodSignature;
    var isFunc: boolean; retType: TVarType; sig: TMethodSignature; pnames: List<string>; pt: TVarType;
    begin
      isFunc:=(Cur.Kind=tkFunction);
      if not ((Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure)) then
        raise new Exception('줄 '+Cur.Line.ToString+': 인터페이스 안에는 메서드 시그니처만 올 수 있습니다 ("'+Cur.Text+'")');
      fPos:=fPos+1;
      var mname:=Expect(tkIdent).Text;
      retType:=vtInteger;
      pnames:=new List<string>;
      sig:=new TMethodSignature(mname, isFunc, retType);
      if Cur.Kind=tkLParen then
      begin
        fPos:=fPos+1;
        if Cur.Kind<>tkRParen then
        begin
          while true do
          begin
            var pn:=Expect(tkIdent).Text; pnames.Add(pn);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; pnames.Add(Expect(tkIdent).Text); end;
            Expect(tkColon); pt:=ParseVarType;
            foreach var pnm in pnames do
            begin sig.ParamNames.Add(pnm); sig.ParamTypes.Add(pt); end;
            pnames.Clear;
            if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
          end;
        end;
        Expect(tkRParen);
      end;
      if isFunc then
      begin Expect(tkColon); sig.ReturnType:=ParseVarType; end;
      Expect(tkSemicolon);
      Result:=sig;
    end;

    // type 섹션: IFoo = interface ... end;  또는  TClassName = class ... end;
    procedure ParseTypeSection(aProg: TProgramNode);
    var
      cn: string; cd: TClassDeclNode; idecl: TInterfaceDeclNode;
      fname: string; ftype: TVarType;
      sig: TMethodSignature;
      isFunc: boolean; retType: TVarType;
      pnames: List<string>; pt: TVarType;
    begin
      Expect(tkType);
      while Cur.Kind=tkIdent do
      begin
        cn:=Cur.Text; fPos:=fPos+1;
        Expect(tkEq);

        // ---- 인터페이스 선언 ----
        if Cur.Kind=tkInterface then
        begin
          fPos:=fPos+1; // 'interface' 소비
          idecl:=new TInterfaceDeclNode(cn);
          fInterfaceNames.Add(cn);

          while Cur.Kind<>tkEnd do
            idecl.Methods.Add(ParseInterfaceMethodSig);

          Expect(tkEnd); Expect(tkSemicolon);
          aProg.InterfaceDecls.Add(idecl);
        end

        // ---- 클래스 선언 ----
        else
        begin
          Expect(tkClass);
          cd:=new TClassDeclNode(cn);

          // 선택적 상속/인터페이스 구현: class(TParentName) 또는 class(IInterfaceName)
          if Cur.Kind=tkLParen then
          begin
            fPos:=fPos+1;
            var pname:=Expect(tkIdent).Text;
            if fClassNames.Contains(pname) then
              cd.ParentName:=pname
            else if fInterfaceNames.Contains(pname) then
              cd.InterfaceName:=pname
            else
              raise new Exception('줄 '+Cur.Line.ToString+': 알 수 없는 부모 클래스/인터페이스 "'+pname+'"');
            Expect(tkRParen);
          end;

          fClassNames.Add(cn);
          fClassParent[cn]:=cd.ParentName;

          // 필드/메서드 이름 목록은 부모의 것을 상속하여 시작 (필드/메서드 참조 판별용)
          if cd.ParentName<>'' then
          begin
            fClassFields[cn]:=new List<string>(fClassFields[cd.ParentName]);
            fClassMethods[cn]:=new Dictionary<string, boolean>(fClassMethods[cd.ParentName]);
          end
          else
          begin
            fClassFields[cn]:=new List<string>;
            fClassMethods[cn]:=new Dictionary<string, boolean>;
          end;

          // private/public 섹션 안의 필드와 메서드 시그니처 읽기
          while Cur.Kind<>tkEnd do
          begin
            // private / public 키워드는 건너뜀
            if (Cur.Kind=tkPrivate) or (Cur.Kind=tkPublic) then
            begin
              fPos:=fPos+1;
            end

            // 메서드 시그니처: procedure/function
            else if (Cur.Kind=tkProcedure) or (Cur.Kind=tkFunction) then
            begin
              isFunc:=(Cur.Kind=tkFunction); fPos:=fPos+1;
              var mname:=Expect(tkIdent).Text;
              retType:=vtInteger;
              // 매개변수 목록 (선택)
              pnames:=new List<string>;
              sig:=new TMethodSignature(mname, isFunc, retType);
              if Cur.Kind=tkLParen then
              begin
                fPos:=fPos+1;
                if Cur.Kind<>tkRParen then
                begin
                  while true do
                  begin
                    var pn:=Expect(tkIdent).Text; pnames.Add(pn);
                    while Cur.Kind=tkComma do begin fPos:=fPos+1; pnames.Add(Expect(tkIdent).Text); end;
                    Expect(tkColon); pt:=ParseVarType;
                    foreach var pnm in pnames do
                    begin sig.ParamNames.Add(pnm); sig.ParamTypes.Add(pt); end;
                    pnames.Clear;
                    if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
                  end;
                end;
                Expect(tkRParen);
              end;
              if isFunc then
              begin
                Expect(tkColon); sig.ReturnType:=ParseVarType;
              end;
              Expect(tkSemicolon);
              cd.Methods.Add(sig);
              fClassMethods[cn][mname]:=isFunc;
            end

            // 필드 선언: fname : type;
            else if Cur.Kind=tkIdent then
            begin
              fname:=Cur.Text; fPos:=fPos+1;
              Expect(tkColon); ftype:=ParseVarType;
              Expect(tkSemicolon);
              cd.Fields.Add(new TFieldDeclNode(fname, ftype));
              fClassFields[cn].Add(fname);
            end

            else
              raise new Exception('줄 '+Cur.Line.ToString+': 클래스 선언 안에서 알 수 없는 토큰 "'+Cur.Text+'"');
          end;

          Expect(tkEnd); Expect(tkSemicolon);
          aProg.ClassDecls.Add(cd);
        end;
      end;
    end;

    // 클래스 메서드 구현: procedure TClassName.MethodName; begin...end;
    function ParseMethodImpl: TMethodImplNode;
    var
      isFunc: boolean; cn, mn: string;
      impl: TMethodImplNode; comp: TCompoundStmtNode;
      pt: TVarType; retType: TVarType;
    begin
      isFunc:=(Cur.Kind=tkFunction); fPos:=fPos+1;
      cn:=Expect(tkIdent).Text; Expect(tkDot);
      mn:=Expect(tkIdent).Text;
      retType:=vtInteger;
      impl:=new TMethodImplNode(cn, mn, isFunc, retType);

      // 매개변수
      if Cur.Kind=tkLParen then
      begin
        fPos:=fPos+1;
        if Cur.Kind<>tkRParen then
        begin
          while true do
          begin
            var pn:=Expect(tkIdent).Text; impl.ParamNames.Add(pn);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; impl.ParamNames.Add(Expect(tkIdent).Text); end;
            Expect(tkColon); pt:=ParseVarType;
            for var i:=impl.ParamTypes.Count to impl.ParamNames.Count-1 do
              impl.ParamTypes.Add(pt);
            if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
          end;
        end;
        Expect(tkRParen);
      end;

      if isFunc then
      begin Expect(tkColon); impl.ReturnType:=ParseVarType; end;
      Expect(tkSemicolon);

      // 본문 파싱 (fCurClass 설정으로 필드 참조 가능)
      var savedClass:=fCurClass; var savedFunc:=fCurFunc;
      fCurClass:=cn; fCurFunc:=mn;

      Expect(tkBegin); comp:=new TCompoundStmtNode;
      while Cur.Kind<>tkEnd do
      begin comp.Statements.Add(ParseStatement); if Cur.Kind=tkSemicolon then fPos:=fPos+1; end;
      Expect(tkEnd); Expect(tkSemicolon);

      fCurClass:=savedClass; fCurFunc:=savedFunc;
      impl.Body:=comp;
      Result:=impl;
    end;

    procedure ParseParams(aP: List<TParamDef>);
    var pt: TVarType; ns: List<string>;
    begin
      Expect(tkLParen);
      if Cur.Kind<>tkRParen then
      begin
        while true do
        begin
          ns:=new List<string>; ns.Add(Expect(tkIdent).Text);
          while Cur.Kind=tkComma do begin fPos:=fPos+1; ns.Add(Expect(tkIdent).Text); end;
          Expect(tkColon); pt:=ParseVarType;
          foreach var nm in ns do aP.Add(new TParamDef(nm, pt));
          if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
        end;
      end;
      Expect(tkRParen);
    end;

    function ParseFuncDecl: TFuncDeclNode;
    var d: TFuncDeclNode; c: TCompoundStmtNode; sv: string;
    begin
      Expect(tkFunction); d:=new TFuncDeclNode(Expect(tkIdent).Text);
      fFuncNames.Add(d.Name); ParseParams(d.Parameters);
      Expect(tkColon); d.ReturnType:=ParseVarType; Expect(tkSemicolon);
      sv:=fCurFunc; fCurFunc:=d.Name;
      Expect(tkBegin); c:=new TCompoundStmtNode;
      while Cur.Kind<>tkEnd do
      begin c.Statements.Add(ParseStatement); if Cur.Kind=tkSemicolon then fPos:=fPos+1; end;
      Expect(tkEnd); Expect(tkSemicolon); fCurFunc:=sv; d.Body:=c; Result:=d;
    end;

    function ParseProcDecl: TProcDeclNode;
    var d: TProcDeclNode; c: TCompoundStmtNode; sv: string;
    begin
      Expect(tkProcedure);
      // ClassName.MethodName 형태이면 메서드 구현으로 처리
      // (이미 Cur.Kind=tkIdent인지 확인)
      d:=new TProcDeclNode(Expect(tkIdent).Text);
      fProcNames.Add(d.Name); ParseParams(d.Parameters); Expect(tkSemicolon);
      sv:=fCurFunc; fCurFunc:='';
      Expect(tkBegin); c:=new TCompoundStmtNode;
      while Cur.Kind<>tkEnd do
      begin c.Statements.Add(ParseStatement); if Cur.Kind=tkSemicolon then fPos:=fPos+1; end;
      Expect(tkEnd); Expect(tkSemicolon); fCurFunc:=sv; d.Body:=c; Result:=d;
    end;

    procedure ParseVarSection(aProg: TProgramNode);
    var vt: TVarType; ns: List<string>; cn: string;
    begin
      Expect(tkVar);
      while (Cur.Kind<>tkBegin) and (Cur.Kind<>tkFunction)
        and (Cur.Kind<>tkProcedure) do
      begin
        ns:=new List<string>; ns.Add(Expect(tkIdent).Text);
        while Cur.Kind=tkComma do begin fPos:=fPos+1; ns.Add(Expect(tkIdent).Text); end;
        Expect(tkColon);
        cn:='';
        // 클래스 타입 변수 처리
        if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
        begin
          cn:=Cur.Text; fPos:=fPos+1; vt:=vtObject;
        end
        // 인터페이스 타입 변수 처리
        else if (Cur.Kind=tkIdent) and fInterfaceNames.Contains(Cur.Text) then
        begin
          cn:=Cur.Text; fPos:=fPos+1; vt:=vtInterface;
        end
        else vt:=ParseVarType;
        Expect(tkSemicolon);
        foreach var nm in ns do
        begin
          aProg.VarDecls.Add(new TVarDecl(nm, vt, cn));
          if (vt=vtIntArray) or (vt=vtStrArray) then fArrayNames.Add(nm);
        end;
      end;
    end;

  public
    constructor Create(aTokens: List<TToken>);
    begin
      fTokens:=aTokens; fPos:=0; fCurFunc:=''; fCurClass:='';
      fFuncNames:=new List<string>;
      fProcNames:=new List<string>;
      fArrayNames:=new List<string>;
      fClassNames:=new List<string>;
      fInterfaceNames:=new List<string>;
      fClassFields:=new Dictionary<string, List<string>>;
      fClassMethods:=new Dictionary<string, Dictionary<string, boolean>>;
      fClassParent:=new Dictionary<string, string>;
    end;

    function ParseProgram: TProgramNode;
    var prog: TProgramNode; t: TToken;
    begin
      Expect(tkProgram); prog:=new TProgramNode(Expect(tkIdent).Text); Expect(tkSemicolon);

      // type 섹션
      if Cur.Kind=tkType then ParseTypeSection(prog);

      // 클래스 메서드 구현 또는 일반 함수/프로시저
      while (Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure) do
      begin
        // ClassName.MethodName 형태인지 미리 보기
        var savedPos:=fPos;
        fPos:=fPos+1; // function/procedure 소비
        if (Cur.Kind=tkIdent) then
        begin
          var name1:=Cur.Text; fPos:=fPos+1;
          if (Cur.Kind=tkDot) and fClassNames.Contains(name1) then
          begin
            // 메서드 구현 → 위치 복원 후 ParseMethodImpl 호출
            fPos:=savedPos;
            prog.MethodImpls.Add(ParseMethodImpl);
          end
          else
          begin
            // 일반 함수/프로시저 → 위치 복원 후 처리
            fPos:=savedPos;
            t:=Cur;
            if t.Kind=tkFunction then prog.FuncDecls.Add(ParseFuncDecl)
            else prog.ProcDecls.Add(ParseProcDecl);
          end;
        end
        else
        begin
          fPos:=savedPos;
          t:=Cur;
          if t.Kind=tkFunction then prog.FuncDecls.Add(ParseFuncDecl)
          else prog.ProcDecls.Add(ParseProcDecl);
        end;
      end;

      if Cur.Kind=tkVar then ParseVarSection(prog);

      Expect(tkBegin);
      while Cur.Kind<>tkEnd do
      begin prog.Statements.Add(ParseStatement); if Cur.Kind=tkSemicolon then fPos:=fPos+1; end;
      Expect(tkEnd); Expect(tkDot); Expect(tkEOF);
      Result:=prog;
    end;
  end;

implementation

end.