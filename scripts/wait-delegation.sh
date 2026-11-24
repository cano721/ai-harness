#!/usr/bin/env bash
# workspace 세션이 인계한 멤버 세션을 기다린다. 완료 파일만 보면 멤버가 승인·질문에서 멈춰도 알 수 없다
# (2026-11-14: 두 멤버가 brief 승인 게이트에서 70분 멈췄는데 완료 파일 대기는 아무 말이 없었다).
# 완료 파일이 생기거나, 멤버 터미널이 입력을 기다리거나, 화면이 오래 그대로거나, 터미널이 끝나면
# 바로 끝내고 이유와 마지막 화면을 찍는다. 백그라운드로 걸면 끝날 때의 알림이 그 이유를 실어 온다.
# --close 면 완료 뒤 멤버 탭을 닫는다. 대화형 세션은 일이 끝나도 입력 대기로 남아 세션당 수백 MB를 쥔다
# (2026-11-17: 끝난 세션 탭 십여 개·swap 27GB). 문서 규칙만으로는 오래 켠 조율 세션이 나중에 추가된 규칙을
# 읽지 못해 닫지 않았다 — 그래서 기다리는 스크립트가 닫는다.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: wait-delegation.sh --done <file> [--terminal <handle>] [options]

  --done <file>        멤버 세션이 끝날 때 쓰는 완료 파일
  --terminal <handle>  멤버 세션의 Orca 터미널 handle (전체 ID, term_<uuid>)
  --interval <s>       확인 간격 초 (기본 30)
  --input-idle <s>     입력 대기 화면이 이만큼 그대로면 awaiting_input (기본 120)
  --stall <s>          화면이 이만큼 그대로면 stalled (기본 600)
  --timeout <s>        이만큼 지나면 timeout, 0이면 무제한 (기본 0)
  --lines <n>          끝날 때 찍는 마지막 화면 줄 수 (기본 15)
  --close              완료 뒤 멤버 탭을 닫는다(--terminal 필요). 완료 파일이 미확인(PLACEHOLDER·진행 중·미확인·pending)
                       이거나 user_decision이면, 화면이 일하는 중(esc to interrupt·shell·monitor)이거나 질문 중이면 닫지 않는다
  --close-wait <s>     닫기 전 일하는 화면이 입력 대기로 돌아오길 기다리는 상한 초 (기본 300)

첫 줄은 'reason=<done|awaiting_input|stalled|exited|terminal_unavailable|timeout>'.
--close 면 done 뒤에 'closed=yes' 또는 'closed=no'와 'close_reason=<done_file_pending|user_decision|busy|awaiting_input|still_listed|terminal_unavailable>'.
종료 코드: done 0, awaiting_input 10, stalled 11, exited 12, terminal_unavailable 13, timeout 14, 사용법 오류 2.
EOF
  exit 2
}

done_file="" terminal="" interval=30 input_idle=120 stall=600 timeout=0 lines=15 close=0 close_wait=300
while [[ $# -gt 0 ]]; do
  case "$1" in
    --done) done_file="${2:-}"; shift 2 ;;
    --terminal) terminal="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --input-idle) input_idle="${2:-}"; shift 2 ;;
    --stall) stall="${2:-}"; shift 2 ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    --lines) lines="${2:-}"; shift 2 ;;
    --close) close=1; shift ;;
    --close-wait) close_wait="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage ;;
  esac
done
[[ -n "$done_file" ]] || usage
[[ $close -eq 0 || -n "$terminal" ]] || { printf -- '--close needs --terminal\n' >&2; usage; }
for n in "$interval" "$input_idle" "$stall" "$timeout" "$lines" "$close_wait"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { printf 'not a number: %s\n' "$n" >&2; usage; }
done
if [[ -n "$terminal" ]]; then
  command -v orca >/dev/null 2>&1 || { printf 'orca CLI not found; omit --terminal to wait on the file only\n' >&2; exit 2; }
  # 짧은 접두어(term_xxxxxxxx)는 나중에 terminal_handle_stale 로 읽기에 실패한다.
  [[ "$terminal" =~ ^term_[0-9a-fA-F-]{36}$ ]] \
    || printf 'warning: %s is not a full terminal handle (term_<uuid>); short handles go stale\n' "$terminal" >&2
fi

screen="" status=""
finish() { # reason code
  printf 'reason=%s\n' "$1"
  if [[ "$1" == "done" ]]; then
    printf 'done_file=%s\n' "$done_file"
    [[ $close -eq 0 ]] || close_member
  elif [[ -n "$terminal" ]]; then
    printf 'terminal=%s\n' "$terminal"
    if [[ -n "$screen" ]]; then
      printf -- '--- last screen ---\n'
      grep -v '^[[:space:]]*$' <<<"$screen" | tail -n "$lines" || true
    fi
  fi
  exit "$2"
}

