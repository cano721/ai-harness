#!/usr/bin/env bash
# 회귀 테스트 — 모니터링 수집·autofix
# 실행: bash tests/run.sh autofix
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-autofix.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-autofix.sh"

# monitor-fetch.sh: 모니터링 도구 응답을 한 형식으로 맞추고, 자격증명을 보낼 곳을 저장소 설정이 정하지 못하게 한다.
AF_LIST="$(af_fetch list --root "$AF_REPO")"
assert_eq "1" "$(printf '%s\n' "$AF_LIST" | grep -c .)" "issues under min_events are not candidates"
assert_eq "sentry:101|50|101" "$(jq -r '[.signature, .count, .meta.id] | join("|")' <<<"$AF_LIST")" "sentry window count sums the hourly stats"
assert_contains "$(<"$AF_STUB/http.log")" "environment=production" "sentry list is scoped to the environment"
AF_DETAIL="$(af_fetch detail --root "$AF_REPO" --meta '{"id":"101"}')"
assert_eq "UserService.java" "$(jq -r '.exception[0].frames[0].file' <<<"$AF_DETAIL")" "detail lists the innermost frame first"
assert_contains "$(jq -r '.message' <<<"$AF_DETAIL")" "token=***" "detail redacts secrets"
[[ "$(jq -r '.tags | has("user.email")' <<<"$AF_DETAIL")" == "false" ]] || fail "detail keeps only allow-listed tags"
assert_eq '{"seen":false,"count":0,"last_seen":null}' "$(af_fetch count --root "$AF_REPO" --meta '{"id":"101"}' --since 2026-10-29T00:00:00Z)" "no events since the fix"
jq -n '[{dateCreated:"2000-01-01T00:00:00Z"},{dateCreated:"2999-01-01T00:00:00Z"}]' >"$AF_STUB/sentry-events.json"
assert_eq "true|1" "$(af_fetch count --root "$AF_REPO" --meta '{"id":"101"}' --since 2026-10-29T00:00:00Z | jq -r '"\(.seen)|\(.count)"')" "only events after since count as a recurrence"
printf '[]\n' >"$AF_STUB/sentry-events.json"
# 진짜 HTTP 경로: 자격증명 없이는 시작하지 않고, 저장소 설정이 자격증명 전송처를 바꾸지 못한다.
AF_RC=0; HARNESS_METRICS_DIR="$AF_DATA" HARNESS_CLAUDE_SETTINGS=/nonexistent SENTRY_AUTH_TOKEN="" HM_SENTRY_TOKEN="" \
  "$ROOT/scripts/monitor-fetch.sh" list --root "$AF_REPO" >/dev/null 2>&1 || AF_RC=$?
assert_eq "4" "$AF_RC" "missing sentry token is a config error"
pass "monitor-fetch normalizes sentry issues and checks recurrence after a time"

AF_BAD="$TEST_TMP/autofix-bad"
mkdir -p "$AF_BAD/.ai-harness"
af_bad() { # $1=monitor json → exit code of list
  jq -n --argjson m "$1" '{monitor:$m}' >"$AF_BAD/.ai-harness/harness.json"
  local rc=0
  HARNESS_METRICS_DIR="$AF_DATA" SENTRY_AUTH_TOKEN=t DATADOG_API_KEY=k DATADOG_APP_KEY=a \
    "$ROOT/scripts/monitor-fetch.sh" list --root "$AF_BAD" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}
assert_eq "4" "$(af_bad '{"provider":"sentry","org":"a","project":"b","base_url":"https://evil.example.com"}')" "repo config cannot send the sentry token to another host"
assert_eq "4" "$(af_bad '{"provider":"datadog","query":"status:error","site":"evil.example.com"}')" "repo config cannot send datadog keys to another host"
assert_eq "4" "$(af_bad '{"provider":"command","command":"/bin/sh"}')" "command adapter must live inside the repo"
assert_eq "4" "$(af_bad '{"provider":"command","command":"../x.sh"}')" "command adapter path cannot climb out"
assert_eq "4" "$(af_bad '{"provider":"nope"}')" "unknown provider is rejected"
pass "monitor credentials only go to known hosts"

