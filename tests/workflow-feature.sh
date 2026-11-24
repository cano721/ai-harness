#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 승인·검증·수리 루프(feature)
# 실행: bash tests/run.sh workflow-feature
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 드라이버는 그래프를 모델 밖에서 실행한다: 전이는 그래프가, 승인은 사용자가 직접 입력한 메시지가, 완료는 드라이버가 실행한 검증이 정한다.
assert_file "$DRIVER"
assert_file "$DRIVER_SHIM"
assert_contains "$(<"$FEATURE_SKILL")" "workflow-driver.sh start --workflow feature" "feature skill points to the graph runner"
for runner in workflow-driver.sh implement-feature-driver.sh; do
  assert_eq "1" "$(jq --arg p ".ai-harness/workflows/$runner" '[.artifacts[] | select(.path == $p and .level == "standard" and (has("integration") | not) and (has("workflow") | not or $p != ".ai-harness/workflows/workflow-driver.sh"))] | length' "$ROOT/templates/managed-files.json")" "$runner ships to every standard project regardless of integration"
done
# 원본의 merge·deploy 러너 우선 계약은 Codex·Claude 생성물에도 함께 전달된다. (#478)
for adapter in implement-feature fix-bug; do
  for generated in ".agents/skills/$adapter/SKILL.md" ".claude/commands/$adapter.md"; do
    GENERATED_CONTENT="$(<"$ROOT/$generated")"
    assert_contains "$GENERATED_CONTENT" 'HM_DELIVERY_LEVEL_REPOS' "$generated keeps repository-specific delivery levels"
    assert_contains "$GENERATED_CONTENT" 'must use the runner' "$generated requires the runner for merge and deploy"
    assert_contains "$GENERATED_CONTENT" 'delivery level, its setting source, and why it could not be applied' "$generated keeps the first-line unapplied-level report"
    assert_contains "$GENERATED_CONTENT" 'takes precedence over “PR only, do not merge”' "$generated preserves delivery-level precedence in delegation"
  done
done
pass "generated adapters preserve delivery-level runner contracts"
assert_eq "human" "$(jq -r '.nodes.approval.actor' "$FEATURE_GRAPH")" "approval is a human node the runner interrupts at"
DRIVER_RC=0
bash "$DRIVER" >/dev/null 2>&1 || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "runner requires a command"

new_driver_repo ok
driver start --runtime codex --request "add feature"
assert_eq "10:waiting_approval:approval" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "start interrupts at the human approval node"
assert_contains "$DRIVER_OUT" "대화에 \"승인\"이라고 입력" "the brief tells the person how to approve"
assert_eq "discover read-only schema=;brief read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "planning nodes run read-only and nothing writes before approval"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "open_questions" "human approval asks the brief node for open questions"
[[ "$(<"$FAKE_LOG.brief.prompt")" != *"needs_human"* ]] || fail "human approval does not ask the brief node to decide"
driver resume
assert_eq "10" "$DRIVER_RC" "resume without approval stays interrupted"
# 사용자가 친 메시지가 아닌 것은 승인이 아니다: 도구 결과, 모델 메시지, 다른 저장소의 세션.
mkdir -p "$DRIVER_TMP/claude/projects/p"
jq -nc --arg c "$DRIVER_REPO" '{type:"user", cwd:$c, timestamp:"2999-01-01T00:00:00Z", message:{role:"user", content:[{type:"tool_result", content:"승인"}]}}' >>"$DRIVER_TMP/claude/projects/p/ok.jsonl"
jq -nc --arg c "$DRIVER_REPO" '{type:"assistant", cwd:$c, timestamp:"2999-01-01T00:00:00Z", message:{role:"assistant", content:"승인"}}' >>"$DRIVER_TMP/claude/projects/p/ok.jsonl"
say_in_claude "승인" "$DRIVER_TMP/elsewhere"
say_in_claude "승인하지 말고 기다려" 
driver resume
assert_eq "10" "$DRIVER_RC" "tool output, model text, other repos, and non-approval words do not approve"
driver revise --feedback "범위에서 X 빼줘"
assert_eq "10" "$DRIVER_RC" "revise rebuilds the brief and waits again"
assert_contains "$(<"$FAKE_LOG.revise")" "범위에서 X 빼줘" "revise passes the person's feedback to the brief node"
assert_contains "$(run_state '[.history[].outcome] | join(",")')" "brief_changed_or_not_approved" "revise follows the declared approval -> brief edge"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a typed approval lets the run reach done"
assert_eq "claude-transcript" "$(run_state .approval.source)" "approval evidence is recorded"
assert_eq "deliver workspace-write schema=;review read-only schema=yes;" "$(tail -n 2 "$FAKE_LOG" | tr '\n' ';')" "only delivery writes; review is read-only with a schema"
assert_contains "$(run_state .publish.skipped)" "does not allow the agent to commit" "without a permissive git_policy, publish is skipped"
assert_eq "1" "$(git -C "$DRIVER_REPO" rev-list --count HEAD)" "without a permissive git_policy, the runner never commits"

