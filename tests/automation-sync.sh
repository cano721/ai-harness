#!/usr/bin/env bash
# 회귀 테스트 — 자동 sync: 버전 알림·opt-in 자동 sync·옛 sync PR 대체
# 실행: bash tests/run.sh automation-sync
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"


# 하네스 생성물 버전 차이: SessionStart 알림과 opt-in 자동 sync (#137)
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

SYNC_OUT="$(sync_cmd outdated --root "$SYNC_REPO" --root "$SYNC_CUR" --root "$SYNC_PLAIN")"
assert_eq "1" "$(jq -s 'length' <<<"$SYNC_OUT")" "only the repo behind the plugin is outdated"
assert_eq "$SYNC_REPO_REAL|sync-svc|origin/develop|0.1.0|$SYNC_PLUGIN" \
  "$(jq -r '"\(.repo)|\(.project)|\(.base)|\(.version)|\(.plugin)"' <<<"$SYNC_OUT")" "outdated row names repo, base and versions"
# 버전은 harness가 실제로 들어 있는 기준 브랜치에서 읽는다 — 사용자 체크아웃이 어디에 있든.
git -C "$SYNC_REPO" checkout -q master
assert_eq "0.1.0" "$(sync_cmd outdated --root "$SYNC_REPO" | jq -r '.version')" "version comes from the base branch, not the checkout"
git -C "$SYNC_REPO" checkout -q develop

# 루트를 주지 않으면 수집된 세션 기록의 작업 경로에서 찾는다. 같은 저장소의 worktree는 하나로 접는다.
git -C "$SYNC_REPO" worktree add -q -b sync-wt "$TEST_TMP/sync-repo-wt"
mkdir -p "$SYNC_DATA/events" "$SYNC_REPO/sub"
jq -cn --arg a "$SYNC_REPO/sub" --arg b "$TEST_TMP/sync-repo-wt" --arg c "$SYNC_PLAIN" --arg d "$TEST_TMP/gone" \
  '{kind:"session",cwd:$a},{kind:"session",cwd:$b},{kind:"session",cwd:$c},{kind:"session",cwd:$d}' >"$SYNC_DATA/events/sync.jsonl"
assert_eq "$SYNC_REPO_REAL" "$(sync_cmd outdated | jq -sr 'map(.repo) | join(",")')" "discovery dedupes worktrees to the main checkout"
# 같은 저장소의 별도 clone(또는 NFC·NFD로 갈라진 한글 경로)은 프로젝트 ID로 접는다 — 같은 sync PR이 두 번 열리지 않게.
git clone -q "$SYNC_ORIGIN" "$TEST_TMP/sync-repo-clone" 2>/dev/null
git -C "$TEST_TMP/sync-repo-clone" checkout -q develop
jq -cn --arg a "$TEST_TMP/sync-repo-clone" '{kind:"session",cwd:$a}' >>"$SYNC_DATA/events/sync.jsonl"
assert_eq "1" "$(sync_cmd outdated | jq -s 'map(select(.project=="sync-svc")) | length')" "separate clones of one project yield one row"

# 알림: 저장소·플러그인 버전 조합당 한 번. 자동 sync가 꺼져 있으면 수동 명령과 켜는 법을 안내한다.
sync_notify() { printf '{"cwd":"%s"}' "$1" | sync_cmd notify; }
SYNC_MSG="$(sync_notify "$SYNC_REPO/sub" | jq -r '.systemMessage // empty')"
assert_contains "$SYNC_MSG" "0.1.0" "notice names the repo harness version"
assert_contains "$SYNC_MSG" "/harness-init --sync" "notice names the sync command"
assert_contains "$SYNC_MSG" "HM_SYNC_AUTO=1" "notice explains how to turn on auto sync"
assert_eq "" "$(sync_notify "$SYNC_REPO")" "notice is shown once per repo and plugin version"
assert_eq "" "$(sync_notify "$SYNC_CUR")" "no notice for a current harness"
assert_eq "" "$(sync_notify "$SYNC_PLAIN")" "no notice without a harness"
HM_SYNC_AUTO=1 sync_notify "$SYNC_MIN" >"$TEST_TMP/sync-notice-auto"
assert_contains "$(jq -r '.systemMessage' "$TEST_TMP/sync-notice-auto")" "draft PR" "auto mode says a draft PR will follow"
SYNC_WS="$TEST_TMP/sync-ws"
mkdir -p "$SYNC_WS/.ai-harness"
jq -n '{kind:"workspace",workspace_id:"ws",harness_version:"0.1.0",members:[]}' >"$SYNC_WS/.ai-harness/workspace.json"
assert_contains "$(sync_notify "$SYNC_WS" | jq -r '.systemMessage')" "workspace" "workspace manifest behind the plugin is noticed"
assert_contains "$(<"$ROOT/scripts/session-start.sh")" "sync-auto.sh" "SessionStart runs the sync notice"

