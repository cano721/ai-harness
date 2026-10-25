#!/usr/bin/env bash
set -euo pipefail

graph_path="${1:-}"
[[ -n "$graph_path" && -f "$graph_path" ]] || {
  printf 'usage: %s <bug-fix-graph.json>\n' "$0" >&2
  exit 2
}

jq -e '
  . as $graph
  | .version == 1
  and .name == "bug-fix"
  and .entry == "triage"
  and (.terminals | index("done"))
  and (.terminals | index("user_decision"))
  and (["triage", "reproduce", "brief", "approval", "regression", "fix", "verify", "review", "repair", "publish", "remote_ci", "done", "user_decision"] | all(.[]; . as $node | $graph.nodes | has($node)))
' "$graph_path" >/dev/null || {
  printf 'invalid bug-fix graph nodes\n' >&2
  exit 1
}

has_transition() {
  local from="$1" to="$2" when="${3:-}"
  if [[ -n "$when" ]]; then
    jq -e --arg from "$from" --arg to "$to" --arg when "$when" '.transitions[] | select(.from == $from and .to == $to and .when == $when)' "$graph_path" >/dev/null
  else
    jq -e --arg from "$from" --arg to "$to" '.transitions[] | select(.from == $from and .to == $to)' "$graph_path" >/dev/null
  fi
}

has_transition triage reproduce
has_transition reproduce brief reproduced_or_evidence_sufficient
has_transition reproduce user_decision cannot_reproduce_and_no_observation_plan
has_transition brief approval
has_transition approval regression user_explicitly_approved
has_transition approval regression auto_approved_by_policy
has_transition regression fix
has_transition fix verify
has_transition verify review required_checks_pass
has_transition review publish no_blocking_findings
has_transition review repair blocking_findings
has_transition repair verify
has_transition repair user_decision repair_limit_reached_or_product_or_environment_decision
has_transition publish remote_ci published_or_not_required
has_transition publish user_decision publish_failed
has_transition remote_ci "done" remote_ci_passed_or_not_required
has_transition remote_ci repair remote_ci_failed
has_transition remote_ci user_decision remote_ci_unverified
# ui_review는 선택 노드다. 있으면 실제 화면 검증을 건너뛰는 경로가 없어야 한다.
if jq -e '.nodes | has("ui_review")' "$graph_path" >/dev/null; then
  has_transition review ui_review no_blocking_findings_ui_affected
  has_transition ui_review publish ui_verified
  has_transition ui_review repair ui_issues
  has_transition ui_review user_decision ui_unverified
  jq -e '.nodes.ui_review.write == false and .nodes.ui_review.browser == true and (.invariants | any(test("ui_review")))
    and ([.transitions[] | select(.from == "ui_review" and .to != "repair" and .to != "user_decision")] | all(.when == "ui_verified" and .to == "publish"))
    and ([.transitions[] | select(.from == "ui_review") | .when] | length == (unique | length))' "$graph_path" >/dev/null || {
    printf 'invalid ui_review node\n' >&2
    exit 1
  }
fi

jq -e '
  (.nodes.approval.write == false)
  and (.nodes.regression.write == true)
  and (.nodes.fix.write == true)
  and (.nodes.repair.write == true)
  and (.nodes.remote_ci.write == false)
  and (.invariants | any(startswith("No write-capable node is reachable before the current brief is approved")))
  and ((.limits.max_repair_attempts | type) == "number" and .limits.max_repair_attempts >= 1)
' "$graph_path" >/dev/null || {
  printf 'invalid bug-fix graph safety invariants\n' >&2
  exit 1
}

printf 'bug-fix graph is valid\n'
