#!/usr/bin/env bash
# 회귀 테스트 — 자동 sync 연쇄: 사용자 활동·결과·마커·실행 기록 가드
# 실행: bash tests/run.sh automation-chain-guard
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-sync-chain.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-sync-chain.sh"
# 앞 sweep이 만들던 마커 디렉토리(이 영역은 앞 sweep 없이 시작한다).
mkdir -p "$CHAIN_DATA/sync-auto"
# 원래 순서에서 이 블록은 automation-chain-cap의 사용량 한도 실행 직후, 그 휴지(HM_LLM_BACKOFF_HOURS 기본 5시간) 안에서 돈다.
# 그 실행이 남기는 finished·usage_limit 기록을 둬 같은 상태에서 시작한다.
mkdir -p "$CHAIN_DATA/harvest-auto"
jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at:$at,event:"finished",project:"chain-1",scope:"sync",result:"failed",exit_code:1,reason:"usage_limit"}' >>"$CHAIN_DATA/harvest-auto/runs.jsonl"

# 사용자가 다시 작업 중이면 잇지 않는다 — 다음 sweep(유휴 대기 포함)이 이어받는다.
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
: >"$TEST_TMP/chain-stub.out"
mkdir -p "$TEST_TMP/chain-claude/-Users-me-work" && : >"$TEST_TMP/chain-claude/-Users-me-work/live.jsonl"
HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "chain stops while the user is active"
find "$TEST_TMP/chain-claude/-Users-me-work" -depth -delete
# 결과 줄이 알려진 값이 아니면 left_for_user로 기록한다(실패 횟수 없는 failed로 무한 재시도하지 않게).
CHAIN_ODD="$TEST_TMP/chain-odd.sh"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"type\":\"result\",\"result\":\"AI_HARNESS_SYNC_RESULT outcome=failed\"}'" >"$CHAIN_ODD"
chmod +x "$CHAIN_ODD"
find "$CHAIN_DATA/sync-auto" -name '*.json' -delete
CHAIN_CMD="$CHAIN_ODD" HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "left_for_user" "$(jq -r '.result' "$CHAIN_DATA/sync-auto/p-chain-1.json")" "unknown outcome is left for the user"
# 마커를 쓸 수 없으면 띄우지 않는다 — 같은 저장소를 끝없이 다시 띄우지 않게.
find "$CHAIN_DATA/sync-auto" -depth -delete && : >"$CHAIN_DATA/sync-auto"
: >"$TEST_TMP/chain-stub.out"
HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
assert_eq "0" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "unwritable marker launches nothing"
find "$CHAIN_DATA/sync-auto" -delete
# 깨진 실행 기록 한 줄이 오늘 집계를 0으로 만들어 상한을 풀지 않는다(오늘 started 1건 + 깨진 줄, 상한 1).
rm -rf "$CHAIN_DATA/sync-auto" "$CHAIN_DATA/harvest-auto/runs.jsonl"
mkdir -p "$CHAIN_DATA/harvest-auto"
jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at:$at,event:"started",project:"x",scope:"sync"}' >"$CHAIN_DATA/harvest-auto/runs.jsonl"
printf '{broken\n' >>"$CHAIN_DATA/harvest-auto/runs.jsonl"
HM_SYNC_AUTO_DAILY_MAX=1 chain_sweep
assert_eq "0|daily_max" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')|$(jq -Rrn '[inputs | fromjson?] | last | .reason' "$CHAIN_DATA/harvest-auto/runs.jsonl")" "a broken run-log line does not reset the daily cap"
HM_SYNC_AUTO_DAILY_MAX=2 chain_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')" "a broken run-log line does not block launches under the cap"
# 실행 기록을 읽을 수 없으면 상한을 닫고 사유를 구분해 남긴다.
if [[ "$(id -u)" == 0 ]]; then
  printf '# skip: unreadable run-log test needs a non-root user\n'
else
  chmod 000 "$CHAIN_DATA/harvest-auto/runs.jsonl"
  HM_SYNC_AUTO_DAILY_MAX=99 chain_sweep
  chmod 600 "$CHAIN_DATA/harvest-auto/runs.jsonl"
  assert_eq "1|runs_unreadable" "$(wc -l <"$TEST_TMP/chain-stub.out" | tr -d ' ')|$(jq -r '.components.sync_auto.last_error' "$CHAIN_DATA/health.json")" "unreadable run log closes the cap with its own reason"
fi
pass "auto sync chains runs within the daily cap (activity, outcome, marker and run-log guards)"

finish_tests
