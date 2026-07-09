// ============================================================
// Main.pas — 진입점.
// 실제 컴파일러처럼: 커맨드라인 인자로 받은 .pas 소스 파일을
// 디스크에서 읽어와 Lex → Parse → Monomorphize → CodeGen 파이프라인을
// 돌린다. 인자가 없으면 Examples\ 폴더의 기본 예제 파일을 사용한다.
// Lexer/Parser/CodeGen 로직은 각 unit 파일에서 관리.
// ============================================================
program Main;

uses
  System.IO,
  System.Text,
  System.Reflection,
  System.Collections.Generic,
  AST,
  Lexer,
  Parser,
  Monomorphize,
  CodeGen;

const
  DefaultExampleDir = 'Examples';
  DefaultExampleFile = 'test_stage30.pas';
  //DefaultExampleFile = 'test_stage29.pas';
  //DefaultExampleFile = 'LocalVars_Test_Stage28.pas';
  //DefaultExampleFile = 'Staticfunctypes_test_Stage27.pas';
  

function ResolveInputPath: string;
var
  exeDir, candidate: string;
begin
  if ParamCount >= 1 then
  begin
    // 사용법: Main.exe <소스파일.pas>
    Result := ParamStr(1);
  end
  else
  begin
    // 인자가 없으면 실행 파일 옆의 Examples\GenericBoxTest.pas 를 기본값으로 사용
    exeDir := System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly.Location);
    candidate := System.IO.Path.Combine(exeDir, DefaultExampleDir, DefaultExampleFile);
    if System.IO.File.Exists(candidate) then
      Result := candidate
    else
      // 실행 파일 위치에 없으면 현재 작업 디렉터리 기준으로 한 번 더 시도
      Result := System.IO.Path.Combine(DefaultExampleDir, DefaultExampleFile);
  end;
end;

var
  inputPath, sourceCode, outputName: string;
  lexer: TLexer; tokens: List<TToken>;
  parser: TParser; prog: TProgramNode;
  mono: TMonomorphizer;
  codegen: TCodeGenerator;

begin
  Writeln('=== Pascal-to-.NET 컴파일러 ===');

  inputPath := ResolveInputPath;

  if not System.IO.File.Exists(inputPath) then
  begin
    Writeln('실패: 입력 소스 파일을 찾을 수 없습니다: ' + inputPath);
    Writeln('사용법: Main.exe <소스파일.pas>');
    Writeln('  (인자를 생략하면 Examples\' + DefaultExampleFile + ' 를 기본으로 사용합니다)');
  end
  else
  begin
    sourceCode := System.IO.File.ReadAllText(inputPath, Encoding.UTF8);
    Writeln('--- 입력 파일: ' + inputPath + ' ---');
    Writeln(sourceCode);
    Writeln;

    try
      lexer := new TLexer(sourceCode);
      tokens := lexer.Tokenize;
      Writeln('[1/4] 토큰화 완료: ' + tokens.Count.ToString + '개 토큰');

      parser := new TParser(tokens);
      prog := parser.ParseProgram;
      Writeln('[2/4] 구문분석 완료: 클래스 ' + prog.ClassDecls.Count.ToString
        + '개(제네릭 템플릿 포함), 인스턴스화 요청 ' + prog.GenericInstantiations.Count.ToString + '건');

      mono := new TMonomorphizer(prog);
      mono.Run;
      Writeln('[3/4] 단형화 완료: 클래스 ' + prog.ClassDecls.Count.ToString
        + '개(구체화됨), 메서드구현 ' + prog.MethodImpls.Count.ToString + '개');

      outputName := System.IO.Path.GetFileNameWithoutExtension(inputPath) + '.exe';
      codegen := new TCodeGenerator(prog);
      codegen.GenerateExe(outputName);
      Writeln('[4/4] 코드생성 완료: ' + outputName + ' 생성됨');

      Writeln;
      Writeln('=====================================================');
      Writeln('성공! "' + outputName + '" 이 생성되었습니다.');
      Writeln('=====================================================');
    except
      on E: Exception do
      begin
        Writeln('실패: ' + E.GetType.FullName);
        Writeln(E.Message);
        Writeln(E.StackTrace);
      end;
    end;
  end;

  Writeln;
  Writeln('아무 키나 누르면 종료합니다...');
  Readln;
end.