# 자동 sync: opt-in, 작업 전용 worktree에서 headless sync, 결과·버전 마커 기록, 버전당 1회.
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
sync_sweep
assert_not_file "$SYNC_DATA/harvest-auto/runs.jsonl"
HM_SYNC_AUTO=1 sync_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "auto sync launches one headless run"
SYNC_RUN_LINE="$(sed -n 1p "$TEST_TMP/sync-stub.out")"
assert_eq "sync-svc|1" "${SYNC_RUN_LINE%|*}" "sync run gets project and recursion guard"
assert_contains "${SYNC_RUN_LINE##*|}" "/auto-worktrees/" "sync runs in a dedicated worktree"
[[ "${SYNC_RUN_LINE##*|}" != "$SYNC_DATA"/* ]] || fail "the sync work tree must be outside the data directory"
assert_eq "develop" "$(git -C "$SYNC_REPO" branch --show-current)" "user checkout is untouched"
assert_eq "1" "$(git -C "$SYNC_REPO" worktree list | grep -vc sync-repo-wt | tr -d ' ')" "sync worktree is removed"
assert_eq "sync|improved|https://example.com/pr/9|0.2" \
  "$(sync_runs '[.[] | select(.event=="finished")] | last | "\(.scope)|\(.result)|\(.artifact)|\(.cost_usd)"')" "sync outcome and PR recorded"
assert_eq "$SYNC_PLUGIN|improved" "$(jq -r '"\(.plugin)|\(.result)"' "$SYNC_DATA/sync-auto/p-sync-svc.json")" "sync marker keeps the plugin version"
HM_SYNC_AUTO=1 sync_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "same plugin version is synced once"

# 적용할 관리 생성물이 없으면 에이전트를 띄우지 않는다(LLM 비용 0).
jq -cn --arg a "$SYNC_MIN" '{kind:"session",cwd:$a}' >>"$SYNC_DATA/events/sync.jsonl"
HM_SYNC_AUTO=1 sync_sweep
assert_eq "1" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "no-op sync skips the agent"
assert_eq "no-change" "$(jq -r '.result' "$SYNC_DATA/sync-auto/p-sync-min.json")" "no-op sync is recorded as no-change"
assert_contains "$(grep -rh '켤 수 있는 stack' "$SYNC_DATA/harvest-auto/logs" 2>/dev/null)" "켤 수 있는 stack: ui (근거: report.html)" "no-op auto sync logs the stacks it could enable"

# 자동 harvest와 별개인 하루 상한.
jq '.result = "failed" | .fails = 1' "$SYNC_DATA/sync-auto/p-sync-svc.json" >"$TEST_TMP/sync-marker" \
  && mv "$TEST_TMP/sync-marker" "$SYNC_DATA/sync-auto/p-sync-svc.json"
HM_SYNC_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=1 sync_sweep
assert_eq "daily_max" "$(sync_runs 'last | .reason')" "sync daily cap"
HM_SYNC_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=5 sync_sweep
assert_eq "2" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "failed sync is retried"
# shellcheck disable=SC2016
assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" '--sync --apply --auto --base $base' "agent is told to sync unattended"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "AI_HARNESS_SYNC_RESULT" "harness-init reports the unattended result"
assert_contains "$(<"$ROOT/scripts/backfill-due.sh")" "HM_SYNC_AUTO" "scheduled run includes auto sync"
# 에이전트를 띄우지 않은 no-op sync는 하루 상한에서 빠진다(started 2건 중 1건이 no_agent).
assert_eq "true" "$(sync_runs '[.[] | select(.event=="finished" and .result=="no-change")] | last | .no_agent')" "no-op sync is marked no_agent"
# 실행 lock을 못 잡아도 실패 횟수는 보존된다.
mkdir -p "$SYNC_DATA/harvest-auto/running.lock" && printf '%s\n' "$$" >"$SYNC_DATA/harvest-auto/running.lock/pid"
jq -cn --arg p "$SYNC_PLUGIN" '{plugin:$p,result:"launched",fails:2}' >"$SYNC_DATA/sync-auto/p-sync-svc.json"
HARNESS_METRICS_DIR="$SYNC_DATA" HM_HARVEST_AUTO_CMD="$SYNC_STUB" "$ROOT/scripts/harvest-auto.sh" run sync-svc "sync-$SYNC_PLUGIN" "$SYNC_REPO" claude sync
assert_eq "failed|2" "$(jq -r '"\(.result)|\(.fails)"' "$SYNC_DATA/sync-auto/p-sync-svc.json")" "busy sync keeps the failure count"
find "$SYNC_DATA/harvest-auto/running.lock" -depth -delete
# 무인 에이전트는 origin 형태의 force push·+refspec도 금지된다.
for SYNC_DENY in 'git push origin --force*' 'git push origin +*' 'git push -u origin -f*'; do
  assert_contains "$(<"$ROOT/scripts/harvest-auto.sh")" "\"Bash($SYNC_DENY)\"" "unattended agent cannot $SYNC_DENY"
done
# 저장소가 정한 base_branch는 브랜치 이름 형태만 받는다(무인 에이전트 지시문까지 가는 값).
jq '.base_branch = "--upload-pack=x"' "$SYNC_REPO/.ai-harness/harness.json" >"$TEST_TMP/sync-hj" && mv "$TEST_TMP/sync-hj" "$SYNC_REPO/.ai-harness/harness.json"
assert_eq "origin/develop" "$(HARNESS_METRICS_DIR="$SYNC_DATA" bash -c 'source "$1/scripts/lib.sh"; hm_resolve_base "$2" --no-fetch' _ "$ROOT" "$SYNC_REPO")" "invalid base_branch is ignored"
git -C "$SYNC_REPO" checkout -q -- .ai-harness/harness.json
# 알림은 체크아웃이 아니라 기준 브랜치 ref를 본다 — 하네스 없는 브랜치에 있어도 같은 판정.
git -C "$SYNC_REPO" checkout -q master
SYNC_DATA2="$TEST_TMP/sync-data2"
assert_contains "$(printf '{"cwd":"%s"}' "$SYNC_REPO" | HARNESS_METRICS_DIR="$SYNC_DATA2" "$ROOT/scripts/sync-auto.sh" notify | jq -r '.systemMessage')" "0.1.0" "notice reads the base branch, not the checkout"
git -C "$SYNC_REPO" checkout -q develop
pass "harness version notice and opt-in auto sync"

# 일부 적용이면 harness_version이 그대로라 다음 버전 sync가 같은 파일로 새 PR을 열고 옛 PR이 쌓였다.
# 새 PR이 열리면 아무도 손대지 않은 옛 sync PR을 닫고, 사람이 리뷰 중이면 새 sync를 띄우지 않는다.
export PRS_STUB_DIR="$TEST_TMP/pr-stub"
mkdir -p "$PRS_STUB_DIR"
cat >"$PRS_STUB_DIR/pr" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --status) id="${2##*/}"; [[ -z "${PRS_STUB_NOCREDS:-}" ]] || exit 4; [[ ! -f "$PRS_STUB_DIR/down" ]] || exit 5; cat "$PRS_STUB_DIR/state-$id.json" 2>/dev/null || echo '{"state":"open","activity":0}' ;;
  --decline) printf '%s|%s\n' "$2" "$4" >>"$PRS_STUB_DIR/declined" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$PRS_STUB_DIR/pr"
