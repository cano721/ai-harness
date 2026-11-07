#!/usr/bin/env bash
# 보드 버튼이 부르는 작업. 인자는 서버가 status.json 항목에서 만든 값만 받는다.
#   board-actions.sh harvest-now <project>
# 출력: 한 줄 JSON {ok, message}
set -uo pipefail

DATA="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}"
PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

reply() { jq -cn --argjson ok "$1" --arg m "$2" '{ok: $ok, message: $m}'; }

# 배치의 세션 기록에서 하네스가 있는 작업 경로를 고른다(harvest-auto.sh batch_origin의 단순판).
origin_of() {
  local batch=$1 ev cwd src root
  while IFS= read -r ev; do
    [ -f "$ev" ] || ev="$DATA/rollups/${ev##*/}"
    [ -f "$ev" ] || continue
    IFS=$'\t' read -r cwd src <<<"$(jq -r 'select(.kind=="session") | [(.cwd // ""), (.src // "claude")] | @tsv' "$ev" 2>/dev/null | head -n 1)"
    if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then continue; fi
    if [ -f "$cwd/.ai-harness/workspace.json" ]; then printf '%s\t%s\n' "$cwd" "$src"; return 0; fi
    root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$root" ] && [ -f "$root/.ai-harness/harness.json" ]; then printf '%s\t%s\n' "$cwd" "$src"; return 0; fi
  done < <(jq -r '.event_files[]?' "$batch")
  # 세션 worktree가 지워졌으면 같은 프로젝트의 지난 무인 실행이 쓴 저장소로.
  root=$(jq -r --arg p "$(jq -r .project "$batch")" 'select(.event == "started" and .project == $p and .repo != null) | .repo' \
    "$DATA/harvest-auto/runs.jsonl" 2>/dev/null | tail -n 1)
  if [ -n "$root" ] && [ -f "$root/.ai-harness/harness.json" ]; then printf '%s\t%s\n' "$root" claude; return 0; fi
  return 1
}

harvest_now() {
  local project=$1 batch="" b status origin cwd src marker before after_result reason
  for b in "$DATA"/harvest-queue/*/analysis-batch.json; do
    [ "$(jq -r '.project' "$b" 2>/dev/null)" = "$project" ] && { batch=$b; break; }
  done
  [ -n "$batch" ] || { reply false "$project 대기 batch를 찾지 못함"; return; }
  [ -x "$PLUGIN/scripts/harvest-auto.sh" ] || { reply false "설치된 ai-harness 플러그인을 찾지 못함"; return; }
  origin=$(origin_of "$batch") || { reply false "batch 세션에서 하네스 저장소를 찾지 못함"; return; }
  IFS=$'\t' read -r cwd src <<<"$origin"
  status=$(jq -c '. + {has_analysis_batch: true}' "$batch")
  marker="$(dirname "$batch")/auto-attempted-batch"
  before=$(jq -r '.at // ""' "$marker" 2>/dev/null || true)
  # 사람이 누른 실행이라 하루 상한만 푼다. 동시 실행 lock·실패 상한·범위 판정은 그대로 따른다.
  HM_HARVEST_AUTO=1 HM_HARVEST_AUTO_DAILY_MAX=999 bash "$PLUGIN/scripts/harvest-auto.sh" trigger "$status" "$cwd" "$src" >/dev/null 2>&1
  after_result=$(jq -r 'select(.at != "'"$before"'") | .result // empty' "$marker" 2>/dev/null || true)
  if [ "$after_result" = launched ]; then
    reply true "$project harvest를 시작함 (무인 실행, 결과는 이 보드에 표시)"
  else
    reason=$(tail -n 5 "$DATA/harvest-auto/runs.jsonl" 2>/dev/null | jq -r --arg p "$project" 'select(.project == $p and .event == "skipped") | .reason' 2>/dev/null | tail -n 1)
    case "$reason" in
      busy) reply false "다른 무인 실행이 진행 중 — 끝난 뒤 다시 누르세요" ;;
      "") reply false "시작하지 않음 (marker: ${after_result:-변화 없음})" ;;
      *) reply false "시작하지 않음: $reason" ;;
    esac
  fi
}

case "${1:-}" in
  harvest-now) harvest_now "${2:-}" ;;
  *) reply false "unknown action"; exit 2 ;;
esac
