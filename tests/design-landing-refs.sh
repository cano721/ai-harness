#!/usr/bin/env bash
# 회귀 테스트 — landing-page 그래프 러너 — 그래프 계약, 브리프·레퍼런스 거부 조건, 레퍼런스 보드·서버, 무인 레퍼런스 선택
# 실행: bash tests/run.sh design-landing-refs
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-design.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-design.sh"
# shellcheck source=tests/lib-design-run.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-design-run.sh"
"$ROOT/scripts/validate-landing-page-graph.sh" "$LP_GRAPH" >/dev/null || fail "the shipped landing-page graph is valid"
jq '.transitions += [{"from":"direction","to":"build","when":"mockup_decides"}]' "$LP_GRAPH" >"$TEST_TMP/lp-bad-graph.json"
if "$ROOT/scripts/validate-landing-page-graph.sh" "$TEST_TMP/lp-bad-graph.json" >/dev/null 2>&1; then fail "a landing-page graph that builds without a preview is invalid"; fi
jq '.transitions += [{"from":"repair","to":"done","when":"repaired"}]' "$LP_GRAPH" >"$TEST_TMP/lp-bad-graph.json"
if "$ROOT/scripts/validate-landing-page-graph.sh" "$TEST_TMP/lp-bad-graph.json" >/dev/null 2>&1; then fail "a landing-page graph that reaches done from repair is invalid"; fi
jq '.nodes.measure.actor = "maker"' "$LP_GRAPH" >"$TEST_TMP/lp-bad-graph.json"
if "$ROOT/scripts/validate-landing-page-graph.sh" "$TEST_TMP/lp-bad-graph.json" >/dev/null 2>&1; then fail "a landing-page graph whose measure is not the runner's is invalid"; fi
LP_W="$TEST_TMP/lp-run"; mkdir -p "$LP_W"
lp init --mode unattended >/dev/null
assert_eq 4 "$(lp_rc submit --node brief --outcome brief_ready)" "landing-run refuses a node whose artifacts are missing"
touch -t 202001010000 "$LP_W/brief.md"
assert_eq 4 "$(lp_rc submit --node brief --outcome brief_ready)" "landing-run refuses artifacts made before the node started"
touch "$LP_W/brief.md"
cat >"$LP_W/tone.json" <<'EOF'
{"mood":["calm","precise","warm"],"avoid":"a test, a hype campaign","palette":[{"name":"Ink","hex":"#18191b","role":"text"},{"name":"Brand","hex":"#3366ff","role":"primary action"}],
 "type":{"display":"Sans 800","body":"Sans 400","display_sample":"Practice first","body_sample":"Answer one question."},"voice":"Calm and plain.","imagery":"product UI"}
