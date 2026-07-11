// ============================================================
// Stage 48 테스트:
//   1) 인라인 "var x := 식;" 문장 — begin...end 안에서 선언과 동시에 대입
//   2) 프로시저 이름 → 델리게이트 변환 — new Thread(SayHello)처럼 괄호 없이
//      이름만 넘기면 ThreadStart 델리게이트로 변환돼야 한다
//   (실제 WPF의 "var t := new System.Threading.Thread(RunApp);" 패턴을
//    WPF 어셈블리 없이도 재현 가능한 System.Threading.Thread로 그대로 테스트)
// ============================================================
program Stage48Test;

uses
  System.Threading;

procedure SayHello;
begin
  Writeln('Hello from thread');
end;

begin
  var t := new System.Threading.Thread(SayHello);  // [Stage 48] 인라인 var + 델리게이트 변환
  t.Start();
  t.Join();
  Writeln('Done');
end.