# Codex 대화에서 친 승인도 같은 규칙으로 인정한다.
new_driver_repo codex_ok
driver start --runtime codex --request "add feature"
mkdir -p "$DRIVER_TMP/codex/sessions/2999"
{
  jq -nc --arg c "$DRIVER_REPO" '{type:"session_meta", payload:{cwd:$c}}'
  jq -nc '{type:"event_msg", timestamp:"2999-01-01T00:00:00Z", payload:{type:"user_message", message:"approve"}}'
} >"$DRIVER_TMP/codex/sessions/2999/rollout.jsonl"
driver resume
assert_eq "0:codex-transcript" "$DRIVER_RC:$(run_state .approval.source)" "a typed approval in a Codex session is accepted"

# 실측: Orca 프로필의 CLAUDE_CONFIG_DIR/projects 는 ~/.claude/projects 로 가는 심볼릭 링크다. 링크 안의 대화도 읽는다.
new_driver_repo symlinked_projects
driver start --runtime codex --request "add feature"
mv "$DRIVER_TMP/claude/projects" "$DRIVER_TMP/real-projects"
ln -s "$DRIVER_TMP/real-projects" "$DRIVER_TMP/claude/projects"
say_in_claude "승인"
driver resume
rm "$DRIVER_TMP/claude/projects" && mv "$DRIVER_TMP/real-projects" "$DRIVER_TMP/claude/projects"
assert_eq "0:claude-transcript" "$DRIVER_RC:$(run_state .approval.source)" "an approval is found when the Claude projects folder is a symlink"

