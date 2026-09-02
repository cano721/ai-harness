#!/usr/bin/env bash
# 세션별 압축 이벤트를 프로젝트 pending 큐에 넣고, 누적량 기준으로 analysis batch를 만든다.
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

positive_threshold() {
  local value="$1" fallback="$2"
  if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

SESSION_THRESHOLD="$(threshold "${HM_HARVEST_SESSION_THRESHOLD:-10}" 10)"
CORRECTION_THRESHOLD="$(threshold "${HM_HARVEST_CORRECTION_THRESHOLD:-2}" 2)"
CORRECTION_SESSION_THRESHOLD="$(threshold "${HM_HARVEST_CORRECTION_SESSION_THRESHOLD:-2}" 2)"
ERROR_THRESHOLD="$(threshold "${HM_HARVEST_ERROR_THRESHOLD:-5}" 5)"
ERROR_SESSION_THRESHOLD="$(threshold "${HM_HARVEST_ERROR_SESSION_THRESHOLD:-2}" 2)"
GUARD_THRESHOLD="$(threshold "${HM_HARVEST_GUARD_THRESHOLD:-3}" 3)"
GUARD_SESSION_THRESHOLD="$(threshold "${HM_HARVEST_GUARD_SESSION_THRESHOLD:-2}" 2)"
PERMISSION_THRESHOLD="$(threshold "${HM_HARVEST_PERMISSION_THRESHOLD:-3}" 3)"
PERMISSION_SESSION_THRESHOLD="$(threshold "${HM_HARVEST_PERMISSION_SESSION_THRESHOLD:-2}" 2)"
MAX_BATCH_SESSIONS="$(positive_threshold "${HM_HARVEST_MAX_BATCH_SESSIONS:-50}" 50)"
REMIND_HOURS="$(threshold "${HM_HARVEST_REMIND_HOURS:-24}" 24)"
THRESHOLDS="$(jq -cn \
  --argjson sessions "$SESSION_THRESHOLD" \
  --argjson corrections "$CORRECTION_THRESHOLD" \
  --argjson correction_sessions "$CORRECTION_SESSION_THRESHOLD" \
  --argjson errors "$ERROR_THRESHOLD" \
  --argjson error_sessions "$ERROR_SESSION_THRESHOLD" \
  --argjson guard_blocks "$GUARD_THRESHOLD" \
  --argjson guard_sessions "$GUARD_SESSION_THRESHOLD" \
  --argjson permission_denials "$PERMISSION_THRESHOLD" \
  --argjson permission_sessions "$PERMISSION_SESSION_THRESHOLD" \
  --argjson max_batch_sessions "$MAX_BATCH_SESSIONS" \
  '{
    sessions:$sessions,
    corrections:$corrections,
    correction_sessions:$correction_sessions,
    errors:$errors,
    error_sessions:$error_sessions,
    guard_blocks:$guard_blocks,
    guard_sessions:$guard_sessions,
    permission_denials:$permission_denials,
    permission_sessions:$permission_sessions,
    max_batch_sessions:$max_batch_sessions
  }')"

usage() {
  cat >&2 <<'EOF'
usage:
  harvest-queue.sh record <event-file>
  harvest-queue.sh import --project <project>
  harvest-queue.sh status --project <project>
  harvest-queue.sh events --project <project>
  harvest-queue.sh history --project <project>
  harvest-queue.sh mark-reviewed --project <project> [--outcome reviewed|improved|no-change]
      [--summary <text>] [--artifact <PR-or-reference>] [--expected <text>]
  harvest-queue.sh notify                 # SessionStart hook; stdin JSON의 cwd 사용
EOF
  exit 2
}

queue_dir() {
  printf '%s/%s\n' "$QUEUE_ROOT" "$(hm_project_key "$1")"
}

