#!/usr/bin/env bash
# 회귀 테스트 — 자동 harvest·자동 적용·자동 sync·자동 병합·스케줄·가드
# 실행: bash tests/run.sh automation
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 자동 harvest: opt-in, 재귀 차단, batch당 1회, 하네스 없는 곳 skip, 일일 상한, 결과 기록
AUTO_DATA="$TEST_TMP/auto-data"
AUTO_REPO="$TEST_TMP/auto-repo"
AUTO_PLAIN="$TEST_TMP/auto-plain"
make_repo "$AUTO_REPO"
make_repo "$AUTO_PLAIN"
mkdir -p "$AUTO_REPO/.ai-harness"
jq -n '{project_id:"auto-svc"}' >"$AUTO_REPO/.ai-harness/harness.json"
AUTO_STUB="$TEST_TMP/auto-stub.sh"
cat >"$AUTO_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "${HM_HARVEST_RUNNING:-}" "$(pwd -P)" >>"$AUTO_STUB_OUT"
case "${AUTO_STUB_MODE:-}" in
  improve)
    # mark-reviewed가 남기는 review-history 레코드 형태
    mkdir -p "$HARNESS_METRICS_DIR/harvest-queue/p-$1"
    jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{reviewed_at:$at,review:{outcome:"improved",artifact:"https://example.com/pr/1"}}' \
      >>"$HARNESS_METRICS_DIR/harvest-queue/p-$1/review-history.jsonl"
    ;;
  fail) exit 3 ;;
  cost) echo "Ignoring 19 permissions.allow entries: workspace not trusted" >&2; echo '{"type":"result","total_cost_usd":0.12}' ;;
  limit) echo '{"type":"result","is_error":true,"api_error_status":429,"api_error":"usage_limit_reached","total_cost_usd":0}'; exit 1 ;;
esac
STUB
chmod +x "$AUTO_STUB"
auto_status() { jq -cn --arg p "$1" --arg b "$2" --arg r "${3:-errors}" '{project:$p,batch_id:$b,has_analysis_batch:true,reasons:($r | split(","))}'; }
auto_trigger() { # $1=status $2=cwd, 추가 env는 호출자가 앞에 붙인다
  HARNESS_METRICS_DIR="$AUTO_DATA" HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$AUTO_STUB" \
    AUTO_STUB_OUT="$TEST_TMP/auto-stub.out" \
    "$ROOT/scripts/harvest-auto.sh" trigger "$1" "$2" claude
}
auto_runs() { jq -sr "$1" "$AUTO_DATA/harvest-auto/runs.jsonl"; }

auto_trigger "$(auto_status auto-svc b1)" "$AUTO_REPO"
assert_not_file "$AUTO_DATA/harvest-auto/runs.jsonl"
HM_HARVEST_AUTO=1 HM_HARVEST_RUNNING=1 auto_trigger "$(auto_status auto-svc b1)" "$AUTO_REPO"
assert_not_file "$AUTO_DATA/harvest-auto/runs.jsonl"
HM_HARVEST_AUTO=1 auto_trigger '{"project":"auto-svc","has_analysis_batch":false}' "$AUTO_REPO"
assert_not_file "$AUTO_DATA/harvest-auto/runs.jsonl"

HM_HARVEST_AUTO=1 auto_trigger "$(auto_status plain b1)" "$AUTO_PLAIN"
HM_HARVEST_AUTO=1 auto_trigger "$(auto_status plain b1)" "$AUTO_PLAIN"
assert_eq 'no_harness_repo' "$(auto_runs '[.[] | select(.project=="plain") | .reason] | join(",")')" "no-harness batch skipped once"

HM_HARVEST_AUTO=1 auto_trigger "$(auto_status auto-svc b0 sessions)" "$AUTO_REPO"
assert_eq "sessions_only" "$(auto_runs 'last | .reason')" "sessions-only batch is left to the notice"
assert_not_file "$TEST_TMP/auto-stub.out"

