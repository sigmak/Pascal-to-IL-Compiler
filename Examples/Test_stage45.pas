// ============================================================
// Stage 45 테스트: {$reference X.dll} 지시문 → 실제 어셈블리 로딩 연결
//   지금까지는 {$reference PresentationFramework.dll} 같은 지시문을 그냥 주석으로
//   통째로 무시했다 — 그래서 System.Windows.Window 같은 실제 WPF 타입은 한 번도
//   진짜로 참조해본 적이 없었다. 이번엔 진짜 WPF 어셈블리를 로드해서 Window를
//   상속하는 첫 end-to-end 테스트.
//
//   * .NET Framework(또는 WPF가 활성화된 .NET 5+ Windows 타깃) 환경에서만 동작합니다.
//   * ShowDialog/Application.Run을 부르지 않으므로 창이 뜨지는 않습니다 — 객체 생성이
//     실제 WPF 어셈블리 로딩 + 상속 체인을 타고 성공하는지가 이번 테스트의 목적입니다.
//   * 상속받은 외부 멤버(Title 등)를 직접 읽고 쓰는 건 아직 별개의 미해결 과제라
//     이번 테스트에서는 건드리지 않았습니다 — 로컬 클래스 자신의 필드만 씁니다.
// ============================================================
program Stage45Test;

{$reference C:\Windows\Microsoft.NET\Framework\v4.0.30319\WPF\PresentationFramework.dll} //실제 존재경로를 지정
{$reference C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.0\PresentationCore.dll} //실제 존재경로를 지정
{$reference C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.0\WindowsBase.dll} //실제 존재경로를 지정

uses
  System.Windows;

type
  TMyWindow = class(System.Windows.Window)
    Loaded1: boolean;
    constructor Create;
  end;

constructor TMyWindow.Create;
begin
  inherited Create;    // 실제 System.Windows.Window의 기본 생성자 호출
  Self.Loaded1 := true;
end;

var
  w: TMyWindow;

begin
  w := new TMyWindow();
  Writeln(w.Loaded1);   // True
end.