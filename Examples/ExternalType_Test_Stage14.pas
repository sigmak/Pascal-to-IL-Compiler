program ExternalTypeTest;
type
  TMyError = class(System.Exception)
  public
    function Describe: string;
  end;

  TMyForm = class(System.Windows.Forms.Form)
  public
    function Greeting: string;
  end;

function TMyError.Describe: string;
begin
  Result := 'System.Exception 상속 확인';
end;

function TMyForm.Greeting: string;
begin
  Result := 'System.Windows.Forms.Form 상속 확인';
end;

var
  e : TMyError;
  f : TMyForm;
begin
  e := TMyError.Create;
  f := TMyForm.Create;
  writeln(e.Describe);
  writeln(f.Greeting);
end.