EOF
assert_eq 4 "$(lp_rc submit --node brief --outcome brief_ready)" "a brief without its tone and manner is refused"
printf '## Tone and manner\ncalm, precise\n' >"$LP_W/brief.md"
jq '.mood = ["calm"] | .palette[0].hex = "dark"' "$TEST_TMP/lp-tone.json" >"$LP_W/tone.json"
assert_eq 4 "$(lp_rc submit --node brief --outcome brief_ready)" "a tone.json without three mood words and hex colors is refused"
assert_contains "$(cat "$TEST_TMP/lp.err")" "mood needs exactly three words" "the runner says what tone.json lacks"
cp "$TEST_TMP/lp-tone.json" "$LP_W/tone.json"
assert_eq references "$(lp submit --node brief --outcome brief_ready)" "landing-run follows the declared edge"
cp "$TEST_TMP/lp-slots.json" "$LP_W/component-slots.json"; cp "$TEST_TMP/lp-searches.json" "$LP_W/searches.json"
jq '.[0].kind = "look"' "$TEST_TMP/lp-refs.json" >"$LP_W/references.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "a reference outside the five board kinds is refused"
assert_contains "$(cat "$TEST_TMP/lp.err")" "tone has 0, needs at least 1" "the runner names the board tab left empty"
jq 'del(.[4].analysis.gap)' "$TEST_TMP/lp-refs.json" >"$LP_W/references.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "a competitor without its four-part analysis is refused"
jq 'del(.[3].video)' "$TEST_TMP/lp-refs.json" >"$LP_W/references.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "an interaction reference without a recording is refused"
cp "$TEST_TMP/lp-refs.json" "$LP_W/references.json"
printf '[]\n' >"$LP_W/searches.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "references without a search are refused"
jq '[.[0]]' "$TEST_TMP/lp-searches.json" >"$LP_W/searches.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "references without a gallery search are refused"
assert_contains "$(cat "$TEST_TMP/lp.err")" "no gallery search" "the runner names the missing search"
jq '.[0].results = ["https://z.example/"]' "$TEST_TMP/lp-searches.json" >"$LP_W/searches.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "a competitor not among the search results is refused"
cp "$TEST_TMP/lp-searches.json" "$LP_W/searches.json"
if command -v node >/dev/null 2>&1; then
  lp board >/dev/null
  assert_file "$LP_W/board.html"
  for tab in tone component layout interaction competitor; do
    assert_contains "$(cat "$LP_W/board.html")" "id=\"tab-$tab\"" "the board has the $tab tab"
  done
  assert_contains "$(cat "$LP_W/board.html")" "background:#3366ff" "the board shows the palette as color chips"
  assert_contains "$(cat "$LP_W/board.html")" "no practice" "the board shows the competitor analysis"
  assert_contains "$(cat "$LP_W/board.html")" 'class="drop" type="button" aria-label="이 레퍼런스 제외" title="이 레퍼런스 제외" data-id="R1"' "each reference has an exclude button"
  assert_contains "$(cat "$LP_W/board.html")" '>되돌리기</button>' "an excluded reference can be restored"
  assert_contains "$(cat "$LP_W/board.html")" "이미 시작됐어요" "a board whose pick is made locks instead of sending again"
  if grep -q '남김\|뺌' "$LP_W/board.html"; then fail "the board no longer says keep/drop (남김·뺌)"; fi
  assert_contains "$(cat "$LP_W/board.html")" "이 레퍼런스로 시작" "the board has a start button"
  assert_contains "$(cat "$LP_W/board.html")" "요약을 복사해 세션에 붙여 주세요" "a statically served board asks for the answer in the session"
  # 보기 전용 보드는 "이 레퍼런스로 시작"을 안내하지 않고, 의견 칸은 펼칠 때만 보여 고르기 바가 본문을 덮지 않는다(#336).
  assert_contains "$(cat "$LP_W/board.html")" '<span class="ask-run" hidden>' "the start guidance shows only when the board can start a run"
  assert_contains "$(cat "$LP_W/board.html")" '.pick .fields{display:none;' "the pick bar keeps its fields folded until asked"
