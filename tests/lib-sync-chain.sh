#!/usr/bin/env bash
# 자동 sync 연쇄 영역(tests/automation-chain-*.sh)이 source하는 공용 준비: sync 에이전트 스텁, harness가 깔린 저장소 셋과 그 세션 이벤트, sweep 함수.
# tests/lib.sh 다음에 source한다. 단독 실행하지 않는다. scripts/harvest-auto.sh sweep이 저장소마다 sync 계획을 세워 느리므로 영역을 나눠 병렬로 돈다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
SYNC_STUB="$TEST_TMP/sync-stub.sh"
cat >"$SYNC_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "${HM_HARVEST_RUNNING:-}" "$(pwd -P)" >>"$SYNC_STUB_OUT"
echo '{"type":"result","total_cost_usd":0.2,"result":"done\nAI_HARNESS_SYNC_RESULT outcome='"${SYNC_STUB_OUTCOME:-improved}"' artifact=https://example.com/pr/'"${SYNC_STUB_PR:-9}"'"}'
STUB
chmod +x "$SYNC_STUB"
CHAIN_DATA="$TEST_TMP/chain-data"
mkdir -p "$CHAIN_DATA/events" "$TEST_TMP/chain-claude" "$TEST_TMP/chain-codex"
for CHAIN_N in 1 2 3; do
  make_repo "$TEST_TMP/chain-$CHAIN_N"
  mkdir -p "$TEST_TMP/chain-$CHAIN_N/.ai-harness"
  jq -n --arg p "chain-$CHAIN_N" '{project_id:$p,harness_version:"0.1.0",level:"standard",integrations:["claude"]}' \
    >"$TEST_TMP/chain-$CHAIN_N/.ai-harness/harness.json"
  git -C "$TEST_TMP/chain-$CHAIN_N" add .ai-harness && git -C "$TEST_TMP/chain-$CHAIN_N" commit -q -m harness
  jq -cn --arg a "$TEST_TMP/chain-$CHAIN_N" '{kind:"session",cwd:$a}' >>"$CHAIN_DATA/events/chain.jsonl"
done
chain_sweep() {
  HARNESS_METRICS_DIR="$CHAIN_DATA" HM_SYNC_AUTO=1 HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="${CHAIN_CMD:-$SYNC_STUB}" HM_HARVEST_AUTO_AGENT=claude \
    HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" \
    HM_HARVEST_GLOBAL_DAYS=0 SYNC_STUB_OUT="$TEST_TMP/chain-stub.out" "$ROOT/scripts/harvest-auto.sh" sweep
}