# Datadog: 줄 번호만 다른 같은 버그는 한 묶음이다(수정 커밋 뒤에도 같은 시그니처로 검증할 수 있게).
jq -n '{data:([range(12) as $i | {attributes:{service:"api",timestamp:"2026-10-28T0\($i % 10):00:00Z",
  attributes:{error:{kind:"IllegalStateException",message:"order \($i) missing",stack:"java.lang.IllegalStateException\n\tat com.acme.Order.pay(Order.java:\(40 + $i))\n\tat com.acme.Api.call(Api.java:9)"}}}}]
  + [{attributes:{service:"api",timestamp:"2026-10-28T01:00:00Z",attributes:{error:{kind:"Other",message:"x",stack:""}}}}])}' >"$AF_STUB/dd-logs.json"
jq -n --argjson m '{"provider":"datadog","query":"service:api status:error","min_events":10}' '{monitor:$m}' >"$AF_BAD/.ai-harness/harness.json"
AF_DD="$(af_fetch list --root "$AF_BAD")"
assert_eq "1|12" "$(printf '%s\n' "$AF_DD" | jq -sr '"\(length)|\(.[0].count)"')" "datadog groups the same frame across line numbers"
assert_contains "$(jq -r '.signature' <<<"$AF_DD")" "datadog:" "datadog signature"
AF_DD_META="$(jq -c '.meta' <<<"$AF_DD")"
jq '{data:(.data[0:2] | map(.attributes.timestamp = "2999-01-01T00:00:00Z"))}' "$AF_STUB/dd-logs.json" >"$AF_STUB/dd-count.json"
assert_eq "true|2" "$(af_fetch count --root "$AF_BAD" --meta "$AF_DD_META" --since 2026-10-29T00:00:00Z | jq -r '"\(.seen)|\(.count)"')" "datadog recurrence matches the stored group key"
assert_contains "$(tail -n 1 "$AF_STUB/http.log")" "logs/events/search" "datadog count searches logs"
AF_DD_SIG="$(jq -r '.signature' <<<"$AF_DD")"
# 스택 프레임으로 묶는 키는 제목 정리(#460)와 무관하게 그대로다 — 이미 추적 중인 시그니처가 바뀌지 않게.
assert_eq "datadog:013e27fae9e43ee6" "$AF_DD_SIG" "frame-grouped datadog signatures stay the same"
# 로그 패턴을 message에 통째로 싣는 앱(#460): 시각·레벨·trace_id 앞머리를 걷어 낸 본문이 제목이고,
# 스택이 없어도 trace_id 값이 줄마다 달라 묶음이 갈라지지 않는다.
jq -n '{data:[range(11) as $i | {attributes:{service:"api",timestamp:"2026-10-28T0\($i % 10):00:00Z",
  message:"2026-10-28 0\($i % 10):00:0\($i % 10).123 ERROR trace_id:\(("abcdef" | .[($i % 6):($i % 6 + 1)]) * 32) span_id:75026564392257433\($i) - KafkaDltHandler:44: [DLT] topic=orders-dlt offset=\(1000 + $i)",
  attributes:{}}}]}' >"$AF_STUB/dd-logs.json"
AF_DD2="$(af_fetch list --root "$AF_BAD")"
assert_eq "1|11" "$(printf '%s\n' "$AF_DD2" | jq -sr '"\(length)|\(.[0].count)"')" "stackless logs with per-line trace ids group together"
assert_eq "KafkaDltHandler:44: [DLT] topic=orders-dlt offset=1000" "$(jq -r '.title' <<<"$AF_DD2")" "the title drops the log line's time, level and trace ids"
pass "monitor-fetch groups datadog logs into stable signatures"

# command 어댑터: 저장소 안 스크립트가 같은 형식을 낸다.
mkdir -p "$AF_BAD/tools"
cat >"$AF_BAD/tools/monitor.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '%s\n' '{"signature":"own:1","title":"t","count":11}' '{"signature":"own:2","title":"u","count":1}' ;;
  count) printf '%s\n' '{"count":3}' ;;
esac
EOF
chmod +x "$AF_BAD/tools/monitor.sh"
jq -n '{monitor:{provider:"command",command:"tools/monitor.sh"}}' >"$AF_BAD/.ai-harness/harness.json"
assert_eq "own:1" "$(af_fetch list --root "$AF_BAD" | jq -r '.signature')" "command adapter list honours min_events"
assert_eq "true" "$(af_fetch count --root "$AF_BAD" --meta '{}' --since 2026-10-29T00:00:00Z | jq -r '.seen')" "command adapter count implies seen"
pass "monitor-fetch runs a repo-local command adapter"

