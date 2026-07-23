#!/usr/bin/env bash
# 미처리/갱신된 transcript 전체 스캔 (Claude + Codex).
# - 이벤트 파일이 없거나 원본이 더 최신이면 재추출 (멱등)
# - 최근 10분 내 수정 파일은 진행 중 세션으로 보고 스킵
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
now=$(date +%s); done_n=0; skip_n=0; fail_n=0

process() { # $1=transcript $2=event파일 $3=extractor
  local t="$1" ev="$2" ex="$3"
  local mt; mt=$(stat -f %m "$t" 2>/dev/null) || return
  (( now - mt < 600 )) && { ((skip_n++)); return; }
  if [[ -f "$ev" ]] && (( $(stat -f %m "$ev") >= mt )); then ((skip_n++)); return; fi
  if "$DIR/$ex" "$t" 2>/dev/null; then ((done_n++)); else ((fail_n++)); fi
}

for t in "$HOME"/.claude/projects/*/*.jsonl; do
  [[ -f "$t" ]] || continue
  process "$t" "$HM_DATA_DIR/events/claude-$(basename "$t" .jsonl).jsonl" extract-claude.sh
done

while IFS= read -r t; do
  sid="$(basename "$t" .jsonl | sed 's/^rollout-//')"
  process "$t" "$HM_DATA_DIR/events/codex-${sid}.jsonl" extract-codex.sh
done < <(find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' 2>/dev/null)

echo "백필 완료: 처리 $done_n, 스킵 $skip_n, 실패 $fail_n"
