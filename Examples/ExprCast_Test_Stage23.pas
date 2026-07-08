program ExprCastTest;
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
  writeln('식 문맥 캐스트 읽기: ' + System.Windows.Forms.Button(sender).Text);
end;

procedure TMyForm.Setup;
begin
  Button1 := System.Windows.Forms.Button.Create;
  Button1.Click += Button1_Click;
  Button1_Click(Button1, System.EventArgs.Create);
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
end.