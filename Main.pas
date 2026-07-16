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
  DefaultExampleFile = 'Test_stage64.pas'; // [Stage 64] 익명 메서드/람다 (-> 구문) 테스트
  //DefaultExampleFile = 'Test_stage63.pas'; // [Stage 63] set of 타입과 집합 연산 (in, +, -, *) 테스트
  //DefaultExampleFile = 'Test_stage62.pas'; // [Stage 62] record 타입 (값 타입 의미론 — 대입 시 복사) 테스트
  //DefaultExampleFile = 'Test_stage61.pas'; // [Stage 61] const 선언 (전역/지역, 타입 추론 포함) 테스트
  //DefaultExampleFile = 'Test_stage60.pas'; // [Stage 60] break/continue, repeat...until 테스트
  //DefaultExampleFile = 'Test_stage59.pas'; // [Stage 59] case...of...else 문 테스트
  //DefaultExampleFile = 'Test_stage58.pas'; // 오류메세지 3개가 발생되는게 맞음. 
  //DefaultExampleFile = 'Test_stage57.pas';
  //DefaultExampleFile = 'Units_DupTest\Dupentry.pas'; // stage56 오류 나는 예제 Examples\Units_DupTest\ 폴더에 Dupa.pas, Dupb.pas, Dupentry.pas 이렇게 3개 가 있음.
  //DefaultExampleFile = 'Units\Entry.pas'; // stage56 정상적인 예제 Examples\Untis\ 폴더에 StringUtils.pas, MathUtils.pas, Entry.pas 이렇게 3개 가 있음.
  //DefaultExampleFile = 'Units\Entry.pas'; // stage54  Examples\Untis\ 폴더에 StringUtils.pas, MathUtils.pas, Entry.pas 이렇게 3개 가 있음. 
  //DefaultExampleFile = 'Test_stage54.pas';
  //DefaultExampleFile = 'Test_stage53.pas';
  //DefaultExampleFile = 'Test_stage52.pas'; // 오류 4가지 표시되면 정상임.
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
  //DefaultExampleFile = 'Test_stage36.pas'; // 현재 0.53b 버전에서 오류해결.
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

// ------------------------------------------------------------
// [Stage 55] unit/멀티파일: 파일탐색 + 의존성 정렬
// ------------------------------------------------------------
// 지금 컴파일러의 Parser는 program의 uses 절 이름을 파싱만 하고 버린다(Parser.pas 주석 참고) —
// 즉 uses에 적힌 이름이 실제로 로컬 .pas 유닛 파일인지, System.* 같은 프레임워크
// 네임스페이스인지는 여태 구분한 적이 없다. 이 단계는 그 구분을 처음 도입한다:
// 이름이 "<이름>.pas" 파일로 실제 존재하면 로컬 유닛(의존성)으로, 없으면 지금까지처럼
// 프레임워크 네임스페이스로 취급해 그냥 무시한다.
//
// 범위는 "탐색 + 순서 계산"까지다. 찾아낸 여러 파일의 선언을 하나의 AST로 실제
// 병합하는 것은 [Stage 56]에서 이어받는다(아래 MergeProgramInto 관련 함수들).

// entry 소스 텍스트에서 최초의 uses 절 하나만 뽑아 이름 목록으로 돌려준다.
// Parser.ParseProgram이 인식하는 문법과 동일: uses Ident(.Ident)*, Ident(.Ident)*, ... ;
// 점(.)이 포함된 이름(System.Windows.Forms 등)은 프레임워크 네임스페이스이므로
// 첫 세그먼트만 후보로 남긴다 — 그래도 파일탐색에서 못 찾으면 어차피 무시된다.
function ExtractUsesNames(sourceCode: string): List<string>;
var
  m: System.Text.RegularExpressions.Match;
  raw, nm: string; parts: array of string; p: string;
