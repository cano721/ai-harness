#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 화면 검증·그래프 전이(feature)
# 실행: bash tests/run.sh workflow-publish
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 화면이 바뀌는 기능은 Brief가 ui_scenarios를 내고, review 뒤 ui_review가 실제 화면을 검증한다. (#150)
start_and_approve ui_ok
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a UI change reaches done only through a verified ui_review"
assert_eq "review;ui_review" "$(tail -n 2 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "ui_review runs after a review with no blocking findings"
assert_contains "$(<"$FAKE_LOG")" "ui_review workspace-write schema=yes net=yes add-dir=yes" "ui_review may run the app and a browser and save captures in the run directory; the fingerprint keeps the repository unchanged"
assert_file "$(run_state .ui_review.evidence_dir)/default.png"
assert_contains "$(<"$(dirname "$(run_state .ui_review.evidence_dir)")/brief.md")" "## 화면 검증 시나리오" "the approved brief carries the UI scenarios"
assert_contains "$(<"$FAKE_LOG.ui_review.prompt")" "default and collapsed states" "ui_review looks at the default state before hovering"
assert_contains "$(<"$FAKE_LOG.ui_review.prompt")" "a screenshot file existing" "ui_review is told what is not evidence"
assert_contains "$DRIVER_OUT" "UI: verified" "the outcome reports the UI verification"
[[ "$(<"$FAKE_LOG.brief.prompt")" == *"ui_scenarios"* ]] || fail "the brief node is asked for UI scenarios"
start_and_approve ui_issues_once
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a blocking UI issue goes through repair and re-verification"
assert_eq "ui_review;repair;review;ui_review" "$(grep -E '^(ui_review|repair|review) ' "$FAKE_LOG" | tail -n 4 | cut -d' ' -f1 | paste -sd ';' -)" "after repair the change is reviewed and its screens verified again"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "펼침 표시가 없어" "repair receives the UI finding"
start_and_approve ui_unverified
assert_eq "20:user_decision:unverified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a UI that could not be verified is never done"
assert_contains "$DRIVER_OUT" "implementation done, UI unverified" "the outcome separates implementation from verification"
assert_eq "0" "$(run_state .attempts)" "an unverified UI goes to a person without repair attempts"
start_and_approve ui_empty_issues
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "issues without findings count as unverified, not as done"
start_and_approve ui_hollow
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "verified without a record of operating each scenario is not evidence"
start_and_approve ui_partial
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "verified with unverified items left is not done"
start_and_approve ui_fake_capture
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "a capture named in the output but missing from the evidence directory is not evidence"
start_and_approve ui_writes
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "ui_review that writes into the repository stops the run"
assert_contains "$DRIVER_OUT" "capture.png" "the violation names the file the node left in the repository"
# Brief가 화면 변경을 놓쳐도 화면 파일이 바뀌면 검증한다.
start_and_approve screen_backstop
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a run whose brief missed the screen change still ends verified"
assert_contains "$(run_state '.ui_scenarios[0]')" "templates/approve.html" "changed screen files become a UI scenario"
assert_eq "review;ui_review" "$(tail -n 2 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "the backstop routes through ui_review"
# 갱신하지 않은 그래프(ui_review 없음)는 그대로 따르되 화면을 검증하지 않았다고 밝힌다.
new_driver_repo ui_legacy_graph
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.nodes.ui_review) | .transitions |= map(select(.from != "ui_review" and .to != "ui_review"))' \
  "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a UI change on a graph without ui_review is never done"
assert_contains "$DRIVER_OUT" "implementation done, UI unverified: the project graph has no ui_review node" "that outcome says the screens were not verified and how to fix it"
assert_eq "null" "$(run_state .publish)" "nothing is published without UI verification"

# 전이는 저장소 그래프가 정한다: review -> done 엣지를 지우면 done에 갈 수 없다.
new_driver_repo graph_driven
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.from == "review" and .to == "publish"))' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "40" "$DRIVER_RC" "an edge missing from the project graph cannot be taken"
assert_contains "$DRIVER_OUT" "graph declares no transition from 'review'" "the runner names the undeclared edge"
pass "UI verification and graph-driven transitions"

finish_tests
