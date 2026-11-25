#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 호스트 규칙·저장소 사실·병합 뒤 검증
# 실행: bash tests/run.sh workflow-merge
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"


# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
export HM_SMOKE_RETRY_SECONDS=0
MR_DATA="$DRIVER_TMP/merge-data"
mkdir -p "$MR_DATA"
merge_config() { # merge-settings-json → 개인 config: 검증에 배포·스모크·재발 추적이 있으면 단계 deploy, 아니면 merge
  jq -r '"HM_APPROVAL=auto", "HM_DELIVERY_LEVEL=" + (if (.verify // []) | any(IN("deploy", "smoke", "monitor")) then "deploy" else "merge" end)' <<<"$1" >"$MR_DATA/config"
}
merge_run() { # scenario merge-settings-json [host/owner/repo] → 저장소 사실은 manifest에, 단계는 개인 config에 두고 approval auto로 실행한다
  new_driver_repo "$1"
  with_policy pr-only auto
  as_host_repo "${3:-github.com/acme/app}"
  jq --argjson m "$2" '.merge_policy = ($m | del(.require, .min_approvals, .method))' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" \
    && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  merge_config "$2"
  cp "$MR_DATA/config" "$DRIVER_TMP/data/config"
  DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime "${MERGE_RUNTIME:-codex}" --request "add feature"
}
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
MP_BASIC='{"verify":["target_ci"],"base":"main"}'
merge_run merge_ok "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "merge policy merges and verifies when every condition holds"
assert_contains "$(<"$FAKE_LOG")" "gh merge https://github.com/acme/app/pull/7 --squash --match-head-commit $(git -C "$DRIVER_REPO" rev-parse HEAD)" "the runner merges with the head pinned to the reviewed, pushed commit"
assert_contains "$(<"$FAKE_LOG")" "gh api repos/acme/app" "the merge method is read from the repository settings"
assert_eq "remote_ci,merge,post_merge_verify" "$(run_state '[.history[] | select(.from | IN("remote_ci", "merge", "post_merge_verify")) | .from] | join(",")')" "merge follows remote CI and is verified after"
assert_eq "1111111111111111111111111111111111111111:alice:passed" "$(run_state '"\(.merge.commit):\(.merge.approvals | join(",")):\(.post_merge.target_ci.status)"')" "the merge commit and the approvers are recorded"
assert_contains "$DRIVER_OUT" "merged: 111111111111 (squash); after merge: target_ci passed" "done reports the merge and the post-merge checks"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "Never merge (under merge the driver merges later" "the publish node still never merges by itself"
# 승인이 아직 없으면 병합하지 않고 기다리며, resume이 다시 본다.
merge_run merge_wait "$MP_BASIC"
assert_eq "30:incomplete:merge" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "missing human approval waits at merge"
assert_contains "$DRIVER_OUT" "human approval: 0 of 1 on the current head" "the wait names the unmet condition"
assert_eq "0" "$(grep -c '^gh merge' "$FAKE_LOG" || true)" "nothing is merged while a condition is unmet"
touch "$FAKE_LOG.approved"
driver resume
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG")" "resume merges once the approval arrives"
# 승인은 지금 head에 대한 것이고 작성자 본인이 아니어야 한다.
merge_run merge_stale "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval of an older commit does not count"
merge_run merge_self "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "the author's own approval does not count"
merge_run merge_outsider "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval from an account without write access does not count"
merge_run merge_bot "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "a bot's approval does not count"
merge_run merge_dismissed "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "a dismissed approval does not count"
merge_run merge_rereviewed "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a reviewer who requested changes and then approved counts as approving"
merge_run merge_draft "$MP_BASIC"
assert_contains "$DRIVER_RC:$DRIVER_OUT" "30:" "a draft pull request waits"
assert_contains "$DRIVER_OUT" "the pull request is a draft" "the draft condition is named"
# 고를 수 없는 상태는 사람에게 넘긴다.
# 충돌만으로 막힌 경우(merge_conflict)는 sync_base가 base를 따라잡는다(tests/workflow-merge-sync.sh). 그 밖의 막힘은 sync하지 않는다.
for s in merge_changes:"a reviewer requested changes" merge_closed:"closed without merging" \
  merge_otherbase:"targets release, not the base branch main" merge_hostci_fail:"the host reports the checks on the head as failed" \
  merge_headmoved:"is not the pushed and reviewed commit" merge_host_down:"cannot read the pull request state" merge_cmd_fail:"merging failed"; do
  merge_run "${s%%:*}" "$MP_BASIC"
  assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "${s%%:*} goes to a person"
  assert_contains "$DRIVER_OUT" "merge blocked: " "${s%%:*} says the merge was blocked"
  assert_contains "$DRIVER_OUT" "${s#*:}" "${s%%:*} names the reason"
  assert_eq "0" "$(run_state '.base_syncs // [] | length')" "${s%%:*} does not sync the base"
