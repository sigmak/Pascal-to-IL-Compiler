// ============================================================
// Stage 41 테스트: 로컬 변수(var 섹션) dotted 외부 .NET 타입 지원
//   이전에는 매개변수/필드에서만 "System.EventArgs" 같은 점(.)으로 연결된
//   외부 타입을 쓸 수 있었고, 함수/프로시저/메서드 본문의 지역 변수 선언은
//   로컬 클래스 이름만 허용했다(그 결과 지역변수는 항상 System.Object로
//   선언되어 그 위에서 멤버 호출을 할 수 없었다). 이제 지역 변수 선언에서도
//   똑같이 동작해야 한다.
//   1) 최상위 함수 본문의 지역변수 — System.Random, 인자 2개짜리 메서드 호출
//   2) 최상위 프로시저 본문의 지역변수 — System.Text.StringBuilder, 메서드 호출을
//      문(statement)으로 실행 후 속성(Length) 읽기
// ============================================================
program Stage41Test;

function RollTwice: integer;
var
  rnd: System.Random;      // [Stage 41] 외부 타입 지역변수 — 인자 없는 생성자
  a, b: integer;
begin
  rnd := new System.Random();
  a := rnd.Next(1, 7);      // 1~6
  b := rnd.Next(1, 7);      // 1~6
  Result := a + b;
end;

procedure Greet(name: string);
var
  sb: System.Text.StringBuilder;   // [Stage 41] 외부 타입 지역변수 — 두 번째 케이스
begin
  sb := new System.Text.StringBuilder();
  sb.Append(name);
  Writeln(sb.Length);
end;

var
  total: integer;

begin
  total := RollTwice();
  Writeln(total >= 2);   // true — 주사위 두 개 눈의 합은 항상 2 이상
  Writeln(total <= 12);  // true — 항상 12 이하
  Greet('Rina');         // 4  ('Rina'.Length)
end.