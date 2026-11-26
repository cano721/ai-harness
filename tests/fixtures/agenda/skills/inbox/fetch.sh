#!/usr/bin/env bash
# 가짜 어댑터(#567): created·from이 있는 할 일, 오래된 할 일, 읽을 수 없는 created, 기한 있는 할 일, 답할 것 1건.
# act.sh done으로 끝낸 id·act.sh delete로 지운 id(#637)는 빼고 내고, act.sh reopen으로 다시 연 id는 다시 낸다.
set -euo pipefail
state="$HM_DATA_DIR/fixture-inbox"; mkdir -p "$state"
done_ids="$(cat "$state/done" "$state/deleted" 2>/dev/null || true)"
emit() { case $'\n'"$done_ids"$'\n' in *$'\n'"$1"$'\n'*) ;; *) printf '%s\n' "$2" ;; esac; }
ago() { python3 -I -c 'import sys, datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
due="$(python3 -I -c 'import datetime; print(datetime.date.today() + datetime.timedelta(days=2))')"
emit i-new "{\"id\":\"i-new\",\"kind\":\"todo\",\"title\":\"예시 검토 요청\",\"created\":\"$(ago 1)\",\"from\":\"예시 담당자\",\"url\":\"https://inbox.example.com/i-new\"}"
emit i-old "{\"id\":\"i-old\",\"kind\":\"todo\",\"title\":\"예시 자료 정리\",\"created\":\"$(ago 72)\",\"from\":\"예시 팀장\"}"
emit i-bad '{"id":"i-bad","kind":"todo","title":"받은 시각을 모르는 요청","created":"어제쯤"}'
emit i-due "{\"id\":\"i-due\",\"kind\":\"todo\",\"title\":\"예시 보고서 마감\",\"due\":\"$due\"}"
emit i-reply '{"id":"i-reply","kind":"reply","title":"주간 회의 시간 확인 부탁드립니다","url":"https://inbox.example.com/i-reply"}'
