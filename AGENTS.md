# AI Harness — Guard + Guide + Gear

## 설계 철학
- **추천 + 선택**: 하네스가 베스트 프랙티스를 추천하고, 팀이 선택한다
- **셋업 후 빠지기**: init 시 세팅해주고, 이후엔 Codex가 알아서 동작한다. 하네스는 개입하지 않는다
- **최소 강제, 최대 안내**: 강제는 보안 Hook 5개뿐. 나머지는 컨벤션과 워크플로우로 안내한다
- **팀 자율성**: 각 팀이 자기 도메인, 컨벤션, 스킬을 자유롭게 구성한다

## 1. Guard (안전)

### 보안 규칙 (항상 적용)
- 위험 명령 실행 금지 (rm -rf, DROP TABLE, force push, chmod 777, sudo)
- 시크릿/인증 정보 하드코딩 금지
- .env, credentials.json 등 민감 파일 커밋 금지
- 인프라 파괴 명령 차단 (terraform destroy, kubectl delete ns)
- 변경 파일 수 guardrail (config.yaml의 max_files_changed)

### 글로벌 Hook
- block-dangerous, secret-scanner, check-architecture, guardrails-check, infra-change-review

## 2. Guide (컨벤션)

### 코드 작성 시
- 프로젝트에 .ai-harness/가 있으면 해당 팀의 컨벤션 스킬을 참고하라
- .ai-harness/context-map.md 를 먼저 읽어 프로젝트 지도를 파악하라 (매뉴얼이 아닌 지도)
- .ai-harness/teams/{team}/skills/convention-{team}.md 파일을 읽어서 적용
- 새 코드 생성 시 templates/presets/ 의 작업 프리셋을 참고하라 (CRUD, 버그수정, 리팩토링)

### 제공 팀
- **backend** — API/DB 개발 (sql-review, api-compat, entity-review, coverage-check)
- **frontend** — React/Vue 개발 (bundle-size, lighthouse, coverage-check)
- **planning** — PRD/유저스토리 (글로벌 planner bundle, runtime-aware)
- **design** — 디자인 시스템/접근성

### planning 팀 특이사항
- planning 팀은 `teams/planning/bundle/` 을 설치 소스로 사용하며, `teams/planning/skills/` 와 `teams/planning/AGENTS.md` 는 legacy 초안으로 취급한다
- planning bundle은 runtime-aware 자산이다. Codex에는 `AGENTS.md`, Codex에는 `AGENTS.md` 형태로 설치된다
- planning은 runtime(Codex/Codex)에 맞게 글로벌 설치하고, backend/frontend는 프로젝트 로컬 세팅한다

### 글로벌 스킬
- test-scenario, regression, smoke-test, deploy-check, rollback-plan, infra-plan, onboard, handoff

## 3. Gear (AI 활용 최적화)

### 프로젝트 맞춤 에이전트
- .ai-harness/agents/ 또는 .Codex/agents/에 프로젝트를 이해하는 전문 에이전트가 있으면 활용하라
- 에이전트는 도메인 지식, 코드 패턴, 컨벤션이 내장되어 있다
- `_managed_by: ai-harness` 마커가 있는 에이전트는 하네스가 관리

### 팀별 전문 스킬
- .ai-harness/teams/{team}/skills/develop-{team}.md — 개발 가이드
- .ai-harness/teams/{team}/skills/review-{team}.md — 리뷰 가이드
- 스킬의 references/ 하위에 상세 예시와 체크리스트가 있다 (필요할 때만 로드)

### AI 활용 가이드
- .ai-harness/workflow.md에 이 프로젝트의 최적 워크플로우 패턴이 정의되어 있다
- 큰 기능은 워크플로우 패턴을 따르면 효율적이다

### Self-Review 방지
- 코드를 구현한 에이전트가 같은 코드를 리뷰하면 안 된다
- task-workflow의 review phase는 implement phase와 반드시 다른 서브에이전트로 실행한다
- 최소 분리: Agent 도구로 별도 서브에이전트 호출 (컨텍스트 분리)
- 강화 분리: OMC team 모드로 별도 프로세스 실행

### Task Workflow
- `.ai-harness/task-workflows/`에 작업 유형별 워크플로우가 정의되어 있다
- 기능 구현, 버그 수정, 리팩토링 등 작업 유형에 따라 적절한 워크플로우를 참고하라
- 각 워크플로우는 단계(phases) + 에이전트 배정 + 실행 순서를 정의한다
- `enforce_separation: true`인 단계는 이전 단계와 반드시 다른 서브에이전트로 실행한다

## 사용 가능한 스킬
- /harness-init : planning은 글로벌 bundle 설치, 개발팀은 프로젝트 분석 → 컨벤션 + 에이전트 + 스킬 + 워크플로우 자동 생성
- /harness-status : 상태 확인 + 차단 현황 + 진단 + 미결정 사항 (Guard/Guide/Gear 3축 표시)
- /harness-rules : 적용 중인 규칙 + 마지막 차단 사유
- /harness-team : 로컬 프로젝트 팀 추가/수정/제거/목록
- /harness-exclude : 글로벌 하네스에서 프로젝트 제외
- /harness-metrics : 에이전트 작업 효율 메트릭 분석 + 개선 제안
- /harness-scaffold : 컨벤션 기반 코드 보일러플레이트 생성

## init 플로우
- /harness-init 실행 시 planning과 개발팀의 분기가 다르다
- planning: runtime 감지 → `teams/planning/bundle/` 기반 글로벌 설치
- 개발팀: 프로젝트 분석 → 컨벤션 → Hook → 에이전트 → 스킬 → 워크플로우 → 검증
- 모든 단계에서 사용자에게 확인받은 후 진행

## 세팅 후 동작 (하네스가 아닌 Codex가 실행)
- .Codex/settings.json에 등록된 Hook이 도구 사용 시 자동 검증
- 차단 시 사유와 대안을 안내
