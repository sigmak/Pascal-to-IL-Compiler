program CastTest;
type
  TMyForm = class(System.Windows.Forms.Form)
  public
    Button1: System.Windows.Forms.Button;
    procedure Setup;
    procedure Button1_Click(sender: System.Object; e: System.EventArgs);
  end;

procedure TMyForm.Button1_Click(sender: System.Object; e: System.EventArgs);
begin
  System.Windows.Forms.Button(sender).Text := '클릭됨!';
  writeln('완료: 캐스트 통한 Text 설정 성공 (예외 없음)');
end;

procedure TMyForm.Setup;
begin
  Button1 := System.Windows.Forms.Button.Create;
  Button1.Click += Button1_Click;
  Button1_Click(Button1, System.EventArgs.Create);
  writeln('Button1.Text (필드로 재확인) = ' + Button1.Text);
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
end.