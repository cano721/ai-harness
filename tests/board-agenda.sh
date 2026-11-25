#!/usr/bin/env bash
# 회귀 테스트 — 보드 '내 일정'(#492): 일정 소스 발견·연결·수집·캐시·실패 격리, 구글 캘린더 어댑터(가짜 구글 서버),
# 직접 적는 할 일(board.sh todo·보드), 비밀 미노출, 안내 문서.
# 실행: bash tests/run.sh board-agenda
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AG_T="$TEST_TMP/board-agenda"
AG_DATA="$AG_T/data"
AG_FIX="$ROOT/tests/fixtures/agenda"
AG_GOOGLE="$ROOT/scripts/board/agenda/google/google_calendar.py"
mkdir -p "$AG_T/bin" "$AG_DATA" "$HM_CLAUDE_SKILLS_DIR" "$HM_CODEX_SKILLS_DIR"
cp -R "$AG_FIX/skills/." "$HM_CLAUDE_SKILLS_DIR/"
# 보드 상태 수집이 실제 claude·orca를 부르지 않게 가짜를 둔다.
cat >"$AG_T/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == agents ]]; then echo '[]'; exit 0; fi
exit 1
EOF
cat >"$AG_T/bin/orca" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"result":{"runs":[],"workers":[]}}'
EOF
chmod +x "$AG_T/bin/claude" "$AG_T/bin/orca"

# 가짜 구글 서버: 인자에 $TEST_TMP가 들어가 종료 시 함께 꺼진다.
AG_GPORT="$(free_port)"
AG_GSTATE="$AG_T/google-state"
python3 -I "$AG_FIX/fake-google.py" "$AG_GSTATE" "$AG_GPORT" >/dev/null 2>&1 &
track_test_process "$!"
AG_GBASE="http://127.0.0.1:$AG_GPORT"
for _ in $(seq 1 50); do curl -s -o /dev/null "$AG_GBASE/" && break; sleep 0.1; done
google_env() {
  env BOARD_AGENDA_GOOGLE_AUTH_URL="$AG_GBASE/auth" BOARD_AGENDA_GOOGLE_TOKEN_URL="$AG_GBASE/token" \
    BOARD_AGENDA_GOOGLE_API_BASE="$AG_GBASE/calendar/v3" BOARD_AGENDA_GOOGLE_REVOKE_URL="$AG_GBASE/revoke" "$@"
}

AG_PORT="$(free_port)"
ag_board() {
  google_env PATH="$AG_T/bin:$PATH" HARNESS_METRICS_DIR="$AG_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$AG_T/projects" \
    HARNESS_CLAUDE_SETTINGS="$AG_T/settings.json" BOARD_PORT="$AG_PORT" BOARD_NO_BROWSER=1 BOARD_IDLE_EXIT=0 \
    BOARD_AGENDA_FETCH_TIMEOUT=3 bash "$ROOT/scripts/board/board.sh" "$@"
}
AG_OPEN="$(ag_board open)"
AG_URL="$(jq -r '.url' <<<"$AG_OPEN")"
AG_TOKEN="${AG_URL#*t=}"
AG_BASE="http://127.0.0.1:$AG_PORT"
track_test_process "$(jq -r '.pid' "$AG_DATA/board/server.json")"
ag_get() { curl -s "$AG_BASE/agenda?t=$AG_TOKEN"; }
ag_post() { # 동작 본문(JSON) → "본문\n상태 코드"
  curl -s -w '\n%{http_code}' -X POST -H "Origin: $AG_BASE" -d "$(jq -cn --arg t "$AG_TOKEN" --argjson b "$2" '$b + {t: $t}')" "$AG_BASE/agenda/$1"
}
ag_code() { tail -n 1 <<<"$1"; }
ag_body() { sed '$d' <<<"$1"; }
ag_wait() { # jq 조건 — 참이 될 때까지 /agenda를 다시 읽는다(최대 15초). 실패하면 마지막 응답을 내고 1
  local out=""
  for _ in $(seq 1 75); do
    out="$(ag_get)"
    if jq -e "$1" >/dev/null 2>&1 <<<"$out"; then printf '%s' "$out"; return 0; fi
    sleep 0.2
  done
  printf '%s' "$out"
  return 1
}
ag_src() { jq -r --arg s "$2" '.sources[] | select(.id == $s) | .'"$3" <<<"$1"; }

# 1. 발견: 사용자 스킬 폴더의 agenda.json이 소스가 되고, 잘못된 선언은 그 소스만 선언 오류다.
AG_OUT="$(ag_get)"
assert_eq "disconnected" "$(ag_src "$AG_OUT" acme state)" "a skill agenda.json is discovered as a disconnected source"
assert_eq "Acme 메신저" "$(ag_src "$AG_OUT" acme name)" "the source carries its declared name"
assert_eq "error|true" "$(ag_src "$AG_OUT" bad state)|$(ag_src "$AG_OUT" bad invalid)" "a broken agenda.json is a declaration error"
assert_contains "$(ag_src "$AG_OUT" bad error)" "선언 오류" "the declaration error is explained"
assert_eq "disconnected" "$(ag_src "$AG_OUT" cal state)" "other sources are unaffected by a broken declaration"
assert_eq "" "$(jq -r '.sources[] | select(.id == "todo") | .id' <<<"$AG_OUT")" "the built-in to-do list is not a connectable source"
pass "agenda discovers sources and isolates declaration errors"

