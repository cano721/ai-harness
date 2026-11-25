#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — git 정책·원격 CI·dirty 시작(feature)
# 실행: bash tests/run.sh workflow-publish-ci
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# harness.json의 approval·git_policy가 사람 대기와 git 단계를 정한다.
new_driver_repo auto_pr
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:auto-policy" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source)" "approval auto passes the gate without a person and reaches done"
assert_contains "$(run_state '[.history[].outcome] | join(",")')" "auto_approved_by_policy" "auto approval follows the declared graph edge"
assert_file "$(run_state .approval.brief)"
assert_eq "HM_APPROVAL" "$(run_state .policy.approval_source)" "the selected approval source stays in run state"
APPROVAL_BRIEF="$(run_state .approval.brief)"
assert_contains "$(<"$APPROVAL_BRIEF")" "승인 모드: auto (출처: HM_APPROVAL)" "brief.md records the approval mode and source for the PR body"
assert_eq "https://example.test/pr/7" "$(run_state .publish.pr_url)" "pr-only opens a PR in the publish node"
assert_contains "$DRIVER_OUT" "PR: https://example.test/pr/7" "done reports the PR"
assert_eq "publish workspace-write schema=yes net=yes;remote_ci workspace-write schema=yes net=yes" "$(tail -n 2 "$FAKE_LOG" | paste -sd ';' -)" "publish writes with network access, then remote_ci reads CI with network access and a schema"
assert_eq "passed:$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(run_state '"\(.remote_ci.status):\(.remote_ci.head)"')" "done waits for remote CI of the pushed commit"
assert_contains "$DRIVER_OUT" "remote CI: passed" "done reports the remote CI result"
assert_contains "$(<"$FAKE_LOG.remote_ci.prompt")" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "remote_ci is told the exact pushed commit"
assert_contains "$(<"$FAKE_LOG.remote_ci.prompt")" "A local run of the CI commands is not a remote result" "a local CI-equivalent run does not stand in for remote CI"
assert_eq "1" "$(run_state '.checkpoints | length')" "the runner commits a local checkpoint after deliver"
assert_contains "$(git -C "$DRIVER_REPO" log --format=%s)" "wip(implement-feature): deliver" "checkpoint commit is on the branch"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(git -C "$DRIVER_TMP/remote-auto_pr.git" rev-parse feat/add-feature)" "the work branch is pushed"

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

new_driver_repo dirty_start
with_policy pr-only auto
echo wip >"$DRIVER_REPO/notes.txt"
driver start --runtime codex --request "add feature"
assert_eq "2" "$DRIVER_RC" "a runner that may commit refuses to start on a dirty tree"
rm "$DRIVER_REPO/notes.txt"
git -C "$DRIVER_REPO" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$(git -C "$DRIVER_REPO" rev-parse --abbrev-ref HEAD)"
driver start --runtime codex --request "add feature"
assert_eq "2" "$DRIVER_RC" "pr-only refuses to start on the base branch"
assert_contains "$DRIVER_OUT" "not the base branch" "the runner says why"
pass "git policy and remote CI keep the runner outside the model"

finish_tests
