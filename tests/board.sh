#!/usr/bin/env bash
# 회귀 테스트 — Harness Board 서버·토큰·권한 훅·레퍼런스 보드·설정 쓰기·impact 화면
# 실행: bash tests/run.sh board
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-board.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-board.sh"

# 레퍼런스 보드(#336): 대시보드가 실행 기록을 읽어 목록·상세·파일·고르기를 보인다. 보드를 띄우기 전에 기록을 둔다
# (status.json은 몇 초 캐시한다). aaaa…는 보기 전용(랜딩 실행 없음), bbbb…는 reference_pick에서 기다리는 랜딩 실행,
# cccc…는 작업 폴더가 없어진 기록이다. 작업 폴더 밖 파일로 가는 심볼릭 링크와 허용하지 않는 확장자도 둔다.
BREF_DIR="$BOARD_DATA/board/references"; mkdir -p "$BREF_DIR"
BREF_VIEW="$BOARD_T/refs-view"; BREF_PICK="$BOARD_T/refs-pick"
for w in "$BREF_VIEW" "$BREF_PICK"; do
  mkdir -p "$w/refs/lay-a" "$w/refs/int-a" "$w/captures"
  printf 'png' >"$w/refs/lay-a/w1440-00.png"; printf 'webm' >"$w/refs/int-a/rec.webm"; printf '{}' >"$w/refs/lay-a/capture.json"
  printf '[{"id":"hero","label":"첫 화면"}]\n' >"$w/component-slots.json"
  jq -n '[{id:"tone-a",kind:"tone",title:"톤",captures:["refs/lay-a/w1440-00.png"]},
    {id:"com-a",kind:"component",title:"구성",recommended:"hero",captures:[]},
    {id:"lay-a",kind:"layout",title:"레이아웃",recommended:"layout",captures:["refs/lay-a/w1440-00.png","../outside.png","/etc/hosts"]},
    {id:"int-a",kind:"interaction",title:"인터랙션",recommended:"interaction",video:"refs/int-a/rec.webm"},
    {id:"cmp-a",kind:"competitor",title:"경쟁사",analysis:{leads_with:"x",claim:"y",cta:"z",gap:"w"}}]' >"$w/references.json"
done
printf 'secret' >"$BOARD_T/outside.png"; ln -s "$BOARD_T/outside.png" "$BREF_VIEW/refs/lay-a/link.png"; ln -s "$BOARD_T" "$BREF_VIEW/captures/up"
mkdir -p "$BREF_PICK/.landing-run"; printf '{"node":"reference_pick","entered_at":"2020-01-01T00:00:00Z"}\n' >"$BREF_PICK/.landing-run/state.json"
bref_rec() { jq -n --arg id "$1" --arg w "$2" --arg t "$3" '{run_id:$id, work:$w, topic:$t, status:"ready", created_at:"2026-11-14T00:00:00Z", updated_at:"2026-11-14T00:00:00Z"}' >"$BREF_DIR/$1.json"; }
bref_rec aaaaaaaaaaaa "$BREF_VIEW" "보기 전용 보드"; bref_rec bbbbbbbbbbbb "$BREF_PICK" "랜딩 고르기"; bref_rec cccccccccccc "$BOARD_T/gone" "사라진 보드"
assert_eq "false" "$(board_sh status | jq -r '.running')" "board is not running before open"
BOARD_OPEN="$(board_sh open)"
assert_eq "false" "$(jq -r '.reused' <<<"$BOARD_OPEN")" "board open starts a server"
BOARD_URL="$(jq -r '.url' <<<"$BOARD_OPEN")"
BOARD_TOKEN="${BOARD_URL#*t=}"
BOARD_BASE="http://127.0.0.1:$BOARD_PORT_T"
assert_contains "$BOARD_URL" "$BOARD_BASE/?t=" "board url is bound to 127.0.0.1 with a token"
assert_eq "600" "$(filemode "$BOARD_DATA/board/server.json")" "server.json is private"
assert_eq "true" "$(board_sh open | jq -r '.reused')" "board open reuses a running server"
assert_eq "$BOARD_URL" "$(board_sh status | jq -r '.url')" "board status reports the same url"
case "$(cat "$BOARD_DATA/board/server.log" 2>/dev/null)" in *"$BOARD_TOKEN"*) fail "server log does not carry the url token" ;; esac
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BOARD_BASE/status.json?t=wrong")" "board rejects a wrong token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BOARD_BASE/status.json")" "board rejects a missing token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: attacker.example:$BOARD_PORT_T" "$BOARD_BASE/status.json?t=$BOARD_TOKEN")" "board rejects a foreign Host (DNS rebinding)"
# JSON 본문은 jq로 만든다 — bash 3.2는 $( ) 안의 \"…,…\"를 중괄호 확장해 요청을 여러 개로 쪼갠다.
BOARD_SEEN_BODY="$(jq -cn --arg t "$BOARD_TOKEN" '{t: $t, ids: []}')"
assert_eq "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $BOARD_BASE" -d "$BOARD_SEEN_BODY" "$BOARD_BASE/seen")" "board accepts its own Origin"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://attacker.example' -d "$BOARD_SEEN_BODY" "$BOARD_BASE/seen")" "board rejects a foreign Origin"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "$BOARD_SEEN_BODY" "$BOARD_BASE/seen")" "board rejects a POST without Origin"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Board-Hook: wrong' -d '{}' "$BOARD_BASE/hook/permission")" "hook endpoint needs its own token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Board-Hook: $BOARD_TOKEN" -d '{}' "$BOARD_BASE/hook/permission")" "the url token does not open the hook endpoint"
BOARD_STATUS="$(curl -s "$BOARD_BASE/status.json?t=$BOARD_TOKEN")"
assert_eq "true" "$(jq '(.generated_at | type) == "string" and (.items | type) == "array" and (.jira_base | type) != "number"' <<<"$BOARD_STATUS")" "status.json shape"
assert_eq "true" "$(jq --arg sid "$BOARD_SID" 'any(.items[]; .section == "work" and .kind == "bg" and .sid == $sid and (.transcript | type) == "string" and (.actions | index("view")) != null and (.id | type) == "string")' <<<"$BOARD_STATUS")" "status.json lists the agent session from claude agents"
assert_eq "true" "$(jq 'any(.items[]; .section == "harness" and .kind == "harvest" and .state == "queued" and (.actions | index("harvest_now")) != null)' <<<"$BOARD_STATUS")" "status.json lists a queued harvest with its action"
assert_eq "true" "$(jq 'any(.items[]; .section == "harness" and .state == "needs_human" and .link == "https://github.com/example/svc/pull/1")' <<<"$BOARD_STATUS")" "status.json lists a draft PR that needs a human"
# 건너뛴 이유는 내부 코드가 아니라 사람 말로 보이고, 화면이 같은 원인끼리 묶도록 이유 코드는 따로 실린다(#291).
assert_eq "지난 동기화 PR 상태를 확인할 수 없어 멈춤|sync_pr_status_unknown 무인 실행을 건너뜀|brand_new_code" \
  "$(jq -r '[.items[] | select(.kind == "schedule" and .state == "blocked" and .project == "svc") | "\(.title)|\(.reason)"] | sort | reverse | join(" ")' <<<"$BOARD_STATUS")" \
  "a skipped run shows a readable title and keeps its reason code for grouping"
