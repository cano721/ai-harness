#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-harness-tests.XXXXXX")"
TESTS=0

cleanup() {
  case "$TEST_TMP" in
    */ai-harness-tests.*) find "$TEST_TMP" -depth -delete 2>/dev/null || true ;;
    *) printf 'unexpected test temp path, preserving: %s\n' "$TEST_TMP" >&2 ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  TESTS=$((TESTS + 1))
  printf 'ok %d - %s\n' "$TESTS" "$1"
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing: $needle)"
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

CLAUDE_FIXTURE="$ROOT/tests/fixtures/claude/aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
CODEX_FIXTURE="$ROOT/tests/fixtures/codex/rollout-2026-07-29T12-00-00-bbbbbbbb-1111-2222-3333-cccccccccccc.jsonl"
CODEX_FILE_SID="2026-07-29T12-00-00-bbbbbbbb-1111-2222-3333-cccccccccccc"
CODEX_SESSION_ID="bbbbbbbb-1111-2222-3333-cccccccccccc"

# stable project ID: origin과 삭제된 worktree 경로 fallback
PROJECT_REPO="$TEST_TMP/repos/service"
PROJECT_WORKTREE="$TEST_TMP/worktrees/service-NMRS-999"
mkdir -p "$PROJECT_REPO" "$TEST_TMP/worktrees"
git -C "$PROJECT_REPO" init -q
git -C "$PROJECT_REPO" config user.email test@example.com
git -C "$PROJECT_REPO" config user.name test
git -C "$PROJECT_REPO" commit -q --allow-empty -m init
git -C "$PROJECT_REPO" remote add origin git@github.com:acme/service.git
git -C "$PROJECT_REPO" worktree add -q -b test-worktree "$PROJECT_WORKTREE"
HARNESS_METRICS_DIR="$TEST_TMP/lib-data"
export HARNESS_METRICS_DIR
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
assert_eq "service" "$(project_id_for_cwd "$PROJECT_REPO")" "origin project id"
assert_eq "service" "$(project_id_for_cwd "$PROJECT_WORKTREE")" "worktree project id"
assert_eq "jobda-agent" "$(project_id_for_cwd "/tmp/workspaces/jobda-agent/NJ-290")" "missing worktree fallback"
pass "stable project IDs"

# Claude/Codex extractor metadata and coverage
EXTRACT_DATA="$TEST_TMP/extract-data"
HARNESS_METRICS_DIR="$EXTRACT_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
HARNESS_METRICS_DIR="$EXTRACT_DATA" "$ROOT/scripts/extract-codex.sh" "$CODEX_FIXTURE"
CLAUDE_EVENT="$EXTRACT_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
CODEX_EVENT="$EXTRACT_DATA/events/codex-${CODEX_FILE_SID}.jsonl"
assert_file "$CLAUDE_EVENT"
assert_file "$CODEX_EVENT"
assert_eq "2" "$(jq -r 'select(.kind=="session") | .v' "$CLAUDE_EVENT")" "Claude event version"
assert_eq "service" "$(jq -r 'select(.kind=="session") | .project' "$CLAUDE_EVENT")" "Claude project normalization"
assert_eq "claude-test-model" "$(jq -r 'select(.kind=="session") | .model' "$CLAUDE_EVENT")" "synthetic model exclusion"
assert_eq "40" "$(jq -r 'select(.kind=="session") | .cache_write' "$CLAUDE_EVENT")" "Claude cache write"
assert_eq "bbbbbbbb-1111-2222-3333-cccccccccccc" "$(jq -r 'select(.kind=="session") | .sid' "$CODEX_EVENT")" "Codex real session id"
assert_eq "jobda-agent" "$(jq -r 'select(.kind=="session") | .project' "$CODEX_EVENT")" "Codex project normalization"
assert_eq "gpt-test-model" "$(jq -r 'select(.kind=="session") | .model' "$CODEX_EVENT")" "Codex model"
assert_eq "openai" "$(jq -r 'select(.kind=="session") | .provider' "$CODEX_EVENT")" "Codex provider"
assert_eq "11" "$(jq -r 'select(.kind=="session") | .cache_write' "$CODEX_EVENT")" "Codex cache write"
assert_eq "2" "$(jq -r 'select(.kind=="jira_issue" and .target=="JDA-123") | .n' "$CODEX_EVENT")" "Codex issue count without duplicate stream"
assert_eq "1" "$(jq -r 'select(.kind=="correction_mark") | .n' "$CODEX_EVENT")" "Codex correction mark"
pass "source extractors"

# 공용 SessionEnd hook이 Codex transcript를 Claude 이벤트로 만들지 않음
HOOK_DATA="$TEST_TMP/hook-data"
jq -n --arg tp "$CODEX_FIXTURE" '{transcript_path:$tp,reason:"other"}' \
  | HARNESS_METRICS_DIR="$HOOK_DATA" "$ROOT/scripts/collect.sh"
if [[ -d "$HOOK_DATA/events" ]] && find "$HOOK_DATA/events" -type f -name '*.jsonl' | grep -q .; then
  fail "Codex hook created a ghost event"
fi
jq -n --arg tp "$CLAUDE_FIXTURE" '{transcript_path:$tp,reason:"user_exit"}' \
  | HARNESS_METRICS_DIR="$HOOK_DATA" "$ROOT/scripts/collect.sh"
