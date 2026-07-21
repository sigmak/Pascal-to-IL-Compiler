program Test_stage73;

// [Stage 73] Stage 71의 true open generic(TypeBuilder/MethodBuilder.DefineGenericParameters)
// 파이프라인을 두 가지로 확장:
//   1) 다중 타입 매개변수: function/procedure Name<T, U>(...)
//   2) 제약조건: <T: TBase> / <T: IInterface> / <T: class> 가 있어도 더 이상 단형화(Monomorphize)로
//      밀려나지 않고, GenericTypeParameterBuilder에 SetBaseTypeConstraint/SetInterfaceConstraints/
//      SetGenericParameterAttributes로 실제 CLR 제약을 건다.
// 제네릭 메서드(클래스 안의 자체 제네릭 메서드, 예: TList<T>.Map<U>)는 이번 단계 범위 밖 — Stage 74 예정.

type
  TAnimal = class
  end;

  TDog = class(TAnimal)
  end;

  TCat = class(TAnimal)
  end;

// ---- 1) 다중 타입 매개변수 (제약 없음) ----
function FirstOf<T, U>(a: T; b: U): T;
begin
  Result := a;
end;

procedure ShowPair<T, U>(a: T; b: U);
begin
  Writeln(a);
  Writeln(b);
end;

// ---- 2) 제약조건 (T: TAnimal) ----
procedure Announce<T: TAnimal>(x: T);
begin
  Writeln('동물 등장:');
  Writeln(x);
end;

var
  d: TDog;
  c: TCat;

begin
  Writeln('=== 다중 타입 매개변수 ===');
  Writeln('FirstOf<integer,string>(42, ''ignored'') = ' + IntToStr(FirstOf<integer, string>(42, 'ignored')));
  ShowPair<integer, string>(7, 'hello');

  Writeln('=== 제약조건 (T: TAnimal) ===');
  d := new TDog;
  c := new TCat;
  Announce<TDog>(d);
  Announce<TCat>(c);
end.