BOARD_ITEM_ID="$(jq -r --arg sid "$BOARD_SID" '.items[] | select(.sid == $sid) | .id' <<<"$BOARD_STATUS")"
BOARD_TRANSCRIPT="$(curl -s "$BOARD_BASE/transcript?t=$BOARD_TOKEN&id=$(jq -rn --arg v "$BOARD_ITEM_ID" '$v | @uri')&offset=0")"
assert_eq "hello board|done" "$(jq -r '[.messages[].text] | join("|")' <<<"$BOARD_TRANSCRIPT")" "board reads the session transcript"
BOARD_ACTION="$(curl -s -X POST -H "Origin: $BOARD_BASE" -d "$(jq -cn --arg t "$BOARD_TOKEN" --arg i "$BOARD_ITEM_ID" '{t: $t, id: $i, action: "rm -rf"}')" "$BOARD_BASE/action")"
assert_eq "false" "$(jq -r '.ok' <<<"$BOARD_ACTION")" "board refuses an action the item does not allow"
BOARD_SET="$(curl -s -X POST -H "Origin: $BOARD_BASE" -d "$(jq -cn --arg t "$BOARD_TOKEN" '{t: $t, kind: "sync", stage: "merge"}')" "$BOARD_BASE/settings/harness")"
assert_eq "true" "$(jq -r '.ok' <<<"$BOARD_SET")" "board writes the harness stage"
assert_contains "$(cat "$BOARD_DATA/config")" 'HM_SYNC_AUTO_MERGE="1"' "harness stage merge turns on auto merge"
assert_contains "$(cat "$BOARD_DATA/board/actions.jsonl")" '"action": "harness_stage"' "board logs actions under the data dir"
# 레퍼런스 보드(#336): 목록 — 주제·상태·탭별 개수, 폴더 없는 기록은 missing, 랜딩 실행이 기다리면 can_pick.
BREF_LIST="$(curl -s "$BOARD_BASE/references?t=$BOARD_TOKEN")"
assert_eq "aaaaaaaaaaaa|bbbbbbbbbbbb|cccccccccccc" "$(jq -r '[.runs[].run_id] | sort | join("|")' <<<"$BREF_LIST")" "the board lists every reference run record"
assert_eq "보기 전용 보드|ready|false|null|1,1,1,1,1" \
  "$(jq -r '.runs[] | select(.run_id == "aaaaaaaaaaaa") | [.topic, .status, .missing, .landing_node, ([.counts.tone, .counts.component, .counts.layout, .counts.interaction, .counts.competitor] | map(tostring) | join(","))] | map(tostring) | join("|")' <<<"$BREF_LIST")" \
  "a reference run shows its topic, status, and count per tab; without a landing run it is view-only"
assert_eq "true|false" "$(jq -r '.runs[] | select(.run_id == "cccccccccccc") | [.missing, .can_pick] | map(tostring) | join("|")' <<<"$BREF_LIST")" "a record whose work folder is gone is listed as missing"
assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' "$BOARD_BASE/references")" "the reference list needs the board token"
# 상세: 작업 폴더 밖 매체(../·절대 경로)는 싣지 않는다.
BREF_RUN="$(curl -s "$BOARD_BASE/references/run?t=$BOARD_TOKEN&run=aaaaaaaaaaaa")"
assert_eq '[{"path":"refs/lay-a/w1440-00.png"}]|refs/int-a/rec.webm|hero' \
  "$(jq -r '.run as $r | [($r.refs[] | select(.id == "lay-a") | .captures | tojson), ($r.refs[] | select(.id == "int-a") | .video.path), $r.slots[0].id] | join("|")' <<<"$BREF_RUN")" \
  "the run detail carries only media inside the work folder"
assert_eq 404 "$(curl -s -o /dev/null -w '%{http_code}' "$BOARD_BASE/references/run?t=$BOARD_TOKEN&run=../../etc")" "the run detail takes only a registered run id"
# 파일 서빙: refs/·captures/ 아래 이미지·영상만. ..·절대 경로·심볼릭 링크로 밖에 닿는 것·다른 확장자·등록 안 된 실행은 거부.
bref_file() { curl -s -o /dev/null -w '%{http_code}' -G "$BOARD_BASE/references/file" --data-urlencode "t=${3-$BOARD_TOKEN}" --data-urlencode "run=${2:-aaaaaaaaaaaa}" --data-urlencode "p=$1"; }
assert_eq 200 "$(bref_file refs/lay-a/w1440-00.png)" "the board serves a reference capture"
assert_eq 200 "$(bref_file refs/int-a/rec.webm)" "the board serves a reference recording"
assert_eq "206|bytes 1-2/4" "$(curl -s -D - -o /dev/null -H 'Range: bytes=1-2' -G "$BOARD_BASE/references/file" --data-urlencode "t=$BOARD_TOKEN" --data-urlencode run=aaaaaaaaaaaa --data-urlencode p=refs/int-a/rec.webm | tr -d '\r' | awk '/^HTTP/{c=$2} /^Content-Range:/{r=$2" "$3} END{print c"|"r}')" "a recording is served in byte ranges"
for bref_bad in ../outside.png refs/../../outside.png "$BOARD_T/outside.png" refs/lay-a/link.png captures/up/outside.png refs/lay-a/capture.json references.json .landing-run/state.json refs/lay-a/missing.png; do
  assert_eq 404 "$(bref_file "$bref_bad")" "the board refuses reference file $bref_bad"
done
assert_eq 404 "$(bref_file refs/lay-a/w1440-00.png 000000000000)" "the board refuses a file of an unregistered run"
assert_eq 403 "$(bref_file refs/lay-a/w1440-00.png aaaaaaaaaaaa wrong)" "the reference file needs the board token"
assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: attacker.example:$BOARD_PORT_T" -G "$BOARD_BASE/references/file" --data-urlencode "t=$BOARD_TOKEN" --data-urlencode run=aaaaaaaaaaaa --data-urlencode p=refs/lay-a/w1440-00.png)" "the reference file checks the Host"
# 고르기: 보기 전용 실행에는 쓰지 않는다. 기다리는 랜딩 실행은 지금 할 일 카드로 뜨고, 고르면 landing-pick.mjs가
# 보드 서버와 같은 reference-pick.json을 쓰고 실행 기록을 picked로 바꾼다. 두 번째 고르기는 409.
bref_pick() { curl -s -w '\n%{http_code}' -X POST -H "Origin: $BOARD_BASE" -d "$(jq -cn --arg t "$BOARD_TOKEN" --arg r "$1" --argjson b "$2" '$b + {t: $t, run: $r}')" "$BOARD_BASE/references/pick"; }
BREF_BODY='{"tone":"이대로","kept":["tone-a","com-a","lay-a","int-a"],"dropped":["cmp-a"],"add_sites":["https://example.com/x"],"user_words":"3D는 과하지 않게","primary":{"layout":"lay-a","interaction":"int-a","components":{"hero":"com-a"},"added_slots":[]}}'
assert_eq 409 "$(bref_pick aaaaaaaaaaaa "$BREF_BODY" | tail -1)" "a view-only reference board takes no pick"
assert_not_file "$BREF_VIEW/reference-pick.json"
assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://attacker.example' -d "$(jq -cn --arg t "$BOARD_TOKEN" '{t: $t, run: "bbbbbbbbbbbb"}')" "$BOARD_BASE/references/pick")" "a reference pick from another origin is refused"
if command -v node >/dev/null 2>&1; then
  assert_eq "true" "$(jq -r '.runs[] | select(.run_id == "bbbbbbbbbbbb") | .can_pick' <<<"$BREF_LIST")" "a landing run waiting at reference_pick can be picked on the board"
  assert_eq "needs_human|레퍼런스 고르기 — 랜딩 고르기|bbbbbbbbbbbb" \
    "$(curl -s "$BOARD_BASE/status.json?t=$BOARD_TOKEN" | jq -r '.items[] | select(.kind == "references") | [.state, .title, .run_id] | join("|")')" \
    "a landing run waiting at reference_pick shows as a to-do card"
  assert_eq 400 "$(bref_pick bbbbbbbbbbbb '{"tone":"이대로","kept":["tone-a"],"primary":{"layout":"lay-a","interaction":"int-a","components":{},"added_slots":[]},"dropped":["lay-a"]}' | tail -1)" "a pick that stars an excluded reference is refused"
  assert_eq 200 "$(bref_pick bbbbbbbbbbbb "$BREF_BODY" | tail -1)" "the board writes the pick of a waiting landing run"
  assert_eq "이대로|lay-a|int-a|com-a|cmp-a|https://example.com/x|3D는 과하지 않게|board" \
    "$(jq -r '[.tone, .primary.layout, .primary.interaction, .primary.components.hero, (.dropped | join(",")), (.add_sites | join(",")), .user_words, .via] | join("|")' "$BREF_PICK/reference-pick.json")" \
    "the board's pick has the same shape the board server writes"
  assert_eq picked "$(jq -r .status "$BREF_DIR/bbbbbbbbbbbb.json")" "a pick on the dashboard marks the run record picked"
  assert_eq 409 "$(bref_pick bbbbbbbbbbbb "$BREF_BODY" | tail -1)" "a second pick in the same node is refused"
  # status.json 캐시(최대 3초)가 지나 다시 모이면 카드가 내려간다 — 내려갈 때까지만 기다린다.
  BREF_CARD="x"
  for _ in $(seq 1 100); do
    BREF_CARD="$(curl -s "$BOARD_BASE/status.json?t=$BOARD_TOKEN" | jq -r '.items[] | select(.kind == "references") | .id')"
    [[ -z "$BREF_CARD" ]] && break
    sleep 0.1
  done
  assert_eq "" "$BREF_CARD" "the to-do card goes away once picked"
