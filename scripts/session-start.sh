#!/usr/bin/env bash
# SessionStart 알림을 한 응답으로 합친다. 각 확인은 실패해도 세션을 막지 않는다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
input="$(cat)"
[[ "${HM_INTERNAL_SESSION:-}" == "1" ]] && exit 0
messages=()

update_result="$(printf '%s' "$input" | "$ROOT/scripts/check-update.sh" notify 2>/dev/null || true)"
update_message="$(jq -r '.systemMessage // empty' <<<"$update_result" 2>/dev/null || true)"
[[ -n "$update_message" ]] && messages+=("$update_message")

skew_result="$("$ROOT/scripts/check-update.sh" skew 2>/dev/null || true)"
skew_message="$(jq -r '.systemMessage // empty' <<<"$skew_result" 2>/dev/null || true)"
[[ -n "$skew_message" ]] && messages+=("$skew_message")

# 플러그인에는 설치 시점 hook이 없으므로 첫 세션에 한 번만 자동 업데이트를 켜는 법을 안내한다.
# 서드파티 마켓플레이스는 auto-update 기본값이 꺼져 있고 사용자만 켤 수 있다. Codex(rollout-*)에는 해당 설정이 없다.
hint_file="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/auto-update-hint-shown"
transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null || true)"
if [[ -n "$transcript" && "$(basename "$transcript")" != rollout-*.jsonl && ! -e "$hint_file" ]]; then
  if mkdir -p "${hint_file%/*}" 2>/dev/null && : >"$hint_file" 2>/dev/null; then
    messages+=("ai-harness 새 버전을 자동으로 받으려면 /plugin → Marketplaces → ai-harness → Enable auto-update 를 켜세요. (이 안내는 한 번만 표시됩니다)")
  fi
fi

"$ROOT/scripts/backfill-due.sh" >/dev/null 2>&1 || true

# macOS에서 정기 backfill(launchd)을 아직 등록하지 않았으면 한 번만 안내한다. 설치는 사용자가 직접 한다.
schedule_hint="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/schedule-hint-shown"
schedule_plist="${HM_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/com.ai-harness.backfill.plist"
if [[ "$(uname -s)" == "Darwin" && -n "$transcript" && "$(basename "$transcript")" != rollout-*.jsonl \
  && ! -e "$schedule_plist" && ! -e "$schedule_hint" ]]; then
  if mkdir -p "${schedule_hint%/*}" 2>/dev/null && : >"$schedule_hint" 2>/dev/null; then
    messages+=("ai-harness: 긴 세션 중에도 기록 수집·자동 개선이 주기대로 돌게 하려면 한 번 실행하세요: \"$ROOT/scripts/schedule.sh\" install (이 안내는 한 번만 표시됩니다)")
  fi
fi

queue_result="$(printf '%s' "$input" | "$ROOT/scripts/harvest-queue.sh" notify 2>/dev/null || true)"
queue_message="$(jq -r '.systemMessage // empty' <<<"$queue_result" 2>/dev/null || true)"
[[ -n "$queue_message" ]] && messages+=("$queue_message")

if ((${#messages[@]} > 0)); then
  joined="$(IFS=$'\n'; printf '%s' "${messages[*]}")"
  jq -cn --arg systemMessage "$joined" '{systemMessage:$systemMessage}'
fi
