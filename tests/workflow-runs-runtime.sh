#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 러너 런타임 선택
# 실행: bash tests/run.sh workflow-runs-runtime
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# --runtime이 없으면 러너를 부른 런타임을 따르고, 못 정하면 integrations·설치된 CLI 순으로 정한다.
# codex가 PATH에 있다는 것만으로 codex를 고르지 않는다(#476).
runtime_run() { # env... → DRIVER_RC, DRIVER_OUT (DRIVER_REPO는 new_driver_repo가 준비)
  DRIVER_RC=0
  DRIVER_OUT="$(env -u CLAUDECODE -u CODEX_THREAD_ID -u HM_RUNTIME -u HM_RUNTIME_REPOS "$@" HM_APPROVAL='' HM_APPROVAL_REPOS='' HARNESS_METRICS_DIR="$DRIVER_TMP/data" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" \
    CLAUDE_CONFIG_DIR="${RUNTIME_CFG:-$DRIVER_TMP/claude}" CODEX_HOME="$DRIVER_TMP/codex" FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO="$FAKE_SCENARIO" FAKE_CHECK=true \
    PATH="${RUNTIME_PATH:-$ROOT/tests/fixtures/driver:$PATH}" bash "$DRIVER" start ${RUNTIME_FLAG:+--runtime "$RUNTIME_FLAG"} --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
}
with_integrations() { # json array → 저장소 manifest
  mkdir -p "$DRIVER_REPO/.ai-harness"
  jq -n --argjson i "$1" '{project_id:"rt", level:"standard", integrations:$i}' >"$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m manifest
}
new_driver_repo rt-claude-caller
runtime_run CLAUDECODE=1
assert_eq "claude" "$(run_state .runtime)" "a runner started from Claude Code runs claude sessions even when codex is installed"
new_driver_repo rt-codex-caller
runtime_run CODEX_THREAD_ID=t-1
assert_eq "codex" "$(run_state .runtime)" "a runner started from Codex runs codex sessions"
new_driver_repo rt-integrations
with_integrations '["claude"]'
runtime_run
assert_eq "claude" "$(run_state .runtime)" "without a caller signal the repository integrations decide"
new_driver_repo rt-both-signals
with_integrations '["codex"]'
runtime_run CLAUDECODE=1 CODEX_THREAD_ID=t-1
assert_eq "codex" "$(run_state .runtime)" "a nested Claude/Codex environment does not guess the caller; integrations decide"
# 설치된 CLI가 codex 하나뿐인 PATH. jq·git은 설치 위치가 머신마다 달라 링크로 넣는다.
mkdir -p "$DRIVER_TMP/only-codex"
ln -sf "$ROOT/tests/fixtures/driver/codex" "$DRIVER_TMP/only-codex/codex"
for t in jq git; do ln -sf "$(command -v "$t")" "$DRIVER_TMP/only-codex/$t"; done
new_driver_repo rt-only-codex
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "codex" "$(run_state .runtime)" "with one CLI installed and no other signal the installed one runs"
new_driver_repo rt-integrations-missing
with_integrations '["claude"]'
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "codex" "$(run_state .runtime)" "integrations naming an uninstalled CLI fall through to the installed one"
new_driver_repo rt-integrations-both
with_integrations '["claude", "codex"]'
runtime_run
assert_eq "2" "$DRIVER_RC" "integrations listing both installed CLIs do not pick one by list order"
new_driver_repo rt-both-signals-undecided
runtime_run CLAUDECODE=1 CODEX_THREAD_ID=t-1
assert_eq "2" "$DRIVER_RC" "a nested Claude/Codex environment without integrations refuses to guess"
# Claude Code에서 부르면 기본이 claude가 되므로, 저장소가 Claude 설정 폴더 안이면 시작 전에 거부하고 codex를 안내한다.
new_driver_repo rt-claude-protected
RUNTIME_CFG="$DRIVER_TMP" runtime_run CLAUDECODE=1
assert_eq "2" "$DRIVER_RC" "a Claude Code caller with the repository inside the Claude configuration directory is refused"
assert_contains "$DRIVER_OUT" "--runtime codex" "the refusal points to --runtime codex"
new_driver_repo rt-undecided
runtime_run
assert_eq "2" "$DRIVER_RC" "both CLIs installed and nothing to decide refuses to guess"
assert_contains "$DRIVER_OUT" "--runtime" "the refusal asks for --runtime"
assert_eq "" "$(find "$DRIVER_TMP/runs" -path "*/repo-rt-undecided-*" -name state.json)" "no run is created when the runtime is undecided"
pass "runner runtime follows the caller, then integrations, then the installed CLI"

