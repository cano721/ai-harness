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
WORK_TMP=$(mktemp -d)
trap 'rm -rf "$WORK_TMP"' EXIT
with_timeout() { # $1=출력 파일, 나머지=명령. 성공하면 종료 코드 0
  local out=$1 pid watchdog rc=0
  shift
  "$@" >"$out" 2>/dev/null &
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

CACHE_DIR="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/board"
# 파일마다 "크기:수정시각<TAB>경로"를 한 줄씩. 여러 파일을 stat 한 번으로 읽는다(파일마다 하위 프로세스를 띄우지 않게).
if stat -c %s /dev/null >/dev/null 2>&1; then
  file_keys() { stat --printf '%s:%Y\t%n\n' "$@" 2>/dev/null; } # GNU
else
  file_keys() { stat -f '%z:%m%t%N' "$@" 2>/dev/null; } # BSD(macOS)
fi

# claude agents 입력 캐시(#380): 보드의 백그라운드 갱신은 BOARD_CACHE_SECONDS를 넘긴다. 그 폴더의 세션 상태 파일(sessions/*.json,
# jobs/*/state.json)이 그대로이고 그 초보다 젊으면 지난 목록을 다시 쓴다(claude 프로세스 하나가 ~0.3초 CPU). 없으면(기본) 늘 새로.
AGENTS_SECS="${BOARD_CACHE_SECONDS:-0}"
case "$AGENTS_SECS" in ''|*[!0-9]*) AGENTS_SECS=0 ;; esac
AGENTS_CACHE="$CACHE_DIR/agents-cache"
now_e=$(date +%s)
agents_key() { # $1=설정 폴더(@default 가능) → 상태 파일 지문
  local root=$1
  [ "$root" != "@default" ] || root="$HOME/.claude"
  { printf '%s\n' "$root"; file_keys "$root"/sessions/*.json "$root"/jobs/*/state.json || true; } | cksum | tr -d ' \t'
}

# 폴더마다 목록을 동시에 받는다(폴더당 ~0.2초가 폴더 수만큼 쌓이지 않게). 성공한 폴더만 ok.<n>을 남긴다.
n=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  n=$((n + 1))
  printf '%s\n' "$d" >"$WORK_TMP/cfg.$n"
  if [ "$AGENTS_SECS" -gt 0 ]; then
    key=$(agents_key "$d")
    printf '%s\n' "$key" >"$WORK_TMP/key.$n"
    slot="$AGENTS_CACHE/$(printf '%s' "$d" | cksum | tr -d ' \t')"
    ckey="" cat_e=0
    [ ! -f "$slot.key" ] || read -r ckey cat_e <"$slot.key" || true
    case "$cat_e" in ''|*[!0-9]*) cat_e=0 ;; esac
    if [ "$ckey" = "$key" ] && [ -f "$slot.json" ] && [ "$now_e" -ge "$cat_e" ] && [ $((now_e - cat_e)) -lt "$AGENTS_SECS" ] \
      && cp "$slot.json" "$WORK_TMP/agents.$n" 2>/dev/null; then
      : >"$WORK_TMP/ok.$n"
      : >"$WORK_TMP/hit.$n"
      continue
    fi
  fi
  if [ "$d" = "@default" ]; then
    { with_timeout "$WORK_TMP/agents.$n" env -u CLAUDE_CONFIG_DIR claude agents --json --all && : >"$WORK_TMP/ok.$n"; } &
  else
    { CLAUDE_CONFIG_DIR="$d" with_timeout "$WORK_TMP/agents.$n" claude agents --json --all && : >"$WORK_TMP/ok.$n"; } &
  fi