fi
# 화면: 고르기 대기·숫자는 랜딩 실행이 기다리는 것만(보기 전용은 중립 '준비됨'), 머리는 목록으로 → 제목·상태 → 탭 순서,
# 작업 폴더는 작게 한 줄로 줄이고 전체는 title과 복사로.
BREF_TPL="$(<"$ROOT/scripts/board/template.html")"
assert_contains "$BREF_TPL" "r.can_pick ? ['attention', '고르기 대기'] : ['info', '준비됨']" "a view-only reference board shows a neutral status, not waiting for a pick"
assert_contains "$BREF_TPL" "const w = (rdata || []).filter((r) => r.can_pick).length" "the sidebar counts only reference boards a landing run waits on"
assert_contains "$BREF_TPL" '<div class="b-refhead" id="refhead" hidden></div>
    <div class="ds-tabs" id="tabs"' "the reference head (back, title, status) sits above the tabs"
assert_contains "$BREF_TPL" "copyBtn('경로 복사', d.work" "the work folder path is shortened with a copy button"
pass "the Harness Board lists reference boards, serves only their media, and takes a pick for a waiting landing run (#336)"

# 레퍼런스 보드의 매체(#518): 작업 폴더의 medium.json이 탭·분석 라벨을 정하고, 이미지 레퍼런스는 원본 주소를 첫 매체로 싣는다.
# medium.json이 없는 실행은 web-page 라벨 그대로다.
BREF_PRINT="$BOARD_T/refs-print"; mkdir -p "$BREF_PRINT"
printf '{"medium":"print"}\n' >"$BREF_PRINT/medium.json"
jq -n '[{id:"img-a",kind:"layout",title:"포스터",image:"https://img.example/a.jpg",recommended:"layout"}]' >"$BREF_PRINT/references.json"
bref_rec dddddddddddd "$BREF_PRINT" "인쇄물 보드"
BREF_PRUN="$(curl -s "$BOARD_BASE/references/run?t=$BOARD_TOKEN&run=dddddddddddd")"
assert_eq 'print|판면 구성|전하는 메시지|{"remote":"https://img.example/a.jpg"}|https://img.example/a.jpg' \
  "$(jq -r '.run | [.medium, .labels.tabs.layout, .labels.analysis.claim, (.refs[0].captures[0] | tojson), .refs[0].image] | join("|")' <<<"$BREF_PRUN")" \
  "a print run carries its medium, its labels, and the image as its first medium"
assert_eq print "$(curl -s "$BOARD_BASE/references?t=$BOARD_TOKEN" | jq -r '.runs[] | select(.run_id == "dddddddddddd") | .medium')" "the list carries each run's medium"
assert_eq 'web-page|레이아웃|경쟁사 분석|첫 화면에서 내세우는 것' \
  "$(curl -s "$BOARD_BASE/references/run?t=$BOARD_TOKEN&run=aaaaaaaaaaaa" | jq -r '.run | [.medium, .labels.tabs.layout, .labels.tabs.competitor, .labels.analysis.leads_with] | join("|")')" \
  "a run without medium.json keeps the web page labels"
assert_contains "$BREF_TPL" "d && d.labels && d.labels.tabs ? REF_TABS.map(" "the board draws the run's tab labels"
assert_contains "$BREF_TPL" "d.labels.analysis[k] || l]) : REF_ANALYSIS" "the board draws the run's analysis labels and falls back to the web page labels"
assert_contains "$BREF_TPL" "refCounts(r)" "the list card counts tabs with the run's labels"
rm -f "$BREF_DIR/dddddddddddd.json"
pass "reference boards follow the run's medium: tab and analysis labels, image references (#518)"

# 권한 훅: 서버가 붙잡은 요청에 사람이 보드에서 허용하면 그 답을 Claude Code 형식으로 돌려준다.
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1","cwd":"/tmp"}' \
  | env -u AI_HARNESS_HEADLESS -u CLAUDE_PID CLAUDE_CODE_ENTRYPOINT=cli HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I "$ROOT/scripts/board/permission-hook.py" >"$BOARD_T/hook.out" &
BOARD_HOOK_PID=$!
BOARD_PERM=""
for _ in $(seq 100); do
  BOARD_PERM="$(curl -s "$BOARD_BASE/status.json?t=$BOARD_TOKEN" | jq -r '[.items[] | .permission.pid // empty][0] // empty')"
  [[ -n "$BOARD_PERM" ]] && break
  sleep 0.1
done
[[ -n "$BOARD_PERM" ]] || fail "board shows the held permission request"
BOARD_DECISION="$(jq -cn --arg t "$BOARD_TOKEN" --arg p "$BOARD_PERM" '{t: $t, pid: $p, decision: "allow"}')"
assert_eq "true" "$(curl -s -X POST -H "Origin: $BOARD_BASE" -d "$BOARD_DECISION" "$BOARD_BASE/permission" | jq -r '.ok')" "board accepts the human decision"
wait "$BOARD_HOOK_PID"
assert_eq "PermissionRequest|allow" "$(jq -r '[.hookSpecificOutput.hookEventName, .hookSpecificOutput.decision.behavior] | join("|")' "$BOARD_T/hook.out")" "permission hook returns the board decision"
assert_eq "" "$(printf '%s' '{"tool_name":"AskUserQuestion"}' | HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I "$ROOT/scripts/board/permission-hook.py")" "permission hook never forwards AskUserQuestion"
# headless(claude -p) 세션에는 답할 사람이 없다. 보는 사람이 있는 보드가 붙잡으면 러너가 멈추므로 훅이 서버를 부르지 않고 조용히 끝난다.
board_hook_headless() { # 이름 env... — 훅이 5초 안에 빈 출력으로 끝나고 보드에 요청이 남지 않아야 한다
  local name="$1" pid i
  shift
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s-headless","cwd":"/tmp"}' \
    | env -u AI_HARNESS_HEADLESS -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_PID "$@" HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I "$ROOT/scripts/board/permission-hook.py" >"$BOARD_T/hook-headless.out" &
  pid=$!
  for i in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    fail "permission hook does not forward a headless request ($name): $(curl -s "$BOARD_BASE/status.json?t=$BOARD_TOKEN" | jq -c '[.items[] | .permission // empty]')"
  fi
  wait "$pid"
  assert_eq "" "$(cat "$BOARD_T/hook-headless.out")" "permission hook prints nothing for a headless session ($name)"
}
board_hook_headless "runner env" AI_HARNESS_HEADLESS=1 CLAUDE_CODE_ENTRYPOINT=cli
board_hook_headless "claude -p entrypoint" CLAUDE_CODE_ENTRYPOINT=sdk-cli
# SDK 세션 안에서 띄운 claude -p 는 entrypoint 가 부모 값(sdk-ts)이다. 신호를 넘기지 않는 예전 러너는 세션 프로세스 인자(-p)로 가린다.
mkdir -p "$BOARD_T/fake"
printf '#!/bin/sh\nsleep 30\n' >"$BOARD_T/fake/claude"
chmod +x "$BOARD_T/fake/claude"
# 가짜 프로세스는 출력을 닫아 둔다 — 남은 sleep이 영역 출력 파이프를 쥐면 run.sh가 그만큼 끝을 기다린다.
"$BOARD_T/fake/claude" -p --permission-mode acceptEdits >/dev/null 2>&1 &
BOARD_FAKE_HEADLESS=$!
"$BOARD_T/fake/claude" --input-format stream-json --permission-prompt-tool stdio -p >/dev/null 2>&1 &
BOARD_FAKE_HOSTED=$!
board_hook_headless "claude -p process under an SDK session" CLAUDE_CODE_ENTRYPOINT=sdk-ts CLAUDE_PID="$BOARD_FAKE_HEADLESS"
# 권한을 대신 받는 호스트(SDK)가 붙은 세션은 사람이 답할 수 있으므로 그대로 보드에 넘긴다.
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s-hosted","cwd":"/tmp"}' \
  | env -u AI_HARNESS_HEADLESS CLAUDE_CODE_ENTRYPOINT=sdk-ts CLAUDE_PID="$BOARD_FAKE_HOSTED" HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I "$ROOT/scripts/board/permission-hook.py" >"$BOARD_T/hook-hosted.out" &
