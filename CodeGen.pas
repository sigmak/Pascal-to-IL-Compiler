// ============================================================
// CodeGen.pas — 목적코드(IL) 생성 (TCodeGenerator)
// AST.pas(노드 타입)에 의존, System.Reflection.Emit으로 실제 IL 방출.
// 새 기능(클래스, 예외, 제네릭 등)의 "실행 가능한 구현체"가 여기 모임.
// 지금 프로젝트에서 가장 자주 바뀌는 파일 = 현재의 실질적 병목 지점.
// ============================================================
// ============================================================
// [분할 안내] 이 파일은 9000줄이 넘던 CodeGen.pas를 딱 3개 조각(CodeGen_Part1~3.pas)
// 으로 나눈 뒤 {$include}로 다시 이어붙이는 "쉘" 파일입니다. TCodeGenerator는 여전히
// 하나의 클래스이고(partial class 미지원), {$include}는 Main.pas가 이미 지원하는
// 전처리 기능을 그대로 씁니다 — 컴파일 시점엔 예전과 완전히 동일한 하나의 텍스트로
// 합쳐집니다. 컴파일 결과(IL)는 분할 전과 100% 동일합니다.
//
//   CodeGen_Part1_TypeInfer.pas - 필드 + 스코프/타입 조회 helper + InferType
//   CodeGen_Part2_Emit.pas      - EmitExpr / EmitStatement (IL 방출 핵심)
//   CodeGen_Part3_Build.pas     - 타입해석/리플렉션 + 클래스·빌드 + 공개 API
//
// 4개 파일(이 쉘 + 3조각)을 반드시 같은 폴더에 함께 두세요.
// ============================================================
unit CodeGen;

interface

uses
  System.Text,
  System.Collections.Generic,
  System.Reflection,
  System.Reflection.Emit,
  System.Globalization,
  AST,
  Scope,
  Symbols;

