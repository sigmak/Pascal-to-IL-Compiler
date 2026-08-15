// ============================================================
// Test_stage131.pas — 이등분 탐색 4단계: 함수 본문을 완전히 비우고
// "Result:=nil;" 하나만 남긴 버전. 시그니처(System.Type,string):PropertyInfo는
// 그대로 유지. 이것도 죽으면 GetProperty/GetType/try-except와 무관하게
// 이 시그니처(특히 반환 타입 PropertyInfo) 자체가 범인이라는 뜻이다.
// ============================================================
program Test131;

uses System.Reflection;

function TrivialFn(t: System.Type; name: string): PropertyInfo;
begin
  Writeln('[MARK-TRIV-0] 진입');
  Result := nil;
  Writeln('[MARK-TRIV-1] 반환 직전');
end;

var pi: PropertyInfo;
begin
  Writeln('[T131] 시작');
  pi := TrivialFn(typeof(string), 'Length');
  Writeln('[T131] pi=nil? ' + (pi=nil).ToString);
  Writeln('[T131] 정상 종료');
end.