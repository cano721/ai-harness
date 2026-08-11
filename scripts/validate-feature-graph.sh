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
  and (["discover", "brief", "approval", "deliver", "review", "repair", "done", "user_decision"] | all(.[]; . as $node | $graph.nodes | has($node)))
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
has_transition review done no_blocking_findings
has_transition review repair blocking_findings
has_transition repair review required_checks_pass
has_transition repair user_decision same_root_cause_after_two_attempts_or_product_decision

jq -e '
  (.nodes.approval.write == false)
  and (.nodes.deliver.write == true)
  and (.nodes.repair.write == true)
  and (.invariants | index("No write-capable node is reachable before user_explicitly_approved."))
' "$graph_path" >/dev/null || {
  printf 'invalid feature-delivery graph safety invariants\n' >&2
  exit 1
}

printf 'feature-delivery graph is valid\n'
