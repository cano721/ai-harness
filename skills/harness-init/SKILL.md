---
name: harness-init
description: 프로젝트 AI 하네스 최초 셋업·설정 변경·생성물 동기화. 프로젝트를 실측 분석해 AGENTS.md·.ai-harness docs·워크플로·페르소나를 스캐폴딩하고, 기존 하네스는 안전한 diff와 관리 파일 해시로 최신 템플릿에 동기화한다.
---

# /harness-init — 프로젝트 AI 하네스 셋업 / 변경 / 동기화

현재 프로젝트(cwd)를 분석해 `.ai-harness` 하네스 구조를 스캐폴딩한다. 이후 `/metrics`로 관찰, `/harvest`로 개선하는 사이클의 시작점. **기존 하네스가 있으면 설정 변경 또는 생성물 동기화 모드로 동작한다.**

인자: `$ARGUMENTS` — 아래 인터뷰 답을 미리 줄 수도 있음 (예: `standard`, `tdd`, `codex`, `guard`). 기존 프로젝트에서는 `--sync`(동기화 계획), `--sync --apply`(안전한 생성물 적용), `--reconfigure`(수준 인터뷰)를 쓴다. 인자가 없으면 현재 설정을 보여 주고 동기화 / 설정 변경 / 둘 다 중 선택하게 한다.

경로 표기: 아래 `$ROOT` = 이 SKILL.md가 있는 디렉터리의 두 단계 상위(플러그인 루트).

## 0. 모드 판정

- `.ai-harness/`와 `AGENTS.md` **둘 다 없음** → **신규 셋업** (1번부터 진행)
- **하나라도 있음** → **기존 하네스 모드** (아래 6번으로) — AGENTS.md만 있는 프로젝트도 기존 하네스로 취급, 절대 덮어쓰지 않는다
- git repo가 아니면 사용자에게 `git init` 여부 확인

## 1. 프로젝트 분석 (질문보다 먼저 — 질문에 실측 컨텍스트를 담기 위해)

빌드 파일로 감지: 언어/프레임워크(`build.gradle*`, `pom.xml`, `package.json`, `pyproject.toml`, `go.mod` 등), 테스트 프레임워크·**기존 테스트 규모**(테스트 파일 수, 커버리지 게이트 유무), 빌드/실행 명령, git 컨벤션(최근 커밋 메시지·브랜치명 패턴 `git log --oneline -30`, `git branch -a`), 패키지/모듈 구조(주요 디렉토리와 의존 방향).

분석 결과는 문서 초안의 **실측 근거**가 된다 — 추측으로 채우지 않는다. 규모가 크면 탐색 서브에이전트(Explore 등)에 위임.

## 2. 수준 인터뷰 (AskUserQuestion — 엄격도는 사용자가 정한다)

하네스 엄격도는 프로젝트 성격에 따라 크게 다르다 (예: 프로덕션 백엔드는 TDD 강제 + 커버리지 게이트가 맞지만, 사이드 프로젝트에 그 수준은 과함). **기본값을 가정하지 말고 물어본다.** 단, 1단계 실측을 질문 설명에 반영한다 (예: "현재 테스트 파일 0개" / "jacoco 게이트 이미 있음").

1. **하네스 규모**: `minimal`(AGENTS.md+docs만) / `standard`(+워크플로·페르소나). Codex Skill 진입점은 아래 도구 통합에서 Codex를 선택할 때 추가한다. `full`은 규모가 아니라 아래 편집 가드 옵션의 이전 명칭이므로 새로 선택하지 않는다.
2. **테스트 정책**: `TDD 강제`(Red→Green→Refactor, test-engineer가 RED 전담) / `테스트 필수`(순서 무관, 구현 후 작성 허용) / `권장만` / `없음`(testing.md·test-engineer 생성 안 함)
   - 실측과 모순되면 지적: 기존 테스트가 0개인데 TDD 강제를 고르면 "기존 코드엔 characterization부터 필요" 경고