done
assert_eq "0" "$(grep -c '^gh merge' "$DRIVER_TMP/merge_changes.log" || true)" "requested changes are never merged over"
# 다른 저장소의 PR은 병합하지 않는다.
merge_run merge_otherrepo "$MP_BASIC" github.com/acme/other
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a pull request outside this repository is never merged"
assert_contains "$DRIVER_OUT" "is not in this repository" "the repository mismatch is named"
assert_eq "0" "$(run_state '.base_syncs // [] | length')" "a pull request outside this repository does not sync the base"
# Bitbucket: 승인은 마지막 push 뒤의 것만 센다. 자격증명은 stdin으로 넘긴다.
export ATLASSIAN_USER='me@example.com' BITBUCKET_API_TOKEN='tok"en' FAKE_PROTECTION=bb_glob
merge_run bb_merge "$(jq -c '.verify = []' <<<"$MP_BASIC")" bitbucket.org/acme/app
assert_eq "0:done:111111111111:repository default" "$DRIVER_RC:$(run_state .status):$(run_state .merge.commit):$(run_state .merge.method)" "a Bitbucket pull request is merged when its conditions hold"
assert_contains "$(<"$FAKE_LOG")" "curl POST acme/app/pullrequests/7/merge" "the Bitbucket merge endpoint is called"
assert_contains "$(<"$FAKE_LOG")" 'curl body {"close_source_branch": false}' "Bitbucket merges with the repository's default strategy"
merge_run bb_stale "$(jq -c '.verify = []' <<<"$MP_BASIC")" bitbucket.org/acme/app
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "a Bitbucket approval from before the last push does not count"
unset ATLASSIAN_USER BITBUCKET_API_TOKEN
export FAKE_PROTECTION=classic
# 사람이 먼저 병합했으면 그 병합 커밋으로 병합 후 검증을 이어 간다.
merge_run merge_outside "$MP_BASIC"
assert_eq "0:done:outside the runner:0" "$DRIVER_RC:$(run_state .status):$(run_state .merge.method):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a pull request merged by a person is verified without merging again"
# 호스트 보호가 필수 승인을 걸면 그 승인을 기다린다. 방식은 저장소가 허용한 방식을 따른다.
export FAKE_MERGE_METHODS=merge_only
merge_run merge_noapproval '{"verify":[],"base":"main"}'
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "the host's required approval is waited for"
assert_contains "$DRIVER_OUT" "human approval: 0 of 1" "the wait names the approval the host requires"
touch "$FAKE_LOG.approved"
DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver resume
assert_eq "0:done:merge" "$DRIVER_RC:$(run_state .status):$(run_state .merge.method)" "resume merges once the host-required approval arrives"
assert_contains "$(<"$FAKE_LOG")" "--merge --match-head-commit" "the merge method is the one the repository allows"
for m in unknown:"the repository settings do not say which merge methods are allowed" denied:"cannot read which merge methods the repository allows"; do
  export FAKE_MERGE_METHODS="${m%%:*}"
  merge_run "merge_method_${m%%:*}" "$MP_BASIC"
  assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "merge methods ${m%%:*}: the runner does not guess a merge method"
  assert_contains "$DRIVER_OUT" "${m#*:}" "merge methods ${m%%:*}: the person is told why"
