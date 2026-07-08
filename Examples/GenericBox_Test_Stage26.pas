program GenericBoxTest;
type
  TBox<T> = class
  private
    fValue: T;
  public
    procedure SetValue(v: T);
    function GetValue: T;
  end;
procedure TBox.SetValue(v: T);
begin
  fValue := v;
end;
function TBox.GetValue: T;
begin
  Result := fValue;
end;
var
  intBox : TBox<integer>;
  strBox : TBox<string>;
begin
  intBox := TBox<integer>.Create;
  intBox.SetValue(42);
  writeln('intBox = ' + IntToStr(intBox.GetValue));
  strBox := TBox<string>.Create;
  strBox.SetValue('hello generics');
  writeln('strBox = ' + strBox.GetValue);
end.