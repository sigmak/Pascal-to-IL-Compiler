// ============================================================
// Test_stage61.pas — Stage 61: const 선언 (전역/지역, 타입 추론 포함)
// 확인 항목:
//   1) 함수/프로시저 본문의 지역 const (타입 추론 + 명시적 타입)
//   2) 지역 const와 지역 var가 함께(순서 상관없이) 쓰이는 경우
//   3) 전역 const, 타입 추론 (integer/string/real)
//   4) 전역 const, 명시적 타입 지정
//   5) 이미 선언된 전역 const를 뒤따르는 전역 const의 초기값 식에서 참조
//   6) var 섹션과 const 섹션이 여러 번 번갈아 나오는 경우
//
// [주의] 함수/프로시저는 소스 구조상 전역 var/const 섹션보다 앞에 와야 한다
// (파서가 함수/프로시저 구현부를 한 번에 소비한 뒤에야 전역 var/const를 파싱하기 때문).
// 또한 전역 var/const는 실제로는 Main 메서드 자신의 로컬 슬롯으로 구현되어 있어서
// (기존 Stage 44 주석 참고) 별도 함수/프로시저 본문에서는 참조할 수 없다 — 이 컴파일러의
// 기존 구조적 제약이며 Stage 61과 무관하다. 그래서 아래 함수/프로시저는 자기 자신의
// 매개변수/지역 const/지역 var만 사용한다.
// ============================================================
program Test_stage61;

function Square(n: integer): integer;
const
  Two = 2;                        // 지역 const, 타입 추론
begin
  Result := n * Two;
end;

procedure ShowInfo;
const
  Tag: string = 'Info';           // 지역 const, 명시적 타입
  Limit = 100;                    // 지역 const, 타입 추론
var
  temp: integer;                  // 지역 const 섹션 다음에 오는 지역 var 섹션
begin
  temp := Limit - 37;
  Writeln(Tag + ': ' + IntToStr(temp));
end;

const
  MaxRetries = 3;                 // 정수 리터럴 → vtInteger로 추론
  Greeting = 'Hello, const!';     // 문자열 리터럴 → vtString으로 추론
  Ratio: real = 3.14159;          // 명시적 타입(real) — 정수/문자열이 아닌 타입 강제 지정
  Initial = MaxRetries * 10 + 1;  // 앞서 선언된 전역 const(MaxRetries)를 식에서 참조

var
  counter: integer;               // const 섹션 사이에 낀 var 섹션

const
  Suffix = '!!!';                 // var 섹션 뒤에 다시 이어지는 const 섹션

begin
  counter := Initial;
  Writeln(Greeting + Suffix);
  Writeln('MaxRetries = ' + IntToStr(MaxRetries));
  Writeln(Ratio);
  Writeln('Square(5) = ' + IntToStr(Square(5)));
  ShowInfo();
  Writeln('counter = ' + IntToStr(counter));
end.