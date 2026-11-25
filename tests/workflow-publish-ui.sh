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

finish_tests
