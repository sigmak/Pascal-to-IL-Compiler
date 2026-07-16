// ============================================================
// Test_stage63.pas — Stage 63: set of 타입과 집합 연산 (in, +, -, *)
// 확인 항목:
//   1) set of <열거형> 변수 선언, 집합 리터럴 [a, b, ...]과 빈 집합 []
//   2) in (멤버십 검사) — 열거형 리터럴/변수 둘 다로 검사
//   3) + (합집합), * (교집합), - (차집합)
//   4) 연산을 이어붙여도(s1 + s2 - s3 등) 계속 집합으로 취급됨
//   5) 대입은 그냥 정수 비트마스크 복사이므로 별도 확인 불필요(값 타입처럼 동작)
// ============================================================
program Test_stage63;

type
  TColor = (Red, Green, Blue, Yellow, Purple);

var
  s1, s2, s3, e: set of TColor;
  c: TColor;

begin
  // [확인 1] 리터럴로 채우기
  s1 := [Red, Blue];
  s2 := [Blue, Green];

  // [확인 2] in — 리터럴 원소
  Writeln('Red in s1 (true여야 함): ' );
  Writeln(Red in s1);
  Writeln('Green in s1 (false여야 함): ');
  Writeln(Green in s1);

  // [확인 2] in — 변수 원소
  c := Green;
  Writeln('c(=Green) in s2 (true여야 함): ');
  Writeln(c in s2);
  c := Yellow;
  Writeln('c(=Yellow) in s2 (false여야 함): ');
  Writeln(c in s2);

  // [확인 3] 합집합: s1+s2 = {Red, Green, Blue}
  s3 := s1 + s2;
  Writeln('--- s3 := s1 + s2 (Red,Green,Blue여야 함) ---');
  Writeln(Red in s3);
  Writeln(Green in s3);
  Writeln(Blue in s3);
  Writeln(Yellow in s3);

  // [확인 3] 교집합: s1*s2 = {Blue}
  s3 := s1 * s2;
  Writeln('--- s3 := s1 * s2 (Blue만 있어야 함) ---');
  Writeln(Red in s3);
  Writeln(Blue in s3);
  Writeln(Green in s3);

  // [확인 3] 차집합: s1-s2 = {Red}
  s3 := s1 - s2;
  Writeln('--- s3 := s1 - s2 (Red만 있어야 함) ---');
  Writeln(Red in s3);
  Writeln(Blue in s3);

  // [확인 4] 연산 이어붙이기: (s1 + s2) - s1 = {Green} 이어야 함
  s3 := s1 + s2 - s1;
  Writeln('--- s3 := s1 + s2 - s1 (Green만 있어야 함) ---');
  Writeln(Green in s3);
  Writeln(Red in s3);
  Writeln(Blue in s3);

  // [확인 1] 빈 집합
  e := [];
  Writeln('--- e := [] (전부 false여야 함) ---');
  Writeln(Red in e);
  Writeln(Purple in e);

  Writeln('Stage 63 테스트 완료');
end.