type
  // [Stage 99 버그 수정] TypeBuilderInstantiation(예: List<TToken>처럼, 원소 타입이 아직
  // CreateType되지 않은 로컬 클래스인 BCL 제네릭 컬렉션)의 프로퍼티(Count, Item 등)에
  // 접근하려면 .NET Reflection.Emit의 공식 우회법 — 열린 제네릭 정의(List<>)에서 멤버를
  // 찾고 TypeBuilder.GetMethod로 그 접근자(get_.../set_...)만 닫힌 버전에 바인딩 — 이
  // 필요하다(SafeGetMethods/SafeGetConstructor(s)가 이미 메서드/생성자에 이 방식을 쓰고
  // 있음, 아래 참고). 다만 PropertyInfo 자체는 공개 API로 직접 만들 수 없는 추상 클래스라,
  // 바인딩된 get/set MethodInfo만 감싸는 최소 래퍼가 필요하다. CodeGen.pas 안에서 실제로
  // 쓰이는 멤버는 PropertyType/GetGetMethod/GetSetMethod/Name/DeclaringType 뿐이고,
  // GetValue/SetValue(런타임 호출)나 커스텀 특성 조회는 IL 방출 중에는 쓰이지 않으므로
  // 지원하지 않는다(호출 시 예외).
  TBoundGenericPropertyInfo = class(PropertyInfo)
  private
    fName: string;
    fDeclType, fPropType: System.Type;
    fGetter, fSetter: MethodInfo;
    fIndexParams: array of ParameterInfo;
    fAttrs: PropertyAttributes;
    function GetCanRead0: boolean;
    begin Result := fGetter <> nil; end;
    function GetCanWrite0: boolean;
    begin Result := fSetter <> nil; end;
  public
    // [Stage 126 수정] 예전에는 이 생성자와 별도로 propName을 직접 받는 오버로드가
    // 하나 더 있었다(둘 다 인자 4개). 그런데 이 자기호스팅 컴파일러의 생성자 빌드 로직이
    // "인자 개수가 같은 두 개의 Create 오버로드"를 구분하지 못해 하나는 IL 본문 없이
    // 남겨져 CreateType 시 "'.ctor' 메서드에 메서드 본문이 없습니다" 오류가 났다(실제
    // 자기컴파일 사례). 오버로드를 아예 없애고 인자 5개짜리 단일 생성자로 통합한다 —
    // openProp이 있으면(제네릭 로컬 클래스 경로) 거기서 Name/Attributes를 가져오고,
    // 없으면(nil, 순수 로컬 클래스 경로) propName/기본 Attributes를 쓴다.
    constructor Create(openProp: PropertyInfo; propName: string; declType: System.Type; getter, setter: MethodInfo);
    begin
      // [버그 수정] PropertyInfo의 무인자 생성자는 protected라 자동 체이닝이 안 됨 — 명시 호출 필요.
      // [추가 수정] 괄호 없는 "inherited Create;" 형태를 BuildConstructorBody의 hasExplicitInherited
      // 감지 로직이 놓치는 문제가 재현되어(자기컴파일 실제 사례), 괄호를 붙인 형태로 바꿔 우회한다.
      inherited Create();
      if openProp <> nil then
      begin
        fName := openProp.Name;
        fAttrs := openProp.Attributes;
      end
      else
      begin
        fName := propName;
        fAttrs := PropertyAttributes.None;
      end;
      fDeclType := declType;
      fGetter := getter;
      fSetter := setter;
      if getter <> nil then
      begin
        fPropType := getter.ReturnType;
        fIndexParams := getter.GetParameters;
      end
      else if setter <> nil then
      begin
        var sp99 := setter.GetParameters;
        if sp99.Length > 0 then fPropType := sp99[sp99.Length - 1].ParameterType
        else fPropType := typeof(System.Object);
        var res99 := new List<ParameterInfo>;
        for var ip99 := 0 to sp99.Length - 2 do res99.Add(sp99[ip99]);
        fIndexParams := res99.ToArray;
      end
      else
      begin
        fPropType := typeof(System.Object);
        fIndexParams := new ParameterInfo[0];
      end;
    end;

    property Name: string read fName; override;
    property DeclaringType: System.Type read fDeclType; override;
    property ReflectedType: System.Type read fDeclType; override;
    property PropertyType: System.Type read fPropType; override;
    property Attributes: PropertyAttributes read fAttrs; override;
    property CanRead: boolean read GetCanRead0; override;
    property CanWrite: boolean read GetCanWrite0; override;

    function GetAccessors(nonPublic: boolean): array of MethodInfo; override;
    begin
      var lst99 := new List<MethodInfo>;
      if fGetter <> nil then lst99.Add(fGetter);
      if fSetter <> nil then lst99.Add(fSetter);
      Result := lst99.ToArray;
    end;

    function GetGetMethod(nonPublic: boolean): MethodInfo; override;
    begin Result := fGetter; end;

    function GetSetMethod(nonPublic: boolean): MethodInfo; override;
    begin Result := fSetter; end;

    function GetIndexParameters: array of ParameterInfo; override;
    begin Result := fIndexParams; end;

    // [버그 수정] PropertyInfo에서 실제로 추상인 오버로드는 이 5개짜리(BindingFlags/Binder/
    // CultureInfo까지 받는) 버전이다 — 2/3개짜리 GetValue(obj,index)/SetValue(obj,value,index)는
    // 이 버전을 호출하는 비추상 편의 메서드일 뿐이라, 그것만 override해서는 추상 멤버가
    // 여전히 남아 "추상 클래스는 인스턴스화할 수 없습니다" 오류가 난다.
    function GetValue(obj: System.Object; invokeAttr: BindingFlags; binder: Binder;
      index: array of System.Object; culture: CultureInfo): System.Object; override;
    begin
      raise new System.NotSupportedException('TBoundGenericPropertyInfo.GetValue는 지원되지 않습니다 (코드생성 전용 래퍼입니다).');
    end;

    procedure SetValue(obj: System.Object; value: System.Object; invokeAttr: BindingFlags; binder: Binder;
      index: array of System.Object; culture: CultureInfo); override;
    begin
      raise new System.NotSupportedException('TBoundGenericPropertyInfo.SetValue는 지원되지 않습니다 (코드생성 전용 래퍼입니다).');
    end;

    function GetCustomAttributes(inherit: boolean): array of System.Object; override;
    begin Result := new System.Object[0]; end;

    function GetCustomAttributes(attributeType: System.Type; inherit: boolean): array of System.Object; override;
    begin Result := new System.Object[0]; end;

    function IsDefined(attributeType: System.Type; inherit: boolean): boolean; override;
    begin Result := false; end;
  end;

  TCodeGenerator = class
  private

    {$include CodeGen_Part1_TypeInfer.pas}

    {$include CodeGen_Part2_Emit.pas}

    {$include CodeGen_Part3_Build.pas}

  end;

implementation

end.