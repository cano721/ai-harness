#!/usr/bin/env bash
# hook/backfill 상태를 작은 로컬 JSON으로 기록한다. 사용자 작업을 막지 않도록 기록 실패는 호출자가 무시할 수 있다.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

HEALTH_FILE="$HM_DATA_DIR/health.json"
LOCK_DIR="$HM_DATA_DIR/.health-lock"

usage() {
  cat >&2 <<'EOF'
usage:
  health.sh success <component>
  health.sh failure <component> [message]
  health.sh status
EOF
  exit 2
}

acquire_lock() {
  local attempt=0 unowned_attempts=0 owner=""
  while (( attempt < 20 )); do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" >"$LOCK_DIR/pid"
      return 0
    fi
    if [[ -f "$LOCK_DIR/pid" ]]; then
      owner="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
    else
      owner=""
    fi
    if [[ ! "$owner" =~ ^[0-9]+$ ]]; then
      unowned_attempts=$((unowned_attempts + 1))
      if (( unowned_attempts >= 5 )); then
        find "$LOCK_DIR" -depth -delete 2>/dev/null || true
        unowned_attempts=0
      else
        sleep 0.02
        attempt=$((attempt + 1))
      fi
      continue
    fi
    unowned_attempts=0
    if ! kill -0 "$owner" 2>/dev/null; then
      find "$LOCK_DIR" -depth -delete 2>/dev/null || true
      continue
    fi
    sleep 0.02
    attempt=$((attempt + 1))
  done
  return 1
}

release_lock() {
  find "$LOCK_DIR" -depth -delete 2>/dev/null || true
}

record_health() {
  local result="$1" component="$2" message="${3:-}" current="{}" tmp=""
  [[ "$component" =~ ^[a-z0-9_-]+$ ]] || usage
  acquire_lock || return 0
  trap release_lock EXIT
  [[ -f "$HEALTH_FILE" ]] && current="$(jq -c '.' "$HEALTH_FILE" 2>/dev/null || printf '{}')"
  tmp="$(mktemp "$HM_DATA_DIR/.health.XXXXXX")"
  printf '%s' "$current" | jq -c \
    --arg component "$component" \
    --arg result "$result" \
    --arg message "$message" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      .v = 1
      | .components = (.components // {})
      | (.components[$component] // {}) as $old
      | .components[$component] = ($old + {
          last_attempt_at:$now,
          last_result:$result,
          success_count:(($old.success_count // 0) + (if $result == "success" then 1 else 0 end)),
          failure_count:(($old.failure_count // 0) + (if $result == "failure" then 1 else 0 end)),
          last_success_at:(if $result == "success" then $now else ($old.last_success_at // null) end),
          last_failure_at:(if $result == "failure" then $now else ($old.last_failure_at // null) end),
          last_error:(if $result == "failure" then $message else ($old.last_error // null) end)
        })
    ' >"$tmp"
  mv "$tmp" "$HEALTH_FILE"
  release_lock
  trap - EXIT
}

case "${1:-}" in
  success)
    [[ -n "${2:-}" ]] || usage
    record_health success "$2"
    ;;
  failure)
    [[ -n "${2:-}" ]] || usage
    record_health failure "$2" "${3:-unknown failure}"
    ;;
  status)
    if [[ -f "$HEALTH_FILE" ]]; then
      jq -c '.' "$HEALTH_FILE" 2>/dev/null || jq -cn '{v:1,components:{},corrupt:true}'
    else
      jq -cn '{v:1,components:{}}'
    fi
    ;;
  *) usage ;;
esac
