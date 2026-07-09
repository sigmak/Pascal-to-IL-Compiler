// ============================================================
// Stage 27 테스트: 최상위 함수/프로시저의 string/boolean/array
// 매개변수 및 반환값이 더 이상 integer로 강제되지 않는지 확인한다.
// (Stage 26까지는 BuildStaticFunc/BuildStaticProc이 모든 매개변수와
//  반환값을 무조건 typeof(integer)로 방출해서, 아래 같은 함수들은
//  IL 검증 실패 또는 값 손상을 일으켰다.)
// ============================================================
program StaticFuncTypesTest;

function Greet(name: string): string;
begin
  Result := 'Hello, ' + name + '!';
end;

function IsLong(s: string): boolean;
begin
  Result := Length(s) > 5;
end;

// [Stage 28] 이제 함수 본문 안에서도 var 섹션으로 지역 변수를 선언할 수 있다.
// (Stage 27 테스트 때는 이 기능이 없어서 a[0]+a[1]+...로 우회했었다.)
function SumArray(a: array of integer): integer;
var i, total: integer;
begin
  total := 0;
  for i := 0 to 4 do
    total := total + a[i];
  Result := total;
end;

procedure PrintTwice(msg: string; shout: boolean);
begin
  if shout then
    Writeln(msg + msg)
  else
    Writeln(msg);
end;

var
  greeting: string;
  longFlag: boolean;
  nums: array of integer;
  total: integer;

begin
  greeting := Greet('Rinachoi');
  Writeln(greeting);

  longFlag := IsLong(greeting);
  if longFlag then
    Writeln('IsLong(greeting) = true')
  else
    Writeln('IsLong(greeting) = false');

  SetLength(nums, 5);
  nums[0] := 10; nums[1] := 20; nums[2] := 30; nums[3] := 40; nums[4] := 50;
  total := SumArray(nums);
  Writeln('SumArray = ' + IntToStr(total));

  PrintTwice('echo', true);
  PrintTwice('once', false);
end.