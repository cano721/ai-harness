#!/usr/bin/env bash
# 세션 transcript를 저비용 모델로 읽어, 접두어·정규식 신호가 놓친 마찰(교정, 반복 실패, 빠진 프로젝트 지식 등)을
# 구조화된 findings로 남긴다 (opt-in: HM_DIGEST=1). 결과는 harvest 큐의 insights 신호와 /harvest 근거가 된다.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

DIGEST_DIR="$HM_DATA_DIR/digests"
RUNS_FILE="$DIGEST_DIR/runs.jsonl"
MODEL="${HM_DIGEST_MODEL:-haiku}"
DAILY_MAX="${HM_DIGEST_DAILY_MAX:-20}"; [[ "$DAILY_MAX" =~ ^[0-9]+$ ]] || DAILY_MAX=20
MIN_TURNS="${HM_DIGEST_MIN_TURNS:-3}"; [[ "$MIN_TURNS" =~ ^[0-9]+$ ]] || MIN_TURNS=3
LOOKBACK_DAYS="${HM_DIGEST_LOOKBACK_DAYS:-14}"; [[ "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] || LOOKBACK_DAYS=14
BUDGET_USD="${HM_DIGEST_BUDGET_USD:-0.2}"
INPUT_MAX_CHARS=40000
mkdir -p "$DIGEST_DIR"

usage() {
  cat >&2 <<'EOF'
usage:
  digest.sh run                     # 정리 대상 세션을 최근 순으로 HM_DIGEST_DAILY_MAX까지 처리
  digest.sh one <event-file>        # 세션 1개 정리
  digest.sh show --project <name>   # 현재 analysis batch(없으면 대기 세션)의 findings
EOF
  exit 2
}

SCHEMA='{
  "type":"object",
  "properties":{"findings":{"type":"array","items":{"type":"object","properties":{
    "category":{"type":"string","enum":["correction","repeated_failure","missing_context","wrong_approach","wasted_effort","workflow_gap","other"]},
    "summary":{"type":"string"},
    "evidence":{"type":"string"},
    "harness_fix":{"type":"string"},
    "confidence":{"type":"string","enum":["high","medium","low"]}
  },"required":["category","summary","evidence","harness_fix","confidence"]}}},
  "required":["findings"]
}'

SYSTEM_PROMPT='너는 코딩 에이전트 세션 기록을 읽고, 프로젝트 하네스(AGENTS.md 규칙, 프로젝트 문서, 워크플로)를 고쳤다면 막을 수 있었던 마찰만 골라내는 분석가다.
입력의 [U]는 사용자 발화, [A]는 에이전트 응답, [E]는 도구 오류다.
뽑을 것:
- correction: 사용자가 에이전트의 방향·결과를 바로잡음 (접두어가 없어도 의미상 교정이면 포함)
- repeated_failure: 같은 종류의 실패·재시도가 반복됨
- missing_context: 에이전트가 프로젝트 사실(구조, 명령, 규칙, 환경)을 몰라 틀리거나 사용자에게 물음
- wrong_approach: 프로젝트 관례와 다른 방식으로 진행하다 되돌림
- wasted_effort: 불필요한 탐색·루프로 시간·토큰을 크게 씀
- workflow_gap: 매번 같은 다단계 절차를 사람이 지시해야 함
버릴 것: 일회성 오타, 정상적인 요구사항 전달·추가 요청, 외부 장애, 하네스로 막을 수 없는 것.
evidence는 입력에서 그대로 인용(160자 이내), summary·harness_fix는 한국어 한 문장(120자 이내).
근거가 분명한 것만, 없으면 빈 배열을 돌려라.'

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

digest_path() { # $1=event_file → digests/<같은 stem>.json
  local base="${1##*/}"
  printf '%s/%s.json\n' "$DIGEST_DIR" "${base%.jsonl}"
}

# transcript → 압축 대화 텍스트. 사용자 발화를 우선 보존하고 응답·오류는 짧게 자른다.
build_input() { # $1=src $2=transcript
  local text=""
  if [[ "$1" == "codex" ]]; then
    text="$(jq -Rr 'fromjson? // empty
      | if .type=="response_item" and .payload.type=="message" then
          (.payload.role) as $r
          | ([.payload.content[]? | (.text // "")] | join(" ")) as $t
          | if ($t | length) == 0 or ($t | startswith("<")) then empty
            elif $r == "user" then "[U] " + ($t | gsub("\\s+"; " ") | .[0:600])
            elif $r == "assistant" then "[A] " + ($t | gsub("\\s+"; " ") | .[0:300])
            else empty end
        elif .type=="response_item" and (.payload.type=="function_call_output") then
          ((.payload.output // "") | tostring) as $o
          | if ($o | test("\"exit_code\":[1-9]|Process exited with code [1-9]")) then "[E] " + ($o | gsub("\\s+"; " ") | .[0:200]) else empty end
        else empty end' "$2" 2>/dev/null)"
  else
    text="$(jq -Rr 'fromjson? // empty
      | if .type=="user" and (.message.content | type) == "string" then
          if (.message.content | startswith("<")) and ((.message.content | test("<command-args>")) | not) then empty
          else "[U] " + (.message.content | gsub("\\s+"; " ") | .[0:600]) end
        elif .type=="user" then
          (.message.content[]? | select(type=="object")
            | if .type=="text" then "[U] " + (.text | gsub("\\s+"; " ") | .[0:600])
              elif .type=="tool_result" and .is_error == true then
                "[E] " + ((.content | if type=="string" then . elif type=="array" then (map(.text? // "") | join(" ")) else "" end)
                  | gsub("\\s+"; " ") | .[0:200])
              else empty end)
        elif .type=="assistant" then
          ([.message.content[]? | select(type=="object" and .type=="text") | .text] | join(" ")) as $t
          | if ($t | length) > 0 then "[A] " + ($t | gsub("\\s+"; " ") | .[0:300]) else empty end
        else empty end' "$2" 2>/dev/null)"
  fi
  # 길면 앞부분 일부와 뒷부분을 남긴다 — 교정은 대개 작업이 진행된 뒤에 나온다.
  if (( ${#text} > INPUT_MAX_CHARS )); then
    text="${text:0:8000}"$'\n[...중략...]\n'"${text: -$((INPUT_MAX_CHARS - 8000))}"
  fi
  printf '%s' "$text"
}

run_model() { # stdin=입력 → structured_output JSON
  if [[ -n "${HM_DIGEST_CMD:-}" ]]; then
    "$HM_DIGEST_CMD"
    return
  fi
  # 우리 hook이 이 내부 세션을 수집·알림하지 않게 표시하고, transcript도 남기지 않는다.
  (cd "$DIGEST_DIR" && HM_INTERNAL_SESSION=1 claude -p "아래 세션 기록에서 findings를 뽑아라." \
    --model "$MODEL" --no-session-persistence --tools "" \
    --system-prompt "$SYSTEM_PROMPT" --json-schema "$SCHEMA" \
    --max-budget-usd "$BUDGET_USD" --output-format json) \
    | jq -c 'select(.is_error != true) | {findings:(.structured_output.findings // []), cost_usd:(.total_cost_usd // null)}'
}

command_one() { # $1=event_file
  local ev="$1" session="" src="" transcript="" input="" out="" dest="" tmp=""
  session="$(jq -c 'select(.kind=="session")' "$ev" 2>/dev/null | head -n 1)"
  [[ -n "$session" ]] || return 1
  src="$(jq -r '.src' <<<"$session")"
  transcript="$(jq -r '.transcript // empty' <<<"$session")"
  [[ -f "$transcript" ]] || return 1
  input="$(build_input "$src" "$transcript")"
  [[ -n "$input" ]] || return 1
  out="$(printf '%s' "$input" | run_model)" || return 1
  [[ -n "$out" ]] && jq -e '.findings | type == "array"' <<<"$out" >/dev/null 2>&1 || return 1
  dest="$(digest_path "$ev")"
  tmp="$(mktemp "$DIGEST_DIR/.digest.XXXXXX")"
  jq -cn --argjson s "$session" --argjson out "$out" --arg model "$MODEL" --arg at "$(now_iso)" '{
    v:1, src:$s.src, sid:$s.sid, project:$s.project, ended:$s.ended, turns:$s.turns,
    model:$model, created_at:$at, cost_usd:$out.cost_usd,
    findings:($out.findings | map(.summary |= .[0:200] | .evidence |= .[0:240] | .harness_fix |= .[0:200]))
  }' >"$tmp" && mv "$tmp" "$dest"
  jq -cn --arg at "$(now_iso)" --arg event "${ev##*/}" --argjson out "$out" \
    '{at:$at,event:$event,findings:($out.findings|length),cost_usd:$out.cost_usd}' >>"$RUNS_FILE"
  # 큐의 insights 신호를 갱신한다.
  "$DIR/harvest-queue.sh" record "$ev" >/dev/null 2>&1 || true
}

done_today() {
  [[ -f "$RUNS_FILE" ]] || { printf '0\n'; return; }
  jq -s --arg day "$(date -u +%Y-%m-%d)" '[.[] | select(.at | startswith($day))] | length' "$RUNS_FILE" 2>/dev/null || printf '0\n'
}

# 정리 대상: 내부 세션 아님, 턴 수 충분, 끝난 지 30분 이상, 최근 N일, digest 없음 또는 세션이 재개됨.
due_events() {
  local cutoff="" settle="" ev=""
  cutoff="$(days_ago_iso "$LOOKBACK_DAYS")"
  settle="$(date -u -v-30M +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%S)"
  shopt -s nullglob
  for ev in "$HM_DATA_DIR"/events/*.jsonl; do
    jq -c --arg cutoff "$cutoff" --arg settle "$settle" --argjson min "$MIN_TURNS" --arg ev "$ev" '
      select(.kind=="session" and ((.internal // false) | not) and (.turns // 0) >= $min
        and (.ended // "") >= $cutoff and (.ended // "") < $settle)
      | {ev:$ev, ended:.ended}' "$ev" 2>/dev/null
  done | jq -sr --arg dir "$DIGEST_DIR" '
      sort_by(.ended) | reverse | .[] | [.ev, .ended] | @tsv' \
    | while IFS=$'\t' read -r ev ended; do
        local dest
        dest="$(digest_path "$ev")"
        if [[ -f "$dest" ]] && [[ "$(jq -r '.ended // empty' "$dest" 2>/dev/null)" == "$ended" ]]; then
          continue
        fi
        printf '%s\n' "$ev"
      done
  shopt -u nullglob
}

command_run() {
  local remaining=0 ev="" ok=0 fail=0
  remaining=$(( DAILY_MAX - $(done_today) ))
  (( remaining > 0 )) || { echo "digest: 오늘 상한($DAILY_MAX) 도달"; return 0; }
  while IFS= read -r ev; do
    (( remaining > 0 )) || break
    if command_one "$ev"; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    remaining=$((remaining - 1))
  done < <(due_events)
  if (( fail > 0 && ok == 0 )); then
    "$DIR/health.sh" failure digest "failed_$fail" >/dev/null 2>&1 || true
  else
    "$DIR/health.sh" success digest >/dev/null 2>&1 || true
  fi
  echo "digest 완료: 정리 $ok, 실패 $fail"
}

command_show() { # --project P
  [[ "${1:-}" == "--project" && -n "${2:-}" ]] || usage
  local ev=""
  while IFS= read -r ev; do
    [[ -n "$ev" ]] || continue
    local dest
    dest="$(digest_path "$ev")"
    [[ -f "$dest" ]] || continue
    jq -c '{sid:(.sid[0:8]), ended, findings:[.findings[] | select(.confidence != "low")]}
      | select(.findings | length > 0)' "$dest"
  done < <("$DIR/harvest-queue.sh" events --project "$2" 2>/dev/null)
}

command="${1:-}"
shift || true
case "$command" in
  run) command_run ;;
  one) [[ -f "${1:-}" ]] || usage; command_one "$1" ;;
  show) command_show "$@" ;;
  *) usage ;;
esac
