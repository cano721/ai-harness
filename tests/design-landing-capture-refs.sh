#!/usr/bin/env bash
# 회귀 테스트 — landing-page 레퍼런스 일괄 캡처(capture-refs)와 레퍼런스 보드 브라우저 E2E(별 표시 이동·섹션 슬롯 추가)
# 실행: bash tests/run.sh design-landing-capture-refs
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-design.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-design.sh"
# capture-refs: one call for every reference; a bad list is refused before a browser starts.
LP_R="$TEST_TMP/lp-refs-run"; mkdir -p "$LP_R"
printf '[{"id":"a","url":"http://127.0.0.1:9/","record":true}]\n' >"$LP_R/refs-to-capture.json"
assert_contains "$(LANDING_CAPTURE_REFS_CMD="echo" "$ROOT/scripts/landing-run.sh" capture-refs --work "$LP_R" --file "$LP_R/refs-to-capture.json" 2>/dev/null)" "--phase all" "capture-refs captures and records in one call by default"
assert_contains "$(LANDING_CAPTURE_REFS_CMD="echo" "$ROOT/scripts/landing-run.sh" capture-refs --work "$LP_R" --file "$LP_R/refs-to-capture.json" --background 2>/dev/null)" "--phase stills" "capture-refs --background takes the stills in the foreground"
if command -v node >/dev/null 2>&1; then
  printf '[{"id":"../x","url":"file:///etc/passwd"}]\n' >"$LP_R/bad-refs.json"
  lp_cr_rc=0; node "$ROOT/scripts/landing-capture-refs.mjs" --work "$LP_R" --file "$LP_R/bad-refs.json" >/dev/null 2>&1 || lp_cr_rc=$?
  assert_eq 2 "$lp_cr_rc" "capture-refs refuses an id that leaves refs/ and a URL that is not http"
fi
if command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  if landing_browser_ok; then
    lp_p3="$(free_port)"; lp_p4="$(free_port)"
    # Two local sites captured in one call (four at a time), a recording left in the background, a bot check flagged.
    python3 -I -m http.server "$lp_p3" --bind 127.0.0.1 --directory "$ROOT/tests/fixtures/landing-refs/a" >/dev/null 2>&1 & LP_SRV3=$!
    python3 -I -m http.server "$lp_p4" --bind 127.0.0.1 --directory "$ROOT/tests/fixtures/landing-refs/b" >/dev/null 2>&1 & LP_SRV4=$!
    sleep 1
    printf '[{"id":"a","url":"http://127.0.0.1:%s/","record":true},{"id":"b","url":"http://127.0.0.1:%s/"},{"id":"cf","url":"http://127.0.0.1:%s/challenge/"},{"id":"w","url":"http://127.0.0.1:%s/widget/"}]\n' "$lp_p3" "$lp_p4" "$lp_p3" "$lp_p3" >"$LP_R/refs-to-capture.json"
    LANDING_RECORD_SECONDS=2 "$ROOT/scripts/landing-run.sh" capture-refs --work "$LP_R" --file "$LP_R/refs-to-capture.json" --background >/dev/null 2>&1 || true
    assert_eq "ok ok challenge" "$(for i in a b cf; do jq -r '.status' "$LP_R/refs/$i/capture.json"; done | tr '\n' ' ' | sed 's/ $//')" "capture-refs captures both sites and flags the bot check"
    assert_eq "Reference B" "$(jq -r '.title' "$LP_R/refs/b/capture.json")" "capture-refs records each page's title"
    assert_eq ok "$(jq -r '.status' "$LP_R/refs/w/capture.json")" "a page that drew its content is not a bot check for carrying a captcha widget"
    assert_file "$LP_R/refs/a/w1440-00.png"; assert_file "$LP_R/refs/b/w390-00.png"
    assert_eq 4 "$(jq -r '.concurrency' "$LP_R/refs/capture-refs.json")" "capture-refs captures four pages at a time"
    for _ in $(seq 1 40); do [[ -f "$LP_R/refs/record.done" ]] && break; sleep 0.5; done
    assert_file "$LP_R/refs/record.done"
    assert_file "$LP_R/refs/a/rec.webm"
    assert_eq "refs/a/rec.webm" "$(jq -r '.video' "$LP_R/refs/a/capture.json")" "the recording is listed next to the reference's captures"
    # 보드 E2E가 읽는 대화형 레퍼런스 묶음(보드 영역의 LP_I와 같은 구성)
    LP_I="$TEST_TMP/lp-run-i"; mkdir -p "$LP_I"
    printf '## Tone and manner\ncalm, precise\n' >"$LP_I/brief.md"; cp "$TEST_TMP/lp-tone.json" "$LP_I/tone.json"
    cp "$TEST_TMP/lp-slots.json" "$LP_I/component-slots.json"
    lp_refs 3 3 3 4 2 2
    jq '.[0].results = ["https://competitor-0.example/"]' "$TEST_TMP/lp-searches.json" >"$LP_I/searches.json"
    jq 'map(if .id == "competitor-1" then .source = "user" else . end)' "$LP_I/references.json" >"$TEST_TMP/lp-user.json" && cp "$TEST_TMP/lp-user.json" "$LP_I/references.json"
    # The reference board in a browser: the layout star moved, a section slot added and given a component, then start.
    LP_B="$TEST_TMP/lp-run-board"; mkdir -p "$LP_B"
    lpb() { "$ROOT/scripts/landing-run.sh" "$@" --work "$LP_B" 2>"$TEST_TMP/lp.err"; }
    lpb init --mode interactive >/dev/null
    for f in brief.md tone.json; do cp "$LP_I/$f" "$LP_B/$f"; done
    lpb submit --node brief --outcome brief_ready >/dev/null
    for f in references.json searches.json component-slots.json; do cp "$LP_I/$f" "$LP_B/$f"; done
    lpb submit --node references --outcome references_ready >/dev/null
    lp_port="$(free_port)"
    lp_e2e="$(node "$ROOT/tests/fixtures/landing-board/primary-e2e.mjs" --url "$(lpb board --port "$lp_port" --serve)" --shots "$TEST_TMP/lp-board-shots")"
    assert_eq "done" "$(jq -r '.result' <<<"$lp_e2e")" "the board takes a moved star and an added slot in a browser"
    assert_eq "$(jq -r '.layout' <<<"$lp_e2e")|interaction-0|component-0|$(jq -r '.component' <<<"$lp_e2e")|연동" \
      "$(jq -r '[.primary.layout, .primary.interaction, .primary.components.hero, .primary.components["extra-1"], .primary.added_slots[0].label] | join("|")' "$LP_B/reference-pick.json")" \
      "the pick records the moved star, the kept recommendations, and the added slot"
    assert_eq direction "$(lpb submit --node reference_pick --outcome picked)" "the board's primary passes the runner's check"
    assert_file "$TEST_TMP/lp-board-shots/primary-4-started.png"
    pkill -f "landing-board-server.mjs --work $(cd "$LP_B" && pwd) --port $lp_port" 2>/dev/null || true
    kill "$LP_SRV3" "$LP_SRV4" 2>/dev/null || true
    wait "$LP_SRV3" "$LP_SRV4" 2>/dev/null || true
  else
    printf '# skip capture-refs browser checks: no Playwright Chromium\n'
  fi
fi
pass "capture-refs captures several sites at once, flags a bot check, records in the background; the reference board takes a primary in a browser"

finish_tests
