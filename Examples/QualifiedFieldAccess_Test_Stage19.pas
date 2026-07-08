program QualifiedFieldAccessTest;
type
  TMyForm = class(System.Windows.Forms.Form)
  public
    Button1: System.Windows.Forms.Button;
    procedure Setup;
  end;

procedure TMyForm.Setup;
begin
  Button1 := System.Windows.Forms.Button.Create;
  Button1.Text := 'Click me';
  writeln(Button1.Text);
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
end.