// ============================================================
// Test_stage129.pas — 이등분 탐색 2단계: GetType().Name 체이닝을 완전히 빼고
// bare try/except만 남긴 버전. 이것도 죽으면 try/except 자체가 범인.
// ============================================================
program Test129;

uses System.Reflection;

function MimicSafeGetProperty3(t: System.Type; name: string): PropertyInfo;
begin
  Writeln('[MARK-SGP3-0] 진입, t=nil? '+(t=nil).ToString+' name="'+name+'"');
  try
    Result := t.GetProperty(name);
    Writeln('[MARK-SGP3-1] t.GetProperty 완료, Result=nil? '+(Result=nil).ToString);
  except
    Writeln('[MARK-SGP3-EXC-0] except 진입');
    Result := nil;
    Writeln('[MARK-SGP3-EXC-1] except 종료');
  end;
  Writeln('[MARK-SGP3-2] 반환 직전');
end;

var pi: PropertyInfo;
begin
  Writeln('[T129] 시작');
  pi := MimicSafeGetProperty3(typeof(string), 'Length');
  Writeln('[T129] pi=nil? ' + (pi=nil).ToString);
  Writeln('[T129] 정상 종료');
end.