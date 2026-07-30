#!/usr/bin/env bash
# SessionEnd hook 진입점. stdin: {session_id, transcript_path, cwd, reason}
# 실패해도 세션 종료를 막지 않는다 (항상 exit 0)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"
tp="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
reason="$(printf '%s' "$input" | jq -r '.reason // empty')"
tp="${tp/#\~/$HOME}"
[[ -f "$tp" ]] || exit 0

# hooks/hooks.json은 Codex도 자동 발견한다. Codex transcript는 backfill이 처리하므로
# 여기서 Claude extractor로 잘못 분류하지 않고 즉시 반환한다.
[[ "$(basename "$tp")" == rollout-*.jsonl ]] && exit 0

"$DIR/extract-claude.sh" "$tp" "$reason" >/dev/null 2>&1
exit 0
