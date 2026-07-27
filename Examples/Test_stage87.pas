// ============================================================
// Test_stage87.pas — [Stage 87] "object" 매개변수 타입(.NET System.Object) 지원 검증.
// 실제 uFileMonitoring.pas의 OnFileChangedEvent(sender: object; e: ...) 시그니처처럼,
// WinForms/이벤트 핸들러 관용구에서 자주 쓰이는 "sender: object" 매개변수를 파싱/코드생성할 수
// 있는지 확인한다. Stage 87 이전에는 "object"가 알려지지 않은 타입으로 처리되어 파싱 오류가 났고,
// 그 오류가 파일 맨 마지막 구현부에서 나면 오류 복구 로직이 유닛의 마지막 "end."까지 통째로
// 삼켜버려 엉뚱한 "예상 tkEnd 실제 tkEOF" 오류로 나타났다(Stage 87에서 오류 복구도 같이 개선).
//
// 성공 기준: 콘솔에 아래 두 줄이 출력되어야 한다.
//   "Stage87 성공: object 매개변수로 다른 타입 인자를 넘길 수 있음"
//   "Stage87 성공: 끝"
// ============================================================
program Test_stage87;

type
  Logger = class
  private
    lastKind: string;
  public
    procedure HandleEvent(sender: object; e: object);
    function LastKind: string;
  end;

procedure Logger.HandleEvent(sender: object; e: object);
begin
  lastKind := sender.GetType.Name;
end;

function Logger.LastKind: string;
begin
  Result := lastKind;
end;

var
  log: Logger;

begin
  log := Logger.Create;

  // object 매개변수에 문자열을 넘긴다 — 참조 타입이라 그대로 전달 가능해야 한다.
  log.HandleEvent('hello', nil);
  if log.LastKind = 'String' then
    Writeln('Stage87 성공: object 매개변수로 다른 타입 인자를 넘길 수 있음')
  else
    Writeln('실패: object 매개변수 타입 처리 오류 (' + log.LastKind + ')');

  Writeln('Stage87 성공: 끝');
end.