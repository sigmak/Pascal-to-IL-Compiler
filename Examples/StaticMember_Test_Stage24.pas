program StaticMemberTest;
type
  TMyForm = class(System.Windows.Forms.Form)
  public
    Button1: System.Windows.Forms.Button;
    procedure Setup;
    procedure Button1_Click(sender: System.Object; e: System.EventArgs);
  end;

procedure TMyForm.Button1_Click(sender: System.Object; e: System.EventArgs);
begin
  writeln('핸들러 호출됨 (정적 속성으로 만든 EventArgs 사용)');
end;

procedure TMyForm.Setup;
begin
  Button1 := System.Windows.Forms.Button.Create;
  Button1.Click += Button1_Click;
  Button1_Click(Button1, System.EventArgs.Empty);
  writeln('완료: 정적 필드/속성(EventArgs.Empty) 접근 성공');
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
end.