BOARD_HOOK_PID=$!
BOARD_PERM=""
for _ in $(seq 100); do
  BOARD_PERM="$(curl -s "$BOARD_BASE/status.json?t=$BOARD_TOKEN" | jq -r '[.items[] | .permission.pid // empty][0] // empty')"
  [[ -n "$BOARD_PERM" ]] && break
  sleep 0.1
done
[[ -n "$BOARD_PERM" ]] || fail "permission hook still forwards a host-attended SDK session"
curl -s -X POST -H "Origin: $BOARD_BASE" -d "$(jq -cn --arg t "$BOARD_TOKEN" --arg p "$BOARD_PERM" '{t: $t, pid: $p, decision: "deny"}')" "$BOARD_BASE/permission" >/dev/null
wait "$BOARD_HOOK_PID"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.decision.behavior' "$BOARD_T/hook-hosted.out")" "permission hook returns the board decision for a host-attended SDK session"
pkill -P "$BOARD_FAKE_HEADLESS" 2>/dev/null || true
pkill -P "$BOARD_FAKE_HOSTED" 2>/dev/null || true
kill "$BOARD_FAKE_HEADLESS" "$BOARD_FAKE_HOSTED" 2>/dev/null || true
wait "$BOARD_FAKE_HEADLESS" "$BOARD_FAKE_HOSTED" 2>/dev/null || true
# 예전 훅 사본이 넘겨도 서버가 붙잡지 않는다: 훅이 실어 보낸 값, 없으면 대화 기록의 최근 entrypoint.
BOARD_HOOK_TOKEN="$(jq -r '.token' "$BOARD_DATA/board/server.json")"
board_hold() { curl -s -m 2 -X POST -H "X-Board-Hook: $BOARD_HOOK_TOKEN" -d "$1" "$BOARD_BASE/hook/permission" || printf 'held'; }
assert_eq "{}" "$(board_hold '{"tool_name":"Bash","session_id":"s-headless","headless":true}')" "board does not hold a request marked headless"
assert_eq "{}" "$(board_hold '{"tool_name":"Bash","session_id":"s-headless","entrypoint":"sdk-cli"}')" "board does not hold a claude -p request"
printf '%s\n' '{"type":"user","entrypoint":"cli"}' '{"type":"assistant","entrypoint":"sdk-cli"}' >"$BOARD_T/headless.jsonl"
assert_eq "{}" "$(board_hold "$(jq -cn --arg p "$BOARD_T/headless.jsonl" '{tool_name: "Bash", session_id: "s-headless", transcript_path: $p}')")" "board reads the entrypoint from the transcript when the hook copy is old"
printf '%s\n' '{"type":"user","entrypoint":"sdk-cli"}' '{"type":"assistant","entrypoint":"cli"}' >"$BOARD_T/attended.jsonl"
assert_eq "held" "$(board_hold "$(jq -cn --arg p "$BOARD_T/attended.jsonl" '{tool_name: "Bash", session_id: "s-attended", transcript_path: $p}')")" "board still holds a request from an interactive session"
# claude -p 를 띄우는 곳은 모두 신호를 넘긴다(SDK 세션 안에서 띄우면 entrypoint 가 부모 값이라 훅이 구분하지 못한다).
for f in scripts/autofix-auto.sh scripts/harvest-auto.sh scripts/auto-merge.sh scripts/digest.sh scripts/ab.sh templates/workflow-driver/workflow-driver.sh; do
  assert_contains "$(cat "$ROOT/$f")" "AI_HARNESS_HEADLESS=1" "$f marks its unattended claude session as headless"
done
assert_eq "true" "$(board_sh stop | jq -r '.stopped')" "board stop stops the server"
assert_not_file "$BOARD_DATA/board/server.json"
assert_eq "false" "$(board_sh status | jq -r '.running')" "board status after stop"
assert_eq "" "$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I "$ROOT/scripts/board/permission-hook.py")" "permission hook prints nothing without a board"
printf '{"port": %s, "token": "x", "pid": 999999}' "$BOARD_PORT_T" >"$BOARD_DATA/board/server.json"
assert_eq "" "$(printf '%s' '{"tool_name":"Bash"}' | HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I "$ROOT/scripts/board/permission-hook.py")" "permission hook prints nothing when the board is gone"
assert_eq "false" "$(board_sh status | jq -r '.running')" "a stale server.json is not a running board"
# 포트를 다른 프로세스가 잡고 있으면 이유를 말하고 멈춘다.
BOARD_BUSY_PORT="$(free_port)"
python3 -I -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(30)' "$BOARD_BUSY_PORT" &
BOARD_BUSY_PID=$!
for _ in $(seq 50); do python3 -I -c 'import socket, sys; sys.exit(socket.socket().connect_ex(("127.0.0.1", int(sys.argv[1]))))' "$BOARD_BUSY_PORT" && break; sleep 0.1; done
if BOARD_BUSY_OUT="$(BOARD_PORT_OVERRIDE="$BOARD_BUSY_PORT" board_sh open 2>&1)"; then fail "board open refuses a port held by another process"; fi
assert_contains "$BOARD_BUSY_OUT" "다른 프로세스" "board open says why it stopped"
kill "$BOARD_BUSY_PID" 2>/dev/null || true
wait "$BOARD_BUSY_PID" 2>/dev/null || true
assert_not_file "$BOARD_DATA/board/server.json"
# BOARD_PORT를 정하지 않았을 때 시작 포트를 다른 프로세스가 쓰면 멈추지 않고 다음 빈 포트(최대 +9)에 띄운다.
BPF_DATA="$BOARD_T/port-fallback"; mkdir -p "$BPF_DATA"
BPF_P="$(free_port)"
bpf_sh() {
  env -u BOARD_PORT PATH="$BOARD_T/bin:$PATH" ORCA_CLI_COMMAND=orca HARNESS_METRICS_DIR="$BPF_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BOARD_T/projects" \
    HARNESS_CLAUDE_SETTINGS="$BOARD_T/settings.json" BOARD_PORT_BASE="$BPF_P" BOARD_NO_BROWSER=1 \
    BOARD_JIRA_URL= JIRA_BASE_URL= bash "$ROOT/scripts/board/board.sh" "$@"
}
python3 -I -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(30)' "$BPF_P" "$BPF_DATA" &
BPF_PID=$!
for _ in $(seq 50); do python3 -I -c 'import socket, sys; sys.exit(socket.socket().connect_ex(("127.0.0.1", int(sys.argv[1]))))' "$BPF_P" && break; sleep 0.1; done
if ! BPF_OUT="$(bpf_sh open --no-browser 2>&1)"; then
  kill "$BPF_PID" 2>/dev/null || true; wait "$BPF_PID" 2>/dev/null || true
  bpf_sh stop >/dev/null 2>&1 || true
  fail "board open falls back to a free port when the default is taken: $BPF_OUT"
fi
BPF_PORT="$(jq -r '.port' "$BPF_DATA/board/server.json")"
BPF_TOKEN="$(jq -r '.url' <<<"$BPF_OUT" | sed 's/.*[?&]t=//')"
assert_eq "true" "$(jq -r '.running' <<<"$BPF_OUT")" "fallback board reports running"
assert_eq "true" "$([ "$BPF_PORT" -gt "$BPF_P" ] && [ "$BPF_PORT" -le "$((BPF_P + 9))" ] && echo true || echo false)" "server.json records a port within the next 9 of the busy one (port=$BPF_PORT base=$BPF_P)"
assert_contains "$(jq -r '.url' <<<"$BPF_OUT")" ":$BPF_PORT/" "open output url carries the actual port"
assert_eq "200" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$BPF_PORT/status.json?t=$BPF_TOKEN")" "fallback board serves status.json on the actual port"
bpf_sh stop >/dev/null 2>&1 || true
kill "$BPF_PID" 2>/dev/null || true
wait "$BPF_PID" 2>/dev/null || true
assert_not_file "$BPF_DATA/board/server.json"
pass "harness board server, tokens, status and permission hook"

