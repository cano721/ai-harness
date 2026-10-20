---
name: harness-init
description: 프로젝트 AI 하네스 최초 셋업·설정 변경·생성물 동기화. 프로젝트를 실측 분석해 AGENTS.md·.ai-harness docs·워크플로·페르소나를 스캐폴딩하고, 기존 하네스는 안전한 diff와 관리 파일 해시로 최신 템플릿에 동기화한다. 여러 독립 저장소를 담는 상위 폴더에서는 workspace 모드로 라우팅 진입점만 만든다.
---

# /harness-init — 프로젝트 AI 하네스 셋업 / 변경 / 동기화

현재 프로젝트(cwd)를 분석해 `.ai-harness` 하네스 구조를 스캐폴딩한다. 이후 `/metrics`로 관찰, `/harvest`로 개선하는 사이클의 시작점. **기존 하네스가 있으면 설정 변경 또는 생성물 동기화 모드로 동작한다.**

인자: `$ARGUMENTS` — 아래 인터뷰 답을 미리 줄 수도 있음 (예: `standard`, `tdd`, `codex`, `guard`, `auto`). 기존 프로젝트에서는 `--sync`(동기화 계획), `--sync --apply`(안전한 생성물 적용), `--reconfigure`(수준 인터뷰)를 쓴다. 인자가 없으면 현재 설정을 보여 주고 동기화 / 설정 변경 / 둘 다 중 선택하게 한다.

경로 표기: 아래 `$ROOT` = 이 SKILL.md가 있는 디렉터리의 두 단계 상위(플러그인 루트).

## 0. 모드 판정

- cwd에 `.ai-harness/workspace.json` 있음 → **기존 workspace** (아래 7-6으로)
- cwd가 **git repo가 아님** → 먼저 `$ROOT/scripts/workspace-scan.sh scan --root .`을 돌린다. `candidate:true`(하위에 독립 git 저장소 2개 이상)면 **workspace 모드** (아래 7번으로). `candidate:false`면 사용자에게 `git init` 여부 확인 후 단일 프로젝트 흐름
- `.ai-harness/`와 `AGENTS.md` **둘 다 없음** → **신규 셋업** (1번부터 진행)
- **하나라도 있음** → **기존 하네스 모드** (아래 6번으로) — AGENTS.md만 있는 프로젝트도 기존 하네스로 취급, 절대 덮어쓰지 않는다

## 1. 프로젝트 분석 (질문보다 먼저 — 질문에 실측 컨텍스트를 담기 위해)

빌드 파일로 감지: 언어/프레임워크(`build.gradle*`, `pom.xml`, `package.json`, `pyproject.toml`, `go.mod` 등), 테스트 프레임워크·**기존 테스트 규모**(테스트 파일 수, 커버리지 게이트 유무), 빌드/실행 명령, git 컨벤션(최근 커밋 메시지·브랜치명 패턴 `git log --oneline -30`, `git branch -a`), 패키지/모듈 구조(주요 디렉토리와 의존 방향).

**프론트엔드 스택 감지**: `package.json`의 dependencies에 `react`·`vue`·`svelte`·`@angular/core` 등이 있으면 프론트엔드 프로젝트다. 이때 프론트 판단 Skill(아래 stack 게이트)의 생성 후보가 된다 — 백엔드 전용 저장소에는 만들지 않는다. FSD(Feature-Sliced Design) 여부도 함께 본다: `src/` 아래 `shared`·`entities`·`features`·`pages` 레이어 디렉터리가 있거나 `steiger.config.*`가 있으면 FSD 사용으로 판단하고, 애매하면 §2에서 사용자에게 묻는다.

분석 결과는 문서 초안의 **실측 근거**가 된다 — 추측으로 채우지 않는다. 규모가 크면 탐색 서브에이전트(Explore 등)에 위임.

## 1-1. 기존 에이전트 자산 융화 (하네스 파일을 쓰기 전에)

팀이 이미 운영하는 에이전트 자산(`CLAUDE.md`·`.claude/agents`·`.claude/skills`·라우터 스킬·settings hook)이 있으면 하네스는 그 **옆에 하나 더 세우지 않는다.** 같은 역할의 페르소나가 둘이면 위임 대상이 모호해지고, 기존 라우팅("코드를 고치는 손은 이 셋 중 하나")과 하네스 워크플로가 서로 다른 지휘 체계가 된다. 하네스가 공급하는 것은 **절차(그래프·Brief 승인·검증 루프)·문서·가드**이고, 일하는 손은 가능한 한 기존 에이전트다.

```bash
$ROOT/scripts/existing-assets.sh scan --root . --templates "$ROOT/templates"
```

출력은 사실만 담는다: `instructions`(CLAUDE.md 위치와 `agents_import`·`imports_agents`, 루트 컨벤션 문서), `agents`(이름·모델·description·`skills`), `skills`(`template_collision`·`identical_to_template`·`routes_agents` = 로컬 에이전트를 부르는 라우터 후보), `commands`, `settings`(기존 hook 이벤트·`enabled_plugins`), `external_refs`(`plugin:agent` 참조와 `declared` 여부), `claude_dir_ignored`. 모든 목록이 비어 있으면 이 절을 건너뛴다.

1. **역할 매핑 초안**: 하네스 역할 슬롯(explorer·developer·test-engineer·reviewer·docs-updater)마다 description·본문으로 책임이 겹치는 기존 에이전트를 찾는다. 담당을 나누는 라우터 스킬(`routes_agents:true`)이 있으면 그 스킬이 정한 대로 구현 슬롯(developer·test-engineer)을 라우터에 맡기는 안이 기본이다. 매핑은 §2 인터뷰 7번에서 사용자가 확정한다 — 추측으로 정하지 않는다.
2. **매핑된 슬롯은 생성하지 않는다**: 확정된 슬롯은 `.claude/agents/<slot>.md`(해당 integration)를 만들지 않고, 워크플로 본문의 위임 대상·AGENTS.md 페르소나 표를 기존 이름(또는 "라우터 `<path>`가 정한 담당")으로 쓴다. 기존 에이전트가 없는 integration(대개 Codex)은 하네스 페르소나를 그대로 만든다. 확정 결과를 manifest `roles`에 기록한다(아래 형식). 이미 생성된 페르소나가 매핑으로 대체되면 sync plan이 `orphaned`(`role_adopted`)로 제거 후보에 올린다.
3. **가드와 맞물리게**: 편집 가드는 편집하는 세션의 transcript에서 docs Read를 찾는다. 매핑된 기존 에이전트 본문에 Preflight 한 줄("작업 전 `AGENTS.md` Preflight와 `.ai-harness/docs/code-conventions.md`(테스트면 `testing.md`)를 Read한다")이 없으면 첫 편집에서 막힌다. 기존 에이전트는 사람 소유 파일이므로 **diff를 보이고 승인받은 뒤에만** 그 한 줄을 넣는다. 승인이 없으면 가드 충돌 가능성을 최종 보고에 적는다.
4. **지침 파일**: 기존 CLAUDE.md는 내용을 보존하고 맨 위에 `@<agents_import>` 한 줄만 넣는다 — `.claude/CLAUDE.md`면 `@../AGENTS.md`다(import는 파일 위치 기준). 루트 CLAUDE.md를 새로 만들지 않는다(두 지침이 이중 로드된다). 컨벤션 문서는 docs에서 링크·요약으로 연결하고 복사하지 않는다.
5. **같은 이름 스킬**(`template_collision:true`): 기존 것을 유지하고 `harness-sync-state.sh exclude --reason existing`으로 기록해 다음 sync가 덮어쓰기나 add로 제안하지 않게 한다. `identical_to_template:true`면 템플릿 그대로이므로 사용자에게 관리 생성물로 넘길지(그러면 exclude하지 않고 `record`) 묻는다. 맞춤본이 템플릿과 다르면 차이 요약을 보고한다.
6. **settings**: 기존 `.claude/settings.json`의 hook·권한은 보존하고 하네스 키만 병합한다. 같은 이벤트에 hook이 이미 있으면 배열에 추가한다.
7. **`.claude/` gitignore**(`claude_dir_ignored:true`): 강제 추가(`git add -f`)하지 않는다. 팀이 `.claude/`를 커밋하지 않기로 했을 수 있으므로, `.gitignore`에 하네스 경로만 예외(`!.claude/agents/` 등)로 둘지 / `.claude` 생성물을 빼고 진행할지 사용자에게 묻는다.
8. **기존 자산 점검표** (보고 전용 — 사람 소유 파일이라 자동으로 고치지 않는다): `external_refs` 중 `declared:false`(저장소가 선언하지 않은 플러그인 — 설치 안 한 팀원에게서 그 경로가 끊긴다), 매핑된 에이전트 frontmatter `skills:`와 본문이 부르는 스킬의 불일치, 코드와 모순되는 서술(존재하지 않는 경로·"아직 X가 없다"류 — 실측으로 확인한 것만), 여러 파일에 반복된 같은 규칙(원본 한 곳 + 참조로 합치는 안)을 **파일:줄 · 문제 · 제안(수정/삭제/병합)** 표로 보인다. 사용자가 고른 항목만 적용한다.

