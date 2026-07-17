// ============================================================
// Test_stage66.pas — Stage 66: 연산자 오버로딩 (operator +, -, *)
// 확인 항목:
//   1) 레코드(TVector)에 대한 operator +, -, * 정의 및 사용
//   2) 연산자 오버로딩 체이닝: a + b + c (좌결합, 중첩 TBinOpNode)
//   3) 클래스(TMoney)에 대한 operator + 정의 및 사용 (self 필드 기반)
// ============================================================
program Test_stage66;

type
  TVector = record
    X, Y: integer;
  end;

  TMoney = class
    Amount: integer;
    constructor Create(a: integer);
  end;

constructor TMoney.Create(a: integer);
begin
  Amount := a;
end;

// [테스트 1] 레코드 operator +, -, *
operator +(a, b: TVector): TVector;
var r: TVector;
begin
  r.X := a.X + b.X;
  r.Y := a.Y + b.Y;
  Result := r;
end;

operator -(a, b: TVector): TVector;
var r: TVector;
begin
  r.X := a.X - b.X;
  r.Y := a.Y - b.Y;
  Result := r;
end;

operator *(a, b: TVector): TVector;
var r: TVector;
begin
  r.X := a.X * b.X;
  r.Y := a.Y * b.Y;
  Result := r;
end;

// [테스트 3] 클래스 operator + (self 필드 X self 필드가 아니라 매개변수 obj 필드로 접근)
operator +(a, b: TMoney): TMoney;
var r: TMoney;
begin
  r := new TMoney(a.Amount + b.Amount);
  Result := r;
end;

var
  v1, v2, v3, v4: TVector;
  m1, m2, m3: TMoney;

begin
  v1.X := 1; v1.Y := 2;
  v2.X := 3; v2.Y := 4;

  v3 := v1 + v2;
  Writeln('v3.X = ' + v3.X); // 4
  Writeln('v3.Y = ' + v3.Y); // 6

  // [테스트 2] 체이닝: v1 + v2 + v3 = (v1+v2) + v3
  v4 := v1 + v2 + v3;
  Writeln('v4.X = ' + v4.X); // 8
  Writeln('v4.Y = ' + v4.Y); // 12

  v4 := v2 - v1;
  Writeln('(v2-v1).X = ' + v4.X); // 2
  Writeln('(v2-v1).Y = ' + v4.Y); // 2

  v4 := v1 * v2;
  Writeln('(v1*v2).X = ' + v4.X); // 3
  Writeln('(v1*v2).Y = ' + v4.Y); // 8

  m1 := new TMoney(1000);
  m2 := new TMoney(2500);
  m3 := m1 + m2;
  Writeln('m3.Amount = ' + m3.Amount); // 3500

  Writeln('Stage 66 테스트 완료');
end.