HM_HARVEST_AUTO=1 auto_trigger "$(auto_status auto-svc b1 sessions,errors)" "$AUTO_REPO"
HM_HARVEST_AUTO=1 auto_trigger "$(auto_status auto-svc b1 sessions,errors)" "$AUTO_REPO"
assert_eq "1" "$(wc -l <"$TEST_TMP/auto-stub.out" | tr -d ' ')" "same batch runs once"
AUTO_RUN_LINE="$(sed -n 1p "$TEST_TMP/auto-stub.out")"
assert_eq "auto-svc|1" "${AUTO_RUN_LINE%|*}" "worker gets project and recursion guard"
AUTO_WORK_DIR="${AUTO_RUN_LINE##*|}"
assert_contains "$AUTO_WORK_DIR" "/auto-worktrees/p-auto-svc-" "agent runs in a dedicated worktree, not the user checkout"
[[ "$AUTO_WORK_DIR" != "$AUTO_DATA"/* ]] || fail "the work tree must be outside the data directory the agent may not write: $AUTO_WORK_DIR"
[[ ! -d "$AUTO_WORK_DIR" ]] || fail "work tree is removed after the run: $AUTO_WORK_DIR"
assert_eq "1" "$(git -C "$AUTO_REPO" worktree list | wc -l | tr -d ' ')" "no leftover worktree registration"
assert_eq "left_for_user" "$(auto_runs '[.[] | select(.event=="finished")] | last | .result')" "unreviewed run is left for user"
assert_eq "12" "$(auto_runs '[.[] | select(.event=="started")] | last | .batch | length')" "run log keeps a short batch key"

HM_HARVEST_AUTO=1 AUTO_STUB_MODE=improve auto_trigger "$(auto_status auto-svc b2)" "$AUTO_REPO"
assert_eq 'improved|https://example.com/pr/1' "$(auto_runs '[.[] | select(.event=="finished")] | last | "\(.result)|\(.artifact)"')" "review outcome recorded"
assert_eq "success" "$(jq -r '.components.harvest_auto.last_result' "$AUTO_DATA/health.json")" "auto health success"

HM_HARVEST_AUTO=1 auto_trigger "$(auto_status auto-svc b3)" "$AUTO_REPO"
assert_eq "daily_max" "$(auto_runs 'last | .reason')" "daily cap skips without consuming batch"
assert_eq "b2" "$(jq -r '.batch_id' "$AUTO_DATA/harvest-queue/p-auto-svc/auto-attempted-batch")" "capped batch stays retryable"

HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_DAILY_MAX=5 AUTO_STUB_MODE=fail auto_trigger "$(auto_status auto-svc b3)" "$AUTO_REPO"
assert_eq "failed|3" "$(auto_runs '[.[] | select(.event=="finished")] | last | "\(.result)|\(.exit_code)"')" "failed run recorded"
assert_eq "exit_3" "$(jq -r '.components.harvest_auto.last_error' "$AUTO_DATA/health.json")" "auto health failure"
assert_file "$(auto_runs '[.[] | select(.event=="finished")] | last | .log')"
# 실제 claude 실행 인자: 허용 목록의 스크립트 경로와 로드되는 플러그인이 같은 설치본이어야 한다.
# shellcheck disable=SC2016  # 스크립트 원문의 literal 변수 참조를 검사
AUTO_ARGS="$(sed -n '/AGENT_CMD=(claude/,/--output-format stream-json --verbose)/p' "$ROOT/scripts/harvest-auto.sh")"
# shellcheck disable=SC2016
assert_contains "$AUTO_ARGS" '--plugin-dir "$plugin_root"' "agent loads the same plugin copy it is allowed to run"
# shellcheck disable=SC2016
assert_contains "$AUTO_ARGS" '"Bash($scripts_dir/*)"' "agent may run that copy's scripts through the stable link"
# shellcheck disable=SC2016
assert_contains "$AUTO_ARGS" '--scripts $scripts_dir' "agent is told the stable scripts path it is allowed to run"
# shellcheck disable=SC2016
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" 'plugin_root="$(hm_claude_plugin_root "$ROOT")"' "claude worker uses the installed copy claude would load"
# shellcheck disable=SC2016
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" '--add-dir "$plugin_root"' "agent can read the plugin copy outside the work tree"
# --plugin-dir과 같은 이름의 설치본이 있으면 claude는 버전이 높은 쪽을 로드한다(#366).
# 가장 높은 설치본을 고르고, 없거나 스크립트가 없는 경로는 건너뛰고, 못 찾으면 기본값.
PR_CFG="$TEST_TMP/plugin-root-cfg"
mkdir -p "$PR_CFG/plugins" "$TEST_TMP/pr-0.77.0/scripts" "$TEST_TMP/pr-0.68.0/scripts" "$TEST_TMP/pr-0.80.0"
jq -n --arg a "$TEST_TMP/pr-0.77.0" --arg b "$TEST_TMP/pr-0.68.0" --arg c "$TEST_TMP/pr-0.80.0" --arg d "$TEST_TMP/pr-missing" '{version: 2, plugins: {
  "ai-harness@ai-harness": [{scope: "user", installPath: $a, version: "0.77.0"}, {scope: "project", installPath: $b, version: "0.68.0"}, {scope: "user", installPath: $c, version: "0.80.0"}],
  "ai-harness@other": [{scope: "user", installPath: $d, version: "0.99.0"}],
  "other@ai-harness": [{scope: "user", installPath: $b, version: "1.0.0"}]}}' >"$PR_CFG/plugins/installed_plugins.json"
assert_eq "$TEST_TMP/pr-0.77.0" "$(CLAUDE_CONFIG_DIR="$PR_CFG" hm_claude_plugin_root /fallback)" "highest installed copy with scripts is chosen"
printf '{}' >"$PR_CFG/plugins/installed_plugins.json"
assert_eq "/fallback" "$(CLAUDE_CONFIG_DIR="$PR_CFG" hm_claude_plugin_root /fallback)" "no installed copy falls back"
assert_eq "/fallback" "$(CLAUDE_CONFIG_DIR="$TEST_TMP/no-such-cfg" hm_claude_plugin_root /fallback)" "missing plugin state falls back"
# 허용 규칙은 경로 문자열 앞부분 일치라, 설치 경로가 버전·프로필로 바뀌거나 공백이 있으면(에이전트가 따옴표로 감싼다)
# 일치하지 않는다(#400). 데이터 디렉토리 아래 공백 없는 고정 링크 하나로 규칙과 호출 경로를 통일한다.
SP_DATA="$TEST_TMP/stable-link-data"
mkdir -p "$TEST_TMP/Application Support/pr-0.80.0/scripts" "$TEST_TMP/pr-0.81.0/scripts"
SP_LINK="$(HM_DATA_DIR="$SP_DATA" hm_auto_plugin_link "$TEST_TMP/Application Support/pr-0.80.0")"
assert_eq "$SP_DATA/run/plugin" "$SP_LINK" "stable plugin link lives under the data directory"
assert_eq "$TEST_TMP/Application Support/pr-0.80.0" "$(readlink "$SP_LINK")" "stable link points at the copy claude loads"
[[ -d "$SP_LINK/scripts" ]] || fail "stable link resolves to the scripts directory"
SP_LINK="$(HM_DATA_DIR="$SP_DATA" hm_auto_plugin_link "$TEST_TMP/pr-0.81.0")"
assert_eq "$TEST_TMP/pr-0.81.0" "$(readlink "$SP_LINK")" "stable link follows a plugin update between runs"
# shellcheck disable=SC2016
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" 'scripts_dir="$(hm_auto_plugin_link "$plugin_root")/scripts"' "harvest worker allows scripts through the stable link"
for SP_SKILL in harvest harness-init autofix; do
  # shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
  assert_contains "$(<"$ROOT/skills/$SP_SKILL/SKILL.md")" '`--scripts <dir>`' "$SP_SKILL skill uses the scripts path the unattended worker passes"
done
pass "unattended runs call plugin scripts through a stable space-free link"
# shellcheck disable=SC2016
assert_contains "$AUTO_ARGS" '"${read_dirs[@]}"' "agent can read events and transcripts outside the work tree"
# shellcheck disable=SC2016
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" '--add-dir "$HM_DATA_DIR" --add-dir "$HM_CLAUDE_PROJECTS_DIR"' "data and transcript dirs are added"
# 에이전트 선택: 세션 도구가 아니라 실행 능력으로. 설정이 우선, 기본은 claude가 있으면 claude.
AGENT_BIN="$TEST_TMP/agent-bin"
mkdir -p "$AGENT_BIN"
printf '#!/bin/sh\n' >"$AGENT_BIN/claude"; chmod +x "$AGENT_BIN/claude"
resolve_agent_with() { # $1=PATH $2=설정
  PATH="$1" HM_HARVEST_AUTO_AGENT="$2" HARNESS_METRICS_DIR="$TEST_TMP/agent-data" "$ROOT/scripts/harvest-auto.sh" agent
}
SYS_PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin"
assert_eq "claude" "$(resolve_agent_with "$AGENT_BIN:$SYS_PATH" auto)" "claude is preferred when installed"
assert_eq "codex" "$(resolve_agent_with "$SYS_PATH" auto)" "codex is the fallback without claude"
assert_eq "codex" "$(resolve_agent_with "$AGENT_BIN:$SYS_PATH" codex)" "explicit agent setting wins"
# shellcheck disable=SC2016
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" 'agent="$(resolve_agent)"' "trigger ignores the session tool when picking the agent"
# shellcheck disable=SC2016
assert_contains "$(sed -n '/    codex)$/,/;;/p' "$ROOT/scripts/harvest-auto.sh")" '--approve-for-me' "codex runs with a current sandbox flag"
HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_DAILY_MAX=9 HM_HARVEST_AUTO_AGENT=claude AUTO_STUB_MODE=cost \
  auto_trigger "$(auto_status auto-svc b-cost)" "$AUTO_REPO"
assert_eq "0.12" "$(auto_runs '[.[] | select(.event=="finished")] | last | .cost_usd')" "cost is read past stderr notices"
# 진행 기록(#296): 시간 제한으로 끊겨도 어디까지 갔는지 보이려면 claude 실행이 stream-json이어야 하고, 출력은 필터를 거쳐 로그에 남는다.
HARVEST_AUTO_SRC="$(<"$ROOT/scripts/harvest-auto.sh")"
assert_file "$ROOT/scripts/agent-progress.jq"
assert_eq "0" "$(grep -c -e '--output-format json)' "$ROOT/scripts/harvest-auto.sh" || true)" "no claude run keeps the single-result json output format"
[[ "$(grep -c -e '--output-format stream-json --verbose)' "$ROOT/scripts/harvest-auto.sh" || true)" -ge 2 ]] \
  || fail "project/sync and global claude runs use stream-json with --verbose"
assert_contains "$HARVEST_AUTO_SRC" "agent-progress.jq" "the agent output goes through the progress filter before it reaches the log"
pass "harvest-auto claude runs stream their progress through the filter"

# 필터 단위: 도구 호출은 progress 줄, result는 그대로, JSON이 아닌 줄은 stderr 줄. 파일 내용·모델 문장·명령 인자·본문은 디스크에 남기지 않는다.
AGENT_STREAM_FIX="$ROOT/tests/fixtures/agent-stream/sample.ndjson"
AGENT_STREAM_OUT="$(jq -R -c -f "$ROOT/scripts/agent-progress.jq" "$AGENT_STREAM_FIX")"
assert_eq "progress,result,stderr" "$(jq -sr '[.[].type] | unique | join(",")' <<<"$AGENT_STREAM_OUT")" "the filter emits only progress, result and stderr lines"
assert_eq "Read,Bash,Bash,Write,Edit,Grep,Agent,Read" "$(jq -sr '[.[] | select(.type == "progress") | .tool] | join(",")' <<<"$AGENT_STREAM_OUT")" "one progress line per tool call, in order"
assert_eq "true" "$(jq -sr '[.[] | select(.type == "progress") | .at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}")] | all' <<<"$AGENT_STREAM_OUT")" "progress lines carry an ISO time"
AGENT_STREAM_TARGETS="$(jq -sr '[.[] | select(.type == "progress") | .target] | @json' <<<"$AGENT_STREAM_OUT")"
assert_eq "예시 서버 상태 확인" "$(jq -r '.[1]' <<<"$AGENT_STREAM_TARGETS")" "a Bash call shows its description"
assert_eq "gh" "$(jq -r '.[2]' <<<"$AGENT_STREAM_TARGETS")" "a Bash call without a description shows only the command name"
assert_eq "true" "$(jq -r '(.[0] | endswith("config/app.yml")) and (.[3] | endswith("notes.md")) and (.[4] | endswith("src/cart.py"))' <<<"$AGENT_STREAM_TARGETS")" "file tools show the file path"
AGENT_STREAM_PAT="$(jq -R -r 'fromjson? | select(.message.content[0].name? == "Grep") | .message.content[0].input.pattern' "$AGENT_STREAM_FIX")"
assert_contains "$(jq -r '.[5]' <<<"$AGENT_STREAM_TARGETS")" "${AGENT_STREAM_PAT:0:60}" "a Grep call shows the start of its pattern"
[[ "$(jq -r '.[5]' <<<"$AGENT_STREAM_TARGETS")" != *"${AGENT_STREAM_PAT:0:61}"* ]] || fail "a Grep pattern is cut at 60 characters"
assert_eq "true" "$(jq -r 'all(.[]; length <= 160)' <<<"$AGENT_STREAM_TARGETS")" "targets are cut at 160 characters"
assert_eq "$(jq -R -c 'fromjson? | select(.type == "result")' "$AGENT_STREAM_FIX")" "$(jq -c 'select(.type == "result")' <<<"$AGENT_STREAM_OUT")" "the result event passes through unchanged"
assert_eq "3" "$(jq -s '[.[] | select(.type == "stderr")] | length' <<<"$AGENT_STREAM_OUT")" "each non-JSON line becomes a stderr line"
assert_eq "Ignoring 19 permissions.allow entries: workspace not trusted" "$(jq -sr '[.[] | select(.type == "stderr")] | .[0].text' <<<"$AGENT_STREAM_OUT")" "a stderr notice keeps its text"
assert_eq "true" "$(jq -sr '[.[] | select(.type == "stderr") | .text | length] | all(. <= 300)' <<<"$AGENT_STREAM_OUT")" "stderr text is cut at 300 characters"
for AGENT_STREAM_SECRET in MODEL_SENTENCE_ONE MODEL_SENTENCE_TWO FILE_CONTENT_SECRET FAKE_KEY_0000 FAKE_TOKEN_123 FAKE_TITLE_ARG FAKE_BODY_ARG \
  WRITE_BODY_SECRET EDIT_OLD_SECRET EDIT_NEW_SECRET AGENT_PROMPT_SECRET STDERR_TAIL_MARK; do
  case "$AGENT_STREAM_OUT" in *"$AGENT_STREAM_SECRET"*) fail "the filter drops $AGENT_STREAM_SECRET (file contents, model sentences, command arguments, bodies, prompts)" ;; esac
done
# 이상한 도구 입력(문자열이 아닌 command)이 있어도 원문 줄을 stderr 줄로 흘리지 않는다(jq 1.6 try/catch가 뒤쪽 오류까지 잡는 문제).
AGENT_STREAM_ODD='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"a.txt","content":"ODD_WRITE_SECRET"}},{"type":"tool_use","name":"Bash","input":{"command":["ODD_ARG_SECRET"]}}]}}'
AGENT_STREAM_ODD_OUT="$(jq -R -c -f "$ROOT/scripts/agent-progress.jq" <<<"$AGENT_STREAM_ODD" 2>/dev/null || true)"
case "$AGENT_STREAM_ODD_OUT" in *ODD_WRITE_SECRET*|*ODD_ARG_SECRET*|*'"type":"stderr"'*) fail "an odd tool input does not leak the raw event as a stderr line" ;; esac
assert_eq "Write" "$(jq -sr '[.[] | select(.type == "progress") | .tool] | first // empty' <<<"$AGENT_STREAM_ODD_OUT")" "an odd tool input still leaves the progress lines before it"
pass "agent-progress.jq keeps tool calls and the result, and drops contents, sentences and arguments"

# 가짜 claude로 무인 실행을 한 번 돌린다: 로그에 progress·result 줄이 남고 비용 파싱이 그대로이며, 끊겨도 종료 코드가 남고, 빈 로그는 지운다.
AUTO_FAKE="$TEST_TMP/auto-fake-claude"
AUTO_FAKE_DATA="$AUTO_FAKE/data"
mkdir -p "$AUTO_FAKE/bin"
cat >"$AUTO_FAKE/bin/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CLAUDE_ARGS"
case "${FAKE_CLAUDE_MODE:-stream}" in
  silent) exit 0 ;;
  fail) echo "stderr notice from the agent" >&2; head -n 6 "$FAKE_CLAUDE_STREAM"; exit 3 ;;
  *) echo "stderr notice from the agent" >&2; cat "$FAKE_CLAUDE_STREAM" ;;
esac
FAKE
chmod +x "$AUTO_FAKE/bin/claude"
auto_fake_run() { # $1=batch $2=mode
  PATH="$AUTO_FAKE/bin:$PATH" HARNESS_METRICS_DIR="$AUTO_FAKE_DATA" HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_FOREGROUND=1 \
    HM_HARVEST_AUTO_AGENT=claude HM_HARVEST_AUTO_DAILY_MAX=9 FAKE_CLAUDE_MODE="$2" FAKE_CLAUDE_ARGS="$AUTO_FAKE/args.log" \
    FAKE_CLAUDE_STREAM="$AGENT_STREAM_FIX" "$ROOT/scripts/harvest-auto.sh" trigger "$(auto_status auto-svc "$1")" "$AUTO_REPO" claude
}
auto_fake_finished() { jq -sr "[.[] | select(.event==\"finished\")] | last | $1" "$AUTO_FAKE_DATA/harvest-auto/runs.jsonl"; }
auto_fake_run b-stream stream
AUTO_FAKE_LOG="$(auto_fake_finished '.log')"
assert_file "$AUTO_FAKE_LOG"
assert_contains "$(<"$AUTO_FAKE/args.log")" "--output-format stream-json" "the agent is asked for a stream"
assert_contains "$(<"$AUTO_FAKE/args.log")" "--verbose" "stream-json needs --verbose"
assert_eq "8" "$(jq -R -c 'fromjson? | select(.type == "progress")' "$AUTO_FAKE_LOG" | wc -l | tr -d ' ')" "the log keeps one progress line per tool call"
assert_eq "1" "$(jq -R -c 'fromjson? | select(.type == "result")' "$AUTO_FAKE_LOG" | wc -l | tr -d ' ')" "the log keeps the result line"
assert_contains "$(<"$AUTO_FAKE_LOG")" '"text":"stderr notice from the agent"' "a stderr notice is kept as a stderr line"
case "$(<"$AUTO_FAKE_LOG")" in *FILE_CONTENT_SECRET*|*MODEL_SENTENCE*|*FAKE_TOKEN*) fail "the run log carries no file contents, model sentences or command arguments" ;; esac
assert_eq "0.34" "$(auto_fake_finished '.cost_usd')" "the cost is still read from the result line"
assert_eq "0" "$(auto_fake_finished '.exit_code')" "a streamed run ends with the agent's exit code"
pass "harvest-auto run with a streaming agent leaves progress and result lines and keeps the cost"

# 끊긴 실행: 에이전트가 비정상 종료해도(pipefail) 종료 코드가 남고, 그때까지의 진행 줄은 로그에 있다.
auto_fake_run b-fail fail
assert_eq "failed|3" "$(auto_fake_finished '"\(.result)|\(.exit_code)"')" "the agent's exit code survives the progress filter"
assert_contains "$(<"$(auto_fake_finished '.log')")" '"type":"progress"' "progress made before the agent died is in the log"
pass "harvest-auto keeps the agent exit code and the progress so far when the agent dies"

# 아무것도 못 남긴 실행의 0바이트 로그는 지운다(보드가 빈 로그 서랍을 열지 않게).
auto_fake_run b-silent silent
assert_not_file "$(auto_fake_finished '.log')"
pass "harvest-auto removes an empty log after the run"

# 사용자·테스트 실행기(HM_HARVEST_AUTO_CMD)는 필터를 거치지 않는다: 출력이 그대로 로그에 남는다.
AUTO_RAW_LOG="$(auto_runs '[.[] | select(.event=="finished")] | last | .log')"  # 바로 앞 b-cost 실행
assert_contains "$(<"$AUTO_RAW_LOG")" "Ignoring 19 permissions.allow entries: workspace not trusted" "a custom runner's output is logged as is"
case "$(<"$AUTO_RAW_LOG")" in *'"type":"stderr"'*) fail "a custom runner's output does not go through the progress filter" ;; esac
pass "harvest-auto custom runner bypasses the progress filter"

# 기준 브랜치: origin/HEAD(master)에는 하네스가 없고 develop에만 있으면 develop에서 작업한다.
BASE_ORIGIN="$TEST_TMP/base-origin.git"
BASE_REPO="$TEST_TMP/base-repo"
git init -q --bare "$BASE_ORIGIN"
make_repo "$BASE_REPO" "$BASE_ORIGIN"
git -C "$BASE_REPO" branch -M master
git -C "$BASE_REPO" push -q origin master
git -C "$BASE_REPO" checkout -q -b develop
mkdir -p "$BASE_REPO/.ai-harness"
jq -n '{project_id:"base-svc"}' >"$BASE_REPO/.ai-harness/harness.json"
git -C "$BASE_REPO" add .ai-harness && git -C "$BASE_REPO" commit -q -m harness
git -C "$BASE_REPO" push -q origin develop
git -C "$BASE_REPO" remote set-head origin master
BASE_STUB="$TEST_TMP/base-stub.sh"
printf '#!/bin/bash\n[[ -f .ai-harness/harness.json ]] && echo has-harness >>"%s" || echo no-harness >>"%s"\n' \
  "$TEST_TMP/base-stub.out" "$TEST_TMP/base-stub.out" >"$BASE_STUB"
chmod +x "$BASE_STUB"
HARNESS_METRICS_DIR="$TEST_TMP/base-data" HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$BASE_STUB" \
  "$ROOT/scripts/harvest-auto.sh" trigger "$(auto_status base-svc b1)" "$BASE_REPO"
assert_eq "has-harness" "$(cat "$TEST_TMP/base-stub.out")" "work tree starts from the branch that carries the harness"
# shellcheck disable=SC2016
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" '--auto --base $base' "agent is told the PR base"
HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_DAILY_MAX=9 HM_HARVEST_AUTO_AGENT=claude AUTO_STUB_MODE=limit \
  auto_trigger "$(auto_status auto-svc b-limit)" "$AUTO_REPO"
assert_eq "failed|usage_limit" "$(auto_runs '[.[] | select(.event=="finished")] | last | "\(.result)|\(.reason)"')" "usage limit is recorded as the failure reason"
assert_eq "failed|0" "$(jq -r '"\(.result)|\(.fails)"' "$AUTO_DATA/harvest-queue/p-auto-svc/auto-attempted-batch")" "usage limit keeps the batch retryable without counting a failure"
assert_eq "usage_limit" "$(jq -r '.components.harvest_auto.last_error' "$AUTO_DATA/health.json")" "health names the usage limit"
# 결정적으로 실패하는 batch는 MAX_FAILS(기본 3)번 뒤 포기해 다른 프로젝트의 차례를 막지 않는다.
for _ in 1 2 3 4; do
  HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_DAILY_MAX=99 HM_HARVEST_AUTO_AGENT=claude AUTO_STUB_MODE=fail \
    auto_trigger "$(auto_status auto-svc b-broken)" "$AUTO_REPO"
done
# shellcheck disable=SC2016
assert_eq "3" "$(auto_runs '(map(select(.event=="started")) | last | .batch) as $b | [.[] | select(.event=="finished" and .batch==$b)] | length')" "a failing batch runs at most three times"
assert_eq "gave_up" "$(auto_runs 'last | .reason')" "then it is given up"
assert_eq "gave_up" "$(jq -r '.result' "$AUTO_DATA/harvest-queue/p-auto-svc/auto-attempted-batch")" "and stays given up"
# 로그인 만료(#315): 이전 버전이 인증 실패를 세어 포기한 batch는 로그로 판정해 다시 시도한다.
printf '%s\n' '{"type":"result","is_error":true,"terminal_reason":"api_error","result":"Failed to authenticate. Run claude auth login"}' >"$TEST_TMP/auto-legacy-auth.log"
jq -cn '{batch_id:"b-legacy",at:"2026-01-01T00:00:00Z",result:"gave_up",fails:3}' >"$AUTO_DATA/harvest-queue/p-auto-svc/auto-attempted-batch"
for _ in 1 2 3; do
  jq -cn --arg b "$(printf '%s' b-legacy | { shasum 2>/dev/null || sha1sum; } | cut -c1-12)" --arg l "$TEST_TMP/auto-legacy-auth.log" \
    '{at:"2026-01-01T00:00:00Z",event:"finished",project:"auto-svc",batch:$b,scope:"project",result:"failed",exit_code:1,reason:"agent_error",log:$l}' \
    >>"$AUTO_DATA/harvest-auto/runs.jsonl"
done
AUTO_LEGACY_KEY="$(printf '%s' b-legacy | { shasum 2>/dev/null || sha1sum; } | cut -c1-12)"
HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_DAILY_MAX=99 HM_HARVEST_AUTO_AGENT=claude auto_trigger "$(auto_status auto-svc b-legacy)" "$AUTO_REPO"
assert_eq "1|true" "$(jq -sr --arg b "$AUTO_LEGACY_KEY" '[.[] | select(.event=="started" and .batch==$b)] | length' "$AUTO_DATA/harvest-auto/runs.jsonl")|$(jq -r '.auth_checked' "$AUTO_DATA/harvest-queue/p-auto-svc/auto-attempted-batch")" "a batch given up only for expired logins runs again"
# 분류는 API 오류로 끝난 결과 줄만 문구로 본다 — 작업 실패 보고에 같은 문구가 섞여도 로그인 만료가 아니다.
af_reason() { printf '%s\n' "$1" | jq -Rrn -L "$ROOT/scripts" 'include "fail-reason"; log_fail_reason'; }
assert_eq "auth_expired" "$(af_reason '{"type":"result","is_error":true,"api_error_status":401,"result":"x"}')" "a 401 is an expired login"
assert_eq "auth_expired" "$(af_reason '{"type":"result","is_error":true,"terminal_reason":"api_error","result":"OAuth session expired and could not be refreshed"}')" "an expired OAuth session without the authenticate prefix is an expired login"
assert_eq "auth_expired" "$(af_reason '{"type":"result","is_error":true,"terminal_reason":"api_error","result":"OAuth token has expired"}')" "an expired OAuth token is still an expired login"
assert_eq "agent_error" "$(af_reason '{"type":"result","is_error":true,"terminal_reason":"max_turns","result":"setup-token 문서를 고치다 실패"}')" "a work failure mentioning setup-token is not an expired login"
assert_eq "" "$(af_reason '{"type":"result","is_error":false,"result":"claude auth login 안내를 추가함"}')" "a successful run is not a failure"
pass "a harvest batch given up for expired logins is retried and the classifier ignores work reports"

pass "opt-in background harvest trigger"

# 자동 harvest가 띄운 headless 세션은 프로젝트 신호로 집계하지 않는다.
INTERNAL_DATA="$TEST_TMP/internal-data"
INTERNAL_TRANSCRIPT="$TEST_TMP/internal/cccccccc-1111-2222-3333-dddddddddddd.jsonl"
mkdir -p "${INTERNAL_TRANSCRIPT%/*}"
INTERNAL_FIRST=0
while IFS= read -r line; do
  if (( INTERNAL_FIRST == 0 )) && jq -e 'select(.type=="user" and (.message.content|type)=="string")' <<<"$line" >/dev/null 2>&1; then
    jq -c '.message.content = "<command-name>/ai-harness:harvest</command-name>\n<command-args>service --auto</command-args>"' <<<"$line"
    INTERNAL_FIRST=1
  else
    printf '%s\n' "$line"
  fi
done <"$CLAUDE_FIXTURE" >"$INTERNAL_TRANSCRIPT"
INTERNAL_EVENT="$INTERNAL_DATA/events/claude-cccccccc-1111-2222-3333-dddddddddddd.jsonl"
HARNESS_METRICS_DIR="$INTERNAL_DATA" "$ROOT/scripts/extract-claude.sh" "$INTERNAL_TRANSCRIPT" "other"
assert_eq "true" "$(jq -r 'select(.kind=="session") | .internal' "$INTERNAL_EVENT")" "auto harvest session is marked internal"
HARNESS_METRICS_DIR="$INTERNAL_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
assert_eq "false" "$(jq -r 'select(.kind=="session") | .internal' "$INTERNAL_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl")" "normal session is not internal"
INTERNAL_MARKER="claude-cccccccc-1111-2222-3333-dddddddddddd.json"
mkdir -p "$INTERNAL_DATA/harvest-queue/p-service/sessions"
jq -cn '{project:"service",src:"claude",sid:"cccccccc-1111-2222-3333-dddddddddddd"}' \
  >"$INTERNAL_DATA/harvest-queue/p-service/sessions/$INTERNAL_MARKER"
HARNESS_METRICS_DIR="$INTERNAL_DATA" "$ROOT/scripts/harvest-queue.sh" record "$INTERNAL_EVENT" >/dev/null
assert_not_file "$INTERNAL_DATA/harvest-queue/p-service/sessions/$INTERNAL_MARKER"
pass "internal auto-harvest sessions stay out of the queue"

# open-pr.sh: 원격을 보고 GitHub/Bitbucket draft PR 요청을 만든다.
PR_REPO="$TEST_TMP/pr-repo"
make_repo "$PR_REPO" "git@bitbucket.org:acme/jobda-agent.git"
git -C "$PR_REPO" checkout -q -b feature/NJ-1-harvest
printf 'body\n' >"$TEST_TMP/pr-body.md"
PR_BB="$(cd "$PR_REPO" && HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --title t --body-file "$TEST_TMP/pr-body.md" --base develop)"
assert_eq "bitbucket|acme/jobda-agent|true|feature/NJ-1-harvest|develop|body" \
  "$(jq -r '[.provider,.slug,.draft,.source.branch.name,.destination.branch.name,(.description|rtrimstr("\n"))] | map(tostring) | join("|")' <<<"$PR_BB")" "Bitbucket draft PR request"
git -C "$PR_REPO" remote set-url origin https://github.com/acme/woorinal.git
PR_GH="$(cd "$PR_REPO" && HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --title t --body-file "$TEST_TMP/pr-body.md" --base main)"
assert_eq "github|acme/woorinal|true" "$(jq -r '[.provider,.slug,.draft] | map(tostring) | join("|")' <<<"$PR_GH")" "GitHub draft PR request"
git -C "$PR_REPO" remote set-url origin git@gitlab.com:acme/x.git
if (cd "$PR_REPO" && HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --title t --body-file "$TEST_TMP/pr-body.md" 2>/dev/null); then
  fail "unsupported host must fail"
fi
git -C "$PR_REPO" remote set-url origin git@bitbucket.org:acme/jobda-agent.git
PR_NOAUTH_RC=0
(cd "$PR_REPO" && ATLASSIAN_USER="" BITBUCKET_API_TOKEN="" HARNESS_CLAUDE_SETTINGS="$TEST_TMP/no-settings.json" "$ROOT/scripts/open-pr.sh" --title t --body-file "$TEST_TMP/pr-body.md" >/dev/null 2>&1) || PR_NOAUTH_RC=$?
assert_eq "4" "$PR_NOAUTH_RC" "Bitbucket without credentials fails before any request"
PR_CHECK_RC=0
(cd "$PR_REPO" && ATLASSIAN_USER="" BITBUCKET_API_TOKEN="" HARNESS_CLAUDE_SETTINGS="$TEST_TMP/no-settings.json" "$ROOT/scripts/open-pr.sh" --check >/dev/null 2>&1) || PR_CHECK_RC=$?
assert_eq "4" "$PR_CHECK_RC" "pre-push check fails without credentials"
git -C "$PR_REPO" remote set-url origin git@gitlab.com:acme/x.git
PR_CHECK_RC=0
(cd "$PR_REPO" && "$ROOT/scripts/open-pr.sh" --check >/dev/null 2>&1) || PR_CHECK_RC=$?
assert_eq "3" "$PR_CHECK_RC" "pre-push check rejects unsupported hosts"
pass "draft PR opener for GitHub and Bitbucket"

# LLM 정리: 정규식이 놓친 마찰을 findings로 남기고 insights 신호로 센다.
DIGEST_DATA="$TEST_TMP/digest-data"
HARNESS_METRICS_DIR="$DIGEST_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
DIGEST_EVENT="$DIGEST_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
assert_file "$DIGEST_EVENT"
DIGEST_STUB="$TEST_TMP/digest-stub.sh"
cat >"$DIGEST_STUB" <<'STUB'
#!/usr/bin/env bash
cat >"$DIGEST_STUB_INPUT"
printf '%s\n' '{"findings":[
 {"category":"missing_context","summary":"배포 대상을 몰랐다","evidence":"배포했는데","harness_fix":"docs에 배포 절차","confidence":"high"},
 {"category":"correction","summary":"브랜치 기준 교정","evidence":"develop 기준","harness_fix":"AGENTS.md 규칙","confidence":"medium"},
 {"category":"other","summary":"애매함","evidence":"x","harness_fix":"y","confidence":"low"}],"cost_usd":0.002}'
STUB
chmod +x "$DIGEST_STUB"
run_digest() {
  HARNESS_METRICS_DIR="$DIGEST_DATA" HM_DIGEST_CMD="$DIGEST_STUB" DIGEST_STUB_INPUT="$TEST_TMP/digest-input.txt" \
    HM_DIGEST_LOOKBACK_DAYS=36500 HM_DIGEST_MIN_TURNS=1 "$ROOT/scripts/digest.sh" "$@"
}
assert_contains "$(run_digest run)" "정리 1" "due session is digested"
DIGEST_FILE="$DIGEST_DATA/digests/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json"
assert_eq "3" "$(jq '.findings | length' "$DIGEST_FILE")" "findings stored"
assert_contains "$(<"$TEST_TMP/digest-input.txt")" "[U] " "model input carries user turns"
assert_eq "2" "$(jq -r '.insights' "$DIGEST_DATA/harvest-queue/p-service/sessions/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.json")" "low-confidence findings are not counted"
assert_contains "$(run_digest run)" "정리 0" "unchanged session is not digested twice"
# v1 시절 findings가 빈 정리는 입력 없이 만든 것일 수 있어 다시 정리한다. v2 빈 결과는 그대로 둔다.
cp "$DIGEST_FILE" "$DIGEST_FILE.orig"
jq -c '.v = 1 | .findings = []' "$DIGEST_FILE" >"$DIGEST_FILE.tmp" && mv "$DIGEST_FILE.tmp" "$DIGEST_FILE"
assert_contains "$(run_digest run)" "정리 1" "empty v1 digest is redone"
assert_eq "2" "$(jq -r '.v' "$DIGEST_FILE")" "redone digest is v2"
jq -c '.findings = []' "$DIGEST_FILE" >"$DIGEST_FILE.tmp" && mv "$DIGEST_FILE.tmp" "$DIGEST_FILE"
assert_contains "$(run_digest run)" "정리 0" "empty v2 digest is kept"
mv "$DIGEST_FILE.orig" "$DIGEST_FILE"
# 시간 제한 래퍼는 백그라운드로 띄우므로 스크립트에서는 표준입력이 /dev/null로 바뀐다 — 이어 줘야 한다.
# (실측: LLM 정리가 2026-10-12부터 빈 입력을 받아 findings가 늘 0건)
printf 'source "%s/scripts/lib.sh"\nprintf piped-input | hm_run_with_timeout 5 cat\n' "$ROOT" >"$TEST_TMP/timeout-stdin.sh"
assert_eq "piped-input" "$(/bin/bash "$TEST_TMP/timeout-stdin.sh" </dev/null)" "hm_run_with_timeout passes piped stdin inside a script"
HARNESS_METRICS_DIR="$DIGEST_DATA" HM_HARVEST_SESSION_THRESHOLD=0 HM_HARVEST_CORRECTION_THRESHOLD=0 \
  HM_HARVEST_ERROR_THRESHOLD=0 HM_HARVEST_GUARD_THRESHOLD=0 HM_HARVEST_PERMISSION_THRESHOLD=0 \
  HM_HARVEST_INSIGHT_THRESHOLD=2 HM_HARVEST_INSIGHT_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" status --project service >"$TEST_TMP/digest-status.json"
assert_eq '["insights"]' "$(jq -c '.reasons' "$TEST_TMP/digest-status.json")" "insights alone can form a batch"
DIGEST_SHOW="$(run_digest show --project service)"
assert_eq "2" "$(jq '.findings | length' <<<"$DIGEST_SHOW")" "show lists medium/high findings of the batch"
HARNESS_METRICS_DIR="$DIGEST_DATA" HM_DIGEST_DAILY_MAX=1 HM_DIGEST_CMD="$DIGEST_STUB" DIGEST_STUB_INPUT=/dev/null \
  "$ROOT/scripts/digest.sh" run | grep -q "상한" || fail "daily cap stops further digests"
INTERNAL_HOOK_DATA="$TEST_TMP/internal-hook-data"
jq -n --arg tp "$CLAUDE_FIXTURE" '{transcript_path:$tp,reason:"other"}' \
  | HARNESS_METRICS_DIR="$INTERNAL_HOOK_DATA" HM_INTERNAL_SESSION=1 "$ROOT/scripts/collect.sh"
assert_not_file "$INTERNAL_HOOK_DATA/health.json"
assert_not_file "$INTERNAL_HOOK_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
pass "LLM session digest feeds insights"

# sweep: 세션 종료 hook 없이 batch가 있는 프로젝트를 찾아 자동 실행한다.
SWEEP_DATA="$TEST_TMP/sweep-data"
mkdir -p "$SWEEP_DATA/events" "$SWEEP_DATA/harvest-queue/p-auto-svc" "$SWEEP_DATA/harvest-queue/p-plain"
make_sweep_batch() { # $1=project $2=cwd $3=created_at
  local ev="$SWEEP_DATA/events/claude-sweep-$1.jsonl"
  jq -cn --arg p "$1" --arg cwd "$2" '{kind:"session",src:"claude",sid:("sweep-"+$p),project:$p,cwd:$cwd}' >"$ev"
  jq -cn --arg p "$1" --arg ev "$ev" --arg at "$3" \
    '{project:$p,batch_id:("b-"+$p),created_at:$at,reasons:["errors"],event_files:[$ev]}' \
    >"$SWEEP_DATA/harvest-queue/p-$1/analysis-batch.json"
}
make_sweep_batch plain "$AUTO_PLAIN" "2026-01-01T00:00:00Z"
make_sweep_batch auto-svc "$AUTO_REPO" "2026-01-02T00:00:00Z"
: >"$TEST_TMP/sweep-stub.out"
run_sweep() {
  HARNESS_METRICS_DIR="$SWEEP_DATA" HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_DAILY_MAX=9 HM_HARVEST_GLOBAL_DAYS=0 HM_HARVEST_AUTO_CMD="$AUTO_STUB" \
    AUTO_STUB_OUT="$TEST_TMP/sweep-stub.out" "$ROOT/scripts/harvest-auto.sh" sweep
}
run_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/sweep-stub.out" | tr -d ' ')" "sweep launches the harness project's batch"
assert_eq "auto-svc" "$(cut -d'|' -f1 "$TEST_TMP/sweep-stub.out")" "sweep picks the repo with a harness"
assert_eq "no_harness_repo" "$(jq -sr '[.[] | select(.project=="plain")] | first | .reason' "$SWEEP_DATA/harvest-auto/runs.jsonl")" "sweep skips repos without a harness"
run_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/sweep-stub.out" | tr -d ' ')" "same batch is not swept twice"
HARNESS_METRICS_DIR="$SWEEP_DATA" HM_HARVEST_AUTO=0 "$ROOT/scripts/harvest-auto.sh" sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/sweep-stub.out" | tr -d ' ')" "sweep is off unless opted in"
assert_contains "$(<"$ROOT/scripts/backfill-due.sh")" "harvest-auto.sh\" sweep" "backfill-due runs the sweep"
# 지워진 worktree 경로뿐인 batch도 같은 프로젝트의 살아 있는 하네스 저장소를 찾아 실행한다.
mkdir -p "$SWEEP_DATA/harvest-queue/p-auto-svc"
jq -cn '{kind:"session",src:"codex",sid:"live",project:"auto-svc"}' \
  | jq -c --arg cwd "$AUTO_REPO" '.cwd=$cwd' >"$SWEEP_DATA/events/codex-live.jsonl"
jq -cn --arg ev "$SWEEP_DATA/events/claude-gone.jsonl" \
  '{project:"auto-svc",batch_id:"b-gone",created_at:"2026-01-03T00:00:00Z",reasons:["errors"],event_files:[$ev]}' \
  >"$SWEEP_DATA/harvest-queue/p-auto-svc/analysis-batch.json"
jq -cn '{kind:"session",src:"claude",sid:"gone",project:"auto-svc",cwd:"/gone/workspaces/auto-svc/NJ-1"}' >"$SWEEP_DATA/events/claude-gone.jsonl"
run_sweep
assert_eq "2" "$(wc -l <"$TEST_TMP/sweep-stub.out" | tr -d ' ')" "batch with only deleted worktrees still runs in the live repo"
# Orca worktree에서만 작업해 원본 경로가 기록에 없으면, 기록에 나온 workspace의 멤버 목록에서 찾는다.
SWEEP_WS="$TEST_TMP/sweep-ws"
make_repo "$SWEEP_WS/ws-svc"
mkdir -p "$SWEEP_WS/ws-svc/.ai-harness" "$SWEEP_WS/.ai-harness" "$SWEEP_DATA/harvest-queue/p-ws-svc"
jq -n '{project_id:"ws-svc"}' >"$SWEEP_WS/ws-svc/.ai-harness/harness.json"
jq -n '{workspace_id:"ws",members:[{path:"ws-svc",project_id:"ws-svc"}]}' >"$SWEEP_WS/.ai-harness/workspace.json"
jq -cn --arg cwd "$SWEEP_WS" '{kind:"session",src:"claude",sid:"ws-root",project:"ws",cwd:$cwd}' >"$SWEEP_DATA/events/claude-ws-root.jsonl"
jq -cn '{kind:"session",src:"claude",sid:"ws-gone",project:"ws-svc",cwd:"/gone/orca/workspaces/ws-svc/NJ-9"}' >"$SWEEP_DATA/events/claude-ws-gone.jsonl"
jq -cn --arg ev "$SWEEP_DATA/events/claude-ws-gone.jsonl" \
  '{project:"ws-svc",batch_id:"b-ws",created_at:"2026-01-04T00:00:00Z",reasons:["errors"],event_files:[$ev]}' \
  >"$SWEEP_DATA/harvest-queue/p-ws-svc/analysis-batch.json"
SWEEP_BEFORE="$(wc -l <"$TEST_TMP/sweep-stub.out" | tr -d ' ')"
run_sweep
assert_eq "$((SWEEP_BEFORE + 1))" "$(wc -l <"$TEST_TMP/sweep-stub.out" | tr -d ' ')" "repo found through workspace members"
assert_eq "ws-svc" "$(tail -n 1 "$TEST_TMP/sweep-stub.out" | cut -d'|' -f1)" "workspace member project runs (an earlier launched batch does not stop the sweep)"
# 이전 버전이 "skipped"로 남긴 batch는 한 번 재판단하고, 하네스가 없으면 조용히 넘어간다.
jq -cn '{batch_id:"b-plain",result:"skipped"}' >"$SWEEP_DATA/harvest-queue/p-plain/auto-attempted-batch"
PLAIN_SKIPS_BEFORE="$(jq -s '[.[] | select(.project=="plain")] | length' "$SWEEP_DATA/harvest-auto/runs.jsonl")"
run_sweep
run_sweep
assert_eq "$((PLAIN_SKIPS_BEFORE + 1))" "$(jq -s '[.[] | select(.project=="plain")] | length' "$SWEEP_DATA/harvest-auto/runs.jsonl")" "legacy skip is re-evaluated once, then quiet"
pass "auto harvest sweep after backfill"

# launchd: shim은 가장 새 플러그인 설치본을 찾고, plist는 매시간 shim을 부른다.
SCHED_DATA="$TEST_TMP/sched-data"
SCHED_AGENTS="$TEST_TMP/sched-agents"
SCHED_HOME="$TEST_TMP/sched-home"
for version in 0.9.0 0.31.0 0.30.0; do
  mkdir -p "$SCHED_HOME/.claude/plugins/cache/ai-harness/ai-harness/$version/scripts"
  printf '#!/bin/bash\necho "due %s"\n' "$version" >"$SCHED_HOME/.claude/plugins/cache/ai-harness/ai-harness/$version/scripts/backfill-due.sh"
  chmod +x "$SCHED_HOME/.claude/plugins/cache/ai-harness/ai-harness/$version/scripts/backfill-due.sh"
done
run_schedule() {
  HARNESS_METRICS_DIR="$SCHED_DATA" HM_LAUNCH_AGENTS_DIR="$SCHED_AGENTS" HM_SCHEDULE_NO_LAUNCHCTL=1 \
    "$ROOT/scripts/schedule.sh" "$@"
}
if [[ "$(uname -s)" == "Darwin" ]]; then
  run_schedule install >/dev/null
  SCHED_PLIST="$SCHED_AGENTS/com.ai-harness.backfill.plist"
  assert_file "$SCHED_PLIST"
  if command -v plutil >/dev/null 2>&1; then plutil -lint "$SCHED_PLIST" >/dev/null || fail "plist lint"; fi
  assert_contains "$(<"$SCHED_PLIST")" "<key>StartInterval</key><integer>3600</integer>" "hourly check"
  assert_contains "$(<"$SCHED_PLIST")" "<key>AbandonProcessGroup</key><true/>" "detached harvest worker survives the job"
  assert_contains "$(<"$SCHED_PLIST")" "$SCHED_DATA/bin/run-due.sh" "plist points at the stable shim"
  assert_eq "due 0.31.0" "$(HARNESS_METRICS_DIR="$SCHED_DATA" HM_PLUGIN_SEARCH_HOME="$SCHED_HOME" /bin/bash "$SCHED_DATA/bin/run-due.sh" | tail -n 1)" "shim runs the newest installed plugin"
  find "$SCHED_HOME/.claude" -depth -delete
  assert_contains "$(HARNESS_METRICS_DIR="$SCHED_DATA" HM_PLUGIN_SEARCH_HOME="$SCHED_HOME" HM_BACKFILL_INTERVAL_HOURS=0 /bin/bash "$SCHED_DATA/bin/run-due.sh")" " run $ROOT" "shim falls back to the recorded plugin root"
  assert_eq "true" "$(run_schedule status | jq -r '.installed')" "status reports install"
  SCHED_AF_PLIST="$SCHED_AGENTS/com.ai-harness.autofix.plist"
  assert_not_file "$SCHED_AF_PLIST"
  assert_eq "null" "$(run_schedule status | jq -c '.autofix')" "status has no autofix schedule unless it is set"
  # autofix 전용 주기: 분 단위 LaunchAgent가 따로 sweep만 부른다.
  HM_AUTOFIX_INTERVAL_MINUTES=15 run_schedule install >/dev/null
  assert_file "$SCHED_AF_PLIST"
  if command -v plutil >/dev/null 2>&1; then plutil -lint "$SCHED_AF_PLIST" >/dev/null || fail "autofix plist lint"; fi
  assert_contains "$(<"$SCHED_AF_PLIST")" "<key>StartInterval</key><integer>900</integer>" "autofix sweep every 15 minutes"
  assert_contains "$(<"$SCHED_AF_PLIST")" "$SCHED_DATA/bin/run-autofix.sh" "autofix plist points at its own stable shim"
  assert_file "$SCHED_PLIST"
  for version in 0.31.0 0.30.0; do
    mkdir -p "$SCHED_HOME/.claude/plugins/cache/ai-harness/ai-harness/$version/scripts"
    printf '#!/bin/bash\necho "autofix %s $*"\n' "$version" >"$SCHED_HOME/.claude/plugins/cache/ai-harness/ai-harness/$version/scripts/autofix-auto.sh"
    chmod +x "$SCHED_HOME/.claude/plugins/cache/ai-harness/ai-harness/$version/scripts/autofix-auto.sh"
  done
  assert_eq "autofix 0.31.0 sweep" "$(HARNESS_METRICS_DIR="$SCHED_DATA" HM_PLUGIN_SEARCH_HOME="$SCHED_HOME" /bin/bash "$SCHED_DATA/bin/run-autofix.sh" | tail -n 1)" "autofix shim runs the newest installed plugin's sweep"
  assert_eq "true|15" "$(run_schedule status | jq -r '"\(.autofix.installed)|\(.autofix.interval_minutes)"')" "status reports the autofix schedule"
  # 주기를 지우고 다시 설치하면 전용 LaunchAgent도 내린다.
  run_schedule install >/dev/null
  assert_not_file "$SCHED_AF_PLIST"
  assert_not_file "$SCHED_DATA/bin/run-autofix.sh"
  SCHED_RC=0
  HM_AUTOFIX_INTERVAL_MINUTES=abc run_schedule install >/dev/null 2>&1 || SCHED_RC=$?
  assert_eq "2" "$SCHED_RC" "a non-numeric autofix interval is refused"
  # 보드가 주기만 바꿀 때(#278): autofix 전용 에이전트만 다루고 backfill은 건드리지 않으며, 등록 즉시 sweep을 돌리지 않는다.
  run_schedule uninstall >/dev/null
  HM_AUTOFIX_INTERVAL_MINUTES=20 run_schedule install-autofix >/dev/null
  assert_file "$SCHED_AF_PLIST"
  assert_not_file "$SCHED_PLIST"
  assert_contains "$(<"$SCHED_AF_PLIST")" "<key>StartInterval</key><integer>1200</integer>" "install-autofix uses the interval"
  case "$(<"$SCHED_AF_PLIST")" in *RunAtLoad*) fail "install-autofix does not start a sweep at load" ;; esac
  assert_eq "true|20" "$(run_schedule status | jq -r '"\(.autofix.installed)|\(.autofix.interval_minutes)"')" "status reports the board-installed schedule"
  run_schedule install-autofix >/dev/null
  assert_not_file "$SCHED_AF_PLIST"
  assert_not_file "$SCHED_PLIST"
  HM_AUTOFIX_INTERVAL_MINUTES=5 run_schedule install >/dev/null
  assert_contains "$(<"$SCHED_AF_PLIST")" "<key>RunAtLoad</key><true/>" "a full install keeps running at load"
  run_schedule uninstall >/dev/null
  assert_not_file "$SCHED_PLIST"
  assert_not_file "$SCHED_AF_PLIST"
  assert_not_file "$SCHED_DATA/bin/run-due.sh"
  assert_not_file "$SCHED_DATA/bin/run-autofix.sh"
else
  SCHED_RC=0
  SCHED_ERR="$(HM_AUTOFIX_INTERVAL_MINUTES=10 run_schedule install 2>&1 >/dev/null)" || SCHED_RC=$?
  assert_eq "3" "$SCHED_RC" "launchd install is macOS-only"
  assert_contains "$SCHED_ERR" "*/10 * * * *" "other OSes get a cron line for the autofix interval"
  assert_contains "$SCHED_ERR" "autofix-auto.sh sweep" "the cron line runs the autofix sweep"
  SCHED_RC=0
  SCHED_ERR="$(HM_AUTOFIX_INTERVAL_MINUTES=10 run_schedule install-autofix 2>&1 >/dev/null)" || SCHED_RC=$?
  assert_eq "3" "$SCHED_RC" "install-autofix is macOS-only too"
  assert_contains "$SCHED_ERR" "autofix-auto.sh sweep" "install-autofix gives the cron line elsewhere"
  # cron */N은 시·분 경계에서 다시 시작한다 — 60·24를 나누지 않는 주기는 틀린 줄 대신 안내를 낸다.
  SCHED_ERR="$(HM_AUTOFIX_INTERVAL_MINUTES=120 run_schedule install-autofix 2>&1 >/dev/null)" || true
  assert_contains "$SCHED_ERR" "0 */2 * * *" "an every-two-hours interval is an exact cron line"
  SCHED_ERR="$(HM_AUTOFIX_INTERVAL_MINUTES=90 run_schedule install-autofix 2>&1 >/dev/null)" || true
  assert_contains "$SCHED_ERR" "cron 한 줄로 정확히 쓸 수 없습니다" "a 90-minute interval is not written as a wrong cron line"
  case "$SCHED_ERR" in *"0 */1 * * *"*) fail "90 minutes is not turned into an hourly cron" ;; esac
  assert_contains "$SCHED_ERR" "OnUnitActiveSec=90min" "a timer that can express the interval is suggested"
fi
pass "launchd schedule"

# 오류 발췌: 반복 실패를 판단할 본문을 남기되 비밀값은 가린다.
ERRX_DATA="$TEST_TMP/errx-data"
ERRX_T="$TEST_TMP/errx/eeeeeeee-1111-2222-3333-ffffffffffff.jsonl"
mkdir -p "${ERRX_T%/*}"
errx_line() { # $1=tool_use id $2=tool $3=결과 본문
  jq -cn --arg id "$1" --arg tool "$2" '{type:"assistant",timestamp:"2026-07-29T01:00:00Z",cwd:"/tmp/service",message:{model:"m",usage:{input_tokens:1,output_tokens:1},content:[{type:"tool_use",id:$id,name:$tool,input:{}}]}}'
  jq -cn --arg id "$1" --arg body "$3" '{type:"user",timestamp:"2026-07-29T01:00:01Z",message:{content:[{type:"tool_result",tool_use_id:$id,is_error:true,content:$body}]}}'
}
{
  jq -cn '{type:"user",timestamp:"2026-07-29T00:59:00Z",cwd:"/tmp/service",message:{content:"빌드해줘"}}'
  errx_line t1 Bash $'Exit code 1\n> build\nError: Cannot find module ./gen/api at /tmp/x.js:12'
  errx_line t2 Bash $'Exit code 1\nError: Cannot find module ./gen/api at /tmp/x.js:31'
  errx_line t3 Bash 'curl failed: Authorization: Bearer sk-live-abc123 token=xyz password: "p@ss" key AKIAABCDEFGHIJKLMNOPQRSTUVWXYZ012345'
  errx_line t4 Edit '[Direct edit guard] src/a.ts 수정 전에 docs를 먼저 Read 하세요.'
  errx_line t5 Bash "The user doesn't want to proceed with this tool use."
} >"$ERRX_T"
HARNESS_METRICS_DIR="$ERRX_DATA" "$ROOT/scripts/extract-claude.sh" "$ERRX_T" "user_exit"
ERRX_EVENT="$ERRX_DATA/events/claude-eeeeeeee-1111-2222-3333-ffffffffffff.jsonl"
ERRX_SAMPLES="$(jq -r 'select(.kind=="error_sample") | "\(.n) \(.target)"' "$ERRX_EVENT")"
assert_contains "$ERRX_SAMPLES" "1 Bash: Error: Cannot find module ./gen/api at /tmp/x.js:12" "error line is preferred over leading output"
assert_contains "$ERRX_SAMPLES" "Authorization: ***" "authorization header redacted"
assert_contains "$ERRX_SAMPLES" "token=***" "token value redacted"
assert_contains "$ERRX_SAMPLES" 'password: "***' "password redacted"
[[ "$ERRX_SAMPLES" != *"sk-live-abc123"* && "$ERRX_SAMPLES" != *"AKIAABCDEFGHIJ"* ]] || fail "secrets leaked into error samples"
[[ "$ERRX_SAMPLES" != *"Direct edit guard"* && "$ERRX_SAMPLES" != *"want to proceed"* ]] || fail "guard and denial stay in their own signals"
ERRX_STATS="$(HARNESS_METRICS_DIR="$ERRX_DATA" "$ROOT/scripts/stats.sh")"
assert_contains "$ERRX_STATS" "| 1 | 1 | 2 | Bash: Error: Cannot find module ./gen/api at /tmp/x.js:12 |" "stats groups the same error across line numbers"
pass "error excerpts for repeated failures"

# 원본 transcript가 지워진 세션도 규칙이 바뀌면 남은 작업 경로로 프로젝트 이름을 다시 판정한다.
RELABEL_DATA="$TEST_TMP/relabel-data"
RELABEL_WS="$TEST_TMP/relabel-ws"
mkdir -p "$RELABEL_DATA/events" "$RELABEL_WS/.ai-harness" "$RELABEL_DATA/harvest-queue/p-old-ws/sessions"
jq -n '{workspace_id:"new-ws",members:[]}' >"$RELABEL_WS/.ai-harness/workspace.json"
jq -cn --arg cwd "$RELABEL_WS" '{v:3,kind:"session",src:"claude",sid:"orphan-1",project:"old-ws",cwd:$cwd,
  transcript:"/gone/orphan-1.jsonl",ended:"2026-08-01T00:00:00Z",turns:3}' >"$RELABEL_DATA/events/claude-orphan-1.jsonl"
