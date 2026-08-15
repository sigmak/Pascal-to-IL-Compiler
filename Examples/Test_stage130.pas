// ============================================================
// Test_stage130.pas — 이등분 탐색 3단계: try/except를 완전히 빼고
// GetType().Name 체이닝만 남긴 버전. 이것도 죽으면 체이닝 자체가 범인.
// ============================================================
program Test130;

uses System.Reflection;

function MimicSafeGetProperty4(t: System.Type; name: string): PropertyInfo;
var _sgpRuntimeTypeName: string;
var _sgpTypeObj: System.Type;
begin
  Writeln('[MARK-SGP4-0] 진입, t=nil? '+(t=nil).ToString+' name="'+name+'"');
  _sgpTypeObj := t.GetType();
  Writeln('[MARK-SGP4-0b] t.GetType() 완료');
  _sgpRuntimeTypeName := _sgpTypeObj.Name;
  Writeln('[MARK-SGP4-1] t.GetType().Name="'+_sgpRuntimeTypeName+'"');
  Result := t.GetProperty(name);
  Writeln('[MARK-SGP4-2] 반환 직전');
end;

var pi: PropertyInfo;
begin
  Writeln('[T130] 시작');
  pi := MimicSafeGetProperty4(typeof(string), 'Length');
  Writeln('[T130] pi=nil? ' + (pi=nil).ToString);
  Writeln('[T130] 정상 종료');
end.