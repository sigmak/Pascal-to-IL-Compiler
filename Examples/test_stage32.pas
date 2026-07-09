// ============================================================
// Stage 32 테스트: 제네릭 확장
//   1) 다중 타입 매개변수: TPair<K, V> = class ... end;
//   2) 중첩 제네릭 인스턴스화: TBox<TBox<integer>>
// ============================================================
program Stage32Test;

type
  TBox<T> = class
    Value: T;
    function GetValue: T;
    procedure SetValue(v: T);
  end;

  TPair<K, V> = class
    First: K;
    Second: V;
    function GetFirst: K;
    function GetSecond: V;
    procedure SetFirst(f: K);
    procedure SetSecond(s: V);
  end;

function TBox.GetValue: T;
begin
  Result := Value;
end;

procedure TBox.SetValue(v: T);
begin
  Value := v;
end;

function TPair.GetFirst: K;
begin
  Result := First;
end;

function TPair.GetSecond: V;
begin
  Result := Second;
end;

procedure TPair.SetFirst(f: K);
begin
  First := f;
end;

procedure TPair.SetSecond(s: V);
begin
  Second := s;
end;

var
  intBox: TBox<integer>;
  strBox: TBox<string>;
  p: TPair<integer, string>;
  innerBox: TBox<integer>;
  nestedBox: TBox<TBox<integer>>;
  unpacked: TBox<integer>;

begin
  // 1) 기본 단일 타입 매개변수 (기존 기능, 회귀 확인)
  intBox := TBox<integer>.Create;
  intBox.SetValue(42);
  Writeln(intBox.GetValue);          // 42

  strBox := TBox<string>.Create;
  strBox.SetValue('hello');
  Writeln(strBox.GetValue);          // hello

  // 2) [Stage 32] 다중 타입 매개변수: TPair<K, V>
  p := TPair<integer, string>.Create;
  p.SetFirst(7);
  p.SetSecond('world');
  Writeln(p.GetFirst);               // 7
  Writeln(p.GetSecond);              // world

  // 3) [Stage 32] 중첩 제네릭 인스턴스화: TBox<TBox<integer>>
  innerBox := TBox<integer>.Create;
  innerBox.SetValue(99);

  nestedBox := TBox<TBox<integer>>.Create;
  nestedBox.SetValue(innerBox);

  unpacked := nestedBox.GetValue;
  Writeln(unpacked.GetValue);        // 99
end.