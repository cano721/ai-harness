#!/usr/bin/env bash
# landing-page 그래프 계약 검사: 노드·전이·한도·불변식이 러너가 기대하는 모양인지 본다.
set -euo pipefail
graph_path="${1:-}"
[[ -n "$graph_path" && -f "$graph_path" ]] || { printf 'usage: %s <landing-page-graph.json>\n' "$0" >&2; exit 2; }
jq -e '
  . as $g
  | $g.name == "landing-page" and $g.entry == "brief"
  and ($g.terminals | index("done")) and ($g.terminals | index("user_decision"))
  and (["brief","references","reference_pick","direction","draft_pick","draft","preview","draft_review","build","measure","review","repair","done","user_decision"]
       | all(.[]; . as $n | $g.nodes | has($n)))
  and $g.nodes.measure.actor == "runner" and $g.nodes.review.actor == "reviewer"
  and $g.nodes.reference_pick.actor == "human" and $g.nodes.draft_pick.actor == "human"
  and ([$g.transitions[] | select(.to == "done")] | all(.from == "review" and (.when == "review_verified" or .when == "review_input_wait")))
  and ([$g.transitions[] | .from as $f | .when as $w | $g.nodes[$f].outcomes // [] | index($w)] | all(. != null))
  and ([$g.transitions[] | .to] | all(. as $t | $g.nodes | has($t)))
  and (($g.limits.max_reviews | type) == "number" and $g.limits.max_reviews >= 1)
  and ($g.review_checks.public_page | index("reference_fidelity")) and ($g.review_checks.public_page | index("flow"))
  and ($g.review_checks.public_page | index("try_it_usability")) and ($g.review_checks.public_page | index("craft"))
  and (($g.first_viewport_major // []) | index("template_look")) and (($g.first_viewport_major // []) | all(. as $c | $g.review_checks.public_page | index($c)))
  and ([$g.transitions[] | select(.to == "build")] | all(.from == "draft_review"))
  and $g.nodes.draft_review.actor == "reviewer" and ($g.review_checks.draft | index("template_look")) and ($g.review_checks.draft | index("craft"))
  and (["interactive", "unattended"] | all(. as $m | $g.references_min[$m] as $r
        | ($r | type) == "object"
        and (["tone","component","layout","interaction","competitor"] | all(. as $k | ($r.per_kind[$k] | type) == "number" and $r.per_kind[$k] >= 1))
        and ($r.interaction_video | type) == "number" and $r.interaction_video <= $r.per_kind.interaction
        and ($r.competitor_max | type) == "number" and $r.competitor_max >= $r.per_kind.competitor))
  and ($g.invariants | any(startswith("Measure outcomes come only from the measure script")))
  and ($g.invariants | any(startswith("Review outcomes are computed from the review JSON")))
' "$graph_path" >/dev/null || { printf 'invalid landing-page graph\n' >&2; exit 1; }
for edge in 'brief references brief_ready' 'draft preview drafted' 'preview draft_review previewed' 'draft_review build draft_pass' 'draft_review draft draft_redo' 'build measure built' 'measure review measured_pass' 'measure repair measured_fail' \
  'review repair review_issues' 'review user_decision review_limit_reached' 'review user_decision review_unverified' 'repair measure repaired'; do
  read -r from to when <<<"$edge"
  jq -e --arg from "$from" --arg to "$to" --arg when "$when" \
    '.transitions[] | select(.from == $from and .to == $to and .when == $when)' "$graph_path" >/dev/null \
    || { printf 'invalid landing-page graph: missing %s -> %s (%s)\n' "$from" "$to" "$when" >&2; exit 1; }
done
printf 'landing-page graph is valid\n'
