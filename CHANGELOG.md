# Changelog

이 파일이 릴리스 노트의 단일 출처입니다. 버전을 올릴 때 여기에 항목을 먼저 쓰고, 그 절을 그대로 GitHub 릴리스 노트로 발행합니다.

플러그인과 함께 배포되므로 네트워크 없이도 `/harness-update`가 변경점을 설명할 수 있습니다.


## v0.22.1 (2026-09-11)

`/harness-init`이 역할 페르소나를 만들 때 `model` frontmatter를 빠뜨리는 문제를 고칩니다.

### 버그 수정

- **역할 agent `model` 누락** — 모델 매핑 표는 있었지만 생성 단계가 이를 지키지 않아 `.claude/agents/*.md`에 `model` 없이 생성되는 경우가 있었습니다. Claude Code는 `model`이 없으면 부모 세션 모델을 상속하므로, reviewer가 sonnet으로 내려가거나 developer가 opus로 올라가 등급 설계가 무력화됐습니다. 이제 `model` 없는 역할 agent는 생성 실패로 취급하고, 마무리 단계에서 `.claude/agents/*.md`와 `.codex/agents/*.toml`의 `model` 누락을 직접 검사합니다.
- **`docs-updater` 기본 모델 누락** — 모델 매핑 표에 `docs-updater` 행이 없어 생성 시 참조할 기본값이 없었습니다. `sonnet`으로 추가했습니다. 표에 없는 역할을 새로 만들면 기본 모델도 표에 함께 추가하도록 규칙을 명시했습니다.

### 동작 변경

- `/harness-init --sync` 계획에 **역할 agent `model` 드리프트** 항목이 추가됩니다. 이전 버전이 `model` 없이 생성한 페르소나를 찾아 표 기본값 한 줄 추가를 제안하며, 적용은 다른 항목과 같이 사용자 승인 뒤에 합니다.

### 업데이트 후 해야 할 일

- 0.22.0 이하에서 초기화한 프로젝트는 `/harness-init --sync`로 `model` 누락을 확인하세요. 페르소나는 관리 생성물이 아니라 manifest 해시 충돌은 없으며, `.claude/agents/*.md` frontmatter에 `model:` 한 줄을 직접 추가해도 됩니다.

## v0.22.0 (2026-09-07)

여러 독립 저장소를 한 폴더에 두고 작업하는 경우를 `/harness-init`이 인식합니다. 이 릴리스는 라우팅 층까지이며, 세션 계측을 저장소별로 나누는 작업은 다음 버전에서 이어집니다.

### 새 기능

- **workspace 모드** — git 저장소가 아닌 상위 폴더에서 `/harness-init`을 실행하면 하위의 독립 git 저장소를 감지하고, 둘 이상이면 라우팅 전용 `AGENTS.md`와 `.ai-harness/workspace.json`만 만듭니다. 멤버 저장소의 하네스는 건드리지 않습니다. 라우팅 AGENTS.md는 작업 파일 경로로 멤버를 정해 그 멤버의 `AGENTS.md`와 워크플로 문서를 먼저 읽게 하고, 멤버 둘 이상을 건드리는 교차 작업 규칙(멤버별 브랜치·PR, 컨벤션 분리, 제공자 → 소비자 순서)을 담습니다.
- **멤버 init 후속 단계(opt-in)** — 하네스가 없는 멤버는 표기만 하고, 사용자가 고른 멤버만 한 번에 하나씩 기존 절차로 초기화합니다. 두 번째 멤버부터는 앞 멤버의 인터뷰 답을 기본값으로 제안하고, 한 번에 최대 3개까지만 처리합니다. 기본값은 전부 해제라 다른 팀 저장소에 합의 없이 하네스가 생기지 않습니다.
- **`scripts/workspace-scan.sh`** — `scan`은 `.git` 디렉터리만 멤버 후보로 삼아 서브모듈·worktree를 제외하고, 같은 저장소의 clone은 하나로 접고(`also_paths`), 멤버 `harness.json`의 정책을 실측하며, 기존 manifest가 있으면 `diff`를 냅니다. 폴더명으로만 식별되는 저장소(`id_source: path`)는 접지 않고, 다른 멤버 안에 중첩된 `.git`은 멤버로 잡지 않습니다. `write`는 manifest를 기록하며 git 저장소 안이거나 독립 저장소가 둘 미만이면 첫 생성을 거부합니다.