# workspace가 인계한 멤버 세션의 승인은 사용자가 workspace 대화에서 멤버 이름을 붙여 친 "승인 <멤버>"로도 받는다(#331).
# 조율 세션이 보낸 세션 간 메시지(isMeta·origin peer)는 승인이 아니다 — 에이전트가 사람 승인을 대신할 수 없다.
WS_ROOT="$DRIVER_TMP/ws"
mkdir -p "$WS_ROOT/.ai-harness"
printf '{"workspace_id":"ws","members":[{"path":"repo-ws_member","project_id":"ws_member"}]}\n' >"$WS_ROOT/.ai-harness/workspace.json"
FAKE_SCENARIO=ok FAKE_LOG="$DRIVER_TMP/ws_member.log"
DRIVER_REPO="$WS_ROOT/repo-ws_member"
mkdir -p "$DRIVER_REPO" && git -C "$DRIVER_REPO" init -q && git -C "$DRIVER_REPO" config user.email t@t && git -C "$DRIVER_REPO" config user.name t
git -C "$DRIVER_REPO" commit -q --allow-empty -m init
DRIVER_REPO="$(git -C "$DRIVER_REPO" rev-parse --show-toplevel)" WS_ROOT="$(cd "$WS_ROOT" && pwd -P)"
: >"$FAKE_LOG"
driver start --runtime codex --request "add feature"
assert_contains "$DRIVER_OUT" "승인 repo-ws_member" "a member run inside a workspace says how to approve from the workspace conversation"
say_in_claude "승인" "$WS_ROOT"
say_in_claude "승인 repo-other" "$WS_ROOT"
mkdir -p "$DRIVER_TMP/claude/projects/p"
jq -nc --arg c "$DRIVER_REPO" '{type:"user", isMeta:true, cwd:$c, timestamp:"2999-01-01T00:00:00Z", origin:{kind:"peer"}, message:{role:"user", content:"승인"}}' >>"$DRIVER_TMP/claude/projects/p/ok.jsonl"
jq -nc --arg c "$DRIVER_REPO" '{type:"user", cwd:$c, timestamp:"2999-01-01T00:00:00Z", origin:{kind:"coordinator"}, message:{role:"user", content:"승인"}}' >>"$DRIVER_TMP/claude/projects/p/ok.jsonl"
driver resume
assert_eq "10" "$DRIVER_RC" "a bare or other-member approval in the workspace and messages from other sessions do not approve"
say_in_claude "승인 repo-ws_member" "$WS_ROOT"
driver resume
assert_eq "0:done:claude-transcript" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source)" "the person's named approval in the workspace conversation approves the member run"

# Claude 세션은 stream-json으로 돌려 도구 호출을 실시간 진행 줄로 보인다. 원본 스트림(파일 내용·명령 인자·모델 문장)은 디스크에 남기지 않는다.
new_driver_repo claude_stream
driver start --runtime claude --request "add feature"
assert_eq "10" "$DRIVER_RC" "a claude run stops at approval like codex"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "claude results come from the stream's result event"
RUN_DIR="$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")"
assert_contains "$DRIVER_OUT" "deliver · Read src/app.ts" "tool calls show live on stderr with repo-relative paths"
assert_contains "$(<"$RUN_DIR/progress.log")" "review-0 · Bash: call the api" "progress.log keeps one line per tool call; Bash shows its description"
assert_contains "$(<"$RUN_DIR/progress.log")" "brief --next--> approval" "progress.log also keeps node transitions"
assert_contains "$(<"$RUN_DIR/progress.log")" "review-0 · Bash: curl" "Bash without a description shows the program name, skipping VAR= assignments"
assert_contains "$(<"$RUN_DIR/progress.log")" "review-0 · Grep useAuth in src" "Grep shows its pattern and repo-relative path"
assert_contains "$DRIVER_OUT" "progress: $RUN_DIR/progress.log" "resume also announces the progress file"
! grep -rq 'SECRET' "$RUN_DIR" || fail "tool inputs, tool results, and model text never reach the run directory: $(grep -rl 'SECRET' "$RUN_DIR")"
assert_eq "1" "$(find "$(dirname "$RUN_DIR")" -maxdepth 0 -perm 700 | wc -l | tr -d ' ')" "run directories are readable only by their owner"
HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER" watch --repo "$DRIVER_REPO" >"$DRIVER_TMP/watch.out" 2>&1 &
WATCH_PID=$!
for _ in $(seq 50); do grep -q 'Bash: call the api' "$DRIVER_TMP/watch.out" 2>/dev/null && break; sleep 0.2; done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
assert_contains "$(<"$DRIVER_TMP/watch.out")" "review-0 · Bash: call the api" "watch follows the latest run's progress"
new_driver_repo claude_fail
FAKE_CLAUDE_FAIL=1 driver start --runtime claude --request "add feature"
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a failed claude session is incomplete even though the progress filter succeeds"

if ! (exec 3<>/dev/tty) 2>/dev/null; then
  new_driver_repo no_tty
  driver start --runtime codex --request "add feature"
  driver approve
  assert_eq "10" "$DRIVER_RC" "terminal approval needs a real terminal"
fi

