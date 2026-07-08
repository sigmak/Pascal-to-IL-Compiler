program EventSubscribeTest;
type
  TMyForm = class(System.Windows.Forms.Form)
  public
    Button1: System.Windows.Forms.Button;
    ClickCount: integer;
    procedure Setup;
    procedure Button1_Click(sender: System.Object; e: System.EventArgs);
  end;

procedure TMyForm.Button1_Click(sender: System.Object; e: System.EventArgs);
begin
  ClickCount := ClickCount + 1;
  writeln('버튼 클릭 핸들러 호출됨! ClickCount=' + IntToStr(ClickCount));
end;

procedure TMyForm.Setup;
begin
  Button1 := System.Windows.Forms.Button.Create;
  Button1.Click += Button1_Click;
  writeln('완료: Button1.Click 이벤트 구독 성공 (예외 없음)');
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
end.
