#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 화면 검증 보강: Brief가 놓친 화면 변경·ui_review 없는 옛 그래프
# 실행: bash tests/run.sh workflow-publish-ui-backstop
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

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
pass "a missed screen change is backstopped and a graph without ui_review never reaches verified"

finish_tests