start_and_approve brief_writes
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "a write during a read-only node stops the run"
assert_eq "discover read-only schema=;" "$(tr '\n' ';' <"$FAKE_LOG")" "nothing runs after a violation"
start_and_approve nocheck
assert_eq "30:brief" "$DRIVER_RC:$(run_state .node)" "a brief without a verification command cannot be approved"
FAKE_CHECK="grep -q fixed feature.txt" start_and_approve fixcheck
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failing driver-run check goes to repair, then review"
assert_eq "deliver;repair;review" "$(tail -n 3 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "check failure skips the reviewer and repairs first"

# 넓은 검사(final_checks)는 라운드마다 돌지 않고 리뷰가 깨끗해진 뒤 한 번 돈다. 실패하면 blocking으로 수리한다. (#462)
FINAL_LOG="$DRIVER_TMP/final-checks.log"
: >"$FINAL_LOG"
FAKE_CHECK="printf 'fast\\n' >>'$FINAL_LOG'" FAKE_FINAL_CHECK="printf 'final\\n' >>'$FINAL_LOG'" start_and_approve final_once
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a run with final checks reaches done"
assert_eq "fast;final" "$(paste -sd ';' "$FINAL_LOG")" "fast checks run before the review and the broad check runs once after it"
assert_eq "1:1" "$(run_state '"\(.checks | length):\(.final_checks | length)"')" "the approved final checks are kept apart from the per-round checks"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "final_checks" "the brief node is asked to split per-round and final checks"
: >"$FINAL_LOG"
FAKE_CHECK="printf 'fast\\n' >>'$FINAL_LOG'" FAKE_FINAL_CHECK="printf 'final\\n' >>'$FINAL_LOG'; grep -q fixed feature.txt" start_and_approve final_fails_once
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failing final check goes to repair like a blocking finding"
assert_eq "fast;final;final;fast" "$(paste -sd ';' "$FINAL_LOG")" "after repair the failed final check runs first and passing it on that tree is not repeated after the re-review"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "required check failed" "repair receives the final check failure"
# 넓은 검사가 파일을 만들면 그 변경은 리뷰를 받지 않았으므로 통과가 아니다 — 수리·재리뷰를 거친다.
FAKE_FINAL_CHECK="echo generated >side.txt" start_and_approve final_side_effect
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a final check that changes files goes through repair and review again"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "changed files that were not reviewed: side.txt" "repair is told which files the final checks changed"
# 넓은 검사가 checks와 겹치면 한 번만 둔다.
FAKE_FINAL_CHECK="true" start_and_approve final_duplicate
assert_eq "0:0" "$DRIVER_RC:$(run_state '.final_checks | length')" "a final check already in checks is not repeated"

# 같은 정규화 실패가 연속되면 수리를 더 반복하지 않고 그래프의 repair -> user_decision 전이로 사람에게 넘긴다.
# 검사 출력은 파일로 둬서 종료 사유의 시그니처가 로그에 찍힌 명령 문자열이 아니라 실패 출력에서 왔음을 확인한다.
STALL_OUT="$DRIVER_TMP/stall-output"
mkdir -p "$STALL_OUT"
printf 'src/app.ts:42: error E12 at 2026-11-19T12:34:56 took 123ms\n' >"$STALL_OUT/same.txt"
FAKE_CHECK="cat '$STALL_OUT/same.txt' >&2; false" start_and_approve repeat_failure_signature
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "two matching failed checks stop repair at the repeat limit"
assert_contains "$DRIVER_OUT" "src/app.ts:<n>: error E<n> at <time> took <duration>" "the repeated failure decision names its normalized signature"
assert_eq "repair>user_decision" "$(run_state '.history | last | .from + ">" + .to')" "the stall goes to a person through the graph's repair escalation edge"