jq -cn '{v:3,kind:"error",src:"claude",sid:"orphan-1",project:"old-ws",n:2}' >>"$RELABEL_DATA/events/claude-orphan-1.jsonl"
HARNESS_METRICS_DIR="$RELABEL_DATA" "$ROOT/scripts/harvest-queue.sh" record "$RELABEL_DATA/events/claude-orphan-1.jsonl" >/dev/null
assert_file "$RELABEL_DATA/harvest-queue/p-old-ws/sessions/claude-orphan-1.json"
RELABEL_OUT="$(HARNESS_METRICS_DIR="$RELABEL_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/relabel-none" \
  HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/relabel-none" "$ROOT/scripts/backfill.sh")"
assert_contains "$RELABEL_OUT" "이름 재판정 1" "orphan event relabelled"
assert_eq "new-ws|new-ws" "$(jq -sr '(map(.project) | unique | join("|")) + "|" + (map(select(.kind=="session"))[0].project)' "$RELABEL_DATA/events/claude-orphan-1.jsonl")" "every event line carries the new project"
assert_file "$RELABEL_DATA/harvest-queue/p-new-ws/sessions/claude-orphan-1.json"
assert_not_file "$RELABEL_DATA/harvest-queue/p-old-ws/sessions/claude-orphan-1.json"
assert_contains "$(HARNESS_METRICS_DIR="$RELABEL_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/relabel-none" \
  HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/relabel-none" "$ROOT/scripts/backfill.sh")" "이름 재판정 0" "relabel runs once per rule change"
# 여러 줄에 cwd가 있는 transcript도 첫 cwd 하나로 판정한다(macOS jq 1.6의 first(inputs) 버그 회피).
MULTI_T="$TEST_TMP/multi-cwd/dddddddd-1111-2222-3333-eeeeeeeeeeee.jsonl"
mkdir -p "${MULTI_T%/*}"
for _ in 1 2 3; do
  jq -cn --arg cwd "$RELABEL_WS" '{type:"user",timestamp:"2026-08-01T00:00:00Z",cwd:$cwd,message:{content:"작업"}}'
done >"$MULTI_T"
HARNESS_METRICS_DIR="$TEST_TMP/multi-data" "$ROOT/scripts/extract-claude.sh" "$MULTI_T" "user_exit"
assert_eq "new-ws" "$(jq -r 'select(.kind=="session") | .project' "$TEST_TMP/multi-data/events/claude-dddddddd-1111-2222-3333-eeeeeeeeeeee.jsonl")" "multi-line cwd transcript resolves through the workspace manifest"
if grep -rnE "^[^#]*jq[^#]*first\(inputs" "$ROOT/scripts" >/dev/null; then fail "first(inputs …) returns every match on macOS jq 1.6 — read lines and head -n 1"; fi
pass "orphan events follow project ID rule changes"

# 개인 지침 자동 적용: 표시된 블록 안에서만, 되돌릴 수 있게, 알림과 함께.
APPLY_DATA="$TEST_TMP/apply-data"
APPLY_HOME="$TEST_TMP/apply-home"
mkdir -p "$APPLY_HOME/ws/.ai-harness"
printf '# 내 규칙\n- 사람이 쓴 줄' >"$APPLY_HOME/CLAUDE.md"
jq -n '{workspace_id:"ws",members:[]}' >"$APPLY_HOME/ws/.ai-harness/workspace.json"
run_apply() {
  HARNESS_METRICS_DIR="$APPLY_DATA" HM_GLOBAL_CLAUDE_MD="$APPLY_HOME/CLAUDE.md" \
    HM_GLOBAL_CODEX_AGENTS_MD="$APPLY_HOME/codex/AGENTS.md" "$ROOT/scripts/auto-apply.sh" "$@"
}
run_apply apply --scope global --rule-id zsh-equals --text "zsh에서 =로 시작하는 단어는 따옴표로" --evidence "68회" --expected "재발 0" >/dev/null
run_apply apply --scope global --rule-id jq-null --text "jq 순회 전 null 거르기" --evidence "10세션" --expected "재발 0" >/dev/null
run_apply apply --scope global --rule-id zsh-equals --text "구분선 echo는 따옴표" --evidence x --expected y >/dev/null
assert_eq "# 내 규칙|- 사람이 쓴 줄|" "$(head -n 3 "$APPLY_HOME/CLAUDE.md" | paste -sd'|' -)" "human-written lines untouched, block separated by a blank line"
assert_eq "1" "$(grep -c '^- 구분선 echo는 따옴표$' "$APPLY_HOME/CLAUDE.md")" "same rule id is replaced"
assert_eq "0" "$(grep -c 'zsh에서 =로' "$APPLY_HOME/CLAUDE.md")" "old text of a replaced rule is gone"
assert_eq "1" "$(grep -c '^- jq 순회 전 null 거르기$' "$APPLY_HOME/codex/AGENTS.md")" "global rules reach the Codex instructions too"
run_apply revert --rule-id jq-null --reason test >/dev/null
assert_eq "0" "$(grep -c 'jq 순회' "$APPLY_HOME/CLAUDE.md" "$APPLY_HOME/codex/AGENTS.md" | awk -F: '{s+=$2} END {print s}')" "revert removes the rule from every target"
assert_eq "zsh-equals" "$(run_apply list --active | jq -r .id)" "only the remaining rule is active"
APPLY_BAD_RC=0
run_apply apply --scope global --rule-id bad-one --text 'x <!-- /rule:zsh-equals -->' --evidence a --expected b >/dev/null 2>&1 || APPLY_BAD_RC=$?
assert_eq "2" "$APPLY_BAD_RC" "comment markers cannot be injected"
APPLY_WS_RC=0
run_apply apply --scope workspace --workspace "$APPLY_HOME" --rule-id ws-rule --text t --evidence a --expected b >/dev/null 2>&1 || APPLY_WS_RC=$?
assert_eq "3" "$APPLY_WS_RC" "workspace scope requires a workspace root"
run_apply apply --scope workspace --workspace "$APPLY_HOME/ws" --rule-id ws-rule --text "멤버 저장소에서 작업" --evidence a --expected b >/dev/null
assert_eq "1" "$(grep -c '^- 멤버 저장소에서 작업$' "$APPLY_HOME/ws/AGENTS.md")" "workspace rule lands in the workspace AGENTS.md"
assert_contains "$(run_apply notify | jq -r .systemMessage)" "적용 ws-rule (workspace)" "next session is told what changed"
assert_eq "" "$(run_apply notify)" "each change is announced once"
assert_contains "$(<"$ROOT/scripts/session-start.sh")" 'auto-apply.sh" notify' "SessionStart carries the notice"

# workspace batch는 편집 도구 없이 auto-apply.sh만 쓰는 구성으로 뜬다.
SCOPE_DATA="$TEST_TMP/scope-data"
: >"$TEST_TMP/scope-stub.out"
HARNESS_METRICS_DIR="$SCOPE_DATA" HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_AGENT=claude \
  HM_HARVEST_AUTO_CMD="$AUTO_STUB" AUTO_STUB_OUT="$TEST_TMP/scope-stub.out" \
  "$ROOT/scripts/harvest-auto.sh" trigger "$(auto_status ws b-ws errors)" "$APPLY_HOME/ws"
assert_eq "ws|1|$(cd "$APPLY_HOME/ws" && pwd -P)" "$(cat "$TEST_TMP/scope-stub.out")" "workspace batch runs in the workspace root"
# shellcheck disable=SC2016
SCOPED_ARGS="$(sed -n '/--auto --scope $scope /,/--output-format stream-json --verbose)/p' "$ROOT/scripts/harvest-auto.sh")"
assert_contains "$SCOPED_ARGS" '--permission-mode dontAsk' "scoped runs deny anything not pre-approved"
assert_contains "$SCOPED_ARGS" '--disallowedTools "Edit" "Write" "MultiEdit" "NotebookEdit"' "scoped runs cannot edit files directly"
# 전역 실행은 주기(기본 7일)마다 한 번, 다른 실행이 없을 때만.
GLOBAL_DATA="$TEST_TMP/global-data"
mkdir -p "$GLOBAL_DATA"
run_global_sweep() {
  HARNESS_METRICS_DIR="$GLOBAL_DATA" HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_AGENT=claude \
    HM_HARVEST_AUTO_CMD="$AUTO_STUB" AUTO_STUB_OUT="$TEST_TMP/global-stub.out" "$ROOT/scripts/harvest-auto.sh" sweep
}
run_global_sweep
run_global_sweep
assert_eq "_global" "$(cut -d'|' -f1 "$TEST_TMP/global-stub.out")" "global run happens once within the period"
assert_eq "no-change" "$(jq -sr '[.[] | select(.event=="finished")] | last | .result' "$GLOBAL_DATA/harvest-auto/runs.jsonl")" "global result comes from the applied log"
pass "personal instructions are auto-applied inside a managed block"

# 리뷰 지적 회귀: 무인 실행이 다루는 입력(config·규칙 문구·transcript)이 코드 실행이나 블록 밖 변경으로 번지지 않는다.
HARD_DIR="$TEST_TMP/hardening"
mkdir -p "$HARD_DIR"
# 주입 줄에는 실제 경로를 박는다 — 파서가 깨져 코드가 돌면 그 파일이 생겨 테스트가 실패하도록.
{
  printf '%s\n' 'HM_ISSUE_RE="(NJ|JDA)-[0-9]+"' 'HM_HARVEST_AUTO=0  # 일시 중지' "export HM_X='a b'"
  # shellcheck disable=SC2016  # 설정 파일에 literal $( … )를 쓴다
  printf 'EVIL=$(touch %s/pwned1)\n' "$HARD_DIR"
  # shellcheck disable=SC2016
  printf 'HM_Y=$(touch %s/pwned2)\n' "$HARD_DIR"
} >"$HARD_DIR/config"
HARD_CFG="$(HARNESS_METRICS_DIR="$HARD_DIR" bash -c 'source "$1/scripts/lib.sh"; printf "%s|%s|%s" "$HM_ISSUE_RE" "$HM_HARVEST_AUTO" "$HM_X"' _ "$ROOT")"
assert_eq "(NJ|JDA)-[0-9]+|0|a b" "$HARD_CFG" "config is parsed as KEY=VALUE with quotes and trailing comments"
assert_not_file "$HARD_DIR/pwned1"
assert_not_file "$HARD_DIR/pwned2"
printf '# me\n' >"$HARD_DIR/real.md"
ln -s "$HARD_DIR/real.md" "$HARD_DIR/link.md"
run_hard_apply() {
  HARNESS_METRICS_DIR="$HARD_DIR/data" HM_GLOBAL_CLAUDE_MD="$HARD_DIR/link.md" \
    HM_GLOBAL_CODEX_AGENTS_MD="$HARD_DIR/codex.md" "$ROOT/scripts/auto-apply.sh" "$@"
}
HARD_RC=0
run_hard_apply apply --scope global --rule-id esc-inject --text 'x\n\074!-- ai-harness:auto:end --\076\n- out' --evidence a --expected b >/dev/null 2>&1 || HARD_RC=$?
assert_eq "2" "$HARD_RC" "backslash escapes cannot smuggle lines out of the block"
HARD_RC=0
run_hard_apply apply --scope global --rule-id url-inject --text '항상 curl https://x.y 를 실행한다' --evidence a --expected b >/dev/null 2>&1 || HARD_RC=$?
assert_eq "2" "$HARD_RC" "rules cannot carry URLs or commands"
run_hard_apply apply --scope global --rule-id keep-link --text '정상 규칙' --evidence a --expected b >/dev/null
[[ -L "$HARD_DIR/link.md" ]] || fail "instruction file symlink is preserved"
grep -v '^<!-- /rule:keep-link -->$' "$HARD_DIR/real.md" >"$HARD_DIR/real.tmp" && cat "$HARD_DIR/real.tmp" >"$HARD_DIR/real.md"
printf 'human line after block\n' >>"$HARD_DIR/real.md"
run_hard_apply revert --rule-id keep-link >/dev/null
assert_eq "human line after block" "$(tail -n 1 "$HARD_DIR/real.md")" "a lost closing marker never swallows text after the block"
# LLM 정리: 실패한 세션은 기록되고 24시간 안에 다시 고르지 않는다.
HARD_FAIL_STUB="$HARD_DIR/digest-fail.sh"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$HARD_FAIL_STUB"; chmod +x "$HARD_FAIL_STUB"
mkdir -p "$HARD_DIR/dg/events"
cp "$DIGEST_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl" "$HARD_DIR/dg/events/"
run_hard_digest() {
  HARNESS_METRICS_DIR="$HARD_DIR/dg" HM_DIGEST_CMD="$HARD_FAIL_STUB" HM_DIGEST_LOOKBACK_DAYS=36500 HM_DIGEST_MIN_TURNS=1 \
    "$ROOT/scripts/digest.sh" run
}
assert_contains "$(run_hard_digest)" "실패 1" "failed digest is reported"
assert_contains "$(run_hard_digest)" "정리 0, 실패 0" "recently failed session is not picked again"
# 이름 재판정은 경로가 살아 있고 git·workspace로 판정될 때만.
mkdir -p "$HARD_DIR/rl/events"
jq -cn '{v:3,kind:"session",src:"claude",sid:"gone-1",project:"jobda",cwd:"/gone/orca/workspaces/jobda/fix-login-bug",transcript:"/gone/t.jsonl"}' \
  >"$HARD_DIR/rl/events/claude-gone-1.jsonl"
HARNESS_METRICS_DIR="$HARD_DIR/rl" HARNESS_CLAUDE_PROJECTS_DIR="$HARD_DIR/none" HARNESS_CODEX_SESSIONS_DIR="$HARD_DIR/none" \
  "$ROOT/scripts/backfill.sh" >/dev/null
assert_eq "jobda" "$(jq -r '.project' "$HARD_DIR/rl/events/claude-gone-1.jsonl")" "a heuristic name never overwrites a git-derived one"
# 프로젝트 실행 권한: 데이터·transcript는 읽기만, 위험한 git은 금지.
HARD_ARGS="$(sed -n '/local deny_args=/,/done < <(codex_session_roots)/p' "$ROOT/scripts/harvest-auto.sh")"
# shellcheck disable=SC2016
assert_contains "$HARD_ARGS" '"Edit(/$HM_DATA_DIR/**)" "Write(/$HM_DATA_DIR/**)"' "data dir (config, shim) is not writable by the agent"
assert_contains "$HARD_ARGS" '"Bash(git -C *)" "Bash(git reset*)" "Bash(git clean*)"' "destructive git is denied"
# shellcheck disable=SC2016
if grep -q '"Bash(git \*)"' <(sed -n '/if \[\[ "$scope" == "project" \]\]; then/,/--output-format stream-json --verbose)/p' "$ROOT/scripts/harvest-auto.sh"); then
  fail "project runs must not get blanket git access"
fi
pass "unattended inputs cannot escape into code execution or outside the managed block"

