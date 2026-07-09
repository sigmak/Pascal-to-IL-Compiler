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
  System.Text.RegularExpressions,
  System.Reflection,
  System.Collections.Generic,
  AST,
  Lexer,
  Parser,
  Monomorphize,
  CodeGen;

const
  DefaultExampleDir = 'Examples';
  DefaultExampleFile = 'test_stage34.pas';
  //DefaultExampleFile = 'test_stage32.pas';
  //DefaultExampleFile = 'test_stage31.pas';
  //DefaultExampleFile = 'test_stage30.pas';
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

// [Stage 33] 진단 메시지 개선.
// Lexer/Parser/Monomorphize가 던지는 메시지는 이미 '줄 N: ...' 형식으로 시작하므로,
// 그 줄 번호를 뽑아내어 실제 소스 코드에서 해당 줄(과 앞뒤 문맥)을 함께 보여준다.
// 줄 번호를 알 수 없는 예외(예: CodeGen 단계의 CLR 런타임 예외)는 메시지만 그대로 보여준다.
procedure PrintCompileError(phase: string; sourceCode: string; ex: Exception);
var
  m: System.Text.RegularExpressions.Match; lineNo, i, startLn, endLn: integer; srcLines: array of string; marker: string;
begin
  Writeln;
  Writeln('=====================================================');
  Writeln('컴파일 실패 — [' + phase + '] 단계');
  Writeln('=====================================================');

  m := System.Text.RegularExpressions.Regex.Match(ex.Message, '^줄 (\d+):\s*(.*)$', System.Text.RegularExpressions.RegexOptions.Singleline);
  if m.Success then
  begin
    lineNo := integer.Parse(m.Groups[1].Value);
    Writeln('오류 (줄 ' + lineNo.ToString + '): ' + m.Groups[2].Value);
    Writeln;

    srcLines := sourceCode.Replace(#13, '').Split(#10);

    startLn := lineNo - 2; if startLn < 1 then startLn := 1;
    endLn := lineNo + 2; if endLn > srcLines.Length then endLn := srcLines.Length;

    for i := startLn to endLn do
    begin
      if i = lineNo then marker := '  >> ' else marker := '     ';
      Writeln(marker + i.ToString.PadLeft(4) + ' | ' + srcLines[i - 1]);
    end;
  end
  else
  begin
    // 줄 번호가 없는 예외 (CLR 런타임 예외 등) — 메시지와 타입만 표시
    Writeln('오류 유형: ' + ex.GetType.FullName);
    Writeln('메시지: ' + ex.Message);
  end;

  Writeln;
  Writeln('(전체 스택 추적)');
  Writeln(ex.StackTrace);
  Writeln('=====================================================');
end;

var
  inputPath, sourceCode, outputName: string;
  lexer: TLexer; tokens: List<TToken>;
  parser: TParser; prog: TProgramNode;
  mono: TMonomorphizer;
  codegen: TCodeGenerator;
  ok: boolean;

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

    ok := true;

    // [Stage 33] 단계별로 try/except를 분리해 어느 단계에서 실패했는지 항상 알 수 있게 한다.
    if ok then
    try
      lexer := new TLexer(sourceCode);
      tokens := lexer.Tokenize;
      Writeln('[1/4] 토큰화 완료: ' + tokens.Count.ToString + '개 토큰');
    except
      on E: Exception do begin PrintCompileError('어휘분석(Lexer)', sourceCode, E); ok := false; end;
    end;

    if ok then
    try
      parser := new TParser(tokens);
      prog := parser.ParseProgram;
      Writeln('[2/4] 구문분석 완료: 클래스 ' + prog.ClassDecls.Count.ToString
        + '개(제네릭 템플릿 포함), 인스턴스화 요청 ' + prog.GenericInstantiations.Count.ToString + '건');
    except
      on E: Exception do begin PrintCompileError('구문분석(Parser)', sourceCode, E); ok := false; end;
    end;

    if ok then
    try
      mono := new TMonomorphizer(prog);
      mono.Run;
      Writeln('[3/4] 단형화 완료: 클래스 ' + prog.ClassDecls.Count.ToString
        + '개(구체화됨), 메서드구현 ' + prog.MethodImpls.Count.ToString + '개');
    except
      on E: Exception do begin PrintCompileError('제네릭 단형화(Monomorphize)', sourceCode, E); ok := false; end;
    end;

    if ok then
    try
      outputName := System.IO.Path.GetFileNameWithoutExtension(inputPath) + '.exe';
      codegen := new TCodeGenerator(prog);
      codegen.GenerateExe(outputName);
      Writeln('[4/4] 코드생성 완료: ' + outputName + ' 생성됨');

      Writeln;
      Writeln('=====================================================');
      Writeln('성공! "' + outputName + '" 이 생성되었습니다.');
      Writeln('=====================================================');
    except
      on E: Exception do begin PrintCompileError('코드생성(CodeGen)', sourceCode, E); ok := false; end;
    end;
  end;

  Writeln;
  Writeln('아무 키나 누르면 종료합니다...');
  Readln;
end.