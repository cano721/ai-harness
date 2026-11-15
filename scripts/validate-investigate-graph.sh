#!/usr/bin/env bash
# investigate 그래프 계약 검사. 조사는 코드를 바꾸지 않고, 원격 기준 코드 → 도메인 문서 → 재현·근거를 거쳐야 원인을 보고한다.
set -euo pipefail

graph_path="${1:-}"
[[ -n "$graph_path" && -f "$graph_path" ]] || {
  printf 'usage: %s <investigate-graph.json>\n' "$0" >&2
  exit 2
}

jq -e '
  . as $g
  | .version == 1
  and .name == "investigate"
  and .entry == "triage"
  and (.terminals | index("done"))
  and (.terminals | index("user_decision"))
  and (["triage", "baseline", "domain_docs", "reproduce", "report", "done", "user_decision"] | all(.[]; . as $n | $g.nodes | has($n)))
  and ([.nodes[] | select(.write != false)] | length == 0)
  and ([.nodes | keys[] | select(IN("regression", "fix", "deliver", "repair", "publish", "remote_ci", "merge"))] | length == 0)
  and (.invariants | any(startswith("The investigation never edits code")))
' "$graph_path" >/dev/null || {
  printf 'invalid investigate graph: every node must be read-only and code-changing nodes are not allowed\n' >&2
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

has_transition triage baseline
has_transition baseline domain_docs
has_transition domain_docs reproduce
has_transition reproduce report reproduced_or_evidence_sufficient
has_transition reproduce user_decision cannot_reproduce_and_no_observation_plan
has_transition report "done" no_code_fix_needed

# 단계를 건너뛰는 전이가 없어야 한다: 각 단계는 바로 앞 단계에서만 들어오고, 보고는 재현·근거가 있을 때만 쓴다.
jq -e '
  ([.transitions[] | select(.to == "baseline") | .from] | unique == ["triage"])
  and ([.transitions[] | select(.to == "domain_docs") | .from] | unique == ["baseline"])
  and ([.transitions[] | select(.to == "reproduce") | .from] | unique == ["domain_docs"])
  and ([.transitions[] | select(.to == "report")] | all(.from == "reproduce" and .when == "reproduced_or_evidence_sufficient"))
' "$graph_path" >/dev/null || {
  printf 'invalid investigate graph: a step is skipped\n' >&2
  exit 1
}

# handoff는 선택 노드다(수정이 필요할 때 fix-bug로 넘긴다). 있으면 보고 뒤에만 닿고 done으로 끝난다.
if jq -e '.nodes | has("handoff")' "$graph_path" >/dev/null; then
  has_transition report handoff code_fix_needed
  has_transition handoff "done"
  jq -e '[.transitions[] | select(.to == "handoff") | .from] | unique == ["report"]' "$graph_path" >/dev/null || {
    printf 'invalid investigate graph: handoff comes only after the report\n' >&2
    exit 1
  }
fi

printf 'investigate graph is valid\n'
