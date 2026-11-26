#!/usr/bin/env bash
# 회귀 테스트 — design-references: 독립 레퍼런스 확인·재촬영·보드·실행 기록, 매체별 규칙, 검색·레퍼런스 확인, 보드 확인, 규칙 문서 개요
# 실행: bash tests/run.sh design-references
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-design.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-design.sh"
DR_RULES="$ROOT/skills/design-references/references/refs-rules.json"
UX_BUILDER="$ROOT/skills/ux-writing-builder/SKILL.md"
UX_AUDIT="$ROOT/skills/ux-writing-audit/SKILL.md"

# design-references: the reference step on its own (no landing run) — the same check the landing runner uses, the same
# board, and a run record a dashboard can list. Competitors on two domains, one domain per kind, no bot check left standing.
DR_W="$TEST_TMP/dr-run"; mkdir -p "$DR_W/refs/r5"
dr() { "$ROOT/scripts/design-refs.sh" "$@" --work "$DR_W" 2>"$TEST_TMP/dr.err"; }
dr_rc() { local rc=0; dr "$@" >/dev/null || rc=$?; printf '%s' "$rc"; }
jq 'map(if .id == "R5" then .captures = ["refs/r5/w1440-00.png"] else . end)' "$TEST_TMP/lp-refs.json" >"$TEST_TMP/dr-refs.json"
cp "$TEST_TMP/dr-refs.json" "$DR_W/references.json"; cp "$TEST_TMP/lp-searches.json" "$DR_W/searches.json"; cp "$TEST_TMP/lp-slots.json" "$DR_W/component-slots.json"
printf '{"id":"r5","url":"https://rival-e.example/","status":"ok"}\n' >"$DR_W/refs/r5/capture.json"
assert_eq ok "$(dr check --mode unattended)" "a reference set gathered on its own passes the same check"
jq 'map(select(.id != "R6"))' "$TEST_TMP/dr-refs.json" >"$DR_W/references.json"
assert_eq 4 "$(dr_rc check --mode unattended)" "a single competitor is refused"
assert_contains "$(cat "$TEST_TMP/dr.err")" "competitor covers 1 site(s), needs at least 2 different domains" "the check names the missing competitor site"
jq 'map(if .id == "R6" then .url = "https://rival-e.example/pricing" | .source = "user" else . end)' "$TEST_TMP/dr-refs.json" >"$DR_W/references.json"
assert_eq 4 "$(dr_rc check --mode unattended)" "two competitors on one domain count as one"
assert_contains "$(cat "$TEST_TMP/dr.err")" "competitor covers 1 site(s)" "two pages of one competitor are one site"
jq 'map(if .id == "R3" then .url = "https://www.comp-b.example/about" else . end)' "$TEST_TMP/dr-refs.json" >"$DR_W/references.json"
assert_eq 4 "$(dr_rc check --mode unattended)" "one domain reused across kinds is refused"
assert_contains "$(cat "$TEST_TMP/dr.err")" "comp-b.example is used in component and layout (R2, R3)" "the check names the reused domain and its references"
jq 'map(if .id == "R1" then .url = "https://tone.acme.co.kr/" elif .id == "R3" then .url = "https://acme.co.kr/" else . end)' "$TEST_TMP/dr-refs.json" >"$DR_W/references.json"
assert_eq 4 "$(dr_rc check --mode unattended)" "a subdomain of the same site under a co.kr-style suffix is the same domain"
jq 'map(if .id == "R1" then .url = "https://one-app.vercel.app/" elif .id == "R3" then .url = "https://other-app.vercel.app/" else . end)' "$TEST_TMP/dr-refs.json" >"$DR_W/references.json"
assert_eq ok "$(dr check --mode unattended)" "two apps on one hosting suffix are two sites"
cp "$TEST_TMP/dr-refs.json" "$DR_W/references.json"
printf '{"id":"r5","url":"https://rival-e.example/","status":"challenge","reason":"bot check"}\n' >"$DR_W/refs/r5/capture.json"
assert_eq 4 "$(dr_rc check --mode unattended)" "a reference whose capture hit a bot check is refused"
assert_contains "$(cat "$TEST_TMP/dr.err")" "R5: refs/r5 is challenge" "the check names the reference left on a bot check"
mkdir -p "$DR_W/refs/r4"; printf '{"id":"r4","status":"failed"}\n' >"$DR_W/refs/r4/capture.json"
jq 'map(if .id == "R4" then .video = "refs/r4/rec.webm" else . end)' "$TEST_TMP/dr-refs.json" >"$DR_W/references.json"
assert_contains "$(dr_rc check --mode unattended; cat "$TEST_TMP/dr.err")" "R4: refs/r4 is failed" "a failed capture behind a recording is refused too"
cp "$TEST_TMP/dr-refs.json" "$DR_W/references.json"
printf 'not a png' >"$TEST_TMP/dr-fake.png"
assert_eq 4 "$(dr_rc retake --id r5 --shot "1440:$TEST_TMP/dr-fake.png")" "a retake needs a real PNG from the browser"
printf '\211PNG\r\n\032\n0000' >"$TEST_TMP/dr-shot.png"
dr retake --id r5 --shot "1440:$TEST_TMP/dr-shot.png" >/dev/null
assert_eq "ok|challenge|browser|refs/r5/w1440-00.png" "$(jq -r '[.status, .retaken.from, .retaken.via, .captures[0]] | join("|")' "$DR_W/refs/r5/capture.json")" "a retake replaces the capture and keeps what it replaced"
assert_eq ok "$(dr check --mode unattended)" "a retaken capture passes"
# The landing runner refuses the same set with the same message: it runs this check, not a copy of it.
DR_L="$TEST_TMP/dr-landing"; mkdir -p "$DR_L/refs/r5"
"$ROOT/scripts/landing-run.sh" init --work "$DR_L" --mode unattended >/dev/null
printf '## Tone and manner\ncalm\n' >"$DR_L/brief.md"; cp "$TEST_TMP/lp-tone.json" "$DR_L/tone.json"
"$ROOT/scripts/landing-run.sh" submit --work "$DR_L" --node brief --outcome brief_ready >/dev/null
for f in references.json searches.json component-slots.json; do cp "$DR_W/$f" "$DR_L/$f"; done
cp "$TEST_TMP/lp-agent-pick.json" "$DR_L/reference-pick.json"
printf '{"id":"r5","status":"challenge"}\n' >"$DR_L/refs/r5/capture.json"
dr_l_rc=0; "$ROOT/scripts/landing-run.sh" submit --work "$DR_L" --node references --outcome references_ready >/dev/null 2>"$TEST_TMP/dr.err" || dr_l_rc=$?
assert_eq 4 "$dr_l_rc" "the landing runner refuses a reference left on a bot check"
assert_contains "$(cat "$TEST_TMP/dr.err")" "R5: refs/r5 is challenge" "the landing runner says what design-references check says"
printf '{"id":"r5","status":"ok"}\n' >"$DR_L/refs/r5/capture.json"
assert_eq direction "$("$ROOT/scripts/landing-run.sh" submit --work "$DR_L" --node references --outcome references_ready 2>/dev/null)" "the landing runner passes the set design-references passes"
if command -v node >/dev/null 2>&1; then
  dr board --topic "AI interview practice" >/dev/null
  assert_file "$DR_W/board.html"
  DR_REC="$HARNESS_METRICS_DIR/board/references/$(dr run-id).json"
  assert_eq "$(cd "$DR_W" && pwd)|AI interview practice|ready|$(cd "$DR_W" && pwd)/references.json" \
    "$(jq -r '[.work, .topic, .status, .references] | join("|")' "$DR_REC")" "drawing the board leaves a run record with the work folder, topic, status, and references"
  dr_created="$(jq -r '.created_at' "$DR_REC")"
  assert_contains "$dr_created" "T" "the run record keeps when the board was made"
  dr board >/dev/null
  assert_eq "$dr_created|AI interview practice|1" "$(jq -r '[.created_at, .topic] | join("|")' "$DR_REC")|$(find "$HARNESS_METRICS_DIR/board/references" -name '*.json' -exec grep -l "$(cd "$DR_W" && pwd)\"" {} + | wc -l | tr -d ' ')" "drawing again updates the same record"
  if command -v curl >/dev/null 2>&1; then
    dr_port="$(free_port)"
    assert_eq "http://127.0.0.1:$dr_port/board.html" "$(dr board --port "$dr_port" --serve)" "design-references serves the board over http"
    assert_eq "true|false" "$(curl -s "http://127.0.0.1:$dr_port/pick" | jq -r '[.server, .run] | join("|")')" "a board served without a landing run is for looking; picks go through the terminal"
    assert_eq "http://127.0.0.1:$dr_port/board.html" "$(dr board --port "$dr_port" --serve)" "serving again on the same port reuses the running server"
    assert_eq 1 "$(pgrep -f "landing-board-server.mjs --work $(cd "$DR_W" && pwd) --port $dr_port" | wc -l | tr -d ' ')" "one board server per folder and port"
    pkill -f "landing-board-server.mjs --work $(cd "$DR_W" && pwd) --port $dr_port" 2>/dev/null || true
    # Harness Board가 떠 있고 레퍼런스 화면을 지원하면 따로 서버를 띄우지 않고 대시보드 주소를 낸다(#336).
    # features가 없는 이전 보드(0.73 이하)나 죽은 server.json이면 지금처럼 자체 서버를 쓴다.
    DR_FAKE="$TEST_TMP/dr-dash"; mkdir -p "$DR_FAKE" "$HARNESS_METRICS_DIR/board"
    printf 'import time\ntime.sleep(120)\n' >"$DR_FAKE/board-server.py"
    python3 "$DR_FAKE/board-server.py" & dr_fake_pid=$!
    jq -n --argjson p "$dr_fake_pid" '{port: 1, token: "x", pid: $p, url: "http://127.0.0.1:1/?t=tok", features: ["references"]}' >"$HARNESS_METRICS_DIR/board/server.json"
    dr_port2="$(free_port)"
    assert_eq "http://127.0.0.1:1/?t=tok&refs=$(dr run-id)" "$(dr board --port "$dr_port2" --serve 2>/dev/null)" "with the Harness Board up, the reference board is shown there"
    assert_eq 0 "$(pgrep -f "landing-board-server.mjs --work $(cd "$DR_W" && pwd) --port $dr_port2" | wc -l | tr -d ' ')" "no separate board server starts while the Harness Board shows it"
    assert_eq "null" "$(jq -r '.url' "$DR_REC")" "the run record keeps no tokened dashboard address"
    jq 'del(.features)' "$HARNESS_METRICS_DIR/board/server.json" >"$DR_FAKE/old.json" && mv "$DR_FAKE/old.json" "$HARNESS_METRICS_DIR/board/server.json"
    assert_eq "http://127.0.0.1:$dr_port2/board.html" "$(dr board --port "$dr_port2" --serve)" "an older board without the references view falls back to the board server"
    pkill -f "landing-board-server.mjs --work $(cd "$DR_W" && pwd) --port $dr_port2" 2>/dev/null || true
    kill "$dr_fake_pid" 2>/dev/null || true; wait "$dr_fake_pid" 2>/dev/null || true
    rm -f "$HARNESS_METRICS_DIR/board/server.json"
  fi
