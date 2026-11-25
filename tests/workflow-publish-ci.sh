#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 원격 CI 실패 수리·반복 실패·미확인
# 실행: bash tests/run.sh workflow-publish-ci
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 원격 CI 실패는 같은 수리 루프로 고쳐 일반 push 후 다시 본다. 볼 수 없으면 done이 아니라 미확인으로 사람에게 간다.
new_driver_repo ci_fail_once
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:passed:1" "$DRIVER_RC:$(run_state .status):$(run_state .remote_ci.status):$(run_state .attempts)" "a remote CI failure goes back through repair and is checked again"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "remote CI failed: test (ubuntu): expected 12:00:00.123456" "repair receives the failing remote check and its log lines"
assert_contains "$(run_state '[.history[].outcome] | join(",")')" "remote_ci_failed" "the failure follows the declared remote_ci -> repair edge"
assert_eq "2" "$(grep -c '^publish ' "$FAKE_LOG")" "the repaired commit is published again"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "push to it and return its URL instead of opening another" "a repeated publish reuses the open PR"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(git -C "$DRIVER_TMP/remote-ci_fail_once.git" rev-parse feat/add-feature)" "the repair is pushed with a normal push"
new_driver_repo ci_always_fail
with_policy pr-only auto
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_repair_attempts = 2' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "remote CI that stays red stops at the graph repair limit"
new_driver_repo ci_unverified
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "remote CI that cannot be observed is never done"
assert_contains "$DRIVER_OUT" "remote CI unverified: no CI tool or token for this host; PR: https://example.test/pr/7" "the outcome says remote CI is unverified and names the PR"
pass "remote CI failures are repaired and unobservable CI is never done"

finish_tests
