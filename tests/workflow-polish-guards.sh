#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — design-polish 보호 경로·레이아웃 probe
# 실행: bash tests/run.sh workflow-polish-guards
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 보호 경로(#411): Claude Code는 설정 디렉터리(~/.claude, CLAUDE_CONFIG_DIR) 안을 무인 세션이 고치거나 읽지 못하게 막는다.
# 실측에서 저장소가 ~/.claude 아래라 fix가 매번 거부돼 "fix changed nothing"으로 수리 횟수만 썼다.
new_driver_repo protected_src
PROT_REPO="$DRIVER_TMP/claude/jobs/protected"
mkdir -p "$PROT_REPO"
git -C "$PROT_REPO" init -q
git -C "$PROT_REPO" config user.email t@t
git -C "$PROT_REPO" config user.name t
git -C "$PROT_REPO" commit -q --allow-empty -m init
DRIVER_REPO="$PROT_REPO"
driver start --workflow polish --runtime claude --request "다듬어줘"
assert_eq "2" "$DRIVER_RC" "a claude run in a repository inside the Claude configuration directory is refused before it starts"
assert_contains "$DRIVER_OUT" "inside the Claude Code configuration directory" "the refusal says why"
assert_contains "$DRIVER_OUT" "git worktree add" "the refusal says how to work around it"
[[ ! -s "$FAKE_LOG" ]] || fail "no session runs in a protected repository"
driver start --runtime codex --request "add feature"
assert_eq "10" "$DRIVER_RC" "the codex sandbox is not limited by the Claude configuration directory"
new_driver_repo protected_runs
DRIVER_RC=0
DRIVER_OUT="$(HM_APPROVAL='' HM_APPROVAL_REPOS='' HM_RUNTIME='' HM_RUNTIME_REPOS='' HARNESS_METRICS_DIR="$DRIVER_TMP/data" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/claude/runs" CLAUDE_CONFIG_DIR="$DRIVER_TMP/claude" \
  PATH="$ROOT/tests/fixtures/driver:$PATH" bash "$DRIVER" start --runtime claude --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "a run folder inside the Claude configuration directory is refused too"
assert_contains "$DRIVER_OUT" "HM_FEATURE_RUNS_DIR" "the refusal names the setting that moves the run folder"
# 권한에 막혀 아무것도 못 바꾼 fix는 환경 실패다: 수리 횟수를 쓰지 않고, 막힌 호출을 알린다.
new_driver_repo polish_denied
driver start --workflow polish --runtime claude --request "다듬어줘"
say_in_claude "승인"
driver resume
assert_eq "30" "$DRIVER_RC" "a denied fix stops as incomplete"
assert_contains "$DRIVER_OUT" "the session was denied: Edit " "the stop names the denied call"
assert_contains "$DRIVER_OUT" "screen.css. This environment failure" "the stop names the denied path"
assert_contains "$DRIVER_OUT" "does not count as a repair attempt" "the stop says the attempt was not counted"
assert_eq "0" "$(run_state .attempts)" "an environment failure does not use up a repair attempt"
driver resume
assert_eq "30:0" "$DRIVER_RC:$(run_state .attempts)" "resuming the same environment failure still uses no attempt"
pass "runners refuse a working folder Claude Code protects and do not count denied fixes as attempts"
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
new_driver_repo polish_layout_sibling
driver start --workflow polish --runtime codex --request "다듬어줘"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a sibling screen's layout issue that was already in the baseline is not a regression of this change"
new_driver_repo polish_layout_sibling_new
driver start --workflow polish --runtime codex --request "다듬어줘"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .node)" "a layout issue the fix brought to a sibling screen blocks the pass"
assert_contains "$(run_state '.findings | join(";")')" "layout (sibling settings · 1280 · light): clipped" "the sibling regression is named"
new_driver_repo polish_layout_missing
driver start --workflow polish --runtime codex --request "다듬어줘"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .node)" "a measure without the layout probe result is not a measurement"
assert_contains "$(run_state '.findings | join(";")')" "layout probe did not run on every screen" "the reason names the missing probe"
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
pass "design-polish blocks a pass on layout breakage the probe measured in the browser"

finish_tests
