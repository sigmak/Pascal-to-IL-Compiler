program InterfaceTest;
type
  ISpeaker = interface
    function Speak: string;
  end;

  TAnimal = class(ISpeaker)
  public
    function Speak: string;
  end;

function TAnimal.Speak: string;
begin
  Result := 'Animal sound';
end;

var
  a : TAnimal;
  s : ISpeaker;
begin
  a := TAnimal.Create;
  s := a;
  writeln(a.Speak);
  writeln(s.Speak);
end.