# 실행마다 바뀌는 객체 주소·출력 순서만 다른 실패는 같은 실패다.
ADDR_COUNT="$DRIVER_TMP/addr-count"
FAKE_CHECK="n=0; [[ -f '$ADDR_COUNT' ]] && n=\$(cat '$ADDR_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$ADDR_COUNT'; if [[ \$((n % 2)) == 1 ]]; then printf 'FAILED tests/test_order.py::test_total - assert <app.Order object at 0x7f8a3c10b2e0> == 110\\nFAILED tests/test_order.py::test_tax - assert 0 == 10\\n'; else printf 'FAILED tests/test_order.py::test_tax - assert 0 == 10\\nFAILED tests/test_order.py::test_total - assert <app.Order object at 0x10c4d2a90> == 110\\n'; fi; false" start_and_approve address_noise_repeat
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "object addresses and output order do not hide a repeated failure"

# 핵심 오류가 달라지면 이전 실패와 같은 반복으로 세지 않는다.
DIFFERENT_FAILURE_COUNT="$DRIVER_TMP/different-failure-count"
FAKE_CHECK="n=0; [[ -f '$DIFFERENT_FAILURE_COUNT' ]] && n=\$(cat '$DIFFERENT_FAILURE_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$DIFFERENT_FAILURE_COUNT'; case \"\$n\" in 1) printf 'src/app.ts:1: error first\\n' >&2 ;; 2) printf 'src/app.ts:2: error second\\n' >&2 ;; *) printf 'src/app.ts:3: error third\\n' >&2 ;; esac; false" start_and_approve different_failure_signature
assert_eq "20:user_decision:3" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a changed failure gets another repair before a repeated new failure stops it"

# 실패한 테스트가 달라도 빌드 도구의 꼬리 요약줄은 같다. 요약줄이 아니라 실패 위치로 시그니처를 만들어 진전하는 수리를 막지 않는다.
gradle_failure() { # test-name line → Gradle 테스트 실패 출력
  printf '%s() FAILED\n    org.opentest4j.AssertionFailedError at %s.java:%s\n\n3 tests completed, 1 failed\n\nFAILURE: Build failed with an exception.\n\n* What went wrong:\nExecution failed for task '"'"':test'"'"'.\n> There were failing tests. See the report at: file:///home/u/proj/build/reports/tests/test/index.html\n\nBUILD FAILED in 4s\n' "$1" "$1" "$2"
}
gradle_failure FooTest 10 >"$STALL_OUT/gradle-1.txt"
gradle_failure BarTest 99 >"$STALL_OUT/gradle-2.txt"
gradle_failure BazTest 7 >"$STALL_OUT/gradle-3.txt"
GRADLE_COUNT="$DRIVER_TMP/gradle-count"
FAKE_CHECK="n=0; [[ -f '$GRADLE_COUNT' ]] && n=\$(cat '$GRADLE_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$GRADLE_COUNT'; [[ \$n -ge 4 ]] && exit 0; cat '$STALL_OUT/gradle-'\$n'.txt'; exit 1" start_and_approve gradle_progress
assert_eq "0:done:3" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "different failing tests under the same build summary are progress, not a repeat"
# 테스트 이름 줄에는 오류 낱말이 없고, 실패가 많으면 바뀐 실패가 뒤쪽에 있다. 둘 다 시그니처에 들어가야 진전을 반복으로 세지 않는다.
jest_failure() { # test-name → jest 실패 출력
  printf 'FAIL src/total.test.ts\n  ● total › %s\n\n    expect(received).toBe(expected)\n\n    Expected: 110\n    Received: 100\n\n      at Object.<anonymous> (src/total.test.ts:12:5)\n\nTests:       1 failed, 3 passed, 4 total\n' "$1"
}
jest_failure "adds tax" >"$STALL_OUT/jest-1.txt"
jest_failure "rounds total" >"$STALL_OUT/jest-2.txt"
JEST_COUNT="$DRIVER_TMP/jest-count"
FAKE_CHECK="n=0; [[ -f '$JEST_COUNT' ]] && n=\$(cat '$JEST_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$JEST_COUNT'; [[ \$n -ge 3 ]] && exit 0; cat '$STALL_OUT/jest-'\$n'.txt'; exit 1" start_and_approve jest_progress
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a different failing test name is progress even without an error word on its line"
many_failures() { # count → Gradle 실패 count개
  local i
  for i in $(seq 1 "$1"); do printf 'Case%sTest > check() FAILED\n    org.opentest4j.AssertionFailedError at Case%sTest.java:5\n' "$i" "$i"; done
  printf '\nBUILD FAILED in 9s\n'
}
many_failures 7 >"$STALL_OUT/many-1.txt"
many_failures 6 >"$STALL_OUT/many-2.txt"
many_failures 5 >"$STALL_OUT/many-3.txt"
MANY_COUNT="$DRIVER_TMP/many-count"
FAKE_CHECK="n=0; [[ -f '$MANY_COUNT' ]] && n=\$(cat '$MANY_COUNT'); n=\$((n + 1)); printf '%s' \"\$n\" >'$MANY_COUNT'; [[ \$n -ge 4 ]] && exit 0; cat '$STALL_OUT/many-'\$n'.txt'; exit 1" start_and_approve many_failures_progress
assert_eq "0:done:3" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "fixing the last of many failures is progress, not a repeat"