prs_sweep() { # 이전 플러그인 버전으로 끝난 것처럼 마커를 되돌린 뒤 sweep
  jq -cn '{plugin:"0.0.1",result:"partial",fails:0}' >"$SYNC_DATA/sync-auto/p-sync-svc.json"
  HM_SYNC_AUTO=1 HM_SYNC_AUTO_DAILY_MAX=99 HM_OPEN_PR_CMD="$PRS_STUB_DIR/pr" sync_sweep
}
PRS_LAUNCHED="$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')"
SYNC_STUB_PR=10 SYNC_STUB_OUTCOME=partial prs_sweep
assert_eq "$((PRS_LAUNCHED + 1))" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "a newer plugin version runs sync again"
assert_eq "https://example.com/pr/9" "$(cut -d'|' -f1 "$PRS_STUB_DIR/declined")" "the untouched older sync PR is declined"
assert_contains "$(cut -d'|' -f2 "$PRS_STUB_DIR/declined")" "https://example.com/pr/10" "decline comment links the new PR"
assert_eq "https://example.com/pr/9|https://example.com/pr/10" \
  "$(sync_runs '[.[] | select(.event=="superseded")] | last | "\(.artifact)|\(.by)"')" "superseded PR is recorded"
# 이미 닫힌 PR과 새 PR 자신은 닫지 않는다.
printf '%s\n' '{"state":"closed","activity":0}' >"$PRS_STUB_DIR/state-9.json"
SYNC_STUB_PR=11 prs_sweep
assert_eq "https://example.com/pr/10" "$(sed -n 2p "$PRS_STUB_DIR/declined" | cut -d'|' -f1)" "only open older PRs are declined"
assert_eq "2" "$(wc -l <"$PRS_STUB_DIR/declined" | tr -d ' ')" "closed PRs and the new PR itself are left alone"
# 사람이 코멘트·리뷰·승인을 남긴 옛 PR이 열려 있으면 새 sync를 띄우지 않는다.
printf '%s\n' '{"state":"open","activity":2}' >"$PRS_STUB_DIR/state-11.json"
PRS_LAUNCHED="$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')"
SYNC_STUB_PR=12 prs_sweep
assert_eq "$PRS_LAUNCHED" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "sync waits while a person reviews the older sync PR"
assert_eq "sync_pr_in_review" "$(sync_runs 'last | .reason')" "the skip names the reason"
assert_eq "2" "$(wc -l <"$PRS_STUB_DIR/declined" | tr -d ' ')" "a reviewed PR is never declined"
# PR 상태를 못 읽으면 판정하지 않고 기다린다 — 그대로 띄우면 PR이 다시 쌓인다.
rm -f "$PRS_STUB_DIR/state-11.json" && : >"$PRS_STUB_DIR/down"
SYNC_STUB_PR=12 prs_sweep
assert_eq "$PRS_LAUNCHED" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "unknown PR state holds the sync"
assert_eq "sync_pr_status_unknown" "$(sync_runs 'last | .reason')" "the hold names the reason"
rm -f "$PRS_STUB_DIR/down"
# 자격증명이 끝내 없어(open-pr.sh 종료 코드 4) 못 읽은 것은 로그인 풀림과 다른 이유로 남긴다(#299) — 보드가 원인과 고칠 곳을 가른다.
SYNC_STUB_PR=12 PRS_STUB_NOCREDS=1 prs_sweep
assert_eq "$PRS_LAUNCHED" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "missing PR host credentials still hold the sync"
assert_eq "sync_pr_no_credentials" "$(sync_runs 'last | .reason')" "the hold says the credentials are missing"
# 지원하지 않는 호스트의 PR은 읽을 수 없을 뿐 일시 장애가 아니다 — 막지 않는다(위 sync 테스트의 example.com PR이 그 경우).
# 새 PR이 열려 있지 않으면(에이전트가 적은 URL이 틀림) 옛 PR을 닫지 않는다. 다른 저장소의 PR도 닫지 않는다.
printf '%s\n' '{"state":"closed","activity":0}' >"$PRS_STUB_DIR/state-13.json"
SYNC_STUB_PR=13 prs_sweep
assert_eq "2" "$(wc -l <"$PRS_STUB_DIR/declined" | tr -d ' ')" "nothing is declined when the new PR is not open"
jq -cn '{at:"2026-01-01T00:00:00Z",event:"finished",project:"sync-svc",scope:"sync",result:"partial",artifact:"https://other.example/pr/7"}' >>"$SYNC_DATA/harvest-auto/runs.jsonl"
rm -f "$PRS_STUB_DIR/state-13.json"
SYNC_STUB_PR=14 prs_sweep
assert_contains "$(cat "$PRS_STUB_DIR/declined")" "https://example.com/pr/13" "the latest untouched PR of the same repo is declined"
if grep -q other.example "$PRS_STUB_DIR/declined"; then fail "a PR of another repo with the same project id is left alone"; fi
# activity: GitHub는 봇의 코멘트·리뷰를 세지 않고, Bitbucket은 코멘트 수 + 승인·변경 요청 참여자를 센다.
PRS_BIN="$TEST_TMP/pr-bin"
mkdir -p "$PRS_BIN"
cat >"$PRS_BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null,"comments":[{"author":{"login":"ci-preview[bot]"}},{"author":{"login":"alice"}}],"reviews":[{"author":{"login":"github-actions"}}]}'
STUB
cat >"$PRS_BIN/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n200' '{"state":"OPEN","comment_count":1,"participants":[{"approved":false,"state":null},{"approved":true,"state":"approved"},{"approved":false,"state":"changes_requested"}]}'
STUB
chmod +x "$PRS_BIN/gh" "$PRS_BIN/curl"
assert_eq "open|1" "$(PATH="$PRS_BIN:$PATH" "$ROOT/scripts/open-pr.sh" --status https://github.com/acme/svc/pull/3 | jq -r '"\(.state)|\(.activity)"')" "GitHub activity ignores bots"
assert_eq "open|3" "$(PATH="$PRS_BIN:$PATH" ATLASSIAN_USER=u BITBUCKET_API_TOKEN=t "$ROOT/scripts/open-pr.sh" --status https://bitbucket.org/ws/repo/pull-requests/4 | jq -r '"\(.state)|\(.activity)"')" "Bitbucket activity counts comments and reviewing participants"
# 무인 실행(launchd)에는 셸 환경변수가 없다. Claude Code settings.json env에 둔 Bitbucket 자격증명으로 조회한다(#299).
mkdir -p "$TEST_TMP/prs-settings-bin"
cat >"$TEST_TMP/prs-settings-bin/curl" <<'STUB'
#!/usr/bin/env bash
cat >"$PRS_CURL_CFG"
printf '%s\n200' '{"state":"OPEN","comment_count":0,"participants":[]}'
STUB
chmod +x "$TEST_TMP/prs-settings-bin/curl"
jq -cn '{env: {ATLASSIAN_USER: "bot@example.com", BITBUCKET_API_TOKEN: "settings-token"}}' >"$TEST_TMP/prs-settings.json"
assert_eq "open" "$(env -u ATLASSIAN_USER -u BITBUCKET_API_TOKEN PATH="$TEST_TMP/prs-settings-bin:$PATH" PRS_CURL_CFG="$TEST_TMP/prs-curl.cfg" \
  HARNESS_CLAUDE_SETTINGS="$TEST_TMP/prs-settings.json" "$ROOT/scripts/open-pr.sh" --status https://bitbucket.org/ws/repo/pull-requests/4 | jq -r '.state')" \
  "Bitbucket status reads credentials from Claude settings env when the shell has none"