# 플러그인 편집 가드: 세션이 열린 곳과 다른 하네스 저장소의 코드 편집은 워크플로를 읽었어도 모델이 혼자 진행하지 못한다.
# 기본은 사용자 확인(permissionDecision: ask)이고, HM_MEMBER_GUARD=block이면 예전처럼 막고 멤버 세션으로 인계하게 한다.
assert_contains "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("member-edit-guard")) | .hooks[0].command' "$ROOT/hooks/hooks.json")" "scripts/member-edit-guard.sh" "PreToolUse hook runs the member edit guard"
assert_eq "Edit|Write|MultiEdit|NotebookEdit" "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("member-edit-guard")) | .matcher' "$ROOT/hooks/hooks.json")" "member edit guard matches Claude edit tools"
assert_eq "3" "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("member-edit-guard")) | .hooks[0].timeout' "$ROOT/hooks/hooks.json")" "member edit guard stays inside a short budget"
GW="$TEST_TMP/guard-ws"
mkdir -p "$GW/jobda/.ai-harness/workflows" "$GW/jobda/src/main" "$GW/worktrees/NJ-1/jobda/.ai-harness/workflows" "$GW/worktrees/NJ-1/jobda/src/main" "$GW/plain/src/main" "$GW/t/sess"
git -C "$GW/jobda" init -q
printf '{"project_id":"jobda"}\n' >"$GW/jobda/.ai-harness/harness.json"
printf '{"project_id":"jobda"}\n' >"$GW/worktrees/NJ-1/jobda/.ai-harness/harness.json"
touch "$GW/jobda/.ai-harness/workflows/implement-feature.md" "$GW/worktrees/NJ-1/jobda/.ai-harness/workflows/implement-feature.md"
guard_line() { # $1=tool name, $2=input json
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"%s","input":%s}]}}\n' "$1" "$2"
}
: >"$GW/t/none.jsonl"
guard_line Read "{\"file_path\":\"$GW/jobda/.ai-harness/workflows/implement-feature.md\"}" >"$GW/t/read.jsonl"
guard_line Bash '{"command":"cd jobda && sed -n 1,80p .ai-harness/workflows/implement-feature.md"}' >"$GW/t/cd.jsonl"
guard_line Bash '{"command":"cat worktrees/NJ-1/jobda/.ai-harness/workflows/implement-feature.md"}' >"$GW/t/wt.jsonl"
cp "$GW/t/read.jsonl" "$GW/t/sess.jsonl"
mkdir -p "$GW/t/sess/subagents"
cp "$GW/t/read.jsonl" "$GW/t/sess/subagents/agent-a1.jsonl"
member_guard() { # $1=cwd, $2=file, $3=transcript, [$4=agent_id] -> ask(확인 요청) | exit code; stdout $GW/out, stderr $GW/err
  local agent="${4:-}" rc=0
  jq -cn --arg cwd "$1" --arg f "$2" --arg t "$3" --arg a "$agent" \
    '{tool_name:"Edit", cwd:$cwd, transcript_path:$t, tool_input:{file_path:$f}} + (if $a=="" then {} else {agent_id:$a} end)' \
    | "$ROOT/scripts/member-edit-guard.sh" 2>"$GW/err" >"$GW/out" || rc=$?
  if [[ "$rc" == 0 && "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$GW/out" 2>/dev/null)" == ask ]]; then echo ask; else echo "$rc"; fi
}
guard_reason() { jq -r '.hookSpecificOutput.permissionDecisionReason' "$GW/out"; }
guard_context() { jq -r '.hookSpecificOutput.additionalContext' "$GW/out"; }
assert_eq "ask" "$(member_guard "$GW" "$GW/jobda/src/main/App.java" "$GW/t/none.jsonl")" "workspace edit of member code asks the user instead of going ahead"
assert_eq "PreToolUse" "$(jq -r '.hookSpecificOutput.hookEventName' "$GW/out")" "ask decision names its hook event"
assert_eq "" "$(<"$GW/err")" "asking writes nothing to stderr (no hook error in the transcript)"
[[ "$(guard_reason)" == "[Direct edit guard] jobda "* ]] || fail "ask reason starts with the guard prefix and names the member"
assert_contains "$(guard_reason)" "허용하면 이 편집만 진행" "ask reason tells the user what approving means"
[[ "$(guard_reason)" != *"claude --bg"* ]] || fail "the user's prompt stays short; handoff steps go to the model"
assert_contains "$(guard_context)" "거부되면 다시 시도하지 마세요" "the model is told not to retry a denied edit"
assert_contains "$(guard_context)" "Bash로 파일을 써서 우회하지 마세요" "the model is told not to route around the prompt with Bash"
assert_contains "$(guard_context)" '/cd jobda' "handoff context offers /cd into the member"
assert_contains "$(guard_context)" 'cd jobda && claude --bg -n <인계 이름> "<인계>"' "handoff context hands off to a Claude Code background session in the member"
assert_contains "$(guard_context)" 'notify_when_idle: true' "handoff context waits on the background session's turn-end notice"
assert_contains "$(guard_context)" 'orca orchestration check --wait' "handoff context keeps Orca supervision as an option when the user wants it"
assert_contains "$(guard_context)" '완료 파일(결과·PR 링크·원격 CI 상태)' "without supervised dispatch the handoff names a completion file to wait for"
assert_contains "$(guard_context)" "첫 지시로 멤버 워크플로 파일(\`.ai-harness/workflows/<name>.md\`)을 Read 하고 그 그래프대로 진행하라고 적습니다" "handoff context tells the handoff to open by reading the member workflow file"
[[ "$(guard_context)$(guard_reason)" != *"워크플로를 읽고"* ]] || fail "reading the workflow is never offered as the way through"
assert_eq "ask" "$(member_guard "$GW" "$GW/jobda/src/main/App.java" "$GW/t/read.jsonl")" "reading the member workflow with Read still asks"
assert_eq "ask" "$(member_guard "$GW" "$GW/jobda/src/main/App.java" "$GW/t/cd.jsonl")" "cd into the member in Bash then reading its workflow still asks"
assert_eq "ask" "$(member_guard "$GW" "$GW/worktrees/NJ-1/jobda/src/main/App.java" "$GW/t/wt.jsonl")" "reading the worktree's workflow still asks"
assert_contains "$(guard_context)" "/cd worktrees/NJ-1/jobda" "handoff context hands off to the worktree, not the main checkout"
assert_eq "ask" "$(member_guard "$GW" "$GW/jobda/src/main/App.java" "$GW/t/sess.jsonl" a1)" "a subagent of a workspace session still asks even when it and its parent read the workflow"
assert_eq "ask" "$(member_guard "$GW" "$GW/jobda/src/main/App.java" "$GW/t/missing.jsonl")" "the verdict does not depend on a readable transcript"
assert_eq "0" "$(member_guard "$GW/jobda" "$GW/jobda/src/main/App.java" "$GW/t/none.jsonl")" "a session opened in the member is left to the member's own guard"
assert_eq "0" "$(member_guard "$GW/jobda/src" "$GW/jobda/src/main/App.java" "$GW/t/none.jsonl")" "a session opened below the member root is inside the member"
assert_eq "0" "$(member_guard "$GW/jobda" "$GW/jobda/src/main/App.java" "$GW/t/none.jsonl" a1)" "a subagent of a member session passes"
assert_eq "0" "$(member_guard "$GW/worktrees/NJ-1/jobda" "$GW/worktrees/NJ-1/jobda/src/main/App.java" "$GW/t/none.jsonl")" "a session opened in the worktree passes"
assert_eq "ask" "$(member_guard "$GW/jobda" "$GW/worktrees/NJ-1/jobda/src/main/App.java" "$GW/t/none.jsonl")" "a worktree is its own member: a main-checkout session must ask"
assert_eq "0" "$(member_guard "$GW" "$GW/jobda/.ai-harness/docs/domain.md" "$GW/t/none.jsonl")" "harness documents are not guarded"
assert_eq "0" "$(member_guard "$GW" "$GW/jobda/.claude/settings.json" "$GW/t/none.jsonl")" "tool settings are not guarded"
assert_eq "0" "$(member_guard "$GW" "$GW/jobda/docs/handoff.md" "$GW/t/none.jsonl")" "markdown documents are not guarded"
assert_eq "0" "$(member_guard "$GW" "$GW/plain/src/main/App.java" "$GW/t/none.jsonl")" "code outside any harness is not guarded"
assert_eq "0" "$(jq -cn '{tool_name:"Bash", cwd:"/", tool_input:{command:"ls"}}' | "$ROOT/scripts/member-edit-guard.sh" >/dev/null 2>&1 && echo 0 || echo $?)" "non-edit tools pass"
ln -s "$GW/jobda" "$GW/jobda-link"
assert_eq "0" "$(member_guard "$GW/jobda-link" "$GW/jobda/src/main/App.java" "$GW/t/none.jsonl")" "a session in a symlinked path of the same member is not blocked"
assert_eq "0" "$(member_guard "$GW/jobda" "$GW/jobda/src/../src/main/App.java" "$GW/t/none.jsonl")" "dot-dot in the edited path still resolves to the same member"
assert_eq "0" "$(HM_MEMBER_GUARD=0 member_guard "$GW" "$GW/jobda/src/main/App.java" "$GW/t/none.jsonl")" "HM_MEMBER_GUARD=0 turns the guard off"
assert_eq "" "$(<"$GW/out")" "passing cases print no decision"
assert_eq "2" "$(HM_MEMBER_GUARD=block member_guard "$GW" "$GW/jobda/src/main/App.java" "$GW/t/none.jsonl")" "HM_MEMBER_GUARD=block keeps the hard block"
[[ "$(<"$GW/err")" == "[Direct edit guard] "* ]] || fail "hard block stderr starts with the counted guard prefix"
assert_contains "$(<"$GW/err")" '/cd jobda' "hard block still hands off to the member"
assert_contains "$(<"$GW/err")" "Bash로 파일을 써서 우회하지 마세요" "hard block still forbids writing around it with Bash"
assert_eq "" "$(<"$GW/out")" "hard block prints no ask decision"
assert_eq "0" "$(HM_MEMBER_GUARD=block member_guard "$GW/jobda" "$GW/jobda/src/main/App.java" "$GW/t/none.jsonl")" "block mode still passes a session opened in the member"
pass "member edit guard"

# 인계 대기는 완료 파일만 보지 않는다 — 멤버 터미널이 승인·질문에서 멈추거나 끝나면 바로 끝내고 이유를 알린다.
WD="$TEST_TMP/wait-delegation"
mkdir -p "$WD/bin"
cat >"$WD/bin/orca" <<'EOF'
#!/usr/bin/env bash
# 실측(Orca 1.4.250): close 는 실제로 닫혀도 오류(tab_not_found)를 낼 수 있다 — 종료 코드가 아니라 list 로 판정해야 한다.
if [[ "${2:-}" == close ]]; then printf '%s\n' "$*" >>"$WD_DIR/closed"; [[ -f "$WD_DIR/close_noop" ]] && rm -f "$WD_DIR/closed"; echo tab_not_found >&2; exit 1; fi
if [[ "${2:-}" == list ]]; then [[ -f "$WD_DIR/closed" ]] && echo '{"ok":true,"result":{"terminals":[]}}' || echo '{"ok":true,"result":{"terminals":[{"handle":"term_3d258b5b-850f-4f77-a851-3013191cd199"}]}}'; exit 0; fi
[[ -f "$WD_DIR/fail" ]] && { echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1; }
jq -Rsc --arg s "$(cat "$WD_DIR/status" 2>/dev/null || echo running)" '{ok:true, result:{terminal:{status:$s, tail:(split("\n"))}}}' "$WD_DIR/screen"
EOF
chmod +x "$WD/bin/orca"
WD_HANDLE="term_3d258b5b-850f-4f77-a851-3013191cd199"
wait_delegation() { # 인자는 그대로 넘긴다. 출력 뒤에 exit=<code>
  local rc=0 out
  out="$(PATH="$WD/bin:$PATH" WD_DIR="$WD" "$ROOT/scripts/wait-delegation.sh" --interval 0 "$@" 2>"$WD/err")" || rc=$?
  printf '%s\nexit=%s' "$out" "$rc"
}
printf 'done\n' >"$WD/finished.md"
WD_OUT="$(wait_delegation --done "$WD/finished.md" --terminal "$WD_HANDLE")"
assert_contains "$WD_OUT" "reason=done" "an existing completion file ends the wait as done"
assert_contains "$WD_OUT" "exit=0" "done exits 0"
printf '구현 계획 brief 입니다.\n승인할까요?\n\n❯ \n⏵⏵ bypass permissions on\n' >"$WD/screen"
WD_OUT="$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --input-idle 0)"
assert_contains "$WD_OUT" "reason=awaiting_input" "a member waiting on a free-text approval question ends the wait"
assert_contains "$WD_OUT" "승인할까요?" "the last screen lines come with the reason"
assert_contains "$WD_OUT" "exit=10" "awaiting_input exits 10"
printf 'Which approach?\n❯ 1. A\n  2. B\nEnter to select · ↑/↓ to navigate\n' >"$WD/screen"
assert_contains "$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --input-idle 0)" "reason=awaiting_input" "a question with choices ends the wait"
# 실측: 새 폴더에서 뜬 Claude 의 신뢰 확인 창은 번호 없는 선택지와 'Enter to confirm' 이다.
printf ' Quick safety check: Is this a project you created or one you trust? (Like your own code, a\n ❯ No, exit\n   Yes, I trust this folder\n Enter to confirm · Esc to cancel\n' >"$WD/screen"
assert_contains "$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --input-idle 0)" "reason=awaiting_input" "the folder trust prompt ends the wait"
printf '✻ Running tests\n' >"$WD/screen"
WD_OUT="$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --input-idle 0 --stall 0)"
assert_contains "$WD_OUT" "reason=stalled" "an unchanged screen without a question ends the wait as stalled"
assert_contains "$WD_OUT" "exit=11" "stalled exits 11"
assert_contains "$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --timeout 1 --interval 1)" "reason=timeout" "a working screen waits until the timeout"
echo exited >"$WD/status"
assert_contains "$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE")" "reason=exited" "an exited member terminal ends the wait"
rm -f "$WD/status"; : >"$WD/fail"
WD_OUT="$(wait_delegation --done "$WD/none.md" --terminal term_3d258b5b)"
assert_contains "$WD_OUT" "reason=terminal_unavailable" "an unreadable terminal handle ends the wait instead of hanging"
assert_contains "$(<"$WD/err")" "short handles go stale" "a short terminal handle is warned about"
rm -f "$WD/fail"
assert_contains "$(wait_delegation --done "$WD/none.md" --timeout 1 --interval 1)" "reason=timeout" "without a terminal the wait watches the file only"
assert_contains "$(wait_delegation --terminal "$WD_HANDLE")" "exit=2" "the completion file is required"
pass "delegation wait reports input gates"

# 끝난 멤버 탭을 닫는다(--close). 대화형 세션은 끝나도 입력 대기로 남아 세션당 수백 MB를 쥔다(2026-11-17: 끝난 세션
# 탭 십여 개·swap 27GB). 오래 켠 조율 세션은 나중에 추가된 문서 규칙을 못 읽으므로 대기 스크립트가 직접 닫는다.
# 완료 파일이 아직 미확인(CI 대기 등)이거나 user_decision이면, 화면이 일하는 중이거나 질문 중이면 닫지 않는다.
printf '## 결과\nPR: #12\n원격 CI: 성공\n' >"$WD/final.md"
printf '⏺ 끝났습니다.\n\n❯ \n⏵⏵ bypass permissions on\n' >"$WD/screen"
rm -f "$WD/closed" "$WD/close_noop"
WD_OUT="$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close)"
assert_contains "$WD_OUT" "reason=done" "closing still reports the completion"
assert_contains "$WD_OUT" "closed=yes" "a finished idle member tab is closed"
assert_contains "$(<"$WD/closed")" "terminal close --terminal $WD_HANDLE" "the member terminal is closed by its full handle"
case "$(<"$WD/closed")" in *--tab*) fail "close without --tab (with --tab Orca closes nothing for launched agents)" ;; esac
rm -f "$WD/closed"
assert_contains "$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE")" "reason=done" "without --close the wait only reports"
assert_not_file "$WD/closed"
printf '## 결과\n원격 CI: PLACEHOLDER\n' >"$WD/pending.md"
WD_OUT="$(wait_delegation --done "$WD/pending.md" --terminal "$WD_HANDLE" --close)"
assert_contains "$WD_OUT" "closed=no" "a completion file whose CI is still open keeps the tab"
assert_contains "$WD_OUT" "close_reason=done_file_pending" "the reason names the open completion file"
printf '## 결과\n그래프 종료: user_decision (원격 CI 미확인)\n' >"$WD/decision.md"
assert_contains "$(wait_delegation --done "$WD/decision.md" --terminal "$WD_HANDLE" --close)" "close_reason=user_decision" "a run that stopped for the user keeps its tab"
assert_not_file "$WD/closed"
printf '✻ Polling CI…\n⏵⏵ bypass permissions on · esc to interrupt\n' >"$WD/screen"
WD_OUT="$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close --close-wait 0)"
assert_contains "$WD_OUT" "close_reason=busy" "a member still working is not closed"
printf '✻ done 7:11 PM · 1 shell still running\n❯ \n' >"$WD/screen"
assert_contains "$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close --close-wait 0)" "close_reason=busy" "a member with a background shell is not closed"
printf '머지할까요?\n\n❯ \n' >"$WD/screen"
assert_contains "$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close --close-wait 0)" "close_reason=awaiting_input" "a member asking a question is not closed"
assert_not_file "$WD/closed"
printf '⏺ 끝났습니다.\n❯ \n' >"$WD/screen"
: >"$WD/close_noop"
assert_contains "$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close)" "close_reason=still_listed" "a close that left the terminal listed is reported, not trusted"
rm -f "$WD/close_noop" "$WD/closed"
assert_contains "$(wait_delegation --done "$WD/final.md" --close)" "exit=2" "--close needs the member terminal"
WD_INIT="$(<"$ROOT/skills/harness-init/SKILL.md")"
assert_contains "$WD_INIT" 'wait-delegation.sh --done <완료 파일> --terminal <멤버 터미널 전체 handle> --close' "workspace delegation waits with --close"
assert_contains "$WD_INIT" "③이 끝난 멤버 탭을 닫지 않음" "sync flags a workspace that does not close finished member tabs"
pass "delegation wait closes a finished member tab"

# 정기 작업은 OS 스케줄러 없이 에이전트 hook이 깨운다. LLM 단계는 사용자가 쉴 때만, 한도 직후엔 쉰다.
assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$ROOT/hooks/hooks.json")" "scripts/tick.sh" "Stop hook ticks the scheduler"
assert_eq "3" "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$ROOT/hooks/hooks.json")" "tick stays inside a short budget"
TICK_DATA="$TEST_TMP/tick-data"
mkdir -p "$TICK_DATA"
printf '{}' | HARNESS_METRICS_DIR="$TICK_DATA" HM_INTERNAL_SESSION=1 HM_BACKFILL_INTERVAL_HOURS=6 "$ROOT/scripts/tick.sh"
assert_not_file "$TICK_DATA/health.json"
TICK_CLAUDE="$TEST_TMP/tick-claude/-tmp-x"
mkdir -p "$TICK_CLAUDE" "$TEST_TMP/tick-codex"
jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{type:"user",timestamp:$t}' >"$TICK_CLAUDE/active.jsonl"
run_tick_worker() {
  HARNESS_METRICS_DIR="$TICK_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/tick-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/tick-codex" \
    HM_BACKFILL_INTERVAL_HOURS=6 HM_BACKFILL_FOREGROUND=1 HM_HARVEST_AUTO=1 HM_HARVEST_GLOBAL_DAYS=0 \
    env "$@" "$ROOT/scripts/backfill-due.sh"
}
run_tick_worker HM_IDLE_MINUTES=20 HM_IDLE_WAIT_HOURS=0
assert_eq "success" "$(jq -r '.components.backfill.last_result' "$TICK_DATA/health.json")" "collection runs even while the user is active"
assert_not_file "$TICK_DATA/harvest-auto/runs.jsonl"
assert_eq "skipped:never_idle" "$(jq -r '"\(.llm):\(.reason)"' "$TICK_DATA/logs/schedule.jsonl" | tail -n 1)" "the schedule log says why LLM steps did not run"
jq '.components.backfill.last_attempt_at = "2020-01-01T00:00:00Z"' "$TICK_DATA/health.json" >"$TICK_DATA/h.tmp" && mv "$TICK_DATA/h.tmp" "$TICK_DATA/health.json"
mkdir -p "$TICK_DATA/harvest-auto"
jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at:$at,event:"finished",project:"x",result:"failed",reason:"usage_limit"}' >"$TICK_DATA/harvest-auto/runs.jsonl"
# 열린 세션은 쉬는 동안에도 시각 없는 줄(last-prompt·cost-state)을 덧붙인다. 파일 수정 시각이 아니라 마지막 기록 시각으로 판정한다.
{
  jq -cn '{type:"user",timestamp:"2000-01-01T00:00:00.000Z"}'
  jq -cn '{type:"last-prompt",lastPrompt:"x"}'
  jq -cn '{type:"cost-state",totalCostUSD:0}'
} >"$TICK_CLAUDE/active.jsonl"
run_tick_worker HM_IDLE_MINUTES=20 HM_IDLE_WAIT_HOURS=0
assert_eq "1" "$(wc -l <"$TICK_DATA/harvest-auto/runs.jsonl" | tr -d ' ')" "LLM steps rest right after a usage limit"
assert_eq "skipped:usage_backoff" "$(jq -r '"\(.llm):\(.reason)"' "$TICK_DATA/logs/schedule.jsonl" | tail -n 1)" "the schedule log names the usage backoff"
jq '.components.backfill.last_attempt_at = "2020-01-01T00:00:00Z"' "$TICK_DATA/health.json" >"$TICK_DATA/h.tmp" && mv "$TICK_DATA/h.tmp" "$TICK_DATA/health.json"
: >"$TICK_DATA/harvest-auto/runs.jsonl"
run_tick_worker HM_IDLE_MINUTES=20 HM_IDLE_WAIT_HOURS=0 HM_HARVEST_GLOBAL_DAYS=7 HM_HARVEST_AUTO_FOREGROUND=1 \
  HM_HARVEST_AUTO_AGENT=claude HM_HARVEST_AUTO_CMD="$AUTO_STUB" AUTO_STUB_OUT="$TEST_TMP/tick-stub.out"
assert_eq "_global" "$(cut -d'|' -f1 "$TEST_TMP/tick-stub.out")" "a session file touched only by untimestamped lines counts as idle, so LLM steps run"
assert_eq "ran" "$(jq -r .llm "$TICK_DATA/logs/schedule.jsonl" | tail -n 1)" "the schedule log records the run"
assert_eq "true" "$(jq -r '.started_at <= .at' "$TICK_DATA/logs/schedule.jsonl" | tail -n 1)" "the schedule log keeps when the round started"
idle_check() { # → active|idle (HM_IDLE_MINUTES=20 기준, 위 tick 디렉터리)
  HARNESS_METRICS_DIR="$TICK_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/tick-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/tick-codex" \
    bash -c 'source "$1"; hm_recently_active 20 && echo active || echo idle' _ "$ROOT/scripts/lib.sh"
}
assert_eq "idle" "$(idle_check)" "untimestamped tail lines alone are idle"
mkdir -p "$TEST_TMP/tick-codex/2999/01/01"
jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{timestamp:$t,type:"event_msg"}' >"$TEST_TMP/tick-codex/2999/01/01/rollout-x.jsonl"
assert_eq "active" "$(idle_check)" "a fresh Codex rollout line counts as activity"
jq -cn '{timestamp:"2000-01-01T00:00:00.000Z",type:"event_msg"}' >"$TEST_TMP/tick-codex/2999/01/01/rollout-x.jsonl"
assert_eq "idle" "$(idle_check)" "a Codex rollout touched recently but last stamped long ago is idle"
pass "hook-driven schedule with idle and usage gates"

# 규칙 품질: 보이지 않는 문자·비밀값 거부, 총량 상한, 효과 수치 판정(세션 시작 시각 기준).
RQ_DIR="$TEST_TMP/rule-quality"
mkdir -p "$RQ_DIR/events"
run_rq() {
  HARNESS_METRICS_DIR="$RQ_DIR" HM_GLOBAL_CLAUDE_MD="$RQ_DIR/C.md" HM_GLOBAL_CODEX_AGENTS_MD="$RQ_DIR/X.md" \
    HM_AUTO_RULES_MAX=2 "$ROOT/scripts/auto-apply.sh" "$@"
}
RQ_RC=0; run_rq apply --scope global --rule-id zw-rule --text "$(printf '정상\342\200\213문구')" --evidence a --expected b >/dev/null 2>&1 || RQ_RC=$?
assert_eq "2" "$RQ_RC" "invisible unicode is rejected"
RQ_RC=0; run_rq apply --scope global --rule-id secret-rule --text '토큰은 api_key=sk1234abcd 로 넣는다' --evidence a --expected b >/dev/null 2>&1 || RQ_RC=$?
assert_eq "2" "$RQ_RC" "secret-looking text is rejected"
RQ_RC=0; run_rq apply --scope global --rule-id bad-signal --text t --evidence a --expected b --signal '(' >/dev/null 2>&1 || RQ_RC=$?
assert_eq "2" "$RQ_RC" "invalid signal regex is rejected"
run_rq apply --scope global --rule-id rule-one --text "첫 규칙" --evidence a --expected b --signal "boom" >/dev/null
run_rq apply --scope global --rule-id rule-two --text "둘째 규칙" --evidence a --expected b >/dev/null
RQ_RC=0; run_rq apply --scope global --rule-id rule-three --text "셋째" --evidence a --expected b >/dev/null 2>&1 || RQ_RC=$?
assert_eq "5" "$RQ_RC" "rule cap blocks a new rule"
run_rq apply --scope global --rule-id rule-two --text "둘째 규칙 강화" --evidence a --expected b >/dev/null
# 효과: 적용 전 10세션 중 6개, 적용 후 시작한 30세션 중 3개에서 신호 → 20→10... 절반 이하면 improved
RQ_AT="$(run_rq list --active | jq -r 'select(.id=="rule-one") | .at')"
make_rq_session() { # $1=sid $2=started $3=hit(1/0)
  jq -cn --arg sid "$1" --arg st "$2" '{kind:"session",src:"claude",sid:$sid,project:"p",started:$st,ended:$st}'
  if [[ "$3" == "1" ]]; then jq -cn --arg sid "$1" '{kind:"error_sample",src:"claude",sid:$sid,project:"p",target:"Bash: boom happened",n:1}'; fi
}
for i in $(seq 1 10); do make_rq_session "b$i" "2026-01-01T00:00:0${i: -1}Z" $(( i <= 6 ? 1 : 0 )); done >"$RQ_DIR/events/before.jsonl"
for i in $(seq 1 30); do make_rq_session "a$i" "2999-01-01T00:00:00Z" $(( i <= 3 ? 1 : 0 )); done >"$RQ_DIR/events/after.jsonl"
# 적용 전 창은 적용 시각 직전 30일이라, 테스트에선 before 세션을 그 창 안으로 옮긴다.
RQ_BEFORE_AT="$(jq -rn --arg at "$RQ_AT" '$at | sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime - 86400 | strftime("%Y-%m-%dT%H:%M:%SZ")')"
sed -i.bak "s/2026-01-01T00:00:0[0-9]Z/$RQ_BEFORE_AT/" "$RQ_DIR/events/before.jsonl"
# 적용 전에 시작해 적용 후에 끝난 세션은 '적용 후'가 아니다.
jq -cn --arg st "$RQ_BEFORE_AT" '{kind:"session",src:"claude",sid:"straddle",project:"p",started:$st,ended:"2999-01-01T00:00:00Z"}' >>"$RQ_DIR/events/before.jsonl"
RQ_EFFECT="$(run_rq effect --rule-id rule-one)"
assert_eq "11|6|30|3|improved" "$(jq -r '"\(.before.sessions)|\(.before.hits)|\(.after.sessions)|\(.after.hits)|\(.verdict)"' <<<"$RQ_EFFECT")" "effect compares rates by session start and judges improvement"
assert_eq "pending" "$(HM_EFFECT_MIN_SESSIONS=100 run_rq effect --rule-id rule-one | jq -r .verdict)" "small samples stay pending"
assert_eq "pending" "$(HM_EFFECT_MIN_EXPECTED=50 run_rq effect --rule-id rule-one | jq -r .verdict)" "rare signals stay pending until enough events are expected"
pass "rule quality gates and measured effect"

# PreToolUse(Bash) DB 스캔 가드(opt-in)는 명령 위치의 DB 클라이언트·드라이버 쿼리 중 스키마 조건 없는 information_schema 정의·메타 조회만 막는다.
DB_GUARD_HOOK="$(jq -c '.hooks.PreToolUse[] | select(.hooks[0].command | contains("db-scan-guard"))' "$ROOT/hooks/hooks.json")"
assert_eq "4" "$(jq '.hooks.PreToolUse | length' "$ROOT/hooks/hooks.json")" "db scan guard joins the existing PreToolUse array (edit guard, db scan, background watchdog, heavy slot)"
assert_eq "3" "$(jq -r '.hooks[0].timeout' <<<"$DB_GUARD_HOOK")" "db scan guard stays inside a short budget"
GUARD_COMMAND="$(jq -r '.hooks[0].command' <<<"$DB_GUARD_HOOK")"
assert_contains "$GUARD_COMMAND" "$LITERAL_PLUGIN_ROOT" "db scan guard quoted plugin root"
assert_contains "$GUARD_COMMAND" "scripts/db-scan-guard.sh" "Bash PreToolUse hook runs the db scan guard"
GUARD_DATA="$TEST_TMP/guard-data"
mkdir -p "$GUARD_DATA"
run_db_guard() {
  jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | HM_DB_SCAN_GUARD="${2-1}" CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$GUARD_DATA" /bin/sh -c "$GUARD_COMMAND"
}
db_guard_verdict() { if [[ -n "$(run_db_guard "$1")" ]]; then echo deny; else echo allow; fi; }
GUARD_CASES=0
while IFS=$'\t' read -r expect command; do
  [[ -n "$expect" ]] || continue
  assert_eq "$expect" "$(db_guard_verdict "$command")" "db scan guard: $command"
  GUARD_CASES=$((GUARD_CASES + 1))
done <<'CASES'
deny	mysql -h 127.0.0.1 -u dev -e "select table_schema, table_name from information_schema.views where view_definition like '%orders%' union all select routine_schema, routine_name from information_schema.routines where routine_definition like '%orders%' union all select trigger_schema, trigger_name from information_schema.triggers where event_object_table = 'orders' or action_statement like '%orders%'"
deny	mysql -h 127.0.0.1 -u dev -e "select count(*) from information_schema.columns where column_name = 'use_yn' and table_name = 'orders'"
deny	mysql -u dev -e "select table_name from information_schema.views where table_schema = 'app' union all select routine_name from information_schema.routines where routine_definition like '%x%'"
deny	mysql -u dev -e "select table_name from information_schema.tables where table_schema = 'app'; select trigger_name from information_schema.triggers"
deny	mysql -u dev -e "select routine_name from `information_schema`.`ROUTINES` where routine_definition like '%x%'"
deny	mysql -u dev information_schema -e "select trigger_name from triggers where action_statement like '%x%'"
deny	mysql -u dev -e "use information_schema; select table_name from views where view_definition like '%x%'"
deny	mysql -u dev -e "select table_name from information_schema.tables where table_schema != 'mysql'"
deny	mysql -u dev -e "select table_name from information_schema.tables where table_schema not in ('mysql', 'sys')"
deny	mariadb -u dev -e "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE WHERE REFERENCED_TABLE_NAME = 'orders'"
deny	python3 -c "import pymysql; c = pymysql.connect(host='127.0.0.1', user='dev').cursor(); c.execute('select * from information_schema.triggers')"
deny	psql -h localhost -d app -c "select table_name from information_schema.views where view_definition like '%orders%'"
deny	mysql -u dev -e "select table_name from information_schema.tables where 1=1 or table_schema = 'app'"
deny	mysql -u dev -e "select table_name from information_schema.tables where table_name = 'x' -- and table_schema = 'app'"
deny	mysql -u dev -e "select table_name from information_schema.views where view_definition like '%table_schema = 1%'"
deny	mysql -u dev -e "select table_name from information_schema.views where /* table_schema = 'app' and */ view_definition like '%x%'"
deny	echo "select * from information_schema.views" | mysql -u dev
deny	MYSQL_PWD=x /usr/local/bin/mysql -u dev --execute="select * from information_schema.routines"
deny	sudo -u postgres psql -c "select table_name from information_schema.views"
allow	mysql -u dev -e "select table_name from information_schema.views where table_schema = 'app' and view_definition like '%orders%'"
allow	mysql -u dev -e "select routine_name from information_schema.routines where routine_schema = 'app' and routine_definition like '%x%' union all select trigger_name from information_schema.triggers where trigger_schema='app' and action_statement like '%x%'"
allow	mysql -u dev -e "select table_name from information_schema.referential_constraints where constraint_schema = 'app'; select table_name from information_schema.tables where table_schema in ('app', 'app_batch')"
allow	mysql -u dev -e "select column_name from information_schema.columns where table_schema = database() and table_name = 'orders'"
allow	mysql -u dev -e "select table_name from information_schema.views where table_schema = 'app' and (view_definition like '%a%' or view_definition like '%b%')"
allow	mysql -u dev -e "select schema_name from information_schema.schemata"
allow	psql -h localhost -d app -c "select table_name from information_schema.columns where column_name = 'id'"
allow	git commit -m "docs: mysql information_schema.views note"
allow	grep -rn "mysql -e 'select * from information_schema.views'" docs/
allow	echo "mysql -u dev -e select * from information_schema.triggers"
allow	git log --oneline --grep "information_schema.triggers"
allow	cd /tmp && mysql -u dev -e "select 1" && echo 'information_schema.views'
CASES
assert_eq "31" "$GUARD_CASES" "db scan guard case count"
assert_eq "deny" "$(db_guard_verdict $'mysql -u dev <<\'SQL\'\nselect table_name from information_schema.views;\nSQL')" "db scan guard reads heredoc SQL fed to a client"
assert_eq "allow" "$(db_guard_verdict $'cat > notes.md <<\'EOF\'\nmysql -e "select * from information_schema.views"\nEOF')" "db scan guard ignores heredoc documents"
assert_eq "allow" "$(db_guard_verdict $'git commit -m "$(cat <<\'EOF\'\ndocs: guard\n\nmysql -e "select * from information_schema.views"\nEOF\n)"')" "db scan guard ignores commit message heredocs"
assert_eq "" "$(run_db_guard "ls -la && git status")" "db scan guard ignores ordinary commands"
DENY_OUT="$(run_db_guard "mysql -u dev -e \"select * from information_schema.triggers\"")"
assert_contains "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$DENY_OUT")" "[DB scan guard] information_schema.TRIGGERS" "db scan guard names the table"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$DENY_OUT")" "db scan guard denies through PreToolUse decision"
# 기본은 꺼져 있고, 켜는 값은 config에서도 읽되 config를 셸로 실행하지 않는다.
assert_eq "" "$(run_db_guard "mysql -u dev -e \"select * from information_schema.triggers\"" "")" "db scan guard is off by default"
printf 'HM_DB_SCAN_GUARD=1\ntouch "%s/pwned"\n' "$GUARD_DATA" >"$GUARD_DATA/config"
assert_contains "$(run_db_guard "mysql -u dev -e \"select * from information_schema.triggers\"" "")" "deny" "db scan guard opt-in by config"
[[ ! -e "$GUARD_DATA/pwned" ]] || fail "db scan guard executed config as shell"
rm -f "$GUARD_DATA/config"
assert_eq "" "$(printf 'not json' | HM_DB_SCAN_GUARD=1 CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$GUARD_COMMAND")" "db scan guard fails open on bad input"
pass "db scan guard"

