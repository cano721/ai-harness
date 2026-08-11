#!/usr/bin/env bash
# SessionEnd hook 진입점. stdin: {session_id, transcript_path, cwd, reason}
# 실패해도 세션 종료를 막지 않는다 (항상 exit 0)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"
input="$(cat)"
tp="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
reason="$(printf '%s' "$input" | jq -r '.reason // empty')"
tp="${tp/#\~/$HOME}"
if [[ ! -f "$tp" ]]; then
  "$DIR/health.sh" failure session_end transcript_missing >/dev/null 2>&1 || true
  exit 0
fi

# hooks/hooks.json을 Codex가 전달하는 환경이면 rollout을 Codex extractor로 분류한다.
# hook이 누락되거나 진행 중인 Codex 세션은 기존 backfill 경로가 보완한다.
if [[ "$(basename "$tp")" == rollout-*.jsonl ]]; then
  if ! "$DIR/extract-codex.sh" "$tp" >/dev/null 2>&1; then
    "$DIR/health.sh" failure session_end codex_extract_failed >/dev/null 2>&1 || true
    exit 0
  fi
  file_sid="$(basename "$tp" .jsonl)"
  file_sid="${file_sid#rollout-}"
  event_file="$HM_DATA_DIR/events/codex-${file_sid}.jsonl"
else
  if ! "$DIR/extract-claude.sh" "$tp" "$reason" >/dev/null 2>&1; then
    "$DIR/health.sh" failure session_end claude_extract_failed >/dev/null 2>&1 || true
    exit 0
  fi
  event_file="$HM_DATA_DIR/events/claude-$(basename "${tp%.jsonl}").jsonl"
fi
if [[ -f "$event_file" ]] \
  && jq -e 'select(.kind=="session")' "$event_file" >/dev/null 2>&1 \
  && "$DIR/harvest-queue.sh" record "$event_file" >/dev/null 2>&1; then
  "$DIR/health.sh" success session_end >/dev/null 2>&1 || true
else
  "$DIR/health.sh" failure session_end queue_record_failed >/dev/null 2>&1 || true
fi
exit 0
