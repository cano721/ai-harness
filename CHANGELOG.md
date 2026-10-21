# Changelog

이 파일이 릴리스 노트의 단일 출처입니다. 버전을 올릴 때 여기에 항목을 먼저 쓰고, 그 절을 그대로 GitHub 릴리스 노트로 발행합니다.

플러그인과 함께 배포되므로 네트워크 없이도 `/harness-update`가 변경점을 설명할 수 있습니다.

작업 중인 변경은 `## Unreleased`에 쌓이고, 릴리스할 때 `scripts/release-prep.sh <version>`이 그 절을 버전 절로 확정합니다. 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md)에 있습니다.


## Unreleased

### 동작 변경

- **자동 sync가 실행 하나가 끝나면 다음 저장소를 이어서 처리합니다** — sweep 1회에 1건만 띄우고 다음 sweep(6시간 뒤)을 기다려, 뒤처진 저장소 6개가 따라오는 데 며칠이 걸렸습니다. 동시 실행은 여전히 1개이고 사용량 한도로 끝난 실행 뒤에는 멈춥니다. 하루 상한 `HM_SYNC_AUTO_DAILY_MAX` 기본값도 2 → 6 (자동 실행 31회 실측 평균 $0.71). (#141)

## v0.40.0 (2026-10-20)
### 새 기능

- **`/metrics`가 세션당 비율을 냅니다** — 합계·순위만 있어 KPI로 쓰는 워크플로 경유율·교정 빈도를 events를 직접 파싱해 계산해야 했습니다. `## 비율` 절이 활성 세션(턴 ≥ 5) 기준 교정 마크/세션·/100턴과, 하네스 프로젝트 활성 세션 중 워크플로를 경유한 비율(전체·프로젝트별)을 냅니다. 경유는 `.ai-harness/workflows/` 문서를 읽었거나 워크플로 커맨드(`implement-feature`·`fix-bug`·`review`·`understand-change`, 프로젝트가 둔 워크플로 이름 포함)를 호출한 세션입니다. (#51)
- **이슈 상태 전환 정책 `issue_policy: "in-progress-on-start"`** — 이슈를 맡겨 작업을 시작해도 트래커의 상태는 사람이 따로 옮겨야 했습니다. `.ai-harness/harness.json`에 이 값을 두면 `/implement-feature`·`/fix-bug`가 요청에 이슈 키·URL이 있을 때 브랜치·worktree 준비와 탐색 전에 그 이슈를 진행 중으로 옮깁니다(도구는 워크플로 본문이 적은 이슈 도구, 예: `/jira`). 상태 이름이 아니라 대상 상태 분류가 진행 중인 전환을 고르고, 이미 진행 중이면 그대로, 완료·종료면 다시 열지 않고 사람에게 묻습니다. 필드가 없으면 이전처럼 이슈 상태를 건드리지 않습니다. `/harness-init` 인터뷰 9번·`--reconfigure`로 고르고, 어댑터가 런타임에 읽으므로 기존 프로젝트는 `--sync`로 어댑터를 갱신한 뒤 켭니다.
- **저장소 하네스가 플러그인보다 뒤처지면 세션 시작 때 알림** — 플러그인은 auto-update로 최신이 돼도 저장소의 생성물·`harness_version`은 `/harness-init --sync`를 돌려야 따라와, 알리는 경로 없이 몇 달씩 뒤처졌습니다(실측: 플러그인 0.39.0, 저장소 0.19.0~0.22.3). 이제 현재 저장소(또는 workspace 매니페스트)가 뒤처지면 sync 명령과 자동 sync 켜는 법을 저장소·플러그인 버전 조합당 한 번 안내합니다. (#137)
- **자동 sync (opt-in `HM_SYNC_AUTO=1`)** — 정기 sweep이 기준 브랜치의 `harness_version`이 뒤처진 하네스 저장소에서 `/harness-init --sync --apply --auto`를 자동 harvest와 같은 무인 경로로 돌려 draft PR을 엽니다. `add`·수정 안 된 관리 생성물 `refresh`만 적용하고 승인 필요·보호 파일·삭제는 PR 본문 "사람 확인 필요" 표로 넘깁니다. 적용할 것이 없으면 에이전트를 띄우지 않습니다. 저장소·버전당 1회, 하루 `HM_SYNC_AUTO_DAILY_MAX`(기본 2). (#137)

### 버그 수정

- **무인 에이전트(자동 harvest·sync)의 origin 형태 force push를 막습니다** — 금지 목록이 `git push --force*`·`-f*`만 막아 `git push origin --force`·`+refspec`이 허용 목록(`git push origin *`)으로 통과할 수 있었습니다. 저장소가 정한 `base_branch`도 브랜치 이름 형태일 때만 무인 지시문에 쓰고, 기준 브랜치 fetch에 시간 제한(`HM_FETCH_TIMEOUT_SEC`, 기본 60초)을 둡니다. (#137)
- **`docs-drift`가 문서와 맞는 Gradle 태스크를 drift로 보고하지 않습니다** — Kotlin DSL 멀티모듈 저장소에서 맞게 적힌 태스크 4건이 오탐으로 올라 "보호 파일 후속 조치" 표를 오염시켰습니다. 원인은 셋이었습니다: stale 판정이 관련성 필터를 거친 사실 목록과 비교해 `jacocoAggregatedReport`·`syntheticTalentExport`처럼 선언됐지만 이름에 검증 키워드가 없는 태스크를 "빌드에 없다"고 봤고, `verify`가 `Verification`과 맞지 않았고, `./gradlew test integrationTest`처럼 한 호출의 둘째 태스크를 사용으로 세지 않았습니다. 이제 stale은 선언된 태스크 전부와 비교하고, `<Test>` 타입 태스크는 이름과 무관하게 검증 태스크로 보며, 한 호출의 둘째 이후 태스크는 missing 해소에만 씁니다(산문의 뒷단어가 stale로 오르지 않게). `"jacocoVerification${suffix}"`처럼 이름이 보간되는 선언은 사실로 올리지 않고, 문서에 적힌 완성된 이름을 stale로 보지 않습니다.

### 동작 변경

- **`approval: auto`에서 Brief의 판단 갈림을 에이전트가 정하고 진행합니다** — auto여도 Brief에 열린 질문이 하나라도 있으면 사람을 기다려 "이슈를 맡기면 PR까지"가 질문 하나에 막혔습니다. 이제 auto의 brief 노드는 열린 질문 대신 `decisions`(질문·선택·근거)를 내고, 추천안을 따라 Brief를 씁니다. 결정은 러너 실행 디렉터리의 `brief.md` "결정 사항"에 남아 deliver·review가 따르고, publish가 PR 본문 "결정 사항"(PR이 없으면 커밋 메시지)에 옮겨 사람이 병합 전에 뒤집을 수 있습니다. 범위를 바꾸는 제품 판단, 데이터 삭제·마이그레이션·인덱스 조작·배포처럼 되돌리기 어려운 선택, 외부 시스템 쓰기는 `needs_human`으로 따로 내고, 하나라도 있으면 지금처럼 승인 노드에서 멈춥니다(exit 10). auto인데 Brief가 예전 형식(`open_questions`)으로 오면 사람을 기다립니다. `approval: human`은 그대로입니다.

### 업데이트 후 해야 할 일

- `/harness-init --sync --apply`로 러너(`implement-feature-driver.sh`)·어댑터·그래프를 갱신합니다. 갱신 전 러너는 auto여도 열린 질문에서 멈춥니다. 그래프 엣지 이름은 바뀌지 않아 손댄 그래프도 그대로 동작합니다.

## v0.39.0 (2026-10-18)
### 새 기능

- **승인 게이트 모드 `approval: "human" | "auto"`** — 위임 세션·상위 오케스트레이터는 사람이 대화에 직접 친 승인을 만들 수 없어 Brief 다음에서 항상 멈췄습니다. `.ai-harness/harness.json`에 `approval:"auto"`를 두면 Brief를 산출물(러너 실행 디렉터리·PR 본문)로 남기고 그래프의 새 `auto_approved_by_policy` 엣지로 통과합니다. Brief에 열린 질문이 있거나, 그래프가 `user_decision`으로 보내는 수리 한도 초과·제품 판단이면 auto에서도 사람을 기다립니다. 기본값은 `human`(필드가 없을 때 포함)이라 기존 프로젝트는 그대로입니다. `/harness-init` 인터뷰 8번·`--reconfigure`로 고릅니다. (#131)
- **그래프 `publish` 노드: done 전에 커밋·push·PR** — 그래프가 `review → done`에서 끝나 PR은 매번 사람 몫이었습니다. feature-delivery·bug-fix 그래프에 `review → publish → done`이 생겼고, `git_policy`가 `pr-only`면 커밋·일반 push·PR 생성(PR 도구·검토자는 프로젝트 워크플로의 기본 규칙), `direct`면 커밋·일반 push, 그 밖이면 건너뜁니다. 러너는 publish 결과를 세션 보고가 아니라 git 상태(미커밋 없음·리뷰한 트리와 같음·실행 전 이력 보존·upstream push·pr-only면 PR URL)로 판정하고, 실패하면 `user_decision`으로 넘깁니다. (#131)
- **러너의 사이클별 체크포인트 커밋** — `git_policy`가 `pr-only`·`direct`면 deliver와 각 repair 뒤 로컬 커밋(`wip(implement-feature): …`)을 남겨 worktree가 사라져도 진행이 남습니다. push는 publish만 합니다. (#131)

### 동작 변경

- **어댑터의 커밋·push·PR 문구가 manifest `git_policy`를 따릅니다** — `/implement-feature`·`/fix-bug`·`/review` 어댑터가 "별도 허가 없이 커밋·푸시·PR 생성을 하지 않는다"로 고정돼 `git_policy:"pr-only"`(PR까지는 에이전트)와 모순됐고 워크플로 본문의 PR 단계를 막았습니다. 이제 `pr-only`는 커밋·일반 push·PR 생성까지, `direct`는 커밋·일반 push까지 허용하고, 정책이 없거나 그 밖의 값이면 이전처럼 별도 허가가 필요합니다. 병합·force push는 어느 정책에서도 하지 않습니다. 어댑터는 manifest를 런타임에 읽으므로 정책을 바꿔도 다시 생성할 필요가 없습니다. (#131)
- **수리 반복 한도 2 → 10, 그래프 `limits.max_repair_attempts`가 단일 출처** — 세 그래프 모두 `limits.max_repair_attempts: 10`을 갖고, 횟수가 박힌 전이 이름(`same_root_cause_after_two_attempts_…`)은 `repair_limit_reached_or_…`로 바뀌었습니다. 러너는 사람에게 넘기는 엣지 이름을 그래프에서 읽고, Claude `.js` 워크플로는 `max_repair_attempts` 인자를 받습니다(없으면 10). 역할 간 넘김 루프 한도(두 번째 왕복에서 사용자에게)는 수리 한도와 별개라 그대로입니다. (#131)
- **워크플로 계약 검사가 새 정책을 기준으로 봅니다** — `repair_limit`은 그래프 `limits`를 먼저 읽고(없는 이전 그래프는 전이 이름), `pr_step_forbidden_by_adapter`는 본문의 PR 단계를 `git_policy`가 `pr-only`·`direct`면 허용하고 그 밖이면 짚으며, `git_policy`를 모르는 이전 어댑터는 `--sync` 갱신 대상으로 짚습니다. (#131)
- **`/harness-init --sync --apply`가 add·refresh를 다시 묻지 않습니다** — `--apply`가 곧 승인이므로 질문은 승인 필요·삭제·보호 파일 편집 항목에만, 모아서 한 번에 합니다. (#131)

### 업데이트 후 해야 할 일

- `/harness-init --sync --apply`로 관리 생성물(세 그래프, 러너, 어댑터, `.claude/workflows/*.js`)을 갱신합니다. 손대지 않은 생성물은 묻지 않고 갱신됩니다. 손댄 그래프(`modified`)를 그대로 두면 이전 한도·엣지가 유지됩니다 — 러너는 `publish` 노드가 없는 그래프에서는 PR 없이 done으로 끝나고, auto 엣지가 없으면 `approval:"auto"`여도 사람 승인을 기다립니다(체크포인트 커밋은 그래프와 무관하게 `git_policy`를 따릅니다).
- `git_policy:"pr-only"`인 프로젝트는 갱신 뒤 러너·어댑터가 커밋·push·PR까지 합니다. 원하지 않으면 `--reconfigure`로 git 통제 수준을 바꾸거나 manifest에서 `git_policy`를 지웁니다.
- 사람 없이 PR까지 가려면 `--reconfigure`에서 승인 게이트를 `정책 승인`으로 고릅니다(manifest `approval:"auto"`).
- `--sync`의 "보호 파일 후속 조치" 표를 확인합니다: 워크플로 본문에 `최대 2회` 같은 숫자가 있으면 `repair_limit`으로 오릅니다(본문은 "그래프 수리 한도"로 참조하게 고칩니다). 본문에 PR 도구·기준 브랜치·검토자 기본값이 없으면 publish 노드가 쓸 수 있게 추가합니다.

## v0.38.0 (2026-10-18)
### 새 기능

- **`/implement-feature` 그래프를 모델 밖에서 실행하는 러너** — 지금까지 승인은 모델이 대화를 읽고 판단하거나 `.js`에 `approved: true`를 넘기는 것이었고, 검증은 작업 에이전트의 보고, Codex는 스킬이 그래프를 따른다는 전제에 기댔습니다. `.ai-harness/workflows/implement-feature-driver.sh`(standard 관리 생성물)는 `feature-delivery-graph.json`을 읽어 선언된 전이만 따르고, 노드마다 별도 세션을 띄워 읽기 전용 노드는 샌드박스·도구 제한·작업 트리 지문으로 지키며, 승인 노드에서 체크포인트를 남기고 멈춥니다. 승인은 사용자가 대화에 직접 입력한 `승인`(Claude·Codex 트랜스크립트)이나 터미널 `approve`만 인정하고, 완료는 Brief와 함께 승인된 검증 명령을 러너가 직접 실행해 판정합니다. 그래프에 `actor`, `limits.max_repair_attempts`, `repair → repair`(검증 실패) 전이가 추가됐습니다. 다음 `/harness-init --sync`에서 갱신 대상으로 오릅니다.
- **스키마 조건 없는 information_schema 조회를 Bash 실행 전에 막는 가드(opt-in)** — 모든 스키마를 훑어 공유 DB를 멈출 수 있습니다. 기본은 꺼져 있고 `HM_DB_SCAN_GUARD=1`로 켭니다. DB 클라이언트가 명령 위치에 올 때만 검사하고, 문자열 리터럴·주석을 지운 뒤 `OR` 없는 `*_schema =`/`IN (...)` 조건이 있어야 통과합니다.
- **init이 기존 에이전트 자산을 분석해 하네스 역할에 융화합니다** — 팀이 이미 `.claude/agents`·라우터 스킬을 운영하는 저장소에 init하면 developer·test-engineer를 그 옆에 하나 더 세워 위임 대상이 모호해졌습니다. `scripts/existing-assets.sh scan`이 기존 지침(CLAUDE.md 위치·import 여부)·에이전트·스킬(템플릿 이름 충돌, 라우터 후보)·settings hook·선언되지 않은 `plugin:agent` 참조·`.claude/` gitignore 여부를 모으고, `/harness-init`이 역할 슬롯을 기존 에이전트·라우터에 매핑(`harness.json`의 `roles`)해 매핑된 슬롯은 생성하지 않습니다. 기존 자산의 낡은 서술·중복·외부 참조는 점검표로 보입니다. (#121)
- **생성물을 영구 제외하고, 설정 밖으로 밀려난 생성물을 제거 후보로 보입니다** — 지운 생성물을 `forget`해도 다음 `--sync`가 add로 되살렸습니다. `harness-sync-state.sh exclude|include`가 `harness.json`의 `excluded`를 관리하고 plan은 `excluded`로만 표시합니다. plan의 `orphaned`는 integration·stack·level을 빼거나 역할을 기존 에이전트에 넘긴 뒤 남은 관리 생성물을 사유와 함께 냅니다. (#121)
- **워크플로 계약 검사가 역할 매핑을 확인합니다** — `roles`가 가리키는 기존 에이전트·라우터 파일이 사라지면 `role_agent_missing`·`role_router_missing`. (#121)
- **harvest가 추가뿐 아니라 제거를 개선안으로 냅니다** — 하네스가 추가만 하며 낡은 규칙·코드와 모순되는 서술·안 쓰는 자산이 쌓였습니다(항상 로드되는 지침이 길수록 준수율이 떨어집니다). 제거 후보 신호(없는 경로·명령 참조, docs-drift·계약 finding, 교정을 유발한 규칙, 중복 지시, 사용 0회)와 가치 기준을 두고, "재발 없음"은 제거 근거에서 뺐습니다. `--auto`는 줄 단위 제거까지 draft PR로 내고 파일·관리 생성물 삭제는 사람에게 넘깁니다. `mark-reviewed --change add|remove|mixed`로 기록해 다음 harvest가 제거를 복원 여부로 검증합니다. (#122)
- **개인 지침 자동 규칙의 중복을 찾아 뺍니다** — 사람이 블록 밖에 같은 규칙을 직접 쓰면 `scripts/auto-apply.sh duplicates`가 해당 줄과 함께 알리고, 자동 harvest가 그 자동 규칙을 되돌립니다. 되돌리기는 scope의 모든 지침 파일에서 지우므로, 규칙이 든 파일 전부(global이면 Claude·Codex 둘 다)에 같은 문구가 있을 때만 알립니다. (#122)

### 동작 변경

- **프론트 테스트 판단 Skill이 HTTP 누수와 정리 훅 순서를 다룹니다** — 팀 맞춤본에서 검증된 규칙을 역반영했습니다: mock되지 않은 요청은 낸 테스트 이름과 함께 실패로 보고, mock 해제·세션 정리는 렌더 정리 뒤에(describe 안 훅은 항상 먼저, Vitest 기본 `sequence.hooks: "stack"`은 역순이라 `"list"` 전제), 시각 회귀 도구는 CI를 막는 설정인지 확인. 다음 `/harness-init --sync`에서 갱신 대상으로 오릅니다.
- **생성되는 역할 agent가 보고를 고정된 절로 끝냅니다** — 안 한 것과 이유·미검증·`다음 담당` 줄. 부모는 `다음 담당: 없음`과 게이트 통과로 slice를 닫고, 왕복만 반복되면 두 번째에서 사용자에게 올립니다. 루브릭 채점 게이트는 #125에서 따로 다룹니다.

## v0.37.0 (2026-10-13)
### 새 기능

- **어디서 연 세션이든 하네스 저장소 코드를 바꾸기 전에 그 저장소의 워크플로를 읽게 합니다** — 저장소의 편집 가드는 그 저장소 설정에 있어 상위 폴더(workspace) 세션에서는 로드되지 않았습니다(실측 차단 0%). 플러그인 `PreToolUse` hook(`scripts/member-edit-guard.sh`)이 편집 파일에서 `.ai-harness/harness.json`이 있는 저장소를 찾아, 세션이 그 저장소 밖에서 열렸고 워크플로를 Read나 Bash로 읽은 기록이 없으면 차단합니다. worktree는 별도 저장소로 보고, 서브에이전트는 부모 세션의 읽기도 인정하며, 하네스 문서 편집·기록 없음·오류는 통과합니다. 실측 22MB transcript에서 0.5초 이내. (#107)
- **workspace 동기화가 전역 페르소나 가림을 경고합니다** — workspace 세션의 `subagent_type: developer` 위임은 멤버 페르소나가 아니라 같은 이름의 `~/.claude/agents/developer.md`로 가서 멤버 쓰기 범위가 적용되지 않았습니다. `workspace-scan.sh scan`이 `persona_shadows`를 내고 `/harness-init`이 경고로 보입니다. (#107)
- **워크플로 계약 검사(`scripts/workflow-contract.sh scan`)** — 워크플로 본문·페르소나·settings는 초기화 뒤 갱신되지 않아, 관리 생성물 해시가 모두 일치해도 그래프·어댑터와 의미가 어긋났습니다(실측 standard 저장소 3곳에서 17~24건: 없는 도구 `/plan`·`/team`·`Task 도구`, 그래프 2회와 다른 반복 한도 5회·3회, 위반 시 변경 폐기, 범위 없는 `codex exec`, developer에 회귀 테스트 배정 등). `/harness-init --sync`가 결과를 "보호 파일 후속 조치" 표에 싣습니다. 읽기 전용이며 자동 수정하지 않습니다. (#105)

### 버그 수정

- **Claude 세션 토큰을 응답당 한 번만 셉니다** — transcript는 응답 하나를 content block마다 한 줄씩 쓰며 같은 `message.id`·`usage`를 반복하는데, 줄 단위로 합산해 출력·캐시 토큰이 약 2배로 집계되고 있었습니다(실측 세션: 출력 114,065 → 55,438). `/metrics` 세션 표와 비용 비교가 바로잡히며, 다음 정기 수집이 기존 이벤트를 자동으로 다시 추출합니다. (#103)
- **Bash로 읽은 하네스 문서도 `doc_read`로 셉니다 (Claude)** — 워크플로 본문은 Read 도구보다 `cat`·`sed`·`head`로 더 자주 읽히는데 Read만 세고 있어 워크플로 경유가 크게 과소 집계됐습니다(실측 디스패치 세션 40개 중 워크플로 읽기 4 → 28). 읽기 명령으로 시작하는 구간의 경로만 세며 `grep` 검색·리다이렉트 쓰기는 제외합니다. Codex는 이미 같은 방식으로 세고 있었습니다. (#104)

### 동작 변경

- **워크플로 본문 생성 규칙 정정** — 실사용 저장소의 워크플로 본문에서 존재하지 않는 도구(`/plan`·`/team`, 옛 이름 `Task 도구`), 쓰기 단계를 수행할 수 없는 `codex exec` 폴백, 그래프와 다른 반복 한도·필수 단계가 확인됐습니다. 도구 매핑을 Claude(Agent `subagent_type`)·Codex(네이티브 서브에이전트 → `codex exec -C … -s workspace-write -o …` → 단일 세션 전환)로 고정하고, 반복 한도·종료·PR은 그래프와 git 정책을 따르게 했습니다. (#106)
- **fix-bug 회귀 테스트는 test-engineer가 맡습니다** — developer 범위에 테스트 경로가 없는데 회귀 테스트를 developer에 맡기던 충돌을 없앴습니다. 역할 범위 위반은 변경을 폐기하지 않고 diff를 보존해 재위임합니다. (#106)
- **페르소나 쓰기 범위를 실측 모듈 경로로 생성합니다** — 멀티모듈 저장소에서 루트 `src/**`로 생성돼 실제 경로와 맞지 않던 문제. (#106)
- **workspace 안내가 `/cd`·`/add-dir`을 반영합니다** — "cwd의 `.claude/`만 로드하므로 해결 불가"는 현재 Claude Code에서 틀렸습니다. `/cd <멤버>`는 멤버 settings·hook까지, `/add-dir <멤버>`는 커맨드·페르소나만 로드합니다. 멤버는 경로 첫 세그먼트가 아니라 git root로 판정하고, workspace 세션의 위임이 같은 이름의 사용자 전역 페르소나로 갈 수 있음을 경고합니다. (#106)
- **편집 가드 경로가 `CLAUDE_PROJECT_DIR`에 의존하지 않습니다** — `/cd`로 들어온 세션에서 이 변수는 시작 디렉토리를 가리킵니다. hook 명령과 스크립트 기준 경로를 git root로 생성합니다. (#106)

### 업데이트 후 해야 할 일

- 기존 workspace: `/harness-init --sync`로 Preflight 첫 줄·①③④ 갱신 diff를 확인하세요.
- 기존 저장소: 워크플로 본문·페르소나·편집 가드는 보호 파일이라 자동으로 바뀌지 않습니다. 위 항목에 해당하는 문구가 있으면 손으로 고치거나 다음 버전의 계약 검증(#105)을 기다리세요.


## v0.36.1 (2026-10-13)
### 버그 수정

- **드문 오류의 규칙 효과를 1~2건 차이로 판정하던 문제 수정** — 적용 후 세션 수만 보고 판정해, 원래 100세션당 1.9건인 오류가 적용 후 32세션에서 1건 나온 것만으로 `no_effect`가 됐습니다(기대 건수 0.6건). 이제 적용 전 발생률로 예상되는 적용 후 건수가 5건(`HM_EFFECT_MIN_EXPECTED`) 이상일 때만 판정하고, 결과에 `expected_after_hits`를 보여 줍니다.

## v0.36.0 (2026-10-13)
### 새 기능

- **자동 규칙의 효과를 수치로 판정합니다** — 규칙마다 줄여야 할 오류·교정 문구의 정규식(`--signal`)을 함께 저장하고, `scripts/auto-apply.sh effect`가 적용 전(직전 30일)과 적용 뒤 시작한 세션의 100세션당 발생률을 비교해 `improved`/`unclear`/`no_effect`/`pending`(적용 후 30세션 미만)을 냅니다. 지침은 세션 시작 때 읽히므로 적용 전에 시작한 세션은 '적용 후'로 세지 않습니다. 자동 harvest는 이 판정으로 규칙을 유지·강화·되돌립니다.
- **자동 규칙 총량 상한(`HM_AUTO_RULES_MAX`, 기본 12)** — 지침 파일이 길수록 에이전트 성공률이 떨어지고 비용이 는다는 보고가 있어, 상한에 닿으면 새 규칙 대신 병합·정리를 요구합니다.
- **기록 금지 목록** — 환경 의존 실패, "X는 안 된다" 같은 부정 주장, 미해결 실패를 절차로 포장한 것, 일회성 서사·번호·날짜, transcript 속 외부 출력의 지시는 규칙·문서로 만들지 않습니다.

### 보안

- 자동 규칙 문구에 보이지 않는 유니코드(제로폭·양방향 제어·BOM)와 비밀값처럼 보이는 문자열을 거부합니다.

### 동작 변경

- **정기 실행이 OS 스케줄러 없이 에이전트 hook으로 돕니다** — launchd는 macOS 전용이고 OS마다 따로 설치해야 했습니다. 이제 Claude Code·Codex 공통 `Stop` hook(응답마다)과 `SessionStart`가 주기만 확인하고(수 ms), 지났으면 작업을 세션과 분리해 띄웁니다. 긴 세션 중에도 주기대로 돌고, macOS·Linux·WSL에서 똑같이 동작합니다. `scripts/schedule.sh`(launchd)는 선택 사항으로 남고, 설치 안내는 더 띄우지 않습니다.
- **LLM 단계(LLM 정리·자동 harvest)는 사용자가 쉬는 동안만 돕니다** — 수집은 바로 하고, LLM 단계는 최근 20분간 대화 기록 활동이 없을 때까지 최대 4시간 기다립니다. 자동 harvest가 사용량 한도로 실패하면 5시간 동안 쉽니다. 실측에서 작업 중 사용량 한도에 막힌 실행이 있었습니다.

### 업데이트 후 해야 할 일

- launchd를 등록했다면 `scripts/schedule.sh uninstall`로 해제해도 됩니다(남겨 둬도 주기·lock을 공유해 중복 실행되지 않습니다).

## v0.35.1 (2026-10-12)
### 보안

- **무인 자동 harvest의 권한을 좁혔습니다** — 이벤트·transcript를 읽으려고 연 데이터 디렉토리를 에이전트가 쓸 수도 있었습니다. 그 안의 `config`는 모든 스크립트가 셸로 읽고 launchd shim도 그 아래에 있어, transcript 속 지시가 샌드박스 밖 코드 실행으로 이어질 수 있었습니다. 이제 데이터·transcript 디렉토리는 쓰기를 금지하고, git은 필요한 하위 명령만 허용합니다(`git -C`·`reset`·`clean`·강제 push·`worktree` 등 금지). `config`는 셸로 실행하지 않고 `HM_`·`HARNESS_` 변수의 `KEY=VALUE`만 읽습니다.
- **자동 적용 규칙 문구로 관리 블록 밖에 줄을 넣을 수 있던 문제 수정** — awk가 백슬래시 이스케이프를 해석해 `\n`으로 블록을 벗어날 수 있었습니다. 규칙 문구는 백슬래시·제어문자·URL·명령 실행·지침 무력화 표현을 거부하고, awk에는 환경변수로 넘깁니다.
- **비밀값 가림 강화** — `Authorization: Basic`, `--password 값`, URL 속 `user:pw@`, `AWS_SECRET_ACCESS_KEY=` 같은 형태가 오류 발췌에 남았습니다. 공용 `scripts/redact.jq`로 모으고, LLM 정리 입력과 결과에도 같은 규칙을 적용합니다. Bitbucket 토큰은 프로세스 인자 대신 stdin으로 넘깁니다.

### 버그 수정

- **같은 batch가 계속 실패하면 3회 뒤 포기합니다** — 결정적으로 실패하는 batch가 매번 하루 상한을 먹어 다른 프로젝트가 실행되지 못할 수 있었습니다. 사용량 한도 실패는 횟수에 넣지 않습니다(`HM_HARVEST_AUTO_MAX_FAILS`). LLM 정리도 실패를 기록하고 24시간 안에 같은 세션을 다시 고르지 않습니다.
- **무인 실행이 응답 없는 명령에 lock을 쥔 채 멈추지 않게** — 자동 harvest(45분)·LLM 정리(5분)에 시간 제한을 두고, git은 자격증명 입력을 기다리지 않으며, Bitbucket 호출은 30초로 제한합니다.
- 자동 harvest가 사용자 저장소 전체에 `git worktree prune`을 돌려 잠시 분리된 다른 worktree 등록까지 지울 수 있던 문제, 지침 파일이 심볼릭 링크면 일반 파일로 바뀌던 문제, 닫는 표시가 지워진 규칙이 블록 뒤 내용까지 지우던 문제, 이름 재판정이 사라진 worktree 경로의 폴더 이름으로 올바른 이름을 덮어쓰던 문제, "ai-harness harvest --auto"를 언급한 일반 세션이 내부 세션으로 빠지던 문제, 긴 한글 프로젝트명으로 작업 폴더 이름이 길이 한도를 넘던 문제, 다른 프로젝트 큐를 그 큐의 lock 없이 고치던 문제를 고쳤습니다.

### 업데이트 후 해야 할 일

- launchd를 쓰면 `scripts/schedule.sh install`을 한 번 다시 실행하세요(UTF-8 로캘 반영).

## v0.35.0 (2026-10-12)
### 새 기능

- **workspace와 전역 지침은 자동 harvest가 직접 적용합니다** — 팀 저장소는 draft PR로 사람이 머지하지만, workspace 루트 `AGENTS.md`와 전역 `CLAUDE.md`·Codex `AGENTS.md`는 개인 소유라 사람 검토 없이 적용하고, 대신 안전장치를 둡니다: 편집 도구 없이 `scripts/auto-apply.sh`로만 표시된 블록 안을 고치고(직접 쓴 내용은 그대로), 적용마다 이전 상태를 남겨 규칙 단위로 되돌릴 수 있으며, 기대효과를 다음 실행이 재발 여부로 판정해 강화하거나 되돌리고, 다음 세션 시작에 무엇을 바꿨는지 알립니다. 전역 지침은 7일마다 2개 이상 프로젝트·5개 이상 세션에 걸친 반복만 다룹니다. 통계 `반복 오류` 표에 프로젝트 수 열이 생겼습니다.

### 버그 수정

- **macOS에서 프로젝트 ID가 harness.json·origin·workspace 대신 폴더 이름으로 정해지던 문제 수정** — macOS 기본 jq(1.6 Apple 빌드)는 `first(inputs | fromjson? | …)`에서 멈추지 않아, transcript의 작업 경로를 여러 줄로 읽었습니다. 그 경로로는 아무 파일도 찾지 못해 항상 마지막 폴더 이름으로 떨어졌고, 저장소 이름과 같을 때는 우연히 맞아 드러나지 않았습니다. workspace 루트 세션은 `jobda-workspace`가 아니라 폴더 이름으로 집계됐습니다(실측 Claude 243·Codex 432세션). 줄 단위로 읽고 첫 줄만 씁니다. 업데이트 후 첫 backfill에서 전 세션이 재추출되고, 큐 상태는 새 이름으로 옮겨집니다.
- **원본 transcript가 지워진 세션이 옛 프로젝트 이름에 남던 문제 수정** — Claude가 오래된 기록을 정리하면 그 세션은 다시 추출되지 않아 이름 규칙이 바뀌어도 그대로였습니다. 규칙(`lib.sh`)이 바뀐 뒤 한 번, 남은 작업 경로로 다시 판정해 이름을 고치고 큐에 다시 기록합니다.

### 업데이트 후 해야 할 일

- 첫 정기 backfill에서 추출기 변경으로 전 세션이 한 번 재추출되고(약 20분, 저우선순위), workspace 루트 세션이 폴더 이름 대신 workspace ID로 다시 묶입니다.
- `HM_HARVEST_AUTO=1`이면 workspace `AGENTS.md`와 전역 지침에 자동 적용이 시작됩니다. 끄려면 `HM_HARVEST_AUTO_WORKSPACE=0`, `HM_HARVEST_GLOBAL_DAYS=0`.

## v0.34.3 (2026-10-11)
### 버그 수정

- **사용량 한도·API 오류로 실패한 자동 harvest가 그 batch를 다시 시도하지 않던 문제 수정** — 실패해도 "실행함"으로 기록돼 batch가 버려졌습니다(실측: Claude 세션 한도 429로 jobda-scheduler 실행이 0.5초 만에 실패). 이제 실패하면 시도 기록을 지워 다음 sweep이 다시 시도하고(하루 상한은 그대로), 실행 기록과 health에 `usage_limit` 등 실패 사유를 남깁니다.

## v0.34.2 (2026-10-10)
### 버그 수정

- **자동 harvest가 이벤트·transcript를 읽지 못하고 건수만으로 판단하던 문제 수정** — 데이터 디렉토리(`~/.ai-harness`)와 transcript(`~/.claude/projects`, Codex 세션)가 작업 worktree 밖이라 읽기가 권한 거부됐습니다(실측: jobda·jobda-agent·jobda-scheduler). 이 디렉토리들을 `--add-dir`로 열어 줍니다.
- **자동 harvest가 하네스 없는 기본 브랜치에서 작업하던 문제 수정** — 작업 worktree를 `origin/HEAD`에서 만들었는데, jobda-* 저장소는 `origin/HEAD`가 하네스 없는 초기 master이고 실제 개발은 `develop`이었습니다. 이제 `harness.json`의 `base_branch` → develop → origin/HEAD → main → master 중 하네스 파일이 실제로 들어 있는 첫 브랜치를 쓰고, 에이전트에게 `--base`로 알려 PR도 그 브랜치를 향합니다.

## v0.34.1 (2026-10-10)
### 버그 수정

- **한 프로젝트가 자동 실행된 뒤 다른 프로젝트들의 차례가 오지 않던 문제 수정** — sweep은 한 번에 하나만 띄우는데, "이번에 띄웠는지"가 아니라 "시도 기록이 launched인지"로 멈춰서, 지난 sweep에서 띄운 batch가 남아 있으면(사람에게 넘긴 경우 등) 매번 거기서 멈췄습니다.
- **Orca worktree에서만 작업한 저장소의 batch가 계속 "하네스 없음"으로 넘어가던 문제 수정** — 세션 기록에 원본 체크아웃 경로가 한 번도 나오지 않아 자동 harvest가 저장소를 찾지 못했습니다(jobda-cms, jobda-scheduler). 이제 기록에 나온 workspace 루트의 `.ai-harness/workspace.json` 멤버 목록에서 프로젝트 ID가 일치하는 저장소를 찾습니다.

## v0.34.0 (2026-10-10)
### 새 기능

- **오류 본문을 발췌해 반복 실패를 판단할 수 있게 했습니다** — 지금까지 이벤트에는 오류 건수만 있어 `/harvest`가 "error 17건이 반복인지 판단할 근거가 없다"며 넘어갔습니다(jobda-database 실측). 이제 실패한 도구 결과마다 `도구: 오류 줄`을 최대 160자 발췌하고(오류 낱말이 든 줄 우선, 세션당 상위 10개), 토큰·비밀번호·긴 키 문자열은 가립니다. `/metrics`·`/harvest` 통계에 `반복 오류` 절이 생겨 줄 번호·해시를 지운 같은 오류를 세션 수 순으로 보여주고, 2개 이상 세션에서 반복되면 개선 근거로 씁니다. 업데이트 후 첫 backfill에서 한 번 전 세션이 재추출됩니다.

## v0.33.2 (2026-10-10)
### 버그 수정

- **Codex 세션이 만든 batch의 자동 harvest가 바로 실패하던 문제 수정** — 현재 Codex CLI에 없는 `--full-auto` 옵션으로 실행해 인자 오류로 끝났습니다. 또 Codex 샌드박스는 `.git`을 읽기 전용으로 두어 커밋·push를 할 수 없습니다. 이제 세션 도구와 무관하게 `claude`가 있으면 Claude Code로 실행하고(`HM_HARVEST_AUTO_AGENT`로 변경 가능), Codex로 돌 때는 현재 옵션(`--approve-for-me`, 큐 기록 경로 허용)으로 분석·보고까지만 합니다.
- **자동 harvest 비용이 기록되지 않던 문제 수정** — Claude가 stderr로 내는 안내(신뢰되지 않은 작업 공간 등)가 결과 JSON 앞에 섞여 파싱에 실패했습니다. 이제 JSON 줄만 읽습니다.

## v0.33.1 (2026-10-10)
### 버그 수정

- **launchd에서 띄운 자동 harvest가 플러그인 스크립트를 실행하지 못하던 문제 수정** — shim이 Codex 쪽 설치본을 고르면 권한 허용 목록은 그 경로로 만들어지는데, `claude`는 자기 캐시의 플러그인을 로드해 경로가 달라 전부 거부됐습니다. 이제 자동 실행이 자신을 띄운 설치본을 `--plugin-dir`로 명시해 로드합니다.
- **지워진 worktree에서 작업한 세션만 있는 batch가 "하네스 없음"으로 영구히 건너뛰어지던 문제 수정** — 같은 프로젝트의 다른 세션 기록에서 지금 살아 있고 프로젝트 ID가 일치하는 하네스 저장소를 찾습니다. 하네스를 못 찾아 넘긴 batch는 다음 sweep에서 다시 확인합니다.
- **PR을 열 수 없는 상황에서도 원격에 브랜치를 올리던 문제 수정** — 자동 harvest가 변경을 적용하기 전에 `open-pr.sh --check`로 원격 종류·인증·접근(Bitbucket IP 허용 목록 포함)을 확인하고, 안 되면 push하지 않고 보고로 끝냅니다.

## v0.33.0 (2026-10-10)
### 버그 수정

- **플러그인을 업데이트할 때마다 전 세션을 다시 추출하던 문제 수정** — 추출기의 수정 시각으로 재추출을 판단해서, 내용이 같아도 새로 설치되면 2천여 세션을 모두 다시 처리했습니다(launchd에서 1시간 이상). 이제 추출기·큐 스크립트의 내용 해시가 바뀐 때만 다시 처리합니다. 이 기준은 이번 업데이트 뒤 첫 backfill에서 기록되므로 그때 한 번은 전체 재처리가 일어납니다.
- **launchd 작업이 macOS 백그라운드 제한으로 크게 느려지던 문제 수정** — `ProcessType=Background`를 빼고 `Nice`·저우선순위 IO만 둡니다. `schedule.sh install`을 한 번 다시 실행해야 적용됩니다.

## v0.32.0 (2026-10-10)
### 새 기능

- **macOS에서 launchd로 수집·정리·자동 개선을 시간 기준으로 돌립니다** — 지금까지는 새 세션을 열 때만 backfill이 돌아, 며칠 이어지는 세션 하나만 켜 두면 그 사이 기록이 처리되지 않았습니다(실측: 6시간 넘는 세션 17%, 세션 시작 간 공백 최대 53시간). `scripts/schedule.sh install`로 한 번 등록하면 매시간 확인해 주기가 지났을 때 backfill → LLM 정리 → 자동 harvest → 릴리스 정보 갱신을 돕니다. 플러그인을 업데이트해도 shim이 최신 설치본을 찾습니다. 아직 등록하지 않은 macOS에서는 첫 세션에 한 번 안내합니다.

### 동작 변경

- **세션 종료(SessionEnd) hook을 없앴습니다** — 터미널·탭을 닫으면 실행되지 않아 실측 43%를 놓쳤고, 자동 harvest 트리거가 여기에만 있어 탭을 닫아 끝내는 프로젝트는 batch가 생겨도 자동 실행되지 않았습니다. 이제 정기 backfill이 유일한 수집 경로이고, 끝날 때마다 batch가 있는 모든 프로젝트를 확인(sweep)해 자동 harvest를 띄웁니다. backfill 기본 주기는 24시간에서 6시간으로 줄었습니다(변경 없는 증분 약 1분). `scripts/collect.sh`는 수동 수집 진입점으로 남습니다.

### 업데이트 후 해야 할 일

- macOS라면 한 번 실행하세요: `<플러그인 경로>/scripts/schedule.sh install` (해제는 `uninstall`, 상태는 `status`).

## v0.31.0 (2026-10-09)
### 새 기능

- **정규식이 놓친 마찰을 LLM이 세션에서 정리합니다 (opt-in)** — 교정 접두어·도구 오류 신호만으로는 의미상 교정이나 프로젝트 지식 부족이 잡히지 않았습니다(실측: 같은 5개 세션에서 정규식 교정 1건, LLM 정리 24건). `HM_DIGEST=1`이면 일일 backfill 뒤 최근 세션을 저비용 모델로 읽어 원문 근거가 붙은 findings를 남기고, 이를 큐의 `insights` 신호와 `/harvest` 근거로 씁니다. 하루 20세션, 세션당 약 $0.003~0.01.
- **자동 harvest가 Bitbucket 저장소에도 draft PR을 엽니다** — 하네스 저장소 대부분이 Bitbucket이라 자동 실행이 보고에서 멈췄습니다. `scripts/open-pr.sh`가 원격을 보고 GitHub는 `gh`, Bitbucket Cloud는 REST API(`ATLASSIAN_USER`·`BITBUCKET_API_TOKEN`)로 draft PR을 만들고, 자동 실행에는 범용 `curl`·`gh` 대신 이 스크립트만 허용합니다.
- **터미널을 그냥 닫은 세션도 하루 한 번 자동으로 수집합니다** — 터미널·탭을 닫으면 `SessionEnd`가 실행되지 않아, 실측에서 최근 14일 Claude 세션의 43%가 `/harvest`나 `/metrics`를 직접 돌릴 때까지 기록되지 않았고 analysis batch 판정도 그만큼 늦어졌습니다. 이제 `SessionStart`가 마지막 backfill이 24시간(`HM_BACKFILL_INTERVAL_HOURS`) 넘었으면 backfill을 세션과 분리된 저우선순위 프로세스로 실행합니다. 세션 시작 시간은 늘지 않습니다.
- **analysis batch가 생기면 `/harvest`를 자동으로 돌릴 수 있습니다 (opt-in)** — 지금까지는 batch가 쌓여도 알림만 뜨고 사람이 `/harvest`를 쳐야 해서, 실제로는 수십 개 batch가 몇 주씩 검토되지 않은 채 남았습니다. `~/.ai-harness/config`에 `HM_HARVEST_AUTO=1`을 두면 `SessionEnd`가 세션과 분리된 headless 세션으로 `/harvest --auto`를 실행해 별도 worktree에서 draft PR까지 만듭니다. 세션 수만 넘은(다른 신호 없는) batch는 실측상 거의 노이즈라 자동 실행에서 빼고 알림으로 남깁니다. batch당 1회·하루 2회·동시 1개·실행당 $5로 제한하고, 실행마다 결과·비용·PR을 `~/.ai-harness/harvest-auto/runs.jsonl`에 남깁니다. GitHub가 아닌 원격(Bitbucket 등)에서는 PR을 만들 수 없으므로 개선안 보고로 끝내고 batch를 사람에게 넘깁니다. 기본값은 꺼져 있습니다.

### 버그 수정

- **자동 harvest가 개선을 적용하는 단계에서 막히던 문제 수정** — headless 실행은 cwd 밖 파일을 편집할 수 없는데, 스킬은 직접 만든 별도 worktree에서 편집하라고 지시하고 있었습니다. 이제 worker가 origin 기본 브랜치로 작업 전용 worktree를 만들어 그 안에서 에이전트를 실행하고, 끝나면 지웁니다.
- **변경 없는 증분 backfill이 4분 20초 → 1분으로** — 이벤트가 그대로여도 매번 1771개 전부를 큐에 다시 기록하고 있었습니다. 이벤트별 기록 스탬프를 두고, 이벤트와 큐 로직(`harvest-queue.sh`·`lib.sh`)이 모두 그대로면 건너뜁니다.
- **자동 harvest 세션이 그 프로젝트의 작업 세션으로 집계되던 문제 수정** — `/harvest --auto` headless 세션이 대상 저장소 세션으로 기록돼, 그 세션의 오류·권한 거부가 다음 batch 신호로 다시 들어갔습니다. 추출 단계에서 내부 세션으로 표시해 큐·통계에서 빼고, 이미 큐에 들어간 것은 다음 backfill에서 꺼냅니다. 옛 프로젝트 큐에는 검토 완료, 새 큐에는 대기로 갈라져 있던 같은 세션도 검토 완료로 합칩니다.
- **추출 규칙이 바뀌어 재추출만 된 세션을 '재개된 세션'으로 다시 큐에 넣던 문제 수정** — 종료 시각·턴 수가 같은데 오탐 수정 등으로 신호 수만 달라지면 검토 완료 세션이 diff 0짜리 대기 세션으로 되살아나 세션 수 기준 batch를 부풀렸습니다. 이제 이런 경우는 검토 기록만 갱신합니다.
- **같은 프로젝트가 여러 이름으로 갈라져 집계되던 문제 수정** — macOS가 한글 경로를 NFD로 넘기면 같은 이름이 다른 큐로 쪼개졌고(실측: `잡다 프로젝트` 432/239 세션), 삭제된 Orca worktree(`<repo>/feature-NJ-612`)의 Codex 세션 67개가 `feature`라는 프로젝트로 묶였습니다. 프로젝트 이름을 NFC로 맞추고, Codex는 rollout에 기록된 저장소 URL을, 그 외에는 브랜치 유형 접두어·이슈 키 worktree 이름을 상위 저장소 디렉토리로 판정합니다. 업데이트 후 첫 backfill에서 재추출되며, 이미 검토한 세션은 새 프로젝트로 옮겨져도 다시 검토 대상이 되지 않습니다. 과거 ID 변경으로 다른 큐에 남아 있던 대기 복사본도 이때 정리됩니다. 옛 이름 큐의 batch에 묶여 있던 세션도 새 프로젝트로 옮기고, 비게 된 옛 batch는 해산합니다 — 옛 이름으로는 알림이 가지 않아 아무도 검토하지 않는 batch로 남기 때문입니다.

### 업데이트 후 해야 할 일

- **첫 세션 시작 뒤 백그라운드 backfill이 모든 세션을 한 번 다시 추출합니다** — 프로젝트 ID 규칙과 추출기가 바뀌었기 때문입니다. 세션 1800개 기준 약 20분 걸리며 저우선순위로 돌아 작업을 막지 않습니다. 이미 검토한 세션은 다시 검토 대상이 되지 않습니다.
- **자동 harvest와 LLM 세션 정리는 기본으로 꺼져 있습니다.** 쓰려면 `~/.ai-harness/config`에 `HM_HARVEST_AUTO=1`, `HM_DIGEST=1`을 추가하세요. Bitbucket 저장소에 PR을 열려면 `ATLASSIAN_USER`·`BITBUCKET_API_TOKEN` 환경변수가 필요합니다.

## v0.30.0 (2026-10-06)
### 새 기능

- **`/diagram`으로 아키텍처·워크플로·시퀀스·데이터 흐름·상태 전이 다이어그램을 그립니다** — 지금까지는 다이어그램 스킬을 따로 찾아 각 에이전트에 설치해야 했습니다. [Archify](https://github.com/tt-a1i/archify) v3.0.1 릴리스 패키지를 `vendor/archify/`에 해시로 고정해 함께 배포하므로, 플러그인만 설치하면 Claude Code·Codex 양쪽에서 타입 검증된 인터랙티브 HTML 다이어그램을 만듭니다. 엔진의 자체 업데이트 확인은 끄고, 갱신은 ai-harness 릴리스로만 합니다. Node.js 18+가 필요하고, 브라우저 검증 단계는 Chrome/Chromium을 씁니다. Codex 기본 샌드박스에서는 Chrome이 뜨지 못해 이 단계에서 권한 승인을 한 번 요청합니다. (#63)

## v0.29.0 (2026-09-25)
### 새 기능

- **workspace AGENTS.md가 멤버 체크아웃 최신 여부를 먼저 확인하게 합니다** — workspace 상위 폴더의 멤버 저장소는 각자 따로 pull 되어 자주 stale인데, 에이전트가 그 로컬 코드를 현재 상태로 읽고 버전·설계를 오판하는 교정이 반복됐습니다. `/harness-init` workspace 모드의 Preflight에 ⑤ `fetch` 후 `origin/<base>`와 비교하는 단계를 넣고, 기존 workspace는 `--sync`에서 같은 단계를 diff로 제안합니다. (#60)
- **`/harvest`가 git이 아닌 workspace의 개선 결과를 기록하는 방법을 안내합니다** — workspace 루트에는 PR을 만들 수 없어 개선이 로컬에만 남고 흔적이 없었습니다. 로컬 적용 시 `--artifact local:<path>`로 기록하고, 범용 개선은 템플릿 개선 이슈로 올리도록 제안합니다. (#60)

## v0.28.0 (2026-09-23)
### 새 기능

- **Claude Code 자동 업데이트를 켜는 법을 안내합니다** — 서드파티 마켓플레이스는 auto-update가 기본으로 꺼져 있어 새 버전마다 `/harness-update --apply`를 직접 실행해야 했습니다. 설치 후 첫 세션에 한 번, 그리고 `/harness-update --apply` 성공 직후 `/plugin` → Marketplaces → ai-harness → Enable auto-update 를 안내합니다. 설정은 사용자가 직접 켜며 플러그인이 바꾸지 않습니다. 기존 사용자도 이 버전으로 올린 뒤 첫 세션에 한 번 보게 됩니다.

## v0.27.0 (2026-09-23)

### 새 기능

- **`/explain-for`가 가족·친구에게 설명하는 요청을 다룹니다** — "엄마한테 설명해줘", "친구한테" 같은 요청에 배우자·부모·아이·친구별 톤과 비유 출처를 적용합니다. 역할은 비개발 독자, 숙련도는 초심자로 보고 관계는 말투만 정합니다. upstream [dreambigou/eli5](https://github.com/dreambigou/eli5)의 관계 청자 표를 옮겨 왔습니다.

### 동작 변경

- **`/explain-for`는 청자를 적지 않으면 어린아이도 이해할 수준(ELI5)으로 설명합니다** — 지금까지는 청자도 전달처도 없으면 한 번 질문하고 멈췄습니다. 이제 upstream [dreambigou/eli5](https://github.com/dreambigou/eli5)처럼 다섯 살 수준을 기본값으로 쓰고, 가정한 청자를 한 줄로 밝힌 뒤 바로 설명합니다. 전달처(PR 리뷰어·스탠드업 등)가 있으면 여전히 그쪽에서 청자를 추론합니다. 숙련도 축에 아동 단계(~5세·~10세/초등 5학년)를 추가하고, ELI5 모드의 어휘·비유·톤·정확성 기준과 예시를 upstream에 맞춰 보강했습니다. 기존 ELI5 정의가 문서마다 "비개발 성인"과 "다섯 살"로 엇갈리던 것도 다섯 살로 통일했습니다. "쉽게 설명해줘" 같은 단순화 요청에도 걸리며, 청자도 단순화 요청도 없는 일반 설명 요청의 동작은 달라지지 않습니다.

## v0.26.0 (2026-09-22)

### 새 기능

- **`/explain-for` — 설명을 청자에 맞춰 다시 쓰는 전역 Skill** — 같은 내용을 매니저·PM·주니어·비개발 직군 중 누구에게 전달하느냐에 따라 프레이밍·용어·깊이·분량만 바꾸고 사실은 그대로 둡니다. 역할과 숙련도 2축으로 청자를 잡고, 청자가 명시되지 않으면 기본 페르소나로 추측하는 대신 전달처에서 추론한 가정을 밝히거나 한 번 질문합니다. 코드를 수정하지 않아 하네스가 없는 저장소에서도 동작하며, `/understand-change`로 세운 이해를 팀에 공유할 때 이어서 씁니다. 청자·수준이 명시된 요청에만 걸리므로 일반 설명 요청의 동작은 달라지지 않습니다. [dreambigou/eli5](https://github.com/dreambigou/eli5)(MIT)의 파생물입니다. (#53)

### 문서

- **릴리스 PR만 merge commit으로 머지한다는 규칙을 명시** — squash로 넣으면 `main`과 `develop`이 영구 분기해 릴리스 뒤 동기화가 fast-forward로 끝나지 않습니다. 릴리스 절차에 마일스톤 닫기·다음 버전 열기 단계도 함께 적었습니다.

## v0.25.0 (2026-09-17)

### 새 기능

- **`scripts/release-prep.sh`** — 릴리스할 때 `## Unreleased` 절을 버전 절로 확정하고 버전 메타데이터 네 곳(plugin.json ×2, release.json, CHANGELOG)을 한 번에 맞춥니다. `--check`는 쓰지 않고 정합성만 봅니다. (#45)

### 동작 변경

- **작업은 `develop`, 릴리스는 `main`입니다** — 설치(`plugin marketplace add`)와 업데이트 확인이 모두 `main`을 읽으므로, `main`에는 릴리스된 상태만 둡니다. 기능·수정 PR은 버전을 올리지 않고 `## Unreleased`에만 항목을 남깁니다. 브랜치 이름·PR base·버전 자릿수 기준은 `CONTRIBUTING.md`에 있습니다. 사용하는 쪽 동작은 바뀌지 않습니다. (#45)
- **릴리스 노트가 닫은 이슈와 PR을 함께 담습니다** — CHANGELOG 항목에 이슈 번호를 적고, 발행 시 `--generate-notes`로 그 버전에 머지된 PR 목록을 본문 아래에 붙입니다. 릴리스마다 같은 이름의 마일스톤(`v<version>`)을 두어 계획과 배포를 각각 볼 수 있습니다. (#45)

## v0.24.0 (2026-09-15)

교정 신호를 **후보 수집(싸게, 넓게)** 과 **판정(격리 컨텍스트에서)** 으로 나눕니다. `correction_mark`는 접두어 6개로 시작하는 턴만 잡아 실제 교정 대부분을 놓치고 있었습니다.

### 새 기능

- **`correction_candidate` 이벤트** — 문장 **어디에나** 불만·부정 표현이 있는 짧은 사용자 턴(200자 이하, 슬래시 커맨드 제외)을 후보로 남깁니다. `correction_mark`에 이미 걸린 턴은 제외합니다. 양 어댑터가 같은 목록을 씁니다. Apple jq(oniguruma)가 한글 alternation 정규식에서 깨지므로 정규식이 아니라 부분문자열 `contains`로 판정합니다.
- **`/harvest` 4단계의 후보 확정 절차** — 후보는 그 자체로 교정이 아니라 **읽어볼 지점**입니다. 확정은 **서브에이전트에 위임**하며, 서브에이전트는 해당 턴과 직전 어시스턴트 응답만 열어 후보당 한 줄(`confirmed|rejected` + 요약)만 돌려줍니다. harvest 세션은 그 판정 줄만 받습니다 — raw transcript가 메인 컨텍스트로 들어오지 않습니다. 위임이 불가능한 환경이면 확정하지 않고 "미확정 N건"으로 보고하며, 미확정 후보는 개선 근거로 쓰지 않습니다.
- **`/metrics`에 교정 후보 섹션** — 확정 전 목록임을 명시합니다.

### 왜

`correction_mark`는 "아니…"처럼 **시작**하는 교정만 잡는다. 실제 교정은 문장 중간에 온다 — "스웨거 링크 이상해", "둘다 여전히 접근 안되잖아". 한 세션에서 네 번 교정받고도 신호가 0이라 `/harvest`가 노이즈로 판정하고 종료한 사례가 있었습니다. 접두어를 늘리는 방식은 다음 표현에서 또 새는 구조라 채택하지 않았습니다.

### 알려진 사각지대

batch 트리거 임계(`harvest-queue.sh`)는 그대로입니다. 후보만 있고 다른 신호(error·guard_block·permission_deny)가 없는 세션은 batch가 열리지 않아 4단계에 도달하지 못합니다. 후보는 오탐이 섞인 신호라 트리거로 쓰면 batch가 남발되므로, 연결 여부는 후보 정밀도를 실측한 뒤 따로 판단합니다.

### 실측

로컬 150세션 재추출: `correction_mark` 13건(12세션) → `correction_candidate` 53건(29세션)이 추가로 표시됩니다. 후보에는 도메인 질문처럼 교정이 아닌 턴도 섞이며, 그걸 거르는 것이 확정 단계의 역할입니다.

### 업데이트 후 해야 할 일

없습니다. 과거 이벤트는 `coverage`에 `correction_candidate`가 없어 `/metrics`가 0이 아니라 "수집 미지원"으로 표시합니다. 다음 `backfill.sh` 재추출부터 채워집니다.
## v0.23.0 (2026-09-15)

`/harness-init --sync`가 **코드와 문서가 어긋난 상태**를 읽기 전용으로 보고합니다. 지금까지 동기화는 템플릿 대비 생성물 구조만 봤기 때문에, 빌드 파일이 바뀌고 `.ai-harness/docs/**`·`AGENTS.md`가 그대로인 상태는 아무도 알려주지 않았습니다.

### 새 기능

- **`scripts/docs-drift.sh scan --root <dir>`** — 빌드 파일에서 기계로 확인 가능한 사실만 뽑아 문서와 대조합니다. Gradle 검증 태스크와 JUnit `includeTags`/`excludeTags`, npm `scripts` 키, Maven 프로파일 `<id>`, pytest `markers`가 대상입니다. 문서 쪽은 임의 단어가 아니라 **실제 호출 형태**(`./gradlew <task>`, `npm run <script>`, `-P<profile>`, `-m <marker>`)만 사용으로 인정합니다. 결과는 `missing_in_docs`(빌드에 있는데 문서에 없음), `stale_in_docs`(문서가 부르는데 빌드에 없음), 그리고 빌드 파일이 문서보다 최근에 커밋됐는지를 담은 약한 신호입니다.
- **`--sync` 계획에 drift 행 추가** — "보호 파일 후속 조치" 표에 실립니다. 문서는 보호 파일이라 `--apply`에서도 건드리지 않고, 수정은 사용자 승인 또는 문서 담당 페르소나로 넘깁니다.

### 왜

`build.gradle`에 `integrationTest`가 추가되고 `test`에 `excludeTags 'integration'`이 붙었는데 `testing.md`의 태스크 표가 초기화 시점 그대로였던 사례가 있었습니다. 문서만 읽은 에이전트는 통합 슬라이스의 존재를 모르고, 워크플로 종료 조건이 `test`/`build`뿐이라 **어떤 게이트에도 걸리지 않는 테스트**가 생겼습니다. 빌드가 깨지지 않으니 신호도 없었습니다.

### 오탐 억제

Gradle 내장 태스크(`build`·`clean`·`assemble` …)와 npm 하위 명령(`install`·`run` …)은 제외하고, **주석 처리된 태스크 선언**(`// tasks.register(...)`, `/* ... */`)은 파싱 전에 지웁니다. 문서 쪽은 `pnpm --filter api test`·`yarn workspace web run build` 같은 워크스페이스 호출에서 플래그와 워크스페이스 이름을 건너뛰고 실제 스크립트명만 읽습니다.

### 한계

문서를 이해하려 들지 않습니다. 토큰이 맞는지만 보므로 서술이 낡았는지는 판정하지 못합니다. Gradle 태스크는 이름 패턴으로 검증 계열만 추리므로(`bootJar`·`classes` 같은 내부 태스크 제외) 그 밖의 이름을 쓰는 검증 태스크는 놓칩니다.

### 업데이트 후 해야 할 일

없습니다. 다음 `/harness-init --sync`부터 계획에 포함됩니다. 생성물 변경 없음.
## v0.22.4 (2026-09-15)

출력이 없는 실패는 `error` 신호에서 뺍니다. `grep -q`·`test`처럼 **종료코드를 판정문으로 쓴 호출**이라 진단할 내용이 없는데도 batch 트리거를 밀어올리고 있었습니다.

### 버그 수정

- **양 어댑터 공통** — 종료코드가 0이 아니어도 출력 본문이 비어 있으면 `error`로 세지 않습니다. Claude는 `Exit code N` 뒤가 비었는지, Codex는 셸 푸터의 `Output:` 뒤가 비었는지로 판정합니다. 브리지 JSON 봉투(`is_error`)는 종전대로 셉니다.
- 명령어 이름으로 탐색성 호출을 걸러내는 방식은 채택하지 않았습니다. 실측에서 이득이 작고(아래), 명령어 파싱은 `cd a && rg b` 같은 복합 명령에서 바로 깨집니다.

### 실측

로컬 transcript 기준 종료코드 ≠ 0 중 본문이 빈 비율은 Claude 483건 중 16건(3%), Codex 1,714건 중 347건(20%)입니다. 세션 240개(Codex 120 + Claude 120) 재추출 결과 `error` 합계는 Codex 99 → 92, Claude 175 → 173이고 **batch 트리거(`n>=5`) 세션 수는 변하지 않았습니다**. 신호의 정의를 정확히 하는 변경이지 임계 동작을 바꾸는 변경이 아닙니다.

### 업데이트 후 해야 할 일

없습니다. 다음 `/metrics`·`/harvest`의 `backfill.sh`가 이벤트를 재추출합니다.

## v0.22.3 (2026-09-13)

`guard_block`·`permission_deny` 판정을 실측 형태에 맞춰 좁히고, 툴을 알 수 없는 결과에 폴백을 둡니다. 로컬 transcript 전수 대조에서 이 변경 전후 수치는 동일합니다(guard_block 51, permission_deny 3) — 지금 잡히는 신호는 그대로 두고, 놓칠 수 있는 경로만 막습니다.

### 버그 수정

- **툴을 알 수 없는 결과에서도 훅 차단을 센다.** `guard_block`은 0.22.2에서 편집 툴(Edit/Write/MultiEdit/NotebookEdit)의 `is_error` 결과로 한정했는데, `tool_use_id`가 없는 구형 transcript나 압축으로 `tool_use`가 사라진 결과는 툴을 알 수 없어 진짜 차단까지 빠질 수 있었습니다. 이제 툴을 못 알아내는 결과는 **줄 시작 접두어**만으로 판정합니다. `git log` 출력처럼 줄 중간에 문구가 섞인 경우는 여전히 제외됩니다.
- **차단 메시지의 실제 래퍼를 인식한다.** Claude Code는 훅 stderr를 `PreToolUse:<툴> hook error: [<훅 경로>]: ` 로 감싸 tool_result에 넣습니다. 실측 차단 51건이 전부 이 형태였고, 접두어 판정이 이 래퍼를 허용합니다.
- **`permission_deny`의 사장 분기를 제거한다.** 로컬 transcript의 `is_error` tool_result 576건 중 실제 거부는 `The user doesn't want to proceed with this tool use.` 한 형태뿐이었고, 소문자 `user rejected`로 시작하는 결과는 한 건도 없었습니다. 관측되지 않는 분기를 지우고 fixture를 실제 메시지로 교체했습니다. Codex 어댑터는 브리지 봉투(`is_error`) 안에서 문구를 찾는 방식 그대로입니다 — 로컬 corpus에 실제 Codex 거부 사례가 없어 봉투의 정확한 문구를 확정하지 못했습니다.

### 업데이트 후 해야 할 일

없습니다. 다음 `/metrics`·`/harvest`의 `backfill.sh`가 이벤트를 재추출합니다.

## v0.22.2 (2026-09-12)

`guard_block`·`error`·`permission_deny` 신호가 문구 매칭으로 부풀던 문제를 고칩니다. 첫 `/harvest`(ai-harness 프로젝트)가 이 가짜 신호로 열린 분석 batch를 정독한 결과입니다.

### 버그 수정

- **Claude `guard_block`은 편집 툴의 `is_error` 결과에서만 셉니다.** 지금까지는 tool_result 본문 어디든 `[Direct edit guard]`가 있으면 차단으로 집계돼, `git log` 출력의 커밋 메시지(#18)·PR 본문·AGENTS.md Read가 모두 차단으로 잡혔습니다. ai-harness 30일 통계의 guard_block 18건(4세션)은 전부 이 경우였고 실제 차단은 0건이었습니다. 가드 훅은 Edit/Write/MultiEdit/NotebookEdit에만 걸리므로 `tool_use_id`로 호출 툴을 확인해, `Exit code 1`로 끝난 Bash 출력에 같은 문구가 섞인 경우(`is_error`이지만 차단 아님)를 제외합니다.
- **Claude `permission_deny`는 `is_error` 결과가 거부 문구로 시작할 때만 셉니다.** 추출기 소스(`extract-claude.jq`) Read, PR 본문, 커밋 메시지에 들어 있던 `doesn't want to proceed`·`user rejected` 문구가 거부로 잡히던 문제를 고칩니다. ai-harness 두 번째 `/harvest` batch의 permission_deny 4건(3세션)이 전부 이 경우였습니다.
- **Codex `guard_block`은 출력 줄 시작의 접두어만 셉니다.** 줄 중간에 섞인 같은 문구는 무시합니다.
- **Codex `error`는 실패한 호출만 셉니다.** 출력 본문의 `isError`/`is_error` 단어를 세던 것을, 브리지 JSON 봉투(`{"is_error":true,...}`로 시작) 또는 Codex CLI 셸 푸터의 `Process exited with code N`(N≠0)으로 바꿨습니다. React 소스의 `isError &&`나 `cat`한 스크립트 본문이 오류로 잡혀 분석 batch를 `errors` 사유로 열던 문제(batch 오류 35건 중 실제 0건)가 사라지고, 반대로 지금까지 0으로 보이던 실제 셸 실패가 Claude와 같은 기준으로 집계됩니다.
- **Codex `permission_deny`도 브리지 봉투가 `is_error`일 때만 셉니다.** Claude 쪽과 기준을 맞춰, 출력에 인용된 거부 문구와 AskUserQuestion의 `clarify` 선택을 제외합니다.

### 업데이트 후 해야 할 일

없습니다. 다음 `/metrics`·`/harvest`의 `backfill.sh`가 이벤트를 재추출하면서 기존 세션의 수치도 다시 계산됩니다.

## v0.22.1 (2026-09-11)

`/harness-init`이 역할 페르소나를 만들 때 `model` frontmatter를 빠뜨리는 문제를 고칩니다.

### 버그 수정

- **역할 agent `model` 누락** — 모델 매핑 표는 있었지만 생성 단계가 이를 지키지 않아 `.claude/agents/*.md`에 `model` 없이 생성되는 경우가 있었습니다. Claude Code는 `model`이 없으면 부모 세션 모델을 상속하므로, reviewer가 sonnet으로 내려가거나 developer가 opus로 올라가 등급 설계가 무력화됐습니다. 이제 `model` 없는 역할 agent는 생성 실패로 취급하고, **보고보다 먼저** 실행하는 마무리 self-check가 `.claude/agents/*.md`와 `.codex/agents/*.toml`의 `model` 누락을 직접 검사합니다. 선택하지 않은 도구 디렉터리에서 오탐이 나지 않도록 `nullglob`을 켜고, Codex 쪽은 `model_reasoning_effort`와 구분되게 `^model[[:space:]]*=`로 검사합니다.
- **`docs-updater`가 문서에 없는 채로 생성되던 문제** — `docs-updater`는 실제로 생성되는 역할 페르소나인데 생성 구조 목록에도, 모델 매핑 표에도 없었습니다. 참조할 기본값이 없어 `model`도 함께 빠졌습니다. 생성 구조(`.claude/agents/`, `.codex/agents/`)와 매핑 표(`sonnet`)에 모두 추가했습니다. 표에 없는 역할을 새로 만들면 기본 모델도 표에 함께 추가하도록 규칙을 명시했습니다.

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
