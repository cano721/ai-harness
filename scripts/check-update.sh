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

now_epoch="$(date +%s)"
cached_epoch=0
cached_latest=""
cached_release_url=""
cached_notes_url=""
cached_result=""
if [[ -f "$state_file" ]]; then
  cached_epoch="$(jq -r '.checked_at_epoch // 0' "$state_file" 2>/dev/null || printf '0')"
  cached_latest="$(jq -r '.latest_version // empty' "$state_file" 2>/dev/null || true)"
  cached_release_url="$(jq -r '.release_url // empty' "$state_file" 2>/dev/null || true)"
  cached_notes_url="$(jq -r '.notes_url // empty' "$state_file" 2>/dev/null || true)"
  cached_result="$(jq -r '.last_result // empty' "$state_file" 2>/dev/null || true)"
fi
is_nonnegative_integer "$cached_epoch" || cached_epoch=0

write_state() {
  local latest="$1" release_url="$2" notes_url="$3" result="$4" error="${5:-}" checked_at
  local temp_file
  checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  temp_file="$(mktemp "$HM_DATA_DIR/.update-check.XXXXXX")"
  jq -cn \
    --arg installed_version "$installed_version" \
    --arg latest_version "$latest" \
    --arg release_url "$release_url" \
    --arg notes_url "$notes_url" \
    --arg last_result "$result" \
    --arg last_error "$error" \
    --arg checked_at "$checked_at" \
    --argjson checked_at_epoch "$now_epoch" \
    '{v:1, installed_version:$installed_version, latest_version:$latest_version,
      release_url:$release_url, notes_url:$notes_url, last_result:$last_result,
      last_error:$last_error, checked_at:$checked_at, checked_at_epoch:$checked_at_epoch}' >"$temp_file"
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
  '{installed_version:$installed_version, latest_version:$latest_version,
    update_available:$update_available, release_url:$release_url, notes_url:$notes_url,
    last_result:$last_result, last_error:$last_error}'