fi
DR_SKILL="$ROOT/skills/design-references/SKILL.md"
assert_file "$DR_SKILL"
assert_file "$ROOT/skills/design-references/agents/openai.yaml"
assert_contains "$(cat "$DR_SKILL")" "design-refs.sh check" "design-references verifies with the shared check"
assert_contains "$(cat "$DR_SKILL")" "board/references/<run-id>.json" "design-references documents the run record"
assert_contains "$(cat "$ROOT/skills/landing-page/references/direction.md")" "design-references" "landing-page's reference step follows design-references"
assert_contains "$(cat "$ROOT/README.md")" "| \`/design-references\` |" "README lists design-references"
pass "design-references standalone check, retake, board, and run record"

# 랜딩 미리보기는 landing-run.sh serve로만 띄운다. 에이전트가 즉석 서버(python3 -m http.server)를 띄우고 잊어
# 몇 주씩 수십 개가 남았다 — serve는 같은 폴더면 재사용하고, stop이 이 WORK의 서버를 끄고, 서버는 요청이 없으면 스스로 끝난다.
LS_W="$TEST_TMP/landing-serve"
mkdir -p "$LS_W/site/a/.secret" "$LS_W/site/b" "$TEST_TMP/landing-serve-outside"
printf '<title>A</title>\n' >"$LS_W/site/a/index.html"
printf 'body{}\n' >"$LS_W/site/a/s.css"
printf 'x\n' >"$LS_W/site/a/.secret/key"
printf '<title>B</title>\n' >"$LS_W/site/b/index.html"
ls_run() { "$ROOT/scripts/landing-run.sh" "$@"; }
LS_RC=0; ls_run serve --work "$LS_W" --dir ../landing-serve-outside >/dev/null 2>&1 || LS_RC=$?
assert_eq 2 "$LS_RC" "serve refuses a folder outside WORK"
LS_RC=0; ls_run serve --work "$LS_W" --candidate a >/dev/null 2>&1 || LS_RC=$?
assert_eq 4 "$LS_RC" "serve --candidate needs a landing run"
if command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  LS_URL="$(ls_run serve --work "$LS_W" --dir site/a)"
  assert_contains "$LS_URL" "http://127.0.0.1:" "serve prints the served address"
  assert_eq "<title>A</title>" "$(curl -s "$LS_URL")" "a folder serves its index.html"
  assert_eq "200 text/css" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "${LS_URL}s.css")" "files are served with their type"
  assert_eq 404 "$(curl -s -o /dev/null -w '%{http_code}' "${LS_URL}.secret/key")" "dotfiles are not served"
  assert_eq 404 "$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "${LS_URL}../b/index.html")" "nothing outside the served folder is served"
  assert_eq "$LS_URL" "$(ls_run serve --work "$LS_W" --dir site/a)" "serving the same folder again reuses the running server"
  LS_URL_B="$(ls_run serve --work "$LS_W" --dir site/b)"
  assert_eq "<title>B</title>" "$(curl -s "$LS_URL_B")" "another folder gets its own server"
  LS_ABS="$(cd "$LS_W" && pwd)"
  assert_eq 2 "$(pgrep -f "landing-serve.mjs --root $LS_ABS/" | wc -l | tr -d ' ')" "one server per folder"
  assert_contains "$(ls_run stop --work "$LS_W")" "stopped 2 server(s)" "stop stops every page server of the run"
  sleep 0.3
  assert_eq 0 "$(pgrep -f "landing-serve.mjs --root $LS_ABS/" | wc -l | tr -d ' ')" "no page server is left after stop"
  # 유휴 종료: 요청 없이 정한 시간이 지나면 미리보기·보드 서버가 스스로 끝난다(0.01분 = 0.6초).
  node "$ROOT/scripts/landing-serve.mjs" --root "$LS_W/site/a" --idle-minutes 0.01 >/dev/null 2>&1 &
  LS_PID=$!
  ls_port="$(free_port)"
  node "$ROOT/scripts/landing-board-server.mjs" --work "$LS_W" --port "$ls_port" --idle-minutes 0.01 >/dev/null 2>&1 &
  LS_BPID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$LS_PID" 2>/dev/null || kill -0 "$LS_BPID" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$LS_PID" 2>/dev/null; then kill "$LS_PID"; fail "the page server exits after its idle time"; fi
  if kill -0 "$LS_BPID" 2>/dev/null; then kill "$LS_BPID"; fail "the board server exits after its idle time"; fi
