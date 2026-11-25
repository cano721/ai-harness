#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 봇·해제·재검토 승인, draft, 원격 CI 없음, 무인 실행, 지원 안 하는 호스트
# 실행: bash tests/run.sh workflow-merge-approval
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
# 승인은 지금 head에 대한 것이고 작성자 본인이 아니어야 한다.
merge_run merge_bot "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "a bot's approval does not count"
merge_run merge_dismissed "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "a dismissed approval does not count"
merge_run merge_rereviewed "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a reviewer who requested changes and then approved counts as approving"
merge_run merge_draft "$MP_BASIC"
assert_contains "$DRIVER_RC:$DRIVER_OUT" "30:" "a draft pull request waits"
assert_contains "$DRIVER_OUT" "the pull request is a draft" "the draft condition is named"
# 원격 CI가 없다는 보고는 remote_ci 조건을 채우지 못한다.
merge_run merge_ci_none "$MP_BASIC"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "require remote_ci needs a passed remote CI, not 'no CI'"
# 무인 실행은 병합하지 않는다.
HM_INTERNAL_SESSION=1 merge_run merge_unattended "$MP_BASIC"
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh ' "$FAKE_LOG" || true)" "an unattended run never merges"
assert_contains "$DRIVER_OUT" "merge: not done — unattended run" "the outcome says the merge was left to a person"
# PR 호스트를 읽을 수 없는 URL이면 병합하지 않는다.
merge_run ok_unknown_host "$MP_BASIC"
assert_contains "$DRIVER_RC:$DRIVER_OUT" "20:" "an unsupported pull request host is not merged"
assert_contains "$DRIVER_OUT" "unsupported pull request host" "the reason names the host"
unset FAKE_PROTECTION
pass "merge node: bot, dismissed and re-reviewed approvals, draft, no CI, unattended and unsupported host (approval gates)"

finish_tests
