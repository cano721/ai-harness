#!/usr/bin/env bash
# 회귀 테스트 — 자동 sync 연쇄: 로그인 만료 분류·알림
# 실행: bash tests/run.sh automation-chain-auth
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-sync-chain.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-sync-chain.sh"
# 앞 sweep이 만들던 마커 디렉토리(이 영역은 앞 sweep 없이 시작한다).
mkdir -p "$CHAIN_DATA/sync-auto"

# 로그인 만료(#315): 인증 실패 결과 줄은 auth_expired로 분류하고, 실패 횟수에 넣지 않으며, 같은 sweep의 다음 실행을 잇지 않는다.
# 사람이 다시 로그인하기 전까지 반드시 실패하므로 MAX_FAILS 기회를 쓰지 않고, 남은 저장소를 같은 이유로 띄우지 않는다.
CHAIN_AUTH="$TEST_TMP/chain-auth.sh"
CHAIN_AUTH_LINE='{"type":"result","is_error":true,"terminal_reason":"api_error","result":"Failed to authenticate: this login reached its time limit and cannot be renewed. Run claude auth login, or use claude setup-token and set CLAUDE_CODE_OAUTH_TOKEN for unattended jobs"}'
# shellcheck disable=SC2016  # 스텁 본문의 $1은 스텁이 실행될 때 펼쳐진다
printf '#!/usr/bin/env bash\necho "$1" >>"%s"\necho %s\nexit 1\n' "$TEST_TMP/chain-auth.out" "'$CHAIN_AUTH_LINE'" >"$CHAIN_AUTH"
chmod +x "$CHAIN_AUTH"
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
chain_auth_notify() { HARNESS_METRICS_DIR="$CHAIN_DATA" "$ROOT/scripts/harvest-auto.sh" notify; }
CHAIN_CMD="$CHAIN_AUTH" HM_LLM_BACKOFF_HOURS=0 HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/chain-auth.out" | tr -d ' ')" "an expired login stops the sweep after the first run"
assert_eq "failed|auth_expired" "$(jq -sr '[.[] | select(.event=="finished")] | last | "\(.result)|\(.reason)"' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "an expired login is recorded as auth_expired"
CHAIN_AUTH_P="$(sed -n 1p "$TEST_TMP/chain-auth.out")"
assert_eq "failed|0" "$(jq -r '"\(.result)|\(.fails)"' "$CHAIN_DATA/sync-auto/p-$CHAIN_AUTH_P.json")" "an expired login does not count as a failure"
assert_eq "auth_expired" "$(jq -r '.components.sync_auto.last_error' "$CHAIN_DATA/health.json")" "health names the expired login"
for _ in 1 2 3; do CHAIN_CMD="$CHAIN_AUTH" HM_LLM_BACKOFF_HOURS=0 HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep; done
assert_eq "4|$CHAIN_AUTH_P|0" "$(wc -l <"$TEST_TMP/chain-auth.out" | tr -d ' ')|$(sort -u "$TEST_TMP/chain-auth.out")|$(jq -r '.fails' "$CHAIN_DATA/sync-auto/p-$CHAIN_AUTH_P.json")" "repeated expired logins never use up the retries"
CHAIN_AUTH_MSG="$(chain_auth_notify | jq -r '.systemMessage')"
assert_contains "$CHAIN_AUTH_MSG" "claude auth login" "session start says the login expired"
assert_contains "$CHAIN_AUTH_MSG" "claude setup-token" "and names the token for unattended runs"
assert_eq "" "$(chain_auth_notify)" "the notice is shown once per failure"
CHAIN_CMD="$CHAIN_AUTH" HM_LLM_BACKOFF_HOURS=0 HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
# 에이전트를 띄우지 않고 끝난 sync는 로그인이 풀렸다는 근거가 아니다.
jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at:$at,event:"finished",project:"chain-x",scope:"sync",result:"no-change",exit_code:0,no_agent:true}' >>"$CHAIN_DATA/harvest-auto/runs.jsonl"
assert_contains "$(chain_auth_notify | jq -r '.systemMessage')" "claude auth login" "a newer expired login is told again, even after a run that launched no agent"
assert_contains "$(<"$ROOT/scripts/session-start.sh")" 'harvest-auto.sh" notify' "session start asks for the expired-login notice"
# 과거 버전은 인증 실패를 agent_error로 세어 fails:3으로 포기했다. 로그가 인증 실패인 지난 실패는 횟수에서 빼 다시 후보가 된다.
# 로그가 인증 실패가 아닌 지난 실패는 그대로 센다.
CHAIN_PLUGIN="$(jq -r '.plugin' "$CHAIN_DATA/sync-auto/p-$CHAIN_AUTH_P.json")"
CHAIN_BATCH="$(printf '%s' "sync-$CHAIN_PLUGIN" | { shasum 2>/dev/null || sha1sum; } | cut -c1-12)"
printf '%s\n' "$CHAIN_AUTH_LINE" >"$TEST_TMP/chain-legacy-auth.log"
printf '%s\n' '{"type":"result","is_error":true,"result":"tool failed"}' >"$TEST_TMP/chain-legacy-other.log"
for CHAIN_N in 1 2 3; do
  jq -cn --arg p "$CHAIN_PLUGIN" '{plugin:$p,at:"2026-01-01T00:00:00Z",result:"failed",fails:3}' >"$CHAIN_DATA/sync-auto/p-chain-$CHAIN_N.json"
done
jq -cn --arg p "$CHAIN_PLUGIN" '{plugin:$p,at:"2026-01-01T00:00:00Z",result:"improved",fails:0}' >"$CHAIN_DATA/sync-auto/p-chain-1.json"
for _ in 1 2 3; do
  jq -cn --arg b "$CHAIN_BATCH" --arg l "$TEST_TMP/chain-legacy-auth.log" \
    '{at:"2026-01-01T00:00:00Z",event:"finished",project:"chain-2",batch:$b,scope:"sync",result:"failed",exit_code:1,reason:"agent_error",log:$l}' >>"$CHAIN_DATA/harvest-auto/runs.jsonl"
  jq -cn --arg b "$CHAIN_BATCH" --arg l "$TEST_TMP/chain-legacy-other.log" \
    '{at:"2026-01-01T00:00:00Z",event:"finished",project:"chain-3",batch:$b,scope:"sync",result:"failed",exit_code:1,reason:"agent_error",log:$l}' >>"$CHAIN_DATA/harvest-auto/runs.jsonl"
done
: >"$TEST_TMP/chain-stub.out"
HM_LLM_BACKOFF_HOURS=0 HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "chain-2" "$(cut -d'|' -f1 "$TEST_TMP/chain-stub.out" | sort -u | tr '\n' ' ' | sed 's/ $//')" "a target given up only for expired logins is tried again, others stay given up"
assert_eq "" "$(chain_auth_notify)" "a run that worked after the expired login clears the notice"
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
pass "an expired login is classified, not counted, stops the sweep and is told once"

finish_tests