fi
assert_eq "--work $(cd "$LP_W" && pwd) --kind references" "$(LANDING_BOARD_CMD="echo" lp board)" "LANDING_BOARD_CMD replaces the board script"
# An interactive board is looked at, so each tab needs enough references (references_min in the graph).
LP_I="$TEST_TMP/lp-run-i"; mkdir -p "$LP_I"
lpi() { "$ROOT/scripts/landing-run.sh" "$@" --work "$LP_I" 2>"$TEST_TMP/lp.err"; }
lpi_rc() { local rc=0; lpi "$@" >/dev/null || rc=$?; printf '%s' "$rc"; }
lpi init --mode interactive >/dev/null
printf '## Tone and manner\ncalm, precise\n' >"$LP_I/brief.md"; cp "$TEST_TMP/lp-tone.json" "$LP_I/tone.json"
lpi submit --node brief --outcome brief_ready >/dev/null
cp "$TEST_TMP/lp-slots.json" "$LP_I/component-slots.json"
lp_refs() { # tone component layout interaction videos competitor → references.json
  jq -n --argjson t "$1" --argjson c "$2" --argjson l "$3" --argjson i "$4" --argjson v "$5" --argjson p "$6" '
    def ref($k; $n): {id: "\($k)-\($n)", kind: $k, title: "x", url: "https://\($k)-\($n).example/", source: "search", take: "t", captures: (if $k == "layout" then ["refs/x/w1440-00.png", "refs/x/w390-00.png"] else ["refs/x.png"] end)}
      + (if $k != "competitor" then {keep_strength: "k", must_not_shrink_to: "m"} else {} end)
      + (if $k == "tone" then {tone_part: "palette"} else {} end)
      + (if $n == 0 and ($k == "layout" or $k == "interaction") then {recommended: $k} elif $n == 0 and $k == "component" then {recommended: "hero"} else {} end);
    [range($t) | ref("tone"; .)] + [range($c) | ref("component"; .)] + [range($l) | ref("layout"; .)]
    + [range($i) | ref("interaction"; .) + (if . < $v then {video: "https://example.com/v\(.).mp4"} else {} end)]
    + [range($p) | ref("competitor"; .) + {analysis: {leads_with: "a", claim: "b", cta: "c", gap: "d"}}]' >"$LP_I/references.json"
}
jq '.[0].results = [range(5) | "https://competitor-\(.).example/"]' "$TEST_TMP/lp-searches.json" >"$LP_I/searches.json"
lp_refs 1 1 1 1 1 1
assert_eq 4 "$(lpi_rc submit --node references --outcome references_ready)" "an interactive board with one reference per tab is refused"
assert_contains "$(cat "$TEST_TMP/lp.err")" "tone has 1, needs at least 3" "the runner names the tab that is short"
lp_refs 3 3 3 4 1 2
assert_eq 4 "$(lpi_rc submit --node references --outcome references_ready)" "an interactive board with fewer than two interaction videos is refused"
lp_refs 3 3 3 4 2 5
assert_eq 4 "$(lpi_rc submit --node references --outcome references_ready)" "an interactive board with more than four competitors is refused"
lp_refs 3 3 3 4 2 2
jq '.[1].id = .[0].id' "$LP_I/references.json" >"$TEST_TMP/lp-dup.json" && cp "$TEST_TMP/lp-dup.json" "$LP_I/references.json"
assert_eq 4 "$(lpi_rc submit --node references --outcome references_ready)" "two references with one id are refused"
lp_refs 3 3 3 4 2 2
jq '.[0].results = ["https://competitor-0.example/"]' "$TEST_TMP/lp-searches.json" >"$LP_I/searches.json"
assert_eq 4 "$(lpi_rc submit --node references --outcome references_ready)" "a competitor found outside search is refused"
jq 'map(if .id == "competitor-1" then .source = "user" else . end)' "$LP_I/references.json" >"$TEST_TMP/lp-user.json" && cp "$TEST_TMP/lp-user.json" "$LP_I/references.json"
assert_eq reference_pick "$(lpi submit --node references --outcome references_ready)" "a competitor the user named needs no search result; enough per tab goes to the pick"
DR_RULES="$ROOT/skills/design-references/references/refs-rules.json"
jq '.interactive.interaction_video = 9' "$DR_RULES" >"$TEST_TMP/dr-bad-rules.json"
assert_eq 2 "$(rc=0; DESIGN_REFS_RULES="$TEST_TMP/dr-bad-rules.json" "$ROOT/scripts/design-refs.sh" check --work "$LP_I" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc")" "rules asking for more interaction videos than interactions are invalid"
jq 'del(.unattended)' "$DR_RULES" >"$TEST_TMP/dr-bad-rules.json"
assert_eq 2 "$(rc=0; DESIGN_REFS_RULES="$TEST_TMP/dr-bad-rules.json" "$ROOT/scripts/design-refs.sh" check --work "$LP_I" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc")" "rules without unattended reference counts are invalid"
jq '.unattended.competitor_domains = 1' "$DR_RULES" >"$TEST_TMP/dr-bad-rules.json"
assert_eq 2 "$(rc=0; DESIGN_REFS_RULES="$TEST_TMP/dr-bad-rules.json" "$ROOT/scripts/design-refs.sh" check --work "$LP_I" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc")" "rules allowing a single competitor site are invalid"
# The user picks on the board: wait-pick returns once a pick made after the node started is there.
printf '{"tone":"old","kept":["tone-0"]}\n' >"$LP_I/reference-pick.json"; touch -t 202001010000 "$LP_I/reference-pick.json"
assert_eq 4 "$(lpi_rc wait-pick --node reference_pick --timeout-min 0)" "wait-pick ignores a pick from before the node started"
assert_eq 3 "$(lpi_rc wait-pick --node draft_pick --timeout-min 0)" "wait-pick waits only on the current node"
if command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  lp_port="$(free_port)"
  assert_eq "http://127.0.0.1:$lp_port/board.html" "$(lpi board --port "$lp_port" --serve)" "board --serve starts the board server and prints the board URL"
  lp_post() { curl -s -o /dev/null -w '%{http_code}' -X "${2:-POST}" -H 'content-type: application/json' ${3:+-H "origin: $3"} --data "$1" "http://127.0.0.1:$lp_port${4:-/pick}"; }
  assert_eq 400 "$(lp_post '{"node":"reference_pick","tone":"이대로","kept":["nope"]}')" "the board server refuses unknown reference ids"
  assert_eq 400 "$(lp_post 'not json')" "the board server refuses a body that is not JSON"
  assert_eq 400 "$(lp_post '{"node":"build"}')" "the board server writes only the pick nodes"
  assert_eq 405 "$(lp_post '{}' POST "" /board.html)" "the board server takes POST only at /pick"
  assert_eq 405 "$(lp_post '{}' PUT)" "the board server refuses other methods"
  assert_eq 403 "$(lp_post '{"node":"reference_pick","tone":"이대로","kept":["tone-0"]}' POST "http://evil.example")" "the board server refuses another origin"
  assert_eq 404 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$lp_port/.landing-run/state.json")" "the board server does not serve the run state"
  assert_eq 200 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$lp_port/board.html")" "the board server serves the board"
  LP_PRIM='"primary":{"layout":"layout-1","interaction":"interaction-0","components":{"hero":"component-2","proof":null,"extra-1":"component-0"},"added_slots":[{"id":"extra-1","label":"연동"}]}'
  assert_eq 400 "$(lp_post '{"node":"reference_pick","tone":"이대로","kept":["tone-0"],"dropped":["layout-1"],'"$LP_PRIM"'}')" "the board server refuses an excluded reference as a primary"
  assert_eq 400 "$(lp_post '{"node":"reference_pick","tone":"이대로","kept":["tone-0"],"primary":{"layout":"layout-1","interaction":"interaction-0","components":{"pricing":"component-0"}}}')" "the board server refuses a component for a slot that does not exist"
  assert_eq 400 "$(lp_post '{"node":"reference_pick","tone":"이대로","kept":["tone-0"]}')" "the board server refuses a pick without its primary references"
  assert_eq 200 "$(lp_post '{"node":"reference_pick","tone":"바꿀 점: 더 따뜻하게","kept":["tone-0","layout-1"],"dropped":["tone-1"],"add_sites":["https://example.com/x"],"user_words":"더 따뜻하게",'"$LP_PRIM"'}')" "the board server takes a valid pick"
  assert_eq "layout-1|component-0|연동" "$(jq -r '[.primary.layout, .primary.components["extra-1"], .primary.added_slots[0].label] | join("|")' "$LP_I/reference-pick.json")" "the pick keeps the primary references and the added slot"
  assert_eq picked "$(jq -r '.status' "$HARNESS_METRICS_DIR/board/references/$("$ROOT/scripts/design-refs.sh" run-id --work "$LP_I").json")" "a pick on the board marks the reference board's run record picked"
  assert_eq "바꿀 점: 더 따뜻하게|tone-0,layout-1|더 따뜻하게" "$(jq -r '[.tone, (.kept | join(",")), .user_words] | join("|")' "$LP_I/reference-pick.json")" "the pick keeps the user's words as written"
  assert_eq "$LP_I/reference-pick.json" "$(lpi wait-pick --node reference_pick --timeout-min 1 | sed "s#^$(cd "$LP_I" && pwd)#$LP_I#")" "wait-pick returns once the board writes the pick"
  lp_state() { curl -s "http://127.0.0.1:$lp_port/state?node=${1:-reference_pick}"; }
  assert_eq "reference_pick|바꿀 점: 더 따뜻하게" "$(lp_state | jq -r '[.node, .picked.tone] | join("|")')" "GET /state returns the current node and the pick made in it"
  assert_eq 409 "$(lp_post '{"node":"reference_pick","tone":"이대로","kept":["tone-0"],'"$LP_PRIM"'}')" "a second pick in the same node is refused, not rewritten"
  assert_eq "바꿀 점: 더 따뜻하게" "$(jq -r .tone "$LP_I/reference-pick.json")" "the refused pick leaves the first one as it was"
  assert_eq picked "$(lpi submit --node reference_pick --outcome picked >/dev/null; jq -r '.history[-1].outcome' "$LP_I/.landing-run/state.json")" "the board's pick passes the runner's reference_pick check"
  assert_eq 409 "$(lp_post '{"node":"reference_pick","tone":"이대로","kept":["tone-0"],'"$LP_PRIM"'}')" "a pick after the run moved on is refused"
  assert_eq "already_started|direction" "$(curl -s -X POST -H 'content-type: application/json' --data '{"node":"reference_pick","tone":"이대로","kept":["tone-0"],'"$LP_PRIM"'}' "http://127.0.0.1:$lp_port/pick" | jq -r '[.error, .node] | join("|")')" "the refusal names the run's current node"
  assert_eq "direction|바꿀 점: 더 따뜻하게" "$(lp_state | jq -r '[.node, .picked.tone] | join("|")')" "GET /state still shows the pick once the run has moved on"
  assert_eq "direction|null" "$(lp_state draft_pick | jq -r '[.node, (.picked | tostring)] | join("|")')" "GET /state has no draft pick before one is made"
  pkill -f "landing-board-server.mjs --work $(cd "$LP_I" && pwd) --port $lp_port" 2>/dev/null || true
  printf '{"candidates":[{"id":"a","dir":"site/a","motion_level":"calm","first_viewport":"one scene"},{"id":"b","dir":"site/b","motion_level":"lively","first_viewport":"another"}]}\n' >"$LP_I/candidates.json"
  printf '{"url":"http://127.0.0.1:9/a/","captures":["caps/a-1440.png","caps/a-390.png"]}\n' >"$LP_I/preview-a.json"
  lpi board --kind drafts >/dev/null
  assert_contains "$(cat "$LP_I/draft-board.html")" 'name="draft" value="b"' "the drafts board lets the user go ahead with one candidate"
  assert_contains "$(cat "$LP_I/draft-board.html")" "caps/a-390.png" "the drafts board shows each candidate's phone capture"
