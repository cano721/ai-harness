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