fi
LS_BOARD_SRC="$(<"$ROOT/scripts/landing-board.mjs")"
assert_contains "$LS_BOARD_SRC" "setInterval(()=>fetch('pick',{cache:'no-store'})" "an open board keeps its server alive"
LS_SKILL="$(<"$ROOT/skills/landing-page/SKILL.md")"
# shellcheck disable=SC2016  # 스킬 본문의 $WORK를 문자 그대로 찾는다
assert_contains "$LS_SKILL" 'landing-run.sh serve --work "$WORK" --candidate <id>' "the skill serves pages through the runner"
assert_contains "$LS_SKILL" 'Do not start your own server' "the skill forbids ad hoc servers"
assert_contains "$(<"$ROOT/skills/landing-page/references/verify.md")" "never start \`python3 -m http.server\`" "verify points at serve instead of an ad hoc server"
pass "landing pages are served through landing-run.sh serve, reused, stopped, and exit when idle"

# 독립 디자인 검토가 정지 캡처로는 못 보는 것을 놓쳤다: OS가 그리는 기본 select 펼침 목록, 입력칸 스타일을 물려받은 정렬,
# 목록 방향과 어긋난 더보기, 글자로 때운 아이콘·눈썹 글자·잘린 상품 사진, 디자인 시스템 파일을 불러오지도 않은 화면.
# 사용자가 나중에야 지적했다. 검토자와 채점 루브릭이 이 항목을 명시적으로 보게 한다.
DR_TEXT="$(cat agents/design-reviewer.md)"
assert_contains "$DR_TEXT" "OS가 그리는 기본 컨트롤" "design-reviewer knows native select popups are not in headless captures"
assert_contains "$DR_TEXT" "| 조작 요소 |" "design-reviewer checks control shape against its role"
assert_contains "$DR_TEXT" "목록 방향" "design-reviewer checks see-more placement against list direction"
assert_contains "$DR_TEXT" "| 만든 솜씨 (상품·서비스를 파는 화면일 때) |" "design-reviewer judges craft on product screens, not only landing pages"
assert_contains "$DR_TEXT" "| 디자인 근거 사용 |" "design-reviewer checks the screen actually loads the design system"
AUDIT_TEXT="$(cat templates/design-audit/SKILL.md)"
assert_contains "$AUDIT_TEXT" "기본 \`<select>\`" "design-audit flags native selects as render-unverifiable"
assert_contains "$AUDIT_TEXT" "공용 입력 스타일" "design-audit flags secondary controls inheriting the form field style"
assert_contains "$AUDIT_TEXT" "공용 컴포넌트 파일을 불러오지 않는다" "design-audit flags screens that skip the design system component file"
pass "design review covers native controls, control roles, see-more placement, craft, and design-system use"

# design-references 매체(#518): 웹페이지 밖의 매체(mobile-page·print·graphic)는 매체별 최소치·캡처 폭·탭 라벨을 쓴다.
# medium.json이 없으면 web-page다 — 위의 design-references·landing-run.sh 블록이 바뀌지 않고 통과하는 것이 회귀 확인이다.
MD_W="$TEST_TMP/md-run"; mkdir -p "$MD_W"
md() { "$ROOT/scripts/design-refs.sh" "$@" --work "$MD_W" 2>"$TEST_TMP/md.err"; }
md_rc() { local rc=0; md "$@" >/dev/null || rc=$?; printf '%s' "$rc"; }
cp "$TEST_TMP/lp-searches.json" "$MD_W/searches.json"; cp "$TEST_TMP/lp-slots.json" "$MD_W/component-slots.json"
jq 'map(select(.kind != "interaction" and .kind != "competitor"))' "$TEST_TMP/lp-refs.json" >"$TEST_TMP/md-print.json"
cp "$TEST_TMP/md-print.json" "$MD_W/references.json"
# 매체 값은 네 가지뿐이고, 정하면 작업 폴더의 medium.json에 남아 다음 명령이 읽는다.
assert_eq 2 "$(md_rc check --mode unattended --medium tape)" "an unknown medium is refused"
assert_not_file "$MD_W/medium.json"
assert_eq ok "$(md check --mode unattended --medium print)" "print passes without interaction or competitor references"
assert_eq '{"medium":"print"}' "$(jq -c . "$MD_W/medium.json")" "--medium is kept in the work folder's medium.json"
assert_eq ok "$(md check --mode unattended)" "the work folder's medium holds without --medium"
printf '{"medium":' >"$MD_W/medium.json"
assert_eq 2 "$(md_rc check --mode unattended)" "a broken medium.json is refused"
printf '{"medium":"tape"}\n' >"$MD_W/medium.json"
assert_eq 2 "$(md_rc check --mode unattended)" "an unknown medium in medium.json is refused"
assert_eq 4 "$(md_rc check --mode unattended --medium web-page)" "the same set is short as a web page"
assert_contains "$(cat "$TEST_TMP/md.err")" "interaction has 0" "a web page still needs an interaction reference"
assert_contains "$(cat "$TEST_TMP/md.err")" "recommend exactly one interaction" "a web page still needs a recommended interaction"
# 인쇄물의 비교작은 선택이고 행동 유도(cta)도 선택이다 — 도메인 2곳 검사도 없다. 웹페이지는 cta가 빠지면 거부한다.
jq '. + [{"id":"P1","kind":"competitor","title":"c","url":"https://rival-e.example/","source":"search","captures":["refs/p1.png"],"analysis":{"leads_with":"a","claim":"b","gap":"d"}}]' \
  "$TEST_TMP/md-print.json" >"$MD_W/references.json"