# open-pr.sh --status: PR URL만으로 상태를 본다.
AF_RC=0; ATLASSIAN_USER="" BITBUCKET_API_TOKEN="" HARNESS_CLAUDE_SETTINGS="$TEST_TMP/no-settings.json" "$ROOT/scripts/open-pr.sh" --status https://bitbucket.org/ws/repo/pull-requests/3 >/dev/null 2>&1 || AF_RC=$?
assert_eq "4" "$AF_RC" "bitbucket status needs credentials"
AF_RC=0; "$ROOT/scripts/open-pr.sh" --status https://example.com/pr/1 >/dev/null 2>&1 || AF_RC=$?
assert_eq "3" "$AF_RC" "unknown PR host is rejected"
pass "open-pr reports PR state for verification"

# autofix-auto.sh: 감지 → draft PR → 병합 → 배포 반영 → 관찰 → 해결/재발.
HARNESS_METRICS_DIR="$AF_DATA" HM_AUTOFIX_AUTO=0 HM_AUTOFIX_CMD="$AF_STUB/agent" "$ROOT/scripts/autofix-auto.sh" sweep
assert_not_file "$AF_STUB/agent-count"
HM_AUTOFIX_REPOS="" af_auto sweep
assert_not_file "$AF_STUB/agent-count"
HM_AUTOFIX_REPOS="other" af_auto sweep
assert_not_file "$AF_STUB/agent-count"
af_auto sweep
assert_eq "1" "$(<"$AF_STUB/agent-count")" "sweep launches one fix"
assert_eq "pr_open|https://github.com/acme/svc/pull/1|1" "$(af_sig '"\(.status)|\(.pr)|\(.attempts)"')" "agent PR is recorded"
assert_eq "new|UserService.java" "$(jq -r '"\(.reason)|\(.detail.exception[0].frames[0].file)"' "$AF_STUB/error-1.json")" "agent gets the error detail"
if git -C "$AF_REPO" worktree list | grep -q auto-worktrees; then fail "worker removes its worktree"; fi
# 무인 에이전트(launchd → claude)가 띄운 셸은 macOS 보호 폴더(~/Desktop 등)에 있는 원본 저장소의 .git을 읽지 못한다(#272).
# 작업 디렉토리는 git 메타데이터를 원본에 기대지 않는 독립 저장소여야 하고, origin·기준 커밋·저장소 user 설정은 원본과 같아야 한다.
AF_WD="$(sed -n 1p "$AF_STUB/git-1.txt")"
assert_eq "$AF_WD/.git" "$(sed -n 2p "$AF_STUB/git-1.txt")" "agent work dir has its own git dir, not the source repo's"
assert_eq "git@github.com:acme/svc.git" "$(sed -n 3p "$AF_STUB/git-1.txt")" "agent work dir keeps the source origin url"
assert_eq "$(git -C "$AF_REPO" rev-parse origin/develop)" "$(sed -n 4p "$AF_STUB/git-1.txt")" "agent work dir is at the base commit"
assert_eq "test@example.com" "$(sed -n 5p "$AF_STUB/git-1.txt")" "agent work dir keeps the repo-local git identity"
[[ ! -e "$AF_WD" ]] || fail "worker removes the agent work dir"
af_auto sweep
assert_eq "1" "$(<"$AF_STUB/agent-count")" "a signature with an open PR is not fixed again"

