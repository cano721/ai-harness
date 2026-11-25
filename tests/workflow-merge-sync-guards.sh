#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — sync_base 노드(#508): 동기화 뒤 검사 실패·다른 막힘·원격 CI 최종 관문
# 실행: bash tests/run.sh workflow-merge-sync-guards
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge-sync.sh"

# A5: 동기화 뒤 검사가 실패하면 push하지 않고 user_decision.
sync_repo merge_conflict_checkfail
base_commit broken.txt broken
FAKE_CHECK='test ! -f broken.txt' sync_start
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a check failing after the base sync goes to a person"
git --git-dir "$(sy_remote)" rev-parse -q --verify "refs/heads/feat/add-feature^2" >/dev/null && fail "the failing sync was pushed"
assert_contains "$DRIVER_OUT" "test ! -f broken.txt" "the failed check is named"
pass "a check failure after the base sync is not pushed"

# A7: 충돌과 다른 막힘(변경 요청)이 같이 있으면 sync하지 않고 사람에게 넘긴다.
sync_repo merge_conflict_changes
base_commit base.txt base
sync_start
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state '.base_syncs // [] | length')" "a conflict with another blocker does not sync"
assert_contains "$DRIVER_OUT" "merge conflicts" "the conflict is named"
assert_contains "$DRIVER_OUT" "a reviewer requested changes" "the other blocker is named"
[[ "$(sync_path)" != *sync_base* ]] || fail "sync_base ran although another blocker was present"
pass "a conflict together with another blocker goes to a person"

# 원격 CI가 최종 관문인 런(.policy.final_gate == remote_ci)에서 sync_base는 checks만 다시 돌린다.
# push한 merge 커밋은 remote_ci를 다시 거치므로 로컬 final_checks는 돌지 않는다. (#557)
sync_repo merge_conflict_remote_gate
mkdir -p "$DRIVER_REPO/.github/workflows"
printf 'on: push\n' >"$DRIVER_REPO/.github/workflows/test.yml"
git -C "$DRIVER_REPO" add .github && git -C "$DRIVER_REPO" commit -qm ci
git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/main
GATE_SYNC_LOG="$DRIVER_TMP/remote-gate-sync.log"
: >"$GATE_SYNC_LOG"
base_commit base.txt base
FAKE_CHECK="printf 'C\\n' >>'$GATE_SYNC_LOG'" FAKE_FINAL_CHECK="printf 'F\\n' >>'$GATE_SYNC_LOG'" sync_start
assert_eq "0:done:1:remote_ci" "$DRIVER_RC:$(run_state .status):$(run_state '.base_syncs | length'):$(run_state .policy.final_gate)" "a remote-gated run syncs the base and merges"
assert_eq "0" "$(grep -c '^F$' "$GATE_SYNC_LOG" || true)" "neither the final gate nor sync_base runs the final checks locally"
[[ "$(grep -c '^C$' "$GATE_SYNC_LOG")" -ge 2 ]] || fail "sync_base runs the checks again (log=$(paste -sd ';' "$GATE_SYNC_LOG"))"
pass "sync_base runs only the checks when remote CI is the final gate"

finish_tests