read_screen() { # 성공하면 screen·status를 채운다
  local out
  out="$(orca terminal read --terminal "$terminal" --screen --json 2>&1)" || return 1
  jq -e '.ok == true' >/dev/null 2>&1 <<<"$out" || return 1
  screen="$(jq -r '(.result.terminal.tail // []) | join("\n")' <<<"$out")"
  status="$(jq -r '.result.terminal.status // "unknown"' <<<"$out")"
}

# Claude Code·Codex 가 사용자 입력을 기다릴 때 화면에 남기는 문구. 자유 입력 질문은 마지막 줄들의 물음표로 본다.
awaiting_input() {
  local tail_text
  tail_text="$(grep -v '^[[:space:]]*$' <<<"$screen" | tail -n 12 || true)"
  grep -Eqi 'Enter to (select|confirm)|Esc to cancel|to navigate|trust this folder|Do you want to|Would you like to|Allow (command|this)|Press enter to (confirm|approve)|\(y/n\)|❯ *(1\.|Yes|No)( |,|$)' <<<"$tail_text" && return 0
  grep -Eq '(\?|할까요|될까요|주세요|승인)[[:space:]]*$' <<<"$tail_text"
}

# 일하는 중인 화면: 턴 진행(esc to interrupt)이나 백그라운드 작업(shell·monitor)이 상태 줄에 있다.
busy() {
  grep -Eqi 'esc to interrupt|[0-9]+ shells?( still running)?|still running|monitor' <<<"$(grep -v '^[[:space:]]*$' <<<"$screen" | tail -n 6 || true)"
}
still_listed() { orca terminal list --json 2>/dev/null | grep -qF "$terminal"; }

no_close() { printf 'closed=no\nclose_reason=%s\n' "$1"; }
close_member() {
  # 완료 파일이 아직 열린 상태면(원격 CI 대기 등) 세션이 그것을 기다리는 중이다. user_decision은 사용자가 그 탭에서 잇는다.
  if grep -Eqi 'user_decision' "$done_file"; then no_close user_decision; return; fi
  if grep -Eqi 'PLACEHOLDER|진행 ?중|미확인|pending|in progress' "$done_file"; then no_close done_file_pending; return; fi
  local deadline=$(( $(date +%s) + close_wait ))
  while :; do
    read_screen || { no_close terminal_unavailable; return; }
    awaiting_input && { no_close awaiting_input; return; }
    busy || break
    [[ $(date +%s) -lt $deadline ]] || { no_close busy; return; }
    sleep "$interval"
  done
  # --tab 은 orca agent launch 로 띄운 탭에서 아무것도 닫지 않는다. 종료 코드는 닫혀도 오류일 수 있어 list 로 판정한다.
  orca terminal close --terminal "$terminal" >/dev/null 2>&1 || true
  sleep 1
  if still_listed; then no_close still_listed; else printf 'closed=yes\n'; fi
}

hash_of() { { shasum -a 256 2>/dev/null || sha256sum; } <<<"$1" | cut -d' ' -f1; }
# 입력창 아래(상태 표시줄의 경과 시간·비용)는 일이 멈춰도 바뀐다 — 화면 전체로 변화를 보면 stalled가 잡히지 않는다(#465).
# 입력창을 감싼 구분선 둘 중 위쪽 것 위의 내용만 본다. 구분선이 둘 미만이면 화면 전체.
content_of() {
  awk '{ line[NR] = $0; t = $0; gsub(/[[:space:]]/, "", t); u = t; gsub(/─|━|-/, "", u)
         if (t != "" && u == "" && length(t) >= 30) rule[++n] = NR }
       END { stop = (n >= 2) ? rule[n - 1] - 1 : NR; for (i = 1; i <= stop; i++) print line[i] }' <<<"$1"
}

start="$(date +%s)" last_hash="" changed_at="$start" failures=0
while :; do
  [[ -f "$done_file" ]] && finish "done" 0
  now="$(date +%s)"
  if [[ -n "$terminal" ]]; then
    if read_screen; then
      failures=0
      [[ "$status" == exited ]] && finish exited 12
      h="$(hash_of "$(content_of "$screen")")"
      [[ "$h" == "$last_hash" ]] || { last_hash="$h"; changed_at="$now"; }
      idle=$((now - changed_at))
      if [[ $idle -ge $input_idle ]] && awaiting_input; then finish awaiting_input 10; fi
      [[ $idle -ge $stall ]] && finish stalled 11
    else
      # 일시적인 실패는 넘기고, 이어지면 handle 이 낡았거나 터미널이 없어진 것으로 본다.
      failures=$((failures + 1))
      [[ $failures -ge 3 ]] && finish terminal_unavailable 13
    fi
  fi
  [[ $timeout -gt 0 && $((now - start)) -ge $timeout ]] && finish timeout 14
  sleep "$interval"
done
