// ============================================================
// UGreeter.pas — [Stage 75] 로컬 유닛 테스트용 헬퍼 파일.
// Examples\Units\ 폴더에 넣는다.
// 'library'로 선언하면 begin...end 메인 블록 없이 선언부만으로 끝낼 수 있다
// (Main.pas가 병합할 때 entry가 아닌 파일의 IsLibrary/Statements는 버려지므로
//  이 파일 자체의 산출물 종류는 최종 결과에 영향을 주지 않는다 — 그냥 문법상 허용값).
// ============================================================
library UGreeter;

function BuildGreeting(name_: string): string;
begin
  Result := 'Hello, ' + name_ + '!';
end;

end.