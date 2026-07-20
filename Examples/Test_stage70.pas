program Test_stage70;

// [Stage 70] LINQ 스타일 확장 메서드 — sequence of T(Stage 69) 위에 Where/Select/Sum/Count/ToArray.
// 1차 제약: 소스는 sequence of T 함수 호출이거나 이 다섯 메서드 자신의 Where/Select 체이닝만
// 가능하다(지역 변수에 저장해 둔 시퀀스는 아직 미지원). Where/Select는 즉시(eager) 평가되어
// List<T>를 만들고, 그 결과는 for-in의 컬렉션 자리에 쓰거나 더 체이닝하는 용도로만 쓴다.
// Sum/Count/ToArray는 최종(terminal) 연산 — 스칼라/배열 값이라 변수에 저장해도 된다.

function Range(lo, hi: integer): sequence of integer;
var i: integer;
begin
  i := lo;
  while i <= hi do
  begin
    yield i;
    i := i + 1;
  end;
end;

var
  x: integer;
  total, cnt: integer;
  arr: array of integer;
  sarr: array of string;
begin
  Writeln('=== Where: 1..10 중 짝수만 ===');
  for x in Range(1, 10).Where(n -> n mod 2 = 0) do
    Writeln('  짝수: ' + IntToStr(x));

  Writeln('=== Select: 1..5를 제곱해서 ===');
  for x in Range(1, 5).Select(n -> n * n) do
    Writeln('  제곱: ' + IntToStr(x));

  Writeln('=== Where + Select 체이닝: 1..10 중 짝수만 골라 제곱 ===');
  for x in Range(1, 10).Where(n -> n mod 2 = 0).Select(n -> n * n) do
    Writeln('  짝수의 제곱: ' + IntToStr(x));

  Writeln('=== Sum / Count ===');
  total := Range(1, 10).Sum();
  Writeln('  1..10 합계: ' + IntToStr(total));
  cnt := Range(1, 10).Where(n -> n mod 3 = 0).Count();
  Writeln('  1..10 중 3의 배수 개수: ' + IntToStr(cnt));

  Writeln('=== Where + Select + Sum 체이닝 ===');
  total := Range(1, 10).Where(n -> n mod 2 = 0).Select(n -> n * n).Sum();
  Writeln('  1..10 중 짝수의 제곱의 합: ' + IntToStr(total));

  Writeln('=== ToArray: 3의 배수만 배열로 ===');
  arr := Range(1, 20).Where(n -> n mod 3 = 0).ToArray();
  for x in arr do
    Writeln('  3의 배수: ' + IntToStr(x));

  Writeln('=== Select로 원소 타입을 바꾸는 경우 (integer -> string) ===');
  sarr := Range(1, 3).Select(n -> IntToStr(n) + '번').ToArray();
  for x in Range(0, Length(sarr) - 1) do
    Writeln('  ' + sarr[x]);
end.