# 같은 id를 다른 폴더(Codex 스킬)가 다시 선언해도 먼저 찾은 쪽이 쓴다.
mkdir -p "$HM_CODEX_SKILLS_DIR/acme-copy"
jq -n '{id: "acme", name: "가로챈 이름", fetch: ["true"]}' >"$HM_CODEX_SKILLS_DIR/acme-copy/agenda.json"
assert_eq "Acme 메신저|1" "$(ag_get | jq -r '[.sources[] | select(.id == "acme")] | "\(.[0].name)|\(length)"')" "a duplicate id keeps the first declaration"
rm -rf "$HM_CODEX_SKILLS_DIR/acme-copy"
pass "agenda keeps the first source for a duplicate id"

# 2. 설정하기: requires 파일이 없으면 needs_setup + 안내, 파일을 두면 연결할 수 있다.
# 구글은 플러그인에 든 공용 클라이언트로 바로 연결할 수 있다(사용자 클라이언트 파일 없이).
assert_eq "disconnected" "$(ag_src "$AG_OUT" google state)" "google is connectable without a user client file"
assert_eq "needs_setup" "$(ag_src "$AG_OUT" duo state)" "a source whose required file is missing needs setup"
assert_contains "$(ag_src "$AG_OUT" duo setup_hint)" "Duo 앱에서 연동을 켠 뒤" "the setup hint comes from the declaration"
assert_eq "409" "$(ag_code "$(ag_post connect '{"source":"duo"}')")" "a source that needs setup cannot connect"
: >"$AG_DATA/fixture-duo-ready"
assert_eq "disconnected" "$(ag_src "$(ag_get)" duo state)" "the source becomes connectable once the required file exists"
jq -n '{installed: {client_id: "fake-client-id", client_secret: "fake-client-SECRET-xyz", redirect_uris: ["http://localhost"]}}' >"$AG_DATA/google-oauth-client.json"
chmod 600 "$AG_DATA/google-oauth-client.json"
pass "agenda asks for setup until the required file exists"

# 3. 연결·끊기와 요청 검사.
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$AG_BASE/agenda?t=wrong")" "agenda read needs the board token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $AG_BASE" -d '{"t":"wrong","source":"acme"}' "$AG_BASE/agenda/connect")" "agenda connect needs the board token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://attacker.example' -d "$(jq -cn --arg t "$AG_TOKEN" '{t: $t, source: "acme"}')" "$AG_BASE/agenda/connect")" "agenda connect refuses a foreign Origin"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: attacker.example:$AG_PORT" "$AG_BASE/agenda?t=$AG_TOKEN")" "agenda read refuses a foreign Host"
assert_eq "404" "$(ag_code "$(ag_post connect '{"source":"nope"}')")" "an unknown source cannot connect"
AG_RES="$(ag_post connect '{"source":"acme"}')"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "connect is accepted"
AG_OUT="$(ag_wait '(.sources[] | select(.id == "acme") | .state) == "connected" and (.items.reply | length) > 0')" || fail "acme connects and fetches: $AG_OUT"
assert_eq "connected" "$(head -n 1 "$AG_DATA/fixture-acme/marks")" "the connect command ran"
assert_eq "true" "$(jq -r '.acme.connected' "$AG_DATA/board/agenda/sources.json")" "sources.json records the connection"
assert_eq "600" "$(filemode "$AG_DATA/board/agenda/sources.json")" "sources.json is private"
pass "agenda connects a source through its connect command"

# 4. JSONL: 정상 3줄(답할 것 2·할 일 1), 잘못된 줄·kind 없는 줄은 건너뛰고 센다. fetch는 --since·--until을 받는다.
assert_eq "2|1|2" "$(jq -r '"\([.items.reply[] | select(.source == "acme")] | length)|\([.items.todo[] | select(.source == "acme")] | length)|\(.sources[] | select(.id == "acme") | .skipped)"' <<<"$AG_OUT")" "valid lines are sorted by kind and bad lines are counted"
assert_eq "Acme 메신저|https://chat.example.com/r1" "$(jq -r '.items.reply[] | select(.id == "r1") | "\(.source_name)|\(.url)"' <<<"$AG_OUT")" "items carry their source name and link"
assert_contains "$(cat "$AG_DATA/fixture-acme/fetch-args")" "--since" "fetch receives the window start"
assert_contains "$(cat "$AG_DATA/fixture-acme/fetch-args")" "--until" "fetch receives the window end"
pass "agenda parses adapter JSONL and skips bad lines"

