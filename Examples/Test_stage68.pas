program Test_stage68;

// [Stage 68] 클로저(변수 캡처) 테스트.
// Button1: 생성자 지역변수 clickCount를 캡처하는 람다 → __Closure1 클래스로 컴파일됨.
//   버튼을 여러 번 누르면 1, 2, 3, ... 누적되는 걸 MessageBox로 확인.
// Button2: 아무것도 캡처하지 않는 람다 → 기존 Stage64 경로(static __Lambda2)가
//   그대로 살아있는지 확인하는 회귀 테스트.
// 주의: self/inherited는 여전히 람다 본문 안에서 미지원이라(1차 제약), Button1.Text
// 처럼 필드에 직접 쓰지 않고 MessageBox.Show(정적 외부 호출)로 값을 확인한다.

{$reference System.Windows.Forms.dll}
{$apptype windows}

type
  TMainForm = class(System.Windows.Forms.Form)
  public
    Button1: System.Windows.Forms.Button;
    Button2: System.Windows.Forms.Button;
  end;

constructor TMainForm.Create;
begin
  inherited Create;

  Button1 := new System.Windows.Forms.Button();
  Button1.Text := 'Count me';
  Button1.Top := 20;
  Button1.Left := 20;

  Button2 := new System.Windows.Forms.Button();
  Button2.Text := 'No capture';
  Button2.Top := 60;
  Button2.Left := 20;

  Controls.Add(Button1);   // 추가
  Controls.Add(Button2);   // 추가

  var clickCount := 0;

  // clickCount는 이 생성자의 지역변수 — __Closure1 필드로 캡처되어 Button1을
  // 계속 눌러도(같은 델리게이트 인스턴스이므로) 값이 유지된다.
  Button1.Click += (sender, e) -> begin
    clickCount := clickCount + 1;
    System.Windows.Forms.MessageBox.Show(IntToStr(clickCount));
  end;

  // 캡처하는 바깥 변수가 없는 람다 — static __LambdaN 경로 회귀 확인.
  Button2.Click += (sender, e) -> begin
    System.Windows.Forms.MessageBox.Show('no capture');
  end;
end;

var f: TMainForm;
begin
  f := new TMainForm();
  System.Windows.Forms.Application.Run(f);
end.