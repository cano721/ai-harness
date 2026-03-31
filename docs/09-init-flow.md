# AI Harness - Init 플로우 상세

## 개요

`/harness-init`은 팀에 따라 서로 다른 설치 경로를 사용한다.

- `planning`
  - 프로젝트 분석을 하지 않는다
  - planner bundle을 현재 runtime에 맞춰 전역 설치한다
- `backend`
  - 기존처럼 프로젝트를 분석한다
  - `.ai-harness/` 아래 로컬 팀 자산을 생성한다

핵심 원칙은 하나다.

> 모든 단계에서 "무엇을 어디에 설치할지"를 먼저 보여주고 사용자 확인 후 진행한다.

## 전체 흐름도

```text
/harness-init
    │
    ▼
[1] 팀 선택
    │
    ├── planning
    │   ▼
    │ [2-A] runtime 감지
    │   ▼
    │ [3-A] planner bundle inspect
    │   ▼
    │ [4-A] 전역 설치
    │   ▼
    │ [5-A] readiness check
    │
    └── backend
        ▼
      [2-B] 글로벌 Hook 확인
        ▼
      [3-B] 프로젝트 확인
        ▼
      [4-B] 프로젝트 분석 및 로컬 세팅
        ▼
      [5-B] 완료 요약
```

## 글로벌 vs 로컬 분리

사용자에게 글로벌/로컬 선택을 별도로 묻지 않는다. 팀 성격에 따라 자동으로 결정한다.

| 항목 | planning | backend |
|------|----------|---------|
| 설치 스코프 | 전역 | 프로젝트 로컬 |
| 설치 대상 | `~/.codex` 또는 `~/.claude` | `./.ai-harness/` |
| 프로젝트 분석 | 하지 않음 | 수행 |
| 설치 소스 | `teams/planning/bundle/` | `teams/backend/` |
| 컨텍스트 파일 | `AGENTS.md` 또는 `CLAUDE.md` | `.ai-harness/teams/backend/CLAUDE.md` |

## 1단계: 팀 선택

가장 먼저 어떤 팀 설정을 적용할지 결정한다.

```text
"어떤 팀 설정을 사용할까요?

 추천:
  - planning: PRD, Jira, user story, checklist
  - backend: Java/Spring, API, DB

 사용 가능한 팀:
  [1] planning — 글로벌 planner bundle (Codex/Claude)
  [2] backend  — Java/Spring, API, DB
  [3] frontend — 준비 중
  [4] devops   — 준비 중
  [5] qa       — 준비 중
  [6] design   — 준비 중

 선택? (planning 또는 backend 등):"
```

planning은 사용자의 역할이 우선이다. backend는 프로젝트 스택 감지 결과를 함께 제시할 수 있다.

## planning 분기

### 2-A단계: runtime 감지

planner bundle은 Codex와 Claude Code 둘 다 지원한다. init은 먼저 현재 에이전트 환경을 감지한다.

감지 기준 예시:

- Codex 관련 환경 변수
- Claude Code 관련 환경 변수
- 현재 설정 디렉토리 힌트
- 홈 디렉토리의 `~/.codex`, `~/.claude` 존재 여부

감지 결과는 runtime뿐 아니라 이유도 함께 보여준다.

예시:

```json
{
  "runtime": "claude",
  "detectionReason": "env:claude"
}
```

### 3-A단계: planner bundle inspect

실제 설치 전 `install-planner-bundle.mjs inspect`로 설치 요약을 보여준다.

```bash
node scripts/install-planner-bundle.mjs inspect --runtime auto
```

출력 예시:

```json
{
  "runtime": "claude",
  "detectionReason": "env:claude",
  "targetRoot": "/Users/.../.claude",
  "contextTarget": "/Users/.../.claude/CLAUDE.md",
  "sourceSkillCount": 26,
  "sourceAgentCount": 16,
  "sourceTemplateCount": 1,
  "atlassianReady": true
}
```

사용자에게는 이 값을 자연어로 압축해 보여준다.

```text
"planning 팀 글로벌 세팅:
  runtime: Claude Code
  detection: env:claude
  target: ~/.claude
  context: ~/.claude/CLAUDE.md
  agents: 16개
  skills: 26개
  templates: 1개
  Atlassian credential: 준비됨

 설치할까요? (Y/n):"
```

### 4-A단계: 전역 설치

확인 후 아래 명령으로 설치한다.