# 6. 주기·캐시: interval_minutes가 지나기 전에는 다시 읽어도 fetch를 다시 부르지 않는다.
AG_CALLS="$(wc -l <"$AG_DATA/fixture-acme/calls" | tr -d ' ')"
ag_get >/dev/null; ag_get >/dev/null
assert_eq "$AG_CALLS" "$(wc -l <"$AG_DATA/fixture-acme/calls" | tr -d ' ')" "reads inside the interval do not fetch again"
assert_eq "600" "$(filemode "$AG_DATA/board/agenda/cache/acme.json")" "the cache file is private"
[[ -n "$(jq -r '.fetched_at // empty' "$AG_DATA/board/agenda/cache/acme.json")" ]] || fail "the cache keeps fetched_at"
pass "agenda serves cached items inside the interval"

# 5. done: done을 선언한 소스는 그 명령을 id와 함께 부른다. 선언이 없으면 보드에만 적고 숨긴다. 일정은 완료 대상이 아니다.
AG_RES="$(ag_post "done" '{"source":"acme","id":"r1"}')"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "done on an adapter item succeeds"
assert_eq "r1" "$(cat "$AG_DATA/fixture-acme/done-args")" "the adapter done command receives the item id"
assert_eq "" "$(ag_get | jq -r '.items.reply[] | select(.id == "r1") | .id')" "the finished item leaves the open list"
ag_post connect '{"source":"localdone"}' >/dev/null
ag_wait '[.items.reply[] | select(.id == "n1")] | length == 1' >/dev/null || fail "localdone fetches its item"
assert_eq "200" "$(ag_code "$(ag_post "done" '{"source":"localdone","id":"n1"}')")" "done on a source without done succeeds"
[[ -n "$(jq -r '.localdone.n1 // empty' "$AG_DATA/board/agenda/done.json")" ]] || fail "done.json records a local completion"
assert_eq "600" "$(filemode "$AG_DATA/board/agenda/done.json")" "done.json is private"
assert_eq "" "$(ag_get | jq -r '.items.reply[] | select(.id == "n1") | .id')" "a locally finished item is hidden"
ag_post connect '{"source":"cal"}' >/dev/null
AG_OUT="$(ag_wait '(.items.event | length) == 3')" || fail "cal fetches its events: $AG_OUT"
assert_eq "e1 e2 e3" "$(jq -r '[.items.event[].id] | join(" ")' <<<"$AG_OUT")" "events are ordered by start time"
assert_eq "400" "$(ag_code "$(ag_post "done" '{"source":"cal","id":"e1"}')")" "an event cannot be marked done"
assert_eq "404" "$(ag_code "$(ag_post "done" '{"source":"acme","id":"missing"}')")" "an unknown item cannot be marked done"
pass "agenda marks items done through the adapter or locally"

# 7. 실패 격리: 한 소스가 실패해도 이전 항목은 남고 error만 채워진다. 시간 초과도 다른 소스를 막지 않는다.
ag_post connect '{"source":"broken"}' >/dev/null
ag_wait '[.items.reply[] | select(.source == "broken")] | length == 1' >/dev/null || fail "broken fetches once"
mkdir -p "$AG_DATA/fixture-broken"; : >"$AG_DATA/fixture-broken/fail"
jq '.fetched_at = "2000-01-01T00:00:00Z" | .tried_at = "2000-01-01T00:00:00Z"' "$AG_DATA/board/agenda/cache/broken.json" >"$AG_T/broken.json"
mv "$AG_T/broken.json" "$AG_DATA/board/agenda/cache/broken.json"
AG_OUT="$(ag_wait '(.sources[] | select(.id == "broken") | .state) == "error"')" || fail "a failing fetch marks the source: $AG_OUT"
assert_contains "$(ag_src "$AG_OUT" broken error)" "메일 서버에 로그인하지 못했습니다" "the failure keeps the adapter reason"
assert_eq "이전에 가져온 메일" "$(jq -r '.items.reply[] | select(.source == "broken") | .title' <<<"$AG_OUT")" "a failing source keeps its previous items"
assert_eq "connected" "$(ag_src "$AG_OUT" acme state)" "other sources stay healthy"
# 실패 알림의 [다시 가져오기]: 주기와 상관없이 그 소스만 바로 다시 모은다.
AG_RES="$(ag_post refresh '{"source":"broken"}')"
assert_eq "200|false" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "refresh reports a fetch that still fails"
assert_contains "$(ag_body "$AG_RES" | jq -r '.message')" "메일 서버에 로그인하지 못했습니다" "a failed refresh explains why"
rm -f "$AG_DATA/fixture-broken/fail"
AG_RES="$(ag_post refresh '{"source":"broken"}')"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "refresh fetches again right away"
assert_eq "connected" "$(ag_src "$(ag_get)" broken state)" "a successful refresh clears the failure"
assert_eq "404" "$(ag_code "$(ag_post refresh '{"source":"nope"}')")" "an unknown source cannot refresh"
assert_eq "409" "$(ag_code "$(ag_post refresh '{"source":"google"}')")" "a source that is not connected cannot refresh"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $AG_BASE" -d '{"t":"wrong","source":"broken"}' "$AG_BASE/agenda/refresh")" "agenda refresh needs the board token"
: >"$AG_DATA/fixture-broken/fail"
pass "agenda refetches one source on demand"
ag_post connect '{"source":"slow"}' >/dev/null
AG_START="$(date +%s)"
ag_get >/dev/null
(($(date +%s) - AG_START < 3)) || fail "a slow source does not hold the agenda read"
AG_OUT="$(ag_wait '(.sources[] | select(.id == "slow") | .state) == "error"')" || fail "a timed-out fetch marks the source: $AG_OUT"
assert_contains "$(ag_src "$AG_OUT" slow error)" "초 안에 끝나지 않았습니다" "the timeout is explained"
assert_eq "2" "$(jq -r '([.items.reply[] | select(.source == "acme")] | length) + ([.items.todo[] | select(.source == "acme")] | length)' <<<"$AG_OUT")" "a timeout does not hide another source's items"
ag_post disconnect '{"source":"slow"}' >/dev/null
pass "agenda isolates a failing or slow source"