done <<<"$cfg_dirs"
wait
# 폴더 순서대로 항목에 config_dir(기본 폴더는 null)을 달고, sessionId가 같으면 pid 있는 쪽(없으면 먼저 나온 쪽)만 남긴다.
agents='[]'
i=0
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
  [ -f "$WORK_TMP/ok.$i" ] || continue
  d=$(<"$WORK_TMP/cfg.$i")
  if [ "$d" = "@default" ]; then cfg_json=null; else cfg_json=$(jq -Rn --arg d "$d" '$d'); fi
  got=$(<"$WORK_TMP/agents.$i")
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$got" || continue
  if [ "$AGENTS_SECS" -gt 0 ] && [ ! -f "$WORK_TMP/hit.$i" ] && mkdir -p "$AGENTS_CACHE" 2>/dev/null && chmod 700 "$AGENTS_CACHE" 2>/dev/null; then
    slot="$AGENTS_CACHE/$(printf '%s' "$d" | cksum | tr -d ' \t')"
    { cp "$WORK_TMP/agents.$i" "$slot.json.$$" && chmod 600 "$slot.json.$$" && mv -f "$slot.json.$$" "$slot.json" \
      && printf '%s %s\n' "$(<"$WORK_TMP/key.$i")" "$now_e" >"$slot.key.$$" && chmod 600 "$slot.key.$$" && mv -f "$slot.key.$$" "$slot.key"; } 2>/dev/null || true
  fi
  agents=$(jq -c --argjson cfg "$cfg_json" --argjson more "$got" '. + ($more | map(. + {config_dir: $cfg}))' <<<"$agents")
done
agents=$(jq -c 'map(select(.sessionId != null)) | group_by(.sessionId) | map((map(select(.pid != null)) | first) // first)' <<<"$agents")

now_ms=$(( $(date +%s) * 1000 ))

# transcript마다 제목·요약을 뽑는 일(전체 grep + tail|jq)이 상태 수집에서 가장 비싸다. 경로·크기·수정 시각이 같으면
# 지난 결과를 쓴다(캐시: $DATA/board/work-cache.json, 이번 목록의 세션만 남김). transcript는 읽기만 한다.
CACHE="$CACHE_DIR/work-cache.json"
# 모양이 틀린 항목(옛 형식·손상)은 버린다 — 남겨 두면 jq가 죽어 작업 칸 전체가 빈다
jq -c 'if type == "object" then with_entries(select((.value | type) == "object" and (.value.key | type) == "string"
  and (.value.titles | type) == "object" and (.value.summary | type) == "object")) else {} end' "$CACHE" >"$WORK_TMP/old" 2>/dev/null \
  || echo '{}' >"$WORK_TMP/old"

# 세션마다 transcript 경로와 키(크기:수정 시각, 모든 파일을 stat 한 번으로). 경로는 지난 캐시에 있던 것이 아직 있으면 그대로 쓰고,
# 없을 때만 프로젝트 폴더 전체를 glob한다(폴더가 수백 개라 세션마다 glob하면 그것만 0.3초).
: >"$WORK_TMP/cur.tsv"
paths=()
# 칸 구분은 공백류가 아닌 \x1f — 탭이면 빈 칸(기본 폴더의 cfg)이 합쳐져 다음 칸이 밀린다.
while IFS=$'\x1f' read -r sid cfg known; do
  [ -n "$sid" ] || continue
  proj="$PROJECTS"
  [ -z "$cfg" ] || proj="$cfg/projects"
  case "$known" in
    "$proj"/*/"$sid".jsonl) set -- "$known" ;;
    *) set -- ;;
  esac
  if [ $# -eq 0 ] || [ ! -f "$1" ]; then set -- "$proj"/*/"$sid".jsonl; fi
  for f in "$@"; do
    [ -f "$f" ] || continue
    printf '%s\t%s\n' "$sid" "$f" >>"$WORK_TMP/cur.tsv"
    paths+=("$f")
    break
  done
