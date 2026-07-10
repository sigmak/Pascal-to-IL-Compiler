// ============================================================
// Stage 37 테스트: 제네릭 "array of T"
//   1) function First<T>(a: array of T): T;               — 최상위 제네릭 함수의 array of T 매개변수
//   2) procedure PrintAll<T>(a: array of T; n: integer);    — 제네릭 프로시저, Length 없이 개수를 따로 받음
//   3) TArrayHelper<T>.FirstOf / PrintAll                   — 제네릭 클래스 메서드의 array of T 매개변수
//
// 알려진 제한사항(이번 단계에서 다루지 않음, 제네릭과 무관한 기존 제약):
//   - 클래스 "필드"의 array of X는 이 컴파일러가 처음부터 a[i] 형태로 인덱싱하는 걸 지원하지
//     않는다(제네릭 이전부터 있던 제약 — fArrayNames에 매개변수/지역변수만 등록되고 필드는
//     등록되지 않기 때문). 그래서 이 테스트는 배열을 항상 매개변수/지역변수로만 주고받는다.
//   - array of T를 클래스 타입 인자로 인스턴스화하는 것(예: array of TUser)은 아직 지원하지
//     않는다 — 정수/문자열 원소 배열만 가능하며, 위반 시 단형화 단계에서 명확한 에러가 난다.
// ============================================================
program Stage37Test;

type
  TArrayHelper<T> = class
    Tag: integer; // 배열과 무관한 일반 필드 (클래스가 비어있지 않게)
    function FirstOf(a: array of T): T;
    procedure PrintAll(a: array of T; n: integer);
  end;

function TArrayHelper.FirstOf(a: array of T): T;
begin
  Result := a[0];
end;

procedure TArrayHelper.PrintAll(a: array of T; n: integer);
var i: integer;
begin
  for i := 0 to n - 1 do
    Writeln(a[i]);
end;

// ---- 1) 최상위 제네릭 함수: array of T 매개변수 ----
function First<T>(a: array of T): T;
begin
  Result := a[0];
end;

// ---- 2) 최상위 제네릭 프로시저: array of T 매개변수 ----
procedure PrintAll<T>(a: array of T; n: integer);
var i: integer;
begin
  for i := 0 to n - 1 do
    Writeln(a[i]);
end;

var
  nums: array of integer;
  words: array of string;
  helper: TArrayHelper<integer>;
  wordHelper: TArrayHelper<string>;

  // 실패 케이스(주석 처리): array of T의 T 자리에 클래스 타입 인자를 주면 단형화 단계에서
  // 명확한 에러로 실패해야 한다(예: TArrayHelper<TSomeClass> 같은 인스턴스화). 현재는
  // 정수/문자열 원소 배열만 지원하므로, 실제로 시도해 보려면 위에 클래스를 하나 선언한 뒤
  // TArrayHelper<그클래스이름>.Create 를 호출해 보면 된다.

begin
  SetLength(nums, 3);
  nums[0] := 10; nums[1] := 20; nums[2] := 30;

  SetLength(words, 2);
  words[0] := 'foo'; words[1] := 'bar';

  // 1) 최상위 제네릭 함수
  Writeln(First<integer>(nums));       // 10
  Writeln(First<string>(words));       // foo

  // 2) 최상위 제네릭 프로시저
  PrintAll<integer>(nums, 3);          // 10 \n 20 \n 30
  PrintAll<string>(words, 2);          // foo \n bar

  // 3) 제네릭 클래스 메서드의 array of T 매개변수
  helper := TArrayHelper<integer>.Create;
  Writeln(helper.FirstOf(nums));       // 10
  helper.PrintAll(nums, 3);            // 10 \n 20 \n 30

  wordHelper := TArrayHelper<string>.Create;
  Writeln(wordHelper.FirstOf(words));  // foo
  wordHelper.PrintAll(words, 2);       // foo \n bar
end.