# 3(이어서). 끊기: disconnect 명령이 돌고, 항목과 캐시가 사라진다.
AG_RES="$(ag_post disconnect '{"source":"acme"}')"
assert_eq "200|disconnected" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.state')" "disconnect is accepted"
assert_eq "disconnected" "$(tail -n 1 "$AG_DATA/fixture-acme/marks")" "the disconnect command ran"
AG_OUT="$(ag_get)"
assert_eq "disconnected|0" "$(ag_src "$AG_OUT" acme state)|$(jq -r '[.items[][] | select(.source == "acme")] | length' <<<"$AG_OUT")" "a disconnected source shows no items"
assert_not_file "$AG_DATA/board/agenda/cache/acme.json"
pass "agenda disconnects a source"

# 3-1. 여러 계정: accounts를 선언한 소스는 연결된 뒤에도 connect로 계정을 더하고, 끊기는 계정 하나씩 한다.
AG_RES="$(ag_post connect '{"source":"duo"}')"
assert_eq "200" "$(ag_code "$AG_RES")" "the first account connects"
AG_OUT="$(ag_wait '(.sources[] | select(.id == "duo") | .accounts | length) == 1 and ([.items.event[] | select(.source == "duo")] | length) == 1')" || fail "duo connects one account: $AG_OUT"
assert_eq "connected|true|a@example.com" "$(jq -r '.sources[] | select(.id == "duo") | "\(.state)|\(.multi)|\([.accounts[].id] | join(","))"' <<<"$AG_OUT")" "the source lists its account"
assert_eq "false" "$(ag_src "$AG_OUT" acme multi)" "a source without accounts is a single connection"
mkdir -p "$HM_CODEX_SKILLS_DIR/nodisc"
jq -n '{id: "nodisc", name: "끊기 없음", fetch: ["true"], accounts: ["true"]}' >"$HM_CODEX_SKILLS_DIR/nodisc/agenda.json"
assert_contains "$(ag_src "$(ag_get)" nodisc error)" "disconnect 명령도 있어야" "accounts without disconnect is a declaration error"
rm -rf "$HM_CODEX_SKILLS_DIR/nodisc"
printf 'b@example.com' >"$AG_DATA/fixture-duo/next"
AG_RES="$(ag_post connect '{"source":"duo"}')"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "connect on a connected multi-account source adds an account"
AG_OUT="$(ag_wait '(.sources[] | select(.id == "duo") | .accounts | length) == 2 and ([.items.event[] | select(.source == "duo")] | length) == 2')" || fail "duo adds a second account: $AG_OUT"
assert_eq "a@example.com,b@example.com" "$(jq -r '[.sources[] | select(.id == "duo") | .accounts[].id] | join(",")' <<<"$AG_OUT")" "both accounts are listed"
: >"$AG_DATA/fixture-duo/expired-b@example.com"
ag_post refresh '{"source":"duo"}' >/dev/null
AG_OUT="$(ag_get)"
assert_eq "connected" "$(ag_src "$AG_OUT" duo state)" "one expired account does not fail the source"
assert_eq "로그인이 만료됐습니다." "$(jq -r '.sources[] | select(.id == "duo") | .accounts[] | select(.id == "b@example.com") | .error' <<<"$AG_OUT")" "the expired account carries its reason"
assert_eq "a@example.com 일정" "$(jq -r '[.items.event[] | select(.source == "duo") | .title] | join(",")' <<<"$AG_OUT")" "the healthy account's events stay"
assert_eq "404" "$(ag_code "$(ag_post disconnect '{"source":"duo","account":"nobody@example.com"}')")" "an unknown account cannot be disconnected"
AG_RES="$(ag_post disconnect '{"source":"duo","account":"b@example.com"}')"
assert_eq "200|connected" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.state')" "disconnecting one account keeps the source connected"
assert_eq "b@example.com" "$(tail -n 1 "$AG_DATA/fixture-duo/disconnect-args")" "the disconnect command receives the account id"
assert_eq "a@example.com" "$(jq -r '[.sources[] | select(.id == "duo") | .accounts[].id] | join(",")' <<<"$(ag_get)")" "only the other account remains"
AG_RES="$(ag_post disconnect '{"source":"duo","account":"a@example.com"}')"
assert_eq "200|disconnected" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.state')" "disconnecting the last account disconnects the source"
AG_OUT="$(ag_get)"
assert_eq "disconnected|0|0" "$(ag_src "$AG_OUT" duo state)|$(jq -r '[.sources[] | select(.id == "duo") | .accounts[]?] | length' <<<"$AG_OUT")|$(jq -r '[.items.event[] | select(.source == "duo")] | length' <<<"$AG_OUT")" "no accounts or items remain"
assert_not_file "$AG_DATA/board/agenda/cache/duo.json"
pass "agenda adds and removes accounts of a multi-account source"

