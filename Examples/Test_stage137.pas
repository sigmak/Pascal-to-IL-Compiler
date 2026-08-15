// ============================================================
// Test_stage137.pas — Test_stage135을 더 잘게 쪼갬: pi:=nil 대입 직후
// 리터럴만 출력(비교 없음), 그 다음에야 (pi=nil) 비교를 별도 boolean
// 변수에 담아서 출력. 어느 줄에서 정확히 죽는지 좁힌다.
// ============================================================
program Test137;

uses System.Reflection;

var pi: PropertyInfo;
var b: boolean;
begin
  Writeln('[T137-0] 시작');
  pi := nil;
  Writeln('[T137-1] pi:=nil 대입 완료 (비교 없음)');
  b := (pi = nil);
  Writeln('[T137-2] b:=(pi=nil) 대입 완료');
  Writeln('[T137-3] b.ToString 호출 직전');
  Writeln('[T137-4] b=' + b.ToString);
  Writeln('[T137-5] 정상 종료');
end.