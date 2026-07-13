program Stage52Test;

// [Phase 2 검증용] 서로 다른 4개 복구 지점에 일부러 문법 오류를 하나씩 심어뒀다:
//   1) type 섹션 — TBroken 선언 자체가 깨짐
//   2) 최상위 procedure 선언 — 매개변수 목록이 깨짐
//   3) var 섹션 — 콜론이 빠짐
//   4) 메인 begin..end 안의 문장 — 대입 연산자가 깨짐
// 예전(Phase 2 이전) 파서라면 1번에서 즉시 멈추고 나머지 3개는 아예 안 보여줬을 것이다.
// 지금은 4개가 전부 한 번에 보고되어야 하고, 그 사이에 있는 "정상적인" 선언들
// (TPoint, DoubleIt, y, Writeln(y) 등)은 컴파일에 영향받지 않아야 한다.

type
  TPoint = class
  private
    FX: real;
  public
    property X: real read FX write FX;
  end;

  TBroken = clas          // (1) 오타: class가 아니라 clas
  end;

function DoubleIt(n: integer): integer;
begin
  Result := n * 2;
end;

procedure BadParams(a: integer; b:);   // (2) 매개변수 타입이 빠짐
begin
  Writeln(a);
end;

var
  p: TPoint;
  x: integer;
  y integer;              // (3) 콜론 누락
  z: integer;

begin
  p := TPoint.Create;
  p.X := 1.5;
  x := DoubleIt(21);
  Writeln(x);             // 42
  Writeln(p.X);           // 1.5

  z =: 10;                // (4) := 가 뒤집힘

  z := 99;
  Writeln(z);             // 99
end.