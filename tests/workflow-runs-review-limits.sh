#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — review 러너(수리 한도·재검증·화면)
# 실행: bash tests/run.sh workflow-runs-review-limits
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

REVIEW_GRAPH_TEMPLATE="$ROOT/templates/review/references/review-graph.json"
# review: 승인 노드가 없는 그래프다. 수리는 사람이 동의한 뒤에만 하고, 커밋하지 않는다.
review_run() { # scenario → 커밋 안 된 변경을 검토하기 시작한다
  new_driver_repo "$1"
  echo change >"$DRIVER_REPO/feature.txt"
  driver start --workflow review --runtime codex --request "review my uncommitted change"
}
new_driver_repo rv_always_blocks
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_repair_attempts = 2' "$REVIEW_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/review-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
echo change >"$DRIVER_REPO/feature.txt"
driver start --workflow review --runtime codex --request "review my uncommitted change"
say_in_claude "승인"
driver resume
assert_eq "10" "$DRIVER_RC" "a finding the person has not seen asks again before it is repaired"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "re-review stops at the graph's repair limit"
FAKE_CHECK="test -f $DRIVER_TMP/rv_verify_fail.seen || { touch $DRIVER_TMP/rv_verify_fail.seen; false; }"
review_run rv_verify_fail
say_in_claude "승인"
driver resume
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failed check after repair goes back to repair"
FAKE_CHECK=false
new_driver_repo rv_verify_limit
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_repair_attempts = 1' "$REVIEW_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/review-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
echo change >"$DRIVER_REPO/feature.txt"
driver start --workflow review --runtime codex --request "review my uncommitted change"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "checks that keep failing reach the repair limit and go to a person"
unset FAKE_CHECK
review_run rv_new_finding
say_in_claude "승인"
driver resume
assert_eq "10:re_review" "$DRIVER_RC:$(run_state .node)" "a new finding outside the approved repair scope asks again"
assert_contains "$DRIVER_OUT" "auth flow must be redesigned" "the person sees the new finding before it is repaired"
assert_eq "1" "$(grep -c '^repair ' "$FAKE_LOG")" "nothing repairs the new finding before the person agrees"
say_in_claude "승인"
driver resume
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "after the second agreement the new finding is repaired and re-reviewed"
review_run rv_ui
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a review of a screen change verifies the rendered screen"
assert_contains "$(<"$FAKE_LOG")" "ui_review workspace-write schema=yes net=yes add-dir=yes" "review keeps captures in the run directory too"
assert_file "$(run_state .ui_review.evidence_dir)/default.png"
new_driver_repo rv_clean_screen
mkdir -p "$DRIVER_REPO/templates"
echo '<summary>반려하기</summary>' >"$DRIVER_REPO/templates/approve.html"
driver start --workflow review --runtime codex --request "review my uncommitted change"
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a changed screen file is verified even when the reviewer listed no scenario"
pass "bug-fix and review graphs run through the same runner"

finish_tests
