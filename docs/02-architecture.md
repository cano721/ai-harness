# AI Harness - 아키텍처

## 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────┐
│                    Claude Code Plugin                        │
│                                                             │
│  .claude-plugin/plugin.json                                 │
│  ├── CLAUDE.md (진입점 — 에이전트가 규칙/스킬 참조)          │
│  ├── skills/ (대화형 셋업 명령)                              │
│  └── hooks/ (상시 보안 검증)                                 │
│                                                             │
│  ┌───────────┐  ┌───────────┐  ┌───────────────────────┐    │
│  │   Skill   │  │   Hook    │  │        Team           │    │
│  │   계층    │  │   계층    │  │        계층           │    │
│  │           │  │           │  │                       │    │
│  │ 대화형    │  │ 상시 자동 │  │  팀별 특화            │    │
│  │ 셋업/도구 │  │ 보안 검증 │  │  Hook + Skill + 규칙  │    │
│  └───────────┘  └───────────┘  └───────────────────────┘    │
│         │              │                │                    │
│         ▼              ▼                ▼                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │            프로젝트 설정 (.ai-harness/)               │   │
│  │  config.yaml / context-map.md / 팀별 컨벤션           │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                   │
│                          ▼                                   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              OMC 연동 (선택)                           │   │
│  │  harness-hook-bridge.js — Hook 체이닝                  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 3개 핵심 계층

### 1. Skill 계층 — 대화형 셋업과 도구

사용자가 슬래시 명령으로 호출하는 대화형 기능. init, 상태 확인, 팀 관리, 보일러플레이트 생성 등.

```
skills/
├── harness-init/SKILL.md        # 프로젝트 초기화
├── harness-status/SKILL.md      # 상태 확인 + 진단
├── harness-rules/SKILL.md       # 적용 규칙 확인
├── harness-team/SKILL.md        # 팀 관리
├── harness-exclude/SKILL.md     # 프로젝트 제외
├── harness-metrics/SKILL.md     # 메트릭 분석
└── harness-scaffold/SKILL.md    # 보일러플레이트 생성
```

각 스킬은 `SKILL.md` 파일 하나로 정의된다. Claude Code 플러그인이 이 파일을 읽어 슬래시 명령으로 노출한다.

**Skill은 init 시점에 집중 동작하고, 일상 작업에서는 scaffold/status 정도만 사용한다.**

### 2. Hook 계층 — 상시 보안 검증

에이전트가 도구를 사용할 때마다 자동 실행되는 셸 스크립트. `.claude/settings.json`에 등록되어 Claude Code가 직접 호출한다.

```
hooks/
├── block-dangerous.sh       # PreToolUse — 위험 명령 차단 + 대안 안내
├── secret-scanner.sh        # PreToolUse — 시크릿 하드코딩 감지
├── check-architecture.sh    # PreToolUse — 아키텍처 경계 위반 검증
└── audit-logger.sh          # PostToolUse — 모든 도구 사용 로깅
```

| Hook | 시점 | 역할 | exit 코드 |
|------|------|------|-----------|
| `block-dangerous.sh` | PreToolUse | `rm -rf`, `DROP TABLE`, `force push`, `chmod 777`, `sudo` 차단. 대안 명령 제시 | 2: 차단, 0: 통과 |
| `secret-scanner.sh` | PreToolUse | API Key, 비밀번호, 토큰 등 하드코딩 감지 | 2: 차단, 0: 통과 |
| `check-architecture.sh` | PreToolUse | 의존성 방향 위반 감지 (하위→상위 import 차단) | 2: 차단, 0: 통과 |
| `audit-logger.sh` | PostToolUse | 도구명, 입력, 시각을 JSONL로 기록 | 항상 0 |

**Hook의 핵심 원칙**: exit 2는 차단, exit 0은 통과. 차단 시 사유와 대안을 stdout으로 출력하면 에이전트가 이를 읽고 수정한다.

### 3. Team 계층 — 팀별 특화

각 팀은 독립된 디렉토리에 자체 규칙, Hook, Skill을 가진다.

