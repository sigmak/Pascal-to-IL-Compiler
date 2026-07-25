// ============================================================
// Test_stage80.pas — [Stage 80] 창 도킹/레이아웃 통합 검증:
//  1) SplitContainer 기반 자체 레이아웃으로 여러 패널(탐색기/에디터/출력)을 한 셸에 도킹
//     (DockPanelSuite 같은 외부 서드파티 어셈블리 대신, 이미 참조 중인
//      System.Windows.Forms.dll만으로 가능한 자체 레이아웃을 택함)
//  2) 창 간 상태 동기화 — 탐색기(TProjectExplorer) 트리에서 파일 노드를
//     더블클릭하면 에디터(TCodeEditorPanel)에 해당 파일이 열리고,
//     출력 패널(TOutputPanel)에 로그가 남는다.
//  3) 여러 클래스 인스턴스 간 상호 참조 + 이벤트 배선 안정성 —
//     TMainShell이 3개의 서로 다른 로컬 클래스(Explorer/Editor/Output) 필드를
//     동시에 갖고, 그 중 하나(Explorer)의 손자뻘 필드(Tree)에서 발생한 이벤트가
//     나머지 둘(Editor/Output)의 메서드를 순서대로 호출한다.
//
// [설계 메모] Stage 78에서 파일명(Text)만 저장했던 트리 노드에, 이번엔 전체
// 경로를 TreeNode.Name(문자열 속성, object 캐스팅 불필요)에 저장해서 더블클릭
// 시 바로 꺼내 쓴다 — Tag(object) 캐스팅 경로는 아직 검증된 적이 없어 피했다.
// ============================================================
program Test_stage80;

{$apptype console}
{$reference System.Windows.Forms.dll}
{$reference System.Drawing.dll}

type
  TProjectExplorer = class(System.Windows.Forms.Panel)
  private
    Tree: System.Windows.Forms.TreeView;
  public
    constructor Create;
    procedure LoadFolder(path: string);
  end;

  TCodeEditorPanel = class(System.Windows.Forms.Panel)
  private
    Tabs: System.Windows.Forms.TabControl;
  public
    constructor Create;
    procedure OpenFile(path: string);
  end;

  TOutputPanel = class(System.Windows.Forms.Panel)
  private
    LogBox: System.Windows.Forms.ListBox;
  public
    constructor Create;
    procedure Log(msg: string);
  end;

  TMainShell = class(System.Windows.Forms.Form)
  private
    MainSplit: System.Windows.Forms.SplitContainer;
    RightSplit: System.Windows.Forms.SplitContainer;
    Explorer: TProjectExplorer;
    Editor: TCodeEditorPanel;
    Output: TOutputPanel;
  public
    constructor Create(rootPath: string);
    procedure Explorer_Tree_DoubleClick;
  end;

// ------------------------------------------------------------
// TProjectExplorer
// ------------------------------------------------------------
constructor TProjectExplorer.Create;
begin
  inherited Create;
  Dock := System.Windows.Forms.DockStyle.Fill;

  Tree := new System.Windows.Forms.TreeView;
  Tree.Dock := System.Windows.Forms.DockStyle.Fill;
  Controls.Add(Tree);
end;

procedure TProjectExplorer.LoadFolder(path: string);
var
  root: System.Windows.Forms.TreeNode;
  fileNode: System.Windows.Forms.TreeNode;
  filePath: string;
begin
  Tree.Nodes.Clear;
  root := Tree.Nodes.Add(path);

  for filePath in System.IO.Directory.GetFiles(path) do
  begin
    fileNode := root.Nodes.Add(System.IO.Path.GetFileName(filePath));
    // [검증 2] 파일 노드에 전체 경로를 Name 속성(문자열)으로 보관 —
    // 더블클릭 시 object/Tag 캐스팅 없이 바로 꺼내 쓰기 위함.
    fileNode.Name := filePath;
  end;

  root.Expand;
end;

// ------------------------------------------------------------
// TCodeEditorPanel
// ------------------------------------------------------------
constructor TCodeEditorPanel.Create;
begin
  inherited Create;
  Dock := System.Windows.Forms.DockStyle.Fill;

  Tabs := new System.Windows.Forms.TabControl;
  Tabs.Dock := System.Windows.Forms.DockStyle.Fill;
  Controls.Add(Tabs);
end;

procedure TCodeEditorPanel.OpenFile(path: string);
var
  content: string;
  fileName: string;
  page: System.Windows.Forms.TabPage;
  editor: System.Windows.Forms.RichTextBox;
  tabCount: integer;
