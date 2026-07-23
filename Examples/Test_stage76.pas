// ============================================================
// Test_stage76_debug2.pas — [Stage 76] 텍스트 미표시 원인 격리용 2차 진단 버전.
// 변경점(원본 대비):
//  1) MainMenu.RenderMode / MainToolbar.RenderMode := ToolStripRenderMode.System 두 줄 제거
//     (기본 렌더러(ManagerRenderMode/Professional)로 그리게 함)
//  2) Application.SetCompatibleTextRenderingDefault(false) 호출 제거
//  나머지 로직/진단 Writeln은 원본과 동일하게 유지.
// ============================================================
program Test_stage76_debug2;

{$apptype console} //  windows
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
    procedure Form_Shown;
    procedure NewMenuItem_Click;
    procedure MainMenu_Paint(sender: System.Object; e: System.Windows.Forms.PaintEventArgs);
    procedure ExitMenuItem_Click;
    procedure NewToolButton_Click;
  end;

constructor TMainForm.Create;
begin
  inherited Create;
  Writeln('[진단] TMainForm.Create 시작');

  Text := 'Stage 76 — Main Shell (debug2: RenderMode 제거)';
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
  Writeln('[Font 진단] MainMenu 상속 폰트 이름 = "' + MainMenu.Font.Name + '", 크기=' + MainMenu.Font.Size.ToString);

  FileMenu := new System.Windows.Forms.ToolStripMenuItem;
  FileMenu.Text := 'File'; //파일
  // [신규] ToolStripItem 내부 페인트 파이프라인이 이 값들 때문에 그리기를
  // 스킵하고 있을 가능성을 배제하기 위해 전부 명시적으로 강제 지정.
  FileMenu.DisplayStyle := System.Windows.Forms.ToolStripItemDisplayStyle.Text;
  FileMenu.AutoSize := true;
  FileMenu.Available := true;
  FileMenu.Enabled := true;
  FileMenu.Visible := true;
  Writeln('[신규진단] FileMenu.DisplayStyle=' + FileMenu.DisplayStyle.ToString
    + ' Available=' + BoolToStr(FileMenu.Available)
    + ' Enabled=' + BoolToStr(FileMenu.Enabled)
    + ' Visible=' + BoolToStr(FileMenu.Visible));

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

  MainMenu.Paint += MainMenu_Paint;
  MainMenu.Dock := System.Windows.Forms.DockStyle.Top;
  // [신규] RenderMode.System(네이티브 Win32 메뉴 룩)으로 완전히 다른 렌더러를 테스트
  MainMenu.RenderMode := System.Windows.Forms.ToolStripRenderMode.System;
  Controls.Add(MainMenu);
  MainMenuStrip := MainMenu;
  Writeln('[신규진단2] Items.Add 이후 FileMenu.Visible=' + BoolToStr(FileMenu.Visible)
    + ' Available=' + BoolToStr(FileMenu.Available));
  Writeln('[진단] 메뉴바 구성 완료');
  FileMenu.ForeColor := System.Drawing.Color.Red;
  MainMenu.BackColor := System.Drawing.Color.Yellow;
  Writeln('[색상 진단] MainMenu.ForeColor=' + MainMenu.ForeColor.ToString + ' BackColor=' + MainMenu.BackColor.ToString);
  Writeln('[항목 진단] FileMenu.Width=' + IntToStr(FileMenu.Width) + ' Height=' + IntToStr(FileMenu.Height));

  // ---- 툴바 ----
  MainToolbar := new System.Windows.Forms.ToolStrip;

  NewToolButton := new System.Windows.Forms.ToolStripButton;
  NewToolButton.Text := 'New Create'; //새로 만들기
  NewToolButton.Click += NewToolButton_Click;
  NewToolButton.ForeColor := System.Drawing.Color.Red;

  MainToolbar.Items.Add(NewToolButton);
  MainToolbar.Dock := System.Windows.Forms.DockStyle.Top;
  // [신규] 툴바도 동일하게 네이티브 렌더러로 테스트
  MainToolbar.RenderMode := System.Windows.Forms.ToolStripRenderMode.System;
  Controls.Add(MainToolbar);
  Writeln('[진단] 툴바 구성 완료');

  // ---- 상태바 ----
  MainStatusBar := new System.Windows.Forms.StatusStrip;

  StatusLabel := new System.Windows.Forms.ToolStripStatusLabel;
  StatusLabel.Text := 'Ready';//준비

  MainStatusBar.Items.Add(StatusLabel);
  MainStatusBar.Dock := System.Windows.Forms.DockStyle.Bottom;
  Controls.Add(MainStatusBar);
  Writeln('[진단] 상태바 구성 완료');

  Shown += Form_Shown;
  Writeln('[진단] TMainForm.Create 끝');

  Writeln('[Text 진단] FileMenu.Text = "' + FileMenu.Text + '"');
  Writeln('[Text 진단] MainMenu.Items.Count = ' + MainMenu.Items.Count.ToString);
  Writeln('[Text 진단] FileMenu.DropDownItems.Count = ' + FileMenu.DropDownItems.Count.ToString);
  Writeln('[Text 진단] MainToolbar.Items.Count = ' + MainToolbar.Items.Count.ToString);

  Writeln('[GUI 진단] Controls.Count = ' + IntToStr(Controls.Count));
  Writeln('[GUI 진단] MainMenu is nil? ' + BoolToStr(MainMenu = nil));

  Writeln('[레이아웃 진단] MainMenu.Dock = ' + MainMenu.Dock.ToString);
  Writeln('[레이아웃 진단] MainMenu.Width=' + IntToStr(MainMenu.Width) + ' Height=' + IntToStr(MainMenu.Height));
  Writeln('[레이아웃 진단] MainToolbar.Dock = ' + MainToolbar.Dock.ToString);
  Writeln('[레이아웃 진단] MainStatusBar.Dock = ' + MainStatusBar.Dock.ToString);

  // [debug2] 렌더러 상태 자체를 직접 출력 (System.Windows.Forms.ToolStripManager.VisualStylesEnabled)
  Writeln('[렌더러 진단] ToolStripManager.VisualStylesEnabled = ' + BoolToStr(System.Windows.Forms.ToolStripManager.VisualStylesEnabled));
  Writeln('[렌더러 진단] MainMenu.RenderMode = ' + MainMenu.RenderMode.ToString);
  Writeln('[렌더러 진단] MainToolbar.RenderMode = ' + MainToolbar.RenderMode.ToString);
  Writeln('[렌더러 진단] MainStatusBar.RenderMode = ' + MainStatusBar.RenderMode.ToString);
