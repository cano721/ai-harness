#!/usr/bin/env bash
# 수집·정리·자동 harvest의 단일 진입점. launchd(scripts/schedule.sh, 매시간 확인)와 SessionStart가 부른다.
# 마지막 backfill이 HM_BACKFILL_INTERVAL_HOURS(기본 6)보다 오래됐으면 저우선순위로
# backfill → (opt-in) LLM 정리 → 자동 harvest sweep → 릴리스 정보 갱신을 한 번에 돈다.
# 두 호출 경로가 겹쳐도 주기 판정과 lock을 공유하므로 한 번만 돈다.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

INTERVAL_HOURS="${HM_BACKFILL_INTERVAL_HOURS:-6}"
[[ "$INTERVAL_HOURS" =~ ^[0-9]+$ ]] || INTERVAL_HOURS=6
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
  # opt-in LLM 정리는 새로 회수된 세션까지 반영된 뒤에 돈다.
  [[ "${HM_DIGEST:-0}" == "1" ]] && { nice -n 10 "$DIR/digest.sh" run >/dev/null 2>&1 || true; }
  "$DIR/harvest-auto.sh" sweep >/dev/null 2>&1 || true
  "$DIR/check-update.sh" refresh >/dev/null 2>&1 || true
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