done
unset FAKE_MERGE_METHODS
# 원격 CI가 없다는 보고는 remote_ci 조건을 채우지 못한다.
merge_run merge_ci_none "$MP_BASIC"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "require remote_ci needs a passed remote CI, not 'no CI'"
# 무인 실행은 병합하지 않는다.
HM_INTERNAL_SESSION=1 merge_run merge_unattended "$MP_BASIC"
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh ' "$FAKE_LOG" || true)" "an unattended run never merges"
assert_contains "$DRIVER_OUT" "merge: not done — unattended run" "the outcome says the merge was left to a person"
# PR 호스트를 읽을 수 없는 URL이면 병합하지 않는다.
merge_run ok_unknown_host "$MP_BASIC"
assert_contains "$DRIVER_RC:$DRIVER_OUT" "20:" "an unsupported pull request host is not merged"
assert_contains "$DRIVER_OUT" "unsupported pull request host" "the reason names the host"
# 병합 후 검증: 타깃 CI → 배포 확인 → 스모크. 실패는 되돌리지 않고 사람에게, 배포 미관측은 기한까지 resume.
merge_run pm_ci_fail "$MP_BASIC"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a failed CI on the merge commit goes to a person"
assert_contains "$DRIVER_OUT" "post-merge check failed: CI on main for the merge commit" "the failure is reported as post-merge"
assert_contains "$(run_state '.findings[1]')" "git revert 1111111111111111111111111111111111111111" "rollback instructions are given, not executed"
# 배포 확인 명령을 실행할 수 없으면(127) 기한까지 기다리지 않는다.
merge_run pm_deploy_missing '{"base":"main","verify":["deploy"],"deploy_check_cmd":"no-such-deploy-check"}'
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a deploy check that cannot run is reported at once"
assert_contains "$DRIVER_OUT" "could not run (exit 127" "the broken command is named"
# base가 manifest에도 origin 기본 브랜치에도 없으면 시작하지 않는다.
merge_run merge_nobase '{}'
assert_eq "2" "$DRIVER_RC" "merge needs to know the base branch it may merge into"
assert_contains "$DRIVER_OUT" "merge_policy.base" "the error says how to set the base branch"
merge_run pm_ci_other "$MP_BASIC"
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .post_merge.target_ci.status)" "a CI result for another commit does not verify the merge"
MP_DEPLOY="$(jq -cn --arg d "test -f $DRIVER_TMP/deployed-\$FAKE_SCENARIO" '{base:"main", verify:["target_ci","deploy","smoke"], deploy_check_cmd:$d, deploy_timeout_minutes:30, smoke_cmd:"test \"$HM_MERGE_COMMIT\" = 1111111111111111111111111111111111111111"}')"
merge_run pm_deploy "$MP_DEPLOY"
assert_eq "30:incomplete:post_merge_verify" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "a deploy not observed yet leaves the run resumable"
assert_contains "$DRIVER_OUT" "not deployed yet" "the wait says the deploy is not observed"
touch "$DRIVER_TMP/deployed-pm_deploy"
driver resume
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^post_merge_verify ' "$FAKE_LOG")" "resume finishes deploy and smoke without rerunning the passed CI step"
assert_contains "$DRIVER_OUT" "target_ci passed, deploy passed, smoke passed" "every post-merge check is reported"
merge_run pm_deploy_late "$MP_DEPLOY"
jq '.merge.merged_epoch -= 3600' "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)" >"$DRIVER_TMP/s.json" \
  && mv "$DRIVER_TMP/s.json" "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a deploy not observed within the timeout goes to a person"
