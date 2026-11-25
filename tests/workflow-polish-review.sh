#!/usr/bin/env bash
# 회귀 테스트 — design-polish 러너 — 측정·검토 뒤 바뀐 파일은 검토·publish 앞에서 거부하고 다시 측정
# 실행: bash tests/run.sh workflow-polish-review
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 측정 뒤 바뀐 파일은 검토하지 않는다: 검사(verify)·측정을 다시 거친다.
new_driver_repo polish_bad_review_once
driver start --workflow polish --runtime codex --request "다듬어줘"
say_in_claude "승인"
driver resume
assert_eq "30:review" "$DRIVER_RC:$(run_state .node)" "an unreadable review stops at review"
echo 'tweak' >>"$DRIVER_REPO/screen.css"
driver resume
assert_eq "20:review" "$DRIVER_RC:$(run_state .node)" "a hand edit after the stop halts resume until it is accepted (#371)"
driver resume --accept-changes
assert_contains "$DRIVER_OUT" "refused: files changed after the measurement (screen.css)" "a change after the measurement is refused"
assert_eq "0" "$DRIVER_RC" "the changed tree is measured and reviewed again, then passes"
assert_eq "review;measure;review" "$(tail -n 3 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "the refused change is measured again before review"

# 검토 뒤 바뀐 파일은 내보내지 않는다: publish 앞에서 거부하고 다시 측정·검토한다.
STATE_FILE="$(find "$DRIVER_TMP/runs" -path "*repo-polish_bad_review_once-*" -name state.json | head -n 1)"
jq '.node = "publish" | .status = "running"' "$STATE_FILE" >"$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
echo 'after review' >>"$DRIVER_REPO/screen.css"
driver resume --accept-changes
assert_eq "20:publish" "$DRIVER_RC:$(run_state .node)" "a hand edit after a stop past review is not taken in, even with --accept-changes (#371)"
# 기준점 대조를 통과한 변경(기준점이 없는 이전 실행)도 publish 앞의 그래프 가드가 막는다.
jq 'del(.repo_baseline) | .status = "running"' "$STATE_FILE" >"$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
driver resume
assert_contains "$DRIVER_OUT" "refused: files changed after the review (screen.css)" "a change after the review is refused before publish"
assert_eq "publish:changed_after_review:verify" "$(run_state '[.history[] | select(.outcome == "changed_after_review")] | last | "\(.from):\(.outcome):\(.to)"')" "the refusal goes back through the checks"
assert_eq "review:changed_after_measure:verify" "$(run_state '[.history[] | select(.outcome == "changed_after_measure")] | last | "\(.from):\(.outcome):\(.to)"')" "a change after the measurement goes back through the checks"
assert_eq "0" "$DRIVER_RC" "after a new measure and review the run finishes"
pass "design-polish refuses files changed after the measurement or the review"

finish_tests
