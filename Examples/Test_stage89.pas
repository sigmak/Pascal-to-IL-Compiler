// ============================================================
// Test_stage89.pas — [Stage 89] 실제 uTest.pas가 쓰는 생성자 표기를 검증한다.
//
// 실제 레포 uTest.pas의 Form1 클래스는 이렇게 되어 있다:
//   public
//     constructor;
//     begin
//       InitializeComponent;
//     end;
//   end;
//
// Stage 88c에서 procedure/function의 "시그니처 뒤 세미콜론 → 인라인 begin...end"
// 패턴은 이미 고쳤지만, 그건 이름이 있는 constructor(Create)에 대한 이야기였고
// 이번 것은 두 가지가 더 겹친다:
//   1) 생성자 이름 자체를 생략 — "constructor;" (Create의 축약형)
//   2) 그 생성자에 클래스 선언 "안"에서 바로 본문(begin...end)이 붙음
//      (별도의 최상위 "constructor ClassName.Create; begin...end;" 없이)
//
// 성공 기준: 콘솔에 "Stage89 성공: Value=42" 가 출력되어야 한다.
// ============================================================
program Test_stage89;
type
  Widget = class
  private
    val: integer;
  public
    constructor;
    begin
      val := 42;
    end;
    function GetValue: integer;
  end;

function Widget.GetValue: integer;
begin
  Result := val;
end;

var
  w: Widget;
begin
  w := Widget.Create; // 이름을 생략했어도 실제 생성자 이름은 여전히 Create
  Writeln('Stage89 성공: Value=' + w.GetValue.ToString);
end.