```bash
node scripts/install-planner-bundle.mjs install --runtime auto
```

설치 규칙:

1. 소스는 항상 `teams/planning/bundle/`을 사용한다.
2. `teams/planning/skills/`와 `teams/planning/CLAUDE.md`는 legacy 초안이므로 설치 소스로 사용하지 않는다.
3. Codex일 때:
   - `AGENTS.md`
   - `agents/`
   - `skills/`
   - `planner-templates/`
4. Claude Code일 때:
   - `CLAUDE.md`
   - `agents/`
   - `skills/`
   - `planner-templates/`
5. 텍스트 자산은 runtime 규칙에 맞게 자동 변환한다.
   - `AGENTS.md -> CLAUDE.md`
   - `~/.codex -> ~/.claude`
   - Codex 관련 문구 -> Claude Code 문구
6. 기존 파일이 다르면 `backups/planner-bundle-{timestamp}/` 아래에 백업 후 덮어쓴다.

### 5-A단계: readiness check

planning 분기의 readiness는 비차단 방식이다. 설치를 막지 않고 상태만 요약한다.

확인 항목:

- Atlassian credential 존재 여부
  - 기준: `~/.claude/credentials.md` 안 `Atlassian` 섹션
- `jira` skill 설치 여부
- `jira-checklist` skill 설치 여부
- `policy-template.md` 설치 여부

완료 메시지 예시:

```text
"planning bundle 설치 완료:
  runtime: Claude Code
  target: ~/.claude
  created: 44
  updated: 2
  skipped: 97

 readiness:
  - Atlassian credential: 있음
  - jira skill: 있음
  - jira-checklist skill: 있음
  - policy template: 있음

 다음 예시:
  - jira NMRS-15863 보여줘
  - create-prd로 정리해줘
  - user-stories로 쪼개줘"
```

## backend 분기

### 2-B단계: 글로벌 Hook 확인

backend는 기존 모델을 유지한다. 전역 보안 Hook 상태를 먼저 확인하고 필요한 항목만 등록한다.

예시:

```text
"보안 Hook을 모든 프로젝트에 적용합니다:
  ✓ block-dangerous
  ✓ secret-scanner
  ★ check-architecture
  ✓ audit-logger

 등록 위치: ~/.claude/settings.json
 진행할까요? (Y/n):"
```

### 3-B단계: 프로젝트 확인

현재 디렉토리를 분석해 어느 프로젝트에 세팅할지 확인한다.

```text
"현재 프로젝트 분석:
  경로: /Users/.../my-service
  스택: Java 17, Spring Boot, JPA
  팀: backend

 이 프로젝트에 backend 세팅을 적용할까요? (Y/n):"
```

### 4-B단계: 프로젝트 분석 및 로컬 세팅

backend는 `.ai-harness/` 아래에 로컬 자산을 만든다.

- `.ai-harness/config.yaml`
- `.ai-harness/context-map.md`
- `.ai-harness/teams/backend/CLAUDE.md`
- `.ai-harness/teams/backend/skills/convention-backend.md`
- 팀별 Hook 등록

필요 시 `copy-team-resources.mjs`, `register-hooks.mjs`를 사용한다.

## planning 카탈로그

planning bundle에 포함되는 대표 자산은 다음과 같다.

- `create-prd`
- `user-stories`
- `jira`
- `jira-checklist`
- 인터뷰/요약/문서 변환 관련 planner skill
- agent TOML 16개
- `AGENTS.md` 공통 컨텍스트
- `policy-template.md`

## 생성/설치 결과

### planning

```text
~/.codex/
├── AGENTS.md
├── agents/
├── skills/
└── planner-templates/
```

또는

```text
~/.claude/
├── CLAUDE.md
├── agents/
├── skills/
└── planner-templates/
```

### backend

```text
프로젝트/
├── .ai-harness/
│   ├── config.yaml
│   ├── context-map.md
│   ├── logs/
│   └── teams/
│       └── backend/
│           ├── CLAUDE.md
│           └── skills/
└── .claude/
    └── settings.json
```

## 유지보수 메모

1. planning 관련 공식 자산은 `teams/planning/bundle/`에만 추가한다.
2. planning legacy 자산은 참조용으로 남겨두되 init 소스로 사용하지 않는다.
3. Claude/Codex 차이는 공통 파일을 중복 보관하지 말고 runtime 변환 규칙으로 흡수한다.
