#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 재개 기준선·개인 자동화 단계·bug-fix/review 러너·조사 보고서 시작
# 실행: bash tests/run.sh workflow-runs
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 반복 실패·의존 산출물 실패 출력(workflow-feature의 것과 같은 모양)과 기본 병합 정책.
STALL_OUT="$DRIVER_TMP/stall-output"
mkdir -p "$STALL_OUT"
printf 'src/app.ts:42: error E12 at 2026-11-19T12:34:56 took 123ms\n' >"$STALL_OUT/same.txt"
printf "node_modules/antd/lib/input/Input.d.ts(3,5): error TS1005: ',' expected.\n" >"$STALL_OUT/tsc-dependency.txt"
MP_BASIC='{"verify":["target_ci"],"base":"main"}'


# 버그 수정·변경 검토도 같은 러너가 실행한다. (#154)
BUG_FIX_GRAPH_TEMPLATE="$ROOT/templates/fix-bug/references/bug-fix-graph.json"
REVIEW_GRAPH_TEMPLATE="$ROOT/templates/review/references/review-graph.json"
run_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
bug_run() { # scenario [start args...] → 승인 뒤 resume까지
  new_driver_repo "$1"
  shift
  driver start --workflow bug-fix --runtime codex --request "total ignores tax" "$@"
  [[ "$DRIVER_RC" == 10 ]] || return 0
  say_in_claude "승인"
  driver resume
}
new_driver_repo bug_ok
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
assert_eq "10:approval:bug-fix" "$DRIVER_RC:$(run_state .node):$(run_state .workflow)" "a bug fix stops at approval after triage, reproduce, and brief"
assert_eq "triage read-only schema=;reproduce workspace-write schema=yes add-dir=yes;brief read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "nothing writes before approval; reproduce may run commands and keeps its notes in the run directory"
assert_contains "$DRIVER_OUT" "Bug Fix Brief" "the person sees a Bug Fix Brief"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "expected 110, got 100" "the brief carries the reproduction evidence"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" ".ai-harness/workflows/fix-bug.md" "bug-fix nodes read the project bug-fix workflow"
assert_contains "$(run_state .graph)" "bug-fix-graph.json" "the run follows the bug-fix graph"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an approved bug fix reaches done"
assert_contains "$(run_state '[.history[].to] | join(",")')" "regression,fix,verify,review,publish,remote_ci,done" "the runner follows the bug-fix graph"
assert_eq "regression workspace-write;fix workspace-write;review read-only" "$(tail -n 3 "$FAKE_LOG" | cut -d' ' -f1,2 | paste -sd ';' -)" "regression and fix write after approval; review stays read-only"
bug_run repro_blocked
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a bug that can be neither reproduced nor observed goes to a person before approval"
assert_contains "$(<"$(run_dir)/unresolved.json")" "a sample order export" "the person sees what is needed to reproduce"
[[ "$(<"$FAKE_LOG")" != *regression* ]] || fail "nothing writes when the bug cannot be reproduced"
bug_run repro_hollow
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "reproduced without evidence is not a reproduction"
bug_run repro_writes
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "reproduce that writes into the repository stops the run"
FAKE_CHECK="grep -q fixed feature.txt" bug_run bug_fixcheck
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failing verify goes to repair, then verify and review again"
assert_eq "fix;repair;review" "$(grep -E '^(fix|repair|review) ' "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "the failed check is repaired before review"
# verify 노드의 첫 실패(attempts 0)는 환경 오류로 확정되지 않으면 repair를 먼저 받는다. 같은 실패가 repair 뒤에도 반복될 때만 멈춘다.
FAKE_CHECK="cat '$STALL_OUT/same.txt'; false" bug_run bug_verify_stall
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a non-environment verify failure is repaired before the repeat stops it"
assert_eq "2" "$(grep -c '^repair ' "$FAKE_LOG")" "the first verify failure is not escalated without a repair"
FAKE_CHECK="cat '$STALL_OUT/tsc-dependency.txt'; false" bug_run bug_verify_dependency
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a confirmed dependency failure at verify goes to a person without a repair"
assert_eq "repair>user_decision" "$(run_state '.history | last | .from + ">" + .to')" "the environment decision follows the bug-fix graph's escalation edge"
bug_run bug_noop
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a bug fix without a change is not done"
bug_run bug_fix_noop
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a regression test alone does not count as a fix"
bug_run ui_bug
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a bug fix that changes a screen goes through ui_review"
assert_file "$(run_state .ui_review.evidence_dir)/default.png"
new_driver_repo bug_pr
with_policy pr-only auto
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state '.checkpoints | length')" "an auto-approved pr-only bug fix checkpoints regression and fix, then opens a PR"
assert_contains "$(git -C "$DRIVER_REPO" log --format=%s)" "wip(fix-bug): regression" "bug-fix checkpoints name the workflow"
new_driver_repo bug_legacy_verify
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.from == "verify" and .when == "required_checks_fail"))' "$BUG_FIX_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/bug-fix-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
FAKE_CHECK=false driver start --workflow bug-fix --runtime codex --request "total ignores tax"
say_in_claude "승인"
FAKE_CHECK=false driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a graph without the verify failure edge hands a failed check to a person"
assert_contains "$DRIVER_OUT" "no verify -> repair edge" "that outcome says how to fix it"
# 실행의 워크플로는 상태가 정한다. 다른 워크플로로 이어 가지 않는다.
driver status --workflow review --run "$(run_state .run_id)"
assert_eq "2" "$DRIVER_RC" "a run cannot be resumed as another workflow"
DRIVER_RC=0
DRIVER_OUT="$(HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER_SHIM" status --repo "$DRIVER_REPO" 2>&1)" || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "the old feature entry point does not resume a bug-fix run"
new_driver_repo shim_ok
DRIVER_RC=0
DRIVER_OUT="$(HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO=shim_ok PATH="$ROOT/tests/fixtures/driver:$PATH" \
  bash "$DRIVER_SHIM" start --runtime codex --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
