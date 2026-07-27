// ============================================================
// Test_stage84.pas — [Stage 84] 실제 PascalABC.net_imitate 레포
// (https://github.com/sigmak/PascalABC.net_imitate)에서 가장 작은 파일부터
// 하나씩 실제로 컴파일해보는 단계의 첫 번째: uRunProcessOptions.pas.
//
// uRunProcessOptions.pas는 레포 원본 그대로(uses 절만 이 파일에 추가) 옮겨왔다:
//   RunProcessOptions = class
//     Process: System.Diagnostics.Process := nil;
//   end;
//
// 이 한 파일을 실제로 링크/컴파일하려면 아래 두 가지가 먼저 돼 있어야 했다:
//   1) 클래스 필드 인라인 기본값 초기화에서 ":=" 표기 지원 (Stage 83은 "="만 지원했음 —
//      실제 레포 코드는 ":="을 쓴다는 게 이번에 드러남)
//   2) System.Diagnostics 네임스페이스(Process) 자동 어셈블리 탐색 등록
//
// 성공 기준: 콘솔에 "Process 필드 기본값 nil 확인 성공"이 출력되어야 한다.
// ============================================================
program Test_stage84;

uses
  uRunProcessOptions;

var
  Opt: RunProcessOptions;

begin
  Opt := RunProcessOptions.Create;
  if Opt.Process = nil then
    Writeln('Process 필드 기본값 nil 확인 성공')
  else
    Writeln('실패: Process가 nil이 아님');
end.