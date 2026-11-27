#!/usr/bin/env bash
# 회귀 테스트 — 세션 수집·추출·harvest 큐·backfill·통계
# 실행: bash tests/run.sh collect
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Claude/Codex extractor metadata and coverage
EXTRACT_DATA="$TEST_TMP/extract-data"
HARNESS_METRICS_DIR="$EXTRACT_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
HARNESS_METRICS_DIR="$EXTRACT_DATA" "$ROOT/scripts/extract-codex.sh" "$CODEX_FIXTURE"
CLAUDE_EVENT="$EXTRACT_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
CODEX_EVENT="$EXTRACT_DATA/events/codex-${CODEX_FILE_SID}.jsonl"
assert_file "$CLAUDE_EVENT"
assert_file "$CODEX_EVENT"
assert_eq "3" "$(jq -r 'select(.kind=="session") | .v' "$CLAUDE_EVENT")" "Claude event version"
assert_eq "service" "$(jq -r 'select(.kind=="session") | .project' "$CLAUDE_EVENT")" "Claude project normalization"
assert_eq "claude-test-model" "$(jq -r 'select(.kind=="session") | .model' "$CLAUDE_EVENT")" "synthetic model exclusion"
assert_eq "40" "$(jq -r 'select(.kind=="session") | .cache_write' "$CLAUDE_EVENT")" "Claude cache write"
assert_eq "6" "$(jq -r 'select(.kind=="error") | .n' "$CLAUDE_EVENT")" "Claude tool error counts is_error results but not output-less failures"
assert_eq "2" "$(jq -r 'select(.kind=="guard_block") | .n' "$CLAUDE_EVENT")" "Claude guard block counts edit-tool results and falls back to line-leading prefix when the tool is unknown"
assert_eq "?: [Direct edit guard] src/app.ts 수정 전에 docs를 먼저 Read 하세요.|Edit: [Direct edit guard] src/app.ts 수정 전에 다음 docs를 먼저 Read 하세요:" \
  "$(jq -rs '[.[] | select(.kind=="guard_sample") | .target] | sort | join("|")' "$CLAUDE_EVENT")" \
  "Claude guard sample names the tool and the blocked target without the hook wrapper"
assert_eq "1" "$(jq -r 'select(.kind=="permission_deny") | .n' "$CLAUDE_EVENT")" "Claude permission denial requires is_error and the observed leading phrase (ignores clarify, source text, git log)"
assert_eq "0" "$(jq -s '[.[] | select(.kind | startswith("correction"))] | length' "$CLAUDE_EVENT")" "Claude adapter leaves corrections to the LLM digest"
USAGE_DUP_FIXTURE="$TEST_TMP/usage-dup/dddddddd-1111-2222-3333-eeeeeeeeeeee.jsonl"
mkdir -p "${USAGE_DUP_FIXTURE%/*}"
{
  printf '%s\n' '{"type":"user","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:00Z","message":{"role":"user","content":"go"}}'
  for block in '{"type":"text","text":"x"}' '{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"a"}}' '{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"b"}}'; do
    printf '{"type":"assistant","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:01Z","message":{"id":"msg_1","model":"claude-test-model","usage":{"input_tokens":5,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":10},"content":[%s]}}\n' "$block"
  done
  printf '%s\n' '{"type":"assistant","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:02Z","message":{"id":"msg_2","model":"claude-test-model","usage":{"input_tokens":1,"output_tokens":7,"cache_read_input_tokens":20,"cache_creation_input_tokens":2},"content":[{"type":"text","text":"y"}]}}'
  printf '%s\n' '{"type":"assistant","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:03Z","message":{"model":"claude-test-model","usage":{"input_tokens":1,"output_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"y"}]}}'
} >"$USAGE_DUP_FIXTURE"
HARNESS_METRICS_DIR="$EXTRACT_DATA" "$ROOT/scripts/extract-claude.sh" "$USAGE_DUP_FIXTURE" "user_exit"
assert_eq "7 110 1020 12" "$(jq -r 'select(.kind=="session") | "\(.tok_in) \(.tok_out) \(.cache_read) \(.cache_write)"' "$EXTRACT_DATA/events/claude-dddddddd-1111-2222-3333-eeeeeeeeeeee.jsonl")" "Claude usage counts each message.id once (content blocks repeat it) and keeps id-less lines"
CTX_FIXTURE="$TEST_TMP/ctx/cccccccc-1111-2222-3333-dddddddddddd.jsonl"
mkdir -p "${CTX_FIXTURE%.jsonl}/subagents"
{
  printf '%s\n' '{"type":"user","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:00Z","message":{"role":"user","content":"go"}}'
  printf '%s\n' '{"type":"assistant","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:01Z","message":{"id":"m1","model":"claude-test-model","usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":900},"content":[{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"/tmp/service/.ai-harness/docs/testing.md"}},{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"cat AGENTS.md .ai-harness/docs/testing.md"}},{"type":"tool_use","id":"g1","name":"Grep","input":{"pattern":"x"}}]}}'
  printf '%s\n' '{"type":"user","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"r1","content":"'"$(printf 'a%.0s' {1..400})"'"},{"type":"tool_result","tool_use_id":"b1","content":"'"$(printf 'b%.0s' {1..80})"'"},{"type":"tool_result","tool_use_id":"g1","content":[{"type":"text","text":"한글"}]}]}}'
  printf '%s\n' '{"type":"assistant","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:03Z","message":{"id":"m2","model":"claude-test-model","usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":1000,"cache_creation_input_tokens":300},"content":[{"type":"text","text":"y"}]}}'
  printf '%s\n' '{"type":"assistant","isSidechain":true,"cwd":"/tmp/service","timestamp":"2026-07-29T00:00:04Z","message":{"id":"m3","model":"claude-test-model","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":99999},"content":[{"type":"text","text":"side"}]}}'
  printf '%s\n' '{"type":"assistant","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:05Z","message":{"id":"m4","model":"claude-test-model","usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":1200,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"z"}]}}'
} >"$CTX_FIXTURE"
for agent in a1 a2; do
  printf '{"type":"assistant","isSidechain":true,"message":{"id":"%s","model":"claude-test-model","usage":{"input_tokens":3,"output_tokens":20,"cache_read_input_tokens":500,"cache_creation_input_tokens":7},"content":[{"type":"text","text":"x"}]}}\n' "$agent" >"${CTX_FIXTURE%.jsonl}/subagents/agent-$agent.jsonl"