acquire_queue_lock() {
  local qdir="$1" lock_dir="$1/.queue-lock"
  mkdir -p "$qdir"
  hm_acquire_lock "$lock_dir" 50 || return 1
  printf '%s\n' "$lock_dir"
}

release_queue_lock() {
  hm_release_lock "$1"
}

migrate_legacy_state() {
  local project="$1" qdir="" legacy_file="" batch_file="" tmp=""
  qdir="$(queue_dir "$project")"
  legacy_file="$qdir/ready.json"
  batch_file="$qdir/analysis-batch.json"
  mkdir -p "$qdir/sessions" "$qdir/seen"

  # v0.9.0의 ready 용어를 v0.9.1 analysis batch 용어로 한 번만 이관한다.
  if [[ -f "$legacy_file" && ! -f "$batch_file" ]]; then
    tmp="$(mktemp "$qdir/.analysis-batch-migration.XXXXXX")"
    if jq -c '
      . as $legacy
      | del(.ready,.newly_ready)
      | . + {
          has_analysis_batch:($legacy.ready // true),
          new_analysis_batch:false
        }
    ' "$legacy_file" >"$tmp"; then
      mv "$tmp" "$batch_file"
      find "$legacy_file" -maxdepth 0 -type f -delete
    else
      find "$tmp" -maxdepth 0 -type f -delete
    fi
  fi

  if [[ -f "$qdir/notified-ready-batch" && ! -e "$qdir/notified-analysis-batch" ]]; then
    mv "$qdir/notified-ready-batch" "$qdir/notified-analysis-batch"
  elif [[ -f "$qdir/notified-ready-at" && ! -e "$qdir/notified-analysis-batch" ]]; then
    mv "$qdir/notified-ready-at" "$qdir/notified-analysis-batch"
  fi

  if [[ -f "$qdir/last-ack.json" && ! -f "$qdir/last-reviewed.json" ]]; then
    tmp="$(mktemp "$qdir/.last-reviewed-migration.XXXXXX")"
    if jq -c '
      . as $legacy
      | del(.acknowledged_at,.ready,.newly_ready)
      | . + {
          reviewed_at:($legacy.acknowledged_at // null),
          has_analysis_batch:false,
          new_analysis_batch:false
        }
    ' "$qdir/last-ack.json" >"$tmp"; then
      mv "$tmp" "$qdir/last-reviewed.json"
      find "$qdir/last-ack.json" -maxdepth 0 -type f -delete
    else
      find "$tmp" -maxdepth 0 -type f -delete
    fi
  fi
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
        (total("correction_mark")) as $corrections
        | (total("error")) as $errors
        | (total("guard_block")) as $guard_blocks
        | (total("permission_deny")) as $permission_denials
        | {
          v: 1,
          project: $session.project,
          src: ($session.src // "unknown"),
          sid: $session.sid,
          event_file: $event_file,
          started: ($session.started // null),
          ended: ($session.ended // null),
          source_mtime: ($session.source_mtime // 0),
          source_size: ($session.source_size // 0),
          corrections: $corrections,
          errors: $errors,
          guard_blocks: $guard_blocks,
          permission_denials: $permission_denials,
          totals: {
            corrections: $corrections,
            errors: $errors,
            guard_blocks: $guard_blocks,
            permission_denials: $permission_denials
          },
          event_revision: ({
            event_v: ($session.v // 0),
            ended: ($session.ended // null),
            turns: ($session.turns // 0),
            tok_in: ($session.tok_in // 0),
            tok_out: ($session.tok_out // 0),
            cache_read: ($session.cache_read // 0),
            cache_write: ($session.cache_write // 0),
            corrections: $corrections,
            errors: $errors,
            guard_blocks: $guard_blocks,
            permission_denials: $permission_denials
          } | tojson)
        }
      end
  ' "$event_file" 2>/dev/null || true
}

record_summary() {
  local summary="$1" only_project="${2:-}"
  local project="" src="" sid="" marker="" qdir="" tmp="" seen_file="" pending_file="" old=""
  local old_revision="" new_revision=""
  project="$(printf '%s' "$summary" | jq -r '.project')"
  [[ -z "$only_project" || "$project" == "$only_project" ]] || return 0

  src="$(printf '%s' "$summary" | jq -r '.src')"
  sid="$(printf '%s' "$summary" | jq -r '.sid')"
  marker="$(printf '%s' "$src-$sid" | jq -sRr '@uri').json"
  qdir="$(queue_dir "$project")"
  mkdir -p "$qdir/sessions" "$qdir/seen"
  seen_file="$qdir/seen/$marker"
  pending_file="$qdir/sessions/$marker"

  # 같은 세션을 재개할 수 있으므로 sid만으로 영구 제외하지 않는다. 마지막 검토 revision과
  # 같으면 멱등 no-op, 달라졌으면 누적 신호의 차분만 새 review unit으로 만든다.
  if [[ -f "$seen_file" ]]; then
    old="$(jq -c '.' "$seen_file" 2>/dev/null || printf '{}')"
    old_revision="$(printf '%s' "$old" | jq -r '.event_revision // empty')"
    new_revision="$(printf '%s' "$summary" | jq -r '.event_revision // empty')"
    if [[ -z "$old_revision" ]] && [[ "$(jq -nr --argjson current "$summary" --argjson old "$old" '
      def counters($x): ($x.totals // {
        corrections:($x.corrections // 0), errors:($x.errors // 0),
        guard_blocks:($x.guard_blocks // 0), permission_denials:($x.permission_denials // 0)
      });
      (($old.ended // null) == ($current.ended // null) and counters($old) == counters($current))
    ')" == "true" ]]; then
      tmp="$(mktemp "$qdir/seen/.revision-upgrade.XXXXXX")"
      jq -cn --argjson old "$old" --argjson current "$summary" '
        $old + {
          event_revision:$current.event_revision,
          totals:$current.totals,
          source_mtime:($current.source_mtime // 0),
          source_size:($current.source_size // 0)
        }
      ' >"$tmp"
      mv "$tmp" "$seen_file"
      RECORD_ACTION="unchanged"
      return 0
    fi
    if [[ -n "$new_revision" && "$new_revision" == "$old_revision" ]]; then
      RECORD_ACTION="unchanged"
      return 0
    fi
    RECORD_ACTION="resumed"
    summary="$(jq -cn --argjson current "$summary" --argjson old "$old" '
      def counters($x): ($x.totals // {
        corrections:($x.corrections // 0),
        errors:($x.errors // 0),
        guard_blocks:($x.guard_blocks // 0),
        permission_denials:($x.permission_denials // 0)
      });
      def delta($new; $previous): if ($new - $previous) > 0 then ($new - $previous) else 0 end;
      (counters($current)) as $new
      | (counters($old)) as $previous
      | $current + {
          corrections:delta($new.corrections; $previous.corrections),
          errors:delta($new.errors; $previous.errors),
          guard_blocks:delta($new.guard_blocks; $previous.guard_blocks),
          permission_denials:delta($new.permission_denials; $previous.permission_denials),
          totals:$new,
          baseline_totals:$previous,
          resumed:true,
          previous_event_revision:($old.event_revision // null)
        }
    ')"
  elif [[ -f "$pending_file" ]]; then
    old="$(jq -c '.' "$pending_file" 2>/dev/null || printf '{}')"
    old_revision="$(printf '%s' "$old" | jq -r '.event_revision // empty')"
    new_revision="$(printf '%s' "$summary" | jq -r '.event_revision // empty')"
    if [[ -n "$new_revision" && "$new_revision" == "$old_revision" ]]; then
      RECORD_ACTION="unchanged-pending"
      return 0
    fi
    RECORD_ACTION="updated-pending"
    summary="$(jq -cn --argjson current "$summary" --argjson old "$old" '
      def counters($x): ($x.totals // {
        corrections:($x.corrections // 0),
        errors:($x.errors // 0),
        guard_blocks:($x.guard_blocks // 0),
        permission_denials:($x.permission_denials // 0)
      });
      def zero: {corrections:0,errors:0,guard_blocks:0,permission_denials:0};
      def delta($new; $previous): if ($new - $previous) > 0 then ($new - $previous) else 0 end;
      (counters($current)) as $new
      | ($old.baseline_totals // zero) as $baseline
      | $current + {
          corrections:delta($new.corrections; $baseline.corrections),
          errors:delta($new.errors; $baseline.errors),
          guard_blocks:delta($new.guard_blocks; $baseline.guard_blocks),
          permission_denials:delta($new.permission_denials; $baseline.permission_denials),
          totals:$new,
          baseline_totals:$baseline,
          resumed:($old.resumed // false),
          previous_event_revision:($old.previous_event_revision // null)
        }
    ')"
  fi

  tmp="$(mktemp "$qdir/sessions/.pending.XXXXXX")"
  printf '%s' "$summary" \
    | jq -c --arg marker "$marker" --arg queued_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {marker:$marker,queued_at:$queued_at}' >"$tmp"
  mv "$tmp" "$qdir/sessions/$marker"
  # 새 revision의 pending marker가 durable해진 뒤 과거 seen marker를 제거한다.
  # 중간 중단 시 둘 다 남더라도 다음 record/mark-reviewed가 새 marker를 우선해 수렴한다.
  if [[ -f "$seen_file" ]]; then
    find "$seen_file" -maxdepth 0 -type f -delete
  fi
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
      counts:{
        sessions:0,
        corrections:0,
        correction_sessions:0,
        errors:0,
        error_sessions:0,
        guard_blocks:0,
        guard_sessions:0,
        permission_denials:0,
        permission_sessions:0
      },
      trigger_counts:{
        sessions:0,
        corrections:0,
        correction_sessions:0,
        errors:0,
        error_sessions:0,
        guard_blocks:0,
        guard_sessions:0,
        permission_denials:0,
        permission_sessions:0
      },
      pending_total_sessions:0,
      markers:[],
      event_files:[]
    }'
    return
  fi

  jq -sc --arg project "$project" --argjson thresholds "$THRESHOLDS" '
    def summarized($items): {
      sessions:($items | length),
      corrections:([$items[].corrections] | add // 0),
      correction_sessions:([$items[] | select(.corrections > 0)] | length),
      errors:([$items[].errors] | add // 0),
      error_sessions:([$items[] | select(.errors > 0)] | length),
      guard_blocks:([$items[].guard_blocks] | add // 0),
      guard_sessions:([$items[] | select(.guard_blocks > 0)] | length),
      permission_denials:([$items[].permission_denials] | add // 0),
      permission_sessions:([$items[] | select(.permission_denials > 0)] | length)
    };
    . as $all
    # batch cap 바깥의 신호가 영구히 가려지지 않도록 신호가 있는 review unit을 우선한다.
    | ($all | sort_by(
        (if ((.corrections + .errors + .guard_blocks + .permission_denials) > 0) then 0 else 1 end),
        (.queued_at // ""),
        (.ended // ""),
        .marker
      ) | .[0:$thresholds.max_batch_sessions]) as $selected
    | {
        project:$project,
        thresholds:$thresholds,
        counts:summarized($selected),
        trigger_counts:summarized($all),
        pending_total_sessions:($all | length),
        markers:([$selected[].marker] | sort),
        event_files:([$selected[].event_file] | unique)
      }
  ' "${files[@]}"
}

evaluate_analysis_batch() {
  local project="$1" qdir="" batch_file="" snapshot="" reasons="" stored="" response="" tmp=""
  qdir="$(queue_dir "$project")"
  batch_file="$qdir/analysis-batch.json"
  migrate_legacy_state "$project"

  if [[ -f "$batch_file" ]]; then
    jq -c '. + {has_analysis_batch:true,new_analysis_batch:false}' "$batch_file"
    return
  fi

  snapshot="$(pending_snapshot "$project")"
  reasons="$(printf '%s' "$snapshot" | jq -c '[
    if .thresholds.sessions > 0 and .pending_total_sessions >= .thresholds.sessions then "sessions" else empty end,
    if .thresholds.corrections > 0
      and .trigger_counts.corrections >= .thresholds.corrections
      and (.thresholds.correction_sessions == 0 or .trigger_counts.correction_sessions >= .thresholds.correction_sessions)
      then "corrections" else empty end,
    if .thresholds.errors > 0
      and .trigger_counts.errors >= .thresholds.errors
      and (.thresholds.error_sessions == 0 or .trigger_counts.error_sessions >= .thresholds.error_sessions)
      then "errors" else empty end,
    if .thresholds.guard_blocks > 0
      and .trigger_counts.guard_blocks >= .thresholds.guard_blocks
      and (.thresholds.guard_sessions == 0 or .trigger_counts.guard_sessions >= .thresholds.guard_sessions)
      then "guard_blocks" else empty end,
    if .thresholds.permission_denials > 0
      and .trigger_counts.permission_denials >= .thresholds.permission_denials
      and (.thresholds.permission_sessions == 0 or .trigger_counts.permission_sessions >= .thresholds.permission_sessions)
      then "permission_denials" else empty end
  ]')"

  if [[ "$(printf '%s' "$reasons" | jq 'length')" == "0" ]]; then
    printf '%s' "$snapshot" | jq -c '. + {has_analysis_batch:false,new_analysis_batch:false,reasons:[]}'
    return
  fi

  stored="$(printf '%s' "$snapshot" | jq -c \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson reasons "$reasons" \
    '. + {
      v:1,
      batch_id:(.markers | join(",")),
      has_analysis_batch:true,
      new_analysis_batch:false,
      created_at:$created_at,
      reasons:$reasons
    }')"
  response="$(printf '%s' "$stored" | jq -c '.new_analysis_batch = true')"
  tmp="$(mktemp "$qdir/.analysis-batch.XXXXXX")"
  printf '%s\n' "$stored" >"$tmp"

  # 같은 프로젝트의 종료 훅이 겹쳐도 첫 snapshot 하나만 analysis batch가 된다.
  if ln "$tmp" "$batch_file" 2>/dev/null; then
    find "$tmp" -maxdepth 0 -type f -delete
    printf '%s\n' "$response"
  else
    find "$tmp" -maxdepth 0 -type f -delete
    jq -c '. + {has_analysis_batch:true,new_analysis_batch:false}' "$batch_file"
  fi
}

parse_project() {
  [[ "${1:-}" == "--project" && -n "${2:-}" ]] || usage
  printf '%s\n' "$2"
}

REVIEW_PROJECT=""; REVIEW_OUTCOME="reviewed"; REVIEW_SUMMARY=""; REVIEW_ARTIFACT=""; REVIEW_EXPECTED=""
RECORD_ACTION="new"
parse_review_options() {
  while (( $# > 0 )); do
    case "$1" in
      --project) [[ -n "${2:-}" ]] || usage; REVIEW_PROJECT="$2"; shift 2 ;;
      --outcome) [[ -n "${2:-}" ]] || usage; REVIEW_OUTCOME="$2"; shift 2 ;;
      --summary) [[ -n "${2:-}" ]] || usage; REVIEW_SUMMARY="$2"; shift 2 ;;
      --artifact) [[ -n "${2:-}" ]] || usage; REVIEW_ARTIFACT="$2"; shift 2 ;;
      --expected) [[ -n "${2:-}" ]] || usage; REVIEW_EXPECTED="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "$REVIEW_PROJECT" ]] || usage
  case "$REVIEW_OUTCOME" in
    reviewed|improved|no-change) ;;
    *) echo "잘못된 --outcome: $REVIEW_OUTCOME" >&2; exit 2 ;;
  esac
}

command_record() {
  [[ -n "${1:-}" ]] || usage
  local summary project qdir lock_dir status
  summary="$(event_summary "$1")"
  [[ -n "$summary" ]] || exit 0
  project="$(printf '%s' "$summary" | jq -r '.project')"
  qdir="$(queue_dir "$project")"
  lock_dir="$(acquire_queue_lock "$qdir")" || return 1
  trap 'release_queue_lock "$lock_dir"' EXIT
  migrate_legacy_state "$project"
  record_summary "$summary"
  status="$(evaluate_analysis_batch "$project")"
  release_queue_lock "$lock_dir"
  trap - EXIT
  printf '%s' "$status" | jq -c --arg record_action "$RECORD_ACTION" '. + {record_action:$record_action}'
}

command_import() {
  local project="$1" event_file="" qdir="" lock_dir=""
  shopt -s nullglob
  local files=("$HM_DATA_DIR/events"/*.jsonl)
  shopt -u nullglob
  qdir="$(queue_dir "$project")"
  lock_dir="$(acquire_queue_lock "$qdir")" || return 1
  trap 'release_queue_lock "$lock_dir"' EXIT
  migrate_legacy_state "$project"
  for event_file in "${files[@]}"; do
    record_one "$event_file" "$project"
  done
  evaluate_analysis_batch "$project"
  release_queue_lock "$lock_dir"
  trap - EXIT
}

command_status() {
  local project="$1" qdir="" lock_dir=""
  qdir="$(queue_dir "$project")"
  lock_dir="$(acquire_queue_lock "$qdir")" || return 1
  trap 'release_queue_lock "$lock_dir"' EXIT
  evaluate_analysis_batch "$project"
  release_queue_lock "$lock_dir"
  trap - EXIT
}

command_events() {
  local project="$1" qdir="" batch_file="" marker="" lock_dir=""
  qdir="$(queue_dir "$project")"
  batch_file="$qdir/analysis-batch.json"
  lock_dir="$(acquire_queue_lock "$qdir")" || return 1
  trap 'release_queue_lock "$lock_dir"' EXIT
  migrate_legacy_state "$project"
  if [[ -f "$batch_file" ]]; then
    while IFS= read -r marker; do
      case "$marker" in
        ""|.|..|*/*) continue ;;
      esac
      [[ -f "$qdir/sessions/$marker" ]] || continue
      jq -r '.event_file' "$qdir/sessions/$marker"
    done < <(jq -r '.markers[]?' "$batch_file")
  fi
  release_queue_lock "$lock_dir"
  trap - EXIT
}

command_history() {
  local project="$1" qdir="" history_file="" lock_dir=""
  qdir="$(queue_dir "$project")"
  history_file="$qdir/review-history.jsonl"
  lock_dir="$(acquire_queue_lock "$qdir")" || return 1
  trap 'release_queue_lock "$lock_dir"' EXIT
  migrate_legacy_state "$project"
  if [[ -f "$history_file" ]]; then
    jq -c '.' "$history_file"
  fi
  release_queue_lock "$lock_dir"
  trap - EXIT
}

command_mark_reviewed() {
  local project="$1" outcome="${2:-reviewed}" summary="${3:-}" artifact="${4:-}" expected="${5:-}"
  local qdir="" batch_file="" marker="" reviewed_tmp="" lock_dir="" batch_id="" reviewed_at=""
  qdir="$(queue_dir "$project")"
  batch_file="$qdir/analysis-batch.json"
  mkdir -p "$qdir/sessions" "$qdir/seen"
  lock_dir="$(acquire_queue_lock "$qdir")" || {
    "$DIR/health.sh" failure harvest_queue review_lock_timeout >/dev/null 2>&1 || true
    return 1
  }
  trap 'release_queue_lock "$lock_dir"' EXIT
  migrate_legacy_state "$project"
  if [[ ! -f "$batch_file" ]]; then
    evaluate_analysis_batch "$project"
    release_queue_lock "$lock_dir"
    trap - EXIT
    "$DIR/health.sh" success harvest_queue >/dev/null 2>&1 || true
    return
  fi

  while IFS= read -r marker; do
    case "$marker" in
      ""|.|..|*/*) continue ;;
    esac
    [[ -f "$qdir/sessions/$marker" ]] || continue
    mv "$qdir/sessions/$marker" "$qdir/seen/$marker"
  done < <(jq -r '.markers[]?' "$batch_file")

  reviewed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reviewed_tmp="$(mktemp "$qdir/.last-reviewed.XXXXXX")"
  jq -c --arg reviewed_at "$reviewed_at" --arg outcome "$outcome" \
    --arg summary "$summary" --arg artifact "$artifact" --arg expected "$expected" '
      . + {
        reviewed_at:$reviewed_at,
        has_analysis_batch:false,
        new_analysis_batch:false,
        review:{
          outcome:$outcome,
          summary:(if $summary == "" then null else $summary[0:500] end),
          artifact:(if $artifact == "" then null else $artifact[0:2048] end),
          expected:(if $expected == "" then null else $expected[0:500] end)
        }
      }
    ' \
    "$batch_file" >"$reviewed_tmp"
  batch_id="$(jq -r '.batch_id' "$batch_file")"
  if [[ ! -f "$qdir/review-history.jsonl" ]] \
    || ! jq -e --arg batch_id "$batch_id" 'select(.batch_id == $batch_id)' \
      "$qdir/review-history.jsonl" >/dev/null 2>&1; then
    jq -c --arg reviewed_at "$reviewed_at" --arg outcome "$outcome" \
      --arg summary "$summary" --arg artifact "$artifact" --arg expected "$expected" '{
      v:1,
      project:.project,
      batch_id:.batch_id,
      created_at:.created_at,
      reviewed_at:$reviewed_at,
      counts:.counts,
      trigger_counts:(.trigger_counts // .counts),
      reasons:.reasons,
      markers:.markers,
      review:{
        outcome:$outcome,
        summary:(if $summary == "" then null else $summary[0:500] end),
        artifact:(if $artifact == "" then null else $artifact[0:2048] end),
        expected:(if $expected == "" then null else $expected[0:500] end)
      }
    }' "$batch_file" >>"$qdir/review-history.jsonl"
  fi
  mv "$reviewed_tmp" "$qdir/last-reviewed.json"
  find "$batch_file" -maxdepth 0 -type f -delete

  # analysis batch가 만들어진 뒤 들어온 세션은 남긴다. 그 양도 기준을 넘으면 다음 batch를 즉시 만든다.
  evaluate_analysis_batch "$project"
  release_queue_lock "$lock_dir"
  trap - EXIT
  "$DIR/health.sh" success harvest_queue >/dev/null 2>&1 || true
  if ! "$DIR/prune.sh" --project "$project" >/dev/null 2>&1; then
    "$DIR/health.sh" failure retention prune_failed >/dev/null 2>&1 || true
  fi
}

command_notify() {
  local input="" cwd="" project="" status="" qdir="" notified_file="" batch_id="" previous_batch=""
  local previous_at=0 now_epoch=0 remind_seconds=0 notify_tmp="" message="" lock_dir=""
  input="$(cat)"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
  [[ -n "$cwd" ]] || return 0
  project="$(project_id_for_cwd "$cwd")"
  [[ -n "$project" ]] || return 0

  qdir="$(queue_dir "$project")"
  lock_dir="$(acquire_queue_lock "$qdir")" || return 0
  trap 'release_queue_lock "$lock_dir"' EXIT
  status="$(evaluate_analysis_batch "$project")"
  if [[ "$(printf '%s' "$status" | jq -r '.has_analysis_batch')" != "true" ]]; then
    release_queue_lock "$lock_dir"
    trap - EXIT
    return 0
  fi
  notified_file="$qdir/notified-analysis-batch"
  batch_id="$(printf '%s' "$status" | jq -r '.batch_id // .created_at // empty')"
  if [[ -z "$batch_id" ]]; then
    release_queue_lock "$lock_dir"
    trap - EXIT
    return 0
  fi
  now_epoch="$(date +%s)"
  remind_seconds=$((REMIND_HOURS * 3600))
  if [[ -f "$notified_file" ]]; then
    previous_batch="$(jq -r '.batch_id // empty' "$notified_file" 2>/dev/null || sed -n '1p' "$notified_file")"
    previous_at="$(jq -r '.notified_at_epoch // 0' "$notified_file" 2>/dev/null || printf '0')"
  fi
  [[ "$previous_at" =~ ^[0-9]+$ ]] || previous_at=0
  if [[ "$previous_batch" == "$batch_id" ]]; then
    if ! (( REMIND_HOURS > 0 && now_epoch - previous_at >= remind_seconds )); then
      release_queue_lock "$lock_dir"
      trap - EXIT
      return 0
    fi
  fi

  notify_tmp="$(mktemp "$qdir/.notified-analysis-batch.XXXXXX")"
  jq -cn --arg batch_id "$batch_id" --argjson notified_at_epoch "$now_epoch" \
    --arg notified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{v:1,batch_id:$batch_id,notified_at:$notified_at,notified_at_epoch:$notified_at_epoch}' \
    >"$notify_tmp"
  mv "$notify_tmp" "$notified_file"
  message="$(printf '%s' "$status" | jq -r '
    "ai-harness: \(.project)에 분석할 활동 묶음이 쌓였습니다. "
    + "세션 \(.counts.sessions) · 교정 \(.counts.corrections) · 오류 \(.counts.errors)"
    + (if (.counts.guard_blocks // 0) > 0 then " · 차단 \(.counts.guard_blocks)" else "" end)
    + (if (.counts.permission_denials // 0) > 0 then " · 권한 거부 \(.counts.permission_denials)" else "" end)
    + ". "
    + "/harvest \(.project)를 실행하세요."
  ')"
  release_queue_lock "$lock_dir"
  trap - EXIT
  jq -cn --arg message "$message" '{systemMessage:$message}'
}

command="${1:-}"
shift || true
case "$command" in
  record) command_record "${1:-}" ;;
  import) project="$(parse_project "${1:-}" "${2:-}")"; command_import "$project" ;;
  status) project="$(parse_project "${1:-}" "${2:-}")"; command_status "$project" ;;
  events) project="$(parse_project "${1:-}" "${2:-}")"; command_events "$project" ;;
  history) project="$(parse_project "${1:-}" "${2:-}")"; command_history "$project" ;;
  mark-reviewed)
    parse_review_options "$@"
    command_mark_reviewed "$REVIEW_PROJECT" "$REVIEW_OUTCOME" "$REVIEW_SUMMARY" "$REVIEW_ARTIFACT" "$REVIEW_EXPECTED"
    ;;
  ack)
    project="$(parse_project "${1:-}" "${2:-}")"
    command_mark_reviewed "$project" reviewed "v0.9.0 ack compatibility" ""
    ;; # v0.9.0 호환
  notify)
    # SessionStart를 깨뜨리지 않도록 알림 경로는 실패해도 조용히 성공한다.
    notification="$(command_notify 2>/dev/null || true)"
    [[ -n "$notification" ]] && printf '%s\n' "$notification"
    true
    ;;
  *) usage ;;
esac
