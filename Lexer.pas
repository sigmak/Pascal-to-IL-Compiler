// ============================================================
// Lexer.pas — 어휘 분석 (TTokenKind, TToken, TLexer)
// 다른 프로젝트 unit에 의존하지 않음 (System.* 만 사용).
// 이 unit이 몇 Stage째 안 바뀐다면 = 어휘 분석은 안정화됐다는 신호.
// [Stage 35] 각 토큰에 시작 열(Column) 번호를 함께 기록해 진단 메시지에 사용한다.
// ============================================================
unit Lexer;

interface

uses
  System.Text,
  System.Collections.Generic;

type
  TTokenKind = (
    tkProgram, tkType, tkClass, tkRecord, tkInterface, tkPrivate, tkPublic,
    tkVar, tkInteger, tkStringType, tkArray, tkOf, tkSet, // [Stage 63] tkSet
    tkBegin, tkEnd, tkWriteln,
    tkIf, tkThen, tkElse, tkWhile, tkDo, tkMod,
    tkFor, tkTo, tkDownto, tkIn, // [Stage 54] for-in 순회 구문의 'in' 키워드
    tkAnd, tkOr, tkNot, tkBoolean, tkTrue, tkFalse,
    tkTry, tkExcept, tkFinally, tkRaise, tkOn,
    tkFunction, tkProcedure, tkResult,
    tkIntToStr, tkSetLength, tkLength,
    tkUses, tkNil, // [Stage 29] uses 절, nil 리터럴
    tkSelf, tkAs, tkInherited, // [Stage 30] self 키워드, as 캐스트, inherited 호출
    tkNew, // [Stage 40] new TypeName(args) 객체 생성 구문
    tkConstructor, // [Stage 42] constructor Create; 선언/구현
    tkLibrary, // [Stage 44] library Name; 선언 (dll 산출물, begin...end 블록 생략 가능)
    tkVirtual, tkOverride, tkAbstract, // [Stage 53] virtual/override/abstract 메서드 지시자
    // [Phase 1] 타입 시스템 확장
    tkReal, tkDouble, tkChar, tkInt64, // 숫자·문자 기본 타입
    tkProperty, tkRead, tkWrite,       // 프로퍼티 선언
    tkCase, // [Stage 59] case...of...else 문
    tkRepeat, tkUntil, // [Stage 60] repeat...until 루프
    tkBreak, tkContinue, // [Stage 60] break/continue
    tkConst, // [Stage 61] const 선언 (전역/지역, 타입 추론 포함)
    tkIdent, tkString, tkIntLiteral, tkRealLiteral, tkCharLiteral,
    tkSemicolon, tkColon, tkComma, tkAssign,
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
            end;
            // reference가 아닌 다른 지시문(apptype 등)은 지금은 그냥 무시.
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
    var sl, sc: integer; sb: StringBuilder; w, lw: string;
    begin
      sl:=fLine; sc:=fCol; sb:=new StringBuilder;
      while Char.IsLetterOrDigit(CC) or (CC='_') do begin sb.Append(CC); Adv; end;
      w:=sb.ToString; lw:=w.ToLower;
      if      lw='program'   then Result:=new TToken(tkProgram,   w,sl,sc)
      else if lw='type'      then Result:=new TToken(tkType,      w,sl,sc)
      else if lw='class'     then Result:=new TToken(tkClass,     w,sl,sc)
      else if lw='record'    then Result:=new TToken(tkRecord,    w,sl,sc) // [Stage 62]
      else if lw='interface' then Result:=new TToken(tkInterface, w,sl,sc)
      else if lw='private'   then Result:=new TToken(tkPrivate,   w,sl,sc)
      else if lw='public'    then Result:=new TToken(tkPublic,    w,sl,sc)
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
      else if lw='setlength' then Result:=new TToken(tkSetLength, w,sl,sc)
      else if lw='length'    then Result:=new TToken(tkLength,    w,sl,sc)
      else if lw='uses'      then Result:=new TToken(tkUses,      w,sl,sc)
      else if lw='nil'       then Result:=new TToken(tkNil,       w,sl,sc)
      else if lw='self'      then Result:=new TToken(tkSelf,      w,sl,sc) // [Stage 30]
      else if lw='as'        then Result:=new TToken(tkAs,        w,sl,sc) // [Stage 30]
      else if lw='inherited' then Result:=new TToken(tkInherited, w,sl,sc) // [Stage 30]
      else if lw='new'       then Result:=new TToken(tkNew,       w,sl,sc) // [Stage 40]
      else if lw='constructor' then Result:=new TToken(tkConstructor, w,sl,sc) // [Stage 42]
      else if lw='library' then Result:=new TToken(tkLibrary, w,sl,sc) // [Stage 44]
      else if lw='virtual'  then Result:=new TToken(tkVirtual,  w,sl,sc) // [Stage 53]
      else if lw='override' then Result:=new TToken(tkOverride, w,sl,sc) // [Stage 53]
      else if lw='abstract' then Result:=new TToken(tkAbstract, w,sl,sc) // [Stage 53]
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
      else if lw='const'    then Result:=new TToken(tkConst,    w,sl,sc) // [Stage 61]
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
      fChars:=src.ToCharArray; fPos:=0; fLine:=1; fCol:=1;
      LexErrors:=new List<string>;
      ReferenceDirectives:=new List<string>; // [Stage 45]
    end;

    function Tokenize: List<TToken>;
    var toks: List<TToken>; ch: char; sc: integer;
    begin
      toks:=new List<TToken>;
      while true do
      begin
        SkipWS; ch:=CC; sc:=fCol;
        if ch=#0 then begin toks.Add(new TToken(tkEOF,'',fLine,fCol)); break; end
        else if Char.IsLetter(ch) or (ch='_') then toks.Add(ReadIdent)
        else if Char.IsDigit(ch) then toks.Add(ReadNum)
        else if ch='#' then toks.Add(ReadCharCode) // [Phase 1] #65 형태 문자 리터럴
        else if ch=#39 then
        begin
          // [Phase 1] 단일 문자 리터럴 'A'와 문자열 리터럴 'hello'를 구분한다.
          // 따옴표 사이 내용이 정확히 1글자이고 닫히면 tkCharLiteral, 그 외에는 tkString.
          var _csl:=fLine; var _csc:=fCol;
          Adv; // 여는 따옴표 소비
          if (CC<>#39) and (CC<>#0) then
          begin
            var _ch:=CC; Adv;
            if CC=#39 then
            begin
              // 'X' — 단일 문자 리터럴
              Adv; // 닫는 따옴표
              var _ct:=new TToken(tkCharLiteral, #39+_ch+#39, _csl, _csc);
              _ct.CharValue:=_ch;
              toks.Add(_ct);
            end
            else
            begin
              // 두 글자 이상 → 문자열 리터럴로 처리. 이미 첫 글자를 소비했으므로 나머지를 읽는다.
              var _sb2:=new System.Text.StringBuilder;
              _sb2.Append(_ch);
              while (CC<>#39) and (CC<>#0) do begin _sb2.Append(CC); Adv; end;
              if CC=#39 then Adv
              else raise new Exception('줄 '+_csl.ToString+', 열 '+_csc.ToString+': 문자열 닫히지 않음');
              toks.Add(new TToken(tkString, _sb2.ToString, _csl, _csc));
            end;
          end
          else
          begin
            // '' — 빈 문자열
            if CC=#39 then Adv;
            toks.Add(new TToken(tkString, '', _csl, _csc));
          end;
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
      end;

      if LexErrors.Count>0 then
        raise new Exception('어휘 분석 오류 '+LexErrors.Count.ToString+'건 발견:'#10+string.Join(#10, LexErrors));

      Result:=toks;
    end;
  end;

implementation

end.