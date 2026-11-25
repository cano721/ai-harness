#!/usr/bin/env bash
# 가짜 어댑터: 답할 것 2건·할 일 1건, 잘못된 줄 1줄, kind 없는 줄 1줄. done.sh로 끝낸 id는 빼고 낸다.
set -euo pipefail
state="$HM_DATA_DIR/fixture-acme"; mkdir -p "$state"
printf 'x\n' >>"$state/calls"
printf '%s\n' "$*" >"$state/fetch-args"
done_ids="$(cat "$state/done" 2>/dev/null || true)"
emit() { case $'\n'"$done_ids"$'\n' in *$'\n'"$1"$'\n'*) ;; *) printf '%s\n' "$2" ;; esac; }
emit r1 '{"id":"r1","kind":"reply","title":"배포 일정 확인 부탁드립니다","url":"https://chat.example.com/r1","detail":"예시 채널"}'
emit r2 '{"id":"r2","kind":"reply","title":"아주 긴 제목의 메시지입니다. 회의록 초안을 검토하고 의견을 남겨 달라는 요청이 와 있으며 이번 주 안에 답해야 합니다. 두 줄을 넘기면 말줄임으로 보여야 합니다."}'
emit t1 '{"id":"t1","kind":"todo","title":"예시 보고서 제출","due":"2026-01-02T09:00:00+09:00","detail":"요청: 예시 담당자"}'
printf '%s\n' 'not json'
printf '%s\n' '{"id":"x1","title":"kind 없음"}'
