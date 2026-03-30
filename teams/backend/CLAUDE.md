# Backend 팀

## 필수 규칙
- SQL 파라미터 바인딩 필수 (문자열 연결 금지)
- SELECT * 금지
- DDL 변경은 마이그레이션 스크립트 필수
- System.out 금지 (@Slf4j 사용)
- API 버저닝 필수 (/api/v1/...)

## 테스트 규칙
- 커버리지 기준: 단위 80%, 통합 60%
- Given-When-Then 패턴, @DisplayName 한글 설명
- 테스트 데이터는 팩토리 패턴으로 생성, 테스트 간 격리 필수
- 버그 수정 시 failing 테스트 먼저 작성 → 코드 수정 → 회귀 테스트 보존
- /test-scenario, /regression, /smoke-test 글로벌 스킬 활용 가능

## 코드 작성 시
- 코드 컨벤션 상세는 /convention-backend 스킬을 참고하라
- 프로젝트 도메인 정보는 .ai-harness/config.yaml의 project 섹션을 참고하라

## 팀 스킬
- /agent-map : AI 에이전트 아키텍처 문서 자동 생성
- /api-design : API 설명 → RESTful 설계 + Spring Boot Controller 코드 생성
- /convention-backend : 백엔드 코드 컨벤션 가이드
- /entity : JPA 엔티티 설계 및 생성
- /migration : DB 마이그레이션 스크립트 생성
