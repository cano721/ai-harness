#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 원격 CI 상태: 다른 커밋·대기·없음
# 실행: bash tests/run.sh workflow-publish-ci-state
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

new_driver_repo ci_stale
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .remote_ci.status)" "a CI result for another commit does not count"
new_driver_repo ci_pending
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "30:incomplete:remote_ci" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "remote CI still running leaves the run resumable at remote_ci"
assert_contains "$DRIVER_OUT" "run resume to check again" "the runner says how to check again"
new_driver_repo ci_none
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:none" "$DRIVER_RC:$(run_state .status):$(run_state .remote_ci.status)" "a repository without remote CI is done after the PR"
pass "remote CI for another commit, pending, or absent is judged by the runner"

finish_tests
