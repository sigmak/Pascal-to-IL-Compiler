program StringTest;

var
  name   : string;
  count  : integer;
  msg    : string;

begin
  name := 'World';
  count := 3;
  msg := 'Hello, ' + name + '!';
  writeln(msg);
  writeln('Count = ' + intToStr(count));
end.