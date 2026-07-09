program TestStage29;

uses
  System.Windows,
  System.Windows.Controls;

type
  TCounter = class
  private
    fValue: integer;
  public
    procedure Init(v: integer);
    function GetValue: integer;
  end;

procedure TCounter.Init(v: integer);
begin
  fValue := v;
end;

function TCounter.GetValue: integer;
begin
  Result := fValue;
end;

var
  c: TCounter;
begin
  c := nil;
  if c = nil then
    Writeln('c is nil before creation')
  else
    Writeln('unexpected');

  c := TCounter.Create;
  c.Init(10);

  if c <> nil then
    Writeln('c is not nil: ' + IntToStr(c.GetValue));
end.