# 환경 오류는 실패 원인 위치가 변경 파일 밖 의존 산출물일 때만이다. 그때는 repair 없이 바로 사람에게 넘긴다.
printf "node_modules/antd/lib/input/Input.d.ts(3,5): error TS1005: ',' expected.\n" >"$STALL_OUT/tsc-dependency.txt"
FAKE_CHECK="cat '$STALL_OUT/tsc-dependency.txt'; false" start_and_approve dependency_output_failure
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failure located in a dependency outside the changes goes to a person without a repair"
[[ "$(<"$FAKE_LOG")" != *repair* ]] || fail "an environment failure is not repaired"
assert_contains "$DRIVER_OUT" "node_modules/antd/lib/input/Input.d.ts" "the environment decision names the dependency location"

# 보고서 경로(build/reports)와 스택 프레임(node_modules)은 원인 위치가 아니다. 이런 실패는 환경 오류로 넘기지 않고 고친다.
gradle_failure FooTest 10 >"$STALL_OUT/gradle-report.txt"
FAKE_CHECK="cat '$STALL_OUT/gradle-report.txt'; grep -q fixed feature.txt" start_and_approve gradle_report_path
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a Gradle report path is not a dependency failure"
printf 'FAIL src/total.test.ts\n  ● total › adds tax\n\n    expect(received).toBe(expected)\n\n      at Object.<anonymous> (src/total.test.ts:5:7)\n      at Promise.then.completed (node_modules/jest-circus/build/utils.js:298:28)\n' >"$STALL_OUT/jest-stack.txt"
FAKE_CHECK="cat '$STALL_OUT/jest-stack.txt'; grep -q fixed feature.txt" start_and_approve jest_stack_frame
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a node_modules stack frame is not a dependency failure"

# repair는 직전 실패 check만 다시 실행하고, 통과 뒤 전체 required set을 한 번 확정한다.
REPAIR_CHECK_LOG="$DRIVER_TMP/repair-checks.log"
FAKE_CHECK="printf 'A\\n' >>'$REPAIR_CHECK_LOG'; grep -q fixed feature.txt" start_and_approve repair_failed_checks_only --check "printf 'B\\n' >>'$REPAIR_CHECK_LOG'" --check "printf 'B\\n' >>'$REPAIR_CHECK_LOG'"
assert_eq "3" "$(grep -c '^A$' "$REPAIR_CHECK_LOG")" "the failed check runs for the initial failure, repair, and final confirmation"
assert_eq "2" "$(grep -c '^B$' "$REPAIR_CHECK_LOG")" "a passing duplicated command runs once initially and once in final confirmation"
start_and_approve review_blocks
assert_eq "20:user_decision:$(jq -r '.limits.max_repair_attempts' "$FEATURE_GRAPH")" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "blocking findings stop at user_decision after the graph's repair limit"
assert_eq "$(($(jq -r '.limits.max_repair_attempts' "$FEATURE_GRAPH") + 1))" "$(grep -c '^review read-only' "$FAKE_LOG")" "every repair is followed by a re-review"
start_and_approve decision
assert_eq "20:0" "$DRIVER_RC:$(run_state .attempts)" "a product decision goes to a person without repair attempts"
start_and_approve bad_review
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a review that breaks the schema is never done"
start_and_approve commit
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "an unauthorized commit stops the run"
start_and_approve noop
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "delivery without a change is not done"
start_and_approve extra_check --check "test -f feature.txt"
assert_eq "0:true" "$DRIVER_RC:$(run_state '.checks | index("test -f feature.txt") != null')" "--check joins the approved verification"

