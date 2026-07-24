// ============================================================
// AST.pas — 노드 타입 정의 (TVarType, TExprNode/TStmtNode 계열)
// 다른 unit에 의존하지 않음. Lexer/Parser/CodeGen 모두 이 unit을 uses 함.
// ============================================================
unit AST;

interface

type
  // ----------------------------------------------------------
  // 변수/식 타입
  // ----------------------------------------------------------
  TVarType = (vtInteger, vtString, vtIntArray, vtStrArray, vtObject, vtInterface, vtBoolean, vtGeneric, vtGenericArray,
              vtReal, vtChar, vtInt64, vtEnum, vtSet, vtMatrix, vtInferred);
  // [Stage 68] vtInferred: 람다 매개변수에 타입 명시가 없을 때(예: (sender, e) -> ...)의 임시
  //   placeholder. 실제 CLR 타입은 CodeGen이 델리게이트의 Invoke 시그니처에서 위치별로 가져와
  //   확정한다 — 파서 단계에서는 "타입 미정"이라는 사실만 기록해 둔다.
  // [Stage 67] vtMatrix: 2차원 배열 (array of array of <elemtype>).
  //   런타임 표현은 CLR jagged array: integer[][] / string[][] / double[][].
  //   원소 타입은 TVarDecl/TParamDef.ClassName 필드에 'integer'/'string'/'real'/'char'/'int64'로 기록된다.
  //   SetLength(m, rows, cols) → 먼저 바깥 배열을 rows 크기로, 이후 각 행을 cols 크기로 초기화.
  //   m[i][j] 읽기 → TMatrix2DIndexExprNode, 쓰기 → TMatrix2DAssignStmtNode.
  // vtSet: [Stage 63] set of <열거형>. 런타임 표현은 System.Int32 비트마스크(비트 i = 서수 i 포함 여부).
  //   ClassName 필드(TVarDecl/TParamDef/TFieldDeclNode 공통 관례)에 대상 열거형 이름을 담는다 — vtEnum과 동일한 관례.
  // vtObject: 클래스 인스턴스 (TCounter 등)
  // vtInterface: 인터페이스 타입 변수 (ISpeaker 등)
  // vtBoolean: boolean 타입 (true/false)
  // vtGeneric: 제네릭 클래스 선언 본문 안에서만 등장하는 "타입 매개변수 자리" (예: T).
  //   Monomorphize 단계에서 실제 타입 인자로 치환되어 사라지므로 CodeGen은 이 값을 절대 보지 않는다.
  // [Stage 37] vtGenericArray: 제네릭 템플릿 안의 "array of T" 자리. vtGeneric과 마찬가지로
  //   Monomorphize 단계에서 실제 타입 인자에 따라 vtIntArray/vtStrArray로 치환되어 사라진다.
  //   (현재는 정수/문자열 타입 인자만 지원 — 클래스 타입 인자로 인스턴스화하면 단형화 단계에서
  //   명확한 에러로 실패한다. "배열 원소가 임의의 클래스" 기능은 이 컴파일러가 아직 갖고 있지
  //   않은 별개의 큰 기능이라 제네릭과 무관하게도 지원되지 않는다.)
  // [Phase 1] vtReal: double 정밀도 실수 (real/double 키워드 모두 이 타입으로 매핑)
  // [Phase 1] vtChar: 단일 문자 (char 키워드, 문자 리터럴 'A' / #65)
  // [Phase 1] vtInt64: 64비트 정수 (int64 키워드)
  // [Phase 1] vtEnum: 열거형 (type TColor = (Red, Green, Blue); 형태)

  // ----------------------------------------------------------
  // Lexer
  // ----------------------------------------------------------
  // ----------------------------------------------------------
  // AST — 식 노드
  // ----------------------------------------------------------
  TExprNode = class end;

  TIntLiteralNode = class(TExprNode)
  public Value: integer;
    constructor Create(v: integer); begin Value:=v; end;
  end;

  // [Phase 1] 실수 리터럴 (3.14, 2.0e-5 등). CLR double로 방출.
  TRealLiteralNode = class(TExprNode)
  public Value: double;
    constructor Create(v: double); begin Value:=v; end;
  end;

  // [Phase 1] 문자 리터럴 ('A', #65). CLR char로 방출.
  TCharLiteralNode = class(TExprNode)
  public Value: char;
    constructor Create(v: char); begin Value:=v; end;
  end;

  // [Phase 1] int64 리터럴 (9999999999 등 integer 범위 초과값, 또는 명시적 int64 변수에 대입되는 값).
  TInt64LiteralNode = class(TExprNode)
  public Value: int64;
    constructor Create(v: int64); begin Value:=v; end;
  end;

  TStrLiteralNode = class(TExprNode)
  public Value: string;
    constructor Create(v: string); begin Value:=v; end;
  end;

  // [Stage 51] 열거형 값 리터럴 (예: North, South — TDirection = (North, South, ...) 의 멤버).
  // 선언 순서대로 0, 1, 2, ... 정수 서수(Ordinal)에 대응하며 CLR에서는 Ldc_I4로 방출된다.
  TEnumValueExprNode = class(TExprNode)
  public
    EnumName: string;
    MemberName: string;
    Ordinal: integer;
    constructor Create(en, mn: string; ord: integer);
    begin EnumName:=en; MemberName:=mn; Ordinal:=ord; end;
  end;

  TVarRefNode = class(TExprNode)
  public VarName: string;
    constructor Create(n: string); begin VarName:=n; end;
  end;

  TResultRefNode = class(TExprNode) end;

  // [Stage 29] nil 리터럴 (참조 타입 변수/필드와의 비교, 대입에 사용)
  TNilLiteralNode = class(TExprNode) end;

  // [Stage 30] self 값 자체를 식으로 참조 (예: 델리게이트 target, 다른 메서드/함수의
  // 인자로 self를 넘길 때). 'self.fValue' 처럼 뒤에 점(.)이 붙는 형태는 파서 단계에서
  // 기존 암시적 self 필드읽기/메서드호출(ObjName='')로 즉시 환원되므로 이 노드가 쓰이지 않는다.
  TSelfExprNode = class(TExprNode) end;

  // [Stage 30] <식> as <TypeName>  — Delphi식 체크 캐스트. 실패 시 InvalidCastException.
  // TargetType은 지역 클래스/인터페이스 이름이거나(IsExternalType=false),
  // 점(.)으로 연결된 외부 .NET 타입 전체 경로(IsExternalType=true).
  TAsCastExprNode = class(TExprNode)
  public Expr: TExprNode; TargetType: string; IsExternalType: boolean;
    constructor Create(e: TExprNode; tt: string);
    begin Expr:=e; TargetType:=tt; IsExternalType:=false; end;
  end;

  // [Stage 30] inherited MethodName(args...)  — 식으로 쓰이는 경우 (함수: 반환값 있음).
  // 예: Result := inherited GetValue();
  TInheritedCallExprNode = class(TExprNode)
  public MethodName: string; Args: List<TExprNode>;
    constructor Create(mn: string); begin MethodName:=mn; Args:=new List<TExprNode>; end;
  end;

  TIntToStrNode = class(TExprNode)
  public Arg: TExprNode;
    constructor Create(a: TExprNode); begin Arg:=a; end;
  end;

  TBoolToStrNode = class(TExprNode)
  public Arg: TExprNode;
    constructor Create(a: TExprNode); begin Arg:=a; end;
  end;

  TArrayIndexExprNode = class(TExprNode)
  public ArrName: string; Index: TExprNode;
    constructor Create(n: string; i: TExprNode); begin ArrName:=n; Index:=i; end;
  end;

  TLengthExprNode = class(TExprNode)
  public ArrName: string;
    constructor Create(n: string); begin ArrName:=n; end;
  end;

  // TCounter.Create → Newobj
  TNewObjectExprNode = class(TExprNode)
  public ClassName: string; IsExternalType: boolean;
    Args: List<TExprNode>; // [Stage 40] new TypeName(args) — 생성자 인자 (없으면 빈 목록)
    constructor Create(cn: string); begin ClassName:=cn; IsExternalType:=false; Args:=new List<TExprNode>; end;
  end;

  // c.GetValue, c.Init(10) → 인스턴스 메서드 호출 (반환값 있음 → 식)
  TMethodCallExprNode = class(TExprNode)
  public ObjName: string; MethodName: string; Args: List<TExprNode>;
    ObjCastType: string; // ''이 아니면 ObjName을 이 타입으로 캐스트한 뒤 멤버에 접근
    // [Stage 74] obj.Method<T,U>(...) 처럼 명시적 타입 인자가 주어진 제네릭 메서드 호출.
    // 비어 있으면(Count=0) 일반(비제네릭) 메서드 호출.
    GenericArgTypes: List<TVarType>;
    GenericArgClassNames: List<string>;
    constructor Create(obj, mth: string);
    begin
      ObjName:=obj; MethodName:=mth; Args:=new List<TExprNode>; ObjCastType:='';
      GenericArgTypes:=new List<TVarType>; GenericArgClassNames:=new List<string>;
    end;
  end;

  // self.fValue 읽기 (메서드 본문 안에서 필드 참조)
  TFieldReadExprNode = class(TExprNode)
  public FieldName: string;
    constructor Create(f: string); begin FieldName:=f; end;
  end;

  TBinOpKind = (boAdd, boSub, boMul, boDiv, boMod, boAnd, boOr);
  TBinOpNode = class(TExprNode)
  public Op: TBinOpKind; Left, Right: TExprNode;
    // 주의: 매개변수 이름을 필드명 Op와 대소문자만 다르게 두면 안 됨.
    // Pascal은 대소문자를 구분하지 않으므로 'op'와 'Op'가 같은 식별자로 처리되어
    // 매개변수가 필드를 가려버리고(Op:=op가 사실상 op:=op가 됨),
    // Op 필드가 항상 기본값(boAdd)으로 남는 버그가 생긴다.
    constructor Create(aOp: TBinOpKind; l, r: TExprNode);
    begin Op:=aOp; Left:=l; Right:=r; end;
  end;

  TCompareKind = (cmpEq, cmpNeq, cmpLt, cmpGt, cmpLe, cmpGe);
  TCompareNode = class(TExprNode)
  public Op: TCompareKind; Left, Right: TExprNode;
    // 위와 동일한 이유로 매개변수명을 aOp로 사용 (Op와 대소문자만 다른 이름 금지).
    constructor Create(aOp: TCompareKind; l, r: TExprNode);
    begin Op:=aOp; Left:=l; Right:=r; end;
  end;

  // [Stage 63] 집합 리터럴 [Red, Blue]. Mask는 파싱 시점에 이미 비트마스크로 접혀 있다
  // (원소가 전부 컴파일타임에 알려진 열거형 멤버이므로). EnumName은 ''일 수도 있는데,
  // 빈 집합 리터럴([])은 어떤 "set of X" 타입에도 그대로 쓸 수 있어(값이 항상 0이므로)
  // 굳이 특정 열거형에 묶어둘 필요가 없다.
  TSetLiteralExprNode = class(TExprNode)
  public EnumName: string; Mask: integer;
    constructor Create(e: string; m: integer); begin EnumName:=e; Mask:=m; end;
  end;

  // [Stage 63] Elem in SetExpr — 집합 멤버십 검사. Elem은 열거형 값(리터럴/변수 모두 가능,
  // 런타임 표현이 곧 서수이므로), SetExpr은 vtSet 식이다.
  TInExprNode = class(TExprNode)
  public Elem, SetExpr: TExprNode;
    constructor Create(e, s: TExprNode); begin Elem:=e; SetExpr:=s; end;
  end;

  // true / false 리터럴
  TBoolLiteralNode = class(TExprNode)
  public Value: boolean;
    constructor Create(v: boolean); begin Value:=v; end;
  end;

  // not <식> (단항, 최우선순위 — ParsePrimary 안에서 파싱)
  TNotExprNode = class(TExprNode)
  public Expr: TExprNode;
    constructor Create(e: TExprNode); begin Expr:=e; end;
  end;

  // [Stage 72] PABCSystem 표준 라이브러리 함수 호출(Abs/Sqrt/UpperCase/Copy/StrToInt/... 등).
  // Stage 70의 TSeqExtCallExprNode와 같은 원칙 — 노드 하나 + 이름으로 CodeGen에서 분기하는
  // 방식이라, 나중에 함수를 더 추가할 때 AST/Parser는 그대로 두고 CodeGen 쪽 분기만 늘리면 된다.
  // Name은 항상 정규화된 표준 표기(예: 'UpperCase')로 저장한다 — Pascal은 대소문자를 구분하지
  // 않으므로 소스에 'uppercase'/'UPPERCASE'라고 써도 여기서는 늘 같은 문자열이 된다.
  TBuiltinCallExprNode = class(TExprNode)
  public Name: string; Args: List<TExprNode>;
    constructor Create(n: string); begin Name:=n; Args:=new List<TExprNode>; end;
  end;

  TFuncCallExprNode = class(TExprNode)
  public FuncName: string; Args: List<TExprNode>;
    constructor Create(n: string); begin FuncName:=n; Args:=new List<TExprNode>; end;
  end;

  // [Stage 70] LINQ 스타일 확장 메서드용 "식 람다": ParamName -> Body  (예: x -> x*x, x -> x mod 2 = 0).
  // Stage 64의 TLambdaExprNode(Body: TStmtNode, 이벤트 구독 전용)와는 별개 — 이쪽은 매개변수 하나에
  // 값을 돌려주는 "식"(TExprNode) 본문만 가진다. begin...end 블록 없이 항상 식 하나.
  TExprLambdaNode = class
  public ParamName: string; Body: TExprNode;
    constructor Create(p: string; b: TExprNode); begin ParamName:=p; Body:=b; end;
  end;

  // [Stage 70] Source.MethodName(...)  형태의 LINQ 스타일 확장 메서드 호출.
  // MethodName은 'Where'/'Select'/'Sum'/'Count'/'ToArray' 중 하나로 제한한다(1차 제약).
  // Where/Select는 Lambda가 필수(각각 predicate/selector), Sum/Count/ToArray는 Lambda=nil(인자 없음).
  // Source는 "시퀀스처럼 취급 가능한 식"이어야 한다 — 1차 제약: sequence of T 함수 호출 또는
  // 이 노드 자신의 체이닝(Where/Select 결과)만 지원. 지역 변수에 저장된 시퀀스는 아직 미지원.
  TSeqExtCallExprNode = class(TExprNode)
  public Source: TExprNode; MethodName: string; Lambda: TExprLambdaNode;
    constructor Create(src: TExprNode; mname: string; lam: TExprLambdaNode);
    begin Source:=src; MethodName:=mname; Lambda:=lam; end;
  end;

  // ----------------------------------------------------------
  // AST — 문장 노드
  // ----------------------------------------------------------
  TStmtNode = class end;

  TWritelnExprStmtNode = class(TStmtNode)
  public Arg: TExprNode;
    constructor Create(a: TExprNode); begin Arg:=a; end;
  end;

  TWritelnStringStmtNode = class(TStmtNode)
  public Text: string;
    constructor Create(t: string); begin Text:=t; end;
  end;

  // [Stage 75] Readln; 또는 Readln(변수); — 콘솔에서 한 줄 입력을 기다린다.
  // Arg=nil이면 인자 없는 Readln; (Enter 대기만). Arg<>nil이면 읽은 줄을 변수에 대입.
  TReadlnStmtNode = class(TStmtNode)
  public Arg: TExprNode; // nil = 인자 없음
    constructor Create(a: TExprNode); begin Arg:=a; end;
  end;

  TAssignStmtNode = class(TStmtNode)
  public VarName: string; ValueExpr: TExprNode;
    constructor Create(n: string; v: TExprNode); begin VarName:=n; ValueExpr:=v; end;
  end;

  TResultAssignStmtNode = class(TStmtNode)
  public ValueExpr: TExprNode;
    constructor Create(v: TExprNode); begin ValueExpr:=v; end;
  end;

  TCompoundStmtNode = class(TStmtNode)
  public Statements: List<TStmtNode>;
    constructor Create; begin Statements:=new List<TStmtNode>; end;
  end;

  TIfStmtNode = class(TStmtNode)
  public Condition: TExprNode; ThenStmt, ElseStmt: TStmtNode;
    constructor Create(c: TExprNode; t, e: TStmtNode);
    begin Condition:=c; ThenStmt:=t; ElseStmt:=e; end;
  end;

  TWhileStmtNode = class(TStmtNode)
  public Condition: TExprNode; Body: TStmtNode;
    constructor Create(c: TExprNode; b: TStmtNode);
    begin Condition:=c; Body:=b; end;
  end;

  // for VarName := StartExpr (to|downto) EndExpr do Body
  TForStmtNode = class(TStmtNode)
  public VarName: string; StartExpr, EndExpr: TExprNode; IsDownto: boolean; Body: TStmtNode;
    constructor Create(v: string; s, e: TExprNode; dn: boolean; b: TStmtNode);
    begin VarName:=v; StartExpr:=s; EndExpr:=e; IsDownto:=dn; Body:=b; end;
  end;

  // [Stage 54] for VarName in CollExpr do Body — 배열/컬렉션 순회.
  // CollExpr은 IEnumerable을 구현하는 값이면 무엇이든 될 수 있다(배열, List<T> 등 외부 컬렉션).
  // CodeGen에서 GetEnumerator/MoveNext/Current 패턴으로 desugar된다.
  TForInStmtNode = class(TStmtNode)
  public VarName: string; CollExpr: TExprNode; Body: TStmtNode;
    constructor Create(v: string; c: TExprNode; b: TStmtNode);
    begin VarName:=v; CollExpr:=c; Body:=b; end;
  end;

  // [Stage 60] repeat 문장들 until Condition — 조건을 맨 뒤에서 검사하므로 본문이 최소 한 번은 실행된다.
  // (while과 달리 조건이 '참'이 되면 멈춘다: while은 조건이 참인 동안, repeat은 조건이 거짓인 동안 반복)
  TRepeatStmtNode = class(TStmtNode)
  public Statements: List<TStmtNode>; Condition: TExprNode;
    constructor Create; begin Statements:=new List<TStmtNode>; end;
  end;

  // [Stage 60] break — 가장 안쪽 for/while/repeat 루프를 즉시 빠져나간다.
  TBreakStmtNode = class(TStmtNode)
  end;

  // [Stage 60] continue — 가장 안쪽 for/while/repeat 루프의 다음 반복으로 건너뛴다.
  TContinueStmtNode = class(TStmtNode)
  end;

  // [Stage 78] exit — 현재 프로시저/함수/메서드(생성자 포함)를 즉시 빠져나간다.
  // break/continue가 "가장 안쪽 루프"를 대상으로 하는 것과 달리, exit은 항상 현재
  // 실행 중인 서브프로그램 전체를 대상으로 한다. 파서 이전에는 이 토큰이 그냥 식별자로
  // 취급되어 CodeGen이 "exit"를 (self 위의) 외부 메서드 호출로 오인해 오류를 냈다
  // ("외부 타입에 메서드 exit가 없습니다") — tkExit 전용 토큰과 이 노드로 그 문제를 해결한다.
  TExitStmtNode = class(TStmtNode)
  end;

  // [Stage 69] yield <식>; — sequence 반환 함수(function ...: sequence of T) 안에서만 쓸 수 있다.
  // MoveNext가 호출될 때마다 이 지점까지 실행하고 Expr 값을 Current로 남긴 뒤 실행을 "일시정지"한다
  // (다음 MoveNext 호출 때 바로 다음 문장부터 이어서 실행). CodeGen이 상태 필드 기반 재개 지점으로 번역한다.
  TYieldStmtNode = class(TStmtNode)
  public Expr: TExprNode;
    constructor Create(e: TExprNode); begin Expr:=e; end;
  end;

  // [Stage 59] case 라벨 하나. 단일 값(예: 3, 'A', Red)이면 HighExpr=nil.
  // 범위(예: 1..5)면 LowExpr..HighExpr 둘 다 채워진다.
  // (PascalABC.NET은 named constructor를 허용하지 않아 — 오류: "Constructor can have
  //  only 'Create' name" — CreateRange 대신 Create를 매개변수 개수로 오버로드한다.)
  TCaseLabel = class
  public
    LowExpr: TExprNode; HighExpr: TExprNode;
    constructor Create(lo: TExprNode); overload; begin LowExpr:=lo; HighExpr:=nil; end;
    constructor Create(lo, hi: TExprNode); overload; begin LowExpr:=lo; HighExpr:=hi; end;
  end;

  // [Stage 59] case의 분기 하나: "라벨1, 라벨2, ... : 문장;"
  TCaseBranchNode = class
  public
    Labels: List<TCaseLabel>; Stmt: TStmtNode;
    constructor Create; begin Labels:=new List<TCaseLabel>; end;
  end;

  // [Stage 59] case Selector of 분기들... [else 문장들] end
  // ElseStmts=nil이면 else 절이 없는 것 (아무 분기도 안 맞으면 그냥 통과).
  TCaseStmtNode = class(TStmtNode)
  public
    Selector: TExprNode; Branches: List<TCaseBranchNode>; ElseStmts: List<TStmtNode>;
    constructor Create(sel: TExprNode);
    begin Selector:=sel; Branches:=new List<TCaseBranchNode>; ElseStmts:=nil; end;
  end;

  TProcCallStmtNode = class(TStmtNode)
  public ProcName: string; Args: List<TExprNode>;
    constructor Create(n: string); begin ProcName:=n; Args:=new List<TExprNode>; end;
  end;

  TSetLengthStmtNode = class(TStmtNode)
  public ArrName: string; NewSize: TExprNode;
    constructor Create(n: string; s: TExprNode); begin ArrName:=n; NewSize:=s; end;
  end;

  TArrayAssignStmtNode = class(TStmtNode)
  public ArrName: string; Index, ValueExpr: TExprNode;
    constructor Create(n: string; i, v: TExprNode);
    begin ArrName:=n; Index:=i; ValueExpr:=v; end;
  end;

  // [Stage 67] 2차원 배열 원소 읽기: arr[i][j]
  // ElemTypeName: 'integer'/'string'/'real'/'char'/'int64' — Ldelem 명령 선택에 사용.
  TMatrix2DIndexExprNode = class(TExprNode)
  public ArrName: string; Row, Col: TExprNode; ElemTypeName: string;
    constructor Create(n: string; r, c: TExprNode; etn: string);
    begin ArrName:=n; Row:=r; Col:=c; ElemTypeName:=etn; end;
  end;

  // [Stage 67] 2차원 배열 원소 쓰기: arr[i][j] := val
  TMatrix2DAssignStmtNode = class(TStmtNode)
  public ArrName: string; Row, Col, ValueExpr: TExprNode; ElemTypeName: string;
    constructor Create(n: string; r, c, v: TExprNode; etn: string);
    begin ArrName:=n; Row:=r; Col:=c; ValueExpr:=v; ElemTypeName:=etn; end;
  end;

  // [Stage 67] 2차원 SetLength: SetLength(arr, rows, cols)
  // rows/cols가 모두 있을 때 이 노드가 만들어진다.
  TSetLengthMatrix2DStmtNode = class(TStmtNode)
  public ArrName: string; Rows, Cols: TExprNode; ElemTypeName: string;
    constructor Create(n: string; r, c: TExprNode; etn: string);
    begin ArrName:=n; Rows:=r; Cols:=c; ElemTypeName:=etn; end;
  end;

  // c.Init(10); 인스턴스 메서드 호출 (반환값 없는 프로시저)
  TMethodCallStmtNode = class(TStmtNode)
  public ObjName: string; MethodName: string; Args: List<TExprNode>;
    ObjCastType: string; // ''이 아니면 ObjName을 이 타입으로 캐스트한 뒤 멤버에 접근 (예: TButton(sender).Focus)
    // [Stage 74] 식 버전(TMethodCallExprNode)과 동일한 목적.
    GenericArgTypes: List<TVarType>;
    GenericArgClassNames: List<string>;
    constructor Create(obj, mth: string);
    begin
      ObjName:=obj; MethodName:=mth; Args:=new List<TExprNode>; ObjCastType:='';
      GenericArgTypes:=new List<TVarType>; GenericArgClassNames:=new List<string>;
    end;
  end;

  // self.fValue := 식  (메서드 본문 안에서 필드 쓰기)
  // Qualifier=''  이면 self의 필드/속성. Qualifier<>'' 이면 그 이름의 필드를 통해
  // 접근하는 대상의 속성/필드 (예: Button1.Text := '...' → Qualifier='Button1', FieldName='Text')
  TFieldAssignStmtNode = class(TStmtNode)
  public FieldName: string; ValueExpr: TExprNode; Qualifier: string;
    QualifierCastType: string; // ''이 아니면 Qualifier를 이 타입으로 캐스트 (예: TButton(sender).Text := ...)
    constructor Create(f: string; v: TExprNode);
    begin FieldName:=f; ValueExpr:=v; Qualifier:=''; QualifierCastType:=''; end;
  end;

  // Qualifier.EventName += HandlerName;  (예: Button1.Click += Button1_Click;)
  // [Stage 64] TEventSubscribeStmtNode/TLambdaExprNode 정의는 TParamDef 선언 뒤로 옮겨져
  // 있다 — 람다가 List<TParamDef>를 담는데, 제네릭 인스턴스화는 클래스 필드 전방 참조와
  // 달리 TParamDef가 이미 정의돼 있어야 하기 때문. (아래쪽, TParamDef 바로 뒤 참고)

  // [Stage 48] begin...end 안에서 "var x := 식;" 형태로 선언과 동시에 대입하는 문장.
  // (앞서 있던 "var 섹션"과 달리, 임의의 문장 사이에서 바로 새 지역 변수를 만든다.)
  // 타입은 CodeGen이 ValueExpr을 통해 그때그때 추론한다.
  TInlineVarStmtNode = class(TStmtNode)
  public VarName: string; ValueExpr: TExprNode;
    constructor Create(n: string; v: TExprNode);
    begin VarName:=n; ValueExpr:=v; end;
  end;

  // try ... except on E: ExType do <stmt> end
  // ExVarName='' 이면 except (on 없이) 또는 finally
  TTryStmtNode = class(TStmtNode)
  public
    BodyStmts:    List<TStmtNode>; // try 블록 본문
    ExVarName:    string;          // on E: Exception do 의 E (없으면 '')
    ExTypeName:   string;          // Exception 클래스 이름 (없으면 '')
    ExceptStmts:  List<TStmtNode>; // except 블록 본문 (없으면 nil)
    FinallyStmts: List<TStmtNode>; // finally 블록 본문 (없으면 nil)
    constructor Create;
    begin
      BodyStmts:=new List<TStmtNode>;
      ExVarName:=''; ExTypeName:='';
      ExceptStmts:=nil; FinallyStmts:=nil;
    end;
  end;

  // raise <식>; 또는 raise; (재발생 — Expr=nil)
  TRaiseStmtNode = class(TStmtNode)
  public Expr: TExprNode; // nil이면 reraise
    constructor Create(e: TExprNode); begin Expr:=e; end;
  end;

  // [Stage 30] inherited MethodName(args...); 또는 inherited;  — 문장으로 쓰이는 경우
  // (프로시저: 반환값 없음/버림). bare 'inherited;'는 파서 단계에서 현재 메서드와
  // 같은 이름 + 같은 매개변수를 그대로 전달하는 형태로 즉시 확장되어 채워진다.
  TInheritedCallStmtNode = class(TStmtNode)
  public MethodName: string; Args: List<TExprNode>;
    constructor Create(mn: string); begin MethodName:=mn; Args:=new List<TExprNode>; end;
  end;

  // E.Message (예외 변수의 Message 프로퍼티)
  TExceptionMsgExprNode = class(TExprNode)
  public VarName: string;
    constructor Create(v: string); begin VarName:=v; end;
  end;

  // TypeName.MemberName  (정적 필드/속성 읽기, 예: System.EventArgs.Empty)
  // TypeName은 점(.)으로 연결된 외부 타입 전체 경로.
  TStaticMemberExprNode = class(TExprNode)
  public TypeName: string; MemberName: string;
    constructor Create(t, m: string); begin TypeName:=t; MemberName:=m; end;
  end;

  // [Stage 75] obj.GetType.FullName 또는 obj.GetType.Name — 예외 진단(ex.GetType.FullName 등)에서
  // 흔히 쓰이는 관용구. obj는 지역/전역 변수(주로 except 블록의 예외 변수)이고, GetType은
  // 괄호 없이 호출되는 인스턴스 메서드, 그 결과(System.Type)의 FullName 또는 Name을 읽는다.
  // 점(.) 3단계 체인이지만 첫 세그먼트가 "타입 이름"이 아니라 변수이므로 TStaticMemberExprNode와는
  // 다른 전용 노드로 분리했다 (파서가 obj.GetType.FullName을 정적 타입 경로로 오인하던 버그 수정).
  TRuntimeTypeNameExprNode = class(TExprNode)
  public VarName: string; WantFullName: boolean; // false면 .Name, true면 .FullName
    constructor Create(v: string; full: boolean); begin VarName:=v; WantFullName:=full; end;
  end;

  // ----------------------------------------------------------
  // AST — 클래스 선언 관련
  // ----------------------------------------------------------
  TParamDef = class
  public Name: string; ParamType: TVarType;
    // [Stage 31] ParamType=vtObject/vtInterface일 때만 의미 있음 (지역 클래스/인터페이스 또는 외부 타입 이름).
    // [Stage 36] ParamType=vtGeneric일 때는 이 매개변수가 참조하는 타입 매개변수 이름(예: 'T')을 담는다.
    ClassName: string;
    IsExternal: boolean; // [Stage 31] true면 ClassName이 외부 .NET 타입 이름
    constructor Create(n: string; t: TVarType); overload;
    begin Name:=n; ParamType:=t; ClassName:=''; IsExternal:=false; end;
    constructor Create(n: string; t: TVarType; cn: string; isExt: boolean); overload;
    begin Name:=n; ParamType:=t; ClassName:=cn; IsExternal:=isExt; end;
  end;

  // [Stage 64] Button1.Click += (a: T1; b: T2) -> 문장;  형태의 인라인 람다.
  // LamParams: 매개변수 목록(타입 명시 필수). Body: 본문 문장 하나(begin...end 블록 금지).
  TLambdaExprNode = class
  public LamParams: List<TParamDef>; Body: TStmtNode;
    constructor Create(ps: List<TParamDef>; b: TStmtNode);
    begin LamParams:=ps; Body:=b; end;
  end;

  // Qualifier.EventName += HandlerName;  또는 Qualifier.EventName += (매개변수) -> 문장;
  // (예: Button1.Click += Button1_Click;  /  Button1.Click += (sender, e) -> ...;)
  // Lambda<>nil 이면 인라인 람다를 구독하며 HandlerName은 무시된다('').
  TEventSubscribeStmtNode = class(TStmtNode)
  public Qualifier: string; EventName: string; HandlerName: string;
    QualifierCastType: string; // ''이 아니면 Qualifier를 이 타입으로 캐스트 (예: TButton(sender).Click += ...)
    Lambda: TLambdaExprNode;   // nil이 아니면 인라인 람다 구독
    constructor Create(q, ev, h: string);
    begin
      Qualifier:=q; EventName:=ev; HandlerName:=h;
      QualifierCastType:=''; Lambda:=nil;
    end;
  end;

  // [Phase 1] 클래스 선언부 안의 프로퍼티 시그니처.
  // property X: T read FX write FX;
  // ReadName/WriteName 이 ''이면 해당 접근자 없음 (읽기 전용/쓰기 전용).
  TPropertySignature = class
  public
    Name: string;
    PropType: TVarType;
    PropClassName: string;  // PropType=vtObject/vtEnum일 때 타입 이름
    IsExternalType: boolean;
    ReadName: string;  // getter 필드/메서드 이름 ('' = 없음)
    WriteName: string; // setter 필드/메서드 이름 ('' = 없음)
    constructor Create(n: string; pt: TVarType);
    begin Name:=n; PropType:=pt; PropClassName:=''; IsExternalType:=false; ReadName:=''; WriteName:=''; end;
  end;

  TFieldDeclNode = class
  public
    Name: string; FieldType: TVarType;
    // FieldType=vtObject일 때: 지역 클래스 또는 외부 타입 이름.
    // FieldType=vtGeneric일 때: [Stage 32] 이 필드가 참조하는 타입 매개변수 이름 (예: 'K'/'V').
    ClassName: string;
    IsExternalType: boolean; // true면 ClassName이 외부 .NET 어셈블리의 타입 (예: System.Windows.Forms.Button)
    constructor Create(n: string; t: TVarType);
    begin Name:=n; FieldType:=t; ClassName:=''; IsExternalType:=false; end;
  end;

  TMethodSignature = class
  public
    Name: string;
    IsFunction: boolean;
    ReturnType: TVarType;
    ReturnGenericName: string;       // [Stage 32] ReturnType=vtGeneric일 때 어느 타입 매개변수(예: 'T'/'K'/'V')인지
    ParamNames: List<string>;
    ParamTypes: List<TVarType>;
    // ParamTypes[i]=vtObject일 때는 클래스/외부타입 이름, vtGeneric일 때는 [Stage 32] 타입 매개변수 이름(예: 'K')
    ParamClassNames: List<string>;
    ParamIsExternal: List<boolean>;  // true면 ParamClassNames[i]가 외부 .NET 타입
    // [Stage 53] virtual/override/abstract 지시자.
    // 이 컴파일러는 모든 인스턴스 메서드를 이미 Virtual+HideBySig로 정의하고 이름/시그니처
    // 일치로 자동 override(슬롯 재사용)하므로, IsVirtual/IsOverride는 지금 당장 코드생성
    // 동작을 바꾸지 않는다 — 파싱을 허용하고 의도를 기록해두는 정도. 반면 IsAbstract는
    // 실제로 동작이 다르다: 본문이 없어야 하고(구현을 파싱/요구하지 않음), CLR 메서드는
    // Abstract 플래그로 정의되며, 소유 클래스는 TypeAttributes.Abstract가 되어야 한다.
    IsVirtual: boolean;
    IsOverride: boolean;
    IsAbstract: boolean;
    // [Stage 74] 제네릭 메서드: function Wrap<T>(x: T): T; — 클래스 자체의 제네릭(TStack<T>)과는
    // 독립적인, 메서드 자신의 타입 매개변수. virtual/abstract와의 조합은 1차 제약으로 아직 미지원.
    IsGeneric: boolean;
    GenericParamNames: List<string>;
    GenericParamConstraints: List<string>;
    constructor Create(n: string; isFunc: boolean; ret: TVarType);
    begin
      Name:=n; IsFunction:=isFunc; ReturnType:=ret; ReturnGenericName:='';
      ParamNames:=new List<string>; ParamTypes:=new List<TVarType>;
      ParamClassNames:=new List<string>; ParamIsExternal:=new List<boolean>;
      IsVirtual:=false; IsOverride:=false; IsAbstract:=false;
      IsGeneric:=false; GenericParamNames:=new List<string>; GenericParamConstraints:=new List<string>;
    end;
  end;

  TClassDeclNode = class
  public
    Name: string;
    ParentName: string; // 부모 클래스 이름 ('' 이면 상속 없음, 암묵적으로 System.Object)
    IsExternalParent: boolean; // true면 ParentName이 외부 .NET 어셈블리의 타입 (예: System.Windows.Window)
    InterfaceName: string; // 구현하는 인터페이스 이름 ('' 이면 없음). ParentName과 양자택일.
    Fields: List<TFieldDeclNode>;
    Methods: List<TMethodSignature>;
    IsGeneric: boolean;       // true면 "TStack<T> = class" / "TPair<K,V> = class" 형태의 제네릭 템플릿 선언
    // [Stage 32] 제네릭 타입 매개변수 이름 목록 (예: TStack<T> → ['T'], TPair<K,V> → ['K','V']).
    // 선언 순서가 TGenericInstantiation.ArgTypes/ArgClassNames의 인덱스와 대응된다. IsGeneric=false면 빈 목록.
    GenericParamNames: List<string>;
    // [Stage 34] GenericParamNames와 같은 인덱스로 대응하는 제약조건.
    // ''(빈 문자열)이면 제약 없음. 'class'면 참조 타입(임의의 클래스)만 허용.
    // 그 외 값이면 해당 이름의 클래스/인터페이스를 상속·구현해야 함 (예: 'TAnimal', 'IComparable').
    GenericParamConstraints: List<string>;
    // [Stage 42] 클래스 선언부에 "constructor Create;"가 있었으면 true.
    // true면 BuildClassShell이 기본(부모 생성자만 호출하는) 생성자 본문을 즉시 채우지 않고,
    // 이후 ConstructorImpls에서 사용자가 작성한 본문을 채워 넣을 때까지 비워 둔다.
    HasUserConstructor: boolean;
    ConstructorParams: List<TParamDef>; // [Stage 47] constructor Create(a: integer; ...) 매개변수 목록. 없으면 빈 목록.
    Properties: List<TPropertySignature>; // [Phase 1] property 선언 목록
    constructor Create(n: string);
    begin
      Name:=n; ParentName:=''; IsExternalParent:=false; InterfaceName:='';
      Fields:=new List<TFieldDeclNode>; Methods:=new List<TMethodSignature>;
      IsGeneric:=false; GenericParamNames:=new List<string>; GenericParamConstraints:=new List<string>;
      HasUserConstructor:=false;
      ConstructorParams:=new List<TParamDef>; // [Stage 47]
      Properties:=new List<TPropertySignature>; // [Phase 1]
    end;
  end;

  // Monomorphize 단계가 처리해야 할 "제네릭 인스턴스화 요청" 하나.
  // Parser가 소스에서 TStack<integer> 또는 TPair<integer,string> 같은 사용을 만날 때마다 등록하고,
  // Monomorphize.TMonomorphizer가 이를 소비해 실제 구체 클래스를 합성한다.
  // [Stage 32] 타입 인자가 하나 이상일 수 있으므로 ArgType/ArgClassName 단일 필드 대신 목록으로 관리하며,
  // 인덱스는 템플릿의 GenericParamNames 순서와 대응된다 (0번째 인자 → 0번째 타입 매개변수).
  TGenericInstantiation = class
  public
    TemplateName: string;  // 제네릭 템플릿 이름 (예: 'TStack', 'TPair')
    ConcreteName: string;  // 합성될 구체 클래스 이름 (예: 'TStack_integer', 'TPair_integer_string')
    ArgTypes: List<TVarType>;    // 타입 인자별로 기본형이면 vtInteger/vtString/vtBoolean, 클래스(중첩 제네릭 포함)면 vtObject
    ArgClassNames: List<string>; // ArgTypes[i]=vtObject일 때 그 클래스 이름(단형화된 이름 포함), 아니면 ''
    constructor Create(tn, cnm: string; ats: List<TVarType>; acns: List<string>);
    begin TemplateName:=tn; ConcreteName:=cnm; ArgTypes:=ats; ArgClassNames:=acns; end;
  end;

  // [Phase 1] 열거형 선언: type TColor = (Red, Green, Blue);
  // CLR에서 System.Enum을 상속하는 int32 기반 enum 타입으로 방출된다.
  TEnumDeclNode = class
  public
    Name: string;
    Members: List<string>; // 선언 순서대로 0, 1, 2, ... 값에 대응
    constructor Create(n: string);
    begin Name:=n; Members:=new List<string>; end;
  end;

  // [Stage 62] 레코드 선언: type TPoint = record X, Y: integer; end;
  // 클래스(TClassDeclNode)와 달리 값 타입(System.ValueType 상속)으로 CodeGen이 빌드하며,
  // 그래서 대입/매개변수 전달 시 CLR이 필드 전체를 복사해준다(값 타입 의미론).
  // 이번 단계에서는 필드만 지원한다 — 메서드/생성자/프로퍼티/상속은 클래스의 몫으로 남겨둔다.
  // 필드 타입도 기본 타입(integer/string/boolean/real/char/int64)·열거형·외부 .NET 타입만
  // 허용한다(지역 클래스/인터페이스/다른 레코드를 필드로 담는 것은 CodeGen의 빌드 순서
  // 문제 때문에 아직 지원하지 않음 — Parser가 명확한 오류로 막는다).
  TRecordDeclNode = class
  public
    Name: string;
    Fields: List<TFieldDeclNode>;
    constructor Create(n: string);
    begin Name:=n; Fields:=new List<TFieldDeclNode>; end;
  end;

  // 인터페이스 선언 (메서드 시그니처만, 본문 없음)
  TInterfaceDeclNode = class
  public
    Name: string;
    Methods: List<TMethodSignature>;
    constructor Create(n: string);
    begin Name:=n; Methods:=new List<TMethodSignature>; end;
  end;

  // ----------------------------------------------------------
  // 변수/매개변수 선언
  // ----------------------------------------------------------
  TVarDecl = class
  public Name: string; VarType: TVarType; ClassName: string;
    // [Stage 41] VarType=vtObject일 때만 의미 있음. true면 ClassName이 점(.)으로 연결된
    // 외부 .NET 타입 이름(예: System.Text.StringBuilder) — TParamDef.IsExternal과 동일한 역할.
    IsExternal: boolean;
    constructor Create(n: string; t: TVarType; cn: string); overload;
    begin Name:=n; VarType:=t; ClassName:=cn; IsExternal:=false; end;
    constructor Create(n: string; t: TVarType; cn: string; isExt: boolean); overload;
    begin Name:=n; VarType:=t; ClassName:=cn; IsExternal:=isExt; end;
  end;

  // [Stage 61] const 선언 (전역/지역). "const Name = 식;" 형태는 식으로부터 타입을 추론하고
  // (TVarDeclStmtNode/TInlineVarStmtNode의 "var x := 식"과 같은 InferType 경로를 그대로 재사용),
  // "const Name: Type = 식;" 형태는 명시된 타입을 그대로 쓴다(HasExplicitType=true).
  // 값은 CodeGen이 선언 직후 한 번 대입해 초기화하는 일반 슬롯으로 구현하며(재대입 금지 검사는
  // 아직 하지 않음), 전역 const는 var와 마찬가지로 사실상 Main 메서드의 로컬 슬롯이 된다.
  TConstDecl = class
  public
    Name: string; VarType: TVarType; ClassName: string; IsExternal: boolean;
    ValueExpr: TExprNode; HasExplicitType: boolean;
    // 타입 추론: const Name = 식;
    constructor Create(n: string; ve: TExprNode); overload;
    begin
      Name:=n; ValueExpr:=ve; VarType:=vtInteger; ClassName:=''; IsExternal:=false;
      HasExplicitType:=false;
    end;
    // 명시적 타입: const Name: Type = 식;
    constructor Create(n: string; t: TVarType; cn: string; isExt: boolean; ve: TExprNode); overload;
    begin
      Name:=n; VarType:=t; ClassName:=cn; IsExternal:=isExt; ValueExpr:=ve;
      HasExplicitType:=true;
    end;
  end;

  // 클래스 메서드 구현 (ClassName.MethodName 형태)
  TMethodImplNode = class
  public
    ClassName: string; MethodName: string;
    IsFunction: boolean; ReturnType: TVarType;
    ReturnGenericName: string; // [Stage 32] ReturnType=vtGeneric일 때 어느 타입 매개변수인지 (예: 'T'/'K'/'V')
    ParamNames: List<string>; ParamTypes: List<TVarType>;
    ParamGenericNames: List<string>; // [Stage 32] ParamTypes[i]=vtGeneric일 때 그 타입 매개변수 이름, 아니면 ''
    LocalVars: List<TVarDecl>; // [Stage 28] 메서드 본문 안의 지역 변수 선언(var 섹션)
    ConstDecls: List<TConstDecl>; // [Stage 61] 메서드 본문 안의 지역 const 선언
    // [Stage 74] 메서드 자신의 제네릭 타입 매개변수(선언부 TMethodSignature.IsGeneric과 대응,
    // 구현부에서도 "procedure TFoo.Bar<T>(...)"처럼 다시 적어줘야 한다).
    IsGeneric: boolean;
    GenericParamNames: List<string>;
    GenericParamConstraints: List<string>;
    Body: TCompoundStmtNode;
    constructor Create(cn, mn: string; isFunc: boolean; ret: TVarType);
    begin
      ClassName:=cn; MethodName:=mn; IsFunction:=isFunc; ReturnType:=ret; ReturnGenericName:='';
      ParamNames:=new List<string>; ParamTypes:=new List<TVarType>;
      ParamGenericNames:=new List<string>;
      LocalVars:=new List<TVarDecl>;
      ConstDecls:=new List<TConstDecl>; // [Stage 61]
      IsGeneric:=false; GenericParamNames:=new List<string>; GenericParamConstraints:=new List<string>;
    end;
  end;

  // [Stage 42] 클래스 생성자 구현: constructor ClassName.Create; begin ... end;
  // [Stage 47] 매개변수 있는 생성자도 지원 (constructor ClassName.Create(a: integer); ...).
  // 본문 안에서 "inherited Create(...)"(부모 생성자 호출)와 암시적 self 메서드 호출(예: InitializeComponent;)을 쓸 수 있다.
  TConstructorImplNode = class
  public
    ClassName: string;
    Parameters: List<TParamDef>; // [Stage 47]
    LocalVars: List<TVarDecl>;
    ConstDecls: List<TConstDecl>; // [Stage 61]
    Body: TCompoundStmtNode;
    constructor Create(cn: string);
    begin ClassName:=cn; Parameters:=new List<TParamDef>; LocalVars:=new List<TVarDecl>; ConstDecls:=new List<TConstDecl>; end;
  end;

  // [Stage 65] TFuncDeclNode.NestedProcs가 아직 정의되지 않은 TProcDeclNode를 미리 참조해야 하고,
  // 반대로 TProcDeclNode.NestedFuncs도 TFuncDeclNode를 참조한다 — 서로가 서로를 참조하는 상호
  // 참조 관계라 어느 한쪽을 먼저 완전히 정의해도 다른 한쪽이 걸린다. 전방 선언으로 해결한다.
  TProcDeclNode = class;

  TFuncDeclNode = class
  public Name: string; Parameters: List<TParamDef>;
    ReturnType: TVarType; Body: TCompoundStmtNode;
    LocalVars: List<TVarDecl>; // [Stage 28] 함수 본문 안의 지역 변수 선언(var 섹션)
    ConstDecls: List<TConstDecl>; // [Stage 61] 함수 본문 안의 지역 const 선언
    // [Stage 36] 최상위 제네릭 함수: function Identity<T>(x: T): T;
    IsGeneric: boolean;
    GenericParamNames: List<string>;       // 예: ['T'] 또는 ['K','V']. IsGeneric=false면 빈 목록.
    GenericParamConstraints: List<string>; // GenericParamNames와 인덱스 대응. ''=제약없음, 'class'=참조타입, 그 외=클래스/인터페이스 이름
    ReturnGenericName: string;             // ReturnType=vtGeneric일 때 어느 타입 매개변수인지 (예: 'T')
    // [Stage 65, 1차] 이 함수 본문 안에 선언된 지역(중첩) 함수/프로시저. 한 겹만 허용되므로
    // NestedFuncs/NestedProcs 안의 항목들은 자기 자신의 NestedFuncs/NestedProcs가 항상 비어 있다.
    // 캡처(클로저) 없음 — Name은 이미 파서 단계에서 "바깥이름$지역이름"으로 맹글링되어 있다.
    NestedFuncs: List<TFuncDeclNode>;
    NestedProcs: List<TProcDeclNode>;
    // [Stage 69] "function Name(...): sequence of T;"로 선언된 함수. true면 ReturnType은 무시하고
    // IterElemType(T)만 쓴다 — CodeGen이 이 함수를 평범한 static 메서드가 아니라 yield 상태
    // 머신(숨은 __IterN 클래스: IEnumerable<T>/IEnumerator<T> 구현)으로 컴파일한다.
    IsIterator: boolean;
    IterElemType: TVarType; // integer/string/boolean/real/char/int64 중 하나만 지원 (1차 제약)
    constructor Create(n: string);
    begin
      Name:=n; Parameters:=new List<TParamDef>; LocalVars:=new List<TVarDecl>;
      ConstDecls:=new List<TConstDecl>; // [Stage 61]
      IsGeneric:=false; GenericParamNames:=new List<string>; GenericParamConstraints:=new List<string>;
      ReturnGenericName:='';
      NestedFuncs:=new List<TFuncDeclNode>; NestedProcs:=new List<TProcDeclNode>; // [Stage 65]
      IsIterator:=false; IterElemType:=vtInteger; // [Stage 69]
    end;
  end;

  TProcDeclNode = class
  public Name: string; Parameters: List<TParamDef>; Body: TCompoundStmtNode;
    LocalVars: List<TVarDecl>; // [Stage 28] 프로시저 본문 안의 지역 변수 선언(var 섹션)
    ConstDecls: List<TConstDecl>; // [Stage 61] 프로시저 본문 안의 지역 const 선언
    // [Stage 36] 최상위 제네릭 프로시저: procedure PrintBoth<T>(a, b: T);
    IsGeneric: boolean;
    GenericParamNames: List<string>;
    GenericParamConstraints: List<string>;
    // [Stage 65, 1차] TFuncDeclNode.NestedFuncs/NestedProcs와 동일한 규칙(한 겹, 캡처 없음).
    NestedFuncs: List<TFuncDeclNode>;
    NestedProcs: List<TProcDeclNode>;
    constructor Create(n: string);
    begin
      Name:=n; Parameters:=new List<TParamDef>; LocalVars:=new List<TVarDecl>;
      ConstDecls:=new List<TConstDecl>; // [Stage 61]
      IsGeneric:=false; GenericParamNames:=new List<string>; GenericParamConstraints:=new List<string>;
      NestedFuncs:=new List<TFuncDeclNode>; NestedProcs:=new List<TProcDeclNode>; // [Stage 65]
    end;
  end;

  // [Stage 36] Monomorphize 단계가 처리해야 할 "제네릭 함수/프로시저 인스턴스화 요청" 하나.
  // Parser가 소스에서 Identity<integer>(5) 같은 명시적 타입 인자 호출을 만날 때마다 등록하고,
  // Monomorphize.TMonomorphizer가 이를 소비해 실제 구체 TFuncDeclNode/TProcDeclNode를 합성한다.
  // 구조는 TGenericInstantiation(클래스용)과 동일하며 IsProc으로 함수/프로시저를 구분한다.
  TGenericFuncInstantiation = class
  public
    TemplateName: string;  // 제네릭 템플릿 이름 (예: 'Identity', 'Swap')
    ConcreteName: string;  // 합성될 구체 함수/프로시저 이름 (예: 'Identity_integer')
    IsProc: boolean;       // true면 프로시저, false면 함수
    ArgTypes: List<TVarType>;
    ArgClassNames: List<string>;
    constructor Create(tn, cnm: string; isP: boolean; ats: List<TVarType>; acns: List<string>);
    begin TemplateName:=tn; ConcreteName:=cnm; IsProc:=isP; ArgTypes:=ats; ArgClassNames:=acns; end;
  end;

  // [Stage 66] 연산자 오버로딩: operator +(a, b: TVector): TVector; 형태의 선언 하나.
  // Parser는 파싱한 본문을 맹글링된 이름(예: 'operator$add$TVector')의 평범한 최상위
  // 함수로 TProgramNode.FuncDecls에도 함께 등록한다 — 이 레코드는 "연산자 기호 + 피연산자
  // 타입 이름 → 그 맹글링된 함수 이름"이라는 매핑 하나만 담는다. CodeGen은 TBinOpNode의
  // 양쪽 피연산자가 같은 레코드/클래스 타입이고 그 조합의 오버로드가 등록되어 있으면
  // 산술 연산(Add/Sub/...) 대신 이 함수 호출로 대체한다.
  // (현재는 "같은 타입끼리 연산해 같은 타입을 돌려주는" 대칭형 +, -, *, /만 지원 — 서로 다른
  // 타입 간의 혼합 연산이나 비교 연산자(=, <>) 오버로딩은 이번 단계 범위 밖이다.)
  TOperatorOverloadNode = class
  public
    OpSymbol: string; // '+', '-', '*', '/'
    TypeName: string; // 피연산자(=반환값) 클래스/레코드 이름
    FuncName: string; // 맹글링된 최상위 함수 이름
    constructor Create(op, tn, fn: string);
    begin OpSymbol:=op; TypeName:=tn; FuncName:=fn; end;
  end;


  TProgramNode = class
  public
    Name: string;
    InterfaceDecls: List<TInterfaceDeclNode>;
    ClassDecls:  List<TClassDeclNode>;
    MethodImpls: List<TMethodImplNode>;
    ConstructorImpls: List<TConstructorImplNode>; // [Stage 42]
    FuncDecls:   List<TFuncDeclNode>;
    ProcDecls:   List<TProcDeclNode>;
    VarDecls:    List<TVarDecl>;
    ConstDecls:  List<TConstDecl>; // [Stage 61] 전역 const 선언
    Statements:  List<TStmtNode>;
    GenericInstantiations: List<TGenericInstantiation>; // Parser가 채우고 Monomorphize가 소비
    GenericFuncInstantiations: List<TGenericFuncInstantiation>; // [Stage 36] 함수/프로시저용, 동일한 방식
    IsLibrary: boolean; // [Stage 44] true면 "library Name;"으로 시작 — exe 대신 dll로 생성, begin...end 블록 생략 가능
    AppType: string; // [Stage 69] {$apptype windows|console} 지시문. 기본 'console'. 'windows'면 콘솔창 없이 실행되는 PE로 생성.
    EnumDecls: List<TEnumDeclNode>; // [Phase 1] 열거형 선언 목록
    RecordDecls: List<TRecordDeclNode>; // [Stage 62] 레코드 선언 목록
    OperatorOverloads: List<TOperatorOverloadNode>; // [Stage 66] 연산자 오버로딩 목록
    constructor Create(n: string);
    begin
      Name:=n;
      InterfaceDecls:=new List<TInterfaceDeclNode>;
      ClassDecls:=new List<TClassDeclNode>;
      MethodImpls:=new List<TMethodImplNode>;
      ConstructorImpls:=new List<TConstructorImplNode>; // [Stage 42]
      FuncDecls:=new List<TFuncDeclNode>;
      ProcDecls:=new List<TProcDeclNode>;
      VarDecls:=new List<TVarDecl>;
      ConstDecls:=new List<TConstDecl>; // [Stage 61]
      Statements:=new List<TStmtNode>;
      GenericInstantiations:=new List<TGenericInstantiation>;
      GenericFuncInstantiations:=new List<TGenericFuncInstantiation>;
      IsLibrary:=false;
      AppType:='console'; // [Stage 69]
      EnumDecls:=new List<TEnumDeclNode>; // [Phase 1]
      RecordDecls:=new List<TRecordDeclNode>; // [Stage 62]
      OperatorOverloads:=new List<TOperatorOverloadNode>; // [Stage 66]
    end;
  end;


implementation

end.