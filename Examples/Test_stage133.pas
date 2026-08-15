// ============================================================
// Test_stage133.pas — Test_stage131과 동일하지만 첫 매개변수만 System.Type
// 대신 Integer로 바꿈 (반환 타입은 PropertyInfo 그대로 유지).
// 131은 죽고 133은 살면 "System.Type을 매개변수로 받는 것"이 범인.
// 133도 죽으면 매개변수와 무관하게 "PropertyInfo를 반환하는 함수" 자체가 범인.
// ============================================================
program Test133;

uses System.Reflection;

function TrivialFn3(t: integer; name: string): PropertyInfo;
begin
  Writeln('[MARK-TRIV3-0] 진입');
  Result := nil;
  Writeln('[MARK-TRIV3-1] 반환 직전');
end;

var pi: PropertyInfo;
begin
  Writeln('[T133] 시작');
  pi := TrivialFn3(5, 'Length');
  Writeln('[T133] pi=nil? ' + (pi=nil).ToString);
  Writeln('[T133] 정상 종료');
end.