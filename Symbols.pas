// ============================================================
// Symbols.pas — [리팩터링 Stage] 클래스 심볼 테이블
// ------------------------------------------------------------
// Scope.pas가 변수 하나당 흩어져 있던 4개 Dictionary(Locals/Types/
// Class/ClrTypes)를 TScope 하나로 묶었던 것과 같은 원리로,
// CodeGen.pas가 "클래스명"을 키로 따로따로 관리하던 13개 병렬
// Dictionary(fTypeBuilders/fBuiltTypes/fFieldBuilders/fInstanceMethods/
// fAbstractMethods/fClassParents/fMethodReturnTypes/fMethodParamClrTypes/
// fCtorBuilders/fCtorParamClrTypes/fClassExternalParentType/
// fClassExternalInterfaceType/fFieldObjClassName)를 TClassSymbol
// 하나로 묶어나가기 위한 유닛.
//
// [마이그레이션 방침] 한 번에 13개를 다 옮기면 회귀 위험이 크므로,
// 필드 하나씩 단계적으로 옮긴다. 이번 1단계는 fClassParents만 이관.
// TClassSymbol에는 앞으로 옮길 필드 자리를 미리 마련해 두되, 아직
// CodeGen.pas가 쓰지 않는 필드는 주석으로만 남겨 둔다(실제로 채워지지
// 않는 필드를 미리 선언해 두면 "이 필드는 왜 항상 nil인가"하는 혼란만
// 생기므로, 실제로 쓰기 시작하는 단계에서 그 필드를 추가한다).
// ============================================================
unit Symbols;

interface

uses
  System.Collections.Generic;

type
  TClassSymbol = class
  public
    Name: string;
    ParentName: string; // [1단계] 기존 fClassParents[cn]. '' = 부모 없음(기존 ContainsKey=false와 동일하게 취급)

    constructor Create(n: string);
    begin
      Name:=n;
      ParentName:='';
    end;
  end;

  TClassTable = class
  public
    Entries: Dictionary<string, TClassSymbol>;

    constructor Create;
    begin
      Entries:=new Dictionary<string, TClassSymbol>;
    end;

    function Has(cn: string): boolean;
    begin
      Result:=Entries.ContainsKey(cn);
    end;

    // 없으면 만들어서 돌려준다 — 예전에 각 Dictionary마다 반복되던
    // "if not ContainsKey then Dict[cn]:=new ..." 초기화 보일러플레이트를 한 곳으로 모음.
    function GetOrCreate(cn: string): TClassSymbol;
    begin
      if not Entries.ContainsKey(cn) then
        Entries[cn]:=new TClassSymbol(cn);
      Result:=Entries[cn];
    end;

    // ---- ParentName 편의 접근자 ----
    // 기존 코드 곳곳의 "if fClassParents.ContainsKey(c) then c:=fClassParents[c] else c:='';"
    // 패턴을 이 한 줄 호출로 대체한다. cn이 테이블에 아예 없어도(클래스가 아직
    // 등록 전이어도) 예외 없이 ''을 돌려주므로 기존 호출부의 방어 로직과 동일하게 동작한다.
    function GetParentName(cn: string): string;
    begin
      if Entries.ContainsKey(cn) then Result:=Entries[cn].ParentName
      else Result:='';
    end;

    procedure SetParentName(cn, pn: string);
    begin
      GetOrCreate(cn).ParentName:=pn;
    end;
  end;

implementation

end.