#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 화면 검증(ui_review): 미확인·증거 없음·저장소 쓰기
# 실행: bash tests/run.sh workflow-publish-ui-unverified
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
run_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }

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
assert_contains "$DRIVER_OUT" "default.png" "the failure names the missing capture"
assert_contains "$DRIVER_OUT" "default.png: missing" "the failure says the capture is missing"
start_and_approve ui_writes
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "ui_review that writes into the repository stops the run"
assert_contains "$DRIVER_OUT" "capture.png" "the violation names the file the node left in the repository"
pass "a UI that cannot be verified or that writes into the repository is never done"

# 증거 실패는 어느 시나리오의 어느 경로가 왜 틀렸는지 알려 준다. (#606)
start_and_approve ui_ambiguous
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "a capture basename matching several files is not evidence"
assert_contains "$DRIVER_OUT" "default.png" "the failure names the capture path"
assert_contains "$DRIVER_OUT" "default.png: ambiguous (2 files named default.png)" "the failure says the capture is ambiguous and how many files match"
assert_contains "$(<"$(run_dir)/unresolved.json")" "ambiguous (2 files named default.png)" "the person sees the ambiguity in unresolved.json"
start_and_approve ui_outside
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "a capture outside the evidence directory is not evidence"
assert_contains "$DRIVER_OUT" "outside-606.png" "the failure names the outside path"
assert_contains "$DRIVER_OUT" "outside-606.png: outside the evidence directory" "the failure says the capture is outside the evidence directory"
start_and_approve ui_no_reason
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "a scenario without captures and without a reason is not evidence"
assert_contains "$DRIVER_OUT" "CLI 출력" "the failure names the scenario without evidence"
pass "ui_review evidence failures name the scenario, the path and the reason"

finish_tests
