#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 승인·검증 시작(feature)
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

pass "feature runner: approval rules, progress stream, and read-only planning"

finish_tests
