// ============================================================
// Stage 49 테스트: on ex: Type do 블록에서 .Message 말고 다른 멤버 접근
//   (WPF 진입점 템플릿의 System.Windows.Forms.MessageBox.Show(ex.ToString(), ...) 패턴)
// ============================================================
program Stage49Test;

begin
  try
    raise new System.Exception('boom');
  except
    on ex: System.Exception do
    begin
      Writeln(ex.Message);      // 기존에도 되던 것 — boom
      Writeln(ex.ToString());   // [Stage 49] 새로 되는 것 — "System.Exception: boom" 계열 문자열
                                 // (정확한 포맷은 런타임마다 조금 다를 수 있음 — 에러 없이
                                 //  "boom"이 포함된 문자열이 찍히면 성공)
    end;
  end;
end.