3. **git 통제 수준**: `PR 필수`(에이전트는 PR까지만, 병합은 사람) / `직접 커밋 허용`
4. **도구 통합**: `Codex` / `Claude` / `둘 다` / `통합 파일 없음`. standard의 Codex Skill은 `Codex` 또는 `둘 다`일 때만 `.agents/skills/`에 생성한다. Claude용 `.claude/`와 `CLAUDE.md`는 `Claude` 또는 `둘 다`일 때만 생성한다.
5. **편집 가드**: 켜기 / 끄기. 가드는 규모와 독립적인 선택 옵션이며, 소스 수정 전에 관련 하네스 문서를 읽었는지 확인한다. transcript를 읽을 수 없으면 fail-open한다.

답에 따라 생성물 조정: 워크플로 본문의 TDD 절차 유무, test-engineer 페르소나 유무, 선택한 도구의 어댑터와 agent별 모델 설정, guard hook 유무, AGENTS.md의 Git 룰 문구. 모델은 사용자 인터뷰로 묻지 않고 아래 역할 기본값을 사용한다.

## 3. 생성 구조 (인터뷰 답 기준으로 가감)

```
AGENTS.md                    # 진입점 (아래 구성)
.ai-harness/
  harness.json               # 수준·안정적 project_id 매니페스트 (아래 참조) — 수준 변경 모드·/harvest가 읽음
  docs/
    code-conventions.md      # 실측된 네이밍·구조·스타일 규칙
    architecture.md          # 모듈 구조, 기술 스택, 빌드/배포 (실측)
    testing.md               # 테스트 실행법, 프레임워크, 작성 규칙 (테스트 정책 '없음'이면 생략)
    domain.md                # 도메인 인덱스 (초기엔 표 틀만 — 도메인 문서는 필요해질 때 domain/{name}.md로 추가)
  workflows/                 # standard
    implement-feature.md     # 기능 개발 절차 (작은 검증 단위·완료 증거 원칙을 프로젝트 정책에 맞춰 구체화)
    feature-delivery-graph.json # implement-feature의 프로젝트 로컬 노드·전이 계약
    fix-bug.md               # 버그 수정 절차 (재현·원인·회귀 검증 기준)
    bug-fix-graph.json       # fix-bug의 프로젝트 로컬 노드·전이 계약
    review.md                # 변경 검토·finding 종료 절차
    review-graph.json        # review의 프로젝트 로컬 노드·전이 계약
    understand-change.md     # 사람이 변경을 이해하고 다음 결정을 내리기 위한 절차
    understanding-change-graph.json # 설명 깊이·검증·micro-world 판단 계약
  agents/                    # standard
    explorer.md              # 탐색 전담 (read-only)
    developer.md             # 구현 전담 (write scope: 소스+빌드 설정)
    test-engineer.md         # 테스트 전담 (write scope: 테스트 디렉토리만. 테스트 정책 '없음'이면 생략)
    reviewer.md              # 리뷰 전담 (read-only)
  hooks/
    direct-edit-guard.sh     # 편집 가드를 켰을 때만
.agents/
  skills/                    # Codex 또는 둘 다를 선택한 standard
    implement-feature/
      SKILL.md                # .ai-harness 워크플로·그래프를 읽는 프로젝트 로컬 진입점
    fix-bug/
      SKILL.md                # .ai-harness 워크플로·그래프를 읽는 프로젝트 로컬 진입점
    review/
      SKILL.md                # .ai-harness 워크플로·그래프를 읽는 프로젝트 로컬 진입점
    understand-change/
      SKILL.md                # 변경 설명·검증·이해 확인을 위한 프로젝트 로컬 진입점
.codex/
  agents/                    # Codex 또는 둘 다를 선택한 standard
    explorer.toml             # model·model_reasoning_effort가 지정된 read-only agent
    test-engineer.toml
    developer.toml
    reviewer.toml
CLAUDE.md                    # Claude 또는 둘 다를 선택했을 때만; 내용: "@AGENTS.md"
.claude/
  agents/                    # explorer/developer/test-engineer/reviewer 위임본 + model frontmatter
  commands/                  # Claude 슬래시 커맨드 진입점
  settings.json              # 감지된 빌드/테스트 명령 allowlist (+ guard 시 PreToolUse hook)
```

