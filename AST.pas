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
              vtReal, vtChar, vtInt64, vtEnum);
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
    constructor Create(obj, mth: string);
    begin ObjName:=obj; MethodName:=mth; Args:=new List<TExprNode>; ObjCastType:=''; end;
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

  TFuncCallExprNode = class(TExprNode)
  public FuncName: string; Args: List<TExprNode>;
    constructor Create(n: string); begin FuncName:=n; Args:=new List<TExprNode>; end;
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

  // c.Init(10); 인스턴스 메서드 호출 (반환값 없는 프로시저)
  TMethodCallStmtNode = class(TStmtNode)
  public ObjName: string; MethodName: string; Args: List<TExprNode>;
    ObjCastType: string; // ''이 아니면 ObjName을 이 타입으로 캐스트한 뒤 멤버에 접근 (예: TButton(sender).Focus)
    constructor Create(obj, mth: string);
    begin ObjName:=obj; MethodName:=mth; Args:=new List<TExprNode>; ObjCastType:=''; end;
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
  // HandlerName은 현재 클래스의 인스턴스 메서드 이름이어야 한다 (델리게이트로 감싸짐).
  TEventSubscribeStmtNode = class(TStmtNode)
  public Qualifier: string; EventName: string; HandlerName: string;
    QualifierCastType: string; // ''이 아니면 Qualifier를 이 타입으로 캐스트
    constructor Create(q, ev, h: string);
    begin Qualifier:=q; EventName:=ev; HandlerName:=h; QualifierCastType:=''; end;
  end;

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
    constructor Create(n: string; isFunc: boolean; ret: TVarType);
    begin
      Name:=n; IsFunction:=isFunc; ReturnType:=ret; ReturnGenericName:='';
      ParamNames:=new List<string>; ParamTypes:=new List<TVarType>;
      ParamClassNames:=new List<string>; ParamIsExternal:=new List<boolean>;
      IsVirtual:=false; IsOverride:=false; IsAbstract:=false;
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

  // 클래스 메서드 구현 (ClassName.MethodName 형태)
  TMethodImplNode = class
  public
    ClassName: string; MethodName: string;
    IsFunction: boolean; ReturnType: TVarType;
    ReturnGenericName: string; // [Stage 32] ReturnType=vtGeneric일 때 어느 타입 매개변수인지 (예: 'T'/'K'/'V')
    ParamNames: List<string>; ParamTypes: List<TVarType>;
    ParamGenericNames: List<string>; // [Stage 32] ParamTypes[i]=vtGeneric일 때 그 타입 매개변수 이름, 아니면 ''
    LocalVars: List<TVarDecl>; // [Stage 28] 메서드 본문 안의 지역 변수 선언(var 섹션)
    Body: TCompoundStmtNode;
    constructor Create(cn, mn: string; isFunc: boolean; ret: TVarType);
    begin
      ClassName:=cn; MethodName:=mn; IsFunction:=isFunc; ReturnType:=ret; ReturnGenericName:='';
      ParamNames:=new List<string>; ParamTypes:=new List<TVarType>;
      ParamGenericNames:=new List<string>;
      LocalVars:=new List<TVarDecl>;
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
    Body: TCompoundStmtNode;
    constructor Create(cn: string);
    begin ClassName:=cn; Parameters:=new List<TParamDef>; LocalVars:=new List<TVarDecl>; end;
  end;

  TFuncDeclNode = class
  public Name: string; Parameters: List<TParamDef>;
    ReturnType: TVarType; Body: TCompoundStmtNode;
    LocalVars: List<TVarDecl>; // [Stage 28] 함수 본문 안의 지역 변수 선언(var 섹션)
    // [Stage 36] 최상위 제네릭 함수: function Identity<T>(x: T): T;
    IsGeneric: boolean;
    GenericParamNames: List<string>;       // 예: ['T'] 또는 ['K','V']. IsGeneric=false면 빈 목록.
    GenericParamConstraints: List<string>; // GenericParamNames와 인덱스 대응. ''=제약없음, 'class'=참조타입, 그 외=클래스/인터페이스 이름
    ReturnGenericName: string;             // ReturnType=vtGeneric일 때 어느 타입 매개변수인지 (예: 'T')
    constructor Create(n: string);
    begin
      Name:=n; Parameters:=new List<TParamDef>; LocalVars:=new List<TVarDecl>;
      IsGeneric:=false; GenericParamNames:=new List<string>; GenericParamConstraints:=new List<string>;
      ReturnGenericName:='';
    end;
  end;

  TProcDeclNode = class
  public Name: string; Parameters: List<TParamDef>; Body: TCompoundStmtNode;
    LocalVars: List<TVarDecl>; // [Stage 28] 프로시저 본문 안의 지역 변수 선언(var 섹션)
    // [Stage 36] 최상위 제네릭 프로시저: procedure PrintBoth<T>(a, b: T);
    IsGeneric: boolean;
    GenericParamNames: List<string>;
    GenericParamConstraints: List<string>;
    constructor Create(n: string);
    begin
      Name:=n; Parameters:=new List<TParamDef>; LocalVars:=new List<TVarDecl>;
      IsGeneric:=false; GenericParamNames:=new List<string>; GenericParamConstraints:=new List<string>;
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
    Statements:  List<TStmtNode>;
    GenericInstantiations: List<TGenericInstantiation>; // Parser가 채우고 Monomorphize가 소비
    GenericFuncInstantiations: List<TGenericFuncInstantiation>; // [Stage 36] 함수/프로시저용, 동일한 방식
    IsLibrary: boolean; // [Stage 44] true면 "library Name;"으로 시작 — exe 대신 dll로 생성, begin...end 블록 생략 가능
    EnumDecls: List<TEnumDeclNode>; // [Phase 1] 열거형 선언 목록
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
      Statements:=new List<TStmtNode>;
      GenericInstantiations:=new List<TGenericInstantiation>;
      GenericFuncInstantiations:=new List<TGenericFuncInstantiation>;
      IsLibrary:=false;
      EnumDecls:=new List<TEnumDeclNode>; // [Phase 1]
    end;
  end;


implementation

end.