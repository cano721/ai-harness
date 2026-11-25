#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 원격 CI 보호: 설정 있는데 없음 보고·원격 변경·옛 그래프
# 실행: bash tests/run.sh workflow-publish-ci-guard
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

new_driver_repo ci_none_but_configured
with_policy pr-only auto
mkdir -p "$DRIVER_REPO/.github/workflows" && echo "on: push" >"$DRIVER_REPO/.github/workflows/test.yml"
git -C "$DRIVER_REPO" add .github && git -C "$DRIVER_REPO" commit -q -m ci
driver start --runtime codex --request "add feature"
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .remote_ci.status)" "a 'no remote CI' report is not trusted when the repository has CI configuration"
new_driver_repo ci_rewrites_remote
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "remote_ci may only read CI: a moved remote branch stops the run"
# 갱신하지 않은 프로젝트 그래프(publish → done)는 그대로 따르되, 원격 CI를 보지 않았다고 밝힌다.
new_driver_repo legacy_publish_graph
with_policy pr-only auto
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.nodes.remote_ci) | .transitions |= (map(select(.from != "remote_ci")) | map(if .to == "remote_ci" then .to = "done" else . end))' \
  "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
assert_eq "0:done:null" "$DRIVER_RC:$(run_state .status):$(run_state .remote_ci)" "a project graph without remote_ci still ends at publish"
assert_contains "$DRIVER_OUT" "remote CI: unverified — the project graph has no remote_ci node" "that outcome says remote CI was not checked"
pass "a no-CI report is not trusted with CI configured, remote moves stop, and legacy graphs end at publish"

finish_tests
