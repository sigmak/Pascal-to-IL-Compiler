// Stage 56 테스트용 유닛 파일.
// library로 선언하고 begin...end 메인 블록 없이 바로 "end."으로 끝난다
// (Parser.ParseProgram: IsLibrary=true이고 Cur.Kind<>tkBegin이면 begin 없이 end 허용).
library StringUtils;

function Greet(personName: string): string;
begin
  Result := 'Hello, ' + personName + '!';
end;

function RepeatStr(s: string; times: integer): string;
var i: integer;
begin
  Result := '';
  for i := 1 to times do
    Result := Result + s;
end;

end.