assert_eq "10:feature" "$DRIVER_RC:$(run_state .workflow)" "the old entry point runs the feature workflow"
DRIVER_RC=0
HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER_SHIM" status --workflow review --repo "$DRIVER_REPO" >/dev/null 2>&1 || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "the old entry point refuses another workflow instead of running the feature one"
# 이 구분 전의 feature 실행(latest-feature 없음)은 그 뒤 다른 워크플로를 시작해도 이어 갈 수 있다.
rm -f "$(dirname "$(run_dir)")/latest-feature"
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
DRIVER_RC=0
DRIVER_OUT="$(HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER_SHIM" status --repo "$DRIVER_REPO" 2>&1)" || DRIVER_RC=$?
assert_eq "0" "$DRIVER_RC" "an older feature run is still found after another workflow started"
assert_contains "$DRIVER_OUT" "workflow feature" "the old entry point resumes the feature run, not the newer bug-fix run"

# resume·approve는 에이전트를 부르기 전에 러너가 멈춘 때의 기준점(HEAD·작업 트리 지문)과 지금을 대조한다. (#371)
# 같으면 그대로 잇고, 미커밋 수정·다른 커밋이면 차이와 남은 검사를 보이고 멈춘다. done에서 바뀌었으면 성공을 돌려주지 않는다.
new_driver_repo baseline_same
driver start --runtime codex --request "add feature"
assert_eq "10:$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$DRIVER_RC:$(run_state .repo_baseline.head)" "the runner keeps the baseline where it stopped"
[[ -n "$(run_state '.repo_baseline.fingerprint // ""')" ]] || fail "the baseline keeps the working tree fingerprint"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a resume from the same baseline continues as before"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a finished run resumed with nothing changed still reports done"
echo later >"$DRIVER_REPO/later.txt"
driver resume
assert_eq "20" "$DRIVER_RC" "a finished run whose working tree changed does not report success"
[[ "$(run_state .status)" != "done" ]] || fail "a changed finished run is not left as done"
assert_contains "$DRIVER_OUT" "later.txt" "the stop names the changed file"
driver resume --accept-changes
assert_eq "20" "$DRIVER_RC" "a finished run does not take changes in; they need a new run"
assert_contains "$DRIVER_OUT" "start a new run" "the finished run says how to check the change"
rm "$DRIVER_REPO/later.txt"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "back at the baseline, the finished run reports done again"
git -C "$DRIVER_REPO" add -A && git -C "$DRIVER_REPO" commit -q --allow-empty -m "after done"
driver resume
assert_eq "20" "$DRIVER_RC" "a commit after a finished run also stops it"

new_driver_repo baseline_dirty
driver start --runtime codex --request "add feature"
echo hand >"$DRIVER_REPO/hand.txt"
say_in_claude "승인"
driver resume
assert_eq "20:approval" "$DRIVER_RC:$(run_state .node)" "an uncommitted change after the stop halts resume"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "no agent writes when the baseline moved"
assert_contains "$DRIVER_OUT" "hand.txt" "the stop names the uncommitted file"
assert_contains "$DRIVER_OUT" "node approval" "the stop names where the run would continue"
assert_contains "$DRIVER_OUT" "checks: true" "the stop names the remaining required checks"
assert_contains "$DRIVER_OUT" "resume --accept-changes" "the stop says how to take the change in on purpose"
driver resume
assert_eq "20" "$DRIVER_RC" "a plain resume keeps stopping until the change is accepted or undone"
driver resume --accept-changes
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an explicit --accept-changes moves the baseline and continues"
assert_eq "1" "$(run_state '.baseline_accepted | length')" "the accepted change is recorded"
driver status --accept-changes
assert_eq "2" "$DRIVER_RC" "--accept-changes belongs to resume and approve only"

new_driver_repo baseline_commit
driver start --runtime codex --request "add feature"
echo other >"$DRIVER_REPO/other.txt"
git -C "$DRIVER_REPO" add -A && git -C "$DRIVER_REPO" commit -q -m "someone else's commit"
say_in_claude "승인"
driver resume
assert_eq "20:approval" "$DRIVER_RC:$(run_state .node)" "a different commit after the stop halts resume"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "no agent writes when HEAD moved"
assert_contains "$DRIVER_OUT" "someone else's commit" "the stop lists the new commits"
driver resume --accept-changes
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an accepted commit becomes the run's head, so the write nodes do not see HEAD as moved"

