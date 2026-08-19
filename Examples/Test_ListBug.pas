// List.Add / 인덱서(get_Item) 격리 테스트.
// VisitUnitForOrder 안의 "order.Add(filePath); ... order[order.Count-1]"에서
// Add 직후 값이 null로 나오는 문제를 재현하기 위한 최소 예제.
// - Test1: 최상위(top-level) begin...end 안에서 바로 List 사용
// - Test2: VisitUnitForOrder와 똑같은 모양(procedure에 파라미터로 List을 전달)으로 사용
program Test_ListBug;

uses
  System.Collections.Generic;

procedure TestViaParam(lst: List<string>; s: string);
begin
  Writeln('[TestViaParam] Add 직전 s = "' + s + '"');
  lst.Add(s);
  Writeln('[TestViaParam] Add 직후 lst.Count = ' + lst.Count.ToString);
  if lst.Count > 0 then
  begin
    if lst[lst.Count - 1] = nil then
      Writeln('[TestViaParam] lst[마지막] = <-- 문제 재현됨')
    else
      Writeln('[TestViaParam] lst[마지막] = "' + lst[lst.Count - 1] + '"');
  end;
  // foreach로도 한 번 더 확인 (인덱서가 아니라 Add 자체가 문제인지 교차검증)
  var _seen: string := '';
  foreach var _item in lst do
    _seen := _item;
  if _seen = nil then
    Writeln('[TestViaParam] foreach 마지막 값 = ')
  else
    Writeln('[TestViaParam] foreach 마지막 값 = "' + _seen + '"');
end;
  
var
  lst1: List<string>;
   v: string;
begin
  // ---- Test1: 최상위 블록에서 바로 ----
  Writeln('=== Test1: 최상위 블록 ===');
  lst1 := new List<string>;
  v := 'hello-toplevel';
  Writeln('Add 직전 v = "' + v + '"');
  lst1.Add(v);
  Writeln('Add 직후 lst1.Count = ' + lst1.Count.ToString);
  if lst1[0] = nil then
    Writeln('lst1[0] = <-- 문제 재현됨')
  else
    Writeln('lst1[0] = "' + lst1[0] + '"');
  
  Writeln;
  // ---- Test2: VisitUnitForOrder와 동일한 형태(파라미터로 전달된 List) ----
  Writeln('=== Test2: 파라미터로 전달된 List ===');
  TestViaParam(lst1, 'hello-viaparam');
  
  Writeln;
  Writeln('=== 끝 ===');
end.