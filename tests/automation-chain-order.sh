#!/usr/bin/env bash
# 회귀 테스트 — 자동 sync 연쇄: sweep 순서
# 실행: bash tests/run.sh automation-chain-order
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-sync-chain.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-sync-chain.sh"

# 연쇄는 sweep과 같은 순서를 따른다 — sync 도중 생긴 harvest batch가 남은 sync보다 먼저 돈다.
rm -rf "$CHAIN_DATA/sync-auto" "$CHAIN_DATA/harvest-auto" "$CHAIN_DATA/harvest-queue"
mkdir -p "$CHAIN_DATA/harvest-queue/p-chain-2"
CHAIN_PRIO="$TEST_TMP/chain-prio.sh"
cat >"$CHAIN_PRIO" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$CHAIN_PRIO_OUT"
# 첫 실행 중에 chain-2의 harvest batch가 생긴다.
if [[ ! -f "$HARNESS_METRICS_DIR/harvest-queue/p-chain-2/analysis-batch.json" ]]; then
  jq -cn --arg ev "$CHAIN_PRIO_EV" '{project:"chain-2",batch_id:"b-prio",created_at:"2026-01-01T00:00:00Z",reasons:["errors"],event_files:[$ev]}' \
    >"$HARNESS_METRICS_DIR/harvest-queue/p-chain-2/analysis-batch.json"
fi
echo '{"type":"result","result":"AI_HARNESS_SYNC_RESULT outcome=no-change"}'
STUB
chmod +x "$CHAIN_PRIO"
jq -cn --arg cwd "$TEST_TMP/chain-2" '{kind:"session",src:"claude",sid:"prio",project:"chain-2",cwd:$cwd}' >"$CHAIN_DATA/events/prio.jsonl"
HARNESS_METRICS_DIR="$CHAIN_DATA" HM_SYNC_AUTO=1 HM_HARVEST_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=2 HM_HARVEST_AUTO_DAILY_MAX=9 \
  HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$CHAIN_PRIO" HM_HARVEST_AUTO_AGENT=claude HM_HARVEST_GLOBAL_DAYS=0 \
  HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" \
  CHAIN_PRIO_OUT="$TEST_TMP/chain-prio.out" CHAIN_PRIO_EV="$CHAIN_DATA/events/prio.jsonl" "$ROOT/scripts/harvest-auto.sh" sweep
assert_eq "sync,project,sync" "$(jq -sr '[.[] | select(.event=="started") | .scope] | join(",")' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "a harvest batch that appears mid-chain runs before the remaining syncs"
pass "auto sync chains runs within the daily cap (sweep order)"

finish_tests