# 보드 설정 쓰기: 개인 단계·하네스 동작은 ~/.ai-harness/config의 해당 키만 바꾸고 다른 줄·권한은 그대로 둔다.
BOARD_REPO="$BOARD_T/repos/svc"
mkdir -p "$BOARD_REPO/.ai-harness"
git -C "$BOARD_REPO" init -q
printf '{"project_id":"svc-id","git_policy":"merge"}\n' >"$BOARD_REPO/.ai-harness/harness.json"
HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import settings as s
repo = sys.argv[2]
assert s.set_personal({"scope": "default", "level": "deploy"}, []) is None
assert s.set_personal({"scope": "default", "level": "bogus"}, []) is not None
assert s.set_personal({"scope": "repo", "repo": "/not/known", "level": "pr"}, [repo]) is not None
assert s.set_personal({"scope": "repo", "repo": repo, "level": "merge"}, [repo]) is None
assert s.set_harness({"kind": "harvest", "stage": "run"}) is None
assert s.set_harness({"kind": "harvest", "daily_max": 2}) is None
assert s.set_harness({"kind": "sync", "daily_max": 31}) is not None
assert s.set_harness({"kind": "sync", "daily_max": 5}) is None
assert s.set_harness({"kind": "other", "stage": "run"}) is not None
assert s.set_harness({"kind": "sync", "stage": "sideways"}) is not None
cfg = s.user_config()
assert cfg["HM_DELIVERY_LEVEL"] == "deploy" and cfg["HM_DELIVERY_LEVEL_REPOS"] == "svc-id=merge", cfg
row = s.read_repo(repo)
eff = s.effective(row, cfg)
assert eff["source"] == "team" and eff["level"] == "pr", eff  # 이 저장소엔 개인 단계를 읽는 러너가 없다
assert any("예전 병합 설정" in n for n in eff["notes"]), eff  # 설정 키 이름이 아니라 사람 말로(#291)
assert not any("git_policy" in n or "harness.json" in n for n in eff["notes"]), eff
' "$ROOT/scripts/board" "$BOARD_REPO" || fail "board settings writes validate input"
BOARD_CFG="$(cat "$BOARD_DATA/config")"
assert_contains "$BOARD_CFG" "# keep this comment" "config keeps comments"
assert_contains "$BOARD_CFG" "HM_DIGEST=1" "config keeps other keys"
assert_contains "$BOARD_CFG" "OTHER_TOOL_SETTING=x" "config keeps unknown lines"
assert_contains "$BOARD_CFG" 'HM_DELIVERY_LEVEL="deploy"' "personal default level written"
assert_contains "$BOARD_CFG" 'HM_DELIVERY_LEVEL_REPOS="svc-id=merge"' "personal repo level keyed by project_id"
assert_contains "$BOARD_CFG" 'HM_HARVEST_AUTO="1"' "harvest auto run written"
assert_contains "$BOARD_CFG" 'HM_SYNC_AUTO_DAILY_MAX="5"' "sync daily max written"
case "$BOARD_CFG" in *HM_HARVEST_AUTO_MERGE*) fail "harvest run stage leaves auto merge off" ;; esac
case "$BOARD_CFG" in *HM_HARVEST_AUTO_DAILY_MAX*) fail "the default daily max removes the line" ;; esac
assert_eq "1" "$(grep -c '^HM_DELIVERY_LEVEL=' "$BOARD_DATA/config")" "a key is written once"
assert_eq "600" "$(filemode "$BOARD_DATA/config")" "config keeps its mode"
assert_eq "deploy" "$(HARNESS_METRICS_DIR="$BOARD_DATA" bash -c 'source "$1/scripts/lib.sh"; printf %s "$HM_DELIVERY_LEVEL"' _ "$ROOT")" "the runner config reader reads what the board wrote"
pass "harness board settings writes"

# 설정 화면(#385): 고른 값은 저장 응답을 기다리지 않고 바로 보이고(실패하면 되돌림), 저장소 읽기는 병렬·추정 캐시로 빠르게 한다.
HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import settings as s
calls = []
s._suggest = lambda repo: calls.append(repo) or {"base": "main", "method": "squash", "host": "github"}
s._suggest_cache.clear()
assert s.suggest("/r") == s.suggest("/r") and calls == ["/r"], calls  # 두 번째 읽기는 git을 다시 부르지 않는다
s._suggest_cache["/r"] = (0, {})
s.suggest("/r")
assert calls == ["/r", "/r"], calls  # 오래된 추정은 다시 계산한다
' "$ROOT/scripts/board" || fail "board caches the base-branch guess"
BOARD_TPL="$(<"$ROOT/scripts/board/template.html")"
for f in "const setLevel = (body) => saveSetting(" "const setApproval = (body) => saveSetting(" "const setHarness = (body) => saveSetting(" "if (!res.ok) { undo(); sver++; renderAll(); }" "if (ver !== sver) return;"; do
  assert_contains "$BOARD_TPL" "$f" "settings save shows the choice at once and reverts on failure: $f"
done
assert_contains "$(<"$ROOT/scripts/board/board-server.py")" "pool.map(hsettings.read_repo, harness_repos())" "settings reads repositories in parallel"
pass "board settings show a choice at once"

# 보드의 승인 모드는 러너와 같은 개인 설정(HM_APPROVAL_REPOS > HM_APPROVAL > human)에서 계산한다.
# manifest에 남은 approval:"auto"는 보이지도 쓰이지도 않는다(#310).
BOARD_APPR_REPO="$BOARD_T/repos/appr"
mkdir -p "$BOARD_APPR_REPO/.ai-harness"
git -C "$BOARD_APPR_REPO" init -q
printf '{"project_id":"appr-id","git_policy":"pr-only","approval":"auto"}\n' >"$BOARD_APPR_REPO/.ai-harness/harness.json"
HM_APPROVAL='' HM_APPROVAL_REPOS='' HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import settings as s
repo = sys.argv[2]
assert "HM_APPROVAL" in s.PERSONAL_KEYS and "HM_APPROVAL_REPOS" in s.PERSONAL_KEYS, s.PERSONAL_KEYS
row = s.read_repo(repo)
assert (row["approval"], row["approval_source"]) == ("human", "none"), row  # manifest approval:auto는 무시
assert s.set_approval({"scope": "default", "mode": "auto"}, []) is None
row = s.read_repo(repo)
assert (row["approval"], row["approval_source"]) == ("auto", "default"), row
assert s.set_approval({"scope": "repo", "repo": repo, "mode": "human"}, [repo]) is None
row = s.read_repo(repo)
assert (row["approval"], row["approval_source"], row["approval_mine"]) == ("human", "repo", "human"), row
assert s.set_approval({"scope": "default", "mode": "sometimes"}, []) is not None
assert s.set_approval({"scope": "repo", "repo": "/not/known", "mode": "auto"}, [repo]) is not None
cfg = s.user_config()
assert cfg["HM_APPROVAL"] == "auto" and cfg["HM_APPROVAL_REPOS"] == "appr-id=human", cfg
assert s.set_approval({"scope": "repo", "repo": repo, "mode": ""}, [repo]) is None
assert s.set_approval({"scope": "default", "mode": ""}, []) is None
row = s.read_repo(repo)
assert (row["approval"], row["approval_source"], row["approval_mine"]) == ("human", "none", None), row
assert "HM_APPROVAL" not in s.user_config() and "HM_APPROVAL_REPOS" not in s.user_config()
# 러너 repository_setting과 같은 규칙: 같은 키는 마지막 값, 빈 값은 다음 단계(전체 설정)로 넘어간다.
assert s.approval_of("appr-id", {"HM_APPROVAL_REPOS": "appr-id=auto,appr-id=human"})["approval"] == "human"
assert s.approval_of("appr-id", {"HM_APPROVAL_REPOS": "appr-id=", "HM_APPROVAL": "auto"})["approval_source"] == "default"
' "$ROOT/scripts/board" "$BOARD_APPR_REPO" || fail "board approval mode follows the personal settings"
# 아직 동기화하지 않은 저장소(#294 이전 러너)는 manifest approval을 읽는다 — 보드도 그 값을 legacy로 보인다.
mkdir -p "$BOARD_APPR_REPO/.ai-harness/workflows"
printf '#!/usr/bin/env bash\n# HM_DELIVERY_LEVEL only\n' >"$BOARD_APPR_REPO/.ai-harness/workflows/workflow-driver.sh"
HM_APPROVAL='' HM_APPROVAL_REPOS='' HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import settings as s
row = s.read_repo(sys.argv[2])
assert (row["approval"], row["approval_source"]) == ("auto", "legacy"), row
' "$ROOT/scripts/board" "$BOARD_APPR_REPO" || fail "board shows the manifest approval for a runner that predates personal approval"
assert_contains "$(<"$BOARD_DATA/config")" "# keep this comment" "approval writes keep other config lines"
pass "harness board approval mode follows personal settings"

