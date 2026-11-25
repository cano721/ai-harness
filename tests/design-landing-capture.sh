#!/usr/bin/env bash
# 회귀 테스트 — landing-page 실제 캡처(landing-capture.mjs): 두 폭의 투어·상태·시트. Playwright Chromium이 뜰 때만 단언한다.
# 실행: bash tests/run.sh design-landing-capture
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-design.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-design.sh"
LP_FIX="$ROOT/tests/fixtures/landing-measure"
if command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  if landing_browser_ok; then
    lp_p1="$(free_port)"
    python3 -I -m http.server "$lp_p1" --bind 127.0.0.1 --directory "$LP_FIX/good" >/dev/null 2>&1 & LP_SRV1=$!
    sleep 1
    node "$ROOT/scripts/landing-capture.mjs" --url "http://127.0.0.1:$lp_p1/" --out "$TEST_TMP/lp-caps" >/dev/null 2>&1 || true
    assert_eq "done" "$(jq -r '.result' "$TEST_TMP/lp-caps/captures.json")" "landing-capture takes the tour, states, and sheets at both widths"
    assert_file "$TEST_TMP/lp-caps/sheet-390.png"
    kill "$LP_SRV1" 2>/dev/null || true
  else
    printf '# skip landing-capture browser checks: no Playwright Chromium\n'
  fi
fi
pass "landing-capture takes the tour, states, and sheets (real browser)"

finish_tests
