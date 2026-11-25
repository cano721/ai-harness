#!/usr/bin/env bash
# 가짜 계정 목록: fixture-duo/expired-<id>가 있으면 그 계정은 오류를 낸다.
set -euo pipefail
state="$HM_DATA_DIR/fixture-duo"
[[ -f "$state/accounts" ]] || exit 0
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  if [[ -f "$state/expired-$id" ]]; then
    jq -cn --arg i "$id" '{id: $i, name: $i, error: "로그인이 만료됐습니다."}'
  else
    jq -cn --arg i "$id" '{id: $i, name: $i}'
  fi
done <"$state/accounts"
