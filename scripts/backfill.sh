#!/usr/bin/env bash
# 미처리/갱신된 transcript 전체 스캔 (Claude + Codex).
# - 이벤트 파일이 없거나 원본/추출기가 더 최신이거나 event version이 다르면 재추출 (멱등)
# - 진행 중 JSONL도 fromjson?로 불완전한 마지막 줄만 버릴 수 있으므로 즉시 처리
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"
done_n=0; skip_n=0; fail_n=0; cleanup_n=0
shopt -s nullglob

# v0.7.x에서 Codex SessionEnd hook이 Claude extractor를 호출해 만든 파생 유령 이벤트 정리.
for ghost in "$HM_DATA_DIR"/events/claude-rollout-*.jsonl; do
  if jq -e 'select(.kind=="session" and .src=="claude" and (.sid|startswith("rollout-")))' \
    "$ghost" >/dev/null 2>&1; then
    find "$ghost" -delete
    ((cleanup_n++))
  fi
done

process() { # $1=transcript $2=event파일 $3=extractor
  local t="$1" ev="$2" ex="$3"
  local mt="" ev_mt="" ev_v="0" dep="" dep_mt="" newest_dep=0
  mt="$(mtime "$t")"
  [[ -n "$mt" ]] || return

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
      return
    fi
  fi

  if "$DIR/$ex" "$t" 2>/dev/null; then ((done_n++)); else ((fail_n++)); fi
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

echo "백필 완료: 처리 $done_n, 스킵 $skip_n, 실패 $fail_n, 유령 정리 $cleanup_n"
