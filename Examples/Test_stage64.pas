// ============================================================
// Test_stage64.pas — Stage 64: 익명 메서드/람다 (-> 구문), 1차: 캡처 없는 람다
// 확인 항목:
//   1) (매개변수: 타입; ...) -> 문장  형태로 인라인 람다를 이벤트 핸들러 자리에 쓸 수 있음
//   2) 람다 본문은 문장 하나(여기서는 Writeln 호출) — begin...end 없이도 동작
//   3) 클로저 없음: 람다 본문은 자신의 매개변수(sender, e)와 전역만 봄 — 여기서는 그걸로 충분함
//   4) 이름 있는 핸들러(HandlerName) 방식은 그대로 계속 동작해야 함(회귀 없음) —
//      이 테스트는 WPF/WinForms 없이 System.Timers.Timer로 이벤트 구독 메커니즘만 확인한다.
// ============================================================
program Test_stage64;

var
  t: System.Timers.Timer;
  tickCount: integer;

begin
  tickCount := 0;
  t := new System.Timers.Timer(100); // 100ms마다 Elapsed 발생

  // [확인 1,2,3] 인라인 람다로 이벤트 구독 — 이름 있는 메서드를 따로 선언할 필요가 없다.
  t.Elapsed += (sender: System.Object; e: System.Timers.ElapsedEventArgs) -> Writeln('tick (람다에서 출력)');

  t.AutoReset := true;
  t.Enabled := true;

  // 타이머가 몇 번 울릴 시간을 준다.
  System.Threading.Thread.Sleep(550);

  t.Enabled := false;
  t.Stop;

  Writeln('Stage 64 테스트 완료 (위에 tick이 여러 번 찍혔어야 정상)');
end.