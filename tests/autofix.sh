#!/usr/bin/env bash
# 회귀 테스트 — 모니터링 수집·autofix
# 실행: bash tests/run.sh autofix
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# monitor-fetch.sh: 모니터링 도구 응답을 한 형식으로 맞추고, 자격증명을 보낼 곳을 저장소 설정이 정하지 못하게 한다.
AF_DATA="$TEST_TMP/autofix-data"
AF_STUB="$TEST_TMP/autofix-stub"
AF_ORIGIN="$TEST_TMP/autofix-origin.git"
AF_REPO="$TEST_TMP/autofix-repo"
mkdir -p "$AF_STUB" "$AF_DATA"
git init -q --bare "$AF_ORIGIN"
git clone -q "$AF_ORIGIN" "$AF_REPO" 2>/dev/null
git -C "$AF_REPO" config user.email test@example.com
git -C "$AF_REPO" config user.name test
# PR URL 소속 확인은 origin 설정값(github.com/acme/svc)으로, 실제 fetch·push는 로컬 bare 저장소로 간다.
git -C "$AF_REPO" remote set-url origin git@github.com:acme/svc.git
git -C "$AF_REPO" config url."$AF_ORIGIN".insteadOf git@github.com:acme/svc.git
af_manifest() { # $1=monitor json → develop에 커밋·push
  mkdir -p "$AF_REPO/.ai-harness"
  jq -n --argjson m "$1" '{project_id:"af-svc",level:"standard",git_policy:"pr-only",monitor:$m}' >"$AF_REPO/.ai-harness/harness.json"
  git -C "$AF_REPO" add -A && git -C "$AF_REPO" commit -q -m "monitor" && git -C "$AF_REPO" push -q origin HEAD:develop 2>/dev/null
  git -C "$AF_REPO" fetch -q origin
}
git -C "$AF_REPO" checkout -q -b develop
af_manifest '{"provider":"sentry","org":"acme","project":"api","environment":"production","min_events":10,"deploy_branch":"main","grace_hours":0,"quiet_hours":0}'
git -C "$AF_REPO" push -q origin develop:main 2>/dev/null

cat >"$AF_STUB/http" <<'EOF'
#!/usr/bin/env bash
# $1=METHOD $2=URL [$3=body]
printf '%s %s\n' "$1" "$2" >>"$AF_STUB/http.log"
case "$2" in
  */issues/\?query=*) cat "$AF_STUB/sentry-issues.json" ;;
  */events/latest/) cat "$AF_STUB/sentry-latest.json" ;;
  */events/\?start=*) cat "$AF_STUB/sentry-events.json" ;;
  */logs/events/search)
    if [[ "$3" == *'"from":"now-'* ]]; then cat "$AF_STUB/dd-logs.json"; else cat "$AF_STUB/dd-count.json"; fi ;;
  *) echo "unexpected $2" >&2; exit 9 ;;
esac
EOF
chmod +x "$AF_STUB/http"
jq -n '[
  {id:"101",title:"NullPointerException: \"user\" is null\tx",culprit:"UserService.load",count:"900",firstSeen:"2026-10-01T00:00:00Z",lastSeen:"2026-10-28T00:00:00Z",permalink:"https://acme.sentry.io/issues/101/",stats:{"24h":[[1,20],[2,30]]}},
  {id:"102",title:"rare",culprit:"x",count:"3",stats:{"24h":[[1,1],[2,2]]}}
]' >"$AF_STUB/sentry-issues.json"
jq -n '{message:"boom token=abcd1234secretvalue",entries:[{type:"exception",data:{values:[{type:"NullPointerException",value:"user is null",
  stacktrace:{frames:[{filename:"Lib.java",function:"x",lineNo:1,inApp:false},{filename:"UserService.java",function:"load",lineNo:42,inApp:true}]}}]}}],
  tags:[{key:"environment",value:"production"},{key:"user.email",value:"a@b.c"}]}' >"$AF_STUB/sentry-latest.json"
printf '[]\n' >"$AF_STUB/sentry-events.json"
export AF_STUB
af_fetch() { HARNESS_METRICS_DIR="$AF_DATA" HM_MONITOR_HTTP="$AF_STUB/http" "$ROOT/scripts/monitor-fetch.sh" "$@"; }

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
cat >"$AF_STUB/agent" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$AF_STUB/agent-count" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" >"$AF_STUB/agent-count"
cp "$1" "$AF_STUB/error-$n.json"
{ pwd -P; git rev-parse --path-format=absolute --git-common-dir; git remote get-url origin; git rev-parse HEAD; git config user.email; } >"$AF_STUB/git-$n.txt" 2>&1
printf '%s\n' "${AF_STUB_RESULT:-AI_HARNESS_AUTOFIX_RESULT outcome=pr_opened artifact=https://github.com/acme/svc/pull/$n}"
EOF
cat >"$AF_STUB/pr" <<'EOF'
#!/usr/bin/env bash
cat "$AF_STUB/pr-state.json"
EOF
chmod +x "$AF_STUB/agent" "$AF_STUB/pr"
af_auto() {
  HARNESS_METRICS_DIR="$AF_DATA" HM_AUTOFIX_AUTO=1 HM_AUTOFIX_FOREGROUND=1 HM_AUTOFIX_REPOS="${HM_AUTOFIX_REPOS-other, af-svc}" HM_MONITOR_HTTP="$AF_STUB/http" HM_AUTOFIX_DAILY_MAX="${HM_AUTOFIX_DAILY_MAX:-99}" \
    HM_AUTOFIX_CMD="$AF_STUB/agent" HM_AUTOFIX_PR_STATUS_CMD="$AF_STUB/pr" \
    HM_AUTOFIX_REPOS_CMD="$ROOT/scripts/sync-auto.sh repos --root $AF_REPO" "$ROOT/scripts/autofix-auto.sh" "$@"
}
af_sig() { HARNESS_METRICS_DIR="$AF_DATA" "$ROOT/scripts/autofix-auto.sh" status --project af-svc | jq -r --arg s "${2:-sentry:101}" "select(.signature==\$s) | $1"; }
af_state() { jq "$1" "$AF_DATA/autofix/p-af-svc/state.json" >"$AF_STUB/st.tmp" && mv "$AF_STUB/st.tmp" "$AF_DATA/autofix/p-af-svc/state.json"; }

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