assert_eq ok "$(md check --mode unattended --medium print)" "print takes one comparison piece without a call to action"
jq 'map(if .id == "R5" then del(.analysis.cta) else . end)' "$TEST_TMP/lp-refs.json" >"$MD_W/references.json"
assert_eq 4 "$(md_rc check --mode unattended --medium web-page)" "a web page competitor without a call to action is refused"
assert_contains "$(cat "$TEST_TMP/md.err")" "competitor needs analysis" "the check names the missing analysis"
# 모바일 페이지는 대화형에서 인터랙션 2개가 필요하다.
cp "$TEST_TMP/lp-refs.json" "$MD_W/references.json"
assert_eq 4 "$(md_rc check --mode interactive --medium mobile-page)" "an interactive mobile page with one interaction is refused"
assert_contains "$(cat "$TEST_TMP/md.err")" "interaction has 1, needs at least 2" "a mobile page needs two interactions when looked at"
# rules 파일: 매체 규칙은 tone·component·layout만 1 이상, 최상위(web-page)는 지금 그대로다.
cp "$TEST_TMP/md-print.json" "$MD_W/references.json"
jq '.media.print.interactive.per_kind.tone = 0' "$DR_RULES" >"$TEST_TMP/md-rules.json"
assert_eq 2 "$(DESIGN_REFS_RULES="$TEST_TMP/md-rules.json" md_rc check --mode unattended --medium print)" "a medium rule without tone references is invalid"
assert_contains "$(cat "$TEST_TMP/md.err")" "invalid rules file" "the check says the rules file is invalid"
jq '.media.print.interactive.competitor_domains = 1' "$DR_RULES" >"$TEST_TMP/md-rules.json"
assert_eq ok "$(DESIGN_REFS_RULES="$TEST_TMP/md-rules.json" md check --mode unattended --medium print)" "a medium without competitors may ask for fewer competitor sites"
jq '.media.print.interactive.per_kind.competitor = 1' "$DR_RULES" >"$TEST_TMP/md-rules.json"
assert_eq 2 "$(DESIGN_REFS_RULES="$TEST_TMP/md-rules.json" md_rc check --mode unattended --medium print)" "a medium asking for competitors needs two competitor sites"
jq '.interactive.per_kind.interaction = 0 | .interactive.interaction_video = 0' "$DR_RULES" >"$TEST_TMP/md-rules.json"
assert_eq 2 "$(DESIGN_REFS_RULES="$TEST_TMP/md-rules.json" md_rc check --mode unattended --medium print)" "the web page rules still need interactions"
# 모음 사이트(behance·dribbble·pinterest·notefolio)의 작품은 작품 단위로 센다. 작품이 아닌 주소는 도메인 단위 그대로다.
md_urls() { jq --arg a "$1" --arg b "$2" 'map(if .id == "R1" then .url = $a elif .id == "R3" then .url = $b else . end)' "$TEST_TMP/md-print.json" >"$MD_W/references.json"; }
md_urls https://www.behance.net/gallery/111/a https://www.behance.net/gallery/222/b
assert_eq ok "$(md check --mode unattended)" "two works on behance are two sites"
md_urls https://www.behance.net/gallery/111/a https://behance.net/gallery/111/other-title
assert_eq 4 "$(md_rc check --mode unattended)" "one behance work in two kinds is refused"
assert_contains "$(cat "$TEST_TMP/md.err")" "behance.net/gallery/111 is used in" "the check names the reused work"
md_urls https://dribbble.com/shots/123-a https://dribbble.com/shots/456-b
assert_eq ok "$(md check --mode unattended)" "two dribbble shots are two sites"
md_urls https://dribbble.com/shots/123-a https://dribbble.com/shots/123
assert_contains "$(md_rc check --mode unattended; cat "$TEST_TMP/md.err")" "dribbble.com/shots/123 is used in" "one dribbble shot in two kinds is refused"
md_urls https://www.pinterest.com/pin/1/ https://pinterest.com/pin/2/
assert_eq ok "$(md check --mode unattended)" "two pins are two sites"
md_urls https://www.pinterest.com/pin/1/ https://pinterest.com/pin/1/
assert_contains "$(md_rc check --mode unattended; cat "$TEST_TMP/md.err")" "pinterest.com/pin/1 is used in" "one pin in two kinds is refused"
md_urls https://notefolio.net/someone/123 https://notefolio.net/other/456
assert_eq ok "$(md check --mode unattended)" "two notefolio works are two sites"
md_urls 'https://www.behance.net/search/projects?search=poster' 'https://www.behance.net/search/projects?search=flyer'
assert_eq 4 "$(md_rc check --mode unattended)" "a gallery search page still counts as the gallery's domain"
assert_contains "$(cat "$TEST_TMP/md.err")" "behance.net is used in" "the check names the gallery domain"
# 이미지 레퍼런스: 원본 이미지 주소(http(s))만 있어도 캡처를 대신한다.
jq 'map(if .id == "R1" or .id == "R3" then del(.captures) | .image = "https://img.example/\(.id).jpg" else . end)' "$TEST_TMP/md-print.json" >"$MD_W/references.json"
assert_eq ok "$(md check --mode unattended)" "an image reference needs no capture"
jq 'map(if .id == "R1" then .image = "file:///etc/passwd" else . end)' "$TEST_TMP/md-print.json" >"$MD_W/references.json"
assert_eq 4 "$(md_rc check --mode unattended)" "an image that is not an http(s) URL is refused"
assert_contains "$(cat "$TEST_TMP/md.err")" "image must be an http(s) URL" "the check names the bad image"
jq 'map(if .id == "R4" then del(.video) | .image = "https://img.example/motion.gif" else . end)' "$TEST_TMP/lp-refs.json" >"$MD_W/references.json"
assert_eq ok "$(md check --mode unattended --medium web-page)" "an image stands in for an interaction capture"
# capture: 호출 인자는 그대로고 매체만 medium.json에 남는다. 기본 폭은 매체를 따르고, 항목의 widths가 이긴다.
printf '[{"id":"a","url":"https://a.example/"},{"id":"b","url":"https://b.example/","widths":[800],"record":true}]\n' >"$MD_W/refs-to-capture.json"
assert_eq "--work $(cd "$MD_W" && pwd) --file $(cd "$MD_W" && pwd)/refs-to-capture.json --phase all" \
  "$(LANDING_CAPTURE_REFS_CMD="echo" md capture --medium mobile-page --file "$MD_W/refs-to-capture.json")" "capture passes the same arguments with a medium"
assert_eq '{"medium":"mobile-page"}' "$(jq -c . "$MD_W/medium.json")" "capture --medium keeps the medium"
if command -v node >/dev/null 2>&1; then
  MD_C="$TEST_TMP/md-capture"; mkdir -p "$MD_C"
  md_plan() { node "$ROOT/scripts/landing-capture-refs.mjs" --work "$MD_C" --file "$MD_W/refs-to-capture.json" --dry-run; }
  assert_eq '[1440,390]|[800]' "$(md_plan | jq -r '[(.[0].widths | tojson), (.[1].widths | tojson)] | join("|")')" "a web page is captured at 1440 and 390 by default"
  assert_not_file "$MD_C/refs/capture-refs.json"
  printf '{"medium":"mobile-page"}\n' >"$MD_C/medium.json"
  assert_eq '[390]|{"width":390,"height":844}' "$(md_plan | jq -r '[(.[0].widths | tojson), (.[1].record | tojson)] | join("|")')" "a mobile page is captured and recorded at phone width"
  printf '{"medium":"print"}\n' >"$MD_C/medium.json"
  assert_eq '[1440]|{"width":1440,"height":900}' "$(md_plan | jq -r '[(.[0].widths | tojson), (.[1].record | tojson)] | join("|")')" "print is captured at 1440"
  printf '{"medium":"graphic"}\n' >"$MD_C/medium.json"
  assert_eq '[1440]' "$(md_plan | jq -c '.[0].widths')" "graphic is captured at 1440"
  # 보드: print는 매체 라벨, 인터랙션 탭 없음, 레이아웃 대표만. 이미지 레퍼런스는 원본 이미지로 싣는다.
  jq 'map(if .id == "R3" then .image = "https://img.example/a.jpg" else . end)' "$TEST_TMP/md-print.json" \
    | jq '. + [{"id":"P1","kind":"competitor","title":"c","url":"https://rival-e.example/","source":"search","captures":["refs/p1.png"],"analysis":{"leads_with":"a","claim":"b","gap":"d"}}]' >"$MD_W/references.json"
  cp "$TEST_TMP/lp-tone.json" "$MD_W/tone.json"
  md board --medium print >/dev/null
  MD_HTML="$(cat "$MD_W/board.html")"
  for md_s in "판면 구성" "비교작 분석" "전하는 메시지" "레이아웃 대표를 ★로 골라 주세요" '<img src="https://img.example/a.jpg"'; do
    assert_contains "$MD_HTML" "$md_s" "a print board shows $md_s"
  done
  case "$MD_HTML" in *'data-tab="interaction"'*) fail "a print board without interaction references has no interaction tab" ;; esac
  case "$MD_HTML" in *"<dt>행동 유도"*) fail "a print board leaves out an empty call to action" ;; esac
  MD_D="$TEST_TMP/md-default"; mkdir -p "$MD_D"
  cp "$TEST_TMP/lp-refs.json" "$MD_D/references.json"; cp "$TEST_TMP/lp-slots.json" "$MD_D/component-slots.json"
  "$ROOT/scripts/design-refs.sh" board --work "$MD_D" >/dev/null 2>&1
  MD_HTML="$(cat "$MD_D/board.html")"
  for md_s in "경쟁사 분석" "첫 화면에서 내세우는 것" "레이아웃·인터랙션 대표를 ★로 골라 주세요" 'data-tab="interaction"'; do
    assert_contains "$MD_HTML" "$md_s" "a board without a medium still shows $md_s"
  done
  assert_not_file "$MD_D/medium.json"
