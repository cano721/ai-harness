#!/usr/bin/env bash
# 회귀 테스트 — 자동 sync 연쇄: 전역 분석 주기·무인 실행 표지
# 실행: bash tests/run.sh automation-chain-global
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-sync-chain.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-sync-chain.sh"

# 원래 순서에서는 앞 블록(automation-chain-order)이 남긴 chain-2 세션 이벤트가 있는 채로 돈다.
jq -cn --arg cwd "$TEST_TMP/chain-2" '{kind:"session",src:"claude",sid:"prio",project:"chain-2",cwd:$cwd}' >"$CHAIN_DATA/events/prio.jsonl"
# 전역 분석은 정기 sweep에서만 주기(기본 7일)당 한 번 돈다 — 연쇄가 끼워 넣지 않는다.
rm -rf "$CHAIN_DATA/sync-auto" "$CHAIN_DATA/harvest-auto" "$CHAIN_DATA/harvest-queue"
chain_global() {
  HARNESS_METRICS_DIR="$CHAIN_DATA" HM_SYNC_AUTO=1 HM_HARVEST_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=9 HM_HARVEST_AUTO_DAILY_MAX=9 \
    HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$SYNC_STUB" HM_HARVEST_AUTO_AGENT=claude \
    HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" \
    SYNC_STUB_OUT="$TEST_TMP/chain-global.out" "$ROOT/scripts/harvest-auto.sh" sweep
}
chain_global
rm -rf "$CHAIN_DATA/sync-auto"
chain_global
assert_eq "1" "$(jq -sr '[.[] | select(.event=="started" and .project=="_global")] | length' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "a chain does not add global runs beyond the periodic sweep"
# 무인 실행은 transcript를 남기지 않는다 — 사용자 활동 판정과 수집에 섞이지 않게.
# shellcheck disable=SC2016  # 스크립트 원문의 literal 변수 참조를 검사
assert_eq "2" "$(grep -c -- '--plugin-dir "$plugin_root" --no-session-persistence' "$ROOT/scripts/harvest-auto.sh")" "unattended claude runs keep no transcript"
# 무인 실행이 도는 동안 정기 실행은 LLM 단계를 건너뛴다.
assert_contains "$(<"$ROOT/scripts/backfill-due.sh")" "run_in_flight && { SKIP_REASON=run_in_flight; return 1; }" "scheduled LLM steps skip while an unattended run is in flight"
pass "auto sync chains runs within the daily cap"

finish_tests
