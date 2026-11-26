# Testing

테스트 정책: **TDD** — 실패하는 회귀 테스트(Red) → 최소 구현(Green) → 테스트를 바꾸지 않는 Refactor. 테스트는 영역 파일 `tests/<영역>.sh`에 기존 관례로 쓴다.

## 구조

- `tests/run.sh` — 진입점. 영역 파일을 하나씩 별도 프로세스로 돌리고 영역별 통과 수·시간을 낸다. 영역을 띄우기 전에 직렬로 실행 캐시 `${TMPDIR:-/tmp}/ai-harness-testcache.XXXXXX`(실행마다 새로 만듦, 영역 정리 패턴 `ai-harness-tests.*`에 걸리지 않는 이름)에 기준 저장소 템플릿(빈 커밋 `init`·user `t@t`)을 만들어 경로를 `HM_TEST_REPO_TEMPLATE`로 넘기고, 끝나거나 끊기면(EXIT·INT·TERM) 지운다. `--list`·`--lint`·`--explain`과 돌릴 영역이 없을 때는 만들지 않는다. 템플릿 생성 함수는 `tests/lib-repo-template.sh`의 `ensure_repo_template`(옆 임시 디렉토리에 만든 뒤 rename으로 확정해 동시에 만들어도 하나만 남는다)이고, 이 파일이 바뀌면 `--changed`는 전체를 고른다.
- `tests/lib.sh` — 공용 준비(`$TEST_TMP`·격리 환경변수·fixture 경로·`make_repo`)와 단언 함수. 영역 파일이 source한다. macOS에서는 `/usr/bin/git`·`/usr/bin/python3`(xcrun 껍데기) 대신 실제 도구 링크를 `$TEST_TMP/real-bin`에 두고 PATH 앞에 넣는다(링크 git은 `GIT_EXEC_PATH`로 실제 git-core를 알려 준다) — 영역 셸뿐 아니라 그 아래 러너·보드·가짜 CLI도 실제 도구를 부른다. `PROJECT_REPO`·`PROJECT_WORKTREE`는 경로만 정하고, 저장소는 쓰는 영역(core·release·workflow)이 머리에서 `make_project_repo`로 만든다(지연 생성). `START_COMMAND`·`START_INPUT`은 쓰는 영역이 직접 만든다. `copy_repo_template <dst>`는 기준 저장소 템플릿을 `cp -R`로 복사한다(`git init`·`commit` 두 번 대신 복사 한 번) — `HM_TEST_REPO_TEMPLATE`가 유효하면 그것을, 없거나 없는 경로면(영역 단독 실행) 처음 쓸 때 `$TEST_TMP/repo-template`에 한 번 만들어 쓴다. 영역은 템플릿을 복사 원본으로만 읽는다. 지금은 `lib-driver.sh`의 `new_driver_repo`만 쓴다(`NEW_REPO_LINKED`의 worktree, `with_policy`의 커밋·bare 원격은 복사 뒤 그대로 만든다). 복사본끼리 init 커밋 해시가 같다.
- `tests/lib-<이름>.sh` — 몇몇 영역만 쓰는 공용 헬퍼(영역 아님). 예: `lib-driver.sh`는 그래프 러너 영역(`workflow*`)이 `lib.sh` 다음에 source한다. 바뀌면 `--changed`가 그 파일 이름을 언급하는 영역을 고른다.
- `tests/<영역>.sh` — 영역별 블록. 목록은 `bash tests/run.sh --list`, 각 파일 머리 주석이 다루는 범위다. 파일마다 자기 `$TEST_TMP`를 쓰므로 영역끼리 상태를 나누지 않는다.

## 실행

