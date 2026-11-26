#!/usr/bin/env bash
# 가짜 done·reopen(#567)·delete(#637): 호출 인자를 기록하고, done이면 다음 fetch가 그 항목을 빼게, reopen이면 다시 내게,
# delete면 다시는 내지 않게 한다. fail-reopen·fail-delete가 있으면 그 동작이 실패한다.
set -euo pipefail
state="$HM_DATA_DIR/fixture-inbox"; mkdir -p "$state"
printf '%s\n' "$*" >>"$state/calls"
case "$1" in
  done) printf '%s\n' "$2" >>"$state/done" ;;
  reopen)
    if [[ -f "$state/fail-reopen" ]]; then echo "원본 요청함에 닿지 못했습니다" >&2; exit 1; fi
    grep -vxF "$2" "$state/done" >"$state/done.tmp" 2>/dev/null || true
    mv "$state/done.tmp" "$state/done" ;;
  delete)
    if [[ -f "$state/fail-delete" ]]; then echo "원본 요청함에 닿지 못했습니다" >&2; exit 1; fi
    printf '%s\n' "$2" >>"$state/deleted" ;;
esac
