#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — bug-fix 러너(verify 반복·무변경·화면)
# 실행: bash tests/run.sh workflow-runs-bugfix-verify
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 반복 실패·의존 산출물 실패 출력(workflow-feature의 것과 같은 모양)과 기본 병합 정책.
STALL_OUT="$DRIVER_TMP/stall-output"
mkdir -p "$STALL_OUT"
printf 'src/app.ts:42: error E12 at 2026-11-19T12:34:56 took 123ms\n' >"$STALL_OUT/same.txt"
printf "node_modules/antd/lib/input/Input.d.ts(3,5): error TS1005: ',' expected.\n" >"$STALL_OUT/tsc-dependency.txt"

# 버그 수정·변경 검토도 같은 러너가 실행한다. (#154)
run_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
bug_run() { # scenario [start args...] → 승인 뒤 resume까지
  new_driver_repo "$1"
  shift
  driver start --workflow bug-fix --runtime codex --request "total ignores tax" "$@"
  [[ "$DRIVER_RC" == 10 ]] || return 0
  say_in_claude "승인"
  driver resume
}
FAKE_CHECK="grep -q fixed feature.txt" bug_run bug_fixcheck
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failing verify goes to repair, then verify and review again"
assert_eq "fix;repair;review" "$(grep -E '^(fix|repair|review) ' "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "the failed check is repaired before review"
# verify 노드의 첫 실패(attempts 0)는 환경 오류로 확정되지 않으면 repair를 먼저 받는다. 같은 실패가 repair 뒤에도 반복될 때만 멈춘다.
FAKE_CHECK="cat '$STALL_OUT/same.txt'; false" bug_run bug_verify_stall
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a non-environment verify failure is repaired before the repeat stops it"
assert_eq "2" "$(grep -c '^repair ' "$FAKE_LOG")" "the first verify failure is not escalated without a repair"
FAKE_CHECK="cat '$STALL_OUT/tsc-dependency.txt'; false" bug_run bug_verify_dependency
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a confirmed dependency failure at verify goes to a person without a repair"
assert_eq "repair>user_decision" "$(run_state '.history | last | .from + ">" + .to')" "the environment decision follows the bug-fix graph's escalation edge"
bug_run bug_noop
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a bug fix without a change is not done"
bug_run bug_fix_noop
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a regression test alone does not count as a fix"
bug_run ui_bug
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a bug fix that changes a screen goes through ui_review"
assert_file "$(run_state .ui_review.evidence_dir)/default.png"
pass "resume compares the saved baseline before any agent runs (bug-fix verify, no-op, and screen)"

finish_tests