pass "feature runner: approval, required checks, and the repair loop"


# 자동 승인 Brief는 요청·이슈의 완료 조건을 항목마다 대응시켜야 한다(#501). 대응도 사유도 없는 조건이 있으면 러너가 다시 쓰게 하고,
# 한도(limits.max_brief_rewrites)를 넘으면 사람에게 넘긴다. 쓰기 노드는 그동안 돌지 않는다.
run_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
brief_history() { run_state '.history | map("\(.from) --\(if .outcome == "" then "next" else .outcome end)--> \(.to)") | join(";")'; }
new_driver_repo auto_uncovered
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision:user_decision" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "an uncovered completion condition is never approved by policy"
assert_contains "$(brief_history)" "approval --brief_changed_or_not_approved--> brief" "the runner sends an uncovered brief back to the brief node"
assert_contains "$(brief_history)" "approval --brief_coverage_incomplete--> user_decision" "past the rewrite limit the run goes to a person"
[[ "$(brief_history)" != *auto_approved_by_policy* ]] || fail "an uncovered brief is not auto-approved"
assert_eq "$(($(jq -r '.limits.max_brief_rewrites' "$FEATURE_GRAPH") + 1))" "$(grep -c '^brief ' "$FAKE_LOG")" "the brief is rewritten up to the graph's limit"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "nothing writes while a completion condition is uncovered"
assert_contains "$(<"$FAKE_LOG.revise")" "Revise it with this feedback" "the rewrite reuses the revise path"
assert_contains "$(<"$FAKE_LOG.revise")" "CSV export" "the rewrite names the uncovered condition"
assert_contains "$DRIVER_OUT" "CSV export" "the person sees the uncovered condition"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "acceptance_map" "the brief node is asked for the completion-condition map"

new_driver_repo auto_empty_map
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "an empty completion-condition map is not approved by policy"
[[ "$(brief_history)" != *auto_approved_by_policy* ]] || fail "an empty map is not auto-approved"

new_driver_repo auto_uncovered_once
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(grep -c '^brief ' "$FAKE_LOG")" "a brief fixed on rewrite passes after two brief runs"
assert_contains "$(brief_history)" "approval --brief_changed_or_not_approved--> brief;brief --next--> approval;approval --auto_approved_by_policy--> deliver" "the rewritten brief is approved by policy"

new_driver_repo auto_out_of_scope
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^brief ' "$FAKE_LOG")" "a condition out of scope with a reason passes on the first brief"
OOS_BRIEF="$(<"$(dirname "$(run_state .approval.brief)")/brief.md")"
assert_contains "$OOS_BRIEF" "## 완료 조건 대응" "brief.md renders the completion-condition map"
assert_contains "$OOS_BRIEF" "- CSV export → 범위 밖: tracked in a follow-up issue" "brief.md shows the out-of-scope reason"
assert_contains "$OOS_BRIEF" "- add feature → feature.txt exists (checks)" "brief.md shows what covers each condition"

