#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 개인 자동화 단계(단계별 병합·deploy)
# 실행: bash tests/run.sh workflow-runs-delivery
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

MP_BASIC='{"verify":["target_ci"],"base":"main"}'

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
pass "delivery level: personal stage, repository facts, host rules (levels pr, merge, deploy)"

# status 줄은 저장소 git_policy와 개인 단계를 나눠 보인다. 내부 .policy.git이 merge여도 저장소 값은 pr-only다. 병합 동작은 그대로다. (#534)
export FAKE_PROTECTION=classic
for dl_repo_git in pr-only merge; do
  delivery_run "dl_status_$dl_repo_git" "$dl_repo_git" "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
  assert_eq "0:done:1:merge" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .policy.git)" "repository $dl_repo_git with level merge still merges and keeps the internal policy merge"
  driver status
  assert_contains "$DRIVER_OUT" "git_policy pr-only" "status shows the repository git_policy pr-only for repository $dl_repo_git"
  assert_contains "$DRIVER_OUT" "delivery merge" "status shows the personal delivery level for repository $dl_repo_git"
  [[ "$DRIVER_OUT" != *"git_policy merge"* ]] || fail "status shows the internal merge as git_policy for repository $dl_repo_git: $DRIVER_OUT"
done
unset FAKE_PROTECTION
rm -f "$DL_DATA/config"
pass "status separates the repository git_policy from the personal delivery level"

finish_tests
