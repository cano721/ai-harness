#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 병합 성공·승인 대기 후 resume, HM_TARGET_CI_REPOS 우선·잘못된 값
# 실행: bash tests/run.sh workflow-merge
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"
# shellcheck source=tests/lib-merge-tci.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge-tci.sh"

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
pass "merge node: merges by the runner and waits for a missing approval until resume"

# B5: 저장소별 설정이 전체 설정보다 우선하고, 잘못된 값은 start를 막는다.
FAKE_TCI_ONCE=passed tci_run pm_tci_repos "HM_TARGET_CI=wait
HM_TARGET_CI_REPOS=repo-pm_tci_repos=notify"
assert_eq "notify:HM_TARGET_CI_REPOS:repo-pm_tci_repos" "$(run_state .policy.merge.target_ci):$(run_state .policy.merge.target_ci_source)" "HM_TARGET_CI_REPOS wins over HM_TARGET_CI"
tci_run pm_tci_bogus "HM_TARGET_CI=bogus"
assert_eq "2" "$DRIVER_RC" "an unknown HM_TARGET_CI stops start"
assert_contains "$DRIVER_OUT" "HM_TARGET_CI in $MR_DATA/config is \"bogus\"; target CI must be wait or notify" "the error names the setting and the allowed values"
unset FAKE_PROTECTION HM_DESKTOP_NOTIFY
pass "HM_TARGET_CI_REPOS wins and an invalid HM_TARGET_CI is refused"

finish_tests
