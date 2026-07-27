program Test_stage83;

// [Stage 83] 클래스 필드 인라인 기본값 초기화 문법: "필드명: 타입 = 식;"
//
// 두 클래스로 두 개의 서로 다른 생성자 IL 경로를 모두 검증한다:
//   1) TCounter - 사용자 정의 생성자가 전혀 없음 → BuildClassShell이 자동으로 만드는
//      기본 생성자(부모 생성자 호출 + Ret) 경로에서 필드 기본값이 적용되는지 확인.
//   2) TPlayer  - 사용자 정의 "constructor Create;"가 있음 → BuildConstructorBody 경로에서
//      필드 기본값이 사용자 본문 실행보다 먼저 적용되는지, 그리고 사용자 본문이 그 값을
//      정상적으로 읽고 덮어쓸 수 있는지 확인.
//
// [주의] 이 컴파일러의 Writeln은 인자를 하나만 받는다 (Stage 72) — 문자열 연결(+)과
// IntToStr/FloatToStr/BoolToStr로 하나의 문자열 식으로 합쳐서 넘긴다.

type
  TCounter = class
    Count: integer = 100;
    Tag: string = '카운터';
    Step: real = 0.5;
    Active: boolean = true;
  end;

  TPlayer = class
    Health: integer = 100;
    Lives: integer = 3;
    PName: string = '무명';
    constructor Create;
  end;

constructor TPlayer.Create;
begin
  // 여기서 이미 100이어야 한다 — 필드 기본값이 사용자 본문보다 먼저 적용됨.
  Writeln('생성자 진입 시 Health = ' + IntToStr(Health));
  PName := '용사'; // 사용자 본문이 기본값을 덮어씀
end;

var
  C: TCounter;
  P: TPlayer;
begin
  C := TCounter.Create;
  Writeln('Count = ' + IntToStr(C.Count));
  Writeln('Tag = ' + C.Tag);
  Writeln('Step = ' + FloatToStr(C.Step));
  Writeln('Active = ' + BoolToStr(C.Active));

  P := TPlayer.Create;
  Writeln('Health = ' + IntToStr(P.Health));
  Writeln('Lives = ' + IntToStr(P.Lives));
  Writeln('PName = ' + P.PName);
end.