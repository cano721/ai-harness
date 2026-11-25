#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 그래프 전이·git 정책·자동 승인 PR·옛 그래프(feature)
# 실행: bash tests/run.sh workflow-publish
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 전이는 저장소 그래프가 정한다: review -> done 엣지를 지우면 done에 갈 수 없다.
new_driver_repo graph_driven
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.from == "review" and .to == "publish"))' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "40" "$DRIVER_RC" "an edge missing from the project graph cannot be taken"
assert_contains "$DRIVER_OUT" "graph declares no transition from 'review'" "the runner names the undeclared edge"

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

new_driver_repo auto_questions
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "auto approval waits for a person when the brief comes back in the legacy open_questions format"
new_driver_repo auto_legacy
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "auto approval waits when the brief recorded no decisions, even without open questions"
# 사용자가 손대 갱신되지 않은 0.38 그래프(publish·auto 엣지 없음, 횟수가 박힌 엣지 이름)에서도 러너는 그 그래프대로 간다.
legacy_graph() {
  mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
  jq '.limits.max_repair_attempts = 2 | del(.nodes.publish)
      | .transitions |= (map(select(.from != "publish" and .when != "auto_approved_by_policy"))
        | map(if .to == "publish" then .to = "done" else . end
              | if .from == "repair" and .to == "user_decision" then .when = "same_root_cause_after_two_attempts_or_product_decision" else . end))' \
    "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
  git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m legacy-graph
}
new_driver_repo legacy_ok
with_policy pr-only auto
legacy_graph
driver start --runtime codex --request "add feature"
assert_eq "10" "$DRIVER_RC" "a legacy graph without the auto edge waits for a person"
say_in_claude "승인"
driver resume
assert_eq "0:done:null" "$DRIVER_RC:$(run_state .status):$(run_state .publish)" "a legacy graph reaches done without a publish node"
new_driver_repo review_blocks_legacy
FAKE_SCENARIO=review_blocks
legacy_graph
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "the escalation edge and repair limit come from the project graph"
pass "feature delivery graph runner enforces the graph outside the model"

finish_tests