## 2. 수준 인터뷰 (AskUserQuestion — 엄격도는 사용자가 정한다)

하네스 엄격도는 프로젝트 성격에 따라 크게 다르다 (예: 프로덕션 백엔드는 TDD 강제 + 커버리지 게이트가 맞지만, 사이드 프로젝트에 그 수준은 과함). **기본값을 가정하지 말고 물어본다.** 단, 1단계 실측을 질문 설명에 반영한다 (예: "현재 테스트 파일 0개" / "jacoco 게이트 이미 있음").

1. **하네스 규모**: `minimal`(AGENTS.md+docs만) / `standard`(+워크플로·페르소나). Codex Skill 진입점은 아래 도구 통합에서 Codex를 선택할 때 추가한다. `full`은 규모가 아니라 아래 편집 가드 옵션의 이전 명칭이므로 새로 선택하지 않는다.
2. **테스트 정책**: `TDD 강제`(Red→Green→Refactor, test-engineer가 RED 전담) / `테스트 필수`(순서 무관, 구현 후 작성 허용) / `권장만` / `없음`(testing.md·test-engineer 생성 안 함)
   - 실측과 모순되면 지적: 기존 테스트가 0개인데 TDD 강제를 고르면 "기존 코드엔 characterization부터 필요" 경고
3. **git 통제 수준**: `PR 필수`(manifest `git_policy:"pr-only"` — 에이전트가 커밋·일반 push·PR 생성까지, 병합·force push는 사람) / `직접 커밋 허용`(`git_policy:"direct"` — 커밋·일반 push까지, PR은 프로젝트 워크플로가 요구할 때만). 어느 쪽이든 병합·force push는 에이전트가 하지 않는다. 값이 없거나 그 밖이면 에이전트는 별도 허가 없이 커밋·push·PR을 하지 않는다(이전 동작)
4. **도구 통합**: `Codex` / `Claude` / `둘 다` / `통합 파일 없음`. standard의 Codex Skill은 `Codex` 또는 `둘 다`일 때만 `.agents/skills/`에 생성한다. Claude용 `.claude/`와 `CLAUDE.md`는 `Claude` 또는 `둘 다`일 때만 생성한다.
5. **편집 가드**: 켜기 / 끄기. 가드는 규모와 독립적인 선택 옵션이며, 소스 수정 전에 관련 하네스 문서를 읽었는지 확인한다. transcript를 읽을 수 없으면 fail-open한다.
6. **프론트 판단 Skill** (§1에서 프론트엔드 스택을 감지했을 때만 묻는다): `생성` / `생성 안 함`. 생성하면 `frontend-fundamentals`·`declarative-code`·`frontend-testing`·`no-unnecessary-effects`를 프로젝트 로컬 Skill로 만든다(모두 읽기 전용 판단 지침). **FSD Skill(`feature-sliced-design`)은 별도 하위 선택**이며 §1에서 FSD를 감지했거나 사용자가 FSD를 쓴다고 답할 때만 추가한다 — FSD를 안 쓰는 프로젝트에 방법론 전체를 심으면 오도한다. 프론트엔드가 아니면 이 항목 자체를 건너뛴다.
7. **역할 매핑** (§1-1에서 기존 에이전트를 찾았을 때만 묻는다): 슬롯별로 §1-1 초안을 보이고 `기존 <name>(또는 라우터)에 맡김` / `하네스 페르소나 생성`을 받는다. 매핑한 슬롯은 생성하지 않는다.
8. **승인 게이트** (standard일 때): `사람 승인`(manifest `approval:"human"`, 기본 — Brief를 보여 주고 사람이 승인할 때까지 파일을 수정하지 않는다) / `정책 승인`(`approval:"auto"` — Brief를 산출물(러너 실행 디렉터리·PR 본문)로 남기고 승인 노드를 통과한다. 위임 세션·상위 오케스트레이터가 사람 없이 PR까지 가는 운영용). auto여도 Brief에 열린 질문이 있거나, 그래프가 `user_decision`으로 보내는 수리 한도 초과·제품 판단, 병합·force push 같은 비가역 작업은 사람에게 간다. `PR 필수`와 함께 고르면 "이슈를 맡기면 PR까지, 병합만 사람" 흐름이 된다.

답에 따라 생성물 조정: 워크플로 본문의 TDD 절차 유무, test-engineer 페르소나 유무, 선택한 도구의 어댑터와 agent별 모델 설정, guard hook 유무, AGENTS.md의 Git 룰 문구(`pr-only`면 "에이전트는 커밋·일반 push·PR 생성까지, 병합·force push는 사람", `direct`면 "커밋·일반 push까지, force push 금지"), **프론트 판단 Skill 생성 여부(및 FSD 포함 여부)**. 승인 게이트(8번)와 git 통제 수준(3번)은 manifest `approval`·`git_policy`에만 기록한다 — 어댑터·러너가 런타임에 manifest를 읽으므로 어댑터 본문을 정책별로 바꿔 렌더하지 않는다(정책을 바꿔도 관리 생성물 해시가 그대로다). 프론트 Skill을 생성하면 manifest의 `stacks`에 `frontend`를(FSD까지면 `fsd`도) 기록해 이후 동기화가 이 stack 게이트로 대상을 거른다. 모델은 사용자 인터뷰로 묻지 않고 아래 역할 기본값을 사용한다. 7번에서 기존 에이전트에 넘긴 슬롯은 아래 구조에서 그 integration의 페르소나 파일을 빼고, 기존 에이전트의 모델은 바꾸지 않는다.

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
    frontend.md              # 프론트 판단 Skill을 생성할 때만. 디자인 시스템·테마 토큰명, 선언 사다리, FSD 여부 등 프로젝트 고유 사실 (실측). 프론트 Skill이 런타임에 읽는 프로젝트 컨텍스트
  workflows/                 # standard
    implement-feature.md     # 기능 개발 절차 (작은 검증 단위·완료 증거 원칙을 프로젝트 정책에 맞춰 구체화)
    feature-delivery-graph.json # implement-feature의 프로젝트 로컬 노드·전이 계약
    fix-bug.md               # 버그 수정 절차 (재현·원인·회귀 검증 기준)
    bug-fix-graph.json       # fix-bug의 프로젝트 로컬 노드·전이 계약
    review.md                # 변경 검토·finding 종료 절차
    review-graph.json        # review의 프로젝트 로컬 노드·전이 계약
    understand-change.md     # 플러그인 `/understand-change`가 읽는 프로젝트별 설명 정책 (선택, 사람 소유)
  agents/                    # standard
    explorer.md              # 탐색 전담 (read-only)
    developer.md             # 구현 전담 (write scope: 소스+빌드 설정)
    test-engineer.md         # 테스트 전담 (write scope: 테스트 디렉토리만. 테스트 정책 '없음'이면 생략)
    reviewer.md              # 리뷰 전담 (read-only)
    docs-updater.md          # docs 영향 분석·갱신 전담 (Mode A read-only / Mode B write scope: .ai-harness/docs/)
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
    frontend-fundamentals/   # stack:frontend일 때만. 아래 4종은 templates/에서 복사한 자립 지침
      SKILL.md
      references/            # 통째로 함께 복사
    declarative-code/
      SKILL.md
    frontend-testing/
      SKILL.md
    no-unnecessary-effects/
      SKILL.md
    feature-sliced-design/   # stack:fsd일 때만 (FSD opt-in)
      SKILL.md
      references/
.codex/
  agents/                    # Codex 또는 둘 다를 선택한 standard
    explorer.toml             # model·model_reasoning_effort가 지정된 read-only agent
    test-engineer.toml
    developer.toml
    reviewer.toml
    docs-updater.toml
CLAUDE.md                    # Claude 또는 둘 다를 선택했을 때만; 내용: "@AGENTS.md"
.claude/
  agents/                    # explorer/developer/test-engineer/reviewer/docs-updater 위임본. 각 파일 frontmatter에 §4 표의 `model` 필수
  commands/                  # Claude 슬래시 커맨드 진입점
  skills/                    # Claude 또는 둘 다 + stack:frontend일 때만. .agents/skills와 동일 프론트 판단 Skill 사본
  workflows/                 # Claude Dynamic Workflow 스크립트 (진입점이 scriptPath로 호출)
  settings.json              # 감지된 빌드/테스트 명령 allowlist (+ guard 시 PreToolUse hook)
