#!/usr/bin/env bash
# SessionStart에서 호출. 마지막 backfill이 HM_BACKFILL_INTERVAL_HOURS(기본 24)보다 오래됐으면
# backfill을 세션과 분리된 저우선순위 프로세스로 띄운다.
# 터미널·탭을 그냥 닫은 세션은 SessionEnd가 실행되지 않아 이 경로로만 수집된다.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

INTERVAL_HOURS="${HM_BACKFILL_INTERVAL_HOURS:-24}"
[[ "$INTERVAL_HOURS" =~ ^[0-9]+$ ]] || INTERVAL_HOURS=24
(( INTERVAL_HOURS > 0 )) || exit 0
LOCK_DIR="$HM_DATA_DIR/.backfill-due.lock"

last_attempt="$(jq -r '.components.backfill.last_attempt_at // empty' "$HM_DATA_DIR/health.json" 2>/dev/null || true)"
if [[ -n "$last_attempt" ]]; then
  last_epoch="$(iso_to_epoch "$last_attempt")"
  if [[ "$last_epoch" =~ ^[0-9]+$ ]] && (( $(date +%s) - last_epoch < INTERVAL_HOURS * 3600 )); then
    exit 0
  fi
fi

if [[ "${1:-}" == "--worker" ]]; then
  hm_acquire_lock "$LOCK_DIR" 1 || exit 0
  trap 'hm_release_lock "$LOCK_DIR"' EXIT
  nice -n 10 "$DIR/backfill.sh" >/dev/null 2>&1 || true
  exit 0
fi

# 이미 도는 중이면 띄우지 않는다. 판정은 worker의 lock이 최종 보장한다.
if [[ -d "$LOCK_DIR" ]] && kill -0 "$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || echo x)" 2>/dev/null; then
  exit 0
fi
if [[ "${HM_BACKFILL_FOREGROUND:-0}" == "1" ]]; then
  "$DIR/backfill-due.sh" --worker
else
  nohup "$DIR/backfill-due.sh" --worker </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0