assert_contains "$DRIVER_OUT" "was not observed as deployed within 30 minutes" "the timeout is named"
merge_run pm_smoke_fail '{"verify":["smoke"],"smoke_cmd":"false","base":"main"}'
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a smoke check that fails twice goes to a person"
assert_contains "$DRIVER_OUT" "the smoke check failed twice" "the smoke failure is named"
# 모니터링 재발 확인: 관찰 창이 길어 러너는 고친 에러를 /autofix 추적에 올리는 데까지 한다.
monitor_run() { # scenario [--monitor-error 파일] → monitor 설정·project_id가 있는 저장소에서 단계 deploy·verify monitor로 실행한다
  local scenario="$1"
  shift
  new_driver_repo "$scenario"
  with_policy pr-only auto
  as_host_repo github.com/acme/app
  jq --arg local "${MONITOR_LOCAL:-}" '.project_id = "acme-app" | .monitor = {provider: "command", command: "bin/errors", window_hours: 168}
    | .merge_policy = {verify: ["monitor", "target_ci"], base: "main"} | if $local == "1" then del(.monitor) else . end' \
    "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  merge_config '{"verify":["monitor"]}'
  cp "$MR_DATA/config" "$DRIVER_TMP/data/config"
  DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "fix the crash" "$@"
}
mkdir -p "$DRIVER_TMP/plugin/scripts"
cat >"$DRIVER_TMP/plugin/scripts/autofix-auto.sh" <<'EOF'
printf 'autofix %s\n' "$*" >>"$FAKE_LOG"
[[ "$FAKE_SCENARIO" != pm_monitor_fail ]] || { echo "state lock failed" >&2; exit 1; }
EOF
printf '%s\n' '{"signature":"sig-42","title":"NullPointerException in Checkout","count":12,"meta":{"id":"42"}}' >"$DRIVER_TMP/monitor-error.json"
export HM_PLUGIN_ROOT="$DRIVER_TMP/plugin"
monitor_run pm_monitor --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "the monitor step finishes the run once the error is tracked"
assert_contains "$(<"$FAKE_LOG")" "autofix track --project acme-app --candidate {\"window_hours\":168,\"signature\":\"sig-42\"" "the fixed error is registered with /autofix, with the manifest's observation window"
assert_contains "$(<"$FAKE_LOG")" "--pr https://github.com/acme/app/pull/7" "the tracked pull request is the merged one"
assert_eq "target_ci,monitor" "$(run_state '.post_merge | keys_unsorted | join(",")')" "post-merge checks run in the fixed order whatever order the manifest lists"
assert_contains "$DRIVER_OUT" "monitor tracked (recurrence of sig-42 is handed to /autofix" "done says the recurrence check continues in /autofix"
monitor_run pm_monitor_none
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^autofix ' "$FAKE_LOG" || true)" "a run without a monitoring error has nothing to track"
assert_contains "$DRIVER_OUT" "monitor skipped (no monitoring error was given" "the skip is reported, not hidden"
monitor_run pm_monitor_fail --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a failed registration goes to a person"
assert_contains "$(run_state '.findings[1]')" "register the error by hand: <ai-harness plugin>/scripts/autofix-auto.sh track --project acme-app --candidate" "the person gets the track command, not rollback advice"
# 개인 로컬 monitor 설정(~/.ai-harness/autofix/monitors/<project_id>.json)만 있어도 시작하고, 그 관찰 창을 쓴다.
mkdir -p "$MR_DATA/autofix/monitors"
printf '%s\n' '{"provider":"command","command":"bin/errors","window_hours":48}' >"$MR_DATA/autofix/monitors/acme-app.json"
MONITOR_LOCAL=1 monitor_run pm_monitor_local --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a local monitor file satisfies verify monitor"
assert_contains "$(<"$FAKE_LOG")" "autofix track --project acme-app --candidate {\"window_hours\":48," "the local file's observation window is used"
printf 'not json\n' >"$MR_DATA/autofix/monitors/acme-app.json"
monitor_run pm_monitor_local_bad --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "2" "$DRIVER_RC" "a broken local monitor file does not start, even with a manifest monitor"
assert_contains "$DRIVER_OUT" "autofix/monitors/acme-app.json" "the error names the broken local file"
find "$MR_DATA/autofix/monitors/acme-app.json" -delete
unset HM_PLUGIN_ROOT
printf '%s\n' '{"title":"no signature"}' >"$DRIVER_TMP/bad-error.json"
monitor_run pm_monitor_bad --monitor-error "$DRIVER_TMP/bad-error.json"
assert_eq "2" "$DRIVER_RC" "a monitoring error without a signature does not start"
cat "$DRIVER_TMP/monitor-error.json" "$DRIVER_TMP/monitor-error.json" >"$DRIVER_TMP/two-errors.json"
monitor_run pm_monitor_two --monitor-error "$DRIVER_TMP/two-errors.json"
assert_eq "2:no run" "$DRIVER_RC:$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*" -name state.json | grep -q . && echo run || echo "no run")" "several monitoring errors in one file are refused before a run is created"
merge_run pm_monitor_noconfig '{"verify":["monitor"],"base":"main"}'
assert_eq "2" "$DRIVER_RC" "verify monitor without the monitor settings does not start"
assert_contains "$DRIVER_OUT" "needs the monitor settings (/autofix setup)" "the error points at /autofix setup"
# merge 노드가 없는 옛 그래프는 병합하지 않고 PR까지로 끝낸다.
new_driver_repo merge_oldgraph
with_policy pr-only auto
as_host_repo github.com/acme/app
jq '.merge_policy = {base: "main"}' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.nodes.merge, .nodes.post_merge_verify) | .transitions |= map(select(.from != "merge" and .from != "post_merge_verify" and .to != "merge"))' \
  "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add -A && git -C "$DRIVER_REPO" commit -qm "old graph"
