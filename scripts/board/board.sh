#!/usr/bin/env bash
# shellcheck disable=SC2016  # write_settings에 넘기는 작은따옴표 인자는 jq 식이다($c·$t는 jq 변수)
# Harness Board 띄우기·끄기·상태, 권한 훅 연결. 상시 서비스가 아니라 필요할 때 여는 로컬 화면이다.
# 서버는 127.0.0.1에만 묶이고 실행마다 새 URL 토큰을 만든다. 상태 파일은 $HM_DATA_DIR/board/에 둬서
# 플러그인이 업데이트돼 경로가 바뀌어도 그대로 이어 쓴다.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/../lib.sh"

BOARD_DIR="$HM_DATA_DIR/board"
CONF="$BOARD_DIR/server.json"
PORT="${BOARD_PORT:-8765}"
CLAUDE_SETTINGS="${HARNESS_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
HOOK_COPY="$BOARD_DIR/bin/permission-hook.py"
HOOK_TIMEOUT=3600

usage() {
  cat >&2 <<'EOF'
usage: board.sh [open] [--no-browser]   서버가 떠 있으면 그 주소를, 없으면 띄운 뒤 주소를 연다
       board.sh stop                    서버를 끈다
       board.sh status                  떠 있는지와 주소
       board.sh hook on|off|status      권한 요청 훅(~/.claude/settings.json PermissionRequest) 연결
env:   BOARD_PORT (기본 8765), HARNESS_METRICS_DIR, HARNESS_CLAUDE_SETTINGS
EOF
  exit 2
}

die() { printf 'board: %s\n' "$*" >&2; exit 1; }

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
  die "BOARD_PORT가 포트 번호가 아님: $PORT"
fi

conf_field() { jq -r --arg k "$1" '.[$k] // empty | tostring' "$CONF" 2>/dev/null || true; }

# server.json의 pid가 살아 있고 그 프로세스가 보드 서버일 때만 참. pid 재사용으로 남의 프로세스를 보드로 착각하지 않게.
board_pid() {
  local pid
  [[ -f "$CONF" ]] || return 1
  pid="$(conf_field pid)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -o command= -p "$pid" 2>/dev/null | grep -q 'board-server\.py' || return 1
  printf '%s\n' "$pid"
}

port_busy() { # 127.0.0.1:port에 누가 받고 있으면 참
  python3 -I -c 'import socket, sys
s = socket.socket(); s.settimeout(1)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$1"
}

port_holder() { # 사람이 읽을 점유 프로세스 설명(알 수 없으면 빈 값)
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1 " (pid " $2 ")"; exit }'
}

