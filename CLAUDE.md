# AI Harness — Guard + Guide + Harness

AI 에이전트를 안전하게 제어하고(Guard), 코드 품질을 강제하며(Guide), AI가 프로젝트를 이해하고 최적으로 활용되도록 셋업한다(Harness).

## 1. Guard (안전)

### 보안 규칙 (항상 적용)
- 위험 명령 실행 금지 (rm -rf, DROP TABLE, force push, chmod 777, sudo)
- 시크릿/인증 정보 하드코딩 금지
- .env, credentials.json 등 민감 파일 커밋 금지
- 인프라 파괴 명령 차단 (terraform destroy, kubectl delete ns)
- 변경 파일 수 guardrail (config.yaml의 max_files_changed)

### 글로벌 Hook
- block-dangerous, secret-scanner, guardrails-check, infra-change-review, audit-logger

## 2. Guide (컨벤션)

### 코드 작성 시
- 프로젝트에 .ai-harness/가 있으면 해당 팀의 컨벤션 스킬을 참고하라
- .ai-harness/teams/{team}/skills/convention-{team}.md 파일을 읽어서 적용

### 제공 팀
- **backend** — API/DB 개발 (sql-review, api-compat, entity-review, coverage-check)
- **frontend** — React/Vue 개발 (bundle-size, lighthouse, coverage-check)
- **planning** — PRD/유저스토리
- **design** — 디자인 시스템/접근성

### 글로벌 스킬
- test-scenario, regression, smoke-test, deploy-check, rollback-plan, infra-plan

## 3. Harness (AI 활용 최적화)

### 프로젝트 맞춤 에이전트
- .ai-harness/agents/ 또는 .claude/agents/에 프로젝트를 이해하는 전문 에이전트가 있으면 활용하라
- 에이전트는 도메인 지식, 코드 패턴, 컨벤션이 내장되어 있다
- `_managed_by: ai-harness` 마커가 있는 에이전트는 하네스가 관리

### 팀별 전문 스킬
- .ai-harness/teams/{team}/skills/develop-{team}.md — 개발 가이드
- .ai-harness/teams/{team}/skills/review-{team}.md — 리뷰 가이드
- 스킬의 references/ 하위에 상세 예시와 체크리스트가 있다 (필요할 때만 로드)

### AI 활용 가이드
- .ai-harness/workflow.md에 이 프로젝트의 최적 워크플로우 패턴이 정의되어 있다
- 큰 기능은 워크플로우 패턴을 따르면 효율적이다

## 사용 가능한 스킬
- /harness-init : 프로젝트 분석 → 컨벤션 + 에이전트 + 스킬 + 워크플로우 자동 생성
- /harness-status : 상태 확인 + 차단 현황 + 진단 + 미결정 사항
- /harness-rules : 적용 중인 규칙 + 마지막 차단 사유
- /harness-team : 팀 추가/수정/제거/목록
- /harness-exclude : 글로벌 하네스에서 프로젝트 제외

## 자동 동작
- .claude/settings.json에 Hook이 등록되어 있으면 도구 사용 시 자동 검증
- 차단 시 사유와 대안을 안내
- 모든 액션은 감사 로그(.ai-harness/logs/)에 기록
