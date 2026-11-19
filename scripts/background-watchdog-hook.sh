#!/usr/bin/env bash
# PreToolUse(Bash): run_in_background 명령마다 에이전트 생존 감시자(background-watchdog.sh)를 따로 띄운다(#423).
# 에이전트가 끝나도 백그라운드 dev 서버가 고아로 남지 않게 한다. 명령은 바꾸지 않는다 — updatedInput을 내면
# Claude Code가 바뀐 명령으로 권한을 다시 판정해 allow 규칙(Bash(npm run dev:*) 등)이 맞지 않게 된다(실측).
# 아무것도 출력하지 않는다. 끄기: HM_BACKGROUND_WATCHDOG=0. 어떤 오류든 그대로 통과(fail-open)한다.
set -uo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)" || exit 0
command_text="$(jq -er 'select(.tool_input.run_in_background == true) | .tool_input.command | strings' <<<"$input" 2>/dev/null)" || exit 0
[[ -n "${command_text//[[:space:]]/}" ]] || exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh" 2>/dev/null || exit 0
[[ "${HM_BACKGROUND_WATCHDOG:-1}" != 0 ]] || exit 0

# hook의 부모가 에이전트 프로세스다. 명령 셸은 이 hook이 끝난 뒤 에이전트의 자식으로 뜨므로,
# 지금 있는 자식을 적어 넘겨 감시자가 새로 뜬 셸만 고르게 한다.
agent="$PPID"
[[ "$agent" =~ ^[0-9]+$ && "$agent" -gt 1 ]] || exit 0
before=" "
while read -r pid ppid; do
  [[ "$ppid" == "$agent" ]] && before+="$pid "
done <<<"$(ps -A -o pid=,ppid= 2>/dev/null)"

# 감시자는 출력과 분리하고 자기 프로세스 그룹에서 띄운다 — 에이전트 그룹에 오는 신호(터미널 탭 닫기·Ctrl+C)와 무관하게 남아야 한다.
if command -v perl >/dev/null 2>&1; then
  perl -e 'setpgrp(0, 0); exec @ARGV' "$DIR/background-watchdog.sh" "$agent" "$before" "$command_text" "$HM_DATA_DIR/bg-watchdog" </dev/null >/dev/null 2>&1 &
else
  "$DIR/background-watchdog.sh" "$agent" "$before" "$command_text" "$HM_DATA_DIR/bg-watchdog" </dev/null >/dev/null 2>&1 &
fi
exit 0
