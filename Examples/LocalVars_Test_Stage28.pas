// ============================================================
// Stage 28 테스트: 함수/프로시저/메서드 본문 안의 지역 변수 선언(var 섹션).
// Stage 27까지는 ParseFuncDecl/ParseProcDecl/ParseMethodImpl이 매개변수
// 목록 바로 다음에 곧장 tkBegin을 기대해서, 아래처럼 본문 안에 var 섹션이
// 있으면 파싱 자체가 실패했다 ("예상 tkBegin 실제 tkVar").
// ============================================================
program LocalVarsTest;

type
  TCounter = class
    Total: integer;
    procedure Reset;
    procedure AddAll(a: array of integer; n: integer);
    function GetTotal: integer;
  end;

procedure TCounter.Reset;
begin
  Total := 0;
end;

// 메서드 본문 안 지역 변수(i) — BuildMethodBody 쪽 Stage 28 처리 확인용
procedure TCounter.AddAll(a: array of integer; n: integer);
var i: integer;
begin
  for i := 0 to n - 1 do
    Total := Total + a[i];
end;

// [참고] 이 컴파일러는 아직 "obj.필드"처럼 클래스 밖에서 필드를 직접 읽는 것을
// 지원하지 않는다(같은 이름의 0-인자 메서드 호출로 파싱됨) — Stage 28과는
// 별개의 기존 제약이라 게터 메서드로 우회한다.
function TCounter.GetTotal: integer;
begin
  Result := Total;
end;

// 최상위 함수 본문 안 지역 변수(i, sum) — BuildStaticFunc 쪽 Stage 28 처리 확인용
function Average(a: array of integer; n: integer): integer;
var i, sum: integer;
begin
  sum := 0;
  for i := 0 to n - 1 do
    sum := sum + a[i];
  Result := sum / n;
end;

// 최상위 프로시저 본문 안 지역 변수 — BuildStaticProc 쪽 Stage 28 처리 확인용
procedure PrintDoubled(x: integer);
var doubled: integer;
begin
  doubled := x * 2;
  Writeln('Doubled = ' + IntToStr(doubled));
end;

var
  c: TCounter;
  nums: array of integer;
  avg: integer;

begin
  SetLength(nums, 5);
  nums[0] := 10; nums[1] := 20; nums[2] := 30; nums[3] := 40; nums[4] := 50;

  c := TCounter.Create;
  c.Reset;
  c.AddAll(nums, 5);
  Writeln('Total = ' + IntToStr(c.GetTotal));

  avg := Average(nums, 5);
  Writeln('Average = ' + IntToStr(avg));

  PrintDoubled(avg);
end.