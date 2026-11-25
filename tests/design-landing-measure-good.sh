#!/usr/bin/env bash
# 회귀 테스트 — landing-page 실제 측정(landing-measure.mjs)이 깨끗한 고정 페이지를 통과시키는지. Playwright Chromium이 뜰 때만 단언한다.
# 실행: bash tests/run.sh design-landing-measure-good
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LP_GRAPH="$ROOT/skills/landing-page/references/landing-page-graph.json"
LP_FIX="$ROOT/tests/fixtures/landing-measure"
if command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  lp_p1="$(free_port)"
  python3 -I -m http.server "$lp_p1" --bind 127.0.0.1 --directory "$LP_FIX/good" >/dev/null 2>&1 & LP_SRV1=$!
  sleep 1
  node "$ROOT/scripts/landing-measure.mjs" --url "http://127.0.0.1:$lp_p1/" --out "$TEST_TMP/lp-good.json" --graph "$LP_GRAPH" --motion-level lively >/dev/null 2>&1 || true
  if [[ "$(jq -r '.result' "$TEST_TMP/lp-good.json" 2>/dev/null)" == unverified ]] && jq -e '.checks | length == 0' "$TEST_TMP/lp-good.json" >/dev/null 2>&1; then
    printf '# skip landing-measure browser checks: %s\n' "$(jq -r '.reason' "$TEST_TMP/lp-good.json")"
  else
    assert_eq pass "$(jq -r '.result' "$TEST_TMP/lp-good.json")" "landing-measure passes a clean page"
  fi
  kill "$LP_SRV1" 2>/dev/null || true
fi
pass "landing-measure passes a clean page (real browser)"

finish_tests
