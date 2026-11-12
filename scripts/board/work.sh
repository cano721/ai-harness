#!/usr/bin/env bash
# 사람이 시킨 작업(에이전트 세션) 상태. 출처: Claude Code 공식 `claude agents --json --all` + 세션 transcript.
# 어느 터미널에서 띄운 세션이든 잡힌다. Orca는 필요 없다.
# 항목 state: needs_human(응답 대기·실패) | running(작업 중) | done(끝남·입력 가능, 최근 DONE_HOURS 이내)
set -uo pipefail
DONE_HOURS="${BOARD_DONE_HOURS:-48}"
PROJECTS="${HARNESS_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

command -v claude >/dev/null 2>&1 || { echo '[]'; exit 0; }

# Claude 설정 폴더 목록: 기본(CLAUDE_CONFIG_DIR 없이 = ~/.claude) → 서버 환경의 $CLAUDE_CONFIG_DIR → 프로필 자동 감지 → 사용자 지정.
# 실경로 기준으로 중복을 빼고 존재하는 폴더만 쓴다. 경로에 공백이 있을 수 있어 줄바꿈으로만 나눈다(':' 구분은 목록 사이만).
PROFILE_GLOBS="${BOARD_CLAUDE_PROFILE_GLOBS-$HOME/Library/Application Support/orca/claude-profiles/*/home}"
seen_dirs=""
cfg_dirs=""   # 줄바꿈 구분. "@default" = 기본 폴더
add_cfg_dir() { # $1=폴더 경로 또는 @default
  local real
  if [ "$1" = "@default" ]; then
    real=$(cd "$HOME/.claude" 2>/dev/null && pwd -P) || real="$HOME/.claude"
  else
    [ -d "$1" ] || return 0
    real=$(cd "$1" 2>/dev/null && pwd -P) || return 0
  fi
  case "
$seen_dirs
" in *"
$real
"*) return 0 ;; esac
  seen_dirs="$seen_dirs
$real"
  cfg_dirs="$cfg_dirs$1
"
}
colon_split() { printf '%s' "$1" | tr ':' '\n'; }
glob_dirs() { # $1=glob 패턴 → 일치하는 폴더를 줄마다 하나씩
  local IFS='
' d
  for d in $1; do [ -d "$d" ] && printf '%s\n' "$d"; done
  return 0
}
# 응답 없는 폴더(로그인 안 된 프로필 등) 하나가 상태 전체를 멈추지 않게 폴더마다 시간 제한을 둔다.
# 출력은 파이프($(...))가 아니라 파일로 받는다 — 끝낸 명령의 자식이 출력을 물고 남아 있으면 $(...)는 그 자식까지 기다린다.
AGENTS_OUT=$(mktemp)
trap 'rm -f "$AGENTS_OUT"' EXIT
with_timeout() { # 출력 → $AGENTS_OUT
  local pid watchdog rc=0
  "$@" >"$AGENTS_OUT" 2>/dev/null &
  pid=$!
  ( sleep "${BOARD_AGENTS_TIMEOUT:-20}"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}
add_cfg_dir "@default"
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || add_cfg_dir "$CLAUDE_CONFIG_DIR"
while IFS= read -r pattern; do
  [ -n "$pattern" ] || continue
  while IFS= read -r d; do
    [ -n "$d" ] && add_cfg_dir "$d"
  done <<<"$(glob_dirs "$pattern")"
done <<<"$(colon_split "$PROFILE_GLOBS")"
while IFS= read -r d; do
  [ -n "$d" ] && add_cfg_dir "$d"
done <<<"$(colon_split "${BOARD_CLAUDE_CONFIG_DIRS:-}")"

# 폴더마다 목록을 받아 항목에 config_dir(기본 폴더는 null)을 달고, sessionId가 같으면 pid 있는 쪽(없으면 먼저 나온 쪽)만 남긴다.
agents='[]'
while IFS= read -r d; do
  [ -n "$d" ] || continue
  if [ "$d" = "@default" ]; then
    with_timeout env -u CLAUDE_CONFIG_DIR claude agents --json --all || continue
    cfg_json=null
  else
    CLAUDE_CONFIG_DIR="$d" with_timeout claude agents --json --all || continue
    cfg_json=$(jq -Rn --arg d "$d" '$d')
  fi
  got=$(<"$AGENTS_OUT")
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$got" || continue
  agents=$(jq -c --argjson cfg "$cfg_json" --argjson more "$got" '. + ($more | map(. + {config_dir: $cfg}))' <<<"$agents")
done <<<"$cfg_dirs"
agents=$(jq -c 'map(select(.sessionId != null)) | group_by(.sessionId) | map((map(select(.pid != null)) | first) // first)' <<<"$agents")

now_ms=$(( $(date +%s) * 1000 ))
jq -c '.[]' <<<"$agents" | while IFS= read -r a; do
  sid=$(jq -r '.sessionId // empty' <<<"$a")
  [ -n "$sid" ] || continue
  t=""
  cfg=$(jq -r '.config_dir // empty' <<<"$a")
  proj="$PROJECTS"
  [ -z "$cfg" ] || proj="$cfg/projects"
  for f in "$proj"/*/"$sid".jsonl; do [ -f "$f" ] && t=$f && break; done
  summary='{}'
  titles='{}'
  if [ -n "$t" ]; then
    # Claude가 붙인 요약 제목(ai-title)과 사람이 바꾼 제목(custom-title, /rename)
    titles=$({ grep -hE '"type":"(ai-title|custom-title)"' "$t" || true; } | jq -cs '{ai: (map(select(.type == "ai-title") | .aiTitle) | last),
      custom: (map(select(.type == "custom-title") | .customTitle) | last)}' 2>/dev/null || echo '{}')
    # 긴 transcript는 끝부분만 본다. 사람 요청(tool_result 제외)과 마지막 답변, 마지막 기록 시각.
    summary=$(tail -n 600 "$t" | jq -cs '
      def text: if type == "string" then . else (map(select(.type? == "text") | .text) | join(" ")) end;
      (map(select(.type == "user" and ((.message.content | type) == "string" or (.message.content | any(.type? == "text")))
                  and (.isMeta != true)
                  and ((.message.content | text | sub("^\\s+"; "")) | test("^(<(command|local-command|system)|Base directory for this skill|Caveat:|<task-notification|This session is being continued|You have [0-9]+ new orchestration message|Another Claude session sent a message)") | not))) | last) as $u
      | (map(select(.type == "assistant" and (.message.content | any(.type? == "text")))) | last) as $r
      | {prompt: ($u.message.content | text? // null), reply: ($r.message.content | text? // null),
         # 사람이 마지막 답 뒤에 아직 말하지 않았을 때만 그 답의 끝부분을 싣는다 — 보드가 본문으로 묻는 질문을 찾는다(asks.py).
         reply_tail: (if $r and (($r.timestamp // "") > ($u.timestamp // "")) then ($r.message.content | text? // "" | .[-400:]) else null end),
         last: (map(.timestamp // empty) | max // null)}' 2>/dev/null || echo '{}')
  fi
  jq -c --argjson s "$summary" --argjson ti "$titles" --arg path "${t:-}" --argjson now "$now_ms" --argjson hours "$DONE_HOURS" '
    def clip($n): if . == null then null else gsub("\\s+"; " ") | if length > $n then .[0:$n] + "…" else . end end;
    (if .status == "waiting" then "needs_human"
     elif .status == "busy" then "running"
     elif .state == "failed" then "needs_human"
     else "done" end) as $st
    | (($s.last // null) // (if .startedAt then (.startedAt / 1000 | floor | todate) else null end)) as $at
    | select(.pid != null or ($at != null and ($now / 1000 - ($at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) < $hours * 3600))
    | {section: "work", kind: (if .kind == "background" then "bg" else "agent" end), state: $st,
       project: (.cwd // "?" | split("/") | map(select(. != "")) | .[-1]),
       at: $at,
       title: ($ti.custom // (if (.name // "" | test("-[0-9a-f]{2}$")) then $ti.ai else null end) // .name // $ti.ai // .sessionId[0:8]),
       term: .name,
       detail: ((if .status == "waiting" then "에이전트가 응답·권한을 기다림\n"
                 elif .state == "failed" then "백그라운드 세션이 실패함\n"
                 elif .pid == null then "세션 종료됨\n" else "" end)
                + (if $s.prompt then "요청: " + ($s.prompt | clip(140)) else "" end)
                + (if $s.reply then "\n— " + ($s.reply | clip(220)) else "" end)),
       reply_tail: ($s.reply_tail // null),
       agent: "claude", sid: .sessionId, short_id: (.id // .sessionId[0:8]), pid, cwd,
       config_dir: (.config_dir // null),
       transcript: (if $path == "" then null else $path end),
       live: (.pid != null), status: .status, bg_state: .state,
       link: null, log: null, cmd: (if .kind == "background" then "claude attach \(.id // .sessionId[0:8])" else null end),
       id: "claude|\(.sessionId)"}
    | .actions = ((if .transcript then ["view"] else [] end)
                  + (if .kind == "bg" and (.status == "idle" or .status == "waiting" or .pid == null) then ["send"] else [] end))' <<<"$a"
done | jq -s .
