// ============================================================
// Test_stage135.pas — 함수 호출 없이, PropertyInfo 타입 지역변수를 그냥
// nil로 직접 대입한 뒤 (pi=nil).ToString만 테스트. 함수 호출/반환과
// 완전히 무관하게 "(PropertyInfo 변수=nil).ToString" 자체가 문제인지 확인.
// ============================================================
program Test135;

uses System.Reflection;

var pi: PropertyInfo;
begin
  Writeln('[T135] 시작');
  pi := nil;
  Writeln('[T135] pi=nil? ' + (pi=nil).ToString);
  Writeln('[T135] 정상 종료');
end.