# 제거: 사람이 블록 밖에 같은 규칙을 직접 쓰면 자동 규칙은 중복이다. 문구 비교는 공백·대소문자·목록 기호를 무시한다.
DUP_HOME="$TEST_TMP/dup-home"
mkdir -p "$DUP_HOME"
printf '# 내 규칙\n' >"$DUP_HOME/CLAUDE.md"
run_dup() {
  HARNESS_METRICS_DIR="$TEST_TMP/dup-data" HM_GLOBAL_CLAUDE_MD="$DUP_HOME/CLAUDE.md" \
    HM_GLOBAL_CODEX_AGENTS_MD="$DUP_HOME/codex/AGENTS.md" "$ROOT/scripts/auto-apply.sh" "$@"
}
run_dup apply --scope global --rule-id quote-equals --text "zsh에서 =로 시작하는 단어는 따옴표로 감싼다" --evidence x --expected y >/dev/null
run_dup apply --scope global --rule-id jq-null --text "jq 순회 전 null을 거른다" --evidence x --expected y >/dev/null
assert_eq "" "$(run_dup duplicates)" "rules only inside the block are not duplicates"
printf '%s\n' '# 내 규칙' '*   ZSH에서 =로 시작하는   단어는 따옴표로 감싼다' "$(tail -n +2 "$DUP_HOME/CLAUDE.md")" >"$DUP_HOME/CLAUDE.md.new" && mv "$DUP_HOME/CLAUDE.md.new" "$DUP_HOME/CLAUDE.md"
# global 규칙은 Claude·Codex 두 지침에 들어 있다 — 한쪽에만 중복이면 revert가 다른 쪽의 유일한 사본까지 지운다.
assert_eq "" "$(run_dup duplicates)" "a duplicate in only one target file is not reported"
printf '%s\n' '- zsh에서 =로 시작하는 단어는 따옴표로 감싼다' "$(<"$DUP_HOME/codex/AGENTS.md")" >"$DUP_HOME/codex/AGENTS.md.new" && mv "$DUP_HOME/codex/AGENTS.md.new" "$DUP_HOME/codex/AGENTS.md"
DUPS="$(run_dup duplicates)"
assert_eq "quote-equals" "$(jq -r '.id' <<<"$DUPS")" "rule restated outside the block in every target is a duplicate"
assert_eq "2" "$(jq -r '.files[] | select(.file | endswith("CLAUDE.md")) | .line' <<<"$DUPS")" "duplicate reports the human-written line"
assert_eq "2" "$(jq -r '.files | length' <<<"$DUPS")" "duplicate lists every target file"
assert_eq "1" "$(jq -s 'length' <<<"$DUPS")" "rules not restated are not reported"
assert_contains "$(<"$ROOT/skills/harvest/SKILL.md")" "auto-apply.sh duplicates" "harvest prunes duplicated auto rules"
pass "duplicate auto rules are removal candidates"

# 제거 개선은 history에 change로 남아 다음 harvest가 '빠진 규칙이 필요했는가'로 검증한다.
CHG_DATA="$TEST_TMP/change-data"
mkdir -p "$CHG_DATA/harvest-queue/p-chg/sessions"
jq -n '{v:1,project:"chg",batch_id:"b1",created_at:"2026-01-01T00:00:00Z",counts:{},reasons:[],markers:[]}' >"$CHG_DATA/harvest-queue/p-chg/analysis-batch.json"
HARNESS_METRICS_DIR="$CHG_DATA" "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project chg --outcome improved \
  --summary "낡은 규칙 제거" --artifact "https://example.test/pr/1" --expected "같은 오류 재발 없음" --change remove >/dev/null
assert_eq "remove" "$(jq -r '.review.change' "$CHG_DATA/harvest-queue/p-chg/review-history.jsonl")" "review history records the change kind"
CHG_RC=0
HARNESS_METRICS_DIR="$CHG_DATA" "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project chg --change shrink >/dev/null 2>&1 || CHG_RC=$?
assert_eq "2" "$CHG_RC" "unknown change kind is rejected"
assert_contains "$(<"$ROOT/skills/harvest/SKILL.md")" "--change remove" "harvest records removals"
pass "harvest records removal changes"

# 하네스 생성물 버전 차이: SessionStart 알림과 opt-in 자동 sync (#137)
SYNC_DATA="$TEST_TMP/sync-data"
SYNC_PLUGIN="$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json")"
SYNC_ORIGIN="$TEST_TMP/sync-origin.git"
SYNC_REPO="$TEST_TMP/sync-repo"
SYNC_CUR="$TEST_TMP/sync-current"
SYNC_MIN="$TEST_TMP/sync-minimal"
SYNC_PLAIN="$TEST_TMP/sync-plain"
git init -q --bare "$SYNC_ORIGIN"
make_repo "$SYNC_REPO" "$SYNC_ORIGIN"
git -C "$SYNC_REPO" branch -M master
git -C "$SYNC_REPO" push -q origin master
git -C "$SYNC_REPO" checkout -q -b develop
mkdir -p "$SYNC_REPO/.ai-harness"
jq -n '{project_id:"sync-svc",harness_version:"0.1.0",level:"standard",integrations:["claude"]}' >"$SYNC_REPO/.ai-harness/harness.json"
git -C "$SYNC_REPO" add .ai-harness && git -C "$SYNC_REPO" commit -q -m harness
git -C "$SYNC_REPO" push -q origin develop
git -C "$SYNC_REPO" remote set-head origin master
make_repo "$SYNC_CUR"
mkdir -p "$SYNC_CUR/.ai-harness"
jq -n --arg v "$SYNC_PLUGIN" '{project_id:"sync-cur",harness_version:$v}' >"$SYNC_CUR/.ai-harness/harness.json"
git -C "$SYNC_CUR" add .ai-harness && git -C "$SYNC_CUR" commit -q -m harness
make_repo "$SYNC_MIN"
mkdir -p "$SYNC_MIN/.ai-harness"
jq -n '{project_id:"sync-min",harness_version:"0.1.0",level:"minimal",integrations:["claude"]}' >"$SYNC_MIN/.ai-harness/harness.json"
printf '%s\n' '<!doctype html><title>report</title>' >"$SYNC_MIN/report.html"
git -C "$SYNC_MIN" add .ai-harness report.html && git -C "$SYNC_MIN" commit -q -m harness
make_repo "$SYNC_PLAIN"
sync_cmd() { HARNESS_METRICS_DIR="$SYNC_DATA" "$ROOT/scripts/sync-auto.sh" "$@"; }
SYNC_REPO_REAL="$(cd "$SYNC_REPO" && pwd -P)"

SYNC_OUT="$(sync_cmd outdated --root "$SYNC_REPO" --root "$SYNC_CUR" --root "$SYNC_PLAIN")"
assert_eq "1" "$(jq -s 'length' <<<"$SYNC_OUT")" "only the repo behind the plugin is outdated"
assert_eq "$SYNC_REPO_REAL|sync-svc|origin/develop|0.1.0|$SYNC_PLUGIN" \
  "$(jq -r '"\(.repo)|\(.project)|\(.base)|\(.version)|\(.plugin)"' <<<"$SYNC_OUT")" "outdated row names repo, base and versions"
# 버전은 harness가 실제로 들어 있는 기준 브랜치에서 읽는다 — 사용자 체크아웃이 어디에 있든.
git -C "$SYNC_REPO" checkout -q master
assert_eq "0.1.0" "$(sync_cmd outdated --root "$SYNC_REPO" | jq -r '.version')" "version comes from the base branch, not the checkout"
git -C "$SYNC_REPO" checkout -q develop

# 루트를 주지 않으면 수집된 세션 기록의 작업 경로에서 찾는다. 같은 저장소의 worktree는 하나로 접는다.
git -C "$SYNC_REPO" worktree add -q -b sync-wt "$TEST_TMP/sync-repo-wt"
mkdir -p "$SYNC_DATA/events" "$SYNC_REPO/sub"
jq -cn --arg a "$SYNC_REPO/sub" --arg b "$TEST_TMP/sync-repo-wt" --arg c "$SYNC_PLAIN" --arg d "$TEST_TMP/gone" \
  '{kind:"session",cwd:$a},{kind:"session",cwd:$b},{kind:"session",cwd:$c},{kind:"session",cwd:$d}' >"$SYNC_DATA/events/sync.jsonl"
assert_eq "$SYNC_REPO_REAL" "$(sync_cmd outdated | jq -sr 'map(.repo) | join(",")')" "discovery dedupes worktrees to the main checkout"
# 같은 저장소의 별도 clone(또는 NFC·NFD로 갈라진 한글 경로)은 프로젝트 ID로 접는다 — 같은 sync PR이 두 번 열리지 않게.
git clone -q "$SYNC_ORIGIN" "$TEST_TMP/sync-repo-clone" 2>/dev/null
git -C "$TEST_TMP/sync-repo-clone" checkout -q develop
jq -cn --arg a "$TEST_TMP/sync-repo-clone" '{kind:"session",cwd:$a}' >>"$SYNC_DATA/events/sync.jsonl"
assert_eq "1" "$(sync_cmd outdated | jq -s 'map(select(.project=="sync-svc")) | length')" "separate clones of one project yield one row"

# 알림: 저장소·플러그인 버전 조합당 한 번. 자동 sync가 꺼져 있으면 수동 명령과 켜는 법을 안내한다.
sync_notify() { printf '{"cwd":"%s"}' "$1" | sync_cmd notify; }
SYNC_MSG="$(sync_notify "$SYNC_REPO/sub" | jq -r '.systemMessage // empty')"
assert_contains "$SYNC_MSG" "0.1.0" "notice names the repo harness version"
assert_contains "$SYNC_MSG" "/harness-init --sync" "notice names the sync command"
assert_contains "$SYNC_MSG" "HM_SYNC_AUTO=1" "notice explains how to turn on auto sync"
assert_eq "" "$(sync_notify "$SYNC_REPO")" "notice is shown once per repo and plugin version"
assert_eq "" "$(sync_notify "$SYNC_CUR")" "no notice for a current harness"
assert_eq "" "$(sync_notify "$SYNC_PLAIN")" "no notice without a harness"
HM_SYNC_AUTO=1 sync_notify "$SYNC_MIN" >"$TEST_TMP/sync-notice-auto"
assert_contains "$(jq -r '.systemMessage' "$TEST_TMP/sync-notice-auto")" "draft PR" "auto mode says a draft PR will follow"
SYNC_WS="$TEST_TMP/sync-ws"
mkdir -p "$SYNC_WS/.ai-harness"
jq -n '{kind:"workspace",workspace_id:"ws",harness_version:"0.1.0",members:[]}' >"$SYNC_WS/.ai-harness/workspace.json"
assert_contains "$(sync_notify "$SYNC_WS" | jq -r '.systemMessage')" "workspace" "workspace manifest behind the plugin is noticed"
assert_contains "$(<"$ROOT/scripts/session-start.sh")" "sync-auto.sh" "SessionStart runs the sync notice"

# 자동 sync: opt-in, 작업 전용 worktree에서 headless sync, 결과·버전 마커 기록, 버전당 1회.
SYNC_STUB="$TEST_TMP/sync-stub.sh"
cat >"$SYNC_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "${HM_HARVEST_RUNNING:-}" "$(pwd -P)" >>"$SYNC_STUB_OUT"
echo '{"type":"result","total_cost_usd":0.2,"result":"done\nAI_HARNESS_SYNC_RESULT outcome='"${SYNC_STUB_OUTCOME:-improved}"' artifact=https://example.com/pr/'"${SYNC_STUB_PR:-9}"'"}'
STUB
chmod +x "$SYNC_STUB"
sync_sweep() {
  HARNESS_METRICS_DIR="$SYNC_DATA" HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$SYNC_STUB" HM_HARVEST_AUTO_AGENT=claude \
    HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" \
    HM_HARVEST_GLOBAL_DAYS=0 SYNC_STUB_OUT="$TEST_TMP/sync-stub.out" "$ROOT/scripts/harvest-auto.sh" sweep
}
sync_runs() { jq -sr "$1" "$SYNC_DATA/harvest-auto/runs.jsonl"; }
sync_sweep
assert_not_file "$SYNC_DATA/harvest-auto/runs.jsonl"
HM_SYNC_AUTO=1 sync_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "auto sync launches one headless run"
SYNC_RUN_LINE="$(sed -n 1p "$TEST_TMP/sync-stub.out")"
assert_eq "sync-svc|1" "${SYNC_RUN_LINE%|*}" "sync run gets project and recursion guard"
assert_contains "${SYNC_RUN_LINE##*|}" "/auto-worktrees/" "sync runs in a dedicated worktree"
[[ "${SYNC_RUN_LINE##*|}" != "$SYNC_DATA"/* ]] || fail "the sync work tree must be outside the data directory"
assert_eq "develop" "$(git -C "$SYNC_REPO" branch --show-current)" "user checkout is untouched"
assert_eq "1" "$(git -C "$SYNC_REPO" worktree list | grep -vc sync-repo-wt | tr -d ' ')" "sync worktree is removed"
assert_eq "sync|improved|https://example.com/pr/9|0.2" \
  "$(sync_runs '[.[] | select(.event=="finished")] | last | "\(.scope)|\(.result)|\(.artifact)|\(.cost_usd)"')" "sync outcome and PR recorded"
assert_eq "$SYNC_PLUGIN|improved" "$(jq -r '"\(.plugin)|\(.result)"' "$SYNC_DATA/sync-auto/p-sync-svc.json")" "sync marker keeps the plugin version"
HM_SYNC_AUTO=1 sync_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "same plugin version is synced once"

# 적용할 관리 생성물이 없으면 에이전트를 띄우지 않는다(LLM 비용 0).
jq -cn --arg a "$SYNC_MIN" '{kind:"session",cwd:$a}' >>"$SYNC_DATA/events/sync.jsonl"
HM_SYNC_AUTO=1 sync_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "no-op sync skips the agent"
assert_eq "no-change" "$(jq -r '.result' "$SYNC_DATA/sync-auto/p-sync-min.json")" "no-op sync is recorded as no-change"
assert_contains "$(grep -rh '켤 수 있는 stack' "$SYNC_DATA/harvest-auto/logs" 2>/dev/null)" "켤 수 있는 stack: ui (근거: report.html)" "no-op auto sync logs the stacks it could enable"

# 자동 harvest와 별개인 하루 상한.
jq '.result = "failed" | .fails = 1' "$SYNC_DATA/sync-auto/p-sync-svc.json" >"$TEST_TMP/sync-marker" \
  && mv "$TEST_TMP/sync-marker" "$SYNC_DATA/sync-auto/p-sync-svc.json"
HM_SYNC_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=1 sync_sweep
assert_eq "daily_max" "$(sync_runs 'last | .reason')" "sync daily cap"
HM_SYNC_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=5 sync_sweep
assert_eq "2" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "failed sync is retried"
# shellcheck disable=SC2016
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" '--sync --apply --auto --base $base' "agent is told to sync unattended"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "AI_HARNESS_SYNC_RESULT" "harness-init reports the unattended result"
assert_contains "$(<"$ROOT/scripts/backfill-due.sh")" "HM_SYNC_AUTO" "scheduled run includes auto sync"
# 에이전트를 띄우지 않은 no-op sync는 하루 상한에서 빠진다(started 2건 중 1건이 no_agent).
assert_eq "true" "$(sync_runs '[.[] | select(.event=="finished" and .result=="no-change")] | last | .no_agent')" "no-op sync is marked no_agent"
# 실행 lock을 못 잡아도 실패 횟수는 보존된다.
mkdir -p "$SYNC_DATA/harvest-auto/running.lock" && printf '%s\n' "$$" >"$SYNC_DATA/harvest-auto/running.lock/pid"
jq -cn --arg p "$SYNC_PLUGIN" '{plugin:$p,result:"launched",fails:2}' >"$SYNC_DATA/sync-auto/p-sync-svc.json"
HARNESS_METRICS_DIR="$SYNC_DATA" HM_HARVEST_AUTO_CMD="$SYNC_STUB" "$ROOT/scripts/harvest-auto.sh" run sync-svc "sync-$SYNC_PLUGIN" "$SYNC_REPO" claude sync
assert_eq "failed|2" "$(jq -r '"\(.result)|\(.fails)"' "$SYNC_DATA/sync-auto/p-sync-svc.json")" "busy sync keeps the failure count"
find "$SYNC_DATA/harvest-auto/running.lock" -depth -delete
# 무인 에이전트는 origin 형태의 force push·+refspec도 금지된다.
for SYNC_DENY in 'git push origin --force*' 'git push origin +*' 'git push -u origin -f*'; do
  assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" "\"Bash($SYNC_DENY)\"" "unattended agent cannot $SYNC_DENY"
done
# 저장소가 정한 base_branch는 브랜치 이름 형태만 받는다(무인 에이전트 지시문까지 가는 값).
jq '.base_branch = "--upload-pack=x"' "$SYNC_REPO/.ai-harness/harness.json" >"$TEST_TMP/sync-hj" && mv "$TEST_TMP/sync-hj" "$SYNC_REPO/.ai-harness/harness.json"
assert_eq "origin/develop" "$(HARNESS_METRICS_DIR="$SYNC_DATA" bash -c 'source "$1/scripts/lib.sh"; hm_resolve_base "$2" --no-fetch' _ "$ROOT" "$SYNC_REPO")" "invalid base_branch is ignored"
git -C "$SYNC_REPO" checkout -q -- .ai-harness/harness.json
# 알림은 체크아웃이 아니라 기준 브랜치 ref를 본다 — 하네스 없는 브랜치에 있어도 같은 판정.
git -C "$SYNC_REPO" checkout -q master
SYNC_DATA2="$TEST_TMP/sync-data2"
assert_contains "$(printf '{"cwd":"%s"}' "$SYNC_REPO" | HARNESS_METRICS_DIR="$SYNC_DATA2" "$ROOT/scripts/sync-auto.sh" notify | jq -r '.systemMessage')" "0.1.0" "notice reads the base branch, not the checkout"
git -C "$SYNC_REPO" checkout -q develop
pass "harness version notice and opt-in auto sync"

# 일부 적용이면 harness_version이 그대로라 다음 버전 sync가 같은 파일로 새 PR을 열고 옛 PR이 쌓였다.
# 새 PR이 열리면 아무도 손대지 않은 옛 sync PR을 닫고, 사람이 리뷰 중이면 새 sync를 띄우지 않는다.
export PRS_STUB_DIR="$TEST_TMP/pr-stub"
mkdir -p "$PRS_STUB_DIR"
cat >"$PRS_STUB_DIR/pr" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --status) id="${2##*/}"; [[ -z "${PRS_STUB_NOCREDS:-}" ]] || exit 4; [[ ! -f "$PRS_STUB_DIR/down" ]] || exit 5; cat "$PRS_STUB_DIR/state-$id.json" 2>/dev/null || echo '{"state":"open","activity":0}' ;;
  --decline) printf '%s|%s\n' "$2" "$4" >>"$PRS_STUB_DIR/declined" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$PRS_STUB_DIR/pr"
prs_sweep() { # 이전 플러그인 버전으로 끝난 것처럼 마커를 되돌린 뒤 sweep
  jq -cn '{plugin:"0.0.1",result:"partial",fails:0}' >"$SYNC_DATA/sync-auto/p-sync-svc.json"
  HM_SYNC_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=99 HM_OPEN_PR_CMD="$PRS_STUB_DIR/pr" sync_sweep
}
PRS_LAUNCHED="$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')"
SYNC_STUB_PR=10 SYNC_STUB_OUTCOME=partial prs_sweep
assert_eq "$((PRS_LAUNCHED + 1))" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "a newer plugin version runs sync again"
assert_eq "https://example.com/pr/9" "$(cut -d'|' -f1 "$PRS_STUB_DIR/declined")" "the untouched older sync PR is declined"
assert_contains "$(cut -d'|' -f2 "$PRS_STUB_DIR/declined")" "https://example.com/pr/10" "decline comment links the new PR"
assert_eq "https://example.com/pr/9|https://example.com/pr/10" \
  "$(sync_runs '[.[] | select(.event=="superseded")] | last | "\(.artifact)|\(.by)"')" "superseded PR is recorded"
# 이미 닫힌 PR과 새 PR 자신은 닫지 않는다.
printf '%s\n' '{"state":"closed","activity":0}' >"$PRS_STUB_DIR/state-9.json"
SYNC_STUB_PR=11 prs_sweep
assert_eq "https://example.com/pr/10" "$(sed -n 2p "$PRS_STUB_DIR/declined" | cut -d'|' -f1)" "only open older PRs are declined"
assert_eq "2" "$(wc -l <"$PRS_STUB_DIR/declined" | tr -d ' ')" "closed PRs and the new PR itself are left alone"
# 사람이 코멘트·리뷰·승인을 남긴 옛 PR이 열려 있으면 새 sync를 띄우지 않는다.
printf '%s\n' '{"state":"open","activity":2}' >"$PRS_STUB_DIR/state-11.json"
PRS_LAUNCHED="$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')"
SYNC_STUB_PR=12 prs_sweep
assert_eq "$PRS_LAUNCHED" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "sync waits while a person reviews the older sync PR"
assert_eq "sync_pr_in_review" "$(sync_runs 'last | .reason')" "the skip names the reason"
assert_eq "2" "$(wc -l <"$PRS_STUB_DIR/declined" | tr -d ' ')" "a reviewed PR is never declined"
# PR 상태를 못 읽으면 판정하지 않고 기다린다 — 그대로 띄우면 PR이 다시 쌓인다.
rm -f "$PRS_STUB_DIR/state-11.json" && : >"$PRS_STUB_DIR/down"
SYNC_STUB_PR=12 prs_sweep
assert_eq "$PRS_LAUNCHED" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "unknown PR state holds the sync"
assert_eq "sync_pr_status_unknown" "$(sync_runs 'last | .reason')" "the hold names the reason"
rm -f "$PRS_STUB_DIR/down"
# 자격증명이 끝내 없어(open-pr.sh 종료 코드 4) 못 읽은 것은 로그인 풀림과 다른 이유로 남긴다(#299) — 보드가 원인과 고칠 곳을 가른다.
SYNC_STUB_PR=12 PRS_STUB_NOCREDS=1 prs_sweep
assert_eq "$PRS_LAUNCHED" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "missing PR host credentials still hold the sync"
assert_eq "sync_pr_no_credentials" "$(sync_runs 'last | .reason')" "the hold says the credentials are missing"
# 지원하지 않는 호스트의 PR은 읽을 수 없을 뿐 일시 장애가 아니다 — 막지 않는다(위 sync 테스트의 example.com PR이 그 경우).
# 새 PR이 열려 있지 않으면(에이전트가 적은 URL이 틀림) 옛 PR을 닫지 않는다. 다른 저장소의 PR도 닫지 않는다.
printf '%s\n' '{"state":"closed","activity":0}' >"$PRS_STUB_DIR/state-13.json"
SYNC_STUB_PR=13 prs_sweep
assert_eq "2" "$(wc -l <"$PRS_STUB_DIR/declined" | tr -d ' ')" "nothing is declined when the new PR is not open"
jq -cn '{at:"2026-01-01T00:00:00Z",event:"finished",project:"sync-svc",scope:"sync",result:"partial",artifact:"https://other.example/pr/7"}' >>"$SYNC_DATA/harvest-auto/runs.jsonl"
rm -f "$PRS_STUB_DIR/state-13.json"
SYNC_STUB_PR=14 prs_sweep
assert_contains "$(cat "$PRS_STUB_DIR/declined")" "https://example.com/pr/13" "the latest untouched PR of the same repo is declined"
if grep -q other.example "$PRS_STUB_DIR/declined"; then fail "a PR of another repo with the same project id is left alone"; fi
# activity: GitHub는 봇의 코멘트·리뷰를 세지 않고, Bitbucket은 코멘트 수 + 승인·변경 요청 참여자를 센다.
PRS_BIN="$TEST_TMP/pr-bin"
mkdir -p "$PRS_BIN"
cat >"$PRS_BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null,"comments":[{"author":{"login":"ci-preview[bot]"}},{"author":{"login":"alice"}}],"reviews":[{"author":{"login":"github-actions"}}]}'
STUB
cat >"$PRS_BIN/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n200' '{"state":"OPEN","comment_count":1,"participants":[{"approved":false,"state":null},{"approved":true,"state":"approved"},{"approved":false,"state":"changes_requested"}]}'
STUB
chmod +x "$PRS_BIN/gh" "$PRS_BIN/curl"
assert_eq "open|1" "$(PATH="$PRS_BIN:$PATH" "$ROOT/scripts/open-pr.sh" --status https://github.com/acme/svc/pull/3 | jq -r '"\(.state)|\(.activity)"')" "GitHub activity ignores bots"
assert_eq "open|3" "$(PATH="$PRS_BIN:$PATH" ATLASSIAN_USER=u BITBUCKET_API_TOKEN=t "$ROOT/scripts/open-pr.sh" --status https://bitbucket.org/ws/repo/pull-requests/4 | jq -r '"\(.state)|\(.activity)"')" "Bitbucket activity counts comments and reviewing participants"
# 무인 실행(launchd)에는 셸 환경변수가 없다. Claude Code settings.json env에 둔 Bitbucket 자격증명으로 조회한다(#299).
mkdir -p "$TEST_TMP/prs-settings-bin"
cat >"$TEST_TMP/prs-settings-bin/curl" <<'STUB'
#!/usr/bin/env bash
cat >"$PRS_CURL_CFG"
printf '%s\n200' '{"state":"OPEN","comment_count":0,"participants":[]}'
STUB
chmod +x "$TEST_TMP/prs-settings-bin/curl"
jq -cn '{env: {ATLASSIAN_USER: "bot@example.com", BITBUCKET_API_TOKEN: "settings-token"}}' >"$TEST_TMP/prs-settings.json"
assert_eq "open" "$(env -u ATLASSIAN_USER -u BITBUCKET_API_TOKEN PATH="$TEST_TMP/prs-settings-bin:$PATH" PRS_CURL_CFG="$TEST_TMP/prs-curl.cfg" \
  HARNESS_CLAUDE_SETTINGS="$TEST_TMP/prs-settings.json" "$ROOT/scripts/open-pr.sh" --status https://bitbucket.org/ws/repo/pull-requests/4 | jq -r '.state')" \
  "Bitbucket status reads credentials from Claude settings env when the shell has none"
