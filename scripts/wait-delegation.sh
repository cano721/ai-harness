#!/usr/bin/env bash
# workspace 세션이 인계한 멤버 세션을 기다린다. 완료 파일만 보면 멤버가 승인·질문에서 멈춰도 알 수 없다
# (2026-11-14: 두 멤버가 brief 승인 게이트에서 70분 멈췄는데 완료 파일 대기는 아무 말이 없었다).
# 완료 파일이 생기거나, 멤버 터미널이 입력을 기다리거나, 화면이 오래 그대로거나, 터미널이 끝나면
# 바로 끝내고 이유와 마지막 화면을 찍는다. 백그라운드로 걸면 끝날 때의 알림이 그 이유를 실어 온다.
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

첫 줄은 'reason=<done|awaiting_input|stalled|exited|terminal_unavailable|timeout>'.
종료 코드: done 0, awaiting_input 10, stalled 11, exited 12, terminal_unavailable 13, timeout 14, 사용법 오류 2.
EOF
  exit 2
}

done_file="" terminal="" interval=30 input_idle=120 stall=600 timeout=0 lines=15
while [[ $# -gt 0 ]]; do
  case "$1" in
    --done) done_file="${2:-}"; shift 2 ;;
    --terminal) terminal="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --input-idle) input_idle="${2:-}"; shift 2 ;;
    --stall) stall="${2:-}"; shift 2 ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    --lines) lines="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage ;;
  esac
done
[[ -n "$done_file" ]] || usage
for n in "$interval" "$input_idle" "$stall" "$timeout" "$lines"; do
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
  grep -Eqi 'Enter to select|to navigate|Do you want to|Would you like to|Allow (command|this)|Press enter to (confirm|approve)|\(y/n\)|❯ *1\. ' <<<"$tail_text" && return 0
  grep -Eq '(\?|할까요|될까요|주세요|승인)[[:space:]]*$' <<<"$tail_text"
}

hash_of() { { shasum -a 256 2>/dev/null || sha256sum; } <<<"$1" | cut -d' ' -f1; }

start="$(date +%s)" last_hash="" changed_at="$start" failures=0
while :; do
  [[ -f "$done_file" ]] && finish "done" 0
  now="$(date +%s)"
  if [[ -n "$terminal" ]]; then
    if read_screen; then
      failures=0
      [[ "$status" == exited ]] && finish exited 12
      h="$(hash_of "$screen")"
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
