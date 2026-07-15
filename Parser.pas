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
  // [Stage 56] Main.pas는 파일마다 별도의 TParser 인스턴스를 만들어 독립적으로 파싱한다.
  // 그런데 아래 TParser의 fFuncNames/fClassNames/... 같은 "이름 인식 테이블"은 그 파일
  // 자신이 선언한 것만 채워지므로, 예를 들어 Entry.pas가 StringUtils.pas에서 선언된
  // Greet 함수를 호출하면 Entry.pas 전용 TParser는 "Greet"를 모르는 이름으로 보고
  // "greeting := Greet('World');"의 '(' 를 "알 수 없는 문장"으로 오인해 실패한다
  // (Parser.pas 714번째 줄 근처: fFuncNames.Contains(t.Text)일 때만 함수 호출로 인식).
  //
  // 이 클래스는 그 이름 테이블들을 파일 경계 너머로 실어 나르는 스냅샷이다.
  // Main.pas가 compileOrder 순서대로 각 파일을 파싱하면서, 매 파일이 끝날 때마다
  // TParser.ExportSymbols로 뽑아 누적하고, 다음 파일의 TParser.ImportExternalSymbols에
  // 그대로 넘겨 계속 이어붙인다 — 즉 뒤에 오는 파일은 앞서 컴파일된 모든 파일이
  // 선언한 이름을 알고 시작한다.
  TParserExternalSymbols = class
  public
    FuncNames, ProcNames, ClassNames, InterfaceNames, EnumNames: List<string>;
    GenericClassNames, GenericFuncNames, GenericProcNames: List<string>;
    ClassFields: Dictionary<string, List<string>>;
    ClassMethods: Dictionary<string, Dictionary<string, boolean>>;
    ClassParent, ClassInterface: Dictionary<string, string>;
    ClassGenericParam, ClassGenericConstraint: Dictionary<string, List<string>>;
    FuncGenericParam, ProcGenericParam: Dictionary<string, List<string>>;
    FuncGenericConstraint, ProcGenericConstraint: Dictionary<string, List<string>>;
    EnumMemberEnumName: Dictionary<string, string>;
    EnumMemberOrdinal: Dictionary<string, integer>;
    constructor Create;
    begin
      FuncNames:=new List<string>; ProcNames:=new List<string>;
      ClassNames:=new List<string>; InterfaceNames:=new List<string>; EnumNames:=new List<string>;
      GenericClassNames:=new List<string>; GenericFuncNames:=new List<string>; GenericProcNames:=new List<string>;
      ClassFields:=new Dictionary<string, List<string>>;
      ClassMethods:=new Dictionary<string, Dictionary<string, boolean>>;
      ClassParent:=new Dictionary<string, string>;
      ClassInterface:=new Dictionary<string, string>;
      ClassGenericParam:=new Dictionary<string, List<string>>;
      ClassGenericConstraint:=new Dictionary<string, List<string>>;
      FuncGenericParam:=new Dictionary<string, List<string>>;
      ProcGenericParam:=new Dictionary<string, List<string>>;
      FuncGenericConstraint:=new Dictionary<string, List<string>>;
      ProcGenericConstraint:=new Dictionary<string, List<string>>;
      EnumMemberEnumName:=new Dictionary<string, string>;
      EnumMemberOrdinal:=new Dictionary<string, integer>;
    end;
  end;

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
    fEnumNames: List<string>; // [Phase 1] 선언된 열거형 이름 목록 (타입 파싱 시 vtEnum 분류용)
    // [Stage 51] 열거형 멤버 이름 → 소속 열거형 이름 / 서수. North → ('TDirection', 0) 처럼
    // 식(expression) 안에서 괄호 없는 식별자로 등장하는 열거형 값을 판별하는 데 쓰인다.
    fEnumMemberEnumName: Dictionary<string, string>;
    fEnumMemberOrdinal: Dictionary<string, integer>;
    // [Stage 51] 문(statement) 파싱 중 발생한 오류들을 즉시 던지지 않고 모아둔다 —
    // IDE에서 한 번에 여러 오류를 보여주기 위한 panic-mode 오류 복구용.
    ParseErrors: List<string>;
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
    // [Stage 52] tkLength만 하드코딩돼 있고 IsKeywordAllowedAsMemberName(바로 아래 정의,
    // read/write/real/double/char/int64 포함)은 실제로 호출된 적이 없어서 obj.Real, obj.Write
    // 같은 멤버 접근이 Length와 동일한 유형의 버그로 실패했다. 여기서 실제로 연결한다.
    function ExpectMemberName: string;
    var t: TToken;
    begin
      t:=Cur;
      if (t.Kind=tkIdent) or (t.Kind=tkLength) or IsKeywordAllowedAsMemberName(t.Kind) then
      begin
        fPos:=fPos+1; Result:=t.Text;
      end
      else
        raise new Exception('줄 '+t.Line.ToString+', 열 '+t.Column.ToString
          +': 멤버 이름이 와야 합니다 ("'+t.Text+'")');
    end;

    // [Phase 1] ExpectMemberName처럼, read/write/property 같은 Phase 1 키워드도
    // 멤버 이름 위치에서는 식별자로 허용해야 한다.
    function IsKeywordAllowedAsMemberName(k: TTokenKind): boolean;
    begin
      Result:=(k=tkLength) or (k=tkRead) or (k=tkWrite) or (k=tkReal)
           or (k=tkDouble) or (k=tkChar) or (k=tkInt64);
    end;

    function ParseVarType: TVarType;
    begin
      fLastGenericName:='';
      if (Cur.Kind=tkIdent) and fCurGenericParams.Contains(Cur.Text) then
        begin fLastGenericName:=Cur.Text; fPos:=fPos+1; Result:=vtGeneric; end
      else if Cur.Kind=tkInteger then begin fPos:=fPos+1; Result:=vtInteger; end
      else if Cur.Kind=tkStringType then begin fPos:=fPos+1; Result:=vtString; end
      else if Cur.Kind=tkBoolean then begin fPos:=fPos+1; Result:=vtBoolean; end
      // [Phase 1] 새 기본 타입
      else if (Cur.Kind=tkReal) or (Cur.Kind=tkDouble) then begin fPos:=fPos+1; Result:=vtReal; end
      else if Cur.Kind=tkChar  then begin fPos:=fPos+1; Result:=vtChar; end
      else if Cur.Kind=tkInt64 then begin fPos:=fPos+1; Result:=vtInt64; end
      else if Cur.Kind=tkArray then
      begin
        fPos:=fPos+1; Expect(tkOf);
        if Cur.Kind=tkInteger then begin fPos:=fPos+1; Result:=vtIntArray; end
        else if Cur.Kind=tkStringType then begin fPos:=fPos+1; Result:=vtStrArray; end
        // [Phase 1] array of real/char/int64 — vtObject + ClassName으로 표현 (CLR double[]/char[]/long[])
        else if (Cur.Kind=tkReal) or (Cur.Kind=tkDouble) then
          begin fPos:=fPos+1; fLastGenericName:='real'; Result:=vtGenericArray; end // 임시: Monomorphize가 real[]로 처리
        else if Cur.Kind=tkChar  then
          begin fPos:=fPos+1; fLastGenericName:='char'; Result:=vtGenericArray; end
        else if Cur.Kind=tkInt64 then
          begin fPos:=fPos+1; fLastGenericName:='int64'; Result:=vtGenericArray; end
        // [Stage 37] array of T — 제네릭 템플릿 본문에서만 등장. 실제 타입은 Monomorphize가 채운다.
        else if (Cur.Kind=tkIdent) and fCurGenericParams.Contains(Cur.Text) then
          begin fLastGenericName:=Cur.Text; fPos:=fPos+1; Result:=vtGenericArray; end
        else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': array of integer/string/real/char/int64'
          +'(또는 제네릭 문맥에서는 array of T)만 지원');
      end
      else if (Cur.Kind=tkIdent) and fEnumNames.Contains(Cur.Text) then
      begin
        fLastGenericName:=Cur.Text; fPos:=fPos+1; Result:=vtEnum; // [Phase 1]
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
      // [Phase 1] 새 기본 타입을 ParseVarType보다 먼저 처리 (tkIdent가 아닌 전용 토큰이므로 안전)
      if (Cur.Kind=tkReal) or (Cur.Kind=tkDouble) then begin fPos:=fPos+1; Result:=vtReal; exit; end;
      if Cur.Kind=tkChar  then begin fPos:=fPos+1; Result:=vtChar; exit; end;
      if Cur.Kind=tkInt64 then begin fPos:=fPos+1; Result:=vtInt64; exit; end;
      // [Phase 1] 열거형 타입
      if (Cur.Kind=tkIdent) and fEnumNames.Contains(Cur.Text) then
      begin
        cn:=Cur.Text; fLastGenericName:=cn; fPos:=fPos+1; Result:=vtEnum; exit;
      end;
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
      begin
        fPos:=fPos+1;
        // [Phase 1] int32 범위(2^31-1 = 2147483647) 초과 시 int64로 자동 승격
        var _iv: int64 := int64.Parse(t.Text);
        if (_iv >= -2147483648) and (_iv <= 2147483647) then
          Result:=new TIntLiteralNode(integer(_iv))
        else
          Result:=new TInt64LiteralNode(_iv);
      end

      // [Phase 1] 실수 리터럴
      else if t.Kind=tkRealLiteral then
        begin fPos:=fPos+1; Result:=new TRealLiteralNode(t.RealValue); end

      // [Phase 1] 문자 리터럴 (#65 또는 'A')
      else if t.Kind=tkCharLiteral then
        begin fPos:=fPos+1; Result:=new TCharLiteralNode(t.CharValue); end

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

      // [Stage 52] Length(x) — Lexer가 'length'를 tkIdent가 아니라 tkLength 키워드 토큰으로
      // 분류하기 때문에(줄 174, Lexer.pas), 아래 tkIdent 분기 안의 'length' 특수 처리(712번째 줄)까지
      // 내려가지 못하고 매칭 실패로 떨어지던 문제. .Length 멤버 접근(arr.Length)은 ExpectMemberName이
      // tkLength를 허용해서 이미 됐지만, 독립 함수 호출 Length(s)/Length(arr) 형태가 빠져 있었다.
      else if t.Kind=tkLength then
      begin
        fPos:=fPos+1; // 'length' 소비 (tkLength)
        Expect(tkLParen);
        var ntL2:=Expect(tkIdent); Expect(tkRParen);
        Result:=new TLengthExprNode(ntL2.Text);
      end

      // [Stage 41] tkLength 단독 분기 제거 — 'length'는 이제 tkIdent로 내려오므로
      // tkIdent 분기 안에서 텍스트로 구분한다 (아래 참조).

      else if t.Kind=tkIdent then
      begin
        fPos:=fPos+1;

        // [Stage 51] North, South 같은 열거형 멤버 이름 — 변수/필드가 아니라 정수 서수 리터럴로 취급.
        // (열거형 선언은 var/begin 섹션보다 항상 먼저 파싱되므로 이 시점에 이미 등록돼 있다.)
        if fEnumMemberEnumName.ContainsKey(t.Text) then
        begin
          Result:=new TEnumValueExprNode(fEnumMemberEnumName[t.Text], t.Text, fEnumMemberOrdinal[t.Text]);
        end

        else
        begin

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

        end; // [Stage 51] else 블록(열거형 멤버가 아닌 일반 식별자 처리) 종료
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

    // ---- [Stage 51] 문장 목록 파싱 (panic-mode 오류 복구 포함) ----
    // 'end' 토큰(또는 파일 끝)을 만날 때까지 문장을 반복 파싱한다. 예전에는 이 루프가
    // begin...end 블록마다(프로그램 본문, 메서드/함수/생성자 본문 등 총 6곳) 그대로
    // 복사되어 있었고, 문장 하나라도 파싱 오류가 나면 예외가 즉시 위로 전파되어 전체
    // 파싱이 중단됐다 — IDE 연동 시 오타 하나 때문에 나머지 오류를 전혀 볼 수 없는 문제.
    // 이제 문장 파싱 실패 시 오류를 ParseErrors에 기록만 해두고, 다음 안전한 지점
    // (';', 'end', 파일 끝)까지 토큰을 건너뛴 뒤 이어서 파싱한다.
    procedure ParseStatementsUntilEnd(target: List<TStmtNode>);
    var stmtStartPos: integer; syncDepth: integer;
    begin
      while (Cur.Kind<>tkEnd) and (Cur.Kind<>tkEOF) do
      begin
        stmtStartPos:=fPos;
        try
          target.Add(ParseStatement);
          if Cur.Kind=tkSemicolon then fPos:=fPos+1;
        except
          on ex: Exception do
          begin
            ParseErrors.Add(ex.Message);
            // 무한루프 방지: 문장 파싱이 토큰을 하나도 전진시키지 못했다면 최소 한 개는 건너뛴다.
            if fPos=stmtStartPos then fPos:=fPos+1;
            // 다음 동기화 지점(';' 또는 'end' 또는 파일 끝)까지 건너뛴다.
            // [버그 수정] 깨진 문장 안에 중첩된 begin...end나 try...end가 있으면
            // (예: "if x then begin ... end" 도중 오류) 그 안쪽 'end'를 이 블록 자신의
            // 끝으로 착각하면 안 된다 — begin/try를 열림으로, end를 닫힘으로 세어
            // 깊이가 0일 때 만나는 ';'나 'end'만 진짜 동기화 지점으로 인정한다.
            syncDepth:=0;
            while Cur.Kind<>tkEOF do
            begin
              if (syncDepth=0) and ((Cur.Kind=tkSemicolon) or (Cur.Kind=tkEnd)) then break;
              if (Cur.Kind=tkBegin) or (Cur.Kind=tkTry) then syncDepth:=syncDepth+1
              else if Cur.Kind=tkEnd then syncDepth:=syncDepth-1;
              fPos:=fPos+1;
            end;
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end;
        end;
      end;
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

      // [Stage 48] var x := 식; — begin...end 안에서 선언과 동시에 대입.
      // (WPF 진입점 템플릿의 "var t := new System.Threading.Thread(RunApp);" 패턴)
      else if Cur.Kind=tkVar then
      begin
        fPos:=fPos+1;
        var ivn:=Expect(tkIdent).Text;
        Expect(tkAssign);
        Result:=new TInlineVarStmtNode(ivn, ParseExpr);
        fCurParams.Add(ivn); // 이후 문장에서 이 이름을 필드로 오인하지 않도록 지역변수로 등록
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
        ParseStatementsUntilEnd(comp.Statements); // [Stage 58] panic-mode 오류 복구
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

      // [Stage 59] case Selector of 라벨1,라벨2..라벨3: 문장; ... [else 문장들] end
      else if Cur.Kind=tkCase then
      begin
        fPos:=fPos+1; // 'case' 소비
        var caseSelExpr:=ParseExpr;
        Expect(tkOf);
        var caseNode:=new TCaseStmtNode(caseSelExpr);
        // 분기 목록: 'else' 또는 'end'(또는 파일 끝) 나올 때까지. [Stage 58]과 같은 panic-mode 복구.
        while (Cur.Kind<>tkElse) and (Cur.Kind<>tkEnd) and (Cur.Kind<>tkEOF) do
        begin
          var caseBranchStart:=fPos;
          try
            var caseBranch:=new TCaseBranchNode;
            while true do
            begin
              var caseLoE:=ParseExpr;
              if Cur.Kind=tkDotDot then
              begin
                fPos:=fPos+1;
                var caseHiE:=ParseExpr;
                caseBranch.Labels.Add(new TCaseLabel(caseLoE, caseHiE));
              end
              else
                caseBranch.Labels.Add(new TCaseLabel(caseLoE));
              if Cur.Kind=tkComma then fPos:=fPos+1 else break;
            end;
            Expect(tkColon);
            caseBranch.Stmt:=ParseStatement;
            caseNode.Branches.Add(caseBranch);
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          except
            on exCase: Exception do
            begin
              ParseErrors.Add(exCase.Message);
              if fPos=caseBranchStart then fPos:=fPos+1;
              // 다음 동기화 지점(';' 또는 'else' 또는 'end')까지 건너뜀.
              // 중첩된 begin/try/case의 안쪽 'end'를 이 case 자신의 끝으로 착각하지 않도록 깊이 추적.
              var caseSyncDepth:=0;
              while Cur.Kind<>tkEOF do
              begin
                if (caseSyncDepth=0) and ((Cur.Kind=tkSemicolon) or (Cur.Kind=tkElse) or (Cur.Kind=tkEnd)) then break;
                if (Cur.Kind=tkBegin) or (Cur.Kind=tkTry) or (Cur.Kind=tkCase) then caseSyncDepth:=caseSyncDepth+1
                else if Cur.Kind=tkEnd then caseSyncDepth:=caseSyncDepth-1;
                fPos:=fPos+1;
              end;
              if Cur.Kind=tkSemicolon then fPos:=fPos+1;
            end;
          end;
        end;
        if Cur.Kind=tkElse then
        begin
          fPos:=fPos+1; // 'else' 소비
          caseNode.ElseStmts:=new List<TStmtNode>;
          ParseStatementsUntilEnd(caseNode.ElseStmts); // [Stage 58] panic-mode 오류 복구, 'end'에서 멈춤
        end;
        Expect(tkEnd);
        Result:=caseNode;
      end

      else if Cur.Kind=tkFor then
      begin
        fPos:=fPos+1;
        var vn:=Expect(tkIdent).Text;
        if Cur.Kind=tkIn then // [Stage 54] for VarName in CollExpr do Body
        begin
          fPos:=fPos+1;
          var collE:=ParseExpr;
          Expect(tkDo);
          var forInBody:=ParseStatement;
          Result:=new TForInStmtNode(vn, collE, forInBody);
        end
        else
        begin
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
        end;
      end

      else if Cur.Kind=tkTry then
      begin
        // try <stmts> (except [on E: Type do <stmt>] | finally <stmts>) end
        fPos:=fPos+1;
        var tryNode:=new TTryStmtNode;
        // try 본문 파싱 (except/finally 키워드가 나올 때까지) [Stage 58] panic-mode 오류 복구
        while (Cur.Kind<>tkExcept) and (Cur.Kind<>tkFinally) and (Cur.Kind<>tkEnd) and (Cur.Kind<>tkEOF) do
        begin
          var tryBodyStart:=fPos;
          try
            tryNode.BodyStmts.Add(ParseStatement);
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          except
            on ex2: Exception do
            begin
              ParseErrors.Add(ex2.Message);
              if fPos=tryBodyStart then fPos:=fPos+1;
              while (Cur.Kind<>tkSemicolon) and (Cur.Kind<>tkExcept) and
                    (Cur.Kind<>tkFinally) and (Cur.Kind<>tkEnd) and (Cur.Kind<>tkEOF) do
                fPos:=fPos+1;
              if Cur.Kind=tkSemicolon then fPos:=fPos+1;
            end;
          end;
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
            // [Stage 43] on ex: System.Exception do — 점(.)으로 연결된 외부 예외 타입 이름도 허용.
            // (실제로는 ExTypeName을 CodeGen이 쓰지 않고 항상 typeof(System.Exception)으로 잡지만,
            // 파싱 자체가 dotted 이름에서 막히면 디자이너가 내는 코드를 아예 받을 수 없다.)
            while Cur.Kind=tkDot do begin fPos:=fPos+1; tryNode.ExTypeName:=tryNode.ExTypeName+'.'+Expect(tkIdent).Text; end;
            Expect(tkDo);
            tryNode.ExceptStmts.Add(ParseStatement);
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end
          else
          begin
            // on 없이 bare except [Stage 58] panic-mode 오류 복구
            while (Cur.Kind<>tkEnd) and (Cur.Kind<>tkFinally) and (Cur.Kind<>tkEOF) do
            begin
              var bareExStart:=fPos;
              try
                tryNode.ExceptStmts.Add(ParseStatement);
                if Cur.Kind=tkSemicolon then fPos:=fPos+1;
              except
                on ex3: Exception do
                begin
                  ParseErrors.Add(ex3.Message);
                  if fPos=bareExStart then fPos:=fPos+1;
                  while (Cur.Kind<>tkSemicolon) and (Cur.Kind<>tkEnd) and
                        (Cur.Kind<>tkFinally) and (Cur.Kind<>tkEOF) do
                    fPos:=fPos+1;
                  if Cur.Kind=tkSemicolon then fPos:=fPos+1;
                end;
              end;
            end;
          end;
          // 선택적 finally after except [Stage 58] panic-mode 오류 복구
          if Cur.Kind=tkFinally then
          begin
            fPos:=fPos+1;
            tryNode.FinallyStmts:=new List<TStmtNode>;
            while (Cur.Kind<>tkEnd) and (Cur.Kind<>tkEOF) do
            begin
              var fin1Start:=fPos;
              try
                tryNode.FinallyStmts.Add(ParseStatement);
                if Cur.Kind=tkSemicolon then fPos:=fPos+1;
              except
                on ex4: Exception do
                begin
                  ParseErrors.Add(ex4.Message);
                  if fPos=fin1Start then fPos:=fPos+1;
                  while (Cur.Kind<>tkSemicolon) and (Cur.Kind<>tkEnd) and (Cur.Kind<>tkEOF) do
                    fPos:=fPos+1;
                  if Cur.Kind=tkSemicolon then fPos:=fPos+1;
                end;
              end;
            end;
          end;
        end
        else if Cur.Kind=tkFinally then
        begin
          fPos:=fPos+1; // 'finally' 소비
          tryNode.FinallyStmts:=new List<TStmtNode>;
          // [Stage 58] panic-mode 오류 복구
          while (Cur.Kind<>tkEnd) and (Cur.Kind<>tkEOF) do
          begin
            var fin2Start:=fPos;
            try
              tryNode.FinallyStmts.Add(ParseStatement);
              if Cur.Kind=tkSemicolon then fPos:=fPos+1;
            except
              on ex5: Exception do
              begin
                ParseErrors.Add(ex5.Message);
                if fPos=fin2Start then fPos:=fPos+1;
                while (Cur.Kind<>tkSemicolon) and (Cur.Kind<>tkEnd) and (Cur.Kind<>tkEOF) do
                  fPos:=fPos+1;
                if Cur.Kind=tkSemicolon then fPos:=fPos+1;
              end;
            end;
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

    // [Stage 58] 클래스/인터페이스 멤버 하나(필드/메서드 시그니처/프로퍼티/생성자 시그니처)가
    // 깨졌을 때 그 멤버 하나만 버리고 다음 멤버(또는 클래스/인터페이스의 'end')로 건너뛴다.
    // 멤버 선언은 항상 ';'으로 끝나므로 다음 ';' 지점까지 건너뛰면 되지만, 매개변수 목록의
    // '(' ')' 안에 있는 ';'(매개변수 그룹 구분자, 예: "function F(a:integer; b:integer)")에
    // 걸려 너무 일찍 멈추지 않도록 괄호 깊이를 추적한다.
    // [주의] 클래스 본문 자체에는 begin...end가 없으므로(멤버는 시그니처뿐, 본문은 별도
    // MethodImpl에서 파싱) ParseStatementsUntilEnd처럼 begin/end 깊이까지 추적할 필요는 없다.
    procedure SkipToMemberBoundary;
    var parenDepth: integer;
    begin
      parenDepth:=0;
      while (Cur.Kind<>tkEOF) and (Cur.Kind<>tkEnd) do
      begin
        if Cur.Kind=tkLParen then parenDepth:=parenDepth+1
        else if Cur.Kind=tkRParen then begin if parenDepth>0 then parenDepth:=parenDepth-1; end
        else if (Cur.Kind=tkSemicolon) and (parenDepth=0) then begin fPos:=fPos+1; exit; end;
        fPos:=fPos+1;
      end;
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
        // [Phase 2] 타입 선언 하나가 깨져도(오타, 괄호 누락 등) 전체 구문분석을 멈추지 않고
        // 오류를 모아둔 뒤 다음 타입 선언(또는 var/함수/프로시저/begin) 자리로 건너뛰어 계속한다.
        var typeDeclStartPos:=fPos;
        try
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

        // ---- [Phase 1] 열거형 선언: TColor = (Red, Green, Blue); ----
        if Cur.Kind=tkLParen then
        begin
          if genParamNames.Count>0 then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 열거형은 제네릭 타입 매개변수를 지원하지 않습니다');
          fPos:=fPos+1; // '(' 소비
          var edecl:=new TEnumDeclNode(cn);
          edecl.Members.Add(Expect(tkIdent).Text);
          while Cur.Kind=tkComma do
          begin
            fPos:=fPos+1;
            edecl.Members.Add(Expect(tkIdent).Text);
          end;
          Expect(tkRParen);
          Expect(tkSemicolon);
          fEnumNames.Add(cn);
          // [Stage 51] 각 멤버 이름을 (열거형명, 서수)로 등록 — North → ('TDirection', 0)
          for var _emIdx:=0 to edecl.Members.Count-1 do
          begin
            fEnumMemberEnumName[edecl.Members[_emIdx]]:=cn;
            fEnumMemberOrdinal[edecl.Members[_emIdx]]:=_emIdx;
          end;
          aProg.EnumDecls.Add(edecl);
        end

        // ---- 인터페이스 선언 ----
        else if Cur.Kind=tkInterface then
        begin
          if genParamNames.Count>0 then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 인터페이스는 아직 지원되지 않습니다');
          fPos:=fPos+1; // 'interface' 소비
          idecl:=new TInterfaceDeclNode(cn);
          fInterfaceNames.Add(cn);

          while Cur.Kind<>tkEnd do
          begin
            // [Stage 58] 인터페이스 메서드 시그니처 하나가 깨져도 인터페이스 전체를
            // 버리지 않고 그 시그니처만 건너뛴다.
            try
              idecl.Methods.Add(ParseInterfaceMethodSig);
            except
              on ex: Exception do
              begin
                ParseErrors.Add(ex.Message);
                SkipToMemberBoundary;
              end;
            end;
          end;

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
            // [Stage 58] 클래스 멤버(필드/메서드/프로퍼티/생성자 시그니처) 하나가 깨져도
            // 클래스 전체를 버리지 않고 그 멤버 하나만 건너뛴다.
            var memberStartPos:=fPos;
            try
            begin
            // private / public 키워드는 건너뜀
            if (Cur.Kind=tkPrivate) or (Cur.Kind=tkPublic) then
            begin
              fPos:=fPos+1;
            end

            // [Stage 42] 생성자 시그니처: constructor Create;
            // [Stage 47] 매개변수 있는 생성자도 지원 (procedure/function 시그니처 파싱과 동일한 패턴)
            else if Cur.Kind=tkConstructor then
            begin
              fPos:=fPos+1;
              var ctorName:=Expect(tkIdent).Text;
              if ctorName<>'Create' then
                raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
                  +': 생성자 이름은 "Create"만 지원합니다 (Stage 42)');
              if Cur.Kind=tkLParen then
              begin
                fPos:=fPos+1;
                if Cur.Kind<>tkRParen then
                begin
                  var ctorPNames:=new List<string>;
                  while true do
                  begin
                    ctorPNames.Add(Expect(tkIdent).Text);
                    while Cur.Kind=tkComma do begin fPos:=fPos+1; ctorPNames.Add(Expect(tkIdent).Text); end;
                    Expect(tkColon);
                    var ctorPIsExt:=false; var ctorPCn:='';
                    var ctorPt:=ParseParamTypeExt(ctorPIsExt, ctorPCn);
                    foreach var ctorPn in ctorPNames do
                      cd.ConstructorParams.Add(new TParamDef(ctorPn, ctorPt, ctorPCn, ctorPIsExt));
                    ctorPNames.Clear;
                    if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
                  end;
                end;
                Expect(tkRParen);
              end;
              Expect(tkSemicolon);
              cd.HasUserConstructor:=true;
            end

            // [Phase 1] 프로퍼티 시그니처: property Name: Type read FX write FX;
            else if Cur.Kind=tkProperty then
            begin
              fPos:=fPos+1; // 'property' 소비
              var propName:=Expect(tkIdent).Text;
              Expect(tkColon);
              var propIsExt:=false; var propCn:='';
              var propType:=ParseParamTypeExt(propIsExt, propCn);
              if (propType=vtEnum) then propCn:=fLastGenericName;
              if (propType=vtGeneric) or (propType=vtGenericArray) then propCn:=fLastGenericName;
              var ps:=new TPropertySignature(propName, propType);
              ps.PropClassName:=propCn; ps.IsExternalType:=propIsExt;
              // read 접근자 (선택)
              if Cur.Kind=tkRead then
              begin
                fPos:=fPos+1;
                ps.ReadName:=Expect(tkIdent).Text;
              end;
              // write 접근자 (선택)
              if Cur.Kind=tkWrite then
              begin
                fPos:=fPos+1;
                ps.WriteName:=Expect(tkIdent).Text;
              end;
              Expect(tkSemicolon);
              cd.Properties.Add(ps);
              // 프로퍼티는 클래스 필드 목록에 이름을 추가한다.
              // 이를 통해 메서드 본문에서 Self.PropName 접근이 필드처럼 인식된다.
              fClassFields[cn].Add(propName);
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
              // [Stage 53] 메서드 지시자: virtual;/override;/abstract; — 순서·조합 무관하게 여러 개 허용
              // (예: "procedure Foo; virtual; abstract;"). 지시자마다 세미콜론이 따라온다.
              while (Cur.Kind=tkVirtual) or (Cur.Kind=tkOverride) or (Cur.Kind=tkAbstract) do
              begin
                if Cur.Kind=tkVirtual then sig.IsVirtual:=true
                else if Cur.Kind=tkOverride then sig.IsOverride:=true
                else sig.IsAbstract:=true;
                fPos:=fPos+1;
                Expect(tkSemicolon);
              end;
              cd.Methods.Add(sig);
              fClassMethods[cn][mname]:=isFunc;
            end

            // 필드 선언: fname1, fname2, ... : type;
            // (기본 타입, 지역 클래스, 또는 외부 타입 System.Windows.Forms.Button)
            // [Phase 1] FX, FY: real; 처럼 쉼표로 묶인 복수 이름도 지원
            else if Cur.Kind=tkIdent then
            begin
              var fnames:=new List<string>;
              fnames.Add(Cur.Text); fPos:=fPos+1;
              while Cur.Kind=tkComma do
              begin
                fPos:=fPos+1;
                fnames.Add(Expect(tkIdent).Text);
              end;
              Expect(tkColon);
              var fldType: TVarType; var fldCn: string; var fldIsExt: boolean;
              fldType:=vtInteger; fldCn:=''; fldIsExt:=false;
              if (Cur.Kind=tkIdent) and fCurGenericParams.Contains(Cur.Text) then
              begin
                fldType:=vtGeneric; fldCn:=Cur.Text; fPos:=fPos+1;
              end
              else if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
              begin
                fldType:=vtObject; fldCn:=Cur.Text; fPos:=fPos+1;
                if (Cur.Kind=tkLt) and fGenericClassNames.Contains(fldCn) then
                  fldCn:=ResolveGenericInstantiation(fldCn);
              end
              else if (Cur.Kind=tkIdent) and fInterfaceNames.Contains(Cur.Text) then
              begin
                fldType:=vtInterface; fldCn:=Cur.Text; fPos:=fPos+1;
              end
              else if (Cur.Kind=tkIdent) and fEnumNames.Contains(Cur.Text) then
              begin
                fldType:=vtEnum; fldCn:=Cur.Text; fPos:=fPos+1; // [Phase 1]
              end
              else if Cur.Kind=tkIdent then
              begin
                var savedPos2:=fPos;
                var qn:=Expect(tkIdent).Text;
                if Cur.Kind=tkDot then
                begin
                  while Cur.Kind=tkDot do
                  begin fPos:=fPos+1; qn:=qn+'.'+Expect(tkIdent).Text; end;
                  fldType:=vtObject; fldCn:=qn; fldIsExt:=true;
                end
                else
                begin
                  fPos:=savedPos2;
                  fldType:=ParseVarType;
                  if fldType=vtGenericArray then fldCn:=fLastGenericName;
                end;
              end
              else
              begin
                fldType:=ParseVarType;
                if fldType=vtGenericArray then fldCn:=fLastGenericName;
              end;
              Expect(tkSemicolon);
              foreach var fn in fnames do
              begin
                var fld:=new TFieldDeclNode(fn, fldType);
                fld.ClassName:=fldCn; fld.IsExternalType:=fldIsExt;
                cd.Fields.Add(fld);
                fClassFields[cn].Add(fn);
              end;
            end

            else
              raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 클래스 선언 안에서 알 수 없는 토큰 "'+Cur.Text+'"');
            end; // [Stage 58] 멤버 try 안의 begin 닫기
            except
              on ex: Exception do
              begin
                ParseErrors.Add(ex.Message);
                if fPos=memberStartPos then fPos:=fPos+1;
                SkipToMemberBoundary;
              end;
            end;
          end;

          fCurGenericParams:=savedGP1;
          Expect(tkEnd); Expect(tkSemicolon);
          aProg.ClassDecls.Add(cd);
        end;
        end; // [Phase 2] try 안의 begin 닫기
        except
          on ex: Exception do
          begin
            ParseErrors.Add(ex.Message);
            // 무한루프 방지: 최소 한 토큰은 전진.
            if fPos=typeDeclStartPos then fPos:=fPos+1;
            // 다음 안전 지점(다음 타입 선언 시작, 또는 var/함수/프로시저/생성자/begin/파일 끝)까지 건너뛴다.
            while (Cur.Kind<>tkSemicolon) and (Cur.Kind<>tkVar) and (Cur.Kind<>tkFunction)
              and (Cur.Kind<>tkProcedure) and (Cur.Kind<>tkConstructor) and (Cur.Kind<>tkBegin)
              and (Cur.Kind<>tkEOF) do
              fPos:=fPos+1;
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end;
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
      ParseStatementsUntilEnd(comp.Statements); // [Stage 58] panic-mode 오류 복구
      Expect(tkEnd); Expect(tkSemicolon);

      fCurClass:=savedClass; fCurFunc:=savedFunc; fCurGenericParams:=savedGP3;
      fCurParams:=savedParams;
      fCurMethodParamNames:=savedMethodParamNames; // [Stage 30]
      impl.Body:=comp;
      Result:=impl;
    end;

    // [Stage 42] 생성자 구현: constructor ClassName.Create; begin ... end;
    // [Stage 47] 매개변수 있는 생성자도 지원 — ParseMethodImpl과 거의 같은 패턴(제네릭은 미지원).
    function ParseConstructorImpl: TConstructorImplNode;
    var cn: string; impl: TConstructorImplNode; comp: TCompoundStmtNode; pt: TVarType;
    begin
      Expect(tkConstructor);
      cn:=Expect(tkIdent).Text; Expect(tkDot);
      var mn:=Expect(tkIdent).Text;
      if mn<>'Create' then
        raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
          +': 생성자 이름은 "Create"만 지원합니다 (Stage 42)');
      impl:=new TConstructorImplNode(cn);

      // [Stage 47] 매개변수 목록 파싱
      if Cur.Kind=tkLParen then
      begin
        fPos:=fPos+1;
        if Cur.Kind<>tkRParen then
        begin
          while true do
          begin
            var ctorPBatch:=new List<string>;
            ctorPBatch.Add(Expect(tkIdent).Text);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; ctorPBatch.Add(Expect(tkIdent).Text); end;
            Expect(tkColon);
            var ctorPIsExt2:=false; var ctorPCn2:='';
            pt:=ParseParamTypeExt(ctorPIsExt2, ctorPCn2);
            foreach var ctorPn2 in ctorPBatch do
              impl.Parameters.Add(new TParamDef(ctorPn2, pt, ctorPCn2, ctorPIsExt2));
            if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
          end;
        end;
        Expect(tkRParen);
      end;
      Expect(tkSemicolon);

      var savedGP4:=fCurGenericParams;
      if fClassGenericParam.ContainsKey(cn) then fCurGenericParams:=fClassGenericParam[cn]
      else fCurGenericParams:=new List<string>;

      var savedClass2:=fCurClass; var savedFunc2:=fCurFunc;
      var savedParams2:=fCurParams;
      var savedMethodParamNames2:=fCurMethodParamNames;
      fCurClass:=cn; fCurFunc:='Create';
      fCurParams:=new List<string>;
      foreach var ctorPn3 in impl.Parameters do fCurParams.Add(ctorPn3.Name); // [Stage 47]
      fCurMethodParamNames:=new List<string>;
      foreach var ctorPn4 in impl.Parameters do fCurMethodParamNames.Add(ctorPn4.Name); // [Stage 47]

      if Cur.Kind=tkVar then
      begin
        ParseLocalVarSection(impl.LocalVars);
        foreach var lvcp2 in impl.LocalVars do fCurParams.Add(lvcp2.Name);
      end;
      Expect(tkBegin); comp:=new TCompoundStmtNode;
      ParseStatementsUntilEnd(comp.Statements); // [Stage 58] panic-mode 오류 복구
      Expect(tkEnd); Expect(tkSemicolon);

      fCurClass:=savedClass2; fCurFunc:=savedFunc2; fCurGenericParams:=savedGP4;
      fCurParams:=savedParams2; fCurMethodParamNames:=savedMethodParamNames2;
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
      ParseStatementsUntilEnd(c.Statements); // [Stage 58] panic-mode 오류 복구
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
      ParseStatementsUntilEnd(c.Statements); // [Stage 58] panic-mode 오류 복구
      Expect(tkEnd); Expect(tkSemicolon); fCurFunc:=sv; d.Body:=c;
      fCurGenericParams:=savedGP5;
      Result:=d;
    end;

    procedure ParseVarSection(aProg: TProgramNode);
    var vt: TVarType; ns: List<string>; cn: string; isExt: boolean; varDeclStartPos: integer;
    begin
      Expect(tkVar);
      while (Cur.Kind<>tkBegin) and (Cur.Kind<>tkFunction)
        and (Cur.Kind<>tkProcedure) and (Cur.Kind<>tkEOF) do
      begin
        // [Phase 2] var 선언 한 줄이 깨져도 전체를 멈추지 않고 오류를 모은 뒤 다음 줄로 건너뛴다.
        varDeclStartPos:=fPos;
        try
        begin
        ns:=new List<string>; ns.Add(Expect(tkIdent).Text);
        while Cur.Kind=tkComma do begin fPos:=fPos+1; ns.Add(Expect(tkIdent).Text); end;
        Expect(tkColon);
        cn:=''; isExt:=false;
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
        // [전역 var 버그 수정] 점(.)으로 연결된 외부 .NET 타입 (예: System.Text.StringBuilder).
        // ParseParamTypeExt/ParseLocalVarSection에는 이미 있었는데 전역 var 섹션에만 빠져 있었다.
        else if Cur.Kind=tkIdent then
        begin
          var savedPosV:=fPos;
          var qnV:=Expect(tkIdent).Text;
          if Cur.Kind=tkDot then
          begin
            while Cur.Kind=tkDot do begin fPos:=fPos+1; qnV:=qnV+'.'+Expect(tkIdent).Text; end;
            cn:=qnV; isExt:=true; vt:=vtObject;
          end
          else
          begin
            fPos:=savedPosV;
            vt:=ParseVarType;
          end;
        end
        else vt:=ParseVarType;
        Expect(tkSemicolon);
        foreach var nm in ns do
        begin
          aProg.VarDecls.Add(new TVarDecl(nm, vt, cn, isExt));
          if (vt=vtIntArray) or (vt=vtStrArray) then fArrayNames.Add(nm);
        end;
        end;
        except
          on ex: Exception do
          begin
            ParseErrors.Add(ex.Message);
            if fPos=varDeclStartPos then fPos:=fPos+1;
            while (Cur.Kind<>tkSemicolon) and (Cur.Kind<>tkBegin) and (Cur.Kind<>tkFunction)
              and (Cur.Kind<>tkProcedure) and (Cur.Kind<>tkEOF) do
              fPos:=fPos+1;
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end;
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
      fEnumNames:=new List<string>; // [Phase 1]
      fEnumMemberEnumName:=new Dictionary<string, string>; // [Stage 51]
      fEnumMemberOrdinal:=new Dictionary<string, integer>; // [Stage 51]
      ParseErrors:=new List<string>; // [Stage 51]
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

    // [Stage 56] 반드시 생성자 직후, ParseProgram 호출 전에 불러야 한다.
    // ext(이전에 컴파일된 파일들이 내보낸 이름 테이블)를 이 파서의 인식 테이블에 병합한다 —
    // 이후 ParseProgram이 문장을 파싱하면서 이 이름들을 "이미 알려진 함수/클래스/..." 로 인정한다.
    // ext가 nil이면(=첫 파일이라 아직 아무것도 안 쌓였으면) 아무 것도 하지 않는다.
    procedure ImportExternalSymbols(ext: TParserExternalSymbols);
    begin
      if ext=nil then exit;
      foreach var s in ext.FuncNames do if not fFuncNames.Contains(s) then fFuncNames.Add(s);
      foreach var s in ext.ProcNames do if not fProcNames.Contains(s) then fProcNames.Add(s);
      foreach var s in ext.ClassNames do if not fClassNames.Contains(s) then fClassNames.Add(s);
      foreach var s in ext.InterfaceNames do if not fInterfaceNames.Contains(s) then fInterfaceNames.Add(s);
      foreach var s in ext.EnumNames do if not fEnumNames.Contains(s) then fEnumNames.Add(s);
      foreach var s in ext.GenericClassNames do if not fGenericClassNames.Contains(s) then fGenericClassNames.Add(s);
      foreach var s in ext.GenericFuncNames do if not fGenericFuncNames.Contains(s) then fGenericFuncNames.Add(s);
      foreach var s in ext.GenericProcNames do if not fGenericProcNames.Contains(s) then fGenericProcNames.Add(s);

      foreach var k in ext.ClassFields.Keys do if not fClassFields.ContainsKey(k) then fClassFields.Add(k, ext.ClassFields[k]);
      foreach var k in ext.ClassMethods.Keys do if not fClassMethods.ContainsKey(k) then fClassMethods.Add(k, ext.ClassMethods[k]);
      foreach var k in ext.ClassParent.Keys do if not fClassParent.ContainsKey(k) then fClassParent.Add(k, ext.ClassParent[k]);
      foreach var k in ext.ClassInterface.Keys do if not fClassInterface.ContainsKey(k) then fClassInterface.Add(k, ext.ClassInterface[k]);
      foreach var k in ext.ClassGenericParam.Keys do if not fClassGenericParam.ContainsKey(k) then fClassGenericParam.Add(k, ext.ClassGenericParam[k]);
      foreach var k in ext.ClassGenericConstraint.Keys do if not fClassGenericConstraint.ContainsKey(k) then fClassGenericConstraint.Add(k, ext.ClassGenericConstraint[k]);
      foreach var k in ext.FuncGenericParam.Keys do if not fFuncGenericParam.ContainsKey(k) then fFuncGenericParam.Add(k, ext.FuncGenericParam[k]);
      foreach var k in ext.ProcGenericParam.Keys do if not fProcGenericParam.ContainsKey(k) then fProcGenericParam.Add(k, ext.ProcGenericParam[k]);
      foreach var k in ext.FuncGenericConstraint.Keys do if not fFuncGenericConstraint.ContainsKey(k) then fFuncGenericConstraint.Add(k, ext.FuncGenericConstraint[k]);
      foreach var k in ext.ProcGenericConstraint.Keys do if not fProcGenericConstraint.ContainsKey(k) then fProcGenericConstraint.Add(k, ext.ProcGenericConstraint[k]);
      foreach var k in ext.EnumMemberEnumName.Keys do if not fEnumMemberEnumName.ContainsKey(k) then fEnumMemberEnumName.Add(k, ext.EnumMemberEnumName[k]);
      foreach var k in ext.EnumMemberOrdinal.Keys do if not fEnumMemberOrdinal.ContainsKey(k) then fEnumMemberOrdinal.Add(k, ext.EnumMemberOrdinal[k]);
    end;

    // [Stage 56] ParseProgram이 성공적으로 끝난 뒤에 불러야 한다.
    // 이 파서가 (ImportExternalSymbols로 미리 받아둔 것 + 이 파일 자신이 새로 선언한 것을
    // 합친) 지금 시점의 전체 이름 테이블을 스냅샷으로 내보낸다. 다음 파일에
    // ImportExternalSymbols로 그대로 넘기면 계속 누적된다.
    function ExportSymbols: TParserExternalSymbols;
    begin
      Result:=new TParserExternalSymbols;
      Result.FuncNames.AddRange(fFuncNames);
      Result.ProcNames.AddRange(fProcNames);
      Result.ClassNames.AddRange(fClassNames);
      Result.InterfaceNames.AddRange(fInterfaceNames);
      Result.EnumNames.AddRange(fEnumNames);
      Result.GenericClassNames.AddRange(fGenericClassNames);
      Result.GenericFuncNames.AddRange(fGenericFuncNames);
      Result.GenericProcNames.AddRange(fGenericProcNames);
      foreach var k in fClassFields.Keys do Result.ClassFields.Add(k, fClassFields[k]);
      foreach var k in fClassMethods.Keys do Result.ClassMethods.Add(k, fClassMethods[k]);
      foreach var k in fClassParent.Keys do Result.ClassParent.Add(k, fClassParent[k]);
      foreach var k in fClassInterface.Keys do Result.ClassInterface.Add(k, fClassInterface[k]);
      foreach var k in fClassGenericParam.Keys do Result.ClassGenericParam.Add(k, fClassGenericParam[k]);
      foreach var k in fClassGenericConstraint.Keys do Result.ClassGenericConstraint.Add(k, fClassGenericConstraint[k]);
      foreach var k in fFuncGenericParam.Keys do Result.FuncGenericParam.Add(k, fFuncGenericParam[k]);
      foreach var k in fProcGenericParam.Keys do Result.ProcGenericParam.Add(k, fProcGenericParam[k]);
      foreach var k in fFuncGenericConstraint.Keys do Result.FuncGenericConstraint.Add(k, fFuncGenericConstraint[k]);
      foreach var k in fProcGenericConstraint.Keys do Result.ProcGenericConstraint.Add(k, fProcGenericConstraint[k]);
      foreach var k in fEnumMemberEnumName.Keys do Result.EnumMemberEnumName.Add(k, fEnumMemberEnumName[k]);
      foreach var k in fEnumMemberOrdinal.Keys do Result.EnumMemberOrdinal.Add(k, fEnumMemberOrdinal[k]);
    end;

    function ParseProgram: TProgramNode;
    var prog: TProgramNode; t: TToken;
    begin
      // [Stage 44] library Name; (dll 산출물) 또는 program Name; (exe 산출물) 둘 다 허용.
      if Cur.Kind=tkLibrary then
      begin
        fPos:=fPos+1; prog:=new TProgramNode(Expect(tkIdent).Text); prog.IsLibrary:=true; Expect(tkSemicolon);
      end
      else
      begin
        Expect(tkProgram); prog:=new TProgramNode(Expect(tkIdent).Text); Expect(tkSemicolon);
      end;
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
      while (Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure) or (Cur.Kind=tkConstructor) do
      begin
        // [Phase 2] 함수/프로시저/메서드/생성자 구현 하나가 깨져도 전체를 멈추지 않고
        // 오류를 모은 뒤 다음 구현부(또는 var/begin) 자리로 건너뛰어 계속한다.
        var implStartPos:=fPos;
        try
        begin
        // [Stage 42] 생성자 구현은 항상 "constructor ClassName.Create;" 형태 (top-level 생성자는 없음)
        if Cur.Kind=tkConstructor then
        begin
          prog.ConstructorImpls.Add(ParseConstructorImpl);
        end
        else
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
        end;
        except
          on ex: Exception do
          begin
            ParseErrors.Add(ex.Message);
            if fPos=implStartPos then fPos:=fPos+1;
            // 다음 안전 지점: 새 함수/프로시저/생성자 선언, var 섹션, 또는 메인 begin.
            // [주의] 깨진 선언 자신의 begin...end 본문을 통째로 건너뛰어야 한다 — 그렇지 않으면
            // 그 안의 'begin'을 "다음 안전 지점"으로 착각해서 멈추고, 결과적으로 그 뒤의 진짜
            // var 섹션/메인 begin을 못 찾고 파싱 전체가 어긋난다. begin/end 중첩 깊이를 추적한다.
            var syncDepth:=0;
            while Cur.Kind<>tkEOF do
            begin
              if (syncDepth=0) and ((Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure)
                 or (Cur.Kind=tkConstructor) or (Cur.Kind=tkVar)) then
                break;
              if Cur.Kind=tkBegin then syncDepth:=syncDepth+1
              else if (Cur.Kind=tkEnd) and (syncDepth>0) then syncDepth:=syncDepth-1;
              fPos:=fPos+1;
            end;
          end;
        end;
      end;

      if Cur.Kind=tkVar then ParseVarSection(prog);

      // [Stage 44] library는 begin...end 초기화 블록이 없을 수 있다 — 디자이너가 생성하는
      // ControlLib 코드는 타입/생성자/메서드 선언만 있고 바로 "end."으로 끝난다.
      // program은 기존처럼 항상 begin...end가 있어야 한다.
      if (not prog.IsLibrary) or (Cur.Kind=tkBegin) then
      begin
        Expect(tkBegin);
        // [Phase 2] 예전엔 여기 별도의 인라인 루프가 있어서 ParseStatementsUntilEnd의
        // 오류 복구(수집 후 다음 안전 지점으로 건너뛰기)를 못 받았다 — 재사용으로 통일.
        ParseStatementsUntilEnd(prog.Statements);
        Expect(tkEnd);
      end
      else
        Expect(tkEnd); // begin 없이 바로 "end."
      Expect(tkDot); Expect(tkEOF);

      // [Phase 2] 파싱 도중 여러 곳에서 모아둔 오류가 있으면 이제야 한꺼번에 보고한다.
      // (Lexer의 다중 오류 형식과 동일하게 맞춰서 Main.pas의 PrintCompileError가
      // 줄마다 따로 소스 문맥을 보여줄 수 있게 한다 — Main.pas는 손댈 필요가 없다.)
      if ParseErrors.Count>0 then
        raise new Exception('구문 분석 오류 '+ParseErrors.Count.ToString+'건 발견:'#10+string.Join(#10, ParseErrors));

      Result:=prog;
    end;
  end;

implementation

end.