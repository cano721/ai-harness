#!/usr/bin/env bash
set -euo pipefail
graph_path="${1:-}"
[[ -n "$graph_path" && -f "$graph_path" ]] || { printf 'usage: %s <review-graph.json>\n' "$0" >&2; exit 2; }
jq -e '
  . as $g
  | $g.name == "change-review" and $g.entry == "scope"
  and ($g.terminals | index("done")) and ($g.terminals | index("user_decision"))
  and (["scope","inspect","classify","repair","verify","re_review","done","user_decision"] | all(.[]; . as $n | $g.nodes | has($n)))
  and $g.nodes.scope.write == false and $g.nodes.inspect.write == false and $g.nodes.repair.write == true
  and ($g.invariants | index("A blocking finding cannot transition directly to done."))
' "$graph_path" >/dev/null || { printf 'invalid review graph\n' >&2; exit 1; }
for edge in 'scope inspect' 'inspect classify' 'repair verify' 'verify re_review'; do
  read -r from to <<<"$edge"
  jq -e --arg from "$from" --arg to "$to" '.transitions[] | select(.from == $from and .to == $to)' "$graph_path" >/dev/null
done
jq -e '.transitions[] | select(.from == "classify" and .to == "done" and .when == "no_blocking_findings")' "$graph_path" >/dev/null
jq -e '.transitions[] | select(.from == "re_review" and .to == "repair" and .when == "blocking_findings")' "$graph_path" >/dev/null
printf 'review graph is valid\n'
