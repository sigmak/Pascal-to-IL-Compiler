// ============================================================
// Test_stage65.pas — Stage 65: 지역(중첩) 프로시저/함수, 1차
// 확인 항목:
//   1) 최상위 함수/프로시저 안에 지역 함수/프로시저를 선언하고 호출할 수 있음
//   2) 지역 함수는 자신의 매개변수로 값을 돌려줄 수 있음 (Result 사용)
//   3) 지역 함수/프로시저는 자기 자신을 재귀 호출할 수 있음
//   4) 캡처(클로저) 없음 — 지역 서브프로그램은 자신의 매개변수/지역변수와 전역만 본다.
//      (바깥 함수의 지역변수는 안 보이므로, 필요한 값은 매개변수로 넘겨야 한다)
//   5) 같은 이름의 지역 함수가 서로 다른 바깥 함수 안에 있어도 충돌하지 않음
//   6) 파싱 순서(1차 제약): var/const 섹션 → 지역 함수/프로시저 선언 → begin
// ============================================================
program Test_stage65;

function SumSquares(n: integer): integer;
var
  i, acc: integer;
  // 지역 함수: 제곱 하나만 계산. 바깥의 n/acc를 보지 않고 자신의 매개변수만 쓴다(캡처 없음).
  function Square(x: integer): integer;
  begin
    Result := x * x;
  end;
begin
  acc := 0;
  for i := 1 to n do
    acc := acc + Square(i);
  Result := acc;
end;

procedure PrintFactorial(n: integer);
  // 지역 함수가 자기 자신을 재귀 호출.
  function Fact(k: integer): integer;
  begin
    if k <= 1 then Result := 1
    else Result := k * Fact(k - 1);
  end;
begin
  Writeln('Factorial: ' + Fact(n));
end;

// 다른 바깥 함수 안에 같은 이름(Square)의 지역 함수를 또 선언 — 이름 충돌 없어야 함.
function DoubleSquareSum(a, b: integer): integer;
  function Square(x: integer): integer;
  begin
    Result := x * x;
  end;
begin
  Result := Square(a) + Square(b);
end;

var
  total: integer;  // 최상위 구조는 원래부터 "함수/프로시저 선언 전체 → var/const 섹션 → begin" 순서를 요구합니다


begin
  total := SumSquares(4); // 1+4+9+16 = 30
  Writeln('SumSquares(4) = ' + total);

  PrintFactorial(5); // 120

  Writeln('DoubleSquareSum(3,4) = ' + DoubleSquareSum(3, 4)); // 9+16=25

  Writeln('Stage 65 테스트 완료');
end.