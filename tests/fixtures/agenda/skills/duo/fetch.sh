#!/usr/bin/env bash
# 가짜 수집: 만료되지 않은 계정마다 오늘 일정 1건.
set -euo pipefail
state="$HM_DATA_DIR/fixture-duo"
[[ -f "$state/accounts" ]] || exit 0
today="$(date +%Y-%m-%d)"
while IFS= read -r id; do
  [[ -n "$id" && ! -f "$state/expired-$id" ]] || continue
  jq -cn --arg i "$id" --arg d "$today" '{id: ("duo-" + $i), kind: "event", title: ($i + " 일정"), start: $d, detail: $i}'
done <"$state/accounts"
