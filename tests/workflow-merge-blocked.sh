#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 사람에게 넘기는 막힘 상태
# 실행: bash tests/run.sh workflow-merge-blocked
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
# 고를 수 없는 상태는 사람에게 넘긴다.
# 충돌만으로 막힌 경우(merge_conflict)는 sync_base가 base를 따라잡는다(tests/workflow-merge-sync.sh). 그 밖의 막힘은 sync하지 않는다.
for s in merge_changes:"a reviewer requested changes" merge_closed:"closed without merging" \
  merge_otherbase:"targets release, not the base branch main" merge_hostci_fail:"the host reports the checks on the head as failed"; do
  merge_run "${s%%:*}" "$MP_BASIC"
  assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "${s%%:*} goes to a person"
  assert_contains "$DRIVER_OUT" "merge blocked: " "${s%%:*} says the merge was blocked"
  assert_contains "$DRIVER_OUT" "${s#*:}" "${s%%:*} names the reason"
  assert_eq "0" "$(run_state '.base_syncs // [] | length')" "${s%%:*} does not sync the base"
done
assert_eq "0" "$(grep -c '^gh merge' "$DRIVER_TMP/merge_changes.log" || true)" "requested changes are never merged over"
unset FAKE_PROTECTION
pass "merge node: unmergeable states go to a person without syncing the base (blocked states)"

finish_tests