done <<<"$(jq -r --slurpfile old "$WORK_TMP/old" '
  ($old[0] | keys | map({key: (split("/") | last | rtrimstr(".jsonl")), value: .}) | from_entries) as $known
  | .[] | [.sessionId, (.config_dir // ""), ($known[.sessionId] // "")] | join("\u001f")' <<<"$agents")"
: >"$WORK_TMP/keys.tsv"
[ "${#paths[@]}" -eq 0 ] || file_keys "${paths[@]}" >"$WORK_TMP/keys.tsv" || true
jq -Rn --rawfile k "$WORK_TMP/keys.tsv" '
  ($k | split("\n") | map(select(. != "") | split("\t") | {key: (.[1:] | join("\t")), value: .[0]}) | from_entries) as $keys
  | [inputs | split("\t") | (.[1:] | join("\t")) as $p | {sid: .[0], path: $p, key: ($keys[$p] // "")}]' <"$WORK_TMP/cur.tsv" >"$WORK_TMP/cur.json"

# 바뀐(또는 처음 보는) transcript만 파싱한다
: >"$WORK_TMP/new"
while IFS=$'\t' read -r t key; do
  [ -n "$t" ] || continue
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
         # 마지막 기록이 API 오류 메시지면(응답이 끊김) 세션은 더 진행하지 않는다 — 사람이 다시 시작해야 한다.
         api_error: ((map(select(.type == "user" or .type == "assistant")) | last) as $z
           | ($z.type == "assistant" and ($z.isApiErrorMessage == true or ($z.message.content | text? // "" | startswith("API Error:"))))),
         last: (map(.timestamp // empty) | max // null)}' 2>/dev/null || echo '{}')
  jq -cn --arg p "$t" --arg k "$key" --argjson ti "$titles" --argjson s "$summary" '{path: $p, key: $k, titles: $ti, summary: $s}' >>"$WORK_TMP/new"
done <<<"$(jq -r --slurpfile old "$WORK_TMP/old" '.[] | select(.key == "" or $old[0][.path].key != .key) | [.path, .key] | @tsv' "$WORK_TMP/cur.json")"

# 새 캐시: 이번 목록의 transcript만. 키를 모르면(stat 실패) 남기지 않는다.
jq -c --slurpfile old "$WORK_TMP/old" --slurpfile new "$WORK_TMP/new" '
  ($new | map({(.path): {key, titles, summary}}) | add // {}) as $n
  | map(select(.key != "") | .path as $p | {($p): ($n[$p] // $old[0][$p])}) | add // {} | with_entries(select(.value != null))' \
  "$WORK_TMP/cur.json" >"$WORK_TMP/cache" 2>/dev/null || echo '{}' >"$WORK_TMP/cache"
if ! cmp -s "$WORK_TMP/cache" "$CACHE" && mkdir -p "$CACHE_DIR" 2>/dev/null; then
  cache_tmp=$(mktemp "$CACHE.XXXXXX" 2>/dev/null) || cache_tmp=""
  if [ -n "$cache_tmp" ]; then
    chmod 600 "$cache_tmp"
    if ! { cat "$WORK_TMP/cache" >"$cache_tmp" && mv -f "$cache_tmp" "$CACHE"; }; then rm -f "$cache_tmp"; fi
  fi
fi

# 바뀐 transcript는 새로 뽑은 결과(cache에 있음)를, 키가 없던 것은 이번 결과(new)를 쓴다
jq --slurpfile c "$WORK_TMP/cache" --slurpfile new "$WORK_TMP/new" --slurpfile cur "$WORK_TMP/cur.json" \
  --argjson now "$now_ms" --argjson hours "$DONE_HOURS" '
  def clip($n): if . == null then null else gsub("\\s+"; " ") | if length > $n then .[0:$n] + "…" else . end end;
  ($cur[0] | map({(.sid): .path}) | add // {}) as $paths
  | (($new | map({(.path): .}) | add // {}) + ($c[0] // {})) as $parsed
  | [ .[] | ($paths[.sessionId] // "") as $path | ($parsed[$path] // {}) as $e
    | ($e.summary // {}) as $s | ($e.titles // {}) as $ti
    # 멈춘 세션: API 오류로 끊김(api_error) · 작업 중인데 프로세스가 없음(no_process). 작업 중으로 남기지 않는다.
    | (if .status == "waiting" then null
     elif $s.api_error == true then "api_error"
     elif .status == "busy" and .pid == null then "no_process"
     else null end) as $stall
    | (if $stall != null then "blocked"
     elif .status == "waiting" then "needs_human"
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
       stall: $stall,
       detail: ((if .status == "waiting" then "에이전트가 응답·권한을 기다림\n"
                 elif $stall == "api_error" then "API 오류로 응답이 끊김 — 다시 시작해야 이어짐\n"
                 elif $stall == "no_process" then "작업 중으로 남았지만 세션 프로세스가 없음\n"
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
                  # 실행 중(쉬는·작업 중)이면 claude attach로 원래 세션에, 멈췄으면 --resume으로(#380). 질문·권한 창에서 기다리면
                  # 창에 잘못 입력될 수 있어 보내기를 열지 않는다 — 화면이 attach 명령을 안내한다.
                  + (if .kind == "bg" and (.status == "idle" or .status == "busy" or .pid == null) then ["send"] else [] end)) ]' <<<"$agents"
