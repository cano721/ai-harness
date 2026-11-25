#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 화면 검증(ui_review): 미확인·증거 없음·저장소 쓰기
# 실행: bash tests/run.sh workflow-publish-ui-unverified
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

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
pass "a UI that cannot be verified or that writes into the repository is never done"

finish_tests
