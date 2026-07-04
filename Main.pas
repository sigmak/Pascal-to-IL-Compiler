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
    'program InterfaceTest;' + #10 +
    'type' + #10 +
    '  ISpeaker = interface' + #10 +
    '    function Speak: string;' + #10 +
    '  end;' + #10 +
    '' + #10 +
    '  TAnimal = class(ISpeaker)' + #10 +
    '  public' + #10 +
    '    function Speak: string;' + #10 +
    '  end;' + #10 +
    '' + #10 +
    'function TAnimal.Speak: string;' + #10 +
    'begin' + #10 +
    '  Result := ''Animal sound'';' + #10 +
    'end;' + #10 +
    '' + #10 +
    'var' + #10 +
    '  a : TAnimal;' + #10 +
    '  s : ISpeaker;' + #10 +
    'begin' + #10 +
    '  a := TAnimal.Create;' + #10 +
    '  s := a;' + #10 +
    '  writeln(a.Speak);' + #10 +
    '  writeln(s.Speak);' + #10 +
    'end.';

var
  lexer: TLexer; tokens: List<TToken>;
  parser: TParser; prog: TProgramNode;
  codegen: TCodeGenerator; outputName: string;

begin
  Writeln('=== Stage 13 (Phase E-2): 제네릭 클래스 + 예외처리(try/except/finally) 테스트 ===');
  Writeln('--- 입력 소스 ---'); Writeln(TestSource); Writeln;

  try
    lexer:=new TLexer(TestSource);
    tokens:=lexer.Tokenize;
    Writeln('[1/3] 토큰화 완료: '+tokens.Count.ToString+'개 토큰');

    parser:=new TParser(tokens);
    prog:=parser.ParseProgram;
    Writeln('[2/3] 구문분석 완료: 인터페이스 '+prog.InterfaceDecls.Count.ToString
      +'개, 클래스 '+prog.ClassDecls.Count.ToString
      +'개, 메서드구현 '+prog.MethodImpls.Count.ToString+'개');

    outputName:='Generic_tef_Test_Stage13.exe';
    codegen:=new TCodeGenerator(prog);
    codegen.GenerateExe(outputName);
    Writeln('[3/3] 코드생성 완료: '+outputName+' 생성됨');

    Writeln;
    Writeln('=====================================================');
    Writeln('성공! "'+outputName+'" 을 실행하면 다음이 출력되어야 합니다:');
    Writeln('  Animal sound');
    Writeln('  Animal sound');
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