// ============================================================
// Stage 50 테스트: 타입까지 보는 오버로드 해석
//   System.Text.StringBuilder는 인자 1개짜리 생성자가 여러 개다:
//     StringBuilder(string value)    — 초기 문자열
//     StringBuilder(int capacity)    — 초기 용량
//   기존(인자 개수만 보는) 방식이면 GetConstructors() 열거 순서에 따라
//   둘 중 아무거나 걸릴 수 있어서, 정수를 넘겼는데 문자열 생성자로 잘못
//   들어가는 식의 오류가 날 수 있었다. [Stage 50]에서는 인자의 추정 타입과
//   매개변수 타입을 비교해서 올바른 오버로드를 고른다.
// ============================================================
program Stage50Test;

var
  sb1: System.Text.StringBuilder;
  sb2: System.Text.StringBuilder;

begin
  sb1 := new System.Text.StringBuilder('Hello');  // [Stage 50] string 생성자로 정확히 선택돼야 함
  sb1.Append(' World');
  Writeln(sb1.ToString());   // Hello World

  sb2 := new System.Text.StringBuilder(64);       // [Stage 50] int(용량) 생성자로 정확히 선택돼야 함
  Writeln(sb2.Capacity >= 64);   // True (용량 생성자가 아니라 문자열 생성자로 잘못 걸렸다면
                                 // Capacity가 64와 무관한 작은 값이 되거나 애초에 예외가 났을 것)
  Writeln(sb2.Length);       // 0 (내용 없이 용량만 잡은 상태이므로)
end.