done
HARNESS_METRICS_DIR="$EXTRACT_DATA" "$ROOT/scripts/extract-claude.sh" "$CTX_FIXTURE" "user_exit"
CTX_EVENT="$EXTRACT_DATA/events/claude-cccccccc-1111-2222-3333-dddddddddddd.jsonl"
assert_eq "2 6 40 1000 14" "$(jq -r 'select(.kind=="session") | "\(.agents) \(.agent_tok_in) \(.agent_tok_out) \(.agent_cache_read) \(.agent_cache_write)"' "$CTX_EVENT")" "Claude subagent transcripts are summed into the parent session"
assert_eq "116" "$(jq -r 'select(.kind=="session") | .tok_in' "$CTX_EVENT")" "Claude main tokens stay main-only (in-file sidechain lines kept as before)"
assert_eq "1000 1310 1205" "$(jq -r 'select(.kind=="session") | "\(.ctx_first) \(.ctx_peak) \(.ctx_last)"' "$CTX_EVENT")" "Claude context first/peak/last from main-chain calls only"
assert_eq "Bash=20/1 Grep=1/1 Read=100/1" "$(jq -r 'select(.kind=="ctx_tool") | "\(.target)=\(.n)/\(.calls)"' "$CTX_EVENT" | sort | paste -sd " " -)" "Claude tool result size per tool (UTF-8 bytes/4)"
assert_eq ".ai-harness/docs/testing.md=100/1" "$(jq -r 'select(.kind=="doc_ctx") | "\(.target)=\(.n)/\(.calls)"' "$CTX_EVENT")" "Claude doc context cost skips results mixing several docs"
AGENT_BF_PROJ="$TEST_TMP/agent-bf-claude/project"
AGENT_BF_DATA="$TEST_TMP/agent-bf-data"
mkdir -p "$AGENT_BF_PROJ"
cp -R "$CTX_FIXTURE" "${CTX_FIXTURE%.jsonl}" "$AGENT_BF_PROJ/"
agent_bf() { HARNESS_METRICS_DIR="$AGENT_BF_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/agent-bf-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/none" "$ROOT/scripts/backfill.sh" >/dev/null; }
agent_bf
AGENT_BF_EVENT="$AGENT_BF_DATA/events/claude-cccccccc-1111-2222-3333-dddddddddddd.jsonl"
touch -t 202601010000 "$AGENT_BF_PROJ/$(basename "$CTX_FIXTURE")" "$AGENT_BF_EVENT"
cp "$AGENT_BF_PROJ/cccccccc-1111-2222-3333-dddddddddddd/subagents/agent-a1.jsonl" "$AGENT_BF_PROJ/cccccccc-1111-2222-3333-dddddddddddd/subagents/agent-a3.jsonl"
agent_bf
assert_eq "3" "$(jq -r 'select(.kind=="session") | .agents' "$AGENT_BF_EVENT")" "backfill re-extracts when only a subagent transcript is newer than the event"
agent_bf
assert_eq "3" "$(jq -r 'select(.kind=="session") | .agents' "$AGENT_BF_EVENT")" "backfill stays stable after re-extracting a subagent update"
CTX_STATS_DATA="$TEST_TMP/ctx-stats"
mkdir -p "$CTX_STATS_DATA/events"
cp "$CTX_EVENT" "$CTX_STATS_DATA/events/"
CTX_STATS="$(HARNESS_METRICS_DIR="$CTX_STATS_DATA" "$ROOT/scripts/stats.sh")"
assert_contains "$CTX_STATS" "| service | 1 | 1 | 116 | 4 | 2200 | 101199 | 6/40/1000 |" "stats shows subagent usage beside main usage"
assert_contains "$CTX_STATS" "| service | 1 | 1000 | 1310 | 1310 |" "stats shows per-project context overhead and peak"
assert_contains "$CTX_STATS" "| .ai-harness/docs/testing.md | 100 | 100 |" "stats shows doc context cost and per-read size"
assert_contains "$CTX_STATS" "| Read | 100 |" "stats ranks tool result sizes"
BASH_DOC_FIXTURE="$TEST_TMP/bash-doc/ffffffff-1111-2222-3333-aaaaaaaaaaaa.jsonl"
mkdir -p "${BASH_DOC_FIXTURE%/*}"
bash_doc_line() { # $1=tool name, $2=input json
  printf '{"type":"assistant","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:01Z","message":{"model":"claude-test-model","content":[{"type":"tool_use","id":"t","name":"%s","input":%s}]}}\n' "$1" "$2"
}
{
  printf '%s\n' '{"type":"user","cwd":"/tmp/service","timestamp":"2026-07-29T00:00:00Z","message":{"role":"user","content":"go"}}'
  bash_doc_line Read '{"file_path":"/tmp/service/.ai-harness/workflows/implement-feature.md"}'
  bash_doc_line Bash '{"command":"cat .ai-harness/workflows/implement-feature.md"}'
  bash_doc_line Bash '{"command":"sed -n '"'"'1,80p'"'"' /repo/member/.ai-harness/docs/testing.md && cat member/AGENTS.md"}'
  bash_doc_line Bash '{"command":"cd member && head -50 \".ai-harness/workflows/fix-bug.md\" | nl"}'
  bash_doc_line Bash '{"command":"grep -rn approval .ai-harness/workflows/"}'
  bash_doc_line Bash '{"command":"printf x > .ai-harness/docs/domain.md"}'
  bash_doc_line Bash '{"command":"cat > .ai-harness/docs/new.md <<'"'"'EOF'"'"'\nbody\nEOF"}'
  bash_doc_line Bash '{"command":"cat notes.txt > .ai-harness/docs/b.md"}'
  bash_doc_line Bash '{"command":"sed -i '"'"'s/a/b/'"'"' .ai-harness/workflows/fix-bug.md"}'
  bash_doc_line Bash '{"command":"cat .ai-harness/docs/한글문서.md"}'
  bash_doc_line Bash '{"command":"cat src/FooCLAUDE.md"}'
} >"$BASH_DOC_FIXTURE"
HARNESS_METRICS_DIR="$EXTRACT_DATA" "$ROOT/scripts/extract-claude.sh" "$BASH_DOC_FIXTURE" "user_exit"
assert_eq ".ai-harness/docs/testing.md=1 .ai-harness/docs/한글문서.md=1 .ai-harness/workflows/fix-bug.md=1 .ai-harness/workflows/implement-feature.md=2 AGENTS.md=1" \
  "$(jq -r 'select(.kind=="doc_read") | "\(.target)=\(.n)"' "$EXTRACT_DATA/events/claude-ffffffff-1111-2222-3333-aaaaaaaaaaaa.jsonl" | sort | paste -sd " " -)" \
  "Claude doc_read counts harness docs read through Bash read commands, not searches, redirects, heredocs or sed -i"
assert_eq "bbbbbbbb-1111-2222-3333-cccccccccccc" "$(jq -r 'select(.kind=="session") | .sid' "$CODEX_EVENT")" "Codex real session id"
assert_eq "acme-agent" "$(jq -r 'select(.kind=="session") | .project' "$CODEX_EVENT")" "Codex project normalization"
assert_eq "gpt-test-model" "$(jq -r 'select(.kind=="session") | .model' "$CODEX_EVENT")" "Codex model"
assert_eq "openai" "$(jq -r 'select(.kind=="session") | .provider' "$CODEX_EVENT")" "Codex provider"
assert_eq "11" "$(jq -r 'select(.kind=="session") | .cache_write' "$CODEX_EVENT")" "Codex cache write"
assert_eq "40 60" "$(jq -r 'select(.kind=="session") | "\(.tok_in) \(.cache_read)"' "$CODEX_EVENT")" "Codex input excludes cached input (OpenAI input_tokens includes it)"
CODEX_CTX_DIR="$TEST_TMP/codex-ctx/2026/07/30"
CODEX_CTX_FIXTURE="$CODEX_CTX_DIR/rollout-2026-07-30T00-00-00-eeeeeeee-1111-2222-3333-ffffffffffff.jsonl"
mkdir -p "$CODEX_CTX_DIR"
{
  sed 's/bbbbbbbb-1111-2222-3333-cccccccccccc/eeeeeeee-1111-2222-3333-ffffffffffff/' "$CODEX_FIXTURE" | grep -v '"token_count"'
  for u in '1000 600 1000 10000' '3000 2500 4000 10000' '2000 1900 6000 5000'; do
    read -r last cached total window <<<"$u"
    printf '{"type":"event_msg","timestamp":"2026-07-30T00:00:09Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":5},"last_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":1},"model_context_window":%s}}}\n' "$total" "$cached" "$last" "$cached" "$window"
  done
} >"$CODEX_CTX_FIXTURE"
HARNESS_METRICS_DIR="$TEST_TMP/codex-ctx-extract" "$ROOT/scripts/extract-codex.sh" "$CODEX_CTX_FIXTURE"
CODEX_CTX_EVENT="$TEST_TMP/codex-ctx-extract/events/codex-2026-07-30T00-00-00-eeeeeeee-1111-2222-3333-ffffffffffff.jsonl"
assert_eq "1000 3000 2000 10000" "$(jq -r 'select(.kind=="session") | "\(.ctx_first) \(.ctx_peak) \(.ctx_last) \(.ctx_window)"' "$CODEX_CTX_EVENT")" "Codex context per call and the window in effect at the peak call (model switch shrinks it later)"
CODEX_LEGACY_DATA="$TEST_TMP/codex-legacy"
mkdir -p "$CODEX_LEGACY_DATA/events"
jq -c 'if .kind=="session" then .coverage -= ["context"] | .tok_in = 100 | del(.ctx_first,.ctx_peak,.ctx_last,.ctx_window) else . end' "$CODEX_EVENT" \
  >"$CODEX_LEGACY_DATA/events/codex-legacy.jsonl"
assert_contains "$(HARNESS_METRICS_DIR="$CODEX_LEGACY_DATA" "$ROOT/scripts/stats.sh")" "| acme-agent | 1 | 3 | 40 |" "stats normalizes legacy Codex input that still included cached input"
CODEX_CTX_REPORT="$(HARNESS_METRICS_DIR="$TEST_TMP/codex-ctx-data" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/none" \
  HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/codex-ctx" "$ROOT/scripts/session.sh" eeeeeeee)"
assert_contains "$CODEX_CTX_REPORT" "최대 3000 / 마지막 2000 · 창 10000의 30%" "session report shows peak share of the Codex context window"
assert_eq "reviewer" "$(jq -r 'select(.kind=="persona") | .target' "$CODEX_EVENT")" "Codex bridge persona"
assert_eq ".ai-harness/docs/code-conventions.md .ai-harness/docs/testing.md" "$(jq -r 'select(.kind=="doc_read") | .target' "$CODEX_EVENT" | sort | paste -sd " " -)" "Codex bridge multi-doc read in one exec"
assert_eq "1" "$(jq -r 'select(.kind=="guard_block") | .n' "$CODEX_EVENT")" "Codex guard block counts line-leading hook prefix only"
assert_eq "1" "$(jq -rs '[.[] | select(.kind=="guard_sample" and (.target | contains("src/app.ts")))] | length' "$CODEX_EVENT")" "Codex guard sample keeps the blocked target"
assert_eq "src/app.ts" "$(jq -r 'select(.kind=="file_edit") | .target' "$CODEX_EVENT")" "Codex bridge file edit"
assert_eq "mcp__jira__get_issue" "$(jq -r 'select(.kind=="mcp_tool") | .target' "$CODEX_EVENT")" "Codex bridge MCP tool"
assert_eq "ai-harness:metrics" "$(jq -r 'select(.kind=="workflow") | .target' "$CODEX_EVENT")" "Codex skill workflow"
assert_eq "3" "$(jq -r 'select(.kind=="error") | .n' "$CODEX_EVENT")" "Codex tool error counts bridge envelope and non-zero exit with output, not source text or output-less failures"
assert_eq "1" "$(jq -r 'select(.kind=="permission_deny") | .n' "$CODEX_EVENT")" "Codex permission denial requires is_error envelope (ignores clarify and quoted source text)"
assert_eq "1" "$(jq -r 'select(.kind=="compact") | .n' "$CODEX_EVENT")" "Codex compaction"
assert_eq "2" "$(jq -r 'select(.kind=="jira_issue" and .target=="JDA-123") | .n' "$CODEX_EVENT")" "Codex issue count without duplicate stream"
assert_eq "0" "$(jq -s '[.[] | select(.kind | startswith("correction"))] | length' "$CODEX_EVENT")" "Codex adapter leaves corrections to the LLM digest"
pass "source extractors"

