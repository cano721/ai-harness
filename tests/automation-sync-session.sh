#!/usr/bin/env bash
# 회귀 테스트 — 자동 sync: 세션에서 연 sync PR 대체·open-pr.sh --list-open
# 실행: bash tests/run.sh automation-sync-session
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-auto-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-auto-sync.sh"

sync_prime
export PRS_STUB_DIR="$TEST_TMP/pr-stub"
mkdir -p "$PRS_STUB_DIR"
: >"$PRS_STUB_DIR/pr"
chmod +x "$PRS_STUB_DIR/pr"

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
