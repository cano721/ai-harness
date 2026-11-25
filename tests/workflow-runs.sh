#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — bug-fix 러너(승인 전 단계·재현 실패)
# 실행: bash tests/run.sh workflow-runs
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

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
new_driver_repo bug_ok
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
assert_eq "10:approval:bug-fix" "$DRIVER_RC:$(run_state .node):$(run_state .workflow)" "a bug fix stops at approval after triage, reproduce, and brief"
assert_eq "triage read-only schema=;reproduce workspace-write schema=yes add-dir=yes;brief read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "nothing writes before approval; reproduce may run commands and keeps its notes in the run directory"
assert_contains "$DRIVER_OUT" "Bug Fix Brief" "the person sees a Bug Fix Brief"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "expected 110, got 100" "the brief carries the reproduction evidence"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" ".ai-harness/workflows/fix-bug.md" "bug-fix nodes read the project bug-fix workflow"
assert_contains "$(run_state .graph)" "bug-fix-graph.json" "the run follows the bug-fix graph"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an approved bug fix reaches done"
assert_contains "$(run_state '[.history[].to] | join(",")')" "regression,fix,verify,review,publish,remote_ci,done" "the runner follows the bug-fix graph"
assert_eq "regression workspace-write;fix workspace-write;review read-only" "$(tail -n 3 "$FAKE_LOG" | cut -d' ' -f1,2 | paste -sd ';' -)" "regression and fix write after approval; review stays read-only"
bug_run repro_blocked
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a bug that can be neither reproduced nor observed goes to a person before approval"
assert_contains "$(<"$(run_dir)/unresolved.json")" "a sample order export" "the person sees what is needed to reproduce"
[[ "$(<"$FAKE_LOG")" != *regression* ]] || fail "nothing writes when the bug cannot be reproduced"
bug_run repro_hollow
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "reproduced without evidence is not a reproduction"
bug_run repro_writes
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "reproduce that writes into the repository stops the run"
pass "resume compares the saved baseline before any agent runs (bug-fix approval and reproduction)"

# status 줄은 저장소 git_policy와 개인 단계를 나눠 보인다. 내부 .policy.git이 merge여도 저장소 값은 pr-only다. 병합 동작은 그대로다. (#534)
export FAKE_PROTECTION=classic
for dl_repo_git in pr-only merge; do
  delivery_run "dl_status_$dl_repo_git" "$dl_repo_git" "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
  assert_eq "0:done:1:merge" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .policy.git)" "repository $dl_repo_git with level merge still merges and keeps the internal policy merge"
  driver status
  assert_contains "$DRIVER_OUT" "git_policy pr-only" "status shows the repository git_policy pr-only for repository $dl_repo_git"
  assert_contains "$DRIVER_OUT" "delivery merge" "status shows the personal delivery level for repository $dl_repo_git"
  [[ "$DRIVER_OUT" != *"git_policy merge"* ]] || fail "status shows the internal merge as git_policy for repository $dl_repo_git: $DRIVER_OUT"
done
unset FAKE_PROTECTION
rm -f "$DL_DATA/config"
pass "status separates the repository git_policy from the personal delivery level"

finish_tests