fi
MD_SKILL="$(cat "$ROOT/skills/design-references/SKILL.md")"
for md_s in mobile-page print graphic --medium "\`image\`" behance media.json; do
  assert_contains "$MD_SKILL" "$md_s" "design-references documents $md_s"
done
assert_contains "$(sed -n '3p' "$ROOT/skills/design-references/SKILL.md")" "print" "the description reaches print requests"
assert_contains "$(sed -n '3p' "$ROOT/skills/design-references/SKILL.md")" "mobile" "the description reaches mobile pages"
pass "design-references media: per-medium minimums, capture widths, tab labels, image references, and gallery works (#518)"

# 디자인 규칙 문서의 `## 레이아웃`이 여백 관계(요소 안·그룹 안 항목 사이·그룹 사이·구획 사이)와 묶기(여백·구획선·면·접기)를
# 하위 절로 갖게 한다. 불변식은 플러그인이, 관계별 단계·사다리·정렬은 프로젝트가 정한다. 필수 절 13개는 그대로다. (#514)
SR_TOKENS="$(<"$ROOT/skills/design-system-builder/references/tokens.md")"
assert_contains "$SR_TOKENS" "## Spacing relationships" "tokens.md has a spacing relationships section"
SR_DENSITY_LINE="$(grep -n '^## Spacing and density' "$ROOT/skills/design-system-builder/references/tokens.md" | cut -d: -f1)"
SR_REL_LINE="$(grep -n '^## Spacing relationships' "$ROOT/skills/design-system-builder/references/tokens.md" | cut -d: -f1)"
[ -n "$SR_DENSITY_LINE" ] && [ -n "$SR_REL_LINE" ] && [ "$SR_REL_LINE" -gt "$SR_DENSITY_LINE" ] \
  || fail "Spacing relationships must follow Spacing and density in tokens.md (density=$SR_DENSITY_LINE relationships=$SR_REL_LINE)"
for phrase in "Fixed invariants" "Project decisions" "inner spacing is always smaller than outer spacing" "one boundary" "group the measured gaps by relationship"; do
  assert_contains "$SR_TOKENS" "$phrase" "tokens.md spacing relationships: $phrase"
done
assert_contains "$(<"$ROOT/skills/design-system-builder/references/extract.md")" "Spacing relationships" "extract.md points axis A at the spacing relationships procedure"
SR_OUT="$(<"$ROOT/skills/design-system-builder/references/output-format.md")"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for phrase in '`### 여백 관계`' '`### 묶기`' '요소 안' '그룹 안 항목 사이' '그룹 사이' '구획 사이' 'propose adding' '| `## 레이아웃` |'; do
  assert_contains "$SR_OUT" "$phrase" "output-format.md layout subsections: $phrase"
done
assert_eq '### 여백 관계|### 묶기|' "$(awk '/^## 레이아웃/{f=1;next} /^## /{f=0} f && /^### /' "$ROOT/docs/design-system.md" | tr '\n' '|')" "docs/design-system.md layout has spacing and grouping subsections in order"
SR_DOC_SPACING="$(awk '/^### 여백 관계/{f=1;next} /^##/{f=0} f' "$ROOT/docs/design-system.md")"
for tok in --space-1 --space-2 --space-3 --space-5 --space-12; do
  assert_contains "$SR_DOC_SPACING" "$tok" "docs/design-system.md spacing relationships names $tok"
done
case "$SR_DOC_SPACING" in
  *--space-4*) fail "docs/design-system.md spacing relationships must not name --space-4 (the layout uses --space-3 and --space-5)" ;;
esac
# 문서 여백 값과 components.css를 잇는 검사가 없어 둘이 표류했다(#524). CSS에서 뽑은 값을 문서가 그대로 말해야 한다.
SR_CSS="$ROOT/docs/design-system/components.css"
SR_MAIN_X="$(sed -n 's/^\.ds-main {.*padding: var(--space-[0-9]*) var(\(--space-[0-9]*\)).*/\1/p' "$SR_CSS" | head -n1)"
SR_NARROW_X="$(sed -n 's/^  \.ds-main {.*padding: var(--space-[0-9]*) var(\(--space-[0-9]*\)).*/\1/p' "$SR_CSS" | head -n1)"
SR_HEAD_GAP="$(sed -n 's/^\.ds-pagehead {.*margin-bottom: var(\(--space-[0-9]*\)).*/\1/p' "$SR_CSS" | head -n1)"
SR_COLUMNS_GAP="$(sed -n 's/^\.ds-columns {.*gap: var(\(--space-[0-9]*\)).*/\1/p' "$SR_CSS" | head -n1)"
SR_SPLIT_GAP="$(sed -n 's/^\.ds-split {.*gap: var(\(--space-[0-9]*\)).*/\1/p' "$SR_CSS" | head -n1)"
SR_STACK_GAP="$(sed -n 's/^\.ds-stack {.*gap: var(\(--space-[0-9]*\)).*/\1/p' "$SR_CSS" | head -n1)"
for sr_pair in "main padding x:$SR_MAIN_X" "narrow main padding x:$SR_NARROW_X" "pagehead margin-bottom:$SR_HEAD_GAP" \
  "columns gap:$SR_COLUMNS_GAP" "split gap:$SR_SPLIT_GAP" "stack gap:$SR_STACK_GAP"; do
  [ -n "${sr_pair#*:}" ] || fail "components.css spacing extraction is empty: ${sr_pair%%:*}"