# 기준점이 없던 이전 버전의 실행도 HEAD는 대조한다.
new_driver_repo baseline_legacy
driver start --runtime codex --request "add feature"
jq 'del(.repo_baseline)' "$(run_dir)/state.json" >"$DRIVER_TMP/legacy.json" && mv "$DRIVER_TMP/legacy.json" "$(run_dir)/state.json"
git -C "$DRIVER_REPO" commit -q --allow-empty -m moved
say_in_claude "승인"
driver resume
assert_eq "20" "$DRIVER_RC" "a run from before baselines still stops when HEAD moved"

# 러너 자신의 체크포인트 커밋·publish가 HEAD를 옮겨도 기준점이 따라가 정상 재개는 막히지 않는다.
new_driver_repo baseline_checkpoint
with_policy pr-only human
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "checkpoint commits and publish keep the baseline with them"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(run_state .repo_baseline.head)" "the baseline follows the runner's own commits"
driver resume
assert_eq "0" "$DRIVER_RC" "a finished pr-only run resumed with nothing changed still reports done"

# 불변식 위반(40)은 러너가 허용하지 않은 변경이라 기준점이 되지 않는다. 다음 resume은 에이전트를 부르기 전에 멈춘다.
new_driver_repo baseline_violation
FAKE_SCENARIO=brief_writes
driver start --runtime codex --request "add feature"
assert_eq "40" "$DRIVER_RC" "a read-only node that writes stops the run"
BW_CALLS="$(wc -l <"$FAKE_LOG")"
driver resume
assert_eq "20:$BW_CALLS" "$DRIVER_RC:$(wc -l <"$FAKE_LOG")" "after an invariant violation, resume stops on the unaccepted change before any agent runs"
assert_contains "$DRIVER_OUT" "sneaky.txt" "the stop names the change the violation left"
new_driver_repo baseline_head_moved
FAKE_SCENARIO=commit
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "40" "$DRIVER_RC" "a write node that commits moves HEAD and stops the run"
driver resume
assert_eq "20:1" "$DRIVER_RC:$(grep -c '^deliver ' "$FAKE_LOG")" "resume after HEAD moved stops before the write node runs again"

# 리뷰를 지난 노드(remote_ci 등)에서는 받아들인 변경이 검증·리뷰를 건너뛰므로 --accept-changes도 거부한다.
new_driver_repo baseline_ci
with_policy pr-only auto
FAKE_SCENARIO=ci_pending
driver start --runtime codex --request "add feature"
assert_eq "30:remote_ci" "$DRIVER_RC:$(run_state .node)" "the run waits at remote_ci"
driver resume
assert_eq "30" "$DRIVER_RC" "resuming a pending remote CI with nothing changed checks again as before"
echo late >"$DRIVER_REPO/late.txt"
driver resume --accept-changes
assert_eq "20:remote_ci" "$DRIVER_RC:$(run_state .node)" "a change after review is not taken into the run"
assert_contains "$DRIVER_OUT" "start a new run" "the stop sends the change to a new run"

# 예전 진입점도 같은 대조를 거친다.
new_driver_repo baseline_shim
shim() { DRIVER_RC=0; DRIVER_OUT="$(HM_APPROVAL='' HM_APPROVAL_REPOS='' HM_RUNTIME='' HM_RUNTIME_REPOS='' HARNESS_METRICS_DIR="$DRIVER_TMP/data" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" CLAUDE_CONFIG_DIR="$DRIVER_TMP/claude" CODEX_HOME="$DRIVER_TMP/codex" \
  FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO="$FAKE_SCENARIO" FAKE_CHECK=true PATH="$ROOT/tests/fixtures/driver:$PATH" \
  bash "$DRIVER_SHIM" "$@" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?; }
shim start --runtime codex --request "add feature"
echo hand >"$DRIVER_REPO/hand.txt"
say_in_claude "승인"
shim resume
assert_eq "20" "$DRIVER_RC" "the old entry point stops on a changed baseline too"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "the old entry point does not write when the baseline moved"
pass "resume compares the saved baseline before any agent runs"

