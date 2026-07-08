program ArrayTest;
var
  nums : array of integer;
  i    : integer;
  sum  : integer;
begin
  SetLength(nums, 5);
  nums[0] := 10;
  nums[1] := 20;
  nums[2] := 30;
  nums[3] := 40;
  nums[4] := 50;
  sum := 0;
  i := 0;
  while i < 5 do
  begin
    sum := sum + nums[i];
    i := i + 1;
  end;
  writeln('Sum = ' + intToStr(sum));  // 기대: Sum = 150
end.