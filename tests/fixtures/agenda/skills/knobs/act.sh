#!/usr/bin/env bash
# 가짜 settings 어댑터(#632): get은 데이터 디렉터리 fixture-knobs/values.json(없으면 기본값)을 내고,
# set은 표준 입력(전체 설정 JSON)을 values.json에 쓰며 호출마다 calls에 한 줄 남긴다. fail-set이 있으면 set이 실패한다.
# options-channels는 선택지 JSONL — 잘못된 줄 2개는 보드가 건너뛴다. fetch는 항목 없이 성공한다.
set -euo pipefail
state="$HM_DATA_DIR/fixture-knobs"; mkdir -p "$state"
case "$1" in
  fetch) ;;
  get)
    if [[ -f "$state/values.json" ]]; then cat "$state/values.json"
    else printf '%s\n' '{"channels":["general"],"digest":false,"forward":false,"lookback":7}'; fi ;;
  options-channels)
    printf '%s\n' '{"value":"general","label":"#general"}' '{"value":"random","label":"#random"}' 'not json' \
      '{"value":"alerts","label":"#alerts"}' '{"value":1,"label":"숫자 값"}' ;;
  set)
    printf 'set\n' >>"$state/calls"
    if [[ -f "$state/fail-set" ]]; then echo "설정 저장소에 닿지 못했습니다" >&2; exit 1; fi
    cat >"$state/values.json" ;;
  *) exit 2 ;;
esac