# 개인 자동화 단계(#242): 병합 여부는 사용자 config의 단계가, 병합 조건은 호스트 브랜치 보호가 정한다(#384). 저장소 merge_policy는 사실만 준다.
DL_DATA="$DRIVER_TMP/delivery-data"
mkdir -p "$DL_DATA"
delivery_run() { # scenario git_policy harness-jq-filter config-text [host/owner/repo] → 사용자 config를 두고 approval auto로 실행한다
  new_driver_repo "$1"
  with_policy "$2" auto
  as_host_repo "${5:-github.com/acme/app}"
  jq "$3" "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  printf 'HM_APPROVAL=auto\n%s\n' "$4" >"$DL_DATA/config"
  cp "$DL_DATA/config" "$DRIVER_TMP/data/config"
  DRIVER_DATA_OVERRIDE="$DL_DATA" HARNESS_METRICS_DIR="$DL_DATA" driver start --runtime codex --request "add feature"
}
DL_FACTS='.project_id = "acme-app" | .merge_policy = {base: "main", deploy_check_cmd: "true", smoke_cmd: "true"}'
gh_merges() { grep -c '^gh merge' "$FAKE_LOG" || true; }
export FAKE_PROTECTION=classic
delivery_run dl_pr merge ".merge_policy = $MP_BASIC" 'HM_DELIVERY_LEVEL=pr'
assert_eq "0:done:0:pr-only" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .policy.git)" "level pr stops at the pull request even when the repository says git_policy merge"
[[ "$(run_state '[.history[].to] | join(",")')" != *merge* ]] || fail "level pr never reaches the merge node"
assert_contains "$DRIVER_OUT" "notice: the repository git_policy merge is no longer used and is read as pr-only" "done says the repository merge setting is no longer used"
# 저장소 merge_policy의 병합 조건(require·min_approvals·method)은 개인 경로에 영향이 없다.
delivery_run dl_merge pr-only "$DL_FACTS"' | .merge_policy += {require: ["remote_ci"], min_approvals: 3, method: "rebase"}' 'HM_DELIVERY_LEVEL="merge"  # 내 단계'
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(gh_merges)" "level merge merges a pr-only repository's pull request"
assert_eq "target_ci" "$(run_state '.post_merge | keys_unsorted | join(",")')" "level merge verifies up to the target branch CI, not deploy or smoke"
assert_eq "1:1:main" "$(run_state '"\(.protection.approvals):\(.protection.checks):\(.protection.base)"')" "the merge node read the base branch protection from the host"
assert_contains "$(<"$FAKE_LOG")" "gh api repos/acme/app/branches/main/protection" "classic branch protection is read for the base branch"
assert_eq "false:squash" "$(run_state '"\(.policy.merge | has("require") or has("min_approvals") or has("method")):\(.merge.method)"')" "the repository merge_policy conditions are not used; the method is the repository's allowed one"
assert_contains "$DRIVER_OUT" "notice: merge_policy require, min_approvals, and method in .ai-harness/harness.json are no longer used; merges follow the branch protection" "the ignored repository merge conditions are named"
delivery_run dl_deploy pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=deploy'
assert_eq "0:done:target_ci,deploy,smoke" "$DRIVER_RC:$(run_state .status):$(run_state '.post_merge | keys_unsorted | join(",")')" "level deploy goes on to the repository's deploy and smoke checks"
delivery_run dl_deploy_nocmd pr-only '.merge_policy = {base: "main"}' 'HM_DELIVERY_LEVEL=deploy'
assert_eq "0:done:target_ci" "$DRIVER_RC:$(run_state .status):$(run_state '.post_merge | keys_unsorted | join(",")')" "level deploy without deploy or smoke commands stops after the merge"
assert_contains "$DRIVER_OUT" "delivery level deploy: the repository has no deploy or smoke check" "the result says why deploy was not verified"
delivery_run dl_repo_level pr-only "$DL_FACTS" "$(printf '%s\n' 'HM_DELIVERY_LEVEL=pr' 'HM_DELIVERY_LEVEL_REPOS="other=deploy, acme-app=merge"' 'HM_MERGE_REQUIRE="human_approval remote_ci"' 'HM_MERGE_METHOD=merge')"
assert_eq "0:done:1:HM_DELIVERY_LEVEL_REPOS:acme-app" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .policy.delivery.source)" "a per-repository level overrides the default level"
assert_contains "$(<"$FAKE_LOG")" "--squash --match-head-commit" "an old personal HM_MERGE_METHOD is not used"
assert_contains "$DRIVER_OUT" "notice: HM_MERGE_REQUIRE, HM_MERGE_MIN_APPROVALS, and HM_MERGE_METHOD in ~/.ai-harness/config are no longer used" "the ignored personal merge settings are named"
export FAKE_PROTECTION=ruleset
delivery_run dl_ruleset pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
assert_eq "30:merge:0" "$DRIVER_RC:$(run_state .node):$(gh_merges)" "the host's required approval count is the condition"
assert_contains "$DRIVER_OUT" "human approval: 1 of 2" "the runner waits for the approvals the host ruleset requires"
# 보호가 없거나 필수 체크만 있으면 저장소 규칙대로 승인 없이 병합한다. 보호를 읽지 못하면 사람에게 넘긴다.
for p in none:"" checks_only:remote_ci; do
  export FAKE_PROTECTION="${p%%:*}"
  delivery_run "dl_prot_${p%%:*}" pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
  assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(gh_merges)" "protection ${p%%:*}: the runner merges by the repository's own rules"
  assert_eq "0" "$(run_state .protection.approvals)" "protection ${p%%:*}: no approval is required"
