#!/usr/bin/env bash
set -euo pipefail

graph_path="${1:-}"
[[ -n "$graph_path" ]] || {
  printf 'usage: %s <feature-delivery-graph.json>\n' "$0" >&2
  exit 2
}
[[ -f "$graph_path" ]] || {
  printf 'graph not found: %s\n' "$graph_path" >&2
  exit 2
}

jq -e '
  . as $graph
  | .version == 1
  and .entry == "discover"
  and (.terminals | index("done"))
  and (.terminals | index("user_decision"))
  and (["discover", "brief", "approval", "deliver", "review", "repair", "publish", "remote_ci", "done", "user_decision"] | all(.[]; . as $node | $graph.nodes | has($node)))
' "$graph_path" >/dev/null || {
  printf 'invalid feature-delivery graph nodes\n' >&2
  exit 1
}

has_transition() {
  local from="$1" to="$2" when="${3:-}"
  if [[ -n "$when" ]]; then
    jq -e --arg from "$from" --arg to "$to" --arg when "$when" \
      '.transitions[] | select(.from == $from and .to == $to and .when == $when)' "$graph_path" >/dev/null
  else
    jq -e --arg from "$from" --arg to "$to" \
      '.transitions[] | select(.from == $from and .to == $to)' "$graph_path" >/dev/null
  fi
}

has_transition discover brief
has_transition brief approval
has_transition approval deliver user_explicitly_approved
has_transition approval deliver auto_approved_by_policy
has_transition review publish no_blocking_findings
has_transition review repair blocking_findings
has_transition repair review required_checks_pass
has_transition repair user_decision repair_limit_reached_or_product_decision
has_transition publish remote_ci published_or_not_required
has_transition publish user_decision publish_failed
has_transition remote_ci "done" remote_ci_passed_or_not_required
has_transition remote_ci repair remote_ci_failed
has_transition remote_ci user_decision remote_ci_unverified

jq -e '
  (.nodes.approval.write == false)
  and (.nodes.deliver.write == true)
  and (.nodes.repair.write == true)
  and (.nodes.publish.write == true)
  and (.nodes.remote_ci.write == false)
  and (.invariants | any(startswith("No write-capable node is reachable before the current brief is approved")))
  and ((.limits.max_repair_attempts | type) == "number" and .limits.max_repair_attempts >= 1)
' "$graph_path" >/dev/null || {
  printf 'invalid feature-delivery graph safety invariants\n' >&2
  exit 1
}

printf 'feature-delivery graph is valid\n'