done
assert_eq "$SR_COLUMNS_GAP" "$SR_SPLIT_GAP" "components.css .ds-columns and .ds-split share one gap"
SR_DOC_BONE="$(grep '^공통 뼈대:' "$ROOT/docs/design-system.md")"
SR_DOC_LIST="$(grep -F -- '- **목록**' "$ROOT/docs/design-system.md")"
SR_DOC_ROW_IN="$(printf '%s\n' "$SR_DOC_SPACING" | grep -F -- '| 그룹 안 항목 사이 |' | head -n1)"
SR_DOC_ROW_BETWEEN="$(printf '%s\n' "$SR_DOC_SPACING" | grep -F -- '| 그룹 사이 |' | head -n1)"
assert_contains "$SR_DOC_BONE" "(\`$SR_MAIN_X\`," "docs/design-system.md layout skeleton names the .ds-main horizontal padding ($SR_MAIN_X)"
assert_contains "$SR_DOC_BONE" "좁은 폭에서 \`$SR_NARROW_X\`" "docs/design-system.md layout skeleton names the narrow-width padding ($SR_NARROW_X)"
assert_contains "$SR_DOC_BONE" "아래 \`$SR_HEAD_GAP\`" "docs/design-system.md layout skeleton names the page head gap ($SR_HEAD_GAP)"
assert_contains "$SR_DOC_LIST" "항목 사이 \`$SR_STACK_GAP\`" "docs/design-system.md list layout names the .ds-stack gap ($SR_STACK_GAP)"
assert_contains "$SR_DOC_LIST" "열 사이 \`$SR_COLUMNS_GAP\`" "docs/design-system.md list layout names the .ds-columns gap ($SR_COLUMNS_GAP)"
assert_contains "$SR_DOC_ROW_IN" "\`$SR_STACK_GAP\`" "docs/design-system.md spacing table row for items within a group matches .ds-stack ($SR_STACK_GAP)"
assert_contains "$SR_DOC_ROW_BETWEEN" "\`$SR_COLUMNS_GAP\`" "docs/design-system.md spacing table row between groups matches .ds-columns ($SR_COLUMNS_GAP)"
SR_DOC_GROUP="$(awk '/^### 묶기/{f=1;next} /^##/{f=0} f' "$ROOT/docs/design-system.md")"
for tok in --color-border --color-surface --color-surface-sunken .ds-num; do
  assert_contains "$SR_DOC_GROUP" "$tok" "docs/design-system.md grouping names $tok"
done
pass "design rule documents carry spacing relationships and grouping under the layout section, and their spacing steps match components.css (#524)"

# 디자인 규칙 문서 `## 원칙` 첫머리에 `### 서비스`(사용자와 상황·핵심 일·성격·피할 것·근거)를 둔다. 서비스 성격이 문서에
# 없어 디자인 Skill마다 다시 묻거나 화면마다 톤이 갈렸다. builder가 기록하고 design-screen·landing-page·design-polish·
# design-reviewer가 근거로 읽는다. `###`라서 필수 13절의 이름과 순서는 그대로다. (#514)
SV_OUT_FILE="$ROOT/skills/design-system-builder/references/output-format.md"
SV_OUT="$(<"$SV_OUT_FILE")"
# shellcheck disable=SC2016  # 표의 백틱을 문자 그대로 찾는다
assert_eq "## 메타|## 원칙|## 레이아웃|## 색과 상태|## 타이포그래피|## 컴포넌트|## 형제 목록|## 문구|## 모션|## 접근성|## 반응형|## 토큰 변경 규칙|## 결정 기록|" \
  "$(grep -E '^\| [0-9]+ \| `## ' "$SV_OUT_FILE" | sed -E 's/^\| [0-9]+ \| `([^`]+)`.*/\1/' | tr '\n' '|')" "output-format.md keeps the 13 required sections in order"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for phrase in '### `### 서비스`' '`사용자와 상황`' '`핵심 일`' '`성격`' '`피할 것`' '`근거`' 'A보다 B' 'a reviewer could call violated' \
  '원본: <경로>' '문구 규칙 미분리' 'propose reducing `## 문구` to the pointer form'; do
  assert_contains "$SV_OUT" "$phrase" "output-format.md service and copy contract: $phrase"
done
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
assert_contains "$(grep '^| 2 | `## 원칙` |' "$SV_OUT_FILE")" '### 서비스' "output-format.md principles row names the service subsection"
SV_DSB="$(<"$ROOT/skills/design-system-builder/SKILL.md")"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for phrase in '`### 서비스`' 'answers to questions 1 and 5' 'draft' '문구 규칙도 같이 만들까요?' '`ux-writing-builder`' 'do not reimplement' \
  'Voice default' '문구 규칙 미분리' 'detection rule in `ux-writing-audit`'; do
  assert_contains "$SV_DSB" "$phrase" "design-system-builder service and copy: $phrase"
done
SV_UWB="$(<"$UX_BUILDER")"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for phrase in 'design rule document'"'"'s `## 문구`' 'propose turning the design rule document'"'"'s `## 문구` into the pointer form' \
  'Voice default' 'detection rule in `ux-writing-audit`'; do
  assert_contains "$SV_UWB" "$phrase" "ux-writing-builder copy source: $phrase"
done
# 문구 규칙 문서 감지 순서는 ux-writing-audit 한 곳에만 적고, 저장소 기준(개인 설정 아님)이다. (#516)
assert_contains "$(<"$UX_AUDIT")" "from the repository, never from personal settings" "ux-writing-audit detects the rule document from the repository"
SV_ORDER_FILES="$(grep -rlF -e 'name another path' -e 'name another location' "$ROOT/skills" "$ROOT/templates" "$ROOT/agents" | sed "s#^$ROOT/##" | sort | tr '\n' '|')"
assert_eq "skills/ux-writing-audit/SKILL.md|" "$SV_ORDER_FILES" "only ux-writing-audit spells out the rule document detection order"
SV_SCREEN="$(<"$ROOT/skills/design-screen/SKILL.md")"
SV_LANDING="$(cat "$ROOT/skills/landing-page/SKILL.md" "$ROOT/skills/landing-page/references/direction.md")"
for SV_TEXT_NAME in design-screen landing-page; do
  if [ "$SV_TEXT_NAME" = design-screen ]; then SV_TEXT="$SV_SCREEN"; else SV_TEXT="$SV_LANDING"; fi
  # shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
  for phrase in '`### 서비스`' 'do not ask again' 'propose adding it to `### 서비스`' 'detection rule in `ux-writing-audit`' 'before writing copy'; do
    assert_contains "$SV_TEXT" "$phrase" "$SV_TEXT_NAME service and copy: $phrase"
  done
done
assert_contains "$SV_SCREEN" ".ai-harness/docs/ux-writing.md" "design-screen keeps the default UX writing path"
assert_contains "$(awk '/^3\. \*\*Critique independently/{f=1} f&&/^4\. /{exit} f' "$ROOT/skills/design-polish/SKILL.md")" "### 서비스" "design-polish critique hands over the service section"
assert_contains "$(awk '/^## 입력/{f=1;next} /^## /{f=0} f' "$ROOT/agents/design-reviewer.md")" "### 서비스" "design-reviewer reads the service section as evidence"
# 이 저장소의 규칙 문서도 `## 원칙`이 `### 서비스`로 시작한다. ux-writing.md가 없으므로 `## 문구`는 가리키기 형태가 아니다.
SV_DOC="$ROOT/docs/design-system.md"
assert_eq "### 서비스" "$(awk '/^## 원칙/{f=1;next} /^## /{f=0} f && /^### /' "$SV_DOC" | head -1)" "docs/design-system.md principles open with the service subsection"
SV_DOC_SERVICE="$(awk '/^### 서비스/{f=1;next} /^##/{f=0} f' "$SV_DOC")"
for phrase in 사용자와\ 상황 핵심\ 일 성격 피할\ 것 근거 보다; do
  assert_contains "$SV_DOC_SERVICE" "$phrase" "docs/design-system.md service subsection: $phrase"
done
[[ "$(awk '/^## 문구/{f=1;next} /^## /{f=0} f' "$SV_DOC")" != *"원본:"* ]] || fail "docs/design-system.md copy section stays full without ux-writing.md"
pass "design rule documents open principles with a service section and copy rules have one source"

