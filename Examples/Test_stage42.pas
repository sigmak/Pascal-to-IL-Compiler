// ============================================================
// Stage 42 테스트: constructor 키워드 + inherited Create(...)
//   1) 클래스 선언부의 "constructor Create;" 선언
//   2) "constructor ClassName.Create; begin ... end;" 구현
//   3) 본문 안에서 "inherited Create;" — 부모(로컬 클래스)의 기본 생성자 호출
//   4) 본문 안에서 필드 대입(Self.Field := ...)과 암시적 self 메서드 호출(Bark;)
//   5) new TDog() (Stage 40)로 실제로 이 생성자를 통해 객체가 만들어지는지 확인
// ============================================================
program Stage42Test;

type
  TAnimal = class
    Sound: string;
    procedure MakeSound;
  end;

  TDog = class(TAnimal)
    Legs: integer;
    constructor Create;
    procedure Bark;
  end;

procedure TAnimal.MakeSound;
begin
  Writeln(Self.Sound);
end;

constructor TDog.Create;
begin
  inherited Create;        // 부모(TAnimal)의 기본 생성자 호출
  Self.Sound := 'Woof';
  Self.Legs := 4;
  Bark;                    // 생성자 본문 안에서 암시적 self 메서드 호출
end;

procedure TDog.Bark;
begin
  Writeln(Self.Legs);
end;

var
  d: TDog;

begin
  d := new TDog();          // 생성자 본문이 실행되며 "4"가 먼저 출력됨
  d.MakeSound();             // 상속받은 메서드 — 생성자가 설정한 필드를 읽어 "Woof" 출력
end.