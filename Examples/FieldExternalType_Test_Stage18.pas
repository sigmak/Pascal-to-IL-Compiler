program FieldExternalTypeTest;
type
  TMyForm = class(System.Windows.Forms.Form)
  public
    Button1: System.Windows.Forms.Button;
    procedure Setup;
  end;

procedure TMyForm.Setup;
begin
  Button1 := System.Windows.Forms.Button.Create;
  writeln('완료: 외부 타입 필드 선언 + 생성 성공 (예외 없음)');
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
end.