# 보드의 기본 런타임도 러너와 같은 개인 설정(HM_RUNTIME_REPOS > HM_RUNTIME > 자동 선택)에서 계산하고 같은 파일에 쓴다(#488).
BOARD_RT_REPO="$BOARD_T/repos/rt"
mkdir -p "$BOARD_RT_REPO/.ai-harness/workflows"
git -C "$BOARD_RT_REPO" init -q
printf '{"project_id":"rt-id","git_policy":"pr-only"}\n' >"$BOARD_RT_REPO/.ai-harness/harness.json"
cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$BOARD_RT_REPO/.ai-harness/workflows/workflow-driver.sh"
HM_RUNTIME='' HM_RUNTIME_REPOS='' HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import settings as s
repo = sys.argv[2]
assert "HM_RUNTIME" in s.PERSONAL_KEYS and "HM_RUNTIME_REPOS" in s.PERSONAL_KEYS, s.PERSONAL_KEYS
assert s.RUNTIMES == ("claude", "codex"), s.RUNTIMES
assert s.runner_runtime(repo) == "personal"
row = s.read_repo(repo)
assert (row["runtime"], row["runtime_source"], row["runtime_mine"]) == (None, "none", None), row
assert s.set_runtime({"scope": "default", "runtime": "claude"}, []) is None
assert "HM_RUNTIME=\"claude\"" in open(s.CONFIG).read()
row = s.read_repo(repo)
assert (row["runtime"], row["runtime_source"], row["runtime_mine"]) == ("claude", "default", None), row
s.write_user_config({"HM_RUNTIME_REPOS": "other-id=claude"})
assert s.set_runtime({"scope": "repo", "repo": repo, "runtime": "codex"}, [repo]) is None
assert s.user_config()["HM_RUNTIME_REPOS"] == "other-id=claude,rt-id=codex", s.user_config()
row = s.read_repo(repo)
assert (row["runtime"], row["runtime_source"], row["runtime_mine"]) == ("codex", "repo", "codex"), row
before = open(s.CONFIG).read()
assert s.set_runtime({"scope": "default", "runtime": "gemini"}, []) is not None
assert s.set_runtime({"scope": "repo", "repo": repo, "runtime": "bogus"}, [repo]) is not None
assert s.set_runtime({"scope": "repo", "repo": "/not/known", "runtime": "codex"}, [repo]) is not None
assert open(s.CONFIG).read() == before, "rejected runtime writes change nothing"
assert s.set_runtime({"scope": "repo", "repo": repo, "runtime": ""}, [repo]) is None
assert s.user_config()["HM_RUNTIME_REPOS"] == "other-id=claude", s.user_config()
assert s.set_runtime({"scope": "default", "runtime": ""}, []) is None
assert "HM_RUNTIME=" not in open(s.CONFIG).read()
s.write_user_config({"HM_RUNTIME_REPOS": ""})
# 러너 runtime_setting과 같은 규칙: 저장소 값 > 전체 값 > 없음, 같은 키는 마지막 값, 잘못된 값도 그대로 보인다.
assert s.runtime_of("rt-id", {"HM_RUNTIME_REPOS": "rt-id=codex,rt-id=claude", "HM_RUNTIME": "codex"})["runtime"] == "claude"
assert s.runtime_of("rt-id", {"HM_RUNTIME_REPOS": "rt-id=", "HM_RUNTIME": "codex"})["runtime_source"] == "default"
assert s.runtime_of("rt-id", {"HM_RUNTIME": "gemini"})["runtime"] == "gemini"
' "$ROOT/scripts/board" "$BOARD_RT_REPO" || fail "board runtime follows the personal settings"
# HM_RUNTIME을 모르는 옛 러너는 설정을 무시하고 자동 선택하므로 legacy로 보이고, 고른 값은 남는다.
printf '#!/usr/bin/env bash\n# HM_DELIVERY_LEVEL HM_APPROVAL only\n' >"$BOARD_RT_REPO/.ai-harness/workflows/workflow-driver.sh"
HM_RUNTIME='' HM_RUNTIME_REPOS='' HARNESS_METRICS_DIR="$BOARD_DATA" python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import settings as s
repo = sys.argv[2]
assert s.runner_runtime(repo) == "old"
assert s.set_runtime({"scope": "repo", "repo": repo, "runtime": "claude"}, [repo]) is None
row = s.read_repo(repo)
assert (row["runtime"], row["runtime_source"], row["runtime_mine"]) == (None, "legacy", "claude"), row
assert s.set_runtime({"scope": "repo", "repo": repo, "runtime": ""}, [repo]) is None
' "$ROOT/scripts/board" "$BOARD_RT_REPO" || fail "board shows legacy runtime for a runner that predates personal runtime"
assert_contains "$(<"$BOARD_DATA/config")" "# keep this comment" "runtime writes keep other config lines"
for f in "const setRuntime = (body) => saveSetting('/settings/runtime'" "settingRow('set-runtime', '내 기본 런타임'" "[['', '자동 선택'], ...RUNTIMES]" "[['', '기본 따름'], ...RUNTIMES]" "rg.setAttribute('aria-labelledby'" "r.approval_mine || r.runtime_mine"; do
  assert_contains "$BOARD_TPL" "$f" "the work settings tab has the runtime controls: $f"
done
pass "harness board runtime follows personal settings"

# 권한 훅 연결은 setup이 물은 뒤 board.sh hook on|off로만: 백업을 남기고 다른 설정은 그대로 둔다.
printf '{"env":{"KEEP":"1"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"true"}]}]}}\n' >"$BOARD_T/settings.json"
assert_eq "false" "$(board_sh hook status | jq -r '.installed')" "hook not installed by default"
BOARD_HOOK_ON="$(board_sh hook on)"
assert_eq "installed" "$(jq -r '.action' <<<"$BOARD_HOOK_ON")" "hook on installs"
assert_file "$(jq -r '.backup' <<<"$BOARD_HOOK_ON")"
assert_file "$BOARD_DATA/board/bin/permission-hook.py"
assert_eq "3600" "$(jq '.hooks.PermissionRequest[0].hooks[0].timeout' "$BOARD_T/settings.json")" "hook timeout covers the board wait"
assert_eq "1|true" "$(jq -r '[.env.KEEP, (.hooks.PreToolUse | length == 1)] | map(tostring) | join("|")' "$BOARD_T/settings.json")" "hook on keeps other settings"
assert_eq "unchanged" "$(board_sh hook on | jq -r '.action')" "hook on is idempotent"
assert_eq "removed" "$(board_sh hook off | jq -r '.action')" "hook off removes"
assert_eq "null|1" "$(jq -r '[(.hooks.PermissionRequest | tostring), (.hooks.PreToolUse | length | tostring)] | join("|")' "$BOARD_T/settings.json")" "hook off leaves other hooks"
assert_not_file "$BOARD_DATA/board/bin/permission-hook.py"
BOARD_SKILL="$(<"$ROOT/skills/board/SKILL.md")"
assert_file "$ROOT/skills/board/agents/openai.yaml"
assert_contains "$BOARD_SKILL" "board.sh open" "board skill opens through board.sh"
assert_contains "$BOARD_SKILL" "몰래 연결하지 않는다" "board skill does not wire the hook itself"
assert_contains "$(<"$ROOT/skills/setup/SKILL.md")" "board.sh hook on" "setup offers the board permission hook"
assert_contains "$(<"$ROOT/README.md")" "| \`/board\` |" "README lists board"
if grep -rIqE 'https://[a-z0-9-]+\.atlassian\.net|bitbucket\.org/[a-z]' "$ROOT/scripts/board" "$ROOT/skills/board"; then
  fail "board code carries no organization URL"
