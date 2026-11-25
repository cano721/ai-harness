#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — bug-fix 그래프·예전 진입점·조사 보고서 시작
# 실행: bash tests/run.sh workflow-runs-bugfix-graph
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

BUG_FIX_GRAPH_TEMPLATE="$ROOT/templates/fix-bug/references/bug-fix-graph.json"
run_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
new_driver_repo bug_pr
with_policy pr-only auto
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state '.checkpoints | length')" "an auto-approved pr-only bug fix checkpoints regression and fix, then opens a PR"
assert_contains "$(git -C "$DRIVER_REPO" log --format=%s)" "wip(fix-bug): regression" "bug-fix checkpoints name the workflow"
new_driver_repo bug_legacy_verify
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.from == "verify" and .when == "required_checks_fail"))' "$BUG_FIX_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/bug-fix-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
FAKE_CHECK=false driver start --workflow bug-fix --runtime codex --request "total ignores tax"
say_in_claude "승인"
FAKE_CHECK=false driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a graph without the verify failure edge hands a failed check to a person"
assert_contains "$DRIVER_OUT" "no verify -> repair edge" "that outcome says how to fix it"
# 실행의 워크플로는 상태가 정한다. 다른 워크플로로 이어 가지 않는다.
driver status --workflow review --run "$(run_state .run_id)"
assert_eq "2" "$DRIVER_RC" "a run cannot be resumed as another workflow"
DRIVER_RC=0
DRIVER_OUT="$(HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER_SHIM" status --repo "$DRIVER_REPO" 2>&1)" || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "the old feature entry point does not resume a bug-fix run"
new_driver_repo shim_ok
DRIVER_RC=0
DRIVER_OUT="$(HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO=shim_ok PATH="$ROOT/tests/fixtures/driver:$PATH" \
  bash "$DRIVER_SHIM" start --runtime codex --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
assert_eq "10:feature" "$DRIVER_RC:$(run_state .workflow)" "the old entry point runs the feature workflow"
DRIVER_RC=0
HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER_SHIM" status --workflow review --repo "$DRIVER_REPO" >/dev/null 2>&1 || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "the old entry point refuses another workflow instead of running the feature one"
# 이 구분 전의 feature 실행(latest-feature 없음)은 그 뒤 다른 워크플로를 시작해도 이어 갈 수 있다.
rm -f "$(dirname "$(run_dir)")/latest-feature"
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
DRIVER_RC=0
DRIVER_OUT="$(HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER_SHIM" status --repo "$DRIVER_REPO" 2>&1)" || DRIVER_RC=$?
assert_eq "0" "$DRIVER_RC" "an older feature run is still found after another workflow started"
assert_contains "$DRIVER_OUT" "workflow feature" "the old entry point resumes the feature run, not the newer bug-fix run"
pass "resume compares the saved baseline before any agent runs (bug-fix graph and old entry point)"

# /investigate가 남긴 조사 보고를 받으면 fix-bug는 triage·reproduce를 다시 하지 않고 brief부터 시작한다. (#338)
INVESTIGATION_REPORT="$DRIVER_TMP/investigation.md"
printf '%s\n' '# Investigation: total ignores tax' 'root cause: tax is skipped when the discount is zero' \
  'evidence: npm test -- total: expected 110, got 100 (origin/develop)' >"$INVESTIGATION_REPORT"
new_driver_repo bug_investigated
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$INVESTIGATION_REPORT"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "an investigated bug still stops at approval"
assert_eq "brief read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "an investigation report skips triage and reproduce"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "tax is skipped when the discount is zero" "the brief reads the investigation report"
assert_contains "$(run_state '[.history[] | .from + ">" + .to] | join(",")')" "triage>brief" "the skip is a declared graph edge"
assert_eq "investigation_report_provided" "$(run_state 'first(.history[] | select(.from == "triage")) | .outcome')" "the skip names its outcome"
# 그 전이가 없는 옛 프로젝트 그래프는 평소대로 triage·reproduce를 돈다.
new_driver_repo bug_investigated_legacy
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.when == "investigation_report_provided"))' "$BUG_FIX_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/bug-fix-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$INVESTIGATION_REPORT"
assert_eq "10" "$DRIVER_RC" "a legacy graph still reaches approval"
assert_contains "$(<"$FAKE_LOG")" "triage read-only" "a legacy graph without the skip edge runs triage"
assert_contains "$(<"$FAKE_LOG.triage.prompt")" "tax is skipped when the discount is zero" "a legacy triage still reads the report"
new_driver_repo feature_investigated
driver start --runtime codex --request "add feature" --investigation "$INVESTIGATION_REPORT"
assert_eq "2" "$DRIVER_RC" "only bug-fix takes an investigation report"
new_driver_repo bug_investigation_missing
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$DRIVER_TMP/no-such-report.md"
assert_eq "2" "$DRIVER_RC" "a missing investigation report is a usage error"
: >"$DRIVER_TMP/empty-investigation.md"
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$DRIVER_TMP/empty-investigation.md"
assert_eq "2" "$DRIVER_RC" "an empty investigation report does not skip reproduce"
pass "fix-bug starts from the brief with an investigation report"

finish_tests
