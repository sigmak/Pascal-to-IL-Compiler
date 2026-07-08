program StaticWriteTest;
type
  TMyForm = class(System.Windows.Forms.Form)
  public
    procedure Setup;
  end;

procedure TMyForm.Setup;
begin
  System.Console.Title := 'Pascal-to-IL Compiler';
  writeln('설정된 제목: ' + System.Console.Title);
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
end.