# 10. 할 일: board.sh todo와 보드가 같은 저장을 쓴다.
AG_TID="$(ag_board todo add 회의록 정리)"
[[ "$AG_TID" =~ ^[0-9a-f]{8}$ ]] || fail "todo add prints a new id (got $AG_TID)"
assert_eq "$AG_TID	회의록 정리" "$(ag_board todo list)" "todo list shows the open item"
assert_eq "600" "$(filemode "$AG_DATA/board/agenda/todos.json")" "todos.json is private"
assert_eq "회의록 정리" "$(ag_get | jq -r --arg i "$AG_TID" '.items.todo[] | select(.source == "todo" and .id == $i) | .title')" "a CLI to-do shows on the board"
ag_board todo "done" "$AG_TID"
assert_eq "" "$(ag_board todo list)" "a finished to-do leaves the list"
assert_contains "$(ag_board todo list --all)" "$AG_TID" "todo list --all keeps finished items"
if ag_board todo "done" nope 2>/dev/null; then fail "todo done with an unknown id fails"; fi
set +e
ag_board todo "done" nope >/dev/null 2>&1; AG_RC1=$?
AG_USAGE="$(ag_board todo 2>&1)"; AG_RC2=$?
ag_board todo bogus >/dev/null 2>&1; AG_RC3=$?
ag_board todo add "" >/dev/null 2>&1; AG_RC4=$?
ag_board todo add "   " >/dev/null 2>&1; AG_RC5=$?
set -e
assert_eq "1 2 2 2 2" "$AG_RC1 $AG_RC2 $AG_RC3 $AG_RC4 $AG_RC5" "todo exit codes"
assert_contains "$AG_USAGE" "board.sh todo add" "todo usage names the subcommands"
AG_RES="$(ag_post todo '{"text":"보드에서 적은 일"}')"
AG_BID="$(ag_body "$AG_RES" | jq -r '.id')"
assert_eq "200" "$(ag_code "$AG_RES")" "the board adds a to-do"
assert_contains "$(ag_board todo list)" "$AG_BID	보드에서 적은 일" "a board to-do shows in the CLI"
assert_eq "400" "$(ag_code "$(ag_post todo '{"text":"  "}')")" "an empty to-do is refused"
assert_eq "200" "$(ag_code "$(ag_post "done" "$(jq -cn --arg i "$AG_BID" '{source: "todo", id: $i}')")")" "the board finishes a to-do"
assert_eq "" "$(ag_board todo list)" "a to-do finished on the board leaves the CLI list"
assert_eq "2" "$(ag_get | jq -r '.todo_total')" "the board knows how many to-dos were ever written"
pass "to-dos are shared between board.sh todo and the board"

# 8. 구글 OAuth: 루프백 + PKCE. 가짜 동의 화면이 code+state로 돌려보내고, 가짜 토큰 엔드포인트가 PKCE를 확인한다.
AG_GD="$AG_T/google-data"; mkdir -p "$AG_GD"
cp "$AG_DATA/google-oauth-client.json" "$AG_GD/"
google_run() { google_env HM_DATA_DIR="$AG_GD" BOARD_NO_BROWSER=1 python3 -I "$AG_GOOGLE" "$@"; }
google_auth_url() { # stderr 파일에서 동의 URL을 기다린다
  for _ in $(seq 1 50); do
    grep -m1 '^http' "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}
google_run connect 2>"$AG_T/connect.err" &
AG_CPID=$!
track_test_process "$AG_CPID"
AG_AUTH="$(google_auth_url "$AG_T/connect.err")" || fail "connect prints the consent URL without a browser"
assert_contains "$AG_AUTH" "$AG_GBASE/auth?" "connect uses the auth endpoint"
assert_contains "$AG_AUTH" "code_challenge_method=S256" "connect uses PKCE S256"
assert_contains "$AG_AUTH" "state=" "connect sends a state"
assert_contains "$AG_AUTH" "scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.readonly" "connect asks only for calendar.readonly"
assert_contains "$AG_AUTH" "redirect_uri=http%3A%2F%2F127.0.0.1%3A" "connect listens on a 127.0.0.1 loopback"
AG_DONE="$(curl -s -L -D "$AG_T/done.headers" "$AG_AUTH")"
assert_contains "$(cat "$AG_T/done.headers")" "text/html" "the loopback answers with an HTML page"
assert_contains "$AG_DONE" "구글 캘린더를 연결했습니다" "the page says the connection is done"
assert_contains "$AG_DONE" "history.replaceState" "the page clears code and state from the address bar"
assert_contains "$AG_DONE" "window.close()" "the page tries to close its own tab"
assert_contains "$AG_DONE" "Content-Security-Policy" "the page allows only its own inline script and style"
case "$AG_DONE" in *code-*) fail "the page does not echo the authorization code" ;; esac
wait "$AG_CPID" || fail "connect finishes after the redirect: $(cat "$AG_T/connect.err")"
assert_contains "$(cat "$AG_GSTATE/token-calls")" "pkce-ok client=fake-client-id" "the token endpoint verified the code verifier with the user's own client"
AG_GTOK="$AG_GD/board/agenda/google-accounts/me@example.com.json"
assert_eq "600" "$(filemode "$AG_GTOK")" "the account token file is private"
assert_eq "700" "$(filemode "$AG_GD/board/agenda/google-accounts")" "the account folder is private"
case "$(cat "$AG_T/connect.err")" in *SECRET*) fail "connect does not print tokens or the client secret" ;; esac
assert_eq '{"id":"me@example.com","name":"me@example.com"}' "$(google_run accounts)" "accounts lists the connected account by its address"
pass "google connect runs a loopback PKCE flow"

