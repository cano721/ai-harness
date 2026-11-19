#!/usr/bin/env bash
# PreToolUse·PostToolUse(Bash): 무거운 명령(빌드·dev 서버·전체 테스트·e2e)을 메모리 기준 슬롯으로 줄 세운다(#436).
# 병렬 세션의 빌드·테스트가 같은 순간에 겹치면 swap이 가득 차 전체가 느려진다(실측: 빌드 4.1GB, jest 워커 9GB).
#
#   heavy-slot-hook.sh pre    PreToolUse — 빈 슬롯을 얻을 때까지 기다리고, HM_HEAVY_WAIT초가 지나면 이유와 함께 거절한다.
#   heavy-slot-hook.sh post   PostToolUse — 포그라운드 명령의 슬롯을 돌려준다(백그라운드는 띄운 직후 오므로 두지 않는다).
#   heavy-slot-hook.sh match <명령>   무거운 명령이면 0
#
# 켜기: HM_HEAVY_SLOTS=<동시 최대>(없으면 아무것도 하지 않는다). 남은 메모리가 30% 미만이면 절반, 15% 미만이면 1개.
# hook timeout(600초)을 넘기면 Claude Code는 명령을 그냥 실행하므로(실측) 대기는 그 전에 스스로 끝내고 거절한다.
# Esc로 끊긴 호출은 PostToolUse가 오지 않는다(실측) — transcript에 그 호출의 tool_result가 있으면 끝난 것으로 회수한다.
# 백그라운드 서버의 슬롯은 background-watchdog.sh가 찾은 그룹(bg-watchdog/<pgid>/tool_use_id)이 사는 동안 쥔다.
# 어떤 오류든 그대로 통과(fail-open)한다.
set -uo pipefail
trap 'exit 0' ERR

mode="${1:-}"
case "$mode" in pre | post | match) ;; *) exit 0 ;; esac
# 꺼져 있으면 lib.sh·jq 전에 빠진다 — Bash 호출마다 Pre·Post(또는 Failure)로 두 번 불린다.
if [[ "$mode" != match && ! "${HM_HEAVY_SLOTS:-}" =~ ^[1-9] ]] &&
  ! grep -qE '^[[:space:]]*(export[[:space:]]+)?HM_HEAVY_SLOTS=["'"'"']?[1-9]' "${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/config" 2>/dev/null; then
  exit 0
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh" 2>/dev/null || exit 0

# 세그먼트(&&·||·;·|·&·괄호·줄바꿈으로 나눈 단위) 머리에 맞춘다. 앞의 VAR=값·env·nohup·exec·time·command·sudo·timeout은 건너뛴다.
# 따옴표는 해석하지 않는다 — 문자열 안의 줄 머리가 맞으면 쓸데없이 기다릴 뿐 막지는 않는다.
HEAVY_DEFAULT_RE='^((npm|bun)( run)?|pnpm( -r| --recursive| --filter[ =][^ ]+| -F [^ ]+)*( run)?|yarn( workspace [^ ]+| [@a-z0-9._/-]+)?( run)?) (build|dev|start|preview|test:ci|e2e)( |:|$)'
HEAVY_DEFAULT_RE+='|^(npx |pnpm exec |yarn )?(next (build|dev|start)|vite( build| preview)?|playwright test|jest|vitest run)( |$)'
HEAVY_DEFAULT_RE+='|^(\./)?(gradlew|gradle|mvnw|mvn)( [^;&|]*)? (build|test|bootRun|assemble|package|verify|install)( |$)'
HEAVY_DEFAULT_RE+='|^docker[ -]compose( [^;&|]*)? up( |$)'
# yarn의 워크스페이스 별칭 자리에 온 패키지 관리 명령(yarn add build 등)은 기본 패턴에서 뺀다.
HEAVY_DEFAULT_EXCLUDE_RE='^yarn (add|remove|install|upgrade|up|why|info|dlx|global|config|cache|link|unlink|set|plugin|npm|pack|version|init|create) '

heavy_match() { # 명령 → 무거우면 0
  local pat="${HM_HEAVY_PATTERNS:-$HEAVY_DEFAULT_RE}" exclude="" text="$1" seg="" nl='
'
  local prefix_re='^([A-Za-z_][A-Za-z0-9_]*=[^ ]*|env|nohup|exec|time|command|sudo|timeout [0-9.]+[smhd]?)[[:space:]]+(.*)$'
  [[ -n "${HM_HEAVY_PATTERNS:-}" ]] || exclude="$HEAVY_DEFAULT_EXCLUDE_RE"
  text="${text//&&/$nl}"
  text="${text//||/$nl}"
  text="${text//;/$nl}"
  text="${text//|/$nl}"
  text="${text//&/$nl}"
  text="${text//(/$nl}"
  text="${text//)/$nl}"
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    while [[ "$seg" =~ $prefix_re ]]; do seg="${BASH_REMATCH[2]}"; done
    [[ -n "$exclude" && "$seg" =~ $exclude ]] && continue
    [[ -n "$seg" && "$seg" =~ $pat ]] && return 0
  done <<<"$text"
  return 1
}