## 4. 작성 원칙

- **AGENTS.md 구성**: Preflight(작업 시작 절차) / Hard constraints / Direct edit guard 룰(선택 시) / 워크플로·페르소나 표 / docs 목록 / Quick Commands(감지된 명령) / Git 컨벤션(실측 + 인터뷰 답)
- **Hard constraints는 틀만 만들고 비워둔다** — "실측으로 검증된 룰만 추가. 추측 금지" 주석 한 줄. 이 섹션은 `/harvest`가 시간을 들여 채우는 영역
- docs는 실측 내용만. 확인 못 한 건 쓰지 말고 "코드를 source of truth로 확인" 문구로 대체
- 페르소나 write scope는 좁게 (test-engineer는 테스트 디렉토리만 등)
- settings.json allowlist는 read-only·빌드·테스트 명령만. deny에 force push
- direct-edit-guard.sh는 소스 경로 수정 전 code-conventions.md(테스트면 testing.md 추가) Read 여부를 transcript에서 grep — 미Read 시 exit 2 + 안내. transcript 접근 불가 시 fail-open(exit 0)
- `/implement-feature`는 플러그인 전역 Skill이 아니라 `standard` 초기화에서 생성하는 **프로젝트 로컬 기능 개발 진입점**이다. `templates/implement-feature/`를 기반으로 Codex는 `.agents/skills/implement-feature/SKILL.md`, Claude는 `.claude/commands/implement-feature.md`를 생성한다. 템플릿의 그래프는 `.ai-harness/workflows/feature-delivery-graph.json`에도 복사하고, 두 진입점은 이 프로젝트 로컬 파일과 `.ai-harness/workflows/implement-feature.md`, 필요한 docs를 먼저 읽어 프로젝트별 정책을 우선하도록 한다. `.ai-harness/`는 프로젝트 특화 규칙의 단일 출처다.
- `templates/implement-feature/references/feature-delivery-graph.json`은 생성 원본이며, 프로젝트에 복사된 `.ai-harness/workflows/feature-delivery-graph.json`이 Codex·Claude 공통 노드/전이 계약의 단일 출처다. Codex는 생성된 프로젝트 Skill과 `.codex/agents/` 위임으로 이를 해석한다. Claude를 선택했을 때는 `claude --version`을 확인하고 **2.1.154 이상**에서만 플러그인 내부의 `/ai-harness:implement-feature` Dynamic Workflow를 승인 후 구현·리뷰 루프에 선택적으로 사용한다고 안내한다. Dynamic Workflow가 없거나 실행 중 사용자 판단이 필요하면 생성된 프로젝트 command의 현재 세션 흐름으로 폴백한다.
- 템플릿에서 생성할 `implement-feature.md`는 프로젝트 정책에 맞춰 구체화한다: 먼저 구현 범위·비범위·검증 케이스·예상 변경 영역·검증 명령을 `Implementation Brief`로 사용자에게 보이고 **명시 승인을 받을 때까지 파일을 수정하지 않는** 계획 게이트를 둔다. 현재 대화에 같은 범위의 승인된 Brief가 있으면 재승인은 요구하지 않는다. 승인 뒤 요구사항을 관찰 가능한 검증 케이스와 1~3개 케이스의 delivery slice로 나눈다. 테스트 정책이 TDD일 때만 Red 실패 확인 → 최소 Green → 테스트를 바꾸지 않는 Refactor를 요구하고, 그 외 정책은 프로젝트가 정한 테스트 순서·필수 여부와 가능한 빌드/lint/type 검증을 따른다. 완료 전에는 blocking finding이 0개가 될 때까지 **리뷰 → 원인별 수정 → targeted/전체 검증 → 재리뷰**를 반복하며, 같은 원인이 두 번의 집중 수정 뒤에도 남으면 사용자 판단으로 올린다. 역할 분리는 선택한 도구와 작업 위험이 뒷받침할 때만 사용하며, 역할 도구가 없다는 이유로 단일 세션 작업을 중단하지 않는다.
- `/fix-bug`도 플러그인 전역 Skill이 아니라 `standard` 초기화에서 생성하는 **프로젝트 로컬 버그 수정 진입점**이다. `templates/fix-bug/`를 기반으로 Codex는 `.agents/skills/fix-bug/SKILL.md`, Claude는 `.claude/commands/fix-bug.md`를 생성한다. 템플릿의 그래프는 `.ai-harness/workflows/bug-fix-graph.json`에도 복사한다. 승인 전에는 관찰·재현·원인 가설만 허용하고, 재현 불가이며 안전한 관측 계획도 없으면 수정하지 않고 사용자에게 필요한 환경·로그·기대 동작을 요청한다.
- 템플릿에서 생성할 `fix-bug.md`는 관찰된/기대 동작, 영향, 재현 증거, 원인 가설과 반증 가능성, 회귀 검증, 최소 변경 범위를 담은 `Bug Fix Brief`를 먼저 제시하고 **명시 승인을 받을 때까지 파일을 수정하지 않는** 게이트를 둔다. 승인 뒤 프로젝트 테스트 정책에 따라 회귀 테스트 또는 동등한 검증 증거를 만들고, targeted/전체 검증과 **리뷰 → 원인별 수정 → 재검토**를 수행한다. 같은 원인이 두 번의 집중 수정 뒤에도 남거나 제품·환경 판단이 필요하면 사용자에게 넘긴다.
- `/review`도 `standard` 초기화에서 생성하는 프로젝트 로컬 진입점이다. `templates/review/`를 기반으로 Codex는 `.agents/skills/review/SKILL.md`, Claude는 `.claude/commands/review.md`를 생성하고 graph를 `.ai-harness/workflows/review-graph.json`에 복사한다. 초기 검토는 read-only이며, blocking finding이 있으면 대상 workflow로 수리한 뒤 필수 검증과 재검토를 거치기 전에는 완료하지 않는다.
- `/understand-change`는 `standard` 초기화에서 생성하는 프로젝트 로컬 설명 진입점이다. `templates/understand-change/`를 기반으로 Codex는 `.agents/skills/understand-change/SKILL.md`, Claude는 `.claude/commands/understand-change.md`를 생성하고 graph를 `.ai-harness/workflows/understanding-change-graph.json`에 복사한다. `understand-change.md`에는 프로젝트 문서·테스트·명령을 바탕으로 small / standard / deep 설명의 깊이를 정한다. 설명은 변경 전 배경, 직관, 실행 흐름, 위험, 직접 검증을 포함하며, standard·deep에서는 이해 확인 문제를 추가한다. deep 변경에서만 상태를 조작하거나 단계별 실행을 관찰하는 micro-world의 최소 형태를 제안하며, 사용자의 별도 승인 없이는 구현하지 않는다.
- Claude 어댑터도 프로젝트 로컬 workflow·graph를 `@.ai-harness/...`로 참조한다. Claude Code가 **2.1.154 이상**이면 승인 후 플러그인 내부의 `/ai-harness:implement-feature`, `/ai-harness:fix-bug`, `/ai-harness:review` Dynamic Workflow를 선택적으로 사용할 수 있고, 그렇지 않으면 현재 세션 흐름으로 폴백한다. 사용하지 않는 도구의 디렉터리·설정 파일은 만들지 않는다.
- 모델은 역할 agent 정의에 직접 지정한다. 이는 사용자 인터뷰 항목이 아니며, 기본 매핑은 아래와 같다. 중요한 보안·데이터 마이그레이션·복잡한 장애 분석은 explorer/test-engineer에 맡기지 않고 developer 또는 reviewer로 승격한다.

