#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 환경 오류·실패 check만 재실행(feature)
# 실행: bash tests/run.sh workflow-feature-environment-failure
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-workflow-feature.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-workflow-feature.sh"

STALL_OUT="$DRIVER_TMP/stall-output"
mkdir -p "$STALL_OUT"
# 환경 오류는 실패 원인 위치가 변경 파일 밖 의존 산출물일 때만이다. 그때는 repair 없이 바로 사람에게 넘긴다.
printf "node_modules/antd/lib/input/Input.d.ts(3,5): error TS1005: ',' expected.\n" >"$STALL_OUT/tsc-dependency.txt"
FAKE_CHECK="cat '$STALL_OUT/tsc-dependency.txt'; false" start_and_approve dependency_output_failure
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failure located in a dependency outside the changes goes to a person without a repair"
[[ "$(<"$FAKE_LOG")" != *repair* ]] || fail "an environment failure is not repaired"
assert_contains "$DRIVER_OUT" "node_modules/antd/lib/input/Input.d.ts" "the environment decision names the dependency location"

# 보고서 경로(build/reports)와 스택 프레임(node_modules)은 원인 위치가 아니다. 이런 실패는 환경 오류로 넘기지 않고 고친다.
gradle_failure FooTest 10 >"$STALL_OUT/gradle-report.txt"
FAKE_CHECK="cat '$STALL_OUT/gradle-report.txt'; grep -q fixed feature.txt" start_and_approve gradle_report_path
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a Gradle report path is not a dependency failure"
printf 'FAIL src/total.test.ts\n  ● total › adds tax\n\n    expect(received).toBe(expected)\n\n      at Object.<anonymous> (src/total.test.ts:5:7)\n      at Promise.then.completed (node_modules/jest-circus/build/utils.js:298:28)\n' >"$STALL_OUT/jest-stack.txt"
FAKE_CHECK="cat '$STALL_OUT/jest-stack.txt'; grep -q fixed feature.txt" start_and_approve jest_stack_frame
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a node_modules stack frame is not a dependency failure"

# repair는 직전 실패 check만 다시 실행하고, 통과 뒤 전체 required set을 한 번 확정한다.
REPAIR_CHECK_LOG="$DRIVER_TMP/repair-checks.log"
FAKE_CHECK="printf 'A\\n' >>'$REPAIR_CHECK_LOG'; grep -q fixed feature.txt" start_and_approve repair_failed_checks_only --check "printf 'B\\n' >>'$REPAIR_CHECK_LOG'" --check "printf 'B\\n' >>'$REPAIR_CHECK_LOG'"
assert_eq "2" "$(grep -c '^A$' "$REPAIR_CHECK_LOG")" "the failed check runs for the initial failure and after repair; the final confirmation reuses that pass on the same tree"
assert_eq "2" "$(grep -c '^B$' "$REPAIR_CHECK_LOG")" "a passing duplicated command runs once initially and once in final confirmation"
pass "feature runner: environment failures go to a person and repair reruns only failed checks"

finish_tests
