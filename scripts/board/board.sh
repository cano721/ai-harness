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
LAUNCHER_APP="${BOARD_LAUNCHER_DIR:-$HOME/Applications}/Harness Board.app"
LAUNCHER_SHIM="$BOARD_DIR/bin/open-board"
LAUNCHER_ROOT_FILE="$BOARD_DIR/bin/plugin-root"
LAUNCHER_ID="com.ai-harness.board"
LAUNCHER_SRC="$BOARD_DIR/bin/launcher.applescript"

usage() {
  cat >&2 <<'EOF'
usage: board.sh [open] [--no-browser]   서버가 떠 있으면 그 주소를, 없으면 띄운 뒤 주소를 연다
       board.sh stop                    서버를 끈다(상주 세션 호스트는 그대로)
       board.sh host-stop               상주 세션 호스트를 끈다(대화 기록 유지, 다음 호스트가 같은 id로 이어 쥠)
       board.sh status                  떠 있는지와 주소
       board.sh hook on|off|status      권한 요청 훅(~/.claude/settings.json PermissionRequest) 연결
       board.sh launcher install|remove|status   눌러서 여는 macOS 앱(~/Applications/Harness Board.app)
env:   BOARD_PORT (기본 8765), BOARD_IDLE_EXIT (분, 기본 30, 0이면 끄지 않음), HARNESS_METRICS_DIR, HARNESS_CLAUDE_SETTINGS
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
  # 다른 플러그인 폴더(업데이트 전 버전)에서 뜬 서버는 새 버전 화면·버전 바뀜 안내(#439)를 못 보인다 — 끄고 이 버전으로 띄운다.
  # 상주 세션은 따로 사는 호스트(#364)가 쥐므로 보드를 다시 띄워도 이어진다.
  if pid="$(board_pid)" && [[ "$(conf_field root)" != "$DIR" ]]; then
    command_stop >/dev/null
  fi
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

# 상주 세션 호스트(#364)를 끈다: 호스트가 세션 stdin을 닫고 끝낸다(대화 기록 유지, 사람이 끝낸 것으로 기록하지 않음).
# 다음 호스트가 뜰 때(보드가 열려 있으면 곧바로) 같은 id로 --resume해 이어 쥔다. 이전 버전 호스트를 새 버전으로 바꿀 때 쓴다.
command_host_stop() {
  local info="$BOARD_DIR/host/host.json" pid i
  pid="$(jq -r '.pid // empty | tostring' "$info" 2>/dev/null || true)"
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null \
    || ! ps -o command= -p "$pid" 2>/dev/null | grep -q 'resident_host\.py'; then
    jq -cn '{host: false, stopped: false}'
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for ((i = 0; i < 100; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && die "상주 세션 호스트(pid $pid)가 10초 안에 끝나지 않았습니다."
  jq -cn --argjson pid "$pid" '{host: true, stopped: true, pid: $pid}'
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

# ---- 런처: /ai-harness:setup이 사용자에게 물은 뒤에만 부른다 ----
# 앱은 osacompile로 만든 stay-open AppleScript 애플릿이다(#363). 보드가 떠 있는 동안 Dock에 남고, Dock에서 종료하면
# 보드도 끄며, 보드가 다른 이유로 꺼지면 따라 끝난다. 셸 스크립트 실행 파일은 Apple 이벤트를 받지 못해 이렇게 할 수 없다.
# 앱은 고정 경로 shim만 부르고, shim이 실행할 때마다 가장 새 플러그인 설치본을 찾는다 — 플러그인을 업데이트해
# 설치 경로(…/<version>/)가 바뀌어도 앱을 다시 만들 필요가 없다. 찾지 못하면 install 때 기록한 경로(개발 체크아웃 등)를 쓴다.
# Finder로 연 앱은 PATH가 /usr/bin:/bin 뿐이라 jq·python3·claude를 못 찾으므로 install 때의 PATH를 shim에 담는다.
write_launcher_shim() { # $1=출력 경로
  {
    printf '#!/bin/bash\n# ai-harness Harness Board 런처 — scripts/board/board.sh launcher install이 생성. 직접 고치지 말 것.\nset -u\n'
    printf 'export PATH=%q"${PATH:+:$PATH}"\n' "$PATH"
    printf 'default_data=%q\n' "$HM_DATA_DIR"
    printf 'export HARNESS_METRICS_DIR="${HARNESS_METRICS_DIR:-$default_data}"\n'
    # Finder로 연 앱은 셸 환경을 물려받지 않는다. install 때 BOARD_IDLE_EXIT를 정했으면 그 값을 담는다.
    if [[ -n "${BOARD_IDLE_EXIT:-}" ]]; then printf 'export BOARD_IDLE_EXIT="${BOARD_IDLE_EXIT:-%s}"\n' "$(printf '%q' "$BOARD_IDLE_EXIT")"; fi
    cat <<'SHIM'
mode="${1:-open}" # open | alive(앱이 보드가 살아 있는지 확인: 0 살아 있음, 1 꺼짐, 2 확인 실패) | stop(앱을 종료할 때)
data_dir="$HARNESS_METRICS_DIR"
log="$data_dir/board/launcher.log"
if [[ -f "$log" ]] && (( $(wc -l <"$log") > 500 )); then
  tail -n 200 "$log" >"$log.tmp" && mv "$log.tmp" "$log"
fi
fail() { # 이유를 기록하고, 눈에 보이게 대화상자로 알린다(앱은 터미널이 없다)
  [[ "$mode" == open ]] || exit 2
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >>"$log" 2>/dev/null
  if [[ "${BOARD_NO_BROWSER:-0}" != 1 ]] && command -v osascript >/dev/null 2>&1; then
    osascript -e 'on run argv' -e 'display alert "Harness Board를 열지 못했습니다" message (item 1 of argv) as warning' -e 'end run' "$1" >/dev/null 2>&1
  fi
  exit 1
}
plugins_home="${HM_PLUGIN_SEARCH_HOME:-$HOME}"
latest="$(for dir in "$plugins_home"/.claude/plugins/cache/ai-harness/ai-harness/*/ \
                    "$plugins_home"/.codex/plugins/cache/ai-harness/ai-harness/*/; do
  [[ -f "${dir}scripts/board/board.sh" ]] || continue
  version="${dir%/}"; version="${version##*/}"
  printf '%s\t%s\n' "$version" "${dir%/}"
done | sort -t$'\t' -k1,1V | tail -n 1)"
root="${latest#*$'\t'}"
[[ -n "$root" ]] || root="$(cat "$data_dir/board/bin/plugin-root" 2>/dev/null)"
[[ -f "$root/scripts/board/board.sh" ]] || fail "ai-harness 설치본을 찾지 못했습니다. 플러그인을 다시 설치하거나 /ai-harness:board로 여세요."
case "$mode" in
  alive)
    # 꺼졌을 때만 1 — 플러그인 업데이트 중이라 확인을 못 한 것(2)으로 앱이 끝나면 Dock으로 끌 수 없는 서버가 남는다.
    state="$(bash "$root/scripts/board/board.sh" status 2>/dev/null)" || exit 2
    case "$state" in *'"running":true'*) exit 0 ;; *'"running":false'*) exit 1 ;; *) exit 2 ;; esac
    ;;
  stop) bash "$root/scripts/board/board.sh" stop >/dev/null 2>&1 ;;
  open)
    # 성공 출력에는 보드 주소(토큰)가 있어 남기지 않는다. 실패 이유(stderr)만 보인다.
    out="$(bash "$root/scripts/board/board.sh" open 2>&1 >/dev/null)" || fail "${out:-board.sh open 실패}"
    ;;
  *) exit 2 ;;
