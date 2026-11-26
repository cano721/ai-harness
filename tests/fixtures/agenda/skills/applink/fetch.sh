#!/usr/bin/env bash
# 가짜 어댑터(#592): 앱 딥링크(msteams:) url을 단 오늘 일정 1건·답할 것 1건, javascript: url을 단 답할 것 1건.
set -euo pipefail
today="$(date +%Y-%m-%d)"
printf '{"id":"m1","kind":"event","title":"예시 앱 회의","start":"%sT15:00:00","end":"%sT15:30:00","url":"msteams:/l/meetup-join/example"}\n' "$today" "$today"
printf '%s\n' '{"id":"m2","kind":"reply","title":"앱에서 답할 메시지","url":"msteams:/l/message/example"}'
printf '%s\n' '{"id":"m3","kind":"reply","title":"막혀야 할 링크","url":"javascript:alert(1)"}'
