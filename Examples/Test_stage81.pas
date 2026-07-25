// ============================================================
// Test_stage81.pas — [Stage 81] unit 파일 구조 최소 지원 검증
//
// 목표: 실제 PascalABC.NET 유닛 파일의 뼈대(unit Name; interface ...
// implementation ... end.)를, 다른 유닛과의 실제 링크 없이 "이 파일 하나만"
// 파싱 + 코드생성할 수 있는지 확인한다. (크로스 유닛 uses 해석은 Stage 82)
//
// unit은 program과 달리 실행 진입점(var/begin...end 메인 블록)이 없다.
// 그래서 Stage 44에서 만든 library(dll 산출) 경로를 그대로 재사용한다 —
// Parser가 "unit Name;"을 보면 IsLibrary:=true, IsUnit:=true로 표시하고,
// 이후 interface 섹션의 type 선언은 기존 type 섹션 파싱을, implementation
// 섹션의 메서드 구현은 기존 생성자/함수/프로시저 구현 파싱을 그대로 재사용한다.
//
// 성공 기준: 실행 결과 화면에 아무 진단 출력도 뜨지 않는다(진입점이 없으므로
// 당연함) — 대신 컴파일러 콘솔에 "[4/4] 코드생성 완료: Test_stage81.dll
// 생성됨" / "성공!"이 떠야 한다.
// ============================================================
unit Test_stage81;

interface

uses
  System.Windows.Forms;

type
  TGreeter = class
  private
    Prefix: string;
  public
    constructor Create;
    procedure Greet(name: string);
    function Louder(msg: string): string;
  end;

implementation

constructor TGreeter.Create;
begin
  Prefix := '[Stage81]';
end;

procedure TGreeter.Greet(name: string);
begin
  Writeln(Prefix + ' Hello, ' + name + '!');
end;

function TGreeter.Louder(msg: string): string;
begin
  // [검증] 단일 세그먼트 string 매개변수에 대한 인스턴스 메서드 호출 —
  // Stage 79에서 고친 typeof(string) 리플렉션 우회 경로를 다시 확인.
  Result := msg.ToUpper;
end;

end.