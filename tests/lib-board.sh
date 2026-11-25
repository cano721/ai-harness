#!/usr/bin/env bash
# Harness Board 테스트 영역(board·board-*)이 lib.sh 다음에 source하는 공용 준비: 가짜 claude·orca, 임시 데이터, 빈 포트와 board_sh.
# 영역 파일이 아니다(tests/run.sh가 lib-*.sh를 건너뛴다). 영역마다 자기 $TEST_TMP 아래에 새로 만든다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다

# Harness Board: 스킬이 필요할 때 띄우는 로컬 서버. 가짜 claude·orca와 임시 데이터·빈 포트로만 돌린다.
BOARD_T="$TEST_TMP/board"
BOARD_DATA="$BOARD_T/data"
mkdir -p "$BOARD_T/bin" "$BOARD_DATA" "$BOARD_T/projects/p"
BOARD_SID="11111111-2222-3333-4444-555555555555"
cat >"$BOARD_T/bin/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == agents ]]; then
  printf '[{"sessionId":"$BOARD_SID","id":"11111111","kind":"background","status":"idle","state":"running","pid":null,"cwd":"$BOARD_T","name":"board task","startedAt":%s000}]\n' "\$(date +%s)"
  exit 0
fi
exit 1
EOF
cat >"$BOARD_T/bin/orca" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"result":{"runs":[],"workers":[]}}'
EOF
chmod +x "$BOARD_T/bin/claude" "$BOARD_T/bin/orca"
# Timestamped now: work.sh drops an ended session older than BOARD_DONE_HOURS (48h), so a fixed date stops matching later.
BOARD_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -cn --arg t "$BOARD_TS" '{type:"user",message:{content:"hello board"},timestamp:$t},
  {type:"assistant",message:{content:[{type:"text",text:"done"}]},timestamp:$t}' >"$BOARD_T/projects/p/$BOARD_SID.jsonl"
mkdir -p "$BOARD_DATA/harvest-queue/p-svc" "$BOARD_DATA/harvest-auto"
jq -cn '{project:"svc", has_analysis_batch:true, created_at:"2026-11-07T09:00:00Z", counts:{sessions:10}, reasons:["sessions"], event_files:[]}' \
  >"$BOARD_DATA/harvest-queue/p-svc/analysis-batch.json"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -cn --arg at "$NOW_ISO" '{event:"started", project:"svc", scope:"repo", at:$at, log:"/nonexistent/run.log", repo:"/nonexistent/svc"},
  {event:"finished", project:"svc", scope:"repo", at:$at, log:"/nonexistent/run.log", result:"improved", artifact:"https://github.com/example/svc/pull/1"},
  {event:"skipped", project:"svc", batch:"sync-1", at:$at, reason:"sync_pr_status_unknown"},
  {event:"skipped", project:"svc", batch:"sync-1", at:$at, reason:"brand_new_code"}' \
  >"$BOARD_DATA/harvest-auto/runs.jsonl"
printf '# keep this comment\nHM_DIGEST=1\nOTHER_TOOL_SETTING=x\n' >"$BOARD_DATA/config"
chmod 600 "$BOARD_DATA/config"
BOARD_PORT_T="$(free_port)"
board_sh() {
  env PATH="$BOARD_T/bin:$PATH" ORCA_CLI_COMMAND=orca HARNESS_METRICS_DIR="$BOARD_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$BOARD_T/projects" \
    HARNESS_CLAUDE_SETTINGS="$BOARD_T/settings.json" BOARD_PORT="${BOARD_PORT_OVERRIDE:-$BOARD_PORT_T}" BOARD_NO_BROWSER=1 \
    BOARD_JIRA_URL= JIRA_BASE_URL= bash "$ROOT/scripts/board/board.sh" "$@"
}
