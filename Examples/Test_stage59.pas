// Test_stage59.pas — case...of...else 문 검증
// - 정수 단일 라벨 / 콤마로 묶은 라벨 / 범위(lo..hi) 라벨
// - char 타입 셀렉터 + 범위 라벨
// - else 절 (아무 라벨도 안 맞을 때)
// - case 자체가 for 루프 안에 있을 때도 정상 동작하는지 (조건 체인이 매 반복 재사용됨)
program Test_stage59;
var
  x: integer;
  ch: char;
  i: integer;
begin
  x := 3;
  case x of
    1: writeln('one');
    2, 3: writeln('two or three');
    4..6: writeln('four to six');
  else
    writeln('other');
  end;

  ch := 'C';
  case ch of
    'A': writeln('letter A');
    'B'..'D': writeln('letter B to D');
  else
    writeln('unknown letter');
  end;

  // else 절이 없을 때 아무 라벨도 안 맞으면 그냥 통과해야 함
  x := 99;
  case x of
    1: writeln('should not print');
  end;
  writeln('after case with no matching label, no else');

  // for 루프 안에서 반복 사용
  for i := 1 to 5 do
  begin
    case i of
      1, 2: writeln('low');
      3: writeln('mid');
      4..5: writeln('high');
    end;
  end;
end.