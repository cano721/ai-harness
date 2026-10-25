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
  and (($g.limits.max_repair_attempts | type) == "number" and $g.limits.max_repair_attempts >= 1)
' "$graph_path" >/dev/null || { printf 'invalid review graph\n' >&2; exit 1; }
for edge in 'scope inspect' 'inspect classify' 'repair verify' 'verify re_review'; do
  read -r from to <<<"$edge"
  jq -e --arg from "$from" --arg to "$to" '.transitions[] | select(.from == $from and .to == $to)' "$graph_path" >/dev/null
done
jq -e '.transitions[] | select(.from == "classify" and .to == "done" and .when == "no_blocking_findings")' "$graph_path" >/dev/null
jq -e '.transitions[] | select(.from == "re_review" and .to == "repair" and .when == "blocking_findings")' "$graph_path" >/dev/null
if jq -e '.nodes | has("ui_review")' "$graph_path" >/dev/null; then
  for edge in 'classify ui_review no_blocking_findings_ui_affected' 're_review ui_review no_blocking_findings_ui_affected' \
    'ui_review done ui_verified' 'ui_review repair ui_issues_and_repair_authorized' 'ui_review user_decision ui_issues_need_user_decision_or_ui_unverified'; do
    read -r from to when <<<"$edge"
    jq -e --arg from "$from" --arg to "$to" --arg when "$when" '.transitions[] | select(.from == $from and .to == $to and .when == $when)' "$graph_path" >/dev/null
  done
  jq -e '.nodes.ui_review.write == false and .nodes.ui_review.browser == true and (.invariants | any(test("ui_review")))
    and ([.transitions[] | select(.from == "ui_review" and .to != "repair" and .to != "user_decision")] | all(.when == "ui_verified"))' "$graph_path" >/dev/null \
    || { printf 'invalid ui_review node\n' >&2; exit 1; }
fi
printf 'review graph is valid\n'
