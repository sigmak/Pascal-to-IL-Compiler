// ============================================================
// Test_stage85.pas — [Stage 85] 프로퍼티의 read/write 접근자가 필드가 아니라
// 메서드를 가리키는 경우를 지원한다.
//   예: property Enabled: boolean read FEnabled write SetEnabled;
//
// 이 패턴은 실제 레포의 uFileMonitoring.pas (FileChangeWatcher 클래스)에
// 그대로 등장한다. 그리고 uFSWatcherService.pas는 그 프로퍼티를 self가 아닌
// 지역 변수(qualifier)를 통해 대입한다:
//   fcw.Enabled := false;   // fcw: FileChangeWatcher (지역 변수)
//
// 이 "obj.Prop := val" 경로는 CodeGen.pas의 EmitPropertyOrFieldSet을 타는데,
// 거기서 targetType(FileChangeWatcher)이 아직 CreateType되지 않은 로컬
// TypeBuilder라 GetProperty가 NotSupportedException을 던지는 알려진 취약점이
// 있었다 (Stage 78에서 EmitQualifierChainLoad/InferQualifierChainType 두 곳은
// 이미 고쳤지만 대입 경로는 그대로 남아 있었음). 읽기 경로(obj.Prop 읽기)도
// 마찬가지로 프로퍼티 getter가 필드가 아니라 메서드일 수 있다는 점은
// 반영되어 있지 않았다.
//
// Stage 85에서 고친 것:
//   1) 프로퍼티 get/set 메서드 방출을 클래스의 일반 메서드 시그니처 정의 "이후"로
//      옮겨서, write 접근자가 메서드 이름을 가리켜도 그 MethodBuilder를 찾을 수
//      있게 함.
//   2) EmitPropertyOrFieldSet / EmitQualifierChainLoad / InferQualifierChainType
//      세 곳 모두에 fTypeBuilders 역방향 조회 가드를 추가 — "obj.Prop"이 로컬
//      클래스의 프로퍼티(get_Prop/set_Prop)를 가리키면 그 메서드를 직접
//      Callvirt하고, 아니면 기존처럼 필드로, 그것도 아니면 기존 외부 타입
//      GetProperty/GetField 경로로 폴백한다.
//
// 이 테스트는 Counter.Value 프로퍼티를 통해 두 경로를 모두 검증한다:
//   - c.Value := 42;   → 쓰기: SetValue(42) 메서드가 실제로 호출되는지
//   - c.Value          → 읽기: get_Value가 FValue 필드를 실제로 반환하는지
//   - c.Calls          → 읽기: SetValue가 정확히 한 번 호출됐는지 (부수효과로 확인)
// (c는 self가 아닌 지역 변수이므로, self.Prop 경로가 아니라 문제였던
//  "지역 변수 qualifier를 통한 프로퍼티 접근" 경로를 그대로 재현한다.)
//
// 성공 기준: 콘솔에 "Stage85 성공: Value=42, Calls=1"이 출력되어야 한다.
// ============================================================
program Test_stage85;

type
  Counter = class
  private
    FValue: integer;
    FSetCalls: integer;
    procedure SetValue(v: integer);
  public
    property Value: integer read FValue write SetValue;
    property Calls: integer read FSetCalls;
  end;

procedure Counter.SetValue(v: integer);
begin
  FSetCalls := FSetCalls + 1;
  FValue := v;
end;

var
  c: Counter;

begin
  c := Counter.Create;
  c.Value := 42;  // <- 핵심 검증 지점: 지역 변수를 통한 프로퍼티 대입 (write → 메서드 호출)
  Writeln('Stage85 성공: Value=' + c.Value.ToString + ', Calls=' + c.Calls.ToString);
end.