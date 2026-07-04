# Pascal-to-IL-Compiler
PascalABC.net 개발툴을 활용한 pascal 컴파일러 개발

사용된 개발툴 : PascalABC.net  https://pascalabc.net/en/

컴파일러 이론 단계에 맞춰 4개 unit + 진입점으로 분리

-----------------------------------------------------------
AST.pas      노드 타입 정의 (TVarType, TExprNode/TStmtNode 계열). 다른 unit에 의존 안 함.

Lexer.pas    어휘 분석 (TTokenKind, TToken, TLexer). AST에도 의존 안 함.

Parser.pas   구문 분석 (TParser). AST + Lexer에 의존.

CodeGen.pas  IL 코드 생성 (TCodeGenerator). AST + Reflection.Emit에 의존.

Main.pas     진입점. TestSource 문자열 + 실행 로직만 남김.

-----------------------------------------------------------

의존 관계 (화살표 = uses):

<img src='https://github.com/sigmak/Pascal-to-IL-Compiler/blob/main/images/Ver-0-13.png' />


앞으로의 작업 원칙

파일명은 절대 바꾸지 않는다. Stage14, 15... 진행해도 항상 이 5개 파일 안에서만 수정.

기능 하나 = 관련 unit 하나만 수정. 예: 새 연산자 추가 → Lexer.pas + Parser.pas만.

제네릭 진짜 구현(DefineGenericParameters) → CodeGen.pas만.

Stage 완료 시점마다 커밋 + 태그.