```
teams/
├── backend/
│   ├── CLAUDE.md                          # 팀 규칙 (SQL 바인딩, SELECT * 금지 등)
│   ├── hooks/
│   │   ├── api-compat.sh                  # API 호환성 검사
│   │   ├── entity-review.sh               # 엔티티 변경 리뷰
│   │   └── sql-review.sh                  # SQL 검증
│   └── skills/
│       ├── convention-backend.md          # 코드 컨벤션 (init 시 프로젝트에 맞춤 생성)
│       ├── api-design.md                  # API 설계 가이드
│       ├── entity.md                      # 엔티티 생성
│       └── migration.md                   # DB 마이그레이션
├── frontend/
│   ├── CLAUDE.md                          # 팀 규칙 (moment 금지, 번들 300KB 등)
│   ├── hooks/
│   │   ├── bundle-size.sh                 # 번들 사이즈 체크
│   │   └── lighthouse.sh                  # Lighthouse 성능 검사
│   └── skills/
│       ├── convention-frontend.md
│       ├── component.md
│       ├── state-management.md
│       └── performance.md
├── devops/
│   ├── CLAUDE.md
│   ├── hooks/
│   │   └── infra-change-review.sh         # 인프라 변경 리뷰
│   └── skills/
│       ├── convention-devops.md
│       ├── deploy-check.md
│       ├── infra-plan.md
│       └── rollback-plan.md
├── qa/
│   ├── CLAUDE.md
│   └── skills/
│       ├── convention-qa.md
│       ├── test-scenario.md
│       └── coverage-check.md
├── planning/
│   ├── CLAUDE.md
│   └── skills/
│       ├── convention-planning.md
│       ├── prd.md
│       ├── user-story.md
│       └── estimation.md
└── design/
    ├── CLAUDE.md
    └── skills/
        ├── convention-design.md
        ├── a11y.md
        ├── figma-to-code.md
        └── responsive.md
```

**팀 계층의 핵심**: init 시 사용자가 선택한 팀의 리소스만 프로젝트에 복사된다. 컨벤션은 범용 템플릿을 기반으로 프로젝트 실제 코드를 분석하여 맞춤 생성한다.

## 데이터 흐름

### init 시점 (한 번) — 모든 단계에서 사용자 확인

```
/harness-init 실행
    │
    ▼
[1. 팀 선택] ─── 기술 스택 감지 → 추천 → 사용자 선택
    │
    ▼
[2. 글로벌 세팅] ─── "보안 Hook을 모든 프로젝트에 적용합니다"
    │                  → 사용자 확인 후 ~/.claude/settings.json에 등록
    ▼
[3. 프로젝트 확인] ─── "이 프로젝트에 세팅할까요?"
    │                    → 프로젝트 분석 + 사용자 확인
    ▼
[4. 프로젝트 세팅] ─── 미세팅 항목 표시 → 사용자 선택 후 세팅
    │                    컨벤션, 컨텍스트맵, 팀 Hook, 외부 연동 등
    ▼
[완료] 적용 요약
```

### 작업 시점 (상시)

```
에이전트가 도구 호출
    │
    ▼
[PreToolUse Hook 실행]
    │
    ├── block-dangerous.sh ─── 위험 명령? → exit 2 (차단 + 대안 안내)
    ├── secret-scanner.sh ──── 시크릿? → exit 2 (차단)
    ├── check-architecture.sh ─ 의존성 위반? → exit 2 (차단)
    └── 팀별 Hook ────────── api-compat, sql-review 등
    │
    ▼ (모두 exit 0이면 실행 허용)
[도구 실행]
    │
    ▼
[PostToolUse Hook 실행]
    │
    ├── audit-logger.sh ──── 도구명/입력/시각 JSONL 기록
    └── 팀별 Hook ────────── bundle-size, lighthouse 등
```

## 설정 파일 구조

### .ai-harness/config.yaml — 프로젝트 설정