begin
  Result := new List<string>;
  m := System.Text.RegularExpressions.Regex.Match(sourceCode,
    '\b(program|library)\s+\w+\s*;\s*uses\s+(.*?);',
    System.Text.RegularExpressions.RegexOptions.Singleline);
  if not m.Success then exit;
  raw := m.Groups[2].Value;
  parts := raw.Split(',');
  foreach p in parts do
  begin
    nm := p.Trim;
    if nm = '' then continue;
    if nm.Contains('.') then nm := nm.Substring(0, nm.IndexOf('.'));
    if not Result.Contains(nm) then Result.Add(nm);
  end;
end;

// 유닛 이름 → 실제 파일 경로. searchDirs를 순서대로 뒤져 "<이름>.pas"가 있으면 그 경로,
// 없으면 '' (파일로 못 찾으면 에러가 아니라 "프레임워크 이름이겠거니" 하고 조용히 넘어간다).
function ResolveUnitFile(unitName: string; searchDirs: List<string>): string;
var dir, candidate: string;
begin
  Result := '';
  foreach dir in searchDirs do
  begin
    candidate := System.IO.Path.Combine(dir, unitName + '.pas');
    if System.IO.File.Exists(candidate) then begin Result := candidate; exit; end;
  end;
end;

// DiscoverCompileOrder의 재귀 방문자. visiting/visited/order/pathStack은 모두 참조 타입
// 컬렉션이라 재귀 호출 사이에 그대로 누적된다(var 매개변수 없이도 공유됨).
// 위상 정렬: 후위 순회로 order에 추가하므로 "의존하는 파일이 항상 의존 대상보다 뒤에" 온다.
procedure VisitUnitForOrder(filePath: string; searchDirs: List<string>;
  visiting, visited: HashSet<string>; order, pathStack: List<string>);
var
  key, src, depName, depPath: string;
  deps: List<string>;
begin
  key := System.IO.Path.GetFullPath(filePath);
  if visited.Contains(key) then exit;

  if visiting.Contains(key) then
  begin
    pathStack.Add(filePath);
    var cycleNames := new List<string>;
    var ci: integer;
    for ci := 0 to pathStack.Count - 1 do
      cycleNames.Add(System.IO.Path.GetFileName(pathStack[ci]));
    raise new Exception('유닛 순환 참조 발견: ' + string.Join(' -> ', cycleNames));
  end;

  visiting.Add(key);
  pathStack.Add(filePath);

  src := System.IO.File.ReadAllText(filePath, Encoding.UTF8);
  deps := ExtractUsesNames(src);
  foreach depName in deps do
  begin
    depPath := ResolveUnitFile(depName, searchDirs);
    if depPath <> '' then
      VisitUnitForOrder(depPath, searchDirs, visiting, visited, order, pathStack);
  end;

  pathStack.RemoveAt(pathStack.Count - 1);
  visiting.Remove(key);
  visited.Add(key);
  order.Add(filePath);
end;

// entryFile부터 시작해 uses로 연결된 로컬 유닛 파일들을 재귀적으로 찾아내고,
// 의존성이 먼저 오도록 위상 정렬한 컴파일 순서를 돌려준다(entryFile이 항상 마지막).
// 순환 참조가 있으면 예외를 던진다.
function DiscoverCompileOrder(entryFile: string; searchDirs: List<string>): List<string>;
var
  visiting, visited: HashSet<string>;
  order, pathStack: List<string>;
begin
  visiting := new HashSet<string>;
  visited := new HashSet<string>;
  order := new List<string>;
  pathStack := new List<string>;
  VisitUnitForOrder(entryFile, searchDirs, visiting, visited, order, pathStack);
  Result := order;
end;