| 역할 | Codex agent 설정 | Claude agent 설정 | 위임 기준 |
|---|---|---|---|
| explorer | `gpt-5.6-terra`, `low`, read-only | `haiku` | 범위가 독립적인 코드 탐색·문서 확인만 |
| test-engineer | `gpt-5.6-terra`, `medium` | `sonnet` | 재현·테스트 추가. 원인 분석이 복잡하면 developer로 승격 |
| developer | `gpt-5.6`, `medium` | `sonnet` | 구현·수정의 기본 담당 |
| reviewer | `gpt-5.6`, `high`, read-only | `opus` | 보안·데이터·설계·마이그레이션 검토에 우선 사용 |

- 위임은 모델 등급과 무관하게 부모 컨텍스트·도구 호출 비용이 든다. 독립적이고 범위가 좁은 작업에만 쓰며, 단순 작업은 현재 세션에서 직접 처리한다.
- Codex 통합은 `.codex/agents/*.toml`에 `name`, `description`, `developer_instructions`, `model`, `model_reasoning_effort`, 필요 시 `sandbox_mode`를 쓴다. Claude 통합은 `.claude/agents/*.md` frontmatter의 `model`에 위 별칭을 쓴다. 선택한 도구에서 기본 모델이 사용 불가하면 설정을 억지로 대체하지 말고, 감지된 오류와 대체 후보를 사용자에게 보여 준다.

