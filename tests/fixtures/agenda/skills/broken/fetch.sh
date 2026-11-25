#!/usr/bin/env bash
# 가짜 어댑터: $HM_DATA_DIR/fixture-broken/fail이 있으면 실패한다. 없으면 답할 것 1건.
set -euo pipefail
if [[ -f "$HM_DATA_DIR/fixture-broken/fail" ]]; then
  echo "메일 서버에 로그인하지 못했습니다" >&2
  exit 1
fi
printf '%s\n' '{"id":"m1","kind":"reply","title":"이전에 가져온 메일"}'
