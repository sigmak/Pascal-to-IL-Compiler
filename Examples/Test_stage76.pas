// ============================================================
// Test_stage76_debug.pas — [Stage 76] 메인 셸 윈도우(TMainForm) 진단용 버전.
// 메뉴바 + 툴바 + 상태바만 있는 껍데기. 도킹/여러 창 연동은 이후 단계.
// ============================================================
program Test_stage76_debug;

{$apptype console}
{$reference System.Windows.Forms.dll}
{$reference System.Drawing.dll}

type
  TMainForm = class(System.Windows.Forms.Form)
  private
    MainMenu: System.Windows.Forms.MenuStrip;
    FileMenu: System.Windows.Forms.ToolStripMenuItem;
    NewMenuItem: System.Windows.Forms.ToolStripMenuItem;
    OpenMenuItem: System.Windows.Forms.ToolStripMenuItem;
    ExitMenuItem: System.Windows.Forms.ToolStripMenuItem;
    MainToolbar: System.Windows.Forms.ToolStrip;
    NewToolButton: System.Windows.Forms.ToolStripButton;
    MainStatusBar: System.Windows.Forms.StatusStrip;
    StatusLabel: System.Windows.Forms.ToolStripStatusLabel;
  public
    constructor Create;
    procedure NewMenuItem_Click;
    procedure ExitMenuItem_Click;
    procedure NewToolButton_Click;
  end;

constructor TMainForm.Create;
begin
  inherited Create;
  Writeln('[진단] TMainForm.Create 시작');

  Text := 'Stage 76 — Main Shell';
  Width := 640;
  Height := 400;
  Writeln('[진단] Text/Width/Height 설정 완료');

  // ---- 메뉴바 ----
  MainMenu := new System.Windows.Forms.MenuStrip;

  FileMenu := new System.Windows.Forms.ToolStripMenuItem;
  FileMenu.Text := '파일(&F)';

  NewMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  NewMenuItem.Text := '새로 만들기(&N)';
  NewMenuItem.Click += NewMenuItem_Click;

  OpenMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  OpenMenuItem.Text := '열기(&O)';

  ExitMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  ExitMenuItem.Text := '종료(&X)';
  ExitMenuItem.Click += ExitMenuItem_Click;

  FileMenu.DropDownItems.Add(NewMenuItem);
  FileMenu.DropDownItems.Add(OpenMenuItem);
  FileMenu.DropDownItems.Add(ExitMenuItem);
  Writeln('[진단] 파일 메뉴 하위 항목 구성 완료');

  MainMenu.Items.Add(FileMenu);
  MainMenu.Dock := System.Windows.Forms.DockStyle.Top;
  Controls.Add(MainMenu);
  MainMenuStrip := MainMenu;
  Writeln('[진단] 메뉴바 구성 완료');

  // ---- 툴바 ----
  MainToolbar := new System.Windows.Forms.ToolStrip;

  NewToolButton := new System.Windows.Forms.ToolStripButton;
  NewToolButton.Text := '새로 만들기';
  NewToolButton.Click += NewToolButton_Click;

  MainToolbar.Items.Add(NewToolButton);
  MainToolbar.Dock := System.Windows.Forms.DockStyle.Top;
  Controls.Add(MainToolbar);
  Writeln('[진단] 툴바 구성 완료');

  // ---- 상태바 ----
  MainStatusBar := new System.Windows.Forms.StatusStrip;

  StatusLabel := new System.Windows.Forms.ToolStripStatusLabel;
  StatusLabel.Text := '준비';

  MainStatusBar.Items.Add(StatusLabel);
  MainStatusBar.Dock := System.Windows.Forms.DockStyle.Bottom;
  Controls.Add(MainStatusBar);
  Writeln('[진단] 상태바 구성 완료');

  Writeln('[진단] TMainForm.Create 끝');
  
  Writeln('[Text 진단] FileMenu.Text = "' + FileMenu.Text + '"');
  Writeln('[Text 진단] MainMenu.Items.Count = ' + MainMenu.Items.Count.ToString);
  Writeln('[Text 진단] FileMenu.DropDownItems.Count = ' + FileMenu.DropDownItems.Count.ToString);
  Writeln('[Text 진단] MainToolbar.Items.Count = ' + MainToolbar.Items.Count.ToString);  
  
  // TMainForm.Create 끝 부분에 추가
  Writeln('[GUI 진단] Controls.Count = ' + IntToStr(Controls.Count));
  Writeln('[GUI 진단] MainMenu is nil? ' + BoolToStr(MainMenu = nil));  
end;

procedure TMainForm.NewMenuItem_Click;
begin
  StatusLabel.Text := '새로 만들기(메뉴) 클릭됨';
end;

procedure TMainForm.ExitMenuItem_Click;
begin
  Close;
end;

procedure TMainForm.NewToolButton_Click;
begin
  StatusLabel.Text := '새로 만들기(툴바) 클릭됨';
end;

var
  f: TMainForm;
begin
  try
    Writeln('[진단] main 시작');
    f := new TMainForm;
    Writeln('[진단] new TMainForm 완료 — Application.Run 호출 직전');
    System.Windows.Forms.Application.Run(f);
    Writeln('[진단] Application.Run 반환됨 (창이 닫힌 뒤)');
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