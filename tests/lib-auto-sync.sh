#!/usr/bin/env bash
# 자동 sync 영역(tests/automation-sync*.sh)이 source하는 공용 준비: harness가 깔린 저장소들, sync 에이전트 스텁과 sweep·기록 읽기 함수,
# 옛 sync PR 대체를 보는 PR 호스트 스텁 경로와 sweep. tests/lib.sh 다음에 source한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
SYNC_DATA="$TEST_TMP/sync-data"
SYNC_PLUGIN="$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json")"
SYNC_ORIGIN="$TEST_TMP/sync-origin.git"
SYNC_REPO="$TEST_TMP/sync-repo"
SYNC_CUR="$TEST_TMP/sync-current"
SYNC_MIN="$TEST_TMP/sync-minimal"
SYNC_PLAIN="$TEST_TMP/sync-plain"
git init -q --bare "$SYNC_ORIGIN"
make_repo "$SYNC_REPO" "$SYNC_ORIGIN"
git -C "$SYNC_REPO" branch -M master
git -C "$SYNC_REPO" push -q origin master
git -C "$SYNC_REPO" checkout -q -b develop
mkdir -p "$SYNC_REPO/.ai-harness"
jq -n '{project_id:"sync-svc",harness_version:"0.1.0",level:"standard",integrations:["claude"]}' >"$SYNC_REPO/.ai-harness/harness.json"
git -C "$SYNC_REPO" add .ai-harness && git -C "$SYNC_REPO" commit -q -m harness
git -C "$SYNC_REPO" push -q origin develop
git -C "$SYNC_REPO" remote set-head origin master
make_repo "$SYNC_CUR"
mkdir -p "$SYNC_CUR/.ai-harness"
jq -n --arg v "$SYNC_PLUGIN" '{project_id:"sync-cur",harness_version:$v}' >"$SYNC_CUR/.ai-harness/harness.json"
git -C "$SYNC_CUR" add .ai-harness && git -C "$SYNC_CUR" commit -q -m harness
make_repo "$SYNC_MIN"
mkdir -p "$SYNC_MIN/.ai-harness"
jq -n '{project_id:"sync-min",harness_version:"0.1.0",level:"minimal",integrations:["claude"]}' >"$SYNC_MIN/.ai-harness/harness.json"
printf '%s\n' '<!doctype html><title>report</title>' >"$SYNC_MIN/report.html"
git -C "$SYNC_MIN" add .ai-harness report.html && git -C "$SYNC_MIN" commit -q -m harness
make_repo "$SYNC_PLAIN"
sync_cmd() { HARNESS_METRICS_DIR="$SYNC_DATA" "$ROOT/scripts/sync-auto.sh" "$@"; }
SYNC_REPO_REAL="$(cd "$SYNC_REPO" && pwd -P)"
SYNC_STUB="$TEST_TMP/sync-stub.sh"
cat >"$SYNC_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "${HM_HARVEST_RUNNING:-}" "$(pwd -P)" >>"$SYNC_STUB_OUT"
echo '{"type":"result","total_cost_usd":0.2,"result":"done\nAI_HARNESS_SYNC_RESULT outcome='"${SYNC_STUB_OUTCOME:-improved}"' artifact=https://example.com/pr/'"${SYNC_STUB_PR:-9}"'"}'
STUB
chmod +x "$SYNC_STUB"
sync_sweep() {
  HARNESS_METRICS_DIR="$SYNC_DATA" HM_HARVEST_AUTO_FOREGROUND=1 HM_HARVEST_AUTO_CMD="$SYNC_STUB" HM_HARVEST_AUTO_AGENT=claude \
    HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/chain-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/chain-codex" \
    HM_HARVEST_GLOBAL_DAYS=0 SYNC_STUB_OUT="$TEST_TMP/sync-stub.out" "$ROOT/scripts/harvest-auto.sh" sweep
}
sync_runs() { jq -sr "$1" "$SYNC_DATA/harvest-auto/runs.jsonl"; }
prs_sweep() { # 이전 플러그인 버전으로 끝난 것처럼 마커를 되돌린 뒤 sweep
  jq -cn '{plugin:"0.0.1",result:"partial",fails:0}' >"$SYNC_DATA/sync-auto/p-sync-svc.json"
  HM_SYNC_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=99 HM_OPEN_PR_CMD="$PRS_STUB_DIR/pr" sync_sweep
}
# 옛 sync PR 대체 영역의 앞단: automation-sync 첫 블록이 남기던 상태(세션 기록에 잡힌 저장소, 자동 sync가 연 PR 9와 버전 마커)를 다시 만든다.
sync_prime() {
  mkdir -p "$SYNC_DATA/events" "$SYNC_REPO/sub"
  jq -cn --arg a "$SYNC_REPO/sub" '{kind:"session",cwd:$a}' >"$SYNC_DATA/events/sync.jsonl"
  HM_SYNC_AUTO=1 sync_sweep
  [[ "$(jq -r '.result' "$SYNC_DATA/sync-auto/p-sync-svc.json" 2>/dev/null)" == improved ]] || fail "sync_prime: the first auto sync did not finish"
}
