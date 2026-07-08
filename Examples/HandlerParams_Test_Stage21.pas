program HandlerParamsTest;
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
  writeln('핸들러 호출됨. sender.ToString = ' + sender.ToString);
  writeln('ClickCount=' + IntToStr(ClickCount));
end;

procedure TMyForm.Setup;
begin
  Button1 := System.Windows.Forms.Button.Create;
  Button1.Click += Button1_Click;
  Button1_Click(Button1, System.EventArgs.Create);
  writeln('완료: 핸들러에서 sender 매개변수 사용 성공');
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
end.