assert_eq 'user = "bot@example.com:settings-token"' "$(cat "$TEST_TMP/prs-curl.cfg")" "the settings credentials go to curl on stdin"
assert_eq 'user = "u:t"' "$(env PATH="$TEST_TMP/prs-settings-bin:$PATH" PRS_CURL_CFG="$TEST_TMP/prs-curl.cfg" ATLASSIAN_USER=u BITBUCKET_API_TOKEN=t \
  HARNESS_CLAUDE_SETTINGS="$TEST_TMP/prs-settings.json" "$ROOT/scripts/open-pr.sh" --status https://bitbucket.org/ws/repo/pull-requests/4 >/dev/null; cat "$TEST_TMP/prs-curl.cfg")" \
  "shell environment credentials win over Claude settings"
# PR 호스트 요청 형태(dry-run): GitHub close, Bitbucket decline + 메시지.
assert_eq "github|https://github.com/acme/svc/pull/3|x" \
  "$(HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --decline https://github.com/acme/svc/pull/3 --comment x | jq -r '"\(.provider)|\(.decline)|\(.comment)"')" "GitHub decline request"
assert_eq "bitbucket|x" \
  "$(HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --decline https://bitbucket.org/ws/repo/pull-requests/4 --comment x | jq -r '"\(.provider)|\(.message)"')" "Bitbucket decline request"
if HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --decline https://example.com/pr/1 >/dev/null 2>&1; then fail "unknown PR hosts are refused"; fi
pass "auto sync supersedes its own older PRs"

# 자동 병합(opt-in): 내용 판정은 로컬 git 객체로, 병합은 호스트 상태(같은 head·대상 브랜치·CI 통과·사람 활동 없음)를 본 뒤에.
AM_REPO="$TEST_TMP/am-repo"
make_repo "$AM_REPO" https://github.com/acme/am.git
git -C "$AM_REPO" checkout -q -b develop
mkdir -p "$AM_REPO/.ai-harness/workflows" "$AM_REPO/.ai-harness/docs"
# 저장소 auto_merge 설정 없이 사용자 설정만으로 동작한다(#250).
jq -n '{project_id:"am-svc",harness_version:"0.1.0",git_policy:"pr-only",managed_files:{}}' >"$AM_REPO/.ai-harness/harness.json"
printf '# rules\n' >"$AM_REPO/AGENTS.md"
printf '# testing\n' >"$AM_REPO/.ai-harness/docs/testing.md"
printf 'x\n' >"$AM_REPO/app.js"
git -C "$AM_REPO" add -A && git -C "$AM_REPO" commit -q -m base
git -C "$AM_REPO" update-ref refs/remotes/origin/develop develop
am_sha() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | awk '{print $1}'; }
am_branch() { git -C "$AM_REPO" checkout -q -B "$1" develop; }
am_commit() { git -C "$AM_REPO" add -A && git -C "$AM_REPO" commit -q -m "$1" && git -C "$AM_REPO" rev-parse HEAD; }
am_manifest() { jq "$1" "$AM_REPO/.ai-harness/harness.json" >"$AM_REPO/.ai-harness/hj" && mv "$AM_REPO/.ai-harness/hj" "$AM_REPO/.ai-harness/harness.json"; }
am_check() { "$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/develop "$@"; }
AM_RUNNER=".ai-harness/workflows/workflow-driver.sh"
am_sync_head() { # 러너를 템플릿 그대로 넣고 manifest 해시를 맞춘 sync 커밋
  am_branch "$1"
  mkdir -p "$AM_REPO/.ai-harness/workflows"
  cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
  am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
}
am_sync_head s-ok
AM_SYNC_OK="$(am_commit sync)"
assert_eq "ok" "$(am_check --scope sync --head "$AM_SYNC_OK")" "a copy-only sync PR passes"
assert_eq "partial_sync" "$(am_check --scope sync --head "$AM_SYNC_OK" --result partial)" "partial sync needs its own opt-in"
AM_REVIEW='{"review":{"first_pass":"pass","expected":"재발 0"}}'
# 저장소 조정값은 기준 브랜치 manifest에서만 읽고, 플러그인 상한을 넘지 못한다.
am_base_with() { # name jq-filter → origin/<name>: develop에 manifest 조정값을 바꾼 기준 브랜치
  git -C "$AM_REPO" checkout -q -B "$1" develop && am_manifest "$2" && git -C "$AM_REPO" commit -q -am "$1"
  git -C "$AM_REPO" update-ref "refs/remotes/origin/$1" "$1"
}
am_on() { # base-name branch → base 위에서 새 브랜치
  git -C "$AM_REPO" checkout -q -B "$2" "$1"
}
am_base_with partial-on '.auto_merge.sync_partial = true'
am_on partial-on s-partial
mkdir -p "$AM_REPO/.ai-harness/workflows"
cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
AM_PARTIAL="$(am_commit partial)"
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/partial-on --scope sync --head "$AM_PARTIAL" --result partial)" "partial sync passes when the base manifest allows it"
am_base_with lines-60 '.auto_merge.harvest_max_lines = 60'
am_on lines-60 h-60 && seq 1 60 >>"$AM_REPO/AGENTS.md"
AM_H60="$(am_commit h60)"
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/lines-60 --scope project --head "$AM_H60" --review "$AM_REVIEW")" "the repo can raise the harvest line cap"
am_base_with lines-999 '.auto_merge.harvest_max_lines = 999'
am_on lines-999 h-999 && seq 1 101 >>"$AM_REPO/AGENTS.md"
assert_eq "too_many_lines:101" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/lines-999 --scope project --head "$(am_commit h999)" --review "$AM_REVIEW")" "the plugin cap still applies"
am_base_with files-big '.auto_merge.harvest_max_files = 1e20'
am_on files-big h-files && for f in a b c d e f; do printf 'x\n' >"$AM_REPO/.ai-harness/docs/$f.md"; done
assert_eq "too_many_files:6" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/files-big --scope project --head "$(am_commit hfiles)" --review "$AM_REVIEW")" "a huge cap is clamped to the plugin cap"
am_base_with lines-bad '.auto_merge.harvest_max_lines = "999"'
am_on lines-bad h-bad && seq 1 41 >>"$AM_REPO/AGENTS.md"
assert_eq "too_many_lines:41" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/lines-bad --scope project --head "$(am_commit hbad)" --review "$AM_REVIEW")" "a non-number value falls back to the default"
# 조정값은 사용자 설정 HM_AUTO_MERGE_*로도 정한다. 저장소 값이 함께 있으면 안전한 쪽(작은 상한·엄격한 불리언)을 쓴다.
assert_eq "ok" "$(HM_AUTO_MERGE_SYNC_PARTIAL=1 am_check --scope sync --head "$AM_SYNC_OK" --result partial)" "the user setting allows partial sync without a repo setting"
am_base_with partial-off '.auto_merge.sync_partial = false'
am_on partial-off s-partial-off
mkdir -p "$AM_REPO/.ai-harness/workflows"
cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
AM_PARTIAL_OFF="$(am_commit partialoff)"
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/partial-off --scope sync --head "$AM_PARTIAL_OFF")" "the strict fixture itself passes as a full sync"
assert_eq "partial_sync" "$(HM_AUTO_MERGE_SYNC_PARTIAL=1 "$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/partial-off --scope sync --head "$AM_PARTIAL_OFF" --result partial)" "a repo that refuses partial sync stays strict"
assert_eq "partial_sync" "$(HM_AUTO_MERGE_SYNC_PARTIAL=0 "$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/partial-on --scope sync --head "$AM_PARTIAL" --result partial)" "a user who refuses partial sync stays strict"
am_branch h-u60 && seq 1 60 >>"$AM_REPO/AGENTS.md"
AM_HU60="$(am_commit hu60)"
assert_eq "ok" "$(HM_AUTO_MERGE_HARVEST_MAX_LINES=60 am_check --scope project --head "$AM_HU60" --review "$AM_REVIEW")" "the user setting raises the harvest line cap"
assert_eq "too_many_lines:60" "$(HM_AUTO_MERGE_HARVEST_MAX_LINES=50 "$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/lines-60 --scope project --head "$AM_H60" --review "$AM_REVIEW")" "with both set the smaller cap wins"
am_branch h-u999 && seq 1 101 >>"$AM_REPO/AGENTS.md"
assert_eq "too_many_lines:101" "$(HM_AUTO_MERGE_HARVEST_MAX_LINES=999 am_check --scope project --head "$(am_commit hu999)" --review "$AM_REVIEW")" "the plugin cap applies to the user setting"
assert_eq "too_many_lines:60" "$(HM_AUTO_MERGE_HARVEST_MAX_LINES=abc am_check --scope project --head "$AM_HU60" --review "$AM_REVIEW")" "a bad user value falls back to the default"
am_sync_head s-bytes
printf '# edited\n' >>"$AM_REPO/$AM_RUNNER"
am_manifest ".managed_files[\"$AM_RUNNER\"].content_sha256 = \"$(am_sha "$AM_REPO/$AM_RUNNER")\""
assert_eq "copy_differs:$AM_RUNNER" "$(am_check --scope sync --head "$(am_commit bytes)")" "a copy that differs from the template is refused"
am_sync_head s-mode
chmod 644 "$AM_REPO/$AM_RUNNER"
assert_eq "bad_mode:100644:$AM_RUNNER" "$(am_check --scope sync --head "$(am_commit mode)")" "a copy must keep the template's executable bit"
am_sync_head s-hash
am_manifest ".managed_files[\"$AM_RUNNER\"].content_sha256 = \"0000\""
assert_eq "manifest_hash_mismatch:$AM_RUNNER" "$(am_check --scope sync --head "$(am_commit hash)")" "a manifest hash that does not match is refused"
am_sync_head s-policy
am_manifest '.git_policy = "merge"'
assert_eq "manifest_policy_changed" "$(am_check --scope sync --head "$(am_commit policy)")" "a sync that changes policy fields is refused"
am_sync_head s-render
mkdir -p "$AM_REPO/.claude/commands" && printf 'x\n' >"$AM_REPO/.claude/commands/review.md"
assert_eq "render_file:.claude/commands/review.md" "$(am_check --scope sync --head "$(am_commit render)")" "a render artifact needs a person"
# render 파일도 스크립트 결과와 바이트 같으면 기계적으로 검증된다(#316). 한 글자라도 다르면 지금처럼 사람에게.
am_sync_head s-render-ok
mkdir -p "$AM_REPO/.claude/commands"
"$ROOT/scripts/render-managed-file.sh" --path .claude/commands/review.md >"$AM_REPO/.claude/commands/review.md"
am_manifest ".managed_files[\".claude/commands/review.md\"] = {content_sha256:\"$(am_sha "$AM_REPO/.claude/commands/review.md")\"}"
assert_eq "render_unmarked:.claude/commands/review.md" "$(am_check --scope sync --head "$(am_commit renderunmarked)")" "a new render must be recorded with the renderer mark"
am_manifest ".managed_files[\".claude/commands/review.md\"].renderer = 1"
assert_eq "ok" "$(am_check --scope sync --head "$(am_commit renderok)")" "a render artifact equal to the render script passes"
am_sync_head s-render-edit
mkdir -p "$AM_REPO/.claude/commands"
"$ROOT/scripts/render-managed-file.sh" --path .claude/commands/review.md >"$AM_REPO/.claude/commands/review.md"
printf ' ' >>"$AM_REPO/.claude/commands/review.md"
am_manifest ".managed_files[\".claude/commands/review.md\"] = {content_sha256:\"$(am_sha "$AM_REPO/.claude/commands/review.md")\"}"
assert_eq "render_file:.claude/commands/review.md" "$(am_check --scope sync --head "$(am_commit renderedit)")" "a render artifact one byte off needs a person"
# 예전 손 렌더(저장소 맞춤 포함)가 기록된 저장소: 해시가 맞아도 base manifest에 renderer 표시가 없으면 첫 결정적
# render PR은 사람이 본다. 표시는 base(대상 브랜치) 것만 믿는다 — head에 표시를 넣어도 통과하지 않는다.
am_render_base() { # name renderer-mark(0|1) → origin/<name>: 옛 진입점이 기록된 기준 브랜치
  git -C "$AM_REPO" checkout -q -B "$1" develop
  mkdir -p "$AM_REPO/.claude/commands"
  # shellcheck disable=SC2016  # $ARGUMENTS는 옛 진입점의 자리표시자 문자열이다
  printf -- '---\ndescription: old\n---\n\n- team routing line\n\n요청: $ARGUMENTS\n' >"$AM_REPO/.claude/commands/review.md"
  am_manifest ".managed_files[\".claude/commands/review.md\"] = {content_sha256:\"$(am_sha "$AM_REPO/.claude/commands/review.md")\"} + (if $2 == 1 then {renderer: 1} else {} end)"
  git -C "$AM_REPO" add -A && git -C "$AM_REPO" commit -q -m "$1"
  git -C "$AM_REPO" update-ref "refs/remotes/origin/$1" "$1"
}
am_render_head() { # base branch → 옛 진입점을 스크립트 결과로 바꾼 sync 커밋
  am_on "$1" "$2"
  "$ROOT/scripts/render-managed-file.sh" --path .claude/commands/review.md >"$AM_REPO/.claude/commands/review.md"
  am_manifest ".harness_version = \"9.9.9\" | .managed_files[\".claude/commands/review.md\"] = {content_sha256:\"$(am_sha "$AM_REPO/.claude/commands/review.md")\", renderer: 1}"
  am_commit "$2"
}
am_render_base render-unmarked 0
assert_eq "render_first:.claude/commands/review.md" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/render-unmarked --scope sync --head "$(am_render_head render-unmarked s-render-first)")" "the first deterministic render over an unmarked hand render needs a person"
am_render_base render-marked 1
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/render-marked --scope sync --head "$(am_render_head render-marked s-render-next)")" "a render over a marked deterministic render passes"
# 표시가 있어도 base 파일을 사람이 고치고 다시 기록하지 않았으면 사람이 본다.
am_render_base render-drift 1
printf -- '- edited later\n' >>"$AM_REPO/.claude/commands/review.md"
git -C "$AM_REPO" commit -q -am render-drift-edit && git -C "$AM_REPO" update-ref refs/remotes/origin/render-drift render-drift
assert_eq "render_modified:.claude/commands/review.md" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/render-drift --scope sync --head "$(am_render_head render-drift s-render-drift)")" "a marked render a person edited after recording needs a person"
am_sync_head s-del
git -C "$AM_REPO" rm -q app.js
assert_eq "unsupported_change:D:app.js" "$(am_check --scope sync --head "$(am_commit del)")" "a deletion is refused"
# 기준 브랜치에 이미 관리 항목이 있는 저장소(실제 저장소는 모두 그렇다): 남아 있으면 통과, 지우면 거부.
am_base_with managed '.managed_files["AGENTS.md"] = {content_sha256:"aaaa"}'
am_on managed s-keep
mkdir -p "$AM_REPO/.ai-harness/workflows" && cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/managed --scope sync --head "$(am_commit keep)")" "existing managed entries that stay are fine"
am_manifest '.managed_files["AGENTS.md"].template_version = "9.9.9"'
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/managed --scope sync --head "$(am_commit tv)")" "recording a new template_version for an untouched file is fine"
am_manifest '.managed_files["app.js"] = {template_version:"x"}'
assert_eq "manifest_hash_changed_without_file:app.js" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/managed --scope sync --head "$(am_commit newkey)")" "a new entry without its file is refused"
am_manifest 'del(.managed_files["app.js"]) | del(.managed_files["AGENTS.md"])'
assert_eq "manifest_entry_removed" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/managed --scope sync --head "$(am_commit drop)")" "removing a managed entry is refused"
am_sync_head s-otherhash
am_manifest '.managed_files["AGENTS.md"] = {content_sha256:"1111"}'
assert_eq "manifest_hash_changed_without_file:AGENTS.md" "$(am_check --scope sync --head "$(am_commit otherhash)")" "hashes of untouched files cannot change"
am_sync_head s-tab
printf 'x\n' >"$AM_REPO/$AM_RUNNER"$'\t'
assert_eq "bad_path" "$(am_check --scope sync --head "$(am_commit tab)")" "a path with a tab cannot pose as a managed file"
# harvest PR: 문서만, 작게, 일반 파일 모드, 1회차 독립 검토 통과·기대효과 기록.
am_hcheck() { am_check --scope project --head "$1" --review "${2:-$AM_REVIEW}"; }
am_branch h-ok
printf -- '- 새 규칙\n' >>"$AM_REPO/AGENTS.md"
AM_HARVEST_OK="$(am_commit harvest)"
assert_eq "ok" "$(am_hcheck "$AM_HARVEST_OK")" "a small doc-only harvest PR passes"
assert_eq "review_not_first_pass" "$(am_hcheck "$AM_HARVEST_OK" '{"review":{"first_pass":"revised","expected":"x"}}')" "a revised proposal needs a person"
assert_eq "no_expected_effect" "$(am_hcheck "$AM_HARVEST_OK" '{"review":{"first_pass":"pass"}}')" "an improvement without expected effect needs a person"
am_branch h-ko
printf -- '- 규칙\n' >"$AM_REPO/.ai-harness/docs/한글-규칙.md"
assert_eq "ok" "$(am_hcheck "$(am_commit ko)")" "Korean doc paths are read as they are"
am_branch h-newline
printf -- '- r\n' >>"$AM_REPO/AGENTS.md"
printf 'x\n' >"$AM_REPO/.ai-harness/docs/a.md"$'\n'"zz" && printf 'y\n' >>"$AM_REPO/app.js"
assert_eq "bad_path" "$(am_hcheck "$(am_commit newline)")" "a path with a newline cannot hide other entries"
am_branch h-rename
git -C "$AM_REPO" mv app.js .ai-harness/docs/app.md
assert_eq "unsupported_change:D:app.js" "$(am_hcheck "$(am_commit rename)")" "a rename cannot hide the deleted source"
am_branch h-link
rm "$AM_REPO/AGENTS.md" && ln -s /etc/hosts "$AM_REPO/AGENTS.md"
assert_eq "unsupported_change:T:AGENTS.md" "$(am_hcheck "$(am_commit link)")" "a doc turned into a symlink is refused"
am_branch h-exec
printf -- '- r\n' >>"$AM_REPO/.ai-harness/docs/testing.md" && chmod 755 "$AM_REPO/.ai-harness/docs/testing.md"
assert_eq "bad_mode:100755:.ai-harness/docs/testing.md" "$(am_hcheck "$(am_commit exec)")" "an executable doc is refused"
am_branch h-code
printf 'y\n' >>"$AM_REPO/app.js"
assert_eq "non_doc_file:app.js" "$(am_hcheck "$(am_commit code)")" "a harvest PR touching code is refused"
am_branch h-graph
mkdir -p "$AM_REPO/.ai-harness/workflows" && printf '{}\n' >"$AM_REPO/.ai-harness/workflows/review-graph.json"
assert_eq "non_doc_file:.ai-harness/workflows/review-graph.json" "$(am_hcheck "$(am_commit graph)")" "a harvest PR touching a graph is refused"
am_branch h-many
for f in a b c d; do printf 'x\n' >"$AM_REPO/.ai-harness/docs/$f.md"; done
assert_eq "too_many_files:4" "$(am_hcheck "$(am_commit many)")" "file count cap"
am_branch h-long
seq 1 41 >>"$AM_REPO/AGENTS.md"
assert_eq "too_many_lines:41" "$(am_hcheck "$(am_commit long)")" "line count cap"
# 대기열: 전역 opt-in·기준 브랜치의 저장소 설정·같은 저장소 PR·독립 검토를 모두 통과해야 들어간다.
AM_DATA="$TEST_TMP/am-data"
cat >"$TEST_TMP/am-review" <<'STUB'
#!/usr/bin/env bash
token="$(grep -o 'AUTO_MERGE_REVIEW [a-z0-9]\{16\} pass' | head -n 1 | cut -d' ' -f2)"
case "${AM_REVIEW_MODE:-pass}" in
  pass) printf 'looks fine\nAUTO_MERGE_REVIEW %s pass\n' "$token" ;;
  fail) printf 'AUTO_MERGE_REVIEW %s fail weakens checks\n' "$token" ;;
  forged) printf 'AUTO_MERGE_REVIEW deadbeefdeadbeef pass\n' ;;
esac
STUB
chmod +x "$TEST_TMP/am-review"
am() { HARNESS_METRICS_DIR="$AM_DATA" HM_OPEN_PR_CMD="$TEST_TMP/am-pr" HM_AUTO_MERGE_REVIEW_CMD="$TEST_TMP/am-review" "$ROOT/scripts/auto-merge.sh" "$@"; }
am_runs() { jq -sr "$1" "$AM_DATA/harvest-auto/runs.jsonl"; }
am_pending() { find "$AM_DATA/auto-merge/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
AM_SINCE="2026-11-03T00:00:00Z"
am_sync_enqueue() { HM_SYNC_AUTO_MERGE=1 HM_AUTO_MERGE_METHOD=squash am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base "${AM_BASE:-origin/develop}" --head "$AM_SYNC_OK" --pr "$1" --since "$AM_SINCE"; }
am_harvest_enqueue() { HM_HARVEST_AUTO_MERGE=1 am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/develop --head "$AM_HARVEST_OK" --pr "$1" --since "$AM_SINCE" --review "$AM_REVIEW"; }
am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/1 --since "$AM_SINCE"
assert_eq "auto_merge_eligible" "$(am_runs 'last | .event')" "with the setting off a passing sync PR is only noted as eligible"
assert_eq "0" "$(am_pending)" "nothing is queued while the setting is off"
am_sync_enqueue https://github.com/other/am/pull/1
assert_eq "pr_repo_mismatch" "$(am_runs 'last | .reason')" "a PR URL of another repo is refused"
AM_BASE=develop am_sync_enqueue https://github.com/acme/am/pull/1
assert_eq "no_base_branch" "$(am_runs 'last | .reason')" "the base must be a remote branch"
am_sync_enqueue https://github.com/acme/am/pull/1
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "a passing sync PR is queued"
assert_eq "1" "$(am_pending)" "one pending entry"
AM_REVIEW_MODE=fail am_harvest_enqueue https://github.com/acme/am/pull/20
assert_eq "independent_review_failed" "$(am_runs 'last | .reason')" "a harvest PR the independent reviewer fails is not queued"
AM_REVIEW_MODE=forged am_harvest_enqueue https://github.com/acme/am/pull/21
assert_eq "independent_review_failed" "$(am_runs 'last | .reason')" "a verdict without this run's token is not accepted"
am_harvest_enqueue https://github.com/acme/am/pull/22
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "a harvest PR passing the independent review is queued"
assert_eq "0" "$(am_runs '[.[] | select(.event == "auto_merge_legacy_switch")] | length')" "no legacy notice for a repo without auto_merge"
# 저장소 허용 스위치는 더 이상 막지 않는다(#250): auto_merge.harvest:false·auto_merge:false여도 사용자 설정이 켜져 있으면 대상이다.
am_base_with off '.auto_merge.harvest = false | .auto_merge.method = "merge"'
am_on off h-off && printf -- '- 새 규칙\n' >>"$AM_REPO/AGENTS.md"
AM_HARVEST_OFF="$(am_commit hoff)"
HM_HARVEST_AUTO_MERGE=1 am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/off --head "$AM_HARVEST_OFF" --pr https://github.com/acme/am/pull/23 --since "$AM_SINCE" --review "$AM_REVIEW"
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "a repo switch set to false no longer blocks"
assert_eq "auto_merge_legacy_switch" "$(am_runs '.[-2].event')" "the old repo switch is recorded for a notice"
assert_eq "merge" "$(jq -r 'select(.pr == "https://github.com/acme/am/pull/23") | .method' "$AM_DATA"/auto-merge/pending/*.json)" "the repo method is used when the user sets none"
am_base_with off-all '.auto_merge = false'
am_on off-all h-offall && printf -- '- 새 규칙\n' >>"$AM_REPO/AGENTS.md"
HM_HARVEST_AUTO_MERGE=1 HM_AUTO_MERGE_METHOD=squash am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/off-all --head "$(am_commit hoffall)" --pr https://github.com/acme/am/pull/24 --since "$AM_SINCE" --review "$AM_REVIEW"
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "auto_merge: false no longer blocks"
assert_eq "squash" "$(jq -r 'select(.pr == "https://github.com/acme/am/pull/24") | .method' "$AM_DATA"/auto-merge/pending/*.json)" "the user method comes first"
rm -f "$AM_DATA"/auto-merge/pending/*.json
am_sync_enqueue https://github.com/acme/am/pull/1
am_harvest_enqueue https://github.com/acme/am/pull/22
# sweep: 호스트 상태 스텁. CI 진행 중이면 기다리고, 통과하면 head를 고정해 병합한다.
cat >"$TEST_TMP/am-pr" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --status) id="${2##*/}"; cat "$AM_PR_STATE_DIR/$id.json" 2>/dev/null || cat "$AM_PR_STATE_DIR/default.json" ;;
  --merge) printf '%s|%s|%s\n' "$2" "$4" "$6" >>"$AM_PR_LOG"; exit "$(cat "$AM_PR_STATE_DIR/merge-rc" 2>/dev/null || echo 0)" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TEST_TMP/am-pr"
