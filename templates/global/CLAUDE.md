## AI Harness 보안 규칙

### 절대 금지
- 위험 명령 실행 금지 (rm -rf, DROP TABLE, force push, chmod 777, sudo)
- 시크릿/인증 정보 하드코딩 금지
- .env, credentials.json 등 민감 파일 커밋 금지

### 코드 작성 시
- 코드를 작성하거나 수정할 때는 반드시 해당 팀의 컨벤션 스킬을 참고하라
- Backend: /convention-backend
- Frontend: /convention-frontend
- 전체: /convention

### 감사 추적
- 모든 도구 사용은 감사 로그에 기록됩니다
