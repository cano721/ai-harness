#!/usr/bin/env bash
# 회귀 테스트 — Harness Board 상주 세션(SSE·권한·질문)과 따로 뜬 상주 세션 호스트(재시작·SIGKILL 뒤 재개·스스로 종료)
# 실행: bash tests/run.sh board-resident
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-board-resident.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-board-resident.sh"

# 보드 상주 세션(#349): '새 세션'은 claude -p stream-json 상주 프로세스로 쥐고 입력은 stdin으로(--resume 없음, 세션 id 유지).
# 권한·질문은 control_request로 받아 SSE(GET /events)로 1초 안에 밀어 주고, 사람이 누른 답만 control_response로 돌려준다.
# 가짜 claude(tests/fixtures/board-resident)가 실측한 형식대로 묻고, 시나리오 클라이언트가 화면처럼 SSE를 열어 답한다.
br_start
# 숨은 탭의 SSE(/events?bg=1)는 보는 사람 표시만 하고 백그라운드 갱신을 살리지 않는다(#351이 숨은 탭 폴링을 뺀 것과 같다).
# 갱신이 1초 주기여도 4초 동안 다른 터미널의 새 세션이 밀려 오지 않아야 한다.
br_agent() { jq -cn --arg s "$1" --arg cwd "$BR_T/cwd" --argjson at "$(date +%s)000" \
  '{sessionId: $s, id: ($s[0:8]), kind: "background", status: "idle", state: "idle", pid: null, cwd: $cwd, name: "other terminal", startedAt: $at}'; }
BR_HIDDEN="bbbbbbbb-0000-4000-8000-000000000349"
BR_SSE_BG="$(python3 -I "$ROOT/tests/fixtures/board-resident/sse-only.py" "http://127.0.0.1:$BR_PORT" "${BR_URL#*t=}" "$BR_T/agents.json" "[$(br_agent "$BR_HIDDEN")]" "$BR_HIDDEN" 4 bg)"
assert_eq "true|false" "$(jq -r '[.hello, .pushed] | map(tostring) | join("|")' <<<"$BR_SSE_BG")" "an event stream from a hidden tab does not keep the background refresh running"
# SSE만 연결된 화면(/status.json 폴링 없음)도 백그라운드 갱신(#351)을 살려, 다른 터미널에 새로 생긴 세션이 이벤트로 온다.
BR_OTHER="aaaaaaaa-0000-4000-8000-000000000349"
BR_OTHER_JSON="[$(br_agent "$BR_HIDDEN"),$(br_agent "$BR_OTHER")]"
BR_SSE_ONLY="$(python3 -I "$ROOT/tests/fixtures/board-resident/sse-only.py" "http://127.0.0.1:$BR_PORT" "${BR_URL#*t=}" "$BR_T/agents.json" "$BR_OTHER_JSON" "$BR_OTHER" 15)"
assert_eq "true|true" "$(jq -r '[.hello, .pushed] | map(tostring) | join("|")' <<<"$BR_SSE_ONLY")" "with only the event stream open, the background refresh keeps running and pushes a session that appeared elsewhere ($(jq -r '.after' <<<"$BR_SSE_ONLY")s)"
BR_REPORT="$(python3 -I "$ROOT/tests/fixtures/board-resident/scenario.py" "http://127.0.0.1:$BR_PORT" "${BR_URL#*t=}" "$BR_T/cwd" "$BR_LOG")" \
  || fail "resident scenario runs ($(tail -5 "$BR_T/server.log"))"