export AM_PR_STATE_DIR="$TEST_TMP/am-state" AM_PR_LOG="$TEST_TMP/am-merged"
mkdir -p "$AM_PR_STATE_DIR"
am_state() { jq -n --arg h "${2:-$AM_SYNC_OK}" "{state:\"open\",head:\$h,base:\"develop\",created:\"2026-11-03T00:05:00\",activity:0,mergeable:\"mergeable\",ci:\"success\",draft:true} | ${3:-.}" >"$AM_PR_STATE_DIR/$1.json"; }
am_state 1 "$AM_SYNC_OK" '.ci = "pending"'
am_state 22 "$AM_HARVEST_OK" '.ci = "pending"'
HM_SYNC_AUTO_MERGE=1 HM_HARVEST_AUTO_MERGE=1 am sweep
assert_eq "2" "$(am_pending)" "pending CI keeps the entries"
assert_not_file "$AM_PR_LOG"
am_state 1
am_state 22 "$AM_HARVEST_OK"
HM_SYNC_AUTO_MERGE=1 HM_HARVEST_AUTO_MERGE=1 am sweep
assert_eq "https://github.com/acme/am/pull/1|$AM_SYNC_OK|squash" "$(sort "$AM_PR_LOG" | sed -n 1p)" "green CI merges with the pinned head and the user method"
assert_eq "https://github.com/acme/am/pull/22|$AM_HARVEST_OK|default" "$(sort "$AM_PR_LOG" | sed -n 2p)" "without any method setting the host default is used"
assert_eq "2" "$(wc -l <"$AM_PR_LOG" | tr -d ' ')" "both queued PRs are merged"
assert_eq "auto_merged" "$(am_runs 'last | .event')" "the merge is recorded"
assert_eq "0" "$(am_pending)" "merged entries leave the queue"
AM_NOTICE="$(am notify | jq -r '.systemMessage')"
assert_contains "$AM_NOTICE" "2건 병합" "SessionStart reports auto merges"
assert_contains "$AM_NOTICE" "auto_merge 허용 스위치(sync·harvest)는 더 이상 쓰지 않습니다" "SessionStart says the repo switch is no longer used"
assert_contains "$AM_NOTICE" "남아 있는 저장소: am-svc." "the notice names the repo"
assert_eq "" "$(am notify)" "the notice is shown once"
HM_HARVEST_AUTO_MERGE=1 am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/off --head "$AM_HARVEST_OFF" --pr https://github.com/acme/am/pull/25 --since "$AM_SINCE" --review "$AM_REVIEW"
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "after the notice the old switch is not recorded again"
rm -f "$AM_DATA"/auto-merge/pending/*.json
: >"$AM_PR_LOG"
for AM_CASE in 'head|.head = "0000000000000000"|head_moved' 'short|.head = "'"${AM_SYNC_OK:0:6}"'"|head_moved' 'base|.base = "main"|pr_base_mismatch' \
  'activity|.activity = 1|human_activity' 'ci|.ci = "failure"|ci_failed' 'conflict|.mergeable = "conflicting"|conflict' 'closed|.state = "closed"|closed' \
  'old|.created = "2026-11-02T23:59:59"|pr_not_from_this_run'; do
  IFS='|' read -r AM_N AM_F AM_R <<<"$AM_CASE"
  am_sync_enqueue "https://github.com/acme/am/pull/$AM_N"
  am_state "$AM_N" "$AM_SYNC_OK" "$AM_F"
  HM_SYNC_AUTO_MERGE=1 am sweep
  assert_eq "auto_merge_skipped|$AM_R" "$(am_runs 'last | "\(.event)|\(.reason)"')" "sweep hands $AM_N to a person"
done
am_sync_enqueue https://github.com/acme/am/pull/30
am_state 30
am sweep
assert_eq "auto_merge_skipped|opted_out" "$(am_runs 'last | "\(.event)|\(.reason)"')" "turning the setting off drops queued PRs"
assert_eq "0" "$(wc -l <"$AM_PR_LOG" | tr -d ' ')" "nothing else was merged"
# 병합 결과 종료 코드: 7은 병합됨(head 다름), 8은 실패 뒤 draft 복구 실패.
for AM_CASE in '7|auto_merged|head_mismatch' '8|auto_merge_skipped|merge_failed_not_redrafted' '5|auto_merge_skipped|merge_failed'; do
  IFS='|' read -r AM_RC AM_E AM_R <<<"$AM_CASE"
  printf '%s\n' "$AM_RC" >"$AM_PR_STATE_DIR/merge-rc"
  am_sync_enqueue "https://github.com/acme/am/pull/4$AM_RC"
  am_state "4$AM_RC"
  HM_SYNC_AUTO_MERGE=1 am sweep
  assert_eq "$AM_E|$AM_R" "$(am_runs 'last | "\(.event)|\(.reason)"')" "merge exit $AM_RC is recorded as $AM_R"
done
rm -f "$AM_PR_STATE_DIR/merge-rc"
assert_contains "$(am notify | jq -r '.systemMessage')" "head_mismatch" "a merge with a different head is surfaced"
# 병합 요청 형태(dry-run).
assert_eq "github|squash|abc1234" "$(HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --merge https://github.com/acme/svc/pull/3 --head abc1234 | jq -r '"\(.provider)|\(.method)|\(.head)"')" "GitHub merge request"
assert_eq "bitbucket|merge_commit" "$(HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --merge https://bitbucket.org/ws/r/pull-requests/4 --head abc1234 --method merge | jq -r '"\(.provider)|\(.merge_strategy)"')" "Bitbucket merge request"
if "$ROOT/scripts/open-pr.sh" --merge https://github.com/acme/svc/pull/3 --head 'x; rm' >/dev/null 2>&1; then fail "merge requires a commit hash head"; fi
if HARNESS_METRICS_DIR="$AM_DATA" "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project am-svc --first-pass maybe >/dev/null 2>&1; then fail "first-pass accepts only pass|revised"; fi
# 꺼져 있을 때: 켰다면 병합됐을 sync PR이 30일에 3건 이상이면 켜는 방법을 30일에 한 번 안내한다. harvest는 권하지 않는다.
AM_DATA="$TEST_TMP/am-hint"
for AM_N in 61 62; do am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr "https://github.com/acme/am/pull/$AM_N" --since "$AM_SINCE"; done
assert_eq "" "$(am notify)" "two eligible PRs are not enough for a hint"
am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/63 --since "$AM_SINCE"
am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/develop --head "$AM_HARVEST_OK" --pr https://github.com/acme/am/pull/64 --since "$AM_SINCE" --review "$AM_REVIEW"
assert_eq "3" "$(am_runs '[.[] | select(.event == "auto_merge_eligible")] | length')" "harvest PRs are not judged in the background"
assert_eq "" "$(HM_AUTO_MERGE_HINT=0 am notify)" "the hint can be turned off"
assert_eq "" "$(HM_SYNC_AUTO_MERGE=1 am notify)" "no hint once auto merge is on"
AM_HINT="$(am notify | jq -r '.systemMessage')"
assert_contains "$AM_HINT" "3건" "the hint shows the evidence"
assert_contains "$AM_HINT" "HM_SYNC_AUTO_MERGE" "the hint names the user setting"
[[ "$AM_HINT" != *'auto_merge'* ]] || fail "the hint no longer asks for a repo setting"
assert_eq "" "$(am notify)" "the hint is shown once per 30 days"
assert_contains "$(<"$ROOT/skills/setup/SKILL.md")" "HM_SYNC_AUTO_MERGE" "setup offers the auto merge options"
# 대화형 /setup 고르기 단계가 디자인 스킬도 묻는다(#220). 설치는 기존 design install 경로를 쓴다.
SETUP_PICK="$(awk '/^## 2\. 고르기/{f=1;next} /^## 4\./{f=0} f' "$ROOT/skills/setup/SKILL.md")"
assert_contains "$SETUP_PICK" "**디자인 스킬**" "interactive setup asks about design skills"
assert_contains "$SETUP_PICK" "\`core\` (권장)" "design question recommends core"
assert_contains "$SETUP_PICK" "review.runs\`·\`review.network" "extra choices show what runs and what network is used"
assert_contains "$SETUP_PICK" "건너뛰기" "design question can be skipped"
assert_contains "$SETUP_PICK" "도구별로 판단해 알린다" "design question handles tools with different states"
assert_contains "$(awk '/^## 1\. 현재 상태/{f=1;next} /^## 2\./{f=0} f' "$ROOT/skills/setup/SKILL.md")" "직접 둔 사본(\`foreign\`)" "design status summary names user-placed copies"
assert_contains "$SETUP_PICK" "\`current\`거나 \`foreign\`" "design question treats a user-placed skill as already present"
assert_contains "$SETUP_PICK" "setup.sh design install --tool" "design choice reuses design install"
assert_contains "$(sed -n '8p' "$ROOT/skills/setup/SKILL.md")" "디자인 스킬 상태 요약" "setup status includes design skill status"
assert_contains "$(awk '/^description:/{print; exit}' "$ROOT/skills/setup/SKILL.md")" "대화형 셋업에서 함께 묻는다" "setup description says interactive setup asks about design"
# CI가 없는 저장소: 기본은 기다리다 사람에게, require_ci:false면 병합. 실패한 CI는 어느 설정에서도 막는다.
AM_DATA="$TEST_TMP/am-noci"
: >"$AM_PR_LOG"
am_base_with noci '.auto_merge.require_ci = false'
am_on noci s-noci
mkdir -p "$AM_REPO/.ai-harness/workflows"
cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
AM_NOCI="$(am_commit noci)"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/71 --since "$AM_SINCE"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/noci --head "$AM_NOCI" --pr https://github.com/acme/am/pull/72 --since "$AM_SINCE"
am_state 71 "$AM_SYNC_OK" '.ci = "none"'
am_state 72 "$AM_NOCI" '.ci = "none" | .base = "noci"'
HM_SYNC_AUTO_MERGE=1 am sweep
assert_eq "https://github.com/acme/am/pull/72" "$(cut -d'|' -f1 "$AM_PR_LOG")" "only the repo that does not require CI merges without CI"
assert_eq "1" "$(am_pending)" "the repo that requires CI keeps waiting"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/noci --head "$AM_NOCI" --pr https://github.com/acme/am/pull/73 --since "$AM_SINCE"
am_state 73 "$AM_NOCI" '.ci = "failure" | .base = "noci"'
HM_SYNC_AUTO_MERGE=1 am sweep
assert_eq "auto_merge_skipped|ci_failed" "$(am_runs '[.[] | select(.artifact == "https://github.com/acme/am/pull/73")] | last | "\(.event)|\(.reason)"')" "failed CI blocks even without require_ci"
# require_ci도 사용자 설정으로 끌 수 있지만, 기준 브랜치가 require_ci:true면 그쪽이 이긴다. 실패한 CI는 여전히 막는다.
rm -f "$AM_DATA"/auto-merge/pending/*.json && : >"$AM_PR_LOG"
am_base_with ci-on '.auto_merge.require_ci = true'
am_on ci-on s-cion
mkdir -p "$AM_REPO/.ai-harness/workflows"
cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
AM_CION="$(am_commit cion)"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/74 --since "$AM_SINCE"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/ci-on --head "$AM_CION" --pr https://github.com/acme/am/pull/75 --since "$AM_SINCE"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/76 --since "$AM_SINCE"
am_state 74 "$AM_SYNC_OK" '.ci = "none"'
am_state 75 "$AM_CION" '.ci = "none" | .base = "ci-on"'
am_state 76 "$AM_SYNC_OK" '.ci = "failure"'
HM_SYNC_AUTO_MERGE=1 HM_AUTO_MERGE_REQUIRE_CI=0 am sweep
assert_eq "https://github.com/acme/am/pull/74" "$(cut -d'|' -f1 "$AM_PR_LOG")" "the user setting merges a repo without CI and without a repo value"
assert_eq "1" "$(am_pending)" "a repo that requires CI keeps waiting despite the user setting"
assert_eq "auto_merge_skipped|ci_failed" "$(am_runs '[.[] | select(.artifact == "https://github.com/acme/am/pull/76")] | last | "\(.event)|\(.reason)"')" "failed CI blocks with the user setting too"
pass "opt-in auto merge of verified unattended PRs"

# 실행이 끝나면 다음 sync 후보를 이어서 띄운다(동시 실행은 1개). sweep 주기(6시간)마다 1건씩이 아니다.
CHAIN_DATA="$TEST_TMP/chain-data"
mkdir -p "$CHAIN_DATA/events" "$TEST_TMP/chain-claude" "$TEST_TMP/chain-codex"
for CHAIN_N in 1 2 3; do
  make_repo "$TEST_TMP/chain-$CHAIN_N"
  mkdir -p "$TEST_TMP/chain-$CHAIN_N/.ai-harness"
  jq -n --arg p "chain-$CHAIN_N" '{project_id:$p,harness_version:"0.1.0",level:"standard",integrations:["claude"]}' \
    >"$TEST_TMP/chain-$CHAIN_N/.ai-harness/harness.json"
  git -C "$TEST_TMP/chain-$CHAIN_N" add .ai-harness && git -C "$TEST_TMP/chain-$CHAIN_N" commit -q -m harness
  jq -cn --arg a "$TEST_TMP/chain-$CHAIN_N" '{kind:"session",cwd:$a}' >>"$CHAIN_DATA/events/chain.jsonl"
done
chain_sweep() {
  HARNESS_METRICS_DIR="$CHAIN_DATA" HM_SYNC_AUTO=1 HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="${CHAIN_CMD:-$SYNC_STUB}" HM_HARVEST_AUTO_AGENT=claude \
    HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" \
    HM_HARVEST_GLOBAL_DAYS=0 SYNC_STUB_OUT="$TEST_TMP/chain-stub.out" "$ROOT/scripts/harvest-auto.sh" sweep
}
HM_SYNC_AUTO_DAILY_MAX=2 chain_sweep
assert_eq "2" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "one sweep chains sync runs up to the daily cap"
assert_eq "daily_max" "$(jq -sr 'last | .reason' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "the chain stops at the daily cap"
chain_sweep
assert_eq "3" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "default daily cap leaves room for the rest"
assert_contains "$(<"$ROOT/README.md")" "HM_SYNC_AUTO_DAILY_MAX=6" "README documents the new default cap"
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" 'HM_SYNC_AUTO_DAILY_MAX:-6}' "code default cap is 6"
# 사용량 한도로 끝난 실행 뒤에는 잇지 않는다.
CHAIN_LIMIT="$TEST_TMP/chain-limit.sh"
# shellcheck disable=SC2016  # 스텁 본문의 $1은 스텁이 실행될 때 펼쳐진다
printf '#!/usr/bin/env bash\necho "$1" >>"%s"\necho %s\nexit 1\n' "$TEST_TMP/chain-limit.out" \
  "'{\"type\":\"result\",\"is_error\":true,\"api_error_status\":429,\"api_error\":\"usage_limit_reached\"}'" >"$CHAIN_LIMIT"
chmod +x "$CHAIN_LIMIT"
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
HARNESS_METRICS_DIR="$CHAIN_DATA" HM_SYNC_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=99 HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$CHAIN_LIMIT" \
  HM_HARVEST_AUTO_AGENT=claude HM_HARVEST_GLOBAL_DAYS=0 HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" \
  HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" "$ROOT/scripts/harvest-auto.sh" sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/chain-limit.out" | tr -d ' ')" "a usage-limited run does not chain the next one"
# 로그인 만료(#315): 인증 실패 결과 줄은 auth_expired로 분류하고, 실패 횟수에 넣지 않으며, 같은 sweep의 다음 실행을 잇지 않는다.
# 사람이 다시 로그인하기 전까지 반드시 실패하므로 MAX_FAILS 기회를 쓰지 않고, 남은 저장소를 같은 이유로 띄우지 않는다.
CHAIN_AUTH="$TEST_TMP/chain-auth.sh"
CHAIN_AUTH_LINE='{"type":"result","is_error":true,"terminal_reason":"api_error","result":"Failed to authenticate: this login reached its time limit and cannot be renewed. Run claude auth login, or use claude setup-token and set CLAUDE_CODE_OAUTH_TOKEN for unattended jobs"}'
# shellcheck disable=SC2016  # 스텁 본문의 $1은 스텁이 실행될 때 펼쳐진다
printf '#!/usr/bin/env bash\necho "$1" >>"%s"\necho %s\nexit 1\n' "$TEST_TMP/chain-auth.out" "'$CHAIN_AUTH_LINE'" >"$CHAIN_AUTH"
chmod +x "$CHAIN_AUTH"
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
chain_auth_notify() { HARNESS_METRICS_DIR="$CHAIN_DATA" "$ROOT/scripts/harvest-auto.sh" notify; }
CHAIN_CMD="$CHAIN_AUTH" HM_LLM_BACKOFF_HOURS=0 HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/chain-auth.out" | tr -d ' ')" "an expired login stops the sweep after the first run"
assert_eq "failed|auth_expired" "$(jq -sr '[.[] | select(.event=="finished")] | last | "\(.result)|\(.reason)"' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "an expired login is recorded as auth_expired"
CHAIN_AUTH_P="$(sed -n 1p "$TEST_TMP/chain-auth.out")"
assert_eq "failed|0" "$(jq -r '"\(.result)|\(.fails)"' "$CHAIN_DATA/sync-auto/p-$CHAIN_AUTH_P.json")" "an expired login does not count as a failure"
assert_eq "auth_expired" "$(jq -r '.components.sync_auto.last_error' "$CHAIN_DATA/health.json")" "health names the expired login"
for _ in 1 2 3; do CHAIN_CMD="$CHAIN_AUTH" HM_LLM_BACKOFF_HOURS=0 HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep; done
assert_eq "4|$CHAIN_AUTH_P|0" "$(wc -l <"$TEST_TMP/chain-auth.out" | tr -d ' ')|$(sort -u "$TEST_TMP/chain-auth.out")|$(jq -r '.fails' "$CHAIN_DATA/sync-auto/p-$CHAIN_AUTH_P.json")" "repeated expired logins never use up the retries"
CHAIN_AUTH_MSG="$(chain_auth_notify | jq -r '.systemMessage')"
assert_contains "$CHAIN_AUTH_MSG" "claude auth login" "session start says the login expired"
assert_contains "$CHAIN_AUTH_MSG" "claude setup-token" "and names the token for unattended runs"
assert_eq "" "$(chain_auth_notify)" "the notice is shown once per failure"
CHAIN_CMD="$CHAIN_AUTH" HM_LLM_BACKOFF_HOURS=0 HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
# 에이전트를 띄우지 않고 끝난 sync는 로그인이 풀렸다는 근거가 아니다.
jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at:$at,event:"finished",project:"chain-x",scope:"sync",result:"no-change",exit_code:0,no_agent:true}' >>"$CHAIN_DATA/harvest-auto/runs.jsonl"
assert_contains "$(chain_auth_notify | jq -r '.systemMessage')" "claude auth login" "a newer expired login is told again, even after a run that launched no agent"
assert_contains "$(<"$ROOT/scripts/session-start.sh")" 'harvest-auto.sh" notify' "session start asks for the expired-login notice"
# 과거 버전은 인증 실패를 agent_error로 세어 fails:3으로 포기했다. 로그가 인증 실패인 지난 실패는 횟수에서 빼 다시 후보가 된다.
# 로그가 인증 실패가 아닌 지난 실패는 그대로 센다.
CHAIN_PLUGIN="$(jq -r '.plugin' "$CHAIN_DATA/sync-auto/p-$CHAIN_AUTH_P.json")"
CHAIN_BATCH="$(printf '%s' "sync-$CHAIN_PLUGIN" | { shasum 2>/dev/null || sha1sum; } | cut -c1-12)"
printf '%s\n' "$CHAIN_AUTH_LINE" >"$TEST_TMP/chain-legacy-auth.log"
printf '%s\n' '{"type":"result","is_error":true,"result":"tool failed"}' >"$TEST_TMP/chain-legacy-other.log"
for CHAIN_N in 1 2 3; do
  jq -cn --arg p "$CHAIN_PLUGIN" '{plugin:$p,at:"2026-01-01T00:00:00Z",result:"failed",fails:3}' >"$CHAIN_DATA/sync-auto/p-chain-$CHAIN_N.json"
done
jq -cn --arg p "$CHAIN_PLUGIN" '{plugin:$p,at:"2026-01-01T00:00:00Z",result:"improved",fails:0}' >"$CHAIN_DATA/sync-auto/p-chain-1.json"
for _ in 1 2 3; do
  jq -cn --arg b "$CHAIN_BATCH" --arg l "$TEST_TMP/chain-legacy-auth.log" \
    '{at:"2026-01-01T00:00:00Z",event:"finished",project:"chain-2",batch:$b,scope:"sync",result:"failed",exit_code:1,reason:"agent_error",log:$l}' >>"$CHAIN_DATA/harvest-auto/runs.jsonl"
  jq -cn --arg b "$CHAIN_BATCH" --arg l "$TEST_TMP/chain-legacy-other.log" \
    '{at:"2026-01-01T00:00:00Z",event:"finished",project:"chain-3",batch:$b,scope:"sync",result:"failed",exit_code:1,reason:"agent_error",log:$l}' >>"$CHAIN_DATA/harvest-auto/runs.jsonl"
done
: >"$TEST_TMP/chain-stub.out"
HM_LLM_BACKOFF_HOURS=0 HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "chain-2" "$(cut -d'|' -f1 "$TEST_TMP/chain-stub.out" | sort -u | tr '\n' ' ' | sed 's/ $//')" "a target given up only for expired logins is tried again, others stay given up"
assert_eq "" "$(chain_auth_notify)" "a run that worked after the expired login clears the notice"
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
pass "an expired login is classified, not counted, stops the sweep and is told once"

# 사용자가 다시 작업 중이면 잇지 않는다 — 다음 sweep(유휴 대기 포함)이 이어받는다.
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
: >"$TEST_TMP/chain-stub.out"
mkdir -p "$TEST_TMP/chain-claude/-Users-me-work" && : >"$TEST_TMP/chain-claude/-Users-me-work/live.jsonl"
HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "chain stops while the user is active"
find "$TEST_TMP/chain-claude/-Users-me-work" -depth -delete
# 결과 줄이 알려진 값이 아니면 left_for_user로 기록한다(실패 횟수 없는 failed로 무한 재시도하지 않게).
CHAIN_ODD="$TEST_TMP/chain-odd.sh"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"type\":\"result\",\"result\":\"AI_HARNESS_SYNC_RESULT outcome=failed\"}'" >"$CHAIN_ODD"
chmod +x "$CHAIN_ODD"
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
CHAIN_CMD="$CHAIN_ODD" HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "left_for_user" "$(jq -r '.result' "$CHAIN_DATA/sync-auto/p-chain-1.json")" "unknown outcome is left for the user"
# 마커를 쓸 수 없으면 띄우지 않는다 — 같은 저장소를 끝없이 다시 띄우지 않게.
find "$CHAIN_DATA/sync-auto" -depth -delete && : >"$CHAIN_DATA/sync-auto"
: >"$TEST_TMP/chain-stub.out"
HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "0" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "unwritable marker launches nothing"
find "$CHAIN_DATA/sync-auto" -delete
# 깨진 실행 기록 한 줄이 오늘 집계를 0으로 만들어 상한을 풀지 않는다(오늘 started 1건 + 깨진 줄, 상한 1).
rm -rf "$CHAIN_DATA/sync-auto" "$CHAIN_DATA/harvest-auto/runs.jsonl"
mkdir -p "$CHAIN_DATA/harvest-auto"
jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at:$at,event:"started",project:"x",scope:"sync"}' >"$CHAIN_DATA/harvest-auto/runs.jsonl"
printf '{broken\n' >>"$CHAIN_DATA/harvest-auto/runs.jsonl"
HM_SYNC_AUTO_DAILY_MAX=1 chain_sweep
assert_eq "0|daily_max" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')|$(jq -Rrn '[inputs | fromjson?] | last | .reason' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "a broken run-log line does not reset the daily cap"
HM_SYNC_AUTO_DAILY_MAX=2 chain_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "a broken run-log line does not block launches under the cap"
# 실행 기록을 읽을 수 없으면 상한을 닫고 사유를 구분해 남긴다.
if [[ "$(id -u)" == 0 ]]; then
  printf '# skip: unreadable run-log test needs a non-root user\n'
else
  chmod 000 "$CHAIN_DATA/harvest-auto/runs.jsonl"
  HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
  chmod 600 "$CHAIN_DATA/harvest-auto/runs.jsonl"
  assert_eq "1|runs_unreadable" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')|$(jq -r '.components.sync_auto.last_error' "$CHAIN_DATA/health.json")" "unreadable run log closes the cap with its own reason"
fi
# 연쇄는 sweep과 같은 순서를 따른다 — sync 도중 생긴 harvest batch가 남은 sync보다 먼저 돈다.
rm -rf "$CHAIN_DATA/sync-auto" "$CHAIN_DATA/harvest-auto" "$CHAIN_DATA/harvest-queue"
mkdir -p "$CHAIN_DATA/harvest-queue/p-chain-2"
CHAIN_PRIO="$TEST_TMP/chain-prio.sh"
cat >"$CHAIN_PRIO" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$CHAIN_PRIO_OUT"
# 첫 실행 중에 chain-2의 harvest batch가 생긴다.
if [[ ! -f "$HARNESS_METRICS_DIR/harvest-queue/p-chain-2/analysis-batch.json" ]]; then
  jq -cn --arg ev "$CHAIN_PRIO_EV" '{project:"chain-2",batch_id:"b-prio",created_at:"2026-01-01T00:00:00Z",reasons:["errors"],event_files:[$ev]}' \
    >"$HARNESS_METRICS_DIR/harvest-queue/p-chain-2/analysis-batch.json"
fi
echo '{"type":"result","result":"AI_HARNESS_SYNC_RESULT outcome=no-change"}'
STUB
chmod +x "$CHAIN_PRIO"
jq -cn --arg cwd "$TEST_TMP/chain-2" '{kind:"session",src:"claude",sid:"prio",project:"chain-2",cwd:$cwd}' >"$CHAIN_DATA/events/prio.jsonl"
HARNESS_METRICS_DIR="$CHAIN_DATA" HM_SYNC_AUTO=1 HM_HARVEST_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=2 HM_HARVEST_AUTO_DAILY_MAX=9 \
  HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$CHAIN_PRIO" HM_HARVEST_AUTO_AGENT=claude HM_HARVEST_GLOBAL_DAYS=0 \
  HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" \
  CHAIN_PRIO_OUT="$TEST_TMP/chain-prio.out" CHAIN_PRIO_EV="$CHAIN_DATA/events/prio.jsonl" "$ROOT/scripts/harvest-auto.sh" sweep
assert_eq "sync,project,sync" "$(jq -sr '[.[] | select(.event=="started") | .scope] | join(",")' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "a harvest batch that appears mid-chain runs before the remaining syncs"
# 전역 분석은 정기 sweep에서만 주기(기본 7일)당 한 번 돈다 — 연쇄가 끼워 넣지 않는다.
rm -rf "$CHAIN_DATA/sync-auto" "$CHAIN_DATA/harvest-auto" "$CHAIN_DATA/harvest-queue"
chain_global() {
  HARNESS_METRICS_DIR="$CHAIN_DATA" HM_SYNC_AUTO=1 HM_HARVEST_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=9 HM_HARVEST_AUTO_DAILY_MAX=9 \
    HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$SYNC_STUB" HM_HARVEST_AUTO_AGENT=claude \
    HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" \
    SYNC_STUB_OUT="$TEST_TMP/chain-global.out" "$ROOT/scripts/harvest-auto.sh" sweep
}
chain_global
rm -rf "$CHAIN_DATA/sync-auto"
chain_global
assert_eq "1" "$(jq -sr '[.[] | select(.event=="started" and .project=="_global")] | length' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "a chain does not add global runs beyond the periodic sweep"
# 무인 실행은 transcript를 남기지 않는다 — 사용자 활동 판정과 수집에 섞이지 않게.
# shellcheck disable=SC2016  # 스크립트 원문의 literal 변수 참조를 검사
assert_eq "2" "$(grep -c -- '--plugin-dir "$plugin_root" --no-session-persistence' "$ROOT/scripts/harvest-auto.sh")" "unattended claude runs keep no transcript"
# 무인 실행이 도는 동안 정기 실행은 LLM 단계를 건너뛴다.
assert_contains "$(<"$ROOT/scripts/backfill-due.sh")" "run_in_flight && { SKIP_REASON=run_in_flight; return 1; }" "scheduled LLM steps skip while an unattended run is in flight"
pass "auto sync chains runs within the daily cap"

# 백그라운드 Bash 감시자 hook: 명령을 바꾸지 않고(권한 판정이 그대로) 아무것도 출력하지 않는다. 등록·끄기·오류 통과.
BG_HOOK="$(jq -c '.hooks.PreToolUse[] | select(.matcher == "Bash" and (.hooks[0].command | contains("background-watchdog")))' "$ROOT/hooks/hooks.json")"
assert_eq "$LITERAL_PLUGIN_ROOT/scripts/background-watchdog-hook.sh\"" "$(jq -r '.hooks[0].command' <<<"$BG_HOOK")" "Bash PreToolUse registers the background watchdog"
assert_eq "3" "$(jq -r '.hooks[0].timeout' <<<"$BG_HOOK")" "background watchdog hook stays inside a short budget"
bg_hook() { "$ROOT/scripts/background-watchdog-hook.sh"; printf '|%s' "$?"; }
assert_eq "|0" "$(jq -cn '{tool_input:{command:"echo bg",run_in_background:true}}' | bg_hook)" "background input gets no hook output (command and permissions untouched)"
assert_eq "|0" "$(jq -cn '{tool_input:{command:"echo fg",run_in_background:false}}' | bg_hook)" "foreground input passes through"
assert_eq "|0" "$(printf '%s\n' '{broken' | bg_hook)" "malformed input fails open silently"
assert_eq "|0" "$(jq -cn '{tool_input:{command:["a"],run_in_background:true}}' | bg_hook)" "non-string command fails open silently"
pass "background command watchdog hook"

# 감시자는 실제 프로세스 그룹에서: 가짜 에이전트가 hook을 부르고, Claude Code처럼 명령을 eval '…'로 넣은 셸을 새 그룹 리더로 띄운다.
# 띄우는 프로세스는 인자에 $TEST_TMP를 넣어 실패해도 cleanup이 끈다.
BG_LOOP='while :; do sleep 1; done'
cat >"$TEST_TMP/bg-agent.sh" <<'EOF'
#!/bin/bash
# bg-agent.sh <hook에 줄 명령> <실제로 띄울 명령> <출력 접두어> — BG_HOOK_CMD(hooks.json의 hook 명령)를 sh -c로 부른 뒤
# Claude Code처럼 eval '…' 뒤에 명령이 더 이어지는(그래서 exec되지 않는) 셸을 자식 그룹 리더로 띄우고 산다.
# hook 명령은 env로 받는다 — 이 프로세스(가짜 에이전트)의 인자에 hook 경로가 없어야 한다.
jq -cn --arg c "$1" --arg id "${BG_TOOL_USE_ID:-}" '{tool_input:{command:$c,run_in_background:true}} + (if $id == "" then {} else {tool_use_id:$id} end)' | /bin/sh -c "$BG_HOOK_CMD" >"$3.hook"
q="'"
esc="${2//$q/$q\"$q\"$q}"
perl -e 'setpgrp(0, 0); exec @ARGV' bash -c "eval '$esc' </dev/null && :" "$3.shell" >"$3.out" 2>"$3.err" &
echo $! >"$3.pid"
wait $!
echo $? >"$3.status"
while :; do sleep 1; done
EOF
bg_start() { # 이름 hook명령 [실행명령] → BG_AGENT, BG_GROUP
  rm -f "$TEST_TMP/$1".*
  BG_HOOK_CMD="$(jq -r '.hooks[0].command' <<<"$BG_HOOK")${BG_HOOK_SUFFIX:-}" CLAUDE_PLUGIN_ROOT="$ROOT" \
    bash "$TEST_TMP/bg-agent.sh" "$2" "${3:-$2}" "$TEST_TMP/$1" &
  BG_AGENT=$!
  for _ in $(seq 1 50); do [[ -s "$TEST_TMP/$1.pid" ]] && break; sleep 0.1; done
  BG_GROUP="$(<"$TEST_TMP/$1.pid")"
}
bg_watching() { pgrep -f "background-watchdog.sh $BG_AGENT " >/dev/null && echo true || echo false; }
bg_claimed() { [[ -d "$HARNESS_METRICS_DIR/bg-watchdog/$BG_GROUP" ]] && echo true || echo false; }
# shellcheck disable=SC2009  # ppid·pgid까지 보여야 해서 pgrep으로 대신할 수 없다
bg_procs() { ps -A -o pid=,ppid=,pgid=,args= | grep -F -e "$TEST_TMP" -e background-watchdog | grep -v grep | cut -c1-200; }
bg_group_gone() { # pgid 초 → 그 시간 안에 그룹이 비면 0
  local i
  for i in $(seq 1 $(($2 * 10))); do kill -0 -- "-$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}
bg_stop_agent() { kill -KILL "$BG_AGENT" 2>/dev/null; wait "$BG_AGENT" 2>/dev/null || true; }

# 에이전트가 강제로 끝나면 그룹 전체(ppid 1로 떨어진 손자 포함)를 끈다. hook 출력은 없다.
bg_start bg-kill "( bash -c '$BG_LOOP' '$TEST_TMP/bg-orphan' & ); bash -c '$BG_LOOP' '$TEST_TMP/bg-main'"
sleep 2
assert_eq "" "$(<"$TEST_TMP/bg-kill.hook")" "hook prints nothing for a background command"
assert_eq "true" "$(kill -0 -- "-$BG_GROUP" 2>/dev/null && echo true || echo false)" "background server keeps running while the agent lives"
[[ "$(bg_claimed)" == true ]] || fail "watchdog found and claimed the background command's group (hook run through /bin/sh like hooks.json): agent=$BG_AGENT group=$BG_GROUP
$(bg_procs)"
bg_stop_agent
bg_group_gone "$BG_GROUP" 8 || fail "process group (with an orphaned grandchild) survives after the agent is gone"

# hook을 감싼 sh가 마지막 명령을 exec하지 않아도(일부 dash) hook의 부모가 아니라 그 위 에이전트를 감시한다.
BG_HOOK_SUFFIX='; :' bg_start bg-wrap "bash -c '$BG_LOOP' '$TEST_TMP/bg-wrap'"
sleep 2
[[ "$(bg_claimed)" == true ]] || fail "watchdog watches the agent even when sh does not exec the hook: agent=$BG_AGENT group=$BG_GROUP
$(bg_procs)"
bg_stop_agent
bg_group_gone "$BG_GROUP" 8 || fail "group survives the agent when sh did not exec the hook"

# 명령이 먼저 끝나면 감시자도 바로 끝나고, 명령의 출력·종료 코드는 그대로다(작은따옴표가 든 명령도 찾는다).
bg_start bg-done "sleep 3; printf '%s' \"it's done\"; printf err >&2; exit 7"
sleep 1
assert_eq "true" "$(bg_claimed)" "watchdog found a command that contains single quotes"
for _ in $(seq 1 80); do [[ -s "$TEST_TMP/bg-done.status" ]] && break; sleep 0.1; done
assert_eq "it's done|err|7" "$(<"$TEST_TMP/bg-done.out")|$(<"$TEST_TMP/bg-done.err")|$(<"$TEST_TMP/bg-done.status")" "command output and exit status are unchanged"
BG_LEFT=true
for _ in $(seq 1 30); do [[ "$(bg_watching)" == false ]] && { BG_LEFT=false; break; }; sleep 0.1; done
assert_eq "false" "$BG_LEFT" "watchdog exits as soon as the command group is empty"
assert_eq "false" "$(bg_claimed)" "watchdog releases its claim when it ends"
bg_stop_agent

# 리더 셸이 먼저 끝나도(일부 pid만 꺼진 경우) 그룹에 남은 프로세스가 있으면 감시를 이어 간다.
bg_start bg-left "bash -c '$BG_LOOP' '$TEST_TMP/bg-left' & sleep 2; exit 0"
for _ in $(seq 1 50); do [[ -s "$TEST_TMP/bg-left.status" ]] && break; sleep 0.1; done
sleep 2
assert_eq "true" "$(bg_watching)" "watchdog keeps watching members left after the leader shell exits"
bg_stop_agent
bg_group_gone "$BG_GROUP" 8 || fail "group members left by an exited leader shell survive the agent"

# hook이 본 명령과 다른 그룹은 건드리지 않는다(못 찾으면 아무것도 하지 않는다).
bg_start bg-other "echo not-this-one" "bash -c '$BG_LOOP' '$TEST_TMP/bg-other'"
sleep 1
bg_stop_agent
sleep 4
assert_eq "true" "$(kill -0 -- "-$BG_GROUP" 2>/dev/null && echo true || echo false)" "watchdog leaves a group it did not match"
kill -KILL -- "-$BG_GROUP" 2>/dev/null || true

# 너무 짧은 첫 줄(cd x 등)은 다른 명령과 헷갈리므로 감시하지 않는다.
bg_start bg-short "cd /
bash -c '$BG_LOOP' '$TEST_TMP/bg-short'"
sleep 1
assert_eq "false" "$(bg_watching)" "a too-short first line starts no watch"
bg_stop_agent
kill -KILL -- "-$BG_GROUP" 2>/dev/null || true

# 끄면 감시자를 띄우지 않는다.
HM_BACKGROUND_WATCHDOG=0 bg_start bg-off "bash -c '$BG_LOOP' '$TEST_TMP/bg-off'"
sleep 1
assert_eq "false" "$(bg_watching)" "HM_BACKGROUND_WATCHDOG=0 starts no watchdog"
bg_stop_agent
kill -KILL -- "-$BG_GROUP" 2>/dev/null || true

# 에이전트를 처음부터 볼 수 없으면 바로 물러난다.
BG_GONE="$(bash -c 'echo $$' "$TEST_TMP/bg-gone")"
BG_START=$SECONDS
"$ROOT/scripts/background-watchdog.sh" "$BG_GONE" " " "sleep 100" "$TEST_TMP/bg-claims"
assert_eq "0" "$((SECONDS - BG_START > 1))" "watchdog exits at once when the agent is already gone"
pass "background watchdog cleans the process group"

# 무거운 명령 슬롯(#436): 병렬 세션의 빌드·dev 서버·전체 테스트를 메모리 기준 동시 수로 줄 세운다.
# hook은 이 테스트 셸에서 직접(명령 치환 없이) 불러 부모 pid(=에이전트)가 살아 있게 한다.
HS="$ROOT/scripts/heavy-slot-hook.sh"
HS_DIR="$HARNESS_METRICS_DIR/heavy-slots"
HS_REG_PRE="$(jq -c '.hooks.PreToolUse[] | select(.matcher == "Bash" and (.hooks[0].command | contains("heavy-slot")))' "$ROOT/hooks/hooks.json")"
assert_eq "$LITERAL_PLUGIN_ROOT/scripts/heavy-slot-hook.sh\" pre" "$(jq -r '.hooks[0].command' <<<"$HS_REG_PRE")" "Bash PreToolUse registers the heavy slot hook"
assert_eq "600" "$(jq -r '.hooks[0].timeout' <<<"$HS_REG_PRE")" "the heavy slot hook may wait up to its timeout"
assert_eq "$LITERAL_PLUGIN_ROOT/scripts/heavy-slot-hook.sh\" post" "$(jq -r '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[0].command | select(contains("heavy-slot"))' "$ROOT/hooks/hooks.json")" "Bash PostToolUse releases heavy slots"
# 실패한 명령은 PostToolUse 대신 PostToolUseFailure가 온다(실측).
assert_eq "$LITERAL_PLUGIN_ROOT/scripts/heavy-slot-hook.sh\" post" "$(jq -r '.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[0].command | select(contains("heavy-slot"))' "$ROOT/hooks/hooks.json")" "Bash PostToolUseFailure releases heavy slots of failed commands"
hs_in() { # tool_use_id 명령 [bg] [transcript]
  jq -cn --arg id "$1" --arg c "$2" --argjson bg "${3:-false}" --arg t "${4:-}" \
    '{tool_name:"Bash", tool_use_id:$id, transcript_path:$t, tool_input:{command:$c, run_in_background:$bg}}'
}
hs_call() { # 모드 입력 → $TEST_TMP/hs.out, $TEST_TMP/hs.rc
  printf '%s' "$2" | "$HS" "$1" >"$TEST_TMP/hs.out" 2>"$TEST_TMP/hs.err"
  echo $? >"$TEST_TMP/hs.rc"
}
hs_slots() { find "$HS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | sed 's#.*/##; s#\.json$##' | sort | paste -sd' ' -; }

