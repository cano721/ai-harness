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
│   │   ├── README.md                 # legacy와 bundle 역할 설명
│   │   ├── CLAUDE.md                 # legacy planning context
│   │   ├── skills/                   # legacy planning draft skill
│   │   └── bundle/                   # planner mode의 실제 설치 소스
│   │       ├── manifest.json         # bundle 설명, 제외 목록, 지원 runtime
│   │       ├── common/               # runtime 공통 planner 자산
│   │       │   ├── AGENTS.md
│   │       │   ├── agents/
│   │       │   └── skills/
│   │       ├── runtimes/             # codex.json / claude.json
│   │       └── templates/            # policy template 등 planner 보조 파일
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

### 3. `teams/planning/`의 이중 구조

planning은 다른 팀과 다르게 두 층으로 관리한다.

- `teams/planning/CLAUDE.md`, `teams/planning/skills/`
  - 기존 초안 자산
  - 아직 검토가 끝나지 않은 legacy source
  - planner mode의 설치 소스로 사용하지 않는다
- `teams/planning/bundle/`
  - planner mode의 공식 설치 소스
  - Codex와 Claude Code 양쪽에 맞춰 전역 설치된다

## planner bundle 상세

### `teams/planning/bundle/common/`

planner mode가 실제로 설치하는 공통 자산이다.

- `AGENTS.md`
- `agents/*.toml`
- `skills/*`

여기에는 PRD, user story, Jira, checklist 같은 planner 작업 스킬과, 바이브코딩까지 고려한 agent 설정이 함께 들어간다.

### `teams/planning/bundle/runtimes/`

runtime adapter 설정이다.

- `codex.json`
  - 대상: `~/.codex`
  - 컨텍스트 파일: `AGENTS.md`
- `claude.json`
  - 대상: `~/.claude`
  - 컨텍스트 파일: `CLAUDE.md`
  - 문서/경로 표현을 Claude 방식으로 치환

`install-planner-bundle.mjs`는 이 설정을 읽어 같은 공통 자산을 Codex/Claude 규칙에 맞게 설치한다.

### `teams/planning/bundle/templates/`

planner 전용 보조 템플릿이다. 현재는 정책 문서 초안 작성을 위한 `policy-template.md`가 포함된다.

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
| `scripts/install-planner-bundle.mjs` | planner bundle inspect/install, runtime 변환, 백업 처리 |
| `scripts/register-hooks.mjs` | 보안 Hook 등록/해제 |

## 유지보수 원칙

1. planner 관련 새 공식 자산은 `teams/planning/bundle/`에 추가한다.
2. `teams/planning/skills/`와 `teams/planning/CLAUDE.md`는 legacy로 유지하며, 검토 전까지 shipping source로 쓰지 않는다.
3. Codex/Claude 차이는 공통 자산을 복제해서 관리하지 말고 `runtimes/*.json`의 변환 규칙으로 흡수한다.