assert_eq 'user = "bot@example.com:settings-token"' "$(cat "$TEST_TMP/prs-curl.cfg")" "the settings credentials go to curl on stdin"
assert_eq 'user = "u:t"' "$(env PATH="$TEST_TMP/prs-settings-bin:$PATH" PRS_CURL_CFG="$TEST_TMP/prs-curl.cfg" ATLASSIAN_USER=u BITBUCKET_API_TOKEN=t \
  HARNESS_CLAUDE_SETTINGS="$TEST_TMP/prs-settings.json" "$ROOT/scripts/open-pr.sh" --status https://bitbucket.org/ws/repo/pull-requests/4 >/dev/null; cat "$TEST_TMP/prs-curl.cfg")" \
  "shell environment credentials win over Claude settings"
# PR 호스트 요청 형태(dry-run): GitHub close, Bitbucket decline + 메시지.
assert_eq "github|https://github.com/acme/svc/pull/3|x" \
  "$(HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --decline https://github.com/acme/svc/pull/3 --comment x | jq -r '"\(.provider)|\(.decline)|\(.comment)"')" "GitHub decline request"
assert_eq "bitbucket|x" \
  "$(HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --decline https://bitbucket.org/ws/repo/pull-requests/4 --comment x | jq -r '"\(.provider)|\(.message)"')" "Bitbucket decline request"
if HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --decline https://example.com/pr/1 >/dev/null 2>&1; then fail "unknown PR hosts are refused"; fi
pass "auto sync supersedes its own older PRs"

# 세션에서 사람이 직접 연 sync PR은 runs.jsonl에 기록되지 않아, 새 sync PR이 열려도 열린 채 남았다(#474).
# 원격의 열린 PR 중 브랜치 이름이 harness-sync-<버전>으로 끝나는 것도 같은 규칙(같은 저장소·열림·사람 활동 0)으로
# 정리하고, 사람이 리뷰 중이면 새 sync를 띄우지 않는다. 새 PR보다 나중에 열린 PR은 옛 PR이 아니다.
cat >"$PRS_STUB_DIR/pr" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --status) id="${2##*/}"; cat "$PRS_STUB_DIR/state-$id.json" 2>/dev/null || echo '{"state":"open","activity":0}' ;;
  --decline) printf '%s|%s\n' "$2" "$4" >>"$PRS_STUB_DIR/declined" ;;
  --list-open) printf '%s\n' "${2:-}" >>"$PRS_STUB_DIR/listed"; cat "$PRS_STUB_DIR/open.jsonl" 2>/dev/null ;;
  *) exit 2 ;;
esac
STUB
: >"$PRS_STUB_DIR/declined"
printf '%s\n' '{"state":"open","activity":0,"created":"2026-06-01T00:00:00"}' >"$PRS_STUB_DIR/state-15.json"
printf '%s\n' '{"state":"open","activity":0,"created":"2026-05-01T00:00:00"}' >"$PRS_STUB_DIR/state-60.json"
printf '%s\n' '{"state":"open","activity":0,"created":"2026-07-01T00:00:00"}' >"$PRS_STUB_DIR/state-61.json"
cat >"$PRS_STUB_DIR/open.jsonl" <<'JSONL'
{"url":"https://example.com/pr/60","head":"feature/EX-1-harness-sync-0.69.0"}
{"url":"https://example.com/pr/61","head":"feature/EX-2-harness-sync-9.9.9"}
{"url":"https://example.com/pr/62","head":"feature/EX-3-login"}
{"url":"https://other.example/pr/63","head":"chore/harness-sync-0.69.0"}
{"url":"https://example.com/pr/15","head":"chore/harness-sync-1.0.0"}
JSONL
SYNC_STUB_PR=15 prs_sweep
assert_contains "$(cat "$PRS_STUB_DIR/declined")" "https://example.com/pr/60|" "an untouched sync PR opened in a session is declined"
assert_eq "https://example.com/pr/60|https://example.com/pr/15" \
  "$(sync_runs '[.[] | select(.event=="superseded")] | last | "\(.artifact)|\(.by)"')" "the session sync PR is recorded as superseded"
