// ============================================================
// Lexer.pas — 어휘 분석 (TTokenKind, TToken, TLexer)
// 다른 프로젝트 unit에 의존하지 않음 (System.* 만 사용).
// 이 unit이 몇 Stage째 안 바뀐다면 = 어휘 분석은 안정화됐다는 신호.
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
    constructor Create(k: TTokenKind; t: string; l: integer);
    begin Kind:=k; Text:=t; Line:=l; end;
  end;

  TLexer = class
  private
    fChars: array of char; fPos, fLine: integer;

    function CC: char;
    begin if fPos<Length(fChars) then Result:=fChars[fPos] else Result:=#0; end;

    function PC: char;
    begin if fPos+1<Length(fChars) then Result:=fChars[fPos+1] else Result:=#0; end;

    procedure Adv;
    begin if CC=#10 then fLine:=fLine+1; fPos:=fPos+1; end;

    procedure SkipWS;
    begin while (CC=' ') or (CC=#9) or (CC=#10) or (CC=#13) do Adv; end;

    function ReadIdent: TToken;
    var sl: integer; sb: StringBuilder; w, lw: string;
    begin
      sl:=fLine; sb:=new StringBuilder;
      while Char.IsLetterOrDigit(CC) or (CC='_') do begin sb.Append(CC); Adv; end;
      w:=sb.ToString; lw:=w.ToLower;
      if      lw='program'   then Result:=new TToken(tkProgram,   w,sl)
      else if lw='type'      then Result:=new TToken(tkType,      w,sl)
      else if lw='class'     then Result:=new TToken(tkClass,     w,sl)
      else if lw='interface' then Result:=new TToken(tkInterface, w,sl)
      else if lw='private'   then Result:=new TToken(tkPrivate,   w,sl)
      else if lw='public'    then Result:=new TToken(tkPublic,    w,sl)
      else if lw='var'       then Result:=new TToken(tkVar,       w,sl)
      else if lw='integer'   then Result:=new TToken(tkInteger,   w,sl)
      else if lw='string'    then Result:=new TToken(tkStringType,w,sl)
      else if lw='array'     then Result:=new TToken(tkArray,     w,sl)
      else if lw='of'        then Result:=new TToken(tkOf,        w,sl)
      else if lw='begin'     then Result:=new TToken(tkBegin,     w,sl)
      else if lw='end'       then Result:=new TToken(tkEnd,       w,sl)
      else if lw='writeln'   then Result:=new TToken(tkWriteln,   w,sl)
      else if lw='if'        then Result:=new TToken(tkIf,        w,sl)
      else if lw='then'      then Result:=new TToken(tkThen,      w,sl)
      else if lw='else'      then Result:=new TToken(tkElse,      w,sl)
      else if lw='while'     then Result:=new TToken(tkWhile,     w,sl)
      else if lw='do'        then Result:=new TToken(tkDo,        w,sl)
      else if lw='mod'       then Result:=new TToken(tkMod,       w,sl)
      else if lw='for'       then Result:=new TToken(tkFor,       w,sl)
      else if lw='to'        then Result:=new TToken(tkTo,        w,sl)
      else if lw='downto'    then Result:=new TToken(tkDownto,    w,sl)
      else if lw='and'       then Result:=new TToken(tkAnd,       w,sl)
      else if lw='or'        then Result:=new TToken(tkOr,        w,sl)
      else if lw='not'       then Result:=new TToken(tkNot,       w,sl)
      else if lw='boolean'   then Result:=new TToken(tkBoolean,   w,sl)
      else if lw='true'      then Result:=new TToken(tkTrue,      w,sl)
      else if lw='false'     then Result:=new TToken(tkFalse,     w,sl)
      else if lw='try'       then Result:=new TToken(tkTry,       w,sl)
      else if lw='except'    then Result:=new TToken(tkExcept,    w,sl)
      else if lw='finally'   then Result:=new TToken(tkFinally,   w,sl)
      else if lw='raise'     then Result:=new TToken(tkRaise,     w,sl)
      else if lw='on'        then Result:=new TToken(tkOn,        w,sl)
      else if lw='function'  then Result:=new TToken(tkFunction,  w,sl)
      else if lw='procedure' then Result:=new TToken(tkProcedure, w,sl)
      else if lw='result'    then Result:=new TToken(tkResult,    w,sl)
      else if lw='inttostr'  then Result:=new TToken(tkIntToStr,  w,sl)
      else if lw='setlength' then Result:=new TToken(tkSetLength, w,sl)
      else if lw='length'    then Result:=new TToken(tkLength,    w,sl)
      else                        Result:=new TToken(tkIdent,     w,sl);
    end;

    function ReadNum: TToken;
    var sl: integer; sb: StringBuilder;
    begin
      sl:=fLine; sb:=new StringBuilder;
      while Char.IsDigit(CC) do begin sb.Append(CC); Adv; end;
      Result:=new TToken(tkIntLiteral, sb.ToString, sl);
    end;

    function ReadStr: TToken;
    var sl: integer; sb: StringBuilder;
    begin
      sl:=fLine; sb:=new StringBuilder; Adv;
      while (CC<>#39) and (CC<>#0) do begin sb.Append(CC); Adv; end;
      if CC=#39 then Adv
      else raise new Exception('줄 '+sl.ToString+': 문자열 닫히지 않음');
      Result:=new TToken(tkString, sb.ToString, sl);
    end;

  public
    constructor Create(src: string);
    begin fChars:=src.ToCharArray; fPos:=0; fLine:=1; end;

    function Tokenize: List<TToken>;
    var toks: List<TToken>; ch: char;
    begin
      toks:=new List<TToken>;
      while true do
      begin
        SkipWS; ch:=CC;
        if ch=#0 then begin toks.Add(new TToken(tkEOF,'',fLine)); break; end
        else if Char.IsLetter(ch) or (ch='_') then toks.Add(ReadIdent)
        else if Char.IsDigit(ch) then toks.Add(ReadNum)
        else if ch=#39 then toks.Add(ReadStr)
        else if ch=';' then begin toks.Add(new TToken(tkSemicolon,';',fLine)); Adv; end
        else if ch=',' then begin toks.Add(new TToken(tkComma,',',fLine)); Adv; end
        else if ch='[' then begin toks.Add(new TToken(tkLBracket,'[',fLine)); Adv; end
        else if ch=']' then begin toks.Add(new TToken(tkRBracket,']',fLine)); Adv; end
        else if (ch=':') and (PC='=') then
          begin toks.Add(new TToken(tkAssign,':=',fLine)); Adv; Adv; end
        else if ch=':' then begin toks.Add(new TToken(tkColon,':',fLine)); Adv; end
        else if (ch='<') and (PC='>') then
          begin toks.Add(new TToken(tkNeq,'<>',fLine)); Adv; Adv; end
        else if (ch='<') and (PC='=') then
          begin toks.Add(new TToken(tkLe,'<=',fLine)); Adv; Adv; end
        else if (ch='>') and (PC='=') then
          begin toks.Add(new TToken(tkGe,'>=',fLine)); Adv; Adv; end
        else if ch='<' then begin toks.Add(new TToken(tkLt,'<',fLine)); Adv; end
        else if ch='>' then begin toks.Add(new TToken(tkGt,'>',fLine)); Adv; end
        else if ch='=' then begin toks.Add(new TToken(tkEq,'=',fLine)); Adv; end
        else if (ch='+') and (PC='=') then
          begin toks.Add(new TToken(tkPlusAssign,'+=',fLine)); Adv; Adv; end
        else if ch='+' then begin toks.Add(new TToken(tkPlus,'+',fLine)); Adv; end
        else if ch='-' then begin toks.Add(new TToken(tkMinus,'-',fLine)); Adv; end
        else if ch='*' then begin toks.Add(new TToken(tkStar,'*',fLine)); Adv; end
        else if ch='/' then begin toks.Add(new TToken(tkSlash,'/',fLine)); Adv; end
        else if ch='(' then begin toks.Add(new TToken(tkLParen,'(',fLine)); Adv; end
        else if ch=')' then begin toks.Add(new TToken(tkRParen,')',fLine)); Adv; end
        else if ch='.' then begin toks.Add(new TToken(tkDot,'.',fLine)); Adv; end
        else raise new Exception('줄 '+fLine.ToString+': 알 수 없는 문자 '+#39+ch.ToString+#39);
      end;
      Result:=toks;
    end;
  end;

implementation

end.