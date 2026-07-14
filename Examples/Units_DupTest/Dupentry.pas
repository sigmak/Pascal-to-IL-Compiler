// 이 예제는 "실패해야 정상"인 테스트다.
// DupA.pas와 DupB.pas가 둘 다 "Helper"라는 이름의 함수를 선언하고 있으므로,
// [Stage 56] MergeProgramInto가 병합 도중 RegisterDeclName에서 중복을 감지하고
// "중복 선언: 함수 "Helper" — "DupA.pas" 파일과 "DupB.pas" 파일에 모두 선언되어
// 있습니다." 같은 메시지로 즉시 실패해야 한다(=CodeGen까지 안 가고 여기서 걸러짐).
program DupEntry;

uses DupA, DupB;

var r: integer;

begin
  r := Helper(10);
  Writeln('r = ' + r);
end.