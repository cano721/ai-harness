#!/usr/bin/env bash
# SessionStart 알림을 한 응답으로 합친다. 각 확인은 실패해도 세션을 막지 않는다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
input="$(cat)"
messages=()

update_result="$(printf '%s' "$input" | "$ROOT/scripts/check-update.sh" notify 2>/dev/null || true)"
update_message="$(jq -r '.systemMessage // empty' <<<"$update_result" 2>/dev/null || true)"
[[ -n "$update_message" ]] && messages+=("$update_message")

queue_result="$(printf '%s' "$input" | "$ROOT/scripts/harvest-queue.sh" notify 2>/dev/null || true)"
queue_message="$(jq -r '.systemMessage // empty' <<<"$queue_result" 2>/dev/null || true)"
[[ -n "$queue_message" ]] && messages+=("$queue_message")

if ((${#messages[@]} > 0)); then
  joined="$(IFS=$'\n'; printf '%s' "${messages[*]}")"
  jq -cn --arg systemMessage "$joined" '{systemMessage:$systemMessage}'
fi