end;

procedure TMainForm.Form_Shown;
begin
  Writeln('[Shown 진단] MainMenu.Dock = ' + MainMenu.Dock.ToString);
  Writeln('[Shown 진단] MainMenu.Width=' + IntToStr(MainMenu.Width) + ' Height=' + IntToStr(MainMenu.Height));
  Writeln('[Shown 진단] MainMenu.Visible=' + BoolToStr(MainMenu.Visible));
  Writeln('[Shown 진단] Form.ClientSize.Width=' + IntToStr(ClientSize.Width));
  Writeln('[Shown 진단] MainMenu.Parent is nil? ' + BoolToStr(MainMenu.Parent = nil));
  Writeln('[Shown 진단] MainMenu.IsHandleCreated=' + BoolToStr(MainMenu.IsHandleCreated));
  Writeln('[신규진단3] Shown 이후 FileMenu.Visible=' + BoolToStr(FileMenu.Visible)
    + ' Available=' + BoolToStr(FileMenu.Available)
    + ' Width=' + IntToStr(FileMenu.Width) + ' Height=' + IntToStr(FileMenu.Height));
  Writeln('[신규진단4] FileMenu.Owner is nil? ' + BoolToStr(FileMenu.Owner = nil));
  Writeln('[신규진단4] FileMenu.GetCurrentParent() is nil? ' + BoolToStr(FileMenu.GetCurrentParent() = nil));
end;

procedure TMainForm.NewMenuItem_Click;
begin
  StatusLabel.Text := '새로 만들기(메뉴) 클릭됨';
end;

procedure TMainForm.MainMenu_Paint(sender: System.Object; e: System.Windows.Forms.PaintEventArgs);
begin
  e.Graphics.DrawString('수동그리기-파일(GDI+)', new System.Drawing.Font('맑은 고딕', 10),
    System.Drawing.Brushes.Black, new System.Drawing.PointF(100, 2));

  System.Windows.Forms.TextRenderer.DrawText(e.Graphics, 'GDI테스트',
    new System.Drawing.Font('맑은 고딕', 10), new System.Drawing.Point(300, 2),
    System.Drawing.Color.Black);

  // [수정] y좌표를 메뉴바 높이(24px) 안으로 — 가로로 나란히 배치
  e.Graphics.DrawString('FileMenu폰트-GDI+', FileMenu.Font,
    System.Drawing.Brushes.Black, new System.Drawing.PointF(450, 2));

  System.Windows.Forms.TextRenderer.DrawText(e.Graphics, 'FileMenu폰트-GDI',
    FileMenu.Font, new System.Drawing.Point(650, 2), System.Drawing.Color.Black);
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
    System.Windows.Forms.Application.EnableVisualStyles();
    // ↓ 이 줄을 반드시 넣어야 ToolStrip 계열 텍스트가 렌더링된다
    System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);
    // [debug2] SetCompatibleTextRenderingDefault(false) 제거 — GDI+ 기본 경로로 테스트
    // System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);
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