// ============================================================
// Stage 43 테스트:
//   1) on ex: System.Exception do — 점(.)으로 연결된 예외 타입 이름 파싱 (이번 단계 수정 사항, B1)
//   2) 지금까지의 기능(Stage 37~42)을 모두 합쳐 WPF InitializeComponent 스타일 메서드를
//      최소 재현 — 실제 WPF/XAML 대신 mscorlib 타입만으로 같은 "모양"의 코드를 구성했다.
//      (PresentationFramework 등 실제 어셈블리 참조 연결은 별개 과제 — Stage 39 부록 참고)
//
//   재현하는 패턴:
//     - 외부 타입을 부모로 상속 + 그 부모를 다시 로컬 클래스가 상속(2단 체이닝)
//     - constructor Create; 안에서 inherited Create; 로 부모 생성자 체이닝
//     - 생성자 안에서 InitializeComponent 스타일 메서드를 암시적 self 호출로 실행
//     - 그 메서드 안에서: 로컬 변수(외부 dotted 타입) + new(인자 있는 외부 생성자) +
//       try/finally(외부 인스턴스 메서드 Dispose 호출) + try/except on 절(dotted 예외 타입)
// ============================================================
program Stage43Test;

type
  TAppBase = class(System.Exception)
    constructor Create;
  end;

  TMyApp = class(TAppBase)
    Label1: string;
    constructor Create;
    procedure InitializeComponent;
  end;

constructor TAppBase.Create;
begin
  inherited Create;              // 외부 부모(System.Exception)의 기본 생성자 호출
end;

constructor TMyApp.Create;
begin
  inherited Create;              // 로컬 부모(TAppBase) 생성자 호출 → 그 안에서 다시 외부로 체이닝
  InitializeComponent;           // 암시적 self 호출 (생성자 본문 안에서)
end;

procedure TMyApp.InitializeComponent;
var
  sr: System.IO.StringReader;    // [Stage 41] 로컬 변수의 외부 dotted 타입
  line: string;
begin
  sr := new System.IO.StringReader('Hello from InitializeComponent'); // [Stage 40] 인자 있는 외부 생성자
  try
    line := sr.ReadLine();
  finally
    sr.Dispose();
  end;
  Self.Label1 := line;

  try
    raise new System.Exception('simulated init error');
  except
    on ex: System.Exception do        // [Stage 43] dotted 예외 타입
      Writeln(ex.Message);
  end;
end;

var
  app: TMyApp;

begin
  app := new TMyApp();
  Writeln(app.Label1);
end.