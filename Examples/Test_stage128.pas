// ============================================================
// Test_stage128.pas — Test_stage127의 이등분 탐색 1단계.
// if/elseif 체인을 완전히 제거하고, GetType().Name 체이닝 + bare try/except만
// 남긴 최소 버전. 이게 여전히 죽으면 "if/else 안에 try/except가 있는 구조"가
// 아니라 try/except 자체(혹은 GetType().Name 체이닝)가 범인이라는 뜻이다.
// ============================================================
program Test128;

uses System.Reflection;

function MimicSafeGetProperty2(t: System.Type; name: string): PropertyInfo;
var _sgpRuntimeTypeName: string;
var _sgpTypeObj: System.Type;
begin
  Writeln('[MARK-SGP2-0] 진입, t=nil? '+(t=nil).ToString+' name="'+name+'"');
  _sgpTypeObj := t.GetType();
  Writeln('[MARK-SGP2-0b] t.GetType() 완료');
  _sgpRuntimeTypeName := _sgpTypeObj.Name;
  Writeln('[MARK-SGP2-1] t.GetType().Name="'+_sgpRuntimeTypeName+'"');

  Writeln('[MARK-SGP2-2] t.GetProperty 호출 직전 (if/elseif 없이 곧바로)');
  try
    Result := t.GetProperty(name);
    Writeln('[MARK-SGP2-3] t.GetProperty 완료, Result=nil? '+(Result=nil).ToString);
  except
    Writeln('[MARK-SGP2-EXC-0] except 진입');
    Result := nil;
    Writeln('[MARK-SGP2-EXC-1] except 종료');
  end;
  Writeln('[MARK-SGP2-4] 반환 직전');
end;

var pi: PropertyInfo;
begin
  Writeln('[T128] 시작');
  pi := MimicSafeGetProperty2(typeof(string), 'Length');
  Writeln('[T128] pi=nil? ' + (pi=nil).ToString);
  Writeln('[T128] 정상 종료');
end.