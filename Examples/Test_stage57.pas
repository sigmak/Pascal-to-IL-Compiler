// ============================================================
// Test_stage57.pas
// ------------------------------------------------------------
// [Stage 57] 대입문 char→string 타입 강제변환 검증용 테스트.
//
// 모두 'a'처럼 따옴표 안이 정확히 한 글자인 리터럴을 사용한다 — Lexer가
// 이런 리터럴을 무조건 TCharLiteralNode로 만들기 때문에(문법적으로는
// 짧은 문자열 리터럴일 수도 있는데), 대입 대상이 string 타입인데도
// 예전 CodeGen은 EmitExpr을 그대로 호출해 문자 코드값을 정수(Ldc_I4)로
// 스택에 올려버렸다. 그 결과가 string 슬롯/필드/배열원소에 그대로
// 저장되면서 나중에 그 값을 문자열 참조로 잘못 역참조해 크래시가 났다.
//
// 아래 5가지 대입 경로를 각각 한 번씩 건드린다:
//   1) 전역 변수 대입      (g := 'g';)
//   2) 지역 변수 대입      (t := 'L'; — LocalTest 프로시저 안)
//   3) 함수 Result 대입    (Result := 'H'; — MakeGreeting 함수 안)
//   4) 클래스 필드(self) 대입 (Caption := 'A'; — TLabel.SetCaption 안)
//   5) 문자열 배열 원소 대입  (names[0] := 'x'; 등)
//
// 고쳐지기 전이었다면 이 프로그램은 대부분의 Writeln에서 잘못된 값을
// 출력하거나(정수로 해석된 문자 코드가 아니라, 문자열 슬롯에 정수가
// 들어간 상태를 문자열로 읽으려다) NullReferenceException/크래시로
// 끝났을 것이다. 고쳐진 뒤에는 각 Writeln 옆 주석의 "기대값"이
// 그대로 출력되어야 한다.
// ============================================================
program Test_stage57;

type
  TLabel = class
    Caption: string;
    procedure SetCaption;
  end;

procedure TLabel.SetCaption;
begin
  // (4) self 필드 대입: fb.FieldType=typeof(string) 이므로
  //     EmitArgForParamType이 'A'를 Ldstr로 로드해야 한다.
  Caption := 'A';
end;

function MakeGreeting: string;
begin
  // (3) Result 대입: fResultType=vtString 이므로
  //     EmitValueForVType이 'H'를 Ldstr로 로드해야 한다.
  Result := 'H';
end;

procedure LocalTest;
var
  t: string;
begin
  // (2) 지역 변수 대입: fLocalScope.GetVType('t')=vtString.
  t := 'L';
  Writeln(t); // 기대값: L
end;

var
  g: string;
  names: array of string;
  lbl: TLabel;
  h: string;

begin
  // (1) 전역 변수 대입: fGlobalScope.GetVType('g')=vtString.
  g := 'g';
  Writeln(g); // 기대값: g

  LocalTest();

  h := MakeGreeting();
  Writeln(h); // 기대값: H

  // (5) 문자열 배열 원소 대입: at2=vtStrArray 이므로 Stelem_Ref 앞에서
  //     문자열로 승격되어야 한다 (안 그러면 GC/접근 시 크래시).
  SetLength(names, 3);
  names[0] := 'x';
  names[1] := 'y';
  names[2] := 'z';
  Writeln(names[0]); // 기대값: x
  Writeln(names[1]); // 기대값: y
  Writeln(names[2]); // 기대값: z

  lbl := new TLabel;
  lbl.SetCaption;
  Writeln(lbl.Caption); // 기대값: A
end.