#!/usr/bin/env bash
# 회귀 테스트 — 자동 sync: 버전 알림·opt-in 자동 sync
# 실행: bash tests/run.sh automation-sync
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-auto-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-auto-sync.sh"

# 하네스 생성물 버전 차이: SessionStart 알림과 opt-in 자동 sync (#137)
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

finish_tests