done
export FAKE_PROTECTION=denied
delivery_run dl_prot_denied pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(gh_merges)" "protection denied: the runner does not merge without knowing the repository's rules"
assert_contains "$DRIVER_OUT" "cannot read the branch protection of main from the host" "protection denied: the person is told why"
export ATLASSIAN_USER='me@example.com' BITBUCKET_API_TOKEN='token'
export FAKE_PROTECTION=bb_glob
delivery_run dl_bb_glob pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge' bitbucket.org/acme/app
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .protection.approvals)" "a Bitbucket branch restriction matching the base by glob allows the merge"
export FAKE_PROTECTION=bb_model
delivery_run dl_bb_model pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge' bitbucket.org/acme/app
assert_eq "30:2:0" "$DRIVER_RC:$(run_state .protection.approvals):$(run_state .protection.checks)" "a branching-model restriction applies to the development branch; other patterns do not"
export FAKE_PROTECTION=bb_denied
delivery_run dl_bb_denied pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge' bitbucket.org/acme/app
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "unreadable Bitbucket branch restrictions are not merged over"
unset ATLASSIAN_USER BITBUCKET_API_TOKEN
export FAKE_PROTECTION=none
# 개인 단계가 없으면 항상 PR까지다. 예전 저장소 git_policy merge·merge_policy로는 병합하지 않고 안내만 남긴다.
delivery_run dl_legacy merge ".merge_policy = $MP_BASIC" ''
assert_eq "0:done:0:pr-only:null:0" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .policy.git):$(run_state .policy.merge):$(grep -c '^gh api' "$FAKE_LOG" || true)" "without a personal level git_policy merge stops at the pull request"
[[ "$(run_state '[.history[].to] | join(",")')" != *merge* ]] || fail "without a personal level the merge node is never reached"
assert_contains "$DRIVER_OUT" "PR: https://github.com/acme/app/pull/7" "the legacy merge setting still opens the pull request"
assert_contains "$DRIVER_OUT" "notice: the repository git_policy merge is no longer used and is read as pr-only; choose how far runs go with a personal delivery level (/ai-harness:setup)" "the result tells how to choose a personal level"
assert_eq "2" "$(grep -c 'notice: the repository git_policy merge is no longer used' <<<"$DRIVER_OUT")" "the notice is shown at start and in the result"
delivery_run dl_none_pr pr-only "$DL_FACTS" ''
assert_eq "0:done:0:[]" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state ".policy.notices | tostring")" "pr-only without a personal level stops at the pull request without a notice"
[[ "$DRIVER_OUT" != *"notice:"* ]] || fail "repository facts alone raise no notice"
# 이전 버전이 시작 때 정한 병합 조건(require·min_approvals·method)으로 대기하던 실행을 resume하면 호스트 규칙으로 다시 판정한다.
state_file="$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
jq '.node = "merge" | .status = "running" | .policy.git = "merge" | .policy.delivery = null
  | .policy.merge = {require: ["remote_ci"], min_approvals: 1, method: "squash", verify: [], base: "main"}' "$state_file" >"$DRIVER_TMP/s.json" && mv "$DRIVER_TMP/s.json" "$state_file"
driver resume
assert_eq "0:done:1:squash" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .merge.method)" "a legacy merge run resumed after the update follows the host rules, not its old conditions"
export FAKE_PROTECTION=classic
HM_INTERNAL_SESSION=1 delivery_run dl_unattended pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh ' "$FAKE_LOG" || true)" "an unattended run does not merge on a personal level either"
assert_contains "$DRIVER_OUT" "merge: not done — unattended run" "the unattended outcome says the merge was left to a person"
unset FAKE_PROTECTION
delivery_run dl_bad pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=ship'
assert_eq "2" "$DRIVER_RC" "an unknown delivery level does not start"
assert_contains "$DRIVER_OUT" "must be pr, merge, or deploy" "the error names the levels"
delivery_run dl_old_require pr-only "$DL_FACTS" "$(printf '%s\n' 'HM_DELIVERY_LEVEL=merge' 'HM_MERGE_REQUIRE=lgtm')"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an old personal merge condition no longer stops the start"
assert_contains "$DRIVER_OUT" "HM_MERGE_REQUIRE, HM_MERGE_MIN_APPROVALS, and HM_MERGE_METHOD in ~/.ai-harness/config are no longer used" "the notice names the old settings"
rm -f "$DL_DATA/config"
pass "delivery level: personal stage, repository facts, host rules"

# review: 승인 노드가 없는 그래프다. 수리는 사람이 동의한 뒤에만 하고, 커밋하지 않는다.
review_run() { # scenario → 커밋 안 된 변경을 검토하기 시작한다
  new_driver_repo "$1"
  echo change >"$DRIVER_REPO/feature.txt"
  driver start --workflow review --runtime codex --request "review my uncommitted change"
}
review_run rv_clean
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a review without blocking findings is done"
assert_eq "scope read-only schema=yes;inspect read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "the initial review is read-only"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(run_state .diff_base)" "the review measures the change from the base the scope node named"
new_driver_repo rv_empty
driver start --workflow review --runtime codex --request "review my uncommitted change"
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a review with nothing to review stops instead of passing"
assert_contains "$DRIVER_OUT" "nothing to review" "the person is told the review target is empty"
review_run rv_blocks
assert_eq "10:waiting_approval:classify" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "blocking findings wait for the person before any repair"
assert_contains "$DRIVER_OUT" "feature.txt: missing case" "the person sees the findings to repair"
assert_contains "$DRIVER_OUT" "수리하지 않으면 여기서 끝난다" "the person can keep the review without a repair"
driver resume
assert_eq "10:1" "$DRIVER_RC:$(grep -c '^inspect ' "$FAKE_LOG")" "resume without approval keeps waiting and does not review again"
say_in_claude "승인"
driver resume
assert_eq "0:done:1:claude-transcript" "$DRIVER_RC:$(run_state .status):$(run_state .attempts):$(run_state .approval.source)" "an approved repair goes through verify and re-review to done"
# 리뷰 노드는 데이터 조회가 있는 변경에서 대량 조회의 "건수 상한 × 행 크기"를 근거로 적는다. 조회가 없는 변경(프론트 등)에는 적용하지 않는다. (#499)
for node in inspect re_review; do
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "row-count bound × row size" "$node checks bulk reads by row-count bound × row size"
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "skip it for changes without such data access" "$node skips the bulk read check without data access"
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "neither is a caller/receiver count mismatch on a write path or when the receiving query reads only the small columns it needs" "$node does not flag the bound of a write path or a small projection"
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "do not leave it out because its definition is outside the diff when its caller is inside it" "$node keeps an existing query whose caller changed"
  assert_contains "$(<"$FAKE_LOG.$node.prompt")" "pulled in by fetch joins or association loading and those in other modules" "$node sizes rows from the entities a query pulls in"
