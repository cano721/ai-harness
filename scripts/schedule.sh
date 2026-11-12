#!/usr/bin/env bash
# macOS launchd로 backfill-due.sh를 매시간 확인 실행한다. 세션을 새로 열지 않아도(긴 세션 하나만 켜 둬도)
# 수집·정리·자동 harvest가 HM_BACKFILL_INTERVAL_HOURS 주기로 돈다. SessionStart 경로와 주기·lock을 공유한다.
# HM_AUTOFIX_INTERVAL_MINUTES가 있으면 /autofix sweep만 그 분 주기로 부르는 LaunchAgent를 따로 둔다(backfill 주기와 별개).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

LABEL="com.ai-harness.backfill"
AGENTS_DIR="${HM_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTS_DIR/$LABEL.plist"
BIN_DIR="$HM_DATA_DIR/bin"
SHIM="$BIN_DIR/run-due.sh"
LOG_FILE="$HM_DATA_DIR/logs/launchd.log"
AF_LABEL="com.ai-harness.autofix"
AF_PLIST="$AGENTS_DIR/$AF_LABEL.plist"
AF_SHIM="$BIN_DIR/run-autofix.sh"
AF_LOG_FILE="$HM_DATA_DIR/logs/launchd-autofix.log"

usage() {
  cat >&2 <<'EOF'
usage: schedule.sh install | install-autofix | uninstall | status | run
  install    shim과 LaunchAgent를 만들고 등록한다 (매시간 확인, 실제 실행 주기는 HM_BACKFILL_INTERVAL_HOURS)
             HM_AUTOFIX_INTERVAL_MINUTES가 있으면 /autofix sweep 전용 LaunchAgent도 그 분 주기로 등록하고, 없으면 내린다
  install-autofix  autofix sweep 전용 LaunchAgent만 HM_AUTOFIX_INTERVAL_MINUTES에 맞춰 등록·해제한다
             (backfill은 그대로, 등록 즉시 실행하지 않음 — 보드 설정 변경용)
  uninstall  등록을 해제하고 파일을 지운다 (autofix 전용 포함)
  status     등록 상태와 마지막 backfill 시각, autofix 전용 주기
  run        지금 한 번 실행한다 (주기 판정은 그대로 적용)
EOF
  exit 2
}

use_launchctl() { [[ "${HM_SCHEDULE_NO_LAUNCHCTL:-0}" != "1" ]] && command -v launchctl >/dev/null 2>&1; }

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

# 플러그인을 업데이트하면 설치 경로(…/<version>/)가 바뀐다. shim은 실행 시점에 가장 새 설치본을 찾고,
# 없으면 install 때 기록한 경로(개발 체크아웃 등)를 쓴다.
write_shim() { # $1=shim 경로 $2=scripts/ 아래 실행 파일 $3=로그 파일 이름 [$4=실행 인자]
  mkdir -p "$BIN_DIR" "${LOG_FILE%/*}"
  printf '%s\n' "$ROOT" >"$BIN_DIR/plugin-root"
  sed -e "s|__SCRIPT__|$2|g" -e "s|__LOG__|$3|g" -e "s|__ARGS__|${4:+ $4}|g" >"$1" <<'SHIM'
#!/bin/bash
# ai-harness launchd shim — scripts/schedule.sh가 생성. 직접 고치지 말 것.
set -u
data_dir="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}"
plugins_home="${HM_PLUGIN_SEARCH_HOME:-$HOME}"
latest="$(for dir in "$plugins_home"/.claude/plugins/cache/ai-harness/ai-harness/*/ \
                    "$plugins_home"/.codex/plugins/cache/ai-harness/ai-harness/*/; do
  [[ -x "${dir}scripts/__SCRIPT__" ]] || continue
  version="${dir%/}"; version="${version##*/}"
  printf '%s\t%s\n' "$version" "${dir%/}"
done | sort -t$'\t' -k1,1V | tail -n 1)"
root="${latest#*$'\t'}"
[[ -n "$root" ]] || root="$(cat "$data_dir/bin/plugin-root" 2>/dev/null || true)"
[[ -x "$root/scripts/__SCRIPT__" ]] || { echo "$(date -u +%FT%TZ) ai-harness 설치본을 찾지 못함"; exit 0; }
log="$data_dir/logs/__LOG__"
if [[ -f "$log" ]] && (( $(wc -l <"$log") > 500 )); then
  tail -n 200 "$log" >"$log.tmp" && mv "$log.tmp" "$log"
fi
echo "$(date -u +%FT%TZ) run $root"
exec "$root/scripts/__SCRIPT__"__ARGS__
SHIM
  chmod 755 "$1"
}

