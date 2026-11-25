#!/usr/bin/env bash
# 가짜 끊기: 인자가 있으면 그 계정만, 없으면 전부 지운다. 받은 인자를 disconnect-args에 남긴다.
set -euo pipefail
state="$HM_DATA_DIR/fixture-duo"; mkdir -p "$state"
printf '%s\n' "${1:-<all>}" >>"$state/disconnect-args"
if [[ $# -eq 0 ]]; then rm -f "$state/accounts"; exit 0; fi
[[ -f "$state/accounts" ]] || exit 0
grep -vxF "$1" "$state/accounts" >"$state/accounts.tmp" || true
mv "$state/accounts.tmp" "$state/accounts"
