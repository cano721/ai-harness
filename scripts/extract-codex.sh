#!/usr/bin/env bash
# Codex CLI rollout 1개 → events/codex-<sid>.jsonl (덮어쓰기 = 멱등)
set -euo pipefail
T="${1:-}"
[[ -f "$T" ]] || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"
FILE_SID="$(basename "$T" .jsonl | sed 's/^rollout-//')"
SID="$(jq -Rrn 'first(inputs | fromjson? | select(.type=="session_meta") | .payload.id // empty) // empty' "$T" 2>/dev/null || true)"
[[ -n "$SID" ]] || SID="$FILE_SID"
CWD="$(jq -Rrn 'first(inputs | fromjson? | select(.type=="session_meta") | .payload.cwd // empty) // empty' "$T" 2>/dev/null || true)"
PROJECT="$(project_id_for_cwd "$CWD")"
SOURCE_MTIME="$(mtime "$T")"; SOURCE_MTIME="${SOURCE_MTIME:-0}"
SOURCE_SIZE="$(filesize "$T")"; SOURCE_SIZE="${SOURCE_SIZE:-0}"
OUT="$HM_DATA_DIR/events/codex-${FILE_SID}.jsonl"
# 임시파일을 대상과 같은 디렉토리에 — cross-device mv 방지
TMP="$(mktemp "$HM_DATA_DIR/events/.tmp.XXXXXX")"
# -R + fromjson?: 손상 라인은 그 줄만 스킵
if jq -c -R -n --argjson event_version "$HM_EVENT_VERSION" \
  --arg sid "$SID" --arg path "$T" --arg issue_re "$HM_ISSUE_RE" \
  --arg project "$PROJECT" --argjson source_mtime "$SOURCE_MTIME" --argjson source_size "$SOURCE_SIZE" '
  def counted(k): group_by(.) | map({kind:k, target:.[0], n:length}) | .[];
  def tool_calls($r): $r[] | select(.payload.type=="function_call" or .payload.type=="custom_tool_call");
  # Codex CLI records native function calls as JSON arguments, while the
  # desktop/runtime bridge records its JavaScript source in `input`.
  def tool_input:
    if .payload.type=="function_call" then (.payload.arguments // "")
    else (.payload.input // "") end;
  def command_input:
    if .payload.type=="function_call" then
      ((.payload.arguments // "{}") | (try fromjson catch {})
       | (.cmd // .command // "")
       | if type=="array" then map(tostring) | join(" ") else tostring end)
    elif .payload.name=="exec" then
      (tool_input | [match("\\\"cmd\\\"\\s*:\\s*\\\"(?<cmd>(?:\\\\\\\\.|[^\\\"])*)\\\""; "g").captures[].string] | join("\n"))
    else "" end;
  # 한 exec 명령이 여러 문서를 읽을 수 있으므로(sed A && sed B) 전체 매치를 모두 낸다.
  def harness_doc:
    ( [match("\\.ai-harness/[A-Za-z0-9_./-]+"; "g").string]
      + (if test("AGENTS\\.md") then ["AGENTS.md"] else [] end)
      + (if test("CLAUDE\\.md") then ["CLAUDE.md"] else [] end) )
    | unique | .[];
  def is_correction:
    startswith("아니") or startswith("아냐") or startswith("그게 아니라")
    or startswith("그거 말고") or startswith("그렇게 말고") or startswith("틀렸");
  [inputs | fromjson? // empty] as $L
  | (first($L[] | select(.type=="session_meta")) // {}) as $meta
  | ($meta.payload.cwd // "") as $cwd
  | {v:$event_version, src:"codex", sid:$sid, project:$project} as $base
  | ($L | map(select(.type=="response_item"))) as $R
  # 실제 사용자 발화만 — environment_context 등 주입 컨텍스트(<로 시작)는 제외
  | ([ $R[] | select(.payload.type=="message" and .payload.role=="user")
       | .payload.content[]? | (.text // "") | select(type=="string" and length>0)
       | select(startswith("<") | not) ]) as $userTexts
  | ([ $L[] | select(.type=="event_msg" and .payload.type=="user_message")
       | (.payload.message // "" | tostring) | select(startswith("<") | not) ]) as $eventUserTexts
  # 같은 발화가 response_item/event_msg 양쪽에 중복되므로 한쪽만 집계한다.
  | (if ($userTexts|length)>0 then $userTexts else $eventUserTexts end) as $texts
  | ([$L[] | select(.type=="event_msg" and .payload.type=="user_message")] | length) as $t2
  | (if ($userTexts|length) > $t2 then ($userTexts|length) else $t2 end) as $turns
  | ([$L[] | select(.type=="event_msg" and .payload.type=="token_count")
       | .payload.info.total_token_usage // empty] | last // {}) as $tok
  # 실제 모델명은 turn_context에 있다. provider를 모델명으로 대신 쓰지 않는다.
  | ([$L[] | select(.type=="turn_context") | .payload.model // empty] | last // null) as $model
  | (select(($L|length) > 0) | $base + {
      kind:"session",
      started: ($meta.payload.timestamp // ($L[0].timestamp // null)),
      ended:   ([$L[] | .timestamp // empty] | last // null),
      turns:   $turns,
      tok_in:  ($tok.input_tokens // 0),
      tok_out: ($tok.output_tokens // 0),
      cache_read: ($tok.cached_input_tokens // 0),
      cache_write: ($tok.cache_write_input_tokens // 0),
      model:   $model,
      provider: ($meta.payload.model_provider // null),
      cwd: $cwd, transcript: $path, source_mtime:$source_mtime, source_size:$source_size,
      coverage: [
        "workflow", "persona", "doc_read", "file_edit", "bash_cmd", "mcp_tool",
        "jira_issue", "error", "guard_block", "permission_deny", "compact",
        "correction_mark"
      ]
    }),
  # Workflow commands are explicit in user prompts for both slash commands
  # and the Codex `$skill` invocation syntax.
  ( [ ( $texts[] | select(test("^/[a-z]")) | capture("^/(?<c>[a-z0-9:_-]+)").c ),
      ( $texts[] | select(contains("$")) | split("$")[1] | split(" ")[0] )
    ] | counted("workflow") | $base + . ),
  # Agent delegation is exposed by the desktop bridge as tools.spawn_agent.
  ( [ tool_calls($R)
      | if .payload.type=="function_call" and .payload.name=="spawn_agent" then
          ((.payload.arguments // "{}") | (try fromjson catch {}) | .task_name // "general-purpose")
        elif .payload.type=="custom_tool_call" and .payload.name=="exec" then
          (tool_input | [match("tools\\.spawn_agent\\s*\\(\\s*\\{[^}]*\\\"task_name\\\"\\s*:\\s*\\\"(?<p>[^\\\"]+)\\\""; "g").captures[].string] | .[])
        else empty end
    ] | counted("persona") | $base + . ),
  # Read and patch calls retain their paths inside bridge input. Only harness
  # documents are reported, matching the Claude adapter privacy boundary.
  ( [ tool_calls($R) | tool_input | harness_doc ] | counted("doc_read") | $base + . ),
  ( [ tool_calls($R)
      | if .payload.type=="function_call" and (.payload.name=="apply_patch" or .payload.name=="edit_file") then
          ((.payload.arguments // "{}") | (try fromjson catch {}) | .file_path // "apply_patch")
        elif .payload.type=="custom_tool_call" and .payload.name=="exec" then
          (tool_input | [match("\\*\\*\\* (?:Update|Add|Delete) File: (?<p>[A-Za-z0-9_./-]+)"; "g").captures[].string] | .[])
        else empty end
    ] | counted("file_edit") | $base + . ),
  ( [ tool_calls($R) | .payload.name // empty
      | select(startswith("mcp__")),
      tool_calls($R) | tool_input | [match("tools\\.(?<m>mcp__[A-Za-z0-9_]+)"; "g").captures[].string] | .[]
    ] | counted("mcp_tool") | $base + . ),
  ( [ tool_calls($R) | command_input
      | select(type=="string" and length>0)
      | split("\n")[] | capture("^\\s*(?<cmd>\\S+)").cmd ]
    | counted("bash_cmd") | $base + . ),
  ( [ $texts[] | [match($issue_re;"g").string] | .[] ]
    | counted("jira_issue") | $base + . ),
  # Codex bridges mark failed calls in their tool output. Guard and permission
  # signals use the same conservative phrases as the Claude adapter.
  ( [$R[] | select(.payload.type=="function_call_output" or .payload.type=="custom_tool_call_output")
     | tostring | select(test("isError|is_error"; "i"))] | length
    | select(.>0) | $base + {kind:"error", n:.} ),
  ( [$R[] | select(.payload.type=="function_call_output" or .payload.type=="custom_tool_call_output")
     | tostring | select(test("\\[Direct edit guard\\]"))] | length
    | select(.>0) | $base + {kind:"guard_block", n:.} ),
  ( [$R[] | select(.payload.type=="function_call_output" or .payload.type=="custom_tool_call_output")
     | tostring | select(test("doesn.t want to proceed|user rejected"; "i"))
     | select(test("wants to clarify these questions") | not)] | length
    | select(.>0) | $base + {kind:"permission_deny", n:.} ),
  ( [$L[] | select(.type=="summary" or .payload.type=="compaction_summary" or .isCompactSummary==true)] | length
    | select(.>0) | $base + {kind:"compact", n:.} ),
  ( $texts[] | select(is_correction)
    | $base + {kind:"correction_mark", target:.[0:60], n:1} )
' "$T" > "$TMP"; then
  mv "$TMP" "$OUT"
else
  rm -f "$TMP"
  echo "extract 실패: $T" >&2
  exit 1
fi