if [[ "$mode" == match ]]; then
  if heavy_match "${2:-}"; then exit 0; else exit 1; fi
fi

[[ "${HM_HEAVY_SLOTS:-}" =~ ^[1-9][0-9]*$ ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)" || exit 0
# jq 한 번: 앞 세 줄이 id·백그라운드·transcript, 나머지가 명령(여러 줄일 수 있다).
{
  IFS= read -r tool_use_id
  IFS= read -r background
  IFS= read -r transcript
  command_text="$(cat)"
} <<<"$(jq -r '(.tool_use_id // "" | tostring), (.tool_input.run_in_background == true), (.transcript_path // "" | tostring), (.tool_input.command | strings)' <<<"$input" 2>/dev/null)"
[[ "$tool_use_id" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

SLOTS="$HM_DATA_DIR/heavy-slots"
CLAIMS="$HM_DATA_DIR/bg-watchdog"
slot="$SLOTS/$tool_use_id.json"

# PostToolUse(성공)·PostToolUseFailure(실패 — 실측: 실패한 명령은 PostToolUse가 오지 않는다) 모두 post로 부른다.
if [[ "$mode" == post ]]; then
  [[ -f "$slot" && "$background" != true ]] && rm -f "$slot"
  exit 0
fi

heavy_match "$command_text" || exit 0
[[ -f "$slot" ]] && exit 0

# hook의 부모가 에이전트다. hooks.json의 sh가 마지막 명령을 exec하지 않으면 한 단계 위로 올라간다(background-watchdog-hook.sh와 같다).
agent="$PPID"
parent_comm="$(ps -o comm= -p "$agent" 2>/dev/null)"
parent_comm="${parent_comm##*/}"
parent_comm="${parent_comm#-}"
if [[ "$parent_comm" =~ ^(sh|dash|bash|ash|zsh)$ && "$(ps -ww -o args= -p "$agent" 2>/dev/null)" == *heavy-slot-hook.sh* ]]; then
  agent="$(ps -o ppid= -p "$agent" 2>/dev/null | tr -d ' ')"
fi
[[ "$agent" =~ ^[0-9]+$ && "$agent" -gt 1 ]] || exit 0

free_pct() { # 남은 메모리 %(모르면 빈 값). HM_HEAVY_MEM_FREE_PCT는 측정 대신 쓸 값(진단·테스트).
  if [[ -n "${HM_HEAVY_MEM_FREE_PCT:-}" ]]; then
    printf '%s' "$HM_HEAVY_MEM_FREE_PCT"
  elif command -v memory_pressure >/dev/null 2>&1; then
    # macOS: swap은 필요할 때 늘어나 사용률이 늘 높다 — 압축 메모리까지 반영한 free percentage만 본다.
    memory_pressure 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p'
  elif [[ -r /proc/meminfo ]]; then
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t > 0) printf "%d", a * 100 / t}' /proc/meminfo
  fi
}

capacity() { # $1=남은 메모리 %
  local max="$HM_HEAVY_SLOTS" free="$1"
  if [[ ! "$free" =~ ^[0-9]+$ ]]; then
    echo "$max"
  elif ((free < 15)); then
    echo 1
  elif ((free < 30)); then
    echo $(((max + 1) / 2))
  else
    echo "$max"
  fi
}

reclaim() { # 끝난 호출의 슬롯을 지운다
  local f="" a="" id="" t="" bg="" started="" d="" held="" now
  now="$(date +%s)"
  for f in "$SLOTS"/*.json; do
    [[ -f "$f" ]] || continue
    # 줄 단위로 읽는다 — 탭으로 나누면 빈 transcript 칸이 사라져 뒤 칸이 밀린다.
    { read -r a; read -r id; read -r t; read -r bg; read -r started; } <<<"$(jq -r '.agent, .tool_use_id, (.transcript // ""), .bg, .started' "$f" 2>/dev/null)"
    if [[ ! "$a" =~ ^[0-9]+$ ]] || ! kill -0 "$a" 2>/dev/null; then
      rm -f "$f"
      continue
    fi
    [[ "$started" =~ ^[0-9]+$ ]] || started="$now"
    if [[ "$bg" == true ]]; then
      held=false
      for d in "$CLAIMS"/*/; do
        d="${d%/}"
        [[ -f "$d/tool_use_id" && "$(<"$d/tool_use_id")" == "$id" ]] || continue
        # 감시자가 KILL로 죽으면 선점 디렉토리가 남는다 — 그룹이 실제로 살아 있을 때만 쥔 것으로 본다.
        [[ "${d##*/}" =~ ^[0-9]+$ ]] && kill -0 -- "-${d##*/}" 2>/dev/null && { held=true; break; }
      done
      # 감시자가 그룹을 찾는 데 최대 120초 — 그 사이에는 쥔 것으로 본다.
      [[ "$held" == true ]] || ((now - started < 130)) || rm -f "$f"
    elif [[ -n "$t" && -f "$t" ]] && tail -c 4000000 "$t" 2>/dev/null | grep -qF "\"tool_use_id\":\"$id\""; then
      rm -f "$f"
    elif ((now - started > ${HM_HEAVY_SLOT_TTL:-10800})); then
      rm -f "$f"
    fi
  done
}

own_servers_only() { # 슬롯을 모두 이 에이전트의 백그라운드 서버가 쥐고 있으면 0 — 기다려도 풀리지 않는다
  local f="" a="" bg="" any=1
  for f in "$SLOTS"/*.json; do
    [[ -f "$f" ]] || continue
    { read -r a; read -r bg; } <<<"$(jq -r '.agent, .bg' "$f" 2>/dev/null)"
    [[ "$a" == "$agent" && "$bg" == true ]] || return 1
    any=0
  done
  return "$any"
}

holders() { # 슬롯을 쥔 명령 목록
  local f="" c="" s="" now
  now="$(date +%s)"
  for f in "$SLOTS"/*.json; do
    [[ -f "$f" ]] || continue
    { read -r c; read -r s; } <<<"$(jq -r '.cmd, .started' "$f" 2>/dev/null)"
    [[ "$s" =~ ^[0-9]+$ ]] || s="$now"
    printf -- '- %s (%s초째)\n' "$c" "$((now - s))"
  done
}

mkdir -p "$SLOTS" 2>/dev/null || exit 0
wait_limit="${HM_HEAVY_WAIT:-540}"
[[ "$wait_limit" =~ ^[0-9]+$ ]] || wait_limit=540
((wait_limit <= 580)) || wait_limit=580
# 백그라운드 명령은 감시자(hook과 함께 시작, 120초 안에 그룹을 찾는다)가 그룹을 놓치지 않게 짧게만 기다린다.
if [[ "$background" == true ]]; then
  bg_wait="${HM_HEAVY_BG_WAIT:-60}"
  [[ "$bg_wait" =~ ^[0-9]+$ ]] || bg_wait=60
  ((wait_limit <= bg_wait)) || wait_limit="$bg_wait"
fi
deadline=$((SECONDS + wait_limit))
first_line="${command_text%%$'\n'*}"
trap 'exit 0' TERM INT

while :; do
  free="$(free_pct)"
  cap="$(capacity "$free")"
  if hm_acquire_lock "$SLOTS/.lock"; then
    reclaim
    used=0
    for f in "$SLOTS"/*.json; do [[ -f "$f" ]] && used=$((used + 1)); done
    if ((used < cap)); then
      jq -cn --arg id "$tool_use_id" --argjson a "$agent" --arg c "${first_line:0:160}" --argjson bg "$background" \
        --arg t "$transcript" --argjson s "$(date +%s)" \
        '{tool_use_id:$id, agent:$a, cmd:$c, bg:$bg, transcript:$t, started:$s}' >"$slot" 2>/dev/null
      hm_release_lock "$SLOTS/.lock"
      exit 0
    fi
    list="$(holders)"
    own=false
    own_servers_only && own=true
    hm_release_lock "$SLOTS/.lock"
    if [[ "$own" == true ]]; then
      reason="[Heavy slot] 무거운 명령의 동시 한도 ${cap}개(남은 메모리 ${free:-?}%)를 이 세션이 백그라운드로 띄운 서버가 모두 쓰고 있어 이 명령을 실행하지 않았습니다. 기다려도 풀리지 않습니다:
${list}
그 서버를 쓰거나, 더 쓰지 않으면 프로세스 그룹째 끈 뒤 다시 실행하세요."
      jq -cn --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
      exit 0
    fi
  else
    list=""
  fi
  if ((SECONDS >= deadline)); then
    # 마지막 시도에서도 lock을 못 얻었으면(목록 없음) 막을 근거가 없다 — 통과(fail-open).
    [[ -n "$list" ]] || exit 0
    reason="[Heavy slot] 무거운 명령(빌드·dev 서버·전체 테스트)이 동시 한도 ${cap}개(남은 메모리 ${free:-?}%)를 모두 쓰고 있어 ${wait_limit}초 기다린 뒤 이 명령을 실행하지 않았습니다. 지금 실행 중:
${list}
잠시 뒤 다시 시도하거나, 더 쓰지 않는 dev 서버·빌드를 먼저 끝내세요. 같은 작업 트리에 이미 떠 있는 서버가 있으면 그것을 쓰세요."
    jq -cn --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
    exit 0
  fi
  sleep 2
done
