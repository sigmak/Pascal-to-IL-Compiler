// ============================================================
// Stage 47 테스트: 매개변수 있는 생성자
//   1) TPerson.Create(n: string; a: integer) — 로컬 클래스의 매개변수 있는 생성자
//   2) new TPerson('Alice', 30) — 인자 있는 로컬 생성자 호출
//   3) TStudent.Create(...)에서 inherited Create(n, a) — 부모 생성자에 인자 전달(체이닝)
// ============================================================
program Stage47Test;

type
  TPerson = class
    Name1: string;
    Age1: integer;
    constructor Create(n: string; a: integer);
  end;

  TStudent = class(TPerson)
    School1: string;
    constructor Create(n: string; a: integer; sch: string);
  end;

constructor TPerson.Create(n: string; a: integer);
begin
  Self.Name1 := n;
  Self.Age1 := a;
end;

constructor TStudent.Create(n: string; a: integer; sch: string);
begin
  inherited Create(n, a);   // [Stage 47] 부모 생성자에 인자 전달
  Self.School1 := sch;
end;

var
  p: TPerson;
  s: TStudent;

begin
  p := new TPerson('Alice', 30);
  Writeln(p.Name1);   // Alice
  Writeln(p.Age1);    // 30

  s := new TStudent('Bob', 20, 'MIT');
  Writeln(s.Name1);   // Bob (부모 필드, inherited Create 경유로 설정됨)
  Writeln(s.Age1);    // 20
  Writeln(s.School1); // MIT
end.