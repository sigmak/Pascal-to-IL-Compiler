program Stage53Test;

// [Stage 53 검증용] virtual / abstract / override
//   - TAnimal.Speak는 abstract → 본문이 없어야 하고, TAnimal 자체는 인스턴스화 불가.
//   - TAnimal.Describe는 virtual(본문 있음) → 자식이 override 안 해도 그대로 상속되어 호출됨.
//   - TDog/TCat은 각각 Speak를 override.
// 기대 출력:
//   Woof
//   Meow
//   I am an animal

type
  TAnimal = class
  public
    procedure Speak; virtual; abstract;
    procedure Describe; virtual;
  end;

  TDog = class(TAnimal)
  public
    procedure Speak; override;
  end;

  TCat = class(TAnimal)
  public
    procedure Speak; override;
  end;

procedure TAnimal.Describe;
begin
  Writeln('I am an animal');
end;

procedure TDog.Speak;
begin
  Writeln('Woof');
end;

procedure TCat.Speak;
begin
  Writeln('Meow');
end;

var
  d: TDog;
  c: TCat;

begin
  d := TDog.Create;
  c := TCat.Create;
  d.Speak;      // Woof
  c.Speak;      // Meow
  d.Describe;   // I am an animal (override 안 한 상속 virtual 메서드)

  // 아래처럼 바꾸면 컴파일 타임에 명확한 오류가 나야 정상입니다 (직접 테스트해보고 싶으면
  // 위 var 섹션에 "a: TAnimal;"을 추가하고 아래 주석을 푸세요):
  // "TAnimal"은(는) abstract 메서드를 갖고 있어 인스턴스를 생성할 수 없습니다.
  // a := TAnimal.Create;
end.