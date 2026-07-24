// ============================================================
// Test_stage78.pas — [Stage 78] 프로젝트 탐색기 패널 검증:
//  1) TreeView/TreeNode 생성 및 계층 추가 (Nodes.Add 체인 반환값 캡처)
//  2) 자식 패널(TProjectExplorer)이 소유한 TreeView의 DoubleClick 이벤트를
//     부모(TMainForm)가 필드 체인(Explorer.Tree)으로 직접 구독 —
//     커스텀 델리게이트/이벤트 선언 없이 "다른 창으로 이벤트 전달" 구현
//  3) System.IO.Directory.GetFiles / System.IO.Path.GetFileName 호출
//  4) 외부 컬렉션 인덱서: Tree.Nodes[0]
// ============================================================
program Test_stage78;

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

  TMainForm = class(System.Windows.Forms.Form)
  private
    Explorer: TProjectExplorer;
    MainStatusBar: System.Windows.Forms.StatusStrip;
    StatusLabel: System.Windows.Forms.ToolStripStatusLabel;
  public
    constructor Create;
    procedure Explorer_Tree_DoubleClick;
  end;

// ------------------------------------------------------------
// TProjectExplorer
// ------------------------------------------------------------
constructor TProjectExplorer.Create;
begin
  inherited Create;
  Dock := System.Windows.Forms.DockStyle.Left;
  Width := 240;

  Tree := new System.Windows.Forms.TreeView;
  Tree.Dock := System.Windows.Forms.DockStyle.Fill;
  Controls.Add(Tree);
end;

procedure TProjectExplorer.LoadFolder(path: string);
var
  root: System.Windows.Forms.TreeNode;
  fileNode: System.Windows.Forms.TreeNode;
  firstNode: System.Windows.Forms.TreeNode;
  filePath: string;
begin
  Tree.Nodes.Clear;

  // [검증 1] 계층 추가 — Nodes.Add 반환값(TreeNode)을 미리 선언한 변수에 캡처
  root := Tree.Nodes.Add(path);

  // [검증 3] System.IO 네임스페이스 정적 호출 + for-in 순회
  for filePath in System.IO.Directory.GetFiles(path) do
  begin
    fileNode := root.Nodes.Add(System.IO.Path.GetFileName(filePath));
  end;

  root.Expand;

  // [검증 4] 외부 컬렉션 인덱서
  if Tree.Nodes.Count > 0 then
  begin
    firstNode := Tree.Nodes[0];
    Writeln('[진단] 인덱서 검증 — Nodes[0].Text = ' + firstNode.Text);
  end;
end;

// ------------------------------------------------------------
// TMainForm
// ------------------------------------------------------------
constructor TMainForm.Create;
begin
  inherited Create;
  Text := 'Stage 78 — 프로젝트 탐색기 검증';
  Width := 700;
  Height := 420;

  Explorer := new TProjectExplorer;
  Controls.Add(Explorer);

  MainStatusBar := new System.Windows.Forms.StatusStrip;
  StatusLabel := new System.Windows.Forms.ToolStripStatusLabel;
  StatusLabel.Text := 'Ready';
  MainStatusBar.Items.Add(StatusLabel);
  MainStatusBar.Dock := System.Windows.Forms.DockStyle.Bottom;
  Controls.Add(MainStatusBar);

  // [검증 2] 자식 패널이 소유한 필드(Explorer.Tree)의 이벤트를 부모가 필드 체인으로
  // 직접 구독 — 커스텀 이벤트/델리게이트 선언 없이 "다른 창으로 이벤트 전달"을 구현.
  Explorer.Tree.DoubleClick += Explorer_Tree_DoubleClick;

  Writeln('[진단] 메인 폼 구성 완료');

  // 실행 환경에 맞게 경로를 바꿔서 테스트하세요.
  Explorer.LoadFolder('D:\2026_Proj\PascalABC-CompilerHost\Pascal-to-IL-Compiler');
end;

procedure TMainForm.Explorer_Tree_DoubleClick;
var
  selected: System.Windows.Forms.TreeNode;
begin
  // [검증 2] 체인을 통한 프로퍼티 읽기 → 변수 캡처 → 부모 상태바 갱신
  selected := Explorer.Tree.SelectedNode;
  if selected <> nil then
  begin
    StatusLabel.Text := '파일 열기 요청: ' + selected.Text;
    Writeln('[진단] 더블클릭 → 파일 열기 요청: ' + selected.Text);
  end;
end;

var
  f: TMainForm;
begin
  try
    System.Windows.Forms.Application.EnableVisualStyles();
    System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);
    f := new TMainForm;
    System.Windows.Forms.Application.Run(f);
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