#!/usr/bin/env bash
# 사용: stats.sh [--days N] [--project 이름] [--analysis-batch]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"
DAYS=""; PROJECT=""; ANALYSIS_BATCH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --analysis-batch) ANALYSIS_BATCH=1; shift ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
  esac
done
CUTOFF=""
if [[ -n "$DAYS" ]]; then
  [[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "잘못된 --days 값: $DAYS (숫자만)" >&2; exit 1; }
  CUTOFF="$(days_ago_iso "$DAYS")"
fi
shopt -s nullglob
files=()
if (( ANALYSIS_BATCH == 1 )); then
  [[ -n "$PROJECT" ]] || { echo "--analysis-batch에는 --project가 필요함" >&2; exit 1; }
  while IFS= read -r event_file; do
    case "$event_file" in
      "$HM_DATA_DIR/events/"*.jsonl) [[ -f "$event_file" ]] && files+=("$event_file") ;;
    esac
  done < <("$DIR/harvest-queue.sh" events --project "$PROJECT")
else
  files=("$HM_DATA_DIR"/events/*.jsonl)
  for rollup_file in "$HM_DATA_DIR"/rollups/*.jsonl; do
    # 명시적인 session 조회 등으로 상세 이벤트가 복원됐으면 원본을 우선해 중복 집계를 막는다.
    [[ -f "$HM_DATA_DIR/events/$(basename "$rollup_file")" ]] || files+=("$rollup_file")
  done
fi
[[ ${#files[@]} -eq 0 ]] && { echo "집계할 이벤트 없음"; exit 1; }
jq -s -r --arg cutoff "$CUTOFF" --arg project "$PROJECT" -f "$DIR/stats.jq" "${files[@]}"
