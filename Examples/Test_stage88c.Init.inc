    // 이 파일은 Test_stage88c.pas의 클래스 선언 "안"에 {$include}로 그대로 끌려들어온다 —
    // 실제 레포의 uTest.Form1.inc(디자이너가 뽑아낸 InitializeComponent)와 같은 패턴.
    procedure InitializeIt;
    begin
      self.&Label := 'hello';
      self.Count := self.Count + 7;
    end;
