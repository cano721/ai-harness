#!/usr/bin/env bash
# 백그라운드 Bash 명령의 감시자. 사용: background-watchdog.sh <에이전트 pid> "<hook 때 있던 자식 pid들>" <명령> <선점 디렉토리> [호출 id]
# background-watchdog-hook.sh가 띄운다. 에이전트의 자식으로 새로 뜬 프로세스 그룹 리더 중 인자에 명령 첫 줄이 든 것을
# 찾아, 그 그룹이 남아 있는 동안 지켜본다. 에이전트가 사라지면 그룹 전체(ppid 1로 떨어진 손자 worker 포함)를
# TERM → 최대 5초 → KILL로 끄고, 그룹이 비면 바로 끝난다. 감시자는 그룹 밖에 있어 리더 셸만 먼저 끝나도 감시가 이어진다.
# 찾지 못하면(권한 거부로 실행 안 됨, 형식이 다름, 리더가 곧바로 끝남) 아무것도 하지 않는다. setsid로 새 세션을 만든 자손은 그룹 밖이라 정리하지 못한다.
set -uo pipefail

[[ ($# == 4 || $# == 5) && "$1" =~ ^[0-9]+$ && "$1" -gt 1 ]] || exit 0
agent="$1"
before="$2"
command_text="$3"
claims="$4"
tool_use_id="${5:-}"
# 에이전트를 처음부터 볼 수 없으면(잠깐 떴다 사라진 래퍼 셸, 신호가 막힌 sandbox) 감시할 수 없다.
kill -0 "$agent" 2>/dev/null || exit 0
trap '' HUP INT

# Claude Code는 명령을 셸 인자 안에 eval '<명령>'으로 넣고 작은따옴표를 '"'"'로 바꾼다. 줄바꿈·탭 표기는 ps마다 달라
# 첫 줄의 탭 앞까지, 앞뒤 공백을 떼고 대조한다. 너무 짧으면(`cd x`, `(`) 다른 명령과 헷갈리므로 감시하지 않는다.
nl='
'
tab='	'
first="${command_text%%"$nl"*}"
first="${first%%"$tab"*}"
first="${first#"${first%%[![:space:]]*}"}"
first="${first%"${first##*[![:space:]]}"}"
first="${first:0:200}"
compact="${first//[[:space:]]/}"
((${#compact} >= 4)) || exit 0
sq="'"
quoted="${first//$sq/$sq\"$sq\"$sq}"

# 같은 명령을 동시에 띄운 감시자끼리 한 그룹을 나눠 갖지 않게 그룹 pid를 선점한다. 선점 디렉토리는 사용자 데이터 디렉토리 안의 내 것만 쓴다.
mkdir -p "$claims" 2>/dev/null || exit 0
[[ -O "$claims" && ! -L "$claims" ]] || exit 0

group=""
# 권한 확인을 기다리는 명령도 잡되, 거부된 명령을 오래 찾다가 나중 명령을 가로채지 않게 기한을 둔다.
deadline=$((SECONDS + 120))
while [[ -z "$group" ]]; do
  kill -0 "$agent" 2>/dev/null || exit 0
  ((SECONDS < deadline)) || exit 0
  while read -r pid ppid pgid args; do
    [[ "$ppid" == "$agent" && "$pid" == "$pgid" && "$before" != *" $pid "* ]] || continue
    [[ "$args" == *"$quoted"* || "$args" == *"$first"* ]] || continue
    mkdir "$claims/$pid" 2>/dev/null || continue
    group="$pid"
    break
  done <<<"$(ps -ww -A -o pid=,ppid=,pgid=,args= 2>/dev/null)"
  # 명령 셸은 hook 직후 뜬다 — 처음 5초는 촘촘히 본다. 명령 안에서 `&`로 띄우고 바로 끝나는 리더(수십 ms)는 잡지 못한다(실측):
  # 리더가 사라지면 남은 멤버를 이 명령과 이을 단서가 없고, 짐작으로 남의 그룹을 끄지 않는다.
  if [[ -z "$group" ]]; then
    if ((SECONDS < 5)); then sleep 0.1; else sleep 0.5; fi
  fi
done
# 선점 디렉토리에 호출 id를 남기면 무거운 명령 슬롯(heavy-slot-hook.sh)이 그룹이 사는 동안 슬롯을 쥔다.
[[ -z "$tool_use_id" ]] || printf '%s' "$tool_use_id" >"$claims/$group/tool_use_id" 2>/dev/null
trap 'rm -f "$claims/$group/tool_use_id"; rmdir "$claims/$group" 2>/dev/null' EXIT

while kill -0 -- "-$group" 2>/dev/null; do
  if ! kill -0 "$agent" 2>/dev/null; then
    # 정상 종료에 몇 초 걸리는 명령(docker compose 등)을 위해 최대 5초 기다리고, 그룹이 비면 바로 끝낸다.
    kill -TERM -- "-$group" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
      kill -0 -- "-$group" 2>/dev/null || exit 0
      sleep 0.2
    done
    kill -KILL -- "-$group" 2>/dev/null
    exit 0
  fi
  sleep 1
done
exit 0
