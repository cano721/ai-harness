#!/usr/bin/env bash
# Claude Code 상태 표시줄 앞에 핸즈프리 듣기 상태를 붙인다.
# 원래 상태 표시줄 명령은 handsfree statusline 이 statusline.orig 에 보관해 두었고, 그 출력을 뒤에 그대로 잇는다.
set -euo pipefail

DATA="${HM_DATA_DIR:-$HOME/.ai-harness}/handsfree"
input="$(cat)"

base=""
if [[ -s "$DATA/statusline.orig" ]]; then
  base="$(printf '%s' "$input" | sh -c "$(<"$DATA/statusline.orig")" 2>/dev/null || true)"
fi

mark=""
pid="$(cat "$DATA/listener.pid" 2>/dev/null || true)"
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  until_at="$(cat "$DATA/paused" 2>/dev/null || true)"
  if [[ "$until_at" =~ ^[0-9]+$ ]] && ((until_at > $(date +%s))); then
    mark="⏸ 듣기 쉬는 중"
  elif [[ -n "${ORCA_TERMINAL_HANDLE:-}" ]] && grep -qF "\"current\": \"$ORCA_TERMINAL_HANDLE\"" "$DATA/state.json" 2>/dev/null; then
    mark="🎙 듣는 중 · 이 세션으로 입력"
  else
    mark="🎙 듣는 중 · 다른 세션"
  fi
fi

if [[ -n "$mark" && -n "$base" ]]; then
  printf '%s | %s\n' "$mark" "$base"
else
  printf '%s%s\n' "$mark" "$base"
fi
