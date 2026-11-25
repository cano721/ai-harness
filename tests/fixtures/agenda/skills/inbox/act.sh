#!/usr/bin/env bash
# 가짜 done·reopen(#567): 호출 인자를 기록하고, done이면 다음 fetch가 그 항목을 빼게, reopen이면 다시 내게 한다.
set -euo pipefail
state="$HM_DATA_DIR/fixture-inbox"; mkdir -p "$state"
printf '%s\n' "$*" >>"$state/calls"
case "$1" in
  done) printf '%s\n' "$2" >>"$state/done" ;;
  reopen)
    if [[ -f "$state/fail-reopen" ]]; then echo "원본 요청함에 닿지 못했습니다" >&2; exit 1; fi
    grep -vxF "$2" "$state/done" >"$state/done.tmp" 2>/dev/null || true
    mv "$state/done.tmp" "$state/done" ;;
esac