write_plist() { # $1=plist $2=label $3=shim $4=StartInterval(초) $5=로그 [$6=추가 환경변수 XML] [$7=RunAtLoad true|false]
  local data_env="" run_at_load="  <key>RunAtLoad</key><true/>"
  [[ "${7:-true}" == true ]] || run_at_load=""
  mkdir -p "$AGENTS_DIR"
  if [[ -n "${HARNESS_METRICS_DIR:-}" ]]; then
    data_env="    <key>HARNESS_METRICS_DIR</key><string>$(xml_escape "$HARNESS_METRICS_DIR")</string>"
  fi
  cat >"$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$2</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$(xml_escape "$3")</string></array>
  <key>StartInterval</key><integer>$4</integer>
$run_at_load
  <!-- ProcessType=Background는 macOS가 CPU·IO를 크게 묶어 첫 전체 재추출이 1시간을 넘겼다. Nice·LowPriorityIO로 충분하다. -->
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <!-- 자동 harvest·autofix worker는 분리 실행되므로 이 작업이 끝나도 살려 둔다. -->
  <key>AbandonProcessGroup</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(xml_escape "$PATH")</string>
    <key>HOME</key><string>$(xml_escape "$HOME")</string>
${6:-}
    <!-- 한글 경로·문자열 길이 계산이 바이트 단위로 깨지지 않게 UTF-8 로캘을 준다. -->
    <key>LANG</key><string>en_US.UTF-8</string>
$data_env
  </dict>
  <key>StandardOutPath</key><string>$(xml_escape "$5")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$5")</string>
</dict>
</plist>
PLIST
  if command -v plutil >/dev/null 2>&1; then plutil -lint "$1" >/dev/null; fi
}

load_agent() { # $1=label $2=plist
  use_launchctl || return 0
  launchctl bootout "gui/$(id -u)/$1" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$2"
}
unload_agent() { # $1=label
  if use_launchctl; then launchctl bootout "gui/$(id -u)/$1" >/dev/null 2>&1 || true; fi
}