assert_file "$HOOK_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
assert_eq "3" "$(jq -r '.hooks.SessionEnd[0].hooks[0].timeout' "$ROOT/hooks/hooks.json")" "shared hook timeout"
# shellcheck disable=SC2016  # hook JSON의 literal 변수 참조를 검사
LITERAL_PLUGIN_ROOT='"${CLAUDE_PLUGIN_ROOT}'
HOOK_COMMAND="$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$ROOT/hooks/hooks.json")"
assert_contains "$HOOK_COMMAND" "$LITERAL_PLUGIN_ROOT" "quoted plugin root"
HOOK_ROOT_WITH_SPACE="$TEST_TMP/plugin root"
HOOK_COMMAND_DATA="$TEST_TMP/hook-command-data"
ln -s "$ROOT" "$HOOK_ROOT_WITH_SPACE"
jq -n --arg tp "$CLAUDE_FIXTURE" '{transcript_path:$tp,reason:"user_exit"}' \
  | CLAUDE_PLUGIN_ROOT="$HOOK_ROOT_WITH_SPACE" HARNESS_METRICS_DIR="$HOOK_COMMAND_DATA" \
    /bin/sh -c "$HOOK_COMMAND"
assert_file "$HOOK_COMMAND_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
pass "cross-platform SessionEnd hook"

# latest는 전역 mtime이 아니라 실제 Codex thread ID 우선
SESSION_CLAUDE="$TEST_TMP/session-claude/project"
SESSION_CODEX="$TEST_TMP/session-codex/2026/07/29"
mkdir -p "$SESSION_CLAUDE" "$SESSION_CODEX"
cp "$CLAUDE_FIXTURE" "$SESSION_CLAUDE/"
cp "$CODEX_FIXTURE" "$SESSION_CODEX/"
touch -t 203001010000 "$SESSION_CLAUDE/$(basename "$CLAUDE_FIXTURE")"
SESSION_REPORT="$(
  HARNESS_METRICS_DIR="$TEST_TMP/session-data" \
  HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/session-claude" \
  HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/session-codex" \
  CODEX_THREAD_ID="$CODEX_SESSION_ID" \
  "$ROOT/scripts/session.sh" latest
)"
assert_contains "$SESSION_REPORT" "소스: codex" "session source"
assert_contains "$SESSION_REPORT" "세션 리포트 — bbbbbbbb" "session id"
assert_contains "$SESSION_REPORT" "모델: gpt-test-model" "session model"
pass "current session selection"

# 최근/진행 중 transcript 처리 + stale v1 강제 재추출
BACKFILL_CLAUDE="$TEST_TMP/backfill-claude/project"
BACKFILL_CODEX="$TEST_TMP/backfill-codex/2026/07/29"
BACKFILL_DATA="$TEST_TMP/backfill-data"
mkdir -p "$BACKFILL_CLAUDE" "$BACKFILL_CODEX" "$BACKFILL_DATA/events"
cp "$CLAUDE_FIXTURE" "$BACKFILL_CLAUDE/"
cp "$CODEX_FIXTURE" "$BACKFILL_CODEX/"
cp "$ROOT/tests/fixtures/ghost-claude-codex-event.jsonl" \
  "$BACKFILL_DATA/events/claude-rollout-legacy.jsonl"
BACKFILL_OUTPUT="$(
  HARNESS_METRICS_DIR="$BACKFILL_DATA" \
  HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/backfill-claude" \
  HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/backfill-codex" \
  "$ROOT/scripts/backfill.sh"
)"
assert_contains "$BACKFILL_OUTPUT" "처리 2" "recent transcripts processed"
assert_contains "$BACKFILL_OUTPUT" "유령 정리 1" "legacy ghost cleanup"
[[ ! -e "$BACKFILL_DATA/events/claude-rollout-legacy.jsonl" ]] || fail "legacy ghost event not removed"
assert_file "$BACKFILL_DATA/events/codex-${CODEX_FILE_SID}.jsonl"
cp "$ROOT/tests/fixtures/stale-codex-event.jsonl" "$BACKFILL_DATA/events/codex-${CODEX_FILE_SID}.jsonl"
touch -t 203001010000 "$BACKFILL_DATA/events/codex-${CODEX_FILE_SID}.jsonl"
HARNESS_METRICS_DIR="$BACKFILL_DATA" \
HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/backfill-claude" \
HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/backfill-codex" \
  "$ROOT/scripts/backfill.sh" >/dev/null
assert_eq "2" "$(jq -r 'select(.kind=="session") | .v' "$BACKFILL_DATA/events/codex-${CODEX_FILE_SID}.jsonl")" "stale event invalidation"
pass "backfill freshness and version invalidation"

# mixed-source stats는 미지원을 0회로 취급하지 않음
STATS_OUTPUT="$(HARNESS_METRICS_DIR="$EXTRACT_DATA" "$ROOT/scripts/stats.sh")"
assert_contains "$STATS_OUTPUT" "## 수집 범위" "coverage section"
assert_contains "$STATS_OUTPUT" "관측 범위: 1/2세션; 나머지는 수집 미지원" "mixed coverage note"
assert_contains "$STATS_OUTPUT" "cache write" "cache write column"
pass "coverage-aware metrics"

# manifest versions and marketplace policy stay aligned
assert_eq "0.8.0" "$(jq -r '.version' "$ROOT/.codex-plugin/plugin.json")" "Codex plugin version"
assert_eq "0.8.0" "$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json")" "Claude plugin version"
assert_eq "ON_INSTALL" "$(jq -r '.plugins[0].policy.authentication' "$ROOT/.agents/plugins/marketplace.json")" "marketplace auth policy"
pass "plugin metadata"

printf '1..%d\n' "$TESTS"