# 하루 상한 '제한 없음'(1000 이상)은 오늘 실행 수와 상관없이 sweep을 막지 않는다. 그 아래 값은 그대로 막는다.
AF_SAVED_STATE="$(<"$AF_DATA/autofix/p-af-svc/state.json")"
cp "$AF_DATA/autofix/runs.jsonl" "$AF_STUB/runs.saved"
af_state 'del(.signatures["sentry:101"])'
AF_DAY="$(date -u +%Y-%m-%d)"
seq 1000 | jq -c --arg d "$AF_DAY" '{at:($d+"T00:00:00Z"), event:"started", project:"af-svc", signature:("old:"+tostring)}' >>"$AF_DATA/autofix/runs.jsonl"
AF_BEFORE="$(<"$AF_STUB/agent-count")"
HM_AUTOFIX_DAILY_MAX=999 af_auto sweep
assert_eq "$AF_BEFORE|daily_max" "$(<"$AF_STUB/agent-count")|$(jq -sr 'last | .reason' "$AF_DATA/autofix/runs.jsonl")" "a finite daily cap still stops new fixes"
HM_AUTOFIX_DAILY_MAX=1000 af_auto sweep
assert_eq "$((AF_BEFORE + 1))" "$(<"$AF_STUB/agent-count")" "an unlimited daily cap does not stop the sweep"
printf '%s\n' "$AF_SAVED_STATE" >"$AF_DATA/autofix/p-af-svc/state.json"
cp "$AF_STUB/runs.saved" "$AF_DATA/autofix/runs.jsonl"
# 실행당 예산: 숫자면 --max-budget-usd로 넘기고, unlimited면 넘기지 않는다(claude 경로).
mkdir -p "$AF_STUB/claude-bin"
cat >"$AF_STUB/claude-bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$AF_STUB/claude-args"
echo '{"type":"result","result":"AI_HARNESS_AUTOFIX_RESULT outcome=not_code_bug","total_cost_usd":0}'
EOF
chmod +x "$AF_STUB/claude-bin/claude"
af_budget_run() { # $1=HM_AUTOFIX_BUDGET_USD → claude에 넘긴 인자 줄
  printf '{"signature":"budget:1","title":"budget","count":10,"meta":{},"reason":"new"}\n' >"$AF_STUB/budget-cand.json"
  : >"$AF_STUB/claude-args"
  env -u HM_AUTOFIX_CMD PATH="$AF_STUB/claude-bin:$PATH" HARNESS_METRICS_DIR="$AF_DATA" HM_MONITOR_HTTP="$AF_STUB/http" HM_AUTOFIX_BUDGET_USD="$1" \
    "$ROOT/scripts/autofix-auto.sh" run af-svc "$AF_REPO" "$AF_STUB/budget-cand.json" >/dev/null 2>&1
  cat "$AF_STUB/claude-args"
}
assert_contains "$(af_budget_run 2.5)" "--max-budget-usd 2.5" "a numeric budget caps the fix run"
case "$(af_budget_run unlimited)" in *--max-budget-usd*) fail "an unlimited budget passes no --max-budget-usd" ;; "") fail "the claude fix run started" ;; esac
assert_contains "$(af_budget_run bogus)" "--max-budget-usd 10" "an invalid budget falls back to the default"
af_state 'del(.signatures["budget:1"])'
cp "$AF_STUB/runs.saved" "$AF_DATA/autofix/runs.jsonl"
pass "autofix unlimited daily cap and budget"

# 로그인 만료(#315): 자동 수정도 인증 실패를 auth_expired로 분류해 실패 횟수에 넣지 않는다. 과거 버전이 agent_error로 센
# 인증 실패(로그로 판정)는 횟수에서 빼 fails:3으로 포기된 에러가 다시 후보가 된다. 같은 회차에 이미 인증 실패가 났으면
# 그 회차의 자동 수정 실행은 띄우지 않는다.
AF_SAVED_STATE="$(<"$AF_DATA/autofix/p-af-svc/state.json")"
cp "$AF_DATA/autofix/runs.jsonl" "$AF_STUB/runs.saved"
AF_AUTH_LINE='{"type":"result","is_error":true,"terminal_reason":"api_error","result":"Failed to authenticate: this login reached its time limit and cannot be renewed. Run claude auth login"}'
printf '%s\n' "$AF_AUTH_LINE" >"$AF_STUB/legacy-auth.log"
af_state '.signatures["sentry:101"] = {status:"failed",fails:3,attempts:1,title:"t"}'
for _ in 1 2 3; do
  jq -cn --arg l "$AF_STUB/legacy-auth.log" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at:$at,event:"finished",project:"af-svc",signature:"sentry:101",outcome:"failed",exit_code:0,reason:"agent_error",log:$l}' >>"$AF_DATA/autofix/runs.jsonl"
done
# 마지막 PR·해결 앞의 인증 실패는 지금 실패 횟수에 들어 있지 않으므로 빼지 않는다.
jq -cn --arg l "$AF_STUB/legacy-auth.log" '{at:"2000-01-01T00:00:00Z",event:"finished",project:"af-svc",signature:"sentry:101",outcome:"failed",exit_code:0,reason:"agent_error",log:$l}' >>"$AF_DATA/autofix/runs.jsonl"
af_state '.signatures["sentry:101"].fails = 4'
jq -n '{state:"open"}' >"$AF_STUB/pr-state.json"
AF_BEFORE="$(<"$AF_STUB/agent-count")"
AF_STUB_RESULT="$AF_AUTH_LINE" af_auto sweep
assert_eq "$((AF_BEFORE + 1))" "$(<"$AF_STUB/agent-count")" "an error given up only for expired logins is tried again"
assert_eq "failed|1|auth_expired" "$(af_sig '"\(.status)|\(.fails)|\(.last_reason)"')" "an expired login is classified and not counted, and only failures after the last PR are forgiven"
assert_eq "auth_expired" "$(jq -sr '[.[] | select(.event=="finished")] | last | .reason' "$AF_DATA/autofix/runs.jsonl")" "the run log names the expired login"
AF_STUB_RESULT="$AF_AUTH_LINE" HM_LLM_TICK_STARTED_AT="2000-01-01T00:00:00Z" af_auto sweep
assert_eq "$((AF_BEFORE + 1))|auth_expired" "$(<"$AF_STUB/agent-count")|$(jq -sr 'last | .reason' "$AF_DATA/autofix/runs.jsonl")" "no more fixes start in a round that already hit an expired login"
printf '%s\n' "$AF_SAVED_STATE" >"$AF_DATA/autofix/p-af-svc/state.json"
cp "$AF_STUB/runs.saved" "$AF_DATA/autofix/runs.jsonl"
assert_contains "$(<"$ROOT/scripts/board/template.html")" "auth_expired: '로그인 만료" "the autofix tab says the login expired"
pass "autofix classifies expired logins without counting them"

