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
    // [Stage 36] 최상위 제네릭 함수/프로시저 템플릿 (클래스와 동일한 패턴)
    fFuncTemplates: Dictionary<string, TFuncDeclNode>;
    fProcTemplates: Dictionary<string, TProcDeclNode>;

    // [Stage 32] 인스턴스화 요청 하나에 대해 "타입 매개변수 이름(T/K/V...) → 실제 타입 인자" 맵을 만든다.
    function BuildSubstMap(inst: TGenericInstantiation; tmpl: TClassDeclNode): Dictionary<string, TArgSlot>;
    // [Stage 36] 함수/프로시저용 버전. 클래스처럼 tmpl 노드 전체가 아니라 GenericParamNames만 필요하다.
    function BuildFuncSubstMap(paramNames: List<string>; argTypes: List<TVarType>; argClassNames: List<string>): Dictionary<string, TArgSlot>;

    // FieldType/ParamTypes[i]/ReturnType이 vtGeneric이면 그 자리에 적힌 타입 매개변수 이름(srcGenericName)을
    // subst에서 찾아 실제 타입 인자로 치환한다.
    procedure ResolveType(subst: Dictionary<string, TArgSlot>;
      srcType: TVarType; srcGenericName: string; srcClassName: string; srcIsExternal: boolean;
      var outType: TVarType; var outClassName: string; var outIsExternal: boolean);

    function BuildConcreteClass(inst: TGenericInstantiation; tmpl: TClassDeclNode): TClassDeclNode;
    procedure BuildConcreteImpls(inst: TGenericInstantiation; subst: Dictionary<string, TArgSlot>);

    // [Stage 36] 최상위 제네릭 함수/프로시저를 구체화한다. 본문은 클래스 메서드와 마찬가지로
    // 타입 소거되어 있으므로(매개변수/지역변수는 이름으로만 참조) 그대로 공유해도 안전하다.
    function BuildConcreteFunc(inst: TGenericFuncInstantiation; tmpl: TFuncDeclNode): TFuncDeclNode;
    function BuildConcreteProc(inst: TGenericFuncInstantiation; tmpl: TProcDeclNode): TProcDeclNode;

  public
    constructor Create(aProg: TProgramNode);

    // aProg를 제자리에서 확장·정리한다:
    //   1) 각 GenericInstantiation/[Stage 36]GenericFuncInstantiation 요청마다 구체 선언을 합성해 추가
    //   2) 원본 제네릭 템플릿 선언(클래스/메서드구현/함수/프로시저)을 목록에서 제거
    procedure Run;
  end;

implementation

constructor TMonomorphizer.Create(aProg: TProgramNode);
begin
  fProg:=aProg;
  fTemplates:=new Dictionary<string, TClassDeclNode>;
  fTemplateImpls:=new Dictionary<string, List<TMethodImplNode>>;
  fFuncTemplates:=new Dictionary<string, TFuncDeclNode>; // [Stage 36]
  fProcTemplates:=new Dictionary<string, TProcDeclNode>; // [Stage 36]
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

