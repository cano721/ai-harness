# AI Harness — AI 에이전트 제어/검증 프레임워크

## 보안 규칙 (항상 적용)
- 위험 명령 실행 금지 (rm -rf, DROP TABLE, force push, chmod 777, sudo)
- 시크릿/인증 정보 하드코딩 금지
- .env, credentials.json 등 민감 파일 커밋 금지

## 코드 작성 시
- 프로젝트에 .ai-harness/가 있으면 해당 팀의 컨벤션 스킬을 참고하라
- .ai-harness/teams/{team}/skills/convention-{team}.md 파일을 읽어서 적용

## 사용 가능한 스킬
- /harness-init : 프로젝트 분석 → 컨벤션 자동 생성 → Hook 등록
- /harness-status : 현재 하네스 상태 확인
- /harness-doctor : 환경/설정/Hook 종합 진단
- /harness-rules : 적용 중인 규칙 + 마지막 차단 사유
- /harness-metrics : 비용 + 사용 메트릭 조회
- /harness-team : 팀 추가/수정/제거/목록
- /harness-rollback : 설정을 이전 스냅샷으로 복원
- /harness-benchmark : Hook 실행 성능 측정
- /harness-exclude : 글로벌 하네스에서 프로젝트 제외

## 자동 동작
- .claude/settings.json에 Hook이 등록되어 있으면 도구 사용 시 자동 검증
- 차단 시 사유와 대안을 안내
- 모든 액션은 감사 로그(.ai-harness/logs/)에 기록
