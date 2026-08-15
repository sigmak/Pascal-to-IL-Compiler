// ============================================================
// Test_stage127.pas — SafeGetProperty와 똑같은 "모양"만 떼어낸 최소 재현.
// gen0(Pascal-to-IL-Compiler.exe, 자기호스팅 아님)으로 직접 컴파일+실행해서,
// 자기호스팅과 무관하게 이 "모양"(지역변수 여러 개 + if/elseif + bare try/except
// 하나) 자체가 gen0의 코드생성 버그를 트리거하는지 확인한다.
// ============================================================
program Test127;

uses System.Reflection;

function MimicSafeGetProperty(t: System.Type; name: string): PropertyInfo;
var _sgpRuntimeTypeName: string;
var _sgpTypeObj: System.Type;
begin
  Writeln('[MARK-SGP-0] 진입, t=nil? '+(t=nil).ToString+' name="'+name+'"');
  _sgpTypeObj := t.GetType();
  Writeln('[MARK-SGP-0b] t.GetType() 완료');
  _sgpRuntimeTypeName := _sgpTypeObj.Name;
  Writeln('[MARK-SGP-1] t.GetType().Name="'+_sgpRuntimeTypeName+'"');
  if _sgpRuntimeTypeName = 'TypeBuilderInstantiation' then
  begin
    Writeln('[MARK-SGP-TBI-0] TBI 분기 (재현 코드에서는 도달하지 않음)');
    Result := nil;
  end
  else if false then
  begin
    Writeln('[MARK-SGP-LOCAL-0] 로컬 분기 (재현 코드에서는 도달하지 않음)');
    Result := nil;
  end
  else
  begin
    Writeln('[MARK-SGP-2] else 분기 진입, t.GetProperty 호출 직전');
    try
      Result := t.GetProperty(name);
      Writeln('[MARK-SGP-3] t.GetProperty 완료, Result=nil? '+(Result=nil).ToString);
    except
      Writeln('[MARK-SGP-EXC-0] except 진입');
      Result := nil;
      Writeln('[MARK-SGP-EXC-1] except 종료');
    end;
  end;
  Writeln('[MARK-SGP-4] 반환 직전');
end;

var pi: PropertyInfo;
begin
  Writeln('[T127] 시작');
  pi := MimicSafeGetProperty(typeof(string), 'Length');
  Writeln('[T127] pi=nil? ' + (pi=nil).ToString);
  Writeln('[T127] 정상 종료');
end.