# 판정: 패키지 매니저 build·dev·start·test:ci, 프레임워크 CLI, 빌드 도구, compose up. 앞의 cd·env·nohup은 건너뛴다.
for c in "yarn web build" "cd apps/web && npm run dev" "nohup yarn dev -p 3100 > log 2>&1 &" "VAR_ENV=st yarn start -p 3999" \
  "(cd apps/web && pnpm build)" "yarn web test:ci" "npx next build" "./gradlew clean build" "docker compose up -d" "yarn workspace web dev"; do
  "$HS" match "$c" || fail "heavy command not matched: $c"
done
for c in "pnpm --filter web build" "pnpm -r build" "yarn workspace web run build" "yarn run build" "sudo docker compose up -d" "timeout 300 yarn build"; do
  "$HS" match "$c" || fail "heavy command not matched: $c"
done
for c in "ls -la" "grep -rn build src" "echo yarn build" "yarn web test src/a.spec.ts" "git status" "cat package.json" "yarn add build" "yarn remove dev" "echo 'a && yarn build'"; do
  ! "$HS" match "$c" || fail "light command matched as heavy: $c"
done
HM_HEAVY_PATTERNS='^make( |$)' "$HS" match "make all" || fail "HM_HEAVY_PATTERNS replaces the default patterns"
! HM_HEAVY_PATTERNS='^make( |$)' "$HS" match "yarn build" || fail "HM_HEAVY_PATTERNS replaces, not extends, the defaults"

# 기본은 꺼짐: 아무것도 쓰지 않고 출력도 없다.
hs_call pre "$(hs_in t-off "yarn build")"
assert_eq "0||" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "without HM_HEAVY_SLOTS the hook does nothing"

export HM_HEAVY_SLOTS=1 HM_HEAVY_MEM_FREE_PCT=80 HM_HEAVY_WAIT=0
# 가벼운 명령은 슬롯을 쓰지 않는다.
hs_call pre "$(hs_in t-light "git status")"
assert_eq "0||" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "light commands pass without a slot"
# 슬롯을 얻으면 출력 없이 통과하고, 다 찼으면 기다리다(여기서는 0초) 이유를 담아 거절한다.
hs_call pre "$(hs_in t1 "yarn web build")"
assert_eq "0||t1" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "a free slot is taken silently"
hs_call pre "$(hs_in t2 "npm run dev")"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")" "a full slot set denies the command"
HS_REASON="$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TEST_TMP/hs.out")"
assert_contains "$HS_REASON" "[Heavy slot] " "the denial starts with a bracketed hook prefix like the other guards"
assert_contains "$HS_REASON" "yarn web build" "the denial names the command holding the slot"
assert_contains "$HS_REASON" "같은 명령을 그대로 다시 실행하세요" "the denial tells the model a plain retry waits again (measured: models retry as is)"
assert_contains "$HS_REASON" "bash -c·스크립트로 감싸거나" "the denial forbids wrapping the command to dodge the wait"
assert_contains "$HS_REASON" "세 번 연속 거절되면" "the denial bounds retries before asking the user"
assert_eq "t1" "$(hs_slots)" "a denied command takes no slot"
# 같은 tool_use_id로 다시 오면 이미 쥔 슬롯이다.
hs_call pre "$(hs_in t1 "yarn web build")"
assert_eq "0|" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")" "a retried call keeps its own slot"
# PostToolUse(포그라운드)가 반환하면 다음 명령이 얻는다.
hs_call post "$(hs_in t1 "yarn web build")"
assert_eq "" "$(hs_slots)" "PostToolUse releases a foreground slot"
hs_call pre "$(hs_in tf "yarn web build")"
hs_call post "$(jq -cn '{tool_name:"Bash", tool_use_id:"tf", hook_event_name:"PostToolUseFailure", is_interrupt:false, error:"exit 1", tool_input:{command:"yarn web build"}}')"
assert_eq "" "$(hs_slots)" "PostToolUseFailure input releases the slot of a failed command"
hs_call pre "$(hs_in t2 "npm run dev")"
assert_eq "t2" "$(hs_slots)" "the next heavy command gets the released slot"

# 기다리는 동안 슬롯이 비면 얻는다.
( sleep 1; rm -f "$HS_DIR/t2.json" ) &
HS_START=$SECONDS
HM_HEAVY_WAIT=8 hs_call pre "$(hs_in t3 "yarn build")"
assert_eq "0||t3" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "a waiting command gets a slot once it frees"
assert_eq "1" "$((SECONDS - HS_START < 7))" "the wait ends as soon as a slot frees"
wait

# 회수: 주인 에이전트가 없거나, transcript에 그 호출의 결과(Esc·중단 포함)가 있으면 끝난 것이다.
HS_DEAD="$(bash -c 'echo $$')"
jq -cn --arg a "$HS_DEAD" '{tool_use_id:"t3", agent:($a|tonumber), cmd:"yarn build", bg:false, transcript:"", started:now|floor}' >"$HS_DIR/t3.json"
hs_call pre "$(hs_in t4 "yarn build")"
assert_eq "t4" "$(hs_slots)" "a slot whose agent is gone is reclaimed"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","is_error":true,"content":"interrupted"}]}}' >"$TEST_TMP/hs-transcript.jsonl"
jq --arg t "$TEST_TMP/hs-transcript.jsonl" '.transcript = $t' "$HS_DIR/t4.json" >"$TEST_TMP/hs.tmp" && mv "$TEST_TMP/hs.tmp" "$HS_DIR/t4.json"
hs_call pre "$(hs_in t5 "yarn build")"
assert_eq "t5" "$(hs_slots)" "a slot whose call already has a tool_result is reclaimed (no PostToolUse after Esc)"
rm -f "$HS_DIR"/*.json

# 메모리가 빠듯하면 상한보다 적게: 여유 15% 미만은 1, 30% 미만은 절반.
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=10 hs_call pre "$(hs_in m1 "yarn build")"
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=10 hs_call pre "$(hs_in m2 "yarn build")"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")" "under 15% free memory only one heavy command runs"
assert_contains "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TEST_TMP/hs.out")" "10%" "the denial reports the free memory"
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=25 hs_call pre "$(hs_in m2 "yarn build")"
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=25 hs_call pre "$(hs_in m3 "yarn build")"
assert_eq "deny|m1 m2" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")|$(hs_slots)" "under 30% free memory half the slots are used"
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=60 hs_call pre "$(hs_in m3 "yarn build")"
assert_eq "m1 m2 m3" "$(hs_slots)" "with enough memory the configured limit applies"
rm -f "$HS_DIR"/*.json

# 동시에 온 hook 여럿 중 상한만큼만 얻는다(lock).
# 각 hook의 부모(에이전트 역할) 서브셸은 끝까지 살아 있어야 한다 — 먼저 끝나면 그 슬롯이 회수돼 다른 hook이 얻는다.
for i in 1 2 3 4 5 6; do { HM_HEAVY_SLOTS=2 hs_call pre "$(hs_in "c$i" "yarn build")"; sleep 3; } & done
wait
assert_eq "2" "$(find "$HS_DIR" -maxdepth 1 -name 'c*.json' | wc -l | tr -d ' ')" "concurrent hooks take exactly the configured number of slots"
rm -f "$HS_DIR"/*.json
# 죽은 pid가 쥔 lock은 회수한다.
HS_DEAD_LOCK="$(bash -c 'echo $$')"
mkdir -p "$HS_DIR/.lock" && printf '%s\n' "$HS_DEAD_LOCK" >"$HS_DIR/.lock/pid"
hs_call pre "$(hs_in l1 "yarn build")"
assert_eq "l1" "$(hs_slots)" "a stale lock from a dead hook is taken over"
rm -f "$HS_DIR"/*.json

# 깨진 입력·tool_use_id 없음은 그대로 통과한다.
hs_call pre '{broken'
assert_eq "0|" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")" "malformed input fails open"
hs_call pre "$(jq -cn '{tool_name:"Bash", tool_input:{command:"yarn build"}}')"
assert_eq "0||" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "input without tool_use_id fails open"
unset HM_HEAVY_SLOTS HM_HEAVY_MEM_FREE_PCT HM_HEAVY_WAIT
pass "heavy command slots"

# 백그라운드 서버: PostToolUse는 띄운 직후 오므로 반환하지 않고, 감시자가 찾은 그룹이 사는 동안 쥔다.
mkdir -p "$TEST_TMP/hs-bin"
printf '%s\n' '#!/bin/bash' 'while :; do sleep 1; done' >"$TEST_TMP/hs-bin/yarn"
chmod +x "$TEST_TMP/hs-bin/yarn"
HS_BG_CMD="yarn dev --port 39999 $TEST_TMP/hs-bg"
export HM_HEAVY_SLOTS=1 HM_HEAVY_MEM_FREE_PCT=80 HM_HEAVY_WAIT=0
hs_call pre "$(hs_in bg1 "$HS_BG_CMD" true)"
assert_eq "bg1" "$(hs_slots)" "a background heavy command takes a slot"
PATH="$TEST_TMP/hs-bin:$PATH" BG_TOOL_USE_ID=bg1 bg_start hs-bg "$HS_BG_CMD"
for _ in $(seq 1 50); do [[ -f "$HARNESS_METRICS_DIR/bg-watchdog/$BG_GROUP/tool_use_id" ]] && break; sleep 0.1; done
assert_eq "bg1" "$(cat "$HARNESS_METRICS_DIR/bg-watchdog/$BG_GROUP/tool_use_id" 2>/dev/null)" "the watchdog records which call its group belongs to"
hs_call post "$(hs_in bg1 "$HS_BG_CMD" true)"
assert_eq "bg1" "$(hs_slots)" "PostToolUse keeps a background slot"
jq '.started -= 600' "$HS_DIR/bg1.json" >"$TEST_TMP/hs.tmp" && mv "$TEST_TMP/hs.tmp" "$HS_DIR/bg1.json"
hs_call pre "$(hs_in bg2 "yarn build")"
assert_eq "deny|bg1" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")|$(hs_slots)" "a background slot is held while its watched group lives"
kill -KILL -- "-$BG_GROUP" 2>/dev/null || true
bg_group_gone "$BG_GROUP" 5 || fail "test group did not stop"
for _ in $(seq 1 30); do [[ -d "$HARNESS_METRICS_DIR/bg-watchdog/$BG_GROUP" ]] || break; sleep 0.2; done
hs_call pre "$(hs_in bg2 "yarn build")"
[[ "$(hs_slots)" == bg2 ]] || fail "the background slot frees once its group is gone: slots=$(hs_slots) claims=$(find "$HARNESS_METRICS_DIR/bg-watchdog" 2>/dev/null | tr '\n' ' ') slot=$(cat "$HS_DIR"/*.json 2>/dev/null) out=$(cat "$TEST_TMP/hs.out")"
bg_stop_agent
rm -f "$HS_DIR"/*.json

# 감시자가 KILL로 죽어 선점 디렉토리만 남으면(그룹은 없음) 슬롯을 쥐지 않는다.
jq -cn --argjson a "$$" '{tool_use_id:"bg3", agent:$a, cmd:"yarn dev", bg:true, transcript:"", started:((now|floor) - 600)}' >"$HS_DIR/bg3.json"
HS_DEAD_GROUP="$(bash -c 'echo $$')"
mkdir -p "$HARNESS_METRICS_DIR/bg-watchdog/$HS_DEAD_GROUP" && printf bg3 >"$HARNESS_METRICS_DIR/bg-watchdog/$HS_DEAD_GROUP/tool_use_id"
hs_call pre "$(hs_in bg4 "yarn build")"
assert_eq "bg4" "$(hs_slots)" "a leftover claim whose group is gone does not hold the slot"
rm -rf "${HARNESS_METRICS_DIR:?}/bg-watchdog/$HS_DEAD_GROUP" "$HS_DIR"/*.json

# 상한을 이 세션의 백그라운드 서버만 쥐고 있으면 기다려도 풀리지 않는다 — 기다리지 않고 바로 알린다.
jq -cn --argjson a "$$" '{tool_use_id:"own1", agent:$a, cmd:"yarn dev -p 3000", bg:true, transcript:"", started:(now|floor)}' >"$HS_DIR/own1.json"
HS_START=$SECONDS
HM_HEAVY_WAIT=20 hs_call pre "$(hs_in own2 "yarn build")"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")" "a slot held only by this session's own server is denied"
assert_eq "1" "$((SECONDS - HS_START < 5))" "the own-server denial does not wait"
assert_contains "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TEST_TMP/hs.out")" "이 세션이 백그라운드로 띄운 서버" "the denial says the session's own server holds the slot"
# 다른 세션의 서버면 기다린다(여기서는 다른 살아 있는 pid로 흉내).
sleep 30 &
HS_OTHER=$!
jq --argjson a "$HS_OTHER" '.agent = $a' "$HS_DIR/own1.json" >"$TEST_TMP/hs.tmp" && mv "$TEST_TMP/hs.tmp" "$HS_DIR/own1.json"
# 백그라운드 명령은 감시자가 그룹을 놓치지 않게 HM_HEAVY_BG_WAIT(기본 60초)까지만 기다린다.
HS_START=$SECONDS
HM_HEAVY_WAIT=20 HM_HEAVY_BG_WAIT=1 hs_call pre "$(hs_in own3 "yarn start" true)"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")" "a background command waiting for another session is denied after its short wait"
assert_eq "1" "$((SECONDS - HS_START < 8))" "a background command waits only HM_HEAVY_BG_WAIT"
kill "$HS_OTHER" 2>/dev/null; wait "$HS_OTHER" 2>/dev/null || true
unset HM_HEAVY_SLOTS HM_HEAVY_MEM_FREE_PCT HM_HEAVY_WAIT
rm -f "$HS_DIR"/*.json
pass "background heavy commands hold their slot while the server lives"

# 상태 표시줄의 경과 시간·비용은 일이 멈춰도 바뀐다(#465). 화면 전체로 변화를 보면 정체(stalled)가 영원히 잡히지 않으므로
# 입력창 구분선 둘 중 위쪽 것 위의 내용만 본다.
cat >"$WD/bin/orca" <<'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == list ]]; then echo '{"ok":true,"result":{"terminals":[]}}'; exit 0; fi
n=$(( $(cat "$WD_DIR/clock" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$WD_DIR/clock"
sed "s/{{clock}}/$n/" "$WD_DIR/screen" | jq -Rsc '{ok:true, result:{terminal:{status:"running", tail:(split("\n"))}}}'
EOF
chmod +x "$WD/bin/orca"
WD_RULE="$(printf '%.0s─' {1..40})"
printf '✻ Running tests\n%s\n❯ \n%s\nctx 10%% | {{clock}}m | cost 0.10\n' "$WD_RULE" "$WD_RULE" >"$WD/screen"
rm -f "$WD/clock"
WD_OUT="$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --interval 1 --input-idle 100 --stall 2 --timeout 6)"
assert_contains "$WD_OUT" "reason=stalled" "a screen whose only change is the status line clock is stalled"
assert_contains "$(<"$ROOT/scripts/wait-delegation.sh")" "content_of" "the change hash reads only the content above the prompt"
pass "delegation wait sees a stall behind a ticking status line"

# 조율 세션 mod(mods/harness-delegations)는 wait-delegation.sh 와 같은 문구로 입력 대기·작업 중을 판정한다(#465).
# 한쪽만 고치면 프롬프트 위 줄과 대기 스크립트가 같은 화면을 다르게 읽는다.
WDM_SH="$(<"$ROOT/scripts/wait-delegation.sh")"
WDM_TS="$(<"$ROOT/mods/harness-delegations/hooks/register.tsx")"
wdm_ts() { sed -n "s#^const $1 = /\\(.*\\)/i\$#\\1#p" <<<"$WDM_TS" | sed 's#\\/#/#g'; }
WDM_ASK_SH="$(grep -o "grep -Eqi '[^']*Enter to (select|confirm)[^']*'" <<<"$WDM_SH" | sed "s/^grep -Eqi '//; s/'\$//")"
WDM_BUSY_SH="$(grep -o "grep -Eqi '[^']*esc to interrupt[^']*'" <<<"$WDM_SH" | sed "s/^grep -Eqi '//; s/'\$//")"
[ -n "$WDM_ASK_SH" ] && [ -n "$WDM_BUSY_SH" ] || fail "wait-delegation.sh patterns are readable"
assert_eq "$WDM_ASK_SH" "$(wdm_ts ASK)" "the mod reads an input prompt with the same pattern as wait-delegation.sh"
assert_eq "$WDM_BUSY_SH" "$(wdm_ts BUSY)" "the mod reads a working screen with the same pattern as wait-delegation.sh"
assert_eq "harness-delegations" "$(jq -r '.plugins[] | select(.source == "./mods/harness-delegations") | .name' "$ROOT/.claude-plugin/marketplace.json")" \
  "the marketplace lists the mod as its own optional plugin"
pass "delegation mod and wait script share their screen patterns"

finish_tests
