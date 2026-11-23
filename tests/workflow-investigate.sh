#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — investigate 워크플로(원인 조사: 기준 커밋·보고 파일·fix-bug 인계) (#342)
# 러너: templates/workflow-driver/workflow-driver.sh, 그래프: templates/investigate/references/investigate-graph.json
# 실행: bash tests/run.sh workflow-investigate
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

mkdir -p "$DRIVER_TMP/data"
INV_DATA="$(cd "$DRIVER_TMP/data" && pwd -P)/investigations"
latest_run() { # 이 저장소의 최근 실행 디렉터리(러너가 남긴 latest)
  local d
  d="$(find "$DRIVER_TMP/runs" -maxdepth 1 -name "$(basename "$DRIVER_REPO")-*" | head -n 1)"
  printf '%s/%s' "$d" "$(<"$d/latest")"
}
latest_state() { jq -r "$1" "$(latest_run)/state.json"; }
inv_history() { latest_state '[.history[] | .to] | join(">")'; }
# 기준 브랜치 main을 origin에 올리고 origin/HEAD를 main으로 둔다.
publish_base() {
  git -C "$DRIVER_REPO" branch -M main
  git -C "$DRIVER_REPO" push -q -u origin main 2>/dev/null
  git -C "$DRIVER_REPO" remote set-head origin main
}

# 조사는 코드를 고치지 않는다. pr-only 저장소의 기준 브랜치·더러운 작업 트리에서도 승인 대기 없이 끝까지 간다.
new_driver_repo inv_ok
with_policy pr-only ""
publish_base
echo scratch >"$DRIVER_REPO/notes.txt"
STATUS_BEFORE="$(git -C "$DRIVER_REPO" status --porcelain)"
driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "0:done" "$DRIVER_RC:$(latest_state .status)" "investigate runs to done in one go"
assert_eq "false" "$(latest_state .policy.commits)" "investigate never commits"
assert_eq "baseline>domain_docs>reproduce>report>handoff>done" "$(inv_history)" "investigate follows the graph from triage"
assert_eq "$STATUS_BEFORE" "$(git -C "$DRIVER_REPO" status --porcelain)" "the investigation leaves the working tree as it was"
assert_contains "$(<"$FAKE_LOG")" "domain_docs read-only" "domain_docs is a read-only session"
assert_contains "$(<"$FAKE_LOG")" "report read-only schema=yes" "report is a read-only session with a schema"
case "$(<"$FAKE_LOG")" in *baseline*|*handoff*) fail "baseline and handoff run without a session" ;; esac
assert_contains "$(<"$FAKE_LOG.reproduce.prompt")" "You are the reproduce node of the investigate graph" "reproduce names the investigate graph"
assert_contains "$(<"$FAKE_LOG.reproduce.prompt")" "read_from" "reproduce reads the baseline"
assert_contains "$(<"$FAKE_LOG.reproduce.prompt")" "total is subtotal plus tax" "reproduce reads the domain contract"
assert_contains "$(<"$FAKE_LOG.domain_docs.prompt")" "You are the domain_docs node of the investigate graph. Do not edit any file." "domain_docs prompt"
pass "investigate runs triage to done without approval on a pr-only base branch"

