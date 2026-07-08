program OOPTest;
type
  TCounter = class
  private
    fValue : integer;
  public
    procedure Init(startVal: integer);
    procedure Increment;
    function  GetValue: integer;
  end;

procedure TCounter.Init(startVal: integer);
begin
  fValue := startVal;
end;

procedure TCounter.Increment;
begin
  fValue := fValue + 1;
end;

function TCounter.GetValue: integer;
begin
  Result := fValue;
end;

var
  c : TCounter;
begin
  c := TCounter.Create;
  c.Init(10);
  c.Increment;
  c.Increment;
  c.Increment;
  writeln(intToStr(c.GetValue));
end.