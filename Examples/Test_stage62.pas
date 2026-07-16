// ============================================================
// Test_stage62.pas — Stage 62: record 타입 (값 타입 의미론 — 대입 시 복사)
// 확인 항목:
//   1) 필드 여러 개(기본 타입 혼합: integer/string/real/boolean)를 가진 레코드 선언
//   2) 지역 변수 선언만으로 필드가 기본값(0/빈 문자열/0.0/false)으로 초기화됨 (new 불필요)
//   3) 필드 읽기/쓰기 (p.X, p.X := 값)
//   4) 레코드 대입(b := a)이 "값 복사"임 — 이후 b의 필드를 바꿔도 a는 그대로
//   5) 레코드를 프로시저/함수 매개변수로 넘기면 "값으로" 전달됨(호출부 원본은 안 바뀜)
//   6) 서로 다른 레코드 타입을 함께 사용
// ============================================================
program Test_stage62;

type
  TPoint = record
    X, Y: integer;
  end;

  TPerson = record
    Name: string;
    Age: integer;
    Score: real;
    Active: boolean;
  end;

procedure PrintPoint(p: TPoint);
begin
  Writeln('(' + IntToStr(p.X) + ', ' + IntToStr(p.Y) + ')');
end;

// [확인 4/5] p는 값으로 전달되므로, 여기서 필드를 바꿔도 호출한 쪽의 원본에는
// 영향이 없어야 한다.
procedure TryMutate(p: TPoint);
begin
  p.X := 9999;
  p.Y := 9999;
  Writeln('TryMutate 내부에서 본 p (수정 후): (' + IntToStr(p.X) + ', ' + IntToStr(p.Y) + ')');
end;

// [주의] "function ...: TPoint;"처럼 최상위 함수가 레코드/클래스를 반환하는 것은
// 이 컴파일러의 기존 제약(최상위 함수 반환 타입은 클래스/레코드 이름을 따로 기억하지
// 않음 — Stage 62와 무관한 기존 한계, 클래스에서도 마찬가지)때문에 아직 지원하지 않는다.
// 그래서 이 테스트는 프로시저 매개변수(값 전달)만으로 값 타입 의미론을 확인한다.

var
  a, b: TPoint;
  person: TPerson;
  zero: TPoint;

begin
  // [확인 2] 선언만으로 0으로 초기화됨
  Writeln('선언 직후 zero: ');
  PrintPoint(zero);

  // [확인 3] 필드 쓰기/읽기
  a.X := 1;
  a.Y := 2;
  Writeln('a = ');
  PrintPoint(a);

  // [확인 4] b := a는 값 복사 — b를 바꿔도 a는 그대로여야 한다
  b := a;
  b.X := 99;
  b.Y := 100;
  Writeln('b(복사 후 수정) = ');
  PrintPoint(b);
  Writeln('a(그대로여야 함) = ');
  PrintPoint(a);

  // [확인 5] 매개변수는 값으로 전달됨 — TryMutate가 뭘 하든 a는 그대로여야 한다
  TryMutate(a);
  Writeln('TryMutate 호출 후 a(여전히 그대로여야 함) = ');
  PrintPoint(a);

  // [확인 6] 서로 다른 레코드 타입(TPerson) — 문자열/실수/불리언 필드
  person.Name := 'Ada';
  person.Age := 36;
  person.Score := 98.5;
  person.Active := true;
  Writeln(person.Name + ' / ' + IntToStr(person.Age));
  Writeln(person.Score);
  Writeln(person.Active);
end.