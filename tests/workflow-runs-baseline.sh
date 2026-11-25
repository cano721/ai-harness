#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 재개 기준선(같은 기준선·미커밋·다른 커밋)
# 실행: bash tests/run.sh workflow-runs-baseline
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

new_driver_repo baseline_same
driver start --runtime codex --request "add feature"
assert_eq "10:$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$DRIVER_RC:$(run_state .repo_baseline.head)" "the runner keeps the baseline where it stopped"
[[ -n "$(run_state '.repo_baseline.fingerprint // ""')" ]] || fail "the baseline keeps the working tree fingerprint"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a resume from the same baseline continues as before"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a finished run resumed with nothing changed still reports done"
echo later >"$DRIVER_REPO/later.txt"
driver resume
assert_eq "20" "$DRIVER_RC" "a finished run whose working tree changed does not report success"
[[ "$(run_state .status)" != "done" ]] || fail "a changed finished run is not left as done"
assert_contains "$DRIVER_OUT" "later.txt" "the stop names the changed file"
driver resume --accept-changes
assert_eq "20" "$DRIVER_RC" "a finished run does not take changes in; they need a new run"
assert_contains "$DRIVER_OUT" "start a new run" "the finished run says how to check the change"
rm "$DRIVER_REPO/later.txt"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "back at the baseline, the finished run reports done again"
git -C "$DRIVER_REPO" add -A && git -C "$DRIVER_REPO" commit -q --allow-empty -m "after done"
driver resume
assert_eq "20" "$DRIVER_RC" "a commit after a finished run also stops it"

new_driver_repo baseline_dirty
driver start --runtime codex --request "add feature"
echo hand >"$DRIVER_REPO/hand.txt"
say_in_claude "승인"
driver resume
assert_eq "20:approval" "$DRIVER_RC:$(run_state .node)" "an uncommitted change after the stop halts resume"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "no agent writes when the baseline moved"
assert_contains "$DRIVER_OUT" "hand.txt" "the stop names the uncommitted file"
assert_contains "$DRIVER_OUT" "node approval" "the stop names where the run would continue"
assert_contains "$DRIVER_OUT" "checks: true" "the stop names the remaining required checks"
assert_contains "$DRIVER_OUT" "resume --accept-changes" "the stop says how to take the change in on purpose"
driver resume
assert_eq "20" "$DRIVER_RC" "a plain resume keeps stopping until the change is accepted or undone"
driver resume --accept-changes
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an explicit --accept-changes moves the baseline and continues"
assert_eq "1" "$(run_state '.baseline_accepted | length')" "the accepted change is recorded"
driver status --accept-changes
assert_eq "2" "$DRIVER_RC" "--accept-changes belongs to resume and approve only"

new_driver_repo baseline_commit
driver start --runtime codex --request "add feature"
echo other >"$DRIVER_REPO/other.txt"
git -C "$DRIVER_REPO" add -A && git -C "$DRIVER_REPO" commit -q -m "someone else's commit"
say_in_claude "승인"
driver resume
assert_eq "20:approval" "$DRIVER_RC:$(run_state .node)" "a different commit after the stop halts resume"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "no agent writes when HEAD moved"
assert_contains "$DRIVER_OUT" "someone else's commit" "the stop lists the new commits"
driver resume --accept-changes
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an accepted commit becomes the run's head, so the write nodes do not see HEAD as moved"
pass "resume compares the saved baseline before any agent runs (same, uncommitted, and other-commit baselines)"

finish_tests
