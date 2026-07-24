// ============================================================
// Test_stage77.pas — [Stage 77] 모달 다이얼로그 창 검증:
//  1) ShowDialog / DialogResult (enum 반환값)
//  2) 다이얼로그 → 부모 데이터 전달 (public 필드로 값 노출)
//  3) TextBox 값 읽기 + 빈 문자열 유효성 검사 → MessageBox.Show
//  4) enum 반환 타입 외부 메서드 호출 + 클래스 간 참조(TMainForm이
//     TNewProjectDialog를 필드 없이 지역변수로 new해서 사용)
// ============================================================
program Test_stage77;

{$apptype console}
{$reference System.Windows.Forms.dll}
{$reference System.Drawing.dll}

type
  TNewProjectDialog = class(System.Windows.Forms.Form)
  private
    lblName: System.Windows.Forms.Label;
    txtName: System.Windows.Forms.TextBox;
    btnOK: System.Windows.Forms.Button;
    btnCancel: System.Windows.Forms.Button;
  public
    ProjectName: string; // [검증 2] 다이얼로그 → 부모로 넘길 결과값 (public 필드)
    constructor Create;
    procedure btnOK_Click;
    procedure btnCancel_Click;
  end;

  TMainForm = class(System.Windows.Forms.Form)
  private
    MainMenu: System.Windows.Forms.MenuStrip;
    FileMenu: System.Windows.Forms.ToolStripMenuItem;
    NewMenuItem: System.Windows.Forms.ToolStripMenuItem;
    MainStatusBar: System.Windows.Forms.StatusStrip;
    StatusLabel: System.Windows.Forms.ToolStripStatusLabel;
  public
    constructor Create;
    procedure NewMenuItem_Click;
  end;

// ------------------------------------------------------------
// TNewProjectDialog
// ------------------------------------------------------------
constructor TNewProjectDialog.Create;
begin
  inherited Create;
  Text := '새 프로젝트';
  Width := 320;
  Height := 160;
  FormBorderStyle := System.Windows.Forms.FormBorderStyle.FixedDialog;
  StartPosition := System.Windows.Forms.FormStartPosition.CenterParent;
  MaximizeBox := false;
  MinimizeBox := false;

  ProjectName := '';

  lblName := new System.Windows.Forms.Label;
  lblName.Text := '프로젝트 이름:';
  lblName.Left := 12;
  lblName.Top := 16;
  lblName.Width := 100;
  Controls.Add(lblName);

  txtName := new System.Windows.Forms.TextBox;
  txtName.Left := 12;
  txtName.Top := 40;
  txtName.Width := 280;
  Controls.Add(txtName);

  btnOK := new System.Windows.Forms.Button;
  btnOK.Text := '확인';
  btnOK.Left := 132;
  btnOK.Top := 80;
  btnOK.Width := 75;
  btnOK.Click += btnOK_Click;
  Controls.Add(btnOK);

  btnCancel := new System.Windows.Forms.Button;
  btnCancel.Text := '취소';
  btnCancel.Left := 217;
  btnCancel.Top := 80;
  btnCancel.Width := 75;
  btnCancel.Click += btnCancel_Click;
  Controls.Add(btnCancel);
end;

procedure TNewProjectDialog.btnOK_Click;
begin
  // [검증 3] 빈 문자열 유효성 검사 → MessageBox.Show. 비어있으면 다이얼로그를
  // 닫지 않고(=DialogResult를 세팅하지 않고) 그대로 남겨 사용자가 다시 입력하게 한다.
  if txtName.Text = '' then
  begin
    System.Windows.Forms.MessageBox.Show('프로젝트 이름을 입력하세요.', '입력 오류');
    exit;
  end;

  ProjectName := txtName.Text;
  DialogResult := System.Windows.Forms.DialogResult.OK; // 이 대입 자체가 ShowDialog를 반환시킨다
  Close;
end;

procedure TNewProjectDialog.btnCancel_Click;
begin
  DialogResult := System.Windows.Forms.DialogResult.Cancel;
  Close;
end;

// ------------------------------------------------------------
// TMainForm
// ------------------------------------------------------------
constructor TMainForm.Create;
begin
  inherited Create;
  Text := 'Stage 77 — 모달 다이얼로그 검증';
  Width := 640;
  Height := 400;

  MainMenu := new System.Windows.Forms.MenuStrip;

  FileMenu := new System.Windows.Forms.ToolStripMenuItem;
  FileMenu.Text := 'File';

  NewMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  NewMenuItem.Text := '새 프로젝트...';
  NewMenuItem.Click += NewMenuItem_Click;

  FileMenu.DropDownItems.Add(NewMenuItem);
  MainMenu.Items.Add(FileMenu);
  MainMenu.Dock := System.Windows.Forms.DockStyle.Top;
  Controls.Add(MainMenu);
  MainMenuStrip := MainMenu;

  MainStatusBar := new System.Windows.Forms.StatusStrip;
  StatusLabel := new System.Windows.Forms.ToolStripStatusLabel;
  StatusLabel.Text := 'Ready';
  MainStatusBar.Items.Add(StatusLabel);
  MainStatusBar.Dock := System.Windows.Forms.DockStyle.Bottom;
  Controls.Add(MainStatusBar);

  Writeln('[진단] 메인 폼 구성 완료');
end;

procedure TMainForm.NewMenuItem_Click;
begin
  // [핵심 검증] 다른 사용자 정의 Form 클래스를 필드 없이 지역변수로 new하고,
  // 그 위에서 상속받은 외부 메서드 ShowDialog를 호출해 enum(DialogResult)을
  // 돌려받는다. 그 값을 다시 외부 enum 정적 필드(DialogResult.OK)와 비교한다.
  var dlg := new TNewProjectDialog;
  var res := dlg.ShowDialog;
  //Writeln('[진단] ShowDialog 반환값: ' + res.ToString);

  if res = System.Windows.Forms.DialogResult.OK then
  begin
    // [검증 2] 다이얼로그가 채워놓은 public 필드를 부모가 읽는다.
    StatusLabel.Text := '프로젝트 생성됨: ' + dlg.ProjectName;
    Writeln('[진단] 생성된 프로젝트 이름: ' + dlg.ProjectName);
  end
  else
  begin
    StatusLabel.Text := '취소됨';
    Writeln('[진단] 다이얼로그 취소됨');
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