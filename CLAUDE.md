# AI Harness — 팀별 AI 에이전트 셋업 시스템

## 설계 철학
- **추천 + 선택**: 하네스가 베스트 프랙티스를 추천하고, 팀이 선택한다
- **셋업 후 빠지기**: init 시 세팅해주고, 이후엔 Claude Code가 알아서 동작한다. 하네스는 개입하지 않는다
- **차단이 아닌 안내**: 위반 시 단순 차단이 아니라 구체적 대안 코드를 제시한다
- **팀 자율성**: 각 팀이 자기 도메인, 컨벤션, 스킬을 자유롭게 구성한다
- **최소 강제**: 필수는 보안 Hook 4개뿐. 나머지는 모두 opt-in이다

## 보안 규칙 (항상 적용)
- 위험 명령 실행 금지 (rm -rf, DROP TABLE, force push, chmod 777, sudo)
- 시크릿/인증 정보 하드코딩 금지
- .env, credentials.json 등 민감 파일 커밋 금지

## 코드 작성 시
- 프로젝트에 .ai-harness/가 있으면 해당 팀의 컨벤션 스킬을 참고하라
- .ai-harness/context-map.md 를 먼저 읽어 프로젝트 지도를 파악하라 (매뉴얼이 아닌 지도)
- .ai-harness/teams/{team}/skills/convention-{team}.md 파일을 읽어서 적용
- planning 팀은 `teams/planning/bundle/` 을 설치 소스로 사용하며, `teams/planning/skills/` 와 `teams/planning/CLAUDE.md` 는 legacy 초안으로 취급한다
- planning bundle은 runtime-aware 자산이다. Codex에는 `AGENTS.md`, Claude Code에는 `CLAUDE.md` 형태로 설치된다고 가정하라
- 새 코드 생성 시 templates/presets/ 의 작업 프리셋을 참고하라 (CRUD, 버그수정, 리팩토링)

## 제공 팀
- 현재: **backend** (로컬 프로젝트 팀), **planning** (글로벌 planner bundle)
- 준비 중: frontend, qa, devops, design
- planning은 runtime(Codex/Claude)에 맞게 글로벌 설치하고, backend는 프로젝트 로컬 세팅한다

## 사용 가능한 스킬
- /harness-init : planning은 글로벌 bundle 설치, backend는 프로젝트 분석 → 컨벤션 자동 생성 → Hook 등록
- /harness-status : 상태 확인 + 차단 현황 + 진단 + 미결정 사항
- /harness-rules : 적용 중인 규칙 + 마지막 차단 사유
- /harness-team : 로컬 프로젝트 팀 추가/수정/제거/목록 (planning 글로벌 bundle 제외)
- /harness-exclude : 글로벌 하네스에서 프로젝트 제외
- /harness-metrics : 에이전트 작업 효율 메트릭 분석 + 개선 제안
- /harness-scaffold : 컨벤션 기반 코드 보일러플레이트 생성 (CRUD, Service 등)

## init 플로우
- /harness-init 실행 시 planning과 backend의 분기가 다르다
- planning: runtime 감지 → `teams/planning/bundle/` 기반 글로벌 설치 → 텍스트 자산 runtime 변환 → Jira readiness 점검
- backend: 팀 선택 → 글로벌 세팅 확인 → 프로젝트 확인 → 프로젝트 세팅
- 모든 단계에서 사용자에게 확인받은 후 진행
- 보안 Hook은 글로벌(~/.claude/settings.json), backend 컨벤션/팀 설정은 로컬(./.ai-harness/)
- planning 자산은 프로젝트 로컬이 아니라 전역(`~/.codex` 또는 `~/.claude`)에 설치한다

## 세팅 후 동작 (하네스가 아닌 Claude Code가 실행)
- .claude/settings.json에 등록된 Hook이 도구 사용 시 자동 검증
- 차단 시 사유와 대안을 안내
- 모든 액션은 감사 로그(.ai-harness/logs/)에 기록
