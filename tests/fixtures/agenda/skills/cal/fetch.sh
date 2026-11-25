#!/usr/bin/env bash
# 가짜 어댑터: 오늘·내일 일정 3건(종일 하나 포함).
set -euo pipefail
today="$(date +%Y-%m-%d)"
tomorrow="$(python3 -I -c 'import datetime; print(datetime.date.today() + datetime.timedelta(days=1))')"
printf '{"id":"e1","kind":"event","title":"주간 회의","start":"%sT10:00:00","end":"%sT11:00:00","url":"https://calendar.example.com/e1"}\n' "$today" "$today"
printf '{"id":"e2","kind":"event","title":"점심 약속","start":"%sT12:30:00","end":"%sT13:30:00"}\n' "$today" "$today"
printf '{"id":"e3","kind":"event","title":"예시 워크숍","start":"%s","end":"%s"}\n' "$tomorrow" "$tomorrow"
