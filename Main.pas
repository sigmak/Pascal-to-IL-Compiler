// ============================================================
// Main.pas — 진입점. Stage마다 바뀌는 건 원칙적으로 TestSource
// (테스트용 Pascal 소스 문자열)와 Writeln 안내 문구뿐이어야 함.
// Lexer/Parser/CodeGen 로직은 각 unit 파일에서 관리.
// ============================================================
program Main;

uses
  System.Text,
  System.Collections.Generic,
  AST,
  Lexer,
  Parser,
  CodeGen;

const
  TestSource =
    'program HandlerParamsTest;' + #10 +
    'type' + #10 +
    '  TMyForm = class(System.Windows.Forms.Form)' + #10 +
    '  public' + #10 +
    '    Button1: System.Windows.Forms.Button;' + #10 +
    '    ClickCount: integer;' + #10 +
    '    procedure Setup;' + #10 +
    '    procedure Button1_Click(sender: System.Object; e: System.EventArgs);' + #10 +
    '  end;' + #10 +
    '' + #10 +
    'procedure TMyForm.Button1_Click(sender: System.Object; e: System.EventArgs);' + #10 +
    'begin' + #10 +
    '  ClickCount := ClickCount + 1;' + #10 +
    '  writeln(''핸들러 호출됨. sender.ToString = '' + sender.ToString);' + #10 +
    '  writeln(''ClickCount='' + IntToStr(ClickCount));' + #10 +
    'end;' + #10 +
    '' + #10 +
    'procedure TMyForm.Setup;' + #10 +
    'begin' + #10 +
    '  Button1 := System.Windows.Forms.Button.Create;' + #10 +
    '  Button1.Click += Button1_Click;' + #10 +
    '  Button1_Click(Button1, System.EventArgs.Create);' + #10 +
    '  writeln(''완료: 핸들러에서 sender 매개변수 사용 성공'');' + #10 +
    'end;' + #10 +
    '' + #10 +
    'var' + #10 +
    '  f : TMyForm;' + #10 +
    'begin' + #10 +
    '  f := TMyForm.Create;' + #10 +
    '  f.Setup;' + #10 +
    'end.';

var
  lexer: TLexer; tokens: List<TToken>;
  parser: TParser; prog: TProgramNode;
  codegen: TCodeGenerator; outputName: string;

begin
  Writeln('=== Stage 21: 핸들러에서 sender/e 매개변수 실제 사용 ===');
  Writeln('--- 입력 소스 ---'); Writeln(TestSource); Writeln;

  try
    lexer:=new TLexer(TestSource);
    tokens:=lexer.Tokenize;
    Writeln('[1/3] 토큰화 완료: '+tokens.Count.ToString+'개 토큰');

    parser:=new TParser(tokens);
    prog:=parser.ParseProgram;
    Writeln('[2/3] 구문분석 완료: 클래스 '+prog.ClassDecls.Count.ToString
      +'개, 메서드구현 '+prog.MethodImpls.Count.ToString+'개');

    outputName:='HandlerParams_Test_Stage21.exe';
    codegen:=new TCodeGenerator(prog);
    codegen.AddReferenceAssembly('System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089');
    codegen.GenerateExe(outputName);
    Writeln('[3/3] 코드생성 완료: '+outputName+' 생성됨');

    Writeln;
    Writeln('=====================================================');
    Writeln('성공! "'+outputName+'" 을 실행하면 다음과 비슷하게 출력됩니다:');
    Writeln('  핸들러 호출됨. sender.ToString = System.Windows.Forms.Button, Text:');
    Writeln('  ClickCount=1');
    Writeln('  완료: 핸들러에서 sender 매개변수 사용 성공');
    Writeln('=====================================================');
  except
    on E: Exception do
    begin
      Writeln('실패: '+E.GetType.FullName);
      Writeln(E.Message);
      Writeln(E.StackTrace);
    end;
  end;

  Writeln;
  Writeln('아무 키나 누르면 종료합니다...');
  Readln;
end.