esac
SHIM
  } >"$1"
  chmod 755 "$1"
}

write_launcher_script() { # $1=출력 경로 $2=shim 경로
  local icon_sum quoted="${2//\\/\\\\}"
  quoted="${quoted//\"/\\\"}" # AppleScript 문자열 안의 \와 "를 이스케이프
  icon_sum="$(cksum <"$DIR/launcher-icon.py")"
  {
    printf -- '-- ai-harness Harness Board 런처 — scripts/board/board.sh launcher install이 생성. 직접 고치지 말 것.\n'
    # 앱 만드는 단계(write_launcher_app)를 바꾸면 build를 올린다 — 기존 앱이 다시 만들어진다.
    printf -- '-- build: 2, icon: %s\n' "${icon_sum%% *}"
    printf 'property shim : "%s"\n' "$quoted"
    cat <<'APPLESCRIPT'
property leaving : false

on run
	openBoard()
end run

-- 떠 있을 때 Dock 아이콘을 다시 누르면 보드 화면을 다시 연다.
on reopen
	openBoard()
end reopen

on openBoard()
	try
		do shell script "/bin/bash " & quoted form of shim
	on error
		-- 이유는 shim이 대화상자와 launcher.log로 이미 알렸다.
		set leaving to true
		quit
	end try
end openBoard

-- 보드가 자동 종료·board.sh stop으로 꺼지면(alive가 1) 앱도 끝난다. 확인 자체가 실패하면 다음 확인까지 기다린다.
on idle
	try
		do shell script "/bin/bash " & quoted form of shim & " alive"
	on error number code
		if code is 1 then
			set leaving to true
			quit
		end if
	end try
	return 10
end idle

-- Dock·메뉴에서 앱을 종료하면 보드 서버도 끈다.
on quit
	if not leaving then
		try
			do shell script "/bin/bash " & quoted form of shim & " stop"
		end try
	end if
	continue quit
end quit
APPLESCRIPT
  } >"$1"
}