```

## 4. 작성 원칙

- **AGENTS.md 구성**: Preflight(작업 시작 절차) / Hard constraints / Direct edit guard 룰(선택 시) / 워크플로·페르소나 표 / docs 목록 / Quick Commands(감지된 명령) / Git 컨벤션(실측 + 인터뷰 답)
- **Hard constraints는 틀만 만들고 비워둔다** — "실측으로 검증된 룰만 추가. 추측 금지" 주석 한 줄. 이 섹션은 `/harvest`가 시간을 들여 채우는 영역
- docs는 실측 내용만. 확인 못 한 건 쓰지 말고 "코드를 source of truth로 확인" 문구로 대체
- 페르소나 write scope는 좁게 (test-engineer는 테스트 디렉토리만 등). 경로는 **실측 모듈 구조**로 쓴다 — 멀티모듈이면 루트 `src/**`가 아니라 `<module>/src/main/**`·`<module>/src/test/**`처럼. 생성 뒤 각 패턴이 저장소 파일에 하나 이상 매칭되는지 확인한다. 매칭이 없는 범위는 역할을 아무 일도 못 하게 만들거나, 우회 편집을 낳는다
- settings.json allowlist는 read-only·빌드·테스트 명령만. deny에 force push
- direct-edit-guard.sh는 소스 경로 수정 전 code-conventions.md(테스트면 testing.md 추가) Read 여부를 transcript에서 grep — 미Read 시 exit 2 + 안내. transcript 접근 불가 시 fail-open(exit 0)
- guard의 기준 경로는 `${CLAUDE_PROJECT_DIR}`가 아니라 hook 입력의 `cwd`에서 구한 git root(`git -C "$cwd" rev-parse --show-toplevel`)다. settings.json의 hook 명령도 `"$(git rev-parse --show-toplevel)/.ai-harness/hooks/direct-edit-guard.sh"`로 쓴다. 상위 폴더에서 시작해 `/cd <저장소>`로 들어온 세션은 저장소 settings·hook을 로드하지만 `CLAUDE_PROJECT_DIR`은 시작 디렉토리를 가리켜, 변수 기준 경로는 스크립트를 찾지 못하거나 다른 저장소의 docs를 기준으로 판정한다
- **차단 메시지 첫 줄은 반드시 `[Direct edit guard] ` 접두어로 시작한다** (대괄호 포함). `scripts/extract-claude.jq`·`scripts/extract-codex.sh`가 이 접두어로만 `guard_block` 신호를 집계하기 때문이다. 접두어가 없으면 실제 차단이 계측에서 조용히 사라져 `/metrics`·`/harvest`가 "차단 0건"으로 오판한다. 반대로 AGENTS.md 본문의 `Direct edit guard` 섹션 제목처럼 대괄호 없는 문구는 Read 출력에 섞여도 집계되지 않아야 하므로, 안내 본문에 대괄호 형태를 중복해 쓰지 않는다. 집계는 Claude에서는 `is_error` tool_result, Codex에서는 출력 **줄 시작**의 접두어만 세므로, 훅은 stderr + exit 2로 차단하고 접두어를 첫 줄 첫 글자에 둔다. Claude Code는 훅 stderr를 `PreToolUse:<툴> hook error: [<훅 경로>]: ` 로 감싸 tool_result에 넣으므로, 추출기는 줄 시작의 그 래퍼까지만 허용한다 — 훅이 접두어 앞에 자기 문구를 더 붙이면 집계에서 빠진다.
- `/implement-feature`는 플러그인 전역 Skill이 아니라 `standard` 초기화에서 생성하는 **프로젝트 로컬 기능 개발 진입점**이다. `templates/implement-feature/`를 기반으로 Codex는 `.agents/skills/implement-feature/SKILL.md`, Claude는 `.claude/commands/implement-feature.md`를 생성한다. 템플릿의 그래프는 `.ai-harness/workflows/feature-delivery-graph.json`에도 복사하고, 두 진입점은 이 프로젝트 로컬 파일과 `.ai-harness/workflows/implement-feature.md`, 필요한 docs를 먼저 읽어 프로젝트별 정책을 우선하도록 한다. `.ai-harness/`는 프로젝트 특화 규칙의 단일 출처다.
- `templates/implement-feature/references/feature-delivery-graph.json`은 생성 원본이며, 프로젝트에 복사된 `.ai-harness/workflows/feature-delivery-graph.json`이 Codex·Claude 공통 노드/전이 계약의 단일 출처다. Codex는 생성된 프로젝트 Skill과 `.codex/agents/` 위임으로 이를 해석한다. Claude를 선택했을 때는 `claude --version`을 확인하고 **2.1.154 이상**에서만 프로젝트의 `.claude/workflows/implement-feature.js`를 승인 후 구현·리뷰 루프에 선택적으로 사용한다고 안내한다. Dynamic Workflow가 없거나 실행 중 사용자 판단이 필요하면 생성된 프로젝트 command의 현재 세션 흐름으로 폴백한다. 같은 디렉터리의 `implement-feature-driver.sh`(관리 생성물)는 이 그래프를 모델 밖에서 실행하는 러너다. 진입점은 러너가 있으면 `start` → (사용자 피드백 시 `revise`) → 사용자가 대화에 직접 `승인` 입력 → `resume` 순으로 쓴다. 러너는 그래프의 `transitions`에 선언된 전이만 따르고, `write:false` 노드는 읽기 전용 세션과 작업 트리 지문 비교로, `actor:"human"` 노드는 실행 중단(체크포인트 후 exit 10)으로 다루며, 승인은 트랜스크립트의 사용자 메시지 또는 터미널 `approve`만 인정한다. manifest `approval:"auto"`면 Brief에 열린 질문이 없을 때 그래프의 `auto_approved_by_policy` 엣지로 통과하고(프로젝트 그래프에서 이 엣지를 지우면 auto여도 사람을 기다린다), `git_policy`가 `pr-only`·`direct`면 deliver·repair 뒤 로컬 체크포인트 커밋을 남기고 `publish` 노드에서 커밋·일반 push·PR을 맡긴 뒤 결과를 git 상태(미커밋 없음·리뷰한 트리와 같음·upstream에 push됨·pr-only면 PR URL)로 확인한다. 그 밖의 `git_policy`면 publish는 아무것도 하지 않고 변경을 커밋하지 않은 채 끝난다. 그래프를 바꾸면 러너 동작도 바뀐다.
- 템플릿에서 생성할 `implement-feature.md`는 프로젝트 정책에 맞춰 구체화한다: 먼저 구현 범위·비범위·검증 케이스·예상 변경 영역·검증 명령을 `Implementation Brief`로 사용자에게 보이고 **명시 승인을 받을 때까지 파일을 수정하지 않는** 계획 게이트를 둔다(manifest `approval:"auto"`면 Brief를 PR 본문에 남기고 열린 질문이 없을 때 통과 — 게이트의 모드는 본문이 아니라 manifest가 정하므로 본문은 "프로젝트 승인 정책에 따라"로 적는다). 현재 대화에 같은 범위의 승인된 Brief가 있으면 재승인은 요구하지 않는다. 승인 뒤 요구사항을 관찰 가능한 검증 케이스와 1~3개 케이스의 delivery slice로 나눈다. 테스트 정책이 TDD일 때만 Red 실패 확인 → 최소 Green → 테스트를 바꾸지 않는 Refactor를 요구하고, 그 외 정책은 프로젝트가 정한 테스트 순서·필수 여부와 가능한 빌드/lint/type 검증을 따른다. 완료 전에는 blocking finding이 0개가 될 때까지 **리뷰 → 원인별 수정 → targeted/전체 검증 → 재리뷰**를 반복하며, 수정이 그래프의 수리 한도(`limits.max_repair_attempts`)에 이르도록 남으면 사용자 판단으로 올린다 — 본문에 횟수를 따로 쓰지 않고 "그래프 수리 한도"로 참조한다. 역할 분리는 선택한 도구와 작업 위험이 뒷받침할 때만 사용하며, 역할 도구가 없다는 이유로 단일 세션 작업을 중단하지 않는다.
- 워크플로 본문의 **도구 매핑**은 아래로 고정하고, 존재하지 않는 도구를 적지 않는다(`/plan`·`/team` 같은 커맨드, 옛 이름 `Task 도구` 금지 — 그래프 json이 계약의 단일 출처이고 본문은 그것을 실행하는 방법만 적는다).
  - **Claude**: 위임은 Agent 도구의 `subagent_type`. manifest `roles`가 슬롯을 기존 에이전트·라우터에 넘겼으면 그 이름(또는 "라우터 `<path>`가 정한 담당")을 쓴다. 계획은 대화 안의 Brief로 보이고 승인받는다. Dynamic Workflow는 위 버전 조건에서만 선택적으로.
  - **Codex**: `.codex/agents/*.toml` 네이티브 서브에이전트를 우선한다. 없으면 `codex exec -C <저장소 루트> -s <read-only|workspace-write> -o <결과 파일>`로 역할 프롬프트를 넘긴다 — 기본 sandbox가 읽기 전용이므로 쓰기 단계에는 `workspace-write`를 명시하고, 결과는 파일로 받아 부모가 검증한다. 둘 다 없으면 현재 세션에서 페르소나 지침을 전환해 진행한다.
  - 반복 한도·종료 조건·PR 여부는 본문에 따로 숫자를 쓰지 않고 그래프와 git 정책을 따른다. 그래프에 없는 필수 단계(docs 갱신 등)를 본문이 추가로 강제하지 않는다.
  - PR은 그래프의 `publish` 노드다. manifest `git_policy`가 `pr-only`면 커밋·일반 push·PR 생성, `direct`면 커밋·일반 push(PR은 워크플로가 요구할 때만), 그 밖이면 건너뛴다. 본문은 이 노드가 쓸 **프로젝트 사실만** 적는다: 기준 브랜치, 작업 브랜치 이름 규칙, 커밋 메시지 규칙, PR 도구(실측 — 예: Bitbucket이면 `/bitbucket`, GitHub이면 `gh pr create --base <기준>`), 검토자·라벨 기본값. 에이전트가 이 값을 사용자에게 묻지 않게 하는 것이 목적이다. 병합·force push는 어느 정책에서도 단계로 두지 않는다.
- **역할 agent 보고 규율**: 생성하는 역할 agent 본문은 보고를 고정된 절로 끝낸다 — 한 것(검증 명령과 결과), **안 한 것과 이유·버린 대안**, 미검증(무엇을 몇 개 봤는지, 못 본 것은 못 봤다고), 그리고 마지막 줄 `다음 담당: <역할>: <할 일 — 파일:줄> | 없음`. 부모 세션은 `다음 담당`이 `없음`이고 검증·리뷰 게이트가 통과해야 그 slice를 닫는다. 두 역할이 서로 넘기기만 하면 두 번째 왕복에서 끊고 사용자에게 올리며(그래프의 수리 반복 한도와 별개인 넘김 루프 한도다), 위임 중 생긴 사용자 질문은 모아서 한 번에 묻는다. §1-1에서 기존 라우터에 매핑한 프로젝트는 라우터가 정한 넘김 형식을 우선한다.
- **역할 범위 위반을 발견하면 변경을 폐기하지 않는다** — 작업을 멈추고, diff를 보존하고, 어느 파일이 어느 역할 범위인지 확인한 뒤 올바른 역할에 재위임한다. 확인 없는 폐기는 사용자 작업과 다른 역할의 산출물을 함께 지운다.
- `/fix-bug`도 플러그인 전역 Skill이 아니라 `standard` 초기화에서 생성하는 **프로젝트 로컬 버그 수정 진입점**이다. `templates/fix-bug/`를 기반으로 Codex는 `.agents/skills/fix-bug/SKILL.md`, Claude는 `.claude/commands/fix-bug.md`를 생성한다. 템플릿의 그래프는 `.ai-harness/workflows/bug-fix-graph.json`에도 복사한다. 승인 전에는 관찰·재현·원인 가설만 허용하고, 재현 불가이며 안전한 관측 계획도 없으면 수정하지 않고 사용자에게 필요한 환경·로그·기대 동작을 요청한다.
- 템플릿에서 생성할 `fix-bug.md`는 관찰된/기대 동작, 영향, 재현 증거, 원인 가설과 반증 가능성, 회귀 검증, 최소 변경 범위를 담은 `Bug Fix Brief`를 먼저 제시하고 **명시 승인을 받을 때까지 파일을 수정하지 않는** 게이트를 둔다. 승인 뒤 프로젝트 테스트 정책에 따라 회귀 테스트 또는 동등한 검증 증거를 만들고(**회귀 테스트는 test-engineer, production 수정은 developer** — developer 범위는 테스트 경로를 포함하지 않으므로 회귀 테스트를 developer에 맡기지 않는다. test-engineer를 만들지 않은 정책이면 developer 범위에 테스트 경로를 넣는다), targeted/전체 검증과 **리뷰 → 원인별 수정 → 재검토**를 수행한다. 수정이 그래프의 수리 한도(`limits.max_repair_attempts`)에 이르도록 남거나 제품·환경 판단이 필요하면 사용자에게 넘긴다. 승인 게이트의 모드와 PR 단계는 `implement-feature.md`와 같이 manifest `approval`·`git_policy`와 그래프 `publish` 노드를 따른다.
- `/review`도 `standard` 초기화에서 생성하는 프로젝트 로컬 진입점이다. `templates/review/`를 기반으로 Codex는 `.agents/skills/review/SKILL.md`, Claude는 `.claude/commands/review.md`를 생성하고 graph를 `.ai-harness/workflows/review-graph.json`에 복사한다. 초기 검토는 read-only이며, blocking finding이 있으면 대상 workflow로 수리한 뒤 필수 검증과 재검토를 거치기 전에는 완료하지 않는다.
- `/understand-change`는 위 셋과 달리 **플러그인 전역 Skill**(`skills/understand-change/`)이며 프로젝트에 진입점을 생성하지 않는다. 코드를 수정하지 않는 설명 전용 흐름이라 테스트·Git 정책 같은 프로젝트 계약을 담지 않고, 프로젝트별 조정은 런타임에 `.ai-harness/workflows/understand-change.md`를 읽어 해결한다. 따라서 관리 생성물·동기화 대상이 아니다. 초기화에서는 그 `understand-change.md`만 사람 소유 보호 파일로 만들어 프로젝트 문서·검증 명령·공유 위치와 small / standard / deep 설명 깊이 기준을 연결한다(없어도 스킬은 내장 기본값으로 동작한다). 설명은 변경 전 배경, 직관, 실행 흐름, 위험, 직접 검증을 포함하며, standard·deep에서는 이해 확인 문제를 추가한다. deep 변경에서만 상태를 조작하거나 단계별 실행을 관찰하는 micro-world의 최소 형태를 제안하며, 사용자의 별도 승인 없이는 구현하지 않는다.
- `/explain-for`도 **플러그인 전역 Skill**(`skills/explain-for/`)이며 프로젝트에 진입점이나 보호 파일을 만들지 않는다. 설명을 청자(역할·숙련도)에 맞춰 다시 쓰는 읽기 전용 흐름이라 프로젝트 계약이 필요 없고, 팀 역할 이름·공유 위치·사내 용어 같은 조정이 필요한 프로젝트만 `.ai-harness/workflows/explain-for.md`를 직접 만들어 두면 스킬이 런타임에 읽는다. 초기화는 그 파일을 생성하지 않으며, 관리 생성물·동기화 대상도 아니다. `/understand-change`가 *무엇이 왜 바뀌었나*를 답하고, `/explain-for`는 그 결과를 *누구에게 어떻게 말하나*로 바꾼다.
- `/diagram`도 **플러그인 전역 Skill**(`skills/diagram/`)이며 프로젝트에 진입점이나 보호 파일을 만들지 않는다. 플러그인에 고정된 Archify 엔진(`vendor/archify/`)으로 다이어그램을 그리고, 초기화가 만든 `.ai-harness/docs/architecture.md`는 어디를 볼지 정하는 지도로만 읽는다 — 근거는 커밋된 소스다. 관리 생성물·동기화 대상이 아니다.
- **프론트 판단 Skill**(`frontend-fundamentals`·`declarative-code`·`frontend-testing`·`no-unnecessary-effects`, FSD면 `feature-sliced-design` 추가)은 `implement-feature` 부류와 달리 워크플로 어댑터가 아니라 `templates/<name>/`의 **자립 지침을 프로젝트로 복사**한 것이다. 코드를 직접 바꾸지 않는 읽기 전용 판단이지만 프론트엔드 전용이라 플러그인 전역 Skill로 두지 않는다 — 백엔드 저장소에 노출되면 노이즈이므로, 프론트엔드로 감지된 프로젝트에서만 stack 게이트(`frontend`/`fsd`)로 생성한다. Codex는 `.agents/skills/<name>/`, Claude는 `.claude/skills/<name>/`에 SKILL.md와 `references/`를 통째로 복사한다. 각 Skill이 참조하는 프로젝트 고유 사실(디자인 시스템·테마 토큰명, 선언 사다리, FSD 여부)은 `templates`를 일반화하며 빠졌으므로 `.ai-harness/docs/frontend.md`에 실측으로 채운다(보호 파일 — 자동 갱신하지 않는다). Skill 본문은 이 문서가 있으면 우선하도록 이미 적혀 있다. `feature-sliced-design`·`no-unnecessary-effects`는 각각 MIT 라이선스 상류의 사본이며(`THIRD-PARTY-LICENSES.md`), 복사본에도 각 SKILL.md 하단의 저작권 문구가 남는다.
- AGENTS.md 워크플로 표에는 `/implement-feature`·`/fix-bug`·`/review`를 프로젝트 진입점으로 싣고, `/understand-change`와 `/explain-for`는 **플러그인 제공 스킬**로 구분해 표기한다 — 프로젝트 파일이 아니므로 하네스 동기화가 아니라 플러그인 설치로 제공된다는 점을 함께 적는다. 프론트 판단 Skill을 생성했으면 프로젝트 로컬 Skill로 표에 함께 싣는다.
- Claude 어댑터도 프로젝트 로컬 workflow·graph를 `@.ai-harness/...`로 참조한다. Claude Code가 **2.1.154 이상**이면 승인 후 프로젝트의 `.claude/workflows/<name>.js`를 선택적으로 사용할 수 있고, 그렇지 않으면 현재 세션 흐름으로 폴백한다. 워크플로는 이름으로 등록되지 않으므로 **프로젝트 루트 기준 절대 경로**를 `scriptPath`로 넘겨 호출하고, 승인된 Brief를 `{ approved: true, brief: "...", max_repair_attempts: <그래프 limits.max_repair_attempts> }`로 전달한다(review.js는 `{ scope, max_repair_attempts }`). 상대 경로는 셸 작업 디렉터리 기준으로 해석되어 실패할 수 있다. 사용하지 않는 도구의 디렉터리·설정 파일은 만들지 않는다.
- 모델은 역할 agent 정의에 직접 지정한다. 이는 사용자 인터뷰 항목이 아니며, 기본 매핑은 아래와 같다. **`model` 없는 역할 agent는 생성 실패로 취급한다** — Claude Code는 frontmatter에 `model`이 없으면 부모 세션 모델을 상속하므로, reviewer가 sonnet으로 내려가거나 developer가 opus로 올라가 등급 설계가 무력화되고 비용도 부모 모델 기준으로 붙는다. 표에 없는 역할을 새로 만들면 그 역할의 기본 모델도 표에 함께 추가한다. 중요한 보안·데이터 마이그레이션·복잡한 장애 분석은 explorer/test-engineer에 맡기지 않고 developer 또는 reviewer로 승격한다.

| 역할 | Codex agent 설정 | Claude agent 설정 | 위임 기준 |
|---|---|---|---|
| explorer | `gpt-5.6-terra`, `low`, read-only | `haiku` | 범위가 독립적인 코드 탐색·문서 확인만 |
| test-engineer | `gpt-5.6-terra`, `medium` | `sonnet` | 재현·테스트 추가. 원인 분석이 복잡하면 developer로 승격 |
| developer | `gpt-5.6`, `medium` | `sonnet` | 구현·수정의 기본 담당 |
| reviewer | `gpt-5.6`, `high`, read-only | `opus` | 보안·데이터·설계·마이그레이션 검토에 우선 사용 |
| docs-updater | `gpt-5.6-terra`, `medium` | `sonnet` | 코드 변경 뒤 docs 영향 분석·갱신 |

- 위임은 모델 등급과 무관하게 부모 컨텍스트·도구 호출 비용이 든다. 독립적이고 범위가 좁은 작업에만 쓰며, 단순 작업은 현재 세션에서 직접 처리한다.
- Codex 통합은 `.codex/agents/*.toml`에 `name`, `description`, `developer_instructions`, `model`, `model_reasoning_effort`, 필요 시 `sandbox_mode`를 쓴다. Claude 통합은 `.claude/agents/*.md` frontmatter의 `model`에 위 별칭을 쓴다. 선택한 도구에서 기본 모델이 사용 불가하면 설정을 억지로 대체하지 말고, 감지된 오류와 대체 후보를 사용자에게 보여 준다.

매니페스트 형식 (인터뷰 답 기록 — 수준 변경·/harvest의 정책 참조용):

```json
{ "project_id": "<origin 저장소명 또는 사용자 확인 ID>", "level": "standard", "test_policy": "tdd", "git_policy": "pr-only", "approval": "human", "integrations": ["codex"], "stacks": [], "edit_guard": false, "initialized": "YYYY-MM-DD", "harness_version": "<플러그인 버전>", "managed_files": { "<relative path>": { "content_sha256": "<생성 직후 해시>", "template_version": "<플러그인 버전>" } },
  "roles": { "<slot>": { "source": "existing", "integrations": ["claude"], "agents": ["<기존 에이전트 이름>"], "router": "<라우터 스킬 경로, 있을 때만>" } },
  "excluded": { "<relative path>": { "reason": "existing | <사용자가 뺀 이유>", "since": "YYYY-MM-DD" } } }
```

- `git_policy`: `pr-only` | `direct`. 그 밖의 값이나 미설정은 에이전트가 별도 허가 없이 커밋·push·PR을 하지 않는 것으로 읽는다. `approval`: `human`(기본, 미설정 포함) | `auto`. 둘 다 어댑터·러너가 런타임에 읽는다.
- `roles`에 없는 슬롯은 하네스 페르소나를 생성한 것으로 본다. `roles`·`excluded`는 손으로 쓰지 않는다 — `excluded`는 `harness-sync-state.sh exclude|include`로, `roles`는 인터뷰 확정 결과를 jq로 기록한다.
- `excluded`에 있는 경로는 plan에서 `action:"excluded"`로만 보이고 add·refresh 대상이 되지 않는다. 되돌리기는 `include`.

## 5. 마무리

1. **생성물 자기 검증 (보고보다 먼저)** — 아래를 실행해 역할 agent의 `model` 누락을 잡는다. 출력이 있으면 §4 표 기본값으로 채운 뒤 다시 실행하고, 출력이 빈 상태가 되기 전에는 2번으로 넘어가지 않는다.

```bash
shopt -s nullglob
for f in .claude/agents/*.md;  do grep -q '^model:' "$f"            || echo "model 누락: $f"; done
for f in .codex/agents/*.toml; do grep -q '^model[[:space:]]*=' "$f" || echo "model 누락: $f"; done
```

   선택하지 않은 도구의 디렉터리는 애초에 없으므로 `nullglob`으로 루프를 건너뛴다(가드가 없으면 매치 없는 글롭이 리터럴로 바인딩돼 오탐이 난다). Codex 쪽은 `model_reasoning_effort`가 `^model`에 걸리므로 `=`까지 anchor한다.

2. 생성 파일 목록 + 각 파일이 실측에서 가져온 근거 요약 보고 (1번 검증을 통과한 뒤에만)
3. 커밋/PR은 사용자 확인 후 (프로젝트 git 컨벤션 따름)
4. 생성 직후 하네스가 관리하는 생성물(프로젝트 로컬 Skill/command, graph, agent 설정, settings)을 아래 명령으로 기록한다. `AGENTS.md`, `.ai-harness/docs/`, 사람이 작성한 workflow 본문은 관리 목록에 넣지 않는다.

```bash
$ROOT/scripts/harness-sync-state.sh record --root . --version <플러그인 버전> \
  --file <관리 생성물 상대 경로> [...]
```

5. 선택한 도구의 진입점과 agent 모델 기본값을 안내: Codex는 `.agents/skills/`의 자연어 호출과 `.codex/agents/`, Claude는 `.claude/commands/`와 `.claude/agents/`를 사용한다. 모델을 사용할 수 없다는 오류가 있으면 대체 후보를 사용자에게 제시한다. 이후 세션부터 활동이 자동 수집되며, 2~4주 뒤 `/metrics`로 관찰, `/harvest <프로젝트>`로 개선 사이클을 시작한다.

## 6. 기존 하네스: 동기화와 설정 변경

1. **현재 상태 파악**: `.ai-harness/harness.json`을 Read하고, 플러그인 루트 `release.json`의 버전과 비교한다. manifest가 없으면 파일 구조로 역추정한다 — 워크플로·페르소나 유무 = standard, guard hook 유무 = `edit_guard:true`, `.agents/skills`와 `.claude` 유무 = 도구 통합, test-engineer·testing.md 유무 = 테스트 정책. `stacks`가 manifest에 없으면 파일로 역추정한다 — `*/skills/frontend-fundamentals` 등 프론트 판단 Skill이 있으면 `frontend`, `*/skills/feature-sliced-design`이 있으면 `fsd`도 포함으로 본다. 기존 `level:"full"`은 `level:"standard", edit_guard:true`로 이관 제안한다. `approval`이 없으면 `human`으로 본다 — 기존 프로젝트의 승인 게이트는 그대로이고, 바꾸려면 `--reconfigure`의 8번이다.
2. **모드 선택**: `--sync`이면 인터뷰 없이 동기화 계획을 만들고, `--sync --apply`이면 아래 안전 규칙으로 적용한다. `--reconfigure`이면 2번 수준 인터뷰를 진행한다. 인자가 없으면 현재 설정·버전을 보여 주고 동기화 / 설정 변경 / 둘 다 중 사용자 선택을 받는다.
3. **동기화 계획**: 관리 대상은 `templates/managed-files.json`이 단일 출처다. 아래 명령으로 현재 level·integration·stack에 맞는 대상과 `add` / `refresh` / `approval_required` 결정을 JSON으로 만들고, 사람이 읽을 수 있는 표와 최신 템플릿 diff를 함께 제시한다. plan은 artifact의 `stack`이 manifest `stacks`에 없으면 건너뛴다 — 백엔드 프로젝트에는 프론트 Skill이 계획에 오르지 않고, 나중에 프론트 스택이 생겨 `--reconfigure`로 `stacks`에 추가하면 그때 add 대상이 된다. 과거 버전처럼 `managed_files` 이력이 없는 기존 파일은 **untracked**로 분류한다.

```bash
$ROOT/scripts/harness-sync-state.sh plan --root . \
  --catalog "$ROOT/templates/managed-files.json"