fi
pass "harness board skill and hook wiring"


# 보드 '하네스 효과'(#256): impact.sh compare를 뒤에서 돌려 저장소·날짜별로 캐시하고, /harness-impact가 보관한 매칭으로 판정한다.
# compare는 가짜 스크립트(고정 JSON·exit 3)로 바꾸고, view·render는 진짜 impact.sh로 돌린다.
BIMP_T="$BOARD_T/impact"
BIMP_DATA="$BIMP_T/data"
mkdir -p "$BIMP_T/repos/app/.ai-harness" "$BIMP_T/repos/noinst/.ai-harness" "$BIMP_DATA/harvest-auto"
git -C "$BIMP_T/repos/app" init -q
printf '{"project_id":"app","initialized":"2026-10-01"}\n' >"$BIMP_T/repos/app/.ai-harness/harness.json"
printf '{"project_id":"noinst"}\n' >"$BIMP_T/repos/noinst/.ai-harness/harness.json"
jq -cn --arg r "$BIMP_T/repos/app" '{event:"finished", project:"app", scope:"repo", at:"2026-11-01T00:00:00Z", repo:$r, result:"none"}' \
  >"$BIMP_DATA/harvest-auto/runs.jsonl"
bimp_fixture() { # today → 가짜 compare JSON
  jq -n --arg today "$1" '{v:1, project:"app", root:"/x", today:$today, installed:{date:"2026-10-01", source:"harness.json"}, window_days:30,
    periods:{
      before:{since:"2026-09-01", until:"2026-10-01", sessions:12, digested_sessions:10, corrections:8, corrections_per_session:0.8,
              missing_context:5, missing_context_per_session:0.5, guard_blocks:0, turns_median:9},
      after:{since:"2026-10-05", until:"2026-11-04", sessions:20, digested_sessions:18, corrections:3, corrections_per_session:0.17,
             missing_context:2, missing_context_per_session:0.11, guard_blocks:4, turns_median:7}},
    weekly:[{week:"2026-09-28", after_install:false, sessions:3, digested_sessions:3, corrections_per_session:0.7, missing_context_per_session:0.3, guard_blocks:0},
            {week:"2026-10-05", after_install:true, sessions:5, digested_sessions:4, corrections_per_session:null, missing_context_per_session:0.2, guard_blocks:2}],
    corrections:{before:{total:1, truncated:false, items:[{date:"2026-09-02", summary:"교정 원문은 보드에 싣지 않음", evidence:"x"}]},
                 after:{total:0, truncated:false, items:[]}},
    missing_context:{before:{total:0, truncated:false, items:[]}, after:{total:0, truncated:false, items:[]}},
    rework:null, warnings:["low_sample"], timeline:[], adoption:{active_sessions:0, harness_sessions:0, top_docs:[]},
    improvements:[
      {id:"h1", date:"2026-10-10", summary:"커버리지 게이트 선검증", expected:"재발 0", artifact:"https://example.com/pr/1", change:"add",
       before:{basis:"batch", batch_sessions:3, observed:3, candidates:{truncated:false, items:[
         {id:"s-b1#0", date:"2026-10-03", category:"correction", summary:"게이트를 CI에서야 발견"},
         {id:"s-b2#0", date:"2026-10-04", category:"workflow_gap", summary:"게이트 늦게 확인"}]}},
       after:{since:"2026-10-10T00:00:00Z", observed:10, observed_by_day:{"2026-10-12":3, "2026-10-20":3, "2026-11-02":4},
              candidates:{truncated:false, items:[{id:"s-a1#0", date:"2026-10-20", category:"workflow_gap", summary:"다른 일"},
                                                  {id:"s-a9#0", date:"2026-11-02", category:"correction", summary:"또 게이트"}]}}},
      {id:"h2", date:"2026-10-15", summary:"배포 순서 규칙", expected:null, artifact:"https://example.com/pr/2", change:"add",
       before:{basis:"batch", batch_sessions:1, observed:10, candidates:{truncated:false, items:[{id:"s-b3#0", date:"2026-10-14", category:"correction", summary:"배포 순서 틀림"}]}},
       after:{since:"2026-10-15T00:00:00Z", observed:10, observed_by_day:{"2026-10-16":3, "2026-10-22":3, "2026-11-02":4},
              candidates:{truncated:false, items:[{id:"s-a2#0", date:"2026-10-22", category:"correction", summary:"배포 순서 또 틀림"}]}}},
      {id:"h3", date:"2026-10-28", summary:"새 규칙", expected:null, artifact:null, change:"add",
       before:{basis:"window", observed:2, candidates:{truncated:false, items:[]}},
       after:{since:"2026-10-28T00:00:00Z", observed:2, observed_by_day:{"2026-11-02":2}, candidates:{truncated:false, items:[]}}},
      {id:"h4", date:"2026-10-02", summary:"안 쓰는 규칙 제거", expected:null, artifact:null, change:"remove",
       before:{basis:"window", observed:4, candidates:{truncated:false, items:[]}},
       after:{since:"2026-10-02T00:00:00Z", observed:9, observed_by_day:{"2026-10-10":9}, candidates:{truncated:false, items:[]}}}]}'
}
bimp_fixture 2026-10-25 >"$BIMP_T/old.json"
bimp_fixture 2026-11-03 >"$BIMP_T/new.json"
# /harness-impact 3·4단계: 에이전트가 맞춘 하이라이트로 render하면 그 매칭이 compare의 --today와 함께 보관된다.
printf '%s\n' '{"improvements":[{"id":"h1","before":["s-b1#0","s-b2#0"],"after":[]},{"id":"h2","before":["s-b3#0"],"after":["s-a2#0"]}]}' >"$BIMP_T/hl.json"
HARNESS_METRICS_DIR="$BIMP_DATA" "$ROOT/scripts/impact.sh" render --data "$BIMP_T/old.json" --highlights "$BIMP_T/hl.json" --out "$BIMP_T/skill.html" >/dev/null
BIMP_KEEP="$BIMP_DATA/reports/highlights/$(hm_short_key app).json"
assert_eq "app 2026-10-25 2" "$(jq -r '"\(.project) \(.matched_through) \(.improvements | length)"' "$BIMP_KEEP")" "impact render keeps the matching per project with the day it covers"
# 보관된 매칭은 그날까지의 세션으로만 판정한다: h1은 10-25까지 6세션 중 재발 0 → 사라짐, 그 뒤 4세션은 아직 맞춰 보지 않음.
BIMP_VIEW="$(HARNESS_METRICS_DIR="$BIMP_DATA" "$ROOT/scripts/impact.sh" view --data "$BIMP_T/new.json")"
assert_eq "gone:6:4:2026-10-25 recurred:6:4:2026-10-25 hold unmatched" \
  "$(jq -r '[.improvements[].result | if .after_hits == null then .verdict else "\(.verdict):\(.observed):\(.unjudged):\(.as_of)" end] | join(" ")' <<<"$BIMP_VIEW")" \
  "impact view judges kept matches only up to the matched day and holds unmatched improvements with few sessions"
assert_eq "false" "$(jq '[.. | objects | has("candidates")] | any' <<<"$BIMP_VIEW")" "impact view drops the candidate pools"
assert_eq "$BIMP_KEEP" "$(jq -r '.highlights.file' <<<"$BIMP_VIEW")" "impact view names the kept matching"
cat >"$BIMP_T/impact.sh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == compare ]]; then
  printf '%s\n' "\$3" >>"$BIMP_T/compare.log"
  case "\$3" in */noinst) echo "설치일을 찾지 못함" >&2; exit 3 ;; esac
  sleep 0.3
  cat "$BIMP_T/new.json"
  exit 0
