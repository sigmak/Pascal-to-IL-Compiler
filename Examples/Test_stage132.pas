// ============================================================
// Test_stage132.pas — Test_stage131과 동일하지만 반환 타입만 PropertyInfo 대신
// System.Object로 바꿈. 131은 죽고 132는 살면 "PropertyInfo라는 특정 타입"이
// 범인. 둘 다 죽으면 "외부 참조 타입을 반환하는 함수" 전반의 문제.
// 둘 다 살면 System.Type을 매개변수로 받는 것 자체는 무관.
// ============================================================
program Test132;

uses System.Reflection;

function TrivialFn2(t: System.Type; name: string): System.Object;
begin
  Writeln('[MARK-TRIV2-0] 진입');
  Result := nil;
  Writeln('[MARK-TRIV2-1] 반환 직전');
end;

var o: System.Object;
begin
  Writeln('[T132] 시작');
  o := TrivialFn2(typeof(string), 'Length');
  Writeln('[T132] o=nil? ' + (o=nil).ToString);
  Writeln('[T132] 정상 종료');
end.