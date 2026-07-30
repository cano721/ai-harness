#!/usr/bin/env bash
# Claude transcript 1개 → events/claude-<sid>.jsonl (덮어쓰기 = 멱등)
set -euo pipefail
T="${1:-}"; REASON="${2:-}"
[[ -f "$T" ]] || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"
SID="$(basename "$T" .jsonl)"
OUT="$HM_DATA_DIR/events/claude-${SID}.jsonl"
CWD="$(jq -Rrn 'first(inputs | fromjson? | select(.cwd? != null) | .cwd) // empty' "$T" 2>/dev/null || true)"
PROJECT="$(project_id_for_cwd "$CWD")"
# 백필 재추출 시 hook이 기록해둔 종료 사유(reason) 보존
if [[ -z "$REASON" && -f "$OUT" ]]; then
  REASON="$(jq -sr 'map(select(.kind=="session") | .reason // empty) | first // empty' "$OUT" 2>/dev/null || true)"
fi
# 임시파일을 대상과 같은 디렉토리에 — cross-device mv(비원자적 copy+delete) 방지
TMP="$(mktemp "$HM_DATA_DIR/events/.tmp.XXXXXX")"
# -R: 원시 라인 입력 — 손상된 JSONL 라인이 있어도 그 줄만 스킵 (extract-claude.jq의 fromjson?)
if jq -c -R -n --argjson event_version "$HM_EVENT_VERSION" \
     --arg sid "$SID" --arg path "$T" --arg reason "$REASON" --arg issue_re "$HM_ISSUE_RE" \
     --arg project "$PROJECT" \
     -f "$DIR/extract-claude.jq" "$T" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$OUT"
else
  rm -f "$TMP"
  echo "extract 실패: $T" >&2
  exit 1
fi
