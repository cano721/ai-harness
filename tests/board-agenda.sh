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
# 가짜 claude: agents는 agents.json을 그대로, --bg는 인자(호출마다 한 줄)·cwd를 남기고 busy 세션 하나를 agents.json에 더한다(#525).
printf '[]\n' >"$AG_T/agents.json"
cat >"$AG_T/bin/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == agents ]]; then cat "$AG_T/agents.json"; exit 0; fi
if [[ "\$1" == --bg ]]; then
  { printf '%s' "\$*" | tr '\n' ' '; echo; } >>"$AG_T/claude.log"; printf '%s\n' "\$PWD" >>"$AG_T/claude-cwd.log"
  n="\$(wc -l <"$AG_T/claude.log" | tr -d ' ')"
  jq --arg n "\$3" --arg sid "\$(printf 'cccccccc-0000-0000-0000-%012d' "\$n")" --argjson at "\$(date +%s)000" --arg cwd "\$PWD" \
    '. + [{sessionId:\$sid, id:\$sid[0:8], kind:"background", status:"busy", state:"running", pid:4242, cwd:\$cwd, name:\$n, startedAt:\$at}]' \
    "$AG_T/agents.json" >"$AG_T/agents.tmp" && mv "$AG_T/agents.tmp" "$AG_T/agents.json"
  echo "backgrounded"; exit 0
fi
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
# 사용자 셸의 Jira 키가 내장 jira 소스(#648)로 새지 않게 뺀다. 키는 블록이 settings.json·secrets.env로만 준다.
ag_board() {
  google_env env -u ATLASSIAN_USER -u ATLASSIAN_API_TOKEN JIRA_BASE_URL= \
    PATH="$AG_T/bin:$PATH" HARNESS_METRICS_DIR="$AG_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$AG_T/projects" \
    HARNESS_CLAUDE_SETTINGS="$AG_T/settings.json" BOARD_PORT="$AG_PORT" BOARD_NO_BROWSER=1 BOARD_IDLE_EXIT=0 \
    BOARD_AGENDA_FETCH_TIMEOUT=3 BOARD_FULL_REFRESH_SECONDS=2 bash "$ROOT/scripts/board/board.sh" "$@"
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

# 11. 기한·아침 요약·한 번에 보는 요약(#539): 할 일 기한은 CLI·보드·어댑터 셋 다 받고, 요약은 아침 알림이 읽는다.
AG_DID="$(ag_board todo add --due 2026-12-01 기한 있는 일)"
assert_eq "2026-12-01" "$(ag_get | jq -r --arg i "$AG_DID" '.items.todo[] | select(.id == $i) | .due')" "todo add --due keeps the due date"
assert_eq "기한 있는 일" "$(ag_get | jq -r --arg i "$AG_DID" '.items.todo[] | select(.id == $i) | .title')" "--due is not part of the title"
ag_board todo add --due 2026-13-45 잘못된 기한 >/dev/null 2>&1 && fail "todo add refuses an impossible due date"
AG_RES="$(ag_post todo '{"text":"보드에서 기한 적은 일","due":"2026-12-02T18:00"}')"
assert_eq "200" "$(ag_code "$AG_RES")" "the board adds a to-do with a due time"
assert_eq "2026-12-02T18:00" "$(ag_get | jq -r --arg i "$(ag_body "$AG_RES" | jq -r .id)" '.items.todo[] | select(.id == $i) | .due')" "the board keeps the due time"
assert_eq "400" "$(ag_code "$(ag_post todo '{"text":"x","due":"내일"}')")" "the board refuses a due that is not a date"
ag_post connect '{"source":"acme"}' >/dev/null
AG_OUT="$(ag_wait '[.items.todo[] | select(.source == "acme")] | length == 1')" || fail "acme to-do came back"
assert_eq "2026-01-02T09:00:00+09:00" "$(jq -r '.items.todo[] | select(.source == "acme") | .due' <<<"$AG_OUT")" "an adapter to-do keeps its due"
AG_SUM="$(ag_board agenda summary)"
assert_eq "true" "$(jq -r '.ok' <<<"$AG_SUM")" "agenda summary prints JSON"
assert_eq "t1" "$(jq -r '.todos[0].id' <<<"$AG_SUM")" "summary puts the earliest due first"
assert_eq "true" "$(jq -r '.todos[0].overdue' <<<"$AG_SUM")" "summary marks a past due as overdue"
assert_eq "true" "$(jq -r '(.replies | length) >= 1 and (.events_today | type) == "array"' <<<"$AG_SUM")" "summary carries replies and today's events"
printf '오늘 할 일 3건\n- 첫째\n' | ag_board brief set --source "아침 요약" >/dev/null || fail "brief set reads stdin"
AG_OUT="$(ag_get)"
assert_eq "오늘 할 일 3건" "$(jq -r '.brief.text | split("\n")[0]' <<<"$AG_OUT")" "the board shows the latest brief"
assert_eq "아침 요약" "$(jq -r '.brief.source' <<<"$AG_OUT")" "the brief names where it came from"
assert_eq "600" "$(filemode "$AG_DATA/board/agenda/brief.json")" "brief.json is private"
assert_contains "$(ag_board brief show)" "- 첫째" "brief show prints the text"
printf '' | ag_board brief set >/dev/null 2>&1 && fail "brief set refuses empty text"
AG_RES="$(ag_post "done" "$(jq -cn --arg i "$AG_DID" '{source: "todo", id: $i}')")"
assert_eq "true" "$(ag_body "$AG_RES" | jq -r '.undo')" "finishing a written to-do can be undone"
assert_eq "200" "$(ag_code "$(ag_post reopen "$(jq -cn --arg i "$AG_DID" '{source: "todo", id: $i}')")")" "reopen brings a finished to-do back"
assert_eq "기한 있는 일" "$(ag_get | jq -r --arg i "$AG_DID" '.items.todo[] | select(.id == $i) | .title')" "the reopened to-do is listed again"
assert_eq "false" "$(ag_body "$(ag_post "done" '{"source":"acme","id":"r2"}')" | jq -r '.undo')" "an adapter completion says it cannot be undone"
assert_eq "409" "$(ag_code "$(ag_post reopen '{"source":"acme","id":"r2"}')")" "reopen refuses what the adapter already finished"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $AG_BASE" -d '{"t":"wrong","source":"todo","id":"x"}' "$AG_BASE/agenda/reopen")" "reopen needs the board token"
pass "to-dos carry due dates and the morning brief lands on the board"

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
case "$AG_DONE" in *"<button"*) fail "the page has no close button the browser would block" ;; esac
assert_contains "$AG_DONE" "⌘W" "the page tells how to close the tab when the browser blocks it"
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
if ! bash "$ROOT/scripts/identifier-scan.sh" "$ROOT/scripts/board/agenda.py" "$ROOT/scripts/board/agenda" "$ROOT/docs/privacy.md" "$AG_FIX" >/dev/null; then
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

# 13. [설정하기] 설정 세션(#525): #494 장치(POST /settings/skills/session, kind agenda)를 재사용한다.
# 지시문은 서버가 agenda.json setup_prompt로 만들고, 소스 id는 발견된 목록만 받는다. 구글은 공용 클라이언트(#519)라 설정 세션이 없다.
ag_sess() { # 세션 요청 본문(JSON) → 응답 본문
  curl -s -X POST -H "Origin: $AG_BASE" -d "$(jq -cn --arg t "$AG_TOKEN" --argjson b "$1" '$b + {t: $t}')" "$AG_BASE/settings/skills/session"
}
ag_log_lines() { if [[ -f "$AG_T/claude.log" ]]; then wc -l <"$AG_T/claude.log" | tr -d ' '; else echo 0; fi; }
AG_SESS_JSON="$AG_DATA/board/skill-sessions.json"
AG_RESPONSES="$AG_T/session-responses.txt"; : >"$AG_RESPONSES"
mkdir -p "$HM_CLAUDE_SKILLS_DIR/needsetup" "$HM_CLAUDE_SKILLS_DIR/hintonly" "$HM_CLAUDE_SKILLS_DIR/badprompt" "$HM_CLAUDE_SKILLS_DIR/badprompt2"
AG_PAD="$(head -c 1100 /dev/zero | tr '\0' x)"
jq -n --arg p "MARKER-525-PROMPT  준비 순서를 안내합니다. $AG_PAD TAIL-525" \
  '{id: "needsetup", name: "설정 세션 소스", fetch: ["true"], requires: ["$HM_DATA_DIR/needsetup-missing"], setup_prompt: $p}' >"$HM_CLAUDE_SKILLS_DIR/needsetup/agenda.json"
jq -n '{id: "hintonly", name: "안내만 있는 소스", fetch: ["true"], requires: ["$HM_DATA_DIR/hintonly-missing"], setup_hint: "HINT-525 안내대로 준비합니다."}' >"$HM_CLAUDE_SKILLS_DIR/hintonly/agenda.json"
jq -n '{id: "badprompt", name: "숫자 지시문", fetch: ["true"], setup_prompt: 5}' >"$HM_CLAUDE_SKILLS_DIR/badprompt/agenda.json"
jq -n '{id: "badprompt2", name: "배열 지시문", fetch: ["true"], setup_prompt: ["a"]}' >"$HM_CLAUDE_SKILLS_DIR/badprompt2/agenda.json"

AG_OUT="$(ag_wait '(.sources[] | select(.id == "needsetup") | .state) == "needs_setup"')" || fail "a source with a missing requires file needs setup: $AG_OUT"
echo "$AG_OUT" >>"$AG_RESPONSES"
assert_eq "true|null" "$(ag_src "$AG_OUT" needsetup setup_session)|$(ag_src "$AG_OUT" needsetup session)" "a source with setup_prompt offers a setup session and none is running yet"
assert_eq "false" "$(ag_src "$AG_OUT" google setup_session)" "the built-in google source offers no setup session"
case "$AG_OUT" in *MARKER-525*) fail "the agenda response never carries the setup_prompt text" ;; esac

# A1·A4·A7 스킬 소스: setup_prompt를 고정 머리말·꼬리말로 감싸고 1000자로 자른다. 브라우저 문자열은 넣지 않는다. 홈에서 claude --bg.
AG_RES="$(ag_sess '{"kind":"agenda","name":"needsetup","action":"setup","prompt":"INJECTED-525","hint":"INJECTED-525"}')"; echo "$AG_RES" >>"$AG_RESPONSES"
assert_eq "true" "$(jq -r '.ok' <<<"$AG_RES")" "a skill source setup session starts"
AG_LOG="$(sed -n 1p "$AG_T/claude.log")"
assert_contains "$AG_LOG" "--bg --name 내 일정: 소스 설정 needsetup" "the session is named for the source id"
assert_contains "$AG_LOG" "MARKER-525-PROMPT 준비 순서를 안내합니다." "the declared setup_prompt reaches the session (whitespace collapsed)"
assert_contains "$AG_LOG" "일정 소스 needsetup의 [설정하기]로 띄운 세션입니다" "the server adds a fixed header"
assert_contains "$AG_LOG" "대화로 받지 않" "the server adds the secret rule footer"
case "$AG_LOG" in *TAIL-525*) fail "a setup_prompt over 1000 characters is cut" ;; esac
case "$(<"$AG_T/claude.log")" in *INJECTED-525*) fail "browser text never reaches the agenda session prompt" ;; esac
assert_eq "$HOME" "$(sed -n 1p "$AG_T/claude-cwd.log")" "the agenda setup session runs in the home folder"

# A2 기록과 상태: skill-sessions.json의 agenda:<id>, /agenda 소스의 session
assert_eq "cccccccc-0000-0000-0000-000000000001 setup" "$(jq -r '.["agenda:needsetup"] | "\(.sid) \(.action)"' "$AG_SESS_JSON")" "the session is recorded under agenda:needsetup"
AG_OUT="$(ag_wait '(.sources[] | select(.id == "needsetup") | .session.state) == "running"')" || fail "a running setup session shows on the source: $AG_OUT"
echo "$AG_OUT" >>"$AG_RESPONSES"
assert_eq "setup|true" "$(ag_src "$AG_OUT" needsetup session.action)|$(ag_src "$AG_OUT" needsetup setup_session)" "the source carries the session action"
pass "agenda skill sources start a recorded setup session from their setup_prompt"

# A5 지시문 없는 소스: setup_hint 펼침만, 세션 요청은 거부
assert_eq "false|HINT-525 안내대로 준비합니다." "$(ag_src "$AG_OUT" hintonly setup_session)|$(ag_src "$AG_OUT" hintonly setup_hint)" "a source without setup_prompt keeps only its hint"
AG_N="$(ag_log_lines)"
AG_RES="$(ag_sess '{"kind":"agenda","name":"hintonly","action":"setup"}')"; echo "$AG_RES" >>"$AG_RESPONSES"
assert_eq "false" "$(jq -r '.ok' <<<"$AG_RES")" "a source without a setup prompt starts no session"
assert_eq "$AG_N" "$(ag_log_lines)" "no claude session is started for a hint-only source"
pass "agenda sources without setup_prompt keep the hint"

