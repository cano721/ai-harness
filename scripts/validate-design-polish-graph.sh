#!/usr/bin/env bash
# design-polish(기존 화면 품질 개선) 그래프의 계약을 검사한다. 러너가 노드·전이를 이 이름으로 실행하므로 바뀌면 실행이 깨진다.
#   - 측정(measure)은 읽기 전용 브라우저 노드, 진단·검토는 실행 디렉터리의 증거를 읽는 읽기 전용 노드
#   - 승인 전에는 쓰기 노드에 닿지 않는다
#   - 모든 수정(fix) 뒤에는 검증 → 다시 측정 → 검토, 검토 통과만 publish로 간다
#   - 측정 뒤 변경(review → verify)·검토 뒤 변경(publish → verify)을 검사·측정·검토로 되돌리는 전이가 있다
set -euo pipefail
graph_path="${1:-}"
[[ -n "$graph_path" && -f "$graph_path" ]] || { printf 'usage: %s <design-polish-graph.json>\n' "$0" >&2; exit 2; }
invalid() { printf 'invalid design-polish graph: %s\n' "$1" >&2; exit 1; }

jq -e '
  . as $g
  | $g.name == "design-polish" and $g.entry == "measure"
  and (["done", "fix_list", "user_decision"] | all(. as $t | $g.terminals | index($t)))
  and (["measure","diagnose","approval","fix","verify","review","publish","remote_ci","done","fix_list","user_decision"] | all(.[]; . as $n | $g.nodes | has($n)))
  and $g.nodes.measure.write == false and $g.nodes.measure.browser == true
  and $g.nodes.diagnose.write == false and $g.nodes.diagnose.reads_run == true
  and $g.nodes.review.write == false and $g.nodes.review.reads_run == true
  and $g.nodes.approval.write == false and $g.nodes.verify.write == false and $g.nodes.fix.write == true
  and (($g.limits.max_repair_attempts | type) == "number" and $g.limits.max_repair_attempts >= 1)
  and (($g.limits.audit_pass_score | type) == "number" and $g.limits.audit_pass_score > 0 and $g.limits.audit_pass_score <= 100)
' "$graph_path" >/dev/null || invalid "nodes, terminals, or limits"

for edge in 'measure diagnose baseline_measured' 'measure review remeasured' 'measure user_decision unmeasured' \
  'diagnose approval fix_list_ready' 'diagnose fix_list no_design_rules' 'diagnose done nothing_to_fix' \
  'approval diagnose brief_changed_or_not_approved' 'approval fix user_explicitly_approved' 'approval fix auto_approved_by_policy' \
  'fix verify -' 'fix user_decision fix_limit_reached' 'verify measure required_checks_pass' 'verify fix required_checks_fail' \
  'review publish polish_passed' 'review fix polish_failed' 'review verify changed_after_measure' \
  'publish remote_ci published_or_not_required' 'publish verify changed_after_review' 'publish user_decision publish_failed' \
  'remote_ci done remote_ci_passed_or_not_required' 'remote_ci fix remote_ci_failed' 'remote_ci user_decision remote_ci_unverified'; do
  read -r from to when <<<"$edge"
  [[ "$when" != - ]] || when=""
  jq -e --arg f "$from" --arg t "$to" --arg w "$when" 'any(.transitions[]; .from == $f and .to == $t and (.when // "") == $w)' "$graph_path" >/dev/null \
    || invalid "missing transition $from -> $to${when:+ ($when)}"
done

# 승인 전에 닿는 노드는 모두 읽기 전용이다. entry부터 따라가되 승인에서 나가는 전이와, 수정 뒤에만 지나는
# 재측정 전이(measure → review, remeasured)는 뺀다 — 첫 측정은 기준선이라 진단으로만 간다.
jq -e '
  . as $g
  | [$g.entry] | until(. as $seen | ([$g.transitions[] | select(.from as $f | $seen | index($f)) | select(.from != "approval" and .when != "remeasured") | .to] + $seen | unique) == ($seen | unique);
      . as $seen | [$g.transitions[] | select(.from as $f | $seen | index($f)) | select(.from != "approval" and .when != "remeasured") | .to] + $seen | unique)
  | all(.[]; $g.nodes[.].write == false)
' "$graph_path" >/dev/null || invalid "a write node is reachable before approval"

# 다른 경로로 publish·done에 가지 않는다: publish로 가는 전이는 검토 통과뿐이고, done은 원격 CI·병합 후 검증·고칠 것 없음만 보낸다.
jq -e '
  ([.transitions[] | select(.to == "publish")] | all(.from == "review" and .when == "polish_passed"))
  and ([.transitions[] | select(.to == "done") | .from] | all(IN("remote_ci", "post_merge_verify", "diagnose")))
  and ([.transitions[] | select(.from == "fix")] | all(.to == "verify" or .to == "user_decision"))
  and ([.transitions[] | select(.from == "verify")] | all(.to == "measure" or .to == "fix"))
  and ([.transitions[] | select(.to == "review")] | all(.from == "measure" and .when == "remeasured"))
  and ([.transitions[] | .from + " " + (.when // "")] | length == (unique | length))
' "$graph_path" >/dev/null || invalid "a transition skips verify, measure, or review"

printf 'design-polish graph is valid\n'
