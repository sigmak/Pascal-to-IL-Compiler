// ============================================================
// Stage 44 테스트: library 키워드 (ControlLib 산출물)
//   실제 GenerateControlLibCode가 내는 것과 같은 모양 — library 헤더, 타입 선언,
//   constructor Create; + inherited Create; + InitializeComponent 호출, 그리고
//   begin...end 초기화 블록 없이 바로 "end."으로 끝남.
//
//   * 이번 테스트는 "실행해서 뭐가 출력되나"를 볼 수 없습니다 — library는 진입점
//     (Main)이 없는 dll이라 그 자체로는 실행할 수 없습니다. 성공 기준은:
//       1) 컴파일이 에러 없이 끝나는지
//       2) Test_stage44.exe가 아니라 Test_stage44.dll이 생성되는지
//     둘 다 확인해주시면 됩니다.
// ============================================================
library Stage44Test;

uses
  System;

type
  TMyControl = class(System.Exception)
    Label1: string;
    constructor Create;
    procedure InitializeComponent;
  end;

constructor TMyControl.Create;
begin
  inherited Create;
  InitializeComponent;
end;

procedure TMyControl.InitializeComponent;
begin
  Self.Label1 := 'Hello from library';
end;

end.