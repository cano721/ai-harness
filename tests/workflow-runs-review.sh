#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — review 러너(수리 승인·반복)
# 실행: bash tests/run.sh workflow-runs-review
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# review: 승인 노드가 없는 그래프다. 수리는 사람이 동의한 뒤에만 하고, 커밋하지 않는다.
review_run() { # scenario → 커밋 안 된 변경을 검토하기 시작한다
  new_driver_repo "$1"
  echo change >"$DRIVER_REPO/feature.txt"
  driver start --workflow review --runtime codex --request "review my uncommitted change"
}
review_run rv_clean
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a review without blocking findings is done"
assert_eq "scope read-only schema=yes;inspect read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "the initial review is read-only"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(run_state .diff_base)" "the review measures the change from the base the scope node named"
new_driver_repo rv_empty
driver start --workflow review --runtime codex --request "review my uncommitted change"
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a review with nothing to review stops instead of passing"
assert_contains "$DRIVER_OUT" "nothing to review" "the person is told the review target is empty"
review_run rv_blocks
assert_eq "10:waiting_approval:classify" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "blocking findings wait for the person before any repair"
assert_contains "$DRIVER_OUT" "feature.txt: missing case" "the person sees the findings to repair"
assert_contains "$DRIVER_OUT" "수리하지 않으면 여기서 끝난다" "the person can keep the review without a repair"
driver resume
assert_eq "10:1" "$DRIVER_RC:$(grep -c '^inspect ' "$FAKE_LOG")" "resume without approval keeps waiting and does not review again"
say_in_claude "승인"
driver resume
assert_eq "0:done:1:claude-transcript" "$DRIVER_RC:$(run_state .status):$(run_state .attempts):$(run_state .approval.source)" "an approved repair goes through verify and re-review to done"
# 리뷰 노드는 데이터 조회가 있는 변경에서 대량 조회의 "건수 상한 × 행 크기"를 근거로 적는다. 조회가 없는 변경(프론트 등)에는 적용하지 않는다. (#499)
for node in inspect re_review; do
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "row-count bound × row size" "$node checks bulk reads by row-count bound × row size"
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "skip it for changes without such data access" "$node skips the bulk read check without data access"
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "neither is a caller/receiver count mismatch on a write path or when the receiving query reads only the small columns it needs" "$node does not flag the bound of a write path or a small projection"
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "do not leave it out because its definition is outside the diff when its caller is inside it" "$node keeps an existing query whose caller changed"
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "pulled in by fetch joins or association loading and those in other modules" "$node sizes rows from the entities a query pulls in"
done
assert_eq "repair;re_review" "$(tail -n 2 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "every repair is followed by checks and re-review"
assert_eq "fixed:1" "$(<"$DRIVER_REPO/feature.txt"):$(git -C "$DRIVER_REPO" rev-list --count HEAD)" "the repair stays uncommitted in the working tree"
assert_contains "$DRIVER_OUT" "left uncommitted" "the outcome says the repair is not committed"
review_run rv_decision
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a finding that needs a product decision goes to a person"
review_run scope_bad_base
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a review base that is not a commit stops the run"
review_run scope_nocheck
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a repair needs a verification command"
new_driver_repo rv_auto
with_policy pr-only auto
echo change >"$DRIVER_REPO/feature.txt"
driver start --workflow review --runtime codex --request "review my uncommitted change"
assert_eq "0:done:auto-policy:0" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source):$(run_state '.checkpoints | length')" "approval auto authorizes the repair, and review never commits"
pass "bug-fix and review graphs run through the same runner (review approval and repair)"

finish_tests
