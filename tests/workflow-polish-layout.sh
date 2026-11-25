#!/usr/bin/env bash
# 회귀 테스트 — design-polish 러너 — 레이아웃 probe 측정·빈 띠 차단·브라우저 probe
# 실행: bash tests/run.sh workflow-polish-layout
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 레이아웃 깨짐(#409): 실측에서 360폭 본문 앞 빈 띠가 audit 96·검토 통과로 남았다. 측정이 캡처마다 브라우저에서 probe를 돌려
# 결과를 측정 JSON에 넣고, 러너가 그 결과로 통과를 막는다 — 채점·검토 모델이 놓쳐도.
new_driver_repo polish_layout_ok
driver start --workflow polish --runtime codex --request "다듬어줘"
PL_RUN="$(dirname "$(find "$DRIVER_TMP/runs" -path "*repo-polish_layout_ok-*" -name state.json | head -n 1)")"
assert_contains "$(<"$FAKE_LOG.measure.prompt")" "$PL_RUN/layout-probe.js" "measure is told to evaluate the layout probe before each capture"
node --check "$PL_RUN/layout-probe.js" 2>/dev/null || fail "the layout probe the driver writes is valid JavaScript"
assert_contains "$(<"$FAKE_LOG.diagnose.prompt")" "no issue on any captured screen" "diagnose sees the layout check result"
new_driver_repo polish_layout_band
driver start --workflow polish --runtime codex --request "다듬어줘"
assert_contains "$(<"$FAKE_LOG.diagnose.prompt")" "target board · 1280 · light: empty-band — 335px band" "diagnose gets the baseline layout issue as evidence"
assert_contains "$(<"$FAKE_LOG.diagnose.prompt")" "Every layout check issue above is a major item" "a layout issue is a major item"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .node)" "a target screen that keeps its empty band never passes, even when the audit and the review pass"
assert_contains "$(run_state '.findings | join(";")')" "layout (target board · 1280 · light): empty-band" "the driver blocks the pass on the layout issue"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "Look at each capture first for empty bands" "the reviewer looks for bands, overflow, and clipping first"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "found
- target board · 1280 · light: empty-band" "the reviewer gets the layout issues after the fix"
# probe 자체: 실제 브라우저에서 깨진 페이지는 잡고 정상 패턴(sticky 사이드바·가로 스크롤 탭·말줄임·접힌 영역·줄 수 제한·
# 화면 낭독 전용·바닥 고정 푸터·큰 히어로 여백)은 지나간다. Playwright Chromium이 없으면 건너뛴다.
if command -v node >/dev/null 2>&1; then
  PL_OUT="$(node "$ROOT/tests/fixtures/polish-layout/probe.mjs" "$PL_RUN/layout-probe.js" "$ROOT/tests/fixtures/polish-layout" 2>/dev/null || echo '{}')"
  if jq -e '.skip' <<<"$PL_OUT" >/dev/null 2>&1; then
    printf '# skip layout probe browser checks: %s\n' "$(jq -r '.skip' <<<"$PL_OUT")"
  else
    assert_eq "band@360=empty-band band@1280= ok-app@360= ok-app@1280= overflow@360=overflow-x overflow@1280= clipped@360=clipped clipped@1280=clipped column@360= column@1280=bg-short landing@360= landing@1280=" \
      "$(jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' <<<"$PL_OUT")" "the layout probe flags each planted breakage and nothing on the healthy pages"
  fi
fi
pass "design-polish layout probe is measured and an empty band blocks the pass"

finish_tests
