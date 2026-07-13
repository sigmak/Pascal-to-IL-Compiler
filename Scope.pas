// ============================================================
// Scope.pas — [Phase 2] 변수 스코프 체인
// ------------------------------------------------------------
// CodeGen이 기존에 변수 하나당 4개의 병렬 Dictionary(Locals/Types/
// Class/ClrTypes) × (Local/Global) = 8개를 따로 관리하던 것을,
// "이름 → TScopeEntry" 하나의 Dictionary로 묶은 TScope 두 개
// (fLocalScope, fGlobalScope)로 정리한다.
//
// TScope는 Parent로 상위 스코프를 가리킬 수 있어, 나중에 중첩
// 함수/람다처럼 스코프가 여러 겹으로 쌓이는 기능을 추가할 때도
// (현재의 로컬/전역 2단 구조를 넘어) 그대로 확장해서 쓸 수 있다.
// 지금 당장은 CodeGen이 로컬을 우선 확인하고 없으면 전역을 보는
// 기존 순서를 그대로 보존하기 위해 Has/Get류는 "이 스코프만" 보고,
// Resolve류는 Parent 체인을 따라 올라가며 찾는다(향후 람다용).
// ============================================================
unit Scope;

interface

uses
  System.Collections.Generic,
  System.Reflection,
  System.Reflection.Emit,
  AST;

type
  // 변수/매개변수 하나에 대한 정보를 한데 모은 항목.
  // 예전에는 fLocals[n], fLocalTypes[n], fLocalClass[n], fLocalClrTypes[n]
  // 4곳에 나뉘어 있던 정보가 이제 이 레코드 하나에 들어간다.
  TScopeEntry = class
  public
    Loc: LocalBuilder;      // 대응하는 CLR 로컬 슬롯
    VType: TVarType;        // 선언된 Pascal 타입
    ClassName: string;      // vtObject/vtEnum/vtInterface일 때 클래스·열거형·인터페이스 이름 ('' = 없음)
    ClrType: System.Type;   // object/외부타입 변수의 실제 CLR 타입 (nil = 미지정 — 기존 ContainsKey=false에 대응)
    constructor Create(l: LocalBuilder; vt: TVarType);
    begin
      Loc:=l; VType:=vt; ClassName:=''; ClrType:=nil;
    end;
  end;

  TScope = class
  public
    Name: string;      // 디버깅용 ('local' / 'global' 등)
    Parent: TScope;     // 상위 스코프 (전역 스코프는 nil). 미래의 중첩 스코프(람다 등)를 위한 체인.
    Entries: Dictionary<string, TScopeEntry>;

    constructor Create(n: string; p: TScope);
    begin
      Name:=n; Parent:=p;
      Entries:=new Dictionary<string, TScopeEntry>;
    end;

    // ---- 이 스코프 안에서만 검색 (기존 fLocals.ContainsKey류와 동일한 의미) ----
    function Has(vn: string): boolean;
    begin
      Result:=Entries.ContainsKey(vn);
    end;

    function HasClrType(vn: string): boolean;
    begin
      Result:=Entries.ContainsKey(vn) and (Entries[vn].ClrType<>nil);
    end;

    // 예전의 별도 fLocalClass/fGlobalClass 딕셔너리는 "클래스 타입 변수만" 담고 있었다
    // (정수/문자열 등 지역변수는 아예 키가 없었음). Has()는 "이 이름이 스코프에 존재하는가"만
    // 보므로 의미가 다르다 — 반드시 ClassName이 실제로 채워졌는지까지 확인해야 한다.
    function HasClassName(vn: string): boolean;
    begin
      Result:=Entries.ContainsKey(vn) and (Entries[vn].ClassName<>'');
    end;

    function GetLoc(vn: string): LocalBuilder;
    begin
      Result:=Entries[vn].Loc;
    end;

    function GetVType(vn: string): TVarType;
    begin
      Result:=Entries[vn].VType;
    end;

    function GetClassName(vn: string): string;
    begin
      Result:=Entries[vn].ClassName;
    end;

    function GetClrType(vn: string): System.Type;
    begin
      Result:=Entries[vn].ClrType;
    end;

    // ---- 선언(등록) ----
    procedure Declare(vn: string; l: LocalBuilder; vt: TVarType);
    begin
      Entries[vn]:=new TScopeEntry(l, vt);
    end;

    procedure SetClassName(vn: string; cn: string);
    begin
      Entries[vn].ClassName:=cn;
    end;

    procedure SetClrType(vn: string; ct: System.Type);
    begin
      Entries[vn].ClrType:=ct;
    end;

    // ---- Parent 체인을 따라 올라가며 검색 (향후 중첩 스코프/람다용) ----
    function TryResolve(vn: string; var outEntry: TScopeEntry): boolean;
    begin
      if Entries.ContainsKey(vn) then
      begin
        outEntry:=Entries[vn];
        Result:=true;
        exit;
      end;
      if Parent<>nil then
      begin
        Result:=Parent.TryResolve(vn, outEntry);
        exit;
      end;
      outEntry:=nil;
      Result:=false;
    end;

    procedure Clear;
    begin
      Entries.Clear;
    end;

    // 스코프 안에서 변수 하나만 제거 (예: try/except의 예외 변수가 블록을 벗어날 때).
    procedure Remove(vn: string);
    begin
      if Entries.ContainsKey(vn) then Entries.Remove(vn);
    end;
  end;

implementation

end.