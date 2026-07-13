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
  DefaultExampleFile = 'Test_stage52.pas';
  //DefaultExampleFile = 'Test_stage51.pas';
  //DefaultExampleFile = 'Test_stage50.pas';
  //DefaultExampleFile = 'Test_stage49.pas';
  //DefaultExampleFile = 'Test_stage48.pas';
  //DefaultExampleFile = 'Test_stage47.pas';
  //DefaultExampleFile = 'Test_stage46.pas';
  //DefaultExampleFile = 'Test_stage45.pas';
  //DefaultExampleFile = 'Test_stage44.pas'; // Test_stage44.dll 생성됨.
  //DefaultExampleFile = 'Test_stage43.pas';
  //DefaultExampleFile = 'Test_stage42.pas';
  //DefaultExampleFile = 'Test_stage41.pas';
  //DefaultExampleFile = 'Test_stage40.pas';
  // 38~39는 문서 작업이라 소스코드및 예제 소스코드가 없음.
  //DefaultExampleFile = 'Test_stage37.pas';
  //DefaultExampleFile = 'Test_stage36.pas';
  //DefaultExampleFile = 'Test_stage35_parse_errors.pas'; // 오류 메세지 검증용
  //DefaultExampleFile = 'Test_stage35_lex_errors.pas';   // 오류 메세지 검증용
  //DefaultExampleFile = 'test_stage34.pas';
  //DefaultExampleFile = 'test_stage32.pas';
  //DefaultExampleFile = 'test_stage31.pas';
  //DefaultExampleFile = 'test_stage30.pas';
  //DefaultExampleFile = 'test_stage29.pas';
  //DefaultExampleFile = 'LocalVars_Test_Stage28.pas';
  //DefaultExampleFile = 'Staticfunctypes_test_Stage27.pas';
  //DefaultExampleFile = 'GenericBox_Test_Stage26.pas';
  //DefaultExampleFile = 'StaticWrite_Test_Stage25.pas';  
  //DefaultExampleFile = 'StaticMember_Test_Stage24.pas';
  //DefaultExampleFile = 'ExprCast_Test_Stage23.pas';
  //DefaultExampleFile = 'Cast_Test_Stage22.pas';
  //DefaultExampleFile = 'HandlerParams_Test_Stage21.pas';
  //DefaultExampleFile = 'EventSubscribe_Test_Stage20.pas';  
  //DefaultExampleFile = 'QualifiedFieldAccess_Test_Stage19.pas';
  //DefaultExampleFile = 'FieldExternalType_Test_Stage18.pas';
  //DefaultExampleFile = 'ExternalRead_Test_Stage17.pas';
  //DefaultExampleFile = 'StaticCall_Test_Stage16.pas';
  //DefaultExampleFile = 'ExternalMember_Test_Stage15.pas';
  //DefaultExampleFile = 'ExternalType_Test_Stage14.pas'; //오류 유형: System.Exception // 메시지: 외부 타입 "System.Windows.Forms.Form"을(를) 찾을 수 없습니다. AddReferenceAssembly로 해당 타입이 들어있는 어셈블리를 먼저 등록했는지 확인하세요.
  //DefaultExampleFile = 'InterfaceTest_Stage12.pas';
  //DefaultExampleFile = 'InterfaceTest_Stage11.pas';
  //DefaultExampleFile = 'InheritTest_Stage10.pas';
  //DefaultExampleFile = 'OOPTest_Stage9.pas';
  //DefaultExampleFile = 'ArrayTest_Stage8.pas';
  //DefaultExampleFile = 'StringTest_Stage7.pas';
  //DefaultExampleFile = 'CalcTest_Stage6.pas';
  //DefaultExampleFile = 'FizzBuzz_Stage5.pas';
  //DefaultExampleFile = 'MiniCompiled_Stage4.pas';
  //DefaultExampleFile = 'HelloWorld_Test_Stage3.pas';
  //DefaultExampleFile = 'HelloWorld_Test_Stage1.pas';

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
  m: System.Text.RegularExpressions.Match;
  lineNo, colNo, i, startLn, endLn: integer;
  srcLines: array of string; marker, caretLine: string;
