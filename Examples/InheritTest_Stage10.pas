program InheritTest;
type
  TAnimal = class
  public
    function Speak: string;
  end;

  TDog = class(TAnimal)
  public
    function Speak: string;
  end;

function TAnimal.Speak: string;
begin
  Result := 'Animal sound';
end;

function TDog.Speak: string;
begin
  Result := 'Woof!';
end;

var
  a : TAnimal;
  d : TDog;
begin
  a := TAnimal.Create;
  d := TDog.Create;
  writeln(a.Speak);   // Animal sound
  writeln(d.Speak);   // Woof!
end.