# 공용 클라이언트: 사용자 클라이언트 파일이 없으면 플러그인에 든 클라이언트로 연결한다.
AG_GD3="$AG_T/google-data-3"; mkdir -p "$AG_GD3"
: >"$AG_GSTATE/token-calls"
google_env HM_DATA_DIR="$AG_GD3" BOARD_NO_BROWSER=1 python3 -I "$AG_GOOGLE" connect 2>"$AG_T/connect3.err" &
AG_CPID=$!
track_test_process "$AG_CPID"
AG_AUTH="$(google_auth_url "$AG_T/connect3.err")" || fail "connect with the built-in client prints the consent URL"
AG_BUILTIN_ID="$(jq -r '.installed.client_id' "$ROOT/scripts/board/agenda/google/client.json")"
assert_contains "$AG_AUTH" "client_id=$AG_BUILTIN_ID" "connect uses the built-in client id"
curl -s -L -o /dev/null "$AG_AUTH"
wait "$AG_CPID" || fail "connect with the built-in client finishes: $(cat "$AG_T/connect3.err")"
assert_contains "$(cat "$AG_GSTATE/token-calls")" "pkce-ok client=$AG_BUILTIN_ID" "the token exchange uses the built-in client"
case "$(cat "$AG_T/connect3.err")" in *"$(jq -r '.installed.client_secret' "$ROOT/scripts/board/agenda/google/client.json")"*) fail "connect does not print the built-in client secret" ;; esac
pass "google connects with the built-in client when the user has none"

# state가 다르면 거부하고 토큰을 만들지 않는다.
AG_GD2="$AG_T/google-data-2"; mkdir -p "$AG_GD2"; cp "$AG_DATA/google-oauth-client.json" "$AG_GD2/"
google_env HM_DATA_DIR="$AG_GD2" BOARD_NO_BROWSER=1 python3 -I "$AG_GOOGLE" connect 2>"$AG_T/connect2.err" &
AG_CPID=$!
track_test_process "$AG_CPID"
AG_AUTH="$(google_auth_url "$AG_T/connect2.err")" || fail "second connect prints the consent URL"
AG_REDIRECT="$(python3 -I -c 'import sys; from urllib.parse import parse_qs, urlparse; print(parse_qs(urlparse(sys.argv[1]).query)["redirect_uri"][0])' "$AG_AUTH")"
curl -s -o /dev/null "$AG_REDIRECT/?code=code-x&state=forged"
if wait "$AG_CPID"; then fail "connect refuses a forged state"; fi
assert_contains "$(cat "$AG_T/connect2.err")" "state" "the refusal names the state check"
assert_not_file "$AG_GD2/board/agenda/google-token.json"
pass "google connect refuses a mismatched state"

# 9. 구글 fetch: 선택한 캘린더만, 만료 토큰은 refresh, refresh가 실패하면 종료 코드로 알린다.
AG_EV="$(google_run fetch --since 2026-11-24T00:00:00+09:00 --until 2026-12-01T00:00:00+09:00)" || fail "google fetch succeeds"
assert_eq "team@example.com:ev1|event|주간 회의" "$(jq -rs 'map("\(.id)|\(.kind)|\(.title)") | join(",")' <<<"$AG_EV")" "only selected calendars' live events are listed"
assert_contains "$(cat "$AG_GSTATE/events-calls")" '"singleEvents": "true"' "events expand recurring series"
assert_contains "$(cat "$AG_GSTATE/events-calls")" '"timeMin": "2026-11-24T00:00:00+09:00"' "events start at the requested window"
gexpire() { jq '.expires_at = 0' "$1" >"$AG_T/tok.json"; mv "$AG_T/tok.json" "$1"; chmod 600 "$1"; }
gexpire "$AG_GTOK"
google_run fetch >/dev/null || fail "google fetch refreshes an expired token"
assert_contains "$(cat "$AG_GSTATE/token-calls")" "refresh_token" "the refresh endpoint was called"
assert_eq "fake-access-SECRET-2|fake-refresh-SECRET-1" "$(jq -r '"\(.access_token)|\(.refresh_token)"' "$AG_GTOK")" "a refresh keeps the refresh token"
gexpire "$AG_GTOK"
: >"$AG_GSTATE/refresh-fail"
if google_run fetch >/dev/null 2>"$AG_T/fetch.err"; then fail "google fetch fails when every account's refresh is refused"; fi
assert_contains "$(cat "$AG_T/fetch.err")" "다시 연결하세요" "a refused refresh asks to reconnect"
assert_contains "$(google_run accounts)" '"error"' "the refused account shows its error in the account list"
rm -f "$AG_GSTATE/refresh-fail"
if google_env HM_DATA_DIR="$AG_GD2" python3 -I "$AG_GOOGLE" fetch >/dev/null 2>"$AG_T/fetch2.err"; then fail "google fetch fails without a token"; fi
assert_contains "$(cat "$AG_T/fetch2.err")" "연결돼 있지 않습니다" "fetch without a token explains it"
pass "google fetch lists selected calendars and refreshes tokens"

