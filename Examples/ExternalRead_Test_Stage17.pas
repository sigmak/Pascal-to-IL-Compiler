program ExternalReadTest;
type
  TMyForm = class(System.Windows.Forms.Form)
  public
    procedure Setup;
    function GetTitle: string;
  end;

procedure TMyForm.Setup;
begin
  Text := 'Hello from Pascal-to-IL compiler';
end;

function TMyForm.GetTitle: string;
begin
  Result := Text;
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
  writeln(f.GetTitle);
end.
