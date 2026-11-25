#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — design-polish 러너(측정·선택·거부)
# 실행: bash tests/run.sh workflow-polish
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# design-polish: 기존 화면 품질 개선. 측정(브라우저 캡처·채점)과 독립 진단 → 사람이 고른 항목만 수정 → 검사·재측정·독립 검토.
# 통과는 러너가 측정 결과로 판정하고(고른 주요 항목 0·audit 기준·기준선보다 나빠진 축 없음), 측정·검토 뒤 바뀐 파일은 거부한다.
POLISH_GRAPH="$ROOT/templates/design-polish/references/design-polish-graph.json"
"$ROOT/scripts/validate-design-polish-graph.sh" "$POLISH_GRAPH" >/dev/null
jq '.transitions += [{"from":"diagnose","to":"fix","when":"skip_approval"}]' "$POLISH_GRAPH" >"$DRIVER_TMP/polish-bad.json"
if "$ROOT/scripts/validate-design-polish-graph.sh" "$DRIVER_TMP/polish-bad.json" >/dev/null 2>&1; then fail "a fix reachable before approval is rejected"; fi
jq '.transitions |= map(select(.from != "publish" or .when != "changed_after_review"))' "$POLISH_GRAPH" >"$DRIVER_TMP/polish-bad.json"
if "$ROOT/scripts/validate-design-polish-graph.sh" "$DRIVER_TMP/polish-bad.json" >/dev/null 2>&1; then fail "a graph without the after-review refusal is rejected"; fi
jq '.transitions += [{"from":"verify","to":"publish","when":"skip_review"}]' "$POLISH_GRAPH" >"$DRIVER_TMP/polish-bad.json"
if "$ROOT/scripts/validate-design-polish-graph.sh" "$DRIVER_TMP/polish-bad.json" >/dev/null 2>&1; then fail "publishing without measure and review is rejected"; fi
assert_eq "3" "$(jq -r '.limits.max_repair_attempts' "$POLISH_GRAPH")" "polish fixes at most three times before a person decides"

new_driver_repo polish_ok
driver start --workflow polish --runtime codex --request "보드 작업 현황 화면 전반적으로 다듬어줘"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "polish stops at the fix list for the person to choose"
assert_eq "measure workspace-write schema=yes net=yes add-dir=yes;diagnose read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "baseline measure renders in a browser and diagnose critiques read-only before any change"
assert_eq "true" "$(run_state '.checks == ["true"]')" "the project checks measure found are what the driver runs"
assert_contains "$DRIVER_OUT" "| [x] | P1 | major |" "major items are preselected"
assert_contains "$DRIVER_OUT" "| [ ] | P2 | minor |" "minor items are listed but not selected"
assert_contains "$DRIVER_OUT" "revise --select" "the list says how to choose other items"
assert_contains "$DRIVER_OUT" "design-audit 80/100" "the list shows the baseline score"
driver revise --select "p9"
assert_eq "2" "$DRIVER_RC" "an id outside the fix list is refused"
driver revise --select "P2, p1"
assert_eq "10:P1,P2" "$DRIVER_RC:$(run_state '.selected | join(",")')" "revise --select changes the selection without a model call"
assert_eq "2" "$(wc -l <"$FAKE_LOG" | tr -d ' ')" "selecting items runs no session"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an approved polish that passes the review is done"
assert_eq "fix;measure;review" "$(sed -n '3,5p' "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "fix is followed by a new measure and the review"
assert_eq "fix workspace-write schema=" "$(sed -n 3p "$FAKE_LOG")" "only fix writes"
assert_contains "$(<"$FAKE_LOG.fix.prompt")" "Test-first is not required" "polish does not force test-first for visual fixes"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "measure-baseline" "the reviewer compares with the baseline captures"
assert_contains "$DRIVER_OUT" "polished P1, P2; design-audit 80 -> 93" "done reports what was fixed and the score change"
assert_eq "verify" "$(run_state '[.history[] | select(.from == "fix") | .to] | first')" "every fix goes through the driver's checks"

# 무인(auto)은 주요 항목만 골라 근거를 남기고 끝까지 간다.
new_driver_repo polish_auto
printf 'HM_APPROVAL=auto\n' >"$DRIVER_TMP/data/config"
driver start --workflow polish --runtime codex --request "다듬어줘"
assert_eq "0:P1" "$DRIVER_RC:$(run_state '.selected | join(",")')" "auto approval selects only the major items"
assert_contains "$(<"$(dirname "$(find "$DRIVER_TMP/runs" -path "*repo-polish_auto-*" -name state.json | head -n 1)")/brief.md")" "심각도 major 항목만 골랐다" "auto records why it selected those items"

# 규칙 문서·기준 화면이 없으면 채점할 기준이 없다: 비평과 고칠 목록까지만 하고 아무것도 바꾸지 않는다.
new_driver_repo polish_norules
driver start --workflow polish --runtime codex --request "다듬어줘"
assert_eq "0:fix_list" "$DRIVER_RC:$(run_state .status)" "without design rules the run ends at the fix list"
assert_contains "$DRIVER_OUT" "/ai-harness:design-system-builder" "it points to creating the design rules"
[[ "$(grep -c '^fix ' "$FAKE_LOG" || true)" == 0 ]] || fail "nothing is fixed without design rules"

# 기준선보다 나빠진 축이 있으면 audit 총점이 기준을 넘어도 통과가 아니다. 한도(3)까지 고치고 사람에게 넘긴다.
new_driver_repo polish_axis_drop
driver start --workflow polish --runtime codex --request "다듬어줘"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .node)" "a polish that keeps lowering an axis ends with a person"
assert_eq "3" "$(grep -c '^fix ' "$FAKE_LOG")" "fix runs at most limits.max_repair_attempts times"
assert_contains "$(run_state '.findings | join(";")')" "axis E fell below the baseline: 15 -> 12" "the driver, not the reviewer, compares each axis with the baseline"

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
