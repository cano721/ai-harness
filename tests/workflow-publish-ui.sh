#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 화면 검증(ui_review): 통과·수리 재검증
# 실행: bash tests/run.sh workflow-publish-ui
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
pass "ui_review verifies screens and a blocking UI issue is repaired and re-verified"

# 캡처를 증거 폴더 하위 폴더에 저장해도(basename이 하나뿐이면) 증거로 인정하고, 브라우저로 못 보는 시나리오는 대체 검증을 따로 보여 준다. (#606)
start_and_approve ui_subdir
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a capture saved in a subdirectory of the evidence directory is found by its unique basename"
start_and_approve ui_nonbrowser
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a scenario that cannot be rendered in a browser passes with a reason and an alternative verification"
assert_contains "$DRIVER_OUT" "CLI 출력" "the outcome names the scenario that was not rendered in a browser"
assert_contains "$DRIVER_OUT" "CLI 실행 출력에서 반려됨 줄 확인" "the alternative verification is shown separately in the verified summary"
pass "ui_review accepts subdirectory captures and non-browser scenarios with an alternative verification"

# 증거에 렌더 엔진을 남긴다: 렌더링한 시나리오에 엔진이 없으면 근거 없는 통과이고, 쓴 엔진은 요약·상태에 남는다. (#678)
start_and_approve ui_no_engine
assert_eq "20:user_decision:unverified" "$DRIVER_RC:$(run_state .node):$(run_state .ui_review.status)" "a rendered scenario without its render engine is not verified"
assert_contains "$(run_state '.findings | join(";")')" "반려: no render engine recorded" "the finding names the scenario that did not record its engine"
start_and_approve ui_webkit
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a scenario rendered in webkit is verified"
assert_contains "$DRIVER_OUT" "rendered in: webkit" "the verified summary names the engine it rendered in"
assert_eq '["webkit"]' "$(run_state '.ui_review.engines | tojson')" "the run state keeps the engines used"
assert_contains "$(<"$FAKE_LOG.ui_review.prompt")" "render target" "ui_review is told to use the render target ui.md declares"
UE_STATE="$(find "$DRIVER_TMP/runs" -path "*repo-ui_ok-*" -name state.json | head -n 1)"
assert_contains "$(jq -r '.ui_review.summary' "$UE_STATE")" "rendered in: chromium" "a default run records chromium"
pass "ui_review records the render engine as evidence and refuses a rendered scenario without one"

finish_tests