# 상태 기록 실패·유실(#278 2차): 시작 상태를 못 남기면 실행하지 않고, 상태 파일을 잃은 프로젝트는 실행 기록으로 되살린다.
AF_BEFORE="$(<"$AF_STUB/agent-count")"
cp "$AF_DATA/autofix/runs.jsonl" "$AF_STUB/runs.saved"
printf 'not a dir\n' >"$AF_DATA/autofix/$(hm_short_key af-broken)"
printf '{"signature":"broken:1","title":"broken","count":10,"meta":{},"reason":"new"}\n' >"$AF_STUB/broken-cand.json"
AF_RC=0
HARNESS_METRICS_DIR="$AF_DATA" HM_AUTOFIX_CMD="$AF_STUB/agent" HM_MONITOR_HTTP="$AF_STUB/http" \
  "$ROOT/scripts/autofix-auto.sh" run af-broken "$AF_REPO" "$AF_STUB/broken-cand.json" >/dev/null 2>&1 || AF_RC=$?
assert_eq "1|$AF_BEFORE|state_error:start" "$AF_RC|$(<"$AF_STUB/agent-count")|$(jq -sr 'last | "\(.event):\(.stage)"' "$AF_DATA/autofix/runs.jsonl")" \
  "a run that cannot record its start does not launch the agent"
find "$AF_DATA/autofix/$(hm_short_key af-broken)" -delete
cp "$AF_STUB/runs.saved" "$AF_DATA/autofix/runs.jsonl"
# 상태 파일 유실: 사람에게 넘긴 실행(left_for_user)이 실행 기록에만 남아도 status에 보이고, 다음 검증이 상태로 되살린다.
AF_STATE_FILE="$AF_DATA/autofix/p-af-svc/state.json"
cp "$AF_STATE_FILE" "$AF_STUB/state.saved"
mkdir -p "$AF_DATA/autofix/logs"
jq -cn '{type:"result", result:"원인 분석: UserService.load에서 null 검사 누락. 사용한 토큰 token=abcd1234secretvalue5678 은 가림.\nAI_HARNESS_AUTOFIX_RESULT outcome=left_for_user"}' \
  >"$AF_DATA/autofix/logs/lost-af-svc.log"
{
  jq -cn '{at:"2026-11-02T00:00:00Z", event:"started", project:"af-svc", signature:"lost:1", reason:"new", log:"LOG"}'
  jq -cn '{at:"2026-11-02T00:01:00Z", event:"finished", project:"af-svc", signature:"lost:1", outcome:"left_for_user", exit_code:0, log:"LOG"}'
} | sed "s|LOG|$AF_DATA/autofix/logs/lost-af-svc.log|" >>"$AF_DATA/autofix/runs.jsonl"
find "$AF_STATE_FILE" -delete
AF_LOST="$(HARNESS_METRICS_DIR="$AF_DATA" "$ROOT/scripts/autofix-auto.sh" status --project af-svc | jq -c 'select(.signature == "lost:1")')"
assert_eq "skipped|left_for_user|runs" "$(jq -r '"\(.status)|\(.outcome)|\(.recovered)"' <<<"$AF_LOST")" "a lost state file still shows the left_for_user run from the run log"
assert_contains "$(jq -r '.summary' <<<"$AF_LOST")" "UserService.load에서 null 검사 누락" "the card carries the agent's analysis from the log"
case "$AF_LOST" in *abcd1234secretvalue5678*|*AI_HARNESS_AUTOFIX_RESULT*) fail "the summary hides secrets and the result marker" ;; esac
af_auto verify --project af-svc
assert_eq "skipped|left_for_user|runs" "$(jq -r '.signatures["lost:1"] | "\(.status)|\(.outcome)|\(.recovered)"' "$AF_STATE_FILE")" "verify writes the recovered signature back to the state file"
assert_contains "$(<"$AF_DATA/autofix/runs.jsonl")" '"event":"recovered","project":"af-svc","signature":"lost:1"' "recovery is logged"
# 상태 파일 안에서 일부러 지운 시그니처(다시 고치게 하기)는 되살리지 않는다.
af_state 'del(.signatures["lost:1"])'
af_auto verify --project af-svc
assert_eq "null" "$(jq -c '.signatures["lost:1"]' "$AF_STATE_FILE")" "a signature removed on purpose is not resurrected"
# 통째 복구는 마지막 결과 위에 그 뒤의 검증 이벤트를 겹친다(해결된 것이 PR 검토 대기로, 닫힌 수동 PR이 열린 PR로 되살아나지 않게).
{
  jq -cn '{at:"2026-11-01T00:00:00Z", event:"finished", project:"replay", signature:"r:1", outcome:"pr_opened", artifact:"https://github.com/acme/r/pull/1"}'
  jq -cn '{at:"2026-11-02T00:00:00Z", event:"merged", project:"replay", signature:"r:1"}'
  jq -cn '{at:"2026-11-04T00:00:00Z", event:"resolved", project:"replay", signature:"r:1"}'
  jq -cn '{at:"2026-11-01T00:00:00Z", event:"tracked", project:"replay", signature:"r:2", artifact:"https://github.com/acme/r/pull/2"}'
  jq -cn '{at:"2026-11-03T00:00:00Z", event:"declined", project:"replay", signature:"r:2"}'
  jq -cn '{at:"2026-11-01T00:00:00Z", event:"finished", project:"replay", signature:"r:3", outcome:"failed", reason:"usage_limit"}'
  # 실패 횟수는 마지막으로 PR을 연 뒤의 실패만 센다.
  jq -cn '{at:"2026-11-01T00:00:00Z", event:"finished", project:"replay", signature:"r:4", outcome:"failed", reason:"agent_error"}'
  jq -cn '{at:"2026-11-02T00:00:00Z", event:"finished", project:"replay", signature:"r:4", outcome:"pr_opened", artifact:"https://github.com/acme/r/pull/4"}'
  jq -cn '{at:"2026-11-03T00:00:00Z", event:"finished", project:"replay", signature:"r:4", outcome:"failed", reason:"agent_error"}'
  jq -cn '{at:"2026-11-04T00:00:00Z", event:"finished", project:"replay", signature:"r:4", outcome:"failed", reason:"agent_error"}'
} >>"$AF_DATA/autofix/runs.jsonl"
assert_eq "r:1:resolved:1:0 r:2:declined:1:0 r:3:failed:0:0 r:4:failed:1:2" \
  "$(HARNESS_METRICS_DIR="$AF_DATA" "$ROOT/scripts/autofix-auto.sh" status --project replay | jq -sr 'map("\(.signature):\(.status):\(.attempts):\(.fails // 0)") | sort | join(" ")')" \
  "a lost state file is replayed through merge, resolve and decline events, and a usage-limit failure is not a failure"
# attempting에 머문 시그니처는 시작 뒤 첫 결과로 옮기고, command_run처럼 PR이 아닌 결과는 시도로 세지 않는다.
af_state '.signatures["att:1"] = {status:"attempting",launched_at:"2026-11-03T00:00:00Z",attempts:1,fails:0} | .signatures["att:2"] = {status:"attempting",launched_at:"2026-11-03T00:00:00Z",attempts:1,fails:0}'
jq -cn '{at:"2026-11-03T00:05:00Z", event:"finished", project:"af-svc", signature:"att:1", outcome:"failed", reason:"agent_error"},
  {at:"2026-11-03T00:05:00Z", event:"finished", project:"af-svc", signature:"att:2", outcome:"failed", reason:"usage_limit"}' >>"$AF_DATA/autofix/runs.jsonl"
af_auto verify --project af-svc
assert_eq "failed:0:1 failed:0:0" "$(jq -r '[.signatures["att:1"], .signatures["att:2"]] | map("\(.status):\(.attempts):\(.fails)") | join(" ")' "$AF_STATE_FILE")" \
  "a stuck attempt takes its first result; a usage limit counts neither as an attempt nor as a failure"
# 스냅샷 뒤 worker가 먼저 결과를 남겼으면(경합) 복구는 다시 반영하지 않는다 — 시도·실패 수가 두 번 바뀌지 않게.
af_state '.signatures["att:3"] = {status:"attempting",launched_at:"2026-11-05T00:00:00Z",attempts:1,fails:0}'
jq -cn '{at:"2026-11-05T00:05:00Z", event:"finished", project:"af-svc", signature:"att:3", outcome:"failed", reason:"agent_error"}' >>"$AF_DATA/autofix/runs.jsonl"
cat >"$AF_STUB/recover-hook" <<EOF
#!/usr/bin/env bash
# 복구가 쓰기 직전에 worker가 끝난 것처럼 결과를 먼저 남긴다.
[[ "\$2" == "att:3" ]] || exit 0
jq '.signatures["att:3"] += {status:"failed",attempts:0,fails:1}' "$AF_STATE_FILE" >"$AF_STUB/st.race" && mv "$AF_STUB/st.race" "$AF_STATE_FILE"
EOF
chmod +x "$AF_STUB/recover-hook"
HM_AUTOFIX_TEST_RECOVER_HOOK="$AF_STUB/recover-hook" af_auto verify --project af-svc
assert_eq "failed:0:1" "$(jq -r '.signatures["att:3"] | "\(.status):\(.attempts):\(.fails)"' "$AF_STATE_FILE")" \
  "recovery does not apply a result the worker already wrote after the snapshot"
case "$(<"$AF_DATA/autofix/runs.jsonl")" in *'"event":"recovered","project":"af-svc","signature":"att:3"'*) fail "a recovery that did not apply is not logged" ;; esac
cp "$AF_STUB/state.saved" "$AF_STATE_FILE"
cp "$AF_STUB/runs.saved" "$AF_DATA/autofix/runs.jsonl"
pass "autofix state write failures and lost state files"

