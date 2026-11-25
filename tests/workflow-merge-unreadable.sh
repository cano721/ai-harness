#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 읽을 수 없는 호스트 상태·다른 저장소 PR
# 실행: bash tests/run.sh workflow-merge-unreadable
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
for s in merge_headmoved:"is not the pushed and reviewed commit" merge_host_down:"cannot read the pull request state" merge_cmd_fail:"merging failed"; do
  merge_run "${s%%:*}" "$MP_BASIC"
  assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "${s%%:*} goes to a person"
  assert_contains "$DRIVER_OUT" "merge blocked: " "${s%%:*} says the merge was blocked"
  assert_contains "$DRIVER_OUT" "${s#*:}" "${s%%:*} names the reason"
  assert_eq "0" "$(run_state '.base_syncs // [] | length')" "${s%%:*} does not sync the base"
done
# 다른 저장소의 PR은 병합하지 않는다.
merge_run merge_otherrepo "$MP_BASIC" github.com/acme/other
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a pull request outside this repository is never merged"
assert_contains "$DRIVER_OUT" "is not in this repository" "the repository mismatch is named"
assert_eq "0" "$(run_state '.base_syncs // [] | length')" "a pull request outside this repository does not sync the base"
unset FAKE_PROTECTION
pass "merge node: head moved, unreadable host and failed merge go to a person; foreign pull requests are never merged (unreadable)"

finish_tests