```yaml
_schema_version: 1

project:
  name: "my-service"
  domain: "채용 관리"
  description: "채용 프로세스 관리 시스템"
  entities: [Applicant, JobPosting, Interview, Evaluation]
  tech_stack: [Java, Spring Boot, JPA, MySQL]
  base_package: "com.company.recruit"

teams: [backend]

guardrails:
  max_files_changed: 20
  max_execution_minutes: 30

hooks:
  block-dangerous:
    enabled: true          # locked — 비활성화 불가
  secret-scanner:
    enabled: true          # locked
  audit-logger:
    enabled: true          # locked
  check-architecture:
    enabled: true          # locked

architecture:
  layers:
    - name: Types/Entity
      patterns: ["dto", "entity", "model", "domain", "type", "vo", "enum"]
    - name: Config
      patterns: ["config", "configuration", "properties"]
    - name: Repository
      patterns: ["repository", "repo", "dao", "mapper", "persistence"]
    - name: Service
      patterns: ["service", "usecase", "application"]
    - name: Controller
      patterns: ["controller", "rest", "api", "endpoint", "resource"]
  direction: "Types/Entity → Config → Repository → Service → Controller"

rules:
  test_coverage: 80

integrations:             # 외부 서비스 연동 (init 시 선택)
  - name: jira
    base_url: https://company.atlassian.net
    project_key: PROJ
```

### .ai-harness/context-map.md — 에이전트용 프로젝트 지도

에이전트가 작업 시 프로젝트의 핵심 구조를 빠르게 파악하기 위한 지도. 전체 매뉴얼이 아닌 진입점과 패턴만 담는다. init 시 자동 생성되며, 다음을 포함한다:

- 프로젝트 개요 (이름, 도메인, 스택)
- 핵심 진입점 (Controller, Service, Repository 경로)
- 의존성 방향
- 주요 엔티티와 관계
- 공통 패턴 (응답 클래스, 예외 처리, DTO 네이밍)
- 자주 수정하는 파일 (git log 기반)

### templates/lock-policy.yaml — 잠금 정책

```yaml
locked:                      # 팀이 비활성화할 수 없음
  - hooks.block-dangerous
  - hooks.audit-logger
  - hooks.secret-scanner
  - hooks.check-architecture
bounded:                     # 범위 내에서만 변경 가능
  rules.test_coverage:
    min: 60
    max: 100
    default: 80
  guardrails.max_files_changed:
    max: 50
    default: 20
free:                        # 팀이 자유롭게 on/off
  - hooks.lighthouse
  - hooks.bundle-size
```

### .claude/settings.json — Hook 등록

```json
{
  "hooks": [
    {
      "event": "PreToolUse",
      "matcher": "Bash|Write|Edit",
      "command": "bash /path/to/hooks/block-dangerous.sh",
      "_managed_by": "ai-harness"
    }
  ]
}
```

`_managed_by: "ai-harness"` 마커로 하네스가 관리하는 Hook을 식별한다. 기존에 사용자가 등록한 Hook은 건드리지 않는다.

## 확장 포인트

### 새 팀 추가

1. `teams/{team-name}/` 디렉토리 생성
2. `CLAUDE.md` — 팀 규칙 작성
3. `skills/convention-{team-name}.md` — 범용 컨벤션 템플릿 작성
4. (선택) `hooks/` — 팀 전용 Hook 추가
5. (선택) `skills/` — 팀 전용 Skill 추가

```
teams/data-engineering/
├── CLAUDE.md
├── hooks/
│   └── data-quality.sh
└── skills/
    ├── convention-data-engineering.md
    └── pipeline.md
```

### 새 Hook 추가

1. `hooks/` (글로벌) 또는 `teams/{team}/hooks/` (팀별)에 셸 스크립트 작성
2. 위치 인수 `$1`(도구명), `$2`(도구 입력)로 도구 정보 수신
3. 차단 시 exit 2 + stdout으로 사유/대안 출력, 통과 시 exit 0
4. `scripts/register-hooks.mjs register`로 settings.json에 등록

```bash
#!/bin/bash
# hooks/my-custom-check.sh
TOOL_NAME="${1:-}"
TOOL_INPUT="${2:-}"

if [[ "$TOOL_INPUT" == *"위험 패턴"* ]]; then
  echo "BLOCKED: 위험 패턴 감지. 대안: ..."
  exit 2
fi
exit 0
```

### 새 Skill 추가

1. `skills/{skill-name}/SKILL.md` 파일 생성
2. YAML front matter로 name, description 정의
3. `<Steps>` 태그 안에 에이전트가 수행할 절차 작성

```markdown
---
name: my-skill
description: 커스텀 작업 수행
---

<Steps>
1. 사용자에게 입력 받기
2. 코드 분석
3. 결과 생성
</Steps>
```

## 호환 정책 — 기존 환경과의 공존