br() { jq -r "$1 | tostring" <<<"$BR_REPORT"; }
assert_eq "200|text/event-stream|hello" "$(br '[.sse_status, .sse_type, .sse_first_event] | join("|")')" "GET /events is an SSE stream that greets first"
assert_eq "true|true" "$(br '[.new_ok, .id_has_sid] | join("|")')" "new session starts as a resident process keyed by its session id"
assert_eq "true" "$(br '.permission_tool_stdio')" "the resident session routes permission prompts to the board over stdio"
assert_eq "true|Bash|bg|needs_human" "$(br '[.perm_pushed, .perm_tool, .item_kind, .item_state] | join("|")')" "a permission request is pushed over SSE as a waiting item"
assert_eq "true" "$(br '.perm_latency < 1')" "the permission request reaches SSE within a second ($(br '.perm_latency')s)"
assert_eq "false" "$(br '.auto_answered')" "the board never answers a permission request by itself"
assert_eq "true" "$(br '.polled_perm')" "status.json carries the same request for the polling fallback"
assert_eq "true|allow|true|true" "$(br '[.allow, .allow_behavior, .allow_same_request, .idle_after_turn] | join("|")')" "the person's allow goes back on stdin as the control response and the turn ends"
assert_eq "true|true|Pick a color|true" "$(br '[.send, .question_pushed, .question_text, .transcript_question] | join("|")')" "AskUserQuestion is pushed as a question with its choices"
assert_eq "true|{\"Pick a color\":\"red\"}" "$(br '[.answer, (.answers_sent | tojson)] | join("|")')" "the person's pick goes back as the AskUserQuestion answers"
assert_eq "false" "$(br '.bad_answer')" "an answer to a request the board does not hold is refused"
assert_eq "true" "$(br '.seen_moves_to_idle')" "marking a resident result as read moves it out of unread"
assert_eq "false|false" "$(br '[.question_via_permission, .send_while_pending] | join("|")')" "a question is answered only by picking, and typed input waits until it is answered"
assert_eq "403" "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$BR_PORT/events")" "the event stream needs the board token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "$(jq -cn --arg t "${BR_URL#*t=}" '{t: $t, id: "x", pid: "y", answers: {}}')" "http://127.0.0.1:$BR_PORT/answer")" "an answer needs the board Origin"
assert_eq "1|false|2" "$(br '[.launches, .resume_used, .stdin_users] | join("|")')" "follow-up input goes to the same process on stdin without --resume"
assert_eq "true" "$(br '.end')" "a resident session can be ended from the board"
assert_contains "$(br '.ended_cmd')" "claude --resume " "an ended resident session shows how to resume it"
assert_eq "true|true|true" "$(br '[.send_after_end, .relaunch_resume_sid, .same_id_after_resume] | join("|")')" "sending to an ended resident session resumes the same session id"
assert_eq "true" "$(jq --arg id "$(br '.new_id')" 'has($id | ltrimstr("res|"))' "$BR_DATA/board/residents.json")" "the board keeps a record of its resident sessions"
BR_TPL="$(<"$ROOT/scripts/board/template.html")"
assert_contains "$BR_TPL" "new EventSource('/events?t='" "the board screen listens to server events"
assert_contains "$BR_TPL" "if (!sseLive()) refresh()" "the board screen polls only while server events are down"
assert_contains "$BR_TPL" "post('/answer'" "the board screen answers a resident question through the session"
assert_contains "$BR_TPL" "if (m.cleanup_failed) refresh()" "a cleanup failure pushed as meta brings the card back with its notice"
BR_VIS="$(sed -n "/document.addEventListener('visibilitychange'/,/});/p" "$ROOT/scripts/board/template.html")"
assert_contains "$BR_VIS" "if (document.hidden) closeEvents()" "a hidden board tab closes its event stream (the bg=1 polling takes over)"
assert_contains "$BR_VIS" "connectEvents()" "a board tab that shows again reconnects its event stream"
assert_contains "$(sed -n '/function closeEvents()/,/^  }$/p' "$ROOT/scripts/board/template.html")" "es.close()" "closing the event stream really closes the EventSource"
# 묶음 목록(읽지 않은 결과 등)에서도 상주 세션은 눌러 열린다 — 동작이 send·end뿐이라 view가 없어도.
BR_OPENABLE="$(grep -m1 '^  const openable = ' "$ROOT/scripts/board/template.html")"
# 함수 본문은 환경변수로 넘긴다 — bash 3.2는 "$(... "${VAR} {...}")" 안의 중괄호를 깨뜨린다.
assert_eq "true false true" "$(BR_OPENABLE="$BR_OPENABLE" node -e 'const SERVER = true, srcOf = (i) => i.section; eval(process.env.BR_OPENABLE.replace("const openable", "var openable"));
console.log([openable({ section: "work", resident: true, actions: ["send", "end"] }), openable({ section: "work", actions: ["send"] }), openable({ section: "work", actions: ["view"] })].join(" "))')" \
  "a resident session in a grouped list opens its drawer; other work items still need view"
