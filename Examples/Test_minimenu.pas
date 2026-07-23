// ============================================================
// Test_minimenu.pas — MenuStrip 텍스트 미표시 최소 재현 케이스.
// 변수 최대 제거: 색상 지정 없음, 폰트 지정 없음, 한글 대신 영문,
// 항목 1개, Dock 없이 기본 상태.
// ============================================================
program Test_minimenu;

{$apptype console}
{$reference System.Windows.Forms.dll}
{$reference System.Drawing.dll}

type
  TMiniForm = class(System.Windows.Forms.Form)
  private
    MMenu: System.Windows.Forms.MenuStrip;
    MItem: System.Windows.Forms.ToolStripMenuItem;
    MFound: System.Windows.Forms.ToolStripMenuItem;
  public
    constructor Create;
  end;

constructor TMiniForm.Create;
begin
  inherited Create;
  Text := 'Mini Menu Test';
  Width := 400;
  Height := 300;

  MMenu := new System.Windows.Forms.MenuStrip;
  MItem := new System.Windows.Forms.ToolStripMenuItem;
  MItem.Text := 'File';

  Writeln('[진단] MItem.Text (설정 직후) = "' + MItem.Text + '"');
  Writeln('[진단] MItem.Font.Name=' + MItem.Font.Name + ' Size=' + MItem.Font.Size.ToString);
  Writeln('[진단] MItem.ForeColor=' + MItem.ForeColor.ToString);
  Writeln('[진단] MItem.BackColor=' + MItem.BackColor.ToString);
  Writeln('[진단] MItem.DisplayStyle=' + MItem.DisplayStyle.ToString);
  Writeln('[진단] MItem.TextAlign=' + MItem.TextAlign.ToString);

  MMenu.Items.Add(MItem);
  MMenu.Dock := System.Windows.Forms.DockStyle.Top;   // [수정] 누락됐던 Dock 지정
  Controls.Add(MMenu);
  MainMenuStrip := MMenu;

  Writeln('[진단] MMenu.Items.Count=' + MMenu.Items.Count.ToString);
  Writeln('[진단] MMenu.Width=' + IntToStr(MMenu.Width) + ' Height=' + IntToStr(MMenu.Height));
  Writeln('[진단] MMenu.Dock=' + MMenu.Dock.ToString);
  Writeln('[진단] MMenu.Visible=' + BoolToStr(MMenu.Visible));
  // [수정] Add 이후에 다시 확인 — 부모에 붙은 뒤라야 Visible이 의미 있음
  Writeln('[진단] MItem.Width=' + IntToStr(MItem.Width) + ' Height=' + IntToStr(MItem.Height));
  Writeln('[진단] MItem.AutoSize=' + BoolToStr(MItem.AutoSize));
  Writeln('[진단] MItem.Visible(Add 이후)=' + BoolToStr(MItem.Visible));
  Writeln('[진단] MItem.Enabled=' + BoolToStr(MItem.Enabled));
  Writeln('[진단] MItem.Owner is nil? ' + BoolToStr(MItem.Owner = nil));

  // [핵심 진단] 컬렉션에 실제로 들어간 게 우리가 만든 MItem과 같은 객체인가?
  // (인덱서 문법 미지원 — for-in으로 첫 항목을 꺼낸다. for-in 변수는 로컬이어야
  //  해서 로컬 var로 순회하되, 로컬변수.프로퍼티 접근이 별도 버그로 막혀서
  //  결과는 클래스 필드 MFound에 담아 필드 경로로 출력한다)
  var itemAny := MItem;   // 타입 추론용 — 아래서 바로 덮어씀
  MFound := nil;
  for itemAny in MMenu.Items do
  begin
    if MFound = nil then MFound := itemAny;
  end;
  Writeln('[핵심 진단] MMenu.Items[0].Text = "' + MFound.Text + '"');
  Writeln('[핵심 진단] MMenu.Items[0] = MItem (같은 객체?) = ' + BoolToStr(MFound = MItem));
  Writeln('[핵심 진단] MMenu.Items[0].Owner is nil? ' + BoolToStr(MFound.Owner = nil));
end;

var
  f: TMiniForm;
begin
  try
    Writeln('[진단] main 시작');
    System.Windows.Forms.Application.EnableVisualStyles;
    f := new TMiniForm;
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