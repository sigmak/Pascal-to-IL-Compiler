// ============================================================
// Monomorphize.pas — 제네릭 단형화(單型化) 전담 유닛 (TMonomorphizer)
// AST.pas에만 의존. Parser 직후, CodeGen 이전에 한 번 실행된다.
//
// 설계 원칙: CodeGen은 제네릭을 "모른다". Parser가 소스에서
// TStack<integer> 같은 사용을 만나면 그 자리에서 이미 구체 클래스
// 이름(TStack_integer)으로 바꿔치기해 두고, 필요한 인스턴스화 요청을
// aProg.GenericInstantiations 에 쌓아 둔다. 이 유닛은 그 요청들을 보고
// 제네릭 템플릿(TStack<T>)으로부터 실제 필드/메서드 타입이 채워진
// 구체 TClassDeclNode/TMethodImplNode를 "찍어내"(단형화) aProg에 추가하고,
// CodeGen이 처리할 수 없는 원본 제네릭 템플릿은 목록에서 제거한다.
//
// 메서드 본문(TCompoundStmtNode)은 타입 소거된 채로 만들어져 있으므로
// (필드/변수는 항상 이름으로만 참조됨) 타입 인자에 따라 새로 만들 필요가
// 없다 — 인스턴스화마다 같은 Body 인스턴스를 그대로 재사용한다.
// ============================================================
unit Monomorphize;

interface

uses
  System.Collections.Generic,
  AST;

type
  // [Stage 32] 타입 인자 하나(기본형이거나 클래스/중첩 제네릭 구체 클래스)
  TArgSlot = record
    ArgType: TVarType;
    ArgClassName: string;
  end;

  TMonomorphizer = class
  private
    fProg: TProgramNode;
    fTemplates: Dictionary<string, TClassDeclNode>;       // 템플릿 이름 → 선언
    fTemplateImpls: Dictionary<string, List<TMethodImplNode>>; // 템플릿 이름 → 메서드 구현 목록

    // [Stage 32] 인스턴스화 요청 하나에 대해 "타입 매개변수 이름(T/K/V...) → 실제 타입 인자" 맵을 만든다.
    function BuildSubstMap(inst: TGenericInstantiation; tmpl: TClassDeclNode): Dictionary<string, TArgSlot>;

    // FieldType/ParamTypes[i]/ReturnType이 vtGeneric이면 그 자리에 적힌 타입 매개변수 이름(srcGenericName)을
    // subst에서 찾아 실제 타입 인자로 치환한다.
    procedure ResolveType(subst: Dictionary<string, TArgSlot>;
      srcType: TVarType; srcGenericName: string; srcClassName: string; srcIsExternal: boolean;
      var outType: TVarType; var outClassName: string; var outIsExternal: boolean);

    function BuildConcreteClass(inst: TGenericInstantiation; tmpl: TClassDeclNode): TClassDeclNode;
    procedure BuildConcreteImpls(inst: TGenericInstantiation; subst: Dictionary<string, TArgSlot>);

  public
    constructor Create(aProg: TProgramNode);

    // aProg를 제자리에서 확장·정리한다:
    //   1) 각 GenericInstantiation 요청마다 구체 클래스/메서드구현을 합성해 추가
    //   2) 원본 제네릭 템플릿 선언 및 그 메서드구현을 목록에서 제거
    procedure Run;
  end;

implementation

constructor TMonomorphizer.Create(aProg: TProgramNode);
begin
  fProg:=aProg;
  fTemplates:=new Dictionary<string, TClassDeclNode>;
  fTemplateImpls:=new Dictionary<string, List<TMethodImplNode>>;
end;

function TMonomorphizer.BuildSubstMap(inst: TGenericInstantiation; tmpl: TClassDeclNode): Dictionary<string, TArgSlot>;
var m: Dictionary<string, TArgSlot>; slot: TArgSlot;
begin
  m:=new Dictionary<string, TArgSlot>;
  if tmpl.GenericParamNames.Count<>inst.ArgTypes.Count then
    raise new Exception('단형화 실패: "'+inst.TemplateName+'"의 타입 매개변수 수('
      +tmpl.GenericParamNames.Count.ToString+')와 인스턴스화 인자 수('
      +inst.ArgTypes.Count.ToString+')가 일치하지 않습니다');
  for var i:=0 to tmpl.GenericParamNames.Count-1 do
  begin
    slot.ArgType:=inst.ArgTypes[i];
    slot.ArgClassName:=inst.ArgClassNames[i];
    m[tmpl.GenericParamNames[i]]:=slot;
  end;
  Result:=m;
end;

procedure TMonomorphizer.ResolveType(subst: Dictionary<string, TArgSlot>;
  srcType: TVarType; srcGenericName: string; srcClassName: string; srcIsExternal: boolean;
  var outType: TVarType; var outClassName: string; var outIsExternal: boolean);
begin
  if srcType=vtGeneric then
  begin
    if not subst.ContainsKey(srcGenericName) then
      raise new Exception('단형화 실패: 알 수 없는 타입 매개변수 "'+srcGenericName+'"');
    outType:=subst[srcGenericName].ArgType;
    outClassName:=subst[srcGenericName].ArgClassName;
    outIsExternal:=false; // 현재는 기본형/지역 클래스(중첩 제네릭 포함) 타입 인자만 지원
  end
  else
  begin
    outType:=srcType; outClassName:=srcClassName; outIsExternal:=srcIsExternal;
  end;
end;

function TMonomorphizer.BuildConcreteClass(inst: TGenericInstantiation; tmpl: TClassDeclNode): TClassDeclNode;
var
  cd: TClassDeclNode; ot: TVarType; ocn: string; oext: boolean; subst: Dictionary<string, TArgSlot>;
