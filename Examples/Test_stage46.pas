// ============================================================
// Stage 46 테스트: 상속받은 외부 멤버(Title 등) 읽기/쓰기
//   Stage 45에서 "아직 별개의 미해결 과제"로 남겨뒀던 부분 —
//   TMyWindow가 상속한 System.Windows.Window의 Title 프로퍼티를
//   1) 생성자 안에서 Self.Title := '...' (self 암시적 쓰기)
//   2) main에서 w.Title := '...' (외부 변수 경유 쓰기)
//   3) main에서 Writeln(w.Title) (외부 변수 경유 읽기, 괄호 없는 obj.field 형태)
//   세 경로 전부를 검증한다.
// ============================================================
program Stage46Test;

{$reference C:\Windows\Microsoft.NET\Framework\v4.0.30319\WPF\PresentationFramework.dll}
{$reference C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.0\PresentationCore.dll}
{$reference C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.0\WindowsBase.dll}

uses
  System.Windows;

type
  TMyWindow = class(System.Windows.Window)
    Loaded1: boolean;
    constructor Create;
  end;

constructor TMyWindow.Create;
begin
  inherited Create;
  Self.Loaded1 := true;
  Self.Title := 'Hello from Self';   // [Stage 46] self 암시적 외부 프로퍼티 쓰기
end;

var
  w: TMyWindow;

begin
  w := new TMyWindow();
  Writeln(w.Loaded1);       // True (Stage 45)
  Writeln(w.Title);         // 'Hello from Self' (Stage 46 읽기)
  w.Title := 'Changed outside';   // [Stage 46] 외부 변수 경유 쓰기 (기존에도 동작하던 경로)
  Writeln(w.Title);         // 'Changed outside'
end.