pass "board holds new sessions as resident stream-json processes and pushes permission requests over SSE"

# 상주 세션 호스트(#364): 상주 세션은 보드 서버가 아니라 따로 뜬 호스트(resident_host.py)가 쥐고, 보드는 유닉스 소켓으로 붙는다.
# 보드를 끄고 켜도 세션 pid가 그대로이고, 꺼진 동안 생긴 권한 요청은 다시 붙은 보드에 바로 뜬다.
# 호스트가 SIGKILL로 죽으면(재부팅 흉내) 다음 보드가 호스트를 다시 띄우고, 사람이 끝내지 않은 세션만 같은 id로 --resume해 입력을 기다린다.
# 세션도 보드 연결도 없으면 호스트가 스스로 끝난다. 앞 블록의 보드(BR_PID)와 세션(BR_RID)을 이어 쓴다.
BR_RID="$(br '.new_id')"
BR_SID="${BR_RID#res|}"
assert_file "$BR_HOST_JSON"
BR_HOST_PID="$(jq -r '.pid' "$BR_HOST_JSON")"
assert_eq "true" "$(br_alive "$BR_HOST_PID" && [[ "$BR_HOST_PID" != "$BR_PID" ]] && echo true || echo false)" "a separate host process holds the resident sessions"
BR_SOCK="$(jq -r '.sock' "$BR_HOST_JSON")"
assert_eq "600|700|600" "$(br_mode "$BR_SOCK")|$(br_mode "$(dirname "$BR_SOCK")")|$(br_mode "$BR_HOST_JSON")" "the host socket is 0600 in a 0700 folder and its record is 0600"
BR_NOAUTH="$(python3 -I -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
s.sendall(json.dumps({"op": "items"}).encode() + b"\n")
data = b""
while not data.endswith(b"\n"):
    got = s.recv(65536)
    if not got:
        break
    data += got
print("refused" if not data or json.loads(data).get("ok") is False and "items" not in json.loads(data) else "accepted")
' "$BR_SOCK")"
assert_eq "refused" "$BR_NOAUTH" "the host refuses a connection that does not present the host token"
BR_NONASCII="$(python3 -I -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
s.sendall(json.dumps({"t": "토큰아님", "op": "items"}).encode() + b"\n")
print(json.loads(s.recv(65536)).get("ok"))
' "$BR_SOCK")"
assert_eq "False|true" "$BR_NONASCII|$(br_alive "$BR_HOST_PID" && echo true || echo false)" "a non-ASCII token is refused cleanly and the host keeps running"
BR_RT1="$(br_client roundtrip "$BR_RID" "before restart")"
assert_eq "true" "$(jq -r '.ok and .seconds != null and .seconds < 3' <<<"$BR_RT1")" "a resident round trip before the board restart is quick ($(jq -r '.seconds' <<<"$BR_RT1")s)"
BR_SESS_PID="$(br_launch_pid "$BR_SID")"
BR_LAUNCHES="$(jq -s '[.[] | select(.argv)] | length' "$BR_LOG")"
# 보드가 꺼지는 사이에 권한을 묻게(SLOW = 1.5초 뒤) 보내고 보드를 끈다.
assert_eq "true" "$(br_client send "$BR_RID" "SLOWPERM while away" | jq -r '.ok')" "send before the board stops"
br_stop
br_wait "[[ ! -f '$BR_DATA/board/server.json' ]]" 50 || fail "the board stops"
br_wait "jq -se --argjson p $BR_SESS_PID 'any(.[]; .pid == \$p and .emitted == \"Bash\")' '$BR_LOG' >/dev/null" 50 \
  || fail "the resident session asks for a permission while the board is off"
