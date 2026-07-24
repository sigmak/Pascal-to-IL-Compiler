// ============================================================
// Test_stage76e.pas — [Stage 76] 남은 로드맵 항목 검증:
//  3) 메뉴 항목 활성/비활성 토글 (Enabled := false 등 속성 쓰기)
//  4) 아이콘 로드 (System.Drawing.Image, 외부 static 메서드 호출 결과를
//     중간 변수에 담았다가 재사용하는 패턴 — CodeGen.pas 패치 검증용)
//  5) 새 외부 컨트롤 타입의 프로퍼티/이벤트가 리플렉션 경로로 잘 잡히는지
// debug2 셸을 그대로 베이스로 쓰고, 진단용 수동 GDI+ 그리기 코드는 정리했다.
// ============================================================
program Test_stage76e;

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
    procedure OpenMenuItem_Click;
    procedure ExitMenuItem_Click;
    procedure NewToolButton_Click;
  end;

constructor TMainForm.Create;
begin
  inherited Create;
  Text := 'Stage 76e — Enabled 토글 + 아이콘 로드 검증';
  Width := 640;
  Height := 400;

  // ---- 아이콘 생성 ----
  // [핵심 검증] "var g := System.Drawing.Graphics.FromImage(bmp);" 처럼
  // 외부 static 메서드 호출 결과를 중간 변수에 담는 패턴. 예전엔 g가
  // System.Object로 선언돼서 이후 g.FillEllipse(...) 오버로드 판별이
  // 깨졌었다(이번 CodeGen.pas 패치로 고쳐졌는지 확인하는 지점).
  var bmp := new System.Drawing.Bitmap(16, 16);
  var g := System.Drawing.Graphics.FromImage(bmp);
  g.FillEllipse(System.Drawing.Brushes.OrangeRed, 1, 1, 14, 14);
  g.Dispose;
  Writeln('[진단] 아이콘 비트맵 생성 완료');

  // ---- 메뉴바 ----
  MainMenu := new System.Windows.Forms.MenuStrip;

  FileMenu := new System.Windows.Forms.ToolStripMenuItem;
  FileMenu.Text := 'File';

  NewMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  NewMenuItem.Text := '새로 만들기';
  NewMenuItem.Image := bmp; // [검증] 중간 변수(bmp)를 외부 프로퍼티에 대입
  NewMenuItem.Click += NewMenuItem_Click;

  OpenMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  OpenMenuItem.Text := '열기';
  OpenMenuItem.Click += OpenMenuItem_Click;

  ExitMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  ExitMenuItem.Text := '종료';
  ExitMenuItem.Click += ExitMenuItem_Click;

  FileMenu.DropDownItems.Add(NewMenuItem);
  FileMenu.DropDownItems.Add(OpenMenuItem);
  FileMenu.DropDownItems.Add(ExitMenuItem);

  MainMenu.Items.Add(FileMenu);
  MainMenu.Dock := System.Windows.Forms.DockStyle.Top;
  Controls.Add(MainMenu);
  MainMenuStrip := MainMenu;
  Writeln('[진단] 메뉴바 구성 완료');

  // ---- 툴바 ----
  MainToolbar := new System.Windows.Forms.ToolStrip;

  NewToolButton := new System.Windows.Forms.ToolStripButton;
  NewToolButton.Text := 'New Create';
  NewToolButton.Image := bmp; // [검증] 같은 중간 변수를 다른 컨트롤에도 재사용
  NewToolButton.Click += NewToolButton_Click;

  MainToolbar.Items.Add(NewToolButton);
  MainToolbar.Dock := System.Windows.Forms.DockStyle.Top;
  Controls.Add(MainToolbar);
  Writeln('[진단] 툴바 구성 완료');

  // ---- 상태바 ----
  MainStatusBar := new System.Windows.Forms.StatusStrip;

  StatusLabel := new System.Windows.Forms.ToolStripStatusLabel;
  StatusLabel.Text := 'Ready';

  MainStatusBar.Items.Add(StatusLabel);
  MainStatusBar.Dock := System.Windows.Forms.DockStyle.Bottom;
  Controls.Add(MainStatusBar);
  Writeln('[진단] 상태바 구성 완료');

  Writeln('[검증] NewMenuItem.Image is nil? ' + BoolToStr(NewMenuItem.Image = nil));
  Writeln('[검증] NewToolButton.Image is nil? ' + BoolToStr(NewToolButton.Image = nil));
end;

procedure TMainForm.NewMenuItem_Click;
begin
  StatusLabel.Text := '새로 만들기(메뉴) 클릭됨';
end;

procedure TMainForm.OpenMenuItem_Click;
begin
  // [검증] 3) Enabled 토글 — 클릭할 때마다 "새로 만들기" 항목을 껐다 켰다 한다.
  NewMenuItem.Enabled := not NewMenuItem.Enabled;
  StatusLabel.Text := '열기 클릭됨 / 새로 만들기 Enabled=' + BoolToStr(NewMenuItem.Enabled);
end;

procedure TMainForm.ExitMenuItem_Click;
begin
  Close;
end;

procedure TMainForm.NewToolButton_Click;
begin
  // [검증] 3) Enabled 토글 — 툴바 버튼 클릭으로 File 메뉴 자체를 껐다 켠다.
  FileMenu.Enabled := not FileMenu.Enabled;
  StatusLabel.Text := '새로 만들기(툴바) 클릭됨 / File 메뉴 Enabled=' + BoolToStr(FileMenu.Enabled);
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