open_browser() {
  [[ "${BOARD_NO_BROWSER:-0}" == 1 ]] && return 0
  if [[ "$(uname -s)" == Darwin ]] && command -v open >/dev/null 2>&1; then
    open "$1" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

running_json() { # pid reused
  jq -cn --argjson pid "$1" --argjson port "$(conf_field port)" --arg url "$(conf_field url)" --argjson reused "$2" \
    '{running: true, pid: $pid, port: $port, url: $url, reused: $reused}'
}

refresh_hook_copy() { # 훅을 연결해 둔 사용자만: 플러그인이 업데이트되면 복사본도 맞춘다
  [[ -f "$HOOK_COPY" ]] || return 0
  cmp -s "$DIR/permission-hook.py" "$HOOK_COPY" && return 0
  cp "$DIR/permission-hook.py" "$HOOK_COPY.tmp" && chmod 755 "$HOOK_COPY.tmp" && mv "$HOOK_COPY.tmp" "$HOOK_COPY"
}

command_open() {
  local browser=1 pid url holder i
  while (($#)); do
    case "$1" in
      --no-browser) browser=0 ;;
      *) usage ;;
    esac
    shift
  done
  mkdir -p "$BOARD_DIR"
  refresh_hook_copy || true
  if pid="$(board_pid)"; then
    url="$(conf_field url)"
    [[ -n "$url" ]] || die "보드 서버(pid $pid)가 떠 있지만 주소를 남기지 않는 이전 버전입니다. board.sh stop 뒤 다시 여세요."
    ((browser)) && open_browser "$url"
    running_json "$pid" true
    return 0
  fi
  if [[ -f "$CONF" ]]; then # 죽은 서버가 남긴 파일. 권한 훅이 엉뚱한 포트로 보내지 않게 지운다
    rm -f "$CONF"
  fi
  if port_busy "$PORT"; then
    holder="$(port_holder "$PORT")"
    die "포트 ${PORT}을 다른 프로세스${holder:+($holder)}가 쓰고 있어 띄우지 않았습니다. 그 프로세스를 끄거나 BOARD_PORT로 다른 포트를 정하세요."
  fi
  # lib.sh가 ~/.ai-harness/config의 HM_·HARNESS_ 키를 이 셸에 export했다. 그대로 물려주면 오래 떠 있는 서버와 그 자식
  # (autofix-auto.sh·status.sh·새 세션)이 띄운 시점의 값을 계속 보고, config에서 키를 지워도 반영되지 않는다.
  # 설정값(HM_*)은 서버와 자식이 config를 직접 읽으므로 config에서 온 HM_ 키는 빼고 띄운다. HARNESS_* 는 위치(데이터·세션 경로)라 그대로 둔다.
  local -a unset_cfg=()
  local key=""
  while IFS= read -r key; do
    [[ -n "$key" ]] && unset_cfg+=(-u "$key")
  done <<<"$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?(HM_[A-Z0-9_]*)=.*/\2/p' "$HM_DATA_DIR/config" 2>/dev/null | sort -u)"
  # 새 세션으로 떼어 띄운다: 이 명령을 부른 셸·에이전트 턴이 끝나도 서버는 남는다.
  env ${unset_cfg[@]+"${unset_cfg[@]}"} BOARD_PORT="$PORT" HARNESS_METRICS_DIR="$HM_DATA_DIR" python3 -I -c 'import subprocess, sys
log = open(sys.argv[2], "ab")
subprocess.Popen([sys.executable, "-B", sys.argv[1], "--no-open"], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                 start_new_session=True, close_fds=True)' "$DIR/board-server.py" "$BOARD_DIR/server.log"
  for ((i = 0; i < 100; i++)); do
    if pid="$(board_pid)" && [[ "$(conf_field port)" == "$PORT" && -n "$(conf_field url)" ]]; then
      url="$(conf_field url)"
      ((browser)) && open_browser "$url"
      running_json "$pid" false
      return 0
    fi
    sleep 0.1
  done
  die "서버가 뜨지 않았습니다. 로그: $BOARD_DIR/server.log — $(tail -n 3 "$BOARD_DIR/server.log" 2>/dev/null | tr '\n' ' ')"
}

command_stop() {
  local pid i
  if ! pid="$(board_pid)"; then
    rm -f "$CONF"
    jq -cn '{running: false, stopped: false}'
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for ((i = 0; i < 50; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && die "보드 서버(pid $pid)가 5초 안에 끝나지 않았습니다."
  rm -f "$CONF"
  jq -cn --argjson pid "$pid" '{running: false, stopped: true, pid: $pid}'
}

command_status() {
  local pid
  if pid="$(board_pid)"; then
    running_json "$pid" true
  else
    jq -cn --argjson port "$PORT" '{running: false, port: $port}'
  fi
}

# ---- 권한 훅 연결: /ai-harness:setup이 사용자에게 물은 뒤에만 부른다 ----
hook_command() { printf 'python3 "%s"' "$HOOK_COPY"; }

settings_ok() {
  [[ ! -f "$CLAUDE_SETTINGS" ]] || jq -e 'type == "object"' "$CLAUDE_SETTINGS" >/dev/null 2>&1 \
    || die "JSON 객체가 아니라 건드리지 않음: $CLAUDE_SETTINGS"
}

write_settings() { # jq 필터 [args...] — 바꾸기 전 백업을 남기고 원자적으로 바꾼다. 백업 경로를 출력
  local filter="$1" tmp backup=""
  shift
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  tmp="$CLAUDE_SETTINGS.tmp.$$"
  if [[ -f "$CLAUDE_SETTINGS" ]]; then
    backup="$CLAUDE_SETTINGS.bak-board-$(date +%Y%m%d%H%M%S)"
    cp -p "$CLAUDE_SETTINGS" "$backup"
    jq "$@" "$filter" "$CLAUDE_SETTINGS" >"$tmp"
    chmod "$(filemode "$CLAUDE_SETTINGS")" "$tmp" 2>/dev/null || true
  else
    jq -n "$@" "{} | $filter" >"$tmp"
  fi
  mv "$tmp" "$CLAUDE_SETTINGS"
  printf '%s' "$backup"
}

hook_state() { # → {installed, command, others}
  local cmd
  cmd="$(hook_command)"
  if [[ -f "$CLAUDE_SETTINGS" ]]; then
    jq -c --arg c "$cmd" '[.hooks.PermissionRequest[]?.hooks[]?.command? // empty] as $all
      | {installed: ($all | index($c) != null), command: $c,
         others: [$all[] | select(. != $c and test("permission-hook\\.py"))]}' "$CLAUDE_SETTINGS"
  else
    jq -cn --arg c "$cmd" '{installed: false, command: $c, others: []}'
  fi
}

command_hook() {
  local sub="${1:-status}" state backup
  settings_ok
  case "$sub" in
    status) hook_state ;;
    on)
      mkdir -p "$(dirname "$HOOK_COPY")"
      cp "$DIR/permission-hook.py" "$HOOK_COPY.tmp" && chmod 755 "$HOOK_COPY.tmp" && mv "$HOOK_COPY.tmp" "$HOOK_COPY"
      state="$(hook_state)"
      if jq -e '.installed' <<<"$state" >/dev/null; then
        jq -c '. + {action: "unchanged"}' <<<"$state"
        return 0
      fi
      backup="$(write_settings '.hooks.PermissionRequest = ((.hooks.PermissionRequest // []) + [{matcher: "*", hooks: [{type: "command", command: $c, timeout: $t}]}])' \
        --arg c "$(hook_command)" --argjson t "$HOOK_TIMEOUT")"
      hook_state | jq -c --arg b "$backup" '. + {action: "installed", backup: (if $b == "" then null else $b end)}'
      ;;
    off)
      state="$(hook_state)"
      if ! jq -e '.installed' <<<"$state" >/dev/null; then
        jq -c '. + {action: "unchanged"}' <<<"$state"
        return 0
      fi
      backup="$(write_settings '.hooks.PermissionRequest |= ([.[] | .hooks |= map(select(.command != $c)) | select((.hooks | length) > 0)])
        | if (.hooks.PermissionRequest | length) == 0 then del(.hooks.PermissionRequest) else . end
        | if (.hooks | length) == 0 then del(.hooks) else . end' --arg c "$(hook_command)")"
      rm -f "$HOOK_COPY"
      hook_state | jq -c --arg b "$backup" '. + {action: "removed", backup: $b}'
      ;;
    *) usage ;;
  esac
}

cmd="${1:-open}"
(($#)) && shift
case "$cmd" in
  open) command_open "$@" ;;
  stop) command_stop ;;
  status) command_status ;;
  hook) command_hook "$@" ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
