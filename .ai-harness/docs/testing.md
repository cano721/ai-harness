# Testing

테스트 정책: **TDD** — 실패하는 회귀 테스트(Red) → 최소 구현(Green) → 테스트를 바꾸지 않는 Refactor. 테스트는 기존 `tests/run.sh` 관례로 쓴다.

## 실행

```bash
bash tests/run.sh                                                        # 전체 회귀 (TAP 형식 `ok N - ...`, 끝에 `1..N`)
bash -n scripts/*.sh scripts/board/*.sh tests/*.sh                       # 문법
npx --yes shellcheck -S style -x scripts/*.sh scripts/board/*.sh tests/*.sh   # CI와 같은 수준
scripts/release-prep.sh --check                                          # 버전 네 곳 정합성 (develop에서도 통과)
```

- CI(`.github/workflows/test.yml`)는 apt의 `shellcheck -x`를 기본 심각도(style 포함)로 돌린다. CI 버전은 로컬 Homebrew 버전보다 엄격할 수 있다 — 예: `A && B || C` 패턴의 SC2015도 실패로 본다. 로컬에서는 `-S style`을 붙여 같은 수준으로 확인한다.
- 단건 실행은 없다. `tests/run.sh`는 위에서 아래로 도는 한 파일이고 첫 실패에서 멈춘다(`fail` → exit 1). 실패 메시지 `FAIL: <설명> (expected=... actual=...)`로 위치를 찾는다.
- 셸 스크립트가 아닌 파일만 바꿨어도 `tests/run.sh`는 돌린다 — 템플릿 바이트 일치·Skill 본문 문구·카탈로그를 검사하는 블록이 있다.

## 작성 규칙 (실측)

- 한 블록 = 한 동작. 블록 위에 왜 필요한지 한국어 주석, 본문은 `assert_eq <기대> <실제> <설명>`·`assert_contains`·`assert_file`·`assert_not_file`·`fail`, 끝에 `pass "<설명>"`.
- 임시 파일은 `$TEST_TMP`(스크립트가 만들고 종료 시 지움) 아래에만. 사용자 홈을 건드리지 않게 격리 환경변수를 쓴다: `HARNESS_METRICS_DIR`, `HM_AUTO_WORKTREE_DIR`, `HM_CLAUDE_SKILLS_DIR`·`HM_CODEX_SKILLS_DIR`, `HM_BACKFILL_INTERVAL_HOURS=0`, `HM_SETUP_HINT=0`, `HM_IMPACT_HINT=0`(파일 머리에서 기본값을 정한다).
- git이 필요한 테스트는 `$TEST_TMP` 아래에 `git init -q`로 저장소를 만들고 `user.email test@example.com`을 설정한다. 원격은 `git init --bare` 로컬 경로.
- fixture는 `tests/fixtures/<종류>/`(`claude/`·`codex/` 세션 기록, `driver/` 러너용 가짜 CLI, `ab/` A/B 정답 구현). 실제 사람·회사 식별자 금지.
- 외부 서비스(GitHub·Bitbucket·LLM)는 호출하지 않는다 — 가짜 실행 파일 디렉토리를 `PATH` 앞에 두는 방식이 기존 관례다(예: 러너 테스트의 `PATH="$ROOT/tests/fixtures/driver:$PATH"`).
- macOS `/bin/bash` 3.2에서도 돌아야 한다(`tests/run.sh`가 fd 누수 패턴을 검사).

## 평가(evals)는 별개

`evals/<skill>/<case>/`는 Skill 평가 과제, `evals/ab/`는 `scripts/ab.sh` A/B 실험 과제다. 회귀 테스트가 아니므로 `tests/run.sh`를 대신하지 않는다. 과제를 추가하면 `evals/ab/README.md` 절차를 따른다.
