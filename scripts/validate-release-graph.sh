#!/usr/bin/env bash
# release 그래프 계약 검사. 승인 전 쓰기 금지, merge commit만, 노트 없는 태그 금지, 기준 이동 시 재검증, force push·기준 브랜치 직접 push 금지를 본다.
set -euo pipefail

graph_path="${1:-}"
[[ -n "$graph_path" && -f "$graph_path" ]] || {
  printf 'usage: %s <release-graph.json>\n' "$0" >&2
  exit 2
}

jq -e '
  . as $g
  | .version == 1
  and .name == "release"
  and .entry == "plan"
  and (.terminals | index("done"))
  and (.terminals | index("user_decision"))
  and (["plan", "approval", "prepare", "revalidate", "publish", "remote_ci", "merge", "post_merge_verify", "release", "verify", "record", "sync", "done", "user_decision"]
    | all(.[]; . as $n | $g.nodes | has($n)))
  and (.nodes.plan.write == false and .nodes.approval.actor == "human")
  and ([.nodes | to_entries[] | select(.value.write == true) | .key] | sort == ["prepare", "publish", "revalidate"])
  and ([.nodes | keys[] | select(IN("deliver", "repair", "fix"))] | length == 0)
' "$graph_path" >/dev/null || {
  printf 'invalid release graph: required nodes are missing, or a node other than prepare, revalidate, and publish writes, or a repair node exists\n' >&2
  exit 1
}

for phrase in "No write-capable node is reachable before the current release plan is approved" \
  "The release is merged only with a merge commit" \
  "No tag or release is created without notes" \
  "When the source branch moves, the release branch catches up and the checks run again" \
  "Neither an agent nor the driver force-pushes or pushes to the source or base branch"; do
  jq -e --arg p "$phrase" '.invariants | any(startswith($p))' "$graph_path" >/dev/null || {
    printf 'invalid release graph: missing invariant "%s"\n' "$phrase" >&2
    exit 1
  }
done

has_transition() {
  local from="$1" to="$2" when="${3:-}"
  jq -e --arg from "$from" --arg to "$to" --arg when "$when" \
    '.transitions[] | select(.from == $from and .to == $to and (.when // "") == $when)' "$graph_path" >/dev/null || {
    printf 'invalid release graph: missing transition %s -> %s%s\n' "$from" "$to" "${when:+ ($when)}" >&2
    exit 1
  }
}

has_transition plan approval plan_valid
has_transition plan user_decision plan_invalid
has_transition approval prepare user_explicitly_approved
has_transition prepare publish prepared
has_transition prepare user_decision prepare_failed
has_transition publish revalidate source_moved
has_transition publish remote_ci published_or_not_required
has_transition revalidate publish caught_up
has_transition revalidate user_decision catch_up_failed
has_transition remote_ci "done" remote_ci_passed_or_not_required
has_transition remote_ci merge remote_ci_passed_and_merge_policy
has_transition remote_ci user_decision remote_ci_failed
has_transition merge revalidate source_moved
has_transition merge post_merge_verify merged
has_transition merge user_decision merge_blocked
has_transition post_merge_verify release post_merge_verified
has_transition release verify released_and_deploy_level
has_transition release record released
has_transition release user_decision release_failed
has_transition verify record verified_or_skipped
has_transition verify user_decision verify_failed
has_transition record sync recorded
has_transition record user_decision record_failed
has_transition sync "done"

# 승인 전 쓰기 노드 금지: prepare에는 approval에서만 들어오고, 태그·릴리스는 병합 뒤 검증을 지나야만 닿는다.
jq -e '
  ([.transitions[] | select(.to == "prepare") | .from] | unique == ["approval"])
  and ([.transitions[] | select(.to == "release") | .from] | unique == ["post_merge_verify"])
  and ([.transitions[] | select(.to == "merge") | .from] | unique == ["remote_ci"])
  and ([.transitions[] | select(.to == "revalidate") | .from] | unique == ["merge", "publish"])
' "$graph_path" >/dev/null || {
  printf 'invalid release graph: a write or release step is reachable without approval, merge, or post-merge checks\n' >&2
  exit 1
}

printf 'release graph is valid\n'
