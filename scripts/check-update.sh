#!/usr/bin/env bash
# ai-harness 최신 릴리스 확인. 자동 설치는 절대 하지 않는다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

COMMAND="${1:-status}"
case "$COMMAND" in
  status|notify) ;;
  *)
    printf 'usage: %s [status|notify]\n' "${0##*/}" >&2
    exit 2
    ;;
esac

installed_version="$(jq -r '.version // empty' "$ROOT/.codex-plugin/plugin.json" 2>/dev/null || true)"
[[ -n "$installed_version" ]] || installed_version="$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)"
release_source="${HM_UPDATE_RELEASE_URL:-https://raw.githubusercontent.com/cano721/ai-harness/main/release.json}"
check_hours="${HM_UPDATE_CHECK_HOURS:-24}"
state_file="$HM_DATA_DIR/update-check.json"

is_nonnegative_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_nonnegative_integer "$check_hours" || check_hours=24

# 조회 실패는 성공 TTL과 분리된 짧은 백오프로 재시도한다. 0이면 백오프 없이 매번 재시도.
retry_minutes="${HM_UPDATE_RETRY_MINUTES:-15}"
retry_max_minutes="${HM_UPDATE_RETRY_MAX_MINUTES:-360}"
is_nonnegative_integer "$retry_minutes" || retry_minutes=15
is_nonnegative_integer "$retry_max_minutes" || retry_max_minutes=360
((retry_max_minutes < retry_minutes)) && retry_max_minutes="$retry_minutes"

now_epoch="$(date +%s)"
cached_epoch=0
cached_checked_at=""
cached_latest=""
cached_release_url=""
cached_notes_url=""
cached_result=""
cached_failure_count=0
cached_next_retry_epoch=0
if [[ -f "$state_file" ]]; then
  cached_epoch="$(jq -r '.checked_at_epoch // 0' "$state_file" 2>/dev/null || printf '0')"
  cached_checked_at="$(jq -r '.checked_at // empty' "$state_file" 2>/dev/null || true)"
  cached_latest="$(jq -r '.latest_version // empty' "$state_file" 2>/dev/null || true)"
  cached_release_url="$(jq -r '.release_url // empty' "$state_file" 2>/dev/null || true)"
  cached_notes_url="$(jq -r '.notes_url // empty' "$state_file" 2>/dev/null || true)"
  cached_result="$(jq -r '.last_result // empty' "$state_file" 2>/dev/null || true)"
  cached_failure_count="$(jq -r '.failure_count // 0' "$state_file" 2>/dev/null || printf '0')"
  cached_next_retry_epoch="$(jq -r '.next_retry_epoch // 0' "$state_file" 2>/dev/null || printf '0')"
fi
is_nonnegative_integer "$cached_epoch" || cached_epoch=0
is_nonnegative_integer "$cached_failure_count" || cached_failure_count=0
is_nonnegative_integer "$cached_next_retry_epoch" || cached_next_retry_epoch=0

# 성공한 조회만 checked_at(성공 TTL)을 갱신한다. 실패는 성공 캐시를 그대로 두고
# 별도의 짧은 백오프만 적립해, 일시적인 네트워크 오류가 하루치 알림을 삼키지 않게 한다.
write_state() {
  local latest="$1" release_url="$2" notes_url="$3" result="$4" error="${5:-}"
  local checked_at checked_epoch failure_count next_retry_epoch backoff cap attempt temp_file
  attempt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$result" == "success" ]]; then
    checked_at="$attempt"
    checked_epoch="$now_epoch"
    failure_count=0
    next_retry_epoch=0
  else
    checked_at="$cached_checked_at"
    checked_epoch="$cached_epoch"
    failure_count=$((cached_failure_count + 1))
    cap=$((retry_max_minutes * 60))
    backoff=$((retry_minutes * 60))
    local doubled=1
    while ((doubled < failure_count && backoff < cap)); do
      backoff=$((backoff * 2))
      doubled=$((doubled + 1))
    done
    ((backoff > cap)) && backoff="$cap"
    next_retry_epoch=$((now_epoch + backoff))
  fi
  temp_file="$(mktemp "$HM_DATA_DIR/.update-check.XXXXXX")"
  jq -cn \
    --arg installed_version "$installed_version" \
    --arg latest_version "$latest" \
    --arg release_url "$release_url" \
    --arg notes_url "$notes_url" \
    --arg last_result "$result" \
    --arg last_error "$error" \
    --arg checked_at "$checked_at" \
    --arg last_attempt_at "$attempt" \
    --argjson checked_at_epoch "$checked_epoch" \
    --argjson last_attempt_epoch "$now_epoch" \
    --argjson failure_count "$failure_count" \
    --argjson next_retry_epoch "$next_retry_epoch" \
    '{v:1, installed_version:$installed_version, latest_version:$latest_version,
      release_url:$release_url, notes_url:$notes_url, last_result:$last_result,
      last_error:$last_error, checked_at:$checked_at, checked_at_epoch:$checked_at_epoch,
      last_attempt_at:$last_attempt_at, last_attempt_epoch:$last_attempt_epoch,
      failure_count:$failure_count, next_retry_epoch:$next_retry_epoch}' >"$temp_file"
  mv "$temp_file" "$state_file"
}