매니페스트 형식 (인터뷰 답 기록 — 수준 변경·/harvest의 정책 참조용):

```json
{ "project_id": "<origin 저장소명 또는 사용자 확인 ID>", "level": "standard", "test_policy": "tdd", "git_policy": "pr-only", "integrations": ["codex"], "edit_guard": false, "initialized": "YYYY-MM-DD", "harness_version": "<플러그인 버전>", "managed_files": { "<relative path>": { "content_sha256": "<생성 직후 해시>", "template_version": "<플러그인 버전>" } } }
```

## 5. 마무리

1. 생성 파일 목록 + 각 파일이 실측에서 가져온 근거 요약 보고
2. 커밋/PR은 사용자 확인 후 (프로젝트 git 컨벤션 따름)
3. 생성 직후 하네스가 관리하는 생성물(프로젝트 로컬 Skill/command, graph, agent 설정, settings)을 아래 명령으로 기록한다. `AGENTS.md`, `.ai-harness/docs/`, 사람이 작성한 workflow 본문은 관리 목록에 넣지 않는다.

```bash
$ROOT/scripts/harness-sync-state.sh record --root . --version <플러그인 버전> \
  --file <관리 생성물 상대 경로> [...]
```

4. 선택한 도구의 진입점과 agent 모델 기본값을 안내: Codex는 `.agents/skills/`의 자연어 호출과 `.codex/agents/`, Claude는 `.claude/commands/`와 `.claude/agents/`를 사용한다. 모델을 사용할 수 없다는 오류가 있으면 대체 후보를 사용자에게 제시한다. 이후 세션부터 활동이 자동 수집되며, 2~4주 뒤 `/metrics`로 관찰, `/harvest <프로젝트>`로 개선 사이클을 시작한다.

## 6. 기존 하네스: 동기화와 설정 변경

