#!/usr/bin/env bash
# 회귀 테스트 — Harness Board 상주 세션 호스트: 옛 플러그인 경로 호스트 교체와 board.sh host-stop
# 실행: bash tests/run.sh board-resident-upgrade
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-board-resident.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-board-resident.sh"

# 플러그인이 업데이트되면 호스트가 옛 경로의 코드로 돌 수 있다. 보드는 host.json의 proto·script를 보고,
# 세션이 없으면 옛 호스트를 끄고 새로 띄우며, 세션이 있으면(같은 proto) 계속 쓰면서 화면에 안내하고 세션이 끝나면 바꾼다.
br_real() { python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
BR_NEW_SCRIPT="$(br_real "$ROOT/scripts/board/resident_host.py")"
BR_OLD="$BR_T/oldplugin/scripts/board"
mkdir -p "$BR_OLD"
cp "$ROOT/scripts/board/resident_host.py" "$ROOT/scripts/board/resident.py" "$BR_OLD/"
br_old_host() { # 옛 플러그인 경로에서 호스트를 띄우고 BR_OLD_PID에 남긴다
  env PATH="$ROOT/tests/fixtures/board-resident:$PATH" HARNESS_METRICS_DIR="$BR_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BR_T/projects" \
    BOARD_STUB_LOG="$BR_LOG" BOARD_HOST_IDLE=60 python3 -I "$BR_OLD/resident_host.py" >>"$BR_T/oldhost.log" 2>&1 &
  BR_OLD_PID=$!
  br_wait "[[ \"\$(jq -r '.pid // empty' '$BR_HOST_JSON' 2>/dev/null)\" == $BR_OLD_PID ]]" 50 || fail "an old-path host starts"
}
br_host_script() { br_real "$(jq -r '.script // empty' "$BR_HOST_JSON" 2>/dev/null)"; }
br_old_host
assert_eq "$(br_real "$BR_OLD/resident_host.py")|1" "$(br_host_script)|$(jq -r '.proto' "$BR_HOST_JSON")" "the host records its script path and protocol"
br_start
br_wait "[[ \"\$(br_host_script)\" == '$BR_NEW_SCRIPT' ]]" 100 || fail "a board replaces an old-path host that holds no session ($(tail -3 "$BR_T/server.log"))"
assert_eq "false" "$(br_alive "$BR_OLD_PID" && echo true || echo false)" "the old-path host with no session is stopped"
br_stop
br_wait "[[ ! -f '$BR_HOST_JSON' ]]" 100 || fail "the replaced host exits once the board leaves"
# 옛 호스트가 세션을 쥐고 있으면 끄지 않고 계속 쓰며 안내한다. 세션이 끝나면 새 버전으로 바꾼다.
br_old_host
BR_OLD_ID="$(python3 -I -c '
import json, socket, sys
info = json.load(open(sys.argv[1]))
s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(info["sock"])
s.sendall(json.dumps({"t": info["token"], "op": "start", "cwd": sys.argv[2], "prompt": "hello old", "name": None}).encode() + b"\n")
print(json.loads(s.recv(65536))["r"]["id"])
' "$BR_HOST_JSON" "$BR_T/cwd")"
br_wait "[[ -n \"\$(br_launch_pid '${BR_OLD_ID#res|}')\" ]]" 50 || fail "the old-path host starts a session"
br_start
br_wait "[[ \"\$(br_client item '$BR_OLD_ID' | jq -r '.live')\" == true ]]" 50 || fail "the board shows the session the old-path host holds"
assert_eq "$BR_OLD_PID" "$(jq -r '.pid' "$BR_HOST_JSON")" "an old-path host that holds a session keeps running"
BR_META="$(curl -s "http://127.0.0.1:$BR_PORT/status.json?t=${BR_URL#*t=}" | jq -c '.resident_host')"
assert_contains "$BR_META" "이전 버전 호스트" "the board says an older host holds the sessions"
assert_eq "false" "$(jq -r '.readonly' <<<"$BR_META")" "a same-protocol older host is still used"
assert_eq "true" "$(br_client end "$BR_OLD_ID" | jq -r '.ok')" "a person ends the session through the older host"
br_wait "[[ \"\$(br_host_script)\" == '$BR_NEW_SCRIPT' ]]" 200 || fail "once its sessions end the older host is replaced by the current one"
assert_eq "false|null" "$(br_alive "$BR_OLD_PID" && echo true || echo false)|$(curl -s "http://127.0.0.1:$BR_PORT/status.json?t=${BR_URL#*t=}" | jq -c '.resident_host')" "the older host is gone and the notice clears"
# board.sh host-stop: 사람이 호스트를 끈다. 세션은 닫히되 사람이 끝낸 것이 아니므로 다음 호스트가 같은 id로 이어 쥔다.
BR_C="$(br_client new "$BR_T/cwd" "hello C" | jq -r '.id')"
BR_SID_C="${BR_C#res|}"
br_wait "[[ \"\$(br_client item '$BR_C' | jq -r '.state')\" == review ]]" 50 || fail "session C finishes its first turn"
BR_C_PID="$(br_launch_pid "$BR_SID_C")"
BR_HS_HOST="$(jq -r '.pid' "$BR_HOST_JSON")"
BR_HS="$(env HARNESS_METRICS_DIR="$BR_DATA" bash "$ROOT/scripts/board/board.sh" host-stop)"
assert_eq "true|$BR_HS_HOST" "$(jq -r '"\(.stopped)|\(.pid)"' <<<"$BR_HS")" "board.sh host-stop stops the resident host"
br_wait "jq -se --argjson p $BR_C_PID 'any(.[]; .pid == \$p and .eof)' '$BR_LOG' >/dev/null" 50 || fail "host-stop closes the session's input"
br_wait "[[ \"\$(br_launch_pid '$BR_SID_C')\" != '$BR_C_PID' ]]" 100 || fail "the next host resumes the session after host-stop"
assert_eq "--resume|$BR_SID_C" "$(jq -rs --arg s "$BR_SID_C" '[.[] | select(.argv and (.argv | index($s)))] | last | .argv | "\(.[index("--resume")])|\(.[index("--resume") + 1])"' "$BR_LOG")" "after host-stop the session comes back with the same id"
assert_eq "true" "$(br_client end "$BR_C" | jq -r '.ok')" "a person ends session C"
br_wait "[[ \"\$(br_client item '$BR_C' | jq -r '.live')\" == false ]]" 50 || fail "session C ends"
br_stop
br_wait "[[ ! -f '$BR_HOST_JSON' ]]" 100 || fail "the host exits once the last session ends and the board leaves"
assert_eq "{\"host\":false,\"stopped\":false}" "$(env HARNESS_METRICS_DIR="$BR_DATA" bash "$ROOT/scripts/board/board.sh" host-stop)" "host-stop with no host says so"
pass "an old-path host is replaced when it holds no session or once its sessions end, and host-stop hands open sessions to the next host"

finish_tests
