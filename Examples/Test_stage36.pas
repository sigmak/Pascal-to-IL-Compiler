// ============================================================
// Stage 36 테스트: 최상위 제네릭 함수/프로시저
//   1) function Identity<T>(x: T): T;           — 가장 단순한 형태, 기본형 두 가지로 인스턴스화
//   2) function Duplicate<T>(x: T): T;           — 본문 안의 지역변수(var temp: T)가 제대로 치환되는지
//   3) function Describe<T: IEntity>(x: T): integer; — 제네릭 함수의 제약조건(Stage 34)
//   4) procedure ShowBoth<T>(a, b: T);           — 제네릭 프로시저, 클래스 타입 인자
//   5) function WrapBox<T: class>(x: T): T;      — 'class' 제약조건이 함수에도 그대로 적용되는지
//
// 주의(현재 지원 범위):
//   - 명시적 타입 인자 호출만 지원한다: Identity<integer>(5) — Identity(5)처럼 타입 추론은 아직 안 됨.
//   - 제네릭 함수 안에서 자기 자신이나 다른 제네릭 함수를 "바깥 T 그대로" 재귀 호출하는 것은 아직 지원하지 않음.
//   - var(참조) 매개변수는 이 컴파일러 자체가 아직 지원하지 않으므로 여기서도 다루지 않는다.
// ============================================================
program Stage36Test;

type
  IEntity = interface
    function GetId: integer;
  end;

  TUser = class(IEntity)
    fId: integer;
    function GetId: integer;
    procedure SetId(v: integer);
  end;

function TUser.GetId: integer;
begin
  Result := fId;
end;

procedure TUser.SetId(v: integer);
begin
  fId := v;
end;

// ---- 1) 가장 단순한 제네릭 함수 ----
function Identity<T>(x: T): T;
begin
  Result := x;
end;

// ---- 2) 본문 안에 제네릭 타입 지역변수가 있는 경우 ----
function Duplicate<T>(x: T): T;
var
  temp: T;
begin
  temp := x;
  Result := temp;
end;

// ---- 3) 인터페이스 제약조건이 걸린 제네릭 함수 ----
function Describe<T: IEntity>(x: T): integer;
begin
  Result := x.GetId;
end;

// ---- 4) 제네릭 프로시저 (클래스 타입 인자) ----
procedure ShowBoth<T>(a, b: T);
begin
  Writeln(a);
  Writeln(b);
end;

// ---- 5) 'class' 제약조건 — 참조 타입만 허용 ----
function WrapBox<T: class>(x: T): T;
begin
  Result := x;
end;

var
  i1, i2: integer;
  s1: string;
  u: TUser;
  boxedUser: TUser;

  // 실패 케이스(주석 처리): 주석을 풀면 각각 명확한 에러로 컴파일이 실패해야 한다.
  // badWrap: integer; badWrap := WrapBox<integer>(5);        // T: class 위반 — integer는 클래스가 아님
  // badDesc: integer; badDesc := Describe<TDummy>(...);       // T: IEntity 위반 — TDummy는 IEntity 미구현

begin
  // 1) 기본형 두 가지로 인스턴스화
  i1 := Identity<integer>(42);
  Writeln(i1);                      // 42

  s1 := Identity<string>('hello');
  Writeln(s1);                      // hello

  // 2) 지역변수(temp: T)를 거쳐도 값이 그대로 보존되는지
  i2 := Duplicate<integer>(99);
  Writeln(i2);                      // 99

  // 3) 인터페이스 제약조건 — IEntity를 구현하는 TUser는 통과
  u := TUser.Create;
  u.SetId(707);
  Writeln(Describe<TUser>(u));      // 707

  // 4) 제네릭 프로시저 — 클래스 타입 인자
  ShowBoth<integer>(1, 2);          // 1 \n 2
  ShowBoth<string>('a', 'b');       // a \n b

  // 5) class 제약조건 — 클래스 타입 인자는 통과
  boxedUser := WrapBox<TUser>(u);
  Writeln(boxedUser.GetId);         // 707
end.