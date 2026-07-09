// ============================================================
// Stage 34 테스트: 제네릭 제약조건 (T: TBaseClass, T: IInterface, T: class)
// ============================================================
program Stage34Test;

type
  ISpeaker = interface
    function Speak: string;
  end;

  TAnimal = class
    fName: string;
    function Speak: string;
    procedure Init(n: string);
  end;

  TDog = class(TAnimal)
    function Speak: string;
  end;

  TRobot = class(ISpeaker)
    function Speak: string;
  end;

  // [Stage 34] T는 TAnimal(또는 그 자손)이어야 한다
  TAnimalBox<T: TAnimal> = class
    Value: T;
    function GetValue: T;
    procedure SetValue(v: T);
  end;

  // [Stage 34] T는 ISpeaker를 구현해야 한다
  TSpeakerBox<T: ISpeaker> = class
    Value: T;
    function GetValue: T;
    procedure SetValue(v: T);
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
begin
  Result := fName + ' barks';
end;

function TRobot.Speak: string;
begin
  Result := 'beep boop';
end;

function TAnimalBox.GetValue: T;
begin
  Result := Value;
end;

procedure TAnimalBox.SetValue(v: T);
begin
  Value := v;
end;

function TSpeakerBox.GetValue: T;
begin
  Result := Value;
end;

procedure TSpeakerBox.SetValue(v: T);
begin
  Value := v;
end;

var
  d: TDog;
  box: TAnimalBox<TDog>;      // TDog는 TAnimal의 자손 → 제약조건 만족
  robo: TRobot;
  sbox: TSpeakerBox<TRobot>;  // TRobot은 ISpeaker 구현 → 제약조건 만족
  boxed: TDog;
  spoken: TRobot;

begin
  d := TDog.Create;
  d.Init('Rex');
  box := TAnimalBox<TDog>.Create;
  box.SetValue(d);
  boxed := box.GetValue;
  Writeln(boxed.Speak);       // Rex barks

  robo := TRobot.Create;
  sbox := TSpeakerBox<TRobot>.Create;
  sbox.SetValue(robo);
  spoken := sbox.GetValue;
  Writeln(spoken.Speak);      // beep boop

  // 아래 줄의 주석을 풀면 컴파일 타임에 제약조건 위반으로 실패해야 한다
  // (TRobot은 TAnimal의 자손이 아니므로 TAnimalBox<TRobot>은 허용되지 않음):
  // var badBox: TAnimalBox<TRobot>;
  // badBox := TAnimalBox<TRobot>.Create;
end.