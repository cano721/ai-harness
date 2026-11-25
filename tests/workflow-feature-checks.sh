#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 최종 검사·반복 실패 시그니처(feature)
# 실행: bash tests/run.sh workflow-feature-checks
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 넓은 검사(final_checks)는 라운드마다 돌지 않고 리뷰가 깨끗해진 뒤 한 번 돈다. 실패하면 blocking으로 수리한다. (#462)
FINAL_LOG="$DRIVER_TMP/final-checks.log"
: >"$FINAL_LOG"
FAKE_CHECK="printf 'fast\\n' >>'$FINAL_LOG'" FAKE_FINAL_CHECK="printf 'final\\n' >>'$FINAL_LOG'" start_and_approve final_once
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a run with final checks reaches done"
assert_eq "fast;final" "$(paste -sd ';' "$FINAL_LOG")" "fast checks run before the review and the broad check runs once after it"
assert_eq "1:1" "$(run_state '"\(.checks | length):\(.final_checks | length)"')" "the approved final checks are kept apart from the per-round checks"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "final_checks" "the brief node is asked to split per-round and final checks"
: >"$FINAL_LOG"
FAKE_CHECK="printf 'fast\\n' >>'$FINAL_LOG'" FAKE_FINAL_CHECK="printf 'final\\n' >>'$FINAL_LOG'; grep -q fixed feature.txt" start_and_approve final_fails_once
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failing final check goes to repair like a blocking finding"
assert_eq "fast;final;final;fast" "$(paste -sd ';' "$FINAL_LOG")" "after repair the failed final check runs first and passing it on that tree is not repeated after the re-review"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "required check failed" "repair receives the final check failure"
# 넓은 검사가 파일을 만들면 그 변경은 리뷰를 받지 않았으므로 통과가 아니다 — 수리·재리뷰를 거친다.
FAKE_FINAL_CHECK="echo generated >side.txt" start_and_approve final_side_effect
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a final check that changes files goes through repair and review again"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "changed files that were not reviewed: side.txt" "repair is told which files the final checks changed"
# 넓은 검사가 checks와 겹치면 한 번만 둔다.
FAKE_FINAL_CHECK="true" start_and_approve final_duplicate
assert_eq "0:0" "$DRIVER_RC:$(run_state '.final_checks | length')" "a final check already in checks is not repeated"

# 같은 정규화 실패가 연속되면 수리를 더 반복하지 않고 그래프의 repair -> user_decision 전이로 사람에게 넘긴다.
# 검사 출력은 파일로 둬서 종료 사유의 시그니처가 로그에 찍힌 명령 문자열이 아니라 실패 출력에서 왔음을 확인한다.
STALL_OUT="$DRIVER_TMP/stall-output"
mkdir -p "$STALL_OUT"
printf 'src/app.ts:42: error E12 at 2026-11-19T12:34:56 took 123ms\n' >"$STALL_OUT/same.txt"
FAKE_CHECK="cat '$STALL_OUT/same.txt' >&2; false" start_and_approve repeat_failure_signature
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "two matching failed checks stop repair at the repeat limit"
assert_contains "$DRIVER_OUT" "src/app.ts:<n>: error E<n> at <time> took <duration>" "the repeated failure decision names its normalized signature"
assert_eq "repair>user_decision" "$(run_state '.history | last | .from + ">" + .to')" "the stall goes to a person through the graph's repair escalation edge"

# 실행마다 바뀌는 객체 주소·출력 순서만 다른 실패는 같은 실패다.
ADDR_COUNT="$DRIVER_TMP/addr-count"
FAKE_CHECK="n=0; [[ -f '$ADDR_COUNT' ]] && n=\$(cat '$ADDR_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$ADDR_COUNT'; if [[ \$((n % 2)) == 1 ]]; then printf 'FAILED tests/test_order.py::test_total - assert <app.Order object at 0x7f8a3c10b2e0> == 110\\nFAILED tests/test_order.py::test_tax - assert 0 == 10\\n'; else printf 'FAILED tests/test_order.py::test_tax - assert 0 == 10\\nFAILED tests/test_order.py::test_total - assert <app.Order object at 0x10c4d2a90> == 110\\n'; fi; false" start_and_approve address_noise_repeat
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "object addresses and output order do not hide a repeated failure"

# 핵심 오류가 달라지면 이전 실패와 같은 반복으로 세지 않는다.
DIFFERENT_FAILURE_COUNT="$DRIVER_TMP/different-failure-count"
FAKE_CHECK="n=0; [[ -f '$DIFFERENT_FAILURE_COUNT' ]] && n=\$(cat '$DIFFERENT_FAILURE_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$DIFFERENT_FAILURE_COUNT'; case \"\$n\" in 1) printf 'src/app.ts:1: error first\\n' >&2 ;; 2) printf 'src/app.ts:2: error second\\n' >&2 ;; *) printf 'src/app.ts:3: error third\\n' >&2 ;; esac; false" start_and_approve different_failure_signature
assert_eq "20:user_decision:3" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a changed failure gets another repair before a repeated new failure stops it"

# 실패한 테스트가 달라도 빌드 도구의 꼬리 요약줄은 같다. 요약줄이 아니라 실패 위치로 시그니처를 만들어 진전하는 수리를 막지 않는다.
gradle_failure() { # test-name line → Gradle 테스트 실패 출력
  printf '%s() FAILED\n    org.opentest4j.AssertionFailedError at %s.java:%s\n\n3 tests completed, 1 failed\n\nFAILURE: Build failed with an exception.\n\n* What went wrong:\nExecution failed for task '"'"':test'"'"'.\n> There were failing tests. See the report at: file:///home/u/proj/build/reports/tests/test/index.html\n\nBUILD FAILED in 4s\n' "$1" "$1" "$2"
}
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

pass "feature runner: final checks and repeated failure signatures"
finish_tests