fi
exec bash "$ROOT/scripts/impact.sh" "\$@"
EOF
chmod +x "$BIMP_T/impact.sh"
BIMP_PORT="$(free_port)"
bimp_sh() {
  env PATH="$BOARD_T/bin:$PATH" ORCA_CLI_COMMAND=orca HARNESS_METRICS_DIR="$BIMP_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BOARD_T/projects" \
    HARNESS_CLAUDE_SETTINGS="$BOARD_T/settings.json" BOARD_PORT="$BIMP_PORT" BOARD_NO_BROWSER=1 BOARD_IMPACT_SH="$BIMP_T/impact.sh" \
    BOARD_JIRA_URL= JIRA_BASE_URL= bash "$ROOT/scripts/board/board.sh" "$@"
}
BIMP_URL="$(bimp_sh open | jq -r '.url')"
BIMP_TOKEN="${BIMP_URL#*t=}"
BIMP_BASE="http://127.0.0.1:$BIMP_PORT"
bimp_get() { curl -s "$BIMP_BASE/impact?t=$BIMP_TOKEN"; }
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BIMP_BASE/impact?t=wrong")" "impact endpoint checks the token"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: attacker.example:$BIMP_PORT" "$BIMP_BASE/impact?t=$BIMP_TOKEN")" "impact endpoint checks the Host"
BIMP_FIRST="$(bimp_get)"
assert_eq "true" "$(jq '.ok and (.repos | length) == 2 and all(.repos[]; .state == "queued" or .state == "running")' <<<"$BIMP_FIRST")" \
  "impact endpoint answers at once and computes in the background"
BIMP=""
for _ in $(seq 100); do
  BIMP="$(bimp_get)"
  jq -e 'all(.repos[]; .state == "ready" or .state == "failed")' <<<"$BIMP" >/dev/null && break
  sleep 0.1
done
BIMP_APP="$(jq -c '.repos[] | select(.name == "app")' <<<"$BIMP")"
BIMP_NO="$(jq -c '.repos[] | select(.name == "noinst")' <<<"$BIMP")"
assert_eq "ready" "$(jq -r '.state' <<<"$BIMP_APP")" "impact computes a repo with an install date"
assert_eq "true" "$(jq '(.computed_at | type) == "string" and .installed.date == "2026-10-01" and .before.corrections == 8 and .after.guard_blocks == 4
  and (.weekly | length) == 2 and .warnings == ["low_sample"] and .matched_through == "2026-10-25" and .rework == null' <<<"$BIMP_APP")" "impact endpoint shape: periods, weekly, warnings"
assert_eq "h4:remove:unmatched h3:add:hold h2:add:recurred h1:add:gone" "$(jq -r '[.improvements[] | "\(.id):\(.change):\(.result.verdict)"] | join(" ")' <<<"$BIMP_APP")" \
  "impact endpoint lists improvements newest first with the change kind"
assert_eq "$(jq -c '[.improvements[] | .result.verdict] | reverse' <<<"$BIMP_VIEW")" "$(jq -c '[.improvements[].result.verdict]' <<<"$BIMP_APP")" \
  "board verdicts are the ones impact.sh view computes"
assert_eq "$(jq -c '.assessment' <<<"$BIMP_VIEW")" "$(jq -c '.assessment' <<<"$BIMP_APP")" \
  "board carries the comparability, trends, and repo status impact.sh view computes"
assert_eq "mixed true down" "$(jq -r '.assessment | "\(.status.key) \(.metrics.corrections_per_session.comparable) \(.metrics.corrections_per_session.change)"' <<<"$BIMP_APP")" \
  "board repo status weighs improvements that held against ones that recurred"
assert_eq "10 0 6 4" "$(jq -r '.improvements[] | select(.id == "h1") | "\(.observed_now) \(.result.after_hits) \(.result.observed) \(.result.unjudged)"' <<<"$BIMP_APP")" \
  "impact card carries sessions observed now and the judged recurrence"
case "$BIMP" in *candidates*|*"교정 원문"*) fail "impact endpoint does not ship candidate pools or correction text" ;; esac
assert_eq "failed 3" "$(jq -r '"\(.state) \(.error.code)"' <<<"$BIMP_NO")" "impact shows a failed compare"
assert_contains "$(jq -r '.error.reason' <<<"$BIMP_NO")" "설치일을 찾지 못함" "impact says why the compare failed"
BIMP_CALLS="$(wc -l <"$BIMP_T/compare.log" | tr -d ' ')"
assert_eq "2" "$BIMP_CALLS" "impact computes each repo once"
BIMP_AT="$(jq -r '.computed_at' <<<"$BIMP_APP")"
bimp_get >/dev/null
sleep 0.5  # 일어나지 않음 확인: 다시 계산하면 가짜 compare(0.3초)가 이 안에 기록을 남긴다
assert_eq "2 $BIMP_AT" "$(wc -l <"$BIMP_T/compare.log" | tr -d ' ') $(bimp_get | jq -r '.repos[] | select(.name == "app") | .computed_at')" \
  "impact reuses today's cache and does not retry today's failure on its own"
BIMP_REPO="$(jq -r '.repo' <<<"$BIMP_APP")"
BIMP_BODY="$(jq -cn --arg t "$BIMP_TOKEN" --arg r "$BIMP_REPO" '{t: $t, repo: $r}')"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "$BIMP_BODY" "$BIMP_BASE/impact/refresh")" "impact refresh checks the Origin"
assert_eq "false" "$(curl -s -X POST -H "Origin: $BIMP_BASE" -d "$(jq -cn --arg t "$BIMP_TOKEN" '{t: $t, repo: "/etc"}')" "$BIMP_BASE/impact/refresh" | jq -r '.ok')" \
  "impact refresh accepts only harness repos"
# computed_at은 초 단위라 다음 초로 넘어간 뒤 다시 계산해야 값이 달라진다 — 초가 바뀔 때까지만 기다린다.
for _ in $(seq 1 20); do [[ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" != "$BIMP_AT" ]] && break; sleep 0.1; done
assert_eq "true" "$(curl -s -X POST -H "Origin: $BIMP_BASE" -d "$BIMP_BODY" "$BIMP_BASE/impact/refresh" | jq -r '.ok')" "impact refresh queues a recompute"
for _ in $(seq 100); do
  BIMP_NOW="$(bimp_get | jq -r '.repos[] | select(.name == "app") | "\(.state) \(.computed_at)"')"
  [[ "$BIMP_NOW" == ready* && "$BIMP_NOW" != "ready $BIMP_AT" ]] && break
  sleep 0.1
done
assert_eq "3" "$(wc -l <"$BIMP_T/compare.log" | tr -d ' ')" "impact refresh runs compare again"
[[ "$(bimp_get | jq -r '.repos[] | select(.name == "app") | .computed_at')" != "$BIMP_AT" ]] || fail "impact refresh replaces today's cache"
assert_contains "$(cat "$BIMP_DATA/board/actions.jsonl")" '"action": "impact_refresh"' "impact refresh is logged"
BIMP_REPORT="$(curl -s "$BIMP_BASE/impact/report?t=$BIMP_TOKEN&repo=$(jq -rn --arg v "$BIMP_REPO" '$v | @uri')")"
assert_contains "$BIMP_REPORT" "const DATA = " "impact report renders the offline report"
assert_contains "$BIMP_REPORT" '"as_of":"2026-10-25"' "impact report reuses the kept matching up to its day"
assert_eq "404" "$(curl -s -o /dev/null -w '%{http_code}' "$BIMP_BASE/impact/report?t=$BIMP_TOKEN&repo=%2Fetc")" "impact report accepts only harness repos"
assert_eq "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BIMP_BASE/impact/report?t=wrong&repo=x")" "impact report checks the token"
assert_eq "2026-10-25" "$(jq -r '.matched_through' "$BIMP_KEEP")" "a board render does not overwrite the kept matching"
assert_eq "true" "$(bimp_sh stop | jq -r '.stopped')" "impact board stops"
assert_contains "$(<"$ROOT/scripts/board/template.html")" "판정 기준 (/harness-impact와 같음)" "impact view states the verdict rule"
assert_contains "$(<"$ROOT/scripts/board/template.html")" "다시 계산 실패" "impact view keeps showing a failed recompute next to the last result"
assert_contains "$(<"$ROOT/skills/board/SKILL.md")" "하네스 효과" "board skill documents the impact view"
pass "harness board impact view: background cache, refresh, failure reason, verdicts from impact"

finish_tests
