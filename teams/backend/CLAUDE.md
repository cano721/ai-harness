# Backend 팀

## 필수 규칙
- SQL 파라미터 바인딩 필수 (문자열 연결 금지)
- SELECT * 금지
- DDL 변경은 마이그레이션 스크립트 필수
- System.out 금지 (@Slf4j 사용)
- API 버저닝 필수 (/api/v1/...)

## 코드 작성 시
- 코드 컨벤션 상세는 /convention-backend 스킬을 참고하라
- 프로젝트 도메인 정보는 .ai-harness/config.yaml의 project 섹션을 참고하라

## 팀 스킬
- /agent-map : AI 에이전트 아키텍처 문서 자동 생성
- /api-design : API 설명 → RESTful 설계 + Spring Boot Controller 코드 생성
- /convention-backend : 백엔드 코드 컨벤션 가이드
- /entity : JPA 엔티티 설계 및 생성
- /migration : DB 마이그레이션 스크립트 생성
