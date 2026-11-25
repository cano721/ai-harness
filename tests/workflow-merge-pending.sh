#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 병합 뒤 claude 중복 result·충돌 계산 대기
# 실행: bash tests/run.sh workflow-merge-pending
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# claude 세션이 result 이벤트를 두 번 내도(#487) 노드 .out은 JSON 문서 하나여야 한다. 둘이면 post-merge target_ci status가 "passed\npassed"가 되어 사람에게 멈춘다.
export FAKE_PROTECTION=classic
FAKE_CLAUDE_RESULTS=2 MERGE_RUNTIME=claude merge_run pm_claude_dup_result "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a claude session that emits the result event twice still finishes the run"
assert_eq "passed" "$(run_state .post_merge.target_ci.status)" "post-merge target_ci status is one word, not one per result event"
PM_RUN_DIR="$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")"
assert_eq "1" "$(jq -n --slurpfile r "$PM_RUN_DIR/post-merge-ci.out" '$r | length')" "the post-merge CI node output is a single JSON document"
PM_REMOTE_OUTS="$(find "$PM_RUN_DIR" -maxdepth 1 -name 'remote-ci-[0-9]*.out')"
[[ -n "$PM_REMOTE_OUTS" ]] || fail "the remote CI node wrote no output"
while IFS= read -r f; do
  assert_eq "1" "$(jq -n --slurpfile r "$f" '$r | length')" "the remote CI node output is a single JSON document ($(basename "$f"))"
done <<<"$PM_REMOTE_OUTS"
assert_eq "remote_ci,merge,post_merge_verify" "$(run_state '[.history[] | select(.from | IN("remote_ci", "merge", "post_merge_verify")) | .from] | join(",")')" "the run goes through remote CI, merge and post-merge verification"
unset FAKE_PROTECTION
pass "claude result emitted twice: node outputs stay a single document and post-merge target_ci passes"

# 호스트가 충돌 여부를 아직 계산 중이면(mergeable UNKNOWN) 곧바로 incomplete로 끝내지 않고 몇 번 다시 물어본다(#542). resume 없이 병합돼야 한다.
export FAKE_PROTECTION=classic HM_MERGE_PENDING_POLL_SECONDS=0
rm -f "$DRIVER_TMP/merge_pending_ok.log.views"
FAKE_UNKNOWN_N=2 merge_run merge_pending_ok "$MP_BASIC"
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a conflict check the host finishes after two asks merges without resume"
[[ "$(<"$FAKE_LOG.views")" -ge 3 ]] || fail "the runner asked the host again (views=$(<"$FAKE_LOG.views"))"
assert_contains "$(wtc_progress)" "has not finished checking for conflicts" "the wait for the conflict check is logged"
# 재시도 한도(HM_MERGE_PENDING_RETRIES)까지 기다려도 UNKNOWN이면 기존처럼 incomplete 30이다: 처음 한 번 + 재시도 3번 = 4번만 묻는다.
rm -f "$DRIVER_TMP/merge_pending_limit.log.views"
FAKE_UNKNOWN_N=99 HM_MERGE_PENDING_RETRIES=3 merge_run merge_pending_limit "$MP_BASIC"
assert_eq "30:incomplete:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a conflict check that never finishes leaves the run resumable without merging"
assert_contains "$DRIVER_OUT" "the host has not finished checking for conflicts" "the incomplete message names the pending conflict check"
assert_eq "4" "$(<"$FAKE_LOG.views")" "the runner asks the host once plus the retry limit"
assert_contains "$(wtc_progress)" "has not finished checking for conflicts on" "each wait names the pull request"
unset FAKE_PROTECTION HM_MERGE_PENDING_POLL_SECONDS
pass "merge waits for the host's conflict check and gives up after the retry limit"

finish_tests