# 로컬 monitor 설정: ~/.ai-harness/autofix/monitors/<project_id>.json이 기준 브랜치 manifest의 monitor보다 앞서고,
# 같은 검증을 받는다. 켜기·상태가 로컬이므로 설정도 저장소에 커밋하지 않고 둘 수 있어야 한다.
AFL_DATA="$TEST_TMP/autofix-local-data"
AFL_REPO="$TEST_TMP/autofix-local-repo"
mkdir -p "$AFL_REPO/.ai-harness" "$AFL_REPO/tools" "$AFL_DATA/autofix/monitors"
git -C "$AFL_REPO" init -q
git -C "$AFL_REPO" config user.email test@example.com
git -C "$AFL_REPO" config user.name test
for afl_src in manifest local; do
  # shellcheck disable=SC2016  # 생성할 어댑터 스크립트의 $1을 문자 그대로 쓴다
  printf '#!/usr/bin/env bash\n[[ "$1" == list ]] && printf '"'"'{"signature":"src:%s","count":20}\\n'"'"'\nexit 0\n' "$afl_src" >"$AFL_REPO/tools/$afl_src.sh"
  chmod +x "$AFL_REPO/tools/$afl_src.sh"
done
afl_manifest() { # $1=monitor json 또는 null → 커밋
  jq -n --argjson m "$1" '{project_id:"af-loc",level:"standard"} + (if $m == null then {} else {monitor:$m} end)' >"$AFL_REPO/.ai-harness/harness.json"
  git -C "$AFL_REPO" add -A && git -C "$AFL_REPO" commit -q -m "manifest"
}
afl_local() { printf '%s\n' "$1" >"$AFL_DATA/autofix/monitors/af-loc.json"; }
afl_list() { # → "rc|signature"
  local out="" rc=0
  out="$(HARNESS_METRICS_DIR="$AFL_DATA" "$ROOT/scripts/monitor-fetch.sh" list --root "$AFL_REPO" 2>/dev/null)" || rc=$?
  printf '%s|%s\n' "$rc" "$(jq -r '.signature' <<<"$out" 2>/dev/null | paste -sd, -)"
}
afl_candidates() {
  HARNESS_METRICS_DIR="$AFL_DATA" HM_AUTOFIX_REPOS="af-loc" HM_AUTOFIX_REPOS_CMD="$ROOT/scripts/sync-auto.sh repos --root $AFL_REPO" \
    "$ROOT/scripts/autofix-auto.sh" candidates --project af-loc 2>/dev/null | jq -r '.signature' | paste -sd, -
}
afl_manifest '{"provider":"command","command":"tools/manifest.sh"}'
assert_eq "0|src:manifest" "$(afl_list)" "without a local file the base-branch manifest monitor is used"
afl_local '{"provider":"command","command":"tools/local.sh"}'
assert_eq "0|src:local" "$(afl_list)" "the local monitor file wins over the manifest"
assert_eq "src:local" "$(afl_candidates)" "autofix candidates use the local monitor file"
afl_manifest null
assert_eq "0|src:local" "$(afl_list)" "a local file works without any monitor in the manifest"
assert_eq "src:local" "$(afl_candidates)" "a repo monitored only locally is an autofix target"
AFL_RC=0
HARNESS_METRICS_DIR="$AFL_DATA" HM_AUTOFIX_REPOS="af-loc" HM_AUTOFIX_REPOS_CMD="$ROOT/scripts/sync-auto.sh repos --root $AFL_REPO" \
  "$ROOT/scripts/autofix-auto.sh" track --project af-loc --candidate '{"signature":"src:local","count":20}' --pr https://github.com/acme/loc/pull/1 || AFL_RC=$?