# 공용 SessionEnd hook이 Codex transcript를 올바른 extractor로 분류함
HOOK_DATA="$TEST_TMP/hook-data"
jq -n --arg tp "$CODEX_FIXTURE" '{transcript_path:$tp,reason:"other"}' \
  | HARNESS_METRICS_DIR="$HOOK_DATA" HM_UPDATE_CHECK_ENABLED=0 "$ROOT/scripts/collect.sh"
assert_not_file "$HOOK_DATA/events/claude-rollout-${CODEX_FILE_SID}.jsonl"
assert_file "$HOOK_DATA/events/codex-${CODEX_FILE_SID}.jsonl"
assert_file "$HOOK_DATA/harvest-queue/p-acme-agent/sessions/codex-${CODEX_SESSION_ID}.json"
jq -n --arg tp "$CLAUDE_FIXTURE" '{transcript_path:$tp,reason:"user_exit"}' \
  | HARNESS_METRICS_DIR="$HOOK_DATA" HM_UPDATE_CHECK_ENABLED=0 "$ROOT/scripts/collect.sh"
assert_file "$HOOK_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
assert_file "$HOOK_DATA/harvest-queue/p-service/sessions/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json"
# 수집은 backfill-due.sh(launchd·SessionStart)가 맡는다. 탭을 닫으면 실행되지 않는 SessionEnd hook은 두지 않는다.
assert_eq "null" "$(jq -c '.hooks.SessionEnd' "$ROOT/hooks/hooks.json")" "no SessionEnd hook"
assert_eq "3" "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$ROOT/hooks/hooks.json")" "SessionStart stays inside its short budget"
# shellcheck disable=SC2016  # hook JSON의 literal 변수 참조를 검사
LITERAL_PLUGIN_ROOT='"${CLAUDE_PLUGIN_ROOT}'
HOOK_COMMAND="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/hooks.json")"
assert_contains "$HOOK_COMMAND" "$LITERAL_PLUGIN_ROOT" "quoted plugin root"
# collect.sh는 수동 수집 진입점으로 남는다. 공백 경로에서도 동작해야 한다.
HOOK_ROOT_WITH_SPACE="$TEST_TMP/plugin root"
HOOK_COMMAND_DATA="$TEST_TMP/hook-command-data"
ln -s "$ROOT" "$HOOK_ROOT_WITH_SPACE"
jq -n --arg tp "$CLAUDE_FIXTURE" '{transcript_path:$tp,reason:"user_exit"}' \
  | HARNESS_METRICS_DIR="$HOOK_COMMAND_DATA" HM_UPDATE_CHECK_ENABLED=0 "$HOOK_ROOT_WITH_SPACE/scripts/collect.sh"
assert_file "$HOOK_COMMAND_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
assert_eq "success" "$(jq -r '.components.session_end.last_result' "$HOOK_COMMAND_DATA/health.json")" "collect health success"
MISSING_HOOK_DATA="$TEST_TMP/missing-hook-data"
jq -n '{transcript_path:"/missing/session.jsonl",reason:"other"}' \
  | HARNESS_METRICS_DIR="$MISSING_HOOK_DATA" "$ROOT/scripts/collect.sh"
assert_eq "failure" "$(jq -r '.components.session_end.last_result' "$MISSING_HOOK_DATA/health.json")" "collect health failure"
assert_eq "transcript_missing" "$(jq -r '.components.session_end.last_error' "$MISSING_HOOK_DATA/health.json")" "collect health error"
pass "collection entry points"

# 각 기준은 독립적으로 끌 수 있고, 교정 누적만으로도 analysis batch가 된다.
SIGNAL_DATA="$TEST_TMP/signal-data"
HARNESS_METRICS_DIR="$SIGNAL_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
seed_correction_digest "$SIGNAL_DATA" "$SIGNAL_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl" 1
SIGNAL_BATCH="$(
  HARNESS_METRICS_DIR="$SIGNAL_DATA" \
  HM_HARVEST_SESSION_THRESHOLD=0 HM_HARVEST_CORRECTION_THRESHOLD=1 \
  HM_HARVEST_CORRECTION_SESSION_THRESHOLD=1 HM_HARVEST_ERROR_THRESHOLD=0 \
  HM_HARVEST_GUARD_THRESHOLD=0 HM_HARVEST_PERMISSION_THRESHOLD=0 \
    "$ROOT/scripts/harvest-queue.sh" record \
      "$SIGNAL_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
)"
assert_eq "corrections" "$(printf '%s' "$SIGNAL_BATCH" | jq -r '.reasons | join(",")')" "independent correction threshold"

# v0.9.0 ready/ack 파일은 처음 읽을 때 analysis/reviewed 명칭으로 자동 이관한다.
LEGACY_DIR="$SIGNAL_DATA/harvest-queue/p-service"
jq -c '. as $batch | del(.has_analysis_batch,.new_analysis_batch) | . + {ready:true,newly_ready:true}' \
  "$LEGACY_DIR/analysis-batch.json" >"$LEGACY_DIR/ready.json"
jq -c '. + {acknowledged_at:"2026-08-09T00:00:00Z"}' \
  "$LEGACY_DIR/ready.json" >"$LEGACY_DIR/last-ack.json"
printf '%s\n' "legacy-batch" >"$LEGACY_DIR/notified-ready-batch"
find "$LEGACY_DIR/analysis-batch.json" -maxdepth 0 -type f -delete
MIGRATED_STATUS="$(
  HARNESS_METRICS_DIR="$SIGNAL_DATA" \
  HM_HARVEST_SESSION_THRESHOLD=0 HM_HARVEST_CORRECTION_THRESHOLD=1 \
  HM_HARVEST_CORRECTION_SESSION_THRESHOLD=1 HM_HARVEST_ERROR_THRESHOLD=0 \
  HM_HARVEST_GUARD_THRESHOLD=0 HM_HARVEST_PERMISSION_THRESHOLD=0 \
    "$ROOT/scripts/harvest-queue.sh" status --project service
)"
assert_eq "true" "$(printf '%s' "$MIGRATED_STATUS" | jq -r '.has_analysis_batch')" "legacy ready state migration"
assert_eq "false" "$(printf '%s' "$MIGRATED_STATUS" | jq -r 'has("ready")')" "legacy ready field removed"
assert_file "$LEGACY_DIR/analysis-batch.json"
assert_file "$LEGACY_DIR/last-reviewed.json"
assert_file "$LEGACY_DIR/notified-analysis-batch"
assert_not_file "$LEGACY_DIR/ready.json"
assert_not_file "$LEGACY_DIR/last-ack.json"
assert_not_file "$LEGACY_DIR/notified-ready-batch"
pass "quantity-based harvest hook queue"

# 반복 신호는 기본적으로 서로 다른 세션에서 관측돼야 하며, 권한 거부도 독립 트리거가 된다.
DIVERSITY_DATA="$TEST_TMP/diversity-data"
HARNESS_METRICS_DIR="$DIVERSITY_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
DIVERSITY_EVENT="$DIVERSITY_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
DIVERSITY_STATUS="$(
  HARNESS_METRICS_DIR="$DIVERSITY_DATA" \
  HM_HARVEST_SESSION_THRESHOLD=0 HM_HARVEST_CORRECTION_THRESHOLD=1 \
  HM_HARVEST_ERROR_THRESHOLD=0 HM_HARVEST_GUARD_THRESHOLD=0 HM_HARVEST_PERMISSION_THRESHOLD=0 \
    "$ROOT/scripts/harvest-queue.sh" record "$DIVERSITY_EVENT"
)"
assert_eq "false" "$(printf '%s' "$DIVERSITY_STATUS" | jq -r '.has_analysis_batch')" "single-session correction noise filtered"
PERMISSION_STATUS="$(
  HARNESS_METRICS_DIR="$DIVERSITY_DATA" \
  HM_HARVEST_SESSION_THRESHOLD=0 HM_HARVEST_CORRECTION_THRESHOLD=0 HM_HARVEST_ERROR_THRESHOLD=0 \
  HM_HARVEST_GUARD_THRESHOLD=0 HM_HARVEST_PERMISSION_THRESHOLD=1 \
  HM_HARVEST_PERMISSION_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" status --project service
)"
assert_eq "permission_denials" "$(printf '%s' "$PERMISSION_STATUS" | jq -r '.reasons | join(",")')" "permission denial trigger"

