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
  Monomorphize,
  CodeGen;

const
  TestSource =
    'program GenericBoxTest;' + #10 +
    'type' + #10 +
    '  TBox<T> = class' + #10 +
    '  private' + #10 +
    '    fValue: T;' + #10 +
    '  public' + #10 +
    '    procedure SetValue(v: T);' + #10 +
    '    function GetValue: T;' + #10 +
    '  end;' + #10 +
    '' + #10 +
    'procedure TBox.SetValue(v: T);' + #10 +
    'begin' + #10 +
    '  fValue := v;' + #10 +
    'end;' + #10 +
    '' + #10 +
    'function TBox.GetValue: T;' + #10 +
    'begin' + #10 +
    '  Result := fValue;' + #10 +
    'end;' + #10 +
    '' + #10 +
    'var' + #10 +
    '  intBox : TBox<integer>;' + #10 +
    '  strBox : TBox<string>;' + #10 +
    'begin' + #10 +
    '  intBox := TBox<integer>.Create;' + #10 +
    '  intBox.SetValue(42);' + #10 +
    '  writeln(''intBox = '' + IntToStr(intBox.GetValue));' + #10 +
    '' + #10 +
    '  strBox := TBox<string>.Create;' + #10 +
    '  strBox.SetValue(''hello generics'');' + #10 +
    '  writeln(''strBox = '' + strBox.GetValue);' + #10 +
    'end.';

var
  lexer: TLexer; tokens: List<TToken>;
  parser: TParser; prog: TProgramNode;
  mono: TMonomorphizer;
  codegen: TCodeGenerator; outputName: string;

begin
  Writeln('=== Stage 26: 제네릭 (단형화) — TBox<T> → TBox_integer / TBox_string ===');
  Writeln('--- 입력 소스 ---'); Writeln(TestSource); Writeln;

  try
    lexer:=new TLexer(TestSource);
    tokens:=lexer.Tokenize;
    Writeln('[1/4] 토큰화 완료: '+tokens.Count.ToString+'개 토큰');

    parser:=new TParser(tokens);
    prog:=parser.ParseProgram;
    Writeln('[2/4] 구문분석 완료: 클래스 '+prog.ClassDecls.Count.ToString
      +'개(제네릭 템플릿 포함), 인스턴스화 요청 '+prog.GenericInstantiations.Count.ToString+'건');

    mono:=new TMonomorphizer(prog);
    mono.Run;
    Writeln('[3/4] 단형화 완료: 클래스 '+prog.ClassDecls.Count.ToString
      +'개(구체화됨), 메서드구현 '+prog.MethodImpls.Count.ToString+'개');

    outputName:='GenericBox_Test_Stage26.exe';
    codegen:=new TCodeGenerator(prog);
    codegen.GenerateExe(outputName);
    Writeln('[4/4] 코드생성 완료: '+outputName+' 생성됨');

    Writeln;
    Writeln('=====================================================');
    Writeln('성공! "'+outputName+'" 을 실행하면 다음이 출력되어야 합니다:');
    Writeln('  intBox = 42');
    Writeln('  strBox = hello generics');
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