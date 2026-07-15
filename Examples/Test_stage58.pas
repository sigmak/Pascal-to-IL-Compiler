// test_Stage58.pas
// -----------------------------------------------------------------------
// Stage 58(선언부 단위 에러 복구) 테스트용 예제.
// 이 파일은 "컴파일이 성공해야" 하는 파일이 아니다 — 일부러 3군데를 깨뜨려서,
// panic-mode 복구가 제대로 동작하면 컴파일러가:
//   1) 첫 번째 오류에서 죽지 않고 끝까지 파싱을 계속하고,
//   2) 마지막에 오류 3건을 한꺼번에(각자 줄 번호와 함께) 보고하고,
//   3) 깨진 부분과 무관한 나머지 선언(TAnimal 전체, TDog의 Name/Bark,
//      TColor, ShowColor의 정상 문장들)은 정상적으로 파싱됐어야 한다
// 는 것을 확인하는 용도다. (ParseErrors.Count>0이면 최종적으로는 컴파일
// 실패로 보고되는 게 맞다 — 목표는 "실패해도 진단이 정확하고 한 번에 다 보이는 것".)
program Test_Stage58;

type
  // ---- 정상 클래스: 문제 없이 그대로 파싱되어야 한다 ----
  TAnimal = class
    Name: string;
    function Speak: string;
  end;

  // ---- [고의 오류 #1] 클래스 멤버 단위 복구 테스트 ----
  // Age 필드에 타입이 빠져 있다("Age: ;"). Stage 58 이전이었다면 이 오류 하나 때문에
  // TDog 클래스 전체(Name, Bark까지)가 통째로 사라졌다. 이제는 Age 필드 하나만
  // 버려지고 Name/Bark는 정상적으로 살아남아야 한다.
  TDog = class
    Name: string;
    Age: ;
    function Bark: string;
  end;

  // ---- [고의 오류 #2] 타입 선언 단위 복구 테스트 ----
  // "=" 뒤에 class/interface/열거형 목록 중 아무것도 오지 않는 완전히 깨진 선언.
  // 이 타입 하나만 버려지고, 바로 다음 TColor 선언부터는 정상 파싱되어야 한다.
  TBroken = ;

  TColor = (Red, Green, Blue);

function TAnimal.Speak: string;
begin
  Result := 'Some sound';
end;

function TDog.Bark: string;
begin
  Result := 'Woof';
end;

procedure ShowColor(c: integer);
begin
  // ---- [고의 오류 #3] 중첩 블록 안 오류 — ParseStatementsUntilEnd 버그 회귀 테스트 ----
  // Writeln() 안에 식이 없어서(바로 ')') 이 문장 파싱이 실패한다. 버그가 있었다면
  // 복구 과정에서 이 안쪽 begin...end의 'end'를 procedure 본문 자체의 끝으로 착각해서,
  // 아래 마지막 Writeln('after nested block') 문장을 통째로 놓치고 파싱이 어긋났다.
  // 지금은 깊이를 추적하므로 이 안쪽 오류만 버려지고, 바깥의 마지막 문장은 정상적으로
  // 파싱되어야 한다.
  if c > 0 then
  begin
    Writeln();
    Writeln('nested ok');
  end;
  Writeln('after nested block');
end;

begin
  ShowColor(1);
end.