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
  TVarType = (vtInteger, vtString, vtIntArray, vtStrArray, vtObject, vtInterface, vtBoolean);
  // vtObject: 클래스 인스턴스 (TCounter 등)
  // vtInterface: 인터페이스 타입 변수 (ISpeaker 등)
  // vtBoolean: boolean 타입 (true/false)

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

  TStrLiteralNode = class(TExprNode)
  public Value: string;
    constructor Create(v: string); begin Value:=v; end;
  end;

  TVarRefNode = class(TExprNode)
  public VarName: string;
    constructor Create(n: string); begin VarName:=n; end;
  end;

  TResultRefNode = class(TExprNode) end;

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
    constructor Create(cn: string); begin ClassName:=cn; IsExternalType:=false; end;
  end;

  // c.GetValue, c.Init(10) → 인스턴스 메서드 호출 (반환값 있음 → 식)
  TMethodCallExprNode = class(TExprNode)
  public ObjName: string; MethodName: string; Args: List<TExprNode>;
    constructor Create(obj, mth: string);
    begin ObjName:=obj; MethodName:=mth; Args:=new List<TExprNode>; end;
  end;

  // self.fValue 읽기 (메서드 본문 안에서 필드 참조)
  TFieldReadExprNode = class(TExprNode)
  public FieldName: string;
    constructor Create(f: string); begin FieldName:=f; end;
  end;

  TBinOpKind = (boAdd, boSub, boMul, boDiv, boMod, boAnd, boOr);
  TBinOpNode = class(TExprNode)
  public Op: TBinOpKind; Left, Right: TExprNode;
    constructor Create(op: TBinOpKind; l, r: TExprNode);
    begin Op:=op; Left:=l; Right:=r; end;
  end;

  TCompareKind = (cmpEq, cmpNeq, cmpLt, cmpGt, cmpLe, cmpGe);
  TCompareNode = class(TExprNode)
  public Op: TCompareKind; Left, Right: TExprNode;
    constructor Create(op: TCompareKind; l, r: TExprNode);
    begin Op:=op; Left:=l; Right:=r; end;
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
    constructor Create(obj, mth: string);
    begin ObjName:=obj; MethodName:=mth; Args:=new List<TExprNode>; end;
  end;

  // self.fValue := 식  (메서드 본문 안에서 필드 쓰기)
  // Qualifier=''  이면 self의 필드/속성. Qualifier<>'' 이면 그 이름의 필드를 통해
  // 접근하는 대상의 속성/필드 (예: Button1.Text := '...' → Qualifier='Button1', FieldName='Text')
  TFieldAssignStmtNode = class(TStmtNode)
  public FieldName: string; ValueExpr: TExprNode; Qualifier: string;
    constructor Create(f: string; v: TExprNode);
    begin FieldName:=f; ValueExpr:=v; Qualifier:=''; end;
  end;

  // Qualifier.EventName += HandlerName;  (예: Button1.Click += Button1_Click;)
  // HandlerName은 현재 클래스의 인스턴스 메서드 이름이어야 한다 (델리게이트로 감싸짐).
  TEventSubscribeStmtNode = class(TStmtNode)
  public Qualifier: string; EventName: string; HandlerName: string;
    constructor Create(q, ev, h: string);
    begin Qualifier:=q; EventName:=ev; HandlerName:=h; end;
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

  // E.Message (예외 변수의 Message 프로퍼티)
  TExceptionMsgExprNode = class(TExprNode)
  public VarName: string;
    constructor Create(v: string); begin VarName:=v; end;
  end;

  // ----------------------------------------------------------
  // AST — 클래스 선언 관련
  // ----------------------------------------------------------
  TFieldDeclNode = class
  public
    Name: string; FieldType: TVarType;
    ClassName: string;      // FieldType=vtObject일 때만 의미 있음 (지역 클래스 또는 외부 타입 이름)
    IsExternalType: boolean; // true면 ClassName이 외부 .NET 어셈블리의 타입 (예: System.Windows.Forms.Button)
    constructor Create(n: string; t: TVarType);
    begin Name:=n; FieldType:=t; ClassName:=''; IsExternalType:=false; end;
  end;

  TMethodSignature = class
  public
    Name: string;
    IsFunction: boolean;
    ReturnType: TVarType;
    ParamNames: List<string>;
    ParamTypes: List<TVarType>;
    ParamClassNames: List<string>;   // ParamTypes[i]=vtObject일 때만 의미 있음
    ParamIsExternal: List<boolean>;  // true면 ParamClassNames[i]가 외부 .NET 타입
    constructor Create(n: string; isFunc: boolean; ret: TVarType);
    begin
      Name:=n; IsFunction:=isFunc; ReturnType:=ret;
      ParamNames:=new List<string>; ParamTypes:=new List<TVarType>;
      ParamClassNames:=new List<string>; ParamIsExternal:=new List<boolean>;
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
    constructor Create(n: string);
    begin
      Name:=n; ParentName:=''; IsExternalParent:=false; InterfaceName:='';
      Fields:=new List<TFieldDeclNode>; Methods:=new List<TMethodSignature>;
    end;
  end;

  // 인터페이스 선언 (메서드 시그니처만, 본문 없음)
  TInterfaceDeclNode = class
  public
    Name: string;
    Methods: List<TMethodSignature>;
    constructor Create(n: string);
    begin Name:=n; Methods:=new List<TMethodSignature>; end;
  end;

  // 클래스 메서드 구현 (ClassName.MethodName 형태)
  TMethodImplNode = class
  public
    ClassName: string; MethodName: string;
    IsFunction: boolean; ReturnType: TVarType;
    ParamNames: List<string>; ParamTypes: List<TVarType>;
    Body: TCompoundStmtNode;
    constructor Create(cn, mn: string; isFunc: boolean; ret: TVarType);
    begin
      ClassName:=cn; MethodName:=mn; IsFunction:=isFunc; ReturnType:=ret;
      ParamNames:=new List<string>; ParamTypes:=new List<TVarType>;
    end;
  end;

  // ----------------------------------------------------------
  // 변수/매개변수 선언
  // ----------------------------------------------------------
  TVarDecl = class
  public Name: string; VarType: TVarType; ClassName: string;
    constructor Create(n: string; t: TVarType; cn: string);
    begin Name:=n; VarType:=t; ClassName:=cn; end;
  end;

  TParamDef = class
  public Name: string; ParamType: TVarType;
    constructor Create(n: string; t: TVarType); begin Name:=n; ParamType:=t; end;
  end;

  TFuncDeclNode = class
  public Name: string; Parameters: List<TParamDef>;
    ReturnType: TVarType; Body: TCompoundStmtNode;
    constructor Create(n: string);
    begin Name:=n; Parameters:=new List<TParamDef>; end;
  end;

  TProcDeclNode = class
  public Name: string; Parameters: List<TParamDef>; Body: TCompoundStmtNode;
    constructor Create(n: string);
    begin Name:=n; Parameters:=new List<TParamDef>; end;
  end;

  TProgramNode = class
  public
    Name: string;
    InterfaceDecls: List<TInterfaceDeclNode>;
    ClassDecls:  List<TClassDeclNode>;
    MethodImpls: List<TMethodImplNode>;
    FuncDecls:   List<TFuncDeclNode>;
    ProcDecls:   List<TProcDeclNode>;
    VarDecls:    List<TVarDecl>;
    Statements:  List<TStmtNode>;
    constructor Create(n: string);
    begin
      Name:=n;
      InterfaceDecls:=new List<TInterfaceDeclNode>;
      ClassDecls:=new List<TClassDeclNode>;
      MethodImpls:=new List<TMethodImplNode>;
      FuncDecls:=new List<TFuncDeclNode>;
      ProcDecls:=new List<TProcDeclNode>;
      VarDecls:=new List<TVarDecl>;
      Statements:=new List<TStmtNode>;
    end;
  end;


implementation

end.