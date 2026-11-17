#!/usr/bin/env bash
# 영역 테스트 파일(tests/<영역>.sh)이 source하는 공용 준비·단언 함수. 단독 실행하지 않는다.
# 영역 파일 하나가 독립 프로세스로 돌고, 파일마다 자기 $TEST_TMP를 만들고 지운다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-harness-tests.XXXXXX")"
TESTS=0
# bash 3.2 can leave $? at 0 inside the EXIT trap after a `set -u` abort, so the run
# only counts as passed when it reached the final line.
TESTS_FINISHED=0

cleanup() {
  # 보드 테스트가 중간에 실패해도 띄운 서버를 남기지 않는다.
  local board_pid conf
  for conf in "$TEST_TMP/board/data/board/server.json" "$TEST_TMP/board/impact/data/board/server.json" "$TEST_TMP/board/autofix/data/board/server.json" "$TEST_TMP/board-resident/data/board/server.json" "$TEST_TMP/board-resident/data/board/host/host.json"; do
    board_pid="$(jq -r '.pid // empty' "$conf" 2>/dev/null || true)"
    [[ "$board_pid" =~ ^[0-9]+$ ]] && kill "$board_pid" 2>/dev/null
    if [[ "$conf" == */host/host.json && "$board_pid" =~ ^[0-9]+$ ]]; then
      # 상주 세션 호스트는 SIGTERM 뒤 세션을 닫으며 기록을 쓴다 — 끝난 뒤 지워야 폴더가 다시 생기지 않는다
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
        kill -0 "$board_pid" 2>/dev/null || break
        sleep 0.1
      done
    fi
  done
  # 테스트가 띄우고 놓친 서버(landing-board-server 등)는 인자에 $TEST_TMP가 들어 있다 — 폴더를 지우기 전에 모두 끈다.
  case "$TEST_TMP" in */ai-harness-tests.*) pkill -f "$TEST_TMP" 2>/dev/null || true ;; esac
  case "$TEST_TMP" in
    */ai-harness-tests.*) find "$TEST_TMP" -depth -delete 2>/dev/null || true ;;
    *) printf 'unexpected test temp path, preserving: %s\n' "$TEST_TMP" >&2 ;;
  esac
  if [ "$TESTS_FINISHED" != 1 ]; then
    printf 'tests aborted before the end (after %d passing groups)\n' "$TESTS" >&2
    exit 1
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

finish_tests() {
  printf '1..%d\n' "$TESTS"
  TESTS_FINISHED=1
}

pass() {
  TESTS=$((TESTS + 1))
  printf 'ok %d - %s\n' "$TESTS" "$1"
}

# 교정은 LLM 정리(digest)의 correction finding으로만 센다. 이벤트 파일 옆 digests/에 n건을 둔다.
seed_correction_digest() { # data_dir event_file n
  mkdir -p "$1/digests"
  local base="${2##*/}"
  jq -cn --argjson n "$3" '{v:2, findings:[range($n) | {category:"correction", summary:"교정", evidence:"아니 그거 말고", harness_fix:"규칙", confidence:"high"}]}' \
    >"$1/digests/${base%.jsonl}.json"
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing: $needle)"
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_not_file() {
  [[ ! -f "$1" ]] || fail "unexpected file: $1"
}

CLAUDE_FIXTURE="$ROOT/tests/fixtures/claude/aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
CODEX_FIXTURE="$ROOT/tests/fixtures/codex/rollout-2026-07-29T12-00-00-bbbbbbbb-1111-2222-3333-cccccccccccc.jsonl"
CODEX_FILE_SID="2026-07-29T12-00-00-bbbbbbbb-1111-2222-3333-cccccccccccc"
CODEX_SESSION_ID="bbbbbbbb-1111-2222-3333-cccccccccccc"

# stable project ID: origin과 삭제된 worktree 경로 fallback
PROJECT_REPO="$TEST_TMP/repos/service"
PROJECT_WORKTREE="$TEST_TMP/worktrees/service-NMRS-999"
mkdir -p "$PROJECT_REPO" "$TEST_TMP/worktrees"
git -C "$PROJECT_REPO" init -q
git -C "$PROJECT_REPO" config user.email test@example.com
git -C "$PROJECT_REPO" config user.name test
git -C "$PROJECT_REPO" commit -q --allow-empty -m init
git -C "$PROJECT_REPO" remote add origin git@github.com:acme/service.git
git -C "$PROJECT_REPO" worktree add -q -b test-worktree "$PROJECT_WORKTREE"
HARNESS_METRICS_DIR="$TEST_TMP/lib-data"
export HARNESS_METRICS_DIR
# SessionStart가 실제 ~/.claude 전체를 백그라운드 backfill하지 않게 기본 비활성화. 전용 테스트만 켠다.
export HM_BACKFILL_INTERVAL_HOURS=0
export HM_AUTO_WORKTREE_DIR="$TEST_TMP/auto-worktrees"
# 셋업 안내는 전용 테스트만 켠다. 전역 스킬 폴더는 실제 홈을 건드리지 않게 격리한다.
export HM_SETUP_HINT=0
# 도입 효과 안내도 전용 테스트만 켠다.
export HM_IMPACT_HINT=0
export HM_CLAUDE_SKILLS_DIR="$TEST_TMP/global-skills/claude" HM_CODEX_SKILLS_DIR="$TEST_TMP/global-skills/codex"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

make_repo() {
  local dir="$1" origin="${2:-}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  git -C "$dir" commit -q --allow-empty -m init
  [[ -z "$origin" ]] || git -C "$dir" remote add origin "$origin"
}

# 여러 영역이 같이 읽는 고정 값
HARNESS_INIT_CONTENT="$(<"$ROOT/skills/harness-init/SKILL.md")"
# shellcheck disable=SC2016  # hook JSON의 literal 변수 참조를 검사
LITERAL_PLUGIN_ROOT='"${CLAUDE_PLUGIN_ROOT}'
START_COMMAND="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/hooks.json")"
START_INPUT="$(jq -cn --arg cwd "$PROJECT_REPO" '{cwd:$cwd}')"
DS_FONT_URL='https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/packages/pretendard/dist/web/variable/woff2/PretendardVariable.woff2'
