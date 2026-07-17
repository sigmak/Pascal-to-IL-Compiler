// ============================================================
// Test_stage65b.pas — Stage 65b: 지역 서브프로그램끼리 선언 순서 무관 호출
// 확인 항목:
//   1) 나중에 선언된 지역 함수를 먼저 선언된 지역 함수가 호출할 수 있음 (순방향)
//   2) 먼저 선언된 지역 함수를 나중에 선언된 지역 함수가 호출할 수 있음 (역방향)
//   3) 지역 함수끼리 상호 재귀 호출 (A → B → A → ...)
//   4) 지역 프로시저가 지역 함수를 (선언 전에) 호출할 수 있음
//   5) 바깥 함수의 begin 블록에서도 (나중에 선언된) 지역 서브프로그램 호출 가능
// ============================================================
program Test_stage65b;

// [테스트 1] 역방향 참조: IsOdd가 IsEven보다 먼저 선언되지만 IsEven을 호출
// IsEven은 IsOdd 뒤에 선언됨 → pre-scan 없이는 실패
function IsEvenOrOdd(n: integer): integer;
  // IsOdd 안에서 IsEven 호출 — IsEven은 아직 선언 안 됨(역방향 참조)
  function IsOdd(x: integer): integer;
  begin
    if x = 0 then Result := 0
    else Result := IsEven(x - 1); // 역방향 호출
  end;

  function IsEven(x: integer): integer;
  begin
    if x = 0 then Result := 1
    else Result := IsOdd(x - 1); // 순방향 호출(이미 선언됨)
  end;
begin
  Result := IsEven(n); // 1이면 짝수, 0이면 홀수
end;

// [테스트 2] 상호 재귀 피보나치 분해
// FibHelper1, FibHelper2 서로 호출
function FibMutual(n: integer): integer;
  function FibA(k: integer): integer;
  begin
    if k <= 0 then Result := 0
    else if k = 1 then Result := 1
    else Result := FibB(k - 1) + FibA(k - 2); // FibB 역방향
  end;

  function FibB(k: integer): integer;
  begin
    if k <= 0 then Result := 0
    else if k = 1 then Result := 1
    else Result := FibA(k - 1) + FibB(k - 2);
  end;
begin
  Result := FibA(n);
end;

// [테스트 3] 지역 프로시저가 나중에 선언된 지역 함수를 호출
// (주의) 지역 서브프로그램은 캡처(클로저) 없이 fGlobalScope에서만 스코프가 시작되므로
// ShowResult 안에서 PrintSum의 매개변수 a, b를 직접 참조할 수 없다.
// 그래서 a, b를 캡처하는 대신 ShowResult 자신의 매개변수(x, y)로 넘겨 받는다 —
// 이러면 여전히 "프로시저가 아직 선언되지 않은 지역 함수(Compute)를 호출"하는
// 항목 4의 취지를 그대로 검증할 수 있다.
procedure PrintSum(a, b: integer);
  procedure ShowResult(label_: string; x, y: integer);
  begin
    Writeln(label_ + ': ' + Compute(x, y)); // Compute는 아래 선언(역방향 호출)
  end;

  function Compute(x, y: integer): integer;
  begin
    Result := x + y;
  end;
begin
  ShowResult('Sum', a, b);
end;

var
  r: integer;

begin
  // 테스트 1: 짝/홀 상호재귀
  r := IsEvenOrOdd(4);
  Writeln('IsEven(4) = ' + r); // 1 (짝수)
  r := IsEvenOrOdd(7);
  Writeln('IsEven(7) = ' + r); // 0 (홀수)

  // 테스트 2: 상호재귀 피보나치
  Writeln('FibMutual(0) = ' + FibMutual(0)); // 0
  Writeln('FibMutual(1) = ' + FibMutual(1)); // 1
  Writeln('FibMutual(6) = ' + FibMutual(6)); // 8

  // 테스트 3: 프로시저→함수 역방향
  PrintSum(10, 20); // Sum: 30

  Writeln('Stage 65b 테스트 완료');
end.