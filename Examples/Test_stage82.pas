// ============================================================
// Test_stage82.pas — [Stage 82] 진짜 멀티 파일: uses가 실제로 다른 .pas 유닛 파일을
// 찾아 그 안의 public 함수만 링크한다 (파일 2개짜리 최소 예제)
//
// Stage82_MathUtils.pas(같은 폴더에 있어야 함)를 uses한다. 컴파일러는:
//   1. uses 절에서 "Stage82_MathUtils"를 읽고 실제로 Stage82_MathUtils.pas 파일을
//      찾아낸다(Stage 55 유닛 탐색 재사용).
//   2. 그 파일을 실제로 Lex/Parse해서, interface 섹션에 시그니처가 있는 이름
//      (Add, Doubled, PrintBanner)만 이 파일의 파서에 "아는 이름"으로 넘긴다
//      (Stage 82의 핵심 — 이전 단계는 그 파일이 아는 이름을 통째로 넘겼다).
//   3. implementation에만 있는 DoubleIt은 넘어가지 않는다 — 그래서 아래 주석
//      처리된 호출을 풀면 "알 수 없는" 이름이라 구문 오류가 난다.
//
// 성공 기준: 콘솔에
//   Add(3, 4) = 7
//   Doubled(5) = 10
//   === Stage 82 성공 ===
// 이 출력되고, "[유닛링크]" 로그와 함께 "성공! ... .exe 이 생성되었습니다."로 끝나야 한다.
// ============================================================
program Test_stage82;

uses
  Stage82_MathUtils;

var
  sum, dbl: integer;

begin
  sum := Add(3, 4);
  dbl := Doubled(5);
  Writeln('Add(3, 4) = ' + sum.ToString);
  Writeln('Doubled(5) = ' + dbl.ToString);
  PrintBanner('Stage 82 성공');

  // [실험용] 아래 줄의 주석을 풀고 다시 컴파일해 보면 실패해야 정상이다 — DoubleIt은
  // Stage82_MathUtils.pas의 implementation에만 있는 비공개 헬퍼라서, 이 파일의 파서는
  // 애초에 그 이름을 모른다(Stage 82가 검증하려는 핵심 지점).
  // Writeln(DoubleIt(9).ToString);
end.