### 동작 변경

- `project_id_for_cwd`가 cwd의 `.ai-harness/workspace.json`을 git 판정보다 먼저 봐서 workspace 세션을 `workspace_id`로 귀속합니다. 단일 저장소·worktree·모노레포의 project_id는 바뀌지 않습니다.

### 알려진 한계

- Claude Code는 cwd의 `.claude/`만 로드하므로 workspace 세션에서는 멤버의 슬래시 커맨드·페르소나·편집 가드가 동작하지 않습니다. 라우팅 AGENTS.md가 워크플로 문서를 직접 읽도록 안내하는 것으로 우회합니다. 한 저장소 안의 깊은 구현은 그 저장소에서 세션을 여세요.
- workspace 세션의 편집·문서 읽힘은 아직 멤버별로 귀속되지 않습니다.

### 업데이트 후 해야 할 일

없습니다. 기존 프로젝트 하네스 생성물 변경 없음 — `/harness-init --sync` 불필요. workspace 모드는 해당 폴더에서 `/harness-init`을 실행할 때만 켜집니다.

## v0.21.0 (2026-09-02)

`/harvest`가 자기 개선의 효과를 스스로 채점하고, 노이즈 분석을 싸게 끝냅니다. Prime Agent의 continual-harness refinement 설계에서 규율만 이식했습니다.

### 새 기능

- **결과 검증 루프** — 개선 PR을 만들 때 `mark-reviewed --expected "<검증 기준>"`으로 기대효과를 기록하면, 다음 `/harvest`가 그 기준을 새 batch 신호와 대조해 지난 개선을 채점합니다. 같은 패턴이 재발했으면 강화안 또는 revert PR을 제안해, 효과 없는 규칙이 하네스에 쌓이는 것을 막습니다. `--expected` 없이 기록한 개선(기존 기록 포함)은 검증 대상에서 제외되므로 하위 호환입니다.
- **정독 게이트** — 가장 비싼 스텝(transcript 정독) 전에 batch 신호와 교정 마크 스니펫만으로 정독 가치를 판단합니다. 노이즈 batch는 정량 분석과 보고만 하고 `no-change`로 종료합니다. 정량 해석·이전 개선 검증·보고는 게이트 결과와 무관하게 항상 수행합니다.
- **최소 아티팩트 라우팅** — 개선안을 가장 작은 단위로 보냅니다: 반복 위임 역할→페르소나, 반복 절차→workflows, 불변 사실→docs, 좁은 행동 정책→AGENTS.md constraint. AGENTS.md 비대화를 막습니다.

### 업데이트 후 해야 할 일

없습니다. 프로젝트 하네스 생성물 변경 없음 — `/harness-init --sync` 불필요. 다음 `/harvest`부터 새 절차(8단계)가 적용됩니다.

## v0.20.0 (2026-09-01)

### 새 기능

