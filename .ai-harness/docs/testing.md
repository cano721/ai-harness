# Testing

테스트 정책: **TDD** — 실패하는 회귀 테스트(Red) → 최소 구현(Green) → 테스트를 바꾸지 않는 Refactor. 테스트는 영역 파일 `tests/<영역>.sh`에 기존 관례로 쓴다.

## 구조

- `tests/run.sh` — 진입점. 영역 파일을 하나씩 별도 프로세스로 돌리고 영역별 통과 수·시간을 낸다.
- `tests/lib.sh` — 공용 준비(`$TEST_TMP`·격리 환경변수·fixture 경로·`make_repo`)와 단언 함수. 영역 파일이 source한다.
- `tests/lib-<이름>.sh` — 몇몇 영역만 쓰는 공용 헬퍼(영역 아님). 예: `lib-driver.sh`는 그래프 러너 영역(`workflow*`)이 `lib.sh` 다음에 source한다. 바뀌면 `--changed`가 그 파일 이름을 언급하는 영역을 고른다.
- `tests/<영역>.sh` — 영역별 블록. 목록은 `bash tests/run.sh --list`, 각 파일 머리 주석이 다루는 범위다. 파일마다 자기 `$TEST_TMP`를 쓰므로 영역끼리 상태를 나누지 않는다.

## 실행

```bash
bash tests/run.sh --changed       # 작업 중: origin/develop 대비 바뀐 파일을 다루는 영역만
bash tests/run.sh <영역>...       # Red/Green 반복: 그 블록이 있는 영역만 (예: board init)
bash tests/run.sh --lint          # 바뀐 셸 파일만 bash -n + shellcheck (파일마다 따로)
bash tests/run.sh --fast          # 느린 영역(tests/slow-areas.txt: 실제 러너·서버를 띄우는 영역) 제외
bash tests/run.sh                 # 전체 — PR 직전 한 번. 러너 아래에서는 HM_TEST_JOBS로 병렬, 러너 밖에서 -j·HM_TEST_JOBS가 둘 다 없으면 직렬 (로컬 약 18분)
bash -n scripts/*.sh scripts/board/*.sh tests/*.sh                       # 문법 (PR 직전)
npx --yes shellcheck -S style -x scripts/*.sh scripts/board/*.sh tests/*.sh   # CI와 같은 수준 (PR 직전)
scripts/release-prep.sh --check                                          # 버전 네 곳 정합성 (develop에서도 통과)
```

