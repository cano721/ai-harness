#!/usr/bin/env bash
set -euo pipefail
graph_path="${1:-}"
[[ -n "$graph_path" && -f "$graph_path" ]] || { printf 'usage: %s <ui-review-graph.json>\n' "$0" >&2; exit 2; }
jq -e '
  . as $g
  | $g.name == "ui-review" and $g.entry == "scope"
  and ($g.terminals | index("done")) and ($g.terminals | index("user_decision"))
  and (["scope","design_system","inspect","repair","verify","done","user_decision"] | all(.[]; . as $n | $g.nodes | has($n)))
  and $g.nodes.scope.write == false and $g.nodes.design_system.write == false
  and $g.nodes.inspect.write == false and $g.nodes.inspect.browser == true and $g.nodes.repair.write == true
  and ($g.invariants | index("A blocking finding cannot transition directly to done."))
  and ($g.invariants | any(startswith("A UI that could not be rendered or operated ends as ui_unverified")))
  and (($g.limits.max_repair_attempts | type) == "number" and $g.limits.max_repair_attempts >= 1)
  and ([$g.transitions[] | select(.from == "inspect" and .to == "done")] | all(.when == "ui_verified"))
' "$graph_path" >/dev/null || { printf 'invalid ui-review graph\n' >&2; exit 1; }
for edge in 'scope design_system' 'design_system inspect' 'inspect done ui_verified' 'inspect repair ui_issues_and_repair_authorized' \
  'inspect user_decision ui_unverified' 'repair verify' 'verify inspect required_checks_pass'; do
  read -r from to when <<<"$edge"
  jq -e --arg from "$from" --arg to "$to" --arg when "${when:-}" \
    '.transitions[] | select(.from == $from and .to == $to and ($when == "" or .when == $when))' "$graph_path" >/dev/null
done
printf 'ui-review graph is valid\n'