merge_config "$MP_BASIC"
cp "$MR_DATA/config" "$DRIVER_TMP/data/config"
DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "add feature"
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh ' "$FAKE_LOG" || true)" "a project graph without the merge node never merges"
assert_contains "$DRIVER_OUT" "the project graph has no merge node" "the outcome asks for a harness sync"
rm -f "$MR_DATA/config"
unset FAKE_PROTECTION
pass "merge node: host rules, repository facts, merge by the runner, post-merge checks"

# 병합이 호스트에서 확인돼도 러너는 worktree를 지우지 않는다(#454). 안전 조건(PR MERGED·깨끗함·미푸시 커밋 없음·중첩 clone 없음·링크된 worktree)만
# 판정해 state.json의 worktree_cleanup {eligible, reason, path, branch}과 progress 로그에 남기고, 정리는 사람이나 보드가 한다.
# orca 삭제 명령은 어느 경우에도 부르지 않는다 — 가짜 orca가 모든 호출을 기록하고, 작업 폴더·브랜치가 남았는지도 본다.
WTC_BIN="$DRIVER_TMP/wtc-bin"
mkdir -p "$WTC_BIN"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$*" >>"%s/orca.log"\n' "$DRIVER_TMP"
  printf 'printf "{\\"ok\\":true,\\"message\\":\\"removed\\"}\\n"\n'
} >"$WTC_BIN/orca"
chmod +x "$WTC_BIN/orca"
export ORCA_CLI_COMMAND="$WTC_BIN/orca"
wtc_run() { # scenario linked(1|"") [merge-settings-json] → 병합까지 끝낸 뒤 worktree_cleanup 판정을 본다
  : >"$DRIVER_TMP/orca.log"
  NEW_REPO_LINKED="$2" merge_run "$1" "${3:-$MP_BASIC}"
}
wtc_assert_kept() { # 라벨 — orca 호출 없음, 작업 폴더·브랜치 그대로
  assert_eq "" "$(<"$DRIVER_TMP/orca.log")" "$1: the runner never calls orca to remove anything"
  [[ -e "$DRIVER_REPO/.git" ]] || fail "$1: the work folder is still there"
  assert_eq "feat/add-feature" "$(git -C "$DRIVER_REPO" symbolic-ref --short HEAD)" "$1: the work branch is still checked out"
}
wtc_progress() { cat "$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")/progress.log"; }
# 링크된 worktree + MERGED·깨끗함·푸시됨 → eligible, 하지만 지우지 않는다.
wtc_run wtc_linked_ok 1
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "wtc: the linked-worktree run merges"
assert_eq "true:null:$DRIVER_REPO:feat/add-feature" "$(run_state '"\(.worktree_cleanup.eligible):\(.worktree_cleanup.reason):\(.worktree_cleanup.path):\(.worktree_cleanup.branch)"')" "a merged, clean, pushed linked worktree is recorded as eligible"
wtc_assert_kept "eligible linked worktree"
assert_contains "$(git -C "$DRIVER_MAIN" worktree list --porcelain)" "$DRIVER_REPO" "the eligible linked worktree is still registered"
assert_contains "$(wtc_progress)" "worktree cleanup" "the verdict is one progress line"
# 메인 체크아웃(링크된 worktree 아님)은 병합돼도 eligible=false. rev-parse --git-dir 상대경로 비교 버그를 잡는다.
wtc_run wtc_main ""
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "wtc: the main-checkout run merges"
assert_eq "false" "$(run_state '.worktree_cleanup.eligible')" "the main checkout is never eligible"
assert_contains "$(run_state '.worktree_cleanup.reason')" "not a removable linked worktree" "the main checkout reason says it is not a linked worktree"
assert_eq "$DRIVER_REPO" "$(run_state '.worktree_cleanup.path')" "the verdict records the checkout path"
wtc_assert_kept "main checkout"
# 커밋 안 한 변경 · 원격에 없는 커밋 · 병합 확인 실패는 eligible=false와 사유.
wtc_run wtc_dirty 1
assert_eq "0:done:false" "$DRIVER_RC:$(run_state .status):$(run_state '.worktree_cleanup.eligible')" "wtc: uncommitted changes make the worktree ineligible"
assert_contains "$(run_state '.worktree_cleanup.reason')" "working tree is not clean" "the dirty reason is recorded"
wtc_assert_kept "dirty worktree"
# 미푸시 커밋은 병합 뒤 검증(smoke) 명령이 남긴다 — 병합 확인 이후 HEAD가 원격에 없는 커밋을 갖게 되는 경우.
wtc_run wtc_unpushed 1 '{"verify":["smoke"],"smoke_cmd":"git -c user.email=t@t -c user.name=t commit -q --allow-empty -m late","base":"main"}'
assert_eq "0:done:false" "$DRIVER_RC:$(run_state .status):$(run_state '.worktree_cleanup.eligible')" "wtc: a commit absent from every remote makes the worktree ineligible"
assert_contains "$(run_state '.worktree_cleanup.reason')" "commits are absent from remotes" "the unpushed reason is recorded"
wtc_assert_kept "unpushed worktree"
wtc_run wtc_unmerged 1 '{"verify":["smoke"],"smoke_cmd":"touch '"$DRIVER_TMP"'/wtc_unmerged.log.reopen","base":"main"}'
assert_eq "0:done:false" "$DRIVER_RC:$(run_state .status):$(run_state '.worktree_cleanup.eligible')" "wtc: a pull request the host no longer reports as merged makes the worktree ineligible"
assert_contains "$(run_state '.worktree_cleanup.reason')" "merge is not confirmed" "the unmerged reason is recorded"
wtc_assert_kept "unmerged worktree"
unset ORCA_CLI_COMMAND
pass "merge cleanup judges worktree eligibility without removing anything"

