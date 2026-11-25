#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — sync_base 노드(#508): 충돌만 막힘·텍스트 충돌·한도·미해결
# 실행: bash tests/run.sh workflow-merge-sync
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge-sync.sh"

# A1: 충돌만으로 막히면 sync_base가 origin/main을 병합하고, 재검사·push 뒤 remote_ci → merge를 다시 거쳐 병합한다.
sync_repo merge_conflict
base_commit base.txt base
sync_start
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a merge blocked only by a base conflict syncs the base and merges"
assert_eq "remote_ci,merge,sync_base,remote_ci,merge,post_merge_verify" "$(sync_path)" "sync_base goes back through remote CI and merge"
assert_eq "1:driver:0" "$(run_state '"\(.base_syncs | length):\(.base_syncs[0].resolved_by):\(.base_syncs[0].conflicts | length)"')" "a clean base merge is recorded as done by the driver"
assert_eq "$(run_state '.base_syncs[0].from')" "$(remote_head '^1')" "the pushed merge commit's first parent is the reviewed head"
assert_eq "$(git --git-dir "$(sy_remote)" rev-parse refs/heads/main)" "$(remote_head '^2')" "the pushed merge commit's second parent is origin/main"
assert_eq "$(remote_head)" "$(run_state '.base_syncs[0].to')" "the record names the pushed commit"
assert_contains "$(<"$FAKE_LOG")" "gh merge https://github.com/acme/app/pull/7 --squash --match-head-commit $(remote_head)" "the merge is pinned to the synced head"
assert_eq "0" "$(grep -c '^sync_base' "$FAKE_LOG" || true)" "a clean base merge does not call an agent"
pass "a base conflict alone goes through sync_base, remote CI, and merge again"

# A2: 실제 텍스트 충돌은 sync_base 에이전트 세션이 풀고, 러너가 표식이 없음을 확인한 뒤 merge 커밋을 만든다.
sync_repo merge_conflict_text
base_commit feature.txt base
sync_start
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a text conflict resolved by the agent merges"
assert_eq "agent:feature.txt" "$(run_state '"\(.base_syncs[0].resolved_by):\(.base_syncs[0].conflicts | join(","))"')" "the record names the agent and the conflicted file"
assert_eq "" "$(git --git-dir "$(sy_remote)" grep -n -e '^<<<<<<<' -e '^>>>>>>>' "$(remote_head)" -- || true)" "the pushed commit has no conflict markers"
assert_contains "$(<"$FAKE_LOG.sync_base.prompt")" "feature.txt" "the sync_base session is told which files conflict"
assert_contains "$(<"$FAKE_LOG")" "sync_base workspace-write" "the sync_base session can write"
assert_eq "$(git --git-dir "$(sy_remote)" rev-parse refs/heads/main)" "$(remote_head '^2')" "the resolved merge commit merges origin/main"
pass "the sync_base agent resolves a text conflict and the driver commits the merge"

# A3: 반복 한도(limits.max_base_syncs)를 넘으면 user_decision이고 병합하지 않는다.
sync_repo merge_conflict_limit
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_base_syncs = 1' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -qm graph
git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/main
base_commit base.txt base
sync_start
assert_eq "20:user_decision:1" "$DRIVER_RC:$(run_state .status):$(run_state '.base_syncs | length')" "the base sync limit goes to a person"
assert_contains "$DRIVER_OUT" "base sync limit (1) reached" "the limit is named"
assert_eq "0" "$(grep -c '^gh merge' "$FAKE_LOG" || true)" "nothing is merged past the limit"
assert_eq "3" "$(jq -r '.limits.max_base_syncs' "$FEATURE_GRAPH")" "the template limit is 3"
pass "the base sync limit stops at user_decision"

# A4: 에이전트가 풀지 못한 충돌은 merge를 abort하고 push하지 않는다.
sync_repo merge_conflict_unresolved
base_commit feature.txt base
sync_start
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "an unresolved conflict goes to a person"
git -C "$DRIVER_REPO" rev-parse -q --verify MERGE_HEAD >/dev/null && fail "the unresolved merge was not aborted"
assert_eq "$(run_state .head)" "$(remote_head)" "nothing is pushed after an unresolved conflict"
assert_eq "$(run_state .head)" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "the local branch stays at the reviewed head"
assert_contains "$DRIVER_OUT" "feature.txt" "the unresolved file is named"
assert_eq "0" "$(run_state '.base_syncs // [] | length')" "an aborted sync is not recorded as done"
pass "an unresolved conflict aborts the merge and goes to a person"

finish_tests
