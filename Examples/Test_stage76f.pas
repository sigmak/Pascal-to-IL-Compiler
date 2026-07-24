// ============================================================
// Test_stage76f.pas — [Stage 76] 로드맵 4) 아이콘 로드 나머지 절반 검증:
//  - Test_stage76e에서는 Bitmap을 "새로 생성"해서 Image 프로퍼티에 넣는
//    경로만 확인했다. 이번엔 로드맵에 적힌 "리소스 or 파일 경로" 로드를
//    실제로 검증한다.
//  1) Bitmap.Save(path, ImageFormat.Png) — 파일로 저장
//     (인스턴스 메서드 + 외부 enum 정적 필드를 인자로 넘기는 조합)
//  2) System.Drawing.Image.FromFile(path) — 파일에서 다시 로드
//     (오늘 고친 정적 메서드 해석 버그 + TryResolveMethodCallClrType의
//      반환 타입 추론이 실제 파일 I/O를 낀 상태에서도 맞물려 도는지 확인)
//  3) Form.Icon := System.Drawing.SystemIcons.Application
//     (상속받은 외부 프로퍼티에, 다른 외부 타입의 정적 프로퍼티 값을
//      그대로 대입 — "리소스형" 아이콘을 쓰는 흔한 패턴의 대체 경로)
// ============================================================
program Test_stage76f;

{$apptype console}
{$reference System.Windows.Forms.dll}
{$reference System.Drawing.dll}

type
  TMainForm = class(System.Windows.Forms.Form)
  private
    MainMenu: System.Windows.Forms.MenuStrip;
    FileMenu: System.Windows.Forms.ToolStripMenuItem;
    NewMenuItem: System.Windows.Forms.ToolStripMenuItem;
    ExitMenuItem: System.Windows.Forms.ToolStripMenuItem;
    MainStatusBar: System.Windows.Forms.StatusStrip;
    StatusLabel: System.Windows.Forms.ToolStripStatusLabel;
  public
    constructor Create;
    procedure NewMenuItem_Click;
    procedure ExitMenuItem_Click;
  end;

constructor TMainForm.Create;
begin
  inherited Create;
  Text := 'Stage 76f — 파일/리소스 아이콘 로드 검증';
  Width := 640;
  Height := 400;

  // ---- 1) 임시 아이콘을 그려서 파일로 저장 ----
  var bmp := new System.Drawing.Bitmap(16, 16);
  var g := System.Drawing.Graphics.FromImage(bmp);
  g.FillEllipse(System.Drawing.Brushes.SteelBlue, 1, 1, 14, 14);
  g.Dispose;

  var iconPath := 'stage76f_icon.png';
  bmp.Save(iconPath, System.Drawing.Imaging.ImageFormat.Png);
  Writeln('[진단] 아이콘 파일 저장 완료: ' + iconPath);

  // ---- 2) 방금 저장한 파일을 다시 로드 (핵심 검증 지점) ----
  // [핵심 검증] Image.FromFile은 외부 정적 타입의 static 메서드 호출이다.
  // 오늘 고친 ResolveMethodByArity(isStatic=true) 경로와,
  // TryResolveMethodCallClrType의 반환 타입 추론(qType=System.Drawing.Image)이
  // 실제 디스크 파일을 낀 상태에서도 제대로 맞물리는지 확인한다.
  var loadedImg := System.Drawing.Image.FromFile(iconPath);
  Writeln('[검증] loadedImg is nil? ' + BoolToStr(loadedImg = nil));

  // ---- 메뉴바 ----
  MainMenu := new System.Windows.Forms.MenuStrip;

  FileMenu := new System.Windows.Forms.ToolStripMenuItem;
  FileMenu.Text := 'File';

  NewMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  NewMenuItem.Text := '새로 만들기';
  NewMenuItem.Image := loadedImg; // [검증] 파일에서 로드한 이미지를 그대로 재사용
  NewMenuItem.Click += NewMenuItem_Click;

  ExitMenuItem := new System.Windows.Forms.ToolStripMenuItem;
  ExitMenuItem.Text := '종료';
  ExitMenuItem.Click += ExitMenuItem_Click;

  FileMenu.DropDownItems.Add(NewMenuItem);
  FileMenu.DropDownItems.Add(ExitMenuItem);

  MainMenu.Items.Add(FileMenu);
  MainMenu.Dock := System.Windows.Forms.DockStyle.Top;
  Controls.Add(MainMenu);
  MainMenuStrip := MainMenu;
  Writeln('[진단] 메뉴바 구성 완료');

  // ---- 3) 폼 자체의 타이틀바/작업표시줄 아이콘 — "리소스형" 대체 경로 ----
  // [검증] System.Drawing.SystemIcons.Application은 외부 정적 타입의 정적
  // "프로퍼티"(리터럴 필드가 아님 — Call로 getter를 실제 호출해야 함)이고,
  // 그 결과를 상속받은 Form.Icon 프로퍼티(setter)에 그대로 대입한다.
  Icon := System.Drawing.SystemIcons.Application;
  Writeln('[검증] Icon is nil? ' + BoolToStr(Icon = nil));

  // ---- 상태바 ----
  MainStatusBar := new System.Windows.Forms.StatusStrip;

  StatusLabel := new System.Windows.Forms.ToolStripStatusLabel;
  StatusLabel.Text := 'Ready';

  MainStatusBar.Items.Add(StatusLabel);
  MainStatusBar.Dock := System.Windows.Forms.DockStyle.Bottom;
  Controls.Add(MainStatusBar);
  Writeln('[진단] 상태바 구성 완료');
end;

procedure TMainForm.NewMenuItem_Click;
begin
  StatusLabel.Text := '새로 만들기 클릭됨';
end;

procedure TMainForm.ExitMenuItem_Click;
begin
  Close;
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