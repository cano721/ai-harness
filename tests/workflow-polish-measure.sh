#!/usr/bin/env bash
# 회귀 테스트 — design-polish 러너 — 측정하지 못한 화면·측정의 저장소 쓰기·승인 전 검사·변경 없음·claude 런타임
# 실행: bash tests/run.sh workflow-polish-measure
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 화면을 띄우지 못하면 측정이 아니다. 측정 노드가 저장소에 쓰면 멈춘다.
new_driver_repo polish_unmeasured
driver start --workflow polish --runtime codex --request "다듬어줘"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .node)" "unmeasured screens go to a person"
new_driver_repo polish_measure_writes
driver start --workflow polish --runtime codex --request "다듬어줘"
assert_eq "40" "$DRIVER_RC" "measure may not write into the repository"
driver start --runtime codex --request "add feature" --select P1
assert_eq "2" "$DRIVER_RC" "--select belongs to polish only"
# 측정 세션이 고른 검사 명령은 승인 전에 실행하지 않는다.
new_driver_repo polish_ok
# shellcheck disable=SC2016  # 검사 명령 문자열이라 $PWD는 러너가 실행할 때 펼친다
FAKE_CHECK='touch "$PWD/ran-before-approval"' driver start --workflow polish --runtime codex --request "다듬어줘"
assert_eq "10" "$DRIVER_RC" "the run waits for the person"
[[ ! -e "$DRIVER_REPO/ran-before-approval" ]] || fail "checks found by measure do not run before approval"
driver revise --select P1 --feedback "x"
assert_eq "2" "$DRIVER_RC" "--select and --feedback are separate revisions"

# 고칠 것이 없으면 아무것도 바꾸지 않고 끝낸다.
new_driver_repo polish_nothing
driver start --workflow polish --runtime codex --request "다듬어줘"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "nothing to fix ends without a change"
assert_contains "$DRIVER_OUT" "nothing to polish" "the result says nothing needed polishing"

# claude 런타임: 진단·검토는 측정 증거 디렉터리만 읽는다(수정 쪽 요약·상태 파일은 열지 않는다).
new_driver_repo polish_claude
driver start --workflow polish --runtime claude --request "다듬어줘"
assert_eq "10" "$DRIVER_RC" "the claude runtime reaches the fix list"
assert_eq "measure-baseline;measure-baseline" "$(sed 's#.*/##' "$FAKE_LOG.adddirs" | paste -sd ';' -)" "measure writes its evidence directory and diagnose reads only that directory"
pass "design-polish graph runner measures, lets the person choose, and refuses unmeasured changes"

finish_tests
