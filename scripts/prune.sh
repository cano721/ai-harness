#!/usr/bin/env bash
# 검토 완료된 오래된 이벤트를 보관 정책에 따라 정리하고 seen marker는 tombstone으로 남긴다.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

PROJECT=""; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$PROJECT" ]] || { echo "--project가 필요함" >&2; exit 2; }

retention_days() {
  local value="$1" fallback="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then printf '%s\n' "$value"; else printf '%s\n' "$fallback"; fi
}

NORMAL_DAYS="$(retention_days "${HM_EVENT_RETENTION_DAYS:-180}" 180)"
SIGNAL_DAYS="$(retention_days "${HM_SIGNAL_EVENT_RETENTION_DAYS:-365}" 365)"
PROJECT_KEY="p-$(printf '%s' "$PROJECT" | jq -sRr '@uri')"
QUEUE_DIR="$HM_DATA_DIR/harvest-queue/$PROJECT_KEY"
ROLLUP_DIR="$HM_DATA_DIR/rollups"
NOW_EPOCH="$(date +%s)"
CHECKED=0; PRUNED=0; KEPT=0
mkdir -p "$ROLLUP_DIR"
shopt -s nullglob

write_tombstone() {
  local marker_file="$1" rollup_file="$2" tmp=""
  tmp="$(mktemp "$QUEUE_DIR/seen/.tombstone.XXXXXX")"
  jq -c --arg rollup_file "$rollup_file" --arg pruned_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    del(.event_file)
    | . + {rollup_file:$rollup_file,pruned_at:$pruned_at,event_pruned:true}
  ' "$marker_file" >"$tmp"
  mv "$tmp" "$marker_file"
}

for marker_file in "$QUEUE_DIR/seen"/*.json; do
  [[ -s "$marker_file" ]] || continue
  CHECKED=$((CHECKED + 1))
  event_file="$(jq -r '.event_file // empty' "$marker_file" 2>/dev/null || true)"
  case "$event_file" in
    "$HM_DATA_DIR/events/"*.jsonl) ;;
    *) KEPT=$((KEPT + 1)); continue ;;
  esac
  rollup_file="$ROLLUP_DIR/$(basename "$event_file")"
  if [[ ! -f "$event_file" ]]; then
    # 상세 삭제 뒤 tombstone 기록 전에 중단된 경우 다음 실행에서 상태 전환을 마무리한다.
    if [[ -f "$rollup_file" && "$DRY_RUN" == 0 ]]; then
      write_tombstone "$marker_file" "$rollup_file"
    else
      KEPT=$((KEPT + 1))
    fi
    continue
  fi

  signal_count="$(jq -r '[(.corrections // 0),(.errors // 0),(.guard_blocks // 0),(.permission_denials // 0)] | add' \
    "$marker_file" 2>/dev/null || printf '0')"
  if (( signal_count > 0 )); then keep_days="$SIGNAL_DAYS"; else keep_days="$NORMAL_DAYS"; fi
  (( keep_days > 0 )) || { KEPT=$((KEPT + 1)); continue; }
  event_time="$(iso_to_epoch "$(jq -r '.ended // empty' "$marker_file" 2>/dev/null || true)")"
  [[ -n "$event_time" ]] || event_time="$(mtime "$event_file")"
  [[ -n "$event_time" ]] || { KEPT=$((KEPT + 1)); continue; }
  if (( NOW_EPOCH - event_time < keep_days * 86400 )); then
    KEPT=$((KEPT + 1))
    continue
  fi

  if (( DRY_RUN == 1 )); then
    printf 'prune candidate: %s\n' "$event_file"
  else
    rollup_tmp="$(mktemp "$ROLLUP_DIR/.rollup.XXXXXX")"
    jq -c '
      if .kind == "session" then del(.transcript,.cwd)
      elif .kind == "correction_mark" then .target = "[reviewed]"
      else .
      end
    ' "$event_file" >"$rollup_tmp"
    mv "$rollup_tmp" "$rollup_file"
    # marker는 상세 삭제가 확인된 뒤에만 tombstone으로 바꾼다. 실패하면 원래 marker가
    # event_file을 계속 가리켜 다음 prune이 안전하게 재시도한다.
    if ! find "$event_file" -maxdepth 0 -type f -delete || [[ -e "$event_file" ]]; then
      echo "상세 이벤트 삭제 실패: $event_file" >&2
      exit 1
    fi
    write_tombstone "$marker_file" "$rollup_file"
  fi
  PRUNED=$((PRUNED + 1))
done

if (( DRY_RUN == 0 )); then
  "$DIR/health.sh" success retention >/dev/null 2>&1 || true
fi
jq -cn --arg project "$PROJECT" --argjson checked "$CHECKED" --argjson pruned "$PRUNED" \
  --argjson kept "$KEPT" --argjson dry_run "$DRY_RUN" \
  '{project:$project,checked:$checked,pruned:$pruned,kept:$kept,dry_run:($dry_run==1)}'