done
assert_eq "repair;re_review" "$(tail -n 2 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "every repair is followed by checks and re-review"
assert_eq "fixed:1" "$(<"$DRIVER_REPO/feature.txt"):$(git -C "$DRIVER_REPO" rev-list --count HEAD)" "the repair stays uncommitted in the working tree"
assert_contains "$DRIVER_OUT" "left uncommitted" "the outcome says the repair is not committed"
review_run rv_decision
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a finding that needs a product decision goes to a person"
review_run scope_bad_base
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a review base that is not a commit stops the run"
review_run scope_nocheck
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a repair needs a verification command"
new_driver_repo rv_auto
with_policy pr-only auto
echo change >"$DRIVER_REPO/feature.txt"
driver start --workflow review --runtime codex --request "review my uncommitted change"
assert_eq "0:done:auto-policy:0" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source):$(run_state '.checkpoints | length')" "approval auto authorizes the repair, and review never commits"
new_driver_repo rv_always_blocks
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_repair_attempts = 2' "$REVIEW_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/review-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
echo change >"$DRIVER_REPO/feature.txt"
driver start --workflow review --runtime codex --request "review my uncommitted change"
say_in_claude "승인"
driver resume
assert_eq "10" "$DRIVER_RC" "a finding the person has not seen asks again before it is repaired"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "re-review stops at the graph's repair limit"
FAKE_CHECK="test -f $DRIVER_TMP/rv_verify_fail.seen || { touch $DRIVER_TMP/rv_verify_fail.seen; false; }"
review_run rv_verify_fail
say_in_claude "승인"
driver resume
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failed check after repair goes back to repair"
FAKE_CHECK=false
new_driver_repo rv_verify_limit
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_repair_attempts = 1' "$REVIEW_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/review-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
echo change >"$DRIVER_REPO/feature.txt"
driver start --workflow review --runtime codex --request "review my uncommitted change"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "checks that keep failing reach the repair limit and go to a person"
unset FAKE_CHECK
review_run rv_new_finding
say_in_claude "승인"
driver resume
assert_eq "10:re_review" "$DRIVER_RC:$(run_state .node)" "a new finding outside the approved repair scope asks again"
assert_contains "$DRIVER_OUT" "auth flow must be redesigned" "the person sees the new finding before it is repaired"
assert_eq "1" "$(grep -c '^repair ' "$FAKE_LOG")" "nothing repairs the new finding before the person agrees"
say_in_claude "승인"
driver resume
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "after the second agreement the new finding is repaired and re-reviewed"
review_run rv_ui
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a review of a screen change verifies the rendered screen"
assert_contains "$(<"$FAKE_LOG")" "ui_review workspace-write schema=yes net=yes add-dir=yes" "review keeps captures in the run directory too"
assert_file "$(run_state .ui_review.evidence_dir)/default.png"
new_driver_repo rv_clean_screen
mkdir -p "$DRIVER_REPO/templates"
echo '<summary>반려하기</summary>' >"$DRIVER_REPO/templates/approve.html"
driver start --workflow review --runtime codex --request "review my uncommitted change"
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a changed screen file is verified even when the reviewer listed no scenario"
pass "bug-fix and review graphs run through the same runner"

# /investigate가 남긴 조사 보고를 받으면 fix-bug는 triage·reproduce를 다시 하지 않고 brief부터 시작한다. (#338)
INVESTIGATION_REPORT="$DRIVER_TMP/investigation.md"
printf '%s\n' '# Investigation: total ignores tax' 'root cause: tax is skipped when the discount is zero' \
  'evidence: npm test -- total: expected 110, got 100 (origin/develop)' >"$INVESTIGATION_REPORT"
