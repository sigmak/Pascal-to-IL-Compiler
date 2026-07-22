// ============================================================
// Test_stage75_debug.pas — [Stage 75] 진단용 버전.
// {$apptype console}로 바꾸고 각 단계마다 Writeln을 찍어서
// "어디까지 실행됐는지"와 "무슨 예외가 났는지"를 눈으로 보기 위한 버전이다.
// 문제 원인을 찾으면 원래 Test_stage75.pas(windows apptype)로 되돌린다.
// ============================================================
program Test_stage75_debug;

{$apptype console}
{$reference System.Windows.Forms.dll}
{$reference System.Drawing.dll}

uses
  UGreeter;

type
  TMiniForm = class(System.Windows.Forms.Form)
  private
    NameBox: System.Windows.Forms.TextBox;
    GreetButton: System.Windows.Forms.Button;
    ResultLabel: System.Windows.Forms.Label;
  public
    constructor Create;
    procedure GreetButton_Click;
  end;

constructor TMiniForm.Create;
begin
  Writeln('[진단] TMiniForm.Create 시작');
  Text := 'Stage 75 — Mini WinForms Test';
  Width := 320;
  Height := 180;
  Writeln('[진단] Text/Width/Height 설정 완료');

  NameBox := new System.Windows.Forms.TextBox;
  NameBox.Left := 20;
  NameBox.Top := 20;
  NameBox.Width := 260;
  NameBox.Text := 'PascalABC';
  Writeln('[진단] NameBox 생성/설정 완료');

  GreetButton := new System.Windows.Forms.Button;
  GreetButton.Left := 20;
  GreetButton.Top := 55;
  GreetButton.Width := 100;
  GreetButton.Text := 'Greet';
  Writeln('[진단] GreetButton 생성/설정 완료');

  ResultLabel := new System.Windows.Forms.Label;
  ResultLabel.Left := 20;
  ResultLabel.Top := 95;
  ResultLabel.Width := 260;
  ResultLabel.Text := '';
  Writeln('[진단] ResultLabel 생성/설정 완료');

  Controls.Add(NameBox);
  Writeln('[진단] Controls.Add(NameBox) 완료');
  Controls.Add(GreetButton);
  Writeln('[진단] Controls.Add(GreetButton) 완료');
  Controls.Add(ResultLabel);
  Writeln('[진단] Controls.Add(ResultLabel) 완료');

  GreetButton.Click += GreetButton_Click;
  Writeln('[진단] 이벤트 구독 완료 — 생성자 끝');
end;

procedure TMiniForm.GreetButton_Click;
begin
  ResultLabel.Text := BuildGreeting(NameBox.Text);
end;

var
  f: TMiniForm;
begin
  try
    Writeln('[진단] main 시작');
    f := new TMiniForm;
    Writeln('[진단] new TMiniForm 완료 — Application.Run 호출 직전');
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