### 핵심 원칙

> **하네스는 강제하지 않는다. 분석하고, 비교하고, 사용자가 결정한다.**

init 시 기존 환경을 감지하여 충돌 가능성을 분석하고, 기존 설정과 하네스 설정의 차이를 비교하여 사용자에게 선택지를 제시한다.

### 충돌 감지 대상

| 영역 | 감지 방법 | 충돌 가능성 |
|------|----------|------------|
| **Hook** | `.claude/settings.json`에서 기존 Hook 목록 확인 | 같은 도구(Bash, Write 등)에 대한 중복 검증 |
| **CLAUDE.md 규칙** | 기존 CLAUDE.md에서 규칙 패턴 파싱 | 네이밍, 코딩 스타일 등 규칙 상충 |
| **플러그인** | `claude plugin list`로 설치된 플러그인 확인 | 스킬 기능 중복 |
| **커스텀 에이전트** | `custom-agents/` 디렉토리 존재 여부 | 역할 중복 |
| **MCP 서버** | `.claude/.mcp.json` 기존 설정 확인 | 같은 서비스 중복 연결 |

### 충돌 시 처리 플로우

```
충돌 감지 → 기존 vs 하네스 비교 분석 → 차이점/장단점 제시 → 사용자가 선택
```

### Hook 충돌

기존 Hook과 하네스 Hook이 같은 영역을 검증하는 경우:

```
"⚠ PreToolUse Hook 충돌 감지:

 [기존] my-security-check.sh
   → rm, sudo, chmod 차단 (3개 패턴)

 [하네스] block-dangerous.sh
   → rm -rf, DROP TABLE, force push, chmod 777, sudo 차단 (6개 패턴)
   → 차단 시 대안 코드 제시

 기존 Hook이 하네스보다 범위가 좁습니다.
  [1] 하네스로 교체 — 더 넓은 범위 + 대안 안내
  [2] 기존 유지 — 하네스 Hook 비활성화
  [3] 둘 다 실행 — 기존 먼저, 하네스가 보완

 선택?:"
```

### CLAUDE.md 규칙 충돌

기존 컨벤션과 하네스가 생성한 컨벤션이 다른 경우:

```
"⚠ 규칙 충돌 감지:

 [기존 CLAUDE.md] 'DTO 네이밍: {Entity}Dto'
 [하네스 컨벤션]  'DTO 네이밍: {Action}{Entity}Request/Response'

 프로젝트 코드 분석: {Action}{Entity}Request 12곳, {Entity}Dto 3곳

  [1] 하네스 패턴 적용 — 다수 사용 중인 패턴 (12곳)
  [2] 기존 패턴 유지
  [3] 나중에 결정 — pending에 저장

 선택?:"
```

### 플러그인/스킬 중복

다른 플러그인이 유사한 스킬을 제공하는 경우:

```
"⚠ 스킬 기능 중복 감지:

 [기존] pm-skills의 /write-prd
   → PRD 8섹션 템플릿
 [하네스] planning 팀의 /prd
   → 프로젝트 도메인 맞춤 PRD + 컨벤션 연동

  [1] 하네스 스킬 사용 — 프로젝트 맞춤 + 컨벤션 연동
  [2] 기존 스킬 유지 — 하네스 스킬 비활성화
  [3] 둘 다 유지 — 용도에 따라 선택 사용

 선택?:"
```

### 비파괴적 등록

어떤 선택을 하든 기존 설정은 삭제하지 않는다:

| 영역 | 하네스 관리 방법 | 기존 보존 방법 |
|------|-----------------|---------------|
| `settings.json` | `_managed_by: "ai-harness"` 마커 | 마커 없는 항목은 건드리지 않음 |
| `CLAUDE.md` | `<!-- harness:start/end -->` 구간 | 구간 밖 내용은 보존 |
| `.mcp.json` | 새 서버만 추가 | 기존 서버 유지 |
| `custom-agents/` | 별도 `custom-agents/` 제공 | 기존 에이전트 유지 |

### init 시 환경 요약

모든 감지 결과를 한 번에 보여주고 진행 여부를 확인한다:

