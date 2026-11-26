#!/usr/bin/env bash
# autofix 영역(tests/autofix*.sh)이 source하는 공용 준비: monitor 설정을 커밋한 저장소와 로컬 bare 원격, 모니터링 HTTP·에이전트·PR 상태 스텁,
# monitor-fetch·autofix-auto 실행 함수. tests/lib.sh 다음에 source한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
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
# 뒤 블록 영역의 앞단: autofix 앞 블록이 남기던 상태(자동 수정이 연 PR 1, 상태 파일·실행 기록·에이전트 호출 수)를 다시 만든다.
af_prime() {
  af_auto sweep
  [[ "$(af_sig '.status')" == pr_open ]] || fail "af_prime: the first sweep did not open a PR"
}
