program StaticCallTest;
type
  TMyForm = class(System.Windows.Forms.Form)
  public
    procedure Setup;
  end;

procedure TMyForm.Setup;
begin
  Text := 'Hello from Pascal-to-IL compiler';
end;

var
  f : TMyForm;
begin
  f := TMyForm.Create;
  f.Setup;
  writeln('폼 준비 완료, Application.Run 호출 직전');
  System.Windows.Forms.Application.Run(f);
end.