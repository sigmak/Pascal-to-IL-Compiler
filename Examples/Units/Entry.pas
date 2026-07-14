// [Stage 55 데모] 실제 unit interface/implementation 문법은 아직 Parser가 지원하지 않으므로,
// 이 파일은 어디까지나 Main.pas의 "파일탐색 + 의존성 정렬" 로직만 검증하기 위한 더미다.
// (Entry -> MathUtils -> StringUtils, Entry -> StringUtils 의존관계)
program Entry;

uses
  System.IO,
  MathUtils,
  StringUtils;

begin
  Writeln('Entry');
end.