#!/usr/bin/env bash
# 수집·정리·자동 harvest의 단일 진입점. 에이전트 hook(SessionStart, 응답마다 Stop → tick.sh)이 부른다 —
# OS 스케줄러에 기대지 않아 macOS·Linux·Windows(WSL)와 Claude Code·Codex에서 똑같이 돈다.
# 마지막 backfill이 HM_BACKFILL_INTERVAL_HOURS(기본 6)보다 오래됐으면 저우선순위로
# backfill → (LLM 단계: 정리 → 자동 harvest·sync sweep → 자동 버그 수정) → 릴리스 정보 갱신을 한 번에 돈다.
# LLM 단계는 사용자가 쉬는 동안만 돈다(최근 활동이 없을 때까지 대기, 사용량 한도 직후엔 휴지).
# 여러 호출이 겹쳐도 주기 판정과 lock을 공유하므로 한 번만 돈다.
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

IDLE_MINUTES="${HM_IDLE_MINUTES:-20}"; [[ "$IDLE_MINUTES" =~ ^[0-9]+$ ]] || IDLE_MINUTES=20
IDLE_WAIT_HOURS="${HM_IDLE_WAIT_HOURS:-4}"; [[ "$IDLE_WAIT_HOURS" =~ ^[0-9]+$ ]] || IDLE_WAIT_HOURS=4
BACKOFF_HOURS="${HM_LLM_BACKOFF_HOURS:-5}"; [[ "$BACKOFF_HOURS" =~ ^[0-9]+$ ]] || BACKOFF_HOURS=5

recently_active() { hm_recently_active "$IDLE_MINUTES"; }
run_in_flight() {
  local lock="$HM_DATA_DIR/harvest-auto/running.lock"
  [[ -d "$lock" ]] && kill -0 "$(sed -n '1p' "$lock/pid" 2>/dev/null || echo x)" 2>/dev/null
}
in_usage_backoff() { hm_in_usage_backoff "$BACKOFF_HOURS"; }

# LLM 단계를 돌려도 되는지: 휴지 중이 아니고, 사용자가 쉬고 있을 때까지(최대 IDLE_WAIT_HOURS) 기다린다.
# 넘긴 이유는 SKIP_REASON에 남긴다 — worker는 출력을 버리므로 이 기록이 없으면 왜 안 돌았는지 알 수 없다.
SKIP_REASON=""
llm_steps_ready() {
  local deadline=0
  in_usage_backoff && { SKIP_REASON=usage_backoff; return 1; }
  # 무인 실행이 이미 돌고 있으면 이번 회차는 넘긴다 — 그 실행이 끝나면 sweep과 같은 순서로 다음 실행을 스스로 잇는다.
  run_in_flight && { SKIP_REASON=run_in_flight; return 1; }
  deadline=$(( $(date +%s) + IDLE_WAIT_HOURS * 3600 ))
  while recently_active; do
    (( $(date +%s) < deadline )) || { SKIP_REASON=never_idle; return 1; }
    sleep "${HM_IDLE_POLL_SECONDS:-300}"
  done
  # 기다리는 사이 시작된 무인 실행도 같다.
  run_in_flight && { SKIP_REASON=run_in_flight; return 1; }
  return 0
}

# 회차마다 LLM 단계를 돌렸는지·넘긴 이유를 한 줄 남긴다(최근 200줄).
WORKER_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# never_idle은 대기 상한 뒤에 기록되므로 회차 시작 시각(started_at)을 함께 남긴다.
schedule_log() { # $1=llm(ran|skipped|off) [$2=reason]
  local file="$HM_DATA_DIR/logs/schedule.jsonl"
  mkdir -p "${file%/*}" 2>/dev/null || return 0
  jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg st "$WORKER_STARTED_AT" --arg llm "$1" --arg reason "${2:-}" \
    '{at:$at,started_at:$st,llm:$llm} + (if $reason == "" then {} else {reason:$reason} end)' >>"$file" 2>/dev/null || return 0
  if (( $(wc -l <"$file") > 200 )); then
    tail -n 200 "$file" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file"
  fi
  return 0
}

if [[ "${1:-}" == "--worker" ]]; then
  hm_acquire_lock "$LOCK_DIR" 1 || exit 0
  trap 'hm_release_lock "$LOCK_DIR"' EXIT
  nice -n 10 "$DIR/backfill.sh" >/dev/null 2>&1 || true
  # LLM 단계는 새로 회수된 세션까지 반영된 뒤, 사용자가 쉬는 동안에만 돈다.
  if [[ "${HM_DIGEST:-0}" != "1" && "${HM_HARVEST_AUTO:-0}" != "1" && "${HM_SYNC_AUTO:-0}" != "1" && "${HM_AUTOFIX_AUTO:-0}" != "1" ]]; then
    schedule_log off
  elif llm_steps_ready; then
    schedule_log ran
    [[ "${HM_DIGEST:-0}" == "1" ]] && { nice -n 10 "$DIR/digest.sh" run >/dev/null 2>&1 || true; }
    "$DIR/harvest-auto.sh" sweep >/dev/null 2>&1 || true
    # 모니터링 기반 자동 수정: 검증(LLM 없음) 뒤, 무인 실행이 비어 있으면 새 에러 1건을 고친다.
    "$DIR/autofix-auto.sh" sweep >/dev/null 2>&1 || true
  else
    schedule_log skipped "$SKIP_REASON"
  fi
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
