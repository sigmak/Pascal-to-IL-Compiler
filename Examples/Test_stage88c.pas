// ============================================================
// Test_stage88c.pas — [Stage 88c] 세 가지를 한꺼번에 검증:
//   1) &Label — Label처럼 예약어와 충돌할 수 있는 이름을 강제로 평범한 식별자로
//      쓰는 이스케이프 문법. Lexer가 '&'를 소비하고 뒤의 이름만 토큰 텍스트로 남긴다
//      (키워드 조회 자체를 건너뛴다).
//   2) internal — private/public과 나란히 쓰는 새 가시성 키워드. 지금은 접근 제어를
//      실제로 강제하지 않으므로 private/public과 똑같이 "건너뛰기"만 하면 된다.
//   3) {$include Test_stage88c.Init.inc} — 클래스 선언 "내부"에서 전개되어, 시그니처와
//      본문(begin...end)이 한 덩어리로 그대로 클래스 안에 들어온다. 실제 레포의
//      uTest.pas + uTest.Form1.inc(디자이너가 만든 InitializeComponent)가 정확히
//      이 패턴이라, 그걸 시도하기 전에 작은 재현으로 먼저 검증한다.
//
// 성공 기준: 콘솔에 "Stage88c 성공: Label=hello, Count=7"이 출력되어야 한다.
// ============================================================
program Test_stage88c;

type
  Widget = class
  private
    &Label: string;
    internal Count: integer;
  public
    constructor Create;
    {$include Test_stage88c.Init.inc}
  end;

constructor Widget.Create;
begin
  &Label := '';
  Count := 0;
  InitializeIt; // {$include}로 들어온, 클래스 안에서 본문까지 정의된 메서드 호출
end;

var
  w: Widget;

begin
  w := Widget.Create;
  Writeln('Stage88c 성공: Label=' + w.&Label + ', Count=' + w.Count.ToString);
end.