assert_contains "$(cat "$PRS_STUB_DIR/listed")" "https://example.com/pr" "open PRs are listed for the new PR's repository"
for PRS_KEEP in pr/61 pr/62 other.example pr/15; do
  if grep -q "$PRS_KEEP|" "$PRS_STUB_DIR/declined"; then fail "$PRS_KEEP must stay open"; fi
done
# 사람이 리뷰 중인 수동 sync PR이 열려 있으면 그 PR과 같은 파일을 고치는 새 sync를 띄우지 않는다.
printf '%s\n' '{"state":"open","activity":1}' >"$PRS_STUB_DIR/state-64.json"
printf '%s\n' '{"url":"https://example.com/pr/64","head":"feature/EX-4-harness-sync-0.70.0"}' >>"$PRS_STUB_DIR/open.jsonl"
PRS_LAUNCHED="$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')"
SYNC_STUB_PR=16 prs_sweep
assert_eq "$PRS_LAUNCHED" "$(wc -l <"$TEST_TMP/sync-stub.out" | tr -d ' ')" "sync waits while a person reviews a session sync PR"
assert_eq "sync_pr_in_review" "$(sync_runs 'last | .reason')" "the hold names the review"
# open-pr.sh --list-open: 저장소 URL(없으면 현재 저장소 origin)의 열린 PR을 {url, head} 한 줄씩 낸다.
PRS_LIST_BIN="$TEST_TMP/pr-list-bin"
mkdir -p "$PRS_LIST_BIN"
cat >"$PRS_LIST_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$PRS_GH_ARGS"
echo '[{"url":"https://github.com/acme/svc/pull/5","headRefName":"chore/harness-sync-0.1.0"}]'
STUB
cat >"$PRS_LIST_BIN/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$*" >"$PRS_CURL_ARGS"
printf '%s\n200' '{"values":[{"links":{"html":{"href":"https://bitbucket.org/ws/repo/pull-requests/8"}},"source":{"branch":{"name":"feature/EX-1-harness-sync-0.69.0"}}}]}'
STUB
chmod +x "$PRS_LIST_BIN/gh" "$PRS_LIST_BIN/curl"
export PRS_GH_ARGS="$TEST_TMP/prs-gh-args" PRS_CURL_ARGS="$TEST_TMP/prs-curl-args"
assert_eq "https://github.com/acme/svc/pull/5|chore/harness-sync-0.1.0" \
  "$(PATH="$PRS_LIST_BIN:$PATH" "$ROOT/scripts/open-pr.sh" --list-open https://github.com/acme/svc | jq -r '"\(.url)|\(.head)"')" "GitHub open PRs with their branches"
