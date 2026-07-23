#!/usr/bin/env bash
# Claude transcript 1개 → events/claude-<sid>.jsonl (덮어쓰기 = 멱등)
set -euo pipefail
T="${1:-}"; REASON="${2:-}"
[[ -f "$T" ]] || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
SID="$(basename "$T" .jsonl)"
OUT="$HM_DATA_DIR/events/claude-${SID}.jsonl"
TMP="$(mktemp)"
if jq -c -n --arg sid "$SID" --arg path "$T" --arg reason "$REASON" \
     -f "$DIR/extract-claude.jq" "$T" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$OUT"
else
  rm -f "$TMP"
  echo "extract 실패: $T" >&2
  exit 1
fi
