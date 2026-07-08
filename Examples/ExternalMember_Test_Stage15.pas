program ExternalMemberTest;
type
  TMyForm = class(System.Windows.Forms.Form)
  public
    procedure Setup;
  end;

procedure TMyForm.Setup;
begin
  Text := 'Hello from Pascal-to-IL compiler';
  Dispose;
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
  writeln('완료: Text 속성 설정 + Dispose 메서드 호출 성공 (예외 없음)');
end.