new_driver_repo bug_investigated
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$INVESTIGATION_REPORT"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "an investigated bug still stops at approval"
assert_eq "brief read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "an investigation report skips triage and reproduce"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "tax is skipped when the discount is zero" "the brief reads the investigation report"
assert_contains "$(run_state '[.history[] | .from + ">" + .to] | join(",")')" "triage>brief" "the skip is a declared graph edge"
assert_eq "investigation_report_provided" "$(run_state 'first(.history[] | select(.from == "triage")) | .outcome')" "the skip names its outcome"
# 그 전이가 없는 옛 프로젝트 그래프는 평소대로 triage·reproduce를 돈다.
new_driver_repo bug_investigated_legacy
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.when == "investigation_report_provided"))' "$BUG_FIX_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/bug-fix-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$INVESTIGATION_REPORT"
assert_eq "10" "$DRIVER_RC" "a legacy graph still reaches approval"
assert_contains "$(<"$FAKE_LOG")" "triage read-only" "a legacy graph without the skip edge runs triage"
assert_contains "$(<"$FAKE_LOG.triage.prompt")" "tax is skipped when the discount is zero" "a legacy triage still reads the report"
new_driver_repo feature_investigated
driver start --runtime codex --request "add feature" --investigation "$INVESTIGATION_REPORT"
assert_eq "2" "$DRIVER_RC" "only bug-fix takes an investigation report"
new_driver_repo bug_investigation_missing
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$DRIVER_TMP/no-such-report.md"
assert_eq "2" "$DRIVER_RC" "a missing investigation report is a usage error"
: >"$DRIVER_TMP/empty-investigation.md"
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$DRIVER_TMP/empty-investigation.md"
assert_eq "2" "$DRIVER_RC" "an empty investigation report does not skip reproduce"
pass "fix-bug starts from the brief with an investigation report"

# --runtime이 없으면 러너를 부른 런타임을 따르고, 못 정하면 integrations·설치된 CLI 순으로 정한다.
# codex가 PATH에 있다는 것만으로 codex를 고르지 않는다(#476).
runtime_run() { # env... → DRIVER_RC, DRIVER_OUT (DRIVER_REPO는 new_driver_repo가 준비)
  DRIVER_RC=0
  DRIVER_OUT="$(env -u CLAUDECODE -u CODEX_THREAD_ID -u HM_RUNTIME -u HM_RUNTIME_REPOS "$@" HM_APPROVAL='' HM_APPROVAL_REPOS='' HARNESS_METRICS_DIR="$DRIVER_TMP/data" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" \
    CLAUDE_CONFIG_DIR="${RUNTIME_CFG:-$DRIVER_TMP/claude}" CODEX_HOME="$DRIVER_TMP/codex" FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO="$FAKE_SCENARIO" FAKE_CHECK=true \
    PATH="${RUNTIME_PATH:-$ROOT/tests/fixtures/driver:$PATH}" bash "$DRIVER" start ${RUNTIME_FLAG:+--runtime "$RUNTIME_FLAG"} --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
}
with_integrations() { # json array → 저장소 manifest
  mkdir -p "$DRIVER_REPO/.ai-harness"
  jq -n --argjson i "$1" '{project_id:"rt", level:"standard", integrations:$i}' >"$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m manifest
}
new_driver_repo rt-claude-caller
runtime_run CLAUDECODE=1
assert_eq "claude" "$(run_state .runtime)" "a runner started from Claude Code runs claude sessions even when codex is installed"
new_driver_repo rt-codex-caller
runtime_run CODEX_THREAD_ID=t-1
assert_eq "codex" "$(run_state .runtime)" "a runner started from Codex runs codex sessions"
new_driver_repo rt-integrations
with_integrations '["claude"]'
runtime_run
assert_eq "claude" "$(run_state .runtime)" "without a caller signal the repository integrations decide"
new_driver_repo rt-both-signals
with_integrations '["codex"]'
runtime_run CLAUDECODE=1 CODEX_THREAD_ID=t-1
assert_eq "codex" "$(run_state .runtime)" "a nested Claude/Codex environment does not guess the caller; integrations decide"
# 설치된 CLI가 codex 하나뿐인 PATH. jq·git은 설치 위치가 머신마다 달라 링크로 넣는다.
mkdir -p "$DRIVER_TMP/only-codex"
ln -sf "$ROOT/tests/fixtures/driver/codex" "$DRIVER_TMP/only-codex/codex"
for t in jq git; do ln -sf "$(command -v "$t")" "$DRIVER_TMP/only-codex/$t"; done
new_driver_repo rt-only-codex
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "codex" "$(run_state .runtime)" "with one CLI installed and no other signal the installed one runs"
new_driver_repo rt-integrations-missing
with_integrations '["claude"]'
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "codex" "$(run_state .runtime)" "integrations naming an uninstalled CLI fall through to the installed one"
new_driver_repo rt-integrations-both
with_integrations '["claude", "codex"]'
runtime_run
assert_eq "2" "$DRIVER_RC" "integrations listing both installed CLIs do not pick one by list order"
new_driver_repo rt-both-signals-undecided
runtime_run CLAUDECODE=1 CODEX_THREAD_ID=t-1
assert_eq "2" "$DRIVER_RC" "a nested Claude/Codex environment without integrations refuses to guess"
# Claude Code에서 부르면 기본이 claude가 되므로, 저장소가 Claude 설정 폴더 안이면 시작 전에 거부하고 codex를 안내한다.
new_driver_repo rt-claude-protected
RUNTIME_CFG="$DRIVER_TMP" runtime_run CLAUDECODE=1
assert_eq "2" "$DRIVER_RC" "a Claude Code caller with the repository inside the Claude configuration directory is refused"
assert_contains "$DRIVER_OUT" "--runtime codex" "the refusal points to --runtime codex"
new_driver_repo rt-undecided
runtime_run
assert_eq "2" "$DRIVER_RC" "both CLIs installed and nothing to decide refuses to guess"
assert_contains "$DRIVER_OUT" "--runtime" "the refusal asks for --runtime"
assert_eq "" "$(find "$DRIVER_TMP/runs" -path "*/repo-rt-undecided-*" -name state.json)" "no run is created when the runtime is undecided"
pass "runner runtime follows the caller, then integrations, then the installed CLI"