# 병합됐지만 배포 브랜치에 아직 없다 → 배포 대기.
git -C "$AF_REPO" commit -q --allow-empty -m "fix" && AF_MERGE="$(git -C "$AF_REPO" rev-parse HEAD)"
git -C "$AF_REPO" push -q origin HEAD:develop 2>/dev/null
jq -n --arg c "$AF_MERGE" --arg m "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{state:"merged",merged_at:$m,merge_commit:$c}' >"$AF_STUB/pr-state.json"
af_auto verify
assert_eq "verifying|null" "$(af_sig '"\(.status)|\(.deployed_at)"')" "merged fix waits for the deploy branch"
HM_AUTOFIX_DEPLOY_WAIT_DAYS=100000 af_auto verify
assert_eq "verifying" "$(af_sig '.status')" "deploy wait is bounded but not yet over"
git -C "$AF_REPO" push -q origin HEAD:main 2>/dev/null
af_auto verify
[[ "$(af_sig '.deployed_at')" != "null" ]] || fail "deploy is observed when the merge commit reaches the deploy branch"
# 수정 전 24시간 50건 → 3건이 나올 시간(2h)만큼은 관찰한다. 막 배포됐으니 아직 판정하지 않는다.
assert_eq "verifying" "$(af_sig '.status')" "quiet window is not over yet"
[[ "$(af_sig '.verify_until')" != "null" ]] || fail "verify_until is recorded"
af_state '.signatures["sentry:101"].deployed_at = "2026-10-01T00:00:00Z"'
af_auto verify
assert_eq "resolved" "$(af_sig '.status')" "no recurrence through the quiet window resolves the error"
assert_eq "resolved" "$(jq -sr 'map(select(.event=="resolved")) | last | .event' "$AF_DATA/autofix/runs.jsonl")" "resolution is logged"
pass "autofix opens a PR and verifies the error stops after deploy"

# 재발: 해결 뒤 다시 목록에 오르면 지난 PR을 넘겨 다시 고친다. 시도 상한이면 사람에게 넘긴다.
af_auto sweep
assert_eq "2" "$(<"$AF_STUB/agent-count")" "a resolved error that reappears is fixed again"
assert_eq "reappeared|https://github.com/acme/svc/pull/1" "$(jq -r '"\(.reason)|\(.previous.prs[0])"' "$AF_STUB/error-2.json")" "previous PR is passed on"
af_state '.signatures["sentry:101"] += {status:"verifying",deployed_at:"2026-10-01T00:00:00Z"}'
jq -n '[{dateCreated:"2999-01-01T00:00:00Z"}]' >"$AF_STUB/sentry-events.json"
af_auto verify
assert_eq "gave_up|1" "$(af_sig '"\(.status)|\(.regressions)"')" "recurrence after the last allowed attempt goes to a person"
af_auto sweep
assert_eq "2" "$(<"$AF_STUB/agent-count")" "gave_up is not retried"
af_state '.signatures["sentry:101"] += {status:"verifying",attempts:1,regressions:[]}'
af_auto verify
assert_eq "regressed" "$(af_sig '.status')" "recurrence with attempts left is a regression"
printf '[]\n' >"$AF_STUB/sentry-events.json"
pass "autofix detects recurrence after a fix"

# 사람이 닫은 PR은 다시 시도하지 않고, 코드 버그가 아닌 에러는 유예 동안 건너뛴다.
af_state '.signatures["sentry:101"] += {status:"verifying",merged_at:"2000-01-01T00:00:00Z",deployed_at:null,merge_commit:"0000000000000000000000000000000000000000"}'
af_auto verify
assert_eq "gave_up|deploy_unobserved" "$(af_sig '"\(.status)|\(.outcome)"')" "a fix never seen on the deploy branch goes to a person"
af_state '.signatures["sentry:101"] += {status:"pr_open",pr:"https://github.com/acme/svc/pull/9"}'
jq -n '{state:"closed",merged_at:null,merge_commit:null}' >"$AF_STUB/pr-state.json"
af_auto sweep
assert_eq "declined|2" "$(af_sig '.status')|$(<"$AF_STUB/agent-count")" "declined PR is not retried"
af_state 'del(.signatures["sentry:101"])'
AF_STUB_RESULT="AI_HARNESS_AUTOFIX_RESULT outcome=not_code_bug" af_auto sweep
assert_eq "skipped|not_code_bug|0" "$(af_sig '"\(.status)|\(.outcome)|\(.attempts)"')" "non-code errors are skipped without using an attempt"
af_auto sweep
assert_eq "3" "$(<"$AF_STUB/agent-count")" "skipped error waits for the cooldown"
af_state 'del(.signatures["sentry:101"])'
AF_STUB_RESULT="AI_HARNESS_AUTOFIX_RESULT outcome=pr_opened artifact=https://github.com/evil/other/pull/1" af_auto sweep
assert_eq "failed|0|1" "$(af_sig '"\(.status)|\(.attempts)|\(.fails)"')" "a PR from another repository is not tracked"
af_state 'del(.signatures["sentry:101"])'
HM_AUTOFIX_DAILY_MAX=0 af_auto sweep
assert_eq "4|daily_max" "$(<"$AF_STUB/agent-count")|$(jq -sr 'last | .reason' "$AF_DATA/autofix/runs.jsonl")" "daily cap stops new fixes"
AF_STUB_RESULT="done" af_auto sweep
assert_eq "skipped|no_result" "$(af_sig '"\(.status)|\(.outcome)"')" "a run without a result line is not mistaken for a PR"
pass "autofix respects declined PRs, cooldowns and caps"