- 러너 밖에서 사람이 직접 병렬로 돌리려면 `-j N`을 붙인다(예: `-j 2`, 로컬 약 9분). CI는 `-j 2`로 고정돼 있다(`.github/workflows/test.yml`).
- **평소에는 바뀐 영역만, 전체 실행은 PR을 만들기 직전에 한 번.** 전체는 수 분 걸리고 그래프 러너·보드 서버를 실제로 띄운다. 여러 세션이 동시에 전체를 돌리면 메모리가 그만큼 곱으로 든다.
- `-j N`은 영역을 최대 N개까지 동시에 돌린다(1 이상의 정수, 영역 수보다 크면 영역 수로 줄인다). `--fast`·`--changed`·영역 이름과 같이 쓸 수 있다. `-j`가 없으면 환경변수 `HM_TEST_JOBS`(1 이상의 정수, 아니면 `-j`와 같은 오류로 exit 2)를 동시 실행 수로 쓰고, `-j`가 있으면 `-j`가 이긴다. 그래프 러너는 모든 검사에 `HM_TEST_JOBS`(사용자 `~/.ai-harness/config`의 `HM_TEST_JOBS`, 없으면 `max(1, min(ncpu/2, 4))`)를 넘기므로 러너 아래의 `--changed`는 병렬로 돈다. 둘 다 없으면 직렬이다 — 영역마다 그래프 러너·보드 서버를 띄우고 다른 세션도 같은 머신에서 테스트를 돌릴 수 있어, 동시 실행 수만큼 메모리가 든다. `run.sh`는 메모리를 재거나 동시 실행 수를 알아서 줄이지 않으므로, 다른 세션이 테스트를 돌리는 중이거나 메모리가 빠듯하면 `-j` 없이 직렬로 돌린다. Brief·검사 명령에는 `-j`를 적지 않는다 — `-j`가 러너의 `HM_TEST_JOBS`를 덮는다(#544).
- `-j`일 때 느린 영역(`tests/slow-areas.txt`에 적힌 순서, 긴 것부터)을 먼저 시작하고, 출력은 영역별로 모았다가 블록째 시작 순서로 낸다(앞 영역을 기다리는 동안 끝난 영역은 stderr에 `# <영역> finished in Ns`). 실패 요약·종료 코드는 직렬과 같다. Ctrl-C·TERM으로 끊으면 돌던 영역에 TERM을 보내 서버·`$TEST_TMP`를 치우게 하고, 이미 끝난 영역의 출력만 내보낸 뒤 `# interrupted: <끝난 수> of <전체> areas finished`와 함께 130(INT)·143(TERM)으로 끝난다.
- `--changed`는 바뀐 경로(없으면 상위 폴더)를 언급하는 영역 파일을 고른다. `tests/lib.sh`·`tests/run.sh`·`scripts/lib.sh`가 바뀌면 전체를 고른다. `tests/slow-areas.txt`(한 줄에 영역 하나, `#` 주석·빈 줄 무시)가 바뀌면 기준 대비 추가·삭제된 줄의 영역만(실제 영역만, 미추적 새 파일이면 적힌 영역 전체) 고른다 — 느린 영역을 추가·삭제할 때는 `run.sh`가 아니라 이 파일을 고친다. 파일이 없으면 느린 영역은 없다. 어느 영역에도 걸리지 않은 파일은 stderr에 적는다 — 그 파일은 전체 실행으로 확인한다.
- CI(`.github/workflows/test.yml`)는 apt의 `shellcheck -x`를 기본 심각도(style 포함)로 돌린다. CI 버전은 로컬 Homebrew 버전보다 엄격할 수 있다 — 예: `A && B || C` 패턴의 SC2015도 실패로 본다. 로컬에서는 `-S style`을 붙여 같은 수준으로 확인한다.
- 영역 파일 하나는 위에서 아래로 돌고 첫 실패에서 멈춘다(`fail` → exit 1). `tests/run.sh`는 실패한 영역이 있어도 나머지 영역을 마저 돌리고 끝에 `# FAILED: <영역>`을 낸다. 실패 메시지 `FAIL: <설명> (expected=... actual=...)`로 위치를 찾는다.
- 셸 스크립트가 아닌 파일만 바꿨어도 테스트는 돌린다 — 템플릿 바이트 일치·Skill 본문 문구·카탈로그를 검사하는 블록이 있다(`--changed`가 경로로 찾아 준다).

## 작성 규칙 (실측)

- 새 블록은 다루는 기능의 영역 파일 끝에 붙인다. 같은 파일 안의 앞 블록 변수·함수는 써도 되지만 다른 영역 파일의 것은 쓸 수 없다 — 모든 영역이 쓰는 고정 값은 `tests/lib.sh`에, 몇몇 영역만 쓰는 헬퍼는 `tests/lib-<이름>.sh`에 둔다. 영역 하나가 3분을 넘기면 블록을 새 영역으로 나눠 `-j`가 듣게 한다(그래프 러너는 `workflow`·`workflow-feature`·`workflow-publish`·`workflow-merge`·`workflow-merge-sync`·`workflow-runs`). 새 영역 파일은 기존 파일처럼 `source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"`로 시작해 `finish_tests`로 끝낸다.
- 한 블록 = 한 동작. 블록 위에 왜 필요한지 한국어 주석, 본문은 `assert_eq <기대> <실제> <설명>`·`assert_contains`·`assert_file`·`assert_not_file`·`fail`, 끝에 `pass "<설명>"`.
- 임시 파일은 `$TEST_TMP`(영역 파일마다 만들고 종료 시 지움) 아래에만. 백그라운드로 띄운 서버는 인자에 `$TEST_TMP` 경로가 들어가게 한다 — 종료 시 `cleanup()`이 `$TEST_TMP`를 인자에 가진 프로세스를 모두 끈다. 사용자 홈을 건드리지 않게 격리 환경변수를 쓴다: `HARNESS_METRICS_DIR`, `HM_AUTO_WORKTREE_DIR`, `HM_CLAUDE_SKILLS_DIR`·`HM_CODEX_SKILLS_DIR`, `HM_BACKFILL_INTERVAL_HOURS=0`, `HM_SETUP_HINT=0`, `HM_IMPACT_HINT=0`(파일 머리에서 기본값을 정한다).
- git이 필요한 테스트는 `$TEST_TMP` 아래에 `git init -q`로 저장소를 만들고 `user.email test@example.com`을 설정한다. 원격은 `git init --bare` 로컬 경로.
- fixture는 `tests/fixtures/<종류>/`(`claude/`·`codex/` 세션 기록, `driver/` 러너용 가짜 CLI, `ab/` A/B 정답 구현). 실제 사람·회사 식별자 금지.
- 외부 서비스(GitHub·Bitbucket·LLM)는 호출하지 않는다 — 가짜 실행 파일 디렉토리를 `PATH` 앞에 두는 방식이 기존 관례다(예: 러너 테스트의 `PATH="$ROOT/tests/fixtures/driver:$PATH"`).
- macOS `/bin/bash` 3.2에서도 돌아야 한다(`tests/core.sh`가 fd 누수 패턴을 검사). 명령 인자인 `"$(... "{a, b}" ...)"`의 안쪽 큰따옴표 문자열에 든 쉼표 중괄호도 3.2가 펼치므로, 안쪽 문자열은 변수나 작은따옴표로 뺀다(`tests/bash32-check.py`가 `--lint`·core 영역에서 검사).

## 평가(evals)는 별개

`evals/<skill>/<case>/`는 Skill 평가 과제, `evals/ab/`는 `scripts/ab.sh` A/B 실험 과제다. 회귀 테스트가 아니므로 `tests/`를 대신하지 않는다. 과제를 추가하면 `evals/ab/README.md` 절차를 따른다.