assert_eq "0" "$AFL_RC" "a PR of a locally monitored repo can be tracked"
find "$AFL_DATA/autofix/monitors/af-loc.json" -delete
assert_eq "5|" "$(afl_list)" "no local file and no manifest monitor is reported as missing settings"
AFL_RC=0; HARNESS_METRICS_DIR="$AFL_DATA" "$ROOT/scripts/monitor-fetch.sh" check --root "$AFL_REPO" >/dev/null 2>&1 || AFL_RC=$?
assert_eq "5" "$AFL_RC" "check tells missing settings (exit 5) apart so /autofix can route to setup"
assert_eq "" "$(afl_candidates)" "a repo with no monitor settings is not an autofix target"
afl_manifest '{"provider":"command","command":"tools/manifest.sh"}'
afl_local 'not json'
assert_eq "4|" "$(afl_list)" "a broken local file is rejected, not silently replaced by the manifest"
assert_eq "" "$(afl_candidates)" "a broken local file keeps the repo out of autofix"
afl_local '{"command":"tools/local.sh"}'
assert_eq "4|" "$(afl_list)" "a local file without provider is rejected"
afl_local '{"provider":"command","command":"/bin/sh"}'
assert_eq "4|" "$(afl_list)" "a local command adapter must also live inside the repo"
afl_local '{"provider":"command","command":"../x.sh"}'
assert_eq "4|" "$(afl_list)" "a local command adapter path cannot climb out"
afl_local '{"provider":"sentry","org":"a","project":"b","base_url":"https://evil.example.com"}'
AFL_RC=0; HARNESS_METRICS_DIR="$AFL_DATA" SENTRY_AUTH_TOKEN=t "$ROOT/scripts/monitor-fetch.sh" list --root "$AFL_REPO" >/dev/null 2>&1 || AFL_RC=$?
assert_eq "4" "$AFL_RC" "a local file cannot send the sentry token to another host either"
find "$AFL_DATA/autofix/monitors/af-loc.json" -delete
pass "autofix monitor settings: local file first, manifest fallback, same validation"

# 보드 '자동 수정' 준비 상태(#278): describe는 네트워크 없이 설정 출처·provider·요약·자격증명 유무만 낸다. 값은 어디에도 싣지 않는다.
afl_describe() { # [VAR=값 ...] → describe JSON
  env -u SENTRY_AUTH_TOKEN -u HM_SENTRY_TOKEN -u DATADOG_API_KEY -u DATADOG_APP_KEY -u DD_API_KEY -u DD_APP_KEY -u HM_DATADOG_API_KEY -u HM_DATADOG_APP_KEY \
    HARNESS_METRICS_DIR="$AFL_DATA" HARNESS_CLAUDE_SETTINGS="$AFL_DATA/no-settings.json" "$@" "$ROOT/scripts/monitor-fetch.sh" describe --root "$AFL_REPO"
}
afl_d() { jq -r '[.project, .source, .provider, .summary, .credentials, (.code | tostring)] | join("|")' <<<"$1"; }
afl_manifest '{"provider":"sentry","org":"acme","project":"web","environment":"prod"}'
AFL_D="$(afl_describe)"
assert_eq "af-loc|manifest|sentry|acme/web (prod)|missing|4" "$(afl_d "$AFL_D")" "describe: manifest monitor without a token is a credential problem"
assert_contains "$(jq -r '.problem' <<<"$AFL_D")" "SENTRY_AUTH_TOKEN" "describe names the missing credential"
AFL_D="$(afl_describe SENTRY_AUTH_TOKEN=leak-me-0123456789)"
assert_eq "af-loc|manifest|sentry|acme/web (prod)|present|0" "$(afl_d "$AFL_D")" "describe: a token in the environment counts as present"
case "$AFL_D" in *leak-me*) fail "describe never prints a credential value" ;; esac
printf '{"env":{"SENTRY_AUTH_TOKEN":"leak-me-settings"}}\n' >"$AFL_DATA/claude-settings.json"
AFL_D="$(afl_describe HARNESS_CLAUDE_SETTINGS="$AFL_DATA/claude-settings.json")"
assert_eq "present" "$(jq -r '.credentials' <<<"$AFL_D")" "describe: a token in Claude settings env counts as present"
case "$AFL_D" in *leak-me*) fail "describe never prints a credential value from settings" ;; esac
afl_local '{"provider":"datadog","query":"service:web status:error"}'
assert_eq "af-loc|local|datadog|service:web status:error|missing|4" "$(afl_d "$(afl_describe DATADOG_API_KEY=only-one)")" "describe: the local file wins and datadog needs both keys"
afl_local '{"provider":"command","command":"tools/local.sh"}'
assert_eq "af-loc|local|command|tools/local.sh|not_needed|0" "$(afl_d "$(afl_describe)")" "describe: a command adapter needs no credential"
afl_local 'not json'
AFL_D="$(afl_describe)"
assert_eq "local|4" "$(jq -r '"\(.source)|\(.code)"' <<<"$AFL_D")" "describe: a broken local file is a settings problem, not the manifest"
find "$AFL_DATA/autofix/monitors/af-loc.json" -delete
afl_manifest null
assert_eq "af-loc|none|||not_needed|5" "$(afl_d "$(afl_describe)")" "describe: no monitor settings anywhere is exit-5 none"
AFL_RC=0; afl_describe >/dev/null 2>&1 || AFL_RC=$?
assert_eq "0" "$AFL_RC" "describe reports missing settings in its output, not as a failure"
pass "monitor-fetch describe: source, provider, summary and credential presence without values"

