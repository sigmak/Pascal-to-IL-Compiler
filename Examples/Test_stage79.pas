// ============================================================
// Test_stage79.pas — [Stage 79] 코드 에디터 패널 검증:
//  1) System.IO.File.ReadAllText / WriteAllText 로 텍스트 로드/저장
//  2) (신택스 하이라이팅 훅은 이번 스테이지에서는 생략 — 있으면 좋고 없어도 진행)
//  3) TabControl/TabPage 동적 생성으로 여러 파일 탭 관리
//  4) 동적 컨트롤(RichTextBox) 생성 후 컬렉션(TabPages/Controls)에 추가/제거,
//     대용량 문자열(반복 연결) 처리
//
// [설계 메모] 모든 "Editor.XXX(...)" 호출은 TMainForm 자기 자신의 메서드
// 안에서 "Editor" 필드(단일 세그먼트, 암시적 self)를 통해서만 이루어지도록
// 했다. f.Editor.OpenFile(...) 처럼 지역변수를 거쳐 로컬 클래스 타입 필드의
// 메서드를 호출하는 다중 세그먼트 체인은 CodeGen의 별도 분기를 타므로
// (방금 Stage 79에서 같은 유형의 TypeBuilder/GetProperty 버그가 있었음)
// 이번 테스트에서는 검증 범위를 좁혀 이미 검증된 단일 세그먼트 경로만 쓴다.
// ============================================================
program Test_stage79;

{$apptype console}
{$reference System.Windows.Forms.dll}
{$reference System.Drawing.dll}

type
  TCodeEditorPanel = class(System.Windows.Forms.Panel)
  private
    Tabs: System.Windows.Forms.TabControl;
  public
    constructor Create;
    procedure OpenFile(path: string);
    procedure SaveTab(index: integer; path: string);
    procedure CloseTab(index: integer);
  end;

  TMainForm = class(System.Windows.Forms.Form)
  private
    Editor: TCodeEditorPanel;
  public
    constructor Create(tempDir: string);
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
  // [검증 1] 파일 텍스트 로드
  content := System.IO.File.ReadAllText(path);
  fileName := System.IO.Path.GetFileName(path);

  page := new System.Windows.Forms.TabPage;
  page.Text := fileName;

  // [검증 3/4] 동적 컨트롤(RichTextBox) 생성
  editor := new System.Windows.Forms.RichTextBox;
  editor.Dock := System.Windows.Forms.DockStyle.Fill;
  editor.Text := content;

  // [검증 4] 동적 생성된 컨트롤을 TabPage.Controls에, TabPage를 Tabs.TabPages에 추가
  page.Controls.Add(editor);
  Tabs.TabPages.Add(page);
  Tabs.SelectedTab := page;

  tabCount := Tabs.TabPages.Count;
  Writeln('[진단] 파일 열림: ' + fileName + ' (' + content.Length + '자, 전체 탭 수=' + tabCount + ')');
end;

procedure TCodeEditorPanel.SaveTab(index: integer; path: string);
var
  page: System.Windows.Forms.TabPage;
  ctrl: System.Windows.Forms.Control;
  tabCount: integer;
  savedLen: integer;
begin
  tabCount := Tabs.TabPages.Count;
  if (index < 0) or (index >= tabCount) then
  begin
    Writeln('[진단] 저장 실패 — 잘못된 탭 인덱스: ' + index);
    exit;
  end;

  // [검증 4] 외부 컬렉션 인덱서로 TabPage 접근, 그 안의 첫 컨트롤(에디터) 취득
  page := Tabs.TabPages[index];
  ctrl := page.Controls[0];

  // [검증 1] 편집 중인 텍스트를 파일로 저장
  savedLen := ctrl.Text.Length;
  System.IO.File.WriteAllText(path, ctrl.Text);
  Writeln('[진단] 저장됨: ' + path + ' (' + savedLen + '자)');
end;

procedure TCodeEditorPanel.CloseTab(index: integer);
var
  page: System.Windows.Forms.TabPage;
  tabCount: integer;
  remaining: integer;
begin
  tabCount := Tabs.TabPages.Count;
  if (index < 0) or (index >= tabCount) then
  begin
    Writeln('[진단] 닫기 실패 — 잘못된 탭 인덱스: ' + index);
    exit;
  end;

  page := Tabs.TabPages[index];

  // [검증 4] 컬렉션에서 동적으로 제거
  Tabs.TabPages.Remove(page);
  remaining := Tabs.TabPages.Count;
  Writeln('[진단] 탭 닫힘. 남은 탭 수 = ' + remaining);
end;

// ------------------------------------------------------------
// TMainForm
// ------------------------------------------------------------
constructor TMainForm.Create(tempDir: string);
var
  path1, path2, path3, path1Saved: string;
begin
  inherited Create;
  Text := 'Stage 79 — 코드 에디터 패널 검증';
  Width := 800;
  Height := 500;

  Editor := new TCodeEditorPanel;
  Controls.Add(Editor);

  path1 := System.IO.Path.Combine(tempDir, 'stage79_a.txt');
  path2 := System.IO.Path.Combine(tempDir, 'stage79_b.txt');
  path3 := System.IO.Path.Combine(tempDir, 'stage79_big.txt');
  path1Saved := System.IO.Path.Combine(tempDir, 'stage79_a_saved.txt');

  // [검증 3] 여러 파일을 탭으로 열기 (Editor는 자기 자신의 필드 — 단일 세그먼트 접근)
  Editor.OpenFile(path1);
  Editor.OpenFile(path2);
  Editor.OpenFile(path3);

  // [검증 1] 탭 0(file A)의 내용을 다른 경로로 저장
  Editor.SaveTab(0, path1Saved);

  // [검증 3/4] 탭 1(file B) 닫기 — 동적 컨트롤/탭 제거
  Editor.CloseTab(1);
end;

var
  f: TMainForm;
  tempDir: string;
  bigContent: string;
  i: integer;
  bigLen: integer;
begin
  try
    System.Windows.Forms.Application.EnableVisualStyles();
    System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);

    tempDir := System.IO.Path.GetTempPath();

    // 테스트용 파일 A, B 준비
    System.IO.File.WriteAllText(System.IO.Path.Combine(tempDir, 'stage79_a.txt'), 'Hello from file A.');
    System.IO.File.WriteAllText(System.IO.Path.Combine(tempDir, 'stage79_b.txt'), 'Hello from file B.');

    // [검증 4] 대용량 문자열 생성 (반복 연결 — 정수 i가 문자열 연결식 안에서
    // 자동으로 문자열로 변환되는지도 함께 확인)
    bigContent := '';
    for i := 1 to 3000 do
      bigContent := bigContent + 'Stage79 line ' + i + ' - self-hosting Pascal compiler large string test. ';

    bigLen := bigContent.Length;
    System.IO.File.WriteAllText(System.IO.Path.Combine(tempDir, 'stage79_big.txt'), bigContent);
    Writeln('[진단] 대용량 테스트 파일 생성 완료 (' + bigLen + '자)');

    f := new TMainForm(tempDir);
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