# sync 전 그래프(brief_coverage_incomplete 엣지 없음)는 한도에서 사람 승인을 기다린다.
new_driver_repo auto_uncovered_noedge
with_policy pr-only auto
FAKE_SCENARIO=auto_uncovered
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.when == "brief_coverage_incomplete"))' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
assert_eq "10:waiting_approval:approval" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "without the coverage edge the run waits for a person at the limit"
assert_contains "$DRIVER_OUT" "brief_coverage_incomplete" "the log says why a person must decide"
pass "auto approval requires every completion condition covered or out of scope"

# 리뷰는 승인된 Brief와 원 요청의 완료 조건을 함께 대조하고, 빠진 조건을 blocking으로 낸다.
new_driver_repo missing_criterion
driver start --runtime codex --request "add feature with CSV export"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a missing completion condition is repaired and re-reviewed"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "Original request:" "review sees the original request"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "add feature with CSV export" "review sees the request text"
assert_contains "$(<"$FAKE_LOG.review.prompt")" "completion condition" "review is told to check every completion condition"
assert_contains "$(brief_history)" "review --blocking_findings--> repair" "a missing completion condition goes to repair"
assert_contains "$(<"$(run_dir)/review-0.out")" "completion condition CSV export not met" "the finding names the missing condition"
pass "review blocks on a completion condition the change does not meet"

# 멈춘 deliver에서 revise하면 그래프의 deliver → brief 엣지로 Brief를 다시 만든다. 이전 승인은 무효다.
new_driver_repo revise_stopped
FAKE_SCENARIO=noop
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "30:incomplete:deliver" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "deliver stopped without a change"
rm -f "$DRIVER_TMP/claude/projects/p/noop.jsonl"
driver revise --feedback "CSV 내보내기가 빠졌다"
assert_eq "10:waiting_approval:approval" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "revise at a stopped deliver rebuilds the brief and waits again"
assert_contains "$(brief_history)" "deliver --brief_revised--> brief" "revise follows the deliver -> brief edge"
assert_contains "$(<"$FAKE_LOG.revise")" "CSV 내보내기가 빠졌다" "the new brief gets the feedback"
assert_eq "null" "$(run_state .approval)" "the earlier approval no longer holds"

# 실행 중인 deliver에서 revise하면 러너를 죽이지 않고 요청 파일만 남긴다. 러너는 세션이 끝난 뒤 review 대신 brief로 간다.
new_driver_repo revise_midway
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "0" "$(<"$FAKE_LOG.midway.rc")" "revise during a running deliver ends with 0"
assert_contains "$(<"$FAKE_LOG.midway.out")" "brief" "revise says the run returns to the brief after the session"
assert_file "$FAKE_LOG.midway.requested"
assert_contains "$(brief_history)" "deliver --brief_revised--> brief" "the runner returns to the brief after the deliver session"
assert_eq "10:waiting_approval:approval" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "the new brief waits for its own approval"
assert_eq "discover;brief;deliver;brief" "$(cut -d' ' -f1 "$FAKE_LOG" | paste -sd ';' -)" "no review runs between the revised deliver and the new brief"
assert_not_file "$(run_dir)/revise-request.json"
assert_contains "$(<"$FAKE_LOG.revise")" "CSV 내보내기가 빠졌다" "the new brief gets the feedback written during deliver"
assert_contains "$(<"$FAKE_LOG.revise")" "Changes already made in this run" "the new brief sees what deliver already changed"
assert_contains "$(<"$FAKE_LOG.revise")" "feature.txt" "the changes deliver made stay"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "the run continues after the new brief is approved"

# brief_revised 엣지가 없는 노드에서는 revise를 받지 않는다.
new_driver_repo revise_refused
FAKE_SCENARIO=bad_review
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "30:review" "$DRIVER_RC:$(run_state .node)" "review stopped on a broken output"
driver revise --feedback "x"
assert_eq "2" "$DRIVER_RC" "revise is refused at a node without a brief_revised edge"
assert_contains "$DRIVER_OUT" "approval, deliver" "the refusal names the nodes that take revise"
pass "revise returns from deliver to the brief without killing the runner"

finish_tests
