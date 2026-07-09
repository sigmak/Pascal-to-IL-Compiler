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
    tkProgram, tkType, tkClass, tkInterface, tkPrivate, tkPublic,
    tkVar, tkInteger, tkStringType, tkArray, tkOf,
    tkBegin, tkEnd, tkWriteln,
    tkIf, tkThen, tkElse, tkWhile, tkDo, tkMod,
    tkFor, tkTo, tkDownto,
    tkAnd, tkOr, tkNot, tkBoolean, tkTrue, tkFalse,
    tkTry, tkExcept, tkFinally, tkRaise, tkOn,
    tkFunction, tkProcedure, tkResult,
    tkIntToStr, tkSetLength, tkLength,
    tkUses, tkNil, // [Stage 29] uses 절, nil 리터럴
    tkSelf, tkAs, tkInherited, // [Stage 30] self 키워드, as 캐스트, inherited 호출
    tkIdent, tkString, tkIntLiteral,
    tkSemicolon, tkColon, tkComma, tkAssign,
    tkPlus, tkMinus, tkStar, tkSlash, tkPlusAssign,
    tkEq, tkNeq, tkLt, tkGt, tkLe, tkGe,
    tkLParen, tkRParen, tkLBracket, tkRBracket,
    tkDot, tkEOF
  );

  TToken = class
  public
    Kind: TTokenKind; Text: string; Line: integer;
    Column: integer; // [Stage 35] 토큰이 시작하는 열 번호 (1-based)
    constructor Create(k: TTokenKind; t: string; l: integer; c: integer);
    begin Kind:=k; Text:=t; Line:=l; Column:=c; end;
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
          // { } 블록 주석
          Adv;
          while (CC<>'}') and (CC<>#0) do Adv;
          if CC='}' then Adv;
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
      else if lw='interface' then Result:=new TToken(tkInterface, w,sl,sc)
      else if lw='private'   then Result:=new TToken(tkPrivate,   w,sl,sc)
      else if lw='public'    then Result:=new TToken(tkPublic,    w,sl,sc)
      else if lw='var'       then Result:=new TToken(tkVar,       w,sl,sc)
      else if lw='integer'   then Result:=new TToken(tkInteger,   w,sl,sc)
      else if lw='string'    then Result:=new TToken(tkStringType,w,sl,sc)
      else if lw='array'     then Result:=new TToken(tkArray,     w,sl,sc)
      else if lw='of'        then Result:=new TToken(tkOf,        w,sl,sc)
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
      else                        Result:=new TToken(tkIdent,     w,sl,sc);
    end;

    function ReadNum: TToken;
    var sl, sc: integer; sb: StringBuilder;
    begin
      sl:=fLine; sc:=fCol; sb:=new StringBuilder;
      while Char.IsDigit(CC) do begin sb.Append(CC); Adv; end;
      Result:=new TToken(tkIntLiteral, sb.ToString, sl, sc);
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
    begin fChars:=src.ToCharArray; fPos:=0; fLine:=1; fCol:=1; LexErrors:=new List<string>; end;

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
        else if ch=#39 then toks.Add(ReadStr)
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