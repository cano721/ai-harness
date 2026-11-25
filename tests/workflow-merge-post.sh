#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 병합 후 검증 실패·base 판정
# 실행: bash tests/run.sh workflow-merge-post
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
# 병합 후 검증: 타깃 CI → 배포 확인 → 스모크. 실패는 되돌리지 않고 사람에게, 배포 미관측은 기한까지 resume.
merge_run pm_ci_fail "$MP_BASIC"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a failed CI on the merge commit goes to a person"
assert_contains "$DRIVER_OUT" "post-merge check failed: CI on main for the merge commit" "the failure is reported as post-merge"
assert_contains "$(run_state '.findings[1]')" "git revert 1111111111111111111111111111111111111111" "rollback instructions are given, not executed"
# 배포 확인 명령을 실행할 수 없으면(127) 기한까지 기다리지 않는다.
merge_run pm_deploy_missing '{"base":"main","verify":["deploy"],"deploy_check_cmd":"no-such-deploy-check"}'
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a deploy check that cannot run is reported at once"
assert_contains "$DRIVER_OUT" "could not run (exit 127" "the broken command is named"
# base가 manifest에도 origin 기본 브랜치에도 없으면 시작하지 않는다.
merge_run merge_nobase '{}'
assert_eq "2" "$DRIVER_RC" "merge needs to know the base branch it may merge into"
assert_contains "$DRIVER_OUT" "merge_policy.base" "the error says how to set the base branch"
merge_run pm_ci_other "$MP_BASIC"
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .post_merge.target_ci.status)" "a CI result for another commit does not verify the merge"
unset FAKE_PROTECTION
pass "merge node: post-merge failures and base branch requirement (post-merge)"

finish_tests
