// ============================================================
// Test_stage136.pas — Test_stage135과 동일하지만 지역변수 타입만
// PropertyInfo 대신 System.Type으로 바꿈. 이게 살면 PropertyInfo라는
// "특정 타입"이 범인. 죽으면 "외부 참조 타입 지역변수" 전반의 문제.
// ============================================================
program Test136;

var t2: System.Type;
begin
  Writeln('[T136] 시작');
  t2 := nil;
  Writeln('[T136] t2=nil? ' + (t2=nil).ToString);
  Writeln('[T136] 정상 종료');
end.