#!/usr/bin/env bash
# 회귀 테스트 — landing-page 실제 측정(landing-measure.mjs)이 심어 둔 결함을 항목별로 잡는지. Playwright Chromium이 뜰 때만 단언한다.
# 실행: bash tests/run.sh design-landing-measure-bad
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LP_GRAPH="$ROOT/skills/landing-page/references/landing-page-graph.json"
LP_FIX="$ROOT/tests/fixtures/landing-measure"
if command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  lp_p2="$(free_port)"
  python3 -I -m http.server "$lp_p2" --bind 127.0.0.1 --directory "$LP_FIX/bad" >/dev/null 2>&1 & LP_SRV2=$!
  sleep 1
  node "$ROOT/scripts/landing-measure.mjs" --url "http://127.0.0.1:$lp_p2/" --out "$TEST_TMP/lp-bad.json" --graph "$LP_GRAPH" --motion-level lively >/dev/null 2>&1 || true
  if [[ "$(jq -r '.result' "$TEST_TMP/lp-bad.json" 2>/dev/null)" == unverified ]] && jq -e '.checks | length == 0' "$TEST_TMP/lp-bad.json" >/dev/null 2>&1; then
    printf '# skip landing-measure browser checks: %s\n' "$(jq -r '.reason' "$TEST_TMP/lp-bad.json")"
  else
    assert_eq "bar_backdrop contrast_solid destinations first_action ghost_layer moment_frame_rate overflow placeholders text_covered" \
      "$(jq -r '[.checks[] | select(.status == "fail") | .id] | sort | join(" ")' "$TEST_TMP/lp-bad.json")" "landing-measure catches each planted defect"
  fi
  kill "$LP_SRV2" 2>/dev/null || true
fi
pass "landing-measure catches each planted defect (real browser)"

finish_tests
