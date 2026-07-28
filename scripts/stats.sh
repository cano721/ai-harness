#!/usr/bin/env bash
# 사용: stats.sh [--days N] [--project 이름]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
DAYS=""; PROJECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
  esac
done
CUTOFF=""
if [[ -n "$DAYS" ]]; then
  [[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "잘못된 --days 값: $DAYS (숫자만)" >&2; exit 1; }
  CUTOFF="$(days_ago_iso "$DAYS")"
fi
shopt -s nullglob
files=("$HM_DATA_DIR"/events/*.jsonl)
[[ ${#files[@]} -eq 0 ]] && { echo "이벤트 없음 — backfill.sh 먼저 실행"; exit 1; }
cat "${files[@]}" | jq -s -r --arg cutoff "$CUTOFF" --arg project "$PROJECT" -f "$DIR/stats.jq"
