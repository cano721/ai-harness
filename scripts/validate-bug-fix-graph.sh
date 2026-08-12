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
  and (["triage", "reproduce", "brief", "approval", "regression", "fix", "verify", "review", "repair", "done", "user_decision"] | all(.[]; . as $node | $graph.nodes | has($node)))
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
has_transition regression fix
has_transition fix verify
has_transition verify review required_checks_pass
has_transition review "done" no_blocking_findings
has_transition review repair blocking_findings
has_transition repair verify
has_transition repair user_decision same_root_cause_after_two_attempts_or_product_or_environment_decision

jq -e '
  (.nodes.approval.write == false)
  and (.nodes.regression.write == true)
  and (.nodes.fix.write == true)
  and (.nodes.repair.write == true)
  and (.invariants | index("No write-capable node is reachable before user_explicitly_approved."))
' "$graph_path" >/dev/null || {
  printf 'invalid bug-fix graph safety invariants\n' >&2
  exit 1
}

printf 'bug-fix graph is valid\n'
