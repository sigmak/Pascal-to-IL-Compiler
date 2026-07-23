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
    procedure Form_Shown;   // ← 추가
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

  // [진단] ToolStrip류가 아닌 일반 Label로 기본 텍스트 렌더링 자체가 되는지 확인.
  var testLabel := new System.Windows.Forms.Label;
  testLabel.Text := '테스트 라벨 - 보이나요?';
  testLabel.Left := 20;
  testLabel.Top := 60;
  testLabel.Width := 400;
  testLabel.Height := 40;
  testLabel.ForeColor := System.Drawing.Color.Blue;
  testLabel.Font := new System.Drawing.Font('맑은 고딕', 16);
  Controls.Add(testLabel);
  Writeln('[진단] 테스트 라벨 추가 완료');

  // ---- 메뉴바 ----
  MainMenu := new System.Windows.Forms.MenuStrip;
  
  Writeln('[Font 진단] Form.Font is nil? ' + BoolToStr(Font = nil));
  // [진단] '맑은 고딕' 지정 폰트가 텍스트 미표시의 원인인지 격리하기 위해 일단 빼고
  // 기본 상속 폰트가 뭔지 확인한다.
  Writeln('[Font 진단] MainMenu 상속 폰트 이름 = "' + MainMenu.Font.Name + '", 크기=' + MainMenu.Font.Size.ToString);

  FileMenu := new System.Windows.Forms.ToolStripMenuItem;
  FileMenu.Text := '파일';

  NewMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  NewMenuItem.Text := '새로 만들기';
  NewMenuItem.Click += NewMenuItem_Click;

  OpenMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  OpenMenuItem.Text := '열기';

  ExitMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  ExitMenuItem.Text := '종료';
  ExitMenuItem.Click += ExitMenuItem_Click;

  FileMenu.DropDownItems.Add(NewMenuItem);
  FileMenu.DropDownItems.Add(OpenMenuItem);
  FileMenu.DropDownItems.Add(ExitMenuItem);
  Writeln('[진단] 파일 메뉴 하위 항목 구성 완료');

  MainMenu.Items.Add(FileMenu);
  MainMenu.Dock := System.Windows.Forms.DockStyle.Top;
  MainMenu.RenderMode := System.Windows.Forms.ToolStripRenderMode.System;
  Controls.Add(MainMenu);
  MainMenuStrip := MainMenu;
  Writeln('[진단] 메뉴바 구성 완료');
  FileMenu.ForeColor := System.Drawing.Color.Red;
  MainMenu.BackColor := System.Drawing.Color.Yellow;
  Writeln('[색상 진단] MainMenu.ForeColor=' + MainMenu.ForeColor.ToString + ' BackColor=' + MainMenu.BackColor.ToString);
  Writeln('[항목 진단] FileMenu.Width=' + IntToStr(FileMenu.Width) + ' Height=' + IntToStr(FileMenu.Height));

  // ---- 툴바 ----
  MainToolbar := new System.Windows.Forms.ToolStrip;

  NewToolButton := new System.Windows.Forms.ToolStripButton;
  NewToolButton.Text := '새로 만들기';
  NewToolButton.Click += NewToolButton_Click;
  NewToolButton.ForeColor := System.Drawing.Color.Red;

  MainToolbar.Items.Add(NewToolButton);
  MainToolbar.Dock := System.Windows.Forms.DockStyle.Top;
  MainToolbar.RenderMode := System.Windows.Forms.ToolStripRenderMode.System;
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

  Shown += Form_Shown;      // ← 생성자 끝부분에 추가 (Controls.Add 다 끝난 뒤)
  Writeln('[진단] TMainForm.Create 끝');
  
  Writeln('[Text 진단] FileMenu.Text = "' + FileMenu.Text + '"');
  Writeln('[Text 진단] MainMenu.Items.Count = ' + MainMenu.Items.Count.ToString);
  Writeln('[Text 진단] FileMenu.DropDownItems.Count = ' + FileMenu.DropDownItems.Count.ToString);
  Writeln('[Text 진단] MainToolbar.Items.Count = ' + MainToolbar.Items.Count.ToString);  
  
  // TMainForm.Create 끝 부분에 추가
  Writeln('[GUI 진단] Controls.Count = ' + IntToStr(Controls.Count));
  Writeln('[GUI 진단] MainMenu is nil? ' + BoolToStr(MainMenu = nil));  
  
  Writeln('[레이아웃 진단] MainMenu.Dock = ' + MainMenu.Dock.ToString);
  Writeln('[레이아웃 진단] MainMenu.Width=' + IntToStr(MainMenu.Width) + ' Height=' + IntToStr(MainMenu.Height));
  Writeln('[레이아웃 진단] MainToolbar.Dock = ' + MainToolbar.Dock.ToString);
  Writeln('[레이아웃 진단] MainStatusBar.Dock = ' + MainStatusBar.Dock.ToString);  
end;

procedure TMainForm.Form_Shown;
begin
  Writeln('[Shown 진단] MainMenu.Dock = ' + MainMenu.Dock.ToString);
  Writeln('[Shown 진단] MainMenu.Width=' + IntToStr(MainMenu.Width) + ' Height=' + IntToStr(MainMenu.Height));
  Writeln('[Shown 진단] MainMenu.Visible=' + BoolToStr(MainMenu.Visible));
  Writeln('[Shown 진단] Form.ClientSize.Width=' + IntToStr(ClientSize.Width));
  Writeln('[Shown 진단] MainMenu.Parent is nil? ' + BoolToStr(MainMenu.Parent = nil));
  Writeln('[Shown 진단] MainMenu.IsHandleCreated=' + BoolToStr(MainMenu.IsHandleCreated));
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
    System.Windows.Forms.Application.EnableVisualStyles;
    System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);
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