```bash
bash tests/run.sh --changed       # 작업 중: origin/develop 대비 바뀐 파일을 다루는 영역만
bash tests/run.sh --changed --explain   # 실행하지 않고 파일별 선택 근거(`<파일> -> <결과>`)와 마지막 줄 `# 선택: <영역들>`만
bash tests/run.sh <영역>...       # Red/Green 반복: 그 블록이 있는 영역만 (예: board init)
bash tests/run.sh --lint          # 바뀐 셸 파일만 bash -n + shellcheck (파일마다 따로)
bash tests/run.sh --fast          # 느린 영역(tests/slow-areas.txt: 실제 러너·서버를 띄우는 영역) 제외
bash tests/run.sh                 # 전체 — PR 직전 한 번. 러너 아래에서는 HM_TEST_JOBS로 병렬, 러너 밖에서 -j·HM_TEST_JOBS가 둘 다 없으면 max(1, min(CPU/2, 6))
bash tests/run.sh --profile <영역>...   # 끝에 느린 블록 30개(직전 ok부터 그 ok까지)를 낸다
bash tests/run.sh --shard 1/4     # CI matrix 샤드: 고른 영역 중 1번 몫만
bash -n scripts/*.sh scripts/board/*.sh tests/*.sh                       # 문법 (PR 직전)
npx --yes shellcheck -S style -x scripts/*.sh scripts/board/*.sh tests/*.sh   # CI와 같은 수준 (PR 직전)
scripts/release-prep.sh --check                                          # 버전 네 곳 정합성 (develop에서도 통과)
```

- 러너 밖에서 사람이 직접 칠 때 `-j`·`HM_TEST_JOBS`가 없으면 CPU 기본값으로 병렬로 돈다. 직렬은 `-j 1`, 동시 실행 수를 직접 고르려면 `-j N`(예: `-j 2`)을 붙인다. CI는 `-j` 대신 matrix 샤드(`--shard ${{ matrix.shard }}/4`)로 나눠 돈다(`.github/workflows/test.yml`).
- **평소에는 바뀐 영역만, 전체 실행은 PR을 만들기 직전에 한 번.** 전체는 수 분 걸리고 그래프 러너·보드 서버를 실제로 띄운다. 여러 세션이 동시에 전체를 돌리면 메모리가 그만큼 곱으로 든다.
- `-j N`은 영역을 최대 N개까지 동시에 돌린다(1 이상의 정수, 영역 수보다 크면 영역 수로 줄인다). `--fast`·`--changed`·영역 이름과 같이 쓸 수 있다. `-j`가 없으면 환경변수 `HM_TEST_JOBS`(1 이상의 정수, 아니면 `-j`와 같은 오류로 exit 2)를 동시 실행 수로 쓰고, `-j`가 있으면 `-j`가 이긴다. 둘 다 없으면 `max(1, min(ncpu/2, 6))`다 — ncpu는 그래프 러너 `resolve_check_jobs`와 같은 순서(`getconf _NPROCESSORS_ONLN` → `sysctl -n hw.ncpu` → `nproc` → 1)로 구하고, 값이 1이면 직렬 경로를 탄다. 그래프 러너도 모든 검사에 같은 식의 `HM_TEST_JOBS`(사용자 `~/.ai-harness/config`의 값이 먼저)를 넘긴다. 영역마다 그래프 러너·보드 서버를 띄우므로 동시 실행 수만큼 메모리가 든다. `run.sh`는 메모리를 재거나 동시 실행 수를 알아서 줄이지 않으므로, 다른 세션이 테스트를 돌리는 중이거나 메모리가 빠듯하면 `-j 1`(또는 `HM_TEST_JOBS=1`)로 직렬로 돌린다. Brief·검사 명령에는 `-j`를 적지 않는다 — `-j`가 러너의 `HM_TEST_JOBS`를 덮는다(#544).
- `--profile`은 영역마다 `tests/profile-blocks.py` 하나가 영역을 띄워 출력을 그대로 흘리며 `ok ` 줄 도착 시각(단조 시계)을 기록하고, 요약 다음에 `# profile: slowest blocks`와 느린 순서로 최대 30줄 `#   <초>s <영역> ok <n> - <설명>`을 낸다. 블록 시간은 직전 `ok`(첫 블록은 영역 시작)부터 그 `ok`까지다. 다른 옵션과 같이 쓸 수 있고, 없으면 출력은 그대로다. 느린 영역을 고칠 때 먼저 이걸로 가장 큰 블록을 찾는다. 실측(#556, macOS 12코어, `-j 3`): 예전 세 영역 automation 424초·workflow-merge 327초·workflow-runs 309초를 영역 32개로 나눠 각 9~61초가 됐다. 실측(#570, macOS 12코어, 기본 `-j 4`, 다른 작업으로 load average 13 안팎): 30초를 넘던 workflow-feature 216초·design 184초·board 192초·workflow-release 149초·workflow-publish 138초·init 135초·workflow-merge-sync 104초·workflow 90초·workflow-merge 81초를 블록 경계(큰 블록은 안쪽 단계 경계)로 영역 70여 개로 나눠 각 5~39초가 됐고, 전체 병렬 실행은 722초에서 457초로 줄었다. 같은 부하에서 30초를 넘게 남은 영역은 board-status·automation-sync·autofix·core·design-landing-measure-bad·setup·board-autofix(30~46초)다. 실측(#585, macOS 12코어, `-j 6`, load average 3~6): 그중 board-status 43초·automation-sync 44초·core 40초·autofix 44초·setup 43초를 블록 경계로 영역 14개(`board-status-attach`·`board-status-refresh`·`automation-sync-supersede`·`automation-sync-session`·`core-parallel`·`core-runner`·`autofix-state`·`setup-design`·`setup-credentials` 등, 공용 앞단은 `lib-auto-sync.sh`·`lib-autofix.sh`·`lib-setup.sh`)로 나눠 각 9~24초가 됐고, design-landing-measure-bad는 측정 입력(`tests/fixtures/landing-measure/bad`)의 페이지 높이·스크롤 지연을 줄여 같은 결함 9개를 잡으며 38초에서 25초 안팎이 됐다. board-autofix는 같은 측정에서 24초라 나누지 않았다. 부하가 load average 11 안팎으로 오르면 automation-chain-global(40초)·init(38초)이 30초를 넘는다. 실측(#614, macOS 12코어, `-j 6`): 같은 영역 묶음(core·workflow-merge·board-autofix·workflow-release-notes·automation-merge)을 기준(merge-base)과 나란히 쟀더니 다른 세션 부하로 load average 40~60일 때 벽시계 132초→47초, CPU(user+sys) 103초→75초였고, load 15~24일 때 다른 묶음(workflow-merge·workflow-release·board-autofix·init·automation-merge·core)은 CPU 88~93초→74~79초였다. 전체 `bash tests/run.sh`(기본 6 동시)는 기준 346초(load 7→21, 476 통과)였다. 변경 뒤 전체는 같은 머신에서 다른 세션들이 전체 테스트를 돌려 load 27~47이라 180초 목표를 확인하지 못했다(통과 478 = 기준 476 + 새 블록 2). 영역 하나의 비용은 대부분 제품 스크립트(러너·보드·init)가 띄우는 jq·git 프로세스이고, xcrun 껍데기 git은 호출당 약 13ms(실제 git 약 5ms)였다.
- 공통 비용 측정(#614 2차, merge-base 기준, macOS 12코어, 영역 121개를 6개씩 병렬, 다른 세션 부하로 load average 25~38): PATH 앞에 둔 일회용 래퍼(`$TEST_TMP` 밖 임시 디렉토리, 커밋하지 않음)가 `git`(서브커맨드별)·`jq`·`python3`(스크립트별) 호출을 영역별로 세고, 부른 쪽이 영역 셸인지 제품 스크립트인지 부모 pid로 나눴다. 공용 헬퍼(`make_repo`·`new_driver_repo`·`with_policy`·`driver`·`board_sh`·`br_start`·`free_port`)는 임시로 감싸 호출마다 시작·끝 시각을 남기고 `--profile`의 블록 경계(`profile-blocks.py run`)에 맞춰 블록 수를 셌다. 다시 재려면 같은 래퍼와 감싸기를 기준 worktree에 임시로 얹고 영역마다 `profile-blocks.py run`으로 돌린다. 초는 호출 시간의 직렬 합(감싸기 오버헤드 호출당 약 20ms 포함)이다. jq·python3는 시각을 남기지 않아 호출 수 × 따로 잰 호출당 시간(jq 약 6ms, python3 시작 약 80ms)으로 추정했고, 블록 수는 그 범주가 나온 영역의 블록 합이다. 러너 기동 시간에는 그 안의 jq·git이 들어 있어 행끼리 겹친다.

  | 범주 | 영역 수 | 블록 수 | 호출 수 | 초 |
  |---|---|---|---|---|
  | 그래프 러너 기동(`driver` → `workflow-driver.sh` 한 번) | 67 | 119 | 462 | 2016 |
  | jq 반복 | 119 | 466 | 105,786 (제품 스크립트 103,746 · 영역 셸 2,040) | 약 620 (추정) |
  | 가짜 저장소 `git init`·커밋(`new_driver_repo` 324 · `with_policy` 165 · `make_repo` 50) | 95 | 135 | 539 (영역 셸의 `git init`·`commit` 1,449) | 80 |
  | 보드 서버 기동·대기(`board_sh open`·`br_start` 10, 런처 `board_sh launcher` 53) | 6 | 8 | 63 | 46 (런처 39) |
  | python3 반복(`free_port` 30 포함, `profile-blocks.py` 제외) | 29 | 232 | 451 | 약 36 (추정, `free_port` 3.5) |

  러너 가짜 CLI(`tests/fixtures/driver`)는 정적 파일을 PATH 앞에 둘 뿐이라 만드는 비용이 없어 캐시하지 않았다. 적용한 수단은 기준 저장소 템플릿 캐시 하나다: `new_driver_repo`가 실행 캐시의 템플릿을 `cp -R`한다. 100회를 따로 재면 `git init`+`commit`이 CPU 2.8초, 복사가 1.7초(호출당 약 11ms)라 전체 324회로 CPU 약 3.6초가 준다. `make_repo`(50회, 4.9초)는 user가 `test@example.com`이고 origin 변형이 있어 템플릿을 하나 더 둬야 하는데 줄어드는 몫이 1초 안팎이라 적용하지 않았다. 보드 서버를 영역당 한 번으로 묶는 것도 적용하지 않았다 — 재기동이 있는 블록(`board`의 재사용·포트 점유, `board-idle`의 `BOARD_IDLE_EXIT` 값별 기동, `board-resident`의 보드 재기동 뒤 세션 유지, `board-resident-upgrade`의 호스트 교체, `board-launcher`의 `bo_reset` 런처 빌드)은 모두 재기동 자체가 검증 대상이고, `board-guide`는 블록마다 서버를 띄우지 않는다. 남은 큰 몫은 러너가 띄우는 jq(호출의 98%)와 git이다 — 테스트 준비가 아니라 제품 스크립트 비용이라 이 범위에서 줄이지 않았다. 적용 전후(같은 머신, `-j 4`, 기준 merge-base와 번갈아 두 번, load average 17~31)로 workflow 11개·core·core-runner·board-autofix·board-status·init 15개 영역 묶음(93 통과로 같음)을 `/usr/bin/time -p`로 재면 CPU(user+sys)는 기준 173.9·177.6초, 변경 뒤 162.7·140.1초였다(벽시계 87·87초 → 83·64초). 줄어든 폭이 단독 측정보다 큰 것은 부하 변동이 섞인 탓이라, 이 수치는 방향만 본다.
- `--shard i/n`(1≤i≤n, 아니면 exit 2)은 다른 선택(`--fast`·`--changed`·영역 이름)을 적용한 영역 목록을 `slow-areas.txt` 순서 다음 나머지 순서로 놓고 위치 k(0부터)가 `k % n == i-1`인 영역만 돌린다. 샤드끼리 겹치지 않고 합치면 전체다. 몫이 비면 `돌릴 영역이 없음`과 exit 0. CI는 `lint` job과 `shard` job의 matrix `shard: [1, 2, 3, 4]`(`--shard ${{ matrix.shard }}/4`, 샤드 안 동시 실행 수는 CPU 기본값)로 돌고, 둘을 `needs`로 묶는 집계 job `test`(`if: always()`, 하나라도 success가 아니면 실패)가 브랜치 보호의 필수 체크다 — matrix 수를 바꾸면 `--shard`의 N도 같이 바꾸고, job을 추가하면 `test`의 `needs`에도 넣는다(`tests/core-runner.sh`가 검사).
- `-j`일 때 느린 영역(`tests/slow-areas.txt`에 적힌 순서, 긴 것부터)을 먼저 시작하고, 출력은 영역별로 모았다가 블록째 시작 순서로 낸다(앞 영역을 기다리는 동안 끝난 영역은 stderr에 `# <영역> finished in Ns`). 실패 요약·종료 코드는 직렬과 같다. Ctrl-C·TERM으로 끊으면 돌던 영역에 TERM을 보내 서버·`$TEST_TMP`를 치우게 하고, 이미 끝난 영역의 출력만 내보낸 뒤 `# interrupted: <끝난 수> of <전체> areas finished`와 함께 130(INT)·143(TERM)으로 끝난다.
- `--changed`는 바뀐 경로(없으면 상위 폴더)를 언급하는 영역 파일을 고른다. `--explain`을 붙이면 테스트를 돌리지 않고 근거만 낸다(`--changed` 없이 쓰면 exit 2, `-j`는 무시). `tests/lib.sh`·`tests/run.sh`·`scripts/lib.sh`가 바뀌면 전체를 고른다. `tests/slow-areas.txt`(한 줄에 영역 하나, `#` 주석·빈 줄 무시)가 바뀌면 기준 대비 추가·삭제된 줄의 영역만(실제 영역만, 미추적 새 파일이면 적힌 영역 전체) 고른다 — 느린 영역을 추가·삭제할 때는 `run.sh`가 아니라 이 파일을 고친다. 파일이 없으면 느린 영역은 없다. 메타 파일은 영역을 넓히지 않는다: `CHANGELOG.md`·`changelog.d/*`는 고르지 않고, `.ai-harness/harness.json`은 기준 대비 `harness_version`·`managed_files.*`의 `content_sha256`·`template_version`만 바뀌었으면 고르지 않는다(다른 키·항목 추가/삭제·비교 불가면 경로로 고른다). `templates/managed-files.json`의 `artifacts[].path`와 같은 생성물 사본은 같은 항목의 `source`(원본) 경로로 고른다. 어느 영역에도 걸리지 않은 파일은 stderr에 적는다 — 그 파일은 전체 실행으로 확인한다.
- CI(`.github/workflows/test.yml`)의 `lint` job은 apt의 `shellcheck -x`를 기본 심각도(style 포함)로 돌린다. CI 버전은 로컬 Homebrew 버전보다 엄격할 수 있다 — 예: `A && B || C` 패턴의 SC2015도 실패로 본다. 로컬에서는 `-S style`을 붙여 같은 수준으로 확인한다.
- 영역 파일 하나는 위에서 아래로 돌고 첫 실패에서 멈춘다(`fail` → exit 1). `tests/run.sh`는 실패한 영역이 있어도 나머지 영역을 마저 돌리고 끝에 `# FAILED: <영역>`을 낸다. 실패 메시지 `FAIL: <설명> (expected=... actual=...)`로 위치를 찾는다.
- 셸 스크립트가 아닌 파일만 바꿨어도 테스트는 돌린다 — 템플릿 바이트 일치·Skill 본문 문구·카탈로그를 검사하는 블록이 있다(`--changed`가 경로로 찾아 준다).

## 작성 규칙 (실측)

- 새 블록은 다루는 기능의 영역 파일 끝에 붙인다. 같은 파일 안의 앞 블록 변수·함수는 써도 되지만 다른 영역 파일의 것은 쓸 수 없다 — 모든 영역이 쓰는 고정 값은 `tests/lib.sh`에, 몇몇 영역만 쓰는 헬퍼는 `tests/lib-<이름>.sh`에 둔다. 영역 하나가 1분을 넘기면 `--profile`로 큰 블록을 찾아 새 영역(`<영역>-<주제>.sh`)으로 나눠 병렬·샤드가 듣게 하고 `tests/slow-areas.txt`를 실측 순서로 고친다. 큰 블록을 나눌 때는 단언을 그대로 옮기고 앞 몫에 새 `pass`를 붙인다 — 앞 블록이 남기던 상태(내보낸 환경변수·마커·기록)는 새 영역 머리에서 다시 만든다. 여러 영역이 쓰는 앞단은 `tests/lib-<이름>.sh`로 뺀다(예: `lib-sync-chain.sh`). 새 영역 파일은 기존 파일처럼 `source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"`로 시작해 `finish_tests`로 끝낸다.
- 무언가가 일어나기를 기다릴 때는 고정 `sleep N` 대신 조건 대기(`for _ in $(seq 1 50); do <조건> && break; sleep 0.1; done`, 이어서 단언이나 `fail`로 원인을 남긴다)를 쓴다. "N초 동안 일어나지 않음"을 보는 대기만 의미를 지키는 최소 시간으로 남기고 근거를 주석에 적는다. 러너 폴링은 테스트에서 기존 env(`HM_MERGE_POLL_SECONDS`·`HM_MERGE_PENDING_POLL_SECONDS`·`HM_MERGE_PENDING_RETRIES`·`HM_SMOKE_RETRY_SECONDS`)를 작게 준다. 보드 서버 간격은 테스트에서 기존 env(`BOARD_REFRESH_SECONDS`·`BOARD_FULL_REFRESH_SECONDS`)와 `BOARD_STALE_SYNC_SECONDS`(상태 캐시를 그 자리에서 다시 모으는 간격, 기본 30초)를 작게 준다.
- 한 블록 = 한 동작. 블록 위에 왜 필요한지 한국어 주석, 본문은 `assert_eq <기대> <실제> <설명>`·`assert_contains`·`assert_file`·`assert_not_file`·`fail`, 끝에 `pass "<설명>"`.
- 임시 파일은 `$TEST_TMP`(영역 파일마다 만들고 종료 시 지움) 아래에만. 백그라운드로 띄운 서버는 인자에 `$TEST_TMP` 경로가 들어가게 한다 — 종료 시 `cleanup()`이 `$TEST_TMP`를 인자에 가진 프로세스를 모두 끈다. 사용자 홈을 건드리지 않게 격리 환경변수를 쓴다: `HARNESS_METRICS_DIR`, `HM_AUTO_WORKTREE_DIR`, `HM_CLAUDE_SKILLS_DIR`·`HM_CODEX_SKILLS_DIR`, `HM_BACKFILL_INTERVAL_HOURS=0`, `HM_SETUP_HINT=0`, `HM_IMPACT_HINT=0`(파일 머리에서 기본값을 정한다). 백그라운드로 띄운 가짜 프로세스가 자식(`sleep` 등)을 남기면 그 자식이 영역 출력 파이프를 쥐어 run.sh가 영역 끝에서 기다리므로, 출력을 `>/dev/null 2>&1`로 닫고 끝낼 때 자식도 끈다(`pkill -P`).
- git이 필요한 테스트는 `make_repo dir [origin]`을 쓰면 된다 — `$TEST_TMP` 아래에 `user.email test@example.com`·빈 커밋 하나를 갖춘 저장소를 만들고 origin은 선택이다(user 설정·origin을 `.git/config`에 직접 써 git 프로세스를 줄인다. 따옴표가 필요한 주소만 `git remote add`). 원격은 `git init --bare` 로컬 경로. 공용 프로젝트 저장소(`PROJECT_REPO`)가 필요하면 영역 머리에서 `make_project_repo`를 부른다.
- fixture는 `tests/fixtures/<종류>/`(`claude/`·`codex/` 세션 기록, `driver/` 러너용 가짜 CLI, `ab/` A/B 정답 구현). 실제 사람·회사 식별자 금지.
- 외부 서비스(GitHub·Bitbucket·LLM)는 호출하지 않는다 — 가짜 실행 파일 디렉토리를 `PATH` 앞에 두는 방식이 기존 관례다(예: 러너 테스트의 `PATH="$ROOT/tests/fixtures/driver:$PATH"`).
- macOS `/bin/bash` 3.2에서도 돌아야 한다(`tests/core.sh`가 fd 누수 패턴을 검사). 명령 인자인 `"$(... "{a, b}" ...)"`의 안쪽 큰따옴표 문자열에 든 쉼표 중괄호도 3.2가 펼치므로, 안쪽 문자열은 변수나 작은따옴표로 뺀다(`tests/bash32-check.py`가 `--lint`·core 영역에서 검사).

## 평가(evals)는 별개

`evals/<skill>/<case>/`는 Skill 평가 과제, `evals/ab/`는 `scripts/ab.sh` A/B 실험 과제다. 회귀 테스트가 아니므로 `tests/`를 대신하지 않는다. 과제를 추가하면 `evals/ab/README.md` 절차를 따른다.
