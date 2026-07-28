#!/usr/bin/env bash
# Codex CLI rollout 1개 → events/codex-<sid>.jsonl (덮어쓰기 = 멱등)
set -euo pipefail
T="${1:-}"
[[ -f "$T" ]] || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
SID="$(basename "$T" .jsonl | sed 's/^rollout-//')"
OUT="$HM_DATA_DIR/events/codex-${SID}.jsonl"
# 임시파일을 대상과 같은 디렉토리에 — cross-device mv 방지
TMP="$(mktemp "$HM_DATA_DIR/events/.tmp.XXXXXX")"
# -R + fromjson?: 손상 라인은 그 줄만 스킵
if jq -c -R -n --arg sid "$SID" --arg path "$T" --arg issue_re "$HM_ISSUE_RE" '
  def counted(k): group_by(.) | map({kind:k, target:.[0], n:length}) | .[];
  [inputs | fromjson? // empty] as $L
  | (first($L[] | select(.type=="session_meta")) // {}) as $meta
  | ($meta.payload.cwd // "") as $cwd
  | ($cwd | split("/") | last // "" | sub("-wt-[0-9]+$";"")) as $proj
  | {v:1, src:"codex", sid:$sid, project:$proj} as $base
  | ($L | map(select(.type=="response_item"))) as $R
  # 실제 사용자 발화만 — environment_context 등 주입 컨텍스트(<로 시작)는 제외
  | ([ $R[] | select(.payload.type=="message" and .payload.role=="user")
       | .payload.content[]? | (.text // "") | select(type=="string" and length>0)
       | select(startswith("<") | not) ]) as $userTexts
  | ([$L[] | select(.type=="event_msg" and .payload.type=="user_message")] | length) as $t2
  | (if ($userTexts|length) > $t2 then ($userTexts|length) else $t2 end) as $turns
  | ([$L[] | select(.type=="event_msg" and .payload.type=="token_count")
       | .payload.info.total_token_usage // empty] | last // {}) as $tok
  # 실제 모델명은 turn_context에 — 없으면 model_provider 폴백
  | ([$L[] | select(.type=="turn_context") | .payload.model // empty] | last
       // ($meta.payload.model_provider // null)) as $model
  | (select(($L|length) > 0) | $base + {
      kind:"session",
      started: ($meta.payload.timestamp // ($L[0].timestamp // null)),
      ended:   ([$L[] | .timestamp // empty] | last // null),
      turns:   $turns,
      tok_in:  ($tok.input_tokens // 0),
      tok_out: ($tok.output_tokens // 0),
      cache_read: ($tok.cached_input_tokens // 0),
      model:   $model,
      cwd: $cwd, transcript: $path
    }),
  ( [ $R[] | select(.payload.type=="function_call")
      | (.payload.arguments // "{}") | (try fromjson catch {})
      | (.cmd // ((.command // []) | if type=="array" then (map(tostring) | join(" ")) else tostring end))
      | select(type=="string" and length>0) | ltrimstr(" ") | split(" ")[0] ]
    | counted("bash_cmd") | $base + . ),
  ( [ ($userTexts[],
       ($L[] | select(.type=="event_msg" and .payload.type=="user_message")
         | (.payload.message // "" | tostring) | select(startswith("<") | not)))
      | [match($issue_re;"g").string] | .[] ]
    | unique_by(.) as $keys | ($keys[] | {kind:"jira_issue", target:., n:1}) | $base + . )
' "$T" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$OUT"
else
  rm -f "$TMP"
  echo "extract 실패: $T" >&2
  exit 1
fi
