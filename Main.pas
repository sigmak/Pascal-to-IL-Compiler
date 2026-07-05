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
    'program EventSubscribeTest;' + #10 +
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
    '  writeln(''버튼 클릭 핸들러 호출됨! ClickCount='' + IntToStr(ClickCount));' + #10 +
    'end;' + #10 +
    '' + #10 +
    'procedure TMyForm.Setup;' + #10 +
    'begin' + #10 +
    '  Button1 := System.Windows.Forms.Button.Create;' + #10 +
    '  Button1.Click += Button1_Click;' + #10 +
    '  writeln(''완료: Button1.Click 이벤트 구독 성공 (예외 없음)'');' + #10 +
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
  Writeln('=== Stage 20: 이벤트 구독 (Button1.Click += Button1_Click;) ===');
  Writeln('--- 입력 소스 ---'); Writeln(TestSource); Writeln;

  try
    lexer:=new TLexer(TestSource);
    tokens:=lexer.Tokenize;
    Writeln('[1/3] 토큰화 완료: '+tokens.Count.ToString+'개 토큰');

    parser:=new TParser(tokens);
    prog:=parser.ParseProgram;
    Writeln('[2/3] 구문분석 완료: 클래스 '+prog.ClassDecls.Count.ToString
      +'개, 메서드구현 '+prog.MethodImpls.Count.ToString+'개');

    outputName:='EventSubscribe_Test_Stage20.exe';
    codegen:=new TCodeGenerator(prog);
    codegen.AddReferenceAssembly('System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089');
    codegen.GenerateExe(outputName);
    Writeln('[3/3] 코드생성 완료: '+outputName+' 생성됨');

    Writeln;
    Writeln('=====================================================');
    Writeln('성공! "'+outputName+'" 을 실행하면 다음이 출력되어야 합니다:');
    Writeln('  완료: Button1.Click 이벤트 구독 성공 (예외 없음)');
    Writeln('=====================================================');
    Writeln;
    Writeln('참고: 실제로 버튼을 클릭해 핸들러가 호출되는지 보려면');
    Writeln('Application.Run(f)로 창을 띄우고 버튼을 눌러봐야 확인됩니다');
    Writeln('(이번 테스트는 "구독 자체가 예외 없이 되는지"만 확인).');
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