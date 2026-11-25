#!/usr/bin/env bash
# 디자인 영역(tests/design*.sh)이 source하는 공용 준비: 랜딩 그래프 경로와 레퍼런스 단계 fixture($TEST_TMP/lp-*.json), 브라우저 확인 함수.
# tests/lib.sh 다음에 source한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
LP_GRAPH="$ROOT/skills/landing-page/references/landing-page-graph.json"
cat >"$TEST_TMP/lp-tone.json" <<'JSON'
{"mood":["calm","precise","warm"],"avoid":"a test, a hype campaign","palette":[{"name":"Ink","hex":"#18191b","role":"text"},{"name":"Brand","hex":"#3366ff","role":"primary action"}],
 "type":{"display":"Sans 800","body":"Sans 400","display_sample":"Practice first","body_sample":"Answer one question."},"voice":"Calm and plain.","imagery":"product UI"}
JSON
cat >"$TEST_TMP/lp-refs.json" <<'JSON'
[{"id":"R1","kind":"tone","title":"Tone ref","url":"https://tone-a.example/","source":"search","take":"t","keep_strength":"k","must_not_shrink_to":"m","tone_part":"palette","captures":["refs/r1.png"]},
 {"id":"R2","kind":"component","title":"Component ref","url":"https://comp-b.example/","source":"library","take":"t","keep_strength":"k","must_not_shrink_to":"m","captures":["refs/r2.png"],"recommended":"hero"},
 {"id":"R3","kind":"layout","title":"Layout ref","url":"https://layout-c.example/","source":"user","take":"t","keep_strength":"k","must_not_shrink_to":"m","captures":["refs/r3/w1440-00.png","refs/r3/w390-00.png"],"recommended":"layout"},
 {"id":"R4","kind":"interaction","title":"Interaction ref","url":"https://motion-d.example/","source":"gallery","take":"t","keep_strength":"k","must_not_shrink_to":"m","video":"refs/r4.mp4","recommended":"interaction"},
 {"id":"R5","kind":"competitor","title":"Competitor","url":"https://rival-e.example/","source":"search","captures":["refs/r5.png"],
  "analysis":{"leads_with":"a demo","claim":"fast","cta":"Start free","gap":"no practice"}},
 {"id":"R6","kind":"competitor","title":"Competitor 2","url":"https://www.rival-f.example/pricing","source":"search","captures":["refs/r6.png"],
  "analysis":{"leads_with":"a price","claim":"cheap","cta":"Buy","gap":"no feedback"}}]
JSON
printf '[{"id":"hero","label":"첫 화면"},{"id":"proof","label":"증거"}]\n' >"$TEST_TMP/lp-slots.json"
printf '%s\n' '{"tone":"이대로","kept":["R1","R2","R3","R4","R5"],"dropped":[],"via":"agent","primary":{"layout":"R3","interaction":"R4","components":{"hero":"R2","proof":null,"faq":null},"added_slots":[{"id":"faq","label":"FAQ"}]}}' >"$TEST_TMP/lp-agent-pick.json"
cat >"$TEST_TMP/lp-searches.json" <<'JSON'
[{"query":"ai interview practice","purpose":"category","engine_or_gallery":"web search","results":["https://rival-e.example/","https://rival-f.example/pricing","https://z.example/"],"picked":["R5","R6"]},
 {"query":"3d scroll","purpose":"gallery","engine_or_gallery":"codrops hub","results":["https://motion-d.example/"],"picked":["R4"]}]
JSON
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
landing_browser_ok() { # Playwright Chromium이 뜰 수 있으면 0
  node --input-type=module -e 'const { launchBrowser } = await import("file://" + process.argv[1]); const { browser } = await launchBrowser(); if (!browser) process.exit(1); await browser.close();' "$ROOT/scripts/landing-browser.mjs" >/dev/null 2>&1
}
