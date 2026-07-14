program ForIn_Test_Stage54;

var
  nums: array of integer;
  names: array of string;
  n: integer;
  s: string;
  total: integer;

begin
  SetLength(nums, 5);
  nums[0] := 10;
  nums[1] := 20;
  nums[2] := 30;
  nums[3] := 40;
  nums[4] := 50;

  total := 0;
  for n in nums do
  begin
    total := total + n;
    Writeln(n);
  end;
  Writeln(total); // 150

  SetLength(names, 3);
  names[0] := 'Alpha';
  names[1] := 'Beta';
  names[2] := 'Gamma';

  for s in names do
    Writeln(s);
end.