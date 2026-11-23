#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 화면 검증·그래프 전이·git 정책·원격 CI·자동 승인(feature)
# 실행: bash tests/run.sh workflow-publish
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
start_and_approve ui_unverified
assert_eq "20:user_decision:unverified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a UI that could not be verified is never done"
assert_contains "$DRIVER_OUT" "implementation done, UI unverified" "the outcome separates implementation from verification"
assert_eq "0" "$(run_state .attempts)" "an unverified UI goes to a person without repair attempts"
start_and_approve ui_empty_issues
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "issues without findings count as unverified, not as done"
start_and_approve ui_hollow
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "verified without a record of operating each scenario is not evidence"
start_and_approve ui_partial
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "verified with unverified items left is not done"
start_and_approve ui_fake_capture
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "a capture named in the output but missing from the evidence directory is not evidence"
start_and_approve ui_writes
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "ui_review that writes into the repository stops the run"
assert_contains "$DRIVER_OUT" "capture.png" "the violation names the file the node left in the repository"
# Brief가 화면 변경을 놓쳐도 화면 파일이 바뀌면 검증한다.
start_and_approve screen_backstop
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a run whose brief missed the screen change still ends verified"
assert_contains "$(run_state '.ui_scenarios[0]')" "templates/approve.html" "changed screen files become a UI scenario"
assert_eq "review;ui_review" "$(tail -n 2 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "the backstop routes through ui_review"
# 갱신하지 않은 그래프(ui_review 없음)는 그대로 따르되 화면을 검증하지 않았다고 밝힌다.
new_driver_repo ui_legacy_graph
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.nodes.ui_review) | .transitions |= map(select(.from != "ui_review" and .to != "ui_review"))' \
  "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a UI change on a graph without ui_review is never done"
assert_contains "$DRIVER_OUT" "implementation done, UI unverified: the project graph has no ui_review node" "that outcome says the screens were not verified and how to fix it"
assert_eq "null" "$(run_state .publish)" "nothing is published without UI verification"

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

new_driver_repo auto_questions
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "auto approval waits for a person when the brief comes back in the legacy open_questions format"
new_driver_repo auto_legacy
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "auto approval waits when the brief recorded no decisions, even without open questions"

# auto에서 brief 노드는 판단이 갈리는 점을 추천안으로 정하고(decisions), 사람만 정할 수 있는 것만 needs_human에 남긴다.
new_driver_repo auto_decisions
with_policy direct auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:auto-policy" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source)" "auto approval with decisions and no needs_human reaches done in one start"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "needs_human" "auto approval asks the brief node to decide and list what only a person can decide"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "migration" "the needs_human criteria name hard-to-reverse choices"
assert_contains "$(<"$(dirname "$(run_state .approval.brief)")/brief.md")" "## 결정 사항" "brief.md keeps the decisions section"
assert_contains "$(<"$(dirname "$(run_state .approval.brief)")/brief.md")" "which plan tier? → free tier only — smallest scope that meets the request" "brief.md records question, choice, and rationale"
assert_contains "$(<"$FAKE_LOG.deliver.prompt")" "free tier only" "deliver implements the brief with its decisions"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "which plan tier? → free tier only" "publish receives the decisions"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "승인 모드: auto (출처: HM_APPROVAL)" "PR instructions carry the resolved approval mode and source"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" '"결정 사항"' "publish is told to copy decisions into the PR body section"

new_driver_repo auto_needs_human
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "10:approval:waiting_approval" "$DRIVER_RC:$(run_state .node):$(run_state .status)" "auto approval stops at the approval node when the brief needs a person"
assert_contains "$DRIVER_OUT" "drop the legacy plans table?" "the person sees what only they can decide"
assert_contains "$DRIVER_OUT" "which plan tier? → free tier only" "the person also sees the decisions the agent made"
assert_eq "discover;brief" "$(cut -d' ' -f1 "$FAKE_LOG" | paste -sd ';' -)" "nothing writes while needs_human is open"
say_in_claude "승인"
driver resume
assert_eq "0:done:claude-transcript" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source)" "a person's approval resolves needs_human and the run continues"

