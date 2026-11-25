#!/usr/bin/env bash
# 가짜 계정 추가: fixture-duo/next(없으면 a@example.com)를 계정 목록에 더한다. 같은 계정이면 그대로 둔다.
set -euo pipefail
state="$HM_DATA_DIR/fixture-duo"; mkdir -p "$state"
id="$(cat "$state/next" 2>/dev/null || echo a@example.com)"
grep -qxF "$id" "$state/accounts" 2>/dev/null || printf '%s\n' "$id" >>"$state/accounts"
rm -f "$state/expired-$id"
