#!/usr/bin/env bash
# 회귀 테스트 — design-polish 러너 — 그래프 검증기·승인 목록 선택·무인 승인·규칙 문서 없음·축 하락 수리 한도
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
pass "design-polish graph runner: validators, fix list selection, auto approval, missing rules, axis drop"

finish_tests
