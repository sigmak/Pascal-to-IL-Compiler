// Stage 56 테스트용 유닛 파일. StringUtils.pas와 동일하게 독립적인(다른 로컬 유닛에
// 의존하지 않는) library — DiscoverCompileOrder가 위상 정렬할 때 Entry.pas보다는
// 먼저, StringUtils.pas와는 순서 상관없이(둘 다 서로 의존하지 않으므로) 컴파일된다.
library MathUtils;

function Square(x: integer): integer;
begin
  Result := x * x;
end;

function Add3(a, b, c: integer): integer;
begin
  Result := a + b + c;
end;

end.