#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 넓은 검사(final_checks)(feature)
# 실행: bash tests/run.sh workflow-feature-final-checks
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 넓은 검사(final_checks)는 라운드마다 돌지 않고 리뷰가 깨끗해진 뒤 한 번 돈다. 실패하면 blocking으로 수리한다. (#462)
FINAL_LOG="$DRIVER_TMP/final-checks.log"
: >"$FINAL_LOG"
FAKE_CHECK="printf 'fast\\n' >>'$FINAL_LOG'" FAKE_FINAL_CHECK="printf 'final\\n' >>'$FINAL_LOG'" start_and_approve final_once
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a run with final checks reaches done"
assert_eq "fast;final" "$(paste -sd ';' "$FINAL_LOG")" "fast checks run before the review and the broad check runs once after it"
assert_eq "1:1" "$(run_state '"\(.checks | length):\(.final_checks | length)"')" "the approved final checks are kept apart from the per-round checks"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "final_checks" "the brief node is asked to split per-round and final checks"
: >"$FINAL_LOG"
FAKE_CHECK="printf 'fast\\n' >>'$FINAL_LOG'" FAKE_FINAL_CHECK="printf 'final\\n' >>'$FINAL_LOG'; grep -q fixed feature.txt" start_and_approve final_fails_once
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failing final check goes to repair like a blocking finding"
assert_eq "fast;final;final;fast" "$(paste -sd ';' "$FINAL_LOG")" "after repair the failed final check runs first and passing it on that tree is not repeated after the re-review"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "required check failed" "repair receives the final check failure"
# 넓은 검사가 파일을 만들면 그 변경은 리뷰를 받지 않았으므로 통과가 아니다 — 수리·재리뷰를 거친다.
FAKE_FINAL_CHECK="echo generated >side.txt" start_and_approve final_side_effect
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a final check that changes files goes through repair and review again"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "changed files that were not reviewed: side.txt" "repair is told which files the final checks changed"
# 넓은 검사가 checks와 겹치면 한 번만 둔다.
FAKE_FINAL_CHECK="true" start_and_approve final_duplicate
assert_eq "0:0" "$DRIVER_RC:$(run_state '.final_checks | length')" "a final check already in checks is not repeated"
pass "feature runner: final checks run once after a clean review"

finish_tests