// ------------------------------------------------------------
// [Stage 56] 여러 파일의 선언을 하나의 AST로 실제 병합
// ------------------------------------------------------------
// Stage 55는 파일 탐색과 컴파일 순서 계산까지만 했다. 이 단계는 그 순서(의존성 먼저,
// entry 파일이 마지막)대로 각 파일을 실제로 Lex/Parse해서 나온 TProgramNode들을,
// 이름 충돌을 검사하면서 하나의 TProgramNode로 합친다.
//
// - entry 파일(목록의 마지막)의 Name / IsLibrary / Statements(메인 begin...end 블록)만
//   최종 결과에 쓰인다.
// - 그 앞의 의존 유닛 파일들은 타입(class/interface/enum)·함수·프로시저·메서드구현·
//   생성자구현·전역변수·제네릭 인스턴스화 요청만 제공한다. 유닛 파일은 관례상
//   "library Unit이름; ... end."처럼 begin...end 없이 끝나므로 자신의 메인 블록은 없다
//   (있어도 병합 시 버려진다 — entry의 메인 블록만 실행된다).
// - 서로 다른 파일에 같은 이름의 클래스/함수/프로시저/인터페이스/열거형이 있으면
//   CodeGen 단계에서 알 수 없는 오류로 나타나기 전에 여기서 바로 "어느 두 파일이
//   충돌했는지" 명확한 오류로 알린다.
// - CodeGen은 "ClassDecls는 부모가 자식보다 먼저 나온다"는 순서를 전제한다
//   (CodeGen.pas의 BuildClassShell 호출부 주석 참고). compileOrder가 의존성을
//   먼저 방문하는 위상 정렬이므로, 병합 순서(의존 파일 → entry 파일)가 그대로
//   이 전제를 만족시킨다 — 단, 같은 파일 안에서는 여전히 부모를 자식보다 먼저
//   선언해야 한다(이건 병합 이전부터 있던 제약).

procedure RegisterDeclName(seen: Dictionary<string,string>; name, kind, fileLabel: string);
begin
  if seen.ContainsKey(name) then
    raise new Exception('중복 선언: ' + kind + ' "' + name + '" — "' + seen[name]
      + '" 파일과 "' + fileLabel + '" 파일에 모두 선언되어 있습니다.');
  seen.Add(name, fileLabel);
end;

// 이미 만들어져 있는 TProgramNode(병합의 뼈대로 삼는 첫 파일) 안의 선언 이름들을
// 중복검사 사전에 등록만 한다 — 아직 아무것도 옮기지는 않는다.
procedure RegisterProgramNames(prog: TProgramNode; fileLabel: string;
  seenClasses, seenFuncs, seenProcs, seenIfaces, seenEnums: Dictionary<string,string>);
var c: TClassDeclNode; f: TFuncDeclNode; p: TProcDeclNode; i: TInterfaceDeclNode; e: TEnumDeclNode;
begin
  foreach c in prog.ClassDecls do RegisterDeclName(seenClasses, c.Name, '클래스', fileLabel);
  foreach f in prog.FuncDecls do RegisterDeclName(seenFuncs, f.Name, '함수', fileLabel);
  foreach p in prog.ProcDecls do RegisterDeclName(seenProcs, p.Name, '프로시저', fileLabel);
  foreach i in prog.InterfaceDecls do RegisterDeclName(seenIfaces, i.Name, '인터페이스', fileLabel);
  foreach e in prog.EnumDecls do RegisterDeclName(seenEnums, e.Name, '열거형', fileLabel);
  // [Stage 62] 레코드는 클래스와 이름공간을 공유하므로(같은 곳에서 "타입 이름"으로 참조됨)
  // seenClasses에 함께 등록한다 — 다른 파일의 클래스와 이름이 겹쳐도 여기서 잡힌다.
  foreach var r62 in prog.RecordDecls do RegisterDeclName(seenClasses, r62.Name, '레코드', fileLabel);
end;

// src(다른 파일에서 파싱된 TProgramNode)의 선언들을 target으로 옮겨 붙인다.
// 옮기기 전에 이름 충돌부터 검사한다(충돌 시 target은 손대지 않고 예외를 던진다).
procedure MergeProgramInto(target, src: TProgramNode; fileLabel: string;
  seenClasses, seenFuncs, seenProcs, seenIfaces, seenEnums: Dictionary<string,string>);