// [Stage 36] 함수/프로시저용 BuildSubstMap. 클래스 쪽과 로직은 동일하지만 tmpl 노드 대신
// GenericParamNames 목록을 직접 받는다(TFuncDeclNode/TProcDeclNode를 공통 타입으로 묶지 않았기 때문).
function TMonomorphizer.BuildFuncSubstMap(paramNames: List<string>; argTypes: List<TVarType>; argClassNames: List<string>): Dictionary<string, TArgSlot>;
var m: Dictionary<string, TArgSlot>; slot: TArgSlot;
begin
  m:=new Dictionary<string, TArgSlot>;
  if paramNames.Count<>argTypes.Count then
    raise new Exception('단형화 실패: 제네릭 함수/프로시저의 타입 매개변수 수('
      +paramNames.Count.ToString+')와 인스턴스화 인자 수('+argTypes.Count.ToString+')가 일치하지 않습니다');
  for var i:=0 to paramNames.Count-1 do
  begin
    slot.ArgType:=argTypes[i];
    slot.ArgClassName:=argClassNames[i];
    m[paramNames[i]]:=slot;
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
  // [Stage 37] "array of T" — 실제 타입 인자가 정수/문자열이면 그에 맞는 배열 타입으로 치환한다.
  // 클래스 타입 인자로 인스턴스화하면 여기서 명확한 에러로 실패한다("배열 원소가 임의의 클래스"
  // 기능은 제네릭과 무관하게 이 컴파일러가 아직 갖고 있지 않은 별개의 기능이기 때문).
  else if srcType=vtGenericArray then
  begin
    if not subst.ContainsKey(srcGenericName) then
      raise new Exception('단형화 실패: 알 수 없는 타입 매개변수 "'+srcGenericName+'"');
    if subst[srcGenericName].ArgType=vtInteger then outType:=vtIntArray
    else if subst[srcGenericName].ArgType=vtString then outType:=vtStrArray
    // [Phase 1] real/char/int64 갰열 타입은 현재 지원하지 않는다 (의미있는 오류로 안내)
    else if subst[srcGenericName].ArgType=vtReal then
      raise new Exception('Phase 1: array of T 자리에 real 타입 인자 불ꬬ 비지원')
    else if subst[srcGenericName].ArgType=vtChar then
      raise new Exception('Phase 1: array of T 자리에 char 타입 인자 불ꬾ 비지원')
    else if subst[srcGenericName].ArgType=vtInt64 then
      raise new Exception('Phase 1: array of T 자리에 int64 타입 인자 비지원')
    else raise new Exception('단형화 실패: "array of '+srcGenericName+'" 자리에 정수/문자열이 아닌 타입 인자가 주어졌습니다 '
      +'— 이 컴파일러는 아직 정수/문자열 배열만 지원하며, 클래스 원소 배열은 지원하지 않습니다');
    outClassName:='';
    outIsExternal:=false;
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
    // [Stage 37 버그 수정] 본문(Body)은 타입 소거되어 있어 그대로 공유해도 안전하지만,
    // LocalVars(예: var i: integer; 같은 지역변수 선언 목록)는 별도 리스트라서 지금까지
    // 전혀 복사되지 않고 있었다 — 그 결과 제네릭 클래스 메서드 안에 지역변수가 하나라도
    // 있으면(for 루프 변수 등) CodeGen이 "선언 안 됨" 오류로 실패했다. 여기서 함께 고친다.
    foreach var lv in srcImpl.LocalVars do
    begin
      var lot: TVarType; var locn: string; var loext: boolean;
      // [Stage 41] lv.IsExternal(외부 .NET 타입 여부)을 입력으로 넘기고, 소거 결과 loext를 그대로 보존한다.
      ResolveType(subst, lv.VarType, lv.ClassName, lv.ClassName, lv.IsExternal, lot, locn, loext);
      impl.LocalVars.Add(new TVarDecl(lv.Name, lot, locn, loext));
    end;
    impl.Body:=srcImpl.Body;
    fProg.MethodImpls.Add(impl);
  end;
end;

// [Stage 36] 최상위 제네릭 함수 하나를 구체화한다 (예: Identity<T> + integer → Identity_integer).
function TMonomorphizer.BuildConcreteFunc(inst: TGenericFuncInstantiation; tmpl: TFuncDeclNode): TFuncDeclNode;
var fn: TFuncDeclNode; subst: Dictionary<string, TArgSlot>; ot: TVarType; ocn: string; oext: boolean;
begin
  subst:=BuildFuncSubstMap(tmpl.GenericParamNames, inst.ArgTypes, inst.ArgClassNames);

  fn:=new TFuncDeclNode(inst.ConcreteName);
  // 합성된 구체 함수 자신은 더 이상 제네릭이 아니다 (IsGeneric 기본값 false 그대로 둠).
  ResolveType(subst, tmpl.ReturnType, tmpl.ReturnGenericName, '', false, ot, ocn, oext);
  fn.ReturnType:=ot;

  foreach var p in tmpl.Parameters do
  begin
    var pot: TVarType; var pocn: string; var poext: boolean;
    // p.ParamType=vtGeneric일 때 p.ClassName에는 [Stage 36] 타입 매개변수 이름(예: 'T')이 들어있다.
    ResolveType(subst, p.ParamType, p.ClassName, p.ClassName, p.IsExternal, pot, pocn, poext);
    fn.Parameters.Add(new TParamDef(p.Name, pot, pocn, poext));
  end;

  foreach var lv in tmpl.LocalVars do
  begin
    var lot: TVarType; var locn: string; var loext: boolean;
    // [Stage 41] lv.IsExternal을 입력으로 넘기고, 소거 결과 loext를 그대로 보존한다.
    ResolveType(subst, lv.VarType, lv.ClassName, lv.ClassName, lv.IsExternal, lot, locn, loext);
    fn.LocalVars.Add(new TVarDecl(lv.Name, lot, locn, loext));
  end;

  // 본문은 타입 소거되어 있으므로(매개변수/지역변수는 이름으로만 참조) 그대로 공유해도 안전하다.
  fn.Body:=tmpl.Body;
  Result:=fn;
end;

// [Stage 36] 최상위 제네릭 프로시저 하나를 구체화한다. BuildConcreteFunc와 동일하나 반환값이 없다.
function TMonomorphizer.BuildConcreteProc(inst: TGenericFuncInstantiation; tmpl: TProcDeclNode): TProcDeclNode;
var pr: TProcDeclNode; subst: Dictionary<string, TArgSlot>;
begin
  subst:=BuildFuncSubstMap(tmpl.GenericParamNames, inst.ArgTypes, inst.ArgClassNames);

  pr:=new TProcDeclNode(inst.ConcreteName);

  foreach var p in tmpl.Parameters do
  begin
    var pot: TVarType; var pocn: string; var poext: boolean;
    ResolveType(subst, p.ParamType, p.ClassName, p.ClassName, p.IsExternal, pot, pocn, poext);
    pr.Parameters.Add(new TParamDef(p.Name, pot, pocn, poext));
  end;

  foreach var lv in tmpl.LocalVars do
  begin
    var lot: TVarType; var locn: string; var loext: boolean;
    // [Stage 41] lv.IsExternal을 입력으로 넘기고, 소거 결과 loext를 그대로 보존한다.
    ResolveType(subst, lv.VarType, lv.ClassName, lv.ClassName, lv.IsExternal, lot, locn, loext);
    pr.LocalVars.Add(new TVarDecl(lv.Name, lot, locn, loext));
  end;

  pr.Body:=tmpl.Body;
  Result:=pr;