begin
  subst:=BuildSubstMap(inst, tmpl);

  cd:=new TClassDeclNode(inst.ConcreteName);
  cd.ParentName:=tmpl.ParentName;
  cd.IsExternalParent:=tmpl.IsExternalParent;
  cd.InterfaceName:=tmpl.InterfaceName;
  // 합성된 구체 클래스 자신은 더 이상 제네릭이 아니다.
  cd.IsGeneric:=false;

  foreach var f in tmpl.Fields do
  begin
    // f.FieldType=vtGeneric일 때 f.ClassName에는 [Stage 32] 타입 매개변수 이름(예: 'K')이 들어있다.
    ResolveType(subst, f.FieldType, f.ClassName, f.ClassName, f.IsExternalType, ot, ocn, oext);
    var nf:=new TFieldDeclNode(f.Name, ot);
    nf.ClassName:=ocn; nf.IsExternalType:=oext;
    cd.Fields.Add(nf);
  end;

  foreach var m in tmpl.Methods do
  begin
    ResolveType(subst, m.ReturnType, m.ReturnGenericName, '', false, ot, ocn, oext);
    var nm:=new TMethodSignature(m.Name, m.IsFunction, ot);
    for var i:=0 to m.ParamTypes.Count-1 do
    begin
      var pot: TVarType; var pocn: string; var poext: boolean;
      // m.ParamTypes[i]=vtGeneric일 때 m.ParamClassNames[i]에는 타입 매개변수 이름이 들어있다.
      ResolveType(subst, m.ParamTypes[i], m.ParamClassNames[i], m.ParamClassNames[i], m.ParamIsExternal[i], pot, pocn, poext);
      nm.ParamNames.Add(m.ParamNames[i]);
      nm.ParamTypes.Add(pot);
      nm.ParamClassNames.Add(pocn);
      nm.ParamIsExternal.Add(poext);
    end;
    cd.Methods.Add(nm);
  end;

  Result:=cd;
end;

procedure TMonomorphizer.BuildConcreteImpls(inst: TGenericInstantiation; subst: Dictionary<string, TArgSlot>);
var ot: TVarType; ocn: string; oext: boolean;
begin
  if not fTemplateImpls.ContainsKey(inst.TemplateName) then exit; // 본문 없는 템플릿(비정상)이면 조용히 건너뜀

  foreach var srcImpl in fTemplateImpls[inst.TemplateName] do
  begin
    ResolveType(subst, srcImpl.ReturnType, srcImpl.ReturnGenericName, '', false, ot, ocn, oext);
    var impl:=new TMethodImplNode(inst.ConcreteName, srcImpl.MethodName, srcImpl.IsFunction, ot);
    for var i:=0 to srcImpl.ParamTypes.Count-1 do
    begin
      var pot: TVarType; var pocn: string; var poext: boolean;
      ResolveType(subst, srcImpl.ParamTypes[i], srcImpl.ParamGenericNames[i], '', false, pot, pocn, poext);
      impl.ParamNames.Add(srcImpl.ParamNames[i]);
      impl.ParamTypes.Add(pot);
      impl.ParamGenericNames.Add(''); // 구체화 후에는 더 이상 제네릭이 아님
    end;
    // 본문은 타입 소거되어 있으므로(필드/변수는 이름으로만 참조) 그대로 공유해도 안전하다.
    impl.Body:=srcImpl.Body;
    fProg.MethodImpls.Add(impl);
  end;
end;

procedure TMonomorphizer.Run;
var processed: List<string>; keptClasses: List<TClassDeclNode>; keptImpls: List<TMethodImplNode>;
begin
  // 1) 템플릿 선언과 그 메서드구현들을 이름으로 색인
  foreach var cd in fProg.ClassDecls do
    if cd.IsGeneric then fTemplates[cd.Name]:=cd;

  if fTemplates.Count=0 then exit; // 제네릭을 전혀 쓰지 않는 프로그램이면 손댈 것 없음

  foreach var impl in fProg.MethodImpls do
    if fTemplates.ContainsKey(impl.ClassName) then
    begin
      if not fTemplateImpls.ContainsKey(impl.ClassName) then
        fTemplateImpls[impl.ClassName]:=new List<TMethodImplNode>;
      fTemplateImpls[impl.ClassName].Add(impl);
    end;

  // 2) 요청된 인스턴스화마다 구체 클래스 + 메서드구현을 합성
  processed:=new List<string>;
  foreach var inst in fProg.GenericInstantiations do
  begin
    if not processed.Contains(inst.ConcreteName) then // 중복 요청 방지(이론상 Parser가 이미 걸러줌)
    begin
      processed.Add(inst.ConcreteName);

      if not fTemplates.ContainsKey(inst.TemplateName) then
        raise new Exception('단형화 실패: 알 수 없는 제네릭 클래스 "'+inst.TemplateName+'"');

      var tmpl:=fTemplates[inst.TemplateName];
      fProg.ClassDecls.Add(BuildConcreteClass(inst, tmpl));
      BuildConcreteImpls(inst, BuildSubstMap(inst, tmpl));
    end;
  end;

  // 3) CodeGen이 이해할 수 없는 원본 제네릭 템플릿(및 그 메서드구현)을 제거
  keptClasses:=new List<TClassDeclNode>;
  foreach var cd2 in fProg.ClassDecls do
    if not fTemplates.ContainsKey(cd2.Name) then keptClasses.Add(cd2);
  fProg.ClassDecls:=keptClasses;

  keptImpls:=new List<TMethodImplNode>;
  foreach var impl2 in fProg.MethodImpls do
    if not fTemplates.ContainsKey(impl2.ClassName) then keptImpls.Add(impl2);
  fProg.MethodImpls:=keptImpls;
end;

end.