var c: TClassDeclNode; f: TFuncDeclNode; p: TProcDeclNode; i: TInterfaceDeclNode; e: TEnumDeclNode;
begin
  foreach c in src.ClassDecls do RegisterDeclName(seenClasses, c.Name, '클래스', fileLabel);
  foreach f in src.FuncDecls do RegisterDeclName(seenFuncs, f.Name, '함수', fileLabel);
  foreach p in src.ProcDecls do RegisterDeclName(seenProcs, p.Name, '프로시저', fileLabel);
  foreach i in src.InterfaceDecls do RegisterDeclName(seenIfaces, i.Name, '인터페이스', fileLabel);
  foreach e in src.EnumDecls do RegisterDeclName(seenEnums, e.Name, '열거형', fileLabel);
  foreach var r62 in src.RecordDecls do RegisterDeclName(seenClasses, r62.Name, '레코드', fileLabel); // [Stage 62]

  target.ClassDecls.AddRange(src.ClassDecls);
  target.FuncDecls.AddRange(src.FuncDecls);
  target.ProcDecls.AddRange(src.ProcDecls);
  target.InterfaceDecls.AddRange(src.InterfaceDecls);
  target.EnumDecls.AddRange(src.EnumDecls);
  target.RecordDecls.AddRange(src.RecordDecls); // [Stage 62]
  target.MethodImpls.AddRange(src.MethodImpls);
  target.ConstructorImpls.AddRange(src.ConstructorImpls);
  target.VarDecls.AddRange(src.VarDecls);
  target.ConstDecls.AddRange(src.ConstDecls); // [Stage 61]
  target.GenericInstantiations.AddRange(src.GenericInstantiations);
  target.GenericFuncInstantiations.AddRange(src.GenericFuncInstantiations);
end;