# A6 화이트리스트: 모르는 id·경로·숫자·null, 설정이 필요 없는 소스, 다른 동작, 선언 오류는 모두 거부. 토큰·Origin은 403.
for AG_BODY in '{"kind":"agenda","name":"nope","action":"setup"}' '{"kind":"agenda","name":"../x","action":"setup"}' \
  '{"kind":"agenda","name":5,"action":"setup"}' '{"kind":"agenda","name":null,"action":"setup"}' \
  '{"kind":"agenda","name":"acme","action":"setup"}' '{"kind":"agenda","name":"needsetup","action":"install"}' \
  '{"kind":"agenda","name":"needsetup","action":"remove"}' '{"kind":"agenda","name":"bad","action":"setup"}' \
  '{"kind":"agenda","name":"badprompt","action":"setup"}' '{"kind":"agenda","name":"google","action":"setup"}'; do
  AG_RES="$(ag_sess "$AG_BODY")"; echo "$AG_RES" >>"$AG_RESPONSES"
  assert_eq "false" "$(jq -r '.ok' <<<"$AG_RES")" "agenda session request is refused: $AG_BODY"
done
assert_eq "$AG_N" "$(ag_log_lines)" "refused requests start no claude session"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $AG_BASE" -d '{"t":"wrong","kind":"agenda","name":"needsetup","action":"setup"}' "$AG_BASE/settings/skills/session")" "an agenda session needs the board token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://attacker.example' -d "$(jq -cn --arg t "$AG_TOKEN" '{t: $t, kind: "agenda", name: "needsetup", action: "setup"}')" "$AG_BASE/settings/skills/session")" "an agenda session refuses a foreign Origin"
assert_eq "$AG_N" "$(ag_log_lines)" "forbidden requests start no claude session"
pass "agenda setup sessions accept only discovered sources that need setup"

# A9 선언 검사: setup_prompt가 문자열이 아니면 선언 오류
for AG_BP in badprompt badprompt2; do
  assert_eq "true" "$(ag_src "$AG_OUT" "$AG_BP" invalid)" "$AG_BP is a declaration error"
  assert_contains "$(ag_src "$AG_OUT" "$AG_BP" error)" "setup_prompt" "the $AG_BP error names setup_prompt"
done
pass "agenda rejects a non-string setup_prompt"

# A3 종료와 재조회: 세션이 끝나면 기록을 지우고, requires 파일이 생겼으면 연결할 수 있는 상태로 보인다.
: >"$AG_DATA/needsetup-missing"
printf '[]\n' >"$AG_T/agents.json"
# 작업 목록은 보는 화면이 있을 때만 뒤에서 다시 모은다(/status.json이 표시) — 화면처럼 작업 현황도 함께 읽는다.
# 지문에 없는 가짜 agents.json 변화는 전체 수집 주기(위 ag_board의 BOARD_FULL_REFRESH_SECONDS=2)마다 보인다.
AG_OUT=""
for _ in $(seq 1 75); do
  curl -s -o /dev/null "$AG_BASE/status.json?t=$AG_TOKEN"
  AG_OUT="$(ag_get)"
  if jq -e '(.sources[] | select(.id == "needsetup")) | .session == null and .state == "disconnected"' >/dev/null 2>&1 <<<"$AG_OUT"; then break; fi
  AG_OUT=""; sleep 0.2
done
[[ -n "$AG_OUT" ]] || fail "a finished session refreshes the source"
echo "$AG_OUT" >>"$AG_RESPONSES"
assert_eq "null" "$(jq -c '.["agenda:needsetup"]' "$AG_SESS_JSON")" "a finished agenda session record is dropped"
pass "agenda refreshes a source after its setup session ends"

# A8 비밀 미노출: client secret이 지시문·기록·응답 어디에도 없다.
for AG_F in "$AG_T/claude.log" "$AG_SESS_JSON" "$AG_DATA/board/actions.jsonl" "$AG_RESPONSES"; do
  if grep -qs "fake-client-SECRET-xyz" "$AG_F"; then fail "the client secret never reaches $AG_F"; fi
done
pass "agenda setup sessions keep the client secret out of prompts, records and responses"

# A10 화면: 설정 세션 소스는 공용 장치로 띄우고 내 일정을 다시 읽는다. 지시문 없는 소스는 펼침을 유지한다.
AG_TPL="$(<"$ROOT/scripts/board/template.html")"
assert_contains "$AG_TPL" "s.state === 'needs_setup' && s.setup_session" "the source button branches on setup_session"
assert_contains "$AG_TPL" "startSetupSession({ kind: 'agenda', name: s.id, action: 'setup' }, b, () => loadAgenda(true))" "the source button launches the shared setup session and reloads the agenda"
assert_contains "$AG_TPL" "async function startSetupSession(body, b, reload" "the launcher takes a reload callback"
assert_contains "$AG_TPL" "aria-controls', 'agsetup-' + s.id" "hint-only sources keep the expandable hint"
assert_contains "$AG_TPL" "x.fetching || x.session" "the agenda polls faster while a setup session runs"
pass "agenda screen launches setup sessions through the shared launcher"

rm -rf "$HM_CLAUDE_SKILLS_DIR/needsetup" "$HM_CLAUDE_SKILLS_DIR/hintonly" "$HM_CLAUDE_SKILLS_DIR/badprompt" "$HM_CLAUDE_SKILLS_DIR/badprompt2"

ag_board stop >/dev/null

# 14. '지금·다음' 재구성(#567): 실제 시각순 일정, created·from·shared, reopen 계약, 완료함.
# 시간대를 고정한 새 보드(새 데이터 디렉터리)로 띄운다 — 앞 블록의 연결·완료 기록과 섞이지 않게.
AG_DATA="$AG_T/data-567"; mkdir -p "$AG_DATA"
AG_PORT="$(free_port)"
export TZ=Asia/Seoul
AG_OPEN="$(ag_board open)"
AG_URL="$(jq -r '.url' <<<"$AG_OPEN")"
AG_TOKEN="${AG_URL#*t=}"
AG_BASE="http://127.0.0.1:$AG_PORT"
track_test_process "$(jq -r '.pid' "$AG_DATA/board/server.json")"

# AC1: 같은 날 일정은 오프셋과 무관하게 종일 → 10:00 → 19:00(10:00Z) → 19:15(21:15+11:00) → 19:30, 다음 날 일정은 맨 뒤.
ag_post connect '{"source":"tz"}' >/dev/null
AG_OUT="$(ag_wait '[.items.event[] | select(.source == "tz")] | length == 6')" || fail "tz fetches its events: $AG_OUT"
assert_eq "z-allday z-morning z-utc z-east z-late z-next" "$(jq -r '[.items.event[] | select(.source == "tz") | .id] | join(" ")' <<<"$AG_OUT")" "events sort by real time across offsets, all-day first"
# AC2(shared): 팀·공유 캘린더 일정 표시가 남는다. 없는 일정에는 붙지 않는다.
assert_eq "true|null" "$(jq -r '[(.items.event[] | select(.id == "z-allday") | .shared), (.items.event[] | select(.id == "z-morning") | .shared)] | map(tostring) | join("|")' <<<"$AG_OUT")" "shared stays on a shared calendar event only"
pass "agenda sorts events by real time and keeps the shared flag"

