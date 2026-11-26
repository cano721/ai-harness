#!/usr/bin/env bash
# 회귀 테스트 — 자동 sync: 옛 sync PR 대체(러너가 연 PR)·PR 호스트 상태 조회와 닫기 요청
# 실행: bash tests/run.sh automation-sync-supersede
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-auto-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-auto-sync.sh"

sync_prime

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

finish_tests