end;

procedure TMonomorphizer.Run;
var processed: List<string>; keptClasses: List<TClassDeclNode>; keptImpls: List<TMethodImplNode>;
    processedFuncs: List<string>; keptFuncs: List<TFuncDeclNode>; keptProcs: List<TProcDeclNode>;
begin
  // ---- 1) 클래스 제네릭 처리 ----
  // 1-1) 템플릿 선언과 그 메서드구현들을 이름으로 색인
  foreach var cd in fProg.ClassDecls do
    if cd.IsGeneric then fTemplates[cd.Name]:=cd;

  // 주의: 예전에는 여기서 "제네릭 클래스가 하나도 없으면 Run 전체를 종료"했는데, 그러면
  // [Stage 36] 클래스 제네릭 없이 최상위 제네릭 함수/프로시저만 쓰는 프로그램에서 아래 2)단계가
  // 통째로 건너뛰어지는 버그가 생긴다. 그래서 1)과 2)를 각각 독립적으로 감싼다.
  if fTemplates.Count>0 then
  begin
    foreach var impl in fProg.MethodImpls do
      if fTemplates.ContainsKey(impl.ClassName) then
      begin
        if not fTemplateImpls.ContainsKey(impl.ClassName) then
          fTemplateImpls[impl.ClassName]:=new List<TMethodImplNode>;
        fTemplateImpls[impl.ClassName].Add(impl);
      end;

    // 1-2) 요청된 인스턴스화마다 구체 클래스 + 메서드구현을 합성
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

    // 1-3) CodeGen이 이해할 수 없는 원본 제네릭 템플릿(및 그 메서드구현)을 제거
    keptClasses:=new List<TClassDeclNode>;
    foreach var cd2 in fProg.ClassDecls do
      if not fTemplates.ContainsKey(cd2.Name) then keptClasses.Add(cd2);
    fProg.ClassDecls:=keptClasses;

    keptImpls:=new List<TMethodImplNode>;
    foreach var impl2 in fProg.MethodImpls do
      if not fTemplates.ContainsKey(impl2.ClassName) then keptImpls.Add(impl2);
    fProg.MethodImpls:=keptImpls;
  end;

  // ---- 2) [Stage 36] 최상위 제네릭 함수/프로시저 처리 (클래스와 완전히 독립적으로 동작) ----
  foreach var fd in fProg.FuncDecls do
    if fd.IsGeneric then fFuncTemplates[fd.Name]:=fd;
  foreach var pd in fProg.ProcDecls do
    if pd.IsGeneric then fProcTemplates[pd.Name]:=pd;

  if (fFuncTemplates.Count>0) or (fProcTemplates.Count>0) then
  begin
    processedFuncs:=new List<string>;
    foreach var finst in fProg.GenericFuncInstantiations do
    begin
      if not processedFuncs.Contains(finst.ConcreteName) then // 중복 요청 방지(이론상 Parser가 이미 걸러줌)
      begin
        processedFuncs.Add(finst.ConcreteName);

        if finst.IsProc then
        begin
          if not fProcTemplates.ContainsKey(finst.TemplateName) then
            raise new Exception('단형화 실패: 알 수 없는 제네릭 프로시저 "'+finst.TemplateName+'"');
          fProg.ProcDecls.Add(BuildConcreteProc(finst, fProcTemplates[finst.TemplateName]));
        end
        else
        begin
          if not fFuncTemplates.ContainsKey(finst.TemplateName) then
            raise new Exception('단형화 실패: 알 수 없는 제네릭 함수 "'+finst.TemplateName+'"');
          fProg.FuncDecls.Add(BuildConcreteFunc(finst, fFuncTemplates[finst.TemplateName]));
        end;
      end;
    end;

    // CodeGen이 이해할 수 없는 원본 제네릭 함수/프로시저 템플릿을 제거
    keptFuncs:=new List<TFuncDeclNode>;
    foreach var fd2 in fProg.FuncDecls do
      if not fFuncTemplates.ContainsKey(fd2.Name) then keptFuncs.Add(fd2);
    fProg.FuncDecls:=keptFuncs;

    keptProcs:=new List<TProcDeclNode>;
    foreach var pd2 in fProg.ProcDecls do
      if not fProcTemplates.ContainsKey(pd2.Name) then keptProcs.Add(pd2);
    fProg.ProcDecls:=keptProcs;
  end;
end;

end.