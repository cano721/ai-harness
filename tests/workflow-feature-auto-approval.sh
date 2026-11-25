#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 자동 승인 완료 조건 대응·리뷰 완료 조건 대조(feature)
# 실행: bash tests/run.sh workflow-feature-auto-approval
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-workflow-feature.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-workflow-feature.sh"

# 자동 승인 Brief는 요청·이슈의 완료 조건을 항목마다 대응시켜야 한다(#501). 대응도 사유도 없는 조건이 있으면 러너가 다시 쓰게 하고,
# 한도(limits.max_brief_rewrites)를 넘으면 사람에게 넘긴다. 쓰기 노드는 그동안 돌지 않는다.
new_driver_repo auto_uncovered
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision:user_decision" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "an uncovered completion condition is never approved by policy"
assert_contains "$(brief_history)" "approval --brief_changed_or_not_approved--> brief" "the runner sends an uncovered brief back to the brief node"
assert_contains "$(brief_history)" "approval --brief_coverage_incomplete--> user_decision" "past the rewrite limit the run goes to a person"
[[ "$(brief_history)" != *auto_approved_by_policy* ]] || fail "an uncovered brief is not auto-approved"
assert_eq "$(($(jq -r '.limits.max_brief_rewrites' "$FEATURE_GRAPH") + 1))" "$(grep -c '^brief ' "$FAKE_LOG")" "the brief is rewritten up to the graph's limit"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "nothing writes while a completion condition is uncovered"
assert_contains "$(<"$FAKE_LOG.revise")" "Revise it with this feedback" "the rewrite reuses the revise path"
assert_contains "$(<"$FAKE_LOG.revise")" "CSV export" "the rewrite names the uncovered condition"
assert_contains "$DRIVER_OUT" "CSV export" "the person sees the uncovered condition"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "acceptance_map" "the brief node is asked for the completion-condition map"

new_driver_repo auto_empty_map
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "an empty completion-condition map is not approved by policy"
[[ "$(brief_history)" != *auto_approved_by_policy* ]] || fail "an empty map is not auto-approved"

new_driver_repo auto_uncovered_once
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(grep -c '^brief ' "$FAKE_LOG")" "a brief fixed on rewrite passes after two brief runs"
assert_contains "$(brief_history)" "approval --brief_changed_or_not_approved--> brief;brief --next--> approval;approval --auto_approved_by_policy--> deliver" "the rewritten brief is approved by policy"

new_driver_repo auto_out_of_scope
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^brief ' "$FAKE_LOG")" "a condition out of scope with a reason passes on the first brief"
OOS_BRIEF="$(<"$(dirname "$(run_state .approval.brief)")/brief.md")"
assert_contains "$OOS_BRIEF" "## 완료 조건 대응" "brief.md renders the completion-condition map"
assert_contains "$OOS_BRIEF" "- CSV export → 범위 밖: tracked in a follow-up issue" "brief.md shows the out-of-scope reason"
assert_contains "$OOS_BRIEF" "- add feature → feature.txt exists (checks)" "brief.md shows what covers each condition"

# sync 전 그래프(brief_coverage_incomplete 엣지 없음)는 한도에서 사람 승인을 기다린다.
new_driver_repo auto_uncovered_noedge
with_policy pr-only auto
FAKE_SCENARIO=auto_uncovered
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.when == "brief_coverage_incomplete"))' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
assert_eq "10:waiting_approval:approval" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "without the coverage edge the run waits for a person at the limit"
assert_contains "$DRIVER_OUT" "brief_coverage_incomplete" "the log says why a person must decide"
pass "auto approval requires every completion condition covered or out of scope"

# 리뷰는 승인된 Brief와 원 요청의 완료 조건을 함께 대조하고, 빠진 조건을 blocking으로 낸다.
new_driver_repo missing_criterion
driver start --runtime codex --request "add feature with CSV export"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a missing completion condition is repaired and re-reviewed"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "Original request:" "review sees the original request"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "add feature with CSV export" "review sees the request text"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "completion condition" "review is told to check every completion condition"
assert_contains "$(brief_history)" "review --blocking_findings--> repair" "a missing completion condition goes to repair"
assert_contains "$(<"$(run_dir)/review-0.out")" "completion condition CSV export not met" "the finding names the missing condition"
pass "review blocks on a completion condition the change does not meet"

finish_tests
