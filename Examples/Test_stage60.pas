program Test_stage60;

var
  i, j, n: integer;
  arr: array of integer;

begin
  // 1) while + break: i가 5가 되면 즉시 탈출 → 0,1,2,3,4만 출력
  writeln('-- while + break --');
  i := 0;
  while i < 100 do
  begin
    if i = 5 then break;
    writeln(i);
    i := i + 1;
  end;

  // 2) for + continue: 짝수만 건너뛰고 홀수만 출력 (0..9 중 1,3,5,7,9)
  writeln('-- for + continue --');
  for i := 0 to 9 do
  begin
    if (i mod 2) = 0 then continue;
    writeln(i);
  end;

  // 3) repeat...until: 최소 한 번 실행 보장, i가 3 미만이어도 본문은 한 번 돈다
  writeln('-- repeat...until --');
  i := 0;
  repeat
    writeln(i);
    i := i + 1;
  until i >= 3;

  // 4) repeat + break/continue 조합
  writeln('-- repeat + continue/break --');
  i := 0;
  repeat
    i := i + 1;
    if (i mod 2) = 0 then continue; // 짝수는 출력 건너뜀
    if i > 7 then break;            // 7 넘으면 탈출
    writeln(i);
  until i >= 100;

  // 5) 중첩 루프: break는 가장 안쪽 for만 빠져나가야 함
  writeln('-- nested loop break scope --');
  for i := 0 to 2 do
  begin
    for j := 0 to 9 do
    begin
      if j = 2 then break; // 안쪽 루프만 탈출
      writeln(i * 10 + j);
    end;
  end;

  // 6) for-in + break/continue (배열 순회)
  writeln('-- for-in + break/continue --');
  SetLength(arr, 6);
  for n := 0 to 5 do arr[n] := n * n;
  for n in arr do
  begin
    if n = 0 then continue;
    if n > 16 then break;
    writeln(n);
  end;

  writeln('done');
end.