1. **현재 상태 파악**: `.ai-harness/harness.json`을 Read하고, 플러그인 루트 `release.json`의 버전과 비교한다. manifest가 없으면 파일 구조로 역추정한다 — 워크플로·페르소나 유무 = standard, guard hook 유무 = `edit_guard:true`, `.agents/skills`와 `.claude` 유무 = 도구 통합, test-engineer·testing.md 유무 = 테스트 정책. 기존 `level:"full"`은 `level:"standard", edit_guard:true`로 이관 제안한다.
2. **모드 선택**: `--sync`이면 인터뷰 없이 동기화 계획을 만들고, `--sync --apply`이면 아래 안전 규칙으로 적용한다. `--reconfigure`이면 2번 수준 인터뷰를 진행한다. 인자가 없으면 현재 설정·버전을 보여 주고 동기화 / 설정 변경 / 둘 다 중 사용자 선택을 받는다.
3. **동기화 계획**: 관리 대상은 `templates/managed-files.json`이 단일 출처다. 아래 명령으로 현재 level·integration에 맞는 대상과 `add` / `refresh` / `approval_required` 결정을 JSON으로 만들고, 사람이 읽을 수 있는 표와 최신 템플릿 diff를 함께 제시한다. 과거 버전처럼 `managed_files` 이력이 없는 기존 파일은 **untracked**로 분류한다.

```bash
$ROOT/scripts/harness-sync-state.sh plan --root . \
  --catalog "$ROOT/templates/managed-files.json"
```
   - **추가 가능**: 새로 도입된 graph, 프로젝트 로컬 Skill/command, agent 설정처럼 대상 파일이 없는 관리 생성물
   - **자동 갱신 가능**: 상태가 `unchanged`인 관리 생성물. 최신 템플릿으로 재생성하고 hash를 갱신한다.
   - **승인 필요**: `modified` 또는 `untracked`인 관리 생성물. 3-way 성격의 현재 파일/마지막 생성 해시/제안 템플릿 diff를 보여 주고, 파일별 사용자 승인을 받은 뒤에만 갱신한다.
   - **보호됨**: `AGENTS.md`, `.ai-harness/docs/**`, 사람이 작성한 workflow 본문. 자동 갱신하지 않으며 개선 제안 diff만 제공한다.
   - **후속 제안(`suggestions`)**: plan 출력의 `suggestions` 배열을 계획 표와 함께 **반드시 별도 "보호 파일 후속 조치" 표로 제시한다** — 건너뛰면 새 진입점이 미등재 반쪽 상태로 남는다. `workflow_body_missing`은 새 진입점이 `@`로 참조하는 `.ai-harness/workflows/<name>.md` 본문 부재, `agents_md_reference`는 AGENTS.md 커맨드 표 미등재를 뜻한다.
4. **적용 규칙**: `--sync`만 있으면 절대 파일·manifest를 변경하지 않는다. `--sync --apply`에서도 추가 가능·자동 갱신 가능 항목만 적용하고, 승인 필요 항목은 명시 승인 범위만 적용한다. 삭제·통합 해제는 항상 파일 목록과 별도 확인을 요구한다. 새 진입점(add) 적용 시 `suggestions`를 함께 처리한다: `workflow_body_missing`은 프로젝트 정책(테스트 정책·검증 명령·docs 매핑)에 맞춰 워크플로 본문을 생성하되 **관리 목록에는 기록하지 않는다** (이후 사람이 소유하는 보호 파일). `agents_md_reference`는 커맨드 표 한 줄 diff를 제안하고 **사용자 승인 후에만** AGENTS.md를 편집한다 — 승인이 없으면 미등재 상태와 그 영향(Preflight 라우팅에서 새 워크플로가 제외됨)을 최종 보고에 명시한다. 적용 뒤 실제로 쓴 관리 생성물만 `harness-sync-state.sh record`로 기록하고 `harness_version`을 갱신한다.
5. **설정 변경**: 재인터뷰 결과에 따라 diff만 적용한다. 테스트 정책 변경은 workflow 본문의 테스트 절차, test-engineer·testing.md, AGENTS.md 위임 규칙을 갱신하되, 기존 사용자 수정은 3번의 승인 필요 규칙을 따른다.
6. 변경 요약, 건너뛴 보호 파일, 다음 동기화에서 검토할 untracked 파일을 보고한다. 커밋/PR은 사용자 확인 후에만 한다.
