#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 개인 자동화 단계(예전 설정·무인·잘못된 값)
# 실행: bash tests/run.sh workflow-runs-delivery-legacy
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

MP_BASIC='{"verify":["target_ci"],"base":"main"}'

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

finish_tests