# 개인 기본 런타임(#488): --runtime > HM_RUNTIME_REPOS > HM_RUNTIME > 자동 선택. 설정이 고른 CLI가 없으면 바꾸지 않고 멈춘다.
rt_config() { printf '%s\n' "$@" >"$DRIVER_TMP/data/config"; }
new_driver_repo rt-flag
with_integrations '[]'
rt_config 'HM_RUNTIME=codex' 'HM_RUNTIME_REPOS="rt=claude"'
RUNTIME_FLAG=codex runtime_run
assert_eq "codex:flag" "$(run_state .runtime):$(run_state .policy.runtime_source)" "--runtime wins over the personal settings"
assert_contains "$DRIVER_OUT" "runtime codex (flag)" "start prints the runtime and where it came from"
new_driver_repo rt-repo-setting
with_integrations '[]'
rt_config 'HM_RUNTIME=codex' 'HM_RUNTIME_REPOS="other=codex,rt=claude"'
runtime_run CODEX_THREAD_ID=t-1
assert_eq "claude:HM_RUNTIME_REPOS:rt" "$(run_state .runtime):$(run_state .policy.runtime_source)" "the repository setting wins over HM_RUNTIME and the caller"
assert_contains "$DRIVER_OUT" "runtime claude (HM_RUNTIME_REPOS:rt)" "start names the repository setting"
# 저장소 설정을 바꿔도 이어 가는 실행은 start 때의 런타임을 쓴다.
rt_config 'HM_RUNTIME_REPOS="rt=codex"'
driver resume
assert_eq "claude" "$(run_state .runtime)" "resume keeps the runtime chosen at start"
new_driver_repo rt-user-setting
with_integrations '[]'
rt_config 'HM_RUNTIME=codex' 'HM_RUNTIME_REPOS="other=claude"'
runtime_run CLAUDECODE=1
assert_eq "codex:HM_RUNTIME" "$(run_state .runtime):$(run_state .policy.runtime_source)" "HM_RUNTIME applies when no repository entry matches"
new_driver_repo rt-default-source
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "codex:default" "$(run_state .runtime):$(run_state .policy.runtime_source)" "without settings the automatic choice is recorded as default"
assert_contains "$DRIVER_OUT" "runtime codex (default)" "start says the runtime was chosen automatically"
new_driver_repo rt-bad-user
rt_config 'HM_RUNTIME=gemini'
runtime_run
assert_eq "2" "$DRIVER_RC" "an unknown HM_RUNTIME stops the start"
assert_contains "$DRIVER_OUT" "HM_RUNTIME in $DRIVER_TMP/data/config is \"gemini\"; runtime must be claude or codex" "the error names the setting and the file"
assert_eq "" "$(find "$DRIVER_TMP/runs" -path "*/repo-rt-bad-user-*" -name state.json)" "no run is created for an invalid runtime setting"
new_driver_repo rt-bad-repo
with_integrations '[]'
rt_config 'HM_RUNTIME_REPOS="rt=bogus"'
runtime_run
assert_eq "2" "$DRIVER_RC" "an unknown repository runtime stops the start"
assert_contains "$DRIVER_OUT" "HM_RUNTIME_REPOS:rt in $DRIVER_TMP/data/config" "the error names the repository entry"
new_driver_repo rt-bad-env
runtime_run HM_RUNTIME=bogus
assert_eq "2" "$DRIVER_RC" "an unknown HM_RUNTIME from the environment stops the start"
assert_contains "$DRIVER_OUT" "in the environment" "the error says the value came from the environment"
new_driver_repo rt-missing-user
rt_config 'HM_RUNTIME=claude'
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "2" "$DRIVER_RC" "a chosen CLI that is not installed stops the start"
assert_contains "$DRIVER_OUT" "HM_RUNTIME in $DRIVER_TMP/data/config chose claude, but claude is not installed" "the stop names the setting and the missing CLI"
assert_eq "" "$(find "$DRIVER_TMP/runs" -path "*/repo-rt-missing-user-*" -name state.json)" "no run falls back to codex"
[[ ! -s "$FAKE_LOG" ]] || fail "no session runs when the chosen CLI is missing"
new_driver_repo rt-missing-repo
with_integrations '[]'
rt_config 'HM_RUNTIME_REPOS="rt=claude"'
RUNTIME_PATH="$DRIVER_TMP/only-codex:/usr/bin:/bin" runtime_run
assert_eq "2" "$DRIVER_RC" "a repository runtime that is not installed stops the start"
assert_contains "$DRIVER_OUT" "HM_RUNTIME_REPOS:rt in $DRIVER_TMP/data/config chose claude" "the stop names the repository entry"
: >"$DRIVER_TMP/data/config"
pass "personal runtime settings pick the node runtime after --runtime and stop when the CLI is missing"

finish_tests
