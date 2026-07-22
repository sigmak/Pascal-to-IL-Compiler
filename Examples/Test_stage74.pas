program Test_stage74;

// [Stage 74] 클래스 안의 자체 제네릭 메서드(TFoo.Bar<T>) — 클래스 자체의 제네릭(TStack<T>)과는
// 독립적: TPrinter는 제네릭 클래스가 아니지만 그 안의 메서드가 자체 타입 매개변수를 가진다.
// 1차 제약:
//   - 제네릭 메서드는 PROCEDURE만 다룬다. FUNCTION으로 T를 반환하고 그 결과를 다시 식(예:
//     IntToStr(...))에 쓰는 경우는 InferType이 아직 vtGeneric을 닫힌 타입으로 되돌리지 못해
//     별도 손질이 필요함(Stage 75 예정) — Writeln(x)처럼 T를 그대로 넘기는 것은 이미 지원됨.
//   - virtual/override/abstract와의 조합 미지원.
//   - 호출부(obj.Method<T>(...))에서 obj의 정적 클래스를 파서가 추적하지 않으므로, 제네릭
//     메서드 이름은 프로그램 전체에서 유일해야 한다(서로 다른 두 클래스가 같은 이름의 제네릭
//     메서드를 가지면 충돌).

type
  TAnimal = class
  end;

  TDog = class(TAnimal)
  end;

  TCat = class(TAnimal)
  end;

  TPrinter = class
    procedure Show<T>(x: T);
    procedure ShowConstrained<T: TAnimal>(x: T);
  end;

procedure TPrinter.Show<T>(x: T);
begin
  Writeln('Show:');
  Writeln(x);
end;

procedure TPrinter.ShowConstrained<T: TAnimal>(x: T);
begin
  Writeln('ShowConstrained:');
  Writeln(x);
end;

var
  p: TPrinter;
  d: TDog;
  c: TCat;

begin
  p := new TPrinter;
  d := new TDog;
  c := new TCat;

  Writeln('=== 제네릭 메서드 (제약 없음, 다중 호출) ===');
  p.Show<integer>(42);
  p.Show<string>('hello');

  Writeln('=== 제네릭 메서드 (제약: T: TAnimal) ===');
  p.ShowConstrained<TDog>(d);
  p.ShowConstrained<TCat>(c);
end.