# AC2: created(ISO)·from은 남고, 읽을 수 없는 created는 필드만 빠진다.
ag_post connect '{"source":"inbox"}' >/dev/null
AG_OUT="$(ag_wait '[.items.todo[] | select(.source == "inbox")] | length == 4')" || fail "inbox fetches its items: $AG_OUT"
AG_NEWC="$(jq -r '.items.todo[] | select(.id == "i-new") | .created' <<<"$AG_OUT")"
[[ "$AG_NEWC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$ ]] || fail "created stays as ISO 8601 (got $AG_NEWC)"
assert_eq "예시 담당자" "$(jq -r '.items.todo[] | select(.id == "i-new") | .from' <<<"$AG_OUT")" "from stays on the item"
assert_eq "받은 시각을 모르는 요청|null" "$(jq -r '.items.todo[] | select(.id == "i-bad") | "\(.title)|\(.created)"' <<<"$AG_OUT")" "an unreadable created is dropped but the item stays"
pass "agenda keeps created and from on adapter items"

# AC3: 직접 적은 할 일은 만든 시각을 created로 낸다.
AG_TID="$(ag_board todo add 예시 할 일)"
AG_TC="$(ag_get | jq -r --arg i "$AG_TID" '.items.todo[] | select(.source == "todo" and .id == $i) | .created')"
[[ "$AG_TC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$ ]] || fail "a written to-do carries created (got $AG_TC)"
pass "a written to-do carries its creation time"

# AC4: reopen을 선언한 어댑터의 done은 되돌릴 수 있고, 완료함에 제목·시각만 남는다(본문 없음).
AG_RES="$(ag_post "done" '{"source":"inbox","id":"i-new"}')"
assert_eq "200|true|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')|$(ag_body "$AG_RES" | jq -r '.undo')" "done on a reopen source can be undone"
assert_eq "done i-new" "$(tail -n 1 "$AG_DATA/fixture-inbox/calls")" "the adapter done command ran with the item id"
AG_OUT="$(ag_get)"
assert_eq "예시 검토 요청|true|todo|Example 요청함" "$(jq -r '.completed[] | select(.source == "inbox" and .id == "i-new") | "\(.title)|\(.can_reopen)|\(.kind)|\(.source_name)"' <<<"$AG_OUT")" "the completion lands in the completed list"
[[ -n "$(jq -r '.completed[] | select(.id == "i-new") | .done_at // empty' <<<"$AG_OUT")" ]] || fail "the completed row carries done_at"
assert_eq "null" "$(jq -r '.completed[] | select(.id == "i-new") | .detail' <<<"$AG_OUT")" "the completed row carries no body"
assert_eq "600" "$(filemode "$AG_DATA/board/agenda/completed.json")" "completed.json is private"
pass "agenda records adapter completions in the completed list"

# AC5: reopen은 선언한 argv에 항목 id를 붙여 부르고, 완료함에서 빼고 항목을 되살린다.
AG_RES="$(ag_post reopen '{"source":"inbox","id":"i-new"}')"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "reopen on a reopen source succeeds"
assert_eq "reopen i-new" "$(tail -n 1 "$AG_DATA/fixture-inbox/calls")" "the adapter reopen command ran with the item id"
AG_OUT="$(ag_wait '[.items.todo[] | select(.id == "i-new")] | length == 1')" || fail "the reopened item is listed again: $AG_OUT"
assert_eq "0" "$(jq -r '[.completed[] | select(.id == "i-new")] | length' <<<"$AG_OUT")" "the reopened item leaves the completed list"
# reopen 명령이 실패하면 ok:false와 어댑터 사유를 돌려주고 완료함에 남긴다.
ag_post "done" '{"source":"inbox","id":"i-old"}' >/dev/null
: >"$AG_DATA/fixture-inbox/fail-reopen"
AG_RES="$(ag_post reopen '{"source":"inbox","id":"i-old"}')"
assert_eq "false" "$(ag_body "$AG_RES" | jq -r '.ok')" "a failing reopen command reports failure"
assert_contains "$(ag_body "$AG_RES" | jq -r '.message')" "원본 요청함에 닿지 못했습니다" "a failing reopen explains why"
assert_eq "1" "$(ag_get | jq -r '[.completed[] | select(.id == "i-old")] | length')" "a failed reopen keeps the completed row"
rm -f "$AG_DATA/fixture-inbox/fail-reopen"
assert_eq "404" "$(ag_code "$(ag_post reopen '{"source":"inbox","id":"never-done"}')")" "reopen refuses an item that was never finished"
pass "agenda reopens an adapter item through its reopen command"

# AC6: reopen이 없는 어댑터 done은 되돌릴 수 없고 원본에서 다시 열라고 안내한다.
ag_post connect '{"source":"acme"}' >/dev/null
ag_wait '[.items.reply[] | select(.source == "acme")] | length == 2' >/dev/null || fail "acme fetches on the new board"
AG_RES="$(ag_post "done" '{"source":"acme","id":"r1"}')"
assert_eq "false" "$(ag_body "$AG_RES" | jq -r '.undo')" "an adapter without reopen cannot undo"
assert_contains "$(ag_body "$AG_RES" | jq -r '.message')" "원본에서 다시 여세요" "the done message points to the original"
AG_RES="$(ag_post reopen '{"source":"acme","id":"r1"}')"
assert_eq "409" "$(ag_code "$AG_RES")" "reopen is refused without a reopen command"
assert_contains "$(ag_body "$AG_RES" | jq -r '.message')" "원본에서 다시 여세요" "the refusal points to the original"
assert_eq "false" "$(ag_get | jq -r '.completed[] | select(.source == "acme" and .id == "r1") | .can_reopen')" "the completed row cannot be reopened"
pass "agenda keeps adapter completions without reopen in the original"

# AC7: 직접 적은 할 일(화면 API·board.sh todo done)과 보드에만 숨긴 항목도 완료함에 남고 다시 열 수 있다.
AG_TID2="$(ag_board todo add 예시 정리)"
ag_post "done" "$(jq -cn --arg i "$AG_TID" '{source: "todo", id: $i}')" >/dev/null
ag_board todo "done" "$AG_TID2"
ag_post connect '{"source":"localdone"}' >/dev/null
ag_wait '[.items.reply[] | select(.id == "n1")] | length == 1' >/dev/null || fail "localdone fetches on the new board"
ag_post "done" '{"source":"localdone","id":"n1"}' >/dev/null
AG_OUT="$(ag_get)"
for AG_K in "todo:$AG_TID" "todo:$AG_TID2" "localdone:n1"; do
  assert_eq "true" "$(jq -r --arg s "${AG_K%%:*}" --arg i "${AG_K#*:}" '.completed[] | select(.source == $s and .id == $i) | .can_reopen' <<<"$AG_OUT")" "$AG_K is in the completed list and can be reopened"
done
assert_eq "예시 할 일" "$(jq -r --arg i "$AG_TID" '.completed[] | select(.id == $i) | .title' <<<"$AG_OUT")" "a written to-do keeps its title in the completed list"
for AG_K in "todo:$AG_TID" "todo:$AG_TID2" "localdone:n1"; do
  assert_eq "200" "$(ag_code "$(ag_post reopen "$(jq -cn --arg s "${AG_K%%:*}" --arg i "${AG_K#*:}" '{source: $s, id: $i}')")")" "$AG_K reopens"
done
AG_OUT="$(ag_get)"
assert_eq "0" "$(jq -r '[.completed[] | select(.source == "todo" or .source == "localdone")] | length' <<<"$AG_OUT")" "reopened rows leave the completed list"
assert_eq "1|1" "$(jq -r --arg i "$AG_TID2" '"\([.items.todo[] | select(.id == $i)] | length)|\([.items.reply[] | select(.id == "n1")] | length)"' <<<"$AG_OUT")" "reopened items are listed again"
pass "agenda keeps written and board-hidden completions in the completed list"

# AC8: 7일이 지난 줄은 응답에서 빠지고 파일에서도 정리된다.
AG_OLD="$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=8)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
jq --arg at "$AG_OLD" '.items += [{source: "todo", source_name: "할 일", id: "oldrow", kind: "todo", title: "오래된 완료", done_at: $at}]' \
  "$AG_DATA/board/agenda/completed.json" >"$AG_T/completed.json"
mv "$AG_T/completed.json" "$AG_DATA/board/agenda/completed.json"
assert_eq "0" "$(ag_get | jq -r '[.completed[] | select(.id == "oldrow")] | length')" "a completion older than 7 days is not listed"
assert_eq "0" "$(jq -r '[.items[] | select(.id == "oldrow")] | length' "$AG_DATA/board/agenda/completed.json")" "a completion older than 7 days is pruned from the file"
assert_eq "600" "$(filemode "$AG_DATA/board/agenda/completed.json")" "the pruned completed.json stays private"
pass "agenda prunes completions older than 7 days"

# AC9: reopen이 문자열 배열이 아니면 그 소스만 선언 오류다.
mkdir -p "$HM_CLAUDE_SKILLS_DIR/badreopen"
jq -n '{id: "badreopen", name: "되돌리기 오류", fetch: ["true"], reopen: "reopen.sh"}' >"$HM_CLAUDE_SKILLS_DIR/badreopen/agenda.json"
AG_OUT="$(ag_get)"
assert_eq "true" "$(ag_src "$AG_OUT" badreopen invalid)" "a non-array reopen is a declaration error"
assert_contains "$(ag_src "$AG_OUT" badreopen error)" "reopen" "the error names reopen"
assert_eq "connected" "$(ag_src "$AG_OUT" inbox state)" "other sources are unaffected"
rm -rf "$HM_CLAUDE_SKILLS_DIR/badreopen"
pass "agenda rejects a non-array reopen declaration"

# AC11: 화면 — 숫자 줄 없이 지금·다음 카드, 머리 연결 버튼, 할 일 세 갈래, 접힌 버튼 셋, hb-ag-seen 객체 형식.
AG_TPL="$(<"$ROOT/scripts/board/template.html")"
case "$AG_TPL" in *todayLine*) fail "the agenda has no today count line" ;; esac
for AG_W in "line('지금'" "line('다음'" "오늘 남은 일정 없음" "내일 첫 일정" "'⚙ 연결 '" "새로 맡겨진 요청" "기한 있음" "쌓인 요청" "완료함" \
  "다시 열기" "이번 주" "요청자별" "hb-ag-group" "원본에서 다시 열기" "agSeenLoad"; do
  assert_contains "$AG_TPL" "$AG_W" "the agenda screen has $AG_W"
done
assert_contains "$AG_TPL" "Array.isArray(raw)" "hb-ag-seen migrates the old array form"
case "$AG_TPL" in *"<h3>연결한 곳</h3>"*|*"sec('연결한 곳'"*) fail "the connected sources section moves into the header" ;; esac
pass "agenda screen leads with now and next and folds the rest"

# #590: 쌓인 요청 보기는 [전체 | 요청자별] radiogroup, 할 일·완료함 제목은 펼쳐 보는 버튼(aria-expanded).
AG_TPLF="$ROOT/scripts/board/template.html"
AG_STALE="$(sed -n '/function staleFold(/,/^  }$/p' "$AG_TPLF")"
[ -n "$AG_STALE" ] || fail "staleFold is found in the template"
for AG_W in "segment(" "'전체'" "'요청자별'" "hb-ag-group" "ds-sr"; do
  assert_contains "$AG_STALE" "$AG_W" "the stale fold view picker has $AG_W"
done
case "$AG_STALE" in *ds-chip*|*aria-pressed*|*"요청자별 묶기"*) fail "the stale fold has no toggle chip" ;; esac
AG_TROW="$(sed -n '/function taskRow(/,/^  }$/p' "$AG_TPLF")"
AG_DONE="$(sed -n '/function completedFold(/,/^  }$/p' "$AG_TPLF")"
assert_contains "$AG_TROW" "agTitle(" "task rows use the expandable title"
assert_contains "$AG_TROW" "task:\${it.source}:\${it.id}" "task title state is keyed by source and id"
assert_contains "$AG_TROW" "agtitle:\${it.source}:\${it.id}" "task title keeps focus across renders"
assert_contains "$AG_DONE" "agTitle(" "completed rows use the expandable title"
assert_contains "$AG_DONE" "done:\${r.source}:\${r.id}" "completed title state is keyed by source and id"
case "$AG_TROW$AG_DONE" in *"'b-agtask__title', it.title"*|*"'b-agdone__title', r.title"*) fail "titles are no longer plain spans" ;; esac
assert_contains "$AG_TPL" '.b-agtitle[aria-expanded="true"] > .b-agtitle__text { white-space: normal;' "an expanded title wraps"
assert_contains "$AG_TPL" "white-space: pre-line" "the detail keeps its line breaks"
assert_contains "$AG_TPL" ".b-agtask__detail { grid-column: 2 / -1;" "the detail spans from the title column to the end"
if command -v node >/dev/null 2>&1; then
  AG_FOLDS="$(sed -n '/function agFold(/,/^  }$/p;/function agFoldBlock(/,/^  }$/p' "$AG_TPLF")"
  AG_SEG="$(sed -n '/function segment(/,/^  }$/p' "$AG_TPLF")"
  AG_ATITLE="$(sed -n '/function agTitle(/,/^  }$/p' "$AG_TPLF")"
  [ -n "$AG_SEG" ] && [ -n "$AG_ATITLE" ] || fail "segment and agTitle are found in the template"
  AG_STUB='class E { constructor(t) { this.tag = t; this.attrs = {}; this.children = []; this.dataset = {}; this.hidden = false; this.textContent = ""; this.className = ""; this.id = ""; }
    setAttribute(k, v) { this.attrs[k] = String(v); } getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
    append(...c) { this.children.push(...c.filter((x) => x != null)); } addEventListener() {} }
  const el = (t, c, x) => { const e = new E(t); if (c) e.className = c; if (x != null) e.textContent = x; return e; };
  const icon = (n, c) => el("svg", "ds-icon" + (c ? " " + c : ""));
  const all = (n, f, out = []) => { if (n instanceof E) { if (f(n)) out.push(n); n.children.forEach((c) => all(c, f, out)); } return out; };
  const allOf = (ns, f) => [].concat(...ns.map((n) => all(n, f)));
  let LS = {}; const store = (k, v) => { if (v === undefined) return k in LS ? LS[k] : null; LS[k] = v; return null; };
  let renders = 0; const renderBoard = () => { renders++; };
  const sameVal = (a, b) => String(a ?? "") === String(b ?? "");
  const taskList = (rows, label) => { const u = el("ul", "b-agtasks"); u.setAttribute("aria-label", label); return u; };
  const agExp = new Set();'
  AG_SEGOUT="$(AG_JS="$AG_STUB
$AG_FOLDS
$AG_SEG
$AG_STALE" node -e 'eval(process.env.AG_JS + `
    agExp.add("stale");
    const list = [{ id: 1, from: "가" }, { id: 2, from: "나" }, { id: 3 }];
    const radios = (n) => all(n, (x) => x.attrs.role === "radio");
    const show = (n) => radios(n).map((b) => b.textContent + "=" + b.getAttribute("aria-checked")).join(",") + " who=" + all(n, (x) => x.className === "b-agwho").length + " lists=" + all(n, (x) => x.tag === "ul").length;
    LS = { "hb-ag-group": "1" }; let n = staleFold(list, {}); console.log(show(n));
    const g = all(n, (x) => x.attrs.role === "radiogroup")[0]; const lab = all(n, (x) => x.id && x.id === g.getAttribute("aria-labelledby"))[0];
    console.log("label=" + (lab ? lab.className + ":" + lab.textContent : "none"));
    radios(n).find((b) => b.textContent === "전체").onclick(); console.log("saved=" + LS["hb-ag-group"]);
    n = staleFold(list, {}); console.log(show(n));
    LS = {}; n = staleFold(list, {}); console.log(show(n));
    radios(n).find((b) => b.textContent === "요청자별").onclick(); console.log("saved=" + LS["hb-ag-group"]);
    LS = { "hb-ag-group": "1" }; n = staleFold([{ id: 1 }, { id: 2 }], {}); console.log("nofrom " + show(n));
  `)')"
  assert_eq "전체=false,요청자별=true who=3 lists=3
label=ds-sr:쌓인 요청 보기
saved=0
전체=true,요청자별=false who=0 lists=1
전체=true,요청자별=false who=0 lists=1
saved=1
nofrom  who=0 lists=1" "$AG_SEGOUT" "the stale view picker maps hb-ag-group 1 to 요청자별 and saves each pick"
  AG_TOUT="$(AG_JS="$AG_STUB
$AG_ATITLE" node -e 'eval(process.env.AG_JS + `
    const show = (r) => { const b = r[0], d = r[1], ctl = b.getAttribute("aria-controls"), tx = all(b, (x) => x.className === "b-agtitle__text")[0];
      const tgt = d && d.id === ctl ? "detail" : tx && tx.id === ctl ? "text" : "none";
      return [b.tag, b.className, b.dataset.key, b.getAttribute("aria-expanded"), tgt, tx.textContent, d ? (d.hidden ? "hidden" : "shown:" + d.textContent) : "nodetail", b.title.replace(/\\n/g, "|")].join(" "); };
    const mk = (detail) => agTitle("b-agtask__title", "task:s:1", "agtitle:s:1", "긴 제목", detail);
    let r = mk("첫 줄\\n둘째 줄"); console.log(show(r));
    r[0].onclick(); console.log(agExp.has("task:s:1") + " renders=" + renders); console.log(show(mk("첫 줄\\n둘째 줄")));
    console.log(show(mk("")));
    mk("x")[0].onclick(); console.log(agExp.has("task:s:1") + " " + show(mk("x")));
    const ids = [agTitle("c", "task:s:가", "k", "t", "d"), agTitle("c", "task:s:나", "k", "t", "d")].map((x) => x[1].id);
    console.log("unique=" + (ids[0] !== ids[1] && !/\\s/.test(ids.join(""))));
  `)')"
  assert_eq "button b-agtitle b-agtask__title agtitle:s:1 false detail 긴 제목 hidden 긴 제목|첫 줄|둘째 줄
true renders=1
button b-agtitle b-agtask__title agtitle:s:1 true detail 긴 제목 shown:첫 줄
둘째 줄 긴 제목|첫 줄|둘째 줄
button b-agtitle b-agtask__title agtitle:s:1 true text 긴 제목 nodetail 긴 제목
false button b-agtitle b-agtask__title agtitle:s:1 false detail 긴 제목 hidden 긴 제목|x
unique=true" "$AG_TOUT" "the title button toggles aria-expanded and shows the detail only when expanded"
fi
pass "stale requests pick a view with a segment and task titles expand in place"

# #581: 할 일 기한은 폼 줄의 [기한] 버튼 → 팝오버(빠른 선택 넷 + 날짜 직접 고르기). date 칸은 팝오버 안에만 있다.
AG_FORM="$(sed -n '/function todoForm(/,/^  }$/p' "$ROOT/scripts/board/template.html")"
[ -n "$AG_FORM" ] || fail "todoForm is found in the template"
case "$AG_FORM" in *"type = 'date'"*) fail "the to-do form row has no date input" ;; esac
AG_POP="$(sed -n '/function duePop(/,/^  }$/p' "$ROOT/scripts/board/template.html")"
assert_contains "$AG_POP" "type = 'date'" "the date input lives in the due popover"
for AG_W in "ag-due-btn" "aria-expanded" "aria-controls" "'기한'" "오늘" "내일" "이번 주 금요일" "다음 주 월요일" "날짜 직접 고르기" "기한 지우기" "Escape"; do
  assert_contains "$AG_TPL" "$AG_W" "the due button has $AG_W"
done
# WebKit은 버튼을 눌러도 포커스를 주지 않고 기존 포커스만 푼다 — 팝오버 안을 누르는 동안엔 focusout으로 닫지 않는다.
AG_DISMISS="$(sed -n '/function agDueDismiss(/,/^  }$/p' "$ROOT/scripts/board/template.html")"
assert_contains "$AG_DISMISS" "agDuePress" "focusout does not close the popover while a pointer is pressed inside it"
assert_contains "$AG_TPL" "agDuePress = agDueOpen && inside" "pointerdown inside the popover marks the press"
if command -v node >/dev/null 2>&1; then
  AG_DQ="$(sed -n '/function dueQuick(/,/^  }$/p' "$ROOT/scripts/board/template.html")"
  [ -n "$AG_DQ" ] || fail "dueQuick is found in the template"
  AG_DQOUT="$(AG_DQ="$AG_DQ" node -e 'const p2 = (n) => String(n).padStart(2, "0"); eval(process.env.AG_DQ);
    for (const d of ["2026-11-26", "2026-11-23", "2026-11-27", "2026-11-29", "2026-12-31"]) { const [y, m, dd] = d.split("-").map(Number);
      console.log(dueQuick(new Date(y, m - 1, dd, 10)).map((q) => q.label + "=" + q.key).join(",")); }')"
  assert_eq "오늘=2026-11-26,내일=2026-11-27,이번 주 금요일=2026-11-27,다음 주 월요일=2026-11-30
오늘=2026-11-23,내일=2026-11-24,이번 주 금요일=2026-11-27,다음 주 월요일=2026-11-30
오늘=2026-11-27,내일=2026-11-28,다음 주 월요일=2026-11-30
오늘=2026-11-29,내일=2026-11-30,다음 주 월요일=2026-11-30
오늘=2026-12-31,내일=2027-01-01,이번 주 금요일=2027-01-01,다음 주 월요일=2027-01-04" "$AG_DQOUT" "dueQuick picks today, tomorrow, this Friday (Mon-Thu only) and next Monday"
fi
pass "the to-do due date is a button with quick picks"

# 앱 딥링크(#592): 어댑터 url은 http(s) 또는 허용 앱 스킴(msteams:, 대소문자 무시, 뒤가 비지 않음)만 남긴다.
# 그 밖의 스킴은 url만 버리고 항목은 남긴다. link 필드로 받아도 같다.
AG_LINKS="$(python3 -I - "$ROOT/scripts/board" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import agenda
cases = ["msteams:/l/message/example", "MSTEAMS:/l/x", "https://chat.example.com/r1", "javascript:alert(1)",
         "data:text/html,x", "file:///etc/passwd", "vbscript:x", "msteams", "msteams:", "msteams: x", "slack://x"]
lines = [json.dumps({"id": "u%d" % i, "kind": "reply", "title": "x", "url": u}) for i, u in enumerate(cases)]
lines.append(json.dumps({"id": "l1", "kind": "reply", "title": "x", "link": "msteams:/l/message/link"}))
items, skipped = agenda.parse_jsonl("\n".join(lines), "s")
print("%d|%d" % (len(items), skipped))
for it in items:
    print(it.get("url", "-"))
PY
)"
assert_eq "12|0
msteams:/l/message/example
MSTEAMS:/l/x
https://chat.example.com/r1
-
-
-
-
-
-
-
-
msteams:/l/message/link" "$AG_LINKS" "agenda keeps http(s) and msteams: links and drops every other scheme but keeps the item"
pass "agenda keeps allowed app deep links only"

# 앱 딥링크(#592): fixture applink를 연결하면 /agenda 응답에서 msteams 항목은 url을 갖고 javascript 항목은 url이 없다.
ag_post connect '{"source":"applink"}' >/dev/null
AG_OUT="$(ag_wait '[.items.reply[] | select(.source == "applink")] | length == 2')" || fail "applink fetches its items: $AG_OUT"
assert_eq "msteams:/l/message/example|-|msteams:/l/meetup-join/example" \
  "$(jq -r '[(.items.reply[] | select(.id == "m2") | .url // "-"), (.items.reply[] | select(.id == "m3") | .url // "-"), (.items.event[] | select(.id == "m1") | .url // "-")] | join("|")' <<<"$AG_OUT")" \
  "the board serves msteams links and drops javascript links"
pass "the board serves app deep links from an adapter"

# 앱 딥링크(#592): 화면은 내 일정 세 곳만 agendaHref로 거른다. safeHref(다른 화면)는 그대로 http(s)·보드 경로만.
# 앱 링크는 target 없이(같은 프레임) '앱에서 열기'로, http(s) 링크는 지금처럼 _blank·'원본에서 보기(새 창)'로 연다.
AG_TPL="$(<"$ROOT/scripts/board/template.html")"
case "$AG_TPL" in *"safeHref(it.url)"*|*"safeHref(r.url)"*) fail "the agenda rows do not use safeHref for item links" ;; esac
AG_OPEN_FN="$(sed -n '/function agOpenLink(/,/^  }$/p' "$ROOT/scripts/board/template.html")"
[ -n "$AG_OPEN_FN" ] || fail "agOpenLink is found in the template"
for AG_W in "agendaHref(" "isAppLink(" "'앱에서 열기'" "'앱에서 다시 열기'" "'원본에서 보기(새 창)'" "'원본에서 다시 열기(새 창)'" "noopener noreferrer" "icon('external')"; do
  assert_contains "$AG_OPEN_FN" "$AG_W" "the agenda open link has $AG_W"
done
assert_eq "3" "$(grep -c 'agOpenLink(' <<<"$AG_TPL" | awk '{print $1 - 1}')" "the to-do, event and done rows use agOpenLink"
if command -v node >/dev/null 2>&1; then
  AG_HREF="$(grep -E '^  const (safeHref|APP_LINK_SCHEMES|isAppLink|agendaHref) = ' "$ROOT/scripts/board/template.html")"
  assert_eq "4" "$(grep -c . <<<"$AG_HREF")" "the link guards are found in the template"
  AG_HOUT="$(AG_SRC="$AG_HREF
$AG_OPEN_FN" node -e 'const el = (tag, cls) => ({ cls, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, append() {} }); const icon = () => null;
    eval(process.env.AG_SRC + `
    console.log(["msteams:/l/x", "MSTEAMS:/l/x", "https://a", "javascript:x", "data:x", "slack://x", "msteams:", "msteams"].map((h) => h + "=" + agendaHref(h)).join(","));
    console.log("safeHref(msteams)=" + safeHref("msteams:/l/x"));
    for (const [u, again] of [["msteams:/l/x", false], ["msteams:/l/x", true], ["https://a", false], ["https://a", true]]) {
      const a = agOpenLink(u, "T", again, "");
      console.log((a.target || "none") + "|" + a.title + "|" + a.attrs["aria-label"]);
    }
    console.log(agOpenLink("javascript:x", "T", false, ""));`);')"
  assert_eq "msteams:/l/x=true,MSTEAMS:/l/x=true,https://a=true,javascript:x=false,data:x=false,slack://x=false,msteams:=false,msteams=false
safeHref(msteams)=false
none|앱에서 열기|앱에서 열기: T
none|앱에서 다시 열기|앱에서 다시 열기: T
_blank|원본에서 보기(새 창)|원본에서 보기(새 창): T
_blank|원본에서 다시 열기(새 창)|원본에서 다시 열기(새 창): T
null" "$AG_HOUT" "app links open in the same frame with an app label and web links keep a new tab"
fi
pass "the agenda opens app deep links without a new tab"

# 앱 딥링크(#592): Python·화면·창 앱이 같은 허용 목록을 쓰고, 어댑터 계약 문서에 적혀 있다.
ag_schemes() { grep -E "$1" "$2" | head -n 1 | sed 's/^[^=]*=//' | grep -oE "[a-z0-9+.-]+" | sort | paste -sd' ' -; }
AG_PY_S="$(ag_schemes '^APP_LINK_SCHEMES = ' "$ROOT/scripts/board/agenda.py")"
assert_eq "msteams" "$AG_PY_S" "agenda.py allows msteams links"
assert_eq "$AG_PY_S" "$(ag_schemes '^  const APP_LINK_SCHEMES = ' "$ROOT/scripts/board/template.html")" "the board screen uses the same app schemes"
assert_eq "$AG_PY_S" "$(ag_schemes 'static let appLinkSchemes = ' "$ROOT/scripts/board/BoardLauncher.swift")" "the window app uses the same app schemes"
assert_contains "$(sed -n '1,40p' "$ROOT/scripts/board/agenda.py")" "msteams:" "the adapter contract docstring names msteams links"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "msteams:" "the board skill documents msteams links"
pass "app deep link schemes match across agenda, screen and window app"

# 소스 설정(#632): settings를 선언한 소스는 settings:true, 없는 소스는 false. 잘못된 settings는 그 소스만 선언 오류다.
AG_OUT="$(ag_get)"
assert_eq "disconnected|true|null" "$(ag_src "$AG_OUT" knobs state)|$(ag_src "$AG_OUT" knobs settings)|$(ag_src "$AG_OUT" knobs invalid)" "a source with a valid settings declaration is discovered"
assert_eq "false" "$(ag_src "$AG_OUT" acme settings)" "a source without settings says so"
assert_eq "error|true" "$(ag_src "$AG_OUT" badknobs state)|$(ag_src "$AG_OUT" badknobs invalid)" "a broken settings declaration is a declaration error"
case "$(ag_src "$AG_OUT" badknobs error)" in "선언 오류: "*options*) ;; *) fail "the settings declaration error names options: $(ag_src "$AG_OUT" badknobs error)" ;; esac
pass "agenda accepts a settings declaration and isolates a broken one"

# 소스 설정(#632): 선언 검사 — 변형마다 parse_declaration이 그 키를 짚는 오류를 내고, 보드에서는 그 소스만 선언 오류다.
AG_DECL="$AG_T/decl"; mkdir -p "$AG_DECL"
AG_KNOBS="$AG_FIX/skills/knobs/agenda.json"
jq '.' "$AG_KNOBS" >"$AG_DECL/ok.json"
jq '.settings.fields[0] |= del(.options)' "$AG_KNOBS" >"$AG_DECL/noopts.json"
jq '.settings.fields[3].min = 40' "$AG_KNOBS" >"$AG_DECL/minmax.json"
jq '.settings.fields[1].type = "text"' "$AG_KNOBS" >"$AG_DECL/type.json"
jq 'del(.settings.set)' "$AG_KNOBS" >"$AG_DECL/noset.json"
jq '.settings.fields[2].id = "digest"' "$AG_KNOBS" >"$AG_DECL/dup.json"
jq '.settings.fields[1].min = 1' "$AG_KNOBS" >"$AG_DECL/minontoggle.json"
jq '.settings.fields[1].options = ["true"]' "$AG_KNOBS" >"$AG_DECL/optsontoggle.json"
jq '.settings.fields[3].max = 2.5' "$AG_KNOBS" >"$AG_DECL/floatmax.json"
jq '.settings.fields = []' "$AG_KNOBS" >"$AG_DECL/nofields.json"
jq '.settings.fields[0].danger = "yes"' "$AG_KNOBS" >"$AG_DECL/danger.json"
jq '.settings.fields[0].label = " "' "$AG_KNOBS" >"$AG_DECL/label.json"
AG_DECL_OUT="$(cd "$AG_DECL" && python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import agenda
for p in sys.argv[2:]:
    src, err = agenda.parse_declaration(p)
    print(p[:-5] + "=" + (err or "OK|" + str(len(src["settings"]["fields"]))))' "$ROOT/scripts/board" \
  ok.json noopts.json minmax.json type.json noset.json dup.json minontoggle.json optsontoggle.json floatmax.json nofields.json danger.json label.json)"
assert_contains "$AG_DECL_OUT" "ok=OK|4" "a valid settings declaration keeps its four fields"
for AG_W in "noopts=*options*" "minmax=*min*max*" "type=*type*" "noset=*set*" "dup=*id*" "minontoggle=*min*number*" \
  "optsontoggle=*options*multi-select*" "floatmax=*max*정수*" "nofields=*fields*" "danger=*danger*" "label=*label*"; do
  AG_LINE="$(grep "^${AG_W%%=*}=" <<<"$AG_DECL_OUT")"
  # shellcheck disable=SC2254  # AG_W는 기대하는 글롭 패턴이다
  case "$AG_LINE" in $AG_W) ;; *) fail "parse_declaration explains ${AG_W%%=*}: $AG_LINE" ;; esac
  case "$AG_LINE" in *"OK|"*) fail "parse_declaration rejects ${AG_W%%=*}" ;; esac
done
mkdir -p "$HM_CLAUDE_SKILLS_DIR/knobs-minmax" "$HM_CLAUDE_SKILLS_DIR/knobs-noset"
jq '.id = "knobs-minmax"' "$AG_DECL/minmax.json" >"$HM_CLAUDE_SKILLS_DIR/knobs-minmax/agenda.json"
jq '.id = "knobs-noset"' "$AG_DECL/noset.json" >"$HM_CLAUDE_SKILLS_DIR/knobs-noset/agenda.json"
AG_OUT="$(ag_get)"
for AG_S in knobs-minmax knobs-noset; do
  assert_eq "true" "$(ag_src "$AG_OUT" "$AG_S" invalid)" "$AG_S is a declaration error on the board"
  case "$(ag_src "$AG_OUT" "$AG_S" error)" in "선언 오류: "*) ;; *) fail "$AG_S explains the declaration error" ;; esac
done
assert_eq "null|null" "$(ag_src "$AG_OUT" acme invalid)|$(ag_src "$AG_OUT" knobs invalid)" "other sources stay valid next to broken settings"
rm -rf "$HM_CLAUDE_SKILLS_DIR/knobs-minmax" "$HM_CLAUDE_SKILLS_DIR/knobs-noset"
pass "agenda validates every settings declaration rule"

# 소스 설정(#632): 읽기 — 연결 전·선언 없는 소스·모르는 소스는 4xx, 연결한 뒤에는 필드·선택지(잘못된 줄은 건너뜀)·get 현재값.
ag_sget() { curl -s -w '\n%{http_code}' "$AG_BASE/agenda/settings?t=${2-$AG_TOKEN}&source=$1"; }
assert_eq "409" "$(ag_code "$(ag_sget knobs)")" "settings of a source that is not connected are refused"
ag_post connect '{"source":"knobs"}' >/dev/null
ag_wait '(.sources[] | select(.id == "knobs") | .state) == "connected"' >/dev/null || fail "knobs connects"
AG_RES="$(ag_sget knobs)"
assert_eq "200|true|4" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '"\(.ok)|\(.fields | length)"')" "settings read returns the declared fields"
assert_eq '[{"value":"general","label":"#general"},{"value":"random","label":"#random"},{"value":"alerts","label":"#alerts"}]' \
  "$(ag_body "$AG_RES" | jq -c '.fields[] | select(.id == "channels") | .options')" "multi-select options come from the options command and bad lines are skipped"
assert_eq "multi-select|true|toggle|number|1|30" "$(ag_body "$AG_RES" | jq -r '[.fields[0].type, .fields[0].danger, .fields[1].type, .fields[3].type, .fields[3].min, .fields[3].max] | join("|")')" "field types, danger and range are served"
assert_contains "$(ag_body "$AG_RES" | jq -r '.fields[0].confirm')" "이 채널을 더할까요" "the confirm sentence is served"
assert_eq '{"channels":["general"],"digest":false,"forward":false,"lookback":7}' "$(ag_body "$AG_RES" | jq -c '.values')" "current values come from the get command"
assert_eq "403" "$(ag_code "$(ag_sget knobs wrong)")" "settings read needs the board token"
assert_eq "404" "$(ag_code "$(ag_sget acme)")" "a source without settings has no settings to read"
assert_eq "404" "$(ag_code "$(ag_sget nope)")" "an unknown source has no settings to read"
pass "agenda reads source settings through get and options"

# 소스 설정(#632): 저장 — values는 바꿀 필드만, 서버가 현재값에 합쳐 전체 객체를 set의 표준 입력으로 넘긴다.
AG_KV="$AG_DATA/fixture-knobs/values.json"
AG_RES="$(ag_post settings '{"source":"knobs","values":{"digest":true}}')"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "turning on a non-danger toggle is saved"
assert_eq '{"channels":["general"],"digest":true,"forward":false,"lookback":7}' "$(jq -cS '.' "$AG_KV")" "set receives every field as one JSON object on stdin"
pass "agenda saves source settings through set with the merged object"

# 소스 설정(#632): 목록 밖·범위 밖·타입이 틀린 값·모르는 필드는 400이고 set을 부르지 않는다.
ag_kcalls() { wc -l <"$AG_DATA/fixture-knobs/calls" | tr -d ' '; }
AG_CALLS="$(ag_kcalls)"
for AG_V in '{"channels":["general","nope"]}' '{"channels":"general"}' '{"lookback":0}' '{"lookback":31}' '{"lookback":"5"}' '{"lookback":3.5}' \
  '{"lookback":true}' '{"digest":"yes"}' '{"bogus":1}' '{}'; do
  AG_BODY="$(jq -cn --argjson v "$AG_V" '{source: "knobs", values: $v}')"
  assert_eq "400" "$(ag_code "$(ag_post settings "$AG_BODY")")" "settings value $AG_V is refused"
done
assert_eq "400" "$(ag_code "$(ag_post settings '{"source":"knobs","values":"digest"}')")" "values must be an object"
assert_contains "$(ag_body "$(ag_post settings '{"source":"knobs","values":{"channels":["nope"]}}')" | jq -r '.message')" "목록에 없는 항목입니다: nope" "an option outside the list is named"
assert_contains "$(ag_body "$(ag_post settings '{"source":"knobs","values":{"lookback":31}}')" | jq -r '.message')" "1~30" "an out-of-range number names the range"
assert_eq "$AG_CALLS" "$(ag_kcalls)" "refused settings never reach set"
assert_eq "true" "$(jq -r '.digest' "$AG_KV")" "refused settings leave the values unchanged"
pass "agenda refuses settings outside the options, range or type"

# 소스 설정(#632): 위험 필드 — 켜기·항목 추가는 confirm:true 없이 409 needs_confirm(set 미호출), 붙이면 저장. 끄기·빼기·danger 아닌 숫자는 바로.
AG_RES="$(ag_post settings '{"source":"knobs","values":{"forward":true}}')"
assert_eq "409|true|forward" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '"\(.needs_confirm)|\(.fields | join(","))"')" "turning on a danger toggle needs confirmation"
AG_RES="$(ag_post settings '{"source":"knobs","values":{"channels":["general","alerts"],"digest":false}}')"
assert_eq "409|channels" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.fields | join(",")')" "adding to a danger multi-select needs confirmation"
assert_eq "409" "$(ag_code "$(ag_post settings '{"source":"knobs","values":{"forward":true},"confirm":"true"}')")" "only a boolean confirm counts"
assert_eq "$AG_CALLS|false|true" "$(ag_kcalls)|$(jq -r '.forward' "$AG_KV")|$(jq -r '.digest' "$AG_KV")" "unconfirmed danger changes never reach set"
AG_RES="$(ag_post settings '{"source":"knobs","values":{"forward":true},"confirm":true}')"
assert_eq "200|true|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')|$(jq -r '.forward' "$AG_KV")" "a confirmed danger toggle is saved"
AG_RES="$(ag_post settings '{"source":"knobs","values":{"channels":["general","alerts","alerts"]},"confirm":true}')"
assert_eq "200|general,alerts" "$(ag_code "$AG_RES")|$(jq -r '.channels | join(",")' "$AG_KV")" "a confirmed addition is saved and duplicates collapse"
assert_eq "200|false" "$(ag_code "$(ag_post settings '{"source":"knobs","values":{"forward":false}}')")|$(jq -r '.forward' "$AG_KV")" "turning off a danger toggle needs no confirmation"
assert_eq "200|general" "$(ag_code "$(ag_post settings '{"source":"knobs","values":{"channels":["general"]}}')")|$(jq -r '.channels | join(",")' "$AG_KV")" "removing from a danger multi-select needs no confirmation"
assert_eq "200|10" "$(ag_code "$(ag_post settings '{"source":"knobs","values":{"lookback":10}}')")|$(jq -r '.lookback' "$AG_KV")" "a non-danger number is saved without confirmation"
pass "agenda enforces confirmation for danger settings on the server"

# 소스 설정(#632): 보안 — 틀린 Origin·토큰은 403, 기록에는 소스와 결과만(설정값 없음).
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://attacker.example' -d "$(jq -cn --arg t "$AG_TOKEN" '{t: $t, source: "knobs", values: {digest: false}}')" "$AG_BASE/agenda/settings")" "settings save refuses a foreign Origin"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $AG_BASE" -d '{"t":"wrong","source":"knobs","values":{"digest":false}}' "$AG_BASE/agenda/settings")" "settings save needs the board token"
assert_contains "$(grep agenda_settings "$AG_DATA/board/actions.jsonl" | tail -n 1)" '"source": "knobs"' "settings saves are logged by source"
if grep -qs alerts "$AG_DATA/board/actions.jsonl" "$AG_DATA/board/server.log"; then fail "board logs carry no settings values"; fi
pass "agenda settings save is guarded and logs no values"

# 소스 설정(#632): set이 실패하면 ok:false와 사람 말 사유, 값은 그대로다.
: >"$AG_DATA/fixture-knobs/fail-set"
AG_RES="$(ag_post settings '{"source":"knobs","values":{"digest":false}}')"
assert_eq "false" "$(ag_body "$AG_RES" | jq -r '.ok')" "a failing set is reported"
assert_contains "$(ag_body "$AG_RES" | jq -r '.message')" "설정 저장소에 닿지 못했습니다" "the failure carries the adapter's reason"
assert_eq "true" "$(jq -r '.digest' "$AG_KV")" "a failing set leaves the values unchanged"
rm -f "$AG_DATA/fixture-knobs/fail-set"
pass "agenda reports a failing settings save"

# 소스 설정(#632): 화면 — 연결한 소스 카드의 설정 폼은 목록 칩(aria-pressed)·숫자 입력만 쓰고, 위험한 변경은 확인 대화 뒤 confirm:true로 보낸다.
AG_SET_FN="$(sed -n '/^  \/\/ ---- 내 일정 소스 설정(이슈 632) ----$/,/^  \/\/ ---- 내 일정 소스 설정 끝 ----$/p' "$ROOT/scripts/board/template.html")"
[ -n "$AG_SET_FN" ] || fail "the settings form code is found in the template"
for AG_W in "/agenda/settings" "ds-chip" "aria-pressed" "ds-setting" "confirm: true" "저장하는 중" "aria-busy" "ds-field__error" "showModal()" "'number'"; do
  assert_contains "$AG_SET_FN" "$AG_W" "the settings form uses $AG_W"
done
case "$AG_SET_FN" in *"'text'"*|*"textarea"*) fail "the settings form has no free text input" ;; esac
AG_DLG="$(grep -E '<dialog class="b-dialog" id="agsetdlg"' -A 6 "$ROOT/scripts/board/template.html")"
assert_contains "$AG_DLG" "ds-btn--danger" "the settings confirm dialog has a danger button"
assert_contains "$(sed -n '/^  function sourceRow(/,/^  }$/p' "$ROOT/scripts/board/template.html")" "s.settings" "the source card shows settings for sources that declare them"
pass "the board renders a settings form with chips and a confirm dialog"

# 소스 설정(#632): 계약은 범용 — settings 코드에 특정 서비스 이름 분기가 없고, 계약 문서에 settings가 적혀 있다.
AG_SET_PY="$(sed -n '/^def _parse_settings(/,/^def parse_declaration(/p; /^    # ---- 소스 설정(#632) ----$/,/^    # ---- 할 일 ----$/p' "$ROOT/scripts/board/agenda.py")"
[ -n "$AG_SET_PY" ] || fail "the settings code is found in agenda.py"
AG_SET_SRV="$(grep -n 'settings' "$ROOT/scripts/board/board-server.py" | grep -i 'agenda')"
if grep -qi 'teams' <<<"$AG_SET_PY$AG_SET_FN$AG_SET_SRV"; then fail "settings code has no service-specific branch"; fi
assert_contains "$(sed -n '1,60p' "$ROOT/scripts/board/agenda.py")" "settings (#632)" "the adapter contract docstring documents settings"
assert_contains "$(<"$ROOT/.ai-harness/docs/ui.md")" "knobs" "the UI doc names the settings fixture"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "/agenda/settings" "the board skill documents the settings API"
pass "agenda settings stay service-agnostic and documented"

# 15. Jira 기본 소스(#648): 가짜 Jira 서버(인자에 $TEST_TMP)로 키 해석(requires_env)·페이지·필드 매핑·설정·오류·비밀 미노출을 본다.
AJ_ADAPTER="$ROOT/scripts/board/agenda/jira/jira_agenda.py"
AJ_STATE="$AG_T/jira-state"; mkdir -p "$AJ_STATE"
AJ_PORT="$(free_port)"
python3 -I "$AG_FIX/fake-jira.py" "$AJ_STATE" "$AJ_PORT" >/dev/null 2>&1 &
track_test_process "$!"
AJ_URL="http://127.0.0.1:$AJ_PORT"
for _ in $(seq 1 50); do curl -s -o /dev/null "$AJ_URL/" && break; sleep 0.1; done
AJ_SECRET="fake-jira-SECRET-648"
AJ_USER="tester@example.com"
printf 'Basic %s' "$(printf '%s:%s' "$AJ_USER" "$AJ_SECRET" | base64 | tr -d '\n')" >"$AJ_STATE/expected-auth"
AJ_LOG="$AJ_STATE/requests.log"
AJ_SETTINGS_FILE="$AG_DATA/board/agenda/jira-settings.json"
AJ_OUT_DIR="$AG_T/jira-out"; mkdir -p "$AJ_OUT_DIR"
jq -n '[
  {key: "ACME-1", fields: {summary: "요약", status: {name: " 진행  중 ", statusCategory: {key: "indeterminate"}}, priority: {name: "High"}, project: {key: "ACME", name: "Acme 프로젝트"},
    duedate: "2026-12-01", created: "2026-11-20T10:15:30.000+0900", reporter: {displayName: "Pat Reporter"}}},
  {key: "ACME-2", fields: {summary: "기한 없는 일", status: {name: "할 일", statusCategory: {key: "new"}}, priority: null, project: {key: "ACME", name: "Acme 프로젝트"},
    duedate: null, created: "2026-11-21T09:00:00.000+0000", reporter: {displayName: "Pat Reporter"}}},
  {key: "OPS-3", fields: {summary: "운영 점검", status: {name: "검토 대기", statusCategory: {key: "weird"}}, priority: {name: "Low"}, project: {key: "OPS", name: "운영"},
    duedate: "2026-12-03", created: "2026-11-22T09:00:00.000-0500", reporter: null}}
]' >"$AJ_STATE/issues.json"
printf '2\n' >"$AJ_STATE/page_size"
aj_keys_settings() { jq -n --arg u "$1" --arg s "$AJ_SECRET" --arg n "$AJ_USER" '{env: {JIRA_BASE_URL: $u, ATLASSIAN_USER: $n, ATLASSIAN_API_TOKEN: $s}}' >"$AG_T/settings.json"; }
aj_secrets() {
  { printf "export JIRA_BASE_URL='%s'\n" "$AJ_URL"; printf "export ATLASSIAN_USER='%s'\n" "$AJ_USER"
    printf "export ATLASSIAN_API_TOKEN='%s'\n" "$AJ_SECRET"; } >"$AG_DATA/secrets.env"
  chmod 600 "$AG_DATA/secrets.env"
}
# 어댑터를 보드 밖에서 부른다: 사용자 셸 키를 빼고, 키는 settings.json·secrets.env로만. stdout·stderr는 A13이 다시 본다.
aj_run() { # name args... → stdout은 $AJ_OUT_DIR/<name>.out, stderr는 .err, 종료 코드를 돌려준다
  local name="$1"; shift
  env -u ATLASSIAN_USER -u ATLASSIAN_API_TOKEN -u JIRA_BASE_URL HM_DATA_DIR="$AG_DATA" HARNESS_CLAUDE_SETTINGS="$AG_T/settings.json" \
    python3 -I "$AJ_ADAPTER" "$@" >"$AJ_OUT_DIR/$name.out" 2>"$AJ_OUT_DIR/$name.err"
}
aj_search() { jq -sc '[.[] | select(.path == "/rest/api/3/search/jql")]' "$AJ_LOG"; }

# A1 키 없음: 환경·settings.json env·secrets.env 어디에도 없으면 내장 jira 소스는 '설정 필요'와 설정 세션, 연결은 409.
printf '{}\n' >"$AG_T/settings.json"
rm -f "$AG_DATA/secrets.env"
AG_OUT="$(ag_get)"
assert_eq "needs_setup|true|Jira" "$(ag_src "$AG_OUT" jira state)|$(ag_src "$AG_OUT" jira setup_session)|$(ag_src "$AG_OUT" jira name)" "the built-in jira source needs setup without keys"
assert_eq "409" "$(ag_code "$(ag_post connect '{"source":"jira"}')")" "jira cannot connect without keys"
assert_contains "$(jq -r '.setup_prompt' "$ROOT/scripts/board/agenda/jira/agenda.json")" "/ai-harness:setup" "the jira setup prompt points to /ai-harness:setup"
AJ_RC=0; aj_run nokeys fetch --since a --until b || AJ_RC=$?
assert_eq "2|1" "$AJ_RC|$(grep -c . "$AJ_OUT_DIR/nokeys.err")" "the adapter without keys exits 2 with one line"
assert_contains "$(<"$AJ_OUT_DIR/nokeys.err")" "ATLASSIAN_API_TOKEN" "the missing-key line names the keys"
pass "jira asks for setup until its keys exist"

# A2 키 해석: settings.json env만, secrets.env만 있어도 설정 충족이다.
aj_keys_settings "$AJ_URL"
assert_eq "disconnected" "$(ag_src "$(ag_get)" jira state)" "keys in settings.json env satisfy jira"
printf '{}\n' >"$AG_T/settings.json"
aj_secrets
assert_eq "disconnected" "$(ag_src "$(ag_get)" jira state)" "keys in secrets.env satisfy jira"
: >"$AJ_LOG"
aj_run secrets fetch --since a --until b || fail "the adapter reads keys from secrets.env: $(<"$AJ_OUT_DIR/secrets.err")"
assert_eq "3|true" "$(grep -c . "$AJ_OUT_DIR/secrets.out")|$(aj_search | jq -r 'length > 0 and all(.auth_ok)')" "the adapter fetches with secrets.env keys"
grep -v ATLASSIAN_API_TOKEN "$AG_DATA/secrets.env" >"$AG_T/secrets.tmp" && mv "$AG_T/secrets.tmp" "$AG_DATA/secrets.env"
assert_eq "needs_setup" "$(ag_src "$(ag_get)" jira state)" "a missing token alone keeps jira in setup"
rm -f "$AG_DATA/secrets.env"
pass "jira resolves keys from settings.json env and secrets.env like setup"

# A3 requires_env 선언: 소문자 키·숫자 값은 그 소스만 선언 오류, 문자열 하나도 받고 빈 값은 없는 것으로 본다. 기존 소스는 그대로.
AG_OUT="$(ag_get)"
assert_eq "error|true" "$(ag_src "$AG_OUT" badenv state)|$(ag_src "$AG_OUT" badenv invalid)" "a lowercase requires_env key is a declaration error"
assert_contains "$(ag_src "$AG_OUT" badenv error)" "requires_env" "the declaration error names requires_env"
mkdir -p "$HM_CODEX_SKILLS_DIR/badenv2" "$HM_CODEX_SKILLS_DIR/envone"
jq -n '{id: "badenv2", name: "숫자 키", fetch: ["true"], requires_env: ["OK_KEY", 3]}' >"$HM_CODEX_SKILLS_DIR/badenv2/agenda.json"
jq -n '{id: "envone", name: "키 하나", fetch: ["true"], requires_env: "AJ_TEST_KEY_648"}' >"$HM_CODEX_SKILLS_DIR/envone/agenda.json"
AG_OUT="$(ag_get)"
assert_eq "true" "$(ag_src "$AG_OUT" badenv2 invalid)" "a non-string requires_env value is a declaration error"
assert_eq "needs_setup" "$(ag_src "$AG_OUT" envone state)" "a single requires_env key that is missing needs setup"
assert_eq "connected|needs_setup" "$(ag_src "$AG_OUT" acme state)|$(ag_src "$AG_OUT" duo state)" "sources without requires_env keep their state"
jq -n '{env: {AJ_TEST_KEY_648: ""}}' >"$AG_T/settings.json"
assert_eq "needs_setup" "$(ag_src "$(ag_get)" envone state)" "an empty settings.json value counts as missing"
printf "export AJ_TEST_KEY_648='it'\\\\''s'\n" >"$AG_DATA/secrets.env"
assert_eq "disconnected" "$(ag_src "$(ag_get)" envone state)" "an escaped secrets.env value satisfies requires_env"
rm -rf "$HM_CODEX_SKILLS_DIR/badenv2" "$HM_CODEX_SKILLS_DIR/envone" "$AG_DATA/secrets.env"
pass "agenda validates requires_env and leaves other sources alone"

# A4·A5·A6·A7 연결·수집: Basic 인증, nextPageToken 페이지(2건씩 → 두 번), 필드 매핑, 기한 없는 이슈. 기본 JQL.
aj_keys_settings "$AJ_URL/"
: >"$AJ_LOG"
assert_eq "200" "$(ag_code "$(ag_post connect '{"source":"jira"}')")" "jira connects once keys exist"
AG_OUT="$(ag_wait '(.sources[] | select(.id == "jira") | .state) == "connected" and ([.items.todo[] | select(.source == "jira")] | length) == 3')" || fail "jira connects and fetches: $AG_OUT"
AJ_REQ="$(aj_search)"
assert_eq "2|true" "$(jq -r 'length' <<<"$AJ_REQ")|$(jq -r 'all(.auth_ok)' <<<"$AJ_REQ")" "two pages are requested with the Basic auth header"
assert_eq "null|2" "$(jq -r '"\(.[0].query.nextPageToken)|\(.[1].query.nextPageToken)"' <<<"$AJ_REQ")" "the second request carries nextPageToken"
assert_eq "assignee = currentUser() AND statusCategory != Done ORDER BY duedate ASC, updated DESC" "$(jq -r '.[0].query.jql' <<<"$AJ_REQ")" "the default JQL lists my open issues"
assert_eq "100|summary,status,priority,project,duedate,created,reporter" "$(jq -r '"\(.[0].query.maxResults)|\(.[0].query.fields)"' <<<"$AJ_REQ")" "the search asks for the mapped fields"
AJ_I="$(jq -c '.items.todo[] | select(.id == "ACME-1")' <<<"$AG_OUT")"
assert_eq "ACME-1 요약|2026-12-01|2026-11-20T10:15:30+09:00|Pat Reporter" "$(jq -r '"\(.title)|\(.due)|\(.created)|\(.from)"' <<<"$AJ_I")" "title, due, created and reporter are mapped"
assert_eq "High · Acme 프로젝트|$AJ_URL/browse/ACME-1|Jira" "$(jq -r '"\(.detail)|\(.url)|\(.source_name)"' <<<"$AJ_I")" "detail and browse url are mapped"
assert_eq "false|Acme 프로젝트" "$(jq -r '.items.todo[] | select(.id == "ACME-2") | "\(has("due"))|\(.detail)"' <<<"$AG_OUT")" "an issue without a due date stays without due"
# 상태(#668): 이름과 statusCategory key를 구조화 필드로 싣고 detail에는 상태가 없다. 모르는 분류 키는 status만 남긴다.
assert_eq "진행 중|indeterminate" "$(jq -r '"\(.status)|\(.status_category)"' <<<"$AJ_I")" "the status name and category are structured fields"
assert_eq "할 일|new" "$(jq -r '.items.todo[] | select(.id == "ACME-2") | "\(.status)|\(.status_category)"' <<<"$AG_OUT")" "a to-do issue carries the new category"
assert_eq "검토 대기|false|Low · 운영" "$(jq -r '.items.todo[] | select(.id == "OPS-3") | "\(.status)|\(has("status_category"))|\(.detail)"' <<<"$AG_OUT")" "an unknown category keeps only the status name"
assert_eq "false|2026-11-22T09:00:00-05:00" "$(jq -r '.items.todo[] | select(.id == "OPS-3") | "\(has("from"))|\(.created)"' <<<"$AG_OUT")" "an issue without a reporter has no from"
pass "jira fetches my open issues page by page and maps their fields"

# A8 상한: 1200건·한 페이지 100건이면 500줄에서 멈추고 요청은 5번 이하다.
cp "$AJ_STATE/issues.json" "$AG_T/jira-issues.json"
jq -n '[range(1; 1201) | {key: "BIG-\(.)", fields: {summary: "큰 목록 \(.)"}}]' >"$AJ_STATE/issues.json"
printf '100\n' >"$AJ_STATE/page_size"
: >"$AJ_LOG"
aj_run big fetch --since a --until b || fail "a big fetch succeeds: $(<"$AJ_OUT_DIR/big.err")"
assert_eq "500" "$(grep -c . "$AJ_OUT_DIR/big.out")" "the adapter stops at 500 issues"
(($(aj_search | jq 'length') <= 5)) || fail "a big fetch makes at most 5 requests"
mv "$AG_T/jira-issues.json" "$AJ_STATE/issues.json"
printf '2\n' >"$AJ_STATE/page_size"
pass "jira stops at 500 issues"

# A9 설정: 프로젝트 선택지는 가짜 서버 목록, 저장값은 600 파일, 다음 수집 JQL에 project in·watcher가 들어간다.
AG_RES="$(ag_sget jira)"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "jira settings are readable once connected"
assert_eq "ACME,OPS|ACME Acme 프로젝트|[]|false" "$(ag_body "$AG_RES" | jq -r '"\([.fields[] | select(.id == "projects") | .options[].value] | join(","))|\(.fields[] | select(.id == "projects") | .options[0].label)|\(.values.projects | tojson)|\(.values.watching)"')" "project options come from Jira and the defaults are empty"
assert_eq "false|false|고르지 않으면 모든 프로젝트" "$(ag_body "$AG_RES" | jq -r '"\(.fields[0].danger)|\(.fields[1].danger)|\(.fields[0].help)"')" "jira settings are not danger fields"
AG_RES="$(ag_post settings '{"source":"jira","values":{"projects":["ACME","OPS"],"watching":true}}')"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "jira settings save without confirmation"
assert_eq "600" "$(filemode "$AJ_SETTINGS_FILE")" "the jira settings file is private"
aj_run sget settings-get || fail "settings-get runs"
assert_eq '{"projects":["ACME","OPS"],"watching":true}' "$(jq -cS '.' "$AJ_OUT_DIR/sget.out")" "settings-get returns the saved values"
: >"$AJ_LOG"
assert_eq "true" "$(ag_body "$(ag_post refresh '{"source":"jira"}')" | jq -r '.ok')" "jira refetches after a settings change"
AJ_JQL="$(aj_search | jq -r '.[0].query.jql')"
assert_eq '(assignee = currentUser() OR watcher = currentUser()) AND statusCategory != Done AND project in ("ACME","OPS") ORDER BY duedate ASC, updated DESC' "$AJ_JQL" "the settings shape the JQL"
pass "jira settings pick projects and watched issues"

# A10 주입 거부: 프로젝트 키가 아닌 값·타입이 틀린 값은 settings-set이 거부하고 파일은 그대로다.
AJ_BEFORE="$(shasum -a 256 "$AJ_SETTINGS_FILE" 2>/dev/null || sha256sum "$AJ_SETTINGS_FILE")"
for AJ_V in '{"projects":["a\" OR 1=1"],"watching":false}' '{"projects":["acme"],"watching":false}' '{"projects":"ACME","watching":false}' \
  '{"projects":[],"watching":"yes"}' '[]' 'not json'; do
  AJ_RC=0; aj_run sset settings-set <<<"$AJ_V" || AJ_RC=$?
  [[ "$AJ_RC" != 0 ]] || fail "settings-set refuses $AJ_V"
done
assert_eq "$AJ_BEFORE" "$(shasum -a 256 "$AJ_SETTINGS_FILE" 2>/dev/null || sha256sum "$AJ_SETTINGS_FILE")" "refused settings leave the file unchanged"
pass "jira settings refuse values outside project keys"

# A11·A12 오류: 401·403은 토큰·권한 안내, 그 밖은 HTTP 상태 한 줄. 이전 항목은 남는다.
for AJ_CODE in 401 403; do
  printf '%s\n' "$AJ_CODE" >"$AJ_STATE/status"
  ag_post refresh '{"source":"jira"}' >/dev/null
  AG_OUT="$(ag_get)"
  assert_eq "error" "$(ag_src "$AG_OUT" jira state)" "jira shows an error on HTTP $AJ_CODE"
  assert_contains "$(ag_src "$AG_OUT" jira error)" "Jira 인증이 거부됐습니다(HTTP $AJ_CODE)" "HTTP $AJ_CODE is explained"
  assert_contains "$(ag_src "$AG_OUT" jira error)" "ATLASSIAN_API_TOKEN" "HTTP $AJ_CODE points to the token"
done
printf '500\n' >"$AJ_STATE/status"
AJ_RC=0; aj_run e500 fetch --since a --until b || AJ_RC=$?
assert_eq "1|Jira 요청 실패: HTTP 500" "$AJ_RC|$(tail -n 1 "$AJ_OUT_DIR/e500.err")" "the adapter reports other HTTP errors in one line"
ag_post refresh '{"source":"jira"}' >/dev/null
assert_contains "$(ag_src "$(ag_get)" jira error)" "Jira 요청 실패: HTTP 500" "the board shows the HTTP status"
rm -f "$AJ_STATE/status"
assert_eq "true" "$(ag_body "$(ag_post refresh '{"source":"jira"}')" | jq -r '.ok')" "jira recovers after the error"
pass "jira explains auth and HTTP errors"

# A14 [완료]: 보드에만 숨기고 done.json에 적는다. 가짜 서버에는 쓰기 요청이 없다.
AG_RES="$(ag_post "done" '{"source":"jira","id":"ACME-1"}')"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "a jira item can be marked done"
[[ -n "$(jq -r '.jira["ACME-1"] // empty' "$AG_DATA/board/agenda/done.json")" ]] || fail "done.json records the jira completion"
assert_eq "" "$(ag_get | jq -r '.items.todo[] | select(.id == "ACME-1") | .id')" "the finished jira item leaves the list"
assert_eq "0" "$(jq -s '[.[] | select(.method != "GET")] | length' "$AJ_LOG")" "jira receives no write request"
pass "jira done hides the item on the board only"

# A13 비밀 미노출: 토큰은 어댑터 출력·보드 데이터·선언 argv에 없고, 어댑터는 프로세스를 띄우지 않는다.
if grep -rqs "$AJ_SECRET" "$AJ_OUT_DIR" "$AG_DATA/board" "$ROOT/scripts/board/agenda/jira/agenda.json"; then fail "the jira token never reaches outputs or board data"; fi
assert_eq "0" "$(grep -c subprocess "$AJ_ADAPTER" || true)" "the jira adapter starts no process"
assert_contains "$(sed -n '1,60p' "$ROOT/scripts/board/agenda.py")" "requires_env" "the adapter contract documents requires_env"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "Jira" "the board skill names the jira source"
assert_contains "$(<"$ROOT/docs/privacy.md")" "Jira" "the privacy note covers jira"
assert_contains "$(<"$ROOT/.ai-harness/docs/ui.md")" "fake-jira.py" "the UI doc names the fake jira server"
pass "jira keeps the token out of outputs and data"

# A15 스프린트 기한(#662): duedate가 없으면 가장 이른 활성 스프린트의 endDate를 due로 쓰고 detail에 출처를 붙인다.
# 스프린트 필드는 /rest/api/3/field의 gh-sprint 항목에서 찾고, 그 조회가 실패하면 기한만 비운다.
cp "$AJ_STATE/issues.json" "$AG_T/jira-issues.json"
jq -n '[{id: "summary", name: "Summary", schema: {type: "string"}},
  {id: "customfield_10020", name: "Sprint", schema: {type: "array", custom: "com.pyxis.greenhopper.jira:gh-sprint"}}]' >"$AJ_STATE/fields.json"
jq -n '[
  {key: "SPR-1", fields: {summary: "기한 우선", status: {name: "할 일"}, duedate: "2026-12-01",
    customfield_10020: [{name: "Acme 7", state: "active", endDate: "2026-12-10T09:00:00.000Z"}]}},
  {key: "SPR-2", fields: {summary: "스프린트 기한", status: {name: "할 일"}, duedate: null,
    customfield_10020: [{name: "Acme 7", state: "active", endDate: "2026-12-05T09:00:00.000Z"}]}},
  {key: "SPR-3", fields: {summary: "여러 스프린트", duedate: null, customfield_10020: [
    {name: "Acme 9", state: "active", endDate: "2026-12-12T09:00:00.000Z"},
    "com.atlassian.greenhopper.service.sprint.Sprint@1[state=ACTIVE]",
    {name: "Acme 8", state: "active", endDate: "2026-12-04T09:00:00.000Z"},
    {name: "Acme 6", state: "closed", endDate: "2026-11-01T09:00:00.000Z"}]}},
  {key: "SPR-4", fields: {summary: "닫힌 스프린트만", status: {name: "할 일"}, duedate: null, customfield_10020: [
    {name: "Acme 5", state: "closed", endDate: "2026-11-01T09:00:00.000Z"},
    {name: "Acme 10", state: "future", endDate: "2026-12-20T09:00:00.000Z"}]}}
]' >"$AJ_STATE/issues.json"
: >"$AJ_LOG"
aj_run sprint fetch --since a --until b || fail "a fetch with sprints succeeds: $(<"$AJ_OUT_DIR/sprint.err")"
aj_item() { jq -c --arg k "$2" 'select(.id == $k)' "$AJ_OUT_DIR/$1.out"; }
assert_eq "2026-12-01|false" "$(aj_item sprint SPR-1 | jq -r '"\(.due)|\(.detail // "" | contains("스프린트"))"')" "duedate wins over the sprint end"
assert_eq "2026-12-05T09:00:00Z|스프린트 Acme 7 종료" "$(aj_item sprint SPR-2 | jq -r '"\(.due)|\(.detail)"')" "an issue without duedate takes its active sprint end"
assert_eq "2026-12-04T09:00:00Z|스프린트 Acme 8 종료" "$(aj_item sprint SPR-3 | jq -r '"\(.due)|\(.detail)"')" "the earliest active sprint wins and closed ones are ignored"
assert_eq "할 일|false" "$(aj_item sprint SPR-1 | jq -r '"\(.status)|\(has("status_category"))"')" "a status without statusCategory gives only the name"
assert_eq "false|false" "$(aj_item sprint SPR-3 | jq -r '"\(has("status"))|\(has("status_category"))"')" "an issue without status has no status fields"
assert_eq "false|false" "$(aj_item sprint SPR-4 | jq -r '"\(has("due"))|\(.detail // "" | contains("스프린트"))"')" "closed and future sprints give no due date"
assert_eq "summary,status,priority,project,duedate,created,reporter,customfield_10020" "$(aj_search | jq -r '[.[].query.fields] | unique | join(";")')" "the search asks for the sprint field it found"
assert_eq "1|GET" "$(jq -sr '[.[] | select(.path == "/rest/api/3/field")] | "\(length)|\([.[].method] | unique | join(","))"' "$AJ_LOG")" "the field list is read once with GET"
# 필드 메타 실패(500)·필드 없음(404): fetch는 성공하고 항목은 그대로, 기한만 없다.
printf '500\n' >"$AJ_STATE/field_status"
AJ_RC=0; aj_run sprint500 fetch --since a --until b || AJ_RC=$?
assert_eq "0|4|false" "$AJ_RC|$(grep -c . "$AJ_OUT_DIR/sprint500.out")|$(aj_item sprint500 SPR-2 | jq -r 'has("due")')" "a failing field list keeps the items without sprint dates"
rm -f "$AJ_STATE/field_status" "$AJ_STATE/fields.json"
: >"$AJ_LOG"
AJ_RC=0; aj_run sprint404 fetch --since a --until b || AJ_RC=$?
assert_eq "0|4|false" "$AJ_RC|$(grep -c . "$AJ_OUT_DIR/sprint404.out")|$(aj_item sprint404 SPR-2 | jq -r 'has("due")')" "a missing field list keeps the items without sprint dates"
assert_eq "summary,status,priority,project,duedate,created,reporter" "$(aj_search | jq -r '[.[].query.fields] | unique | join(";")')" "without a sprint field the search fields stay the same"
if grep -rqs "$AJ_SECRET" "$AJ_OUT_DIR"; then fail "the jira token stays out of sprint fetch outputs"; fi
mv "$AG_T/jira-issues.json" "$AJ_STATE/issues.json"
pass "jira uses the earliest active sprint end when an issue has no due date"

# 할 일 삭제(#637): 직접 적은 할 일은 열린 것이든 끝낸 것이든 todos.json·completed.json에서 빠진다.
AG_DID="$(ag_board todo add 지울 할 일)"
AG_RES="$(ag_post delete "$(jq -cn --arg i "$AG_DID" '{source: "todo", id: $i}')")"
assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "deleting a written to-do succeeds"
case "$(ag_board todo list --all)" in *"$AG_DID"*) fail "a deleted to-do leaves todos.json" ;; esac
AG_DID2="$(ag_board todo add 끝내고 지울 할 일)"
ag_board todo "done" "$AG_DID2"
assert_eq "1" "$(jq -r --arg i "$AG_DID2" '[.items[] | select(.id == $i)] | length' "$AG_DATA/board/agenda/completed.json")" "the finished to-do is in the completed list first"
assert_eq "200" "$(ag_code "$(ag_post delete "$(jq -cn --arg i "$AG_DID2" '{source: "todo", id: $i}')")")" "deleting a finished to-do succeeds"
assert_eq "0|0" "$(jq -r --arg i "$AG_DID2" '[.items[] | select(.id == $i)] | length' "$AG_DATA/board/agenda/todos.json")|$(jq -r --arg i "$AG_DID2" '[.items[] | select(.id == $i)] | length' "$AG_DATA/board/agenda/completed.json")" "a deleted finished to-do leaves todos.json and completed.json"
assert_eq "404" "$(ag_code "$(ag_post delete '{"source":"todo","id":"nope"}')")" "deleting an unknown to-do is 404"
assert_eq "400|400" "$(ag_code "$(ag_post delete '{"source":"todo"}')")|$(ag_code "$(ag_post delete '{"source":"todo","id":7}')")" "a delete without a string id is 400"
pass "agenda deletes written to-dos from the list and the completed list"

# 할 일 삭제(#637): board.sh todo delete — 성공 0, 없는 id 1, 인자 없음·둘·빈 id는 usage 2.
ag_del_rc() { local rc=0; ag_board todo delete "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
AG_DID3="$(ag_board todo add CLI로 지울 할 일)"
assert_eq "0 1 2 2 2" "$(ag_del_rc "$AG_DID3") $(ag_del_rc "$AG_DID3") $(ag_del_rc) $(ag_del_rc a b) $(ag_del_rc "")" "todo delete exit codes"
case "$(ag_board todo list --all)" in *"$AG_DID3"*) fail "todo delete removes the to-do" ;; esac
assert_contains "$(ag_board todo 2>&1 || true)" "|delete <id>" "the todo usage lists delete"
pass "board.sh todo delete removes a to-do with the documented exit codes"

# 할 일 삭제(#637): delete를 선언한 어댑터의 할 일·답할 것은 그 argv에 id를 붙여 지우고, 다시 수집하면 사라진다.
AG_OUT="$(ag_get)"
assert_eq "true|false|false" "$(ag_src "$AG_OUT" inbox can_delete)|$(ag_src "$AG_OUT" localdone can_delete)|$(ag_src "$AG_OUT" cal can_delete)" "can_delete follows the delete declaration"
for AG_I in i-due i-reply; do
  AG_RES="$(ag_post delete "$(jq -cn --arg i "$AG_I" '{source: "inbox", id: $i}')")"
  assert_eq "200|true" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "deleting inbox $AG_I succeeds"
  grep -qxF "delete $AG_I" "$AG_DATA/fixture-inbox/calls" || fail "the adapter delete command ran with $AG_I"
done
AG_OUT="$(ag_wait '[.items[][] | select(.source == "inbox" and (.id == "i-due" or .id == "i-reply"))] | length == 0')" || fail "deleted inbox items leave the agenda: $AG_OUT"
pass "agenda deletes adapter items through the declared delete command"

# 할 일 삭제(#637): delete 명령이 실패하면 ok:false와 사유, 항목은 남는다.
: >"$AG_DATA/fixture-inbox/fail-delete"
AG_RES="$(ag_post delete '{"source":"inbox","id":"i-bad"}')"
assert_eq "200|false" "$(ag_code "$AG_RES")|$(ag_body "$AG_RES" | jq -r '.ok')" "a failing delete command is reported"
assert_contains "$(ag_body "$AG_RES" | jq -r '.message')" "Example 요청함에서 지우지 못했습니다" "a failing delete names the source"
assert_contains "$(ag_body "$AG_RES" | jq -r '.message')" "원본 요청함에 닿지 못했습니다" "a failing delete carries the adapter's reason"
assert_eq "1" "$(ag_get | jq -r '[.items.todo[] | select(.id == "i-bad")] | length')" "a failed delete keeps the item"
rm -f "$AG_DATA/fixture-inbox/fail-delete"
pass "agenda keeps an item when the delete command fails"

# 할 일 삭제(#637): 일정 400, delete 미선언 409, 모르는 소스·항목 404, 토큰 없음 403.
ag_post connect '{"source":"cal"}' >/dev/null
ag_wait '[.items.event[] | select(.source == "cal" and .id == "e1")] | length == 1' >/dev/null || fail "cal still lists e1"
assert_eq "400" "$(ag_code "$(ag_post delete '{"source":"cal","id":"e1"}')")" "an event cannot be deleted"
AG_RES="$(ag_post delete '{"source":"localdone","id":"n1"}')"
assert_eq "409" "$(ag_code "$AG_RES")" "a source without delete refuses"
assert_contains "$(ag_body "$AG_RES" | jq -r '.message')" "원본에서" "the refusal points to the original"
assert_eq "404|404" "$(ag_code "$(ag_post delete '{"source":"nope","id":"x"}')")|$(ag_code "$(ag_post delete '{"source":"inbox","id":"never"}')")" "unknown sources and items are 404"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $AG_BASE" -d '{"source":"todo","id":"x"}' "$AG_BASE/agenda/delete")" "delete needs the board token"
pass "agenda refuses deleting events, undeclared sources and unknown items"

# 할 일 삭제(#637): delete가 문자열 배열이 아니면 그 소스만 선언 오류다. 계약 문서에 delete가 적혀 있다.
mkdir -p "$HM_CLAUDE_SKILLS_DIR/baddelete"
jq -n '{id: "baddelete", name: "삭제 오류", fetch: ["true"], delete: "rm.sh"}' >"$HM_CLAUDE_SKILLS_DIR/baddelete/agenda.json"
AG_OUT="$(ag_get)"
assert_eq "true" "$(ag_src "$AG_OUT" baddelete invalid)" "a non-array delete is a declaration error"
assert_contains "$(ag_src "$AG_OUT" baddelete error)" "delete" "the error names delete"
rm -rf "$HM_CLAUDE_SKILLS_DIR/baddelete"
assert_contains "$(sed -n '1,60p' "$ROOT/scripts/board/agenda.py")" "선택 delete(#637" "the adapter contract docstring documents delete"
assert_contains "$(sed -n '1,60p' "$ROOT/scripts/board/board-server.py")" "/agenda/delete" "the server path comment documents delete"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "todo delete <id>" "the board skill documents todo delete"
assert_contains "$(<"$ROOT/.ai-harness/docs/ui.md")" "fail-delete" "the UI doc names the delete fixture switch"
pass "agenda validates and documents the delete declaration"

# 할 일 삭제(#637): 화면 — 할 일·답할 것 줄의 [삭제]는 확인 대화(취소 초점·danger 확정)를 한 번 거쳐 /agenda/delete로 보낸다.
AG_TPLF="$ROOT/scripts/board/template.html"
AG_TPL="$(<"$AG_TPLF")"
assert_contains "$AG_TPL" "/agenda/delete" "the screen posts to /agenda/delete"
AG_ADLG="$(grep -E '<dialog class="b-dialog" id="adlg"' -A 6 "$AG_TPLF")"
[ -n "$AG_ADLG" ] || fail "the delete dialog adlg exists"
assert_contains "$AG_ADLG" "ds-btn--danger" "the delete dialog confirms with a danger button"
assert_contains "$AG_ADLG" 'id="acancel"' "the delete dialog has a cancel button"
AG_DEL_FN="$(sed -n '/^  \/\/ ---- 내 일정 할 일 삭제(이슈 637) ----$/,/^  \/\/ ---- 내 일정 할 일 삭제 끝 ----$/p' "$AG_TPLF")"
[ -n "$AG_DEL_FN" ] || fail "the delete code is found in the template"
assert_contains "$AG_DEL_FN" "\$('acancel').focus()" "the delete dialog focuses cancel"
if command -v node >/dev/null 2>&1; then
  AG_TROW="$(sed -n '/function taskRow(/,/^  }$/p' "$AG_TPLF")"
  AG_DSTUB='class E { constructor(t) { this.tag = t; this.attrs = {}; this.children = []; this.dataset = {}; this.textContent = ""; this.className = ""; }
    setAttribute(k, v) { this.attrs[k] = String(v); } getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; } removeAttribute(k) { delete this.attrs[k]; }
    append(...c) { this.children.push(...c.filter((x) => x != null)); } addEventListener() {} focus() { focused = this.id || this.dataset.key; } closest() { return null; } }
  let focused = null;
  const el = (t, c, x) => { const e = new E(t); if (c) e.className = c; if (x != null) e.textContent = x; return e; };
  const btn = (label, cls, f) => { const b = el("button", "ds-btn" + (cls ? " " + cls : ""), label); if (f) b.onclick = f; return b; };
  const icon = () => el("svg"); const badge = () => el("span"); const chip = (x) => el("span", "ds-chip", x);
  const agTitle = (c, k, f, title) => [el("button", c, title), null];
  const dueInfo = () => null; const agOpenLink = () => null; const agAge = () => ""; const agKey = (it) => it.source + ":" + it.id;
  const agFresh = new Set(); let SERVER = true;
  let agData = { sources: [{ id: "inbox", name: "Example 요청함", can_delete: true }, { id: "localdone", name: "Local 알림", can_delete: false }] };
  const dlg = { listeners: {}, open: false, shows: 0, returnValue: "x", addEventListener(k, f) { this.listeners[k] = f; },
    showModal() { this.open = true; this.shows++; }, close() { this.open = false; return this.listeners.close && this.listeners.close(); } };
  const D = { adlg: dlg }; const $ = (id) => D[id] || (D[id] = new E("x"), D[id].id = id, D[id]);
  const posts = []; const post = async (p, b) => { posts.push(p + " " + JSON.stringify(b)); return { ok: true, message: "지웠습니다." }; };
  const toasts = []; const toast = (m, ok) => toasts.push(ok + ":" + m); const loadAgenda = async () => {};
  const CSS = { escape: (s) => s }; const document = { querySelector: () => null, getElementById: () => null };
  const all = (n, f, out = []) => { if (n instanceof E) { if (f(n)) out.push(n); n.children.forEach((c) => all(c, f, out)); } return out; };
  const delBtn = (r) => all(r, (x) => (x.getAttribute("aria-label") || "").startsWith("삭제: "))[0];'
  AG_DOUT="$(AG_JS="$AG_DSTUB
$AG_TROW
$AG_DEL_FN" node -e 'eval(process.env.AG_JS + `
    (async () => {
      const rows = [["local", { source: "todo", id: "t1", kind: "todo", title: "직접", local: true }],
        ["inbox-reply", { source: "inbox", source_name: "Example 요청함", id: "r1", kind: "reply", title: "답장" }],
        ["inbox-todo", { source: "inbox", source_name: "Example 요청함", id: "i1", kind: "todo", title: "요청" }],
        ["localdone", { source: "localdone", id: "n1", kind: "reply", title: "알림" }],
        ["event", { source: "inbox", id: "e1", kind: "event", title: "회의" }]];
      console.log(rows.map(([n, it]) => { const b = delBtn(taskRow(it, 0, {})); return n + "=" + (b ? b.className + "|" + b.textContent + "|" + b.getAttribute("aria-label") : "none"); }).join("\\n"));
      SERVER = false; console.log("static=" + (delBtn(taskRow(rows[0][1], 0, {})) ? "button" : "none")); SERVER = true;
      const b = delBtn(taskRow(rows[1][1], 0, {}));
      b.onclick(); b.onclick();
      console.log("open=" + dlg.open + " shows=" + dlg.shows + " rv=" + JSON.stringify(dlg.returnValue) + " focus=" + focused + " desc=" + D.adesc.textContent);
      dlg.returnValue = "cancel"; await dlg.close();
      console.log("cancel posts=" + posts.length);
      const l = delBtn(taskRow(rows[0][1], 0, {})); l.onclick(); console.log("local desc=" + D.adesc.textContent);
      dlg.returnValue = "ok"; await dlg.close();
      console.log("ok posts=" + posts.join(",") + " toasts=" + toasts.join(","));
    })();
  `)')"
  assert_eq "local=ds-btn ds-btn--sm ds-btn--ghost b-agtask__del|삭제|삭제: 직접
inbox-reply=ds-btn ds-btn--sm ds-btn--ghost b-agtask__del|삭제|삭제: 답장
inbox-todo=ds-btn ds-btn--sm ds-btn--ghost b-agtask__del|삭제|삭제: 요청
localdone=none
event=none
static=none
open=true shows=1 rv=\"\" focus=acancel desc='답장'을(를) 지웁니다. Example 요청함 원본에서도 지워집니다.
cancel posts=0
local desc='직접'을(를) 지웁니다. 목록과 완료 기록에서 빠집니다.
ok posts=/agenda/delete {\"source\":\"todo\",\"id\":\"t1\"} toasts=true:지웠습니다." "$AG_DOUT" "delete buttons follow can_delete and the dialog opens once, cancels without a request and confirms with one"
fi
pass "the board asks once before deleting a to-do or reply"

# Jira 상태(#668): _normalize는 status를 공백 정리·40자로, status_category는 new|indeterminate|done만 남긴다.
# 허용하지 않는 값은 그 필드만 버리고 항목은 남긴다. 다른 출처도 같은 선택 필드를 쓸 수 있다.
AG_STATUS="$(python3 -I - "$ROOT/scripts/board" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import agenda
cases = [{"status": " 진행  중 ", "status_category": "indeterminate"}, {"status": "할 일", "status_category": "new"},
         {"status": "끝", "status_category": "done"}, {"status": "x", "status_category": "bogus"},
         {"status": "x", "status_category": 3}, {"status": "가" * 41}, {"status": "  "}, {"status": 7, "status_category": "new"}]
lines = [json.dumps(dict(c, id="s%d" % i, kind="todo", title="t")) for i, c in enumerate(cases)]
items, skipped = agenda.parse_jsonl("\n".join(lines), "s")
print("%d|%d" % (len(items), skipped))
for it in items:
    st = it.get("status", "-")
    print("%s|%s" % (st if len(st) < 30 else "len%d" % len(st), it.get("status_category", "-")))
PY
)"
assert_eq "8|0
진행 중|indeterminate
할 일|new
끝|done
x|-
x|-
len40|-
-|-
-|new" "$AG_STATUS" "agenda keeps a short status and only known status categories"
grep -q 'status_category' "$ROOT/scripts/board/agenda.py" || fail "the adapter contract documents status_category"
pass "agenda normalizes the structured status fields"

ag_board stop >/dev/null
unset TZ
finish_tests
