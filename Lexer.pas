// ============================================================
// Lexer.pas — 어휘 분석 (TTokenKind, TToken, TLexer)
// 다른 프로젝트 unit에 의존하지 않음 (System.* 만 사용).
// 이 unit이 몇 Stage째 안 바뀐다면 = 어휘 분석은 안정화됐다는 신호.
// [Stage 110 진단] 자기 컴파일본(test_self.exe)에서만 AST.pas 렉싱 중 NullReferenceException —
//   기존 mod 50 진단 로그로는 iter=50에도 못 미쳐 죽어서 정확한 위치를 못 잡았다.
//   그래서 이 버전은 임시로 mod 1(매 토큰마다)로 낮췄다 — 정확한 크래시 지점을 확인한 뒤
//   다시 mod 50으로 되돌릴 것.
// [Stage 111] 진단 결과, Tokenize 안의 "바깥 try(EOF 시 break 포함) 안에 안쪽 try(ReadIdent
//   감싸는 것)가 중첩되고 두 catch가 같은 이름(E)의 예외 변수를 쓰는" 구조에서 self-compiled
//   바이너리만 IL이 잘못 만들어지는 것으로 추정됨(진단용 try/except 자체가 전혀 작동하지 않음 —
//   Writeln 한 줄도 안 찍히고 죽음). 우회책으로:
//   1) ReadIdent를 감싸던 안쪽 try/except를 제거함 (어차피 진단 목적이었고 신뢰 불가로 확인됨)
//   2) EOF 시의 break를 try 블록 "안"에서 바로 하지 않고, 플래그(_eof)로만 표시한 뒤
//      try/except 블록이 끝난 "밖"에서 break하도록 바꿈 — 보호구역(try)을 벗어나는 분기를
//      아예 없애서 Leave/Br 관련 IL 생성 문제를 원천적으로 피한다.
//   두 수정 모두 동작 자체(토큰화 결과)는 이전과 동일해야 한다.
// ============================================================
unit Lexer;

interface

uses
  System.Text,
  System.Collections.Generic;

