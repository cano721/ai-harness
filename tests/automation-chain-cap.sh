#!/usr/bin/env bash
# 회귀 테스트 — 자동 sync 연쇄: 하루 상한·사용량 한도
# 실행: bash tests/run.sh automation-chain-cap
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-sync-chain.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-sync-chain.sh"

# 실행이 끝나면 다음 sync 후보를 이어서 띄운다(동시 실행은 1개). sweep 주기(6시간)마다 1건씩이 아니다.
HM_SYNC_AUTO_DAILY_MAX=2 chain_sweep
assert_eq "2" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "one sweep chains sync runs up to the daily cap"
assert_eq "daily_max" "$(jq -sr 'last | .reason' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "the chain stops at the daily cap"
chain_sweep
assert_eq "3" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "default daily cap leaves room for the rest"
assert_contains "$(<"$ROOT/docs/configuration.md")" "HM_SYNC_AUTO_DAILY_MAX=6" "docs/configuration.md documents the new default cap"
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" 'HM_SYNC_AUTO_DAILY_MAX:-6}' "code default cap is 6"
# 사용량 한도로 끝난 실행 뒤에는 잇지 않는다.
CHAIN_LIMIT="$TEST_TMP/chain-limit.sh"
# shellcheck disable=SC2016  # 스텁 본문의 $1은 스텁이 실행될 때 펼쳐진다
printf '#!/usr/bin/env bash\necho "$1" >>"%s"\necho %s\nexit 1\n' "$TEST_TMP/chain-limit.out" \
  "'{\"type\":\"result\",\"is_error\":true,\"api_error_status\":429,\"api_error\":\"usage_limit_reached\"}'" >"$CHAIN_LIMIT"
chmod +x "$CHAIN_LIMIT"
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
HARNESS_METRICS_DIR="$CHAIN_DATA" HM_SYNC_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=99 HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$CHAIN_LIMIT" \
  HM_HARVEST_AUTO_AGENT=claude HM_HARVEST_GLOBAL_DAYS=0 HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" \
  HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" "$ROOT/scripts/harvest-auto.sh" sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/chain-limit.out" | tr -d ' ')" "a usage-limited run does not chain the next one"
pass "auto sync chains runs within the daily cap (daily cap and usage limit)"

finish_tests
