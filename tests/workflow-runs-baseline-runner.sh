#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 재개 기준선(이전 버전·러너 커밋·불변식·remote_ci·예전 진입점)
# 실행: bash tests/run.sh workflow-runs-baseline-runner
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

run_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }

# 기준점이 없던 이전 버전의 실행도 HEAD는 대조한다.
new_driver_repo baseline_legacy
driver start --runtime codex --request "add feature"
jq 'del(.repo_baseline)' "$(run_dir)/state.json" >"$DRIVER_TMP/legacy.json" && mv "$DRIVER_TMP/legacy.json" "$(run_dir)/state.json"
git -C "$DRIVER_REPO" commit -q --allow-empty -m moved
say_in_claude "승인"
driver resume
assert_eq "20" "$DRIVER_RC" "a run from before baselines still stops when HEAD moved"

# 러너 자신의 체크포인트 커밋·publish가 HEAD를 옮겨도 기준점이 따라가 정상 재개는 막히지 않는다.
new_driver_repo baseline_checkpoint
with_policy pr-only human
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "checkpoint commits and publish keep the baseline with them"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(run_state .repo_baseline.head)" "the baseline follows the runner's own commits"
driver resume
assert_eq "0" "$DRIVER_RC" "a finished pr-only run resumed with nothing changed still reports done"

# 불변식 위반(40)은 러너가 허용하지 않은 변경이라 기준점이 되지 않는다. 다음 resume은 에이전트를 부르기 전에 멈춘다.
new_driver_repo baseline_violation
FAKE_SCENARIO=brief_writes
driver start --runtime codex --request "add feature"
assert_eq "40" "$DRIVER_RC" "a read-only node that writes stops the run"
BW_CALLS="$(wc -l <"$FAKE_LOG")"
driver resume
assert_eq "20:$BW_CALLS" "$DRIVER_RC:$(wc -l <"$FAKE_LOG")" "after an invariant violation, resume stops on the unaccepted change before any agent runs"
assert_contains "$DRIVER_OUT" "sneaky.txt" "the stop names the change the violation left"
new_driver_repo baseline_head_moved
FAKE_SCENARIO=commit
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "40" "$DRIVER_RC" "a write node that commits moves HEAD and stops the run"
driver resume
assert_eq "20:1" "$DRIVER_RC:$(grep -c '^deliver ' "$FAKE_LOG")" "resume after HEAD moved stops before the write node runs again"

# 리뷰를 지난 노드(remote_ci 등)에서는 받아들인 변경이 검증·리뷰를 건너뛰므로 --accept-changes도 거부한다.
new_driver_repo baseline_ci
with_policy pr-only auto
FAKE_SCENARIO=ci_pending
driver start --runtime codex --request "add feature"
assert_eq "30:remote_ci" "$DRIVER_RC:$(run_state .node)" "the run waits at remote_ci"
driver resume
assert_eq "30" "$DRIVER_RC" "resuming a pending remote CI with nothing changed checks again as before"
echo late >"$DRIVER_REPO/late.txt"
driver resume --accept-changes
assert_eq "20:remote_ci" "$DRIVER_RC:$(run_state .node)" "a change after review is not taken into the run"
assert_contains "$DRIVER_OUT" "start a new run" "the stop sends the change to a new run"

# 예전 진입점도 같은 대조를 거친다.
new_driver_repo baseline_shim
shim() { DRIVER_RC=0; DRIVER_OUT="$(HM_APPROVAL='' HM_APPROVAL_REPOS='' HM_RUNTIME='' HM_RUNTIME_REPOS='' HARNESS_METRICS_DIR="$DRIVER_TMP/data" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" CLAUDE_CONFIG_DIR="$DRIVER_TMP/claude" CODEX_HOME="$DRIVER_TMP/codex" \
  FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO="$FAKE_SCENARIO" FAKE_CHECK=true PATH="$ROOT/tests/fixtures/driver:$PATH" \
  bash "$DRIVER_SHIM" "$@" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?; }
shim start --runtime codex --request "add feature"
echo hand >"$DRIVER_REPO/hand.txt"
say_in_claude "승인"
shim resume
assert_eq "20" "$DRIVER_RC" "the old entry point stops on a changed baseline too"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "the old entry point does not write when the baseline moved"
pass "resume compares the saved baseline before any agent runs"

finish_tests
