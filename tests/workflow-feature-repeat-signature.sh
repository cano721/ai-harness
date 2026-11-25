#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 반복 실패 시그니처(feature)
# 실행: bash tests/run.sh workflow-feature-repeat-signature
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

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
pass "feature runner: repeated failure signatures stop the repair loop"

finish_tests
