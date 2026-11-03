#!/usr/bin/env bash
# A/B 테스트용 가짜 에이전트: 하네스(AGENTS.md)가 있으면 규칙대로, 없으면 규칙을 모르는 구현을 넣는다.
set -euo pipefail
# 실험 실행이 사용 기록(metrics·harvest)에 섞이지 않는지 확인한다.
[[ "${HM_INTERNAL_SESSION:-}" == "1" ]] || { echo "HM_INTERNAL_SESSION not set" >&2; exit 9; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f AGENTS.md ]]; then
  cp "$here/good_service.py" orders/service.py
  cp "$here/good_tests.py" tests/test_new.py
  printf '{"type":"result","is_error":false,"num_turns":6,"total_cost_usd":0.4,"duration_ms":30000,"usage":{"input_tokens":10,"output_tokens":200,"cache_read_input_tokens":1000}}\n'
else
  cp "$here/naive_service.py" orders/service.py
  printf '{"type":"result","is_error":false,"num_turns":9,"total_cost_usd":0.3,"duration_ms":40000,"usage":{"input_tokens":12,"output_tokens":250,"cache_read_input_tokens":900}}\n'
fi
