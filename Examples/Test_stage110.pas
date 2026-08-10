// ============================================================
// Test_stage110.pas — 최소 재현: "필드 := 외부 메서드 호출(인자 0개, 배열 반환)" 대입
// TLexer.Create의 "fChars:=src.ToCharArray;"에서 재현된 것과 똑같은 패턴만 떼어냈다.
// 이 파일 하나만 test_self.exe로 컴파일해서 같은 NullReferenceException이 나는지 확인한다.
// ============================================================
program Test110;

type
  TX = class
  private
    fChars: array of char;
  public
    constructor Create(src: string);
    begin
      Writeln('[T110] Create 진입, src.Length=' + src.Length.ToString);
      try
        fChars:=src.ToCharArray;
        Writeln('[T110] fChars:=src.ToCharArray 완료, Length(fChars)=' + Length(fChars).ToString);
      except
        on E: Exception do
        begin
          Writeln('[T110-EXC] 예외 타입: ' + E.GetType.FullName);
          Writeln('[T110-EXC] E.Message: ' + E.Message);
          Writeln('[T110-EXC] E.ToString (전체): ' + E.ToString);
          if E.InnerException<>nil then
            Writeln('[T110-EXC] InnerException: ' + E.InnerException.ToString);
          raise;
        end;
      end;
    end;
  end;

var
  x: TX;
begin
  x := new TX('hello world');
  Writeln('[T110] 정상 종료');
end.