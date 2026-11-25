#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 병합 성공·승인 대기·현재 head/작성자/권한 승인 조건
# 실행: bash tests/run.sh workflow-merge
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
merge_run merge_ok "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "merge policy merges and verifies when every condition holds"
assert_contains "$(<"$FAKE_LOG")" "gh merge https://github.com/acme/app/pull/7 --squash --match-head-commit $(git -C "$DRIVER_REPO" rev-parse HEAD)" "the runner merges with the head pinned to the reviewed, pushed commit"
assert_contains "$(<"$FAKE_LOG")" "gh api repos/acme/app" "the merge method is read from the repository settings"
assert_eq "remote_ci,merge,post_merge_verify" "$(run_state '[.history[] | select(.from | IN("remote_ci", "merge", "post_merge_verify")) | .from] | join(",")')" "merge follows remote CI and is verified after"
assert_eq "1111111111111111111111111111111111111111:alice:passed" "$(run_state '"\(.merge.commit):\(.merge.approvals | join(",")):\(.post_merge.target_ci.status)"')" "the merge commit and the approvers are recorded"
assert_contains "$DRIVER_OUT" "merged: 111111111111 (squash); after merge: target_ci passed" "done reports the merge and the post-merge checks"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "Never merge (under merge the driver merges later" "the publish node still never merges by itself"
# 승인이 아직 없으면 병합하지 않고 기다리며, resume이 다시 본다.
merge_run merge_wait "$MP_BASIC"
assert_eq "30:incomplete:merge" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "missing human approval waits at merge"
assert_contains "$DRIVER_OUT" "human approval: 0 of 1 on the current head" "the wait names the unmet condition"
assert_eq "0" "$(grep -c '^gh merge' "$FAKE_LOG" || true)" "nothing is merged while a condition is unmet"
touch "$FAKE_LOG.approved"
driver resume
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG")" "resume merges once the approval arrives"
# 승인은 지금 head에 대한 것이고 작성자 본인이 아니어야 한다.
merge_run merge_stale "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval of an older commit does not count"
merge_run merge_self "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "the author's own approval does not count"
merge_run merge_outsider "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval from an account without write access does not count"
unset FAKE_PROTECTION
pass "merge node: host rules, repository facts, merge by the runner (approval conditions)"

finish_tests
