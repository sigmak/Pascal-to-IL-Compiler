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
    RecordNames: List<string>; // [Stage 62]
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
      RecordNames:=new List<string>; // [Stage 62]
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
    // [성능] List<string> → HashSet<string>. 이 이름 테이블들은 식별자 하나를 파싱할 때마다
    // .Contains()로 여러 번 조회되는(Parser.pas 전체에서 50곳 이상) 핫패스라, 심볼 수가
    // 늘어날수록(자기컴파일처럼 함수/클래스 수백~수천 개) List의 O(n) 선형 탐색이 그대로
    // 체감 컴파일 시간에 곱해진다. Contains/Add만 쓰고 순서·인덱스 접근이 없는 걸 확인했으므로
    // O(1) 평균 조회의 HashSet으로 바꾼다 (ExportSymbols의 List.AddRange(HashSet)은 그대로 동작).
    fFuncNames, fProcNames, fArrayNames: HashSet<string>;
    // [Stage 101 버그 수정] fArrayNames는 Stage 98부터 "진짜 array of T" 뿐 아니라
    // List<T>/Dictionary<K,V> 같은 인덱서를 가진 외부 컬렉션 필드/변수도 함께 포함하게
    // 넓어졌다. 그런데 "arr[i][j] — 두 번째 '['가 있으면 2차원 인덱스"(Stage 67) 분기가
    // fArrayNames에 있다는 사실만으로 무조건 TMatrix2DIndexExprNode/TMatrix2DAssignStmtNode를
    // 만들어버려서, fClassGenericParam[templateName][ci]처럼 Dictionary 필드를 이중
    // 인덱싱하는 (진짜 2차원 배열이 아닌) 식/문장까지 "로컬/전역 2차원 배열 변수"로 오인해
    // Scope.GetLoc에서 KeyNotFoundException으로 죽었다(자기컴파일 중 실제로 재현됨 —
    // Parser.pas 자신의 ResolveGenericInstantiation). fMatrixNames는 진짜 vtMatrix로
    // 선언된 이름만 담는 별도 세트로, "두 번째 '[' → 2차원" 판단을 이걸로만 좁힌다.
    fMatrixNames: HashSet<string>;
    // [Stage 65, 1차] 현재 파싱 중인 최상위 함수/프로시저 안에 선언된 지역(중첩) 서브프로그램의
    // "소스에 쓰인 이름 → 맹글링된 실제 이름(Outer$Inner)" 매핑. 최상위 함수/프로시저에
    // 들어갈 때 새로 만들고 나올 때 이전 값(보통 nil)으로 복원한다 — 한 겹만 지원하므로
    // 지역 서브프로그램 자신의 본문 파싱 중에는 새로 만들지 않고 그대로 이어서 쓴다.
    fCurNestedAlias: Dictionary<string, string>;
    // [Stage 87] uses 절에 나온 네임스페이스 목록 — System, System.Drawing, System.Windows.Forms 등.
    // ParseParamTypeExt/ParseVarType에서 단순 이름(EventArgs, Label 등)을 완전 경로로 해석할 때 사용.
    fImportedNamespaces: List<string>;
    fClassNames: HashSet<string>; // 선언된 클래스 이름 목록 (제네릭 템플릿 이름 + 단형화된 구체 이름 포함) [성능] HashSet
    fInterfaceNames: HashSet<string>; // 선언된 인터페이스 이름 목록 [성능] HashSet
    fEnumNames: HashSet<string>; // [Phase 1] 선언된 열거형 이름 목록 (타입 파싱 시 vtEnum 분류용) [성능] HashSet
    // [Stage 62] 선언된 레코드 이름 목록. 레코드 이름은 fClassNames에도 함께 등록해서
    // (var/필드/매개변수 타입 인식 같은) 기존 "지역 클래스 이름" 인식 경로를 그대로 재사용한다 —
    // fRecordNames는 그중 "값 타입이라 new/상속이 금지된다" 같은 레코드 전용 규칙을 걸 때만 따로 확인한다.
    fRecordNames: HashSet<string>; // [성능] HashSet
    // [Stage 66] 이미 등록된 연산자 오버로딩 조합 집합 ("기호|타입이름"). 같은 조합이 두 번
    // 선언되는 것을 막는 용도로만 쓴다.
    fOperatorSigs: HashSet<string>;
    // [Stage 51] 열거형 멤버 이름 → 소속 열거형 이름 / 서수. North → ('TDirection', 0) 처럼
    // 식(expression) 안에서 괄호 없는 식별자로 등장하는 열거형 값을 판별하는 데 쓰인다.
    fEnumMemberEnumName: Dictionary<string, string>;
    fEnumMemberOrdinal: Dictionary<string, integer>;
    fEnumSize: Dictionary<string, integer>; // [Stage 63] 열거형명 → 멤버 개수
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
    fGenericClassNames: HashSet<string>; // 제네릭 템플릿으로 선언된 클래스 이름 (예: 'TStack') [성능] HashSet
    // [Stage 32] 템플릿 이름 → 타입 매개변수 이름 목록 (예: 'TStack'→['T'], 'TPair'→['K','V'])
    fClassGenericParam: Dictionary<string, List<string>>;
    // [Stage 34] 템플릿 이름 → 타입 매개변수별 제약조건 목록 (fClassGenericParam과 같은 인덱스로 대응, ''=제약 없음)
    fClassGenericConstraint: Dictionary<string, List<string>>;
    // [Stage 36] 최상위 제네릭 함수/프로시저 지원 (클래스 제네릭과 동일한 패턴).
    fGenericFuncNames, fGenericProcNames: HashSet<string>; // 제네릭 템플릿으로 선언된 함수/프로시저 이름 [성능] HashSet
    fFuncGenericParam, fProcGenericParam: Dictionary<string, List<string>>;      // 템플릿 이름 → 타입 매개변수 이름 목록
    fFuncGenericConstraint, fProcGenericConstraint: Dictionary<string, List<string>>; // 템플릿 이름 → 제약조건 목록(같은 인덱스)
    // [Stage 74] 클래스 안의 자체 제네릭 메서드(TFoo.Bar<T>). 1차 제약: 클래스와 무관하게
    // "메서드 이름"만으로 색인한다(같은 이름의 제네릭 메서드가 서로 다른 두 클래스에 있으면
    // 충돌 — 호출부(obj.Method<T>(...))에서 obj의 정적 클래스를 파서가 추적하지 않기 때문).
    fGenericMethodNames: List<string>;
    fMethodGenericParam: Dictionary<string, List<string>>;      // 메서드 이름 → 타입 매개변수 이름 목록
    fMethodGenericConstraint: Dictionary<string, List<string>>; // 메서드 이름 → 제약조건 목록(같은 인덱스)
    // [Stage 32] 현재 파싱 중인 제네릭 클래스 본문/메서드구현에서 유효한 타입 매개변수 이름들 (빈 목록이면 제네릭 문맥 아님)
    fCurGenericParams: List<string>;
    // [Stage 32] ParseVarType/ParseParamTypeExt가 vtGeneric을 반환했을 때, 그 자리에서 바로 리턴값에
    // 담을 수 없는 "어느 타입 매개변수였는지" 이름을 넘겨주는 보조 채널. 호출 직후 곧바로 읽어야 한다.
    fLastGenericName: string;

    // [Stage 72] PABCSystem 표준 라이브러리 함수 이름 화이트리스트. Pascal은 대소문자를
    // 구분하지 않으므로 소스의 표기(대문자든 소문자든)와 무관하게 항상 이 표의 정규화된
    // 표기를 돌려준다 — 화이트리스트에 없는 이름이면 빈 문자열('')을 돌려주고, 호출부는
    // 그 경우 기존 경로(사용자 정의 함수/변수 등)로 계속 진행한다.
    // [버그 수정] PascalABC.NET은 and/or를 완전 평가(non-short-circuit)한다. 코드 곳곳에
    // "outer.ContainsKey(k1) and outer[k1].ContainsKey(k2)" 형태로 중첩 Dictionary를
    // 조회하던 자리들은, outer에 k1이 없을 때도 outer[k1]을 그대로 평가해
    // KeyNotFoundException을 던졌다(자기컴파일 실제 사례 — CodeGen.pas/Scope.pas와 동일한
    // 근본 원인). 이 제네릭 헬퍼로 통일해, k1이 없으면 k2를 아예 조회하지 않도록 한다.
    function DictDictHas<TV>(d: Dictionary<string, Dictionary<string, TV>>; k1, k2: string): boolean;
    var _ddHasKey: boolean;
    begin
      _ddHasKey:=d.ContainsKey(k1);
      if _ddHasKey then
        Result:=d[k1].ContainsKey(k2)
      else
        Result:=false;
    end;

    function NormalizeBuiltinFuncName(text: string): string;
    var lw: string;
    begin
      lw:=text.ToLower;
      if lw='abs' then Result:='Abs'
      else if lw='sqr' then Result:='Sqr'
      else if lw='sqrt' then Result:='Sqrt'
      else if lw='round' then Result:='Round'
      else if lw='trunc' then Result:='Trunc'
      else if lw='random' then Result:='Random'
      else if lw='uppercase' then Result:='UpperCase'
      else if lw='lowercase' then Result:='LowerCase'
      else if lw='trim' then Result:='Trim'
      else if lw='copy' then Result:='Copy'
      else if lw='pos' then Result:='Pos'
      else if lw='strtoint' then Result:='StrToInt'
      else if lw='strtofloat' then Result:='StrToFloat'
      else if lw='floattostr' then Result:='FloatToStr'
      else if lw='ord' then Result:='Ord'
      else if lw='chr' then Result:='Chr'
      else if lw='readln' then Result:='ReadLn'
      // [Stage 90] Format('{0}, {1}', a, b) — .NET string.Format 스타일 문자열 서식.
      // 인자 개수는 여기서 검증하지 않고(가변 인자) CodeGen의 EmitBuiltinCall에서 처리한다.
      else if lw='format' then Result:='Format'
      // [Stage 93] GetCurrentDir — 인자 없이 괄호 없이도 쓰는 표준 함수(파스칼 관례).
      // IsNiladicBuiltinFuncName에 등록된 이름만 괄호 없는 호출도 허용한다.
      else if lw='getcurrentdir' then Result:='GetCurrentDir'
      // [Stage 96] ParamCount / ParamStr(n) — 커맨드라인 인자 접근. Main.pas의
      // ResolveInputPath가 셀프호스팅 컴파일 대상에 새로 들어오면서 처음 필요해졌다.
      else if lw='paramcount' then Result:='ParamCount'
      else if lw='paramstr' then Result:='ParamStr'
      else Result:='';
    end;

    // [Stage 93] 괄호 없이도 호출 가능한(인자 0개) 표준 라이브러리 함수 이름 화이트리스트.
    // Pascal 관례상 인자 없는 함수는 괄호를 생략할 수 있다(예: appPath := GetCurrentDir;).
    // 여기 없는 이름은 기존처럼 '(' 뒤따를 때만 함수 호출로 인식된다.
    function IsNiladicBuiltinFuncName(text: string): boolean;
    var lw3: string;
    begin
      lw3:=text.ToLower;
      // [Stage 96] ParamCount는 괄호 없이 값처럼 쓰인다 (예: "if ParamCount >= 1 then").
      Result:=(lw3='getcurrentdir') or (lw3='paramcount');
    end;

    // [Stage 92] byte(204) 처럼 .NET 원시 값 타입 이름을 캐스트 대상으로 쓰는 표현을 인식하기
    // 위한 화이트리스트. WinForms 디자이너가 생성하는 (byte)(204) 류 캐스트 지원의 기반이 된다.
    // (여기 없는 이름은 기존 경로대로 일반 함수 호출/식별자로 계속 처리된다.)
    function IsPrimitiveCastTypeName(text: string): boolean;
    var lw2: string;
    begin
      lw2:=text.ToLower;
      Result:=(lw2='byte') or (lw2='sbyte') or (lw2='short') or (lw2='ushort') or
              (lw2='int') or (lw2='uint') or (lw2='long') or (lw2='ulong') or
              (lw2='single') or (lw2='double') or (lw2='decimal') or
              (lw2='char') or (lw2='bool') or (lw2='boolean') or (lw2='object');
    end;

    // [Stage 98 버그 수정] fArrayNames는 원래 "array of T" 필드/지역변수/매개변수만 등록해
    // "이름[식]" 인덱싱 문법을 허용하는 용도였다(위쪽 "array of T 클래스 필드" 버그 수정
    // 주석 참고). 그런데 List<T>/Dictionary<K,V> 같은 외부 제네릭 컬렉션도 .NET에서는
    // 똑같이 "컬렉션이름[인덱스]"로 인덱서 접근이 가능하다 — 예를 들어 이 컴파일러 자신의
    // "fTokens: List<TToken>;" 필드를 "fTokens[fPos]"로 읽는 코드가 그렇다. 하지만 이런
    // 필드는 ParseExternalGenericType을 거쳐 vtObject+IsExternalType으로만 기록되고
    // fArrayNames에는 전혀 등록되지 않아서, 위와 똑같은 이유로 "["가 "알 수 없는 문장"
    // 오류로 이어졌다. 인덱서를 갖는 대표적인 .NET 제네릭 컬렉션 타입 이름을 화이트리스트로
    // 인식해, 그런 타입의 필드/지역변수/매개변수도 fArrayNames에 함께 등록되도록 한다.
    function IsIndexerCapableExternalType(cn: string): boolean;
    var lcn: string;
    begin
      lcn:=cn.ToLower;
      Result:=lcn.StartsWith('list<') or lcn.StartsWith('ilist<') or
              lcn.StartsWith('dictionary<') or lcn.StartsWith('idictionary<') or
              lcn.StartsWith('system.collections.generic.list<') or
              lcn.StartsWith('system.collections.generic.dictionary<');
    end;

    function Cur: TToken; begin Result:=fTokens[fPos]; end;

    // [Stage 102 버그 수정] 클래스 멤버를 위에서 아래로 단일 패스로 파싱하다 보니, 어떤
    // 메서드의 본문이 "같은 클래스 안에서 자신보다 뒤에 선언된" 다른 무인자(니라딕) 메서드를
    // 괄호 없이 호출하면(Pascal 관용 표현, 예: Lexer.pas의 CC) fClassMethods[cn]에 그 이름이
    // 아직 등록되지 않아 "괄호 없이 호출된 자기 클래스의 무인자 메서드" 분기 조건이 실패하고
    // 최종 else로 떨어져 TFieldReadExprNode(필드 읽기)로 오인된다 — 실제 사례: Parser.pas
    // 자신의 ParsePrimary(앞쪽에 선언)가 뒤쪽에 선언된 ParseAddSub를
    // "idxE:=ParseAddSub;"처럼 괄호 없이 부름. CodeGen은 이를 필드로 찾다가
    // "필드/속성을 찾을 수 없음: TParser.ParseAddSub"로 실패한다.
    // 본문을 실제로 파싱하기 전에, 이 클래스 안의 모든 procedure/function 이름을 가볍게
    // (전체 문법을 따르지 않고 토큰만 훑어) 미리 fClassMethods[cn]에 등록해 이 순서 의존성을
    // 원천적으로 없앤다. begin/case/try/record는 반드시 대응하는 end가 있으므로 깊이 카운터로
    // 그 안(메서드 본문 등)을 건너뛰고, 깊이가 0인 상태에서 처음 만나는 end가 바로 이 클래스
    // 자신의 닫는 end이므로 거기서 스캔을 멈춘다. fPos는 스캔 전후로 그대로 복원한다.
    procedure PreRegisterClassMethodNames(cn: string);
    var savedPos, depth: integer;
    begin
      savedPos:=fPos;
      depth:=0;
      while fPos<fTokens.Count do
      begin
        if (Cur.Kind=tkBegin) or (Cur.Kind=tkCase) or (Cur.Kind=tkTry) or (Cur.Kind=tkRecord) then
          depth:=depth+1
        else if Cur.Kind=tkEnd then
        begin
          if depth=0 then break; // 이 클래스 자신의 닫는 end — 스캔 종료
          depth:=depth-1;
        end
        else if (depth=0) and ((Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure)) then
        begin
          var _preIsFunc:=(Cur.Kind=tkFunction);
          if (fPos+1<fTokens.Count) and (fTokens[fPos+1].Kind=tkIdent) then
          begin
            var _preName:=fTokens[fPos+1].Text;
            if not fClassMethods[cn].ContainsKey(_preName) then
              fClassMethods[cn][_preName]:=_preIsFunc;
          end;
        end;
        fPos:=fPos+1;
      end;
      fPos:=savedPos;
    end;

    // [Stage 94] ParseTypeName(필드/변수 선언 타입, Stage 87)이 쓰는 것과 같은 방식으로 —
    // uses 절에 나열된 네임스페이스들 + 이미 로드된 어셈블리 목록에서 name이 실제로 어떤
    // 타입으로 존재하는지 찾는다. 식(expression) 위치에서 "TabControl(sender)"처럼 우리가
    // 미리 알 수 없는(사용자 함수도 로컬 클래스도 아닌) 외부 타입 이름으로의 캐스트를
    // 인식하는 데 재사용한다. 찾으면 fullName에 "네임스페이스.타입이름"을 채우고 true.
    function TryResolveExternalTypeByUses(name: string; var fullName: string): boolean;
    var _ns93: string; _full93: string; _t93: System.Type; _asm93: System.Reflection.Assembly; _searchNs93: List<string>;
    begin
      fullName:='';
      // [Stage 96] System은 uses 절에 명시적으로 없어도 항상 폴백으로 탐색한다 (ParseParamTypeExt와 동일한 이유).
      _searchNs93:=new List<string>(fImportedNamespaces);
      if not _searchNs93.Contains('System') then _searchNs93.Add('System');
      foreach _ns93 in _searchNs93 do
      begin
        _full93:=_ns93+'.'+name;
        try
          _t93:=System.Type.GetType(_full93);
          if _t93=nil then
            foreach _asm93 in System.AppDomain.CurrentDomain.GetAssemblies() do
            begin _t93:=_asm93.GetType(_full93); if _t93<>nil then break; end;
          if _t93<>nil then begin fullName:=_full93; break; end;
        except
        end;
      end;
      Result:=fullName<>'';
    end;

    // [버그 수정] "obj.Method(arg).Member" (예: dirText.Substring(1).Trim) 패턴이 아래
    // "TypeName(expr).member 캐스트" 분기(segs2.Count>1 and 다음 토큰이 '(')와 겉보기에
    // 똑같아서, 지금까지는 인자가 단순 변수/필드가 아니면(예: 정수 리터럴 1) 무조건 캐스트로
    // 오판해 "dirText.Substring"을 존재하지 않는 외부 타입으로 취급했다. 이 헬퍼로 실제
    // segs2 전체(이미 점으로 합쳐진 이름)가 진짜 리플렉션 가능한 CLR 타입인지 먼저 확인해,
    // 아니면 일반 메서드 호출 체인으로 폴백하도록 한다. 이미 로드된 어셈블리만 검색한다는
    // 점에서 TryResolveExternalTypeByUses와 동일 — {$reference}/자동 GAC 로드는 Lexer가
    // 토큰화 직후(Main.pas의 TryEarlyLoadAssembly) 이미 처리해 뒀으므로 이 시점엔 반영돼 있다.
    function IsResolvableExternalTypeName(fullName: string): boolean;
    var _t94: System.Type; _asm94: System.Reflection.Assembly;
    begin
      Result:=false;
      try
        _t94:=System.Type.GetType(fullName);
        if _t94<>nil then begin Result:=true; exit; end;
      except
      end;
      foreach _asm94 in System.AppDomain.CurrentDomain.GetAssemblies() do
      begin
        try
          _t94:=_asm94.GetType(fullName);
          if _t94<>nil then begin Result:=true; exit; end;
        except
        end;
      end;
    end;

    // [Stage 70] LINQ 스타일 확장 메서드 체이닝(Source.Where(...).Select(...) 등) 인식을 위해
    // 현재 위치에서 offset만큼 앞선 토큰을 소비 없이 미리 본다. 범위를 벗어나면 마지막 토큰
    // (항상 tkEOF여야 함 — Lexer가 토큰 스트림 끝에 EOF를 붙여 둔다는 기존 전제를 그대로 따름)을 돌려준다.
    function PeekAt(offset: integer): TToken;
    begin
      if fPos+offset < fTokens.Count then Result:=fTokens[fPos+offset]
      else Result:=fTokens[fTokens.Count-1];
    end;

    // [Stage 70] "이 토큰이 LINQ 확장 메서드 화이트리스트 이름인가" — 일반 obj.Method() 호출 파싱과
    // 절대 충돌하지 않도록 정해진 5개 이름(Where/Select/Sum/Count/ToArray)만 인식한다.
    function IsSeqExtMethodName(tok: TToken): boolean;
    begin
      Result:=(tok.Kind=tkIdent) and
        ((tok.Text='Where') or (tok.Text='Select') or (tok.Text='Sum')
         or (tok.Text='Count') or (tok.Text='ToArray'));
    end;

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
    // 속성/메서드 이름으로 허용한다.
    // [Stage 101 버그 수정] 기존에는 tkLength/read/write/real/double/char/int64 6개만 하드코딩된
    // 화이트리스트였다 — 그런데 System.Type.GetType(...)처럼 외부 타입의 정적 멤버를 체인으로
    // 부르는 표현식에서는 "Type" 자체가 이 컴파일러의 예약어(tkType)라서 걸러지지 못하고
    // "멤버 이름이 와야 합니다"로 실패했다. ExpectQualNamePart(Stage 100, 타입 이름 조각용)와
    // 동일한 이유의 문제라 동일하게 화이트리스트 대신 블랙리스트(진짜 이름이 될 수 없는 토큰만
    // 제외)로 바꾼다 — 점 뒤 위치는 어차피 Pascal 키워드가 의미를 가질 수 없는 자리이므로 안전하다.
    function ExpectMemberName: string;
    var t: TToken;
    begin
      t:=Cur;
      case t.Kind of
        tkDot, tkDotDot, tkSemicolon, tkColon, tkComma, tkAssign, tkArrow,
        tkPlus, tkMinus, tkStar, tkSlash, tkPlusAssign,
        tkEq, tkNeq, tkLt, tkGt, tkLe, tkGe,
        tkLParen, tkRParen, tkLBracket, tkRBracket,
        tkString, tkIntLiteral, tkRealLiteral, tkCharLiteral, tkEOF:
          raise new Exception('줄 '+t.Line.ToString+', 열 '+t.Column.ToString
            +': 멤버 이름이 와야 합니다 ("'+t.Text+'")');
      end;
      fPos:=fPos+1; Result:=t.Text;
    end;

    // [Phase 1] ExpectMemberName처럼, read/write/property 같은 Phase 1 키워드도
    // 멤버 이름 위치에서는 식별자로 허용해야 한다.
    function IsKeywordAllowedAsMemberName(k: TTokenKind): boolean;
    begin
      Result:=(k=tkLength) or (k=tkRead) or (k=tkWrite) or (k=tkReal)
           or (k=tkDouble) or (k=tkChar) or (k=tkInt64);
    end;

    // [Stage 100 버그 수정] 점(.)으로 연결된 외부(.NET) 타입/네임스페이스 이름의 한 조각을
    // 소비한다. System.Type, System.String, System.Array, System.Char, System.Boolean처럼
    // .NET BCL에서는 흔한 이름들이 이 컴파일러의 Pascal 예약어(type/string/array/char/boolean 등)와
    // 우연히 글자가 겹치면, Lexer는 문맥을 모른 채 항상 그 키워드 토큰으로 분류해버린다.
    // 하지만 점(.) 바로 뒤는 Pascal 키워드가 올 수 없는 자리이므로, 여기서는 tkIdent가
    // 아니어도 구두점/연산자/리터럴/EOF가 아닌 토큰이면 전부 이름 조각으로 허용한다.
    // ExpectMemberName(점 뒤 프로퍼티/메서드 이름, Stage 41)과 같은 문제의 다른 얼굴이지만,
    // 그쪽은 좁은 화이트리스트였던 것과 달리 여기는 "외부 타입 전체 경로"라 어떤 예약어든
    // 부딪힐 수 있어 화이트리스트 대신 블랙리스트(진짜로 이름이 될 수 없는 것들)로 판단한다.
    function ExpectQualNamePart: string;
    var t: TToken;
    begin
      t:=Cur;
      case t.Kind of
        tkDot, tkDotDot, tkSemicolon, tkColon, tkComma, tkAssign, tkArrow,
        tkPlus, tkMinus, tkStar, tkSlash, tkPlusAssign,
        tkEq, tkNeq, tkLt, tkGt, tkLe, tkGe,
        tkLParen, tkRParen, tkLBracket, tkRBracket,
        tkString, tkIntLiteral, tkRealLiteral, tkCharLiteral, tkEOF:
          raise new Exception('줄 '+t.Line.ToString+', 열 '+t.Column.ToString
            +': 예상 식별자(외부 타입 이름 조각) 실제 '+t.Kind.ToString+' ("'+t.Text+'")');
      end;
      fPos:=fPos+1; Result:=t.Text;
    end;

    // [Stage 86] 외부(.NET) 제네릭 타입의 타입 인자 하나를 파싱한다.
    // 기본 타입 키워드, 로컬 클래스/열거형 이름, 점(.)으로 연결된 외부 타입 이름,
    // 또는 중첩된 외부 제네릭 타입(예: List<string>)을 허용한다.
    // 사용자 정의 제네릭 클래스(TStack<T> 등)를 타입 인자 자리에 쓰는 경우는
    // ResolveGenericInstantiation 쪽 기존 경로를 그대로 재사용한다.
    function ParseExternalGenericTypeArg: string;
    var argName: string; nestedArgs: List<string>;
    begin
      if Cur.Kind=tkInteger then begin fPos:=fPos+1; Result:='integer'; exit; end;
      if Cur.Kind=tkStringType then begin fPos:=fPos+1; Result:='string'; exit; end;
      if Cur.Kind=tkBoolean then begin fPos:=fPos+1; Result:='boolean'; exit; end;
      if (Cur.Kind=tkReal) or (Cur.Kind=tkDouble) then begin fPos:=fPos+1; Result:='real'; exit; end;
      if Cur.Kind=tkChar then begin fPos:=fPos+1; Result:='char'; exit; end;
      if Cur.Kind=tkInt64 then begin fPos:=fPos+1; Result:='int64'; exit; end;
      if Cur.Kind=tkIdent then
      begin
        argName:=Cur.Text; fPos:=fPos+1;
        // 사용자 정의 제네릭 클래스가 타입 인자로 쓰인 경우(중첩 제네릭): 기존 단형화 경로로 위임
        if (Cur.Kind=tkLt) and fGenericClassNames.Contains(argName) then
        begin
          argName:=ResolveGenericInstantiation(argName);
          Result:=argName; exit;
        end;
        while Cur.Kind=tkDot do begin fPos:=fPos+1; argName:=argName+'.'+ExpectQualNamePart; end;
        if Cur.Kind=tkLt then // 중첩된 외부 제네릭 타입 인자 (예: Dictionary<string, List<string>>)
        begin
          fPos:=fPos+1;
          nestedArgs:=new List<string>;
          nestedArgs.Add(ParseExternalGenericTypeArg);
          while Cur.Kind=tkComma do begin fPos:=fPos+1; nestedArgs.Add(ParseExternalGenericTypeArg); end;
          Expect(tkGt);
          argName:=argName+'<'+string.Join(',', nestedArgs.ToArray)+'>';
        end;
        Result:=argName;
      end
      // [자기컴파일] Dictionary<string, array of System.Type> 처럼 제네릭 인자 자리에
      // array of <외부타입> 이 오는 경우. "array[]" 형태의 문자열로 반환한다.
      else if Cur.Kind=tkArray then
      begin
        fPos:=fPos+1; Expect(tkOf);
        var arrElem:=ParseExternalGenericTypeArg; // 원소 타입 재귀 파싱
        Result:=arrElem+'[]';
      end
      else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
        +': 제네릭 타입 인자로 지원되지 않는 타입 ("'+Cur.Text+'")');
    end;

    // [Stage 86] 외부(.NET) 제네릭 타입 이름 전체를 파싱한다. 호출 시점에 baseName(예: "Dictionary")은
    // 이미 소비된 상태이고 Cur='<' 이어야 한다. 결과는 "Dictionary<string,FileChangeWatcher>" 형태의
    // 문자열 — CodeGen.ResolveExternalType이 이 표기를 그대로 인식해 재귀적으로 CLR 타입을 조립한다.
    function ParseExternalGenericType(baseName: string): string;
    var args: List<string>;
    begin
      Expect(tkLt);
      args:=new List<string>;
      args.Add(ParseExternalGenericTypeArg);
      while Cur.Kind=tkComma do begin fPos:=fPos+1; args.Add(ParseExternalGenericTypeArg); end;
      Expect(tkGt);
      Result:=baseName+'<'+string.Join(',', args.ToArray)+'>';
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
        // [Stage 67] array of array of <elemtype> → 2차원 배열 (vtMatrix)
        if Cur.Kind=tkArray then
        begin
          fPos:=fPos+1; Expect(tkOf);
          if Cur.Kind=tkInteger then begin fPos:=fPos+1; fLastGenericName:='integer'; Result:=vtMatrix; end
          else if Cur.Kind=tkStringType then begin fPos:=fPos+1; fLastGenericName:='string'; Result:=vtMatrix; end
          else if (Cur.Kind=tkReal) or (Cur.Kind=tkDouble) then begin fPos:=fPos+1; fLastGenericName:='real'; Result:=vtMatrix; end
          else if Cur.Kind=tkChar  then begin fPos:=fPos+1; fLastGenericName:='char'; Result:=vtMatrix; end
          else if Cur.Kind=tkInt64 then begin fPos:=fPos+1; fLastGenericName:='int64'; Result:=vtMatrix; end
          else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
            +': array of array of 뒤에는 integer/string/real/char/int64만 지원 (Stage 67)');
        end
        else if Cur.Kind=tkInteger then begin fPos:=fPos+1; Result:=vtIntArray; end
        else if Cur.Kind=tkStringType then begin fPos:=fPos+1; Result:=vtStrArray; end
        // [Phase 1] array of real/char/int64 — vtObject + ClassName으로 표현 (CLR double[]/char[]/long[])
        else if (Cur.Kind=tkReal) or (Cur.Kind=tkDouble) then
          begin fPos:=fPos+1; fLastGenericName:='real'; Result:=vtGenericArray; end // 임시: Monomorphize가 real[]로 처리
        else if Cur.Kind=tkChar  then
          begin fPos:=fPos+1; fLastGenericName:='char'; Result:=vtGenericArray; end
        else if Cur.Kind=tkInt64 then
          begin fPos:=fPos+1; fLastGenericName:='int64'; Result:=vtGenericArray; end
        // [Stage 90] array of object — .NET object[] (예: Assembly.GetCustomAttributes의 반환 타입).
        // fClassNames에 없는 'object'라는 단순 식별자일 때만 반응(사용자 클래스 이름 'object'와 충돌 방지).
        else if (Cur.Kind=tkIdent) and (Cur.Text.ToLower='object') and (not fClassNames.Contains(Cur.Text)) then
          begin fPos:=fPos+1; Result:=vtObjArray; end
        // [Stage 37] array of T — 제네릭 템플릿 본문에서만 등장. 실제 타입은 Monomorphize가 채운다.
        else if (Cur.Kind=tkIdent) and fCurGenericParams.Contains(Cur.Text) then
          begin fLastGenericName:=Cur.Text; fPos:=fPos+1; Result:=vtGenericArray; end
        // [자기컴파일] array of System.Type 처럼 array of <외부 타입> — vtObjArray + ClassName으로 표현.
        // ParseExternalGenericTypeArg와 동일 로직으로 외부 타입 이름을 완성한다.
        else if Cur.Kind=tkIdent then
        begin
          var _aoExt:=Cur.Text; fPos:=fPos+1;
          while Cur.Kind=tkDot do begin fPos:=fPos+1; _aoExt:=_aoExt+'.'+ExpectQualNamePart; end;
          fLastGenericName:=_aoExt+'[]'; Result:=vtObjArray;
        end
        else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': array of integer/string/real/char/int64'
          +'(또는 제네릭 문맥에서는 array of T)만 지원');
      end
      else if (Cur.Kind=tkIdent) and fEnumNames.Contains(Cur.Text) then
      begin
        fLastGenericName:=Cur.Text; fPos:=fPos+1; Result:=vtEnum; // [Phase 1]
      end
      // [Stage 63] set of <열거형>. 원소는 열거형 하나로 한정하며(정수 범위 집합은 아직 미지원),
      // 런타임 표현이 32비트 비트마스크이므로 열거형 멤버가 32개를 넘으면 지원 범위 밖이다.
      else if Cur.Kind=tkSet then
      begin
        fPos:=fPos+1; Expect(tkOf);
        if not ((Cur.Kind=tkIdent) and fEnumNames.Contains(Cur.Text)) then
          raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': set of 뒤에는 열거형 이름이 와야 합니다 (Stage 63)');
        // [버그 수정] PascalABC.NET의 and 완전 평가 — Cur.Text가 fEnumSize에 없을 때도
        // 인덱싱이 평가되어 KeyNotFoundException을 던지던 문제. 단계적 if로 교체.
        if fEnumSize.ContainsKey(Cur.Text) then
        begin
          if fEnumSize[Cur.Text]>32 then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 열거형 "'+Cur.Text
              +'"의 멤버가 32개를 넘어 집합으로 표현할 수 없습니다 (Stage 63은 32비트 비트마스크 사용)');
        end;
        fLastGenericName:=Cur.Text; fPos:=fPos+1; Result:=vtSet;
      end
      else if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
      begin
        // [버그 수정] 로컬 클래스 이름도 fLastGenericName에 저장 — 외부 타입(405번 줄)과
        // 동일하게, 호출부(함수/메서드 반환 타입 파싱)가 ReturnClassName을 채울 수 있도록.
        fLastGenericName:=Cur.Text; fPos:=fPos+1; Result:=vtObject;
      end
      else if Cur.Kind=tkIdent then
      begin
        // [Stage 94+] List<TToken>/Dictionary<K,V>/HashSet<T> 등 .NET BCL 제네릭 컬렉션을
        // 반환 타입으로 쓰는 경우 — ParseParamTypeExt와 동일한 화이트리스트로 처리한다.
        // (예: function Tokenize: List<TToken>; — 셀프 호스팅 컴파일 시 Lexer.pas가 이 패턴을 씀)
        var _qn87v:=Cur.Text;
        if (PeekAt(1).Kind=tkLt) and
           ((_qn87v='List') or (_qn87v='Dictionary') or (_qn87v='HashSet') or (_qn87v='Queue') or (_qn87v='Stack')
            or (_qn87v='IEnumerable') or (_qn87v='IList') or (_qn87v='IDictionary') or (_qn87v='ICollection')
            or (_qn87v='SortedList') or (_qn87v='LinkedList') or (_qn87v='SortedDictionary')) then
        begin
          fPos:=fPos+1; // 컬렉션 이름 소비
          // [Stage 97 버그 수정] 파라미터 타입 파싱(ParseParamTypeExt)과 동일한 버그 —
          // 이전에는 fLastGenericName에 arity/타입인자 없는 "System.Collections.Generic.List"만
          // 남기고 SkipGenericArgs로 실제 타입 인자를 버렸다. ResolveExternalType은 이 이름으로
          // System.Type.GetType을 시도하지만 실제 CLR 이름은 "List`1"(+타입인자)이라 항상 실패한다.
          // ParseExternalGenericType으로 실제 타입 인자를 담아 "List<TToken>" 형태로 만든다.
          fLastGenericName:=ParseExternalGenericType(_qn87v); Result:=vtObject;
        end
        else
        begin
        // [자기컴파일] "System.Type"처럼 점(.)으로 연결된 완전한 외부 타입 이름을 반환
        // 타입 자리에 직접 쓴 경우 — 그동안은 첫 세그먼트("System") 하나만 단순 이름으로
        // 보고 fImportedNamespaces 접두사를 붙여봤다가 실패하면 바로 "타입이 와야 합니다"
        // 로 포기했다. 여기서 먼저 점으로 이어지는 전체 세그먼트를 다 모은 뒤, 그 완전한
        // 이름으로 직접 타입을 찾는다(찾으면 네임스페이스 접두사가 필요 없다).
        var _qnFull87v:=_qn87v;
        fPos:=fPos+1; // 첫 세그먼트("System") 소비
        while Cur.Kind=tkDot do
        begin
          fPos:=fPos+1; // '.' 소비
          _qnFull87v:=_qnFull87v+'.'+ExpectMemberName; // ExpectMemberName이 다음 세그먼트도 소비함
        end;
        // 완전한 이름으로 직접 타입 조회 시도
        var _resolvedFull87v:='';
        try
          var _tFull87v:=System.Type.GetType(_qnFull87v);
          if _tFull87v=nil then
            foreach var _asmFull87v in System.AppDomain.CurrentDomain.GetAssemblies() do
            begin _tFull87v:=_asmFull87v.GetType(_qnFull87v); if _tFull87v<>nil then break; end;
          if _tFull87v<>nil then _resolvedFull87v:=_qnFull87v;
        except
        end;
        // [Stage 87] 로컬 클래스도 아닌 단순 이름 — uses 절 네임스페이스에서 탐색
        // [Stage 96] System은 uses 절에 없어도 항상 마지막 폴백으로 탐색한다.
        var _resolved87v:='';
        if _resolvedFull87v<>'' then _resolved87v:=_resolvedFull87v
        else
        begin
        var _searchNs87v:=new List<string>(fImportedNamespaces);
        if not _searchNs87v.Contains('System') then _searchNs87v.Add('System');
        foreach var _ns87v in _searchNs87v do
        begin
          var _full87v:=_ns87v+'.'+_qnFull87v;
          try
            var _t87v:=System.Type.GetType(_full87v);
            if _t87v=nil then
              foreach var _asm87v in System.AppDomain.CurrentDomain.GetAssemblies() do
              begin _t87v:=_asm87v.GetType(_full87v); if _t87v<>nil then break; end;
            if _t87v<>nil then begin _resolved87v:=_full87v; break; end;
          except
          end;
        end;
        end;
        if _resolved87v<>'' then
        begin
          fLastGenericName:=_resolved87v; Result:=vtObject;
        end
        else
          raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 타입이 와야 합니다 ("'+_qnFull87v+'")');
        end;
      end
      else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 타입이 와야 합니다 ("'+Cur.Text+'")');
    end;

    // [Stage 99] 타입 이름 뒤에 오는 제네릭 인자 목록 "<A, B<C>, ...>"를 통째로 소비한다.
    // 파서가 인식하지 못하는 외부 제네릭 타입(예: List<TParamDef>, Dictionary<string,integer>)을
    // 파라미터/필드 타입으로 쓸 때 "<...>" 부분이 남아 토큰 스트림이 어긋나는 버그를 방지한다.
    // 중첩 꺾쇠도 depth로 카운트해 올바르게 처리한다.
    procedure SkipGenericArgs;
    var depth: integer;
    begin
      if Cur.Kind<>tkLt then exit;
      depth:=1; fPos:=fPos+1; // '<' 소비
      while (depth>0) and (Cur.Kind<>tkEOF) do
      begin
        if Cur.Kind=tkLt then depth:=depth+1
        else if Cur.Kind=tkGt then depth:=depth-1;
        fPos:=fPos+1;
      end;
      // depth=0일 때 fPos는 이미 '>' 다음을 가리킴
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
      // [Stage 63] set of <열거형>
      if Cur.Kind=tkSet then
      begin
        fPos:=fPos+1; Expect(tkOf);
        if not ((Cur.Kind=tkIdent) and fEnumNames.Contains(Cur.Text)) then
          raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': set of 뒤에는 열거형 이름이 와야 합니다 (Stage 63)');
        // [버그 수정] PascalABC.NET의 and 완전 평가 — Cur.Text가 fEnumSize에 없을 때도
        // 인덱싱이 평가되어 KeyNotFoundException을 던지던 문제. 단계적 if로 교체.
        if fEnumSize.ContainsKey(Cur.Text) then
        begin
          if fEnumSize[Cur.Text]>32 then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 열거형 "'+Cur.Text
              +'"의 멤버가 32개를 넘어 집합으로 표현할 수 없습니다 (Stage 63은 32비트 비트마스크 사용)');
        end;
        cn:=Cur.Text; fLastGenericName:=cn; fPos:=fPos+1; Result:=vtSet; exit;
      end;
      // [Stage 87] object — .NET System.Object 매개변수/필드 타입
      if (Cur.Kind=tkIdent) and (Cur.Text.ToLower='object') and (not fClassNames.Contains(Cur.Text)) then
      begin
        fPos:=fPos+1; cn:='System.Object'; isExt:=true; Result:=vtObject; exit;
      end;
      if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
      begin
        cn:=Cur.Text; fPos:=fPos+1; Result:=vtObject;
        if (Cur.Kind=tkLt) and fGenericClassNames.Contains(cn) then cn:=ResolveGenericInstantiation(cn)
        else if Cur.Kind=tkLt then SkipGenericArgs; // [Stage 99] 인식 못 하는 제네릭 인자 소비
      end
      else if (Cur.Kind=tkIdent) and fInterfaceNames.Contains(Cur.Text) then
      begin cn:=Cur.Text; fPos:=fPos+1; Result:=vtInterface; end
      else if Cur.Kind=tkIdent then
      begin
        var savedPos4:=fPos;
        var qn4:=Expect(tkIdent).Text;
        // [버그 수정] List<T>/Dictionary<K,V> 같은 .NET BCL 제네릭 컬렉션을 매개변수/필드
        // 타입으로 직접 쓰면(예: AST.pas의 "ps: List<TParamDef>"), 아래 네임스페이스 탐색이
        // System.Type.GetType("System.Collections.Generic.List")를 시도하는데 이건 항상 nil이다
        // — 실제 CLR 타입 이름은 arity가 붙은 "List`1" 형태라 붙지 않은 이름으로는 못 찾는다.
        // 그 결과 "타입이 와야 합니다 (List)"로 실패했다. 자주 쓰는 컬렉션 이름을 미리 알려진
        // 목록으로 특별 취급해 System.Collections.Generic.<이름> 외부 타입으로 바로 인식시킨다
        // — 제네릭 타입 인자 자체는 지금 단계에서는 검증하지 않고 SkipGenericArgs로 소비만 한다.
        if (Cur.Kind=tkLt) and
           ((qn4='List') or (qn4='Dictionary') or (qn4='HashSet') or (qn4='Queue') or (qn4='Stack')
            or (qn4='IEnumerable') or (qn4='IList') or (qn4='IDictionary') or (qn4='ICollection')
            or (qn4='SortedList') or (qn4='LinkedList') or (qn4='SortedDictionary')) then
        begin
          // [Stage 97 버그 수정] 예전에는 cn:='System.Collections.Generic.'+qn4 로 arity/타입인자가
          // 없는 이름을 만들고 SkipGenericArgs로 실제 타입 인자(<TToken> 등)를 그냥 버렸다.
          // 그 결과 CodeGen.ResolveExternalType이 System.Type.GetType("System.Collections.Generic.List")를
          // 시도하는데, 실제 CLR 이름은 "List`1"(닫힌 제네릭이면 타입 인자까지 필요)이라 항상 실패
          // ("외부 타입 ... List 을(를) 찾을 수 없습니다")했다. ParseExternalGenericType으로 실제
          // 타입 인자를 그대로 파싱해 "List<TToken>" 형태로 만들면, ResolveExternalType이
          // '<' 포함 여부로 ResolveExternalGenericType 경로를 타 정상적으로 닫힌 제네릭 타입을 조립한다.
          cn:=ParseExternalGenericType(qn4); isExt:=true; Result:=vtObject;
        end
        else if Cur.Kind=tkDot then
        begin
          while Cur.Kind=tkDot do begin fPos:=fPos+1; qn4:=qn4+'.'+ExpectQualNamePart; end;
          isExt:=true; Result:=vtObject;
          // [셀프 컴파일 버그 수정] Stage 99에서는 점(.)으로 완전히 연결된 외부 타입 이름 뒤에
          // 제네릭 타입 인자(예: System.Collections.Generic.KeyValuePair<string, TypeBuilder>)가
          // 오면 SkipGenericArgs로 그냥 버렸다. 그 결과 cn이 arity/타입인자 없는
          // "System.Collections.Generic.KeyValuePair"로만 남아 CodeGen.ResolveExternalType이
          // "System.Collections.Generic.KeyValuePair`2"를 조립할 방법이 없어 "외부 타입을
          // 찾을 수 없습니다"로 실패했다(List/Dictionary 같은 짧은 이름은 Stage 97에서 이미
          // ParseExternalGenericType으로 고쳤지만, 점으로 연결된 완전한 이름 쪽은 빠져 있었다).
          // 짧은 이름 경로와 동일하게 ParseExternalGenericType으로 실제 타입 인자를 그대로
          // cn에 담아 "KeyValuePair<string,TypeBuilder>" 형태로 만들면, ResolveExternalType의
          // '<' 포함 여부 분기가 ResolveExternalGenericType으로 정상적으로 닫힌 제네릭을 조립한다.
          if Cur.Kind=tkLt then cn:=ParseExternalGenericType(qn4)
          else cn:=qn4;
        end
        else
        begin
          // [Stage 87] 점 없는 단순 이름 — uses 절 네임스페이스에서 탐색.
          // 예: EventArgs → System.EventArgs / System.Windows.Forms.EventArgs
          // CLR에 실제로 있는 첫 번째 완전 경로를 사용한다.
          // [Stage 96 버그 수정] "ex: Exception"처럼 System 네임스페이스의 흔한 타입(Exception,
          // Object, String, Array 등)을 매개변수/필드 타입으로 쓸 때, 소스의 uses 절에 정작
          // "System"이 없으면(대개 System.IO/System.Text처럼 하위 네임스페이스만 있음)
          // 이 탐색이 전부 실패해 "타입이 와야 합니다"로 죽었다. System은 항상 로드되어 있는
          // mscorlib의 기본 네임스페이스이므로, uses 절에 명시되어 있지 않아도 마지막
          // 폴백으로 항상 시도한다.
          var _searchNs87:=new List<string>(fImportedNamespaces);
          if not _searchNs87.Contains('System') then _searchNs87.Add('System');
          var _resolved87:='';
          foreach var _ns87 in _searchNs87 do
          begin
            var _full87:=_ns87+'.'+qn4;
            try
              var _t87:=System.Type.GetType(_full87);
              if _t87=nil then
              begin
                // GetType이 nil 반환 시 — 로드된 어셈블리 전체에서 재탐색
                foreach var _asm87 in System.AppDomain.CurrentDomain.GetAssemblies() do
                begin
                  _t87:=_asm87.GetType(_full87);
                  if _t87<>nil then break;
                end;
              end;
              if _t87<>nil then begin _resolved87:=_full87; break; end;
            except
            end;
          end;
          if _resolved87<>'' then
          begin
            isExt:=true; Result:=vtObject;
            // [셀프 컴파일 버그 수정] 위 점(.)-연결 분기와 같은 이유로, 네임스페이스 탐색으로
            // 해석된 단순 이름 뒤에 제네릭 타입 인자가 오는 경우도 SkipGenericArgs로 버리지 않고
            // ParseExternalGenericType으로 담아야 ResolveExternalType이 닫힌 제네릭을 조립할 수 있다.
            if Cur.Kind=tkLt then cn:=ParseExternalGenericType(_resolved87)
            else cn:=_resolved87;
          end
          else
          begin
            fPos:=savedPos4;
            Result:=ParseVarType; // 기본 타입도 지역클래스도 아니면 여기서 명확한 에러
          end;
        end;
      end
      else
      begin
        Result:=ParseVarType;
        // [버그 수정] "gpBuilders: array of GenericTypeParameterBuilder"처럼 array of <외부 타입>
        // (vtObjArray) 이거나 array of T / array of real·char·int64(vtGenericArray) 매개변수도
        // vtMatrix와 마찬가지로 fLastGenericName에 원소 타입 이름을 담아 두는데, 예전에는
        // vtMatrix일 때만 cn으로 복사해서 vtObjArray/vtGenericArray는 cn=''로 비워진 채
        // 남았다. 그 결과 CodeGen의 VTC(vtObjArray, '')가 원소 타입을 몰라 조용히 object[]로
        // 폴백해, 이후 그 배열 원소에 대한 메서드 호출이 항상 System.Object 기준으로 잘못
        // 해석됐다(자기컴파일 중 실제 재현됨: ApplyGenericParamConstraints의
        // "gpBuilders: array of GenericTypeParameterBuilder").
        if (Result=vtMatrix) or (Result=vtObjArray) or (Result=vtGenericArray) then cn:=fLastGenericName;
      end;
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
        // [버그 수정] PascalABC.NET의 and 완전 평가(non-short-circuit) 때문에 "X and Y"에서
        // X가 false여도 Y는 그대로 평가된다 — cur가 fClassInterface에 없을 때도
        // fClassInterface[cur]가 평가되어 KeyNotFoundException을 던지던 문제. and로 묶는 대신
        // ContainsKey일 때만 값을 비교하는 단계적 if로 바꾼다.
        if fClassInterface.ContainsKey(cur) then
        begin
          if fClassInterface[cur]=constraintName then begin Result:=true; exit; end;
        end;
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
        else if (Cur.Kind=tkIdent) and fRecordNames.Contains(Cur.Text) then // [Stage 62]
          raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 레코드 "'+Cur.Text
            +'"는 아직 제네릭 타입 인자로 쓸 수 없습니다 (값 타입 — Stage 62)')
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

    // [Stage 74] obj.Method<T,U>(...) 형태의 제네릭 메서드 호출에서 '<' 이후 타입 인자 목록을
    // 파싱한다. ResolveGenericFuncInstantiation(최상위 제네릭 함수/프로시저용)과 같은 문법·제약
    // 검증 로직을 쓰지만, 메서드 호출은 이름을 맹글링하지 않고(대상 클래스를 파서가 모르므로)
    // 타입 인자를 AST 노드(GenericArgTypes/GenericArgClassNames)에 그대로 실어 CodeGen에 넘긴다.
    procedure ParseMethodCallGenericArgs(methodName: string; var argTypes: List<TVarType>; var argClassNames: List<string>);
    var
      oneType: TVarType; oneClassName, oneTag: string;
      paramNames, constraintList: List<string>;
    begin
      Expect(tkLt);
      paramNames:=nil; constraintList:=nil;
      if fMethodGenericParam.ContainsKey(methodName) then paramNames:=fMethodGenericParam[methodName];
      if fMethodGenericConstraint.ContainsKey(methodName) then constraintList:=fMethodGenericConstraint[methodName];

      argTypes:=new List<TVarType>; argClassNames:=new List<string>;
      while true do
      begin
        oneClassName:='';
        if Cur.Kind=tkInteger then begin fPos:=fPos+1; oneType:=vtInteger; oneTag:='integer'; end
        else if Cur.Kind=tkStringType then begin fPos:=fPos+1; oneType:=vtString; oneTag:='string'; end
        else if Cur.Kind=tkBoolean then begin fPos:=fPos+1; oneType:=vtBoolean; oneTag:='boolean'; end
        else if (Cur.Kind=tkIdent) and fClassNames.Contains(Cur.Text) then
          begin oneClassName:=Cur.Text; oneType:=vtObject; oneTag:=Cur.Text; fPos:=fPos+1; end
        else
          raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 메서드 "'+methodName
            +'"의 타입 인자로 지원되지 않는 타입 ("'+Cur.Text+'") — integer/string/boolean 또는 일반 클래스만 가능합니다 (Stage 74)');

        if (constraintList<>nil) and (argTypes.Count<constraintList.Count) and (constraintList[argTypes.Count]<>'') then
        begin
          if (oneType<>vtObject) or (not SatisfiesConstraint(oneClassName, constraintList[argTypes.Count])) then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 메서드 "'+methodName
              +'"의 타입 인자 "'+oneTag+'"는 제약조건 "'+constraintList[argTypes.Count]+'"을(를) 만족하지 않습니다');
        end;

        argTypes.Add(oneType); argClassNames.Add(oneClassName);
        if Cur.Kind=tkComma then fPos:=fPos+1 else break;
      end;
      Expect(tkGt);

      if (paramNames<>nil) and (paramNames.Count<>argTypes.Count) then
        raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 메서드 "'+methodName+'"는 타입 매개변수 '
          +paramNames.Count.ToString+'개가 필요한데 '+argTypes.Count.ToString+'개가 주어졌습니다');
    end;

    // ---- 식 파싱 (ParsePrimary 안에서는 ParseAddSub만 호출) ----

    function ParsePrimary: TExprNode;
    var t: TToken; inner, argE, idxE: TExprNode;
        cn: TFuncCallExprNode; mc: TMethodCallExprNode;
        extCastFull93: string;
    begin
      t:=Cur;

      // [버그 수정] 단항 마이너스(-x). 예전에는 이 분기 자체가 없어서 i := -7; 처럼 식
      // 맨 앞에 오는 '-'는 무조건 "식이 와야 하는데 -" 파싱 에러였다(이항 뺄셈은
      // ParseAddSub에 있었지만, 단항으로 쓰는 경우는 아무도 처리하지 않았음). 0-피연산자로
      // 접어(fold) 기존 TBinOpNode(boSub)를 그대로 재사용한다 — integer/real 승격 등
      // 기존 이항 뺄셈의 타입 처리 전부를 공짜로 물려받는다. 가장 강하게 묶이도록(즉
      // -x*y가 (-x)*y가 되도록) 피연산자는 재귀적으로 ParsePrimary 하나만 소비한다.
      if t.Kind=tkMinus then
      begin
        fPos:=fPos+1; // '-' 소비
        Result:=new TBinOpNode(boSub, new TIntLiteralNode(0), ParsePrimary);
      end

      // [Stage 91] typeof(TypeName) — .NET typeof 연산자. System.Type 값을 만든다(주로
      // GetCustomAttributes(Type, bool) 같은 리플렉션 API 인자로 쓰인다). 괄호 안이 "값 식"이
      // 아니라 "타입 이름"이라 일반 ParseExpr로는 못 다룬다(변수/필드가 아니므로) — 그래서
      // 등록 안 된 평범한 식별자로 오인되어 typeof만 홀로 소비되고 뒤의 "(...)"가 그대로
      // 남아 "예상 tkRParen 실제 tkLParen" 에러로 이어졌다. 일반 tkIdent 분기보다 먼저 검사.
      else if (t.Kind=tkIdent) and (t.Text.ToLower='typeof') and (PeekAt(1).Kind=tkLParen) then
      begin
        fPos:=fPos+2; // 'typeof' '(' 소비
        // [자기컴파일] typeof(string)/typeof(boolean)/typeof(integer) 처럼
        // 괄호 안에 키워드 타입이 오는 경우 — Expect(tkIdent)는 키워드 토큰을 거부한다.
        var toName: string;
        if Cur.Kind=tkStringType then begin toName:='string'; fPos:=fPos+1; end
        else if Cur.Kind=tkBoolean then begin toName:='boolean'; fPos:=fPos+1; end
        else if Cur.Kind=tkInteger then begin toName:='integer'; fPos:=fPos+1; end
        else if (Cur.Kind=tkReal) or (Cur.Kind=tkDouble) then begin toName:='double'; fPos:=fPos+1; end
        else if Cur.Kind=tkChar then begin toName:='char'; fPos:=fPos+1; end
        else if Cur.Kind=tkInt64 then begin toName:='int64'; fPos:=fPos+1; end
        else
        begin
          toName:=Expect(tkIdent).Text;
          while Cur.Kind=tkDot do begin fPos:=fPos+1; toName:=toName+'.'+ExpectQualNamePart; end;
          // [자기컴파일 버그 수정] typeof(System.Collections.Generic.KeyValuePair<System.Object,System.Object>)
          // 처럼 typeof 안의 타입 이름이 외부 제네릭 타입일 수 있다 — 예전에는 점(.) 체이닝만
          // 처리하고 바로 Expect(tkRParen)으로 넘어가서, 뒤따르는 '<'가 "예상 tkRParen 실제
          // tkLt"로 튕겨나갔다. ParseExternalGenericType/ParseExternalGenericTypeArg(위에서
          // Dictionary<string,T> 같은 필드/매개변수 타입에 이미 쓰이는 것과 동일한 로직)를
          // 재사용해 "Base<Arg1,Arg2>" 형태의 문자열로 완성한다 — CodeGen의 ResolveExternalType이
          // 이미 이 표기를 인식해 재귀적으로 CLR 타입을 조립한다(ResolveExternalGenericType).
          if Cur.Kind=tkLt then toName:=ParseExternalGenericType(toName);
        end;
        Expect(tkRParen);
        Result:=new TTypeOfExprNode(toName);
      end

      else if t.Kind=tkIntLiteral then
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
      // [Stage 95 버그 수정] 실제 Delphi/Object Pascal은 문자열·문자 리터럴을 연산자(+) 없이
      // 그냥 나란히 적으면(예: 'abc'#10'def', '건 발견:'#10) 컴파일 타임에 하나의 문자열
      // 상수로 암시적으로 이어붙인다(개행 등 제어문자를 문자열 리터럴 안에 끼워 넣는 매우 흔한
      // 관용구). 이 파서는 그 규칙이 아예 없어서 '건 발견:'#10처럼 '+' 없이 문자 리터럴이
      // 바로 뒤따르면 리터럴 하나만 소비하고 멈춰버렸고, 그 뒤(#10)는 여전히 인자 목록 안에
      // 남아 있어 상위 호출부가 ')'를 기대하다 tkCharLiteral을 만나 "예상 tkRParen 실제
      // tkCharLiteral" 파싱 오류로 이어졌다. 문자열/문자 리터럴 뒤에 또 문자열/문자 리터럴이
      // 연산자 없이 바로 이어지면(원본 문법의 "겹치는 상수" 규칙) 전부 하나의 문자열로
      // 접어(fold) TStrLiteralNode 하나로 만든다.
      else if t.Kind=tkCharLiteral then
      begin
        fPos:=fPos+1;
        if (Cur.Kind=tkString) or (Cur.Kind=tkCharLiteral) then
        begin
          var sb95:=new System.Text.StringBuilder;
          sb95.Append(t.CharValue);
          while (Cur.Kind=tkString) or (Cur.Kind=tkCharLiteral) do
          begin
            if Cur.Kind=tkString then sb95.Append(Cur.Text) else sb95.Append(Cur.CharValue);
            fPos:=fPos+1;
          end;
          Result:=new TStrLiteralNode(sb95.ToString);
        end
        else
          Result:=new TCharLiteralNode(t.CharValue);
      end

      else if t.Kind=tkString then
      begin
        fPos:=fPos+1;
        if (Cur.Kind=tkString) or (Cur.Kind=tkCharLiteral) then // [Stage 95]
        begin
          var sb95b:=new System.Text.StringBuilder;
          sb95b.Append(t.Text);
          while (Cur.Kind=tkString) or (Cur.Kind=tkCharLiteral) do
          begin
            if Cur.Kind=tkString then sb95b.Append(Cur.Text) else sb95b.Append(Cur.CharValue);
            fPos:=fPos+1;
          end;
          Result:=new TStrLiteralNode(sb95b.ToString);
        end
        else
          Result:=new TStrLiteralNode(t.Text);
      end

      else if t.Kind=tkResult then
        begin fPos:=fPos+1; Result:=new TResultRefNode; end

      else if t.Kind=tkTrue then
        begin fPos:=fPos+1; Result:=new TBoolLiteralNode(true); end

      else if t.Kind=tkFalse then
        begin fPos:=fPos+1; Result:=new TBoolLiteralNode(false); end

      else if t.Kind=tkNil then
        begin fPos:=fPos+1; Result:=new TNilLiteralNode; end // [Stage 29]

      // [Stage 63] 집합 리터럴: [Red, Blue] 또는 빈 집합 []. 원소는 열거형 멤버 이름만
      // 지원한다(정수 범위 집합 등은 아직 지원하지 않음). 모든 원소가 같은 열거형에
      // 속해야 하며, 여기서 곧바로 32비트 비트마스크 상수로 접어(fold) 둔다 — 런타임에는
      // 그냥 정수 하나일 뿐이라 CodeGen은 Ldc_I4 한 번이면 된다.
      // [Stage 96] [...] 리터럴 일반화: Stage 63은 "원소가 전부 열거형 멤버 이름"인 경우만
      // 지원했다(예: [Red, Blue]). 하지만 리플렉션 API 인자([typeof(integer)]), 문자열 배열
      // (['a','b']), 임의의 식([propClrType]) 등도 같은 대괄호 문법을 쓴다 — 예전에는
      // 무조건 "Expect(tkIdent) + 열거형 멤버인지 확인"으로 파싱했기 때문에 이런 경우들이
      // 전부 "집합 리터럴의 원소 ... 는 열거형 멤버가 아닙니다"로 실패했다.
      // 이제는 원소를 일단 일반 식(ParseAddSub)으로 파싱한 뒤 사후 판별한다:
      // - 모든 원소가 "같은 열거형"의 TEnumValueExprNode이면(빈 리스트 포함) 기존과 동일하게
      //   비트마스크 TSetLiteralExprNode로 접는다 — 'in' 연산 등 기존 집합 의미론을 그대로 유지.
      // - 하나라도 아니면 TArrayLiteralExprNode(임의 원소 배열)로 만든다 — 실제 CLR 배열
      //   타입은 CodeGen이 문맥(기대 매개변수 타입/대입 대상 타입)을 보고 정한다.
      else if t.Kind=tkLBracket then
      begin
        fPos:=fPos+1; // '[' 소비
        var arrElems96:=new List<TExprNode>;
        if Cur.Kind<>tkRBracket then
        begin
          arrElems96.Add(ParseAddSub);
          while Cur.Kind=tkComma do begin fPos:=fPos+1; arrElems96.Add(ParseAddSub); end;
        end;
        Expect(tkRBracket);

        var allEnum96:=true; var setEnumName96:=''; var setMask96:=0;
        var elm96: TExprNode; var ev96: TEnumValueExprNode;
        foreach elm96 in arrElems96 do
        begin
          if not (elm96 is TEnumValueExprNode) then begin allEnum96:=false; break; end;
          ev96:=TEnumValueExprNode(elm96);
          if (setEnumName96<>'') and (setEnumName96<>ev96.EnumName) then begin allEnum96:=false; break; end;
          setEnumName96:=ev96.EnumName;
          setMask96:=setMask96 or (1 shl ev96.Ordinal);
        end;

        if allEnum96 then
          Result:=new TSetLiteralExprNode(setEnumName96, setMask96)
        else
        begin
          var arrLit96:=new TArrayLiteralExprNode;
          arrLit96.Elements.AddRange(arrElems96);
          Result:=arrLit96;
        end;
      end

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
              mc.Args.Add(ParseExpr);
              while Cur.Kind=tkComma do begin fPos:=fPos+1; mc.Args.Add(ParseExpr); end;
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
            iceN.Args.Add(ParseExpr);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; iceN.Args.Add(ParseExpr); end;
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
        // [Stage 96 수정] 'new string(ch, count)'처럼 내장 타입 키워드가 new 뒤에 오는 경우.
        // Lexer는 'string'을 tkIdent가 아니라 tkStringType으로 토큰화하므로, 기존
        // Expect(tkIdent) 하나만으로는 "예상 tkIdent 실제 tkStringType" 오류가 났다.
        // System.String에는 new string(char, int)(문자를 count번 반복) 등 유용한 생성자가
        // 있으므로 'string'을 외부 타입 이름으로 그대로 통과시킨다.
        var newTn: string;
        if Cur.Kind=tkStringType then begin newTn:='string'; fPos:=fPos+1; end
        else newTn:=Expect(tkIdent).Text;
        if (Cur.Kind=tkLt) and fGenericClassNames.Contains(newTn) then
          newTn:=ResolveGenericInstantiation(newTn)
        else if Cur.Kind=tkLt then // [Stage 86] new Dictionary<string, FileChangeWatcher> 같은 외부 제네릭 타입 생성
          newTn:=ParseExternalGenericType(newTn);
        while Cur.Kind=tkDot do begin fPos:=fPos+1; newTn:=newTn+'.'+ExpectQualNamePart; end;
        // [Stage 96] 위 tkLt 검사는 점(.)으로 연결되기 전(예: "Dictionary<...>")만 잡았다.
        // "new System.Collections.Generic.List<MethodInfo>()"처럼 여러 단계 점으로 연결된
        // 이름 뒤에 오는 제네릭 인자는 점 소비 루프가 끝난 뒤에야 비로소 '<'를 만나므로,
        // 여기서도 한 번 더 확인해야 한다 — 안 그러면 '<...>'가 소비되지 않고 그대로 남아
        // 뒤에서 비교 연산자로 오인되어 "알 수 없는 문장 (\">\")" 등으로 실패한다.
        if Cur.Kind=tkLt then newTn:=ParseExternalGenericType(newTn);
        if fRecordNames.Contains(newTn) then // [Stage 62]
          raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 레코드 "'+newTn
            +'"는 new로 생성할 수 없습니다 — 변수 선언만으로 이미 필드가 기본값(0/빈 문자열 등)으로 초기화됩니다');
        var neoN:=new TNewObjectExprNode(newTn);
        neoN.IsExternalType:=not fClassNames.Contains(newTn);
        if Cur.Kind=tkLBracket then
        begin
          // [Stage 92] new Type[SizeExpr](item1, item2, ...) — 배열 생성(+ 선택적 초기화 목록).
          // WinForms 디자이너가 흔히 내보내는
          // "new System.Windows.Forms.ToolStripItem[9](a, b, ..., i)" 패턴. CodeGen(EmitExpr의
          // TNewObjectExprNode 처리)은 이미 ArraySizeExpr/Args를 보고 Newarr+Stelem을 내는
          // 지원이 있었지만, Parser가 이 문법 자체를 인식 못 해 '['를 만나면 곧장
          // "예상 tkRParen 실제 tkLBracket"으로 실패하고 있었다.
          fPos:=fPos+1; // '[' 소비
          neoN.ArraySizeExpr:=ParseExpr;
          Expect(tkRBracket);
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
        end
        else if Cur.Kind=tkLParen then
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

      // [Stage 94+] Char.IsLetter(c) / double.Parse(s,...) / integer.Parse(s) / char(code) /
      // string.Join(...) / string.Format(...) 등 내장 타입 키워드가 식(expression) 위치에서
      // 정적 메서드 호출 수신자나 캐스트 대상으로 쓰이는 패턴.
      // Lexer는 이 이름들을 tkChar/tkDouble/tkInteger/tkInt64/tkReal/tkStringType 으로 토큰화해서
      // tkIdent 분기에 도달하지 못한다. 여기서 가로채서 처리한다.
      // 패턴:
      //   타입.메서드(args)  → TMethodCallExprNode('타입명', '메서드명')
      //   char(expr)         → TExternalCastExprNode('char', expr)
      // [중요] t:=Cur 이후 분기 진입 시 반드시 fPos:=fPos+1로 타입 키워드를 소비해야 함.
      else if (t.Kind=tkChar) or (t.Kind=tkDouble) or (t.Kind=tkReal)
           or (t.Kind=tkInteger) or (t.Kind=tkInt64) or (t.Kind=tkStringType) then
      begin
        fPos:=fPos+1; // 타입 키워드(Char/double/integer/int64/string) 소비 — 필수!
        var _btn: string;
        if t.Kind=tkChar       then _btn:='char'
        else if t.Kind=tkDouble     then _btn:='double'
        else if t.Kind=tkReal       then _btn:='double'
        else if t.Kind=tkInteger    then _btn:='integer'
        else if t.Kind=tkInt64      then _btn:='int64'
        else _btn:='string'; // tkStringType

        if Cur.Kind=tkDot then
        begin
          // Char.IsLetter(ch) / double.Parse(s,...) / string.Join(',', list) 등 — 정적 메서드 호출
          fPos:=fPos+1; // '.' 소비
          var _btMname:=Expect(tkIdent).Text;
          var _btMc:=new TMethodCallExprNode(_btn, _btMname);
          if Cur.Kind=tkLParen then
          begin
            fPos:=fPos+1;
            if Cur.Kind<>tkRParen then
            begin
              _btMc.Args.Add(ParseExpr);
              while Cur.Kind=tkComma do begin fPos:=fPos+1; _btMc.Args.Add(ParseExpr); end;
            end;
            Expect(tkRParen);
          end;
          Result:=_btMc;
        end
        else if Cur.Kind=tkLParen then
        begin
          // char(code) / integer(expr) / double(expr) 등 — 타입 캐스트
          fPos:=fPos+1; // '(' 소비
          var _btCastArg:=ParseExpr;
          Expect(tkRParen);
          Result:=new TExternalCastExprNode(_btn, _btCastArg);
        end
        else
          raise new Exception('줄 '+t.Line.ToString+', 열 '+t.Column.ToString
            +': 식이 와야 하는데 "'+t.Text+'" — 내장 타입은 "타입.메서드(...)" 또는 "타입(식)" 형태로만 쓸 수 있습니다');
      end

      else if t.Kind=tkNot then
        begin fPos:=fPos+1; Result:=new TNotExprNode(ParsePrimary); end

      else if t.Kind=tkIntToStr then
      begin
        fPos:=fPos+1; Expect(tkLParen);
        argE:=ParseAddSub; Expect(tkRParen);
        Result:=new TIntToStrNode(argE);
      end

      // [Stage 76] BoolToStr(expr) — boolean 식을 'True'/'False' 문자열로 변환.
      // 인자에 비교식(= 등)이 올 수 있으므로 ParseAddSub가 아닌 ParseExpr로 파싱한다.
      else if t.Kind=tkBoolToStr then
      begin
        fPos:=fPos+1; Expect(tkLParen);
        argE:=ParseExpr; Expect(tkRParen);
        Result:=new TBoolToStrNode(argE);
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
                mc.Args.Add(ParseExpr);
                while Cur.Kind=tkComma do begin fPos:=fPos+1; mc.Args.Add(ParseExpr); end;
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
            if IsResolvableExternalTypeName(string.Join('.', segs2))
               and (castArgs2.Count=1) and (Cur.Kind=tkDot) then
            begin
              var castType2:=string.Join('.', segs2);
              var innerName2:='';
              var isSimpleCastTarget90:=true;
              if castArgs2[0] is TVarRefNode then innerName2:=TVarRefNode(castArgs2[0]).VarName
              else if castArgs2[0] is TFieldReadExprNode then innerName2:=TFieldReadExprNode(castArgs2[0]).FieldName
              else isSimpleCastTarget90:=false;

              if not isSimpleCastTarget90 then
              begin
                // [Stage 90] 단순 변수/필드가 아닌 임의의 식(예: attributes[0]) — 캐스트 노드로 감싸고
                // 뒤의 ".member"/".method(...)"는 ParsePrimary 끝의 범용 체이닝 루프에 맡긴다
                // (거기서 TChainedMemberExprNode로 감싸며, 여러 단계 체이닝도 자동으로 처리됨).
                Result:=new TExternalCastExprNode(castType2, castArgs2[0]);
              end
              else
              begin
                fPos:=fPos+1; // '.' 소비
                var member3:=ExpectMemberName; // [Stage 41] 키워드 속성명(Length 등) 허용
                var mc3:=new TMethodCallExprNode(innerName2, member3);
                mc3.ObjCastType:=castType2;
                if Cur.Kind=tkLParen then
                begin
                  fPos:=fPos+1;
                  if Cur.Kind<>tkRParen then
                  begin
                    mc3.Args.Add(ParseExpr);
                    while Cur.Kind=tkComma do begin fPos:=fPos+1; mc3.Args.Add(ParseExpr); end;
                  end;
                  Expect(tkRParen);
                end;
                Result:=mc3;
              end;
            end
            else
            begin
              // [버그 수정] segs2(예: "dirText.Substring")가 실제로 리플렉션 가능한 외부 타입이
              // 아니면 캐스트일 수 없다 — 그냥 obj.Method(args) 형태의 일반 메서드 호출이다
              // (예: dirText.Substring(1).Trim — dirText는 지역변수, Substring은 그 위의
              // 인스턴스 메서드). 뒤에 이어지는 ".Trim"은 ParsePrimary 끝의 범용 체이닝 루프가
              // 이 mc4 결과 위에 TChainedMemberExprNode로 자동으로 얹어준다.
              // (예: System.Windows.Forms.MessageBox.Show(...) 를 식으로 사용).
              var staticQualifier:=string.Join('.', segs2.GetRange(0, segs2.Count-1));
              var staticMname:=segs2[segs2.Count-1];
              var mc4:=new TMethodCallExprNode(staticQualifier, staticMname);
              foreach var a6 in castArgs2 do mc4.Args.Add(a6);
              Result:=mc4;
            end;
          end
          // [Stage 75] obj.GetType.FullName / obj.GetType.Name — 3단계 체인이지만 첫 세그먼트는
          // 변수(예: except 블록의 ex)이지 외부 타입 이름이 아니다. 아래 일반 정적-경로 분기보다
          // 먼저 검사해야 "ex.GetType"을 존재하지 않는 타입으로 착각해 ResolveExternalType이
          // 실패하는 것을 막는다.
          else if (segs2.Count=3) and (segs2[1].ToLower='gettype')
                  and ((segs2[2].ToLower='fullname') or (segs2[2].ToLower='name')) then
          begin
            Result:=new TRuntimeTypeNameExprNode(segs2[0], segs2[2].ToLower='fullname');
          end

          else if segs2.Count>2 then
          begin
            // [Stage 76 확장] 괄호 없이 3단계 이상 점(.)으로 연결된 경우, 예전에는 무조건
            // "정적 필드/속성 읽기"(예: System.EventArgs.Empty)로만 취급해 TStaticMemberExprNode를
            // 만들었다. 하지만 "MainMenu.Items.Count.ToString"처럼 첫 세그먼트가 실제
            // 필드/변수인 체인도 겉보기엔 똑같아서 파서 단계에서는 둘을 구분할 수 없다
            // (그건 필드/지역변수 테이블을 가진 CodeGen만 안다). 그래서 정적 타입 경로인지
            // 변수 체인인지의 판별 자체를 CodeGen으로 미루고, 여기서는 이미 있는
            // TMethodCallExprNode(한정자 전체, 마지막 세그먼트)로 통일해서 넘긴다 —
            // CodeGen의 InferType/EmitExpr이 IsChainStartSegment로 실제 판별한다.
            var staticQualifier2:=string.Join('.', segs2.GetRange(0, segs2.Count-1));
            var staticMname2:=segs2[segs2.Count-1];
            Result:=new TMethodCallExprNode(staticQualifier2, staticMname2);
            // [Stage 78] 3단계 이상 체인 뒤에 '['가 오는 경우도 외부 컬렉션 인덱서로
            // 재해석한다 (예: Self.Tree.Nodes[0]).
            if Cur.Kind=tkLBracket then
            begin
              fPos:=fPos+1;
              var idxE78b:=ParseAddSub;
              Expect(tkRBracket);
              Result:=new TExternalIndexExprNode(staticQualifier2+'.'+staticMname2, idxE78b);
            end;
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
              // [Stage 74] obj.Method<T>(...) — mname2가 등록된 제네릭 메서드 이름일 때만 '<'를
              // 타입 인자 시작으로 해석한다(그렇지 않으면 obj.Value < 10 같은 비교식과 충돌).
              if (Cur.Kind=tkLt) and fGenericMethodNames.Contains(mname2) then
              begin
                var mcArgTypes74: List<TVarType>; var mcArgClassNames74: List<string>;
                ParseMethodCallGenericArgs(mname2, mcArgTypes74, mcArgClassNames74);
                mc.GenericArgTypes:=mcArgTypes74; mc.GenericArgClassNames:=mcArgClassNames74;
              end;
              if Cur.Kind=tkLParen then
              begin
                fPos:=fPos+1;
                if Cur.Kind<>tkRParen then
                begin
                  mc.Args.Add(ParseExpr);
                  while Cur.Kind=tkComma do begin fPos:=fPos+1; mc.Args.Add(ParseExpr); end;
                end;
                Expect(tkRParen);
              end;
              Result:=mc;
              // [Stage 78] obj.Member[i] — 방금 만든 2단계 체인 뒤에 '['가 오면 외부
              // 컬렉션 인덱서(예: Tree.Nodes[0])로 재해석한다.
              if Cur.Kind=tkLBracket then
              begin
                fPos:=fPos+1;
                var idxE78a:=ParseAddSub;
                Expect(tkRBracket);
                Result:=new TExternalIndexExprNode(t.Text+'.'+mname2, idxE78a);
              end;
            end;
          end;
        end

        // 배열 인덱스 (1차원 또는 2차원)
        else if (Cur.Kind=tkLBracket) and fArrayNames.Contains(t.Text) then
        begin
          fPos:=fPos+1; idxE:=ParseAddSub; Expect(tkRBracket);
          // [Stage 67] arr[i][j] — 두 번째 '[' 가 있으면 2차원 인덱스.
          // [Stage 101 버그 수정] fArrayNames에는 진짜 2차원 배열뿐 아니라(Stage 98부터)
          // List/Dictionary 필드도 섞여 있으므로, 여기서는 fMatrixNames(진짜 vtMatrix만)로
          // 좁혀 판단한다 — 아니면 fClassGenericParam[templateName][ci] 같은 Dictionary
          // 이중 인덱싱까지 "2차원 배열"로 오인해 CodeGen에서 Scope.GetLoc이 죽는다.
          // 매트릭스가 아니면 두 번째 '['는 여기서 소비하지 않고 그대로 남겨, 아래에서
          // TArrayIndexExprNode를 만든 뒤 함수 끝의 범용 체이닝 루프(Stage 96)가
          // TChainedIndexExprNode로 이어받게 한다.
          if (Cur.Kind=tkLBracket) and fMatrixNames.Contains(t.Text) then
          begin
            fPos:=fPos+1;
            var idxE2:=ParseAddSub; Expect(tkRBracket);
            Result:=new TMatrix2DIndexExprNode(t.Text, idxE, idxE2, '');
          end
          else
            Result:=new TArrayIndexExprNode(t.Text, idxE);
        end

        // [자기컴파일] fArrayNames에 등록되지 않은 이름의 인덱싱 — 예: inline var로 선언된
        // List<T>/Dictionary<K,V> 지역변수(ps[0], constraints[ci], callArgs[0] 등). 이런 변수는
        // (헤더 var 섹션이 아니라) "var ps:=...;" 처럼 선언되어 fArrayNames에 등록될 기회가
        // 없었다. 이미 문장 대입 쪽(Stage 88)에서 쓰던 것과 같은 외부 컬렉션 get_Item 인덱서
        // 경로(TExternalIndexExprNode)로 읽는다 — 함수 끝의 범용 체이닝 루프가 뒤이은
        // '.Member'/'.Method(...)'까지 자동으로 이어 붙여준다.
        else if Cur.Kind=tkLBracket then
        begin
          fPos:=fPos+1; idxE:=ParseAddSub; Expect(tkRBracket);
          Result:=new TExternalIndexExprNode(t.Text, idxE);
        end

        // [Stage 36] 제네릭 함수 호출: Identity<integer>(5) — 명시적 타입 인자 필요
        else if (Cur.Kind=tkLt) and fGenericFuncNames.Contains(t.Text) then
        begin
          var concreteFuncName:=ResolveGenericFuncInstantiation(t.Text, false);
          cn:=new TFuncCallExprNode(concreteFuncName);
          Expect(tkLParen);
          if Cur.Kind<>tkRParen then
          begin
            cn.Args.Add(ParseExpr);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; cn.Args.Add(ParseExpr); end;
          end;
          Expect(tkRParen); Result:=cn;
        end

        // 일반 함수 호출
        else if (Cur.Kind=tkLParen) and fFuncNames.Contains(t.Text) then
        begin
          cn:=new TFuncCallExprNode(ResolveCallName(t.Text)); fPos:=fPos+1; // [Stage 65] 지역 함수면 맹글링된 이름으로
          if Cur.Kind<>tkRParen then
          begin
            // [Stage 96] ParseAddSub는 비교 연산자(>=, <=, =, <>, in 등)를 모른다 —
            // ResolveMethodByArity(..., mc.ObjName.IndexOf('.')>=0)처럼 비교식 자체를
            // 인자로 넘기는 흔한 패턴(boolean 매개변수에 조건식을 바로 전달)에서
            // ">="가 그대로 남아 "예상 tkRParen 실제 tkGe"로 실패했다. ParseExpr은
            // ParseAddSub 위에 비교/in만 얹은 상위 계층이라 안전하게 대체 가능하다.
            cn.Args.Add(ParseExpr);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; cn.Args.Add(ParseExpr); end;
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

        // [Stage 72] PABCSystem 표준 라이브러리 함수(Abs/Sqrt/UpperCase/Copy/StrToInt/... 등).
        // fFuncNames(사용자 정의 함수)에 없을 때만 반응하므로, 혹시 사용자가 같은 이름으로
        // 직접 함수를 정의했다면(위의 "일반 함수 호출" 분기가 먼저 걸려) 그쪽이 우선한다.
        // 인자 개수는 여기서 검증하지 않고(0개부터 몇 개든 그대로 받아 둔다) CodeGen이
        // EmitBuiltinCall에서 함수별로 정확한 개수를 검사해 에러 메시지를 낸다.
        else if (Cur.Kind=tkLParen) and (NormalizeBuiltinFuncName(t.Text)<>'') and (not fFuncNames.Contains(t.Text)) then
        begin
          var bcn:=new TBuiltinCallExprNode(NormalizeBuiltinFuncName(t.Text));
          fPos:=fPos+1; // '(' 소비
          if Cur.Kind<>tkRParen then
          begin
            bcn.Args.Add(ParseExpr);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; bcn.Args.Add(ParseExpr); end;
          end;
          Expect(tkRParen);
          Result:=bcn;
        end

        // [Stage 92] byte(204) 같은 .NET 원시 값 타입 캐스트. 사용자 함수/클래스 이름과
        // 겹치면 그쪽을 우선하도록 fFuncNames/fClassNames에 없을 때만 반응한다.
        else if (Cur.Kind=tkLParen) and IsPrimitiveCastTypeName(t.Text) and
                (not fFuncNames.Contains(t.Text)) and (not fClassNames.Contains(t.Text)) then
        begin
          fPos:=fPos+1; // '(' 소비
          var castArgDirect92:=ParseExpr;
          Expect(tkRParen);
          Result:=new TExternalCastExprNode(t.Text, castArgDirect92);
        end

        // [Stage 94] TabControl(sender) 같은, 원시 타입이 아닌 임의의 외부(.NET) 타입으로의
        // 캐스트. byte(204)와 같은 문제이지만 대상이 프로젝트가 미리 알 수 없는(화이트리스트로
        // 못 채우는) 외부 클래스 이름이라, uses 절 네임스페이스 + 이미 로드된 어셈블리에서
        // 실제로 그 이름의 타입이 존재하는지 찾아본다(ParseTypeName의 Stage 87과 동일한 방식).
        // 사용자 함수/로컬 클래스 이름과 겹치면 그쪽을 우선한다.
        else if (Cur.Kind=tkLParen) and (not fFuncNames.Contains(t.Text)) and (not fClassNames.Contains(t.Text))
                and TryResolveExternalTypeByUses(t.Text, extCastFull93) then
        begin
          fPos:=fPos+1; // '(' 소비
          var castArgExt94:=ParseExpr;
          Expect(tkRParen);
          Result:=new TExternalCastExprNode(extCastFull93, castArgExt94);
        end

        // [자기컴파일 버그 수정] TVarRefNode(expr) 같은, 로컬(사용자 정의) 클래스 이름으로의
        // 하드 캐스트. byte(204)/TabControl(sender)와 똑같은 모양이지만 대상이 이 프로젝트
        // 안에서 선언된 클래스(fClassNames)일 때는 바로 위 두 분기 모두 "not
        // fClassNames.Contains(t.Text)" 조건 때문에 걸러지고, 그대로 아래 "암시적 self 메서드
        // 호출" 분기로 떨어져 "TVarRefNode"를 self의 메서드 이름으로 오인했다 — 그 결과
        // CodeGen에서 "알 수 없는 메서드 "TParser.TVarRefNode""처럼 실패했다(Parser.pas
        // 자신이 castArgs[0] is TVarRefNode then innerName:=TVarRefNode(castArgs[0]).VarName
        // 같은 캐스트 표현을 여러 곳에서 쓰기 때문에 self-hosting 컴파일에서만 드러난 버그).
        // 현재 클래스에 정말 같은 이름의 메서드가 있으면(드물지만 이름이 겹칠 수 있으니)
        // 그쪽을 우선한다. Castclass로 구현되는 TAsCastExprNode(IsExternalType=false)를
        // 그대로 재사용하면 fTypeBuilders 조회 로직(TAsCastExprNode 처리부)을 그대로 탄다.
        else if (Cur.Kind=tkLParen) and fClassNames.Contains(t.Text)
                and not ((fCurClass<>'') and DictDictHas(fClassMethods, fCurClass, t.Text)) then
        begin
          fPos:=fPos+1; // '(' 소비
          var castArgLocalCls:=ParseExpr;
          Expect(tkRParen);
          var localClsCast:=new TAsCastExprNode(castArgLocalCls, t.Text);
          localClsCast.IsExternalType:=false;
          Result:=localClsCast;
        end

        // [Stage 93] 괄호 없이 부른 인자 0개 표준 라이브러리 함수 — 예: GetCurrentDir;
        // (Pascal 관례상 무인자 함수는 괄호 생략 가능). IsNiladicBuiltinFuncName 화이트리스트에
        // 있고 사용자가 같은 이름의 함수/필드를 직접 정의하지 않았을 때만 반응한다.
        else if (NormalizeBuiltinFuncName(t.Text)<>'') and IsNiladicBuiltinFuncName(t.Text)
                and (Cur.Kind<>tkLParen) and (not fFuncNames.Contains(t.Text)) then
        begin
          Result:=new TBuiltinCallExprNode(NormalizeBuiltinFuncName(t.Text));
        end

        // [자기컴파일] 암시적 self 메서드 호출 (식 위치): 예) argName:=ResolveGenericInstantiation(argName);
        // ParseStatement 쪽(문장 위치)에는 이미 있던 분기(Show(); 처럼 괄호 있는 암시적 self 호출)와
        // 완전히 동일한 조건 — 대입문 오른쪽이나 다른 식 안에서 자기 클래스 메서드를 호출하면
        // fFuncNames(전역 함수 목록)에는 없으니 여기까지 떨어지는데, 그동안 처리가 없어 "알 수 없는
        // 문장"/"예상 tkRParen" 에러로 이어졌다. Result에 담아두면 함수 끝의 범용 '.member' 체이닝
        // 루프가 이어지는 .Text/.Kind 등을 자동으로 처리해준다.
        else if (fCurClass<>'') and (Cur.Kind=tkLParen) then
        begin
          mc:=new TMethodCallExprNode('', t.Text); fPos:=fPos+1;
          if Cur.Kind<>tkRParen then
          begin
            mc.Args.Add(ParseExpr);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; mc.Args.Add(ParseExpr); end;
          end;
          Expect(tkRParen); Result:=mc;
        end

        // [버그 수정] 괄호 없이 호출된 자기 클래스의 무인자(니라딕) 메서드 —
        // 예: Lexer.pas의 "function CC: char;"를 "while CC=' ' do Adv;"처럼
        // 괄호 없이 값처럼 쓰는 파스칼 관용 표현. 위의 tkLParen 분기는 괄호가
        // 붙어 있을 때만 반응하므로, 괄호 없는 이 경우는 그대로 else로 떨어져
        // "필드 읽기"(TFieldReadExprNode)로 오인되었다 — CC는 필드가 아니라
        // 메서드이므로 CodeGen이 필드 목록에서 못 찾아 "필드/속성을 찾을 수
        // 없음: TLexer.CC" 예외로 이어졌다. 매개변수 이름이 아니면서 현재
        // 클래스의 메서드 이름과 일치할 때만 이 분기가 반응하므로 진짜 필드
        // 읽기 동작에는 영향이 없다.
        else if (fCurClass<>'') and not fCurParams.Contains(t.Text)
                and fClassMethods.ContainsKey(fCurClass)
                and fClassMethods[fCurClass].ContainsKey(t.Text) then
        begin
          Result:=new TMethodCallExprNode('', t.Text);
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
        // [버그 수정] 예전엔 괄호 안을 ParseAddSub로만 파싱해서 (n >= 0) 같은 괄호로 묶인
        // 비교식이 "예상 tkRParen 실제 tkGe" 에러가 났다(비교 연산자는 ParseExpr에만 있고
        // ParseAddSub까지는 안 내려옴). ParseExpr는 ParseAddSub의 상위 호환(비교 연산자가
        // 없으면 결과가 완전히 같음)이라 안전하게 바꿀 수 있다.
        fPos:=fPos+1; inner:=ParseExpr; Expect(tkRParen);

        // [Stage 92] C 스타일 캐스트 (TypeName)(Expr) 인식 — WinForms 디자이너가 생성하는
        // ((byte)(204)) 같은 표현이 여기 해당한다. 괄호로 묶인 식이 단순 식별자(타입 이름)
        // 하나뿐이고 바로 뒤에 또 '('가 이어지는 경우인데, 이 조합은 캐스트가 아니고서는
        // 문법적으로 나올 수 없다(괄호식 뒤에 괄호식이 연산자 없이 바로 이어붙는 경우가
        // 없으므로) — 그래서 화이트리스트 없이 항상 캐스트로 해석해도 안전하다.
        if Cur.Kind=tkLParen then
        begin
          var castTypeName92:='';
          if inner is TVarRefNode then castTypeName92:=TVarRefNode(inner).VarName
          else if inner is TFieldReadExprNode then castTypeName92:=TFieldReadExprNode(inner).FieldName;
          if castTypeName92<>'' then
          begin
            fPos:=fPos+1; // '(' 소비
            var castArgParen92:=ParseExpr;
            Expect(tkRParen);
            inner:=new TExternalCastExprNode(castTypeName92, castArgParen92);
          end;
        end;

        Result:=inner;
      end

      else
        raise new Exception('줄 '+t.Line.ToString+', 열 '+t.Column.ToString+': 식이 와야 하는데 "'+t.Text+'"');

      // [Stage 70] LINQ 스타일 확장 메서드 체이닝: Source.Where(...)/.Select(...)/.Sum()/.Count()/.ToArray().
      // 화이트리스트 이름(IsSeqExtMethodName) + 바로 뒤 '(' 조합일 때만 반응하므로, 위에서 이미
      // 처리된 일반 obj.Method(...) 호출 파싱(TMethodCallExprNode)과는 겹치지 않는다. 여러 번
      // 체이닝 가능(Where(...).Select(...).Sum() 등) — while로 반복.
      // [Stage 90] 위 LINQ 체이닝과, 그 외 일반 멤버 접근/메서드 호출 체인을 하나의 루프로
      // 합쳐서(둘이 섞여도, 예: X.Foo().Where(...).Bar 처럼) 계속 이어질 수 있게 한다.
      // [Stage 96] 원래 tkDot만 반복하던 루프였다. GetIndexParameters()[0], SplitByDot(x)[0],
      // fMethodParamClrTypes[a][b]처럼 "이미 파싱된 식(메서드 호출 결과, 체인된 멤버, 인덱싱
      // 결과 등) 바로 뒤에 또 '['가 오는" 패턴은 예전에는 아예 처리되지 않아 "예상 tkRParen
      // 실제 tkLBracket" 등으로 실패했다. TChainedIndexExprNode는 CodeGen에 이미 구현이
      // 있었지만(EmitExpr/InferType/EmitArgForParamType 참고) 파서가 한 번도 만든 적이 없었다.
      while (Cur.Kind=tkDot) or (Cur.Kind=tkLBracket) do
      begin
        if Cur.Kind=tkLBracket then
        begin
          fPos:=fPos+1; // '[' 소비
          var chIdx96:=ParseAddSub;
          Expect(tkRBracket);
          Result:=new TChainedIndexExprNode(Result, chIdx96);
        end
        else if IsSeqExtMethodName(PeekAt(1)) and (PeekAt(2).Kind=tkLParen) then
        begin
          fPos:=fPos+1; // '.' 소비
          var extName:=Cur.Text; fPos:=fPos+1; // 메서드 이름 소비
          Expect(tkLParen);
          var extLam: TExprLambdaNode := nil;
          if (extName='Where') or (extName='Select') then
          begin
            // 매개변수 하나 -> 식  (괄호 있는 (x) -> ...  / 없는 x -> ... 둘 다 허용)
            var extParamName: string;
            if Cur.Kind=tkLParen then
            begin
              fPos:=fPos+1; extParamName:=Expect(tkIdent).Text; Expect(tkRParen);
            end
            else
              extParamName:=Expect(tkIdent).Text;
            Expect(tkArrow);
            extLam:=new TExprLambdaNode(extParamName, ParseExpr);
          end;
          Expect(tkRParen);
          Result:=new TSeqExtCallExprNode(Result, extName, extLam);
        end
        else
        begin
          // [Stage 90] 일반 체인: expr.Member 또는 expr.Member(args). 예: a.GetName().Version.ToString().
          fPos:=fPos+1; // '.' 소비
          var chMember:=ExpectMemberName;
          if Cur.Kind=tkLParen then
          begin
            var chNode:=new TChainedMemberExprNode(Result, chMember, true);
            fPos:=fPos+1;
            if Cur.Kind<>tkRParen then
            begin
              chNode.Args.Add(ParseExpr);
              while Cur.Kind=tkComma do begin fPos:=fPos+1; chNode.Args.Add(ParseExpr); end;
            end;
            Expect(tkRParen);
            Result:=chNode;
          end
          else
            Result:=new TChainedMemberExprNode(Result, chMember, false);
        end;
      end;
    end;

    // [Stage 30] <식> as <TypeName> — Delphi에서 as는 *,/,mod와 같은 우선순위이므로
    // ParsePrimary 바로 위, ParseMulDivMod가 사용하는 자리에 끼워 넣는다.
    function ParseAsCast: TExprNode;
    var e: TExprNode; tn: string; isExt: boolean; asN: TAsCastExprNode; isN: TIsCheckExprNode; wasIs: boolean;
    begin
      e:=ParsePrimary;
      // [자기컴파일] 'is'는 AST(TIsCheckExprNode)/CodeGen(Isinst+null비교)은 이미 준비돼 있었지만
      // Parser에 인식 자체가 빠져 있었다. 'as'와 완전히 같은 자리(우선순위)에서 함께 처리한다.
      while (Cur.Kind=tkAs) or (Cur.Kind=tkIs) do
      begin
        wasIs:=(Cur.Kind=tkIs);
        fPos:=fPos+1;
        tn:=Expect(tkIdent).Text; isExt:=false;
        while Cur.Kind=tkDot do begin fPos:=fPos+1; tn:=tn+'.'+ExpectQualNamePart; end;
        if not (fClassNames.Contains(tn) or fInterfaceNames.Contains(tn)) then isExt:=true;
        if wasIs then
        begin
          isN:=new TIsCheckExprNode(e, tn); isN.IsExternalType:=isExt;
          e:=isN;
        end
        else
        begin
          asN:=new TAsCastExprNode(e, tn); asN.IsExternalType:=isExt;
          e:=asN;
        end;
      end;
      Result:=e;
    end;

    function ParseMulDivMod: TExprNode;
    var left: TExprNode; op: TBinOpKind;
    begin
      left:=ParseAsCast;
      while (Cur.Kind=tkStar) or (Cur.Kind=tkSlash) or (Cur.Kind=tkMod) or (Cur.Kind=tkAnd)
            or (Cur.Kind=tkShl) or (Cur.Kind=tkShr) do
      begin
        if Cur.Kind=tkStar then op:=boMul
        else if Cur.Kind=tkSlash then op:=boDiv
        else if Cur.Kind=tkMod then op:=boMod
        else if Cur.Kind=tkShl then op:=boShl
        else if Cur.Kind=tkShr then op:=boShr
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
      else if Cur.Kind=tkIn then // [Stage 63] Elem in SetExpr — 관계 연산자와 같은 우선순위
      begin
        fPos:=fPos+1;
        Result:=new TInExprNode(left, ParseAddSub);
      end
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
              if (Cur.Kind=tkBegin) or (Cur.Kind=tkTry) or (Cur.Kind=tkCase) then syncDepth:=syncDepth+1
              else if Cur.Kind=tkEnd then syncDepth:=syncDepth-1;
              fPos:=fPos+1;
            end;
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end;
        end;
      end;
    end;

    // [Stage 60] repeat 문장들 until Condition — ParseStatementsUntilEnd와 동일한 panic-mode
    // 오류 복구 패턴이지만 종료 토큰이 'end'가 아니라 'until'이다. 중첩된 begin/try/case/repeat는
    // 깊이를 늘리고 그에 대응하는 end/until을 만나면 깊이를 줄여, 깊이 0에서 만난 ';' 또는
    // 'until'만 진짜 동기화 지점으로 인정한다 (caseSyncDepth와 같은 원리).
    procedure ParseStatementsUntilRepeat(target: List<TStmtNode>);
    var stmtStartPos: integer; syncDepth: integer;
    begin
      while (Cur.Kind<>tkUntil) and (Cur.Kind<>tkEOF) do
      begin
        stmtStartPos:=fPos;
        try
          target.Add(ParseStatement);
          if Cur.Kind=tkSemicolon then fPos:=fPos+1;
        except
          on ex: Exception do
          begin
            ParseErrors.Add(ex.Message);
            if fPos=stmtStartPos then fPos:=fPos+1;
            syncDepth:=0;
            while Cur.Kind<>tkEOF do
            begin
              if (syncDepth=0) and ((Cur.Kind=tkSemicolon) or (Cur.Kind=tkUntil)) then break;
              if (Cur.Kind=tkBegin) or (Cur.Kind=tkTry) or (Cur.Kind=tkCase) or (Cur.Kind=tkRepeat) then syncDepth:=syncDepth+1
              else if (Cur.Kind=tkEnd) or (Cur.Kind=tkUntil) then syncDepth:=syncDepth-1;
              fPos:=fPos+1;
            end;
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end;
        end;
      end;
    end;

    // ---- 문장 파싱 ----
    // [Stage 64→68] 람다 매개변수 목록과 본문을 파싱한다. 호출 시점에 '(' 은 아직 소비되지 않은 상태.
    // (a: T1; b: T2) -> 문장  또는  (a, b) -> begin...end  모두 허용.
    // [Stage 68] 매개변수 그룹마다 콜론+타입 표기는 선택 사항이다 — 생략하면 vtInferred로
    // 표시해 두고, CodeGen이 델리게이트의 Invoke 시그니처에서 위치별 실제 CLR 타입을 가져와
    // 확정한다(예: (sender, e) -> ... 의 sender/e는 이벤트 델리게이트 시그니처로부터 추론).
    // 본문은 문장 하나 또는 begin...end 블록 모두 허용된다(ParseStatement가 둘 다 처리).
    function ParseLambdaExpr: TLambdaExprNode;
    var ps: List<TParamDef>;
    begin
      Expect(tkLParen);
      ps:=new List<TParamDef>;
      if Cur.Kind<>tkRParen then
      begin
        while true do
        begin
          var lpNames:=new List<string>; lpNames.Add(Expect(tkIdent).Text);
          while Cur.Kind=tkComma do begin fPos:=fPos+1; lpNames.Add(Expect(tkIdent).Text); end;
          if Cur.Kind=tkColon then
          begin
            fPos:=fPos+1;
            var lpIsExt:=false; var lpCn:='';
            var lpType:=ParseParamTypeExt(lpIsExt, lpCn);
            foreach var lpn in lpNames do ps.Add(new TParamDef(lpn, lpType, lpCn, lpIsExt));
          end
          else
            // [Stage 68] 타입 미표기 — vtInferred placeholder. CodeGen이 나중에 채운다.
            foreach var lpn in lpNames do ps.Add(new TParamDef(lpn, vtInferred, '', false));
          if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
        end;
      end;
      Expect(tkRParen);
      Expect(tkArrow);
      Result:=new TLambdaExprNode(ps, ParseStatement);
    end;

    function ParseStatement: TStmtNode;
    var
      nt: TToken; rhs, idx, sz: TExprNode;
      comp: TCompoundStmtNode; cond: TExprNode;
      tS, eS, bS: TStmtNode; pcn: TProcCallStmtNode;
      mcs: TMethodCallStmtNode;
    begin
      if Cur.Kind=tkWriteln then
      begin
        fPos:=fPos+1;
        // [Stage 96 수정] 'Writeln;' (괄호 자체가 없음) 과 'Writeln();' (빈 괄호) 모두
        // 표준 Pascal에서 "인자 없이 줄바꿈만 출력"하는 유효한 호출이다. 기존 코드는
        // Expect(tkLParen)을 무조건 요구해서 'Writeln;'이 "예상 tkLParen 실제
        // tkSemicolon" 파스 오류로 실패했다. 이제 괄호가 없거나 바로 닫히면 빈 줄
        // 출력(TWritelnStringStmtNode(''))으로 처리한다.
        if (Cur.Kind<>tkLParen) then
        begin
          Result:=new TWritelnStringStmtNode('');
        end
        else if (fPos+1<fTokens.Count) and (fTokens[fPos+1].Kind=tkRParen) then
        begin
          fPos:=fPos+2; // '(' 와 ')' 소비
          Result:=new TWritelnStringStmtNode('');
        end
        else
        begin
          fPos:=fPos+1; rhs:=ParseExpr;
          // [Stage 90] writeln(a, b, c, ...) — 콤마로 이어지는 추가 인자 지원.
          // (기존에는 인자를 정확히 1개만 받았고, 콤마가 나오면 "예상 tkRParen 실제 tkComma" 에러.)
          if Cur.Kind=tkComma then
          begin
            var wArgs:=new List<TExprNode>; wArgs.Add(rhs);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; wArgs.Add(ParseExpr); end;
            Expect(tkRParen);
            var wNode90:=new TWritelnArgsStmtNode;
            wNode90.Args:=wArgs;
            Result:=wNode90;
          end
          else
          begin
            Expect(tkRParen);
            if rhs is TStrLiteralNode then
              Result:=new TWritelnStringStmtNode(TStrLiteralNode(rhs).Value)
            else Result:=new TWritelnExprStmtNode(rhs);
          end;
        end;
      end

      // [Stage 75] Readln; 또는 Readln(변수);
      // 렉서는 식별자 대소문자를 정규화하지 않고 원문 그대로 보존하므로(Writeln 등
      // 진짜 예약어와 달리 Readln은 tkIdent로 들어온다), .ToLower로 비교해야 한다.
      else if (Cur.Kind=tkIdent) and (Cur.Text.ToLower='readln') then
      begin
        fPos:=fPos+1;
        if Cur.Kind=tkLParen then
        begin
          fPos:=fPos+1;
          rhs:=ParseExpr; // 대입 대상 변수 식
          Expect(tkRParen);
          Result:=new TReadlnStmtNode(rhs);
        end
        else
          Result:=new TReadlnStmtNode(nil); // 인자 없음 — Enter 대기
      end

      else if Cur.Kind=tkResult then
      begin
        fPos:=fPos+1;
        if Cur.Kind=tkDot then
        begin
          // [자기컴파일] Result.FuncNames.AddRange(...); 처럼 Result 값에 체이닝하는 문장.
          // 일반 식별자의 '.' 체이닝(위쪽 tkIdent 분기)과 같은 패턴이지만 시작 세그먼트가
          // 'Result'라는 점만 다르다 — CodeGen의 IsChainStartSegment/EmitQualifierChainLoad가
          // 'Result'를 인식하도록 함께 손봤다.
          var rsegs:=new List<string>; rsegs.Add('Result');
          while Cur.Kind=tkDot do begin fPos:=fPos+1; rsegs.Add(ExpectMemberName); end;
          var rmname:=rsegs[rsegs.Count-1];
          var rqualifier:=string.Join('.', rsegs.GetRange(0, rsegs.Count-1));
          if Cur.Kind=tkAssign then
          begin
            fPos:=fPos+1;
            var rfas:=new TFieldAssignStmtNode(rmname, ParseExpr);
            rfas.Qualifier:=rqualifier;
            Result:=rfas;
          end
          else
          begin
            var rmcs:=new TMethodCallStmtNode(rqualifier, rmname);
            if Cur.Kind=tkLParen then
            begin
              fPos:=fPos+1;
              if Cur.Kind<>tkRParen then
              begin
                rmcs.Args.Add(ParseExpr);
                while Cur.Kind=tkComma do begin fPos:=fPos+1; rmcs.Args.Add(ParseExpr); end;
              end;
              Expect(tkRParen);
            end;
            Result:=rmcs;
          end;
        end
        else
        begin
          Expect(tkAssign);
          Result:=new TResultAssignStmtNode(ParseExpr);
        end;
      end

      else if Cur.Kind=tkSetLength then
      begin
        fPos:=fPos+1; Expect(tkLParen);
        nt:=Expect(tkIdent); Expect(tkComma);
        sz:=ParseExpr;
        // [Stage 67] SetLength(arr, rows, cols) — 2차원 배열 초기화
        if Cur.Kind=tkComma then
        begin
          fPos:=fPos+1;
          var cols2:=ParseExpr; Expect(tkRParen);
          Result:=new TSetLengthMatrix2DStmtNode(nt.Text, sz, cols2, '');
        end
        else
        begin
          Expect(tkRParen);
          Result:=new TSetLengthStmtNode(nt.Text, sz);
        end;
      end

      // [Stage 48 / 자기컴파일 확장] var x := 식; 뿐 아니라 var x: Type; / var x: Type := 식; /
      // var a, b: Type; 형태도 지원한다(자기 자신의 소스에서 흔히 쓰이던 패턴인데 그동안
      // "var x := 식"의 타입 추론 형태만 지원돼 있었다). 이름들을 먼저 콤마로 모은 뒤,
      // 뒤따르는 토큰이 ':'(타입 명시)인지 아니면 바로 ':='(기존 추론 방식)인지로 갈라진다.
      // [주의] 세미콜론은 이 함수가 아니라 ParseStatementsUntilEnd 호출부가 소비하므로 여기서는
      // Expect(tkSemicolon)을 하지 않는다(기존 관례와 동일).
      else if Cur.Kind=tkVar then
      begin
        fPos:=fPos+1;
        var ivNames:=new List<string>;
        ivNames.Add(Expect(tkIdent).Text);
        while Cur.Kind=tkComma do begin fPos:=fPos+1; ivNames.Add(Expect(tkIdent).Text); end;

        if Cur.Kind=tkColon then
        begin
          // 명시적 타입: var a, b: Type; 또는 var a: Type := 식;
          fPos:=fPos+1; // ':' 소비
          var ivIsExt: boolean; var ivCn: string;
          var ivVt:=ParseParamTypeExt(ivIsExt, ivCn);
          if (ivVt=vtGeneric) or (ivVt=vtGenericArray) or (ivVt=vtMatrix) then ivCn:=fLastGenericName;
          var ivInit: TExprNode := nil;
          if Cur.Kind=tkAssign then
          begin
            if ivNames.Count>1 then
              raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
                +': 여러 변수를 한 번에 선언할 때는 초기화식을 함께 쓸 수 없습니다 (예: "var a, b: 타입;")');
            fPos:=fPos+1; ivInit:=ParseExpr;
          end;
          var ivCompound:=new TCompoundStmtNode;
          foreach var ivNm in ivNames do
          begin
            var ivNode:=new TInlineVarStmtNode(ivNm, ivInit);
            ivNode.HasExplicitType:=true; ivNode.ExplicitVarType:=ivVt;
            ivNode.ExplicitClassName:=ivCn; ivNode.ExplicitIsExternal:=ivIsExt;
            ivCompound.Statements.Add(ivNode);
            fCurParams.Add(ivNm); // 이후 문장에서 이 이름을 필드로 오인하지 않도록 지역변수로 등록
            if (ivVt=vtIntArray) or (ivVt=vtStrArray) or (ivVt=vtGenericArray) or (ivVt=vtObjArray) then
              fArrayNames.Add(ivNm)
            else if ivIsExt and IsIndexerCapableExternalType(ivCn) then
              begin if not fArrayNames.Contains(ivNm) then fArrayNames.Add(ivNm); end;
          end;
          if ivNames.Count=1 then Result:=ivCompound.Statements[0]
          else Result:=ivCompound;
        end
        else
        begin
          // 기존 방식: var x := 식; (타입 명시 없이 여러 개는 지원하지 않음 — 표준 Pascal에도 없음)
          if ivNames.Count>1 then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
              +': 타입 없이 여러 변수를 한 번에 선언할 수 없습니다 (":=" 는 이름 하나만 지원)');
          Expect(tkAssign);
          var ivInferExpr:=ParseExpr;
          Result:=new TInlineVarStmtNode(ivNames[0], ivInferExpr);
          fCurParams.Add(ivNames[0]); // 이후 문장에서 이 이름을 필드로 오인하지 않도록 지역변수로 등록
          // [버그 수정] "var closedTypes74e:=new System.Type[n];"처럼 타입 추론 분기에서도
          // ArraySizeExpr가 있는 배열 생성식이면 진짜 배열이므로 fArrayNames에 등록해야 한다.
          // 위 "타입 명시" 분기(2294행)만 등록을 하고 있어서, 이후 "closedTypes74e[i]:=x" 같은
          // 대입이 fArrayNames.Contains 검사에 걸려 진짜 배열 대입(Stelem) 경로를 못 타고
          // 외부 컬렉션 인덱서 대입(리플렉션 set_Item 탐색) 경로로 잘못 빠졌다 — 진짜 배열은
          // 리플렉션에 set_Item을 노출하지 않으므로 "메서드 set_Item가 없습니다"로 실패했다
          // (자기컴파일 중 실제 재현됨).
          if (ivInferExpr is TNewObjectExprNode) and (TNewObjectExprNode(ivInferExpr).ArraySizeExpr<>nil) then
            begin if not fArrayNames.Contains(ivNames[0]) then fArrayNames.Add(ivNames[0]); end;
        end;
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
            // [Stage 64] 오른쪽이 '('로 시작하면 이름 있는 핸들러 대신 인라인 람다로 취급한다.
            fPos:=fPos+1;
            if Cur.Kind=tkLParen then
            begin
              var evsLam:=new TEventSubscribeStmtNode(qualifier, mname, '');
              evsLam.Lambda:=ParseLambdaExpr;
              Result:=evsLam;
            end
            else
            begin
              var handlerName:=Expect(tkIdent).Text;
              Result:=new TEventSubscribeStmtNode(qualifier, mname, handlerName);
            end;
          end
          else
          begin
            // [Stage 74] obj.Method<T>(...) — mname이 등록된 제네릭 메서드 이름일 때만 '<'를
            // 타입 인자 시작으로 해석한다.
            var mcsArgTypes74: List<TVarType>:=nil; var mcsArgClassNames74: List<string>:=nil;
            if (Cur.Kind=tkLt) and fGenericMethodNames.Contains(mname) then
              ParseMethodCallGenericArgs(mname, mcsArgTypes74, mcsArgClassNames74);

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
              if mcsArgTypes74<>nil then
              begin mcs.GenericArgTypes:=mcsArgTypes74; mcs.GenericArgClassNames:=mcsArgClassNames74; end;
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
          pcn:=new TProcCallStmtNode(ResolveCallName(nt.Text)); fPos:=fPos+1; // [Stage 65] 지역 프로시저면 맹글링된 이름으로
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
          Expect(tkRParen);
          // [자기컴파일 버그 수정] GetOrCreate(cn).ParentName := pn; 처럼, 인자 있는
          // 암시적 self 메서드 호출 바로 뒤에 '.'이 오면 그 반환값의 필드/프로퍼티에
          // 대입(또는 접근)하는 문장이다 — 예전에는 이 경우를 전혀 처리하지 않고
          // Result:=mcs로 끝내버려서, 뒤에 남은 '.ParentName:=pn'이 다음 ParseStatement
          // 호출에서 "알 수 없는 문장 (\".\")"으로 실패했다.
          if Cur.Kind=tkDot then
          begin
            fPos:=fPos+1; // '.' 소비
            var scfaField:=ExpectMemberName;
            if Cur.Kind=tkAssign then
            begin
              fPos:=fPos+1;
              var scfaVal:=ParseExpr;
              var scfaNode:=new TSelfCallFieldAssignStmtNode(mcs.MethodName, scfaField, scfaVal);
              scfaNode.Args:=mcs.Args;
              Result:=scfaNode;
            end
            else
            begin
              // GetOrCreate(cn).Foo(...) — 반환값에 이어서 메서드 호출하는 경우는 아직
              // 실제 사례가 없어 지원하지 않는다; 명확한 오류로 알린다(무음 실패 방지).
              raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
                +': 메서드 호출 결과에 대한 "." 다음에는 대입(:=)만 지원합니다 ("'+scfaField+'")');
            end;
          end
          else
            Result:=mcs;
        end

        // 암시적 self 메서드 호출 (괄호 없음, 인자 없음): 예) Show; Close;
        // [Stage 94+] else/end/until 앞에서도 인식 — if CC=#39 then Adv else raise ... 패턴.
        // 기존에는 세미콜론일 때만 반응해서, then/else 사이에 괄호 없는 메서드 호출이 오면
        // Expect(tkAssign)으로 떨어져 "예상 tkAssign 실제 tkElse" 오류가 발생했다.
        else if (fCurClass<>'') and
                ((Cur.Kind=tkSemicolon) or (Cur.Kind=tkElse) or (Cur.Kind=tkEnd)
                 or (Cur.Kind=tkUntil) or (Cur.Kind=tkEOF)) then
          Result:=new TMethodCallStmtNode('', nt.Text)

        // 배열 원소 대입 (1차원 또는 2차원) — fArrayNames는 진짜 Pascal 배열뿐 아니라
        // List<T>/Dictionary<K,V> 등 인덱서를 가진 외부 컬렉션 필드/변수도 포함하므로(Stage 98),
        // 단일 인덱싱 뒤에 대입이 아니라 '.'이 오는 경우(예: fClassFields[cn].Add(propName);)도
        // 함께 처리한다 — 안 그러면 이 분기가 아래의 "미등록 이름" 폴백보다 먼저 매치되어
        // 항상 Expect(tkAssign)만 시도하다 실패한다.
        else if (Cur.Kind=tkLBracket) and fArrayNames.Contains(nt.Text) then
        begin
          fPos:=fPos+1; idx:=ParseExpr; Expect(tkRBracket);
          // [Stage 67] arr[i][j] := val — 두 번째 '[' 가 있으면 2차원 대입.
          // [Stage 101 버그 수정] fArrayNames에는 List/Dictionary 필드도 섞여 있으므로(Stage 98),
          // 진짜 2차원 배열인지는 fMatrixNames로 좁혀 판단한다. 매트릭스가 아니면
          // fClassMethods[cn][mname]:=isFunc; 같은 이중 인덱서 대입과 동일한 패턴이므로
          // 아래 [Stage 88]의 TExternalDoubleIndexAssignStmtNode 경로를 그대로 재사용한다.
          if (Cur.Kind=tkLBracket) and fMatrixNames.Contains(nt.Text) then
          begin
            fPos:=fPos+1;
            var idx2:=ParseExpr; Expect(tkRBracket);
            Expect(tkAssign); rhs:=ParseExpr;
            // 원소 타입은 CodeGen에서 스코프로 조회하므로 여기선 '' 전달
            Result:=new TMatrix2DAssignStmtNode(nt.Text, idx, idx2, rhs, '');
          end
          else if Cur.Kind=tkLBracket then // [Stage 101] 매트릭스가 아닌 이중 인덱서 대입 (예: Dictionary 필드)
          begin
            fPos:=fPos+1;
            var idx2NonMat:=ParseExpr; Expect(tkRBracket);
            Expect(tkAssign); rhs:=ParseExpr;
            Result:=new TExternalDoubleIndexAssignStmtNode(nt.Text, idx, idx2NonMat, rhs);
          end
          // [자기컴파일] fClassFields[cn].Add(propName); 처럼 인덱싱 결과에 메서드 호출.
          // [Stage 98+] Entries[vn].ClassName := cn; 처럼 인덱싱 결과 필드 대입도 지원.
          else if Cur.Kind=tkDot then
          begin
            fPos:=fPos+1; // '.' 소비
            var idxMnameArr:=ExpectMemberName;
            if Cur.Kind=tkAssign then
            begin
              // arr[idx].Field := value  →  TExternalIndexFieldAssignStmtNode
              fPos:=fPos+1;
              var idxFieldValArr:=ParseExpr;
              Result:=new TExternalIndexFieldAssignStmtNode(nt.Text, idx, idxMnameArr, idxFieldValArr);
            end
            else
            begin
              var eimcArr:=new TExternalIndexMethodCallStmtNode(nt.Text, idx, idxMnameArr);
              if Cur.Kind=tkLParen then
              begin
                fPos:=fPos+1;
                if Cur.Kind<>tkRParen then
                begin
                  eimcArr.Args.Add(ParseExpr);
                  while Cur.Kind=tkComma do begin fPos:=fPos+1; eimcArr.Args.Add(ParseExpr); end;
                end;
                Expect(tkRParen);
              end;
              Result:=eimcArr;
            end;
          end
          else
          begin
            Expect(tkAssign); rhs:=ParseExpr;
            Result:=new TArrayAssignStmtNode(nt.Text, idx, rhs);
          end;
        end

        // [Stage 88] 외부 컬렉션 인덱서 대입: watchers[s] := new FileChangeWatcher(...); 처럼
        // 로컬 Pascal 배열이 아닌 필드/변수에 대괄호 대입이 오는 경우. Dictionary<K,V> 등
        // 외부 제네릭 컬렉션의 인덱서 setter는 CLR에서 컴파일러가 자동 생성하는 "set_Item(key, value)"
        // 메서드라서, 이미 검증된 일반 외부 메서드 호출 경로(TMethodCallStmtNode)로 그대로 위임한다 —
        // CodeGen을 새로 손댈 필요 없이 리플렉션 기반 오버로드 해석을 재사용.
        else if Cur.Kind=tkLBracket then
        begin
          fPos:=fPos+1;
          var idxKey88:=ParseExpr;
          Expect(tkRBracket);
          // [자기컴파일] 이중 인덱서 대입: fClassMethods[cn][mname]:=isFunc; — CodeGen에는
          // 이미 TExternalDoubleIndexAssignStmtNode 처리가 있었지만 Parser가 만든 적이 없었다.
          if Cur.Kind=tkLBracket then
          begin
            fPos:=fPos+1;
            var idxKey88b:=ParseExpr;
            Expect(tkRBracket);
            Expect(tkAssign);
            var valExpr88b:=ParseExpr;
            Result:=new TExternalDoubleIndexAssignStmtNode(nt.Text, idxKey88, idxKey88b, valExpr88b);
          end
          // [자기컴파일] 인덱싱 결과에 메서드 호출: fClassFields[cn].Add(propName); — 마찬가지로
          // CodeGen엔 TExternalIndexMethodCallStmtNode 처리가 이미 있었지만 Parser가 안 만들었다.
          // [Stage 98+] Entries[vn].ClassName := cn; 처럼 인덱싱 결과 필드 대입도 지원.
          else if Cur.Kind=tkDot then
          begin
            fPos:=fPos+1; // '.' 소비
            var idxMname88:=ExpectMemberName;
            if Cur.Kind=tkAssign then
            begin
              // dict[key].Field := value  →  TExternalIndexFieldAssignStmtNode
              fPos:=fPos+1;
              var idxFieldVal88:=ParseExpr;
              Result:=new TExternalIndexFieldAssignStmtNode(nt.Text, idxKey88, idxMname88, idxFieldVal88);
            end
            else
            begin
              var eimc88:=new TExternalIndexMethodCallStmtNode(nt.Text, idxKey88, idxMname88);
              if Cur.Kind=tkLParen then
              begin
                fPos:=fPos+1;
                if Cur.Kind<>tkRParen then
                begin
                  eimc88.Args.Add(ParseExpr);
                  while Cur.Kind=tkComma do begin fPos:=fPos+1; eimc88.Args.Add(ParseExpr); end;
                end;
                Expect(tkRParen);
              end;
              Result:=eimc88;
            end;
          end
          else
          begin
            Expect(tkAssign);
            var valExpr88:=ParseExpr;
            var setItemCall88:=new TMethodCallStmtNode(nt.Text, 'set_Item');
            setItemCall88.Args.Add(idxKey88);
            setItemCall88.Args.Add(valExpr88);
            Result:=setItemCall88;
          end;
        end

        // [버그 수정] 암시적 self 이벤트 구독 (self. 접두사 없음): 예) Shown += Form_Shown;
        // self.Xxx += Handler; 형태는 아래쪽 tkSelf 분기에서 이미 지원되고 있었지만,
        // self. 를 생략한 형태(Text := ... 처럼 암시적 필드 대입은 되면서 암시적 이벤트
        // 구독만 빠져 있었다)는 처리가 안 되어 있어 tkAssign을 기대하다가 tkPlusAssign을
        // 만나 파싱 에러가 났다.
        else if (fCurClass<>'') and (Cur.Kind=tkPlusAssign) then
        begin
          fPos:=fPos+1;
          if Cur.Kind=tkLParen then // [Stage 64] 람다 핸들러
          begin
            var evsLam4:=new TEventSubscribeStmtNode('', nt.Text, ''); // Qualifier='' → self가 이벤트 소유자
            evsLam4.Lambda:=ParseLambdaExpr;
            Result:=evsLam4;
          end
          else
          begin
            var handlerName4:=Expect(tkIdent).Text;
            Result:=new TEventSubscribeStmtNode('', nt.Text, handlerName4); // Qualifier='' → self가 이벤트 소유자
          end;
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
        // [Stage 87] self.필드.프로퍼티... 3단 이상 체인: self.label1.Location := ...
        // 점이 또 오면 체인을 계속 읽어 Qualifier로 쌓는다.
        if Cur.Kind=tkDot then
        begin
          var selfChain87:=selfMname2;
          while Cur.Kind=tkDot do
          begin
            fPos:=fPos+1;
            var selfNext87:=Expect(tkIdent).Text;
            if Cur.Kind=tkDot then
              selfChain87:=selfChain87+'.'+selfNext87
            else if Cur.Kind=tkAssign then
            begin
              // selfChain87.selfNext87 := rhs
              fPos:=fPos+1; rhs:=ParseExpr;
              var fas87:=new TFieldAssignStmtNode(selfNext87, rhs);
              fas87.Qualifier:=selfChain87;
              Result:=fas87;
              break;
            end
            else if Cur.Kind=tkPlusAssign then
            begin
              fPos:=fPos+1;
              if Cur.Kind=tkLParen then
              begin
                var evs87:=new TEventSubscribeStmtNode(selfChain87, selfNext87, '');
                evs87.Lambda:=ParseLambdaExpr;
                Result:=evs87;
              end
              else
              begin
                var handlerName87:=Expect(tkIdent).Text;
                Result:=new TEventSubscribeStmtNode(selfChain87, selfNext87, handlerName87);
              end;
              break;
            end
            else
            begin
              // selfChain87.selfNext87(args) — 메서드 호출
              mcs:=new TMethodCallStmtNode(selfChain87, selfNext87);
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
              break;
            end;
          end;
        end
        else if Cur.Kind=tkAssign then
        begin
          fPos:=fPos+1; rhs:=ParseExpr;
          Result:=new TFieldAssignStmtNode(selfMname2, rhs); // Qualifier='' → self 필드/속성 대입
        end
        else if Cur.Kind=tkPlusAssign then
        begin
          fPos:=fPos+1;
          if Cur.Kind=tkLParen then // [Stage 64]
          begin
            var evsLam3:=new TEventSubscribeStmtNode('', selfMname2, ''); // Qualifier='' → self가 이벤트 소유자
            evsLam3.Lambda:=ParseLambdaExpr;
            Result:=evsLam3;
          end
          else
          begin
            var handlerName3:=Expect(tkIdent).Text;
            Result:=new TEventSubscribeStmtNode('', selfMname2, handlerName3); // Qualifier='' → self가 이벤트 소유자
          end;
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

      // [Stage 60] repeat 문장들 [;문장들...] until Condition
      else if Cur.Kind=tkRepeat then
      begin
        fPos:=fPos+1; // 'repeat' 소비
        var repNode:=new TRepeatStmtNode;
        ParseStatementsUntilRepeat(repNode.Statements);
        Expect(tkUntil);
        repNode.Condition:=ParseExpr;
        Result:=repNode;
      end

      // [Stage 60] break — 가장 안쪽 루프 탈출
      else if Cur.Kind=tkBreak then
      begin
        fPos:=fPos+1;
        Result:=new TBreakStmtNode;
      end

      // [Stage 60] continue — 가장 안쪽 루프의 다음 반복으로
      else if Cur.Kind=tkContinue then
      begin
        fPos:=fPos+1;
        Result:=new TContinueStmtNode;
      end

      // [Stage 78] exit — 현재 프로시저/함수/메서드/생성자를 즉시 빠져나감.
      // 예전에는 'exit'가 그냥 식별자(tkIdent)로 렉싱되어 "인자 없는 메서드 호출"
      // 문장으로 파싱됐고, self가 외부 타입(예: System.Windows.Forms.Form)을 상속한
      // 메서드 안에서는 CodeGen이 그 외부 타입 위에서 "exit"라는 메서드를 찾다가 실패했다.
      // 이제 전용 키워드 토큰(tkExit)으로 렉싱되므로 여기서 바로 처리한다.
      else if Cur.Kind=tkExit then
      begin
        fPos:=fPos+1;
        Result:=new TExitStmtNode;
      end

      // [Stage 69] yield <식>; — sequence of T 함수 안에서만 유효(위반 시 CodeGen이 오류를 냄).
      else if Cur.Kind=tkYield then
      begin
        fPos:=fPos+1;
        var yieldExpr:=ParseExpr;
        Result:=new TYieldStmtNode(yieldExpr);
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
        // [Stage 101] "for var i:=..." / "foreach var x in ..." — 카운터/순회 변수를 for문
        // 자리에서 바로 선언하는 C# 스타일. 이 컴파일러는 var를 반드시 함수 맨 앞 var 섹션에서만
        // 선언하게 되어 있으므로, 여기서는 "var" 토큰만 소비하고 이름을 fCurParams(지역 이름으로
        // 인식되는 목록)에 즉시 등록해 이후 문장에서 참조 가능하게 만든다 — 실제 지역변수 목록에
        // 추가하는 것과 동일한 효과를 낸다(타입은 for/foreach 자체가 정하므로 별도 TVarDecl은 불필요).
        if Cur.Kind=tkVar then fPos:=fPos+1;
        var vn:=Expect(tkIdent).Text;
        if not fCurParams.Contains(vn) then fCurParams.Add(vn);
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
            while Cur.Kind=tkDot do begin fPos:=fPos+1; tryNode.ExTypeName:=tryNode.ExTypeName+'.'+ExpectQualNamePart; end;
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
            // [Stage 100 버그 수정] "var fullName: string" 같은 참조(by-ref) 매개변수 수식자를
            // 이 시그니처 파서가 전혀 몰랐다 — AST(TMethodSignature.ParamIsByRef)와 CodeGen은
            // 이미 Stage 100에서 ByRef 매개변수를 완전히 지원하도록 준비돼 있었는데, 정작
            // Parser가 'var'/'const' 수식자를 매개변수 이름 자리로 착각해 "예상 tkIdent 실제
            // tkVar" 오류로 이어졌었다. 이름 목록 앞의 var/const를 소비해 참조 여부로 기록한다.
            var pByRef:=(Cur.Kind=tkVar) or (Cur.Kind=tkConst);
            if pByRef then fPos:=fPos+1;
            var pn:=Expect(tkIdent).Text; pnames.Add(pn);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; pnames.Add(Expect(tkIdent).Text); end;
            Expect(tkColon);
            var pIsExt:=false; var pCn:='';
            pt:=ParseParamTypeExt(pIsExt, pCn);
            foreach var pnm in pnames do
            begin
              sig.ParamNames.Add(pnm); sig.ParamTypes.Add(pt);
              sig.ParamClassNames.Add(pCn); sig.ParamIsExternal.Add(pIsExt);
              sig.ParamIsByRef.Add(pByRef); // [Stage 100 버그 수정]
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
        // [버그 수정] 반환 타입이 로컬 클래스/외부 타입(vtObject)이면 이름을 보존해야
        // CodeGen이 정확한 CLR 반환 타입을 만들 수 있다 (TFuncDeclNode.ReturnClassName과 동일한 이유).
        if (sig.ReturnType=vtObject) or (sig.ReturnType=vtObjArray) or (sig.ReturnType=vtMatrix) then sig.ReturnClassName:=fLastGenericName;
      end;
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
          fEnumSize[cn]:=edecl.Members.Count; // [Stage 63]
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

        // ---- [Stage 62] 레코드 선언: TPoint = record X, Y: integer; end; ----
        // 값 타입 의미론(대입 시 복사)이 필요해서 클래스와 구조는 비슷해도 CodeGen에서
        // System.ValueType을 상속하는 별도 타입으로 빌드한다. 이번 단계는 필드만 지원한다
        // (메서드/생성자/상속/제네릭은 지원하지 않음 — 필요해지면 별도 스테이지로).
        else if Cur.Kind=tkRecord then
        begin
          if genParamNames.Count>0 then
            raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 레코드는 제네릭 타입 매개변수를 지원하지 않습니다 (Stage 62)');
          fPos:=fPos+1; // 'record' 소비
          var rdecl:=new TRecordDeclNode(cn);
          while Cur.Kind<>tkEnd do
          begin
            var rfnames:=new List<string>;
            rfnames.Add(Expect(tkIdent).Text);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; rfnames.Add(Expect(tkIdent).Text); end;
            Expect(tkColon);
            var rfIsExt:=false; var rfCn:='';
            var rfType:=ParseParamTypeExt(rfIsExt, rfCn);
            // [Stage 62] 필드 타입 제한: 기본 타입/열거형/외부 .NET 타입만 허용.
            // 지역 클래스·인터페이스·다른 레코드는 CodeGen의 타입 빌드 순서(레코드가 클래스보다
            // 먼저 완성됨) 때문에 지금은 지원하지 않는다 — 여기서 명확한 오류로 막는다.
            if ((rfType=vtObject) and (not rfIsExt)) or (rfType=vtInterface)
               or (rfType=vtGeneric) or (rfType=vtGenericArray) then
              raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
                +': 레코드 필드 "'+rfnames[rfnames.Count-1]+'"는 기본 타입/열거형/외부 .NET 타입만 지원합니다 '
                +'(지역 클래스·인터페이스·다른 레코드를 필드로 담는 것은 아직 지원하지 않음, Stage 62)');
            Expect(tkSemicolon);
            foreach var rfn in rfnames do
            begin
              var rfld:=new TFieldDeclNode(rfn, rfType);
              rfld.ClassName:=rfCn; rfld.IsExternalType:=rfIsExt;
              rdecl.Fields.Add(rfld);
            end;
          end;
          Expect(tkEnd); Expect(tkSemicolon);
          fRecordNames.Add(cn);
          fClassNames.Add(cn); // [Stage 62] var/필드/매개변수 타입 인식 경로를 클래스와 공유
          aProg.RecordDecls.Add(rdecl);
        end

        // ---- 클래스 선언 ----
        else
        begin
          Expect(tkClass);
          // [버그 수정] 전방 선언(forward declaration): "TName = class;" — 본문 없이 세미콜론만
          // 오는 경우. 서로를 참조하는 두 클래스(예: AST.pas의 TFuncDeclNode.NestedProcs:
          // List<TProcDeclNode>가 TProcDeclNode의 실제 정의보다 먼저 나옴)를 다루는 Delphi식
          // 관용구다. 실제 본문("TName = class(...) ... end;")은 파일 뒤쪽에 같은 이름으로 다시
          // 나온다. 여기서는 이름만 미리 fClassNames 등에 등록해 다른 타입이 필드/매개변수
          // 타입으로 이 이름을 앞서 참조할 수 있게만 해주고, aProg.ClassDecls에는 아무것도
          // 추가하지 않는다 — 실제 클래스 선언은 뒤에서 다시 이 while 루프를 돌 때 정상적으로
          // 채워진다.
          if Cur.Kind=tkSemicolon then
          begin
            fPos:=fPos+1; // ';' 소비
            if not fClassNames.Contains(cn) then fClassNames.Add(cn);
            if not fClassFields.ContainsKey(cn) then fClassFields[cn]:=new List<string>;
            if not fClassMethods.ContainsKey(cn) then fClassMethods[cn]:=new Dictionary<string, boolean>;
            continue;
          end;
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
              pname:=pname+'.'+ExpectQualNamePart;
            end;
            if fRecordNames.Contains(pname) then // [Stage 62]
              raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 레코드 "'+pname+'"는 상속할 수 없습니다 (값 타입)')
            else if fClassNames.Contains(pname) then
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

          // [Stage 102] 본문을 파싱하기 전에 이 클래스의 모든 메서드 이름을 미리 등록 —
          // 위쪽 메서드가 아래쪽에 선언된 무인자 메서드를 괄호 없이 호출하는 순방향 참조를 지원한다.
          PreRegisterClassMethodNames(cn);

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
            // private / public / internal 키워드는 건너뜀 [Stage 88c: internal 추가]
            if (Cur.Kind=tkPrivate) or (Cur.Kind=tkPublic) or (Cur.Kind=tkInternal) then
            begin
              fPos:=fPos+1;
            end

            // [Stage 42] 생성자 시그니처: constructor Create;
            // [Stage 47] 매개변수 있는 생성자도 지원 (procedure/function 시그니처 파싱과 동일한 패턴)
            // [Stage 89] 실제 레포(uTest.pas)는 이름 없이 그냥 "constructor;"라고만 쓰고 바로
            // "begin...end;"로 본문을 붙인다 — 이름 생략은 "Create"의 축약형(디자이너가 뽑는
            // 흔한 표기), 본문은 procedure/function과 마찬가지로 클래스 선언 "안"에 인라인으로 온다.
            else if Cur.Kind=tkConstructor then
            begin
              fPos:=fPos+1;
              var ctorName:='Create';
              if Cur.Kind=tkIdent then
              begin
                ctorName:=Cur.Text; fPos:=fPos+1;
                if ctorName<>'Create' then
                  raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
                    +': 생성자 이름은 "Create"만 지원합니다 (Stage 42)');
              end;
              // [Stage 99] 이 생성자 하나의 파라미터만 담는 로컬 리스트.
              // cd.ConstructorParams에 누적하던 예전 방식은 오버로드 시 여러 생성자의
              // 파라미터가 뒤섞이는 문제가 있었다. CodeGen(Stage 99~)은 이미
              // TConstructorImplNode.Parameters만 보므로, 여기서도 impl 단위로 분리한다.
              var thisCtorParams:=new List<TParamDef>;
              if Cur.Kind=tkLParen then
              begin
                fPos:=fPos+1;
                if Cur.Kind<>tkRParen then
                begin
                  var ctorPNames:=new List<string>;
                  while true do
                  begin
                    // [Stage 100 버그 수정] 생성자 매개변수도 var/const 참조 수식자를 몰랐다.
                    var ctorByRef:=(Cur.Kind=tkVar) or (Cur.Kind=tkConst);
                    if ctorByRef then fPos:=fPos+1;
                    ctorPNames.Add(Expect(tkIdent).Text);
                    while Cur.Kind=tkComma do begin fPos:=fPos+1; ctorPNames.Add(Expect(tkIdent).Text); end;
                    Expect(tkColon);
                    var ctorPIsExt:=false; var ctorPCn:='';
                    var ctorPt:=ParseParamTypeExt(ctorPIsExt, ctorPCn);
                    foreach var ctorPn in ctorPNames do
                    begin
                      var ctorPd1:=new TParamDef(ctorPn, ctorPt, ctorPCn, ctorPIsExt); ctorPd1.IsByRef:=ctorByRef;
                      var ctorPd2:=new TParamDef(ctorPn, ctorPt, ctorPCn, ctorPIsExt); ctorPd2.IsByRef:=ctorByRef;
                      thisCtorParams.Add(ctorPd1);
                      cd.ConstructorParams.Add(ctorPd2);
                    end;
                    ctorPNames.Clear;
                    if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
                  end;
                end;
                Expect(tkRParen);
              end;
              Expect(tkSemicolon);
              // [Stage 99] "overload;" 지시자 소비 — overload는 예약어가 아니라 tkIdent로
              // 토큰화되므로 텍스트로 비교한다. 여러 번 나와도 허용(방어적으로 while).
              while (Cur.Kind=tkIdent) and (Cur.Text.ToLower='overload') do
              begin
                fPos:=fPos+1; // 'overload' 소비
                Expect(tkSemicolon);
              end;
              cd.HasUserConstructor:=true;

              // [Stage 89] "constructor; begin ... end;" — {$include}로 끌려온 procedure와
              // 완전히 같은 이유(시그니처를 끝맺는 ';'을 소비한 "다음"에 tkBegin을 검사)로 처리한다.
              // [버그 수정] "constructor; var x: integer; begin ... end;"처럼 begin 앞에 지역
              // var/const 섹션이 먼저 오는 경우, 예전에는 Cur.Kind=tkBegin만 확인해서 이 분기에
              // 아예 못 들어오고, var/const 토큰이 클래스 멤버 목록으로 잘못 넘어가 "클래스 선언
              // 안에서 알 수 없는 토큰 var" 오류로 이어졌다. 이 분기 안쪽은 이미 var/const를
              // 처리하므로(ParseLocalDeclSections 호출), 진입 조건만 넓히면 된다.
              if (Cur.Kind=tkBegin) or (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then
              begin
                var cimpl89:=new TConstructorImplNode(cn);
                // [Stage 99] cd.ConstructorParams 전체 대신 이 생성자의 파라미터만 복사
                foreach var cp89 in thisCtorParams do cimpl89.Parameters.Add(cp89);

                var savedClass89:=fCurClass; var savedFunc89:=fCurFunc;
                var savedParams89:=fCurParams; var savedMethodParamNames89:=fCurMethodParamNames;
                fCurClass:=cn; fCurFunc:='Create';
                fCurParams:=new List<string>;
                foreach var cpn89 in cimpl89.Parameters do fCurParams.Add(cpn89.Name);
                fCurMethodParamNames:=new List<string>;
                foreach var cpn89b in cimpl89.Parameters do fCurMethodParamNames.Add(cpn89b.Name);

                if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then
                begin
                  ParseLocalDeclSections(cimpl89.LocalVars, cimpl89.ConstDecls);
                  foreach var lvcp89 in cimpl89.LocalVars do fCurParams.Add(lvcp89.Name);
                  foreach var lccp89 in cimpl89.ConstDecls do fCurParams.Add(lccp89.Name);
                end;

                Expect(tkBegin);
                var cimplComp89:=new TCompoundStmtNode;
                ParseStatementsUntilEnd(cimplComp89.Statements); // [Stage 58] panic-mode 오류 복구
                Expect(tkEnd); Expect(tkSemicolon);
                cimpl89.Body:=cimplComp89;
                fProg.ConstructorImpls.Add(cimpl89);

                fCurClass:=savedClass89; fCurFunc:=savedFunc89;
                fCurParams:=savedParams89; fCurMethodParamNames:=savedMethodParamNames89;
              end;
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
              // [자기컴파일 버그 수정] property 지시자: override;/virtual;/abstract; — 외부
              // 추상 타입(예: System.Reflection.PropertyInfo)을 상속해 그 추상 프로퍼티를
              // 오버라이드할 때 쓰인다(CodeGen.pas의 TBoundGenericPropertyInfo 실제 사례).
              // 메서드 지시자(위 3663번째 줄 근처)와 동일한 문법 — 순서·조합 무관, 지시자마다
              // 세미콜론이 따라온다. CodeGen이 만드는 getter/setter는 이미 항상
              // MethodAttributes.Virtual로 정의되므로(Stage 85) 파서 단계에서는 구문만 허용하고
              // 소비하면 된다 — 이름·시그니처가 일치하는 상속 가상/추상 멤버가 있으면 CLR이
              // 기본 슬롯 재사용 규칙으로 알아서 오버라이드로 연결한다.
              while (Cur.Kind=tkVirtual) or (Cur.Kind=tkOverride) or (Cur.Kind=tkAbstract) do
              begin
                fPos:=fPos+1;
                Expect(tkSemicolon);
              end;
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

              // [Stage 74] 메서드 자신의 제네릭 타입 매개변수: function Wrap<T>(x: T): T;
              // 클래스 자체의 제네릭(TStack<T>)과는 독립적 — 이 클래스가 제네릭이 아니어도 된다.
              var savedGP74sig:=fCurGenericParams;
              var mGenNames74, mGenConstraints74: List<string>;
              ParseCallableGenericParams(mGenNames74, mGenConstraints74);
              if mGenNames74.Count>0 then
              begin
                sig.IsGeneric:=true; sig.GenericParamNames:=mGenNames74; sig.GenericParamConstraints:=mGenConstraints74;
                // 매개변수/반환 타입 파싱 동안 T 등을 vtGeneric으로 인식시킨다. 클래스 자체가
                // 이미 제네릭이면(fCurGenericParams가 그 T들로 설정돼 있으면) 메서드 자신의
                // 타입 매개변수를 덧붙인다 — 이름이 겹치면 메서드 쪽이 가려버릴 수 있으므로
                // 겹치지 않게 쓰는 것을 권장(1차 제약, 별도 검증은 하지 않음).
                var combinedGP74:=new List<string>;
                foreach var g74 in fCurGenericParams do combinedGP74.Add(g74);
                foreach var g74b in mGenNames74 do combinedGP74.Add(g74b);
                fCurGenericParams:=combinedGP74;
              end;

              if Cur.Kind=tkLParen then
              begin
                fPos:=fPos+1;
                if Cur.Kind<>tkRParen then
                begin
                  while true do
                  begin
                    // [Stage 100 버그 수정] 인라인(88c) 클래스 메서드 시그니처도 마찬가지로
                    // var/const 참조 매개변수 수식자를 몰랐다 (예: Parser.pas 자신의
                    // "function TryResolveExternalTypeByUses(name: string; var fullName: string): boolean;").
                    var pByRef2:=(Cur.Kind=tkVar) or (Cur.Kind=tkConst);
                    if pByRef2 then fPos:=fPos+1;
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
                      sig.ParamIsByRef.Add(pByRef2); // [Stage 100 버그 수정]
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
                // [버그 수정] 반환 타입이 로컬 클래스/외부 타입(vtObject)이면 이름을 보존한다.
                // 이게 없으면 CodeGen의 DefineMethod가 VTC(vtObject,'')로 떨어져 메서드의 실제
                // CLR 반환 타입이 System.Object가 되고(예: function Cur: TToken;), 그 반환값에
                // 체인 접근(Cur.Kind 등)할 때 "타입 System.Object에 메서드 X가 없습니다"로 실패한다.
                if (sig.ReturnType=vtObject) or (sig.ReturnType=vtObjArray) or (sig.ReturnType=vtMatrix) then sig.ReturnClassName:=fLastGenericName;
              end;
              fCurGenericParams:=savedGP74sig; // [Stage 74]

              // [Stage 88c] {$include uTest.Form1.inc} 같은 지시문이 클래스 선언 "내부"에서
              // 전개되면, 시그니처(세미콜론까지 포함해서 "procedure Name;")뒤에 곧바로
              // 본문(begin...end)이 온다 — 디자이너가 만드는 InitializeComponent가 대표적인 예.
              // [버그 수정] 처음 구현에서는 세미콜론을 소비하기 "전"에 Cur.Kind=tkBegin을
              // 검사했는데, 실제 문법은 "procedure InitializeIt; begin ... end;"처럼 시그니처와
              // begin 사이에 세미콜론이 항상 있으므로 그 시점의 Cur는 절대 tkBegin이 될 수 없었다
              // (항상 else 쪽의 "시그니처만" 경로로 빠졌다 — 그 뒤 "begin"이 클래스 멤버로
              // 잘못 해석되어 파싱 전체가 어긋났다). 세미콜론을 먼저 소비한 "다음"에 검사하도록 고쳤다.
              // 여기서는 시그니처를 평소대로 cd.Methods에 등록해 CodeGen의 시그니처 정의
              // 단계를 그대로 재사용하고, 본문은 ParseMethodImpl과 같은 방식으로 바로 파싱해
              // fProg.MethodImpls에 (마치 별도 구현부에 있던 것처럼) 담아둔다.
              // [버그 수정] "function ReadIdent: TToken; var sl,sc: integer; ...; begin ... end;"처럼
              // begin 앞에 지역 var/const 섹션이 먼저 오는 경우(Lexer.pas 실제 사례), 예전에는
              // Cur.Kind=tkBegin만 확인해서 이 분기에 못 들어오고 시그니처만 등록한 채 끝나버렸다
              // — 그 뒤 var/const 토큰이 클래스 멤버로 잘못 해석되어 "클래스 선언 안에서 알 수
              // 없는 토큰 var" 오류로 이어졌다. 이 분기 안쪽은 이미 var/const를 처리하므로
              // (아래 ParseLocalDeclSections 호출), 진입 조건만 넓히면 된다.
              Expect(tkSemicolon);
              if (Cur.Kind=tkBegin) or (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then
              begin
                cd.Methods.Add(sig);
                fClassMethods[cn][mname]:=isFunc;
                if sig.IsGeneric then
                begin
                  if not fGenericMethodNames.Contains(mname) then fGenericMethodNames.Add(mname);
                  fMethodGenericParam[mname]:=sig.GenericParamNames;
                  fMethodGenericConstraint[mname]:=sig.GenericParamConstraints;
                end;

                var inlImpl:=new TMethodImplNode(cn, mname, isFunc, sig.ReturnType);
                inlImpl.ReturnGenericName:=sig.ReturnGenericName;
                inlImpl.ReturnClassName:=sig.ReturnClassName; // [버그 수정] BuildMethodBody의 Result 지역변수 타입 정확화
                inlImpl.ParamNames.AddRange(sig.ParamNames);
                inlImpl.ParamTypes.AddRange(sig.ParamTypes);
                for var pgi88c:=0 to sig.ParamTypes.Count-1 do
                begin
                  if (sig.ParamTypes[pgi88c]=vtGeneric) or (sig.ParamTypes[pgi88c]=vtGenericArray) then
                    inlImpl.ParamGenericNames.Add(sig.ParamClassNames[pgi88c])
                  else
                    inlImpl.ParamGenericNames.Add('');
                  if (sig.ParamTypes[pgi88c]=vtIntArray) or (sig.ParamTypes[pgi88c]=vtStrArray) or (sig.ParamTypes[pgi88c]=vtGenericArray) or (sig.ParamTypes[pgi88c]=vtObjArray) then
                    if not fArrayNames.Contains(sig.ParamNames[pgi88c]) then fArrayNames.Add(sig.ParamNames[pgi88c]);
                  // [Stage 98] List<T>/Dictionary<K,V> 등 인덱서를 갖는 외부 제네릭 컬렉션 매개변수.
                  if sig.ParamIsExternal[pgi88c] and IsIndexerCapableExternalType(sig.ParamClassNames[pgi88c]) then
                    if not fArrayNames.Contains(sig.ParamNames[pgi88c]) then fArrayNames.Add(sig.ParamNames[pgi88c]);
                end;

                var savedClass88c:=fCurClass; var savedFunc88c:=fCurFunc;
                var savedParams88c:=fCurParams; var savedMethodParamNames88c:=fCurMethodParamNames;
                fCurClass:=cn; fCurFunc:=mname;
                fCurParams:=new List<string>;
                foreach var pnCp88c in inlImpl.ParamNames do fCurParams.Add(pnCp88c);
                fCurMethodParamNames:=new List<string>;
                foreach var pnCp88c2 in inlImpl.ParamNames do fCurMethodParamNames.Add(pnCp88c2);

                if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then
                begin
                  ParseLocalDeclSections(inlImpl.LocalVars, inlImpl.ConstDecls);
                  foreach var lvcp88c in inlImpl.LocalVars do fCurParams.Add(lvcp88c.Name);
                  foreach var lccp88c in inlImpl.ConstDecls do fCurParams.Add(lccp88c.Name);
                end;

                Expect(tkBegin);
                var inlComp:=new TCompoundStmtNode;
                ParseStatementsUntilEnd(inlComp.Statements); // [Stage 58] panic-mode 오류 복구
                Expect(tkEnd); Expect(tkSemicolon);
                inlImpl.Body:=inlComp;
                fProg.MethodImpls.Add(inlImpl);

                fCurClass:=savedClass88c; fCurFunc:=savedFunc88c;
                fCurParams:=savedParams88c; fCurMethodParamNames:=savedMethodParamNames88c;
              end
              else
              begin
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
              // [Stage 74] 1차 제약: 제네릭 메서드는 virtual/override/abstract와 조합하지 않는다
              // (CLR 제네릭 가상 메서드의 override 슬롯 매칭까지는 아직 다루지 않음).
              if sig.IsGeneric and (sig.IsVirtual or sig.IsOverride or sig.IsAbstract) then
                raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString+': 제네릭 메서드 "'+mname
                  +'"는 virtual/override/abstract와 함께 쓸 수 없습니다 (Stage 74, 1차 제약)');
              cd.Methods.Add(sig);
              fClassMethods[cn][mname]:=isFunc;
              if sig.IsGeneric then
              begin
                if not fGenericMethodNames.Contains(mname) then fGenericMethodNames.Add(mname);
                fMethodGenericParam[mname]:=sig.GenericParamNames;
                fMethodGenericConstraint[mname]:=sig.GenericParamConstraints;
              end;
              // [자기컴파일 버그 수정] virtual;/override;/abstract; 지시자 "다음"에도
              // [Stage 88c]처럼 곧바로 본문(begin...end;)이 올 수 있다 — 예:
              // "function GetAccessors(nonPublic: boolean): array of MethodInfo; override;
              //  begin ... end;" (CodeGen.pas의 TBoundGenericPropertyInfo 실제 사례).
              // 위 [Stage 88c] 분기는 지시자가 오기 "전"에 tkBegin인지만 확인해서, 지시자가
              // 하나라도 있으면 이 경로(else)로 빠지고 그 뒤엔 본문 검사가 아예 없어 시그니처만
              // 등록한 채 끝나버렸다 — 그 결과 뒤따르는 "begin"이 클래스 멤버로 잘못 해석되어
              // "클래스 선언 안에서 알 수 없는 토큰 begin" 오류로 이어졌다. abstract 메서드는
              // 원래 본문이 없어야 하므로(위 fAbstractMethods 표시), 이 분기는 사실상
              // virtual/override 뒤에 본문이 오는 경우를 위한 것이다.
              if (Cur.Kind=tkBegin) or (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then
              begin
                var inlImplMod:=new TMethodImplNode(cn, mname, isFunc, sig.ReturnType);
                inlImplMod.ReturnGenericName:=sig.ReturnGenericName;
                inlImplMod.ReturnClassName:=sig.ReturnClassName;
                inlImplMod.ParamNames.AddRange(sig.ParamNames);
                inlImplMod.ParamTypes.AddRange(sig.ParamTypes);
                for var pgiMod:=0 to sig.ParamTypes.Count-1 do
                begin
                  if (sig.ParamTypes[pgiMod]=vtGeneric) or (sig.ParamTypes[pgiMod]=vtGenericArray) then
                    inlImplMod.ParamGenericNames.Add(sig.ParamClassNames[pgiMod])
                  else
                    inlImplMod.ParamGenericNames.Add('');
                  if (sig.ParamTypes[pgiMod]=vtIntArray) or (sig.ParamTypes[pgiMod]=vtStrArray) or (sig.ParamTypes[pgiMod]=vtGenericArray) or (sig.ParamTypes[pgiMod]=vtObjArray) then
                    if not fArrayNames.Contains(sig.ParamNames[pgiMod]) then fArrayNames.Add(sig.ParamNames[pgiMod]);
                  if sig.ParamIsExternal[pgiMod] and IsIndexerCapableExternalType(sig.ParamClassNames[pgiMod]) then
                    if not fArrayNames.Contains(sig.ParamNames[pgiMod]) then fArrayNames.Add(sig.ParamNames[pgiMod]);
                end;

                var savedClassMod:=fCurClass; var savedFuncMod:=fCurFunc;
                var savedParamsMod:=fCurParams; var savedMethodParamNamesMod:=fCurMethodParamNames;
                fCurClass:=cn; fCurFunc:=mname;
                fCurParams:=new List<string>;
                foreach var pnCpMod in inlImplMod.ParamNames do fCurParams.Add(pnCpMod);
                fCurMethodParamNames:=new List<string>;
                foreach var pnCpMod2 in inlImplMod.ParamNames do fCurMethodParamNames.Add(pnCpMod2);

                if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then
                begin
                  ParseLocalDeclSections(inlImplMod.LocalVars, inlImplMod.ConstDecls);
                  foreach var lvcpMod in inlImplMod.LocalVars do fCurParams.Add(lvcpMod.Name);
                  foreach var lccpMod in inlImplMod.ConstDecls do fCurParams.Add(lccpMod.Name);
                end;

                Expect(tkBegin);
                var inlCompMod:=new TCompoundStmtNode;
                ParseStatementsUntilEnd(inlCompMod.Statements); // [Stage 58] panic-mode 오류 복구
                Expect(tkEnd); Expect(tkSemicolon);
                inlImplMod.Body:=inlCompMod;
                fProg.MethodImpls.Add(inlImplMod);

                fCurClass:=savedClassMod; fCurFunc:=savedFuncMod;
                fCurParams:=savedParamsMod; fCurMethodParamNames:=savedMethodParamNamesMod;
              end;
              end;
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
              // [Stage 86] 외부 제네릭 컬렉션 필드: Dictionary<string, FileChangeWatcher> 같은
              // .NET 제네릭 타입 — 로컬 클래스명도 아니고 현재 제네릭 클래스의 타입 매개변수도
              // 아니지만 바로 뒤에 '<'가 오는 경우.
              else if (Cur.Kind=tkIdent) and (PeekAt(1).Kind=tkLt) then
              begin
                var extGenBase:=Cur.Text; fPos:=fPos+1;
                fldCn:=ParseExternalGenericType(extGenBase);
                fldType:=vtObject; fldIsExt:=true;
              end
              else if Cur.Kind=tkIdent then
              begin
                var savedPos2:=fPos;
                var qn:=Expect(tkIdent).Text;
                if Cur.Kind=tkDot then
                begin
                  while Cur.Kind=tkDot do
                  begin fPos:=fPos+1; qn:=qn+'.'+ExpectQualNamePart; end;
                  fldType:=vtObject; fldCn:=qn; fldIsExt:=true;
                end
                else
                begin
                  // [Stage 87] 점 없는 단순 이름 — uses 네임스페이스에서 탐색
                  var _resolved87f:='';
                  foreach var _ns87f in fImportedNamespaces do
                  begin
                    var _full87f:=_ns87f+'.'+qn;
                    try
                      var _t87f:=System.Type.GetType(_full87f);
                      if _t87f=nil then
                        foreach var _asm87f in System.AppDomain.CurrentDomain.GetAssemblies() do
                        begin _t87f:=_asm87f.GetType(_full87f); if _t87f<>nil then break; end;
                      if _t87f<>nil then begin _resolved87f:=_full87f; break; end;
                    except
                    end;
                  end;
                  if _resolved87f<>'' then
                  begin
                    fldType:=vtObject; fldCn:=_resolved87f; fldIsExt:=true;
                  end
                  else
                  begin
                    fPos:=savedPos2;
                    fldType:=ParseVarType;
                    if (fldType=vtGenericArray) or (fldType=vtObject) then
                    begin
                      if fldType=vtObject then begin fldCn:=fLastGenericName; fldIsExt:=(fldCn<>'') and not fClassNames.Contains(fldCn); end
                      else fldCn:=fLastGenericName;
                    end;
                  end;
                end;
              end
              else
              begin
                fldType:=ParseVarType;
                if fldType=vtGenericArray then fldCn:=fLastGenericName;
              end;
              // [Stage 83] 클래스 필드 인라인 기본값 초기화: "Name: type = 식;" 또는 "Name: type := 식;"
              // (실제 PascalABC.net_imitate 소스는 ":=" 표기를 씀 — 예: uRunProcessOptions.pas의
              // "Process: System.Diagnostics.Process := nil;" — 두 표기 모두 허용한다.)
              // 쉼표로 묶인 여러 필드 이름에 동시에 붙이는 것은 의미가 모호하므로
              // (예: "X, Y: integer = 0;"이 두 필드 모두에 적용되는지 불분명) 허용하지 않고
              // 이름이 하나일 때만 허용한다.
              var fldDefaultExpr: TExprNode:=nil;
              if (Cur.Kind=tkEq) or (Cur.Kind=tkAssign) then
              begin
                if fnames.Count<>1 then
                  raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
                    +': 인라인 기본값 초기화는 필드 하나씩만 지원합니다 (예: "'+fnames[0]+': 타입 := 값;")');
                fPos:=fPos+1; // '=' 또는 ':=' 소비
                fldDefaultExpr:=ParseExpr;
              end;
              Expect(tkSemicolon);
              foreach var fn in fnames do
              begin
                var fld:=new TFieldDeclNode(fn, fldType);
                fld.ClassName:=fldCn; fld.IsExternalType:=fldIsExt;
                fld.DefaultValueExpr:=fldDefaultExpr; // [Stage 83]
                cd.Fields.Add(fld);
                fClassFields[cn].Add(fn);
                // [버그 수정] array of T 클래스 필드(예: Lexer.pas의 "fChars: array of char")도
                // 로컬 변수/매개변수와 동일하게 fArrayNames에 등록해야 한다. 이게 없으면
                // 메서드 본문 안에서 "fChars[fPos]" 같은 인덱싱 식이 "fArrayNames.Contains"
                // 검사를 통과 못해 식 파싱이 중간에 멈추고, 남은 "["가 "알 수 없는 문장"
                // 오류로 이어졌다.
                if (fldType=vtIntArray) or (fldType=vtStrArray) or (fldType=vtGenericArray) or (fldType=vtObjArray) then
                begin
                  if not fArrayNames.Contains(fn) then fArrayNames.Add(fn);
                end;
                if fldType=vtMatrix then
                begin
                  if not fArrayNames.Contains(fn) then fArrayNames.Add(fn);
                  if not fMatrixNames.Contains(fn) then fMatrixNames.Add(fn); // [Stage 101]
                end;
                // [Stage 98] List<T>/Dictionary<K,V> 등 인덱서를 갖는 외부 제네릭 컬렉션 필드.
                if fldIsExt and IsIndexerCapableExternalType(fldCn) then
                begin
                  if not fArrayNames.Contains(fn) then fArrayNames.Add(fn);
                end;
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
            // [버그 수정] 예전 정지 토큰 집합(tkSemicolon/tkVar/tkConst/tkFunction/tkProcedure/
            // tkConstructor/tkBegin/tkEOF)에는 tkEnd와 tkImplementation이 빠져 있었다. 그 결과
            // 깨진 타입 선언 하나를 복구하려고 건너뛰는 도중에 타입 섹션(또는 유닛)을 닫는
            // 진짜 'end;'/'implementation'을 그냥 지나쳐버릴 수 있었고, 그러면 이후 파서 상태가
            // 완전히 어긋나 버려(예: "예상 tkImplementation 실제 tkEnd" 같은 전혀 다른 곳에서
            // 엉뚱한 오류가 남) 정작 원인이 된 진짜 오류 메시지는 ParseErrors 안에 묻혀버렸다.
            // tkEnd/tkImplementation/tkType을 정지 토큰에 추가해, 건너뛰기가 반드시 "다음 타입
            // 선언 시작 전" 또는 "타입 섹션이 끝나는 경계"에서 멈추도록 한다. 이 세 토큰은
            // 여기서 소비하지 않고 그대로 남겨 바깥 로직이 정상적으로 처리하게 둔다.
            while (Cur.Kind<>tkSemicolon) and (Cur.Kind<>tkVar) and (Cur.Kind<>tkConst) and (Cur.Kind<>tkFunction)
              and (Cur.Kind<>tkProcedure) and (Cur.Kind<>tkConstructor) and (Cur.Kind<>tkBegin)
              and (Cur.Kind<>tkEnd) and (Cur.Kind<>tkImplementation) and (Cur.Kind<>tkType)
              and (Cur.Kind<>tkEOF) do
              fPos:=fPos+1;
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end;
        end;
      end;
    end;

    // [Stage 28] 함수/프로시저/메서드 본문 안의 지역 변수 선언(var 섹션)을 파싱한다.
    // 최상위 var 섹션(ParseVarSection)과 로직은 같다.
    // [Stage 65] 지역(중첩) 함수/프로시저 선언은 var/const 섹션 "다음"에만 올 수 있으므로
    // (1차 제약 — 임의로 섞어 쓸 수 없음), tkFunction/tkProcedure를 만나도 여기서 끝낸다.
    procedure ParseLocalVarSection(aList: List<TVarDecl>);
    var vt: TVarType; ns: List<string>; cn: string; isExt: boolean;
    begin
      Expect(tkVar);
      while (Cur.Kind<>tkBegin) and (Cur.Kind<>tkConst)
        and (Cur.Kind<>tkFunction) and (Cur.Kind<>tkProcedure) and (Cur.Kind<>tkVar) do // [Stage 61] const 섹션과 교차 가능, [Stage 65] 지역 서브프로그램 앞에서 정지, [Stage 67] 연속된 var 섹션도 정지
      begin
        ns:=new List<string>; ns.Add(Expect(tkIdent).Text);
        while Cur.Kind=tkComma do begin fPos:=fPos+1; ns.Add(Expect(tkIdent).Text); end;
        Expect(tkColon);
        // [Stage 41] 기존에는 여기서 클래스/인터페이스/기본타입만 직접 처리하고 점(.)으로 연결된
        // 외부 .NET 타입(예: var sb: System.Text.StringBuilder;)은 지원하지 않았다. 매개변수/필드에서
        // 이미 쓰던 ParseParamTypeExt(지역클래스/인터페이스/외부타입/제네릭 모두 처리)로 통일한다.
        vt:=ParseParamTypeExt(isExt, cn);
        if (vt=vtGeneric) or (vt=vtGenericArray) then cn:=fLastGenericName; // [Stage 36/37] 제네릭 지역변수(예: var temp: T; var arr: array of T;)의 타입 매개변수 이름 보존
        if vt=vtMatrix then cn:=fLastGenericName; // [Stage 67] 2차원 배열 원소 타입 이름 보존
        Expect(tkSemicolon);
        foreach var nm in ns do
        begin
          aList.Add(new TVarDecl(nm, vt, cn, isExt));
          if (vt=vtIntArray) or (vt=vtStrArray) or (vt=vtGenericArray) or (vt=vtObjArray) then fArrayNames.Add(nm); // [Stage 37/90]
          if vt=vtMatrix then begin if not fArrayNames.Contains(nm) then fArrayNames.Add(nm); if not fMatrixNames.Contains(nm) then fMatrixNames.Add(nm); end; // [Stage 67/101]
          if isExt and IsIndexerCapableExternalType(cn) then // [Stage 98] List<T>/Dictionary<K,V> 지역변수 인덱싱 지원
            begin if not fArrayNames.Contains(nm) then fArrayNames.Add(nm); end;
        end;
      end;
    end;

    // [Stage 61] 함수/프로시저/메서드/생성자 본문 안의 지역 const 선언(const 섹션)을 파싱한다.
    // "const Name = 식;" 은 식으로부터 타입을 추론하고, "const Name: Type = 식;" 은 명시된 타입을 쓴다.
    // var 섹션과 마찬가지로 tkBegin 또는 (교차하는) tkVar를 만나면 끝난다.
    // [Stage 65] tkFunction/tkProcedure를 만나도 끝낸다 — 지역 서브프로그램은 var/const 다음.
    procedure ParseLocalConstSection(aList: List<TConstDecl>);
    var vt: TVarType; nm: string; cn: string; isExt: boolean; ve: TExprNode; hasType: boolean;
    begin
      Expect(tkConst);
      while (Cur.Kind<>tkBegin) and (Cur.Kind<>tkVar)
        and (Cur.Kind<>tkFunction) and (Cur.Kind<>tkProcedure) do
      begin
        nm:=Expect(tkIdent).Text;
        hasType:=false; cn:=''; isExt:=false; vt:=vtInteger;
        if Cur.Kind=tkColon then
        begin
          fPos:=fPos+1;
          vt:=ParseParamTypeExt(isExt, cn);
          hasType:=true;
        end;
        Expect(tkEq);
        ve:=ParseExpr;
        Expect(tkSemicolon);
        if hasType then aList.Add(new TConstDecl(nm, vt, cn, isExt, ve))
        else aList.Add(new TConstDecl(nm, ve));
      end;
    end;

    // [Stage 61] var/const 섹션은 순서에 상관없이 여러 번 번갈아 나올 수 있다
    // (예: const ... var ... const ...). tkBegin을 만날 때까지 번갈아 파싱한다.
    procedure ParseLocalDeclSections(aVarList: List<TVarDecl>; aConstList: List<TConstDecl>);
    begin
      while (Cur.Kind=tkVar) or (Cur.Kind=tkConst) do
      begin
        if Cur.Kind=tkVar then ParseLocalVarSection(aVarList)
        else ParseLocalConstSection(aConstList);
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

      // [Stage 74] 메서드 자신이 제네릭이면(선언부와 동일하게) 구현부에도 <T>를 다시 적어야 한다.
      if Cur.Kind=tkLt then
      begin
        var implGenNames74, implGenConstraints74: List<string>;
        ParseCallableGenericParams(implGenNames74, implGenConstraints74);
        impl.IsGeneric:=true;
        impl.GenericParamNames:=implGenNames74;
        impl.GenericParamConstraints:=implGenConstraints74;
      end;

      // 제네릭 클래스(TStack<T>, [Stage 32] TPair<K,V> 등)의 메서드 구현이면, 본문의 매개변수/반환
      // 타입에서 T/K/V 등을 인식할 수 있도록 fCurGenericParams를 설정해 둔다.
      // [Stage 74] 메서드 자신의 제네릭 타입 매개변수도 (클래스 제네릭과 함께, 또는 단독으로) 더한다.
      var savedGP3:=fCurGenericParams;
      fCurGenericParams:=new List<string>;
      if fClassGenericParam.ContainsKey(cn) then
        foreach var gp74c in fClassGenericParam[cn] do fCurGenericParams.Add(gp74c);
      if impl.IsGeneric then
        foreach var gp74m in impl.GenericParamNames do fCurGenericParams.Add(gp74m);

      // 매개변수
      if Cur.Kind=tkLParen then
      begin
        fPos:=fPos+1;
        if Cur.Kind<>tkRParen then
        begin
          while true do
          begin
            var pBatch:=new List<string>;
            // [Stage 100 버그 수정] 구현부(procedure/function TClass.Method(...))의 매개변수
            // 목록도 시그니처와 마찬가지로 var/const 참조 수식자를 몰랐다.
            var pByRef3:=(Cur.Kind=tkVar) or (Cur.Kind=tkConst);
            if pByRef3 then fPos:=fPos+1;
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
              impl.ParamIsByRef.Add(pByRef3); // [Stage 100 버그 수정]
            end;
            // [Stage 28] array of integer/string 매개변수를 본문에서 a[i]로 인덱싱할 수
            // 있으려면 fArrayNames에 등록되어야 한다(별개 버그, 함께 수정).
            if (pt=vtIntArray) or (pt=vtStrArray) or (pt=vtGenericArray) or (pt=vtObjArray) then // [Stage 37/90]
              foreach var pbn in pBatch do
                if not fArrayNames.Contains(pbn) then fArrayNames.Add(pbn);
            if pIsExt3 and IsIndexerCapableExternalType(pCn3) then // [Stage 98] List<T>/Dictionary<K,V> 메서드 구현 매개변수 인덱싱 지원
              foreach var pbn2 in pBatch do
                if not fArrayNames.Contains(pbn2) then fArrayNames.Add(pbn2);
            if Cur.Kind=tkSemicolon then fPos:=fPos+1 else break;
          end;
        end;
        Expect(tkRParen);
      end;

      if isFunc then
      begin
        Expect(tkColon); impl.ReturnType:=ParseVarType;
        if (impl.ReturnType=vtGeneric) or (impl.ReturnType=vtGenericArray) then impl.ReturnGenericName:=fLastGenericName; // [Stage 32/37]
        // [버그 수정] 반환 타입이 로컬 클래스/외부 타입(vtObject)이면 이름을 보존한다 —
        // TMethodSignature 쪽과 동일한 이유(BuildMethodBody의 Result 지역변수 정확화).
        if (impl.ReturnType=vtObject) or (impl.ReturnType=vtObjArray) or (impl.ReturnType=vtMatrix) then impl.ReturnClassName:=fLastGenericName;
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
      if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then // [Stage 61] const 섹션도 함께 처리
      begin
        ParseLocalDeclSections(impl.LocalVars, impl.ConstDecls);
        foreach var lvcp in impl.LocalVars do fCurParams.Add(lvcp.Name);
        foreach var lccp in impl.ConstDecls do fCurParams.Add(lccp.Name);
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

      // [Stage 68 재확인] 클래스 선언부 안에 "constructor Create;"라는 선언 없이,
      // 이 실제 구현(constructor ClassName.Create; begin...end;)만 별도로 존재하는
      // 경우에도 해당 클래스의 HasUserConstructor를 여기서 true로 표시해 둔다.
      // 그렇지 않으면 BuildClassShell이 "사용자 생성자가 없다"고 오판해서 자동으로
      // "부모 생성자 호출 + Ret"짜리 생성자 본문을 미리 채워 넣어 버리고, 이후
      // BuildConstructorBody가 실제 본문(필드 초기화, Controls.Add, 이벤트 구독 등)을
      // 그 뒤에 이어 붙여도 이미 Ret 뒤에 놓인 도달 불가능한 코드가 되어 조용히
      // 무시된다(예외도 없이 그냥 실행되지 않음) — 폼은 뜨지만(부모 생성자는 실행됨)
      // 버튼이 하나도 안 보이는 버그의 원인이었다.
      foreach var _cd68 in fProg.ClassDecls do
        if _cd68.Name=cn then begin _cd68.HasUserConstructor:=true; break; end;

      // [Stage 47] 매개변수 목록 파싱
      if Cur.Kind=tkLParen then
      begin
        fPos:=fPos+1;
        if Cur.Kind<>tkRParen then
        begin
          while true do
          begin
            var ctorPBatch:=new List<string>;
            // [Stage 100 버그 수정] "constructor TClass.Create(var x: string);" 형태도 지원.
            var ctorByRef2:=(Cur.Kind=tkVar) or (Cur.Kind=tkConst);
            if ctorByRef2 then fPos:=fPos+1;
            ctorPBatch.Add(Expect(tkIdent).Text);
            while Cur.Kind=tkComma do begin fPos:=fPos+1; ctorPBatch.Add(Expect(tkIdent).Text); end;
            Expect(tkColon);
            var ctorPIsExt2:=false; var ctorPCn2:='';
            pt:=ParseParamTypeExt(ctorPIsExt2, ctorPCn2);
            foreach var ctorPn2 in ctorPBatch do
            begin
              var ctorPd3:=new TParamDef(ctorPn2, pt, ctorPCn2, ctorPIsExt2); ctorPd3.IsByRef:=ctorByRef2;
              impl.Parameters.Add(ctorPd3);
            end;
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

      if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then // [Stage 61] const 섹션도 함께 처리
      begin
        ParseLocalDeclSections(impl.LocalVars, impl.ConstDecls);
        foreach var lvcp2 in impl.LocalVars do fCurParams.Add(lvcp2.Name);
        foreach var lccp2 in impl.ConstDecls do fCurParams.Add(lccp2.Name);
      end;
      Expect(tkBegin); comp:=new TCompoundStmtNode;
      ParseStatementsUntilEnd(comp.Statements); // [Stage 58] panic-mode 오류 복구
      Expect(tkEnd); Expect(tkSemicolon);

      fCurClass:=savedClass2; fCurFunc:=savedFunc2; fCurGenericParams:=savedGP4;
      fCurParams:=savedParams2; fCurMethodParamNames:=savedMethodParamNames2;
      impl.Body:=comp;
      Result:=impl;
    end;

    // [Stage 65b] 지역 서브프로그램 블록(function/procedure ... end; 연속)을 실제로 파싱하기 전에
    // 먼저 토큰 스트림을 앞으로 훑어(pre-scan) 모든 지역 서브프로그램의 이름을 수집한다.
    // 이렇게 하면 선언 순서와 무관하게(앞/뒤, 상호재귀) 서로 호출할 수 있다.
    //
    // 알고리즘:
    //   현재 fPos가 가리키는 위치부터 (function|procedure) tkIdent ... end; 패턴을 반복한다.
    //   각 서브프로그램 본문(begin...end)의 중첩 깊이를 추적해 올바른 end;를 찾고 건너뛴다.
    //   var/const 섹션은 begin이 나올 때까지 토큰을 버린다.
    //   fPos는 변경하지 않는다 — 완전한 파싱은 이후 ParseNestedFuncDecl/ParseNestedProcDecl이 수행한다.
    procedure PreScanNestedSubprograms(enclosingName: string);
    var scanPos: integer; localName, mangled: string; depth: integer;
    begin
      scanPos := fPos; // 현재 위치 기억 (복원용)
      while (fPos < fTokens.Count) and
            ((fTokens[fPos].Kind = tkFunction) or (fTokens[fPos].Kind = tkProcedure)) do
      begin
        var isFunc := (fTokens[fPos].Kind = tkFunction);
        fPos := fPos + 1; // function/procedure 소비

        // 이름 읽기
        if (fPos < fTokens.Count) and (fTokens[fPos].Kind = tkIdent) then
        begin
          localName := fTokens[fPos].Text;
          mangled := enclosingName + '$' + localName;
          fPos := fPos + 1;

          // 아직 등록되지 않은 경우에만 등록 (중복 방지)
          if not fCurNestedAlias.ContainsKey(localName) then
          begin
            fCurNestedAlias[localName] := mangled;
            if isFunc then
            begin
              if not fFuncNames.Contains(localName) then fFuncNames.Add(localName);
            end
            else
            begin
              if not fProcNames.Contains(localName) then fProcNames.Add(localName);
            end;
          end;
        end;

        // 이 서브프로그램의 나머지 토큰을 건너뛴다: ';' 뒤 ~ end; 까지
        // 전략: begin 을 만나면 begin/end 중첩 깊이를 추적, depth=0 이 된 end 직후 ';' 까지 진행
        // begin 이전에는 var/const 섹션 등이 있을 수 있으므로 begin을 기다린다.
        while (fPos < fTokens.Count) and (fTokens[fPos].Kind <> tkBegin) do
          fPos := fPos + 1;
        // 이제 fPos 는 tkBegin
        depth := 0;
        while fPos < fTokens.Count do
        begin
          var tk := fTokens[fPos].Kind;
          if tk = tkBegin then depth := depth + 1
          else if tk = tkEnd then
          begin
            depth := depth - 1;
            if depth = 0 then
            begin
              fPos := fPos + 1; // end 소비
              // end 뒤의 ';' 소비
              if (fPos < fTokens.Count) and (fTokens[fPos].Kind = tkSemicolon) then
                fPos := fPos + 1;
              break;
            end;
          end;
          fPos := fPos + 1;
        end;
      end;
      fPos := scanPos; // 위치 완전 복원
    end;

    // [Stage 65] 식/문장에서 함수·프로시저 호출 이름을 만들 때 항상 이 함수를 거친다.
    // 그 이름이 현재 감싸는 함수/프로시저의 지역 서브프로그램이면(fCurNestedAlias에 등록됨)
    // 맹글링된 실제 이름으로 바꿔주고, 아니면(최상위/외부 이름) 그대로 돌려준다.
    function ResolveCallName(n: string): string;
    begin
      if (fCurNestedAlias<>nil) and fCurNestedAlias.ContainsKey(n) then Result:=fCurNestedAlias[n]
      else Result:=n;
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
          // [Stage 100 버그 수정] 최상위 함수/프로시저(예: Main.pas의
          // "procedure ResolveProject(projPath: string; var mainFile: string; ...)")도
          // var/const 참조 매개변수 수식자를 인식하지 못했다.
          var pByRef5:=(Cur.Kind=tkVar) or (Cur.Kind=tkConst);
          if pByRef5 then fPos:=fPos+1;
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
            var pd5:=new TParamDef(nm, pt, pCn5, pIsExt5);
            pd5.IsByRef:=pByRef5; // [Stage 100 버그 수정]
            aP.Add(pd5);
            // [Stage 28] array of integer/string 매개변수도 본문에서 a[i]로 인덱싱할 수
            // 있어야 하는데, 이전에는 매개변수 이름이 fArrayNames에 등록되지 않아
            // 배열 인덱스 식으로 인식되지 않았다(별개 버그, 이번에 함께 수정).
            if (pt=vtIntArray) or (pt=vtStrArray) or (pt=vtGenericArray) or (pt=vtObjArray) then fArrayNames.Add(nm); // [Stage 37/90]
            if pt=vtMatrix then begin if not fArrayNames.Contains(nm) then fArrayNames.Add(nm); if not fMatrixNames.Contains(nm) then fMatrixNames.Add(nm); end; // [Stage 67/101]
            if pIsExt5 and IsIndexerCapableExternalType(pCn5) then // [Stage 98] List<T>/Dictionary<K,V> 매개변수 인덱싱 지원
              begin if not fArrayNames.Contains(nm) then fArrayNames.Add(nm); end;
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
        // [Stage 82] unit의 interface 섹션에서 이 이름이 이미 시그니처로 등록됐을 수
        // 있으므로(ParseInterfaceHeaderDecl) 중복 추가를 막는다.
        if not fFuncNames.Contains(d.Name) then fFuncNames.Add(d.Name);

      // (본문/매개변수/반환타입 파싱 동안 fCurGenericParams를 설정해 T 등의 참조를 vtGeneric으로 인식시킨다)
      savedGP4:=fCurGenericParams;
      if d.IsGeneric then fCurGenericParams:=genNames;

      ParseParams(d.Parameters);
      Expect(tkColon);
      // [Stage 69] function Name(...): sequence of <basictype>; — yield 기반 lazy 시퀀스.
      // 일반 ParseVarType과는 별도 경로로 처리한다: 최상위 함수의 반환 자리에서만 인식되고
      // (클래스 메서드/중첩 함수는 1차 제약으로 아직 미지원), 원소 타입도 기본 스칼라 타입만 허용한다.
      if Cur.Kind=tkSequence then
      begin
        fPos:=fPos+1; Expect(tkOf);
        d.IsIterator:=true;
        if Cur.Kind=tkInteger then begin fPos:=fPos+1; d.IterElemType:=vtInteger; end
        else if Cur.Kind=tkStringType then begin fPos:=fPos+1; d.IterElemType:=vtString; end
        else if Cur.Kind=tkBoolean then begin fPos:=fPos+1; d.IterElemType:=vtBoolean; end
        else if (Cur.Kind=tkReal) or (Cur.Kind=tkDouble) then begin fPos:=fPos+1; d.IterElemType:=vtReal; end
        else if Cur.Kind=tkChar then begin fPos:=fPos+1; d.IterElemType:=vtChar; end
        else if Cur.Kind=tkInt64 then begin fPos:=fPos+1; d.IterElemType:=vtInt64; end
        else raise new Exception('줄 '+Cur.Line.ToString+', 열 '+Cur.Column.ToString
          +': sequence of 뒤에는 integer/string/boolean/real/char/int64만 지원합니다 (Stage 69, 1차)');
        d.ReturnType:=vtInteger; // 사용되지 않음(IsIterator=true면 CodeGen이 IterElemType만 봄) — 안전한 기본값만 채워둠
      end
      else
      begin
        d.ReturnType:=ParseVarType;
        if (d.ReturnType=vtGeneric) or (d.ReturnType=vtGenericArray) then d.ReturnGenericName:=fLastGenericName; // [Stage 36/37]
        // [버그 수정] vtObject 반환 타입이면 fLastGenericName에 클래스/외부 타입 이름이 들어있다
        // (ParseVarType의 로컬 클래스 분기와 외부 타입 분기 모두 fLastGenericName을 채운다).
        // DeclareStaticFunc가 VTC(vtObject, ReturnClassName)으로 정확한 CLR 반환 타입을 얻는다.
        if (d.ReturnType=vtObject) or (d.ReturnType=vtObjArray) or (d.ReturnType=vtMatrix) then d.ReturnClassName:=fLastGenericName;
      end;
      Expect(tkSemicolon);
      sv:=fCurFunc; fCurFunc:=d.Name;
      if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then ParseLocalDeclSections(d.LocalVars, d.ConstDecls); // [Stage 61]

      // [Stage 65, 1차] var/const 섹션 다음, begin 앞에 오는 지역(중첩) 함수/프로시저 선언.
      // 이 함수(d) 자신이 최상위이므로 한 겹 중첩만 허용 — ParseNestedFuncDecl/ParseNestedProcDecl은
      // 스스로 또 다른 중첩을 파싱하지 않는다. fCurNestedAlias는 d의 본문(아래 begin...end)을
      // 파싱하는 동안에도 계속 유지되어야 하므로 Expect(tkEnd) 뒤에서 복원한다.
      var savedAlias4:=fCurNestedAlias;
      fCurNestedAlias:=new Dictionary<string, string>;
      // [Stage 65b] 실제 파싱 전에 모든 지역 서브프로그램 이름을 미리 등록해
      // 선언 순서와 무관한(순방향·역방향·상호재귀) 호출을 허용한다.
      PreScanNestedSubprograms(d.Name);
      while (Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure) do
      begin
        if Cur.Kind=tkFunction then d.NestedFuncs.Add(ParseNestedFuncDecl(d.Name))
        else d.NestedProcs.Add(ParseNestedProcDecl(d.Name));
      end;

      Expect(tkBegin); c:=new TCompoundStmtNode;
      ParseStatementsUntilEnd(c.Statements); // [Stage 58] panic-mode 오류 복구
      Expect(tkEnd); Expect(tkSemicolon); fCurFunc:=sv; d.Body:=c;
      fCurNestedAlias:=savedAlias4; // [Stage 65]
      fCurGenericParams:=savedGP4;
      Result:=d;
    end;

    // [Stage 66] 연산자 오버로딩: operator +(a, b: TVector): TVector; ... end; 형태의 선언.
    // 일반 최상위 함수와 거의 똑같이 파싱하되(매개변수/지역 var·const 섹션/본문 모두 재사용),
    // 이름 자리에 연산자 기호가 오고 매개변수 2개가 반드시 같은 레코드/클래스 타입이어야 하며
    // 반환 타입도 그와 같은 타입이어야 한다(대칭형 +, -, *, /만 지원 — 서로 다른 타입 간
    // 혼합 연산이나 비교 연산자(=, <>) 오버로딩은 이번 단계 범위 밖).
    // 파싱된 본문은 맹글링된 이름(예: 'operator$add$TVector')의 평범한 최상위 함수로
    // prog.FuncDecls에 등록하고, prog.OperatorOverloads에는 "기호+타입이름 → 맹글링된 이름"
    // 매핑만 남긴다 — CodeGen이 TBinOpNode 방출 시 이 매핑을 참조해 산술 연산 대신
    // 함수 호출로 대체한다.
    procedure ParseOperatorDecl(prog: TProgramNode);
    var
      opTok: TToken; opSym, opWord, typeName, mangled: string;
      d: TFuncDeclNode; c: TCompoundStmtNode; sv: string;
      retIsExt: boolean; retCn: string; retType: TVarType; ps: List<TParamDef>;
    begin
      Expect(tkOperator);
      opTok:=Cur;
      if opTok.Kind=tkPlus then begin opSym:='+'; opWord:='add'; end
      else if opTok.Kind=tkMinus then begin opSym:='-'; opWord:='sub'; end
      else if opTok.Kind=tkStar then begin opSym:='*'; opWord:='mul'; end
      else if opTok.Kind=tkSlash then begin opSym:='/'; opWord:='div'; end
      else raise new Exception('줄 '+opTok.Line.ToString+', 열 '+opTok.Column.ToString
        +': operator 뒤에는 +, -, *, / 중 하나가 와야 합니다 (Stage 66)');
      fPos:=fPos+1; // 연산자 기호 토큰 소비

      ps:=new List<TParamDef>;
      ParseParams(ps);
      if ps.Count<>2 then
        raise new Exception('줄 '+opTok.Line.ToString+', 열 '+opTok.Column.ToString
          +': operator '+opSym+'는 매개변수 2개(좌/우 피연산자)만 지원합니다 (Stage 66)');
      if (ps[0].ParamType<>vtObject) or (ps[1].ParamType<>vtObject)
         or (ps[0].ClassName<>ps[1].ClassName) or (ps[0].ClassName='') then
        raise new Exception('줄 '+opTok.Line.ToString+', 열 '+opTok.Column.ToString
          +': operator '+opSym+'의 두 매개변수는 같은 레코드/클래스 타입이어야 합니다 (Stage 66)');
      typeName:=ps[0].ClassName;

      Expect(tkColon);
      retType:=ParseParamTypeExt(retIsExt, retCn);
      if (retType<>vtObject) or (retCn<>typeName) then
        raise new Exception('줄 '+opTok.Line.ToString+', 열 '+opTok.Column.ToString
          +': operator '+opSym+'의 반환 타입은 피연산자와 같은 "'+typeName+'"이어야 합니다 (Stage 66)');
      Expect(tkSemicolon);

      if fOperatorSigs.Contains(opSym+'|'+typeName) then
        raise new Exception('줄 '+opTok.Line.ToString+', 열 '+opTok.Column.ToString
          +': 연산자 "'+opSym+'"가 타입 "'+typeName+'"에 대해 이미 정의되어 있습니다 (Stage 66)');
      fOperatorSigs.Add(opSym+'|'+typeName);

      mangled:='operator$'+opWord+'$'+typeName;
      d:=new TFuncDeclNode(mangled);
      d.Parameters:=ps;
      d.ReturnType:=vtObject;

      sv:=fCurFunc; fCurFunc:=mangled;
      if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then ParseLocalDeclSections(d.LocalVars, d.ConstDecls);

      Expect(tkBegin); c:=new TCompoundStmtNode;
      ParseStatementsUntilEnd(c.Statements);
      Expect(tkEnd); Expect(tkSemicolon);
      fCurFunc:=sv; d.Body:=c;

      prog.FuncDecls.Add(d);
      prog.OperatorOverloads.Add(new TOperatorOverloadNode(opSym, typeName, mangled));
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
        // [Stage 82] unit의 interface 섹션에서 이미 시그니처로 등록됐을 수 있으므로 중복 방지.
        if not fProcNames.Contains(d.Name) then fProcNames.Add(d.Name);

      savedGP5:=fCurGenericParams;
      if d.IsGeneric then fCurGenericParams:=genNames;

      ParseParams(d.Parameters); Expect(tkSemicolon);
      sv:=fCurFunc; fCurFunc:='';
      if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then ParseLocalDeclSections(d.LocalVars, d.ConstDecls); // [Stage 61]

      // [Stage 65, 1차] ParseFuncDecl과 동일한 규칙 — 자세한 설명은 그쪽 주석 참고.
      var savedAlias5:=fCurNestedAlias;
      fCurNestedAlias:=new Dictionary<string, string>;
      // [Stage 65b] 선언 순서와 무관한 호출을 위해 미리 모든 이름을 등록한다.
      PreScanNestedSubprograms(d.Name);
      while (Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure) do
      begin
        if Cur.Kind=tkFunction then d.NestedFuncs.Add(ParseNestedFuncDecl(d.Name))
        else d.NestedProcs.Add(ParseNestedProcDecl(d.Name));
      end;

      Expect(tkBegin); c:=new TCompoundStmtNode;
      ParseStatementsUntilEnd(c.Statements); // [Stage 58] panic-mode 오류 복구
      Expect(tkEnd); Expect(tkSemicolon); fCurFunc:=sv; d.Body:=c;
      fCurNestedAlias:=savedAlias5; // [Stage 65]
      fCurGenericParams:=savedGP5;
      Result:=d;
    end;

    // [Stage 65, 1차] 최상위 함수/프로시저(enclosingName) 본문 안에 선언된 지역 함수.
    // ParseFuncDecl과 거의 같지만:
    //   - 제네릭 지역 함수는 지원하지 않는다(1차 범위 밖 — <T> 파싱 자체를 시도하지 않음).
    //   - 또 다른 지역 서브프로그램을 자신 안에 선언할 수 없다(한 겹만 허용, panic-mode 오류
    //     복구를 단순하게 유지하기 위함이기도 함).
    //   - 캡처(클로저) 없음: 바깥 함수의 매개변수/지역변수는 안 보이고, 자신의 매개변수/지역변수와
    //     전역만 본다. CodeGen이 이를 그냥 독립된 static 메서드로 만들기 때문에 애초에 접근 경로가 없다.
    //   - 이름은 "enclosingName$지역이름"으로 맹글링해서 전역 fMethods 네임스페이스 충돌을 피한다.
    //     소스에는 여전히 지역이름 그대로 쓰므로, fCurNestedAlias에 등록해 두고 fFuncNames에는
    //     지역이름을 등록한다(호출 인식용) — 실제 호출 노드 생성은 ResolveCallName이 맹글링된
    //     이름으로 바꿔준다.
    function ParseNestedFuncDecl(enclosingName: string): TFuncDeclNode;
    var d: TFuncDeclNode; c: TCompoundStmtNode; sv: string; localName, mangled: string;
    begin
      Expect(tkFunction);
      localName:=Expect(tkIdent).Text;
      mangled:=enclosingName+'$'+localName;
      d:=new TFuncDeclNode(mangled);
      // [Stage 65b] PreScanNestedSubprograms가 이미 등록했을 수 있으므로 중복 방지
      if not fFuncNames.Contains(localName) then fFuncNames.Add(localName);
      fCurNestedAlias[localName]:=mangled; // 덮어써도 동일한 값이므로 무해

      ParseParams(d.Parameters);
      Expect(tkColon); d.ReturnType:=ParseVarType;
      if (d.ReturnType=vtGeneric) or (d.ReturnType=vtGenericArray) then d.ReturnGenericName:=fLastGenericName;
      if (d.ReturnType=vtObject) or (d.ReturnType=vtObjArray) or (d.ReturnType=vtMatrix) then d.ReturnClassName:=fLastGenericName; // [버그 수정]
      Expect(tkSemicolon);
      sv:=fCurFunc; fCurFunc:=mangled;
      if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then ParseLocalDeclSections(d.LocalVars, d.ConstDecls);
      Expect(tkBegin); c:=new TCompoundStmtNode;
      ParseStatementsUntilEnd(c.Statements); // [Stage 58] panic-mode 오류 복구
      Expect(tkEnd); Expect(tkSemicolon); fCurFunc:=sv; d.Body:=c;
      Result:=d;
    end;

    // [Stage 65, 1차] ParseNestedFuncDecl과 동일한 규칙의 지역 프로시저. 설명은 그쪽 주석 참고.
    function ParseNestedProcDecl(enclosingName: string): TProcDeclNode;
    var d: TProcDeclNode; c: TCompoundStmtNode; sv: string; localName, mangled: string;
    begin
      Expect(tkProcedure);
      localName:=Expect(tkIdent).Text;
      mangled:=enclosingName+'$'+localName;
      d:=new TProcDeclNode(mangled);
      // [Stage 65b] PreScanNestedSubprograms가 이미 등록했을 수 있으므로 중복 방지
      if not fProcNames.Contains(localName) then fProcNames.Add(localName);
      fCurNestedAlias[localName]:=mangled; // 덮어써도 동일한 값이므로 무해

      ParseParams(d.Parameters); Expect(tkSemicolon);
      sv:=fCurFunc; fCurFunc:='';
      if (Cur.Kind=tkVar) or (Cur.Kind=tkConst) then ParseLocalDeclSections(d.LocalVars, d.ConstDecls);
      Expect(tkBegin); c:=new TCompoundStmtNode;
      ParseStatementsUntilEnd(c.Statements); // [Stage 58] panic-mode 오류 복구
      Expect(tkEnd); Expect(tkSemicolon); fCurFunc:=sv; d.Body:=c;
      Result:=d;
    end;

    procedure ParseVarSection(aProg: TProgramNode);
    var vt: TVarType; ns: List<string>; cn: string; isExt: boolean; varDeclStartPos: integer;
    begin
      Expect(tkVar);
      while (Cur.Kind<>tkBegin) and (Cur.Kind<>tkFunction)
        and (Cur.Kind<>tkProcedure) and (Cur.Kind<>tkConst) and (Cur.Kind<>tkEOF)
        and (Cur.Kind<>tkVar) do // [Stage 67] 연속된 두 번째 var 섹션도 멈춤 조건에 포함
      begin
        // [Phase 2] var 선언 한 줄이 깨져도 전체를 멈추지 않고 오류를 모은 뒤 다음 줄로 건너뛴다.
        varDeclStartPos:=fPos;
        try
        begin
        ns:=new List<string>; ns.Add(Expect(tkIdent).Text);
        while Cur.Kind=tkComma do begin fPos:=fPos+1; ns.Add(Expect(tkIdent).Text); end;
        Expect(tkColon);
        cn:=''; isExt:=false;
        // [버그 수정] 전역 var 섹션도 지역 var/매개변수(ParseLocalVarSection/ParseParams)와
        // 동일하게 ParseParamTypeExt로 통일한다. 기존 손파싱 코드는 클래스/인터페이스/
        // 점(.)-연결 외부타입만 챙기고, List<T>/Dictionary<K,V>/HashSet<T> 같은 점 없는
        // 짧은 이름의 BCL 제네릭 컬렉션은 전혀 몰라 ParseVarType 기본 폴백으로 떨어졌다
        // (IsExternal=false, ClassName='') — 그 결과 "unitSearchDirs: List<string>;" 같은
        // 전역 변수가 CodeGen에서 cn=''+ClrType 미등록 상태로 넘어가 "unitSearchDirs.Add"가
        // "알 수 없는 메서드"로 실패했다(자기컴파일 중 Main.pas 자신의 소스에서 실제 재현됨).
        // ParseParamTypeExt는 클래스/인터페이스/열거형/set of/object/짧은 이름 BCL 제네릭
        // (List·Dictionary·HashSet·Queue·Stack·IEnumerable·IList·IDictionary·ICollection·
        // SortedList·LinkedList·SortedDictionary)/점 연결 외부타입/네임스페이스 탐색/기본
        // ParseVarType 폴백까지 이미 다 처리하는 상위 호환 함수라 기존 로직을 완전히
        // 대체해도 안전하다.
        vt:=ParseParamTypeExt(isExt, cn);
        if (vt=vtGeneric) or (vt=vtGenericArray) then cn:=fLastGenericName;
        if vt=vtMatrix then cn:=fLastGenericName;
        // [Stage 93] "Name: Type := expr;" — 전역 var 초기화식 (예: visualStates: VisualStates := new VisualStates();)
        var giveInit93: TExprNode := nil;
        if Cur.Kind=tkAssign then begin fPos:=fPos+1; giveInit93:=ParseExpr; end;
        Expect(tkSemicolon);
        foreach var nm in ns do
        begin
          var vd93:=new TVarDecl(nm, vt, cn, isExt);
          vd93.InitExpr:=giveInit93; // 이름이 여러 개(a, b: T := expr;)면 각자 같은 초기화식을 공유
          aProg.VarDecls.Add(vd93);
          if (vt=vtIntArray) or (vt=vtStrArray) then fArrayNames.Add(nm);
          if vt=vtMatrix then begin if not fArrayNames.Contains(nm) then fArrayNames.Add(nm); if not fMatrixNames.Contains(nm) then fMatrixNames.Add(nm); end; // [Stage 67/101]
          if isExt and IsIndexerCapableExternalType(cn) then // [Stage 98] List<T>/Dictionary<K,V> 전역변수 인덱싱 지원
            begin if not fArrayNames.Contains(nm) then fArrayNames.Add(nm); end;
        end;
        end;
        except
          on ex: Exception do
          begin
            ParseErrors.Add(ex.Message);
            if fPos=varDeclStartPos then fPos:=fPos+1;
            while (Cur.Kind<>tkSemicolon) and (Cur.Kind<>tkBegin) and (Cur.Kind<>tkFunction)
              and (Cur.Kind<>tkProcedure) and (Cur.Kind<>tkConst) and (Cur.Kind<>tkEOF)
              and (Cur.Kind<>tkVar) do // [Stage 67] 다음 var 섹션 선언을 삼키지 않도록
              fPos:=fPos+1;
            if Cur.Kind=tkSemicolon then fPos:=fPos+1;
          end;
        end;
      end;
    end;

    // [Stage 61] 전역 const 섹션: "const Name = 식;" (타입 추론) 또는
    // "const Name: Type = 식;" (명시적 타입). 여러 const/var 섹션이 번갈아 나올 수 있으므로
    // tkVar를 만나도(또한 함수/프로시저/begin/파일끝을 만나도) 멈춘다.
    procedure ParseConstSection(aProg: TProgramNode);
    var vt: TVarType; nm: string; cn: string; isExt: boolean; ve: TExprNode;
        hasType: boolean; constDeclStartPos: integer;
    begin
      Expect(tkConst);
      while (Cur.Kind<>tkBegin) and (Cur.Kind<>tkFunction)
        and (Cur.Kind<>tkProcedure) and (Cur.Kind<>tkVar) and (Cur.Kind<>tkEOF) do
      begin
        // [Phase 2] var 섹션과 동일한 원칙: const 선언 한 줄이 깨져도 전체를 멈추지 않는다.
        constDeclStartPos:=fPos;
        try
        begin
        nm:=Expect(tkIdent).Text;
        hasType:=false; cn:=''; isExt:=false; vt:=vtInteger;
        if Cur.Kind=tkColon then
        begin
          fPos:=fPos+1;
          vt:=ParseParamTypeExt(isExt, cn);
          hasType:=true;
        end;
        Expect(tkEq);
        ve:=ParseExpr;
        Expect(tkSemicolon);
        if hasType then aProg.ConstDecls.Add(new TConstDecl(nm, vt, cn, isExt, ve))
        else aProg.ConstDecls.Add(new TConstDecl(nm, ve));
        end;
        except
          on ex: Exception do
          begin
            ParseErrors.Add(ex.Message);
            if fPos=constDeclStartPos then fPos:=fPos+1;
            while (Cur.Kind<>tkSemicolon) and (Cur.Kind<>tkBegin) and (Cur.Kind<>tkFunction)
              and (Cur.Kind<>tkProcedure) and (Cur.Kind<>tkVar) and (Cur.Kind<>tkEOF) do
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
      fOperatorSigs:=new HashSet<string>; // [Stage 66]
      fCurMethodParamNames:=new List<string>; // [Stage 30]
      fCurNestedAlias:=nil; // [Stage 65] 최상위 함수/프로시저 밖에서는 지역 서브프로그램 별칭이 없음
      fFuncNames:=new HashSet<string>; // [성능] List→HashSet
      fProcNames:=new HashSet<string>; // [성능] List→HashSet
      fArrayNames:=new HashSet<string>; // [성능] List→HashSet
      fMatrixNames:=new HashSet<string>; // [Stage 101]
      fClassNames:=new HashSet<string>; // [성능] List→HashSet
      fInterfaceNames:=new HashSet<string>; // [성능] List→HashSet
      fEnumNames:=new HashSet<string>; // [Phase 1] [성능] List→HashSet
      fImportedNamespaces:=new List<string>; // [Stage 87]
      fRecordNames:=new HashSet<string>; // [Stage 62] [성능] List→HashSet
      fEnumMemberEnumName:=new Dictionary<string, string>; // [Stage 51]
      fEnumMemberOrdinal:=new Dictionary<string, integer>; // [Stage 51]
      fEnumSize:=new Dictionary<string, integer>; // [Stage 63] 열거형명 → 멤버 개수 (set of X의 32비트 한도 검사용)
      ParseErrors:=new List<string>; // [Stage 51]
      fClassFields:=new Dictionary<string, List<string>>;
      fClassMethods:=new Dictionary<string, Dictionary<string, boolean>>;
      fClassParent:=new Dictionary<string, string>;
      fClassInterface:=new Dictionary<string, string>; // [Stage 34]
      fGenericClassNames:=new HashSet<string>; // [성능] List→HashSet
      fClassGenericParam:=new Dictionary<string, List<string>>;
      fClassGenericConstraint:=new Dictionary<string, List<string>>; // [Stage 34]
      fGenericFuncNames:=new HashSet<string>; // [Stage 36] [성능] List→HashSet
      fGenericProcNames:=new HashSet<string>; // [Stage 36] [성능] List→HashSet
      fFuncGenericParam:=new Dictionary<string, List<string>>; // [Stage 36]
      fProcGenericParam:=new Dictionary<string, List<string>>; // [Stage 36]
      fFuncGenericConstraint:=new Dictionary<string, List<string>>; // [Stage 36]
      fProcGenericConstraint:=new Dictionary<string, List<string>>; // [Stage 36]
      fGenericMethodNames:=new List<string>; // [Stage 74]
      fMethodGenericParam:=new Dictionary<string, List<string>>; // [Stage 74]
      fMethodGenericConstraint:=new Dictionary<string, List<string>>; // [Stage 74]
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
      foreach var s in ext.RecordNames do if not fRecordNames.Contains(s) then fRecordNames.Add(s); // [Stage 62]
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
      Result.RecordNames.AddRange(fRecordNames); // [Stage 62]
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

    // [Stage 81] uses 절: uses UnitA, UnitB.SubUnit, ...;
    // 지금은 이름을 소비만 하고 버린다 — 외부 타입은 이미 완전한 점(.) 경로 이름으로
    // 참조되므로(예: System.Windows.Forms.Button) uses 목록 자체가 CodeGen에 영향을 주지 않는다.
    // WPF 디자이너가 생성하는 파일 헤더를 그대로 통과시키는 것이 목적. [Stage 81]에서
    // unit의 interface/implementation 섹션에도 각각 uses가 올 수 있어 재사용 가능하게 뽑아냄
    // (실제 다른 유닛과의 링크는 Stage 82에서 다룬다 — 지금은 여전히 이름만 버린다).
    procedure ParseAndDiscardUsesClause;
    begin
      // [Stage 87] uses 절 이름을 fImportedNamespaces에 저장한다.
      // 단순 이름(EventArgs, Label 등)을 ParseParamTypeExt/ParseVarType에서
      // 완전 경로로 해석하는 데 사용한다.
      fPos:=fPos+1; // 'uses' 소비
      var _nsName87:=Expect(tkIdent).Text;
      while Cur.Kind=tkDot do begin fPos:=fPos+1; _nsName87:=_nsName87+'.'+ExpectQualNamePart; end;
      if not fImportedNamespaces.Contains(_nsName87) then fImportedNamespaces.Add(_nsName87);
      while Cur.Kind=tkComma do
      begin
        fPos:=fPos+1;
        _nsName87:=Expect(tkIdent).Text;
        while Cur.Kind=tkDot do begin fPos:=fPos+1; _nsName87:=_nsName87+'.'+ExpectQualNamePart; end;
        if not fImportedNamespaces.Contains(_nsName87) then fImportedNamespaces.Add(_nsName87);
      end;
      Expect(tkSemicolon);
    end;

    // [Stage 82] unit의 interface 섹션에 오는 "본문 없는" 함수/프로시저 시그니처.
    //   function Name(params): RetType;   또는   procedure Name(params);
    // 로 끝난다 — begin...end 본문이 없다. 실제 본문은 뒤따르는 implementation 섹션에
    // 같은 이름으로 다시 나온다(그건 기존 ParseFuncDecl/ParseProcDecl 경로를 그대로 탄다).
    // 여기서는 TFuncDeclNode/TProcDeclNode를 만들지 않는다(본문이 없어 만들 수 없다) —
    // 대신 이름을 (1) fFuncNames/fProcNames에 등록해 이후 문장 파싱에서 호출 문법으로
    // 인식되게 하고, (2) prog.PublicFuncNames/PublicProcNames(이 유닛의 공개 API 목록)에
    // 등록한다. Main.pas는 다른 파일이 이 유닛을 uses할 때 이 공개 API 목록만 넘겨준다 —
    // implementation에만 있는(=이 목록에 없는) 이름은 다른 파일 쪽 파서에 전달되지 않으므로
    // 자연스럽게 "모르는 이름"이 되어 접근이 막힌다.
    procedure ParseInterfaceHeaderDecl(prog: TProgramNode);
    var isFunc: boolean; name: string; ps: List<TParamDef>; rt: TVarType;
    begin
      isFunc:=(Cur.Kind=tkFunction);
      fPos:=fPos+1; // 'function'/'procedure' 소비
      name:=Expect(tkIdent).Text;
      ps:=new List<TParamDef>;
      ParseParams(ps);
      if isFunc then
      begin
        Expect(tkColon);
        rt:=ParseVarType; // 반환 타입은 지금은 검증 없이 소비만 함(구현부 쪽 반환타입이 최종 진실)
        Expect(tkSemicolon);
        if not fFuncNames.Contains(name) then fFuncNames.Add(name);
        if not prog.PublicFuncNames.Contains(name) then prog.PublicFuncNames.Add(name);
      end
      else
      begin
        Expect(tkSemicolon);
        if not fProcNames.Contains(name) then fProcNames.Add(name);
        if not prog.PublicProcNames.Contains(name) then prog.PublicProcNames.Add(name);
      end;
    end;

    function ParseProgram: TProgramNode;
    var prog: TProgramNode; t: TToken;
    begin
      // [Stage 44] library Name; (dll 산출물) 또는 program Name; (exe 산출물) 둘 다 허용.
      // [Stage 81] unit Name; interface ... implementation ... end. 도 허용 — 유닛도
      // 실행 진입점(begin...end)이 없으므로 library와 동일하게 IsLibrary:=true로 취급해
      // 기존 DLL 산출 경로를 그대로 재사용한다. (다른 유닛에서 실제로 uses해서 링크하는
      // 것은 아직 안 됨 — 이 파일 하나만 단독으로 파싱/코드생성하는 것까지가 Stage 81 범위.)
      if Cur.Kind=tkLibrary then
      begin
        fPos:=fPos+1; prog:=new TProgramNode(Expect(tkIdent).Text); prog.IsLibrary:=true; Expect(tkSemicolon);
      end
      else if Cur.Kind=tkUnit then
      begin
        fPos:=fPos+1; // 'unit' 소비
        prog:=new TProgramNode(Expect(tkIdent).Text);
        prog.IsLibrary:=true;
        prog.IsUnit:=true;
        Expect(tkSemicolon);
      end
      else
      begin
        // [버그수정] 'program Name;' 헤더가 없는 파일(예: 'uses uMain; begin ... end.'로
        // 바로 시작하는 진입점 파일 — 실제 PascalABC.NET/디자이너 산출물에서 흔한 형태)을
        // 지금까지는 Expect(tkProgram)이 무조건 요구해서 "예상 tkProgram 실제 tkUses"
        // 파싱 오류로 막혔다. tkProgram 토큰이 보이면 기존대로 소비하고, 없으면 그냥
        // 이름 없는 프로그램으로 취급해 넘어간다(실행에 이름 자체는 쓰이지 않는다 —
        // 출력 파일명은 GenerateExe의 outName 매개변수로 별도로 정해진다).
        if Cur.Kind=tkProgram then
        begin
          fPos:=fPos+1; prog:=new TProgramNode(Expect(tkIdent).Text); Expect(tkSemicolon);
        end
        else
          prog:=new TProgramNode('Program');
      end;
      fProg:=prog; // 깊이 상관없이(식/타입 파싱 도중) GenericInstantiations에 접근하기 위함

      // [Stage 81] unit이면 type 섹션 앞에 'interface' 키워드가 와야 한다.
      // [Stage 92] 단, fChild.pas처럼 interface/implementation 없이 바로
      // uses + type + begin end. 로 가는 단순 유닛도 허용한다.
      var _hasInterface92 := false;
      if prog.IsUnit then
      begin
        if Cur.Kind=tkInterface then begin fPos:=fPos+1; _hasInterface92:=true; end;
        // interface 없으면 그냥 계속 (단순 유닛)
      end;

      if Cur.Kind=tkUses then ParseAndDiscardUsesClause;

      // type 섹션
      if Cur.Kind=tkType then ParseTypeSection(prog);

      // [Stage 82] unit이면 type 섹션 다음에 함수/프로시저 "시그니처만" 있는 선언이
      // 0개 이상 올 수 있다(본문 없는 forward 선언 — 실제 본문은 implementation에
      // 같은 이름으로 다시 나온다). 여기 나열된 이름들이 이 유닛의 공개 API가 된다.
      if prog.IsUnit then
        while (Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure) do
          ParseInterfaceHeaderDecl(prog);

      // [Stage 81] unit이면 여기서 'implementation' 키워드, 그리고 그 섹션 전용 uses도
      // 올 수 있다. 이후의 메서드 구현부/var/const 파싱은 program/library와 완전히 동일한
      // 문법이라 아래 기존 코드를 그대로 재사용한다.
      // [Stage 92] interface가 없는 단순 유닛은 implementation도 없을 수 있다.
      if prog.IsUnit then
      begin
        if _hasInterface92 then
        begin
          // [버그 수정] type 섹션 안에서 [Phase 2] 오류 복구가 실행됐다면(ParseErrors에
          // 이미 기록됨), 그 진짜 원인을 먼저 보고한다. 그렇지 않으면 복구 과정에서
          // 파서 위치가 살짝 어긋난 채로 여기 도달해 Expect(tkImplementation)이 전혀
          // 관계없는 토큰("예상 tkImplementation 실제 tkEnd" 등)으로 실패하고, 정작 원인이
          // 된 첫 번째 오류 메시지는 ParseErrors 리스트 안에 묻힌 채 사용자에게 보이지
          // 않았다.
          if ParseErrors.Count>0 then
            raise new Exception('구문 분석 오류 '+ParseErrors.Count.ToString+'건 발견:'#10+string.Join(#10, ParseErrors));
          Expect(tkImplementation);
          if Cur.Kind=tkUses then ParseAndDiscardUsesClause;
        end
        else if Cur.Kind=tkImplementation then
        begin
          fPos:=fPos+1; // 'implementation' 소비
          if Cur.Kind=tkUses then ParseAndDiscardUsesClause;
        end;
      end;

      // [Stage 92 버그 수정] 클래스 메서드 구현/일반 함수·프로시저/생성자/연산자와 var/const 섹션은
      // 순서 상관없이 얼마든지 번갈아 나올 수 있다(예: var 섹션이 맨 앞에 한 번 나오고 그 뒤에
      // 여러 procedure 구현부가 이어지는 경우). 예전에는 이 둘이 별도의 while 루프였는데, 첫 번째
      // 루프(함수/프로시저)가 "한 번 끝나면 다신 안 돌아오는" 구조라 var 섹션이 함수/프로시저보다
      // 먼저 나오면 그 뒤에 남은 함수/프로시저 구현부들을 통째로 못 읽고 곧장 "end."을 기대하다
      // "예상 tkEnd 실제 tkProcedure" 에러로 이어졌다. 하나의 루프로 합쳐서 매 반복마다 어느 쪽이든
      // 올 수 있게 한다.
      while (Cur.Kind=tkFunction) or (Cur.Kind=tkProcedure) or (Cur.Kind=tkConstructor) or (Cur.Kind=tkOperator)
            or (Cur.Kind=tkVar) or (Cur.Kind=tkConst) do
      begin
        if Cur.Kind=tkVar then ParseVarSection(prog)
        else if Cur.Kind=tkConst then ParseConstSection(prog)
        else
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
        // [Stage 66] operator +(a, b: T): T; ... end; — 항상 최상위 선언
        else if Cur.Kind=tkOperator then
        begin
          ParseOperatorDecl(prog);
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
                 or (Cur.Kind=tkConstructor) or (Cur.Kind=tkOperator) or (Cur.Kind=tkVar) or (Cur.Kind=tkConst)
                 or (Cur.Kind=tkEnd)) then // [Stage 87] 마지막 구현부가 깨져도 유닛의 최종 end.는 삼키지 않음
                break;
              if (Cur.Kind=tkBegin) or (Cur.Kind=tkTry) or (Cur.Kind=tkCase) then syncDepth:=syncDepth+1
              else if (Cur.Kind=tkEnd) and (syncDepth>0) then syncDepth:=syncDepth-1;
              fPos:=fPos+1;
            end;
          end;
        end;
        end;
      end;

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

      // [Stage 82] interface에 시그니처만 선언해놓고 implementation에 본문을 안 준 경우를
      // 여기서 바로 잡아낸다 — 안 그러면 "링크할 실체가 없는 빈 공개 API"가 되어, 나중에
      // 이 유닛을 uses하는 다른 파일에서 정체불명의 CodeGen 오류로 튀어나오게 된다.
      if prog.IsUnit then
      begin
        foreach var pubFn in prog.PublicFuncNames do
        begin
          var implFound:=false;
          foreach var fd in prog.FuncDecls do if fd.Name=pubFn then begin implFound:=true; break; end;
          if not implFound then
            raise new Exception('유닛 "'+prog.Name+'"의 interface에 선언된 함수 "'+pubFn
              +'"의 구현이 implementation 섹션에 없습니다 (Stage 82)');
        end;
        foreach var pubPn in prog.PublicProcNames do
        begin
          var implFound2:=false;
          foreach var pd in prog.ProcDecls do if pd.Name=pubPn then begin implFound2:=true; break; end;
          if not implFound2 then
            raise new Exception('유닛 "'+prog.Name+'"의 interface에 선언된 프로시저 "'+pubPn
              +'"의 구현이 implementation 섹션에 없습니다 (Stage 82)');
        end;
      end;

      Result:=prog;
    end;
  end;

implementation

end.