var
  inputPath, sourceCode, outputName: string;
  prog: TProgramNode;
  mono: TMonomorphizer;
  codegen: TCodeGenerator;
  ok: boolean;
  mergedProg: TProgramNode;
  allReferenceDirectives: List<string>;
  seenClassNames, seenFuncNames, seenProcNames, seenIfaceNames, seenEnumNames: Dictionary<string,string>;
  totalTokenCount: integer;
  compileOrder: List<string>;
  fileProg: TProgramNode;
  symbolAccumulator: TParserExternalSymbols;

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

    // [Stage 55] 유닛 파일탐색 + 의존성 정렬. entry 파일 디렉터리, 그 아래 Examples\,
    // 그 아래 Units\ 를 검색 경로로 쓴다. 탐색 자체가 실패하면(순환 참조 등) entry
    // 파일 하나만으로 컴파일을 계속한다 — 로컬 유닛을 안 쓰는 기존 단일 파일 테스트들이
    // 계속 그대로 동작해야 하기 때문.
    var unitSearchDirs := new List<string>;
    var inputDir := System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(inputPath));
    unitSearchDirs.Add(inputDir);
    var examplesDir := System.IO.Path.Combine(inputDir, DefaultExampleDir);
    if System.IO.Directory.Exists(examplesDir) then unitSearchDirs.Add(examplesDir);
    var unitsDir := System.IO.Path.Combine(inputDir, 'Units');
    if System.IO.Directory.Exists(unitsDir) then unitSearchDirs.Add(unitsDir);

    try
      compileOrder := DiscoverCompileOrder(inputPath, unitSearchDirs);
      if compileOrder.Count > 1 then
      begin
        Writeln('[유닛탐색] 의존성 ' + (compileOrder.Count - 1).ToString + '개 파일 발견 — 컴파일 순서(의존성 먼저):');
        for var oi := 0 to compileOrder.Count - 1 do
          Writeln('    ' + (oi + 1).ToString + '. ' + System.IO.Path.GetFileName(compileOrder[oi]));
      end
      else
        Writeln('[유닛탐색] 로컬 유닛 의존성 없음 — 단일 파일 컴파일');
      Writeln;
    except
      on E: Exception do
      begin
        Writeln('[유닛탐색] 실패: ' + E.Message);
        Writeln('  단일 파일(진입점만)로 컴파일을 계속합니다.');
        Writeln;
        compileOrder := new List<string>;
        compileOrder.Add(inputPath);
      end;
    end;

    // [Stage 56] compileOrder 순서대로 각 파일을 Lex/Parse하고, 하나의 TProgramNode로 병합한다.
    // 파일이 1개뿐이면(로컬 유닛 없음) 기존과 동일하게 동작한다.
    mergedProg := nil;
    allReferenceDirectives := new List<string>;
    seenClassNames := new Dictionary<string,string>;
    seenFuncNames := new Dictionary<string,string>;
    seenProcNames := new Dictionary<string,string>;
    seenIfaceNames := new Dictionary<string,string>;
    seenEnumNames := new Dictionary<string,string>;
    totalTokenCount := 0;
    symbolAccumulator := nil; // [Stage 56] 파일이 하나씩 파싱될 때마다 뒤로 누적됨

    var fi := 0;
    while ok and (fi < compileOrder.Count) do
    begin
      var filePath := compileOrder[fi];
      var fileLabel := System.IO.Path.GetFileName(filePath);
      var fileSrc := System.IO.File.ReadAllText(filePath, Encoding.UTF8);
      try
        var fileLexer := new TLexer(fileSrc);
        var fileTokens := fileLexer.Tokenize;
        totalTokenCount := totalTokenCount + fileTokens.Count;
        foreach var rd in fileLexer.ReferenceDirectives do
          if not allReferenceDirectives.Contains(rd) then allReferenceDirectives.Add(rd);

        var fileParser := new TParser(fileTokens);
        // [Stage 56] 이전 파일들(의존성 먼저 순서)이 선언한 함수/클래스/... 이름을
        // 이 파서에 미리 알려준다 — 안 그러면 다른 파일에서 선언된 함수를 호출하는
        // 문장을 파싱할 때 "알 수 없는 문장"으로 오인해 실패한다.
        fileParser.ImportExternalSymbols(symbolAccumulator);
        fileProg := fileParser.ParseProgram;
        symbolAccumulator := fileParser.ExportSymbols;
      except
        on E: Exception do
        begin
          PrintCompileError('어휘/구문분석(' + fileLabel + ')', fileSrc, E);
          ok := false;
        end;
      end;

      if ok then
      try
        if mergedProg = nil then
        begin
          // 첫 파일을 병합의 뼈대로 삼는다(마지막 파일이면 그대로 entry가 됨).
          mergedProg := fileProg;
          RegisterProgramNames(mergedProg, fileLabel, seenClassNames, seenFuncNames, seenProcNames, seenIfaceNames, seenEnumNames);
        end
        else
        begin
          MergeProgramInto(mergedProg, fileProg, fileLabel, seenClassNames, seenFuncNames, seenProcNames, seenIfaceNames, seenEnumNames);
          if fi = compileOrder.Count - 1 then
          begin
            // entry 파일(항상 목록의 마지막): 이름/산출물 종류/메인 블록은 entry 것을 쓴다.
            mergedProg.Name := fileProg.Name;
            mergedProg.IsLibrary := fileProg.IsLibrary;
            mergedProg.Statements := fileProg.Statements;
          end;
        end;
      except
        on E: Exception do
        begin
          PrintCompileError('다중 파일 병합(' + fileLabel + ')', fileSrc, E);
          ok := false;
        end;
      end;
      fi := fi + 1;
    end;

    if ok then
    begin
      prog := mergedProg;
      var mergeLabel := '';
      if compileOrder.Count > 1 then mergeLabel := '(병합)';
      Writeln('[1/4] 토큰화 완료: ' + totalTokenCount.ToString + '개 토큰 (파일 ' + compileOrder.Count.ToString + '개 합계)');
      Writeln('[2/4] 구문분석 완료' + mergeLabel + ': 클래스 ' + prog.ClassDecls.Count.ToString
        + '개(제네릭 템플릿 포함), 인스턴스화 요청 ' + prog.GenericInstantiations.Count.ToString + '건');
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
      // [Stage 56] 병합된 파일 전체(entry + 로컬 유닛들)에서 모은 지시문을 함께 등록한다.
      if allReferenceDirectives.Count>0 then
      begin
        Writeln('  참조 어셈블리 등록 중: ' + string.Join(', ', allReferenceDirectives));
        foreach var refName in allReferenceDirectives do
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