# 9-1. 여러 구글 계정: 계정을 더하면 일정이 합쳐지고(같은 캘린더는 한 번), 한 계정이 만료돼도 나머지는 보이며, 하나씩 끊는다.
gconnect() { # 계정 → 그 계정으로 연결
  printf '%s' "$1" >"$AG_GSTATE/next-account"
  google_run connect 2>"$AG_T/connect-$1.err" &
  local pid=$!
  track_test_process "$pid"
  local url; url="$(google_auth_url "$AG_T/connect-$1.err")" || fail "connect for $1 prints the consent URL"
  curl -s -L -o /dev/null "$url"
  wait "$pid" || fail "connect for $1 finishes: $(cat "$AG_T/connect-$1.err")"
}
gconnect me@example.com
gconnect work@example.com
rm -f "$AG_GSTATE/next-account"
assert_eq "me@example.com,work@example.com" "$(google_run accounts | jq -rs 'map(.id) | join(",")')" "two accounts are connected"
AG_EV="$(google_run fetch)" || fail "fetch with two accounts succeeds"
assert_eq "team@example.com:ev1,work@example.com:ev1" "$(jq -rs 'map(.id) | sort | join(",")' <<<"$AG_EV")" "events from both accounts are merged and a shared calendar shows once"
gexpire "$AG_GD/board/agenda/google-accounts/work@example.com.json"
: >"$AG_GSTATE/refresh-fail-work@example.com"
AG_EV="$(google_run fetch 2>"$AG_T/fetch3.err")" || fail "one expired account does not fail the fetch: $(cat "$AG_T/fetch3.err")"
assert_eq "team@example.com:ev1" "$(jq -rs 'map(.id) | join(",")' <<<"$AG_EV")" "the healthy account's events stay"
assert_eq "work@example.com" "$(google_run accounts | jq -rs 'map(select(.error)) | map(.id) | join(",")')" "only the expired account shows an error"
rm -f "$AG_GSTATE/refresh-fail-work@example.com"
gconnect work@example.com
rm -f "$AG_GSTATE/next-account"
assert_eq "" "$(google_run accounts | jq -rs 'map(select(.error)) | map(.id) | join(",")')" "reconnecting the account clears its error"
: >"$AG_GSTATE/revoke-calls"
if google_run disconnect nobody@example.com 2>/dev/null; then fail "disconnect refuses an unknown account"; fi
if google_run disconnect ../google-token 2>/dev/null; then fail "disconnect refuses a path-like account"; fi
google_run disconnect work@example.com || fail "google disconnects one account"
assert_eq "me@example.com" "$(google_run accounts | jq -rs 'map(.id) | join(",")')" "the other account remains"
assert_contains "$(cat "$AG_GSTATE/revoke-calls")" "revoke" "disconnecting an account revokes its token"
google_run disconnect || fail "google disconnect without an account removes all"
assert_eq "" "$(google_run accounts)" "no accounts remain"
pass "google connects several accounts, merges their calendars, and disconnects one at a time"

# 9-2. 예전 단일 토큰(google-token.json)은 그대로 이어 쓰고, 처음 수집할 때 계정 주소로 옮긴다.
jq -n --argjson e "$(($(date +%s) + 3600))" '{access_token: "fake-access-SECRET-1", refresh_token: "fake-refresh-SECRET-1", expires_at: $e}' >"$AG_GD/board/agenda/google-token.json"
chmod 600 "$AG_GD/board/agenda/google-token.json"
assert_eq "1" "$(google_run accounts | jq -s 'length')" "a legacy token shows as one account"
google_run fetch >/dev/null || fail "fetch works with a legacy token"
assert_not_file "$AG_GD/board/agenda/google-token.json"
assert_eq "me@example.com" "$(google_run accounts | jq -rs 'map(.id) | join(",")')" "the legacy token moved to its account address"
# 같은 계정 파일이 이미 있으면 예전 토큰만 지우고 계정 파일은 그대로 둔다.
cp "$AG_GD/board/agenda/google-accounts/me@example.com.json" "$AG_T/me-before.json"
jq -n --argjson e "$(($(date +%s) + 3600))" '{access_token: "fake-access-SECRET-1", refresh_token: "fake-refresh-SECRET-legacy", expires_at: $e}' >"$AG_GD/board/agenda/google-token.json"
chmod 600 "$AG_GD/board/agenda/google-token.json"
google_run fetch >/dev/null || fail "fetch with a legacy token and an existing account file"
assert_not_file "$AG_GD/board/agenda/google-token.json"
assert_eq "fake-refresh-SECRET-1" "$(jq -r '.refresh_token' "$AG_GD/board/agenda/google-accounts/me@example.com.json")" "the existing account file is kept"
google_run disconnect || fail "disconnect after migration"
pass "google keeps a legacy single token working and moves it to its account"

