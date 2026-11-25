#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 실패 시그니처 진전 판정(feature)
# 실행: bash tests/run.sh workflow-feature-failure-signature
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-workflow-feature.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-workflow-feature.sh"

STALL_OUT="$DRIVER_TMP/stall-output"
mkdir -p "$STALL_OUT"
# 실패한 테스트가 달라도 빌드 도구의 꼬리 요약줄은 같다. 요약줄이 아니라 실패 위치로 시그니처를 만들어 진전하는 수리를 막지 않는다.
gradle_failure FooTest 10 >"$STALL_OUT/gradle-1.txt"
gradle_failure BarTest 99 >"$STALL_OUT/gradle-2.txt"
gradle_failure BazTest 7 >"$STALL_OUT/gradle-3.txt"
GRADLE_COUNT="$DRIVER_TMP/gradle-count"
FAKE_CHECK="n=0; [[ -f '$GRADLE_COUNT' ]] && n=\$(cat '$GRADLE_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$GRADLE_COUNT'; [[ \$n -ge 4 ]] && exit 0; cat '$STALL_OUT/gradle-'\$n'.txt'; exit 1" start_and_approve gradle_progress
assert_eq "0:done:3" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "different failing tests under the same build summary are progress, not a repeat"
# 테스트 이름 줄에는 오류 낱말이 없고, 실패가 많으면 바뀐 실패가 뒤쪽에 있다. 둘 다 시그니처에 들어가야 진전을 반복으로 세지 않는다.
jest_failure() { # test-name → jest 실패 출력
  printf 'FAIL src/total.test.ts\n  ● total › %s\n\n    expect(received).toBe(expected)\n\n    Expected: 110\n    Received: 100\n\n      at Object.<anonymous> (src/total.test.ts:12:5)\n\nTests:       1 failed, 3 passed, 4 total\n' "$1"
}
jest_failure "adds tax" >"$STALL_OUT/jest-1.txt"
jest_failure "rounds total" >"$STALL_OUT/jest-2.txt"
JEST_COUNT="$DRIVER_TMP/jest-count"
FAKE_CHECK="n=0; [[ -f '$JEST_COUNT' ]] && n=\$(cat '$JEST_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$JEST_COUNT'; [[ \$n -ge 3 ]] && exit 0; cat '$STALL_OUT/jest-'\$n'.txt'; exit 1" start_and_approve jest_progress
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a different failing test name is progress even without an error word on its line"
many_failures() { # count → Gradle 실패 count개
  local i
  for i in $(seq 1 "$1"); do printf 'Case%sTest > check() FAILED\n    org.opentest4j.AssertionFailedError at Case%sTest.java:5\n' "$i" "$i"; done
  printf '\nBUILD FAILED in 9s\n'
}
many_failures 7 >"$STALL_OUT/many-1.txt"
many_failures 6 >"$STALL_OUT/many-2.txt"
many_failures 5 >"$STALL_OUT/many-3.txt"
MANY_COUNT="$DRIVER_TMP/many-count"
FAKE_CHECK="n=0; [[ -f '$MANY_COUNT' ]] && n=\$(cat '$MANY_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$MANY_COUNT'; [[ \$n -ge 4 ]] && exit 0; cat '$STALL_OUT/many-'\$n'.txt'; exit 1" start_and_approve many_failures_progress
assert_eq "0:done:3" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "fixing the last of many failures is progress, not a repeat"
pass "feature runner: failure signatures tell progress from repeats"

finish_tests
