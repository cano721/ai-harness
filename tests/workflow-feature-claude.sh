#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — Claude 스트림 진행 줄·읽기 전용 위반·검사 실패 수리(feature)
# 실행: bash tests/run.sh workflow-feature-claude
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# Claude 세션은 stream-json으로 돌려 도구 호출을 실시간 진행 줄로 보인다. 원본 스트림(파일 내용·명령 인자·모델 문장)은 디스크에 남기지 않는다.
new_driver_repo claude_stream
driver start --runtime claude --request "add feature"
assert_eq "10" "$DRIVER_RC" "a claude run stops at approval like codex"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "claude results come from the stream's result event"
RUN_DIR="$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")"
assert_contains "$DRIVER_OUT" "deliver · Read src/app.ts" "tool calls show live on stderr with repo-relative paths"
assert_contains "$(<"$RUN_DIR/progress.log")" "review-0 · Bash: call the api" "progress.log keeps one line per tool call; Bash shows its description"
assert_contains "$(<"$RUN_DIR/progress.log")" "brief --next--> approval" "progress.log also keeps node transitions"
assert_contains "$(<"$RUN_DIR/progress.log")" "review-0 · Bash: curl" "Bash without a description shows the program name, skipping VAR= assignments"
assert_contains "$(<"$RUN_DIR/progress.log")" "review-0 · Grep useAuth in src" "Grep shows its pattern and repo-relative path"
assert_contains "$DRIVER_OUT" "progress: $RUN_DIR/progress.log" "resume also announces the progress file"
! grep -rq 'SECRET' "$RUN_DIR" || fail "tool inputs, tool results, and model text never reach the run directory: $(grep -rl 'SECRET' "$RUN_DIR")"
assert_eq "1" "$(find "$(dirname "$RUN_DIR")" -maxdepth 0 -perm 700 | wc -l | tr -d ' ')" "run directories are readable only by their owner"
HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER" watch --repo "$DRIVER_REPO" >"$DRIVER_TMP/watch.out" 2>&1 &
WATCH_PID=$!
for _ in $(seq 50); do grep -q 'Bash: call the api' "$DRIVER_TMP/watch.out" 2>/dev/null && break; sleep 0.2; done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
assert_contains "$(<"$DRIVER_TMP/watch.out")" "review-0 · Bash: call the api" "watch follows the latest run's progress"
new_driver_repo claude_fail
FAKE_CLAUDE_FAIL=1 driver start --runtime claude --request "add feature"
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a failed claude session is incomplete even though the progress filter succeeds"

if ! (exec 3<>/dev/tty) 2>/dev/null; then
  new_driver_repo no_tty
  driver start --runtime codex --request "add feature"
  driver approve
  assert_eq "10" "$DRIVER_RC" "terminal approval needs a real terminal"
fi

start_and_approve brief_writes
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "a write during a read-only node stops the run"
assert_eq "discover read-only schema=;" "$(tr '\n' ';' <"$FAKE_LOG")" "nothing runs after a violation"
start_and_approve nocheck
assert_eq "30:brief" "$DRIVER_RC:$(run_state .node)" "a brief without a verification command cannot be approved"
FAKE_CHECK="grep -q fixed feature.txt" start_and_approve fixcheck
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failing driver-run check goes to repair, then review"
assert_eq "deliver;repair;review" "$(tail -n 3 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "check failure skips the reviewer and repairs first"
pass "feature runner: claude stream, read-only violations, and check-failure repair"

finish_tests
