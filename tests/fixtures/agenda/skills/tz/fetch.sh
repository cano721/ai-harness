#!/usr/bin/env bash
# 가짜 어댑터(#567): 오프셋이 섞인 같은 날 일정 — 10:00+09:00, 19:30+09:00, 10:00Z(=19:00 KST), 21:15+11:00(=19:15 KST),
# 종일 공유 일정 1건, 다음 날 1건. 문자열로 견주면 21:15+11:00이 19:30 뒤로 가므로 실제 시각 정렬만 맞는다.
# 날짜는 보드가 띄운 시간대(테스트는 TZ=Asia/Seoul) 기준 오늘이다.
set -euo pipefail
today="$(date +%Y-%m-%d)"
tomorrow="$(python3 -I -c 'import datetime; print(datetime.date.today() + datetime.timedelta(days=1))')"
printf '{"id":"z-late","kind":"event","title":"저녁 회고","start":"%sT19:30:00+09:00","end":"%sT20:00:00+09:00"}\n' "$today" "$today"
printf '{"id":"z-utc","kind":"event","title":"해외 통화","start":"%sT10:00:00Z","end":"%sT10:20:00Z"}\n' "$today" "$today"
printf '{"id":"z-east","kind":"event","title":"동쪽 지사 통화","start":"%sT21:15:00+11:00","end":"%sT21:30:00+11:00"}\n' "$today" "$today"
printf '{"id":"z-next","kind":"event","title":"다음 날 주간 회의","start":"%sT09:00:00+09:00","end":"%sT10:00:00+09:00"}\n' "$tomorrow" "$tomorrow"
printf '{"id":"z-morning","kind":"event","title":"주간 회의","start":"%sT10:00:00+09:00","end":"%sT11:00:00+09:00"}\n' "$today" "$today"
printf '{"id":"z-allday","kind":"event","title":"예시 담당자 휴가","start":"%s","end":"%s","shared":true}\n' "$today" "$tomorrow"
