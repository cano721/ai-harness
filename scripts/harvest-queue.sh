#!/usr/bin/env bash
# 세션별 압축 이벤트를 프로젝트 pending 큐에 넣고, 누적량 기준으로 harvest 준비 상태를 만든다.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

QUEUE_ROOT="$HM_DATA_DIR/harvest-queue"

threshold() {
  local value="$1" fallback="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

SESSION_THRESHOLD="$(threshold "${HM_HARVEST_SESSION_THRESHOLD:-10}" 10)"
CORRECTION_THRESHOLD="$(threshold "${HM_HARVEST_CORRECTION_THRESHOLD:-2}" 2)"
ERROR_THRESHOLD="$(threshold "${HM_HARVEST_ERROR_THRESHOLD:-5}" 5)"
THRESHOLDS="$(jq -cn \
  --argjson sessions "$SESSION_THRESHOLD" \
  --argjson corrections "$CORRECTION_THRESHOLD" \
  --argjson errors "$ERROR_THRESHOLD" \
  '{sessions:$sessions,corrections:$corrections,errors:$errors}')"

usage() {
  cat >&2 <<'EOF'
usage:
  harvest-queue.sh record <event-file>
  harvest-queue.sh import --project <project>
  harvest-queue.sh status --project <project>
  harvest-queue.sh events --project <project>
  harvest-queue.sh ack --project <project>
  harvest-queue.sh notify                 # SessionStart hook; stdin JSON의 cwd 사용
EOF
  exit 2
}

project_key() {
  # 항상 prefix를 붙여 '.', '..' 같은 프로젝트 인자가 queue root 밖을 가리키지 못하게 한다.
  printf 'p-%s\n' "$(printf '%s' "$1" | jq -sRr '@uri')"
}

queue_dir() {
  printf '%s/%s\n' "$QUEUE_ROOT" "$(project_key "$1")"
}

event_summary() {
  local event_file="$1"
  jq -sc --arg event_file "$event_file" '
    def total($kind):
      ([.[] | select(.kind == $kind) | (.n // 1)] | add // 0);
    (map(select(.kind == "session")) | first) as $session
    | if $session == null or ($session.project // "") == "" or ($session.sid // "") == "" then
        empty
      else
        {
          v: 1,
          project: $session.project,
          src: ($session.src // "unknown"),
          sid: $session.sid,
          event_file: $event_file,
          started: ($session.started // null),
          ended: ($session.ended // null),
          corrections: total("correction_mark"),
          errors: total("error")
        }
      end
  ' "$event_file" 2>/dev/null || true
}

record_summary() {
  local summary="$1" only_project="${2:-}"
  local project="" src="" sid="" marker="" qdir="" tmp=""
  project="$(printf '%s' "$summary" | jq -r '.project')"
  [[ -z "$only_project" || "$project" == "$only_project" ]] || return 0

  src="$(printf '%s' "$summary" | jq -r '.src')"
  sid="$(printf '%s' "$summary" | jq -r '.sid')"
  marker="$(printf '%s' "$src-$sid" | jq -sRr '@uri').json"
  qdir="$(queue_dir "$project")"
  mkdir -p "$qdir/sessions" "$qdir/seen"

  # 이미 분석 완료한 세션은 backfill/import가 다시 pending으로 되살리지 않는다.
  [[ -f "$qdir/seen/$marker" ]] && return 0

  tmp="$(mktemp "$qdir/sessions/.pending.XXXXXX")"
  printf '%s' "$summary" \
    | jq -c --arg marker "$marker" --arg queued_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {marker:$marker,queued_at:$queued_at}' >"$tmp"
  mv "$tmp" "$qdir/sessions/$marker"
}

record_one() {
  local event_file="$1" only_project="${2:-}" summary=""
  [[ -f "$event_file" ]] || return 0
  summary="$(event_summary "$event_file")"
  [[ -n "$summary" ]] || return 0
  record_summary "$summary" "$only_project"
}

pending_snapshot() {
  local project="$1" qdir="" files=()
  qdir="$(queue_dir "$project")"
  mkdir -p "$qdir/sessions" "$qdir/seen"

  shopt -s nullglob
  files=("$qdir/sessions"/*.json)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    jq -cn --arg project "$project" --argjson thresholds "$THRESHOLDS" '{
      project:$project,
      thresholds:$thresholds,
      counts:{sessions:0,corrections:0,errors:0},
      markers:[],
      event_files:[]
    }'
    return
  fi

  jq -sc --arg project "$project" --argjson thresholds "$THRESHOLDS" '{
    project:$project,
    thresholds:$thresholds,
    counts:{
      sessions:length,
      corrections:([.[].corrections] | add // 0),
      errors:([.[].errors] | add // 0)
    },
    markers:([.[].marker] | sort),
    event_files:([.[].event_file] | unique)
  }' "${files[@]}"
}

evaluate_ready() {
  local project="$1" qdir="" ready_file="" snapshot="" reasons="" candidate="" tmp=""
  qdir="$(queue_dir "$project")"
  ready_file="$qdir/ready.json"
  mkdir -p "$qdir/sessions" "$qdir/seen"

  if [[ -f "$ready_file" ]]; then
    jq -c '. + {ready:true,newly_ready:false}' "$ready_file"
    return
  fi

  snapshot="$(pending_snapshot "$project")"
  reasons="$(printf '%s' "$snapshot" | jq -c '[
    if .thresholds.sessions > 0 and .counts.sessions >= .thresholds.sessions then "sessions" else empty end,
    if .thresholds.corrections > 0 and .counts.corrections >= .thresholds.corrections then "corrections" else empty end,
    if .thresholds.errors > 0 and .counts.errors >= .thresholds.errors then "errors" else empty end
  ]')"

  if [[ "$(printf '%s' "$reasons" | jq 'length')" == "0" ]]; then
    printf '%s' "$snapshot" | jq -c '. + {ready:false,newly_ready:false,reasons:[]}'
    return
  fi

  candidate="$(printf '%s' "$snapshot" | jq -c \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson reasons "$reasons" \
    '. + {
      v:1,
      batch_id:(.markers | join(",")),
      ready:true,
      newly_ready:true,
      created_at:$created_at,
      reasons:$reasons
    }')"
  tmp="$(mktemp "$qdir/.ready.XXXXXX")"
  printf '%s\n' "$candidate" >"$tmp"

  # 같은 프로젝트의 종료 훅이 겹쳐도 첫 snapshot 하나만 ready batch가 된다.
  if ln "$tmp" "$ready_file" 2>/dev/null; then
    find "$tmp" -maxdepth 0 -type f -delete
    printf '%s\n' "$candidate"
  else
    find "$tmp" -maxdepth 0 -type f -delete
    jq -c '. + {ready:true,newly_ready:false}' "$ready_file"
  fi
}

parse_project() {
  [[ "${1:-}" == "--project" && -n "${2:-}" ]] || usage
  printf '%s\n' "$2"
}

command_record() {
  [[ -n "${1:-}" ]] || usage
  local summary project
  summary="$(event_summary "$1")"
  [[ -n "$summary" ]] || exit 0
  record_summary "$summary"
  project="$(printf '%s' "$summary" | jq -r '.project')"
  evaluate_ready "$project"
}

command_import() {
  local project="$1" event_file=""
  shopt -s nullglob
  local files=("$HM_DATA_DIR/events"/*.jsonl)
  shopt -u nullglob
  for event_file in "${files[@]}"; do
    record_one "$event_file" "$project"
  done
  evaluate_ready "$project"
}

command_events() {
  local project="$1" qdir="" ready_file="" marker=""
  qdir="$(queue_dir "$project")"
  ready_file="$qdir/ready.json"
  [[ -f "$ready_file" ]] || return 0
  while IFS= read -r marker; do
    case "$marker" in
      ""|*/*|..|../*|*/..) continue ;;
    esac
    [[ -f "$qdir/sessions/$marker" ]] || continue
    jq -r '.event_file' "$qdir/sessions/$marker"
  done < <(jq -r '.markers[]?' "$ready_file")
}

command_ack() {
  local project="$1" qdir="" ready_file="" marker="" ack_tmp=""
  qdir="$(queue_dir "$project")"
  ready_file="$qdir/ready.json"
  [[ -f "$ready_file" ]] || { evaluate_ready "$project"; return; }
  mkdir -p "$qdir/seen"

  while IFS= read -r marker; do
    case "$marker" in
      ""|*/*|..|../*|*/..) continue ;;
    esac
    [[ -f "$qdir/sessions/$marker" ]] || continue
    mv "$qdir/sessions/$marker" "$qdir/seen/$marker"
  done < <(jq -r '.markers[]?' "$ready_file")

  ack_tmp="$(mktemp "$qdir/.last-ack.XXXXXX")"
  jq -c --arg acknowledged_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {acknowledged_at:$acknowledged_at}' "$ready_file" >"$ack_tmp"
  mv "$ack_tmp" "$qdir/last-ack.json"
  find "$ready_file" -maxdepth 0 -type f -delete

  # ready batch가 만들어진 뒤 들어온 세션은 남긴다. 그 양도 기준을 넘으면 다음 batch를 즉시 만든다.
  evaluate_ready "$project"
}

command_notify() {
  local input="" cwd="" project="" status="" qdir="" notified_file="" batch_id="" previous="" message=""
  input="$(cat)"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
  [[ -n "$cwd" ]] || return 0
  project="$(project_id_for_cwd "$cwd")"
  [[ -n "$project" ]] || return 0

  status="$(evaluate_ready "$project")"
  [[ "$(printf '%s' "$status" | jq -r '.ready')" == "true" ]] || return 0
  qdir="$(queue_dir "$project")"
  notified_file="$qdir/notified-ready-batch"
  batch_id="$(printf '%s' "$status" | jq -r '.batch_id // .created_at // empty')"
  previous="$(test -f "$notified_file" && sed -n '1p' "$notified_file" || true)"
  [[ -z "$batch_id" || "$previous" != "$batch_id" ]] || return 0

  printf '%s\n' "$batch_id" >"$notified_file"
  message="$(printf '%s' "$status" | jq -r '
    "ai-harness: \(.project)에 분석할 활동이 충분히 쌓였습니다 "
    + "(세션 \(.counts.sessions), 교정 \(.counts.corrections), 오류 \(.counts.errors)). "
    + "/harvest \(.project)를 실행하세요."
  ')"
  jq -cn --arg message "$message" '{systemMessage:$message}'
}

command="${1:-}"
shift || true
case "$command" in
  record) command_record "${1:-}" ;;
  import) project="$(parse_project "${1:-}" "${2:-}")"; command_import "$project" ;;
  status) project="$(parse_project "${1:-}" "${2:-}")"; evaluate_ready "$project" ;;
  events) project="$(parse_project "${1:-}" "${2:-}")"; command_events "$project" ;;
  ack) project="$(parse_project "${1:-}" "${2:-}")"; command_ack "$project" ;;
  notify)
    # SessionStart를 깨뜨리지 않도록 알림 경로는 실패해도 조용히 성공한다.
    notification="$(command_notify 2>/dev/null || true)"
    [[ -n "$notification" ]] && printf '%s\n' "$notification"
    true
    ;;
  *) usage ;;
esac