# 개인 기본 런타임(#488): --runtime > HM_RUNTIME_REPOS > HM_RUNTIME > 자동 선택. 설정이 고른 CLI가 없으면 바꾸지 않고 멈춘다.
rt_config() { printf '%s\n' "$@" >"$DRIVER_TMP/data/config"; }
new_driver_repo rt-flag
with_integrations '[]'
rt_config 'HM_RUNTIME=codex' 'HM_RUNTIME_REPOS="rt=claude"'
RUNTIME_FLAG=codex runtime_run
assert_eq "codex:flag" "$(run_state .runtime):$(run_state .policy.runtime_source)" "--runtime wins over the personal settings"
assert_contains "$DRIVER_OUT" "runtime codex (flag)" "start prints the runtime and where it came from"
new_driver_repo rt-repo-setting
with_integrations '[]'
rt_config 'HM_RUNTIME=codex' 'HM_RUNTIME_REPOS="other=codex,rt=claude"'
runtime_run CODEX_THREAD_ID=t-1
assert_eq "claude:HM_RUNTIME_REPOS:rt" "$(run_state .runtime):$(run_state .policy.runtime_source)" "the repository setting wins over HM_RUNTIME and the caller"
assert_contains "$DRIVER_OUT" "runtime claude (HM_RUNTIME_REPOS:rt)" "start names the repository setting"
# 저장소 설정을 바꿔도 이어 가는 실행은 start 때의 런타임을 쓴다.
rt_config 'HM_RUNTIME_REPOS="rt=codex"'
driver resume
assert_eq "claude" "$(run_state .runtime)" "resume keeps the runtime chosen at start"
new_driver_repo rt-user-setting
with_integrations '[]'
rt_config 'HM_RUNTIME=codex' 'HM_RUNTIME_REPOS="other=claude"'
runtime_run CLAUDECODE=1
assert_eq "codex:HM_RUNTIME" "$(run_state .runtime):$(run_state .policy.runtime_source)" "HM_RUNTIME applies when no repository entry matches"
new_driver_repo rt-default-source
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "codex:default" "$(run_state .runtime):$(run_state .policy.runtime_source)" "without settings the automatic choice is recorded as default"
assert_contains "$DRIVER_OUT" "runtime codex (default)" "start says the runtime was chosen automatically"
new_driver_repo rt-bad-user
rt_config 'HM_RUNTIME=gemini'
runtime_run
assert_eq "2" "$DRIVER_RC" "an unknown HM_RUNTIME stops the start"
assert_contains "$DRIVER_OUT" "HM_RUNTIME in $DRIVER_TMP/data/config is \"gemini\"; runtime must be claude or codex" "the error names the setting and the file"
assert_eq "" "$(find "$DRIVER_TMP/runs" -path "*/repo-rt-bad-user-*" -name state.json)" "no run is created for an invalid runtime setting"
new_driver_repo rt-bad-repo
with_integrations '[]'
rt_config 'HM_RUNTIME_REPOS="rt=bogus"'
runtime_run
assert_eq "2" "$DRIVER_RC" "an unknown repository runtime stops the start"
assert_contains "$DRIVER_OUT" "HM_RUNTIME_REPOS:rt in $DRIVER_TMP/data/config" "the error names the repository entry"
new_driver_repo rt-bad-env
runtime_run HM_RUNTIME=bogus
assert_eq "2" "$DRIVER_RC" "an unknown HM_RUNTIME from the environment stops the start"
assert_contains "$DRIVER_OUT" "in the environment" "the error says the value came from the environment"
new_driver_repo rt-missing-user
rt_config 'HM_RUNTIME=claude'
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "2" "$DRIVER_RC" "a chosen CLI that is not installed stops the start"
assert_contains "$DRIVER_OUT" "HM_RUNTIME in $DRIVER_TMP/data/config chose claude, but claude is not installed" "the stop names the setting and the missing CLI"
assert_eq "" "$(find "$DRIVER_TMP/runs" -path "*/repo-rt-missing-user-*" -name state.json)" "no run falls back to codex"
[[ ! -s "$FAKE_LOG" ]] || fail "no session runs when the chosen CLI is missing"
new_driver_repo rt-missing-repo
with_integrations '[]'
rt_config 'HM_RUNTIME_REPOS="rt=claude"'
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "2" "$DRIVER_RC" "a repository runtime that is not installed stops the start"
assert_contains "$DRIVER_OUT" "HM_RUNTIME_REPOS:rt in $DRIVER_TMP/data/config chose claude" "the stop names the repository entry"
: >"$DRIVER_TMP/data/config"
pass "personal runtime settings pick the node runtime after --runtime and stop when the CLI is missing"

finish_tests