- **프론트엔드 판단 Skill 5종** — React/TypeScript 저장소에서 판단이 필요한 자리를 커버합니다. `frontend-fundamentals`(코드 품질 4축 리뷰), `declarative-code`(추상화를 올릴지 판단 + 컴포넌트 API 설계), `frontend-testing`(테스트를 쓸지·어느 층위인지 결정), `no-unnecessary-effects`(`useEffect` 결정 트리), 그리고 FSD 프로젝트용 `feature-sliced-design`(FSD v2.1 구조). 전역 플러그인 Skill이 아니라 `/harness-init`이 **프론트엔드로 감지된 프로젝트에서만** 프로젝트 로컬 Skill로 생성합니다(백엔드 저장소엔 노출 안 됨). `feature-sliced-design`은 FSD를 감지했거나 사용자가 opt-in할 때만 추가합니다. 프로젝트 고유 사실(디자인 시스템·선언 사다리·FSD 여부)은 `.ai-harness/docs/frontend.md`에 실측으로 채우고 Skill이 이를 우선합니다. stack(`frontend`/`fsd`) 게이트로 동기화 대상을 거릅니다.

  `feature-sliced-design`과 `no-unnecessary-effects`는 각각 [feature-sliced/skills](https://github.com/feature-sliced/skills), [Cst2989/react-tips-skill](https://github.com/Cst2989/react-tips-skill)의 사본으로 둘 다 MIT 라이선스입니다. 저작권·라이선스 전문은 `THIRD-PARTY-LICENSES.md`에 있습니다. 상류 변경은 원본에서 다시 가져옵니다.

## v0.19.0 (2026-09-01)

기능 개발·버그 수정·검토 Dynamic Workflow가 플러그인이 아니라 프로젝트에 설치됩니다. **기존 하네스 프로젝트는 `/harness-init --sync`가 필요합니다.**

### 달라진 점

- **`/ai-harness:implement-feature`, `/ai-harness:fix-bug`, `/ai-harness:review`가 사라집니다.** 이 셋은 플러그인 전역 커맨드라 하네스가 없는 프로젝트에서도 목록에 떴지만, 직접 호출하면 `approval_required`만 반환하는 막다른 길이었습니다. 하네스가 있는 프로젝트에서는 진입점(`/implement-feature` 등)과 이름이 겹쳐 어느 쪽을 불러야 하는지 알기 어려웠습니다.
- **대신 `/harness-init`이 `.claude/workflows/`에 스크립트를 생성합니다.** Claude 통합을 선택한 `standard` 프로젝트에만 생깁니다. 프로젝트 진입점이 승인된 Brief와 함께 절대 경로를 `scriptPath`로 넘겨 호출합니다.
- **강제력은 그대로입니다.** 스키마로 검증되는 리뷰 루프, blocking finding이 남으면 완료를 반환하지 못하는 판정, `interrupted`·`review_incomplete`·`user_decision_required` 미완료 상태가 모두 유지됩니다. 실행 위치만 바뀌었습니다.

### 업데이트 후 해야 할 일

기존 하네스 프로젝트에서 `/harness-init --sync`를 실행하면 아래 3개가 **추가 가능** 항목으로 잡힙니다. `--sync --apply`로 적용하세요.

- `.claude/workflows/implement-feature.js`
- `.claude/workflows/fix-bug.js`
- `.claude/workflows/review.js`

Codex만 쓰는 프로젝트에는 해당하지 않습니다. Dynamic Workflow는 Claude Code 2.1.154 이상 전용이며, 사용할 수 없어도 기능 개발·버그 수정·검토 흐름은 현재 세션에서 그대로 유지됩니다.

## v0.18.0 (2026-08-30)

업데이트 알림이 더 안정적으로 도착하고, 업데이트를 적용한 뒤 무엇이 남았는지 알려 줍니다. 별도의 조치는 필요 없습니다.

### 새 기능

- **버전 스큐 알림** — 플러그인을 업데이트해도 실행 중인 세션은 재시작 전까지 이전 버전을 로드한 채 돕니다. 이제 설치된 버전과 현재 세션이 로드한 버전이 다르면 세션 시작 시 알려 줍니다.

  ```
  ai-harness 설치 버전은 0.18.0이지만 이 세션은 0.17.1을 로드했습니다. 새 세션을 시작하면 적용됩니다.
  ```

  업데이트 직후 "적용했는데 동작이 그대로"인 상황의 이유를 바로 알 수 있습니다.

### 개선

- **릴리스 조회가 세션 시작을 막지 않습니다.** 세션 시작 hook은 3초 예산을 여러 확인과 나눠 쓰기 때문에 조회 타임아웃이 1~2초로 빠듯했고, 느린 회선이나 VPN에서는 일상적으로 실패했습니다. 조회를 **세션 종료 시점**으로 옮기고 타임아웃을 넉넉히(연결 2초, 전체 5초) 잡았습니다. 세션 시작은 이미 받아 둔 캐시만 읽습니다.
- **조회가 이벤트 수집을 방해하지 않습니다.** 세션 종료 처리에서 조회는 수집이 모두 끝난 뒤 마지막에 돌아, 느린 네트워크가 활동 기록 수집을 지연시키거나 잃게 하지 않습니다.
- **릴리스 발행 누락을 CI가 잡습니다.** 태그만 올라가고 릴리스 노트가 없으면 `notes_url`이 404가 되고 `/harness-update`가 변경점을 요약하지 못합니다. 이제 태그와 `release.json`의 버전·URL 일치, 그리고 노트 발행 여부를 태그 push 시점에 검증합니다.

### 알아 둘 점

새로 설치한 직후에는 캐시가 비어 있어 첫 업데이트 알림이 한 세션 뒤로 밀립니다. 확인 주기가 24시간이라 실질적인 영향은 없습니다.

### 새 설정 (선택)

```bash
HM_UPDATE_CONNECT_TIMEOUT=2      # 릴리스 조회 연결 타임아웃(초)
HM_UPDATE_MAX_TIME=5             # 릴리스 조회 전체 타임아웃(초)
```


## v0.17.1 (2026-08-28)

업데이트 알림이 조용히 사라지던 문제를 고쳤습니다. 별도의 조치는 필요 없습니다.

### 수정

- **실패한 릴리스 조회가 24시간 알림 주기를 소비하지 않습니다.** 이전에는 조회 실패도 성공처럼 `checked_at`을 갱신해, 일시적인 네트워크 오류 한 번이 하루 동안 업데이트 알림을 삼켰습니다. SessionStart hook의 3초 제한 때문에 조회 타임아웃이 1~2초로 짧아 실패가 어렵지 않게 발생합니다. 이제 성공한 조회만 24시간 주기를 갱신하고, 실패는 기본 15분에서 6시간까지 배가되는 별도 백오프로 재시도하며 성공 시 초기화됩니다.
- **손상된 상태 캐시가 버전 확인을 중단시키지 않습니다.** `~/.ai-harness/update-check.json`의 값이 손상되면 확인 스크립트가 오류로 종료됐고, hook이 그 오류를 버리므로 알림만 조용히 사라졌습니다.
- **0으로 시작하는 설정값이 상태 파일을 고착시키지 않습니다.** `HM_UPDATE_CHECK_HOURS=08`처럼 0-패딩 값을 넣으면 산술 확장이 8진수로 읽어 실패했고, 상태 파일이 기록되지 않아 이후 모든 세션이 같은 오류를 반복했습니다. 이제 유효하지 않은 값은 기본값으로 되돌아갑니다.

### 개선

- **`/harness-update`가 버전 번호만 알리지 않습니다.** 새 버전이 있으면 해당 버전의 릴리스 노트를 읽어 달라진 동작·새 진입점·이동하거나 제거된 진입점과 필요한 후속 조치를 요약하고, 적용 후에도 같은 요약을 제시합니다.
- **`release.json`이 릴리스 목록 대신 해당 버전의 태그를 가리킵니다.** 어떤 변경인지 특정할 수 있습니다.

### 새 설정 (선택)

```bash
HM_UPDATE_RETRY_MINUTES=15       # 조회 실패 후 첫 재시도 간격. 0이면 백오프 없음
HM_UPDATE_RETRY_MAX_MINUTES=360  # 연속 실패 시 백오프 상한
```


## v0.17.0 (2026-08-28)

0.16.0 이후 누적된 변경입니다. **기존 프로젝트는 업데이트 후 `/harness-init --sync`가 필요합니다.**

### 달라진 진입점

- **`/understand-change`가 플러그인 전역 Skill이 되었습니다.** 이전에는 `standard` 초기화가 프로젝트마다 사본을 생성했지만, 이 워크플로는 테스트·git 정책 같은 프로젝트 계약을 담지 않아 모든 프로젝트에서 동일한 파일이었습니다. 이제 플러그인이 직접 제공하며, 런타임에 `.ai-harness/workflows/understand-change.md`를 읽어 프로젝트별 조정을 받습니다.
- 호출 경로가 `/ai-harness:understand-change`로 바뀝니다.

#### 업데이트 후 해야 할 일

기존 프로젝트에 남은 0.16.0 사본은 새 스킬을 가립니다. `/harness-init --sync`로 계획을 확인하고 `--sync --apply`로 정리하세요. 대상:

- `.agents/skills/understand-change/SKILL.md`
- `.claude/commands/understand-change.md`
- `.ai-harness/workflows/understanding-change-graph.json`

카탈로그에서 빠진 생성물이 manifest에 남아 있던 문제를 위해 retired 목록과 forget 명령을 추가했으므로, 동기화 계획이 이 세 파일을 명시적으로 제안합니다.

### 개선

- **동기화 계획에 protected-file 제안 표시** — 새 진입점이 절반만 등록되는 것을 막습니다. 참조된 `.ai-harness/workflows/<name>.md`가 없으면 `workflow_body_missing`, AGENTS.md 커맨드 표에 새 커맨드가 없으면 `agents_md_reference`로 표시하고, AGENTS.md 행 추가는 사용자 승인 후에만 적용합니다.
- **메트릭 오탐 수정** — `guard_block`이 AGENTS.md 본문의 "Direct edit guard" 문구에도 매칭돼 AGENTS.md를 읽을 때마다 hook 차단으로 집계됐습니다(실측 30일: 106건 전부 오탐, 실제 차단 0건). 이제 hook stderr 접두사 `[Direct edit guard]`만 매칭합니다. AskUserQuestion의 "clarify" 응답이 `permission_deny`로 세지던 문제도 함께 수정했습니다.
- **Codex `harness_doc` 누락 수정** — 한 exec에 여러 문서를 읽으면(`sed A && sed B`) 첫 건만 집계돼 doc_read 커버리지가 낮게 나왔습니다. 이제 모든 매치를 기록합니다.
- **guard hook 출력 계약 명시** — `harness-init`이 생성하는 guard hook은 `[Direct edit guard]` 접두사를 반드시 출력해야 합니다. 접두사가 없으면 실제 차단이 `/metrics`·`/harvest`에서 조용히 사라집니다.


## v0.16.0 (2026-08-23)

첫 공개 태그 릴리스입니다. Claude Code와 Codex CLI에서 프로젝트별 AI 작업 규칙을 만들고, 실제 작업 기록으로 개선하는 듀얼 플러그인입니다.

### 새 기능

- **`/understand-change` 워크플로** — `standard` 초기화가 생성하는 프로젝트 로컬 변경 설명 진입점. 변경의 배경·직관·실행 흐름·위험·직접 검증을 small/standard/deep 깊이로 설명하고, standard 이상에서는 이해 확인 문제를 제공합니다. 그래프 계약(`understanding-change-graph.json`)과 전용 검증 스크립트 포함.
- **Codex 활동 메트릭 확장** — Codex rollout에서 수집하는 활동 범위를 넓히고, 이벤트 버전을 v3로 올려 기존 Codex 이벤트를 backfill에서 자동 재추출합니다.

### 개선

- lock 회수·프로젝트 키 인코딩을 `lib.sh` 공용 헬퍼로 통합해 `harvest-queue.sh` / `health.sh` / `prune.sh`의 중복 구현 제거
- `stats.jq` 세션 소속 판정을 배열 스캔에서 객체 lookup으로 교체 (이벤트 누적 시 성능)
- `/ai-harness:review` Dynamic Workflow와 `templates/`·`tests/` 구조를 문서에 반영

### 라이선스

- **MIT 라이선스 채택** — LICENSE 파일 추가, 두 플러그인 매니페스트에 `license` 필드 선언
