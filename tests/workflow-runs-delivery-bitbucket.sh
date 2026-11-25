#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 개인 자동화 단계(Bitbucket 브랜치 제한)
# 실행: bash tests/run.sh workflow-runs-delivery-bitbucket
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

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
pass "delivery level: personal stage, repository facts, host rules (Bitbucket branch restrictions)"

finish_tests