assert_eq "false" "$([[ -f "$BR_DATA/board/server.json" ]] && echo true || echo false)" "the permission request was made while no board was running"
assert_eq "true|true|0" "$(br_alive "$BR_SESS_PID" && echo true || echo false)|$(br_alive "$BR_HOST_PID" && echo true || echo false)|$(jq -s --argjson p "$BR_SESS_PID" '[.[] | select(.pid == $p and .eof)] | length' "$BR_LOG")" \
  "stopping the board leaves the host and its resident session running"
br_start
assert_eq "$BR_HOST_PID" "$(jq -r '.pid' "$BR_HOST_JSON")" "a restarted board attaches to the running host"
BR_PERM_AT="$(br_client waitperm "$BR_RID" 5)"
# 다시 켠 보드의 첫 목록(첫 수집이라 1–2초 걸릴 수 있다)에 이미 실려 있어야 한다 — 따로 더 기다리지 않는다.
assert_eq "true" "$(jq -r '.first' <<<"$BR_PERM_AT")" "a permission request made while the board was off is in the first listing of the board that comes back ($(jq -r '.seconds' <<<"$BR_PERM_AT")s)"
assert_eq "true" "$(br_client allow "$BR_RID" | jq -r '.ok')" "the person's allow after the restart is accepted"
br_wait "jq -se --argjson p $BR_SESS_PID 'any(.[]; .pid == \$p and .stdin.type == \"control_response\" and (.stdin | tostring | test(\"allow\")))' '$BR_LOG' >/dev/null" 50 \
  || fail "the allow reaches the same resident process after the board restart"
BR_RT2="$(br_client roundtrip "$BR_RID" "after restart")"
assert_eq "true" "$(jq -r '.ok and .seconds != null and .seconds < 3' <<<"$BR_RT2")" "a resident round trip after the board restart is still quick ($(jq -r '.seconds' <<<"$BR_RT2")s)"
assert_eq "$BR_SESS_PID|$BR_LAUNCHES" "$(br_launch_pid "$BR_SID")|$(jq -s '[.[] | select(.argv)] | length' "$BR_LOG")" "the board restart neither relaunches nor resumes the session"
# 사람이 끝낸 세션 B와, 권한을 기다리던 세션 A를 두고 호스트를 SIGKILL한다(재부팅 흉내).
BR_B="$(br_client new "$BR_T/cwd" "hello B" | jq -r '.id')"
BR_SID_B="${BR_B#res|}"
br_wait "[[ \"\$(br_client item '$BR_B' | jq -r '.state')\" == review ]]" 50 || fail "session B finishes its first turn"
assert_eq "true" "$(br_client end "$BR_B" | jq -r '.ok')" "a person ends session B"
br_wait "[[ \"\$(br_client item '$BR_B' | jq -r '.live')\" == false ]]" 50 || fail "session B ends"
assert_eq "true" "$(br_client send "$BR_RID" "PERM before kill" | jq -r '.ok')" "session A asks again"
assert_eq "true" "$(br_client waitperm "$BR_RID" 5 | jq -r '.seconds != null')" "session A waits on a permission when the host dies"
br_stop
BR_LAUNCHES="$(jq -s '[.[] | select(.argv)] | length' "$BR_LOG")"
kill -9 "$BR_HOST_PID"
br_wait "! br_alive $BR_HOST_PID" 50 || fail "the host is killed"
br_wait "jq -se --argjson p $BR_SESS_PID 'any(.[]; .pid == \$p and .eof)' '$BR_LOG' >/dev/null" 50 || fail "the session held by the killed host ends"
br_start
br_wait "[[ \$(jq -s '[.[] | select(.argv)] | length' '$BR_LOG') -gt $BR_LAUNCHES ]]" 80 || fail "opening the board after the host died resumes the open session ($(tail -5 "$BR_T/server.log"))"
sleep 1  # 일어나지 않음 확인: 아래 "재개된 세션에 저절로 보낸 입력이 없다"를 보려면 재개 뒤 잠시 둔다(새 호스트 기록도 이 안에 쓰인다)
BR_NEW_HOST="$(jq -r '.pid // empty' "$BR_HOST_JSON")"
assert_eq "true" "$([[ -n "$BR_NEW_HOST" && "$BR_NEW_HOST" != "$BR_HOST_PID" ]] && br_alive "$BR_NEW_HOST" && echo true || echo false)" "opening the board starts a new host when the old one died"
assert_eq "[[\"--resume\",\"$BR_SID\"]]" "$(jq -sc --argjson n "$BR_LAUNCHES" '[.[] | select(.argv)][$n:] | map(.argv | [.[index("--resume")], .[index("--resume") + 1]])' "$BR_LOG")" \
  "only the session nobody ended is resumed, with the same id"
