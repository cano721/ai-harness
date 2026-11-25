#!/usr/bin/env bash
# 회귀 테스트 — design-polish 러너 — 형제 화면 레이아웃 회귀·probe 결과 누락
# 실행: bash tests/run.sh workflow-polish-layout-sibling
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

new_driver_repo polish_layout_sibling
driver start --workflow polish --runtime codex --request "다듬어줘"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a sibling screen's layout issue that was already in the baseline is not a regression of this change"
new_driver_repo polish_layout_sibling_new
driver start --workflow polish --runtime codex --request "다듬어줘"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .node)" "a layout issue the fix brought to a sibling screen blocks the pass"
assert_contains "$(run_state '.findings | join(";")')" "layout (sibling settings · 1280 · light): clipped" "the sibling regression is named"
new_driver_repo polish_layout_missing
driver start --workflow polish --runtime codex --request "다듬어줘"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .node)" "a measure without the layout probe result is not a measurement"
assert_contains "$(run_state '.findings | join(";")')" "layout probe did not run on every screen" "the reason names the missing probe"
pass "design-polish blocks a pass on layout breakage the probe measured in the browser"

finish_tests
