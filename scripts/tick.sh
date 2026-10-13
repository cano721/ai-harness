#!/usr/bin/env bash
# Stop hook(응답이 끝날 때마다) 진입점. OS 스케줄러 없이 긴 세션 중에도 정기 작업이 돌게 한다.
# 하는 일은 "주기가 지났나" 확인뿐이라 수 ms에 끝나고, 지났으면 backfill-due.sh가 작업을 세션과 분리해 띄운다.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat >/dev/null 2>&1 || true
# 하네스가 띄운 내부 headless 세션(자동 harvest·LLM 정리)에서는 아무것도 하지 않는다.
[[ "${HM_INTERNAL_SESSION:-}" == "1" ]] && exit 0
"$DIR/backfill-due.sh" >/dev/null 2>&1 || true
exit 0