# claude 세션이 result 이벤트를 두 번 내도(#487) 노드 .out은 JSON 문서 하나여야 한다. 둘이면 post-merge target_ci status가 "passed\npassed"가 되어 사람에게 멈춘다.
export FAKE_PROTECTION=classic
FAKE_CLAUDE_RESULTS=2 MERGE_RUNTIME=claude merge_run pm_claude_dup_result "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a claude session that emits the result event twice still finishes the run"
assert_eq "passed" "$(run_state .post_merge.target_ci.status)" "post-merge target_ci status is one word, not one per result event"
PM_RUN_DIR="$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")"
assert_eq "1" "$(jq -n --slurpfile r "$PM_RUN_DIR/post-merge-ci.out" '$r | length')" "the post-merge CI node output is a single JSON document"
PM_REMOTE_OUTS="$(find "$PM_RUN_DIR" -maxdepth 1 -name 'remote-ci-[0-9]*.out')"
[[ -n "$PM_REMOTE_OUTS" ]] || fail "the remote CI node wrote no output"
while IFS= read -r f; do
  assert_eq "1" "$(jq -n --slurpfile r "$f" '$r | length')" "the remote CI node output is a single JSON document ($(basename "$f"))"
done <<<"$PM_REMOTE_OUTS"
assert_eq "remote_ci,merge,post_merge_verify" "$(run_state '[.history[] | select(.from | IN("remote_ci", "merge", "post_merge_verify")) | .from] | join(",")')" "the run goes through remote CI, merge and post-merge verification"
unset FAKE_PROTECTION
pass "claude result emitted twice: node outputs stay a single document and post-merge target_ci passes"

# 호스트가 충돌 여부를 아직 계산 중이면(mergeable UNKNOWN) 곧바로 incomplete로 끝내지 않고 몇 번 다시 물어본다(#542). resume 없이 병합돼야 한다.
export FAKE_PROTECTION=classic HM_MERGE_PENDING_POLL_SECONDS=0
rm -f "$DRIVER_TMP/merge_pending_ok.log.views"
FAKE_UNKNOWN_N=2 merge_run merge_pending_ok "$MP_BASIC"
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a conflict check the host finishes after two asks merges without resume"
[[ "$(<"$FAKE_LOG.views")" -ge 3 ]] || fail "the runner asked the host again (views=$(<"$FAKE_LOG.views"))"
assert_contains "$(wtc_progress)" "has not finished checking for conflicts" "the wait for the conflict check is logged"
# 재시도 한도(HM_MERGE_PENDING_RETRIES)까지 기다려도 UNKNOWN이면 기존처럼 incomplete 30이다: 처음 한 번 + 재시도 3번 = 4번만 묻는다.
rm -f "$DRIVER_TMP/merge_pending_limit.log.views"
FAKE_UNKNOWN_N=99 HM_MERGE_PENDING_RETRIES=3 merge_run merge_pending_limit "$MP_BASIC"
assert_eq "30:incomplete:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a conflict check that never finishes leaves the run resumable without merging"
assert_contains "$DRIVER_OUT" "the host has not finished checking for conflicts" "the incomplete message names the pending conflict check"
assert_eq "4" "$(<"$FAKE_LOG.views")" "the runner asks the host once plus the retry limit"
assert_contains "$(wtc_progress)" "has not finished checking for conflicts on" "each wait names the pull request"
unset FAKE_PROTECTION HM_MERGE_PENDING_POLL_SECONDS
pass "merge waits for the host's conflict check and gives up after the retry limit"

