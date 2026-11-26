#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 한 번 실행에서 띄우는 jq 프로세스 수 상한(#640)
# 실행: bash tests/run.sh workflow-jq-budget
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 러너는 상태 파일·그래프를 읽고 쓸 때마다 jq를 띄운다. 대표 실행(workflow-feature의 ok 시나리오: start → 승인 → resume → done)에서
# 띄우는 jq 수가 다시 늘지 않게 상한을 둔다. PATH 앞의 래퍼가 호출마다 JQ_COUNT_LOG에 한 줄을 남기고 실제 jq를 exec한다.
# 센 값에는 러너가 띄운 가짜 CLI(tests/fixtures/driver의 codex)가 부르는 jq(4회)도 들어 있다. 영역 셸의 jq(say_in_claude·run_state)는 래퍼 밖에서 부른다.
# 기준값도 같은 방식으로 셌다: #640 전 merge-base에서 115회(러너 111 + 가짜 CLI 4). 상한은 그 50%(내림)인 57회다.
JQ_BUDGET=57
REAL_JQ="$(command -v jq)"
JQ_WRAP_DIR="$TEST_TMP/jq-count-bin"
mkdir -p "$JQ_WRAP_DIR"
cat >"$JQ_WRAP_DIR/jq" <<EOF
#!/bin/sh
printf 'jq\n' >>"\$JQ_COUNT_LOG"
exec '$REAL_JQ' "\$@"
EOF
chmod +x "$JQ_WRAP_DIR/jq"
export JQ_COUNT_LOG="$TEST_TMP/jq-count.log"
counted_driver() { local path="$PATH"; PATH="$JQ_WRAP_DIR:$PATH"; driver "$@"; PATH="$path"; }

new_driver_repo ok
: >"$JQ_COUNT_LOG"
counted_driver start --runtime codex --request "add feature"
JQ_START_RC="$DRIVER_RC"
JQ_START_CALLS="$(wc -l <"$JQ_COUNT_LOG" | tr -d ' ')"
say_in_claude "승인"
counted_driver resume
JQ_CALLS="$(wc -l <"$JQ_COUNT_LOG" | tr -d ' ')"
assert_eq "10:0:done" "$JQ_START_RC:$DRIVER_RC:$(run_state .status)" "the ok scenario still waits for approval, then reaches done"
[[ "$JQ_START_CALLS" -gt 0 ]] || fail "the jq wrapper counted no call (PATH wrapper not used)"
[[ "$JQ_CALLS" -le "$JQ_BUDGET" ]] || fail "runner jq calls over budget (expected<=$JQ_BUDGET actual=$JQ_CALLS)"
pass "runner ok scenario stays within the jq call budget"

finish_tests
