#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 수리 한도 도달 시 사람에게 넘김(feature)
# 실행: bash tests/run.sh workflow-feature-review-loop
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

start_and_approve review_blocks
assert_eq "20:user_decision:$(jq -r '.limits.max_repair_attempts' "$FEATURE_GRAPH")" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "blocking findings stop at user_decision after the graph's repair limit"
assert_eq "$(($(jq -r '.limits.max_repair_attempts' "$FEATURE_GRAPH") + 1))" "$(grep -c '^review read-only' "$FAKE_LOG")" "every repair is followed by a re-review"
pass "feature runner: blocking findings stop at the repair limit"

finish_tests