# 11. 보드를 거친 구글 수집: 응답·로그에 토큰과 client secret이 없다.
jq -n --argjson e "$(($(date +%s) + 3600))" '{access_token: "fake-access-SECRET-1", refresh_token: "fake-refresh-SECRET-1", expires_at: $e}' >"$AG_DATA/board/agenda/google-token.json"
chmod 600 "$AG_DATA/board/agenda/google-token.json"
jq '.google = {connected: true, at: "2026-11-24T00:00:00Z"}' "$AG_DATA/board/agenda/sources.json" >"$AG_T/src.json"; mv "$AG_T/src.json" "$AG_DATA/board/agenda/sources.json"
AG_OUT="$(ag_wait '[.items.event[] | select(.source == "google")] | length == 1')" || fail "the board fetches google events: $AG_OUT"
assert_eq "구글 캘린더|팀 캘린더" "$(jq -r '.items.event[] | select(.source == "google") | "\(.source_name)|\(.detail)"' <<<"$AG_OUT")" "google events show on the board"
for AG_SECRET in fake-client-SECRET-xyz fake-access-SECRET fake-refresh-SECRET; do
  case "$AG_OUT" in *"$AG_SECRET"*) fail "the agenda response carries no $AG_SECRET" ;; esac
  if grep -rqs "$AG_SECRET" "$AG_DATA/board/server.log" "$AG_DATA/board/actions.jsonl"; then fail "board logs carry no $AG_SECRET"; fi
done
pass "agenda keeps tokens and the client secret out of responses and logs"

# 공개 저장소: 공용 OAuth 클라이언트 값은 client.json 하나에만 있고, 조직 식별자는 어디에도 없다.
AG_CLIENT="$ROOT/scripts/board/agenda/google/client.json"
assert_eq "true" "$(jq -r '.installed | (.client_id | endswith(".apps.googleusercontent.com")) and (.client_secret | length > 0)' "$AG_CLIENT")" "the built-in client is a desktop (installed) client"
AG_LEAK="$(grep -rlE 'apps\.googleusercontent\.com|GOCSPX-' "$ROOT/scripts" "$ROOT/skills" "$ROOT/docs" "$ROOT/tests" "$ROOT/README.md" | grep -vxF "$AG_CLIENT" | grep -v '/tests/board-agenda.sh$' || true)"
assert_eq "" "$AG_LEAK" "client values live only in client.json"
if grep -rqiE 'midas|jobda|khb1122' "$ROOT/scripts/board/agenda.py" "$ROOT/scripts/board/agenda" "$ROOT/docs/privacy.md" "$AG_FIX"; then
  fail "agenda files carry no organization identifiers"
fi
pass "agenda files keep client values in one place and carry no identifiers"

# 12. 안내 문서: setup이 직접 만드는 OAuth 클라이언트를, privacy가 읽는 것·저장 위치·중개 서버 없음을 말한다.
AG_SETUP="$(<"$ROOT/skills/setup/SKILL.md")"
assert_contains "$AG_SETUP" "8-4. 내 일정 — 구글 캘린더 연결 (선택)" "setup has the calendar section"
assert_contains "$AG_SETUP" "google-oauth-client.json" "setup names the client file"
assert_contains "$AG_SETUP" "calendar.readonly" "setup names the scope"
assert_contains "$AG_SETUP" "데스크톱 앱" "setup explains an optional desktop app client"
assert_contains "$AG_SETUP" "[계정 추가]" "setup explains adding accounts"
assert_contains "$AG_SETUP" "따로 준비할 것은 없다" "setup says the built-in client needs no preparation"
AG_PRIV="$(<"$ROOT/docs/privacy.md")"
assert_contains "$AG_PRIV" "calendar.readonly" "privacy names the scope"
assert_contains "$AG_PRIV" ".ai-harness/board/agenda" "privacy names where data is stored"
assert_contains "$AG_PRIV" "중개 서버" "privacy says there is no relay server"
assert_contains "$AG_PRIV" "google-accounts/<계정>.json" "privacy names the per-account token files"
assert_contains "$AG_PRIV" "PKCE" "privacy explains why the built-in client value is not a secret"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "board.sh todo" "board skill describes the to-do CLI"
pass "agenda guides and privacy notes are in place"

ag_board stop >/dev/null
finish_tests
