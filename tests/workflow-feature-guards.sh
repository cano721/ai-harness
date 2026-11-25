#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 제품 결정·잘못된 리뷰·무단 커밋·무변경·--check(feature)
# 실행: bash tests/run.sh workflow-feature-guards
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

start_and_approve decision
assert_eq "20:0" "$DRIVER_RC:$(run_state .attempts)" "a product decision goes to a person without repair attempts"
start_and_approve bad_review
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a review that breaks the schema is never done"
start_and_approve commit
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "an unauthorized commit stops the run"
start_and_approve noop
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "delivery without a change is not done"
start_and_approve extra_check --check "test -f feature.txt"
assert_eq "0:true" "$DRIVER_RC:$(run_state '.checks | index("test -f feature.txt") != null')" "--check joins the approved verification"
# feature·bug-fix의 review 노드도 같은 대량 조회 점검을 받는다. (#499)
assert_contains "$(<"$FAKE_LOG.review.prompt")" "row-count bound × row size" "the review node checks bulk reads by row-count bound × row size"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "LONGTEXT, MEDIUMTEXT, TEXT" "the review node names large columns"

pass "feature runner: approval, required checks, and the repair loop"

finish_tests
