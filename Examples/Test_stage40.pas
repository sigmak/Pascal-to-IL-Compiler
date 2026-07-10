// ============================================================
// Stage 40 테스트: `new TypeName(args)` 객체 생성 구문
//   1) 로컬 클래스, 인자 없는 new() — 기존 "TypeName.Create"와 동등해야 함
//   2) 외부 .NET 타입, 인자 있는 생성자 — new 없이는 원천적으로 불가능했던 케이스
//      (System.Exception(string) — 1개짜리 오버로드라 인자 개수만으로도 모호함이 없음)
// ============================================================
program Stage40Test;

type
  TCounter = class
    Value: integer;
    function GetValue: integer;
  end;

function TCounter.GetValue: integer;
begin
  Result := Self.Value;
end;

var
  c: TCounter;

begin
  // 1) 로컬 클래스, 인자 없는 new
  c := new TCounter();
  Writeln(c.GetValue());              // 0

  // 2) 외부 타입, 인자 1개짜리 생성자
  try
    raise new System.Exception('boom from new');
  except
    on e: Exception do
      Writeln(e.Message);            // boom from new
  end;
end.