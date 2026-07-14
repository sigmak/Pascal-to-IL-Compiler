// Stage 56 테스트용 entry 파일.
// uses 절의 StringUtils/MathUtils는 실제로 같은 폴더(Units\)에 존재하는 .pas 파일이므로
// [Stage 55]가 로컬 유닛으로 인식해 컴파일 순서에 포함시키고,
// [Stage 56]이 그 둘을 이 파일과 하나의 TProgramNode로 병합한다.
// 아래 Greet/RepeatStr(StringUtils)와 Square/Add3(MathUtils) 호출이 성공적으로
// 컴파일되면(=선언되지 않은 함수 오류 없이) 병합이 제대로 된 것이다.
program Entry;

uses StringUtils, MathUtils;

var
  greeting, repeated: string;
  sq, total: integer;

begin
  greeting := Greet('World');
  Writeln(greeting);

  sq := Square(7);
  Writeln('Square(7) = ' + sq);

  total := Add3(1, 2, 3);
  Writeln('Add3(1,2,3) = ' + total);

  repeated := RepeatStr('ab', 3);
  Writeln('RepeatStr(ab,3) = ' + repeated);
end.