# design-references 검사 틈(#529) (1): 검색 근거는 사용자가 직접 준 경쟁사(source user·direct)를 면제하고, 나머지는 도메인으로 맞춘다.
# 같은 도메인의 다른 경로·www. 서브도메인은 같은 사이트다. 검색에 없는 search 경쟁사는 여전히 거부한다.
RG_W="$TEST_TMP/rg-run"; mkdir -p "$RG_W"
rg() { "$ROOT/scripts/design-refs.sh" "$@" --work "$RG_W" 2>"$TEST_TMP/rg.err"; }
rg_rc() { local rc=0; rg "$@" >/dev/null || rc=$?; printf '%s' "$rc"; }
cp "$TEST_TMP/lp-slots.json" "$RG_W/component-slots.json"
rg_refs() { jq "$1" "${2:-$TEST_TMP/lp-refs.json}" >"$RG_W/references.json"; } # jq 필터 [입력] → references.json
rg_found() { jq -n --argjson r "$1" '[{"query":"q1","purpose":"category","engine_or_gallery":"web search","results":$r,"picked":[]},{"query":"q2","purpose":"gallery","engine_or_gallery":"codrops hub","results":["https://motion-d.example/"],"picked":["R4"]}]' >"$RG_W/searches.json"; } # 카테고리 검색 결과 목록
rg_refs '.'; rg_found '["https://rival-e.example/","https://rival-f.example/pricing"]'
assert_eq ok "$(rg check --mode unattended)" "the top-up fixture passes the check"
rg_found '["https://rival-f.example/pricing","https://z.example/"]'
rg_refs 'map(if .id == "R5" then .source = "direct" else . end)'
assert_eq ok "$(rg check --mode unattended)" "a competitor the user gave directly needs no search result"
rg_found '["https://rival-e.example/pricing","https://rival-f.example/pricing"]'
rg_refs '.'
assert_eq ok "$(rg check --mode unattended)" "a competitor's root page matches a result on another path of the same domain"
rg_found '["https://www.rival-e.example/features","https://rival-f.example/pricing"]'
assert_eq ok "$(rg check --mode unattended)" "a www. result matches the competitor on the bare domain"
rg_found '["https://z.example/","https://rival-f.example/pricing"]'
assert_eq 4 "$(rg_rc check --mode unattended)" "a search competitor whose domain is not among the results is refused"
assert_contains "$(cat "$TEST_TMP/rg.err")" "R5: competitor https://rival-e.example/ is not among the search results" "the check names the competitor missing from the searches"
rg_found '["https://rival-e.example/","https://rival-f.example/pricing"]'
pass "design-references search check: direct competitors exempt, same-domain matches, search competitors still need results (#529)"

# design-references 검사 틈(#529) (2): 보드가 쓰는 필드(title·url·source·take 계열·tone_part·캡처)가 비면 거부하고, 메시지는 "<id>: <field> is required"다.
# 캡처 폭은 매체의 layout 규칙(media.json)을 따른다. 경쟁사는 take 계열이 없어도 된다.
rg_missing() { # <jq 필터> <기대 메시지> <설명> [매체] [입력 파일]
  local f="$1" msg="$2" what="$3" medium="${4:-}" src="${5:-$TEST_TMP/lp-refs.json}"
  rg_refs "$f" "$src"
  if [[ -n "$medium" ]]; then
    assert_eq 4 "$(rg_rc check --mode unattended --medium "$medium")" "$what"
  else
    assert_eq 4 "$(rg_rc check --mode unattended)" "$what"
  fi
  assert_contains "$(cat "$TEST_TMP/rg.err")" "$msg" "$what: message"
}
rg_ok() { # <jq 필터> <설명> [매체] [입력 파일]
  rg_refs "$1" "${4:-$TEST_TMP/lp-refs.json}"
  assert_eq ok "$(rg check --mode unattended --medium "${3:-web-page}")" "$2"
}
for rg_f in keep_strength must_not_shrink_to take title tone_part url source; do
  rg_missing "map(if .id == \"R1\" then del(.$rg_f) else . end)" "R1: $rg_f is required" "a tone reference without $rg_f is refused"
done
rg_missing 'map(if .id == "R1" then .keep_strength = "" else . end)' "R1: keep_strength is required" "an empty string counts as missing"
rg_missing 'map(if .id == "R1" then .take = 5 else . end)' "R1: take is required" "a non-string counts as missing"
rg_missing 'map(if .id == "R2" then del(.must_not_shrink_to) else . end)' "R2: must_not_shrink_to is required" "a component without must_not_shrink_to is refused"
rg_missing 'map(if .id == "R2" then del(.captures) else . end)' "R2: captures or image is required" "a component without captures or image is refused"
rg_missing 'map(if .id == "R1" then del(.captures) else . end)' "R1: captures or image is required" "a tone reference without captures or image is refused"
rg_missing 'map(if .id == "R5" then del(.captures) else . end)' "R5: captures or image is required" "a competitor without captures or image is refused"
rg_missing 'map(if .id == "R5" then del(.title) else . end)' "R5: title is required" "a competitor without a title is refused"
rg_missing 'map(if .id == "R3" then .captures = ["refs/r3/w1440-00.png"] else . end)' "R3: captures at w390 are required for a web-page layout" "a web page layout captured only at 1440 is refused"
rg_missing 'map(if .id == "R3" then del(.captures) | .image = "https://img.example/r3.jpg" else . end)' "R3: captures at w1440" "an image alone does not stand in for a web page layout's captures"
rg_missing 'map(if .id == "R3" then .captures = ["refs/r3/w1440-00.png", "refs/r3/w390-00.png.bak"] else . end)' "captures at w390 are required" "a capture name must match w<width>-<n>.png"
rg_ok 'map(if .id == "R5" then del(.take) else . end)' "a competitor needs no take"
rg_ok 'map(if .id == "R3" then .captures = ["refs/r3/w390-00.png"] else . end)' "a mobile page layout needs only the 390 capture" mobile-page
rg_missing 'map(if .id == "R3" then .captures = ["refs/r3/w1440-00.png"] else . end)' "R3: captures at w390 are required for a mobile-page layout" "a mobile page layout without the 390 capture is refused" mobile-page
for rg_m in print graphic; do
  rg_ok 'map(if .id == "R3" then del(.captures) | .image = "https://img.example/r3.jpg" else . end)' "a $rg_m layout may be an image alone" "$rg_m" "$TEST_TMP/md-print.json"
  rg_ok 'map(if .id == "R3" then .captures = ["refs/r3/page-00.png"] else . end)' "a $rg_m layout may be a single capture" "$rg_m" "$TEST_TMP/md-print.json"
  rg_missing 'map(if .id == "R3" then del(.captures) else . end)' "R3: captures or image is required" "a $rg_m layout without captures or image is refused" "$rg_m" "$TEST_TMP/md-print.json"
done
rg_refs '.'
rm -f "$RG_W/medium.json"
pass "design-references reference check: required fields, per-medium layout captures, competitor take optional (#529)"

# design-references 검사 틈(#529): media.json이 매체별 layout 규칙(캡처 폭·이미지 대체 가능 여부)의 단일 출처다.
RG_MEDIA="$ROOT/skills/design-references/references/media.json"
for rg_m in web-page:1440,390:false mobile-page:390:false print::true graphic::true; do
  rg_name="${rg_m%%:*}"; rg_rest="${rg_m#*:}"; rg_w="${rg_rest%%:*}"; rg_img="${rg_rest#*:}"
  assert_eq "$rg_w|$rg_img" "$(jq -r --arg m "$rg_name" '.media[$m].layout | [(.widths | map(tostring) | join(",")), (.image | tostring)] | join("|")' "$RG_MEDIA")" "media.json gives $rg_name a layout rule"
