# AI Harness - 디렉토리 구조

## 전체 구조

```text
ai-harness/
├── .claude-plugin/                   # Claude Code 플러그인 메타데이터
├── CLAUDE.md                         # 플러그인 루트 컨텍스트
├── README.md
├── package.json
│
├── skills/                           # 사용자가 직접 호출하는 하네스 스킬
│   ├── harness-init/
│   ├── harness-status/
│   ├── harness-rules/
│   ├── harness-team/
│   ├── harness-exclude/
│   ├── harness-metrics/
│   └── harness-scaffold/
│
├── scripts/                          # 스킬이 내부적으로 호출하는 유틸리티
│   ├── check-environment.mjs
│   ├── copy-team-resources.mjs
│   ├── inject-claudemd.mjs
│   ├── install-planner-bundle.mjs    # planner bundle 전역 설치
│   ├── register-hooks.mjs
│   └── test-hooks.mjs
│
├── hooks/                            # 전역 보안/감사 Hook
│   ├── audit-logger.sh
│   ├── block-dangerous.sh
│   ├── secret-scanner.sh
│   └── *.test.yaml
│
├── teams/                            # 팀별 자산
│   ├── backend/                      # 프로젝트 로컬 팀 자산
│   ├── design/
│   ├── devops/
│   ├── frontend/
│   ├── planning/
│   │   ├── README.md                 # planner bundle 구조 설명
│   │   ├── bundle-codex/             # Codex용 실제 배포 번들
│   │   │   ├── AGENTS.md
│   │   │   ├── agents/
│   │   │   ├── skills/
│   │   │   └── planner-templates/
│   │   └── bundle-claude/            # Claude Code용 실제 배포 번들
│   │       ├── CLAUDE.md
│   │       ├── agents/
│   │       ├── skills/
│   │       └── planner-templates/
│   └── qa/
│
├── templates/                        # 프로젝트 로컬 설정 템플릿
│   ├── config.yaml
│   ├── context-map.md
│   ├── lock-policy.yaml
│   ├── presets/
│   └── global/
│
├── global/                           # 공통 skill/template 자산
├── custom-agents/                    # 회사 커스텀 에이전트 정의
├── omc-integration/                  # OMC 연동 자산
└── docs/
```

## 핵심 구분

### 1. 루트 `skills/`

사용자가 자연어로 직접 호출하는 하네스 스킬이다. planner bundle 안의 skill과 다르게, 이 위치의 스킬은 설치 흐름과 운영 제어를 담당한다.

### 2. `teams/backend/` 등 로컬 팀 자산

backend 같은 개발 팀은 현재 프로젝트에 `.ai-harness/teams/{team}` 형태로 복사되어 사용된다. 즉, 레포 안 `teams/{team}`는 템플릿 소스이고 실제 사용 위치는 프로젝트 내부다.

### 3. `teams/planning/`의 runtime별 번들 구조

planning은 runtime별 실제 배포 번들을 분리해서 관리한다.

- `teams/planning/bundle-codex/`
  - Codex용 planner bundle
  - `AGENTS.md`, `agents/*.toml`, `skills/`, `planner-templates/`를 포함한다
- `teams/planning/bundle-claude/`
  - Claude Code용 planner bundle
  - `CLAUDE.md`, `agents/*.md`, `skills/`, `planner-templates/`를 포함한다

## planner bundle 상세

### `teams/planning/bundle-codex/`

Codex 전용 실제 배포 번들이다.

- `AGENTS.md`
- `agents/*.toml`
- `skills/*`
- `planner-templates/*`

### `teams/planning/bundle-claude/`

Claude Code 전용 실제 배포 번들이다.

- `CLAUDE.md`
- `agents/*.md`
- `skills/*`
- `planner-templates/*`

`install-planner-bundle.mjs`는 선택된 runtime에 따라 해당 번들을 직접 설치한다.

## 설치 스코프

| 대상 | 설치 스코프 | 실제 설치 위치 |
|------|-------------|----------------|
| backend | 프로젝트 로컬 | `./.ai-harness/teams/backend` |
| planning | 전역 | `~/.codex` 또는 `~/.claude` |

즉, team 개념은 유지하지만 설치 스코프는 팀 성격에 따라 다르다. planning은 team이면서도 전역 설치형이다.

## 관련 스크립트

| 스크립트 | 역할 |
|---------|------|
| `scripts/copy-team-resources.mjs` | backend 등 로컬 팀 자산 복사 |
| `scripts/install-planner-bundle.mjs` | planner bundle inspect/install, runtime별 번들 선택, 백업 처리 |
| `scripts/register-hooks.mjs` | 보안 Hook 등록/해제 |

## 유지보수 원칙

1. planner 관련 새 공식 자산은 `teams/planning/bundle-codex/` 또는 `teams/planning/bundle-claude/`에 추가한다.
2. Codex와 Claude의 포맷 차이는 설치 시점 변환보다 각 runtime 번들에서 명시적으로 관리한다.