# 상태 기록이 attempting에 멈췄어도 실행 기록에 PR이 있으면 그 PR로 복구하고, 다시 고치지 않는다.
af_state '.signatures["sentry:101"] += {status:"attempting",launched_at:"2000-01-01T00:00:00Z",attempts:1,fails:0}'
jq -cn '{at:"2000-01-01T01:00:00Z",event:"finished",project:"af-svc",signature:"sentry:101",outcome:"pr_opened",artifact:"https://github.com/acme/svc/pull/77"}' >>"$AF_DATA/autofix/runs.jsonl"
jq -n '{state:"open"}' >"$AF_STUB/pr-state.json"
AF_BEFORE="$(<"$AF_STUB/agent-count")"
af_auto sweep
assert_eq "pr_open|https://github.com/acme/svc/pull/77|$AF_BEFORE" "$(af_sig '"\(.status)|\(.pr)"')|$(<"$AF_STUB/agent-count")" "a PR recorded only in the run log is recovered"
af_state '.signatures["sentry:101"] += {status:"attempting",launched_at:"2000-01-01T00:00:00Z",attempts:2,fails:0}'
af_auto sweep
assert_eq "$AF_BEFORE" "$(<"$AF_STUB/agent-count")" "stale attempts stop at the attempt limit"
af_state 'del(.signatures["sentry:101"])'
AF_RC=0
HM_AUTOFIX_REPOS="other" af_auto track --project af-svc --candidate "$AF_LIST" --pr https://github.com/acme/svc/pull/42 2>/dev/null || AF_RC=$?
assert_eq "3:" "$AF_RC:$(af_sig '.status')" "a PR of a project that verify never visits is not tracked"
af_auto track --project af-svc --candidate "$AF_LIST" --pr https://github.com/acme/svc/pull/42
assert_eq "pr_open|https://github.com/acme/svc/pull/42|50" "$(af_sig '"\(.status)|\(.pr)"')|$(jq -r '.signatures["sentry:101"].baseline.count' "$AF_DATA/autofix/p-af-svc/state.json")" "manual PR joins verification"
AF_ARGS="$(sed -n '/AGENT_CMD=(claude/,/--output-format json)/p' "$ROOT/scripts/autofix-auto.sh")"
assert_contains "$AF_ARGS" '--permission-mode dontAsk' "unlisted commands are denied without asking"
# shellcheck disable=SC2016
assert_contains "$AF_ARGS" '--plugin-dir "$plugin_root"' "autofix loads the installed copy it may run (#366)"
# shellcheck disable=SC2016
assert_contains "$AF_ARGS" '"Bash($scripts_dir/open-pr.sh*)"' "autofix may run open-pr.sh through the stable link (#400)"
# shellcheck disable=SC2016
assert_contains "$AF_ARGS" '--scripts $scripts_dir' "autofix agent is told the stable scripts path (#400)"
if grep -qE '"Bash"|"Bash\((curl|gh|bash|sh|python|node) ' <<<"$AF_ARGS"; then fail "unattended autofix must not allow arbitrary Bash"; fi
assert_contains "$AF_ARGS" '"Bash(git push -u origin fix/*)"' "push is limited to fix branches"
assert_contains "$AF_ARGS" '"Read(~/.claude/settings.json)"' "agent cannot read credential settings"
assert_contains "$AF_ARGS" "--settings \"\$scrub\"" "monitor credentials are blanked in the agent env"
assert_contains "$AF_ARGS" '--no-session-persistence' "unattended autofix keeps no transcript"
assert_contains "$(<"$ROOT/scripts/backfill-due.sh")" 'autofix-auto.sh" sweep' "backfill-due runs the autofix sweep"
assert_contains "$(<"$ROOT/scripts/autofix-auto.sh")" 'harvest-auto/running.lock' "autofix shares the unattended-run lock"
pass "autofix tracks manual PRs and runs with a restricted agent"

finish_tests
