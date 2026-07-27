#!/usr/bin/env bash
# SessionEnd hook 진입점. stdin: {session_id, transcript_path, cwd, reason}
# 실패해도 세션 종료를 막지 않는다 (항상 exit 0)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"
tp="$(echo "$input" | jq -r '.transcript_path // empty')"
reason="$(echo "$input" | jq -r '.reason // empty')"
tp="${tp/#\~/$HOME}"
[[ -f "$tp" ]] && "$DIR/extract-claude.sh" "$tp" "$reason" >/dev/null 2>&1
exit 0
