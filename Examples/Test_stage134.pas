// ============================================================
// Test_stage134.pas — Test_stage131과 동일하지만, 반환값을 받은 뒤
// (pi=nil).ToString 비교를 하지 않고 그냥 리터럴 문자열만 출력.
// 이게 살면 "(반환받은 변수=nil).ToString" 조합이 범인.
// 이것도 죽으면 함수 호출→반환 자체(그 뒤에 뭘 하든 무관)가 범인.
// ============================================================
program Test134;

uses System.Reflection;

function TrivialFn5(t: System.Type; name: string): PropertyInfo;
begin
  Writeln('[MARK-TRIV5-0] 진입');
  Result := nil;
  Writeln('[MARK-TRIV5-1] 반환 직전');
end;

var pi: PropertyInfo;
begin
  Writeln('[T134] 시작');
  pi := TrivialFn5(typeof(string), 'Length');
  Writeln('[T134] 호출 반환 완료 (pi 미사용)');
  Writeln('[T134] 정상 종료');
end.