# 보고는 러너가 저장소·실행 디렉터리 밖에 쓴다. 첫머리에 기준 커밋, comment가 있으면 초안 파일.
REPORT="$(latest_state .investigation_report.path)"
assert_file "$REPORT"
case "$REPORT" in "$INV_DATA/repo-inv_ok/"*.md) ;; *) fail "report lives under the investigations folder (actual=$REPORT)" ;; esac
case "$REPORT" in "$DRIVER_REPO"/*|"$DRIVER_TMP/runs"/*) fail "report is outside the repository and run folder" ;; esac
assert_contains "$(head -n 1 "$REPORT")" "기준 커밋: $(git -C "$DRIVER_REPO" rev-parse origin/main) (working_tree, behind 0)" "the report names the commit it read"
assert_contains "$(<"$REPORT")" "tax is skipped when the discount is zero" "the report body follows"
assert_eq "${REPORT%.md}.comment.md" "$(latest_state .investigation_report.comment)" "the comment draft sits next to the report"
assert_contains "$(<"${REPORT%.md}.comment.md")" "할인이 0일 때" "the comment draft holds the node's comment"
assert_eq "code_fix_needed" "$(latest_state .investigation_report.outcome)" "the outcome is recorded"
assert_eq "0" "$(latest_state .code_baseline.behind)" "an up-to-date checkout is not behind"
assert_eq "main:ok:working_tree" "$(latest_state '"\(.code_baseline.base):\(.code_baseline.fetch):\(.code_baseline.read_from)"')" "baseline reads the working tree when up to date"
pass "the investigation report is written outside the repository with its base commit"

# 수정이 필요하면 fix-bug를 그 보고로 시작하는 명령을 남긴다. 그 명령은 triage·reproduce를 건너뛴다.
HANDOFF="$(latest_state .handoff.command)"
assert_contains "$HANDOFF" "start --workflow bug-fix" "handoff starts fix-bug"
assert_contains "$HANDOFF" "--investigation $(printf '%q' "$REPORT")" "handoff passes the report"
assert_contains "$DRIVER_OUT" "code fix needed — next: $HANDOFF" "the result names the next command"
assert_contains "$DRIVER_OUT" "investigation report: $REPORT; comment draft: ${REPORT%.md}.comment.md" "the result names both files"
RUN_DIR_OK="$(latest_run)"
assert_contains "$(<"$RUN_DIR_OK/handoff.out")" "/fix-bug $REPORT" "handoff.out names the skill entry too"
new_driver_repo inv_handoff_target
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$REPORT"
assert_eq "10" "$DRIVER_RC" "fix-bug with the report waits for approval"
assert_eq "investigation_report_provided" "$(run_state 'first(.history[] | select(.from == "triage")) | .outcome')" "fix-bug skips triage with the report"
pass "a needed fix is handed to fix-bug with the report"

# origin이 로컬보다 앞서면 origin/<base>를 읽으라고 남긴다.
new_driver_repo inv_behind
with_policy pr-only ""
publish_base
git clone -q -b main "$DRIVER_TMP/remote-inv_behind.git" "$DRIVER_TMP/clone-inv_behind"
git -C "$DRIVER_TMP/clone-inv_behind" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead
git -C "$DRIVER_TMP/clone-inv_behind" push -q origin HEAD:main 2>/dev/null
driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "0" "$DRIVER_RC" "a behind checkout still finishes"
assert_eq "1:origin/main" "$(latest_state '"\(.code_baseline.behind):\(.code_baseline.read_from)"')" "baseline counts how far behind"
assert_eq "$(git -C "$DRIVER_TMP/clone-inv_behind" rev-parse HEAD)" "$(latest_state .code_baseline.base_commit)" "baseline reads the origin commit"
RUN_DIR_BEHIND="$(latest_run)"
assert_contains "$(<"$RUN_DIR_BEHIND/baseline.out")" "git show origin/main:" "baseline.out tells the nodes to read origin"
assert_contains "$(head -n 1 "$(latest_state .investigation_report.path)")" "(origin/main, behind 1)" "the report names the origin commit"
pass "baseline reads origin when the checkout is behind"

# origin이 없어도 멈추지 않는다.
new_driver_repo inv_no_remote
driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "0:done" "$DRIVER_RC:$(latest_state .status)" "no origin still finishes"
assert_eq "no_remote:working_tree" "$(latest_state '"\(.code_baseline.fetch):\(.code_baseline.read_from)"')" "baseline notes the missing remote"
pass "baseline does not stop without a remote"

# 수정이 필요 없으면 handoff 없이 끝난다.
new_driver_repo inv_no_fix
driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "0" "$DRIVER_RC" "no fix needed finishes"
case "$(inv_history)" in *handoff*) fail "no handoff when no fix is needed" ;; esac
assert_contains "$DRIVER_OUT" "no code fix needed; investigation report: $(latest_state .investigation_report.path)" "the result names the report"
assert_eq "" "$(latest_state .investigation_report.comment)" "an empty comment writes no draft"
assert_eq "" "$(find "$INV_DATA/repo-inv_no_fix" -name '*.comment.md')" "no comment draft file"
pass "no code fix needed ends without a handoff"

# 재현하지 못하면 사람에게 넘기고 보고를 쓰지 않는다.
new_driver_repo repro_blocked
driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "20:user_decision" "$DRIVER_RC:$(latest_state .node)" "blocked reproduction stops for a person"
[[ ! -d "$INV_DATA/repo-repro_blocked" ]] || fail "no report without reproduction"
pass "investigate without reproduction stops at user_decision"

# 읽기 노드가 저장소에 쓰면 멈춘다.
new_driver_repo inv_docs_writes
driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "40:invariant_violation" "$DRIVER_RC:$(latest_state .status)" "domain_docs writing is an invariant violation"
new_driver_repo inv_report_writes
driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "40:invariant_violation" "$DRIVER_RC:$(latest_state .status)" "report writing is an invariant violation"
pass "read-only investigate nodes cannot write"

# 스키마 위반은 미완료다.
new_driver_repo inv_report_bad
driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "30:incomplete" "$DRIVER_RC:$(latest_state .status)" "a report off the schema is incomplete"
pass "report output must match the schema"

# 형식에 맞지 않는 slug는 경로가 되지 않는다.
new_driver_repo inv_bad_slug
driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "0" "$DRIVER_RC" "a bad slug still finishes"
case "$(latest_state .investigation_report.path)" in "$INV_DATA/repo-inv_bad_slug/"*-investigation.md) ;; *) fail "a bad slug falls back to investigation (actual=$(latest_state .investigation_report.path))" ;; esac
[[ ! -e "$DRIVER_TMP/data/evil.md" && ! -e "$DRIVER_TMP/evil.md" ]] || fail "a bad slug cannot escape the folder"
pass "a malformed slug falls back to investigation"

# 같은 분 안에 같은 slug면 -2를 붙이고 앞 보고를 덮지 않는다. 분이 바뀌면 한 번 더 돌린다.
new_driver_repo inv_collide
driver start --workflow investigate --runtime codex --request "total ignores tax"
FIRST="$(latest_state .investigation_report.path)"
FIRST_SUM="$(git hash-object "$FIRST")"
SECOND=""
for _ in 1 2; do
  driver start --workflow investigate --runtime codex --request "total ignores tax"
  SECOND="$(latest_state .investigation_report.path)"
  [[ "${SECOND%.md}" == "${FIRST%.md}-2" ]] && break
  FIRST="$SECOND"
  FIRST_SUM="$(git hash-object "$FIRST")"
done
assert_eq "${FIRST%.md}-2.md" "$SECOND" "a second report in the same minute gets -2"
assert_eq "$FIRST_SUM" "$(git hash-object "$FIRST")" "the first report is kept"
pass "report names never overwrite an earlier report"

# 보고 디렉터리가 저장소 안이면 쓰지 않는다.
new_driver_repo inv_inside
DRIVER_DATA_OVERRIDE="$DRIVER_REPO/.data" driver start --workflow investigate --runtime codex --request "total ignores tax"
assert_eq "30:incomplete" "$DRIVER_RC:$(latest_state .status)" "a report folder inside the repository is refused"
[[ ! -d "$DRIVER_REPO/.data/investigations" ]] || fail "nothing is written inside the repository"
pass "the report folder must be outside the repository"

# claude 런타임도 구조화 출력으로 보고를 받는다.
new_driver_repo inv_claude
driver start --workflow investigate --runtime claude --request "total ignores tax"
assert_eq "0:done" "$DRIVER_RC:$(latest_state .status)" "investigate runs on claude"
assert_file "$(latest_state .investigation_report.path)"
pass "investigate runs on the claude runtime"

# 조사 보고는 bug-fix에만 넘긴다. 사용법·문서 계약.
new_driver_repo inv_usage
echo '# x' >"$DRIVER_TMP/inv-usage.md"
driver start --workflow investigate --runtime codex --request "x" --investigation "$DRIVER_TMP/inv-usage.md"
assert_eq "2" "$DRIVER_RC" "investigate does not take --investigation"
driver start --help
assert_contains "$DRIVER_OUT" "investigate" "usage lists investigate"
INV_SKILL="$(<"$ROOT/templates/investigate/SKILL.md")"
case "$INV_SKILL" in *"does not run this workflow yet"*) fail "the investigate skill says the runner runs it" ;; esac
assert_contains "$INV_SKILL" "--workflow investigate" "the investigate skill names the runner"
assert_contains "$(<"$ROOT/AGENTS.md")" "investigate" "AGENTS.md lists investigate"
cmp -s "$DRIVER" "$ROOT/.ai-harness/workflows/workflow-driver.sh" || fail "the runner copies are byte-identical"
pass "investigate runner contract in usage and docs"

finish_tests