# 수동 후보 조회는 무인 실행 허용 목록(HM_AUTOFIX_REPOS)과 무관하게 그 저장소의 monitor 설정으로 계산한다.
# 무인 실행 없이 수동으로만 쓰는 사람도 후보를 볼 수 있어야 한다. 검증 대상 등록(track)의 허용 목록 규칙은 그대로다.
# 앞 블록의 track이 src:local을 pr_open으로 올렸으므로 추적되지 않은 시그니처(src:manifest)를 내는 어댑터를 쓴다.
afl_local '{"provider":"command","command":"tools/manifest.sh"}'
assert_eq "src:manifest" "$(HARNESS_METRICS_DIR="$AFL_DATA" HM_AUTOFIX_REPOS="" \
  "$ROOT/scripts/autofix-auto.sh" candidates --project af-loc --root "$AFL_REPO" 2>/dev/null | jq -r '.signature')" \
  "manual candidates work for a repo outside HM_AUTOFIX_REPOS"
assert_eq "src:manifest" "$(HARNESS_METRICS_DIR="$AFL_DATA" HM_AUTOFIX_REPOS="other" HM_AUTOFIX_REPOS_CMD="$ROOT/scripts/sync-auto.sh repos --root $AFL_REPO" \
  "$ROOT/scripts/autofix-auto.sh" candidates --project af-loc 2>/dev/null | jq -r '.signature')" \
  "manual candidates without --root find the repo without the allow-list"
AFL_RC=0; HARNESS_METRICS_DIR="$AFL_DATA" "$ROOT/scripts/autofix-auto.sh" candidates --project other-id --root "$AFL_REPO" >/dev/null 2>&1 || AFL_RC=$?
assert_eq "2" "$AFL_RC" "candidates refuse a --project that does not match the --root repo"
AFL_RC=0; HARNESS_METRICS_DIR="$AFL_DATA" HM_AUTOFIX_REPOS="other" HM_AUTOFIX_REPOS_CMD="$ROOT/scripts/sync-auto.sh repos --root $AFL_REPO" \
  "$ROOT/scripts/autofix-auto.sh" track --project af-loc --candidate '{"signature":"src:local","count":20}' --pr https://github.com/acme/loc/pull/2 >/dev/null 2>&1 || AFL_RC=$?
assert_eq "3" "$AFL_RC" "track still requires the allow-list"
find "$AFL_DATA/autofix/monitors/af-loc.json" -delete
pass "manual autofix candidates are not bound to the unattended allow-list"

# setup 보조: discover가 실제 데이터(최근 에러의 service·env / project·environment별 건수)를 보여 줘
# 사용자가 고르게 한다. 저장소 설정 없이 돌고, 자격증명 전송처 제한은 list와 같다.
AFD_STUB="$TEST_TMP/autofix-discover"
mkdir -p "$AFD_STUB"
cat >"$AFD_STUB/http" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "$1" "$2" "${3:-}" >>"$AFD_STUB/http.log"
case "$2" in
  https://api.datadoghq.eu/api/v2/logs/analytics/aggregate)
    printf '%s\n' '{"data":{"buckets":[{"by":{"service":"api","env":"prod"},"computes":{"c0":120}},{"by":{"service":"web worker","env":"staging"},"computes":{"c0":7}},{"by":{"service":"batch"},"computes":{"c0":3}}]}}' ;;
  https://sentry.io/api/0/organizations/acme/events/\?*)
    printf '%s\n' '{"data":[{"project":"api","environment":"production","count()":42,"count_unique(issue)":5},{"project":"web","environment":null,"count()":2,"count_unique(issue)":1}]}' ;;
  https://sentry.io/api/0/organizations/)
    printf '%s\n' '[{"slug":"acme","name":"Acme"}]' ;;
  *) echo "unexpected $2" >&2; exit 9 ;;
esac
EOF
chmod +x "$AFD_STUB/http"
export AFD_STUB
afd() { HARNESS_METRICS_DIR="$AFL_DATA" HM_MONITOR_HTTP="$AFD_STUB/http" "$ROOT/scripts/monitor-fetch.sh" discover "$@"; }
AFD_DD="$(afd --provider datadog --site datadoghq.eu --hours 6)"
assert_eq "3" "$(printf '%s\n' "$AFD_DD" | grep -c .)" "datadog discover prints one line per service/env"
assert_eq "api|prod|120|service:api env:prod status:error" "$(head -n 1 <<<"$AFD_DD" | jq -r '"\(.service)|\(.env)|\(.count)|\(.query)"')" \
  "datadog discover counts errors per service and env with a ready query"
assert_eq 'service:"web worker" env:staging status:error' "$(sed -n 2p <<<"$AFD_DD" | jq -r '.query')" "discover quotes values with spaces"
assert_eq "|service:batch status:error" "$(sed -n 3p <<<"$AFD_DD" | jq -r '"\(.env)|\(.query)"')" "a service without env gets no env term"
assert_contains "$(<"$AFD_STUB/http.log")" '"from":"now-6h"' "datadog discover honours --hours"
assert_contains "$(<"$AFD_STUB/http.log")" '"query":"status:error"' "datadog discover aggregates error logs"
AFD_SE="$(afd --provider sentry --org acme)"
assert_eq "acme|api|production|42|5" "$(head -n 1 <<<"$AFD_SE" | jq -r '"\(.org)|\(.project)|\(.environment)|\(.events)|\(.issues)"')" \
  "sentry discover counts events and issues per project and environment"
