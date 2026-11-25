#!/usr/bin/env bash
# 회귀 테스트 — design-polish 러너 — Claude 보호 경로 거부와 거부된 fix를 수리 횟수로 세지 않음
# 실행: bash tests/run.sh workflow-polish-protected
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 보호 경로(#411): Claude Code는 설정 디렉터리(~/.claude, CLAUDE_CONFIG_DIR) 안을 무인 세션이 고치거나 읽지 못하게 막는다.
# 실측에서 저장소가 ~/.claude 아래라 fix가 매번 거부돼 "fix changed nothing"으로 수리 횟수만 썼다.
new_driver_repo protected_src
PROT_REPO="$DRIVER_TMP/claude/jobs/protected"
mkdir -p "$PROT_REPO"
git -C "$PROT_REPO" init -q
git -C "$PROT_REPO" config user.email t@t
git -C "$PROT_REPO" config user.name t
git -C "$PROT_REPO" commit -q --allow-empty -m init
DRIVER_REPO="$PROT_REPO"
driver start --workflow polish --runtime claude --request "다듬어줘"
assert_eq "2" "$DRIVER_RC" "a claude run in a repository inside the Claude configuration directory is refused before it starts"
assert_contains "$DRIVER_OUT" "inside the Claude Code configuration directory" "the refusal says why"
assert_contains "$DRIVER_OUT" "git worktree add" "the refusal says how to work around it"
[[ ! -s "$FAKE_LOG" ]] || fail "no session runs in a protected repository"
driver start --runtime codex --request "add feature"
assert_eq "10" "$DRIVER_RC" "the codex sandbox is not limited by the Claude configuration directory"
new_driver_repo protected_runs
DRIVER_RC=0
DRIVER_OUT="$(HM_APPROVAL='' HM_APPROVAL_REPOS='' HM_RUNTIME='' HM_RUNTIME_REPOS='' HARNESS_METRICS_DIR="$DRIVER_TMP/data" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/claude/runs" CLAUDE_CONFIG_DIR="$DRIVER_TMP/claude" \
  PATH="$ROOT/tests/fixtures/driver:$PATH" bash "$DRIVER" start --runtime claude --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "a run folder inside the Claude configuration directory is refused too"
assert_contains "$DRIVER_OUT" "HM_FEATURE_RUNS_DIR" "the refusal names the setting that moves the run folder"
# 권한에 막혀 아무것도 못 바꾼 fix는 환경 실패다: 수리 횟수를 쓰지 않고, 막힌 호출을 알린다.
new_driver_repo polish_denied
driver start --workflow polish --runtime claude --request "다듬어줘"
say_in_claude "승인"
driver resume
assert_eq "30" "$DRIVER_RC" "a denied fix stops as incomplete"
assert_contains "$DRIVER_OUT" "the session was denied: Edit " "the stop names the denied call"
assert_contains "$DRIVER_OUT" "screen.css. This environment failure" "the stop names the denied path"
assert_contains "$DRIVER_OUT" "does not count as a repair attempt" "the stop says the attempt was not counted"
assert_eq "0" "$(run_state .attempts)" "an environment failure does not use up a repair attempt"
driver resume
assert_eq "30:0" "$DRIVER_RC:$(run_state .attempts)" "resuming the same environment failure still uses no attempt"
pass "runners refuse a working folder Claude Code protects and do not count denied fixes as attempts"

finish_tests
