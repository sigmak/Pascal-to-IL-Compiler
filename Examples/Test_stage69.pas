program Test_stage69;

// [Stage 69] yield / sequence of T — lazy evaluation 시퀀스 테스트.
// Range(a,b): a부터 b까지(포함) 정수를 하나씩 "게으르게" 만들어내는 시퀀스.
// 실제로는 함수를 호출하는 순간(Range(1,5))에는 아무 반복도 일어나지 않고,
// for..in이 MoveNext를 부를 때마다 딱 한 걸음씩만 진행된다 — Writeln들을 보면
// "생성 X" 다음에 바로 "생성 1"이 아니라, for 루프가 값을 실제로 쓸 때마다
// "생성 N" 로그가 하나씩 끼어드는 걸로 확인할 수 있다.

function Range(lo, hi: integer): sequence of integer;
var i: integer;
begin
  i := lo;
  while i <= hi do
  begin
    Writeln('  (Range 내부) 값 ' + IntToStr(i) + ' 생성');
    yield i;
    i := i + 1;
  end;
end;

// 짝수만 골라내는 시퀀스 — if 안의 yield, while 루프 중첩도 같이 확인.
function Evens(lo, hi: integer): sequence of integer;
var i: integer;
begin
  i := lo;
  while i <= hi do
  begin
    if (i mod 2) = 0 then
      yield i;
    i := i + 1;
  end;
end;

var x: integer;
begin
  Writeln('=== Range(1,5) ===');
  for x in Range(1, 5) do
    Writeln('받은 값: ' + IntToStr(x));

  Writeln('=== Evens(1,10) ===');
  for x in Evens(1, 10) do
    Writeln('짝수: ' + IntToStr(x));
end.