write_launcher_app() { # $1=앱 경로 $2=AppleScript 소스
  local out
  # 성공해도 서명 교체 안내를 stderr에 찍으므로 실패할 때만 보인다.
  out="$(osacompile -s -o "$1" "$2" 2>&1)" || die "osacompile로 런처 앱을 만들지 못했습니다: $out"
  plutil -replace CFBundleIdentifier -string "$LAUNCHER_ID" "$1/Contents/Info.plist" || die "런처 앱 bundle id를 쓰지 못했습니다"
  python3 -I "$DIR/launcher-icon.py" "$1/Contents/Resources/applet.icns" || die "런처 앱 아이콘을 그리지 못했습니다"
  # Info.plist·아이콘을 바꿔 osacompile의 ad-hoc 서명이 깨졌으니 다시 서명한다(Apple Silicon은 서명 없는 실행 파일을 막는다).
  out="$(codesign --force -s - "$1" 2>&1)" || die "런처 앱을 서명하지 못했습니다: $out"
}

launcher_ours() { grep -q "<string>$LAUNCHER_ID</string>" "$LAUNCHER_APP/Contents/Info.plist" 2>/dev/null; }

launcher_json() { # action
  local installed=false
  launcher_ours && [[ -x "$LAUNCHER_SHIM" ]] && installed=true
  jq -cn --arg a "$1" --argjson i "$installed" --arg app "$LAUNCHER_APP" --arg shim "$LAUNCHER_SHIM" \
    '{installed: $i, app: $app, shim: $shim} + (if $a == "" then {} else {action: $a} end)'
}

command_launcher() {
  local sub="${1:-status}" plugin_root action=unchanged
  case "$sub" in
    status) launcher_json "" ;;
    install)
      [[ "${BOARD_LAUNCHER_PLATFORM:-$(uname -s)}" == Darwin ]] || die "런처 앱은 macOS에서만 만듭니다. 다른 OS에서는 /ai-harness:board 또는 board.sh open으로 여세요."
      if [[ -e "$LAUNCHER_APP" ]] && ! launcher_ours; then
        die "같은 이름의 다른 앱이 있어 건드리지 않았습니다: $LAUNCHER_APP"
      fi
      plugin_root="$(cd "$DIR/../.." && pwd)"
      mkdir -p "$BOARD_DIR/bin"
      # 새 앱은 같은 폴더에서 만든 뒤 이름만 바꿔 넣는다(다른 볼륨 사이 mv는 복사라 중간 상태가 남는다). 중단돼도 임시본은 지운다.
      mkdir -p "$(dirname "$LAUNCHER_APP")"
      rm -rf "$(dirname "$LAUNCHER_APP")"/.harness-board.new.* # 강제 종료로 남은 지난 임시본
      # osacompile은 이름이 .app으로 끝나야 애플릿을 만들고 앱 이름도 파일 이름에서 따므로, 임시 폴더 안에 같은 이름으로 만든다.
      stage="$(dirname "$LAUNCHER_APP")/.harness-board.new.$$"
      tmp="$stage/$(basename "$LAUNCHER_APP")"
      trap 'rm -rf "$stage" "$LAUNCHER_SHIM.tmp.$$" "$LAUNCHER_SRC.tmp.$$" "$LAUNCHER_APP.old.$$"' EXIT
      mkdir -p "$stage"
      write_launcher_shim "$LAUNCHER_SHIM.tmp.$$"
      write_launcher_script "$LAUNCHER_SRC.tmp.$$" "$LAUNCHER_SHIM"
      # 컴파일한 애플릿은 매번 바이트가 달라, 소스(shim·AppleScript·아이콘 생성기 체크섬)가 같고 애플릿이 있으면 그대로 둔다.
      if ! cmp -s "$LAUNCHER_SHIM.tmp.$$" "$LAUNCHER_SHIM" || ! cmp -s "$LAUNCHER_SRC.tmp.$$" "$LAUNCHER_SRC" \
        || ! launcher_ours || [[ ! -x "$LAUNCHER_APP/Contents/MacOS/applet" ]]; then
        write_launcher_app "$tmp" "$LAUNCHER_SRC.tmp.$$"
        mv "$LAUNCHER_SHIM.tmp.$$" "$LAUNCHER_SHIM"
        mv "$LAUNCHER_SRC.tmp.$$" "$LAUNCHER_SRC"
        if [[ -e "$LAUNCHER_APP" ]]; then mv "$LAUNCHER_APP" "$LAUNCHER_APP.old.$$"; fi
        mv "$tmp" "$LAUNCHER_APP"
        action=installed
      fi
      printf '%s\n' "$plugin_root" >"$LAUNCHER_ROOT_FILE"
      launcher_json "$action"
      ;;
    remove)
      if launcher_ours; then
        rm -rf "$LAUNCHER_APP"
        action=removed
      fi
      if [[ -f "$LAUNCHER_SHIM" || -f "$LAUNCHER_ROOT_FILE" || -f "$LAUNCHER_SRC" ]]; then
        rm -f "$LAUNCHER_SHIM" "$LAUNCHER_ROOT_FILE" "$LAUNCHER_SRC"
        action=removed
      fi
      launcher_json "$action"
      ;;
    *) usage ;;
  esac
}

cmd="${1:-open}"
(($#)) && shift
case "$cmd" in
  open) command_open "$@" ;;
  stop) command_stop ;;
  host-stop) command_host_stop ;;
  status) command_status ;;
  hook) command_hook "$@" ;;
  launcher) command_launcher "$@" ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