```
   - **추가 가능**: 새로 도입된 graph, 프로젝트 로컬 Skill/command, agent 설정처럼 대상 파일이 없는 관리 생성물
   - **자동 갱신 가능**: 상태가 `unchanged`인 관리 생성물. 최신 템플릿으로 재생성하고 hash를 갱신한다.
   - **승인 필요**: `modified` 또는 `untracked`인 관리 생성물. 3-way 성격의 현재 파일/마지막 생성 해시/제안 템플릿 diff를 보여 주고, 파일별 사용자 승인을 받은 뒤에만 갱신한다.
   - **보호됨**: `AGENTS.md`, `.ai-harness/docs/**`, 사람이 작성한 workflow 본문. 자동 갱신하지 않으며 개선 제안 diff만 제공한다.
   - **코드↔docs drift** (보호 파일에 대한 **읽기 전용 리포트** — 자동 수정하지 않는다): 관리 생성물 동기화는 템플릿 대비 구조만 보므로, 빌드 파일이 바뀌고 문서가 그대로인 상태는 이 경로로만 드러난다. 아래를 실행해 `missing_in_docs`(빌드에 있는데 어느 문서에도 안 적힌 검증 태스크·스크립트·프로파일·태그)와 `stale_in_docs`(문서가 부르는데 빌드에 없는 것)를 **"보호 파일 후속 조치" 표에 행으로 싣는다**. `timestamps.docs_older_than_build`가 true면 정확도 낮은 약한 신호로 함께 적되 그것만으로 행을 만들지는 않는다. 수정은 사용자 승인 또는 문서 담당 페르소나에게 넘긴다 — 문서는 보호 파일이라 `--apply`에서도 건드리지 않는다.

```bash
$ROOT/scripts/docs-drift.sh scan --root .
```

     기계로 확인 가능한 토큰만 본다: Gradle 검증 태스크(이름에 test/check/verif/lint/coverage/e2e/integration/regression/migrat/format 포함, 또는 `<Test>` 타입 — stale 판정은 이름과 무관하게 선언된 태스크 전부와 비교)와 JUnit `includeTags`/`excludeTags`, npm `scripts` 키, Maven 프로파일 `<id>`, pytest `markers`. 문서 쪽은 임의 단어가 아니라 **실제 호출 형태**(`./gradlew <task> [<task>...]`, `npm run <script>`, `-P<profile>`, `-m <marker>`)만 사용으로 인정하고, 태그만 서술 언급도 인정한다. `drift: false`면 이 행을 만들지 않는다. 문서를 이해하려 들지 않으므로 서술이 낡았는지는 판정하지 못한다 — 토큰이 맞는지만 본다.
   - **워크플로 계약 drift** (보호 파일에 대한 **읽기 전용 리포트**): 워크플로 본문·페르소나·settings는 초기화 때 생성된 뒤 갱신되지 않아, 관리 생성물 해시가 모두 일치해도 그래프·어댑터와 의미가 어긋날 수 있다. 아래를 실행해 `findings`를 **"보호 파일 후속 조치" 표에 행으로 싣는다**(파일:줄 · 검사 · 토큰 · 제안). `contract_drift: false`면 행을 만들지 않는다. 수정은 사용자 승인 후에만 하고, `--apply`에서도 자동으로 고치지 않는다.

```bash
$ROOT/scripts/workflow-contract.sh scan --root .
```

     검사: `nonexistent_tool`(`/plan`·`/team`·`Task 도구` 등 없는 도구), `repair_limit`(본문의 `최대 N회`가 그래프 `limits.max_repair_attempts`와 다름 — 그 필드가 없는 이전 그래프는 전이 이름의 횟수), `discard_on_violation`(위반 시 변경 폐기), `codex_exec_unbounded`(`-C`·`-s` 없는 `codex exec`), `pr_step_forbidden_by_adapter`(본문이 PR 생성을 단계로 두는데 manifest `git_policy`가 `pr-only`·`direct`가 아니거나, 어댑터가 `git_policy`를 모르는 이전 버전이라 PR을 금지함), `regression_role`(fix-bug가 테스트 편집이 금지된 developer에 회귀 테스트를 맡김), `write_scope_unmatched`(어떤 파일과도 맞지 않는 페르소나 쓰기 범위), `guard_project_dir`(`CLAUDE_PROJECT_DIR` 기준 hook 경로), `role_agent_missing`·`role_router_missing`(manifest `roles`가 가리키는 기존 에이전트·라우터 파일이 사라짐 — 위임이 조용히 끊긴다). 기준은 §4 작성 원칙이며, 토큰만 보고 서술의 옳고 그름은 판정하지 않는다.
   - **후속 제안(`suggestions`)**: plan 출력의 `suggestions` 배열을 계획 표와 함께 **반드시 별도 "보호 파일 후속 조치" 표로 제시한다** — 건너뛰면 새 진입점이 미등재 반쪽 상태로 남는다. `workflow_body_missing`은 새 진입점이 `@`로 참조하는 `.ai-harness/workflows/<name>.md` 본문 부재, `agents_md_reference`는 AGENTS.md 커맨드 표 미등재를 뜻한다.
   - **기존 자산 재점검**: §1-1의 `existing-assets.sh scan`을 다시 돌려 init 이후 팀이 새로 넣은 에이전트·라우터·같은 이름 스킬을 찾는다. 새로 생긴 기존 에이전트가 하네스 페르소나와 역할이 겹치면 §1-1의 매핑 절차를 그대로 제안한다(사용자 확정 후 `roles` 갱신 → 대체된 페르소나는 다음 항목의 `orphaned`로 정리).
   - **고아 생성물(`orphaned`)**: 현재 설정으로는 더 이상 생성하지 않는 관리 생성물이다. `reason`은 `level_changed`·`integration_removed`·`stack_removed`·`role_adopted`(역할을 기존 에이전트에 넘김). 계획 표에 **제거 후보로 반드시 함께 제시한다** — `--reconfigure`로 integration·stack을 뺐거나 역할을 넘긴 뒤 남은 사본은 기존 에이전트와 나란히 다시 위임 대상이 된다.
   - **역할 agent `model` 드리프트** (위 분류와 별개인 **수동 점검** — 역할 agent는 `managed-files.json` 대상이 아니어서 `plan` 출력에 나오지 않는다): §5의 1번 self-check 스니펫을 그대로 실행해 `model` 없는 역할 agent를 찾고, §4 표 기본값으로 채우는 한 줄 추가를 계획 표 맨 아래에 **별도 행으로** 싣는다. 이전 버전이 누락한 채 생성한 경우가 있고, 누락된 agent는 부모 세션 모델을 그대로 상속한다. 본문은 바뀌지 않으므로 diff는 한 줄이지만, 적용은 다른 항목과 같이 사용자 승인 뒤에 한다. 해시 기록 대상이 아니므로 `record`도 하지 않는다.
   - **정리 대상(`retired`)**: 카탈로그의 `retired` 목록이 **명시적으로 내린** 생성물 중 이 프로젝트에 흔적이 남은 것이다(예: 0.16.0에서 깔렸다가 플러그인 전역 Skill로 옮겨진 `/understand-change` 사본). `present`는 파일이 디스크에 남았는지, `tracked`는 manifest가 아직 기록 중인지를 뜻하며 **둘은 따로 정리해야 한다**. 계획 표에 **반드시 함께 제시한다** — 방치하면 낡은 프로젝트 사본이 최신 플러그인 스킬을 가린다. 카탈로그에 없다는 사실만으로 추론하지 않는다: `.codex/agents/*.toml`처럼 init이 관리하지만 카탈로그가 선언한 적 없는 생성물이 있어, 추론하면 살아 있는 파일을 삭제 후보로 올린다.
4. **적용 규칙**: `--sync`만 있으면 절대 파일·manifest를 변경하지 않는다. `--sync --apply`에서도 추가 가능·자동 갱신 가능 항목만 적용하고, 승인 필요 항목은 명시 승인 범위만 적용한다. 추가 가능·자동 갱신 가능 항목은 `--apply`가 곧 승인이므로 **다시 묻지 않고** 적용한다 — 질문은 승인 필요·삭제·보호 파일 편집 항목에만 하고, 그런 항목이 여럿이면 한 번에 모아 묻는다. 그런 항목이 없으면 묻지 않고 적용 결과만 보고한다. 삭제·통합 해제는 항상 파일 목록과 별도 확인을 요구한다. 새 진입점(add) 적용 시 `suggestions`를 함께 처리한다: `workflow_body_missing`은 프로젝트 정책(테스트 정책·검증 명령·docs 매핑)에 맞춰 워크플로 본문을 생성하되 **관리 목록에는 기록하지 않는다** (이후 사람이 소유하는 보호 파일). `agents_md_reference`는 커맨드 표 한 줄 diff를 제안하고 **사용자 승인 후에만** AGENTS.md를 편집한다 — 승인이 없으면 미등재 상태와 그 영향(Preflight 라우팅에서 새 워크플로가 제외됨)을 최종 보고에 명시한다. `retired` 항목은 파일 목록을 보이고 **사용자 확인을 받은 뒤에만** `present:true`인 파일을 삭제하고, `tracked:true`인 항목은 `harness-sync-state.sh forget --file <path>`로 manifest에서 지운다 — `forget`은 manifest만 정리하며 파일을 삭제하지 않으므로 해당하는 두 단계를 모두 수행한다. 확인을 못 받으면 파일과 manifest 항목을 그대로 두고 낡은 사본이 남았다는 사실을 보고한다. `orphaned` 항목도 같은 2단계(확인 뒤 파일 삭제 + `forget`)로 정리한다. **사용자가 특정 생성물을 빼 달라고 하면**(팀 자체 흐름이 있어 `/fix-bug`가 필요 없음 등) 파일 목록을 확인받고 파일을 지운 뒤 `harness-sync-state.sh exclude --file <path> --reason "<이유>"`로 기록한다 — `forget`만 하면 다음 sync가 같은 파일을 add로 되살린다. 한 워크플로의 진입점을 모두 뺐으면 AGENTS.md 워크플로 표의 해당 행 삭제를 diff로 제안한다. 적용 뒤 실제로 쓴 관리 생성물만 `harness-sync-state.sh record`로 기록하고 `harness_version`을 갱신한다.
5. **설정 변경**: 재인터뷰 결과에 따라 diff만 적용한다. 승인 게이트·git 통제 수준 변경은 manifest `approval`·`git_policy`와 AGENTS.md Git 룰 문구만 바꾼다(어댑터·러너는 런타임에 읽으므로 재생성하지 않는다). 테스트 정책 변경은 workflow 본문의 테스트 절차, test-engineer·testing.md, AGENTS.md 위임 규칙을 갱신하되, 기존 사용자 수정은 3번의 승인 필요 규칙을 따른다.
6. 변경 요약, 건너뛴 보호 파일, 다음 동기화에서 검토할 untracked 파일을 보고한다. 커밋/PR은 사용자 확인 후에만 한다.

## 7. Workspace 모드 — 여러 독립 저장소가 한 폴더에 있을 때

cwd가 git 저장소가 아니고 하위에 독립 git 저장소가 둘 이상이면 workspace다. 이 모드는 **라우팅 층만** 만든다 — 워크플로·페르소나·hook·settings는 만들지 않고, 멤버 저장소의 하네스는 한 바이트도 바꾸지 않는다. 모노레포(git 루트 하나)는 workspace가 아니라 단일 프로젝트다.

Claude Code는 시작 디렉토리의 `.claude/`를 로드하므로 workspace 세션은 그대로는 멤버의 슬래시 커맨드·페르소나·편집 가드를 쓰지 못한다. 멤버로 들어가는 방법은 셋이다(Claude Code 공식 문서 기준).

| 방법 | 멤버 커맨드·스킬·페르소나 | 멤버 settings의 hook·권한 | 비고 |
|---|---|---|---|
| 멤버 저장소에서 새 세션 (`claude` / `codex -C <member>`) | 로드 | 로드 | 구현의 기본 경로 |
| `/cd <member>` (2.1.246+) | 로드 | 로드 | 대화 유지. `CLAUDE_PROJECT_DIR`은 시작 디렉토리로 남는다 |
| `/add-dir <member>` (cwd 하위, 2.1.257+) | 로드 | **미로드** | 편집 가드가 없으므로 구현에는 쓰지 않는다 |

플러그인 hook(`scripts/member-edit-guard.sh`)은 시작 디렉토리와 무관하게 로드되므로, workspace 세션이 하네스 멤버의 코드를 편집하려 하면 그 멤버의 워크플로를 읽기 전까지 차단한다(멤버 안에서 연 세션은 멤버의 편집 가드가 맡는다). 그래서 workspace 세션은 여러 저장소를 훑어보거나 교차 변경을 조율하는 용도이고, 한 저장소 안의 구현은 멤버 세션 또는 `/cd <member>`로 한다 — 이 안내를 workspace AGENTS.md 첫 줄에 쓴다.

### 7-1. 감지

```bash
$ROOT/scripts/workspace-scan.sh scan --root .            # 기본 depth 2
$ROOT/scripts/workspace-scan.sh scan --root . --depth 3  # 그룹 폴더가 더 깊을 때만
```

- `.git` **디렉터리**만 멤버 후보다. 서브모듈·worktree는 `.git`이 파일이라 제외되고 `node_modules` 아래는 내려가지 않는다.
- 멤버 `project_id`는 멤버 `harness.json`의 값을 우선하고, 없으면 origin 저장소명 → 폴더명 순으로 정한다(`project_id_for_cwd`와 같은 규칙). 출처는 `id_source`(`manifest` / `origin` / `path`)로 붙는다. `manifest`·`origin` 출처의 `project_id`가 여럿이면 한 저장소의 clone이므로 멤버 하나로 접고 나머지 경로를 `also_paths`에 둔다. `path` 출처(폴더명 폴백)는 identity가 아니라서 접지 않는다 — 무관한 `teamA/backend`·`teamB/backend`는 둘 다 멤버다. 다른 멤버 안에 중첩된 `.git`(커밋된 vendor clone 등)은 그 멤버의 일부로 보고 멤버로 잡지 않는다. 접은 뒤 멤버가 1개면 `candidate:false`다 — 같은 저장소의 worktree 폴더만 모인 곳은 workspace가 아니다.
- 멤버마다 `harness:true|false`와 실측 정책(`level`·`test_policy`·`git_policy`·`edit_guard`)이 붙는다. `harness:false`인 멤버는 그 저장소에 하네스가 없다는 표시이며, 이 시점에 init하지 않는다.

### 7-2. 확인

멤버 표(경로·project_id·하네스 유무·테스트 정책·git 정책·also_paths)를 보이고, `persona_shadows`가 비어 있지 않으면 **멤버 페르소나와 같은 이름의 사용자 전역 페르소나(`~/.claude/agents/`)** 목록을 경고로 함께 보인다 — workspace 세션의 `subagent_type` 위임은 멤버 쓰기 범위가 아니라 전역 페르소나로 간다. 해소는 사용자 선택이다(전역 이름 변경, 또는 멤버 코드 위임은 멤버 세션·`/cd`에서만).

그다음 AskUserQuestion으로 `workspace로 셋업` / `취소`를 받는다. workspace 수준 인터뷰는 **도구 통합**(Claude / Codex / 둘 다) 하나만 묻는다. 규모·테스트 정책·편집 가드는 멤버 각자의 것이므로 여기서 묻지 않는다.

### 7-3. 생성물

```
AGENTS.md                  # 라우팅 전용 진입점 (보호 파일)
CLAUDE.md                  # "@AGENTS.md" — Claude 또는 둘 다를 선택했을 때만
.ai-harness/
  workspace.json           # 매니페스트. harness.json과 파일명이 달라 단일 프로젝트와 섞이지 않는다
```

매니페스트는 손으로 쓰지 않고 스크립트로 기록한다. 생략한 값은 기존 manifest에서 유지되고 `harness_version`은 현재 플러그인 버전으로 찍힌다. 첫 기록은 `candidate:true`일 때만 되고 git 저장소 안에서는 거부된다. 기존 manifest의 재기록(7-6)은 멤버가 줄어도 허용된다.

```bash
$ROOT/scripts/workspace-scan.sh write --root . --workspace-id <폴더명 또는 사용자 확인 ID> --integrations claude
```

`managed_files`는 없다. AGENTS.md·CLAUDE.md는 보호 파일이고 그 외 관리 생성물이 없으므로 `harness-sync-state.sh`를 거치지 않는다. 계측은 workspace 세션을 `workspace_id`로 귀속한다(`project_id_for_cwd`가 `workspace.json`을 git 판정보다 먼저 본다). 멤버별 편집 귀속은 후속 버전에서 다룬다.

### 7-4. AGENTS.md 구성

- **첫 줄 안내**: 위 진입 방법 표와 쓰임새(훑어보기·교차 조율용, 구현은 멤버 세션 또는 `/cd <member>`).
- **Preflight**: ① 작업 대상 파일에서 위로 올라가 `.ai-harness/harness.json`이 있는 git root(`git -C <dir> rev-parse --show-toplevel`)로 멤버를 정한다 — 경로 첫 세그먼트는 `worktrees/<이슈>/<member>` 같은 worktree 배치에서 틀린다. ② 그 멤버의 `AGENTS.md`를 Read한다. ③ 멤버 코드를 바꾸는 작업이면 멤버 세션 또는 `/cd <member>`로 옮겨 멤버 워크플로를 진입점으로 쓴다. 옮길 수 없으면 `<member>/.ai-harness/workflows/<name>.md`를 **직접 읽고 절차를 따른다**. ④ workspace 세션에서 `subagent_type: developer` 같은 위임은 멤버 페르소나가 아니라 **같은 이름의 사용자 전역 페르소나(`~/.claude/agents/`)로 갈 수 있다** — 멤버 쓰기 범위가 적용되지 않으므로, 멤버 코드를 바꾸는 위임은 ③의 방법으로 멤버에 들어간 뒤 한다. 들어갈 수 없으면 `general-purpose` 프롬프트에 멤버 페르소나 지침과 파일 범위를 인라인하고 결과를 직접 확인한다. ⑤ 멤버 코드로 "현재 상태"(버전·설계·존재 여부)를 판정하기 전 `git -C <member> fetch origin` 후 `git -C <member> rev-list --count HEAD..origin/<base>`로 비교하고, 뒤처져 있으면 기본으로 `git -C <member> show origin/<base>:<path>`로 읽는다(워킹트리를 건드리지 않는다). 체크아웃 자체를 최신화(`pull --ff-only`)하는 건 `git -C <member> status --porcelain`이 비어 있고 로컬 브랜치가 origin과 diverge하지 않았을 때만 한다 — 사용자가 작업 중인 체크아웃일 수 있다. `<base>`는 멤버 AGENTS.md의 기준 브랜치 규칙을 따르고, AGENTS.md가 없으면 `git -C <member> symbolic-ref --short refs/remotes/origin/HEAD`의 기본 브랜치를 쓴다. 멤버 체크아웃은 각자 따로 pull 되어 자주 stale이고, workspace 세션은 여러 멤버를 한꺼번에 훑으므로 삭제된 브랜치·옛 코드를 현재로 오판하기 쉽다.
- **멤버 표**: 경로 · project_id · 하네스 유무 · 테스트 정책 · git 정책. `harness:false` 멤버는 "해당 저장소에서 `/harness-init` 권장"으로 표기한다.
- **교차 작업 규칙**: 멤버 둘 이상을 건드릴 때 멤버별 별도 브랜치·PR, 컨벤션은 각 멤버 것만 적용(섞지 않음), 공유 계약(API 스키마·이벤트 포맷) 변경은 제공자 → 소비자 순서, 완료 보고는 멤버별 검증 결과를 분리.
- **Hard constraints**: 틀만 비워 둔다. 단일 하네스와 같이 `/harvest`가 채운다.
- **Quick Commands**: 멤버별 빌드·테스트 명령을 `(cd <member> && ...)` 형태로. 멤버 AGENTS.md의 실측 명령을 복사하고 없으면 비운다.

### 7-5. 멤버 init 후속 단계 (opt-in)

생성물을 쓴 뒤 `harness:false` 멤버가 있으면 AskUserQuestion(multiSelect)으로 **지금 init할 멤버**를 고르게 한다. 기본값은 전부 해제다 — 다른 팀 저장소에 합의 없이 하네스를 심는 일을 막는다. 고르지 않은 멤버는 표기만 남긴다.

1. 선택된 멤버를 **한 번에 하나씩** 처리한다. 1~5번 절차를 그대로 쓰되 모든 경로를 멤버 루트 기준으로 둔다 — 분석은 `git -C <member>`·`<member>/package.json`처럼 경로를 명시하고, 기록은 `harness-sync-state.sh record --root <member>`로 한다.
2. 인터뷰는 첫 멤버에서 2번의 전체 항목을 묻고, 두 번째 멤버부터는 앞 멤버의 답을 기본값으로 보여 **"같음 / 다르게 답함"** 하나만 묻는다. 실측이 기본값과 모순되면(앞 멤버는 TDD인데 이 멤버는 테스트 0개 등) 2번의 경고 규칙대로 지적한다.
3. 멤버 하나가 끝나면 생성 파일 목록과 실측 근거를 보고하고 커밋 여부를 확인한 뒤 다음 멤버로 간다. 저장소마다 브랜치·PR이 따로이므로 한 멤버를 끝내기 전에 다음 멤버 파일을 만들지 않는다.
4. 선택이 3개를 넘으면 앞의 3개만 처리하고 나머지는 "각 저장소에서 `/harness-init`"으로 안내한다. 상위 세션 컨텍스트 보호가 목적이다. 실측 분석은 Explore 서브에이전트에 위임할 수 있지만 인터뷰는 서브에이전트가 사용자에게 질문할 수 없어 메인 세션에서 한다.
5. 모두 끝나면 `workspace-scan.sh write --root .`로 매니페스트를 다시 기록하고(멤버가 `harness:true`와 실측 정책으로 바뀐다), AGENTS.md 멤버 표는 diff를 보여 **승인 후에만** 편집한다.

### 7-6. 기존 workspace: 동기화

`scan`은 기존 `workspace.json`이 있으면 `diff`를 함께 낸다 — `added`(새 멤버 폴더), `removed`(사라진 멤버), `changed`(멤버의 하네스 유무·정책이 바뀜).

- `--sync`만 있으면 표만 보이고 파일·manifest를 바꾸지 않는다.
- `--sync --apply`: `added`·`changed`는 `workspace-scan.sh write --root .`로 manifest를 갱신한다. `removed`는 멤버 목록을 보이고 **사용자 확인 후에만** write한다(폴더가 잠시 없는 것일 수 있다). AGENTS.md 멤버 표·Quick Commands는 보호 파일이므로 diff를 제안하고 승인 후 편집한다.
- 기존 AGENTS.md Preflight에 7-4의 단계가 빠져 있거나 낡았으면(예: 이전 버전으로 만든 workspace에 Preflight ⑤ 멤버 최신 여부 확인이 없음, 첫 줄·①③④가 "cwd의 `.claude/`만 로드하므로 해결 불가"·"경로 첫 세그먼트" 기준) 같은 방식으로 diff를 제안하고 승인 후 반영한다. 사용자가 손으로 고친 문구는 덮어쓰지 않는다.
- `persona_shadows`는 7-2와 같이 경고로 보인다.
- 멤버 저장소 자체의 동기화는 여기서 하지 않는다. 각 멤버에서 `/harness-init --sync`를 안내한다.
