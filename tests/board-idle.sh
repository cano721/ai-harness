#!/usr/bin/env bash
# 회귀 테스트 — Harness Board 자동 종료(보는 사람이 없을 때)
# 실행: bash tests/run.sh board-idle
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-board.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-board.sh"

# 보드 자동 종료(#355): 런처로 켜고 잊어도 서버가 남지 않게 BOARD_IDLE_EXIT분 동안 보는 사람이 없으면 스스로 꺼진다.
# 붙잡은 권한 요청이 있으면 끄지 않는다(끄면 그 터미널 세션이 답을 잃는다). 0이면 끄지 않는다.
board_alive() { [[ "$(board_sh status | jq -r '.running')" == true ]]; }
# 0.02분 = 1.2초. 서버는 max(0.5, IDLE_EXIT/4)초마다 확인하므로 2초 안팎이면 꺼진다.
BOARD_IDLE_EXIT=0.02 board_sh open >/dev/null
board_alive || fail "board with idle exit starts"
for _ in $(seq 100); do board_alive || break; sleep 0.1; done
board_alive && fail "board exits after BOARD_IDLE_EXIT minutes with nobody watching"
assert_not_file "$BOARD_DATA/board/server.json"
BOARD_IDLE_EXIT=0 board_sh open >/dev/null
sleep 2  # 일어나지 않음 확인: 위 0.02분 보드가 꺼지는 시간(약 1.7초)보다 길게
board_alive || fail "BOARD_IDLE_EXIT=0 keeps the board running"
board_sh stop >/dev/null
# 서버가 요청을 붙잡은 것(actions.jsonl의 held 기록)을 본 뒤에 창을 연다 — curl이 늦게 도착해 창이 붙잡는 시간을 넘지 않게(#585).
BI_LOG="$BOARD_DATA/board/actions.jsonl"
BI_LOG_LINES="$(wc -l <"$BI_LOG" 2>/dev/null || echo 0)"
BOARD_IDLE_EXIT=0.02 BOARD_PERMISSION_WAIT=8 board_sh open >/dev/null
BI_TOKEN="$(jq -r '.token' "$BOARD_DATA/board/server.json")"
curl -s -m 15 -X POST -H "X-Board-Hook: $BI_TOKEN" -d '{"tool_name":"Bash","session_id":"s-idle"}' "http://127.0.0.1:$BOARD_PORT_T/hook/permission" >/dev/null &
BI_HOLD=$!
bi_held() { tail -n "+$((BI_LOG_LINES + 1))" "$BI_LOG" 2>/dev/null | grep -q '"held": true'; }
for _ in $(seq 1 100); do bi_held && break; sleep 0.1; done
bi_held || fail "the board holds the permission request"
sleep 2  # 일어나지 않음 확인: 권한 요청이 없으면 꺼졌을 시간(약 1.7초)보다 길게. 붙잡는 시간(8초)은 이 창보다 넉넉히 길다
board_alive || fail "board does not exit while it holds a permission request"
wait "$BI_HOLD" 2>/dev/null || true
for _ in $(seq 100); do board_alive || break; sleep 0.1; done
board_alive && fail "board exits once the held request is released"
pass "harness board exits when nobody watches"

finish_tests
