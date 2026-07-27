// ============================================================
// Test_stage86.pas — [Stage 86] uFileMonitoring.pas(uFSWatcherService.pas가
// 실제로 의존하는 파일)를 컴파일하는 데 필요했던 두 가지 새 기능을 검증한다.
//
// 실제 레포의 FileChangeWatcher 클래스는 이렇게 시작한다:
//   FileChangeWatcher = class(IDisposable)
//   private
//     activeWatchers: Dictionary<FileChangeWatcher, FileChangeWatcher>;
//   ...
//
// 1) class(IDisposable) — 외부(.NET) "인터페이스"를 괄호 안에 쓴 경우.
//    기존 코드는 괄호 안 이름이 로컬 클래스/인터페이스가 아니면 무조건 "외부
//    부모 클래스"로 취급해 TypeBuilder.DefineType의 parent 자리에 그대로
//    넣었다 — IDisposable은 인터페이스라 이러면 TypeBuilder가 예외를 던진다.
//    Stage 86에서: 리플렉션으로 실제 인터페이스인지 확인해 AddInterfaceImplementation
//    경로로 분리했고, "IDisposable" 같은 짧은 이름을 "System.IDisposable"로
//    바꿔주는 화이트리스트도 추가했다.
//
// 2) Dictionary<K,V> 같은 외부 제네릭 컬렉션을 필드 타입/new 생성자에 쓰는 것.
//    기존 코드는 필드 타입 파싱에서 "로컬 클래스도, 현재 제네릭 클래스의 타입
//    매개변수도 아닌 이름 뒤에 '<'가 오는 경우"를 처리하지 못해 파싱 자체가
//    실패했다. Stage 86에서 CodeGen.ResolveExternalType을 확장해
//    "Dictionary<string,Box>" 같은 표기를 재귀적으로 분해 → 각 타입 인자를
//    CLR 타입으로 해석 → MakeGenericType으로 조립하도록 했다. 이때 타입 인자로
//    "자기 자신"(아직 CreateType되지 않은 TypeBuilder)이 와도 되는지까지
//    검증한다 — 실제 레포 코드가 정확히 이 패턴(Dictionary<FileChangeWatcher,
//    FileChangeWatcher>, 자기 자신을 키/값으로 씀)이기 때문이다.
//
// 성공 기준: 콘솔에 다음 세 줄이 출력되어야 한다.
//   "Stage86 성공: Dictionary 필드 new/Add/ContainsKey 동작 확인"
//   "Stage86 성공: IDisposable 구현 확인 (Dispose 호출 → Remove까지 정상 동작)"
//   "Stage86 성공: 끝"
// ============================================================
program Test_stage86;

type
  // 실제 uFileMonitoring.pas의 FileChangeWatcher와 같은 모양:
  // (1) 외부 인터페이스(IDisposable) 구현 + (2) 자기 자신을 타입 인자로 쓰는
  // Dictionary<Box,Box> 필드 를 동시에 검증한다.
  Box = class(IDisposable)
  private
    activeBoxes: Dictionary<Box, Box>;
    disposed: boolean;
  public
    constructor Create;
    procedure Dispose;
    function IsDisposed: boolean;
    function HasSelf: boolean;
  end;

constructor Box.Create;
begin
  activeBoxes := new Dictionary<Box, Box>;
  activeBoxes.Add(self, self);
  disposed := false;
end;

procedure Box.Dispose;
begin
  activeBoxes.Remove(self);
  disposed := true;
end;

function Box.IsDisposed: boolean;
begin
  Result := disposed;
end;

function Box.HasSelf: boolean;
begin
  Result := activeBoxes.ContainsKey(self);
end;

var
  b: Box;

begin
  b := Box.Create;

  // (2) Dictionary<Box,Box> 필드: new/Add/ContainsKey가 실제로 동작하는지
  // (Add(self, self) 뒤 ContainsKey(self)가 true여야 함 — self를 키/값 양쪽에 넣는
  // 자기참조 제네릭 인스턴스화가 실제로 성립했는지까지 함께 검증)
  if b.HasSelf then
    Writeln('Stage86 성공: Dictionary 필드 new/Add/ContainsKey 동작 확인')
  else
    Writeln('실패: Dictionary 필드에 Add한 self를 ContainsKey로 찾지 못함');

  // (1) class(IDisposable): Box.Create가 이미 tb.AddInterfaceImplementation(IDisposable) +
  // tb.CreateType()을 거쳤다 — CLR은 인터페이스가 요구하는 Dispose()를 실제로 못 찾으면
  // CreateType 시점에 TypeLoadException을 던지므로, 여기까지 실행이 온 것 자체가 인터페이스
  // 구현이 성립했다는 뜻이다. 그 위에서 Dispose 호출이 실제 로직(activeBoxes.Remove)으로
  // 이어지는지까지 확인한다.
  b.Dispose;

  if b.IsDisposed and (not b.HasSelf) then
    Writeln('Stage86 성공: IDisposable 구현 확인 (Dispose 호출 → Remove까지 정상 동작)')
  else
    Writeln('실패: Dispose 호출이 실제 메서드로 이어지지 않음');

  Writeln('Stage86 성공: 끝');
end.