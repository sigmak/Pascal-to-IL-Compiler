// ============================================================
// Stage 30 데모: self 키워드 / as 캐스트 / inherited
// 외부 .NET 어셈블리(WPF 등) 없이 로컬 클래스만으로 세 기능을 모두 보여준다.
// ============================================================
program Stage30Test;

type
  TAnimal = class
    fName: string;
    function Speak: string;
    procedure Init(n: string);
  end;

  TDog = class(TAnimal)
    function Speak: string;
    procedure Init(n: string);
    function Describe: string;
  end;

procedure TAnimal.Init(n: string);
begin
  fName := n; // self.fName 과 동일 (필드는 항상 암시적 self)
end;

function TAnimal.Speak: string;
begin
  Result := fName + ' makes a sound';
end;

procedure TDog.Init(n: string);
begin
  inherited; // [Stage 30] bare inherited; → TAnimal.Init(n) 을 같은 인자로 그대로 호출
end;

function TDog.Speak: string;
var baseMsg: string;
begin
  baseMsg := inherited Speak(); // [Stage 30] 식으로 쓰이는 inherited — TAnimal.Speak() 호출
  Result := baseMsg + ' (woof!)';
end;

function TDog.Describe: string;
var self2: TDog;
begin
  self2 := Self as TDog; // [Stage 30] self 값 자체 + as 캐스트 (항상 성공하는 자명한 예시)
  Result := 'Describe: ' + self2.Speak;
end;

var
  d: TDog;
begin
  d := TDog.Create;
  d.Init('Rex');
  Writeln(d.Speak);     // Rex makes a sound (woof!)
  Writeln(d.Describe);  // Describe: Rex makes a sound (woof!)
end.