version_is_newer() {
  local current="${1#v}" candidate="${2#v}" current_core candidate_core
  local current_pre="" candidate_pre="" i current_part candidate_part
  current="${current%%+*}"
  candidate="${candidate%%+*}"
  current_core="${current%%-*}"
  candidate_core="${candidate%%-*}"
  [[ "$current" == *-* ]] && current_pre="${current#*-}"
  [[ "$candidate" == *-* ]] && candidate_pre="${candidate#*-}"
  local IFS=.
  local -a current_parts candidate_parts
  read -r -a current_parts <<<"$current_core"
  read -r -a candidate_parts <<<"$candidate_core"
  for i in 0 1 2; do
    current_part="${current_parts[$i]:-0}"
    candidate_part="${candidate_parts[$i]:-0}"
    [[ "$current_part" =~ ^[0-9]+$ && "$candidate_part" =~ ^[0-9]+$ ]] || return 1
    if ((10#$candidate_part > 10#$current_part)); then return 0; fi
    if ((10#$candidate_part < 10#$current_part)); then return 1; fi
  done
  [[ -n "$current_pre" && -z "$candidate_pre" ]]
}

should_refresh=false
if [[ "${HM_UPDATE_CHECK_ENABLED:-1}" == "0" ]]; then
  should_refresh=false
elif [[ -z "$cached_latest" || "$cached_epoch" -le 0 ]]; then
  should_refresh=true
elif (( now_epoch - cached_epoch >= check_hours * 3600 )); then
  should_refresh=true
fi

# 직전 실패의 백오프가 남아 있으면 세션마다 재조회하지 않는다.
# check_hours=0(매 시작 확인)은 명시적 선택이므로 백오프를 적용하지 않는다.
if [[ "$should_refresh" == true ]] && ((check_hours > 0)) && ((now_epoch < cached_next_retry_epoch)); then
  should_refresh=false
fi

if [[ "$should_refresh" == true ]]; then
  if [[ ! "$release_source" =~ ^https:// ]]; then
    write_state "$cached_latest" "$cached_release_url" "$cached_notes_url" "failure" "release_url_must_use_https"
    cached_result="failure"
  elif ! command -v curl >/dev/null 2>&1; then
    write_state "$cached_latest" "$cached_release_url" "$cached_notes_url" "failure" "curl_unavailable"
    cached_result="failure"
  else
    response_file="$(mktemp "$HM_DATA_DIR/.update-release.XXXXXX")"
    if curl --fail --silent --show-error --location --connect-timeout 1 --max-time 2 \
      "$release_source" >"$response_file" 2>/dev/null; then
      latest="$(jq -r '.version // .tag_name // empty' "$response_file" 2>/dev/null || true)"
      latest="${latest#v}"
      release_url="$(jq -r '.release_url // .html_url // empty' "$response_file" 2>/dev/null || true)"
      notes_url="$(jq -r '.notes_url // .html_url // empty' "$response_file" 2>/dev/null || true)"
      if [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
        write_state "$latest" "$release_url" "$notes_url" "success"
        cached_latest="$latest"
        cached_release_url="$release_url"
        cached_notes_url="$notes_url"
        cached_result="success"
      else
        write_state "$cached_latest" "$cached_release_url" "$cached_notes_url" "failure" "invalid_release_metadata"
        cached_result="failure"
      fi
    else
      write_state "$cached_latest" "$cached_release_url" "$cached_notes_url" "failure" "release_fetch_failed"
      cached_result="failure"
    fi
    rm -f "$response_file"
  fi
fi

update_available=false
if [[ -n "$installed_version" && -n "$cached_latest" ]] && version_is_newer "$installed_version" "$cached_latest"; then
  update_available=true
fi

if [[ "$COMMAND" == "notify" ]]; then
  if [[ "$update_available" == true ]]; then
    jq -cn --arg installed "$installed_version" --arg latest "$cached_latest" --arg url "$cached_release_url" \
      '{systemMessage:("ai-harness " + $latest + " 업데이트가 있습니다 (현재 " + $installed + "). /harness-update 를 실행해 확인·업데이트하세요." + (if $url == "" then "" else " 릴리스: " + $url end))}'
  fi
  exit 0
fi

jq -cn \
  --arg installed_version "$installed_version" \
  --arg latest_version "$cached_latest" \
  --arg release_url "$cached_release_url" \
  --arg notes_url "$cached_notes_url" \
  --arg last_result "$cached_result" \
  --arg last_error "$(jq -r '.last_error // empty' "$state_file" 2>/dev/null || true)" \
  --argjson update_available "$update_available" \
  --argjson failure_count "$(jq -r '.failure_count // 0' "$state_file" 2>/dev/null || printf '0')" \
  --argjson next_retry_epoch "$(jq -r '.next_retry_epoch // 0' "$state_file" 2>/dev/null || printf '0')" \
  '{installed_version:$installed_version, latest_version:$latest_version,
    update_available:$update_available, release_url:$release_url, notes_url:$notes_url,
    last_result:$last_result, last_error:$last_error,
    failure_count:$failure_count, next_retry_epoch:$next_retry_epoch}'
