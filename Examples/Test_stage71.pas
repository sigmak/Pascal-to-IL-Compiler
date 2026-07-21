program Test_stage71;

// [Stage 71] true open generic — 최상위 제네릭 함수/프로시저를 인스턴스화(호출)마다
// 복제하는 대신(예전 방식: 단형화), 실제 CLR 오픈 제네릭 메서드 "하나"로 컴파일한다
// (Reflection.Emit의 MethodBuilder.DefineGenericParameters 사용). 호출부는
// MakeGenericMethod로 그 자리에서 닫아(close) 호출한다.
// 1차 제약: 타입 매개변수에 제약조건이 없고(T: 뭐뭐 형태 없음), "array of T" 매개변수가
// 없고, 중첩 서브프로그램이 없는 템플릿만 이 방식이 적용된다 — 그 외는 예전처럼
// 인스턴스화마다 복제(단형화)된다(Monomorphize.pas의 IsFuncOpenGenericEligible/
// IsProcOpenGenericEligible이 판정).

function Identity<T>(x: T): T;
begin
  Result := x;
end;

function First<A, B>(a: A; b: B): A;
begin
  Result := a;
end;

procedure PrintTwice<T>(x: T);
begin
  Writeln(x);
  Writeln(x);
end;

var
  i: integer; s: string; b: boolean;

begin
  Writeln('=== Identity<T> — 서로 다른 타입 인자로 같은 템플릿 호출 ===');
  i := Identity<integer>(42);
  Writeln('  Identity<integer>(42) = ' + IntToStr(i));

  s := Identity<string>('hello');
  Writeln('  Identity<string>(' + #39 + 'hello' + #39 + ') = ' + s); // ''작은따옴표는 ' + #39 + ' 이렇게 대체함.

  b := Identity<boolean>(true);
  if b then Writeln('  Identity<boolean>(true) = true');

  Writeln('=== First<A, B> — 타입 매개변수 2개 ===');
  i := First<integer, string>(7, 'ignored');
  Writeln('  First<integer,string>(7, ' + #39 + 'ignored' + #39 + ') = ' + IntToStr(i)); // ''작은따옴표는 ' + #39 + ' 이렇게 대체함.

  Writeln('=== PrintTwice<T> — 제네릭 프로시저 + Writeln(제네릭 값) ===');
  PrintTwice<integer>(99);
  PrintTwice<string>('two');
end.