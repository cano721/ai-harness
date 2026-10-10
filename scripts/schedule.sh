#!/usr/bin/env bash
# macOS launchd로 backfill-due.sh를 매시간 확인 실행한다. 세션을 새로 열지 않아도(긴 세션 하나만 켜 둬도)
# 수집·정리·자동 harvest가 HM_BACKFILL_INTERVAL_HOURS 주기로 돈다. SessionStart 경로와 주기·lock을 공유한다.
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

usage() {
  cat >&2 <<'EOF'
usage: schedule.sh install | uninstall | status | run
  install    shim과 LaunchAgent를 만들고 등록한다 (매시간 확인, 실제 실행 주기는 HM_BACKFILL_INTERVAL_HOURS)
  uninstall  등록을 해제하고 파일을 지운다
  status     등록 상태와 마지막 backfill 시각
  run        지금 한 번 실행한다 (주기 판정은 그대로 적용)
EOF
  exit 2
}

use_launchctl() { [[ "${HM_SCHEDULE_NO_LAUNCHCTL:-0}" != "1" ]] && command -v launchctl >/dev/null 2>&1; }

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

# 플러그인을 업데이트하면 설치 경로(…/<version>/)가 바뀐다. shim은 실행 시점에 가장 새 설치본을 찾고,
# 없으면 install 때 기록한 경로(개발 체크아웃 등)를 쓴다.
write_shim() {
  mkdir -p "$BIN_DIR" "${LOG_FILE%/*}"
  printf '%s\n' "$ROOT" >"$BIN_DIR/plugin-root"
  cat >"$SHIM" <<'SHIM'
#!/bin/bash
# ai-harness launchd shim — scripts/schedule.sh가 생성. 직접 고치지 말 것.
set -u
data_dir="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}"
plugins_home="${HM_PLUGIN_SEARCH_HOME:-$HOME}"
latest="$(for dir in "$plugins_home"/.claude/plugins/cache/ai-harness/ai-harness/*/ \
                    "$plugins_home"/.codex/plugins/cache/ai-harness/ai-harness/*/; do
  [[ -x "${dir}scripts/backfill-due.sh" ]] || continue
  version="${dir%/}"; version="${version##*/}"
  printf '%s\t%s\n' "$version" "${dir%/}"
done | sort -t$'\t' -k1,1V | tail -n 1)"
root="${latest#*$'\t'}"
[[ -n "$root" ]] || root="$(cat "$data_dir/bin/plugin-root" 2>/dev/null || true)"
[[ -x "$root/scripts/backfill-due.sh" ]] || { echo "$(date -u +%FT%TZ) ai-harness 설치본을 찾지 못함"; exit 0; }
log="$data_dir/logs/launchd.log"
if [[ -f "$log" ]] && (( $(wc -l <"$log") > 500 )); then
  tail -n 200 "$log" >"$log.tmp" && mv "$log.tmp" "$log"
fi
echo "$(date -u +%FT%TZ) run $root"
exec "$root/scripts/backfill-due.sh"
SHIM
  chmod 755 "$SHIM"
}

write_plist() {
  local data_env=""
  mkdir -p "$AGENTS_DIR"
  if [[ -n "${HARNESS_METRICS_DIR:-}" ]]; then
    data_env="    <key>HARNESS_METRICS_DIR</key><string>$(xml_escape "$HARNESS_METRICS_DIR")</string>"
  fi
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$(xml_escape "$SHIM")</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <!-- ProcessType=Background는 macOS가 CPU·IO를 크게 묶어 첫 전체 재추출이 1시간을 넘겼다. Nice·LowPriorityIO로 충분하다. -->
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <!-- 자동 harvest worker는 분리 실행되므로 이 작업이 끝나도 살려 둔다. -->
  <key>AbandonProcessGroup</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(xml_escape "$PATH")</string>
    <key>HOME</key><string>$(xml_escape "$HOME")</string>
    <key>HM_BACKFILL_FOREGROUND</key><string>1</string>
$data_env
  </dict>
  <key>StandardOutPath</key><string>$(xml_escape "$LOG_FILE")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LOG_FILE")</string>
</dict>
</plist>
EOF
}

command_install() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "launchd는 macOS 전용입니다. 다른 OS에서는 SessionStart 경로가 같은 주기로 돌고, 필요하면 cron에 다음을 등록하세요:" >&2
    echo "  0 * * * * HM_BACKFILL_FOREGROUND=1 $DIR/backfill-due.sh" >&2
    exit 3
  fi
  write_shim
  write_plist
  if command -v plutil >/dev/null 2>&1; then plutil -lint "$PLIST" >/dev/null; fi
  if use_launchctl; then
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  fi
  echo "설치: $PLIST (매시간 확인, 실행 주기 ${HM_BACKFILL_INTERVAL_HOURS:-6}시간, 로그 $LOG_FILE)"
}

command_uninstall() {
  if use_launchctl; then launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true; fi
  find "$PLIST" "$SHIM" "$BIN_DIR/plugin-root" -maxdepth 0 -type f -delete 2>/dev/null || true
  echo "해제: $LABEL"
}

command_status() {
  local loaded="no"
  if use_launchctl && launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then loaded="yes"; fi
  jq -cn --arg plist "$PLIST" --argjson installed "$([[ -f "$PLIST" ]] && echo true || echo false)" \
    --arg loaded "$loaded" \
    --arg last_backfill "$(jq -r '.components.backfill.last_attempt_at // empty' "$HM_DATA_DIR/health.json" 2>/dev/null)" \
    --arg last_run "$(grep ' run ' "$LOG_FILE" 2>/dev/null | tail -n 1 | cut -d' ' -f1)" \
    '{installed:$installed, loaded:($loaded=="yes"), plist:$plist, last_launchd_run:$last_run, last_backfill:$last_backfill}'
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
  uninstall) command_uninstall ;;
  status) command_status ;;
  run) command_run ;;
  *) usage ;;
esac