# autofix 전용 주기(분). 비었거나 0이면 빈 출력 — sweep은 backfill 주기에만 돈다(지금까지와 같다).
autofix_interval() {
  local v="${HM_AUTOFIX_INTERVAL_MINUTES:-}"
  [[ -n "$v" ]] || return 0
  [[ "$v" =~ ^[0-9]+$ ]] || { printf 'HM_AUTOFIX_INTERVAL_MINUTES는 분 단위 정수여야 합니다: %s\n' "$v" >&2; return 2; }
  (( 10#$v > 0 )) || return 0
  printf '%s\n' "$((10#$v))"
}

remove_autofix_agent() {
  unload_agent "$AF_LABEL"
  find "$AF_PLIST" "$AF_SHIM" -maxdepth 0 -type f -delete 2>/dev/null || true
}

# cron의 */N은 시·분 경계에서 다시 시작하므로 N이 60(분)·24(시)를 나누어떨어뜨릴 때만 정확히 N분 간격이다.
# 그 밖의 주기(45분, 90분 등)는 한 줄로 정확히 쓸 수 없어 systemd 타이머 예시를 안내한다.
autofix_cron_hint() { # $1=분
  local cron="" m="${1:-}"
  [[ -n "$m" ]] || return 0
  if (( m < 60 && 60 % m == 0 )); then cron="*/$m * * * *"
  elif (( m % 60 == 0 && 24 % (m / 60) == 0 )); then cron="0 */$(( m / 60 )) * * *"
  fi
  if [[ -n "$cron" ]]; then
    echo "  $cron $DIR/autofix-auto.sh sweep" >&2
  else
    echo "  (${m}분 주기는 cron 한 줄로 정확히 쓸 수 없습니다 — 60을 나누는 분(5·10·15·20·30)이나 24를 나누는 시간으로 고르거나," >&2
    echo "   systemd 타이머를 쓰세요: OnUnitActiveSec=${m}min, ExecStart=$DIR/autofix-auto.sh sweep)" >&2
  fi
}

# autofix 전용 에이전트를 주기에 맞춰 등록하거나(주기 있음) 내린다(주기 없음). $1=분(빈 값 = 없음) $2=RunAtLoad true|false
sync_autofix_agent() {
  if [[ -n "$1" ]]; then
    write_shim "$AF_SHIM" autofix-auto.sh "${AF_LOG_FILE##*/}" sweep
    write_plist "$AF_PLIST" "$AF_LABEL" "$AF_SHIM" "$(( $1 * 60 ))" "$AF_LOG_FILE" "" "$2"
    load_agent "$AF_LABEL" "$AF_PLIST"
    echo "설치: $AF_PLIST (/autofix sweep ${1}분마다, 로그 $AF_LOG_FILE)"
  elif [[ -f "$AF_PLIST" || -f "$AF_SHIM" ]]; then
    remove_autofix_agent
    echo "해제: $AF_LABEL (HM_AUTOFIX_INTERVAL_MINUTES 없음 — sweep은 backfill 주기에 돈다)"
  else
    echo "변경 없음: sweep 전용 주기 없음 — sweep은 backfill 주기에 돈다"
  fi
}

command_install() {
  local af_minutes=""
  af_minutes="$(autofix_interval)" || exit 2
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "launchd는 macOS 전용입니다. 다른 OS에서는 SessionStart 경로가 같은 주기로 돌고, 필요하면 cron에 다음을 등록하세요:" >&2
    echo "  0 * * * * HM_BACKFILL_FOREGROUND=1 $DIR/backfill-due.sh" >&2
    autofix_cron_hint "$af_minutes"
    exit 3
  fi
  write_shim "$SHIM" backfill-due.sh "${LOG_FILE##*/}"
  write_plist "$PLIST" "$LABEL" "$SHIM" 3600 "$LOG_FILE" "    <key>HM_BACKFILL_FOREGROUND</key><string>1</string>"
  load_agent "$LABEL" "$PLIST"
  echo "설치: $PLIST (매시간 확인, 실행 주기 ${HM_BACKFILL_INTERVAL_HOURS:-6}시간, 로그 $LOG_FILE)"
  if [[ -n "$af_minutes" ]]; then
    sync_autofix_agent "$af_minutes" true
  elif [[ -f "$AF_PLIST" || -f "$AF_SHIM" ]]; then
    sync_autofix_agent "" true
  fi
}

# 보드가 sweep 주기만 바꿀 때: autofix 전용 에이전트만 다루고(backfill 에이전트는 설치·재등록하지 않는다),
# 등록하자마자 sweep이 돌지 않게 RunAtLoad 없이 둔다 — 첫 sweep은 주기가 한 번 지난 뒤다.
command_install_autofix() {
  local af_minutes=""
  af_minutes="$(autofix_interval)" || exit 2
  if [[ "$(uname -s)" != "Darwin" ]]; then
    if [[ -n "$af_minutes" ]]; then
      echo "launchd는 macOS 전용입니다. 다른 OS에서는 cron에 다음을 등록하세요:" >&2
      autofix_cron_hint "$af_minutes"
    else
      echo "launchd는 macOS 전용입니다. 다른 OS에서는 cron에 둔 autofix-auto.sh sweep 줄을 지우세요" >&2
    fi
    exit 3
  fi
  sync_autofix_agent "$af_minutes" false
}

command_uninstall() {
  unload_agent "$LABEL"
  remove_autofix_agent
  find "$PLIST" "$SHIM" "$BIN_DIR/plugin-root" -maxdepth 0 -type f -delete 2>/dev/null || true
  echo "해제: $LABEL"
}

command_status() {
  local loaded="no" af="null" af_loaded="no" af_seconds=""
  if use_launchctl && launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then loaded="yes"; fi
  if [[ -f "$AF_PLIST" ]]; then
    if use_launchctl && launchctl print "gui/$(id -u)/$AF_LABEL" >/dev/null 2>&1; then af_loaded="yes"; fi
    af_seconds="$(sed -n 's|.*<key>StartInterval</key><integer>\([0-9]*\)</integer>.*|\1|p' "$AF_PLIST" | head -n 1)"
    af="$(jq -cn --arg plist "$AF_PLIST" --arg loaded "$af_loaded" --arg s "$af_seconds" \
      --arg last_run "$(grep ' run ' "$AF_LOG_FILE" 2>/dev/null | tail -n 1 | cut -d' ' -f1)" \
      '{installed:true, loaded:($loaded=="yes"), plist:$plist, interval_minutes:(($s | tonumber? // 0) / 60 | floor), last_launchd_run:$last_run}')"
  fi
  jq -cn --arg plist "$PLIST" --argjson installed "$([[ -f "$PLIST" ]] && echo true || echo false)" \
    --arg loaded "$loaded" --argjson autofix "$af" \
    --arg last_backfill "$(jq -r '.components.backfill.last_attempt_at // empty' "$HM_DATA_DIR/health.json" 2>/dev/null)" \
    --arg last_run "$(grep ' run ' "$LOG_FILE" 2>/dev/null | tail -n 1 | cut -d' ' -f1)" \
    '{installed:$installed, loaded:($loaded=="yes"), plist:$plist, last_launchd_run:$last_run, last_backfill:$last_backfill, autofix:$autofix}'
}

command_run() {
  if use_launchctl && launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    launchctl kickstart "gui/$(id -u)/$LABEL"
  else
    HM_BACKFILL_FOREGROUND=1 "$DIR/backfill-due.sh"
  fi
}

case "${1:-}" in
  install) command_install ;;
  install-autofix) command_install_autofix ;;
  uninstall) command_uninstall ;;
  status) command_status ;;
  run) command_run ;;
  *) usage ;;
esac