begin
  content := System.IO.File.ReadAllText(path);
  fileName := System.IO.Path.GetFileName(path);

  page := new System.Windows.Forms.TabPage;
  page.Text := fileName;

  editor := new System.Windows.Forms.RichTextBox;
  editor.Dock := System.Windows.Forms.DockStyle.Fill;
  editor.Text := content;

  page.Controls.Add(editor);
  Tabs.TabPages.Add(page);
  Tabs.SelectedTab := page;

  tabCount := Tabs.TabPages.Count;
  Writeln('[진단] 에디터: 파일 열림 ' + fileName + ' (' + content.Length + '자, 탭 수=' + tabCount + ')');
end;

// ------------------------------------------------------------
// TOutputPanel
// ------------------------------------------------------------
constructor TOutputPanel.Create;
begin
  inherited Create;
  Dock := System.Windows.Forms.DockStyle.Fill;

  LogBox := new System.Windows.Forms.ListBox;
  LogBox.Dock := System.Windows.Forms.DockStyle.Fill;
  Controls.Add(LogBox);
end;

procedure TOutputPanel.Log(msg: string);
begin
  LogBox.Items.Add(msg);
  Writeln(msg);
end;

// ------------------------------------------------------------
// TMainShell
// ------------------------------------------------------------
constructor TMainShell.Create(rootPath: string);
begin
  inherited Create;
  Text := 'Stage 80 — 도킹 셸 검증';
  Width := 1000;
  Height := 600;

  // [검증 1] SplitContainer 두 개를 중첩해 3분할 레이아웃 구성
  // (왼쪽: 탐색기 / 오른쪽 위: 에디터 / 오른쪽 아래: 출력)
  MainSplit := new System.Windows.Forms.SplitContainer;
  MainSplit.Dock := System.Windows.Forms.DockStyle.Fill;
  MainSplit.SplitterDistance := 250;

  RightSplit := new System.Windows.Forms.SplitContainer;
  RightSplit.Dock := System.Windows.Forms.DockStyle.Fill;
  RightSplit.Orientation := System.Windows.Forms.Orientation.Horizontal;
  RightSplit.SplitterDistance := 380;

  Explorer := new TProjectExplorer;
  Editor := new TCodeEditorPanel;
  Output := new TOutputPanel;

  MainSplit.Panel1.Controls.Add(Explorer);
  RightSplit.Panel1.Controls.Add(Editor);
  RightSplit.Panel2.Controls.Add(Output);
  MainSplit.Panel2.Controls.Add(RightSplit);

  Controls.Add(MainSplit);

  Explorer.LoadFolder(rootPath);

  // [검증 2/3] 탐색기의 손자뻘 필드(Explorer.Tree)에서 발생하는 이벤트를
  // 셸(TMainShell)이 직접 구독 — 다중 세그먼트 필드 체인을 통한 이벤트 배선.
  Explorer.Tree.DoubleClick += Explorer_Tree_DoubleClick;

  Output.Log('[진단] 셸 초기화 완료. 루트 = ' + rootPath);
end;

procedure TMainShell.Explorer_Tree_DoubleClick;
var
  selected: System.Windows.Forms.TreeNode;
  filePath: string;
begin
  selected := Explorer.Tree.SelectedNode;
  if selected <> nil then
  begin
    filePath := selected.Name;
    if filePath <> '' then
    begin
      // [검증 2/3] 탐색기(Explorer) → 에디터(Editor) → 출력(Output),
      // 서로 다른 3개의 로컬 클래스 인스턴스를 오가는 호출 체인.
      Editor.OpenFile(filePath);
      Output.Log('[진단] 탐색기 → 에디터: ' + filePath);
    end
    else
      Output.Log('[진단] 폴더 노드 더블클릭(파일 아님): ' + selected.Text);
  end;
end;

var
  shell: TMainShell;
  rootPath: string;
begin
  try
    System.Windows.Forms.Application.EnableVisualStyles();
    System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);

    rootPath := System.IO.Directory.GetCurrentDirectory();

    shell := new TMainShell(rootPath);
    System.Windows.Forms.Application.Run(shell);
  except
    on ex: Exception do
    begin
      Writeln('[진단] 예외 발생!');
      Writeln('타입: ' + ex.GetType.FullName);
      Writeln('메시지: ' + ex.Message);
      Writeln('스택: ' + ex.StackTrace);
    end;
  end;
  Writeln('[진단] 아무 키나 누르면 종료합니다...');
  Readln;
end.