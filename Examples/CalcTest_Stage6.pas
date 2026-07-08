program CalcTest;

function Add(a, b: integer): integer;
begin
  Result := a + b;
end;

procedure PrintLine(n: integer);
begin
  writeln(n);
end;

var
  x, y, z : integer;
begin
  x := 10;
  y := 32;
  z := Add(x, y);
  PrintLine(z);
end.
