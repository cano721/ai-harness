#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 개인 자동화 단계(호스트 브랜치 보호)
# 실행: bash tests/run.sh workflow-runs-delivery-host
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
pass "delivery level: personal stage, repository facts, host rules (host branch protection)"

finish_tests
