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
    'program ExternalTypeTest;' + #10 +
    'type' + #10 +
    '  TMyError = class(System.Exception)' + #10 +
    '  public' + #10 +
    '    function Describe: string;' + #10 +
    '  end;' + #10 +
    '' + #10 +
    '  TMyForm = class(System.Windows.Forms.Form)' + #10 +
    '  public' + #10 +
    '    function Greeting: string;' + #10 +
    '  end;' + #10 +
    '' + #10 +
    'function TMyError.Describe: string;' + #10 +
    'begin' + #10 +
    '  Result := ''System.Exception 상속 확인'';' + #10 +
    'end;' + #10 +
    '' + #10 +
    'function TMyForm.Greeting: string;' + #10 +
    'begin' + #10 +
    '  Result := ''System.Windows.Forms.Form 상속 확인'';' + #10 +
    'end;' + #10 +
    '' + #10 +
    'var' + #10 +
    '  e : TMyError;' + #10 +
    '  f : TMyForm;' + #10 +
    'begin' + #10 +
    '  e := TMyError.Create;' + #10 +
    '  f := TMyForm.Create;' + #10 +
    '  writeln(e.Describe);' + #10 +
    '  writeln(f.Greeting);' + #10 +
    'end.';

var
  lexer: TLexer; tokens: List<TToken>;
  parser: TParser; prog: TProgramNode;
  codegen: TCodeGenerator; outputName: string;

begin
  Writeln('=== Stage 14: 외부 .NET 어셈블리 타입 상속 (WPF/WinForm/Avalonia 기반) ===');
  Writeln('--- 입력 소스 ---'); Writeln(TestSource); Writeln;

  try
    lexer:=new TLexer(TestSource);
    tokens:=lexer.Tokenize;
    Writeln('[1/3] 토큰화 완료: '+tokens.Count.ToString+'개 토큰');

    parser:=new TParser(tokens);
    prog:=parser.ParseProgram;
    Writeln('[2/3] 구문분석 완료: 클래스 '+prog.ClassDecls.Count.ToString
      +'개, 메서드구현 '+prog.MethodImpls.Count.ToString+'개');

    outputName:='ExternalType_Test_Stage14.exe';
    codegen:=new TCodeGenerator(prog);
    // TMyError(System.Exception)는 mscorlib이라 등록 없이도 찾아짐.
    // TMyForm(System.Windows.Forms.Form)은 GAC 어셈블리이므로 명시적으로 등록해야 함.
    // WPF를 쓴다면 'PresentationFramework','PresentationCore','WindowsBase'를,
    // AvaloniaUI를 쓴다면 해당 dll의 전체 경로를 등록하면 된다.
    //codegen.AddReferenceAssembly('System.Windows.Forms'); // 실행시 오류 발생해서 아래 방식으로 대체함.
    codegen.AddReferenceAssembly('System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089');
    codegen.GenerateExe(outputName);
    Writeln('[3/3] 코드생성 완료: '+outputName+' 생성됨');

    Writeln;
    Writeln('=====================================================');
    Writeln('성공! "'+outputName+'" 을 실행하면 다음이 출력되어야 합니다:');
    Writeln('  System.Exception 상속 확인');
    Writeln('  System.Windows.Forms.Form 상속 확인');
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