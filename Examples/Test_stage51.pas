program Stage51Test;
type
  TDirection = (North, South, East, West);
  TPoint = class
  private
    FX, FY: real;
  public
    property X: real read FX write FX;
    property Y: real read FY write FY;
  end;
var
  p: TPoint;
  d: TDirection;
  c: char;
  n: int64;
begin
  p := TPoint.Create;
  p.X := 3.14;
  p.Y := 2.71;
  Writeln(p.X);        // 3.14
  d := North;
  c := #65;            // 'A'
  c := 'Z';
  n := 9999999999;
  Writeln(n);
end.