program Test_stage72;

// [Stage 72] PABCSystem 표준 라이브러리 (Writeln 이상의 것들).
// Abs/Sqr/Sqrt/Round/Trunc/Random, UpperCase/LowerCase/Trim/Copy/Pos,
// StrToInt/StrToFloat/FloatToStr, Ord/Chr, ReadLn.
// TBuiltinCallExprNode 하나로 전부 처리 — Parser의 화이트리스트(NormalizeBuiltinFuncName)에
// 없는 이름은 그대로 예전 경로(사용자 정의 함수/변수 등)로 흘러가므로 기존 동작에 영향 없음.

var
  i, n: integer; r: real; s, s2: string; c: char;

begin
  Writeln('=== 수치 함수 ===');
  i := -7;
  Writeln('Abs(-7) = ' + IntToStr(Abs(i)));
  Writeln('Sqr(6) = ' + IntToStr(Sqr(6)));
  r := Sqrt(2);
  Writeln('Sqrt(2) = ' + FloatToStr(r));
  r := 3.7;
  Writeln('Round(3.7) = ' + IntToStr(Round(r)));
  Writeln('Trunc(3.7) = ' + IntToStr(Trunc(r)));
  n := Random(10);
  if (n >= 0) and (n < 10) then
    Writeln('Random(10)이 [0,10) 범위 안에 있음 = true');

  Writeln('=== 문자열 함수 ===');
  s := '  Hello, PascalABC  ';
  Writeln('UpperCase = [' + UpperCase(s) + ']');
  Writeln('LowerCase = [' + LowerCase(s) + ']');
  Writeln('Trim = [' + Trim(s) + ']');
  s2 := Trim(s);
  Writeln('Copy(s2, 1, 5) = ' + Copy(s2, 1, 5));
  Writeln('Pos(''Pascal'', s2) = ' + IntToStr(Pos('Pascal', s2)));
  Writeln('Pos(''nope'', s2) = ' + IntToStr(Pos('nope', s2)));

  Writeln('=== 변환 함수 ===');
  i := StrToInt('123');
  Writeln('StrToInt(''123'') = ' + IntToStr(i));
  r := StrToFloat('3.5');
  Writeln('StrToFloat(''3.5'') = ' + FloatToStr(r));

  Writeln('=== Ord / Chr ===');
  c := 'A';
  Writeln('Ord(''A'') = ' + IntToStr(Ord(c)));
  c := Chr(66);
  Writeln('Chr(66) = ' + c);
end.