fi
assert_eq 3 "$(lp_rc submit --node references --outcome picked)" "landing-run refuses an outcome with no edge"
rm -f "$LP_W/component-slots.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "references without their section slots are refused"
printf '[{"id":"hero","label":"첫 화면"},{"id":"hero","label":"다시"}]\n' >"$LP_W/component-slots.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "a slot listed twice is refused"
cp "$TEST_TMP/lp-slots.json" "$LP_W/component-slots.json"
jq 'map(del(.recommended))' "$TEST_TMP/lp-refs.json" >"$LP_W/references.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "references without the agent's recommended primary are refused"
assert_contains "$(cat "$TEST_TMP/lp.err")" "recommend exactly one layout reference" "the runner names the missing recommendation"
jq 'map(if .id == "R2" then .recommended = "pricing" else . end)' "$TEST_TMP/lp-refs.json" >"$LP_W/references.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "a component recommended for a slot that does not exist is refused"
cp "$TEST_TMP/lp-refs.json" "$LP_W/references.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "an unattended run without its own pick is refused"
jq '.via = "board"' "$TEST_TMP/lp-agent-pick.json" >"$LP_W/reference-pick.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "an unattended pick says it was the agent's"
jq '.primary.layout = "R9"' "$TEST_TMP/lp-agent-pick.json" >"$LP_W/reference-pick.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "a primary that names no reference is refused"
jq '.dropped = ["R4"]' "$TEST_TMP/lp-agent-pick.json" >"$LP_W/reference-pick.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "an excluded reference cannot be a primary"
assert_contains "$(cat "$TEST_TMP/lp.err")" "primary.interaction must be an interaction reference that is not excluded" "the runner names the excluded primary"
jq '.primary.components.pricing = "R2"' "$TEST_TMP/lp-agent-pick.json" >"$LP_W/reference-pick.json"
assert_eq 4 "$(lp_rc submit --node references --outcome references_ready)" "a component for a slot that is neither listed nor added is refused"
cp "$TEST_TMP/lp-agent-pick.json" "$LP_W/reference-pick.json"
assert_eq direction "$(lp submit --node references --outcome references_ready)" "unattended runs skip the human reference pick (the agent's pick, with an added slot, passes)"
pass "landing-page graph runner: contract, reference checks, reference board and server, unattended reference pick"

finish_tests