type
  TTokenKind = (
    tkProgram, tkType, tkClass, tkRecord, tkInterface, tkPrivate, tkPublic,
    tkInternal, // [Stage 88c] internal 가시성 지정자 — 지금은 public과 동일하게 취급(접근 제어 미시행)
    tkVar, tkInteger, tkStringType, tkArray, tkOf, tkSet, // [Stage 63] tkSet
    tkBegin, tkEnd, tkWriteln,
    tkIf, tkThen, tkElse, tkWhile, tkDo, tkMod,
    tkFor, tkTo, tkDownto, tkIn, // [Stage 54] for-in 순회 구문의 'in' 키워드
    tkAnd, tkOr, tkNot, tkBoolean, tkTrue, tkFalse,
    tkTry, tkExcept, tkFinally, tkRaise, tkOn,
    tkFunction, tkProcedure, tkResult,
    tkIntToStr, tkBoolToStr, tkSetLength, tkLength,
    tkUses, tkNil, // [Stage 29] uses 절, nil 리터럴
    tkSelf, tkAs, tkInherited, // [Stage 30] self 키워드, as 캐스트, inherited 호출
    tkIs, // [자기컴파일] <식> is <TypeName> 런타임 타입 체크 — AST(TIsCheckExprNode)/CodeGen은 이미
          // Stage 93c에 준비돼 있었으나 Lexer/Parser에 'is' 키워드 인식이 빠져 있던 것을 보완.
    tkShl, tkShr, // [자기컴파일] 비트 시프트 연산자. AST(TBinOpKind.boShl/boShr)/CodeGen(Shl/Shr_Un)은
                  // 이미 준비돼 있었으나 Lexer/Parser에 실제 키워드 인식이 빠져 있던 것을 보완.
    tkNew, // [Stage 40] new TypeName(args) 객체 생성 구문
    tkConstructor, // [Stage 42] constructor Create; 선언/구현
    tkLibrary, // [Stage 44] library Name; 선언 (dll 산출물, begin...end 블록 생략 가능)
    tkUnit, tkImplementation, // [Stage 81] unit Name; interface ... implementation ... end. 구조
    tkVirtual, tkOverride, tkAbstract, // [Stage 53] virtual/override/abstract 메서드 지시자
    tkOperator, // [Stage 66] operator +(a, b: T): T; 연산자 오버로딩 선언
    // [Phase 1] 타입 시스템 확장
    tkReal, tkDouble, tkChar, tkInt64, // 숫자·문자 기본 타입
    tkProperty, tkRead, tkWrite,       // 프로퍼티 선언
    tkCase, // [Stage 59] case...of...else 문
    tkRepeat, tkUntil, // [Stage 60] repeat...until 루프
    tkBreak, tkContinue, // [Stage 60] break/continue
    tkExit, // [Stage 78] exit — 현재 프로시저/함수/메서드를 즉시 빠져나감(외부 메서드 호출로 오인되지 않도록 전용 키워드 토큰으로 인식)
    tkYield, tkSequence, // [Stage 69] yield / sequence of T — 시퀀스 lazy evaluation
    tkConst, // [Stage 61] const 선언 (전역/지역, 타입 추론 포함)
    tkIdent, tkString, tkIntLiteral, tkRealLiteral, tkCharLiteral,
    tkSemicolon, tkColon, tkComma, tkAssign, tkArrow, // [Stage 64] tkArrow = '->'
    tkPlus, tkMinus, tkStar, tkSlash, tkPlusAssign,
    tkEq, tkNeq, tkLt, tkGt, tkLe, tkGe,
    tkLParen, tkRParen, tkLBracket, tkRBracket,
    tkDot, tkDotDot, tkEOF // [Stage 59] tkDotDot: case 라벨의 1..5 형태 범위
  );

  TToken = class
  public
    Kind: TTokenKind; Text: string; Line: integer;
    Column: integer; // [Stage 35] 토큰이 시작하는 열 번호 (1-based)
    // [Phase 1] 실수 리터럴의 파싱된 값 (Kind=tkRealLiteral일 때만 유효).
    // Parser가 Text를 다시 ParseDouble 하는 대신 여기서 한 번만 변환.
    RealValue: double;
    // [Phase 1] 문자 리터럴의 파싱된 값 (Kind=tkCharLiteral일 때만 유효).
    CharValue: char;
    constructor Create(k: TTokenKind; t: string; l: integer; c: integer);
    begin Kind:=k; Text:=t; Line:=l; Column:=c; RealValue:=0.0; CharValue:=#0; end;
  end;

  TLexer = class
  private
    fChars: array of char; fPos, fLine, fCol: integer;
  public
    // [Stage 35] '알 수 없는 문자' 오류는 서로 독립적이므로, 하나 만나도 즉시 멈추지 않고
    // 문제 문자만 건너뛴 뒤 계속 스캔하면서 전부 모은다. Tokenize 끝에서 하나라도 있으면
    // 모아둔 목록 전체를 담은 예외 하나를 던진다(= 한 번의 컴파일 시도로 여러 오류를 다 보여줌).
    // 문자열이 닫히지 않는 경우(따옴표 짝 안 맞음)는 이후 스캔 전체가 신뢰할 수 없어지므로
    // 기존처럼 즉시 예외를 던진다.
    LexErrors: List<string>;
    // [Stage 45] {$reference X.dll} 지시문에서 뽑아낸 어셈블리 이름/경로 목록.
    // 예전에는 {...}를 전부 일반 주석으로 그냥 건너뛰어서 이 정보가 통째로 사라졌다 —
    // Main.pas가 컴파일 전에 이 목록을 보고 AddReferenceAssembly를 호출해줘야
    // System.Windows.Window 같은 실제 외부 어셈블리 타입을 쓸 수 있다.
    ReferenceDirectives: List<string>;
    // [Stage 69] {$apptype windows|console} 지시문에서 뽑아낸 값. 못 만나면 '' (Main.pas가 기본값 'console'로 취급).
    AppTypeDirective: string;
  private

    function CC: char;
    begin if fPos<Length(fChars) then Result:=fChars[fPos] else Result:=#0; end;

    function PC: char;
    begin if fPos+1<Length(fChars) then Result:=fChars[fPos+1] else Result:=#0; end;

    // [Stage 35] 문자 하나를 소비하면서 줄/열을 함께 갱신한다.
    // 개행 문자 자체를 소비할 때 다음 문자가 1열이 되도록 fCol을 리셋한다.
    procedure Adv;
    begin
      if CC=#10 then begin fLine:=fLine+1; fCol:=1; end
      else fCol:=fCol+1;
      fPos:=fPos+1;
    end;

    procedure SkipWS;
    begin
      while true do
      begin
        while (CC=' ') or (CC=#9) or (CC=#10) or (CC=#13) do Adv;
        if (CC='/') and (PC='/') then
        begin
          // // 줄 주석: 줄 끝까지 건너뜀
          while (CC<>#10) and (CC<>#0) do Adv;
        end
        else if CC='{' then
        begin
          // { } 블록 주석 — 단, {$reference X.dll} 형태는 내용을 뽑아서 ReferenceDirectives에 담는다.
          // (다른 {$...} 지시문, 예: {$apptype windows}는 예전처럼 그냥 무시한다.)
          var _dirSb:=new System.Text.StringBuilder();
          Adv;
          while (CC<>'}') and (CC<>#0) do begin _dirSb.Append(CC); Adv; end;
          if CC='}' then Adv;
          var _dirText:=_dirSb.ToString.Trim;
          if _dirText.StartsWith('$') then
          begin
            var _dirBody:=_dirText.Substring(1).Trim; // '$' 제거
            if _dirBody.ToLower.StartsWith('reference') then
            begin
              var _refName:=_dirBody.Substring('reference'.Length).Trim;
              if _refName<>'' then ReferenceDirectives.Add(_refName);
            end
            else if _dirBody.ToLower.StartsWith('apptype') then
            begin
              // [Stage 69] {$apptype windows} / {$apptype console}
              var _appVal:=_dirBody.Substring('apptype'.Length).Trim.ToLower;
              if (_appVal='windows') or (_appVal='console') then
                AppTypeDirective:=_appVal;
            end;
            // reference/apptype이 아닌 다른 지시문은 지금은 그냥 무시.
          end;
        end
        else if (CC='(') and (PC='*') then
        begin
          // (* *) 블록 주석
          Adv; Adv;
          while not(((CC='*') and (PC=')')) or (CC=#0)) do Adv;
          if CC='*' then begin Adv; Adv; end;
        end
        else
          break; // 공백도 주석도 아니면 종료
      end;
    end;

    function ReadIdent: TToken;
    var sl, sc: integer; sb: StringBuilder; w, lw: string; wasEscaped: boolean;
    begin
      sl:=fLine; sc:=fCol; sb:=new StringBuilder;
      // [Stage 88c] &Label — 맨 앞의 &는 "다음 이름을 예약어로 보지 말고 무조건 평범한
      // 식별자로 취급하라"는 표시일 뿐, 식별자 텍스트 자체에는 포함되지 않는다.
      wasEscaped:=false;
      if CC='&' then begin wasEscaped:=true; Adv; end;
      while Char.IsLetterOrDigit(CC) or (CC='_') do begin sb.Append(CC); Adv; end;
      w:=sb.ToString; lw:=w.ToLower;
      if wasEscaped then begin Result:=new TToken(tkIdent, w,sl,sc); exit; end;
      if      lw='program'   then Result:=new TToken(tkProgram,   w,sl,sc)
      else if lw='type'      then Result:=new TToken(tkType,      w,sl,sc)
      else if lw='class'     then Result:=new TToken(tkClass,     w,sl,sc)
      else if lw='record'    then Result:=new TToken(tkRecord,    w,sl,sc) // [Stage 62]
      else if lw='interface' then Result:=new TToken(tkInterface, w,sl,sc)
      else if lw='private'   then Result:=new TToken(tkPrivate,   w,sl,sc)
      else if lw='public'    then Result:=new TToken(tkPublic,    w,sl,sc)
      else if lw='internal'  then Result:=new TToken(tkInternal,  w,sl,sc) // [Stage 88c]
      else if lw='var'       then Result:=new TToken(tkVar,       w,sl,sc)
      else if lw='integer'   then Result:=new TToken(tkInteger,   w,sl,sc)
      else if lw='string'    then Result:=new TToken(tkStringType,w,sl,sc)
      else if lw='array'     then Result:=new TToken(tkArray,     w,sl,sc)
      else if lw='of'        then Result:=new TToken(tkOf,        w,sl,sc)
      else if lw='set'       then Result:=new TToken(tkSet,       w,sl,sc) // [Stage 63]
      else if lw='begin'     then Result:=new TToken(tkBegin,     w,sl,sc)
      else if lw='end'       then Result:=new TToken(tkEnd,       w,sl,sc)
      else if lw='writeln'   then Result:=new TToken(tkWriteln,   w,sl,sc)
      else if lw='if'        then Result:=new TToken(tkIf,        w,sl,sc)
      else if lw='then'      then Result:=new TToken(tkThen,      w,sl,sc)
      else if lw='else'      then Result:=new TToken(tkElse,      w,sl,sc)
      else if lw='while'     then Result:=new TToken(tkWhile,     w,sl,sc)
      else if lw='do'        then Result:=new TToken(tkDo,        w,sl,sc)
      else if lw='mod'       then Result:=new TToken(tkMod,       w,sl,sc)
      else if lw='for'       then Result:=new TToken(tkFor,       w,sl,sc)
      // [Stage 101] foreach — 이 컴파일러 자신의 소스(Parser.pas 등 self-hosting 대상 7개 파일)가
      // 전부 Pascal 고유의 "for x in y do" 대신 C# 스타일 "foreach x in y do"/"foreach var x in y do"를
      // 쓰기 때문에, 셀프호스팅 컴파일 시 foreach가 그냥 tkIdent로 읽혀 "foreach"라는 이름의 변수에
      // 대입하는 문장으로 오인되어 즉시 어긋났었다. foreach를 tkFor와 완전히 같은 토큰으로 취급해
      // 기존 for-in 파싱 경로를 그대로 재사용한다.
      else if lw='foreach'    then Result:=new TToken(tkFor,       w,sl,sc)
      else if lw='to'        then Result:=new TToken(tkTo,        w,sl,sc)
      else if lw='downto'    then Result:=new TToken(tkDownto,    w,sl,sc)
      else if lw='in'        then Result:=new TToken(tkIn,        w,sl,sc) // [Stage 54]
      else if lw='and'       then Result:=new TToken(tkAnd,       w,sl,sc)
      else if lw='or'        then Result:=new TToken(tkOr,        w,sl,sc)
      else if lw='not'       then Result:=new TToken(tkNot,       w,sl,sc)
      else if lw='boolean'   then Result:=new TToken(tkBoolean,   w,sl,sc)
      else if lw='true'      then Result:=new TToken(tkTrue,      w,sl,sc)
      else if lw='false'     then Result:=new TToken(tkFalse,     w,sl,sc)
      else if lw='try'       then Result:=new TToken(tkTry,       w,sl,sc)
      else if lw='except'    then Result:=new TToken(tkExcept,    w,sl,sc)
      else if lw='finally'   then Result:=new TToken(tkFinally,   w,sl,sc)
      else if lw='raise'     then Result:=new TToken(tkRaise,     w,sl,sc)
      else if lw='on'        then Result:=new TToken(tkOn,        w,sl,sc)
      else if lw='function'  then Result:=new TToken(tkFunction,  w,sl,sc)
      else if lw='procedure' then Result:=new TToken(tkProcedure, w,sl,sc)
      else if lw='result'    then Result:=new TToken(tkResult,    w,sl,sc)
      else if lw='inttostr'  then Result:=new TToken(tkIntToStr,  w,sl,sc)
      else if lw='booltostr' then Result:=new TToken(tkBoolToStr, w,sl,sc)
      else if lw='setlength' then Result:=new TToken(tkSetLength, w,sl,sc)
      else if lw='length'    then Result:=new TToken(tkLength,    w,sl,sc)
      else if lw='uses'      then Result:=new TToken(tkUses,      w,sl,sc)
      else if lw='nil'       then Result:=new TToken(tkNil,       w,sl,sc)
      else if lw='self'      then Result:=new TToken(tkSelf,      w,sl,sc) // [Stage 30]
      else if lw='as'        then Result:=new TToken(tkAs,        w,sl,sc) // [Stage 30]
      else if lw='is'        then Result:=new TToken(tkIs,        w,sl,sc) // [자기컴파일] is 타입체크
      else if lw='shl'       then Result:=new TToken(tkShl,       w,sl,sc) // [자기컴파일] 왼쪽 시프트
      else if lw='shr'       then Result:=new TToken(tkShr,       w,sl,sc) // [자기컴파일] 오른쪽 시프트
      else if lw='inherited' then Result:=new TToken(tkInherited, w,sl,sc) // [Stage 30]
      else if lw='new'       then Result:=new TToken(tkNew,       w,sl,sc) // [Stage 40]
      else if lw='constructor' then Result:=new TToken(tkConstructor, w,sl,sc) // [Stage 42]
      else if lw='library' then Result:=new TToken(tkLibrary, w,sl,sc) // [Stage 44]
      else if lw='virtual'  then Result:=new TToken(tkVirtual,  w,sl,sc) // [Stage 53]
      else if lw='override' then Result:=new TToken(tkOverride, w,sl,sc) // [Stage 53]
      else if lw='abstract' then Result:=new TToken(tkAbstract, w,sl,sc) // [Stage 53]
      else if lw='operator' then Result:=new TToken(tkOperator, w,sl,sc) // [Stage 66]
      // [Phase 1] 타입 시스템 확장 키워드
      else if lw='real'     then Result:=new TToken(tkReal,     w,sl,sc)
      else if lw='double'   then Result:=new TToken(tkDouble,   w,sl,sc)
      else if lw='char'     then Result:=new TToken(tkChar,     w,sl,sc)
      else if lw='int64'    then Result:=new TToken(tkInt64,    w,sl,sc)
      else if lw='property' then Result:=new TToken(tkProperty, w,sl,sc)
      else if lw='read'     then Result:=new TToken(tkRead,     w,sl,sc)
      else if lw='write'    then Result:=new TToken(tkWrite,    w,sl,sc)
      else if lw='case'     then Result:=new TToken(tkCase,     w,sl,sc) // [Stage 59]
      else if lw='repeat'   then Result:=new TToken(tkRepeat,   w,sl,sc) // [Stage 60]
      else if lw='until'    then Result:=new TToken(tkUntil,    w,sl,sc) // [Stage 60]
      else if lw='break'    then Result:=new TToken(tkBreak,    w,sl,sc) // [Stage 60]
      else if lw='continue' then Result:=new TToken(tkContinue, w,sl,sc) // [Stage 60]
      else if lw='exit'     then Result:=new TToken(tkExit,     w,sl,sc) // [Stage 78]
      else if lw='yield'    then Result:=new TToken(tkYield,    w,sl,sc) // [Stage 69]
      else if lw='sequence' then Result:=new TToken(tkSequence, w,sl,sc) // [Stage 69]
      else if lw='const'    then Result:=new TToken(tkConst,    w,sl,sc) // [Stage 61]
      else if lw='unit'     then Result:=new TToken(tkUnit,     w,sl,sc) // [Stage 81]
      else if lw='implementation' then Result:=new TToken(tkImplementation, w,sl,sc) // [Stage 81]
      else                        Result:=new TToken(tkIdent,     w,sl,sc);
    end;

    // [Phase 1] 정수 또는 실수 리터럴을 읽는다.
    // 소수점(.) 또는 지수부(e/E)가 있으면 tkRealLiteral, 없으면 tkIntLiteral.
    function ReadNum: TToken;
    var sl, sc: integer; sb: StringBuilder; tok: TToken;
    begin
      sl:=fLine; sc:=fCol; sb:=new StringBuilder;
      while Char.IsDigit(CC) do begin sb.Append(CC); Adv; end;
      // 소수점이 있고, 그 다음이 숫자면 실수 (예: 3.14). 단, '.' 단독(레코드 접근 등)은 제외.
      if (CC='.') and Char.IsDigit(PC) then
      begin
        sb.Append(CC); Adv; // '.' 소비
        while Char.IsDigit(CC) do begin sb.Append(CC); Adv; end;
      end;
      // 지수부 (e/E [+/-] digits)
      if (CC='e') or (CC='E') then
      begin
        sb.Append(CC); Adv;
        if (CC='+') or (CC='-') then begin sb.Append(CC); Adv; end;
        while Char.IsDigit(CC) do begin sb.Append(CC); Adv; end;
      end;
      var s:=sb.ToString;
      if s.Contains('.') or s.Contains('e') or s.Contains('E') then
      begin
        tok:=new TToken(tkRealLiteral, s, sl, sc);
        tok.RealValue:=double.Parse(s, System.Globalization.CultureInfo.InvariantCulture);
        Result:=tok;
      end
      else
        Result:=new TToken(tkIntLiteral, s, sl, sc);
    end;

    // [Phase 1] #N 형태의 문자 리터럴 (예: #65 = 'A', #10 = 줄바꿈)
    function ReadCharCode: TToken;
    var sl, sc: integer; sb: StringBuilder; code: integer;
    begin
      sl:=fLine; sc:=fCol;
      Adv; // '#' 소비
      sb:=new StringBuilder;
      while Char.IsDigit(CC) do begin sb.Append(CC); Adv; end;
      if sb.Length=0 then
        raise new Exception('줄 '+sl.ToString+', 열 '+sc.ToString+': # 뒤에 숫자가 와야 합니다');
      code:=integer.Parse(sb.ToString);
      var tok:=new TToken(tkCharLiteral, '#'+sb.ToString, sl, sc);
      tok.CharValue:=char(code);
      Result:=tok;
    end;

    function ReadStr: TToken;
    var sl, sc: integer; sb: StringBuilder;
    begin
      sl:=fLine; sc:=fCol; sb:=new StringBuilder; Adv;
      while (CC<>#39) and (CC<>#0) do begin sb.Append(CC); Adv; end;
      if CC=#39 then Adv
      else raise new Exception('줄 '+sl.ToString+', 열 '+sc.ToString+': 문자열 닫히지 않음');
      Result:=new TToken(tkString, sb.ToString, sl, sc);
    end;

  public
    constructor Create(src: string);
    begin
      Writeln('[MARK-A] TLexer.Create 진입, src.Length=' + src.Length.ToString);
      fChars:=src.ToCharArray; fPos:=0; fLine:=1; fCol:=1;
      Writeln('[MARK-B] fChars 대입 완료, fChars.Length=' + Length(fChars).ToString);
      LexErrors:=new List<string>;
      ReferenceDirectives:=new List<string>; // [Stage 45]
      AppTypeDirective:=''; // [Stage 69]
      Writeln('[MARK-B2] TLexer.Create 종료');
    end;

    function Tokenize: List<TToken>;
    var toks: List<TToken>; ch: char; sc: integer; _sl0, _sc0, _sp0: integer; _iterN: integer; _eof: boolean;
    begin
      Writeln('[MARK-C] Tokenize 진입');
      toks:=new List<TToken>;
      _iterN:=0;
      Writeln('[MARK-D] while 루프 진입 직전');
      while true do
      begin
        // [진단] 예외 기반 진단(try/except)이 이 특정 구조(중첩 try + 루프 안 break)에서
        // 예외를 못 잡는 것으로 확인됐다 — 예외 처리에 의존하지 않는 "무조건 찍히는"
        // 순수 진행 로그로 바꾼다. 이 프로젝트의 StripComments 진행 로그와 같은 방식:
        // 크래시가 나도 그 직전까지 출력된 로그는 이미 콘솔에 나가 있으므로, 마지막으로
        // 찍힌 줄/열/fPos를 보면 정확히 어느 반복에서 멈췄는지 알 수 있다.
        // [Stage 110 진단] mod 50으로는 self-compiled exe가 iter=50 이전에 죽어서 위치를
        // 못 잡았다. mod 1(매 반복)은 출력량이 너무 많아 콘솔이 감당 못해 사실상 멈춘
        // 것처럼 보였다 — 절충안: 앞쪽 60번은 무조건 찍어 조기 크래시 지점을 놓치지 않고,
        // 그 이후엔 2000번마다만 찍어 총 출력량을 확 줄인다.
        _iterN:=_iterN+1;
        if (_iterN<=60) or ((_iterN mod 2000)=0) then
          Writeln('[진단] Tokenize 진행중: iter=' + _iterN.ToString + ', fLine=' + fLine.ToString +
            ', fCol=' + fCol.ToString + ', fPos=' + fPos.ToString + ', 토큰수=' + toks.Count.ToString);
        _sl0:=fLine; _sc0:=fCol; _sp0:=fPos;
        _eof:=false; // [Stage 111] try 안에서 곧장 break하지 않고, 플래그만 세운다.
        try
        begin
        SkipWS; ch:=CC; sc:=fCol;
        if ch=#0 then begin toks.Add(new TToken(tkEOF,'',fLine,fCol)); _eof:=true; end
        // [Stage 111] ReadIdent를 감싸던 안쪽 try/except를 제거했다 — 진단 목적으로 넣었던
        // 것인데, "중첩 try + 루프 안 break" 구조 자체가 self-compiled 바이너리에서 문제를
        // 일으키는 것으로 추정되어(진단 Writeln조차 안 찍히고 죽음) 오히려 원인 쪽에 가까웠다.
        // 예외는 바깥쪽 try/except가 그대로 잡아 로그를 남긴다(아래 except 블록 참고).
        else if Char.IsLetter(ch) or (ch='_') then toks.Add(ReadIdent)
        // [Stage 88c] &Label 같은 이스케이프된 식별자 — Label처럼 예약어와 충돌하는
        // 이름을 강제로 "그냥 식별자"로 쓰겠다는 표시. & 다음에 글자/밑줄이 와야 진짜
        // 이스케이프고, 그렇지 않으면(예: 접근 연산자 등으로 쓰일 가능성 대비) 그냥 통과.
        else if (ch='&') and (Char.IsLetter(PC) or (PC='_')) then toks.Add(ReadIdent)
        else if Char.IsDigit(ch) then toks.Add(ReadNum)
        else if ch='#' then toks.Add(ReadCharCode) // [Phase 1] #65 형태 문자 리터럴
        else if ch=#39 then
        begin
          // [버그 수정] 예전에는 여는 따옴표 바로 다음이 닫는 따옴표면 무조건 "빈 문자열"로
          // 처리했다 — 그런데 표준 Pascal에서 문자열 안의 ''는 리터럴 따옴표 한 글자를
          // 뜻한다(예: 'it''s' = it's). 그 구분(빈 문자열 vs 이스케이프된 따옴표)은 문맥
          // 없이는 앞글자만 봐서 알 수 없으므로, 전체를 한 번에 스캔하는 통일된 방식으로
          // 다시 짰다: '가 나오면 다음 글자를 봐서 또 '면 이스케이프(따옴표 한 글자를 담고
          // 계속), 아니면 진짜 닫는 따옴표. 다 읽은 뒤 담긴 글자 수가 정확히 1개면
          // 문자 리터럴(예: 'A'), 그 외(0개 또는 2개 이상)면 문자열 리터럴로 판정한다 —
          // 판정 기준 자체는 예전과 같고, 이스케이프 처리만 새로 생겼다.
          var _csl:=fLine; var _csc:=fCol;
          Adv; // 여는 따옴표 소비
          var _sb2:=new System.Text.StringBuilder;
          var _qcnt:=0; var _qlast:=#0;
          while true do
          begin
            if CC=#0 then
              raise new Exception('줄 '+_csl.ToString+', 열 '+_csc.ToString+': 문자열 닫히지 않음');
            if CC=#39 then
            begin
              Adv; // 따옴표 하나 소비
              if CC=#39 then
              begin
                // '' — 이스케이프된 따옴표 한 글자
                _sb2.Append(#39); _qcnt:=_qcnt+1; _qlast:=#39; Adv;
              end
              else
                break; // 진짜 닫는 따옴표
            end
            else
            begin
              _sb2.Append(CC); _qcnt:=_qcnt+1; _qlast:=CC; Adv;
            end;
          end;
          if _qcnt=1 then
          begin
            var _ct:=new TToken(tkCharLiteral, #39+_qlast+#39, _csl, _csc);
            _ct.CharValue:=_qlast;
            toks.Add(_ct);
          end
          else
            toks.Add(new TToken(tkString, _sb2.ToString, _csl, _csc));
        end
        else if ch=';' then begin toks.Add(new TToken(tkSemicolon,';',fLine,sc)); Adv; end
        else if ch=',' then begin toks.Add(new TToken(tkComma,',',fLine,sc)); Adv; end
        else if ch='[' then begin toks.Add(new TToken(tkLBracket,'[',fLine,sc)); Adv; end
        else if ch=']' then begin toks.Add(new TToken(tkRBracket,']',fLine,sc)); Adv; end
        else if (ch=':') and (PC='=') then
          begin toks.Add(new TToken(tkAssign,':=',fLine,sc)); Adv; Adv; end
        else if ch=':' then begin toks.Add(new TToken(tkColon,':',fLine,sc)); Adv; end
        else if (ch='<') and (PC='>') then
          begin toks.Add(new TToken(tkNeq,'<>',fLine,sc)); Adv; Adv; end
        else if (ch='<') and (PC='=') then
          begin toks.Add(new TToken(tkLe,'<=',fLine,sc)); Adv; Adv; end
        else if (ch='>') and (PC='=') then
          begin toks.Add(new TToken(tkGe,'>=',fLine,sc)); Adv; Adv; end
        else if ch='<' then begin toks.Add(new TToken(tkLt,'<',fLine,sc)); Adv; end
        else if ch='>' then begin toks.Add(new TToken(tkGt,'>',fLine,sc)); Adv; end
        else if ch='=' then begin toks.Add(new TToken(tkEq,'=',fLine,sc)); Adv; end
        else if (ch='+') and (PC='=') then
          begin toks.Add(new TToken(tkPlusAssign,'+=',fLine,sc)); Adv; Adv; end
        else if ch='+' then begin toks.Add(new TToken(tkPlus,'+',fLine,sc)); Adv; end
        else if (ch='-') and (PC='>') then // [Stage 64] 람다 화살표
          begin toks.Add(new TToken(tkArrow,'->',fLine,sc)); Adv; Adv; end
        else if ch='-' then begin toks.Add(new TToken(tkMinus,'-',fLine,sc)); Adv; end
        else if ch='*' then begin toks.Add(new TToken(tkStar,'*',fLine,sc)); Adv; end
        else if ch='/' then begin toks.Add(new TToken(tkSlash,'/',fLine,sc)); Adv; end
        else if ch='(' then begin toks.Add(new TToken(tkLParen,'(',fLine,sc)); Adv; end
        else if ch=')' then begin toks.Add(new TToken(tkRParen,')',fLine,sc)); Adv; end
        else if (ch='.') and (PC='.') then // [Stage 59] '..' 범위 연산자 (case 라벨: 1..5)
          begin toks.Add(new TToken(tkDotDot,'..',fLine,sc)); Adv; Adv; end
        else if ch='.' then begin toks.Add(new TToken(tkDot,'.',fLine,sc)); Adv; end
        else begin
          // [Stage 35] 즉시 던지지 않고 모아둔다 — 문제 문자 하나를 건너뛰고 스캔을 계속한다.
          LexErrors.Add('줄 '+fLine.ToString+', 열 '+fCol.ToString+': 알 수 없는 문자 '+#39+ch.ToString+#39);
          Adv;
        end;
        end; // [진단] try 시작(SkipWS 포함, 이번 반복 전체) 종료
        except
          on E: Exception do
          begin
            // [진단] SkipWS의 {$...} 지시문 파싱, 문자열 리터럴 처리, ReadIdent, ReadNum,
            // ReadCharCode 등 이 반복에서 일어난 예외의 위치를 정확히 찍는다 — 반복
            // "시작 시점"과 "예외 시점" 위치를 함께 보여줘서 어느 문자/구간에서 죽었는지
            // 바로 드러나게 한다.
            Writeln('[진단] Tokenize 반복 예외: 반복시작 line=' + _sl0.ToString + ', col=' + _sc0.ToString + ', pos=' + _sp0.ToString +
              ' / 예외시점 fLine=' + fLine.ToString + ', fCol=' + fCol.ToString + ', fPos=' + fPos.ToString +
              ', 현재CC=' + #39 + CC + #39 + '(코드 ' + integer(CC).ToString + '), 다음PC=' + #39 + PC + #39 + '(코드 ' + integer(PC).ToString + ')');
            Writeln('[진단] 예외 타입: ' + E.GetType.FullName + ', 메시지: ' + E.Message);
            Writeln('[진단] 지금까지 읽은 토큰 수: ' + toks.Count.ToString);
            if toks.Count>0 then
              Writeln('[진단] 마지막 성공 토큰: Kind=' + toks[toks.Count-1].Kind.ToString + ', Text="' + toks[toks.Count-1].Text + '"');
            raise;
          end;
        end;
        // [Stage 111] try/except 블록을 완전히 벗어난 지점에서 break한다 — 보호구역(try) 안에서
        // 곧장 break하지 않도록 해서, 그로 인한 IL 생성 문제 가능성을 원천적으로 피한다.
        if _eof then break;
      end;

      if LexErrors.Count>0 then
        raise new Exception('어휘 분석 오류 '+LexErrors.Count.ToString+'건 발견:'#10+string.Join(#10, LexErrors));

      Result:=toks;
    end;
  end;

implementation

end.