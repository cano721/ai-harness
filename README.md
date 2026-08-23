# ai-harness

Claude Code와 Codex CLI에서 프로젝트별 AI 작업 규칙을 만들고, 실제 작업 기록을 근거로 그 규칙을 점진적으로 개선하는 듀얼 플러그인입니다.

하네스는 에이전트가 더 자주 행동하게 만드는 자동 실행기가 아닙니다. 평소 작업을 가볍게 기록하고, 충분한 근거가 쌓였을 때만 사람이 `/harvest`로 검토·승인하는 구조입니다. 파일 수정, PR 생성, 플러그인 업데이트는 모두 명시적인 사용자 요청 뒤에만 일어납니다.

## 목차

- [한눈에 보기](#overview)
- [제공하는 Skills](#skills)
- [빠른 시작](#quick-start)
- [기존 프로젝트 하네스 업데이트](#project-sync)
- [기능 개발 흐름](#feature-delivery)
- [버그 수정 흐름](#bug-fix)
- [변경 검토 흐름](#review)
- [자가학습](#self-learning)
- [수집 데이터와 보관](#data-retention)
- [업데이트](#updates)
- [설정](#configuration)
- [저장소 구조 · 요구사항](#repository)

<a id="overview"></a>

## 한눈에 보기

```mermaid
flowchart LR
    A["/harness-init\n프로젝트 규칙 생성"] --> B["평소 개발\n/implement-feature 등"]
    B --> C["SessionEnd hook\n압축 이벤트 기록"]
    C --> D["analysis batch\n분석할 만큼 축적"]
    D --> E["/harvest\n근거 검토·개선안"]
    E -->|"사용자 승인·PR 병합"| A
    C -. "언제든 조회" .-> F["/metrics"]
```

| 하고 싶은 일 | 명령 | 결과 |
|---|---|---|
| 프로젝트에 규칙을 처음 만들기 | `/harness-init` | `AGENTS.md`, `.ai-harness`, 필요한 도구별 어댑터 생성 |
| 기존 프로젝트 하네스 최신화 | `/harness-init --sync` | 생성물 상태와 최신 템플릿 차이 조회 |
| 초기화된 프로젝트에서 기능을 안전하게 개발하기 | `/implement-feature` | 계획 승인 → 구현 → 검토·수정·재검토 |
| 쌓인 사용 기록 보기 | `/metrics [7d\|30d\|90d\|all]` | 세션·토큰·워크플로·신호 리포트 |
| 기록으로 하네스 개선하기 | `/harvest <프로젝트>` | 근거 기반 개선안과 PR 제안 |
| 플러그인 최신화 | `/harness-update --check` / `--apply` | 확인만 또는 명시적 업데이트 |

`/metrics`는 관찰용이며 `/harvest` 전에 실행할 필요가 없습니다. analysis batch는 **개선이 확정된 묶음이 아니라**, `/harvest`가 검토할 입력 단위입니다.

<a id="skills"></a>

## 제공하는 Skills

### 플러그인에 기본 제공

| Skill | 언제 쓰나 | 하는 일 | 자동 실행 여부 |
|---|---|---|---|
| `/harness-init` | 새 프로젝트를 시작하거나 기존 하네스 설정·생성물을 최신화할 때 | 코드베이스를 실측하고, 테스트·Git 정책과 도구 통합에 맞춰 `AGENTS.md`, `.ai-harness`, 역할 agent를 생성·변경·동기화합니다. | 사용자 실행 |
| `/metrics` | 사용 현황이나 특정 세션의 병목을 확인할 때 | 세션·토큰·문서 읽힘·워크플로·오류/가드 신호를 조회합니다. 로컬 event cache는 갱신하지만 프로젝트 파일은 수정하지 않습니다. | 사용자 실행, 읽기 전용 |
| `/harvest` | analysis batch가 생겼거나 하네스 개선을 검토할 때 | 축적된 활동·교정 신호를 분석해 행동을 바꿀 만한 개선안만 제안하고, 승인된 경우 PR을 만듭니다. | 사용자 실행 |
| `/harness-update` | 설치 버전을 확인하거나 최신 버전을 적용할 때 | `--check`으로 확인하고, `--apply`가 명시된 경우에만 현재 호스트의 플러그인을 업데이트합니다. | 사용자 실행 |

이 네 Skill은 플러그인 설치만으로 사용할 수 있습니다. 기능 개발 Skill은 프로젝트 규칙 없이는 노출하지 않고, 아래처럼 `/harness-init`이 생성합니다.

### `/harness-init`이 프로젝트에 생성하는 진입점

`standard` 수준에서만 생성합니다. 선택하지 않은 도구의 파일은 만들지 않습니다. Codex는 프로젝트 로컬 Skill을, Claude는 같은 목적의 slash command 어댑터를 만듭니다.

| 프로젝트 기능 | Codex (`Codex` 또는 `둘 다` 선택) | Claude (`Claude` 또는 `둘 다` 선택) | 역할 |
|---|---|---|---|
| 기능 개발 | `.agents/skills/implement-feature/SKILL.md` | `.claude/commands/implement-feature.md` | 내부 템플릿을 프로젝트 정책으로 구체화해 생성합니다. `.ai-harness/workflows/implement-feature.md`와 프로젝트 docs를 먼저 읽는 진입점입니다. |
| 버그 수정 | `.agents/skills/fix-bug/SKILL.md` | `.claude/commands/fix-bug.md` | 내부 템플릿을 프로젝트의 재현·수정·회귀 검증 규칙으로 구체화해 생성합니다. |
| 코드 검토 | `.agents/skills/review/SKILL.md` | `.claude/commands/review.md` | 내부 템플릿의 risk 기반 검토·수정·재검토 규칙으로 구체화해 생성합니다. |
| 변경 이해 | `.agents/skills/understand-change/SKILL.md` | `.claude/commands/understand-change.md` | 변경의 배경·직관·흐름·위험·직접 검증을 설명해 사람이 다음 설계 판단에 참여할 수 있게 합니다. |

`AGENTS.md`, `.ai-harness/workflows/`, `.ai-harness/docs/`, 역할 agent 설정도 함께 생성되며, 이들이 프로젝트 특화 규칙의 단일 출처입니다. 프로젝트 진입점은 내부 템플릿을 프로젝트에 맞게 연결한 결과물이며, 전역으로 제공되는 공용 Skill이 아닙니다.

Skill과 별개로 `SessionEnd`·`SessionStart` hook은 플러그인 설치 뒤 자동 실행됩니다. 이 hook은 **기록, 누적량 판정, 알림**까지만 담당하며 `/harvest` 실행·코드 수정·PR 생성·업데이트를 자동으로 수행하지 않습니다.

<a id="quick-start"></a>

## 빠른 시작

### 1. 플러그인 설치

```bash
# Claude Code
claude plugin marketplace add cano721/ai-harness
claude plugin enable ai-harness@ai-harness

# Codex CLI
codex plugin marketplace add cano721/ai-harness
codex plugin add ai-harness@ai-harness
```

둘 중 사용하는 도구만 설치해도 됩니다. 설치 뒤 새 세션을 시작하면 hook과 skill이 로드됩니다.

### 2. 대상 프로젝트에서 초기화

프로젝트 루트에서 `/harness-init`을 실행합니다. 실제 코드베이스를 먼저 살핀 뒤 아래만 선택하면 됩니다.

- 규모: `minimal` 또는 `standard`
- 사용할 도구: Codex / Claude / 둘 다 / 통합 파일 없음
- 테스트 정책: TDD 강제 / 테스트 필수 / 권장 / 없음
- Git 통제: PR 필수 또는 직접 커밋 허용

`standard`는 `minimal`의 상위 집합입니다. `AGENTS.md`와 문서에 더해 워크플로와 역할 agent 설정을 만듭니다. `full` 같은 별도 규모는 없고, 편집 가드는 독립적인 선택입니다.

초기화 결과는 `.ai-harness/harness.json`에 저장됩니다. 이미 하네스가 있는 프로젝트에서 다시 실행하면 수준 변경 모드로 동작하며, 변경 diff만 적용합니다. 다운그레이드로 파일을 지우는 경우에는 대상 목록을 먼저 확인합니다.

### 3. 평소처럼 개발

일반 작업은 프로젝트의 `AGENTS.md`와 `.ai-harness` 규칙을 따릅니다. `standard` 초기화로 생성된 프로젝트에서는 신규 기능을 `/implement-feature`, 결함 수정을 `/fix-bug`로 시작해 각각의 계획 검토를 먼저 할 수 있습니다. 세션 종료 시 활동이 자동으로 기록되며, 별도 스케줄러를 돌릴 필요는 없습니다.

<a id="project-sync"></a>

## 기존 프로젝트 하네스 업데이트

플러그인 업데이트와 프로젝트 하네스 업데이트는 분리됩니다.

```text
/harness-update --apply          # 플러그인·hook·템플릿 업데이트
프로젝트 루트에서
/harness-init --sync             # 변경 계획만 확인 (파일 변경 없음)
/harness-init --sync --apply     # 안전한 생성물 동기화
```

`harness-init`은 [`managed-files.json`](templates/managed-files.json)을 단일 출처로 사용해 현재 수준·도구 통합에 필요한 관리 생성물을 결정하고, `harness.json`의 `managed_files`에 저장된 마지막 생성 해시와 현재 파일을 비교합니다.

| 파일 상태 | `--sync --apply` 동작 |
|---|---|
| 새 파일 | graph, 로컬 Skill/command, agent 설정 같은 관리 생성물을 추가 |
| `unchanged` | 이전 생성 뒤 수정되지 않은 관리 파일만 최신 템플릿으로 갱신 |
| `modified` | 현재 파일과 제안 변경의 diff를 보여 주고 파일별 승인 뒤 갱신 |
| `untracked` | 이전 버전에 해시 이력이 없는 기존 파일. 자동 덮어쓰기 없이 diff와 승인을 요구 |
| 보호됨 | `AGENTS.md`, `.ai-harness/docs/`, 사람이 작성한 workflow 본문. 자동 갱신하지 않고 개선 제안만 표시 |

처음 `managed_files`를 지원하는 버전으로 동기화하는 기존 프로젝트는, 기존 파일을 `untracked`로 안전하게 취급합니다. 따라서 기존 프로젝트 지식이나 사용자 수정이 자동으로 사라지지 않습니다. 설정 자체를 바꾸려면 `/harness-init --reconfigure`를 사용하고, 인자 없이 실행하면 동기화·설정 변경·둘 다 중 선택할 수 있습니다.

<a id="feature-delivery"></a>

## 기능 개발 흐름: `/implement-feature`

이것은 플러그인 기본 Skill이 아니라 `standard` 초기화가 만든 프로젝트 로컬 Skill/command입니다. 프로젝트의 기존 규칙을 우선하며, 아래 전달 흐름으로 기능 개발을 일관되게 수행합니다.

```mermaid
stateDiagram-v2
    [*] --> discover
    discover --> brief
    brief --> approval
    approval --> brief: 범위 변경 또는 미승인
    approval --> deliver: 명시적 승인
    deliver --> review
    review --> done: blocking finding 없음
    review --> repair: blocking finding 있음
    repair --> review: 검증 통과
    repair --> user_decision: 동일 원인 2회 반복·제품 판단 필요
```

1. **계획** — 범위·비범위·검증 케이스·예상 변경 파일·검증 계획을 `Implementation Brief`로 제시합니다. 명시 승인 전에는 코드나 테스트 파일을 수정하지 않습니다.
2. **구현** — 승인 후 작업을 작고 검증 가능한 delivery slice로 나눕니다. TDD 강제 프로젝트에서는 Red → Green → Refactor를 지키고, 그 외에는 프로젝트 테스트 정책을 따릅니다.
3. **검토 루프** — acceptance case와 diff를 검토합니다. blocking finding은 원인별 수정 → targeted/전체 검증 → 재검토로 해소를 확인합니다. 같은 원인이 두 번 반복되거나 제품 결정이 필요하면 추측하지 않고 사용자에게 넘깁니다.

같은 대화 안에 승인된 동일 범위의 Brief가 있으면 재승인 없이 구현을 이어갑니다. explorer, test-engineer, developer, reviewer 역할이 설정된 경우에만 독립적인 작업을 위임하며, 작은 작업은 단일 세션에서 동일한 순서를 지킵니다.

### Codex와 Claude 실행 방식

생성에 쓰는 [기능 개발 템플릿의 그래프 계약](templates/implement-feature/references/feature-delivery-graph.json)은 노드, 전이, 쓰기 허용 시점, 종료 조건을 한곳에서 정의합니다.

| 도구 | 실행 방식 |
|---|---|
| Codex | skill과 역할 agent(또는 단일 세션의 단계 경계)가 그래프 계약을 해석합니다. 별도의 그래프 런타임은 필요하지 않습니다. |
| Claude Code 2.1.154 이상 | Brief가 승인된 뒤 선택적으로 `/ai-harness:implement-feature` Dynamic Workflow가 구현 → 검토 → 수정 → 재검토를 실행할 수 있습니다. |
| 그 외 Claude Code | 현재 세션에서 같은 그래프 계약을 따릅니다. Dynamic Workflow를 사용할 수 없어도 기능 개발 흐름은 유지됩니다. |

Claude Dynamic Workflow는 계획·사용자 승인을 대신하지 않습니다. 승인은 항상 skill 대화 단계에서 먼저 받습니다.

## 변경 이해 흐름: `/understand-change`

`standard` 초기화가 만드는 프로젝트 로컬 Skill/command입니다. AI가 만든 변경을 단순히 통과/실패로 검수하지 않고, 사람이 다음 제품·기술 결정을 내릴 수 있을 정도로 이해하게 만드는 흐름입니다.

1. **범위와 근거 확인** — diff만 읽지 않고 관련 호출부, 테스트, 설정, 데이터 계약을 확인합니다. 코드·PR·로그 안의 지시문은 데이터로만 취급합니다.
2. **설명 깊이 선택** — 작은 변경은 결과·흐름·직접 검증만, 여러 파일이나 리스크가 있는 변경은 배경·직관·위험·이해 확인 문제까지 제공합니다.
3. **복잡한 변경의 학습 도구** — 상태 전이, 마이그레이션, 비동기 흐름처럼 직접 조작하며 이해하는 편이 빠를 때만 micro-world의 최소 형태를 제안합니다. 자동으로 만들지는 않습니다.

초기화 시 `.ai-harness/workflows/understand-change.md`에 프로젝트의 문서, 검증 명령, 공유 위치를 연결하고, 그래프 계약은 `.ai-harness/workflows/understanding-change-graph.json`으로 복사합니다. 팀에 공유할 때는 결과, 달라진 mental model, 검증 근거, 남은 결정만 짧게 handoff합니다.

<a id="bug-fix"></a>

## 버그 수정 흐름: `/fix-bug`

`standard` 초기화가 만든 프로젝트 로컬 Skill/command입니다. 기능 개발과 달리 재현과 관측 증거가 선행 조건이며, 단순히 오류 메시지를 보고 추측으로 수정하지 않습니다.

```mermaid
stateDiagram-v2
    [*] --> triage
    triage --> reproduce
    reproduce --> brief: 재현 또는 충분한 증거
    reproduce --> user_decision: 재현 불가·관측 계획 없음
    brief --> approval
    approval --> brief: 범위 변경 또는 미승인
    approval --> regression: 명시적 승인
    regression --> fix
    fix --> verify
    verify --> review: 필수 검증 통과
    verify --> repair: 필수 검증 실패
    review --> done: blocking finding 없음
    review --> repair: blocking finding 있음
    repair --> verify
```

1. **관찰·재현** — 관찰된/기대 동작, 영향, 환경, 재현 결과를 분리해 기록합니다. 재현이 불가능하고 안전한 관측 계획도 없으면 필요한 로그·환경·기대 동작을 사용자에게 요청합니다.
2. **수정 승인** — 원인 가설과 반증 가능성, 회귀 검증, 최소 변경 범위, 롤백·호환성 위험을 담은 `Bug Fix Brief`를 보여 주고 승인을 받습니다. 승인 전에는 파일을 수정하지 않습니다.
3. **회귀 검증과 수정** — 테스트 정책에 맞게 회귀 테스트 또는 동등한 검증 증거를 먼저 마련한 뒤 최소 수정합니다.
4. **검토 루프** — targeted/전체 검증 뒤 재현 증거·회귀·호환성·범위 이탈을 검토합니다. 같은 원인이 두 번의 집중 수정 뒤에도 남거나 제품·환경 판단이 필요하면 사용자에게 넘깁니다.

생성에 쓰는 [버그 수정 템플릿의 그래프 계약](templates/fix-bug/references/bug-fix-graph.json)은 프로젝트 생성 시 `.ai-harness/workflows/bug-fix-graph.json`으로 복사됩니다. Claude Code `2.1.154+`에서는 승인 뒤 선택적으로 `/ai-harness:fix-bug` Dynamic Workflow를 사용할 수 있고, 그 외에는 같은 흐름을 현재 세션에서 수행합니다.

<a id="review"></a>

## 변경 검토 흐름: `/review`

`standard` 초기화가 만든 프로젝트 로컬 Skill/command입니다. 변경 범위와 수용 기준을 먼저 고정한 뒤, 동작·회귀·필수 검증·보안/데이터·호환성·범위 이탈 순으로 검토합니다.

```mermaid
stateDiagram-v2
    [*] --> scope
    scope --> inspect
    inspect --> classify
    classify --> done: blocking finding 없음
    classify --> repair: 수리 권한이 있는 blocking finding
    classify --> user_decision: 사용자 판단 필요
    repair --> verify
    verify --> re_review
    re_review --> done: blocking finding 없음
    re_review --> repair: blocking finding 남음
```

초기 검토는 read-only입니다. blocking finding은 대상 workflow에서 수리한 뒤 targeted/필수 검증과 재검토를 모두 통과해야 완료됩니다. 같은 원인이 두 번 남거나 제품 판단이 필요하면 사용자에게 넘깁니다. [review 그래프 계약](templates/review/references/review-graph.json)은 프로젝트 생성 시 `.ai-harness/workflows/review-graph.json`으로 복사됩니다. Claude Code `2.1.154+`에서는 검토 → 수리 → 재검토 루프에 선택적으로 `/ai-harness:review` Dynamic Workflow를 사용할 수 있고, 그 외에는 같은 흐름을 현재 세션에서 수행합니다.

### 역할별 기본 모델

모델 선택은 초기화 인터뷰에서 묻지 않습니다. 선택한 도구의 역할 agent 정의에 기본값을 기록합니다.

| 역할 | Codex | Claude | 주 용도 |
|---|---|---|---|
| explorer | `gpt-5.6-terra` / low | Haiku | 독립적인 코드 탐색·문서 확인 |
| test-engineer | `gpt-5.6-terra` / medium | Sonnet | 재현과 테스트 추가 |
| developer | `gpt-5.6` / medium | Sonnet | 구현과 수정 |
| reviewer | `gpt-5.6` / high | Opus | 보안·데이터·설계 검토 |

계정 또는 조직 정책상 모델을 쓸 수 없으면 임의로 다른 모델을 고르지 않고 대체 후보를 안내합니다. 보안, 데이터 마이그레이션, 복잡한 장애 분석은 가벼운 역할에 위임하지 않습니다.

<a id="self-learning"></a>

## 자가학습: 기록 → 분석 → 개선

### 자동으로 일어나는 일

| 시점 | hook | 하는 일 | 하지 않는 일 |
|---|---|---|---|
| 세션 종료 | `SessionEnd` → `scripts/collect.sh` | transcript에서 압축 이벤트를 추출해 프로젝트별 pending 큐에 멱등 적재하고, 누적량을 판정 | LLM 분석, 파일 수정, PR 생성 |
| 세션 시작 | `SessionStart` → `scripts/session-start.sh` | analysis batch와 새 릴리스 여부를 알림 | `/harvest` 실행, 플러그인 설치·업데이트 |

두 hook은 3초 timeout이며 실패해도 작업 세션을 막지 않습니다. 누락·진행 중인 Codex 세션은 `/metrics`, `/harvest`, 세션 조회의 backfill이 보완합니다.

### 언제 `/harvest`를 안내하나

기본적으로 아래 중 하나면 pending 세션을 analysis batch로 묶고 다음 세션 시작에 `/harvest`를 안내합니다.

- 세션 10개 누적
- 서로 다른 2개 이상 세션에서 사용자 교정 2개
- 서로 다른 2개 이상 세션에서 오류 5개, 가드 차단 3개, 권한 거부 3개 중 하나

한 batch는 최대 50개 세션입니다. 단, 트리거 판정은 전체 pending을 기준으로 하며 신호가 있는 세션을 우선 포함합니다. 분석 중 새로 종료된 세션은 다음 batch에 보존됩니다. 첫 알림을 놓치면 기본 24시간마다 다시 알립니다.

`/harvest`는 batch와 30/90일 baseline을 분리해 비교한 뒤 아래 중 하나를 결론으로 남깁니다.

- **개선 적용**: 에이전트의 실제 행동을 바꿀 제약·워크플로·문서 구조 변경만 PR로 제안합니다.
- **통계 참고**: 근거는 있으나 아직 행동 변경으로 이어질 만큼 강하지 않은 경우입니다.
- **개선점 없음**: cosmetic 정리나 단발성 노이즈는 적용하지 않습니다.

정상 완료한 batch만 `mark-reviewed`로 소비합니다. `--dry-run`이나 실패한 분석은 pending을 지우지 않습니다.

```bash
# 개선 PR을 만든 경우
scripts/harvest-queue.sh mark-reviewed --project <프로젝트> \
  --outcome improved --summary "<개선 요약>" --artifact "<PR URL>"

# 적용할 개선이 없는 경우
scripts/harvest-queue.sh mark-reviewed --project <프로젝트> \
  --outcome no-change --summary "<적용하지 않은 이유>"
```

<a id="data-retention"></a>

## 수집 데이터와 보관

수집은 `jq` 기반이며 LLM 비용이 들지 않습니다. transcript 전문을 복사하지 않습니다.

- 수집 항목: 세션 메타(토큰·모델·턴), workflow/command 사용, 역할 위임, 하네스 문서 읽기, 편집 파일, bash 명령, MCP 도구, 이슈 키, 오류·가드·권한 거부·컨텍스트 압축 횟수
- 사용자 교정 마크만 해당 발화 앞 60자 스니펫을 보관해 개선 분석의 정독 후보로 표시합니다.
- Claude와 Codex 모두 위 항목을 관측합니다. Codex는 native function call과 desktop/runtime bridge의 custom tool call을 해석하며, bridge가 경로를 노출하지 않는 편집은 파일별 핫스팟 대신 집계에서 제외될 수 있습니다. 미지원은 0회와 구분하므로, 관측하지 못한 데이터로 삭제 근거를 만들지 않습니다.

| 데이터 | 기본 위치 | 보관 방식 |
|---|---|---|
| 압축 이벤트 | `~/.ai-harness/events/` | 일반 180일, 교정·오류·차단·권한 거부가 있으면 365일 |
| 통계 rollup | `~/.ai-harness/rollups/` | 상세 보관 기간 후 transcript 경로와 교정 문구를 제거해 전환 |
| harvest 큐·검토 이력 | `~/.ai-harness/harvest-queue/` | pending, 현재 batch, 완료 marker, `review-history.jsonl` |
| 상태 | `~/.ai-harness/health.json`, `update-check.json` | 수집 건강 상태와 릴리스 확인 캐시만 기록 |

상세 이벤트 삭제가 중단되면 원 marker를 유지해 다음 실행에서 재시도합니다. 같은 세션이 실제로 갱신되면 rollup 뒤에도 새 revision을 수집합니다. 프로젝트 ID는 `.ai-harness/harness.json`을 우선하고, 없으면 git origin/common-dir로 정규화해 worktree를 하나의 프로젝트로 묶습니다.

<a id="updates"></a>

## 업데이트

SessionStart는 공식 `release.json`을 기본 24시간 TTL 캐시로 확인하고 새 버전만 알려 줍니다. 네트워크 실패는 기존 성공 캐시를 보존하며 세션을 막지 않습니다.

```bash
# 설치 상태와 최신 버전만 확인
/harness-update --check

# 사용자가 명시적으로 적용
/harness-update --apply
```

직접 적용해야 한다면 현재 사용하는 호스트에서 다음 명령을 실행할 수 있습니다.

```bash
# Codex CLI
codex plugin marketplace upgrade ai-harness
codex plugin add ai-harness@ai-harness

# Claude Code
claude plugin update ai-harness@ai-harness
```

적용 뒤 새 대화 또는 세션을 시작해 변경된 skill과 hook을 다시 로드합니다.

<a id="configuration"></a>

## 설정 (선택)

`~/.ai-harness/config`에 아래 값을 둘 수 있습니다.

```bash
HM_ISSUE_RE="(NJ|JDA)-[0-9]+"   # 기본: [A-Z]{2,}[0-9]*-[0-9]+
HM_HARVEST_SESSION_THRESHOLD=10  # 0이면 세션 수 기준 비활성화
HM_HARVEST_CORRECTION_THRESHOLD=2
HM_HARVEST_CORRECTION_SESSION_THRESHOLD=2
HM_HARVEST_ERROR_THRESHOLD=5
HM_HARVEST_ERROR_SESSION_THRESHOLD=2
HM_HARVEST_GUARD_THRESHOLD=3
HM_HARVEST_GUARD_SESSION_THRESHOLD=2
HM_HARVEST_PERMISSION_THRESHOLD=3
HM_HARVEST_PERMISSION_SESSION_THRESHOLD=2
HM_HARVEST_MAX_BATCH_SESSIONS=50
HM_HARVEST_REMIND_HOURS=24       # 0이면 batch당 한 번만 알림
HM_EVENT_RETENTION_DAYS=180      # 0이면 일반 이벤트 자동 정리 비활성화
HM_SIGNAL_EVENT_RETENTION_DAYS=365
HM_UPDATE_CHECK_HOURS=24         # 0이면 매 SessionStart마다 확인
```

저장 위치를 바꾸려면 셸 프로파일에 설정합니다.

```bash
export HARNESS_METRICS_DIR="/custom/path"  # 기본: ~/.ai-harness
```

<a id="repository"></a>

## 저장소 구조 · 요구사항

```text
.claude-plugin/   Claude Code 플러그인 매니페스트와 마켓플레이스
.codex-plugin/    Codex CLI 플러그인 매니페스트
.agents/plugins/  Codex 마켓플레이스
skills/           Claude·Codex가 공용으로 읽는 skill 지시
hooks/            SessionEnd 수집·SessionStart 알림 정의
workflows/        Claude Dynamic Workflow 어댑터
scripts/          수집·집계·보관·업데이트·그래프 검증 스크립트
templates/        /harness-init이 프로젝트에 생성하는 진입점·그래프 계약 원본 (managed-files.json이 단일 출처)
tests/            회귀 테스트와 fixtures (bash tests/run.sh)
```

macOS/Linux에서 bash와 `jq`가 필요합니다. `curl`은 릴리스 확인에만 사용합니다. 교정 마크 감지는 현재 한국어 패턴 중심입니다.

개발 시 회귀 테스트는 아래와 같습니다. `shellcheck`이 설치되어 있으면 shell 검사도 권장합니다.

```bash
bash tests/run.sh
shellcheck scripts/*.sh tests/*.sh
```
