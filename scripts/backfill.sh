#!/usr/bin/env bash
# 미처리/갱신된 transcript 전체 스캔 (Claude + Codex).
# - 이벤트 파일이 없거나 원본/추출기가 더 최신이거나 event version이 다르면 재추출 (멱등)
# - 진행 중 JSONL도 fromjson?로 불완전한 마지막 줄만 버릴 수 있으므로 즉시 처리
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"
done_n=0; skip_n=0; fail_n=0; cleanup_n=0; queue_n=0; queue_fail_n=0
shopt -s nullglob

# v0.7.x에서 Codex SessionEnd hook이 Claude extractor를 호출해 만든 파생 유령 이벤트 정리.
for ghost in "$HM_DATA_DIR"/events/claude-rollout-*.jsonl; do
  if jq -e 'select(.kind=="session" and .src=="claude" and (.sid|startswith("rollout-")))' \
    "$ghost" >/dev/null 2>&1; then
    find "$ghost" -delete
    ((cleanup_n++))
  fi
done

enqueue_event() {
  local ev="$1" queue_result="" action="" rollup="" rollup_tmp=""
  local source_mtime=0 source_size=0
  if [[ -f "$ev" ]] \
    && jq -e 'select(.kind=="session")' "$ev" >/dev/null 2>&1 \
    && queue_result="$("$DIR/harvest-queue.sh" record "$ev" 2>/dev/null)"; then
    ((queue_n++))
    action="$(printf '%s' "$queue_result" | jq -r '.record_action // empty' 2>/dev/null || true)"
    rollup="$HM_DATA_DIR/rollups/$(basename "$ev")"
    # mtime만 바뀐 동일 transcript를 확인하려 상세 이벤트를 잠시 복원했더라도,
    # revision이 같으면 기존 rollup을 유지하고 상세 복사본은 다시 제거한다.
    if [[ "$action" == "unchanged" && -f "$rollup" && -f "$ev" ]]; then
      source_mtime="$(jq -sr 'map(select(.kind=="session") | .source_mtime // 0) | first // 0' "$ev")"
      source_size="$(jq -sr 'map(select(.kind=="session") | .source_size // 0) | first // 0' "$ev")"
      rollup_tmp="$(mktemp "$HM_DATA_DIR/rollups/.rollup-source.XXXXXX")"
      jq -c --argjson source_mtime "$source_mtime" --argjson source_size "$source_size" '
        if .kind=="session" then .source_mtime=$source_mtime | .source_size=$source_size else . end
      ' "$rollup" >"$rollup_tmp"
      mv "$rollup_tmp" "$rollup"
      find "$ev" -maxdepth 0 -type f -delete
    fi
  else
    ((queue_fail_n++))
  fi
}

process() { # $1=transcript $2=event파일 $3=extractor
  local t="$1" ev="$2" ex="$3"
  local mt="" ev_mt="" ev_v="0" dep="" dep_mt="" newest_dep=0 rollup="" rollup_mt=""
  local source_mtime=0 source_size=0 current_size=0
  mt="$(mtime "$t")"
  [[ -n "$mt" ]] || return

  # 검토 완료 후 보관 정책으로 rollup된 세션은 extractor 변경만으로 상세 이벤트를 되살리지 않는다.
  # 단, 같은 세션 transcript가 실제로 갱신됐으면 재개된 세션이므로 다시 추출·큐 등록한다.
  rollup="$HM_DATA_DIR/rollups/$(basename "$ev")"
  if [[ ! -f "$ev" && -f "$rollup" ]]; then
    source_mtime="$(jq -sr 'map(select(.kind=="session") | .source_mtime // 0) | first // 0' "$rollup" 2>/dev/null || printf '0')"
    source_size="$(jq -sr 'map(select(.kind=="session") | .source_size // 0) | first // 0' "$rollup" 2>/dev/null || printf '0')"
    current_size="$(filesize "$t")"; current_size="${current_size:-0}"
    if (( source_mtime > 0 )) && [[ "$mt" == "$source_mtime" && "$current_size" == "$source_size" ]]; then
      ((skip_n++))
      return
    elif (( source_mtime == 0 )); then
      rollup_mt="$(mtime "$rollup")"
      if [[ -n "$rollup_mt" ]] && (( rollup_mt >= mt )); then
        ((skip_n++))
        return
      fi
    fi
  fi

  for dep in "$DIR/$ex" "$DIR/lib.sh"; do
    dep_mt="$(mtime "$dep")"
    [[ -n "$dep_mt" ]] && (( dep_mt > newest_dep )) && newest_dep="$dep_mt"
  done
  if [[ "$ex" == "extract-claude.sh" ]]; then
    dep_mt="$(mtime "$DIR/extract-claude.jq")"
    [[ -n "$dep_mt" ]] && (( dep_mt > newest_dep )) && newest_dep="$dep_mt"
  fi

  if [[ -f "$ev" ]]; then
    ev_mt="$(mtime "$ev")"
    ev_v="$(jq -sr 'map(select(.kind=="session")) | first | .v // 0' "$ev" 2>/dev/null || printf '0')"
    if [[ "$ev_v" == "$HM_EVENT_VERSION" && -n "$ev_mt" ]] \
      && (( ev_mt >= mt && ev_mt >= newest_dep )); then
      ((skip_n++))
      enqueue_event "$ev"
      return
    fi
  fi

  if "$DIR/$ex" "$t" 2>/dev/null; then
    ((done_n++))
    enqueue_event "$ev"
  else
    ((fail_n++))
  fi
}

for t in "$HM_CLAUDE_PROJECTS_DIR"/*/*.jsonl; do
  [[ -f "$t" ]] || continue
  process "$t" "$HM_DATA_DIR/events/claude-$(basename "$t" .jsonl).jsonl" extract-claude.sh
done

while IFS= read -r codex_root; do
  [[ -d "$codex_root" ]] || continue
  while IFS= read -r t; do
    sid="$(basename "$t" .jsonl | sed 's/^rollout-//')"
    process "$t" "$HM_DATA_DIR/events/codex-${sid}.jsonl" extract-codex.sh
  done < <(find "$codex_root" -name 'rollout-*.jsonl' -type f 2>/dev/null)
done < <(codex_session_roots)

if (( fail_n > 0 || queue_fail_n > 0 )); then
  "$DIR/health.sh" failure backfill "extract_${fail_n}_queue_${queue_fail_n}" >/dev/null 2>&1 || true
else
  "$DIR/health.sh" success backfill >/dev/null 2>&1 || true
fi
echo "백필 완료: 처리 $done_n, 스킵 $skip_n, 실패 $fail_n, 큐 $queue_n, 큐 실패 $queue_fail_n, 유령 정리 $cleanup_n"
