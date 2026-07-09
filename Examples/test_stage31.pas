// ============================================================
// Stage 31 데모: 최상위 함수/프로시저의 클래스 타입 매개변수 지원
// ============================================================
program Stage31Test;

type
  TAnimal = class
    fName: string;
    function Speak: string;
    procedure Init(n: string);
  end;

  TDog = class(TAnimal)
    function Speak: string;
  end;

procedure TAnimal.Init(n: string);
begin
  fName := n;
end;

function TAnimal.Speak: string;
begin
  Result := fName + ' makes a sound';
end;

function TDog.Speak: string;
var baseMsg: string;
begin
  baseMsg := inherited Speak();
  Result := baseMsg + ' (woof!)';
end;

// [Stage 31] 최상위 함수가 클래스 타입 매개변수 a를 받는다.
function Describe(a: TAnimal): string;
begin
  Result := 'Describe: ' + a.Speak;
end;

// [Stage 31] 최상위 프로시저도 클래스 타입 매개변수를 받는다.
procedure PrintDescribe(a: TAnimal);
begin
  Writeln(Describe(a));
end;

var
  d: TDog;
begin
  d := TDog.Create;
  d.Init('Rex');
  PrintDescribe(d);   // Describe: Rex makes a sound (woof!)
end.