```
"기존 환경 감지 결과:
  ✓ OMC 플러그인 — Hook 브릿지로 연동
  ✓ custom-agents/ 2개 — 하네스 에이전트와 별도 유지
  ⚠ PreToolUse Hook 3개 — 충돌 여부 확인 필요 (1건)
  ⚠ CLAUDE.md 규칙 — 컨벤션 차이 감지 (2건)
  ✓ .mcp.json MySQL — 기존 유지

 충돌 항목을 하나씩 확인합니다. 계속할까요?"
```

## OMC 연동

OMC(Oh My Claude Code)가 설치된 환경에서는 `omc-integration/harness-hook-bridge.js`가 Hook 체이닝을 담당한다.

### Hook 실행 순서

```
PreToolUse:
  하네스 글로벌 Hook → 팀 Hook → OMC Hook

PostToolUse:
  OMC Hook → 팀 Hook → 하네스 글로벌 Hook
```

Pre에서는 하네스 보안이 먼저 실행되어 위험을 차단하고, Post에서는 OMC가 먼저 처리한 후 하네스가 로깅한다.

### 브릿지 동작

```
harness-hook-bridge.js <event> <tool_name> <tool_input>
    │
    ├── .ai-harness/config.yaml에서 팀 목록 로드
    ├── hooks/ 에서 글로벌 Hook 수집
    ├── teams/{team}/hooks/ 에서 팀 Hook 수집
    ├── .claude/hooks/ 에서 OMC Hook 수집
    │
    └── 순서대로 실행 (exit 2 시 즉시 중단)
```

OMC가 없으면 브릿지 없이 Claude Code가 직접 `settings.json`의 Hook을 실행한다. OMC 연동은 완전히 선택이며, 하네스의 핵심 기능은 OMC 없이도 동작한다.

## 확장 계획 — 멀티 플랫폼 지원

현재 AI Harness는 Claude Code 전용이지만, 보안 규칙/컨벤션/팀 구조 등 핵심 자산은 플랫폼에 독립적이다. 향후 Codex, Cursor 등 다른 AI 코딩 도구를 지원할 때를 대비하여, **"무엇을 세팅하는가"와 "어디에 세팅하는가"를 분리**하는 구조를 유지한다.

### 공통 코어 (플랫폼 독립)

어떤 플랫폼이든 재사용 가능한 자산:

| 자산 | 설명 | 이식성 |
|------|------|--------|
| Hook 스크립트 | `block-dangerous.sh`, `secret-scanner.sh` 등 순수 bash | 그대로 실행 가능 |
| 컨벤션 | 마크다운 형식의 코딩 규칙 | 어떤 컨텍스트 파일이든 주입 가능 |
| 아키텍처 레이어 정의 | `config.yaml`의 레이어/패턴 | 플랫폼 무관 |
| 팀 구조 + 추천 카탈로그 | `teams/` 디렉토리 | 플랫폼 무관 |
| 컨텍스트 맵 | 프로젝트 지도 마크다운 | 어떤 도구든 참조 가능 |

### 플랫폼 어댑터 (플랫폼별)

각 플랫폼의 세팅 방식에 맞게 변환하는 레이어:

```
AI Harness (공통 코어)
  │
  ├── Claude Code 어댑터 (현재)
  │   ├── .claude/settings.json에 Hook 등록
  │   ├── CLAUDE.md에 규칙 주입
  │   └── skills/SKILL.md 포맷
  │
  ├── Codex 어댑터 (향후)
  │   ├── AGENTS.md에 규칙 주입
  │   ├── Codex Hook/설정에 등록
  │   └── Codex 명령어 포맷
  │
  └── 기타 어댑터 (향후)
      └── 해당 플랫폼의 설정 방식에 맞게 변환
```

### 현재 지켜야 할 원칙

멀티 플랫폼 지원을 당장 구현하지는 않지만, 확장 가능성을 유지하기 위해 다음을 지킨다:

1. **Hook 스크립트는 순수 bash로 유지** — Claude Code 고유 API에 의존하지 않는다
2. **컨벤션은 일반 마크다운으로 유지** — CLAUDE.md 전용 문법을 쓰지 않는다
3. **등록 로직은 scripts/에 분리** — `register-hooks.mjs`, `inject-claudemd.mjs` 등이 어댑터 역할을 한다
4. **config.yaml은 플랫폼 중립** — Claude Code 전용 설정을 넣지 않는다
