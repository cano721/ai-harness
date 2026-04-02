# AI Harness — 팀별 AI 에이전트 셋업 시스템

> [English README](README.en.md)

## 목차

- [설계 철학](#설계-철학)
- [아키텍처](#아키텍처)
- [유저 플로우](#유저-플로우)
- [빠른 시작](#빠른-시작)
- [스킬 목록](#스킬-목록)
- [팀 프로필](#팀-프로필)
- [Hook 시스템 (Guard)](#hook-시스템)
- [컨벤션 시스템 (Guide)](#컨벤션-시스템-guide)
- [Task Workflow 시스템 (Gear)](#task-workflow-시스템-gear)
- [OMC 연동](#omc-연동-oh-my-claudecode)
- [Init 후 프로젝트 구조](#init-후-프로젝트-구조)
- [설계 문서](#설계-문서)
- [요구사항](#요구사항)

AI Harness는 로컬 AI 런타임 위에 얹는 경량 control plane입니다. 플러그인을 설치하고 `/harness-init`을 실행하면, 팀에 맞는 AI 작업 환경을 자동으로 구성합니다.

- **backend** 프로젝트를 분석하여 팀에 맞는 보안 Hook, 코드 컨벤션, 스킬을 자동으로 구성합니다.
- **planning** 팀은 현재 runtime이 Codex인지 Claude Code인지 감지한 뒤 글로벌 planner bundle을 세팅합니다.

세팅이 끝나면 하네스는 빠지고, Claude Code / Codex 에이전트가 설치된 규칙과 스킬을 사용합니다. 즉, 실행 주체는 에이전트이고 하네스는 가드레일과 프로젝트 지도를 제공하는 control plane 역할에 머뭅니다.

## 설계 철학

| 철학 | 설명 |
|------|------|
| **추천 + 선택** | 베스트 프랙티스를 추천하고, 팀이 선택한다 |
| **셋업 후 빠지기** | init 시 세팅해주고, 이후엔 Claude Code가 동작. 하네스는 개입하지 않는다 |
| **최소 강제, 최대 안내** | 강제는 보안 Hook 5개뿐. 나머지는 컨벤션과 워크플로우로 안내한다 |
| **팀 자율성** | 각 팀이 자기 도메인, 컨벤션, 스킬을 자유롭게 구성한다 |

## 아키텍처

### Three-Pillar Architecture

Guard(안전) + Guide(컨벤션) + Gear(AI 최적화) 3축으로 구성됩니다. 이 3축은 각각 실행 차단, 작업 방향 제시, 런타임 최적화에 대응하며 함께 AI 작업의 운영면을 담당합니다.

![Three-Pillar Architecture](docs/images/1-three-pillar.png)

| 축 | 역할 | 구성 요소 |
|----|------|----------|
| **Guard** | 보안 — 위험 명령 차단, 시크릿 유출 방지 | 5개 글로벌 Hook |
| **Guide** | 컨벤션 — 팀별 코드 스타일, 아키텍처 규칙 | CLAUDE.md, convention-*.md, context-map.md |
| **Gear** | AI 최적화 — 프로젝트 맞춤 에이전트/스킬/워크플로우 | Project-Aware Agents, Domain Skills, Task Workflows |

## 유저 플로우

### 초기화 (`/harness-init`)

팀에 따라 다른 경로로 초기화됩니다.

![Init Flow](docs/images/4-init-flow.png)

| 경로 | 단계 |
|------|------|
| **공통 (개발팀)** | 글로벌 보안 Hook 등록 → 프로젝트 분석 |
| **Planning** | Runtime 감지 → Planner Bundle 설치 → AGENTS.md/CLAUDE.md 변환 → 26+ Skills 등록 |
| **Backend** | CLAUDE.md 최적화 → 컨벤션 생성 → 팀 Hook → context-map → 맞춤 에이전트 → Task Workflow → 검증 |
| **Frontend** | 컨벤션 생성 → 팀 Hook 등록 |

### 일상 사용

초기화 후 평소처럼 에이전트에서 작업하면 3축이 자동으로 동작합니다.

```
개발자: "지원자 목록 조회 API 만들어줘"

[Harness] task-workflow 매칭 → implement-feature
    ↓
[Harness] architect 에이전트: 요구사항 분석 + 설계
    ↓
[Guide] developer 에이전트: convention-backend.md 참고하여 코드 생성
    → /api/v1/applicants (버저닝 적용)
    → CommonResponse<T> (공통 응답 포맷)
    ↓
[Guard] Hook이 코드 작성 시 자동 검증
    → SELECT * 사용? → 차단 + "컬럼을 명시하세요"
    → 시크릿 하드코딩? → 차단 + "환경 변수 사용하세요"
    ↓
[Harness] reviewer 에이전트: 컨벤션 + 아키텍처 리뷰 (self-review 방지)

```

```
기획자: "jira NMRS-15863 보여줘"
    ↓
planner bundle의 jira skill 사용
    ↓
"create-prd" / "user-stories" / "jira-checklist" 같은 스킬로 후속 작업
```

### 관리 (필요할 때)

```
"backend 팀 추가해줘"    → /harness-team
"왜 차단됐어?"           → /harness-rules
"하네스 상태 보여줘"     → /harness-status
```

## 빠른 시작

### 설치

```bash
# 마켓플레이스 등록
claude plugin marketplace add https://github.com/cano721/ai-harness.git

# 플러그인 설치
claude plugin install ai-harness
```

### 초기화

개발 팀:

```
"하네스 초기화해줘"
또는
"이 프로젝트 분석해서 컨벤션 만들고 보안 설정해줘"
```

기획 팀:

```
"planning 팀으로 하네스 초기화해줘"
또는
"기획자 모드로 글로벌 planner bundle 설치해줘"
```

초기화 흐름:

1. **팀 선택** — planning / backend 등 팀 선택
2. **planning** — 현재 runtime 감지 후 `teams/planning/bundle/`을 글로벌 위치에 설치
   - 설치 전 `inspect`로 runtime, 대상 경로, 설치 개수를 먼저 보여줍니다.
   - 설치 중 텍스트 자산은 runtime에 맞게 자동 변환됩니다. 예: `AGENTS.md → CLAUDE.md`, `~/.codex → ~/.claude`
3. **backend** — 보안 Hook 확인 후 현재 프로젝트 분석 및 로컬 `.ai-harness/` 세팅
4. **완료 요약** — 설치된 자산 수, readiness, 다음 추천 명령 표시

### 상태 확인

```
"하네스 상태 보여줘"
```

현재 적용된 팀, Hook, 오늘의 이벤트 요약을 표시합니다.

### 문제 해결

왜 차단됐는지 알고 싶을 때:

```
"왜 차단됐어?"
```

## 스킬 목록

7개 스킬로 하네스를 완전히 제어합니다. 모두 자연어로 호출 가능합니다.

| 스킬 | 사용 예시 | 기능 |
|------|----------|------|
| **harness-init** | "하네스 초기화해줘" | planning은 글로벌 planner bundle 설치, backend는 프로젝트 로컬 하네스 세팅 |
| **harness-status** | "하네스 상태 보여줘" | 설정 상태 + 차단 현황 + 진단 + 미결정 사항 |
| **harness-rules** | "적용된 규칙 보여줘" | 현재 보안 규칙 목록, 마지막 차단 사유 |
| **harness-team** | "backend 팀 추가해줘" | 로컬 프로젝트 팀 추가/제거, 컨벤션 수정 |
| **harness-exclude** | "이 프로젝트 제외해줘" | 글로벌 하네스 제외 프로젝트 관리 |
| **harness-metrics** | "메트릭 분석해줘" | 에이전트 작업 효율 메트릭 분석 + 개선 제안 |
| **harness-scaffold** | "CRUD 만들어줘" | 컨벤션 기반 코드 보일러플레이트 생성 |

## 팀 프로필

현재 **Backend 팀**과 **Planning 팀(beta)** 이 제공됩니다. 다른 팀은 고도화 후 순차 제공 예정입니다.

![Team Structure](docs/images/3-team-structure.png)

### 제공 중

| 팀 | 핵심 역할 | 컨벤션 | Hook | 스킬 |
|----|---------|--------|------|------|
| **BE** | API/DB 개발 | 패키지 구조, DTO 네이밍, REST 규칙 | sql-review, api-compat, entity-review, coverage-check | entity, migration, api-design, convention, agent-map |
| **Planning** | PRD, Jira, 유저 스토리, 체크리스트 | 글로벌 AGENTS/CLAUDE + planner bundle | 없음 | create-prd, user-stories, jira, jira-checklist 포함 26개 skill + 16개 agent |

### 준비 중 (향후 제공)

| 팀 | 핵심 역할 | 상태 |
|----|---------|------|
| FE | React/Vue 개발 | 준비 중 |
| QA | 테스트/검증 | 준비 중 |
| DevOps | 인프라/배포 | 준비 중 |
| 디자인 | 디자인 시스템 | 준비 중 |

개발 팀은 초기화 후 다음 파일을 받습니다:

- `.ai-harness/teams/{team}/skills/convention-{team}.md` — 팀별 코드 스타일
- `.ai-harness/teams/{team}/CLAUDE.md` — 팀별 최소 규칙 + 스킬 참조

planning 팀은 로컬 프로젝트 대신 `teams/planning/bundle/`을 설치 소스로 사용합니다:

- `teams/planning/skills/` 와 `teams/planning/CLAUDE.md` 는 아직 검토 중인 legacy planning 자산
- `teams/planning/bundle/common/` 은 실제 설치되는 planner bundle
- `teams/planning/bundle/runtimes/` 는 Codex/Claude별 파일명과 경로 매핑 규칙
- `teams/planning/README.md` 는 legacy와 bundle의 역할 분리를 설명하는 planner 전용 안내서

## Hook 시스템

### PreToolUse / PostToolUse

Claude Code는 도구(Bash, Write, Edit 등)를 실행할 때 Hook을 호출합니다:

| 트리거 | 시점 | 용도 |
|--------|------|------|
| **PreToolUse** | 도구 실행 **직전** | 위험 명령 차단, SQL 검증, 시크릿 감지 |
| **PostToolUse** | 도구 실행 **직후** | 테스트 커버리지 확인, 번들 사이즈 체크 |

Hook이 `exit 0`이면 허용, `exit 2`이면 차단됩니다. 차단 시 stderr 메시지가 Claude에게 전달되어 대안을 안내합니다.

### Hook 실행 흐름

![Hook System](docs/images/2-hook-system.png)

### 글로벌 Hook (모든 팀에 적용)

5개 글로벌 Hook이 자동으로 등록됩니다:

**block-dangerous.sh** — 위험 패턴 차단

- `rm -rf` (rm과 -r, -f 플래그 조합)
- `DROP TABLE/DATABASE/INDEX`
- `TRUNCATE TABLE`
- `git push --force` (`--force-with-lease`는 허용)
- `chmod 777`
- `sudo` 명령

차단 시 안내: "BLOCKED: [사유]. 대안: [권장 방법]"

**secret-scanner.sh** — 민감 정보 유출 방지

- API 키, 암호, 개인정보 감지
- 커밋 전 자동 마스킹
- 시크릿 문자열을 `.env` 등에 저장하도록 안내

**check-architecture.sh** — 아키텍처 경계 위반 검증

- 의존성 방향 위반 감지 (Types/Entity → Config → Repository → Service → Controller)
- 하위 레이어에서 상위 레이어 import 시 차단 + 대안 안내

![Layer Enforcement](docs/images/5-layer-enforcement.png)

**guardrails-check.sh** — 변경 범위 제한

- 한 번에 변경 가능한 파일 수 제한 (config.yaml의 `max_files_changed`)
- 실행 시간 제한 초과 감지
- 과도한 변경 시 차단 + 분할 작업 안내

**infra-change-review.sh** — 인프라 변경 안전 검증

- `terraform destroy`, `kubectl delete ns`, `aws` 삭제 명령 차단
- 인프라 파괴 명령 실행 전 확인 요구
- 안전한 대안 제시

### 팀별 Hook

팀 추가 시 팀별 Hook도 함께 등록됩니다. 예를 들어 FE팀은:

- `bundle-size.sh` — 번들 사이즈 증가 감지
- `lighthouse.sh` — 성능 메트릭 수집

차단된 경우:

```
"왜 차단됐어?"
```

최근 차단 사유를 확인하세요.

## Hook 예시 시나리오

### 시나리오 1: rm -rf 시도

```
Claude: "모든 로그 파일을 삭제합니다"
bash: rm -rf logs/

Hook 응답:
BLOCKED: rm -rf 명령은 하네스 보안 정책에 의해 차단됩니다.
대안: 개별 파일 삭제 또는 rimraf 사용
```

### 시나리오 2: 민감 정보 감지

```
Claude: "DB 연결 정보를 .env에 저장합니다"
PLAINTEXT: DATABASE_URL="postgres://user:password@host"

Hook 응답:
BLOCKED: 평문 암호가 감지되었습니다.
대안: 환경 변수로 로드하거나 secrets.json 사용
마스킹됨: DATABASE_URL="postgres://user:***@host"
```

### 시나리오 3: 팀별 Hook

```
Claude: "React 컴포넌트를 작성합니다"
번들 크기: 450KB → 480KB (+30KB)

Hook 응답:
경고: 번들 크기가 30KB 증가했습니다 (한도: 100KB).
분석: 새 라이브러리 @emotion/core (25KB)
권장: 동적 임포트 고려
```

## 컨벤션 시스템 (Guide)

Guard가 "하지 마라"라면, Guide는 **"이렇게 해라"**입니다. 프로젝트 CLAUDE.md에 주입된 지시에 따라 Claude Code가 컨벤션 문서를 참고하여 코드를 생성합니다.

### 동작 방식

```
/harness-init 실행
  → 프로젝트 코드 분석 (Entity, API 패턴, 네이밍 등)
  → .ai-harness/teams/backend/skills/convention-backend.md 생성
  → 프로젝트 CLAUDE.md에 "convention-backend.md를 참고하라" 주입
```

이후 Claude Code가 코드 생성 시 자동으로 컨벤션을 따릅니다:

```
개발자: "지원자 목록 조회 API 만들어줘"
  → Claude: convention-backend.md 참고
  → /api/v1/applicants (버저닝 적용)
  → CommonResponse<T> (공통 응답 포맷)
  → SELECT 컬럼 명시 (SELECT * 금지)
```

### 컨벤션 파일 구성

| 파일 | 역할 |
|------|------|
| `.ai-harness/teams/{team}/skills/convention-{team}.md` | 팀별 코드 스타일 (패키지 구조, DTO 네이밍, REST 규칙 등) |
| `.ai-harness/context-map.md` | 프로젝트 지도 (도메인, 엔트리포인트, 패턴) |
| `.ai-harness/teams/{team}/CLAUDE.md` | 팀별 규칙 + 스킬 참조 |

### Guard vs Guide

| | Guard (Hook) | Guide (컨벤션) |
|---|---|---|
| **방식** | 셸 스크립트 → exit 2로 차단 | CLAUDE.md → 컨벤션 문서 참조 |
| **강제력** | 시스템 레벨 (100% 차단) | 프롬프트 레벨 (Claude가 따름) |
| **시점** | 도구 실행 직전 (PreToolUse) | 코드 생성 시 |

## Task Workflow 시스템 (Gear)

Guard가 "막고", Guide가 "안내"한다면, Gear는 **"프로젝트를 이해하고 잘 해라"**입니다. 프로젝트 맞춤 에이전트와 작업 유형별 워크플로우를 제공합니다.

### 프로젝트 맞춤 에이전트

init 시 프로젝트 코드를 분석하여 3개 전문 에이전트를 생성합니다:

| 에이전트 | 역할 |
|---------|------|
| `{project}-developer` | 도메인 맥락 + 컨벤션 내장 개발 에이전트 |
| `{project}-reviewer` | 경계면 검증 + 컨벤션 체크 리뷰 에이전트 |
| `{project}-architect` | 도메인 관계도 + 레이어 구조 설계 에이전트 |

### 작업 유형별 워크플로우

작업 요청에 따라 적절한 에이전트 조합과 실행 순서가 결정됩니다:

| 작업 | 워크플로우 | 흐름 |
|------|-----------|------|
| "기능 만들어줘" | **implement-feature** | architect 분석 → developer 구현 → reviewer 리뷰 → 수정 |
| "버그 수정해줘" | **fix-bug** | developer 진단 → developer 수정 → reviewer 리뷰 → 회귀확인 |
| "리팩토링해줘" | **refactor** | architect 계획 → developer 구현 → reviewer 검증 |
| "코드 리뷰해줘" | **code-review** | reviewer 단독 리뷰 |
| "설계해줘" | **design** | architect 분석 → architect 설계 → reviewer 검토 |

### Self-Review 방지

모든 워크플로우의 review 단계는 구현 단계와 **다른 에이전트**가 실행합니다:

| 실행 방식 | 분리 수준 |
|----------|----------|
| **기본 (Skill)** | Agent 도구로 서브에이전트 호출 → 컨텍스트 분리 |
| **강화 (OMC team)** | 별도 tmux pane/프로세스 → 완전 분리 |

## OMC 연동 (oh-my-claudecode)

oh-my-claudecode와 함께 사용하면 ai-harness의 기능이 강화됩니다.

![OMC Integration](docs/images/6-omc-integration.png)

### Hook 체이닝

`harness-hook-bridge.js`로 OMC Hook과 Harness Hook을 동시에 평가합니다. 양쪽 모두 통과해야 실행이 허용됩니다.

### Task Workflow 강화

| 기능 | OMC 없이 | OMC 있을 때 |
|------|---------|------------|
| **에이전트 분리** | 서브에이전트 (컨텍스트 분리) | 별도 tmux 프로세스 (완전 분리) |
| **반복 수정** | 수동 재요청 | ralph 모드 (자동 루프) |
| **병렬 실행** | 순차 진행 | team/ultrawork 모드 |
| **전체 자동화** | Skill이 단계별 진행 | autopilot 모드 |

## Init 후 프로젝트 구조

`/harness-init`을 실행하면 프로젝트에 다음 파일이 생성됩니다.

```
my-project/
├── .ai-harness/
│   ├── config.yaml                    # 프로젝트 설정 (스택, 도메인, 팀)
│   ├── context-map.md                 # 프로젝트 지도 (도메인, 엔트리포인트, 패턴)
│   ├── teams/backend/
│   │   ├── CLAUDE.md                  # 팀 규칙 + 스킬 참조
│   │   └── skills/
│   │       └── convention-backend.md  # 프로젝트 맞춤 컨벤션 (Guide)
│   ├── task-workflows/                # 작업 유형별 워크플로우 (Gear)
│   │   ├── implement-feature.yaml
│   │   ├── fix-bug.yaml
│   │   ├── refactor.yaml
│   │   ├── code-review.yaml
│   │   └── design.yaml
│   └── agents/                        # 프로젝트 맞춤 에이전트 원본
│
├── .claude/
│   ├── settings.json                  # 보안 Hook 등록 (Guard)
│   └── agents/                        # Claude Code에서 사용하는 에이전트
│       ├── {project}-developer.md     # 도메인 맥락 + 컨벤션 내장
│       ├── {project}-reviewer.md      # 경계면 검증 + 컨벤션 체크
│       └── {project}-architect.md     # 도메인 관계도 + 레이어 설계
│
└── CLAUDE.md                          # <!-- harness:start --> 구간에 규칙 주입
```

Planning 팀은 프로젝트가 아닌 글로벌에 설치됩니다:

```
~/.claude/  (또는 ~/.codex/)
├── CLAUDE.md (또는 AGENTS.md)    # Planner bundle 컨텍스트
├── agents/                       # 16개 planner 에이전트
└── skills/                       # 26+ planner 스킬 (jira, create-prd 등)
```

## 설계 문서

초기 기획 시 작성된 설계 문서입니다. 최신 구조는 이 README를 참고하세요.

- **기획 문서 28개**: [docs/00-index.md](docs/00-index.md) — 아키텍처, init 플로우, 팀 커스터마이징, OMC 연동 등
- **상세 설계(SDD) 8개**: [docs/sdd/](docs/sdd/) — 시스템 개요, 모듈 설계, Hook 엔진, 기술 스택 등

## 요구사항

- **Node.js**: >= 18
- **Git**: 저장소 필수
- **Claude Code**: 플러그인으로 등록
- **OS**: macOS, Linux (Windows는 WSL 필수)

> [English README](README.en.md)

## 라이선스

MIT

## 저자

cano721