assert_contains "$(cat "$PRS_GH_ARGS")" "--repo acme/svc --state open" "GitHub list asks the named repository for open PRs"
assert_eq "https://bitbucket.org/ws/repo/pull-requests/8|feature/EX-1-harness-sync-0.69.0" \
  "$(PATH="$PRS_LIST_BIN:$PATH" ATLASSIAN_USER=u BITBUCKET_API_TOKEN=t "$ROOT/scripts/open-pr.sh" --list-open https://bitbucket.org/ws/repo | jq -r '"\(.url)|\(.head)"')" "Bitbucket open PRs with their branches"
assert_contains "$(cat "$PRS_CURL_ARGS")" "repositories/ws/repo/pullrequests?state=OPEN" "Bitbucket list asks for open PRs"
PRS_LIST_REPO="$TEST_TMP/prs-list-repo"
make_repo "$PRS_LIST_REPO" https://github.com/acme/origin-svc.git
(cd "$PRS_LIST_REPO" && PATH="$PRS_LIST_BIN:$PATH" "$ROOT/scripts/open-pr.sh" --list-open >/dev/null)
assert_contains "$(cat "$PRS_GH_ARGS")" "--repo acme/origin-svc" "without a URL the current repository's origin is listed"
if (cd "$PRS_LIST_REPO" && env -u ATLASSIAN_USER -u BITBUCKET_API_TOKEN HARNESS_CLAUDE_SETTINGS=/nonexistent \
  "$ROOT/scripts/open-pr.sh" --list-open https://bitbucket.org/ws/repo >/dev/null 2>&1); then fail "Bitbucket list needs credentials"; fi
pass "auto sync also supersedes sync PRs opened in a session"

finish_tests