begin
  Writeln;
  Writeln('=====================================================');
  Writeln('컴파일 실패 — [' + phase + '] 단계');
  Writeln('=====================================================');

  // [Stage 35] '줄 N, 열 C: ...' 형식이면 줄 번호와 열 번호를 모두 뽑아 캐럿(^)으로 정확한 위치를 가리킨다.
  // 예전 메시지('줄 N: ...', 열 번호 없음)나 줄 정보가 아예 없는 예외도 각각 처리한다.
  m := System.Text.RegularExpressions.Regex.Match(ex.Message, '^줄 (\d+), 열 (\d+):\s*(.*)$', System.Text.RegularExpressions.RegexOptions.Singleline);
  if m.Success then
  begin
    lineNo := integer.Parse(m.Groups[1].Value);
    colNo := integer.Parse(m.Groups[2].Value);
    Writeln('오류 (줄 ' + lineNo.ToString + ', 열 ' + colNo.ToString + '): ' + m.Groups[3].Value);
    Writeln;

    srcLines := sourceCode.Replace(#13, '').Split(#10);
    startLn := lineNo - 2; if startLn < 1 then startLn := 1;
    endLn := lineNo + 2; if endLn > srcLines.Length then endLn := srcLines.Length;

    for i := startLn to endLn do
    begin
      if i = lineNo then marker := '  >> ' else marker := '     ';
      Writeln(marker + i.ToString.PadLeft(4) + ' | ' + srcLines[i - 1]);
      if i = lineNo then
      begin
        caretLine := ''.PadLeft(colNo - 1, ' ');
        Writeln('            ' + caretLine + '^');
      end;
    end;
  end
  else
  begin
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
      // [Stage 35] Lexer가 여러 개의 '알 수 없는 문자' 오류를 한 번에 모아 던진 경우:
      // 각 줄이 '줄 N, 열 C: ...' 형식이므로, 하나씩 나눠 각자의 소스 컨텍스트를 보여준다.
      var subLines := ex.Message.Split(#10);
      var anyMatched := false;
      foreach var subLine in subLines do
      begin
        var sm := System.Text.RegularExpressions.Regex.Match(subLine, '^줄 (\d+), 열 (\d+):\s*(.*)$');
        if sm.Success then
        begin
          anyMatched := true;
          lineNo := integer.Parse(sm.Groups[1].Value);
          colNo := integer.Parse(sm.Groups[2].Value);
          Writeln('오류 (줄 ' + lineNo.ToString + ', 열 ' + colNo.ToString + '): ' + sm.Groups[3].Value);
          srcLines := sourceCode.Replace(#13, '').Split(#10);
          if (lineNo >= 1) and (lineNo <= srcLines.Length) then
          begin
            Writeln('  >> ' + lineNo.ToString.PadLeft(4) + ' | ' + srcLines[lineNo - 1]);
            caretLine := ''.PadLeft(colNo - 1, ' ');
            Writeln('            ' + caretLine + '^');
          end;
          Writeln;
        end;
      end;
      if not anyMatched then
      begin
        // 줄 번호가 없는 예외 (CLR 런타임 예외, Monomorphize의 구조적 오류 등) — 메시지와 타입만 표시
        Writeln('오류 유형: ' + ex.GetType.FullName);
        Writeln('메시지: ' + ex.Message);
      end;
    end;
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
      // [Stage 44] library는 .dll로, program은 기존처럼 .exe로 저장한다.
      if prog.IsLibrary then
        outputName := System.IO.Path.GetFileNameWithoutExtension(inputPath) + '.dll'
      else
        outputName := System.IO.Path.GetFileNameWithoutExtension(inputPath) + '.exe';
      codegen := new TCodeGenerator(prog);

      // [Stage 45] 소스 안의 {$reference X.dll} 지시문에서 뽑아둔 어셈블리를 codegen에 등록.
      // 이게 없으면 System.Windows.Window 같은 실제 WPF 타입은 참조할 수 없다
      // (mscorlib에 없는 타입은 Type.GetType만으로는 못 찾고, 미리 로드해둔 어셈블리 목록에서 찾는다).
      if lexer.ReferenceDirectives.Count>0 then
      begin
        Writeln('  참조 어셈블리 등록 중: ' + string.Join(', ', lexer.ReferenceDirectives));
        foreach var refName in lexer.ReferenceDirectives do
          codegen.AddReferenceAssembly(refName);
      end;

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