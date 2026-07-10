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
    fCurParams: List<string>; // 현재 파싱 중인 메서드의 매개변수 이름 목록 (필드보다 우선) — 지역변수도 나중에 추가됨
    fCurMethodParamNames: List<string>; // [Stage 30] 순수 매개변수 이름만(지역변수 제외) — bare 'inherited;' 인자 전달용
    fFuncNames, fProcNames, fArrayNames: List<string>;
    fClassNames: List<string>; // 선언된 클래스 이름 목록 (제네릭 템플릿 이름 + 단형화된 구체 이름 포함)
    fInterfaceNames: List<string>; // 선언된 인터페이스 이름 목록
    // 클래스별 필드 이름 목록 (메서드 본문에서 필드 vs 변수 구분) — 상속받은 필드 포함
    fClassFields: Dictionary<string, List<string>>;
    // 클래스별 메서드 이름 → isFunction — 상속받은 메서드 포함
    fClassMethods: Dictionary<string, Dictionary<string, boolean>>;
    // 클래스별 부모 클래스 이름 ('' 이면 없음)
    fClassParent: Dictionary<string, string>;
    // [Stage 34] 클래스별 구현 인터페이스 이름 ('' 이면 없음) — 제네릭 제약조건 검증에 사용
    fClassInterface: Dictionary<string, string>;
    // Stage26: 제네릭(단형화) 지원
    fProg: TProgramNode; // ParseProgram 시작 시 설정 — 깊이 상관없이 GenericInstantiations에 접근하기 위함
    fGenericClassNames: List<string>; // 제네릭 템플릿으로 선언된 클래스 이름 (예: 'TStack')
    // [Stage 32] 템플릿 이름 → 타입 매개변수 이름 목록 (예: 'TStack'→['T'], 'TPair'→['K','V'])
    fClassGenericParam: Dictionary<string, List<string>>;
    // [Stage 34] 템플릿 이름 → 타입 매개변수별 제약조건 목록 (fClassGenericParam과 같은 인덱스로 대응, ''=제약 없음)
    fClassGenericConstraint: Dictionary<string, List<string>>;
    // [Stage 36] 최상위 제네릭 함수/프로시저 지원 (클래스 제네릭과 동일한 패턴).
    fGenericFuncNames, fGenericProcNames: List<string>; // 제네릭 템플릿으로 선언된 함수/프로시저 이름
    fFuncGenericParam, fProcGenericParam: Dictionary<string, List<string>>;      // 템플릿 이름 → 타입 매개변수 이름 목록
    fFuncGenericConstraint, fProcGenericConstraint: Dictionary<string, List<string>>; // 템플릿 이름 → 제약조건 목록(같은 인덱스)
    // [Stage 32] 현재 파싱 중인 제네릭 클래스 본문/메서드구현에서 유효한 타입 매개변수 이름들 (빈 목록이면 제네릭 문맥 아님)
    fCurGenericParams: List<string>;
    // [Stage 32] ParseVarType/ParseParamTypeExt가 vtGeneric을 반환했을 때, 그 자리에서 바로 리턴값에
    // 담을 수 없는 "어느 타입 매개변수였는지" 이름을 넘겨주는 보조 채널. 호출 직후 곧바로 읽어야 한다.
    fLastGenericName: string;

    function Cur: TToken; begin Result:=fTokens[fPos]; end;

    function Expect(k: TTokenKind): TToken;
    var t: TToken;
    begin
      t:=Cur;
      if t.Kind<>k then
        raise new Exception('줄 '+t.Line.ToString+', 열 '+t.Column.ToString+': 예상 '+k.ToString
          +' 실제 '+t.Kind.ToString+' ("'+t.Text+'")');
      fPos:=fPos+1; Result:=t;
    end;

    // [Stage 41] 점(.) 뒤 멤버 이름 소비 헬퍼.
    // .Length, .Count 등 Lexer가 키워드 토큰으로 분류하는 이름도
    // 속성/메서드 이름으로 허용한다. tkIdent이거나 알려진 키워드이면 통과.
    function ExpectMemberName: string;
    var t: TToken;
    begin
      t:=Cur;
      if (t.Kind=tkIdent) or (t.Kind=tkLength) then
      begin
        fPos:=fPos+1; Result:=t.Text;
      end
      else
        raise new Exception('줄 '+t.Line.ToString+', 열 '+t.Column.ToString
          +': 멤버 이름이 와야 합니다 ("'+t.Text+'")');
    end;

    function ParseVarType: TVarType;
    begin
      fLastGenericName:='';
      if (Cur.Kind=tkIdent) and fCurGenericParams.Contains(Cur.Text) then
        begin fLastGenericName:=Cur.Text; fPos:=fPos+1; Result:=vtGeneric; end
      else if Cur.Kind=tkInteger then begin fPos:=fPos+1; Result:=vtInteger; end
      else if Cur.Kind=tkStringType then begin fPos:=fPos+1; Result:=vtString; end
      else if Cur.Kind=tkBoolean then begin fPos:=fPos+1; Result:=vtBoolean; end
      else if Cur.Kind=tkArray then
      begin
        fPos:=fPos+1; Expect(tkOf);
        if Cur.Kind=tkInteger then begin fPos:=fPos+1; Result:=vtIntArray; end
        else if Cur.Kind=tkStringType then begin fPos:=fPos+1; Result:=vtStrArray; end
        // [Stage 37] array of T — 제네릭 템플릿 본문에서만 등장. 실제 타입은 Monomorphize가 채운다.
        else if (Cur.Kind=tkIdent) and fCurGenericParams.Contains(Cur.Text) then
          begin fLastGenericName:=Cur.Text; fPos:=fPos+1; Result:=vtGenericArray; end
        else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': array of integer/string'
          +'(또는 제네릭 문맥에서는 array of T)만 지원');
      end
      else if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
      begin
        fPos:=fPos+1; Result:=vtObject;
      end
      else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 타입이 와야 합니다 ("'+Cur.Text+'")');
    end;

    // 매개변수/필드 타입 하나를 파싱한다 (기본타입/지역클래스/인터페이스/외부타입 모두 지원).
    // isExt(출력)가 true면 cn(출력)이 외부 .NET 타입 이름 (예: System.EventArgs).
    function ParseParamTypeExt(var isExt: boolean; var cn: string): TVarType;
    begin
      isExt:=false; cn:=''; fLastGenericName:='';
      if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
      begin
        cn:=Cur.Text; fPos:=fPos+1; Result:=vtObject;
        if (Cur.Kind=tkLt) and fGenericClassNames.Contains(cn) then cn:=ResolveGenericInstantiation(cn);
      end
      else if (Cur.Kind=tkIdent) and fInterfaceNames.Contains(Cur.Text) then
      begin cn:=Cur.Text; fPos:=fPos+1; Result:=vtInterface; end
      else if Cur.Kind=tkIdent then
      begin
        var savedPos4:=fPos;
        var qn4:=Expect(tkIdent).Text;
        if Cur.Kind=tkDot then
        begin
          while Cur.Kind=tkDot do begin fPos:=fPos+1; qn4:=qn4+'.'+Expect(tkIdent).Text; end;
          cn:=qn4; isExt:=true; Result:=vtObject;
        end
        else
        begin
          fPos:=savedPos4;
          Result:=ParseVarType; // 기본 타입도 지역클래스도 아니면 여기서 명확한 에러
        end;
      end
      else
        Result:=ParseVarType;
    end;

    // [Stage 34] 타입 매개변수 하나 뒤에 선택적으로 붙는 제약조건을 파싱한다: <T: TAnimal>, <T: IComparable>, <T: class>
    // 호출 시점에 매개변수 이름(T 등)은 이미 소비된 상태. 콜론이 없으면 제약 없음('')을 돌려준다.
    function ParseOptionalGenericConstraint: string;
    var constraintName: string;
    begin
      if Cur.Kind<>tkColon then begin Result:=''; exit; end;
      fPos:=fPos+1; // ':' 소비
      if Cur.Kind=tkClass then begin fPos:=fPos+1; Result:='class'; exit; end; // T: class (임의의 참조 타입)
      if Cur.Kind<>tkIdent then
        raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 제약조건에는 클래스/인터페이스 이름 또는 "class"가 와야 합니다');
      constraintName:=Cur.Text; fPos:=fPos+1;
      if (not fClassNames.Contains(constraintName)) and (not fInterfaceNames.Contains(constraintName)) then
        raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제약조건 "'+constraintName+'"는 알 수 없는 클래스/인터페이스입니다');
      Result:=constraintName;
    end;

    // [Stage 34] 타입 인자(클래스 이름)가 제약조건(클래스/인터페이스 이름 또는 'class')을 만족하는지 검사.
    // 상속 체인(fClassParent)과 구현 인터페이스(fClassInterface)를 따라 올라가며 확인한다.
    function SatisfiesConstraint(className, constraintName: string): boolean;
    var cur: string;
    begin
      if constraintName='class' then begin Result:=true; exit; end; // 'class' 제약: 임의의 참조 타입 허용
      cur:=className;
      while cur<>'' do
      begin
        if cur=constraintName then begin Result:=true; exit; end;
        if fClassInterface.ContainsKey(cur) and (fClassInterface[cur]=constraintName) then
          begin Result:=true; exit; end;
        if fClassParent.ContainsKey(cur) then cur:=fClassParent[cur] else cur:='';
      end;
      Result:=false;
    end;

    // Stage26/[Stage 32] 제네릭 인스턴스화 (예: TStack<integer>, TPair<integer,string>,
    // TStack<TStack<integer>>) 해석.
    // 호출 시점에 templateName은 이미 소비된 상태이고 Cur='<' 이어야 한다.
    // '<' TypeArg (',' TypeArg)* '>' 를 소비하고, 아직 등록되지 않은 조합이면
    // fProg.GenericInstantiations에 요청을 등록한 뒤, 실제로 CodeGen이 다루게 될 구체 클래스 이름을 돌려준다.
    // [Stage 32] 타입 인자 자신이 다른 제네릭 인스턴스(TStack<integer> 등)이면 재귀적으로
    // 먼저 해석해 그 구체 클래스 이름을 인자로 사용한다(중첩 제네릭).
    function ResolveGenericInstantiation(templateName: string): string;
    var
      argTypes: List<TVarType>; argClassNames, argTags: List<string>;
      concreteName: string; oneType: TVarType; oneClassName, oneTag: string;
    begin
      Expect(tkLt);

      argTypes:=new List<TVarType>; argClassNames:=new List<string>; argTags:=new List<string>;
      while true do
      begin
        oneClassName:='';
        if Cur.Kind=tkInteger then begin fPos:=fPos+1; oneType:=vtInteger; oneTag:='integer'; end
        else if Cur.Kind=tkStringType then begin fPos:=fPos+1; oneType:=vtString; oneTag:='string'; end
        else if Cur.Kind=tkBoolean then begin fPos:=fPos+1; oneType:=vtBoolean; oneTag:='boolean'; end
        else if (Cur.Kind=tkIdent) and fGenericClassNames.Contains(Cur.Text) then
        begin
          // [Stage 32] 중첩 제네릭: 타입 인자 자체가 TStack<...> 형태
          var nestedTemplate:=Cur.Text; fPos:=fPos+1;
          if Cur.Kind<>tkLt then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 클래스 "'+nestedTemplate
              +'"는 타입 인자 없이 쓸 수 없습니다 (예: '+nestedTemplate+'<integer>)');
          var nestedConcrete:=ResolveGenericInstantiation(nestedTemplate);
          oneType:=vtObject; oneClassName:=nestedConcrete; oneTag:=nestedConcrete;
        end
        else if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
          begin oneClassName:=Cur.Text; oneType:=vtObject; oneTag:=Cur.Text; fPos:=fPos+1; end
        else
          raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 타입 인자로 지원되지 않는 타입 ("'+Cur.Text
            +'") — integer/string/boolean, 일반 클래스, 또는 다른 제네릭 인스턴스만 가능합니다');

        argTypes.Add(oneType); argClassNames.Add(oneClassName); argTags.Add(oneTag);

        if Cur.Kind=tkComma then fPos:=fPos+1 else break;
      end;

      Expect(tkGt);

      // [Stage 32] 타입 매개변수 개수 검증 (예: TPair는 2개인데 1개만 준 경우)
      if fClassGenericParam.ContainsKey(templateName)
         and (fClassGenericParam[templateName].Count<>argTypes.Count) then
        raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 클래스 "'+templateName+'"는 타입 매개변수 '
          +fClassGenericParam[templateName].Count.ToString+'개가 필요한데 '+argTypes.Count.ToString+'개가 주어졌습니다');

      // [Stage 34] 제약조건 검증 (T: TAnimal, T: IComparable, T: class 등)
      if fClassGenericConstraint.ContainsKey(templateName) then
      begin
        var constraints:=fClassGenericConstraint[templateName];
        for var ci:=0 to constraints.Count-1 do
        begin
          if constraints[ci]<>'' then
          begin
            if (argTypes[ci]<>vtObject) or (not SatisfiesConstraint(argClassNames[ci], constraints[ci])) then
              raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 타입 인자 "'+argTags[ci]
                +'"는 제약조건 "'+constraints[ci]+'"을(를) 만족하지 않습니다 (타입 매개변수 "'
                +fClassGenericParam[templateName][ci]+'")');
          end;
        end;
      end;

      concreteName:=templateName;
      foreach var tag in argTags do concreteName:=concreteName+'_'+tag;

      if not fClassNames.Contains(concreteName) then
      begin
        fClassNames.Add(concreteName);
        fClassFields[concreteName]:=new List<string>(fClassFields[templateName]);
        fClassMethods[concreteName]:=new Dictionary<string, boolean>(fClassMethods[templateName]);
        fClassParent[concreteName]:='';
        fClassInterface[concreteName]:=''; // [Stage 36] SatisfiesConstraint가 안전하게 조회할 수 있도록 기본값 등록
        fProg.GenericInstantiations.Add(new TGenericInstantiation(templateName, concreteName, argTypes, argClassNames));
      end;

      Result:=concreteName;
    end;

    // [Stage 36] 함수/프로시저 이름 뒤의 선택적 제네릭 타입 매개변수 목록을 파싱한다:
    //   function Identity<T>(x: T): T;         procedure Swap<T: class>(a, b: T);
    // '<'가 없으면 빈 목록 두 개를 돌려준다(제네릭 아님). 클래스 쪽 파싱 로직과 동일한 패턴이며
    // ParseOptionalGenericConstraint(위 [Stage 34])를 그대로 재사용한다.
    procedure ParseCallableGenericParams(var names, constraints: List<string>);
    begin
      names:=new List<string>; constraints:=new List<string>;
      if Cur.Kind=tkLt then
      begin
        fPos:=fPos+1;
        names.Add(Expect(tkIdent).Text);
        constraints.Add(ParseOptionalGenericConstraint);
        while Cur.Kind=tkComma do
        begin
          fPos:=fPos+1;
          names.Add(Expect(tkIdent).Text);
          constraints.Add(ParseOptionalGenericConstraint);
        end;
        Expect(tkGt);
      end;
    end;

    // [Stage 36] 제네릭 함수/프로시저 호출 인스턴스화 (예: Identity<integer>(5), Swap<TUser>(a, b)) 해석.
    // ResolveGenericInstantiation(클래스용)과 동일한 구조이며, 호출 시점에 templateName은 이미
    // 소비된 상태이고 Cur='<' 이어야 한다. isProc으로 함수/프로시저 어느 쪽 템플릿인지 구분한다.
    // 주의: 현재는 명시적 타입 인자만 지원한다 — Identity(5) 같은 타입 추론 호출은 지원하지 않으며,
    // 타입 인자로 바깥 스코프의 제네릭 매개변수(T 자신)를 넘기는 것도 아직 지원하지 않는다.
    function ResolveGenericFuncInstantiation(templateName: string; isProc: boolean): string;
    var
      argTypes: List<TVarType>; argClassNames, argTags: List<string>;
      concreteName: string; oneType: TVarType; oneClassName, oneTag: string;
      paramNames, constraintList: List<string>; kindLabel: string;
    begin
      Expect(tkLt);

      if isProc then kindLabel:='프로시저' else kindLabel:='함수';

      paramNames:=nil; constraintList:=nil;
      if isProc then
      begin
        if fProcGenericParam.ContainsKey(templateName) then paramNames:=fProcGenericParam[templateName];
        if fProcGenericConstraint.ContainsKey(templateName) then constraintList:=fProcGenericConstraint[templateName];
      end
      else
      begin
        if fFuncGenericParam.ContainsKey(templateName) then paramNames:=fFuncGenericParam[templateName];
        if fFuncGenericConstraint.ContainsKey(templateName) then constraintList:=fFuncGenericConstraint[templateName];
      end;

      argTypes:=new List<TVarType>; argClassNames:=new List<string>; argTags:=new List<string>;
      while true do
      begin
        oneClassName:='';
        if Cur.Kind=tkInteger then begin fPos:=fPos+1; oneType:=vtInteger; oneTag:='integer'; end
        else if Cur.Kind=tkStringType then begin fPos:=fPos+1; oneType:=vtString; oneTag:='string'; end
        else if Cur.Kind=tkBoolean then begin fPos:=fPos+1; oneType:=vtBoolean; oneTag:='boolean'; end
        else if (Cur.Kind=tkIdent) and fGenericClassNames.Contains(Cur.Text) then
        begin
          // 중첩 제네릭: 타입 인자 자체가 TBox<...> 형태
          var nestedTemplate:=Cur.Text; fPos:=fPos+1;
          if Cur.Kind<>tkLt then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 클래스 "'+nestedTemplate
              +'"는 타입 인자 없이 쓸 수 없습니다 (예: '+nestedTemplate+'<integer>)');
          var nestedConcrete:=ResolveGenericInstantiation(nestedTemplate);
          oneType:=vtObject; oneClassName:=nestedConcrete; oneTag:=nestedConcrete;
        end
        else if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
          begin oneClassName:=Cur.Text; oneType:=vtObject; oneTag:=Cur.Text; fPos:=fPos+1; end
        else
          raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 '+kindLabel+' 타입 인자로 지원되지 않는 타입 ("'+Cur.Text
            +'") — integer/string/boolean, 일반 클래스, 또는 다른 제네릭 인스턴스만 가능합니다');

        // [Stage 36] 제약조건 검증 (T: TAnimal, T: IComparable, T: class 등)
        if (constraintList<>nil) and (argTypes.Count<constraintList.Count) and (constraintList[argTypes.Count]<>'') then
        begin
          if (oneType<>vtObject) or (not SatisfiesConstraint(oneClassName, constraintList[argTypes.Count])) then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 '+kindLabel+' "'+templateName
              +'"의 타입 인자 "'+oneTag+'"는 제약조건 "'+constraintList[argTypes.Count]+'"을(를) 만족하지 않습니다 (타입 매개변수 "'
              +paramNames[argTypes.Count]+'")');
        end;

        argTypes.Add(oneType); argClassNames.Add(oneClassName); argTags.Add(oneTag);

        if Cur.Kind=tkComma then fPos:=fPos+1 else break;
      end;

      Expect(tkGt);

      // [Stage 36] 타입 매개변수 개수 검증
      if (paramNames<>nil) and (paramNames.Count<>argTypes.Count) then
        raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 '+kindLabel+' "'+templateName+'"는 타입 매개변수 '
          +paramNames.Count.ToString+'개가 필요한데 '+argTypes.Count.ToString+'개가 주어졌습니다');

      concreteName:=templateName;
      foreach var tag in argTags do concreteName:=concreteName+'_'+tag;

      if isProc then
      begin
        if not fProcNames.Contains(concreteName) then
        begin
          fProcNames.Add(concreteName);
          fProg.GenericFuncInstantiations.Add(new TGenericFuncInstantiation(templateName, concreteName, true, argTypes, argClassNames));
        end;
      end
      else
      begin
        if not fFuncNames.Contains(concreteName) then
        begin
          fFuncNames.Add(concreteName);
          fProg.GenericFuncInstantiations.Add(new TGenericFuncInstantiation(templateName, concreteName, false, argTypes, argClassNames));
        end;
      end;

      Result:=concreteName;
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

      else if t.Kind=tkNil then
        begin fPos:=fPos+1; Result:=new TNilLiteralNode; end // [Stage 29]

      else if t.Kind=tkSelf then // [Stage 30]
      begin
        fPos:=fPos+1;
        if Cur.Kind=tkDot then
        begin
          // self.Xxx / self.Xxx(...) → 기존 암시적 self 필드읽기/메서드호출(ObjName='')로 환원.
          // (self가 필드/외부 상속 타입 어느 쪽이든 CodeGen이 이미 판별해준다.)
          fPos:=fPos+1;
          var selfMname:=ExpectMemberName; // [Stage 41] 키워드 속성명(Length 등) 허용
          if Cur.Kind=tkLParen then
          begin
            mc:=new TMethodCallExprNode('', selfMname); fPos:=fPos+1;
            if Cur.Kind<>tkRParen then
            begin
              mc.Args.Add(ParseAddSub);
              while Cur.Kind=tkComma do begin fPos:=fPos+1; mc.Args.Add(ParseAddSub); end;
            end;
            Expect(tkRParen);
            Result:=mc;
          end
          else
            Result:=new TFieldReadExprNode(selfMname);
        end
        else
          Result:=new TSelfExprNode; // self 자체를 값으로 사용 (예: 인자로 전달, as 캐스트 대상)
      end

      else if t.Kind=tkInherited then // [Stage 30] 식으로 쓰이는 inherited (예: Result := inherited GetValue();)
      begin
        fPos:=fPos+1;
        var imnE:=Expect(tkIdent).Text;
        var iceN:=new TInheritedCallExprNode(imnE);
        if Cur.Kind=tkLParen then
        begin
          fPos:=fPos+1;
          if Cur.Kind<>tkRParen then
          begin
            iceN.Args.Add(ParseAddSub);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; iceN.Args.Add(ParseAddSub); end;
          end;
          Expect(tkRParen);
        end;
        Result:=iceN;
      end

      // [Stage 40] new TypeName(args) — PascalABC.NET 스타일 객체 생성 구문.
      // 기존 "TypeName.Create" 관용구와 별개로, 인자 있는 생성자 호출을 지원하기 위해 추가.
      // TypeName은 로컬 클래스(제네릭 인스턴스화 포함)이거나 점(.)으로 연결된 외부 .NET 타입.
      else if t.Kind=tkNew then
      begin
        fPos:=fPos+1; // 'new' 소비
        var newTn:=Expect(tkIdent).Text;
        if (Cur.Kind=tkLt) and fGenericClassNames.Contains(newTn) then
          newTn:=ResolveGenericInstantiation(newTn);
        while Cur.Kind=tkDot do begin fPos:=fPos+1; newTn:=newTn+'.'+Expect(tkIdent).Text; end;
        var neoN:=new TNewObjectExprNode(newTn);
        neoN.IsExternalType:=not fClassNames.Contains(newTn);
        if Cur.Kind=tkLParen then
        begin
          fPos:=fPos+1;
          if Cur.Kind<>tkRParen then
          begin
            neoN.Args.Add(ParseExpr);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; neoN.Args.Add(ParseExpr); end;
          end;
          Expect(tkRParen);
        end;
        Result:=neoN;
      end

      else if t.Kind=tkNot then
        begin fPos:=fPos+1; Result:=new TNotExprNode(ParsePrimary); end

      else if t.Kind=tkIntToStr then
      begin
        fPos:=fPos+1; Expect(tkLParen);
        argE:=ParseAddSub; Expect(tkRParen);
        Result:=new TIntToStrNode(argE);
      end

      // [Stage 41] tkLength 단독 분기 제거 — 'length'는 이제 tkIdent로 내려오므로
      // tkIdent 분기 안에서 텍스트로 구분한다 (아래 참조).

      else if t.Kind=tkIdent then
      begin
        fPos:=fPos+1;

        // Stage26: TStack<integer> 처럼 제네릭 클래스 이름 뒤에 '<' 가 이어지면
        // 그 자리에서 단형화 요청을 등록하고, 이후 로직은 구체 클래스 이름(gcn)으로 진행한다.
        var gcn:=t.Text;
        if (Cur.Kind=tkLt) and fGenericClassNames.Contains(gcn) then
          gcn:=ResolveGenericInstantiation(gcn);

        // 클래스명.Create → TNewObjectExprNode (지역 클래스 또는 점(.)으로 연결된 외부 타입)
        if (Cur.Kind=tkDot) and fClassNames.Contains(gcn) then
        begin
          fPos:=fPos+1; // '.' 소비
          var mname:=Expect(tkIdent);
          if mname.Text.ToLower='create' then
          begin
            Result:=new TNewObjectExprNode(gcn);
          end
          else
          begin
            // 클래스명.메서드 (함수 호출로서 식)
            mc:=new TMethodCallExprNode(gcn, mname.Text);
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

        // 점(.)으로 연결된 외부 타입의 .Create (예: System.Windows.Forms.Button.Create)
        // 또는 TypeName(expr).member 캐스트 읽기 (예: System.Windows.Forms.Button(sender).Text)
        // fClassNames에 없는 식별자로 시작하고, 점이 여러 번 이어지는 경우.
        else if (Cur.Kind=tkDot) then
        begin
          var savedPos3:=fPos; var segs2:=new List<string>; segs2.Add(t.Text);
          while Cur.Kind=tkDot do
          begin fPos:=fPos+1; segs2.Add(ExpectMemberName); end; // [Stage 41] 키워드 속성명(Length 등) 허용
          if segs2[segs2.Count-1].ToLower='create' then
          begin
            var neo2:=new TNewObjectExprNode(string.Join('.', segs2.GetRange(0, segs2.Count-1)));
            neo2.IsExternalType:=true;
            Result:=neo2;
          end
          else if (Cur.Kind=tkLParen) and (segs2.Count>1) then
          begin
            // TypeName(expr).member 캐스트 읽기 패턴인지 확인해본다.
            // segs2 전체가 사실 타입 이름이고, 괄호 안 인자(정확히 1개)가 캐스트 대상.
            var savedPos5:=fPos;
            fPos:=fPos+1; // '(' 소비
            var castArgs2:=new List<TExprNode>;
            if Cur.Kind<>tkRParen then
            begin
              castArgs2.Add(ParseExpr);
              while Cur.Kind=tkComma do begin fPos:=fPos+1; castArgs2.Add(ParseExpr); end;
            end;
            Expect(tkRParen);
            if (castArgs2.Count=1) and (Cur.Kind=tkDot) then
            begin
              var castType2:=string.Join('.', segs2);
              var innerName2:='';
              if castArgs2[0] is TVarRefNode then innerName2:=TVarRefNode(castArgs2[0]).VarName
              else if castArgs2[0] is TFieldReadExprNode then innerName2:=TFieldReadExprNode(castArgs2[0]).FieldName
              else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 캐스트 대상은 단순 변수/필드 이름이어야 합니다');
              fPos:=fPos+1; // '.' 소비
              var member3:=ExpectMemberName; // [Stage 41] 키워드 속성명(Length 등) 허용
              var mc3:=new TMethodCallExprNode(innerName2, member3);
              mc3.ObjCastType:=castType2;
              if Cur.Kind=tkLParen then
              begin
                fPos:=fPos+1;
                if Cur.Kind<>tkRParen then
                begin
                  mc3.Args.Add(ParseAddSub);
                  while Cur.Kind=tkComma do begin fPos:=fPos+1; mc3.Args.Add(ParseAddSub); end;
                end;
                Expect(tkRParen);
              end;
              Result:=mc3;
            end
            else
            begin
              // 캐스트 패턴이 아니면 정적(static) 메서드 호출로 간주한다
              // (예: System.Windows.Forms.MessageBox.Show(...) 를 식으로 사용).
              var staticQualifier:=string.Join('.', segs2.GetRange(0, segs2.Count-1));
              var staticMname:=segs2[segs2.Count-1];
              var mc4:=new TMethodCallExprNode(staticQualifier, staticMname);
              foreach var a6 in castArgs2 do mc4.Args.Add(a6);
              Result:=mc4;
            end;
          end
          else if segs2.Count>2 then
          begin
            // 괄호 없이 3단계 이상 점(.)으로 연결된 경우 = 정적 필드/속성 읽기
            // (예: System.EventArgs.Empty). 지역 변수/필드 이름에는 점이 없으므로
            // 2단계(obj.Member)와 명확히 구분된다.
            var staticType:=string.Join('.', segs2.GetRange(0, segs2.Count-1));
            var staticMember:=segs2[segs2.Count-1];
            Result:=new TStaticMemberExprNode(staticType, staticMember);
          end
          else
          begin
            // Create도 캐스트도 아니면 기존처럼 obj.Method 식으로 되돌린다 (한 단계만 지원)
            fPos:=savedPos3;
            fPos:=fPos+1; // '.' 소비
            var mname2:=ExpectMemberName; // [Stage 41] 키워드 속성명(Length 등) 허용
            if mname2.ToLower='message' then
              Result:=new TExceptionMsgExprNode(t.Text)
            else
            begin
              mc:=new TMethodCallExprNode(t.Text, mname2);
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
          end;
        end

        // 배열 인덱스
        else if (Cur.Kind=tkLBracket) and fArrayNames.Contains(t.Text) then
        begin
          fPos:=fPos+1; idxE:=ParseAddSub; Expect(tkRBracket);
          Result:=new TArrayIndexExprNode(t.Text, idxE);
        end

        // [Stage 36] 제네릭 함수 호출: Identity<integer>(5) — 명시적 타입 인자 필요
        else if (Cur.Kind=tkLt) and fGenericFuncNames.Contains(t.Text) then
        begin
          var concreteFuncName:=ResolveGenericFuncInstantiation(t.Text, false);
          cn:=new TFuncCallExprNode(concreteFuncName);
          Expect(tkLParen);
          if Cur.Kind<>tkRParen then
          begin
            cn.Args.Add(ParseAddSub);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; cn.Args.Add(ParseAddSub); end;
          end;
          Expect(tkRParen); Result:=cn;
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

        // [Stage 41] 'length'가 tkIdent로 들어오는 경우: Length(arr) 단독 함수 호출.
        // Lexer에서 tkLength 키워드로 분류하던 것을 tkIdent로 내리면서 이 분기로 이동.
        else if (t.Text.ToLower='length') and (Cur.Kind=tkLParen) then
        begin
          fPos:=fPos+1; // '(' 소비 (t는 이미 소비됨)
          var ntL:=Expect(tkIdent); Expect(tkRParen);
          Result:=new TLengthExprNode(ntL.Text);
        end

        else
        begin
          // 메서드 본문 안에서의 식별자 읽기: 매개변수 이름이면 지역 변수 참조,
          // 그렇지 않으면 필드/속성 읽기로 취급한다.
          // (var 섹션보다 메서드가 먼저 파싱되어 전역변수 이름을 알 수 없고,
          //  이 경로로 전역변수를 읽는 기존 코드도 없었음. 지역 필드든 외부
          //  상속 타입의 속성이든 CodeGen 단계에서 최종 판별한다.)
          if (fCurClass<>'') and not fCurParams.Contains(t.Text) then
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
        raise new Exception('줄 '+t.Line.ToString+', 열 '+t.Column.ToString+': 식이 와야 하는데 "'+t.Text+'"');
    end;

    // [Stage 30] <식> as <TypeName> — Delphi에서 as는 *,/,mod와 같은 우선순위이므로
    // ParsePrimary 바로 위, ParseMulDivMod가 사용하는 자리에 끼워 넣는다.
    function ParseAsCast: TExprNode;
    var e: TExprNode; tn: string; isExt: boolean; asN: TAsCastExprNode;
    begin
      e:=ParsePrimary;
      while Cur.Kind=tkAs do
      begin
        fPos:=fPos+1;
        tn:=Expect(tkIdent).Text; isExt:=false;
        while Cur.Kind=tkDot do begin fPos:=fPos+1; tn:=tn+'.'+Expect(tkIdent).Text; end;
        if not (fClassNames.Contains(tn) or fInterfaceNames.Contains(tn)) then isExt:=true;
        asN:=new TAsCastExprNode(e, tn); asN.IsExternalType:=isExt;
        e:=asN;
      end;
      Result:=e;
    end;

    function ParseMulDivMod: TExprNode;
    var left: TExprNode; op: TBinOpKind;
    begin
      left:=ParseAsCast;
      while (Cur.Kind=tkStar) or (Cur.Kind=tkSlash) or (Cur.Kind=tkMod) or (Cur.Kind=tkAnd) do
      begin
        if Cur.Kind=tkStar then op:=boMul
        else if Cur.Kind=tkSlash then op:=boDiv
        else if Cur.Kind=tkMod then op:=boMod
        else op:=boAnd; // tkAnd — 표준 Pascal에서 and는 *,/,mod와 같은 우선순위
        fPos:=fPos+1; left:=new TBinOpNode(op, left, ParseAsCast);
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
        // 또는 System.Windows.Forms.Application.Run(f) 처럼 여러 단계 점(.)으로
        // 연결된 외부 타입의 정적(static) 멤버 호출. 마지막 세그먼트가 메서드
        // 이름이고, 그 앞부분 전체가 대상(지역 변수 또는 외부 타입 이름)이다.
        // 실제로 지역 변수인지 외부 타입인지는 CodeGen 단계에서 판별한다.
        if Cur.Kind=tkDot then
        begin
          var segs:=new List<string>; segs.Add(nt.Text);
          while Cur.Kind=tkDot do
          begin
            fPos:=fPos+1;
            segs.Add(ExpectMemberName); // [Stage 41] 키워드 속성명(Length 등) 허용
          end;
          var mname:=segs[segs.Count-1];
          var qualifier:=string.Join('.', segs.GetRange(0, segs.Count-1));
          if Cur.Kind=tkAssign then
          begin
            // Button1.Text := '...' 처럼 필드/전역변수/외부타입을 통한
            // 한정(qualified) 속성·필드 대입. 대상이 무엇인지는 CodeGen이 판별한다.
            fPos:=fPos+1; rhs:=ParseExpr;
            var fas2:=new TFieldAssignStmtNode(mname, rhs);
            fas2.Qualifier:=qualifier;
            Result:=fas2;
          end
          else if Cur.Kind=tkPlusAssign then
          begin
            // Button1.Click += Button1_Click;  이벤트 구독.
            // 오른쪽은 항상 "현재 클래스의 메서드 이름" 하나만 온다 (괄호 없음).
            fPos:=fPos+1;
            var handlerName:=Expect(tkIdent).Text;
            Result:=new TEventSubscribeStmtNode(qualifier, mname, handlerName);
          end
          else
          begin
            // 괄호를 먼저 파싱해본다 — 정적 호출의 인자일 수도, 캐스트 대상(단일 인자)일 수도 있다.
            var callArgs:=new List<TExprNode>; var hadParen:=false;
            if Cur.Kind=tkLParen then
            begin
              hadParen:=true; fPos:=fPos+1;
              if Cur.Kind<>tkRParen then
              begin
                callArgs.Add(ParseExpr);
                while Cur.Kind=tkComma do begin fPos:=fPos+1; callArgs.Add(ParseExpr); end;
              end;
              Expect(tkRParen);
            end;

            if hadParen and (callArgs.Count=1) and (Cur.Kind=tkDot) then
            begin
              // TypeName(expr).member ...  캐스트 패턴으로 재해석.
              // qualifier+'.'+mname 전체가 사실 타입 이름이었고, callArgs[0]이 캐스트 대상.
              var castType:=qualifier+'.'+mname;
              var innerName:='';
              if callArgs[0] is TVarRefNode then innerName:=TVarRefNode(callArgs[0]).VarName
              else if callArgs[0] is TFieldReadExprNode then innerName:=TFieldReadExprNode(callArgs[0]).FieldName
              else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 캐스트 대상은 단순 변수/필드 이름이어야 합니다');

              fPos:=fPos+1; // '.' 소비
              var member2:=Expect(tkIdent).Text;

              if Cur.Kind=tkAssign then
              begin
                fPos:=fPos+1; rhs:=ParseExpr;
                var fas3:=new TFieldAssignStmtNode(member2, rhs);
                fas3.Qualifier:=innerName; fas3.QualifierCastType:=castType;
                Result:=fas3;
              end
              else if Cur.Kind=tkPlusAssign then
              begin
                fPos:=fPos+1;
                var handlerName2:=Expect(tkIdent).Text;
                var evs2:=new TEventSubscribeStmtNode(innerName, member2, handlerName2);
                evs2.QualifierCastType:=castType;
                Result:=evs2;
              end
              else
              begin
                var mcs2:=new TMethodCallStmtNode(innerName, member2);
                mcs2.ObjCastType:=castType;
                if Cur.Kind=tkLParen then
                begin
                  fPos:=fPos+1;
                  if Cur.Kind<>tkRParen then
                  begin
                    mcs2.Args.Add(ParseExpr);
                    while Cur.Kind=tkComma do begin fPos:=fPos+1; mcs2.Args.Add(ParseExpr); end;
                  end;
                  Expect(tkRParen);
                end;
                Result:=mcs2;
              end;
            end
            else
            begin
              // 기존처럼: 정적 호출 또는 필드/변수 경유 메서드 호출
              mcs:=new TMethodCallStmtNode(qualifier, mname);
              foreach var a5 in callArgs do mcs.Args.Add(a5);
              Result:=mcs;
            end;
          end;
        end

        // [Stage 36] 제네릭 프로시저 호출: Swap<TUser>(a, b) — 명시적 타입 인자 필요
        else if (Cur.Kind=tkLt) and fGenericProcNames.Contains(nt.Text) then
        begin
          var concreteProcName:=ResolveGenericFuncInstantiation(nt.Text, true);
          pcn:=new TProcCallStmtNode(concreteProcName);
          Expect(tkLParen);
          if Cur.Kind<>tkRParen then
          begin
            pcn.Args.Add(ParseExpr);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; pcn.Args.Add(ParseExpr); end;
          end;
          Expect(tkRParen); Result:=pcn;
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

        // 암시적 self 메서드 호출 (괄호 있음): 예) Show(); Close(42);
        // 메서드 본문 안에서만 의미 있음. 로컬 메서드면 그대로, 아니면 외부
        // 상속 타입(Reflection)에서 찾는다 — 실제 판별은 CodeGen 단계에서.
        else if (fCurClass<>'') and (Cur.Kind=tkLParen) then
        begin
          mcs:=new TMethodCallStmtNode('', nt.Text); fPos:=fPos+1;
          if Cur.Kind<>tkRParen then
          begin
            mcs.Args.Add(ParseExpr);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; mcs.Args.Add(ParseExpr); end;
          end;
          Expect(tkRParen); Result:=mcs;
        end

        // 암시적 self 메서드 호출 (괄호 없음, 인자 없음): 예) Show; Close;
        else if (fCurClass<>'') and (Cur.Kind=tkSemicolon) then
          Result:=new TMethodCallStmtNode('', nt.Text)

        // 배열 원소 대입
        else if (Cur.Kind=tkLBracket) and fArrayNames.Contains(nt.Text) then
        begin
          fPos:=fPos+1; idx:=ParseExpr; Expect(tkRBracket);
          Expect(tkAssign); rhs:=ParseExpr;
          Result:=new TArrayAssignStmtNode(nt.Text, idx, rhs);
        end

        // 대입문 (일반 변수 또는 필드/외부 속성)
        else
        begin
          Expect(tkAssign); rhs:=ParseExpr;
          // 메서드 본문 안에서의 대입: 매개변수 이름이면 지역 변수 대입으로,
          // 그렇지 않으면 필드/속성 쓰기로 취급한다.
          // (메서드는 var 섹션보다 먼저 파싱되므로 전역변수 이름 목록을 알 수 없고,
          //  실제로 이 경로로 전역변수에 대입하는 기존 코드도 없었음 — 지역 필드든
          //  외부 상속 타입의 속성이든 CodeGen 단계에서 최종 판별한다.)
          if (fCurClass<>'') and not fCurParams.Contains(nt.Text) then
            Result:=new TFieldAssignStmtNode(nt.Text, rhs)
          else
            Result:=new TAssignStmtNode(nt.Text, rhs);
        end;
      end

      // [Stage 30] self.Xxx := ...; / self.Xxx(...); / self.Event += Handler; 문장.
      // ParsePrimary의 self.Xxx 식 처리와 마찬가지로 기존 암시적 self 경로(Qualifier/ObjName='')
      // 로 환원해 재사용한다.
      else if Cur.Kind=tkSelf then
      begin
        fPos:=fPos+1; Expect(tkDot);
        var selfMname2:=Expect(tkIdent).Text;
        if Cur.Kind=tkAssign then
        begin
          fPos:=fPos+1; rhs:=ParseExpr;
          Result:=new TFieldAssignStmtNode(selfMname2, rhs); // Qualifier='' → self 필드/속성 대입
        end
        else if Cur.Kind=tkPlusAssign then
        begin
          fPos:=fPos+1;
          var handlerName3:=Expect(tkIdent).Text;
          Result:=new TEventSubscribeStmtNode('', selfMname2, handlerName3); // Qualifier='' → self가 이벤트 소유자
        end
        else
        begin
          mcs:=new TMethodCallStmtNode('', selfMname2);
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
        else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': for문에는 to 또는 downto가 와야 합니다');
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

      // [Stage 30] inherited MethodName(args); / inherited MethodName; / inherited;
      // bare 'inherited;'는 현재 메서드와 같은 이름 + 같은 매개변수를 그대로 부모에게 전달한다
      // (오버라이드 관용구: procedure TDerived.Init(x: integer); begin inherited; ... end;).
      else if Cur.Kind=tkInherited then
      begin
        fPos:=fPos+1;
        if (Cur.Kind=tkSemicolon) or (Cur.Kind=tkEnd) then
        begin
          var ihs:=new TInheritedCallStmtNode(fCurFunc);
          foreach var pnm2 in fCurMethodParamNames do ihs.Args.Add(new TVarRefNode(pnm2));
          Result:=ihs;
        end
        else
        begin
          var imn:=Expect(tkIdent).Text;
          var ihs2:=new TInheritedCallStmtNode(imn);
          if Cur.Kind=tkLParen then
          begin
            fPos:=fPos+1;
            if Cur.Kind<>tkRParen then
            begin
              ihs2.Args.Add(ParseExpr);
              while Cur.Kind=tkComma do begin fPos:=fPos+1; ihs2.Args.Add(ParseExpr); end;
            end;
            Expect(tkRParen);
          end;
          Result:=ihs2;
        end;
      end

      else
        raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 알 수 없는 문장 ("'+Cur.Text+'")');
    end;

    // 인터페이스 안의 메서드 시그니처 하나 파싱 (본문 없음)
    function ParseInterfaceMethodSig: TMethodSignature;
    var isFunc: boolean; retType: TVarType; sig: TMethodSignature; pnames: List<string>; pt: TVarType;
    begin
      isFunc:=(Cur.Kind=tkFunction);
      if not ((Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure)) then
        raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 인터페이스 안에는 메서드 시그니처만 올 수 있습니다 ("'+Cur.Text+'")');
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
            Expect(tkColon);
            var pIsExt:=false; var pCn:='';
            pt:=ParseParamTypeExt(pIsExt, pCn);
            foreach var pnm in pnames do
            begin
              sig.ParamNames.Add(pnm); sig.ParamTypes.Add(pt);
              sig.ParamClassNames.Add(pCn); sig.ParamIsExternal.Add(pIsExt);
            end;
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

        // 선택적 제네릭 타입 매개변수: TStack<T> = class ... end; 또는 [Stage 32] TPair<K,V> = class ... end;
        // [Stage 34] 각 매개변수는 선택적으로 제약조건을 가질 수 있다: TBox<T: TAnimal>, TBox<T: class>
        var genParamNames:=new List<string>;
        var genParamConstraints:=new List<string>;
        if Cur.Kind=tkLt then
        begin
          fPos:=fPos+1;
          genParamNames.Add(Expect(tkIdent).Text);
          genParamConstraints.Add(ParseOptionalGenericConstraint);
          while Cur.Kind=tkComma do
          begin
            fPos:=fPos+1;
            genParamNames.Add(Expect(tkIdent).Text);
            genParamConstraints.Add(ParseOptionalGenericConstraint);
          end;
          Expect(tkGt);
        end;

        Expect(tkEq);

        // ---- 인터페이스 선언 ----
        if Cur.Kind=tkInterface then
        begin
          if genParamNames.Count>0 then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 인터페이스는 아직 지원되지 않습니다');
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
          cd.IsGeneric:=(genParamNames.Count>0); cd.GenericParamNames:=genParamNames;
          cd.GenericParamConstraints:=genParamConstraints;
          if cd.IsGeneric then
          begin
            fGenericClassNames.Add(cn);
            fClassGenericParam[cn]:=genParamNames;
            fClassGenericConstraint[cn]:=genParamConstraints;
          end;

          // 선택적 상속/인터페이스 구현: class(TParentName) 또는 class(IInterfaceName)
          // 또는 class(System.Windows.Window) 처럼 점(.)으로 연결된 외부 .NET 타입
          if Cur.Kind=tkLParen then
          begin
            fPos:=fPos+1;
            var pname:=Expect(tkIdent).Text;
            while Cur.Kind=tkDot do
            begin
              fPos:=fPos+1;
              pname:=pname+'.'+Expect(tkIdent).Text;
            end;
            if fClassNames.Contains(pname) then
              cd.ParentName:=pname
            else if fInterfaceNames.Contains(pname) then
              cd.InterfaceName:=pname
            else
            begin
              // 로컬에 없는 이름 → 외부 어셈블리 타입으로 간주 (예: System.Windows.Window).
              // 실제 존재 여부는 CodeGen 단계에서 참조된 어셈블리를 뒤져 확인한다.
              cd.ParentName:=pname;
              cd.IsExternalParent:=true;
            end;
            Expect(tkRParen);
          end;

          fClassNames.Add(cn);
          fClassParent[cn]:=cd.ParentName;
          fClassInterface[cn]:=cd.InterfaceName; // [Stage 34] 제네릭 제약조건 검증용

          // 필드/메서드 이름 목록은 부모의 것을 상속하여 시작 (필드/메서드 참조 판별용)
          // 외부 타입 상속인 경우 그 타입의 필드/메서드 목록을 알 수 없으므로 빈 목록으로 시작
          // (외부 타입 멤버 접근은 Stage15 이후 과제)
          if (cd.ParentName<>'') and (not cd.IsExternalParent) then
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
          // (본문 파싱 동안 fCurGenericParams를 설정해 T/K/V 등의 참조를 vtGeneric으로 인식시킨다)
          var savedGP1:=fCurGenericParams; fCurGenericParams:=genParamNames;
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
                    Expect(tkColon);
                    var pIsExt2:=false; var pCn2:='';
                    pt:=ParseParamTypeExt(pIsExt2, pCn2);
                    if (pt=vtGeneric) or (pt=vtGenericArray) then pCn2:=fLastGenericName; // [Stage 32/37] 어느 타입 매개변수(K/V 등)인지 기록
                    foreach var pnm in pnames do
                    begin
                      sig.ParamNames.Add(pnm); sig.ParamTypes.Add(pt);
                      sig.ParamClassNames.Add(pCn2); sig.ParamIsExternal.Add(pIsExt2);
                    end;
                    pnames.Clear;
                    if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
                  end;
                end;
                Expect(tkRParen);
              end;
              if isFunc then
              begin
                Expect(tkColon); sig.ReturnType:=ParseVarType;
                if (sig.ReturnType=vtGeneric) or (sig.ReturnType=vtGenericArray) then sig.ReturnGenericName:=fLastGenericName; // [Stage 32/37]
              end;
              Expect(tkSemicolon);
              cd.Methods.Add(sig);
              fClassMethods[cn][mname]:=isFunc;
            end

            // 필드 선언: fname : type;  (기본 타입, 지역 클래스, 또는 외부 타입 System.Windows.Forms.Button)
            else if Cur.Kind=tkIdent then
            begin
              fname:=Cur.Text; fPos:=fPos+1;
              Expect(tkColon);
              var fld:=new TFieldDeclNode(fname, vtInteger);
              if (Cur.Kind=tkIdent) and fCurGenericParams.Contains(Cur.Text) then
              begin
                fld.FieldType:=vtGeneric; fld.ClassName:=Cur.Text; fPos:=fPos+1; // [Stage 32] 어느 타입 매개변수인지 기록
              end
              else if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
              begin
                fld.FieldType:=vtObject; fld.ClassName:=Cur.Text; fPos:=fPos+1;
                if (Cur.Kind=tkLt) and fGenericClassNames.Contains(fld.ClassName) then
                  fld.ClassName:=ResolveGenericInstantiation(fld.ClassName);
              end
              else if (Cur.Kind=tkIdent) and fInterfaceNames.Contains(Cur.Text) then
              begin
                fld.FieldType:=vtInterface; fld.ClassName:=Cur.Text; fPos:=fPos+1;
              end
              else if Cur.Kind=tkIdent then
              begin
                // fClassNames/fInterfaceNames에 없는 식별자로 시작 → 점(.)으로 연결된
                // 외부 .NET 타입일 가능성 확인 (예: System.Windows.Forms.Button)
                var savedPos2:=fPos;
                var qn:=Expect(tkIdent).Text;
                if Cur.Kind=tkDot then
                begin
                  while Cur.Kind=tkDot do
                  begin fPos:=fPos+1; qn:=qn+'.'+Expect(tkIdent).Text; end;
                  fld.FieldType:=vtObject; fld.ClassName:=qn; fld.IsExternalType:=true;
                end
                else
                begin
                  fPos:=savedPos2; // 점이 없으면 기본 타입 파서로 위임 (integer/string 등의 별칭이 아니므로 오류 처리됨)
                  fld.FieldType:=ParseVarType;
                  if fld.FieldType=vtGenericArray then fld.ClassName:=fLastGenericName; // [Stage 37]
                end;
              end
              else
              begin
                fld.FieldType:=ParseVarType;
                if fld.FieldType=vtGenericArray then fld.ClassName:=fLastGenericName; // [Stage 37] 필드가 array of T인 경우
              end;
              Expect(tkSemicolon);
              cd.Fields.Add(fld);
              fClassFields[cn].Add(fname);
            end

            else
              raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 클래스 선언 안에서 알 수 없는 토큰 "'+Cur.Text+'"');
          end;

          fCurGenericParams:=savedGP1;
          Expect(tkEnd); Expect(tkSemicolon);
          aProg.ClassDecls.Add(cd);
        end;
      end;
    end;

    // [Stage 28] 함수/프로시저/메서드 본문 안의 지역 변수 선언(var 섹션)을 파싱한다.
    // 최상위 var 섹션(ParseVarSection)과 로직은 같지만, 중첩 함수/프로시저 선언이
    // 없으므로 tkBegin 하나만 만나면 끝난다.
    procedure ParseLocalVarSection(aList: List<TVarDecl>);
    var vt: TVarType; ns: List<string>; cn: string; isExt: boolean;
    begin
      Expect(tkVar);
      while Cur.Kind<>tkBegin do
      begin
        ns:=new List<string>; ns.Add(Expect(tkIdent).Text);
        while Cur.Kind=tkComma do begin fPos:=fPos+1; ns.Add(Expect(tkIdent).Text); end;
        Expect(tkColon);
        // [Stage 41] 기존에는 여기서 클래스/인터페이스/기본타입만 직접 처리하고 점(.)으로 연결된
        // 외부 .NET 타입(예: var sb: System.Text.StringBuilder;)은 지원하지 않았다. 매개변수/필드에서
        // 이미 쓰던 ParseParamTypeExt(지역클래스/인터페이스/외부타입/제네릭 모두 처리)로 통일한다.
        vt:=ParseParamTypeExt(isExt, cn);
        if (vt=vtGeneric) or (vt=vtGenericArray) then cn:=fLastGenericName; // [Stage 36/37] 제네릭 지역변수(예: var temp: T; var arr: array of T;)의 타입 매개변수 이름 보존
        Expect(tkSemicolon);
        foreach var nm in ns do
        begin
          aList.Add(new TVarDecl(nm, vt, cn, isExt));
          if (vt=vtIntArray) or (vt=vtStrArray) or (vt=vtGenericArray) then fArrayNames.Add(nm); // [Stage 37]
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

      // 제네릭 클래스(TStack<T>, [Stage 32] TPair<K,V> 등)의 메서드 구현이면, 본문의 매개변수/반환
      // 타입에서 T/K/V 등을 인식할 수 있도록 fCurGenericParams를 설정해 둔다.
      var savedGP3:=fCurGenericParams;
      if fClassGenericParam.ContainsKey(cn) then fCurGenericParams:=fClassGenericParam[cn]
      else fCurGenericParams:=new List<string>;

      // 매개변수
      if Cur.Kind=tkLParen then
      begin
        fPos:=fPos+1;
        if Cur.Kind<>tkRParen then
        begin
          while true do
          begin
            var pBatch:=new List<string>;
            var pn:=Expect(tkIdent).Text; impl.ParamNames.Add(pn); pBatch.Add(pn);
            while Cur.Kind=tkComma do
            begin
              fPos:=fPos+1; var pn2:=Expect(tkIdent).Text;
              impl.ParamNames.Add(pn2); pBatch.Add(pn2);
            end;
            Expect(tkColon);
            var pIsExt3:=false; var pCn3:='';
            pt:=ParseParamTypeExt(pIsExt3, pCn3);
            var pGenName3:=''; if (pt=vtGeneric) or (pt=vtGenericArray) then pGenName3:=fLastGenericName; // [Stage 32/37]
            for var i:=impl.ParamTypes.Count to impl.ParamNames.Count-1 do
            begin
              impl.ParamTypes.Add(pt);
              impl.ParamGenericNames.Add(pGenName3);
            end;
            // [Stage 28] array of integer/string 매개변수를 본문에서 a[i]로 인덱싱할 수
            // 있으려면 fArrayNames에 등록되어야 한다(별개 버그, 함께 수정).
            if (pt=vtIntArray) or (pt=vtStrArray) or (pt=vtGenericArray) then // [Stage 37]
              foreach var pbn in pBatch do
                if not fArrayNames.Contains(pbn) then fArrayNames.Add(pbn);
            if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
          end;
        end;
        Expect(tkRParen);
      end;

      if isFunc then
      begin
        Expect(tkColon); impl.ReturnType:=ParseVarType;
        if (impl.ReturnType=vtGeneric) or (impl.ReturnType=vtGenericArray) then impl.ReturnGenericName:=fLastGenericName; // [Stage 32/37]
      end;
      Expect(tkSemicolon);

      // 본문 파싱 (fCurClass 설정으로 필드 참조 가능)
      var savedClass:=fCurClass; var savedFunc:=fCurFunc;
      var savedParams:=fCurParams;
      var savedMethodParamNames:=fCurMethodParamNames; // [Stage 30]
      fCurClass:=cn; fCurFunc:=mn;
      fCurParams:=new List<string>;
      foreach var pnCp in impl.ParamNames do fCurParams.Add(pnCp);
      fCurMethodParamNames:=new List<string>; // [Stage 30] 지역변수 섞이기 전, 순수 매개변수 이름만 스냅샷
      foreach var pnCp2 in impl.ParamNames do fCurMethodParamNames.Add(pnCp2);

      // [Stage 28] 지역 변수도 매개변수와 마찬가지로 "필드가 아님"으로 표시해야
      // ParsePrimary/ParseStatement의 필드 vs 지역변수 분기가 올바르게 동작한다.
      // (fCurParams는 사실상 "이 스코프에서 필드보다 우선하는 이름" 목록으로 쓰인다.)
      if Cur.Kind=tkVar then
      begin
        ParseLocalVarSection(impl.LocalVars);
        foreach var lvcp in impl.LocalVars do fCurParams.Add(lvcp.Name);
      end;
      Expect(tkBegin); comp:=new TCompoundStmtNode;
      while Cur.Kind<>tkEnd do
      begin comp.Statements.Add(ParseStatement); if Cur.Kind=tkSemicolon then fPos:=fPos+1; end;
      Expect(tkEnd); Expect(tkSemicolon);

      fCurClass:=savedClass; fCurFunc:=savedFunc; fCurGenericParams:=savedGP3;
      fCurParams:=savedParams;
      fCurMethodParamNames:=savedMethodParamNames; // [Stage 30]
      impl.Body:=comp;
      Result:=impl;
    end;

    procedure ParseParams(aP: List<TParamDef>);
    var pt: TVarType; ns: List<string>;
    begin
      // [Stage 41] 매개변수가 없는 함수/프로시저는 괄호 자체를 생략할 수 있다.
      // '(' 가 없으면 빈 매개변수 목록으로 처리하고 바로 리턴.
      if Cur.Kind <> tkLParen then exit;   // ← 이 한 줄 추가 
      
      Expect(tkLParen);
      if Cur.Kind<>tkRParen then
      begin
        while true do
        begin
          ns:=new List<string>; ns.Add(Expect(tkIdent).Text);
          while Cur.Kind=tkComma do begin fPos:=fPos+1; ns.Add(Expect(tkIdent).Text); end;
          Expect(tkColon);
          // [Stage 31] 이전에는 ParseVarType만 써서 최상위 함수/프로시저가
          // 클래스/인터페이스/외부 .NET 타입 매개변수를 받을 수 없었다.
          // (클래스 메서드 시그니처는 이미 ParseParamTypeExt를 쓰고 있었음 — 동일하게 맞춘다.)
          var pIsExt5:=false; var pCn5:='';
          pt:=ParseParamTypeExt(pIsExt5, pCn5);
          if (pt=vtGeneric) or (pt=vtGenericArray) then pCn5:=fLastGenericName; // [Stage 36/37] 제네릭 매개변수(예: x: T, a: array of T)의 타입 매개변수 이름 보존
          foreach var nm in ns do
          begin
            aP.Add(new TParamDef(nm, pt, pCn5, pIsExt5));
            // [Stage 28] array of integer/string 매개변수도 본문에서 a[i]로 인덱싱할 수
            // 있어야 하는데, 이전에는 매개변수 이름이 fArrayNames에 등록되지 않아
            // 배열 인덱스 식으로 인식되지 않았다(별개 버그, 이번에 함께 수정).
            if (pt=vtIntArray) or (pt=vtStrArray) or (pt=vtGenericArray) then fArrayNames.Add(nm); // [Stage 37]
          end;
          if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
        end;
      end;
      Expect(tkRParen);
    end;

    function ParseFuncDecl: TFuncDeclNode;
    var d: TFuncDeclNode; c: TCompoundStmtNode; sv: string;
        genNames, genConstraints, savedGP4: List<string>;
    begin
      Expect(tkFunction); d:=new TFuncDeclNode(Expect(tkIdent).Text);

      // [Stage 36] 최상위 제네릭 함수: function Identity<T>(x: T): T;
      ParseCallableGenericParams(genNames, genConstraints);
      d.IsGeneric:=(genNames.Count>0);
      d.GenericParamNames:=genNames;
      d.GenericParamConstraints:=genConstraints;
      if d.IsGeneric then
      begin
        fGenericFuncNames.Add(d.Name);
        fFuncGenericParam[d.Name]:=genNames;
        fFuncGenericConstraint[d.Name]:=genConstraints;
      end
      else
        fFuncNames.Add(d.Name);

      // (본문/매개변수/반환타입 파싱 동안 fCurGenericParams를 설정해 T 등의 참조를 vtGeneric으로 인식시킨다)
      savedGP4:=fCurGenericParams;
      if d.IsGeneric then fCurGenericParams:=genNames;

      ParseParams(d.Parameters);
      Expect(tkColon); d.ReturnType:=ParseVarType;
      if (d.ReturnType=vtGeneric) or (d.ReturnType=vtGenericArray) then d.ReturnGenericName:=fLastGenericName; // [Stage 36/37]
      Expect(tkSemicolon);
      sv:=fCurFunc; fCurFunc:=d.Name;
      if Cur.Kind=tkVar then ParseLocalVarSection(d.LocalVars);
      Expect(tkBegin); c:=new TCompoundStmtNode;
      while Cur.Kind<>tkEnd do
      begin c.Statements.Add(ParseStatement); if Cur.Kind=tkSemicolon then fPos:=fPos+1; end;
      Expect(tkEnd); Expect(tkSemicolon); fCurFunc:=sv; d.Body:=c;
      fCurGenericParams:=savedGP4;
      Result:=d;
    end;

    function ParseProcDecl: TProcDeclNode;
    var d: TProcDeclNode; c: TCompoundStmtNode; sv: string;
        genNames, genConstraints, savedGP5: List<string>;
    begin
      Expect(tkProcedure);
      // ClassName.MethodName 형태이면 메서드 구현으로 처리
      // (이미 Cur.Kind=tkIdent인지 확인)
      d:=new TProcDeclNode(Expect(tkIdent).Text);

      // [Stage 36] 최상위 제네릭 프로시저: procedure PrintTwice<T>(x: T);
      ParseCallableGenericParams(genNames, genConstraints);
      d.IsGeneric:=(genNames.Count>0);
      d.GenericParamNames:=genNames;
      d.GenericParamConstraints:=genConstraints;
      if d.IsGeneric then
      begin
        fGenericProcNames.Add(d.Name);
        fProcGenericParam[d.Name]:=genNames;
        fProcGenericConstraint[d.Name]:=genConstraints;
      end
      else
        fProcNames.Add(d.Name);

      savedGP5:=fCurGenericParams;
      if d.IsGeneric then fCurGenericParams:=genNames;

      ParseParams(d.Parameters); Expect(tkSemicolon);
      sv:=fCurFunc; fCurFunc:='';
      if Cur.Kind=tkVar then ParseLocalVarSection(d.LocalVars);
      Expect(tkBegin); c:=new TCompoundStmtNode;
      while Cur.Kind<>tkEnd do
      begin c.Statements.Add(ParseStatement); if Cur.Kind=tkSemicolon then fPos:=fPos+1; end;
      Expect(tkEnd); Expect(tkSemicolon); fCurFunc:=sv; d.Body:=c;
      fCurGenericParams:=savedGP5;
      Result:=d;
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
          if (Cur.Kind=tkLt) and fGenericClassNames.Contains(cn) then cn:=ResolveGenericInstantiation(cn);
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
      fTokens:=aTokens; fPos:=0; fCurFunc:=''; fCurClass:=''; fCurParams:=new List<string>;
      fCurMethodParamNames:=new List<string>; // [Stage 30]
      fFuncNames:=new List<string>;
      fProcNames:=new List<string>;
      fArrayNames:=new List<string>;
      fClassNames:=new List<string>;
      fInterfaceNames:=new List<string>;
      fClassFields:=new Dictionary<string, List<string>>;
      fClassMethods:=new Dictionary<string, Dictionary<string, boolean>>;
      fClassParent:=new Dictionary<string, string>;
      fClassInterface:=new Dictionary<string, string>; // [Stage 34]
      fGenericClassNames:=new List<string>;
      fClassGenericParam:=new Dictionary<string, List<string>>;
      fClassGenericConstraint:=new Dictionary<string, List<string>>; // [Stage 34]
      fGenericFuncNames:=new List<string>; // [Stage 36]
      fGenericProcNames:=new List<string>; // [Stage 36]
      fFuncGenericParam:=new Dictionary<string, List<string>>; // [Stage 36]
      fProcGenericParam:=new Dictionary<string, List<string>>; // [Stage 36]
      fFuncGenericConstraint:=new Dictionary<string, List<string>>; // [Stage 36]
      fProcGenericConstraint:=new Dictionary<string, List<string>>; // [Stage 36]
      fCurGenericParams:=new List<string>;
      fLastGenericName:='';
    end;

    function ParseProgram: TProgramNode;
    var prog: TProgramNode; t: TToken;
    begin
      Expect(tkProgram); prog:=new TProgramNode(Expect(tkIdent).Text); Expect(tkSemicolon);
      fProg:=prog; // 깊이 상관없이(식/타입 파싱 도중) GenericInstantiations에 접근하기 위함

      // [Stage 29] uses 절: uses UnitA, UnitB.SubUnit, ...;
      // 지금은 이름을 소비만 하고 버린다 — 외부 타입은 이미 완전한 점(.) 경로 이름으로
      // 참조되므로(예: System.Windows.Forms.Button) uses 목록 자체가 CodeGen에 영향을 주지 않는다.
      // WPF 디자이너가 생성하는 파일 헤더를 그대로 통과시키는 것이 목적.
      if Cur.Kind=tkUses then
      begin
        fPos:=fPos+1; // 'uses' 소비
        Expect(tkIdent);
        while Cur.Kind=tkDot do begin fPos:=fPos+1; Expect(tkIdent); end;
        while Cur.Kind=tkComma do
        begin
          fPos:=fPos+1;
          Expect(tkIdent);
          while Cur.Kind=tkDot do begin fPos:=fPos+1; Expect(tkIdent); end;
        end;
        Expect(tkSemicolon);
      end;

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