new_driver_repo auto_no_edge
with_policy pr-only auto
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.when == "auto_approved_by_policy"))' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
assert_eq "10" "$DRIVER_RC" "a project graph without the auto edge keeps the human gate"

new_driver_repo human_pr
with_policy pr-only ""
FAKE_CHECK="grep -q fixed feature.txt" driver start --runtime codex --request "add feature"
assert_eq "10:human:default" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "approval defaults to human and records the default source"
say_in_claude "승인"
driver resume
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state '.checkpoints | length')" "a human-approved pr-only run checkpoints deliver and each repair, then opens a PR"

new_driver_repo approval_repo
with_policy pr-only ""
printf 'HM_APPROVAL=auto\nHM_APPROVAL_REPOS="repo-approval_repo=human,elsewhere=auto"\n' >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "10:human:HM_APPROVAL_REPOS:repo-approval_repo" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "a matching repository approval setting overrides the global setting"

new_driver_repo approval_global
with_policy pr-only ""
printf 'HM_APPROVAL=auto\nHM_APPROVAL_REPOS="another=human"\n' >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "0:auto:HM_APPROVAL" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "the global approval setting applies without a matching repository entry"

new_driver_repo manifest_approval
with_policy pr-only ""
jq '.approval = "auto"' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/manifest.json" && mv "$DRIVER_REPO/manifest.json" "$DRIVER_REPO/.ai-harness/harness.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m legacy-approval
: >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "10:human:default" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "a legacy manifest approval value is ignored"
assert_eq "1" "$(grep -c 'notice: .ai-harness/harness.json approval is ignored' <<<"$DRIVER_OUT")" "a legacy manifest approval value produces one migration notice"

# 승인 모드 오타를 human으로 조용히 읽지 않는다 — 시작하지 않고 고칠 키를 알린다.
new_driver_repo approval_invalid
with_policy pr-only ""
printf 'HM_APPROVAL=yes\n' >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "2" "$DRIVER_RC" "an invalid personal approval value stops the start"
assert_contains "$DRIVER_OUT" "approval must be human or auto" "the invalid approval value is named"
assert_contains "$DRIVER_OUT" "HM_APPROVAL in $DRIVER_TMP/data/config" "the invalid approval names the config file it came from"
: >"$DRIVER_TMP/data/config"
# 값이 환경변수에서 왔으면 config 파일이 아니라 환경변수라고 말한다(#310).
DRIVER_RC=0
DRIVER_OUT="$(HM_APPROVAL=yes HM_APPROVAL_REPOS='' HARNESS_METRICS_DIR="$DRIVER_TMP/data" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" CLAUDE_CONFIG_DIR="$DRIVER_TMP/claude" CODEX_HOME="$DRIVER_TMP/codex" \
  FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO="$FAKE_SCENARIO" PATH="$ROOT/tests/fixtures/driver:$PATH" \
  bash "$DRIVER" start --runtime codex --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "an invalid approval from the environment stops the start"
assert_contains "$DRIVER_OUT" "HM_APPROVAL in the environment" "the invalid approval names the environment as its source"
[[ "$DRIVER_OUT" != *"config is"* ]] || fail "an environment value is not reported as a config file value"

# 업그레이드 전에 시작된 실행에는 approval_source가 없다 — 기본값(default)이 아니라 legacy로 보인다(#310).
new_driver_repo approval_legacy_status
with_policy pr-only ""
driver start --runtime codex --request "add feature"
LEGACY_STATE="$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
jq 'del(.policy.approval_source)' "$LEGACY_STATE" >"$LEGACY_STATE.tmp" && mv "$LEGACY_STATE.tmp" "$LEGACY_STATE"
driver status --workflow feature --run "$(run_state .run_id)"
assert_contains "$DRIVER_OUT" "approval human (legacy)" "a run without a recorded approval source shows legacy"
[[ "$DRIVER_OUT" != *"(default)"* ]] || fail "a legacy run is not shown as using the default approval"

new_driver_repo publish_unpushed
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a publish the runner cannot verify goes to a person"
assert_contains "$(run_state '.findings | join(";")')" "HEAD is not pushed to its upstream" "publish is judged by git state, not the session report"
assert_contains "$(run_state '.findings | join(";")')" "pr_url is empty" "pr-only without a PR is not done"

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