# 병합 뒤 target_ci 개인 설정 HM_TARGET_CI(wait 기본|notify, 저장소별 HM_TARGET_CI_REPOS가 우선). (#557)
# notify는 한 번만 읽고, 진행 중이면 분리 감시(watch-target-ci)를 띄운 뒤 done으로 끝난다. 감시는 실패를 ALERT·.alerts·데스크톱 알림으로 남긴다.
export FAKE_PROTECTION=classic HM_DESKTOP_NOTIFY=0
NOTIFY_BIN="$DRIVER_TMP/notify-bin"
NOTIFY_LOG="$DRIVER_TMP/notify.log"
mkdir -p "$NOTIFY_BIN"
for notifier in osascript notify-send; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >>%q\n' "$notifier" "$NOTIFY_LOG" >"$NOTIFY_BIN/$notifier"
  chmod +x "$NOTIFY_BIN/$notifier"
done
tci_run() { # scenario [config-line] → 단계 merge, target_ci만 검증하는 런
  new_driver_repo "$1"
  with_policy pr-only auto
  as_host_repo github.com/acme/app
  jq '.merge_policy = {"verify":["target_ci"],"base":"main"}' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" \
    && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  printf 'HM_APPROVAL=auto\nHM_DELIVERY_LEVEL=merge\n%s\n' "${2:-}" >"$MR_DATA/config"
  DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "add feature"
}
tci_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }

# B1: 설정이 없으면 wait — 지금처럼 기다리고, 끝까지 진행 중이면 incomplete로 resume을 기다린다.
tci_run pm_tci_wait
assert_eq "0:done:wait:default" "$DRIVER_RC:$(run_state .status):$(run_state .policy.merge.target_ci):$(run_state .policy.merge.target_ci_source)" "target CI waits by default"
FAKE_TCI_WATCH=pending tci_run pm_tci_wait_pending "HM_TARGET_CI=wait"
assert_eq "30:incomplete:post_merge_verify" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "wait leaves a still-running merge CI resumable"
assert_eq "null" "$(run_state '.post_merge.target_ci.watcher // null')" "wait starts no watcher"
pass "HM_TARGET_CI wait keeps waiting for the merge commit CI"

# B2: notify에서 한 번 읽은 결과가 진행 중이면 tracked로 두고 감시를 띄운 뒤 done. 감시는 끝나면 결과를 상태에 남긴다.
FAKE_TCI_ONCE=pending FAKE_TCI_WATCH=passed tci_run pm_tci_notify "HM_TARGET_CI=notify"
assert_eq "0:done:notify:HM_TARGET_CI" "$DRIVER_RC:$(run_state .status):$(run_state .policy.merge.target_ci):$(run_state .policy.merge.target_ci_source)" "notify finishes the run while the merge CI is still running"
assert_eq "tracked" "$(run_state .post_merge.target_ci.status)" "the pending merge CI is tracked"
[[ "$(run_state '.post_merge.target_ci.watcher.pid')" =~ ^[0-9]+$ ]] || fail "the watcher pid is recorded (actual=$(run_state '.post_merge.target_ci.watcher.pid'))"
assert_contains "$(<"$(tci_dir)/post-merge-ci.prompt")" "Do not wait" "the notify read is told not to wait"
assert_contains "$DRIVER_OUT" "target_ci tracked" "done reports the tracked merge CI"
for _ in $(seq 1 100); do
  [[ "$(run_state '.post_merge.target_ci.watched_at // ""')" == "" ]] || break
  sleep 0.2
