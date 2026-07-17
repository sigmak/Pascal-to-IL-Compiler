// ============================================================
// Test_stage67.pas — Stage 67: 다차원 배열 (array of array)
// 확인 항목:
//   1) 전역 array of array of integer 선언 + SetLength(m, rows, cols)
//   2) m[i][j] := val 쓰기 / m[i][j] 읽기
//   3) 지역 array of array of integer (var 섹션)
//   4) array of array of string
//   5) array of array of real
//   6) Length(m) = 행 수
//   7) for 루프로 행렬 초기화 + 합산
// ============================================================
program Test_stage67;

var
  grid: array of array of integer;
  strGrid: array of array of string;

var
  mat: array of array of integer;
  rmat: array of array of real;
  i, j, sum: integer;

begin
  // [테스트 1] 전역 integer 2차원 배열
  SetLength(grid, 3, 4);
  grid[0][0] := 1;
  grid[0][1] := 2;
  grid[1][0] := 10;
  grid[2][3] := 99;
  Writeln('grid[0][0] = ' + grid[0][0]); // 1
  Writeln('grid[0][1] = ' + grid[0][1]); // 2
  Writeln('grid[1][0] = ' + grid[1][0]); // 10
  Writeln('grid[2][3] = ' + grid[2][3]); // 99

  // [테스트 2] Length = 행 수
  Writeln('rows = ' + Length(grid)); // 3

  // [테스트 3] for 루프로 행렬 초기화 및 합산
  SetLength(mat, 2, 3);
  for i := 0 to 1 do
    for j := 0 to 2 do
      mat[i][j] := i * 3 + j;
  // mat = [[0,1,2],[3,4,5]]
  sum := 0;
  for i := 0 to 1 do
    for j := 0 to 2 do
      sum := sum + mat[i][j];
  Writeln('sum(mat) = ' + sum); // 0+1+2+3+4+5 = 15

  // [테스트 4] 전역 string 2차원 배열
  SetLength(strGrid, 2, 2);
  strGrid[0][0] := 'hello';
  strGrid[0][1] := 'world';
  strGrid[1][0] := 'foo';
  strGrid[1][1] := 'bar';
  Writeln('strGrid[0][0] = ' + strGrid[0][0]); // hello
  Writeln('strGrid[1][1] = ' + strGrid[1][1]); // bar

  // [테스트 5] 지역 real 2차원 배열
  SetLength(rmat, 2, 2);
  rmat[0][0] := 1.5;
  rmat[1][1] := 3.14;
  Writeln('rmat[0][0] = ' + rmat[0][0]); // 1.5
  Writeln('rmat[1][1] = ' + rmat[1][1]); // 3.14

  Writeln('Stage 67 테스트 완료');
end.