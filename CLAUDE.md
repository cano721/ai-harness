# AI Harness — AI 에이전트 제어/검증 프레임워크

## 설계 철학
- **제어 + 생산성**: 안전하게 통제하면서, 에이전트가 더 잘 작업하도록 돕는다
- **차단이 아닌 안내**: 위반 시 단순 차단이 아니라 구체적 대안 코드를 제시한다
- **아키텍처 강제**: 의존성 방향을 기계적으로 검증하여 구조적 일관성을 유지한다
- **메트릭 기반 개선**: 차단 패턴을 분석하여 컨벤션과 스캐폴딩을 지속 개선한다

## 보안 규칙 (항상 적용)
- 위험 명령 실행 금지 (rm -rf, DROP TABLE, force push, chmod 777, sudo)
- 시크릿/인증 정보 하드코딩 금지
- .env, credentials.json 등 민감 파일 커밋 금지

## 코드 작성 시
- 프로젝트에 .ai-harness/가 있으면 해당 팀의 컨벤션 스킬을 참고하라
- .ai-harness/context-map.md 를 먼저 읽어 프로젝트 지도를 파악하라 (매뉴얼이 아닌 지도)
- .ai-harness/teams/{team}/skills/convention-{team}.md 파일을 읽어서 적용
- 새 코드 생성 시 templates/presets/ 의 작업 프리셋을 참고하라 (CRUD, 버그수정, 리팩토링)

## 제공 팀
- 현재: **backend** (제공 중)
- 준비 중: frontend, qa, devops, planning, design
- backend 외 팀 요청 시 "아직 준비 중입니다" 안내

## 사용 가능한 스킬
- /harness-init : 프로젝트 분석 → 컨벤션 자동 생성 → Hook 등록
- /harness-status : 상태 확인 + 차단 현황 + 진단 + 미결정 사항
- /harness-rules : 적용 중인 규칙 + 마지막 차단 사유
- /harness-team : 팀 추가/수정/제거/목록
- /harness-exclude : 글로벌 하네스에서 프로젝트 제외
- /harness-metrics : 에이전트 작업 효율 메트릭 분석 + 개선 제안
- /harness-scaffold : 컨벤션 기반 코드 보일러플레이트 생성 (CRUD, Service 등)

## 자동 동작
- .claude/settings.json에 Hook이 등록되어 있으면 도구 사용 시 자동 검증
- 차단 시 사유와 대안을 안내
- 모든 액션은 감사 로그(.ai-harness/logs/)에 기록