done
assert_eq "passed:done:0" "$(run_state '"\(.post_merge.target_ci.status):\(.status):\(.alerts // [] | length)"')" "the watcher records a passing merge CI without an alert and leaves the run done"
grep -q "ALERT:" "$(tci_dir)/progress.log" && fail "a passing merge CI raises no alert"
pass "HM_TARGET_CI notify tracks a running merge CI with a detached watcher"

# B3: notify에서 한 번 읽은 결과가 실패면 지금처럼 사람에게 넘기고 되돌리기 안내를 붙인다.
FAKE_TCI_ONCE=failed tci_run pm_tci_notify_fail "HM_TARGET_CI=notify"
assert_eq "20:user_decision:failed" "$DRIVER_RC:$(run_state .status):$(run_state .post_merge.target_ci.status)" "a failed merge CI read once goes to a person"
assert_contains "$(run_state '.findings | join(" ")')" "git revert" "the failure carries rollback instructions"
assert_eq "null" "$(run_state '.post_merge.target_ci.watcher // null')" "an observed failure starts no watcher"
pass "HM_TARGET_CI notify hands an observed failure to a person"

# B4: 분리 감시를 직접 실행한다. 실패는 ALERT·.alerts·데스크톱 알림(HM_DESKTOP_NOTIFY=0이면 끔), 런의 status는 그대로다.
tci_run pm_tci_watch
TCI_RUN_ID="$(run_state .run_id)"
: >"$NOTIFY_LOG"
FAKE_TCI_WATCH=failed PATH="$NOTIFY_BIN:$PATH" driver watch-target-ci --run "$TCI_RUN_ID"
assert_eq "0:done:failed:1" "$DRIVER_RC:$(run_state .status):$(run_state .post_merge.target_ci.status):$(run_state '.alerts | length')" "the watcher records the failure and an alert without changing the run status"
assert_contains "$(<"$(tci_dir)/progress.log")" "ALERT: CI on main for merge commit 1111111111111111111111111111111111111111 failed" "the failure is an ALERT line in progress.log"
assert_contains "$(run_state '.alerts[0].rollback_hint')" "git revert" "the alert carries rollback instructions"
assert_eq "" "$(cat "$NOTIFY_LOG")" "HM_DESKTOP_NOTIFY=0 sends no desktop notification"
driver status --run "$TCI_RUN_ID"
assert_contains "$DRIVER_OUT" "ALERT " "status shows the alert"
FAKE_TCI_WATCH=failed HM_DESKTOP_NOTIFY=1 PATH="$NOTIFY_BIN:$PATH" driver watch-target-ci --run "$TCI_RUN_ID"
assert_eq "0:2" "$DRIVER_RC:$(run_state '.alerts | length')" "a second failure adds another alert"
assert_contains "$(cat "$NOTIFY_LOG")" "merge commit 1111111111111111111111111111111111111111" "a desktop notification is sent when allowed"
FAKE_TCI_WATCH=passed PATH="$NOTIFY_BIN:$PATH" driver watch-target-ci --run "$TCI_RUN_ID"
assert_eq "0:passed:2:done" "$DRIVER_RC:$(run_state .post_merge.target_ci.status):$(run_state '.alerts | length'):$(run_state .status)" "a passing result records passed without an alert"
pass "watch-target-ci alerts on a failed merge CI and leaves the finished run as it was"

# B5: 저장소별 설정이 전체 설정보다 우선하고, 잘못된 값은 start를 막는다.
FAKE_TCI_ONCE=passed tci_run pm_tci_repos "HM_TARGET_CI=wait
HM_TARGET_CI_REPOS=repo-pm_tci_repos=notify"
assert_eq "notify:HM_TARGET_CI_REPOS:repo-pm_tci_repos" "$(run_state .policy.merge.target_ci):$(run_state .policy.merge.target_ci_source)" "HM_TARGET_CI_REPOS wins over HM_TARGET_CI"
tci_run pm_tci_bogus "HM_TARGET_CI=bogus"
assert_eq "2" "$DRIVER_RC" "an unknown HM_TARGET_CI stops start"
assert_contains "$DRIVER_OUT" "HM_TARGET_CI in $MR_DATA/config is \"bogus\"; target CI must be wait or notify" "the error names the setting and the allowed values"
unset FAKE_PROTECTION HM_DESKTOP_NOTIFY
pass "HM_TARGET_CI_REPOS wins and an invalid HM_TARGET_CI is refused"

finish_tests