BR_RESUMED="$(br_launch_pid "$BR_SID")"
assert_eq "0" "$(jq -s --argjson p "$BR_RESUMED" '[.[] | select(.pid == $p and .stdin)] | length' "$BR_LOG")" "a resumed session waits for input — nothing is sent to it on its own"
BR_A_ITEM="$(br_client item "$BR_RID")"
assert_eq "true|true|idle|false" "$(jq -r '[.live, .interrupted, .status, (.permission != null)] | map(tostring) | join("|")' <<<"$BR_A_ITEM")" "the resumed session is live, idle, and marked as interrupted without the lost request"
assert_contains "$(jq -r '.detail' <<<"$BR_A_ITEM")" "끊긴 요청" "the card says a request was cut off and to send again"
assert_eq "false" "$(br_client item "$BR_B" | jq -r '.live')" "the session a person ended stays ended"
BR_RT3="$(br_client roundtrip "$BR_RID" "after host restart")"
assert_eq "true" "$(jq -r '.ok and .seconds != null' <<<"$BR_RT3")" "sending to the resumed session continues the same process"
assert_eq "$BR_RESUMED|null" "$(br_launch_pid "$BR_SID")|$(br_client item "$BR_RID" | jq -r '.interrupted')" "the resumed process takes the input and the interrupted mark clears"
# 끝낼 세션이 없고 보드 연결도 없으면 호스트가 스스로 끝난다(BOARD_HOST_IDLE=1초).
assert_eq "true" "$(br_client end "$BR_RID" | jq -r '.ok')" "a person ends session A"
br_wait "[[ \"\$(br_client item '$BR_RID' | jq -r '.live')\" == false ]]" 50 || fail "session A ends"
sleep 1.5  # 일어나지 않음 확인: 연결이 없으면 꺼졌을 시간(BOARD_HOST_IDLE 1초 + 확인 간격 0.25초)보다 길게
assert_eq "true" "$(br_alive "$BR_NEW_HOST" && echo true || echo false)" "the host stays while a board is connected"
br_stop
br_wait "! br_alive $BR_NEW_HOST" 100 || fail "the host exits on its own with no session and no board"
assert_eq "false|false" "$([[ -e "$BR_SOCK" ]] && echo true || echo false)|$([[ -f "$BR_HOST_JSON" ]] && echo true || echo false)" "the exiting host removes its socket and record"
BR_REG="$BR_DATA/board/residents.json"
assert_eq "true|true" "$(jq -r --arg a "$BR_SID" --arg b "$BR_SID_B" '[.[$a].closed, .[$b].closed] | map(tostring) | join("|")' "$BR_REG")" "sessions a person ended are recorded as closed and kept for resume"
pass "a separate host keeps resident sessions across board restarts and resumes open ones after it dies (round trip $(jq -r '.seconds' <<<"$BR_RT1")s → $(jq -r '.seconds' <<<"$BR_RT2")s)"

finish_tests
