#!/usr/bin/env bash
# Codex CLI rollout 1개 → events/codex-<sid>.jsonl (덮어쓰기 = 멱등)
set -euo pipefail
T="${1:-}"
[[ -f "$T" ]] || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
SID="$(basename "$T" .jsonl | sed 's/^rollout-//')"
OUT="$HM_DATA_DIR/events/codex-${SID}.jsonl"
TMP="$(mktemp)"
if jq -c -n --arg sid "$SID" --arg path "$T" --arg issue_re "$HM_ISSUE_RE" '
  def counted(k): group_by(.) | map({kind:k, target:.[0], n:length}) | .[];
  [inputs] as $L
  | (first($L[] | select(.type=="session_meta")) // {}) as $meta
  | ($meta.payload.cwd // "") as $cwd
  | ($cwd | split("/") | last | sub("-wt-[0-9]+$";"")) as $proj
  | {v:1, src:"codex", sid:$sid, project:$proj} as $base
  | ($L | map(select(.type=="response_item"))) as $R
  | ([$R[] | select(.payload.type=="message" and .payload.role=="user")] | length) as $t1
  | ([$L[] | select(.type=="event_msg" and .payload.type=="user_message")] | length) as $t2
  | ([$L[] | select(.type=="event_msg" and .payload.type=="token_count")
       | .payload.info.total_token_usage // empty] | last // {}) as $tok
  | ($base + {
      kind:"session",
      started: ($meta.payload.timestamp // ($L[0].timestamp // null)),
      ended:   ([$L[] | .timestamp // empty] | last // null),
      turns:   (if $t1 > $t2 then $t1 else $t2 end),
      tok_in:  ($tok.input_tokens // 0),
      tok_out: ($tok.output_tokens // 0),
      cache_read: ($tok.cached_input_tokens // 0),
      model:   ($meta.payload.model_provider // null),
      cwd: $cwd, transcript: $path
    }),
  ( [ $R[] | select(.payload.type=="function_call")
      | (.payload.arguments // "{}") | (try fromjson catch {})
      | (.cmd // ((.command // []) | if type=="array" then join(" ") else tostring end))
      | select(type=="string" and length>0) | ltrimstr(" ") | split(" ")[0] ]
    | counted("bash_cmd") | $base + . ),
  ( [ $R[] | select(.payload.type=="user_message")
      | (.payload.message // .payload.content // "" | tostring)
      | [match($issue_re;"g").string] | .[] ]
    | counted("jira_issue") | $base + . )
' "$T" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$OUT"
else
  rm -f "$TMP"
  echo "extract 실패: $T" >&2
  exit 1
fi
