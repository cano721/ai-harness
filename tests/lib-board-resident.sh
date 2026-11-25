#!/usr/bin/env bash
# Harness Board 상주 세션 영역(board-resident·board-resident-upgrade)이 lib.sh 다음에 source하는 공용 준비:
# 가짜 claude(tests/fixtures/board-resident)로 띄우는 보드 서버(br_start·br_stop)와 호스트·세션 확인 헬퍼. 영역 파일이 아니다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
BR_T="$TEST_TMP/board-resident"
BR_DATA="$BR_T/data"
mkdir -p "$BR_DATA" "$BR_T/cwd" "$BR_T/projects"
chmod +x "$ROOT/tests/fixtures/board-resident/claude" "$ROOT/tests/fixtures/board-resident/orca"
BR_LOG="$BR_T/stub.jsonl"
: >"$BR_LOG"
# 보드를 끄고 다시 켜는 테스트(#364)가 같은 환경으로 여러 번 띄운다. 호스트는 보드가 띄우므로 이 환경을 물려받는다.
# 가짜 claude agents 목록(BOARD_STUB_AGENTS)은 세션 상태 파일(sessions/·jobs/)을 만들지 않아 갱신 지문(#380)에 잡히지 않는다 —
# 다른 터미널에 생긴 세션이 밀려 오는지 보려면 전체 수집 최소 주기를 1초로 둔다.
br_start() {
  BR_PORT="$(free_port)"
  env PATH="$ROOT/tests/fixtures/board-resident:$PATH" HARNESS_METRICS_DIR="$BR_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BR_T/projects" \
    BOARD_CLAUDE_PROFILE_GLOBS="$BR_T/none/*" BOARD_CLAUDE_CONFIG_DIRS= BOARD_PORT="$BR_PORT" BOARD_STUB_LOG="$BR_LOG" \
    BOARD_STUB_AGENTS="$BR_T/agents.json" BOARD_REFRESH_SECONDS=1 BOARD_HOST_IDLE=1 BOARD_JIRA_URL= JIRA_BASE_URL= \
    BOARD_FULL_REFRESH_SECONDS=1 \
    python3 -I "$ROOT/scripts/board/board-server.py" --no-open >>"$BR_T/server.log" 2>&1 &
  BR_PID=$!
  BR_URL=""
  for _ in $(seq 100); do
    [[ "$(jq -r '.pid // empty' "$BR_DATA/board/server.json" 2>/dev/null || true)" == "$BR_PID" ]] \
      && BR_URL="$(jq -r '.url // empty' "$BR_DATA/board/server.json" 2>/dev/null || true)"
    [[ -n "$BR_URL" ]] && break
    sleep 0.1
  done
  [[ -n "$BR_URL" ]] || fail "board server for resident sessions starts ($(tail -5 "$BR_T/server.log"))"
}
br_stop() { # board.sh stop과 같이 SIGTERM
  kill "$BR_PID" 2>/dev/null || true
  wait "$BR_PID" 2>/dev/null || true
}
br_client() { python3 -I "$ROOT/tests/fixtures/board-resident/client.py" "http://127.0.0.1:$BR_PORT" "${BR_URL#*t=}" "$@"; }
br_mode() { python3 -I -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"; }
br_alive() { kill -0 "$1" 2>/dev/null; }
br_launch_pid() { # 그 세션 id로 띄운 마지막 가짜 claude의 pid
  jq -rs --arg s "$1" '[.[] | select(.argv and (.argv | index($s)))] | last | .pid // empty' "$BR_LOG"
}
br_wait() { # 조건 셸 식, 0.1초 단위 횟수
  local i
  for ((i = 0; i < $2; i++)); do eval "$1" && return 0; sleep 0.1; done
  return 1
}
BR_HOST_JSON="$BR_DATA/board/host/host.json"