assert_eq "" "$(sed -n 2p <<<"$AFD_SE" | jq -r '.environment')" "sentry discover keeps events without an environment"
assert_contains "$(grep 'organizations/acme/events' "$AFD_STUB/http.log")" "statsPeriod=24h" "sentry discover defaults to 24 hours"
assert_eq "acme" "$(afd --provider sentry | jq -r '.org')" "sentry discover without --org lists organizations"
AFD_RC=0; afd --provider datadog --site evil.example.com >/dev/null 2>&1 || AFD_RC=$?
assert_eq "4" "$AFD_RC" "discover cannot send datadog keys to another host"
AFD_RC=0; afd --provider sentry --org acme --base-url https://evil.example.com >/dev/null 2>&1 || AFD_RC=$?
assert_eq "4" "$AFD_RC" "discover cannot send the sentry token to another host"
AFD_RC=0; HARNESS_METRICS_DIR="$AFL_DATA" HARNESS_CLAUDE_SETTINGS=/nonexistent DATADOG_API_KEY="" DATADOG_APP_KEY="" DD_API_KEY="" DD_APP_KEY="" HM_DATADOG_API_KEY="" HM_DATADOG_APP_KEY="" \
  "$ROOT/scripts/monitor-fetch.sh" discover --provider datadog >/dev/null 2>&1 || AFD_RC=$?
assert_eq "4" "$AFD_RC" "discover without credentials is a config error"
AFD_RC=0; afd --provider command >/dev/null 2>&1 || AFD_RC=$?
assert_eq "2" "$AFD_RC" "discover supports only datadog and sentry"
pass "monitor-fetch discover lists real service/env choices for setup"

# save(#450): 보드 설정 폼이 만든 monitor를 개인 로컬 파일에만 쓴다. 검증에 걸리면 아무것도 쓰지 않는다.
afs() { env -u SENTRY_AUTH_TOKEN -u HM_SENTRY_TOKEN -u DATADOG_API_KEY -u DATADOG_APP_KEY HARNESS_METRICS_DIR="$AFL_DATA" HARNESS_CLAUDE_SETTINGS=/nonexistent \
  "$ROOT/scripts/monitor-fetch.sh" save --root "$AFL_REPO" --monitor "$1"; }
