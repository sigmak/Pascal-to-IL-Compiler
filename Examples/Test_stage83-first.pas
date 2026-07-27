// ============================================================
// Test_stage83.pas — [Stage 83] 클래스 필드 인라인 기본값 초기화
//
// PascalABC.NET 문법: 클래스 선언 안에서 필드에 직접 := 식을 붙여
// 인스턴스 생성 시 자동으로 초기화되도록 하는 기능.
//
// 성공 기준:
//   FileOpened = False
//   Count = 42
//   Label = hello
//   === Stage 83 성공 ===
// 가 출력되고 컴파일·실행이 정상 완료되어야 한다.
// ============================================================
program Test_stage83;

type
  TConfig = class
  public
    FileOpened: boolean := false;
    Count: integer := 42;
    Label: string := 'hello';
  end;

var
  cfg: TConfig;
begin
  cfg := new TConfig;
  Writeln('FileOpened = ' + cfg.FileOpened.ToString);
  Writeln('Count = ' + cfg.Count.ToString);
  Writeln('Label = ' + cfg.Label);
  Writeln('=== Stage 83 성공 ===');
end.