# batch cap 이전의 일반 세션이 뒤쪽 신호를 가리지 않는다.
CAP_DATA="$TEST_TMP/cap-data"
mkdir -p "$CAP_DATA/events"
for sid in a b; do
  jq -cn --arg sid "$sid" \
    '{v:2,kind:"session",src:"claude",sid:$sid,project:"service",ended:"2026-01-01T00:00:00Z",coverage:["correction_mark"]}' \
    >"$CAP_DATA/events/$sid.jsonl"
done
for sid in c d; do
  jq -cn --arg sid "$sid" \
    '{v:2,kind:"session",src:"claude",sid:$sid,project:"service",ended:"2026-01-01T00:00:00Z",coverage:["correction_mark"]}' \
    >"$CAP_DATA/events/$sid.jsonl"
  seed_correction_digest "$CAP_DATA" "$CAP_DATA/events/$sid.jsonl" 1
done
for event_file in "$CAP_DATA/events"/*.jsonl; do
  HARNESS_METRICS_DIR="$CAP_DATA" HM_HARVEST_SESSION_THRESHOLD=0 \
  HM_HARVEST_CORRECTION_THRESHOLD=2 HM_HARVEST_CORRECTION_SESSION_THRESHOLD=2 \
  HM_HARVEST_ERROR_THRESHOLD=0 HM_HARVEST_GUARD_THRESHOLD=0 HM_HARVEST_PERMISSION_THRESHOLD=0 \
  HM_HARVEST_MAX_BATCH_SESSIONS=2 \
    "$ROOT/scripts/harvest-queue.sh" record "$event_file" >/dev/null
done
CAP_STATUS="$(
  HARNESS_METRICS_DIR="$CAP_DATA" HM_HARVEST_SESSION_THRESHOLD=0 \
  HM_HARVEST_CORRECTION_THRESHOLD=2 HM_HARVEST_CORRECTION_SESSION_THRESHOLD=2 \
  HM_HARVEST_ERROR_THRESHOLD=0 HM_HARVEST_GUARD_THRESHOLD=0 HM_HARVEST_PERMISSION_THRESHOLD=0 \
  HM_HARVEST_MAX_BATCH_SESSIONS=2 \
    "$ROOT/scripts/harvest-queue.sh" status --project service
)"
assert_eq "true" "$(printf '%s' "$CAP_STATUS" | jq -r '.has_analysis_batch')" "signal beyond batch cap triggers"
assert_eq "2" "$(printf '%s' "$CAP_STATUS" | jq -r '.counts.correction_sessions')" "signal sessions selected before cap"
assert_eq "4" "$(printf '%s' "$CAP_STATUS" | jq -r '.trigger_counts.sessions')" "trigger counts cover all pending sessions"

# 동시에 검토 완료를 호출해도 같은 batch 이력이 중복 기록되지 않는다.
LOCK_DATA="$TEST_TMP/lock-data"
HARNESS_METRICS_DIR="$LOCK_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
LOCK_EVENT="$LOCK_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
HARNESS_METRICS_DIR="$LOCK_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" record "$LOCK_EVENT" >/dev/null
HARNESS_METRICS_DIR="$LOCK_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service >/dev/null &
LOCK_PID_1=$!
HARNESS_METRICS_DIR="$LOCK_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service >/dev/null &
LOCK_PID_2=$!
wait "$LOCK_PID_1"
wait "$LOCK_PID_2"
assert_eq "1" "$(wc -l < "$LOCK_DATA/harvest-queue/p-service/review-history.jsonl" | tr -d ' ')" "review lock prevents duplicate history"

# mkdir이 확인과 생성을 나눠 처리해도(uutils) lock은 동시 호출을 상호 배제한다.
NONATOMIC_BIN="$TEST_TMP/nonatomic-mkdir-bin"
mkdir -p "$NONATOMIC_BIN"
cat >"$NONATOMIC_BIN/mkdir" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "-p" ]] && exec "$REAL_MKDIR" "$@"
done
for target in "$@"; do
  if [[ -e "$target" ]]; then
    echo "mkdir: cannot create directory '$target': File exists" >&2
    exit 1
  fi
  sleep 0.2
  "$REAL_MKDIR" -p "$target"
done
FAKE
chmod +x "$NONATOMIC_BIN/mkdir"
REAL_MKDIR_PATH="$(command -v mkdir)"
for round in 1 2 3; do
  NA_DATA="$TEST_TMP/nonatomic-lock-data-$round"
  HARNESS_METRICS_DIR="$NA_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
  NA_EVENT="$NA_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
  HARNESS_METRICS_DIR="$NA_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" record "$NA_EVENT" >/dev/null
  PATH="$NONATOMIC_BIN:$PATH" REAL_MKDIR="$REAL_MKDIR_PATH" \
    HARNESS_METRICS_DIR="$NA_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service >/dev/null 2>"$NA_DATA/err-1" &
  NA_PID_1=$!
  PATH="$NONATOMIC_BIN:$PATH" REAL_MKDIR="$REAL_MKDIR_PATH" \
    HARNESS_METRICS_DIR="$NA_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service >/dev/null 2>"$NA_DATA/err-2" &
  NA_PID_2=$!
  NA_RC_1=0
  NA_RC_2=0
  wait "$NA_PID_1" || NA_RC_1=$?
  wait "$NA_PID_2" || NA_RC_2=$?
  assert_eq "0" "$NA_RC_1" "nonatomic mkdir round $round first mark-reviewed exit"
  assert_eq "0" "$NA_RC_2" "nonatomic mkdir round $round second mark-reviewed exit"
  assert_eq "1" "$(wc -l < "$NA_DATA/harvest-queue/p-service/review-history.jsonl" | tr -d ' ')" "nonatomic mkdir round $round history once"
  if grep -q 'cannot stat\|No such file' "$NA_DATA/err-1" "$NA_DATA/err-2"; then
    fail "nonatomic mkdir round $round raced into critical section: $(cat "$NA_DATA/err-1" "$NA_DATA/err-2")"
  fi
  [[ ! -e "$NA_DATA/harvest-queue/p-service/.queue-lock" ]] || fail "nonatomic mkdir round $round queue lock left behind"
done
pass "queue lock excludes concurrent callers even when mkdir is non-atomic"

# 임계구역 안에서 실패해도 EXIT trap이 lock을 푼다(bash 5에서 local 변수가 사라져도).
FAILLOCK_DATA="$TEST_TMP/failure-lock-data"
FAILLOCK_BIN="$TEST_TMP/failing-mv-bin"
mkdir -p "$FAILLOCK_BIN"
cat >"$FAILLOCK_BIN/mv" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  */sessions/*) echo "mv: simulated failure for $1" >&2; exit 1 ;;
esac
exec "$REAL_MV" "$@"
FAKE
chmod +x "$FAILLOCK_BIN/mv"
HARNESS_METRICS_DIR="$FAILLOCK_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
FAILLOCK_EVENT="$FAILLOCK_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
HARNESS_METRICS_DIR="$FAILLOCK_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" record "$FAILLOCK_EVENT" >/dev/null
FAILLOCK_RC=0
# 가짜 mv를 PATH 앞에 두기 전에 진짜 경로를 구한다(같은 줄이면 해시 캐시 여부에 따라 가짜를 잡아 무한 재실행).
FAILLOCK_REAL_MV="$(command -v mv)"
PATH="$FAILLOCK_BIN:$PATH" REAL_MV="$FAILLOCK_REAL_MV" \
  HARNESS_METRICS_DIR="$FAILLOCK_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service >/dev/null 2>"$FAILLOCK_DATA/err" || FAILLOCK_RC=$?
if [[ "$FAILLOCK_RC" == "0" ]]; then
  fail "mark-reviewed should fail when moving a session marker fails"
fi
if grep -q 'unbound variable' "$FAILLOCK_DATA/err"; then
  fail "EXIT trap referenced an out-of-scope variable: $(cat "$FAILLOCK_DATA/err")"
fi
[[ ! -e "$FAILLOCK_DATA/harvest-queue/p-service/.queue-lock" ]] || fail "queue lock left behind after failure inside critical section"
pass "queue lock is released when the critical section fails"

# record가 marker 교체 중이어도 mark-reviewed는 같은 프로젝트 lock을 기다려 상태가 갈라지지 않는다.
ATOMIC_DATA="$TEST_TMP/atomic-data"
HARNESS_METRICS_DIR="$ATOMIC_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
ATOMIC_EVENT="$ATOMIC_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
HARNESS_METRICS_DIR="$ATOMIC_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" record "$ATOMIC_EVENT" >/dev/null
ATOMIC_EVENT_TMP="$ATOMIC_DATA/events/.atomic-update.jsonl"
jq -c 'if .kind=="session" then .ended="2027-01-02T00:00:00Z" | .turns=(.turns+1) else . end' \
  "$ATOMIC_EVENT" >"$ATOMIC_EVENT_TMP"
mv "$ATOMIC_EVENT_TMP" "$ATOMIC_EVENT"
HARNESS_METRICS_DIR="$ATOMIC_DATA" "$ROOT/scripts/health.sh" failure harvest_queue simulated >/dev/null
(
  ATOMIC_ROOT="$ATOMIC_DATA/race"
  export ATOMIC_ROOT
  # shellcheck disable=SC2329  # 하위 harvest-queue 프로세스가 export된 wrapper를 호출
  # shellcheck disable=SC2317  # export된 함수라 현재 셸에서는 직접 호출하지 않는다
  mv() {
    if [[ "${RACE_BLOCK:-0}" == 1 && "${1:-}" == *'/sessions/.pending.'* && "${2:-}" == *'/sessions/'* ]]; then
      mkdir "$ATOMIC_ROOT-record-ready"
      while [[ ! -d "$ATOMIC_ROOT-release-record" ]]; do sleep 0.01; done
    fi
    command /bin/mv "$@"
  }
  export -f mv
  RACE_BLOCK=1 HARNESS_METRICS_DIR="$ATOMIC_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" record "$ATOMIC_EVENT" >/dev/null &
  ATOMIC_RECORD_PID=$!
  for _ in $(seq 1 200); do
    [[ -d "$ATOMIC_ROOT-record-ready" ]] && break
    sleep 0.01
  done
  [[ -d "$ATOMIC_ROOT-record-ready" ]] || fail "record race did not reach marker move"
  HARNESS_METRICS_DIR="$ATOMIC_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service \
      --outcome no-change --summary "동시성 검증" >/dev/null &
  ATOMIC_REVIEW_PID=$!
  sleep 0.05
  mkdir "$ATOMIC_ROOT-release-record"
  wait "$ATOMIC_RECORD_PID"
  wait "$ATOMIC_REVIEW_PID"
)
assert_not_file "$ATOMIC_DATA/harvest-queue/p-service/sessions/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json"
assert_not_file "$ATOMIC_DATA/harvest-queue/p-service/analysis-batch.json"
assert_eq "success" "$(jq -r '.components.harvest_queue.last_result' "$ATOMIC_DATA/health.json")" "queue health recovers after success"
pass "signal diversity and review locking"

# 검토 완료한 동일 sid를 재개하면 새 revision만 review unit으로 돌아오고 신호는 누적 차분이다.
RESUME_DATA="$TEST_TMP/resume-data"
HARNESS_METRICS_DIR="$RESUME_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
RESUME_EVENT="$RESUME_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
seed_correction_digest "$RESUME_DATA" "$RESUME_EVENT" 1
HARNESS_METRICS_DIR="$RESUME_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" record "$RESUME_EVENT" >/dev/null
HARNESS_METRICS_DIR="$RESUME_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service \
    --outcome no-change --summary "최초 검토" >/dev/null
RESUME_SEEN="$RESUME_DATA/harvest-queue/p-service/seen/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json"
LEGACY_SEEN_TMP="$RESUME_DATA/harvest-queue/p-service/seen/.legacy-seen.json"
jq -c 'del(.event_revision,.totals,.source_mtime,.source_size)' "$RESUME_SEEN" >"$LEGACY_SEEN_TMP"
mv "$LEGACY_SEEN_TMP" "$RESUME_SEEN"
LEGACY_SEEN_STATUS="$(
  HARNESS_METRICS_DIR="$RESUME_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" record "$RESUME_EVENT"
)"
assert_eq "unchanged" "$(printf '%s' "$LEGACY_SEEN_STATUS" | jq -r '.record_action')" "legacy seen marker is not requeued"
assert_eq "true" "$(jq -r 'has("event_revision")' "$RESUME_SEEN")" "legacy seen marker revision upgrade"
RESUME_TMP="$RESUME_DATA/events/.resumed.jsonl"
jq -c '
  if .kind=="session" then .ended="2027-01-01T00:00:00Z" | .turns=(.turns+1)
  else . end
' "$RESUME_EVENT" >"$RESUME_TMP"
mv "$RESUME_TMP" "$RESUME_EVENT"
seed_correction_digest "$RESUME_DATA" "$RESUME_EVENT" 2
RESUME_STATUS="$(
  HARNESS_METRICS_DIR="$RESUME_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" record "$RESUME_EVENT"
)"
RESUME_MARKER="$RESUME_DATA/harvest-queue/p-service/sessions/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json"
assert_eq "resumed" "$(printf '%s' "$RESUME_STATUS" | jq -r '.record_action')" "resumed session action"
assert_eq "true" "$(printf '%s' "$RESUME_STATUS" | jq -r '.has_analysis_batch')" "resumed session creates batch"
assert_eq "true" "$(jq -r '.resumed' "$RESUME_MARKER")" "resumed marker"
assert_eq "1" "$(jq -r '.corrections' "$RESUME_MARKER")" "resumed correction delta"
assert_eq "2" "$(jq -r '.totals.corrections' "$RESUME_MARKER")" "resumed correction cumulative total"
PENDING_REPEAT="$(
  HARNESS_METRICS_DIR="$RESUME_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" record "$RESUME_EVENT"
)"
assert_eq "unchanged-pending" "$(printf '%s' "$PENDING_REPEAT" | jq -r '.record_action')" "resumed pending revision is idempotent"
assert_eq "1" "$(jq -r '.corrections' "$RESUME_MARKER")" "repeated collection preserves correction delta"
HARNESS_METRICS_DIR="$RESUME_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service \
    --outcome improved --summary "재개 세션 교정 반영" >/dev/null
UNCHANGED_STATUS="$(
  HARNESS_METRICS_DIR="$RESUME_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" record "$RESUME_EVENT"
)"
assert_eq "unchanged" "$(printf '%s' "$UNCHANGED_STATUS" | jq -r '.record_action')" "reviewed revision is idempotent"
assert_eq "false" "$(printf '%s' "$UNCHANGED_STATUS" | jq -r '.has_analysis_batch')" "unchanged revision stays reviewed"
pass "resumed session revisions"

# 검토 완료된 오래된 이벤트는 보관 기간 후 tombstone과 review 이력만 남긴다.
RETENTION_DATA="$TEST_TMP/retention-data"
HARNESS_METRICS_DIR="$RETENTION_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
RETENTION_EVENT="$RETENTION_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
# 옛 버전이 남긴 문구 규칙 교정(사용자 발화 원문)도 보관본에서 지워진다.
jq -cn '{v:2,kind:"correction_mark",src:"claude",sid:"aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb",project:"service",target:"아니 그거 말고",n:1}' >>"$RETENTION_EVENT"
touch -t 202001010000 "$RETENTION_EVENT"
HARNESS_METRICS_DIR="$RETENTION_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" record "$RETENTION_EVENT" >/dev/null
HARNESS_METRICS_DIR="$RETENTION_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
HM_EVENT_RETENTION_DAYS=0 HM_SIGNAL_EVENT_RETENTION_DAYS=0 \
  "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service \
    --outcome no-change --summary "보관 테스트" >/dev/null
RETENTION_MARKER="$RETENTION_DATA/harvest-queue/p-service/seen/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json"
RETENTION_MARKER_BEFORE="$RETENTION_DATA/marker-before-prune.json"
cp "$RETENTION_MARKER" "$RETENTION_MARKER_BEFORE"

# 상세 삭제가 실패하면 marker가 event_file을 유지해 다음 prune이 재시도할 수 있다.
(
  PRUNE_FAIL_EVENT="$RETENTION_EVENT"
  export PRUNE_FAIL_EVENT
  # shellcheck disable=SC2329  # 하위 prune 프로세스가 export된 wrapper를 호출
  # shellcheck disable=SC2317  # export된 함수라 현재 셸에서는 직접 호출하지 않는다
  find() {
    if [[ "${1:-}" == "$PRUNE_FAIL_EVENT" ]]; then return 1; fi
    command /usr/bin/find "$@"
  }
  export -f find
  if HARNESS_METRICS_DIR="$RETENTION_DATA" HM_EVENT_RETENTION_DAYS=1 HM_SIGNAL_EVENT_RETENTION_DAYS=1 \
    "$ROOT/scripts/prune.sh" --project service >/dev/null 2>&1; then
    fail "prune deletion failure unexpectedly succeeded"
  fi
)
assert_file "$RETENTION_EVENT"
assert_eq "$RETENTION_EVENT" "$(jq -r '.event_file' "$RETENTION_MARKER")" "failed prune remains retryable"

HARNESS_METRICS_DIR="$RETENTION_DATA" HM_EVENT_RETENTION_DAYS=1 HM_SIGNAL_EVENT_RETENTION_DAYS=1 \
  "$ROOT/scripts/prune.sh" --project service >/dev/null
assert_not_file "$RETENTION_EVENT"
RETENTION_ROLLUP="$RETENTION_DATA/rollups/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
assert_file "$RETENTION_ROLLUP"
assert_eq "false" "$(jq -s 'any(.[]; has("transcript"))' "$RETENTION_ROLLUP")" "rollup removes transcript path"
assert_eq "[reviewed]" "$(jq -r 'select(.kind=="correction_mark") | .target' "$RETENTION_ROLLUP")" "rollup redacts correction text"
assert_eq "true" "$(jq -r '.event_pruned' "$RETENTION_MARKER")" "reviewed event tombstone"
assert_eq "true" "$(jq -r 'has("event_revision")' "$RETENTION_MARKER")" "tombstone preserves reviewed revision"

# 상세 삭제 직후 tombstone 교체 전에 중단된 상태도 다음 실행이 마무리한다.
cp "$RETENTION_MARKER_BEFORE" "$RETENTION_MARKER"
HARNESS_METRICS_DIR="$RETENTION_DATA" HM_EVENT_RETENTION_DAYS=1 HM_SIGNAL_EVENT_RETENTION_DAYS=1 \
  "$ROOT/scripts/prune.sh" --project service >/dev/null
assert_eq "true" "$(jq -r '.event_pruned' "$RETENTION_MARKER")" "interrupted prune finalizes tombstone"
assert_file "$RETENTION_DATA/harvest-queue/p-service/review-history.jsonl"
assert_eq "success" "$(jq -r '.components.retention.last_result' "$RETENTION_DATA/health.json")" "retention health"
RETENTION_STATS="$(HARNESS_METRICS_DIR="$RETENTION_DATA" "$ROOT/scripts/stats.sh" --project service)"
assert_contains "$RETENTION_STATS" "| service | 1 |" "rollup remains in statistics"
RETENTION_TRANSCRIPTS="$TEST_TMP/retention-transcripts/project"
mkdir -p "$RETENTION_TRANSCRIPTS"
cp "$CLAUDE_FIXTURE" "$RETENTION_TRANSCRIPTS/"
HARNESS_METRICS_DIR="$RETENTION_DATA" \
HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/retention-transcripts" \
HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/no-retention-codex" \
  "$ROOT/scripts/backfill.sh" >/dev/null
assert_not_file "$RETENTION_EVENT"

# rollup 뒤 같은 transcript가 실제 갱신되면 backfill이 새 revision을 복원한다.
jq -cn '{
  type:"user",uuid:"u3",cwd:"/tmp/service-NMRS-123",timestamp:"2026-08-10T00:00:00Z",
  message:{content:"아니 새 세션 교정을 반영해줘"}
}' >>"$RETENTION_TRANSCRIPTS/$(basename "$CLAUDE_FIXTURE")"
HARNESS_METRICS_DIR="$RETENTION_DATA" \
HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/retention-transcripts" \
HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/no-retention-codex" \
HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/backfill.sh" >/dev/null
assert_file "$RETENTION_EVENT"
assert_file "$RETENTION_DATA/harvest-queue/p-service/analysis-batch.json"
assert_eq "true" "$(jq -r '.resumed' "$RETENTION_DATA/harvest-queue/p-service/sessions/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json")" "post-rollup resume queued"
pass "reviewed event retention"

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
assert_contains "$BACKFILL_OUTPUT" "큐 2" "backfill events queued"
assert_contains "$BACKFILL_OUTPUT" "유령 정리 1" "legacy ghost cleanup"
[[ ! -e "$BACKFILL_DATA/events/claude-rollout-legacy.jsonl" ]] || fail "legacy ghost event not removed"
assert_file "$BACKFILL_DATA/events/codex-${CODEX_FILE_SID}.jsonl"
assert_file "$BACKFILL_DATA/harvest-queue/p-service/sessions/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json"
assert_file "$BACKFILL_DATA/harvest-queue/p-acme-agent/sessions/codex-${CODEX_SESSION_ID}.json"
assert_eq "success" "$(jq -r '.components.backfill.last_result' "$BACKFILL_DATA/health.json")" "backfill health"
cp "$ROOT/tests/fixtures/stale-codex-event.jsonl" "$BACKFILL_DATA/events/codex-${CODEX_FILE_SID}.jsonl"
touch -t 203001010000 "$BACKFILL_DATA/events/codex-${CODEX_FILE_SID}.jsonl"
HARNESS_METRICS_DIR="$BACKFILL_DATA" \
HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/backfill-claude" \
HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/backfill-codex" \
  "$ROOT/scripts/backfill.sh" >/dev/null
assert_eq "3" "$(jq -r 'select(.kind=="session") | .v' "$BACKFILL_DATA/events/codex-${CODEX_FILE_SID}.jsonl")" "stale event invalidation"
BACKFILL_AGAIN="$(HARNESS_METRICS_DIR="$BACKFILL_DATA" \
HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/backfill-claude" \
HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/backfill-codex" \
  "$ROOT/scripts/backfill.sh")"
assert_contains "$BACKFILL_AGAIN" "큐 0," "unchanged events are not re-recorded"
find "$BACKFILL_DATA/.enqueued" -type f -exec touch -t 200001010000 {} +
BACKFILL_STALE="$(HARNESS_METRICS_DIR="$BACKFILL_DATA" \
HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/backfill-claude" \
HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/backfill-codex" \
  "$ROOT/scripts/backfill.sh")"
assert_contains "$BACKFILL_STALE" "큐 유지 0," "stale stamps are re-recorded"
# 플러그인 재설치: 내용이 같은 스크립트가 새 수정 시각으로 깔려도 전체 재추출·재기록하지 않는다.
REINSTALL_ROOT="$TEST_TMP/reinstall-plugin"
mkdir -p "$REINSTALL_ROOT"
cp -R "$ROOT/scripts" "$REINSTALL_ROOT/"
run_reinstall_backfill() {
  HARNESS_METRICS_DIR="$BACKFILL_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/backfill-claude" \
    HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/backfill-codex" "$REINSTALL_ROOT/scripts/backfill.sh"
}
run_reinstall_backfill >/dev/null
sleep 1
find "$REINSTALL_ROOT/scripts" -type f -exec touch {} +
assert_contains "$(run_reinstall_backfill)" "처리 0," "same-content reinstall does not re-extract"
sleep 1
printf '\n# changed\n' >>"$REINSTALL_ROOT/scripts/extract-claude.jq"
assert_contains "$(run_reinstall_backfill)" "처리 1," "changed extractor content re-extracts"
pass "backfill freshness and version invalidation"

# Claude와 Codex 모두 동일한 상세 수집 범위를 보고한다.
STATS_OUTPUT="$(HARNESS_METRICS_DIR="$EXTRACT_DATA" "$ROOT/scripts/stats.sh")"
assert_contains "$STATS_OUTPUT" "## 수집 범위" "coverage section"
assert_contains "$STATS_OUTPUT" "| codex | 1 | bash_cmd, compact, context, doc_read" "full Codex coverage declaration"
assert_contains "$STATS_OUTPUT" "cache write" "cache write column"
pass "coverage-aware metrics"

# 비율: 활성 세션(턴 ≥ 5) 기준 교정 비율, 하네스 프로젝트 활성 세션 기준 워크플로 경유 비율.
RATIO_DATA="$TEST_TMP/ratio-data"
mkdir -p "$RATIO_DATA/events"
ratio_session() { # sid project turns [events-json...]
  local sid="$1" project="$2" turns="$3"; shift 3
  {
    jq -cn --arg sid "$sid" --arg p "$project" --argjson t "$turns" \
      '{v:1, src:"claude", sid:$sid, project:$p, kind:"session", started:"2026-10-10T00:00:00Z",
        ended:"2026-10-10T01:00:00Z", turns:$t,
        coverage:["workflow","doc_read","correction_mark"]}'
    for ev in "$@"; do
      jq -cn --arg sid "$sid" --arg p "$project" --argjson e "$ev" '{v:1, src:"claude", sid:$sid, project:$p, n:1} + $e'
    done
  } >"$RATIO_DATA/events/claude-$sid.jsonl"
}
ratio_session s1 svc 6 '{"kind":"doc_read","target":".ai-harness/workflows/implement-feature.md"}'
ratio_session s2 svc 8 '{"kind":"workflow","target":"ai-harness:understand-change"}'
ratio_session s3 svc 5 '{"kind":"workflow","target":"jira"}' '{"kind":"doc_read","target":"AGENTS.md"}' \
  '{"kind":"correction_mark","target":"아니 그거 말고","n":2}'
ratio_session s4 svc 2 '{"kind":"doc_read","target":".ai-harness/workflows/implement-feature.md"}'
ratio_session s5 other 10 '{"kind":"workflow","target":"review"}' '{"kind":"doc_read","target":".ai-harness/config"}'
ratio_session s6 svc 5 '{"kind":"workflow","target":"refactor"}'
ratio_session s7 svc 1 '{"kind":"doc_read","target":".ai-harness/workflows/refactor.md"}'
# 다른 하네스 프로젝트에서 읽힌 워크플로 이름은 이 프로젝트의 경유 근거가 아니다.
ratio_session s8 nos 6 '{"kind":"doc_read","target":".ai-harness/docs/testing.md"}' '{"kind":"workflow","target":"refactor"}'
# project가 없는 옛 이벤트도 /metrics를 멈추지 않는다.
jq -cn '{v:1, src:"claude", sid:"s9", kind:"session", started:"2026-10-10T00:00:00Z", ended:"2026-10-10T01:00:00Z", turns:6,
  coverage:["workflow","doc_read","correction_mark"]}, {v:1, src:"claude", sid:"s9", kind:"doc_read", target:".ai-harness/docs/x.md", n:1}' \
  >"$RATIO_DATA/events/claude-s9.jsonl"
RATIO_STATS="$(HARNESS_METRICS_DIR="$RATIO_DATA" "$ROOT/scripts/stats.sh")"
assert_contains "$RATIO_STATS" "## 비율" "ratio section"
assert_contains "$RATIO_STATS" "| 워크플로 경유 세션 | 50% (3/6) |" "workflow pass ratio over harness-project active sessions"
case "$RATIO_STATS" in *"교정 마크"*) fail "stats no longer reports rule-based correction marks" ;; esac
assert_contains "$RATIO_STATS" "| svc | 75% (3/4) |" "per-project workflow pass ratio"
case "${RATIO_STATS#*## 비율}" in *"| other |"*) fail "non-harness project excluded from workflow ratio" ;; esac
assert_contains "$RATIO_STATS" "| nos | 0% (0/1) |" "workflow names read in another project do not count"
# /investigate는 하네스 생성 워크플로다: 본문을 읽지 않고 슬래시로만 들어와도 경유로 센다. (#338)
ratio_session s10 inv 6 '{"kind":"doc_read","target":".ai-harness/docs/domain.md"}' '{"kind":"workflow","target":"investigate"}'
assert_contains "$(HARNESS_METRICS_DIR="$RATIO_DATA" "$ROOT/scripts/stats.sh")" "| inv | 100% (1/1) |" "an investigate session passes through a harness workflow"
pass "session ratio metrics"

# 워크플로 대상 세션 경유: 조회·CI 설정·문서만 고친 세션은 기능·버그 워크플로 대상이 아니므로 분모에서 뺀다.
# 대상 = 워크플로 경유 또는 구현 페르소나(developer·*implementer·test-engineer) 위임 또는 코드 파일 편집.
TARGET_DATA="$TEST_TMP/target-ratio-data"
mkdir -p "$TARGET_DATA/events"
target_session() { # sid [events-json...] — 프로젝트는 TARGET_PROJECT(기본 svc)
  local sid="$1" project="${TARGET_PROJECT:-svc}"; shift
  {
    jq -cn --arg sid "$sid" --arg p "$project" '{v:1, src:"claude", sid:$sid, project:$p, kind:"session", started:"2026-10-10T00:00:00Z",
      ended:"2026-10-10T01:00:00Z", turns:6, coverage:["workflow","doc_read","persona","file_edit"]}'
    for ev in "$@"; do
      jq -cn --arg sid "$sid" --arg p "$project" --argjson e "$ev" '{v:1, src:"claude", sid:$sid, project:$p, n:1} + $e'
    done
  } >"$TARGET_DATA/events/claude-$sid.jsonl"
}
target_session t1 '{"kind":"doc_read","target":".ai-harness/workflows/fix-bug.md"}'
target_session t2 '{"kind":"persona","target":"developer"}'
target_session t3 '{"kind":"file_edit","target":"/repo/src/main/App.java"}'
target_session t4 '{"kind":"persona","target":"fe-implementer"}'
target_session t5 '{"kind":"file_edit","target":"/repo/bitbucket-pipelines.yml"}' \
  '{"kind":"file_edit","target":"/repo/build.gradle.kts"}' '{"kind":"file_edit","target":"/repo/.ai-harness/docs/domain.md"}' \
  '{"kind":"file_edit","target":"/repo/Dockerfile"}' '{"kind":"file_edit","target":"/repo/.claude/settings.json"}'
target_session t6 '{"kind":"persona","target":"explorer"}' \
  '{"kind":"file_edit","target":"/tmp/claude-1/scratchpad/plan.py"}' '{"kind":"file_edit","target":"/repo/handoffs/next.md"}' \
  '{"kind":"file_edit","target":"/home/u/.claude/projects/x/memory/note.ts"}'
target_session t7
# Claude Code worktree 안의 코드 편집은 하네스 설정(.claude/) 편집이 아니다.
target_session t8 '{"kind":"file_edit","target":".claude/worktrees/w1/src/Main.kt"}'
# 파일 이름이 없는 target(Codex patch 경로가 디렉토리에서 잘림)·대체값은 코드 편집 근거가 아니다.
target_session t9 '{"kind":"file_edit","target":"/repo/docs/"}' '{"kind":"file_edit","target":"apply_patch"}' '{"kind":"file_edit"}' \
  '{"kind":"file_edit","target":".claude/worktrees/w2/README.md"}'
target_session t10 '{"kind":"file_edit","target":"/repo/dockerfile"}' '{"kind":"file_edit","target":"/repo/deploy/app.Dockerfile"}'
# 대상 세션이 없는 하네스 프로젝트는 대상 경유를 `-`로 낸다.
TARGET_PROJECT=web target_session w1 '{"kind":"doc_read","target":".ai-harness/docs/testing.md"}'
TARGET_STATS="$(HARNESS_METRICS_DIR="$TARGET_DATA" "$ROOT/scripts/stats.sh")"
assert_contains "$TARGET_STATS" "| 워크플로 경유 세션 | 9% (1/11) |" "overall workflow ratio keeps every harness-project active session"
assert_contains "$TARGET_STATS" "| 워크플로 대상 세션 경유 | 20% (1/5) |" "target ratio counts only implementation sessions"
assert_contains "$TARGET_STATS" "| 프로젝트 | 워크플로 경유 | 대상 경유 |" "per-project table has a target column"
assert_contains "$TARGET_STATS" "| svc | 10% (1/10) | 20% (1/5) |" "per-project target ratio"
assert_contains "$TARGET_STATS" "| web | 0% (0/1) | - |" "project without target sessions shows no target ratio"
pass "workflow target session ratio"

# 저장소 정보 활용: 대상 세션 중 하네스 docs·워크플로 문서를 Read한 세션. AGENTS.md·CLAUDE.md는 자동 로드라 근거가 아니다.
# 위 대상 세션 픽스처에 docs만 읽은 세션·아무것도 안 읽은 세션·AGENTS.md만 읽은 세션을 더한다(t1은 워크플로만 읽음).
INFO_DATA="$TEST_TMP/info-ratio-data"
cp -R "$TARGET_DATA" "$INFO_DATA"
TARGET_DATA="$INFO_DATA" target_session i1 '{"kind":"persona","target":"developer"}' \
  '{"kind":"doc_read","target":".ai-harness/docs/code-conventions.md"}'
TARGET_DATA="$INFO_DATA" target_session i2 '{"kind":"file_edit","target":"/repo/src/Api.java"}'
TARGET_DATA="$INFO_DATA" target_session i3 '{"kind":"file_edit","target":"/repo/src/Web.java"}' \
  '{"kind":"doc_read","target":"AGENTS.md"}' '{"kind":"doc_read","target":"CLAUDE.md"}'
INFO_STATS="$(HARNESS_METRICS_DIR="$INFO_DATA" "$ROOT/scripts/stats.sh")"
assert_contains "$INFO_STATS" "| 워크플로 대상 세션 경유 | 13% (1/8) |" "info fixture keeps target denominator"
assert_contains "$INFO_STATS" "| 저장소 정보 활용 | 25% (2/8) |" "repo info ratio counts docs or workflow reads among target sessions"
assert_contains "$INFO_STATS" "| 프로젝트 | 워크플로 경유 | 대상 경유 | 정보 활용 |" "per-project table has an info column"
assert_contains "$INFO_STATS" "| svc | 8% (1/13) | 13% (1/8) | 25% (2/8) |" "per-project repo info ratio"
assert_contains "$INFO_STATS" "| web | 0% (0/1) | - | - |" "project without target sessions shows no info ratio"
pass "repo info ratio over target sessions"

# 날짜 구간 필터: 설치일 전후처럼 특정 날짜로 자른다. until은 그 날을 포함하지 않는다.
RANGE_DATA="$TEST_TMP/range-data"
mkdir -p "$RANGE_DATA/events"
for spec in r1:2026-09-20 r2:2026-10-01 r3:2026-10-15 r4:2026-10-31; do
  jq -cn --arg sid "${spec%%:*}" --arg d "${spec#*:}" '{v:3, src:"claude", sid:$sid, project:"svc", kind:"session",
    started:($d+"T01:00:00Z"), ended:($d+"T02:00:00Z"), turns:6, coverage:["workflow"]}' >"$RANGE_DATA/events/claude-${spec%%:*}.jsonl"
done
RANGE_STATS="$(HARNESS_METRICS_DIR="$RANGE_DATA" "$ROOT/scripts/stats.sh" --since 2026-10-01 --until 2026-10-31)"
assert_contains "$RANGE_STATS" "기간: 2026-10-01 ~ 2026-10-31 전날" "stats prints the date range"
assert_contains "$RANGE_STATS" "| svc | 2 | 12 |" "stats keeps sessions inside [since, until)"
assert_contains "$(HARNESS_METRICS_DIR="$RANGE_DATA" "$ROOT/scripts/stats.sh" --until 2026-10-01)" "| svc | 1 | 6 |" "until alone keeps earlier sessions"
if HARNESS_METRICS_DIR="$RANGE_DATA" "$ROOT/scripts/stats.sh" --days 7 --since 2026-10-01 >/dev/null 2>&1; then
  fail "stats rejects --days with --since"
fi
if HARNESS_METRICS_DIR="$RANGE_DATA" "$ROOT/scripts/stats.sh" --since 2026/10/01 >/dev/null 2>&1; then
  fail "stats rejects a malformed --since"
fi
pass "stats date range filter"

# Codex rollout의 저장소 URL은 삭제된 worktree에서도 프로젝트를 지킨다.
REPO_URL_DATA="$TEST_TMP/repo-url-data"
REPO_URL_ROLLOUT="$TEST_TMP/repo-url/rollout-2026-07-29T12-00-00-dddddddd-1111-2222-3333-cccccccccccc.jsonl"
mkdir -p "${REPO_URL_ROLLOUT%/*}"
jq -cR 'fromjson? | if .type=="session_meta" then .payload.cwd="/gone/workspaces/x/feature-NJ-612"
  | .payload.git={repository_url:"https://github.com/acme/acme-agent.git"} else . end' \
  "$CODEX_FIXTURE" >"$REPO_URL_ROLLOUT"
HARNESS_METRICS_DIR="$REPO_URL_DATA" "$ROOT/scripts/extract-codex.sh" "$REPO_URL_ROLLOUT"
assert_eq "acme-agent" "$(jq -r 'select(.kind=="session") | .project' "$REPO_URL_DATA"/events/codex-*dddddddd*.jsonl)" "Codex extractor uses recorded repo URL"

# 프로젝트 ID가 바뀐 재추출 세션은 이전 큐의 검토 상태를 이어받는다.
MOVE_DATA="$TEST_TMP/move-data"
HARNESS_METRICS_DIR="$MOVE_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
MOVE_EVENT="$MOVE_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
seed_correction_digest "$MOVE_DATA" "$MOVE_EVENT" 1
MOVE_MARKER="claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json"
retag_move_event() {
  jq -c --arg p "$1" 'if .kind=="session" then .project=$p else . end' "$MOVE_EVENT" >"$MOVE_EVENT.tmp"
  mv "$MOVE_EVENT.tmp" "$MOVE_EVENT"
}
move_record() { HARNESS_METRICS_DIR="$MOVE_DATA" HM_HARVEST_SESSION_THRESHOLD=0 "$ROOT/scripts/harvest-queue.sh" record "$MOVE_EVENT"; }
retag_move_event old-name
move_record >/dev/null
assert_file "$MOVE_DATA/harvest-queue/p-old-name/sessions/$MOVE_MARKER"
retag_move_event new-name
assert_eq "unchanged-pending" "$(move_record | jq -r '.record_action')" "moved pending session is adopted, not duplicated"
assert_not_file "$MOVE_DATA/harvest-queue/p-old-name/sessions/$MOVE_MARKER"
assert_eq "new-name" "$(jq -r '.project' "$MOVE_DATA/harvest-queue/p-new-name/sessions/$MOVE_MARKER")" "adopted record carries the new project"
HARNESS_METRICS_DIR="$MOVE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 "$ROOT/scripts/harvest-queue.sh" status --project new-name >/dev/null
HARNESS_METRICS_DIR="$MOVE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project new-name --outcome no-change --summary test >/dev/null
assert_file "$MOVE_DATA/harvest-queue/p-new-name/seen/$MOVE_MARKER"
retag_move_event third-name
assert_eq "unchanged" "$(move_record | jq -r '.record_action')" "reviewed session is not re-queued under a new project"
assert_file "$MOVE_DATA/harvest-queue/p-third-name/seen/$MOVE_MARKER"
assert_not_file "$MOVE_DATA/harvest-queue/p-third-name/sessions/$MOVE_MARKER"
HELD_EVENT_DATA="$TEST_TMP/held-data"
HARNESS_METRICS_DIR="$HELD_EVENT_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
HELD_EVENT="$HELD_EVENT_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
jq -c 'if .kind=="session" then .project="held-old" else . end' "$HELD_EVENT" >"$HELD_EVENT.tmp" && mv "$HELD_EVENT.tmp" "$HELD_EVENT"
HARNESS_METRICS_DIR="$HELD_EVENT_DATA" HM_HARVEST_SESSION_THRESHOLD=1 "$ROOT/scripts/harvest-queue.sh" record "$HELD_EVENT" >/dev/null
assert_file "$HELD_EVENT_DATA/harvest-queue/p-held-old/analysis-batch.json"
jq -c 'if .kind=="session" then .project="held-new" else . end' "$HELD_EVENT" >"$HELD_EVENT.tmp" && mv "$HELD_EVENT.tmp" "$HELD_EVENT"
HARNESS_METRICS_DIR="$HELD_EVENT_DATA" "$ROOT/scripts/harvest-queue.sh" record "$HELD_EVENT" >/dev/null
assert_file "$HELD_EVENT_DATA/harvest-queue/p-held-new/sessions/$MOVE_MARKER"
assert_not_file "$HELD_EVENT_DATA/harvest-queue/p-held-old/sessions/$MOVE_MARKER"
assert_not_file "$HELD_EVENT_DATA/harvest-queue/p-held-old/analysis-batch.json"
# 추출 규칙 변경으로 신호 수만 달라진 재추출은 검토 완료 세션을 다시 큐에 넣지 않는다.
retag_move_event third-name
rm -f "$MOVE_DATA/digests/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json"
assert_eq "unchanged" "$(move_record | jq -r '.record_action')" "re-extraction with changed signal counts stays reviewed"
assert_not_file "$MOVE_DATA/harvest-queue/p-third-name/sessions/$MOVE_MARKER"
assert_eq "0" "$(jq -r '.totals.corrections' "$MOVE_DATA/harvest-queue/p-third-name/seen/$MOVE_MARKER")" "reviewed marker takes the re-extracted totals"
mkdir -p "$MOVE_DATA/harvest-queue/p-stale-name/sessions"
jq -c '.project="stale-name"' "$MOVE_DATA/harvest-queue/p-third-name/seen/$MOVE_MARKER" \
  >"$MOVE_DATA/harvest-queue/p-stale-name/sessions/$MOVE_MARKER"
move_record >/dev/null
assert_not_file "$MOVE_DATA/harvest-queue/p-stale-name/sessions/$MOVE_MARKER"
# 내 큐에는 대기, 옛 큐에는 검토 완료로 갈라진 같은 세션은 검토 완료로 합친다.
mkdir -p "$MOVE_DATA/harvest-queue/p-split-old/seen"
cp "$MOVE_DATA/harvest-queue/p-third-name/seen/$MOVE_MARKER" "$MOVE_DATA/harvest-queue/p-split-old/seen/$MOVE_MARKER"
mv "$MOVE_DATA/harvest-queue/p-third-name/seen/$MOVE_MARKER" "$MOVE_DATA/harvest-queue/p-third-name/sessions/$MOVE_MARKER"
move_record >/dev/null
assert_file "$MOVE_DATA/harvest-queue/p-third-name/seen/$MOVE_MARKER"
assert_not_file "$MOVE_DATA/harvest-queue/p-third-name/sessions/$MOVE_MARKER"
assert_not_file "$MOVE_DATA/harvest-queue/p-split-old/seen/$MOVE_MARKER"
pass "project ID changes keep queue state"

# 정기 backfill: launchd·SessionStart가 주기적으로 세션을 회수한다.
DUE_DATA="$TEST_TMP/due-data"
DUE_CLAUDE="$TEST_TMP/due-claude/-tmp-service"
mkdir -p "$DUE_CLAUDE" "$TEST_TMP/due-codex"
cp "$CLAUDE_FIXTURE" "$DUE_CLAUDE/"
run_due() {
  HARNESS_METRICS_DIR="$DUE_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/due-claude" \
    HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/due-codex" HM_BACKFILL_FOREGROUND=1 \
    HM_BACKFILL_INTERVAL_HOURS="$1" "$ROOT/scripts/backfill-due.sh"
}
run_due 0
assert_not_file "$DUE_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
run_due 24
assert_file "$DUE_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
assert_eq "1" "$(jq -r '.components.backfill.success_count' "$DUE_DATA/health.json")" "first due backfill runs"
run_due 24
assert_eq "1" "$(jq -r '.components.backfill.success_count' "$DUE_DATA/health.json")" "backfill not repeated inside interval"
jq '.components.backfill.last_attempt_at = "2020-01-01T00:00:00Z"' "$DUE_DATA/health.json" >"$DUE_DATA/health.tmp"
mv "$DUE_DATA/health.tmp" "$DUE_DATA/health.json"
run_due 24
assert_eq "2" "$(jq -r '.components.backfill.success_count' "$DUE_DATA/health.json")" "backfill reruns after interval"
mkdir -p "$DUE_DATA/.backfill-due.lock"
printf '%s\n' "$$" >"$DUE_DATA/.backfill-due.lock/pid"
jq '.components.backfill.last_attempt_at = "2020-01-01T00:00:00Z"' "$DUE_DATA/health.json" >"$DUE_DATA/health.tmp"
mv "$DUE_DATA/health.tmp" "$DUE_DATA/health.json"
run_due 24
assert_eq "2" "$(jq -r '.components.backfill.success_count' "$DUE_DATA/health.json")" "running backfill is not duplicated"
find "$DUE_DATA/.backfill-due.lock" -depth -delete
assert_contains "$(<"$ROOT/scripts/session-start.sh")" "backfill-due.sh" "SessionStart schedules backfill"
pass "scheduled background backfill"

finish_tests