done
pass "media.json carries a layout capture rule per medium (#529)"

# design-references 검사 틈(#529) (3): 보드를 실제 브라우저로 열어 탭마다 이미지·영상이 뜨는지 본다(landing-board-check.mjs).
# 브라우저가 없으면 unverified로 끝나고 건너뛴다.
if command -v node >/dev/null 2>&1; then
  BC_W="$TEST_TMP/bc-work"; BC_O="$TEST_TMP/bc-out"; mkdir -p "$BC_W/refs/r3" "$BC_W/refs/r5"
  printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d >"$TEST_TMP/bc-1x1.png"
  for bc_f in r1 r2 r4 r6 r3/w1440-00 r3/w390-00; do mkdir -p "$BC_W/refs/$(dirname "$bc_f")"; cp "$TEST_TMP/bc-1x1.png" "$BC_W/refs/$bc_f.png"; done
  cp "$TEST_TMP/bc-1x1.png" "$BC_W/refs/r5.png"
  jq 'map(if .id == "R4" then del(.video) | .captures = ["refs/r4.png"] else . end)' "$TEST_TMP/lp-refs.json" >"$BC_W/references.json"
  cp "$TEST_TMP/lp-slots.json" "$BC_W/component-slots.json"; cp "$TEST_TMP/lp-tone.json" "$BC_W/tone.json"
  node "$ROOT/scripts/landing-board.mjs" --work "$BC_W" --kind references >/dev/null
  assert_file "$BC_W/board.html"
  bc_rc=0; node "$ROOT/scripts/landing-board-check.mjs" --work "$BC_W" --out "$BC_O" >"$TEST_TMP/bc.out" 2>"$TEST_TMP/bc.err" || bc_rc=$?
  if [[ "$(jq -r '.result' "$BC_O/board-check.json" 2>/dev/null)" == unverified ]]; then
    printf '# skip landing-board-check browser checks: %s\n' "$(jq -r '.reason' "$BC_O/board-check.json")"
  else
    assert_eq 0 "$bc_rc" "a board whose images all load passes the board check"
    assert_eq pass "$(jq -r '.result' "$BC_O/board-check.json")" "board-check.json says pass"
    assert_eq pass "$(jq -r '.result' "$TEST_TMP/bc.out")" "stdout says pass"
    assert_eq "tone component layout interaction competitor" "$(jq -r '[.tabs[].tab] | join(" ")' "$BC_O/board-check.json")" "every tab is checked"
    assert_file "$BC_O/tab-layout.png"
    rm -f "$BC_W/refs/r3/w390-00.png"
    bc_rc=0; node "$ROOT/scripts/landing-board-check.mjs" --work "$BC_W" --out "$BC_O" >"$TEST_TMP/bc.out" 2>"$TEST_TMP/bc.err" || bc_rc=$?
    assert_eq 4 "$bc_rc" "a missing image fails the board check"
    assert_eq fail "$(jq -r '.result' "$BC_O/board-check.json")" "board-check.json says fail"
    assert_eq "layout" "$(jq -r '[.tabs[] | select((.failed | length) > 0) | .tab] | join(",")' "$BC_O/board-check.json")" "only the tab with the missing image fails"
    assert_contains "$(jq -r '[.tabs[].failed[].src] | join(" ")' "$BC_O/board-check.json")" "w390-00.png" "the failure names the missing image"
    assert_eq 1 "$(jq -r '.failed' "$TEST_TMP/bc.out")" "stdout counts the failed items"
    cp "$TEST_TMP/bc-1x1.png" "$BC_W/refs/r3/w390-00.png"
    jq 'map(if .id == "R4" then .video = "refs/missing.mp4" else . end)' "$BC_W/references.json" >"$BC_W/references.tmp" && mv "$BC_W/references.tmp" "$BC_W/references.json"
    node "$ROOT/scripts/landing-board.mjs" --work "$BC_W" --kind references >/dev/null
    bc_rc=0; node "$ROOT/scripts/landing-board-check.mjs" --work "$BC_W" --out "$BC_O" >"$TEST_TMP/bc.out" 2>"$TEST_TMP/bc.err" || bc_rc=$?
    assert_eq 4 "$bc_rc" "a video that does not load fails the board check"
    assert_eq video "$(jq -r '[.tabs[] | select(.tab == "interaction") | .failed[].tag] | join(",")' "$BC_O/board-check.json")" "the failed item is the video"
    assert_contains "$(jq -r '[.tabs[].failed[].src] | join(" ")' "$BC_O/board-check.json")" "missing.mp4" "the failure names the missing video"
  fi
  bc_rc=0; node "$ROOT/scripts/landing-board-check.mjs" --out "$BC_O" >/dev/null 2>&1 || bc_rc=$?
  assert_eq 2 "$bc_rc" "the board check without --work or --url is a usage error"
fi
pass "board check opens every tab and fails on an image or video that does not load (#529)"

MD_SKILL="$(cat "$ROOT/skills/design-references/SKILL.md")"
assert_contains "$MD_SKILL" 'source: "direct"' "design-references documents the direct source"
assert_contains "$MD_SKILL" "landing-board-check.mjs" "design-references documents the board check"
pass "design-references skill names the direct source and the board check (#529)"

# design-audit 축 E 우선순위(#533): UX 라이팅 규칙 문서가 있으면 카탈로그에서도 용어는 ux-writing-audit로 넘기고,
# `## 문구`가 없어도 절 없음으로 감점하지 않고 정직성과 `### 서비스` 톤 일관성으로 잰다.
# design-system-builder의 문구 규칙 질문은 라운드당 세 질문 상한 안에 든다.
EP_AUDIT_FILE="$ROOT/templates/design-audit/SKILL.md"
EP_AUDIT="$(<"$EP_AUDIT_FILE")"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for phrase in '카탈로그에서도 용어는 감점하지 않고 `ux-writing-audit`로 넘긴다' 'UX 라이팅 규칙 문서는 있고 `## 문구`가 없으면' \
  'E는 정직성과 `### 서비스` 톤 일관성으로 잰다'; do
  assert_contains "$EP_AUDIT" "$phrase" "design-audit axis E precedence: $phrase"
done
for EP_COPY in skills/design-screen/references/design-audit.md .claude/skills/design-audit/SKILL.md .agents/skills/design-audit/SKILL.md; do
  cmp -s "$ROOT/$EP_COPY" "$EP_AUDIT_FILE" || fail "$EP_COPY must match templates/design-audit/SKILL.md byte for byte"
done
assert_contains "$(<"$ROOT/skills/design-system-builder/SKILL.md")" "inside the three-question limit of a round" "design-system-builder asks the copy rule question inside the round limit"
pass "design-audit axis E precedence with a UX writing rule document and the copy rule question limit (#533)"

# output-format.md 기본 경로가 SKILL.md 대체 체인과 정합한다 (#627, AC-8).
DR_OF="$(<"$ROOT/skills/design-system-builder/references/output-format.md")"
assert_contains "$DR_OF" "docs/design-system.md" "output-format.md still names the default path docs/design-system.md"
assert_contains "$DR_OF" "SKILL.md § 1" "output-format.md points to the SKILL.md destination resolution as the single source"
pass "output-format.md default path aligns with the destination resolution fallback chain (#627)"


finish_tests
