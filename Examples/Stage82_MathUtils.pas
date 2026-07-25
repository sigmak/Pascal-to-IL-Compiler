// ============================================================
// Stage82_MathUtils.pas — [Stage 82] "진짜" 유닛 파일
//
// Test_stage82.pas(진입점)와 반드시 같은 폴더에 둔다 — Main.pas의 유닛 탐색은
// 항상 entry 파일이 있는 폴더를 첫 번째 검색 경로로 쓴다.
//
// 이 파일의 interface 섹션에는 "본문 없는" 함수/프로시저 시그니처만 있다
// (Add, Doubled, PrintBanner). 이 세 이름만 이 유닛의 공개 API가 되어, 이 유닛을
// uses하는 다른 파일에서 호출할 수 있다.
//
// implementation 섹션에는 그 세 개의 실제 본문 + 그 어디에도 interface 시그니처가
// 없는 DoubleIt이 하나 더 있다. DoubleIt은 "이 유닛만 아는" 비공개 헬퍼다 — 같은
// 파일 안에서는(Doubled 안에서처럼) 자유롭게 부를 수 있지만, 이 유닛을 uses하는
// 다른 파일의 파서에는 그 이름 자체가 전달되지 않는다. Test_stage82.pas 맨 아래
// 주석 처리된 호출을 살려보면 이걸 직접 확인할 수 있다.
// ============================================================
unit Stage82_MathUtils;

interface

// [Stage 82] 시그니처만 — 본문은 없다("function ... ;"으로 바로 끝남).
// 실제 본문은 아래 implementation 섹션에 같은 이름으로 다시 나온다.
function Add(a, b: integer): integer;
function Doubled(x: integer): integer;
procedure PrintBanner(msg: string);

implementation

function Add(a, b: integer): integer;
begin
  Result := a + b;
end;

// [Stage 82] interface에 시그니처가 없는 함수 — 이 유닛의 "비공개" 구현 세부사항.
// Main.pas가 다음 파일(uses하는 쪽)에 이 이름을 넘기지 않으므로, 다른 파일의 파서는
// 이 이름 자체를 모른다. 아래 Doubled가 이 함수를 부르므로, 이 컴파일러는(중첩
// 서브프로그램과 달리 최상위 함수는 서로 미리 스캔해두지 않는다) 반드시 이 함수가
// 텍스트 상 Doubled보다 먼저 나와야 한다 — 안 그러면 "아직 모르는 이름"이 되어
// Doubled의 몸통을 파싱할 때 구문 오류가 난다.
function DoubleIt(n: integer): integer;
begin
  Result := n * 2;
end;

function Doubled(x: integer): integer;
begin
  // 공개 API인 Doubled가 내부적으로 비공개 헬퍼 DoubleIt을 쓴다 — 이 유닛 내부에서는
  // interface/implementation 구분 없이 서로 다 보이므로 문제없다.
  Result := DoubleIt(x);
end;

procedure PrintBanner(msg: string);
begin
  Writeln('=== ' + msg + ' ===');
end;

end.