afs_rc() { local rc=0; afs "$1" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
AFS_FILE="$AFL_DATA/autofix/monitors/af-loc.json"
for afs_bad in 'nope' '[1]' '{} {}' '{"provider":"datadog"}' '{"provider":"datadog","query":"q","foo":1}' '{"provider":"command","command":"tools/x.sh"}' \
  '{"provider":"sentry","org":"a/b","project":"p"}' '{"provider":"datadog","query":"q","min_events":-1}' '{"provider":"datadog","query":"q","window_hours":1.5}' \
  '{"provider":"datadog","query":"q","deploy_branch":"a b"}'; do
  assert_eq "2" "$(afs_rc "$afs_bad")" "save rejects $afs_bad"
done
assert_eq "4" "$(afs_rc '{"provider":"datadog","query":"q","site":"evil.example.com"}')" "save keeps the datadog site rule"
assert_eq "4" "$(afs_rc '{"provider":"sentry","org":"a","project":"b","base_url":"https://evil.example.com"}')" "save keeps the sentry host rule"
[[ ! -e "$AFS_FILE" ]] || fail "a rejected save writes nothing"
AFS_OUT="$(afs '{"provider":"datadog","query":"service:api env:prod status:error","window_hours":48}')"
assert_eq "af-loc|$AFS_FILE" "$(jq -r '"\(.project)|\(.file)"' <<<"$AFS_OUT")" "save writes the repo's local monitor file even without credentials"
assert_eq "service:api env:prod status:error|48" "$(jq -r '"\(.query)|\(.window_hours)"' "$AFS_FILE")" "save keeps the monitor as given"
assert_eq "600" "$(stat -c %a "$AFS_FILE" 2>/dev/null || stat -f %Lp "$AFS_FILE")" "the monitor file is private"
assert_eq "local|datadog" "$(afl_describe | jq -r '"\(.source)|\(.provider)"')" "describe reads what save wrote"
assert_eq "2" "$(afs_rc '{"provider":"datadog","query":""}')" "a bad save after a good one fails"
assert_eq "service:api env:prod status:error" "$(jq -r '.query' "$AFS_FILE")" "a failed save keeps the previous file"
find "$AFS_FILE" -delete
pass "monitor-fetch save writes a validated personal monitor file"

# /autofix: 설정이 없으면 setup으로 넘어가고, setup 절차는 별도 파일에 둔다(수정 실행 때 setup 절차를 같이 읽지 않게).
assert_file "$ROOT/skills/autofix/setup.md"
AF_SKILL="$(<"$ROOT/skills/autofix/SKILL.md")"
assert_contains "$AF_SKILL" "setup.md" "autofix SKILL routes to setup.md"
assert_contains "$AF_SKILL" "exit 5" "autofix manual path checks for missing settings first"
assert_contains "$AF_SKILL" "candidates --project <id> --root ." "autofix manual candidates use the current repo"
AF_SETUP="$(<"$ROOT/skills/autofix/setup.md")"
assert_contains "$AF_SETUP" "monitor-fetch.sh discover" "setup shows discover results"
assert_contains "$AF_SETUP" "autofix-auto.sh configure" "setup still writes the unattended settings"
pass "autofix routes missing settings to a separate setup procedure"

# 짧은 주기 sweep과 backfill 경로 sweep이 겹치면 늦게 온 쪽은 아무것도 하지 않는다.
mkdir -p "$AF_DATA/autofix/.sweep.lock"
printf '%s\n' "$$" >"$AF_DATA/autofix/.sweep.lock/pid"
af_state 'del(.signatures["sentry:101"])'
AF_BEFORE="$(<"$AF_STUB/agent-count")"
af_auto sweep
assert_eq "$AF_BEFORE" "$(<"$AF_STUB/agent-count")" "a sweep already running blocks a second one"
find "$AF_DATA/autofix/.sweep.lock" -depth -delete
af_auto sweep
assert_eq "$((AF_BEFORE + 1))" "$(<"$AF_STUB/agent-count")" "the next sweep runs once the lock is free"
pass "autofix sweeps do not overlap"

# /autofix setup의 무인 실행 설정: 개인 config의 해당 키만 바꾸고 다른 줄·주석·권한은 남기며, 틀린 값은 아무것도 쓰지 않는다.
AFC_DATA="$TEST_TMP/autofix-config-data"
mkdir -p "$AFC_DATA"
printf '# 내 설정\nHM_HARVEST_AUTO=1\nHM_AUTOFIX_DAILY_MAX=7\nexport HM_AUTOFIX_REPOS="svc-a svc-b"\n' >"$AFC_DATA/config"
chmod 640 "$AFC_DATA/config"
afc() { env -u HM_AUTOFIX_REPOS -u HM_AUTOFIX_AUTO -u HM_AUTOFIX_DAILY_MAX HARNESS_METRICS_DIR="$AFC_DATA" "$ROOT/scripts/autofix-auto.sh" configure "$@"; }
assert_eq "false|svc-a,svc-b|null|7|2|10" "$(afc | jq -r '[.auto, (.repos | join(",")), .interval_minutes, .daily_max, .max_attempts, .budget_usd] | map(tostring) | join("|")')" "configure without flags shows the current values and defaults"
afc --auto 1 --add-repo svc-c --interval-minutes 10 --daily-max 4 --max-attempts 3 --budget-usd 2.5 >/dev/null
AFC_CFG="$(<"$AFC_DATA/config")"
assert_contains "$AFC_CFG" "# 내 설정" "comments are kept"
assert_contains "$AFC_CFG" "HM_HARVEST_AUTO=1" "other keys are kept"
assert_contains "$AFC_CFG" 'HM_AUTOFIX_REPOS="svc-a,svc-b,svc-c"' "the repo is added to the existing list"
assert_contains "$AFC_CFG" 'HM_AUTOFIX_INTERVAL_MINUTES="10"' "the sweep interval is written"
assert_contains "$AFC_CFG" 'HM_AUTOFIX_BUDGET_USD="2.5"' "a decimal budget is accepted"
assert_eq "1" "$(grep -c 'HM_AUTOFIX_DAILY_MAX' "$AFC_DATA/config")" "an existing key is replaced, not duplicated"
assert_eq "640" "$(filemode "$AFC_DATA/config")" "the config file keeps its permissions"
afc --add-repo svc-a --interval-minutes off >/dev/null
assert_eq "svc-a,svc-b,svc-c|0" "$(sed -n 's/^HM_AUTOFIX_REPOS="\(.*\)"$/\1/p' "$AFC_DATA/config")|$(grep -c 'HM_AUTOFIX_INTERVAL_MINUTES' "$AFC_DATA/config")" "an already listed repo is not added twice; off removes the interval"
AFC_BEFORE="$(<"$AFC_DATA/config")"
for afc_bad in "--daily-max x" "--max-attempts 0" "--budget-usd 0" "--budget-usd 1e3" "--interval-minutes 1.5" "--auto yes" "--add-repo a,b"; do
  AFC_RC=0
  # shellcheck disable=SC2086  # 플래그와 값을 나눠 넘긴다
  afc --auto 0 $afc_bad >/dev/null 2>&1 || AFC_RC=$?
  assert_eq "2" "$AFC_RC" "configure rejects $afc_bad"
done
assert_eq "$AFC_BEFORE" "$(<"$AFC_DATA/config")" "a rejected value changes nothing, not even the valid flags"
pass "autofix configure updates only its keys in the personal config"

afc --remove-repo svc-b >/dev/null
assert_contains "$(<"$AFC_DATA/config")" 'HM_AUTOFIX_REPOS="svc-a,svc-c"' "configure removes a repo from the list"
AFC_BEFORE="$(<"$AFC_DATA/config")"
afc --remove-repo not-listed >/dev/null
assert_eq "$AFC_BEFORE" "$(<"$AFC_DATA/config")" "removing a repo that is not listed changes nothing"
AFC_RC=0; afc --remove-repo 'a b' >/dev/null 2>&1 || AFC_RC=$?
assert_eq "2|$AFC_BEFORE" "$AFC_RC|$(<"$AFC_DATA/config")" "configure rejects a bad --remove-repo and writes nothing"
afc --remove-repo svc-a >/dev/null; afc --remove-repo svc-c >/dev/null
assert_eq "0" "$(grep -c 'HM_AUTOFIX_REPOS' "$AFC_DATA/config")" "removing the last repo removes the line"
assert_eq "[]" "$(afc | jq -c '.repos')" "configure shows an empty target list"
pass "autofix configure removes target repos"

# 제한 없음: 하루 상한은 보드 harvest·sync와 같은 관례(1000 = 제한 없음), 실행당 예산은 명시값 unlimited. 0은 그대로 '하루 0회'.
afc --daily-max unlimited --budget-usd unlimited --interval-minutes 90 >/dev/null
AFC_CFG="$(<"$AFC_DATA/config")"
assert_contains "$AFC_CFG" 'HM_AUTOFIX_DAILY_MAX="1000"' "daily max unlimited is written as the board's unlimited value"
assert_contains "$AFC_CFG" 'HM_AUTOFIX_BUDGET_USD="unlimited"' "budget unlimited is written explicitly"
assert_contains "$AFC_CFG" 'HM_AUTOFIX_INTERVAL_MINUTES="90"' "a custom interval in minutes is written"
assert_eq "1000|true|unlimited|90" "$(afc | jq -r '"\(.daily_max)|\(.daily_unlimited)|\(.budget_usd)|\(.interval_minutes)"')" "configure shows unlimited values"
afc --daily-max 0 --budget-usd 3 >/dev/null
assert_eq "0|false|3" "$(afc | jq -r '"\(.daily_max)|\(.daily_unlimited)|\(.budget_usd)"')" "0 keeps meaning zero runs a day and a number replaces unlimited"
AFC_BEFORE="$(<"$AFC_DATA/config")"
for afc_bad in "--daily-max unlimit" "--daily-max -1" "--daily-max 08" "--daily-max 01000" "--daily-max 99999999999999999999" "--interval-minutes 99999999999999999999" "--max-attempts 99999999999999999999" "--budget-usd Unlimited" "--budget-usd none" "--interval-minutes 0x5" "--interval-minutes -5"; do
  AFC_RC=0
  # shellcheck disable=SC2086  # 플래그와 값을 나눠 넘긴다
  afc --auto 1 $afc_bad >/dev/null 2>&1 || AFC_RC=$?
  assert_eq "2" "$AFC_RC" "configure rejects $afc_bad"
done
assert_eq "$AFC_BEFORE" "$(<"$AFC_DATA/config")" "a rejected unlimited-like value changes nothing"
pass "autofix configure accepts unlimited daily max and budget and custom intervals"

finish_tests
