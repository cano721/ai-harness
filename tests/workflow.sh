#!/usr/bin/env bash
# 회귀 테스트 — SessionStart 안내·그래프 러너(feature·bug-fix·review·investigate)·병합 노드
# 실행: bash tests/run.sh workflow
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 누적량 hook: 멱등 pending → analysis batch → 다음 세션 1회 알림 → 묶음 단위 검토 완료
QUEUE_DATA="$TEST_TMP/queue-data"
HARNESS_METRICS_DIR="$QUEUE_DATA" "$ROOT/scripts/extract-claude.sh" "$CLAUDE_FIXTURE" "user_exit"
QUEUE_EVENT="$QUEUE_DATA/events/claude-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb.jsonl"
ANALYSIS_BATCH="$(
  HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" record "$QUEUE_EVENT"
)"
assert_eq "true" "$(printf '%s' "$ANALYSIS_BATCH" | jq -r '.has_analysis_batch')" "quantity threshold analysis batch"
assert_eq "true" "$(printf '%s' "$ANALYSIS_BATCH" | jq -r '.new_analysis_batch')" "first analysis batch transition"
assert_eq "1" "$(printf '%s' "$ANALYSIS_BATCH" | jq -r '.counts.sessions')" "analysis batch session count"
assert_eq "false" "$(jq -r '.new_analysis_batch' "$QUEUE_DATA/harvest-queue/p-service/analysis-batch.json")" "stored batch is not a transient response"

# 같은 세션을 다시 수집해도 pending 수가 늘지 않는다.
HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" record "$QUEUE_EVENT" >/dev/null
QUEUE_STATUS="$(
  HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" status --project service
)"
assert_eq "1" "$(printf '%s' "$QUEUE_STATUS" | jq -r '.counts.sessions')" "idempotent queue record"

START_COMMAND="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/hooks.json")"
assert_eq "3" "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$ROOT/hooks/hooks.json")" "SessionStart hook timeout"
assert_contains "$START_COMMAND" "session-start.sh" "SessionStart notification aggregator"
START_INPUT="$(jq -cn --arg cwd "$PROJECT_REPO" '{cwd:$cwd}')"
ANALYSIS_NOTICE="$(
  printf '%s' "$START_INPUT" \
    | CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 HM_UPDATE_CHECK_ENABLED=0 \
      /bin/sh -c "$START_COMMAND"
)"
assert_contains "$ANALYSIS_NOTICE" "분석할 활동 묶음" "analysis batch notification"
assert_contains "$ANALYSIS_NOTICE" "/harvest service" "analysis command notification"
SECOND_NOTICE="$(
  printf '%s' "$START_INPUT" \
    | CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 HM_UPDATE_CHECK_ENABLED=0 \
      /bin/sh -c "$START_COMMAND"
)"
assert_eq "" "$SECOND_NOTICE" "analysis notification only once per batch"

# 자동 업데이트 안내는 Claude 세션의 첫 SessionStart에만 한 번 뜬다.
HINT_DATA="$TEST_TMP/hint-data"
CLAUDE_START_INPUT="$(jq -cn --arg cwd "$PROJECT_REPO" '{cwd:$cwd, transcript_path:"/tmp/claude-session.jsonl"}')"
CODEX_START_INPUT="$(jq -cn --arg cwd "$PROJECT_REPO" '{cwd:$cwd, transcript_path:"/tmp/rollout-2026-09-23T00-00-00-abc.jsonl"}')"
run_start_hook() {
  printf '%s' "$1" \
    | CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$HINT_DATA" HM_UPDATE_CHECK_ENABLED=0 \
      HM_LAUNCH_AGENTS_DIR="$TEST_TMP/hint-agents" /bin/sh -c "$START_COMMAND"
}
CODEX_HINT="$(run_start_hook "$CODEX_START_INPUT")"
assert_eq "" "$CODEX_HINT" "no auto-update hint for Codex sessions"
assert_not_file "$HINT_DATA/auto-update-hint-shown"
FIRST_HINT="$(run_start_hook "$CLAUDE_START_INPUT")"
assert_contains "$(jq -r '.systemMessage' <<<"$FIRST_HINT")" "Enable auto-update" "auto-update hint on first Claude session"
assert_file "$HINT_DATA/auto-update-hint-shown"
assert_eq "" "$(run_start_hook "$CLAUDE_START_INPUT")" "auto-update hint shown only once"
pass "SessionStart auto-update hint"

assert_eq "$QUEUE_EVENT" "$(
  HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" events --project service
)" "analysis batch event list"

# 알림은 즉시 반복하지 않지만 cooldown이 지나면 같은 미처리 묶음을 다시 알린다.
NOTICE_STATE="$QUEUE_DATA/harvest-queue/p-service/notified-analysis-batch"
NOTICE_TMP="$QUEUE_DATA/harvest-queue/p-service/.notice-test.json"
jq -c '.notified_at_epoch = 0' "$NOTICE_STATE" >"$NOTICE_TMP"
mv "$NOTICE_TMP" "$NOTICE_STATE"
REMINDER_NOTICE="$(
  printf '%s' "$START_INPUT" \
    | CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$QUEUE_DATA" \
      HM_HARVEST_SESSION_THRESHOLD=1 HM_HARVEST_REMIND_HOURS=24 HM_UPDATE_CHECK_ENABLED=0 \
      /bin/sh -c "$START_COMMAND"
)"
assert_contains "$REMINDER_NOTICE" "/harvest service" "analysis reminder after cooldown"

# analysis batch 이후 들어온 세션은 첫 mark-reviewed에 삭제되지 않고 다음 묶음이 된다.
QUEUE_EVENT_2="$QUEUE_DATA/events/claude-cccccccc-1111-2222-3333-dddddddddddd.jsonl"
jq -c '.sid = "cccccccc-1111-2222-3333-dddddddddddd"' "$QUEUE_EVENT" >"$QUEUE_EVENT_2"
HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" record "$QUEUE_EVENT_2" >/dev/null
BATCH_STATS="$(
  HARNESS_METRICS_DIR="$QUEUE_DATA" "$ROOT/scripts/stats.sh" \
    --project service --analysis-batch
)"
assert_contains "$BATCH_STATS" "| service | 1 |" "analysis batch scoped stats"
NEXT_BATCH="$(
  HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
    "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service \
      --outcome improved --summary "반복 교정 constraint 추가" --artifact "https://example.test/pr/1" \
      --expected "동일 유형 correction_mark 재발 0"
)"
assert_eq "true" "$(printf '%s' "$NEXT_BATCH" | jq -r '.has_analysis_batch')" "post-batch session preserved"
assert_eq "1" "$(printf '%s' "$NEXT_BATCH" | jq -r '.counts.sessions')" "next batch size"
NEXT_NOTICE="$(
  printf '%s' "$START_INPUT" \
    | CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 HM_UPDATE_CHECK_ENABLED=0 \
      /bin/sh -c "$START_COMMAND"
)"
assert_contains "$NEXT_NOTICE" "/harvest service" "next batch notification"
HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project service \
    --outcome no-change --summary "행동 변경 근거 없음" >/dev/null
HARNESS_METRICS_DIR="$QUEUE_DATA" HM_HARVEST_SESSION_THRESHOLD=1 \
  "$ROOT/scripts/harvest-queue.sh" import --project service >/dev/null
assert_not_file "$QUEUE_DATA/harvest-queue/p-service/analysis-batch.json"
assert_eq "false" "$(jq -r '.has_analysis_batch' "$QUEUE_DATA/harvest-queue/p-service/last-reviewed.json")" "reviewed batch state"
assert_eq "2" "$(wc -l < "$QUEUE_DATA/harvest-queue/p-service/review-history.jsonl" | tr -d ' ')" "review history append"
assert_eq "improved" "$(jq -sr '.[0].review.outcome' "$QUEUE_DATA/harvest-queue/p-service/review-history.jsonl")" "review outcome persisted"
assert_eq "https://example.test/pr/1" "$(jq -sr '.[0].review.artifact' "$QUEUE_DATA/harvest-queue/p-service/review-history.jsonl")" "review artifact persisted"
assert_eq "동일 유형 correction_mark 재발 0" "$(jq -sr '.[0].review.expected' "$QUEUE_DATA/harvest-queue/p-service/review-history.jsonl")" "review expected persisted"
assert_eq "no-change" "$(jq -sr '.[1].review.outcome' "$QUEUE_DATA/harvest-queue/p-service/review-history.jsonl")" "no-change outcome persisted"
assert_eq "null" "$(jq -sr '.[1].review.expected' "$QUEUE_DATA/harvest-queue/p-service/review-history.jsonl")" "expected null without flag"
HISTORY_OUTPUT="$(HARNESS_METRICS_DIR="$QUEUE_DATA" "$ROOT/scripts/harvest-queue.sh" history --project service)"
assert_eq "2" "$(printf '%s\n' "$HISTORY_OUTPUT" | jq -s 'length')" "review history command"

# implement-feature 템플릿은 standard 초기화가 만드는 프로젝트 로컬 전달 게이트의 원본이다.
FEATURE_SKILL="$ROOT/templates/implement-feature/SKILL.md"
assert_file "$FEATURE_SKILL"
assert_not_file "$ROOT/skills/implement-feature/SKILL.md"
FEATURE_SKILL_CONTENT="$(<"$FEATURE_SKILL")"
assert_contains "$FEATURE_SKILL_CONTENT" "This is a project adapter" "feature skill is a thin adapter"
assert_contains "$FEATURE_SKILL_CONTENT" ".ai-harness/workflows/implement-feature.md" "feature skill references project workflow"
assert_contains "$FEATURE_SKILL_CONTENT" ".ai-harness/workflows/feature-delivery-graph.json" "feature skill references project graph"
assert_contains "$FEATURE_SKILL_CONTENT" "Do not edit before explicit approval" "feature skill keeps approval gate"
HARNESS_INIT_CONTENT="$(<"$ROOT/skills/harness-init/SKILL.md")"
assert_contains "$HARNESS_INIT_CONTENT" "templates/implement-feature/" "harness init uses the local feature template"
assert_contains "$HARNESS_INIT_CONTENT" ".ai-harness/workflows/feature-delivery-graph.json" "harness init copies the local feature graph"
# 커밋·push·PR은 manifest의 git_policy, 승인 대기는 개인 설정이 정한다.
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for adapter in implement-feature fix-bug review; do
  ADAPTER_CONTENT="$(<"$ROOT/templates/$adapter/SKILL.md")"
  assert_contains "$ADAPTER_CONTENT" '`git_policy`' "$adapter adapter follows git_policy"
  assert_contains "$ADAPTER_CONTENT" '`.ai-harness/harness.json`' "$adapter adapter reads the policy from the manifest"
  [[ "$ADAPTER_CONTENT" != *"push, create a PR, merge, or change project policy unless separately authorized"* ]] || fail "$adapter adapter still forbids PRs regardless of git_policy"
  assert_contains "$ADAPTER_CONTENT" "never merge, force-push" "$adapter adapter never merges or force-pushes"
  [[ "$adapter" == review ]] || assert_contains "$ADAPTER_CONTENT" "the only merge is the runner's \`merge\` node" "$adapter adapter leaves merging to the runner's merge node"
done
# 작업 시작 때 이슈 상태 전환은 manifest의 issue_policy가 정한다. review는 이슈 작업을 시작하지 않는다.
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for adapter in implement-feature fix-bug; do
  ADAPTER_CONTENT="$(<"$ROOT/templates/$adapter/SKILL.md")"
  assert_contains "$ADAPTER_CONTENT" '`issue_policy`: `in-progress-on-start`' "$adapter adapter follows issue_policy"
  assert_contains "$ADAPTER_CONTENT" "Missing or any other value — leave issue status alone" "$adapter adapter leaves issues alone without issue_policy"
done
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
assert_contains "$FEATURE_SKILL_CONTENT" '`auto` — present the brief' "feature adapter honors personal approval auto"
assert_contains "$HARNESS_INIT_CONTENT" 'HM_APPROVAL' "harness init documents personal approval settings"
assert_contains "$HARNESS_INIT_CONTENT" 'HM_APPROVAL_REPOS' "harness init documents repository-specific approval settings"
[[ "$HARNESS_INIT_CONTENT" != *'"approval": "human"'* ]] || fail "harness init does not write approval to the manifest"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
assert_contains "$HARNESS_INIT_CONTENT" '기존 `approval` 값은 보존' "harness init preserves legacy approval fields and asks for review"
assert_contains "$HARNESS_INIT_CONTENT" "다시 묻지 않고" "sync --apply applies add and refresh without asking again"
pass "project implementation planning gate"

# 승인 모드는 개인 설정(HM_APPROVAL_REPOS > HM_APPROVAL > human)만 정한다(#294). manifest에 approval:"auto"가 남은
# 저장소에서 옛 문구를 따르는 경로(autofix 수동 수정·생성될 workflow 본문·이 저장소 어댑터)가 사람 승인을 건너뛰지 않게 한다(#310).
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
{
  AUTOFIX_SKILL_CONTENT="$(<"$ROOT/skills/autofix/SKILL.md")"
  [[ "$AUTOFIX_SKILL_CONTENT" != *'프로젝트 정책(`approval`)'* ]] || fail "autofix manual fixes do not follow the legacy manifest approval"
  [[ "$AUTOFIX_SKILL_CONTENT" != *'manifest `approval`과 관계없이'* ]] || fail "autofix unattended runs name the personal approval setting"
  assert_contains "$AUTOFIX_SKILL_CONTENT" '`HM_APPROVAL_REPOS`' "autofix manual fixes resolve approval from the personal settings"
  [[ "$HARNESS_INIT_CONTENT" != *'manifest가 정하므로'* ]] || fail "harness init does not say the manifest decides the approval gate"
  SETUP_APPROVAL="$(awk '/^### 8-0\./{f=1; next} /^### /{f=0} f' "$ROOT/skills/setup/SKILL.md")"
  assert_contains "$SETUP_APPROVAL" '모든 저장소' "setup warns that a global auto approval applies to every repository"
  assert_contains "$SETUP_APPROVAL" '신뢰하지 않는 저장소' "setup warns about untrusted repositories under auto approval"
  for generated in .claude/commands/implement-feature.md .claude/commands/fix-bug.md .claude/commands/review.md \
    .agents/skills/implement-feature/SKILL.md .agents/skills/fix-bug/SKILL.md .agents/skills/review/SKILL.md; do
    GENERATED_CONTENT="$(<"$ROOT/$generated")"
    [[ "$GENERATED_CONTENT" != *'Read `approval`'* && "$GENERATED_CONTENT" != *'`approval: auto`'* ]] || fail "$generated is re-rendered with the personal approval wording"
  done
}
pass "approval follows personal settings in skills and generated adapters"

# 공용 그래프 계약은 승인 전 write와 blocking finding의 done 전이를 막는다.
FEATURE_GRAPH="$ROOT/templates/implement-feature/references/feature-delivery-graph.json"
assert_file "$FEATURE_GRAPH"
"$ROOT/scripts/validate-feature-graph.sh" "$FEATURE_GRAPH" >/dev/null
assert_eq "false" "$(jq -r '.nodes.approval.write' "$FEATURE_GRAPH")" "approval node is read-only"
assert_eq "true" "$(jq -r '.nodes.deliver.write' "$FEATURE_GRAPH")" "delivery node can write"
for graph in "$FEATURE_GRAPH" "$ROOT/templates/fix-bug/references/bug-fix-graph.json" "$ROOT/templates/review/references/review-graph.json"; do
  assert_eq "10" "$(jq -r '.limits.max_repair_attempts' "$graph")" "$(basename "$graph") keeps its repair limit in limits"
  [[ "$(jq -r '[.transitions[].when // empty] | join(" ")' "$graph")" != *_two_* ]] || fail "$(basename "$graph") spells a repair count in an edge name"
done
assert_eq "true:true" "$(jq -r '"\(.nodes.publish.write):\(.nodes.publish.network)"' "$FEATURE_GRAPH")" "publish writes and needs the network"
INVALID_GRAPH="$TEST_TMP/no-publish-graph.json"
jq 'del(.transitions[] | select(.from == "publish"))' "$FEATURE_GRAPH" >"$INVALID_GRAPH"
if "$ROOT/scripts/validate-feature-graph.sh" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "a graph whose publish node cannot finish is invalid"; fi
jq 'del(.transitions[] | select(.from == "remote_ci" and .to == "repair"))' "$FEATURE_GRAPH" >"$INVALID_GRAPH"
if "$ROOT/scripts/validate-feature-graph.sh" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "a graph whose remote CI failure cannot be repaired is invalid"; fi
for graph in "$FEATURE_GRAPH" "$ROOT/templates/fix-bug/references/bug-fix-graph.json"; do
  assert_eq "false:true:remote_ci" "$(jq -r '"\(.nodes.remote_ci.write):\(.nodes.remote_ci.network):\(first(.transitions[] | select(.from == "publish" and .when == "published_or_not_required") | .to))"' "$graph")" "$(basename "$graph") checks remote CI after publish without writing"
  assert_eq "done repair user_decision merge" "$(jq -r '[.transitions[] | select(.from == "remote_ci") | .to] | join(" ")' "$graph")" "$(basename "$graph") routes remote CI pass, failure, unverified, and merge under git_policy merge"
done
# ui_review는 선택 노드다. 옛 그래프(노드 없음)도 유효하고, 노드가 있으면 화면 검증을 건너뛰는 경로가 없어야 한다. (#150)
UI_GRAPH="$ROOT/templates/ui-review/references/ui-review-graph.json"
"$ROOT/scripts/validate-ui-review-graph.sh" "$UI_GRAPH" >/dev/null
for pair in "feature:$FEATURE_GRAPH" "bug-fix:$ROOT/templates/fix-bug/references/bug-fix-graph.json" "review:$ROOT/templates/review/references/review-graph.json"; do
  validator="$ROOT/scripts/validate-${pair%%:*}-graph.sh"
  graph="${pair#*:}"
  assert_eq "false:true" "$(jq -r '"\(.nodes.ui_review.write):\(.nodes.ui_review.browser)"' "$graph")" "$(basename "$graph") verifies screens in a browser without writing"
  jq 'del(.nodes.ui_review) | .transitions |= map(select(.from != "ui_review" and .to != "ui_review"))' "$graph" >"$INVALID_GRAPH"
  "$validator" "$INVALID_GRAPH" >/dev/null || fail "$(basename "$graph") without ui_review stays valid for unsynced projects"
  jq 'del(.transitions[] | select(.from == "ui_review" and (.to == "repair")))' "$graph" >"$INVALID_GRAPH"
  if "$validator" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "$(basename "$graph") whose UI issues cannot be repaired is invalid"; fi
  jq '.nodes.ui_review.write = true' "$graph" >"$INVALID_GRAPH"
  if "$validator" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "$(basename "$graph") whose ui_review can write is invalid"; fi
  jq --arg to "$(jq -r 'first(.transitions[] | select(.from == "ui_review" and .when == "ui_verified") | .to)' "$graph")" \
    '.transitions += [{"from": "ui_review", "to": $to, "when": "ui_unverified_but_ship"}]' "$graph" >"$INVALID_GRAPH"
  if "$validator" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "$(basename "$graph") with a ui_review bypass to done or publish is invalid"; fi
  jq '.transitions = [{"from": "ui_review", "to": "repair", "when": "ui_verified"}] + .transitions' "$graph" >"$INVALID_GRAPH"
  if "$validator" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "$(basename "$graph") with two ui_review exits on the same outcome is invalid"; fi
done
jq '.transitions += [{"from": "inspect", "to": "done", "when": "no_blocking_findings"}]' "$UI_GRAPH" >"$INVALID_GRAPH"
if "$ROOT/scripts/validate-ui-review-graph.sh" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "a ui-review graph that reaches done without ui_verified is invalid"; fi
jq 'del(.transitions[] | select(.when == "ui_unverified"))' "$UI_GRAPH" >"$INVALID_GRAPH"
if "$ROOT/scripts/validate-ui-review-graph.sh" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "a ui-review graph without an unverified exit is invalid"; fi
for adapter in implement-feature fix-bug review; do
  assert_contains "$(<"$ROOT/templates/$adapter/SKILL.md")" "ui_review" "$adapter adapter routes UI changes through ui_review"
  assert_contains "$(<"$ROOT/templates/$adapter/SKILL.md")" "workflow-driver.sh" "$adapter adapter runs the graph through the shared runner"
done
pass "feature delivery graph adapters"

# 드라이버는 그래프를 모델 밖에서 실행한다: 전이는 그래프가, 승인은 사용자가 직접 입력한 메시지가, 완료는 드라이버가 실행한 검증이 정한다.
DRIVER="$ROOT/templates/workflow-driver/workflow-driver.sh"
DRIVER_SHIM="$ROOT/templates/implement-feature/references/implement-feature-driver.sh"
assert_file "$DRIVER"
assert_file "$DRIVER_SHIM"
assert_contains "$(<"$FEATURE_SKILL")" "workflow-driver.sh start --workflow feature" "feature skill points to the graph runner"
for runner in workflow-driver.sh implement-feature-driver.sh; do
  assert_eq "1" "$(jq --arg p ".ai-harness/workflows/$runner" '[.artifacts[] | select(.path == $p and .level == "standard" and (has("integration") | not) and (has("workflow") | not or $p != ".ai-harness/workflows/workflow-driver.sh"))] | length' "$ROOT/templates/managed-files.json")" "$runner ships to every standard project regardless of integration"
done
assert_eq "human" "$(jq -r '.nodes.approval.actor' "$FEATURE_GRAPH")" "approval is a human node the runner interrupts at"
DRIVER_TMP="$TEST_TMP/driver"
mkdir -p "$DRIVER_TMP"
driver() { # args... → DRIVER_RC, DRIVER_OUT
  DRIVER_RC=0
  DRIVER_DATA="${DRIVER_DATA_OVERRIDE:-$DRIVER_TMP/data}"
  mkdir -p "$DRIVER_DATA"
  DRIVER_OUT="$(HM_APPROVAL='' HM_APPROVAL_REPOS='' HARNESS_METRICS_DIR="$DRIVER_DATA" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" CLAUDE_CONFIG_DIR="$DRIVER_TMP/claude" CODEX_HOME="$DRIVER_TMP/codex" \
    FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO="$FAKE_SCENARIO" FAKE_CHECK="${FAKE_CHECK:-true}" PATH="$ROOT/tests/fixtures/driver:$PATH" \
    bash "$DRIVER" "$@" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
}
new_driver_repo() { # scenario → DRIVER_REPO, FAKE_LOG, FAKE_SCENARIO
  FAKE_SCENARIO="$1"
  DRIVER_REPO="$DRIVER_TMP/repo-$1"
  FAKE_LOG="$DRIVER_TMP/$1.log"
  mkdir -p "$DRIVER_TMP/data"
  : >"$DRIVER_TMP/data/config"
  mkdir -p "$DRIVER_REPO"
  git -C "$DRIVER_REPO" init -q
  git -C "$DRIVER_REPO" config user.email t@t
  git -C "$DRIVER_REPO" config user.name t
  git -C "$DRIVER_REPO" commit -q --allow-empty -m init
  DRIVER_REPO="$(git -C "$DRIVER_REPO" rev-parse --show-toplevel)"
  : >"$FAKE_LOG"
}
run_state() { jq -r "$1" "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
say_in_claude() { # text [cwd] — Claude 트랜스크립트에 사용자 메시지를 남긴다
  mkdir -p "$DRIVER_TMP/claude/projects/p"
  jq -nc --arg c "${2:-$DRIVER_REPO}" --arg m "$1" '{type:"user", cwd:$c, timestamp:"2999-01-01T00:00:00.000Z", message:{role:"user", content:$m}}' \
    >>"$DRIVER_TMP/claude/projects/p/$FAKE_SCENARIO.jsonl"
}
start_and_approve() { # scenario [start args...]
  new_driver_repo "$1"
  shift
  driver start --runtime codex --request "add feature" "$@"
  [[ "$DRIVER_RC" == 10 ]] || return 0
  say_in_claude "승인"
  driver resume
}

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

# 화면이 바뀌는 기능은 Brief가 ui_scenarios를 내고, review 뒤 ui_review가 실제 화면을 검증한다. (#150)
start_and_approve ui_ok
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a UI change reaches done only through a verified ui_review"
assert_eq "review;ui_review" "$(tail -n 2 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "ui_review runs after a review with no blocking findings"
assert_contains "$(<"$FAKE_LOG")" "ui_review workspace-write schema=yes net=yes add-dir=yes" "ui_review may run the app and a browser and save captures in the run directory; the fingerprint keeps the repository unchanged"
assert_file "$(run_state .ui_review.evidence_dir)/default.png"
assert_contains "$(<"$(dirname "$(run_state .ui_review.evidence_dir)")/brief.md")" "## 화면 검증 시나리오" "the approved brief carries the UI scenarios"
assert_contains "$(<"$FAKE_LOG.ui_review.prompt")" "default and collapsed states" "ui_review looks at the default state before hovering"
assert_contains "$(<"$FAKE_LOG.ui_review.prompt")" "a screenshot file existing" "ui_review is told what is not evidence"
assert_contains "$DRIVER_OUT" "UI: verified" "the outcome reports the UI verification"
[[ "$(<"$FAKE_LOG.brief.prompt")" == *"ui_scenarios"* ]] || fail "the brief node is asked for UI scenarios"
start_and_approve ui_issues_once
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a blocking UI issue goes through repair and re-verification"
assert_eq "ui_review;repair;review;ui_review" "$(grep -E '^(ui_review|repair|review) ' "$FAKE_LOG" | tail -n 4 | cut -d' ' -f1 | paste -sd ';' -)" "after repair the change is reviewed and its screens verified again"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "펼침 표시가 없어" "repair receives the UI finding"
start_and_approve ui_unverified
assert_eq "20:user_decision:unverified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a UI that could not be verified is never done"
assert_contains "$DRIVER_OUT" "implementation done, UI unverified" "the outcome separates implementation from verification"
assert_eq "0" "$(run_state .attempts)" "an unverified UI goes to a person without repair attempts"
start_and_approve ui_empty_issues
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "issues without findings count as unverified, not as done"
start_and_approve ui_hollow
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "verified without a record of operating each scenario is not evidence"
start_and_approve ui_partial
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "verified with unverified items left is not done"
start_and_approve ui_fake_capture
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .ui_review.status)" "a capture named in the output but missing from the evidence directory is not evidence"
start_and_approve ui_writes
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "ui_review that writes into the repository stops the run"
assert_contains "$DRIVER_OUT" "capture.png" "the violation names the file the node left in the repository"
# Brief가 화면 변경을 놓쳐도 화면 파일이 바뀌면 검증한다.
start_and_approve screen_backstop
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a run whose brief missed the screen change still ends verified"
assert_contains "$(run_state '.ui_scenarios[0]')" "templates/approve.html" "changed screen files become a UI scenario"
assert_eq "review;ui_review" "$(tail -n 2 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "the backstop routes through ui_review"
# 갱신하지 않은 그래프(ui_review 없음)는 그대로 따르되 화면을 검증하지 않았다고 밝힌다.
new_driver_repo ui_legacy_graph
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.nodes.ui_review) | .transitions |= map(select(.from != "ui_review" and .to != "ui_review"))' \
  "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a UI change on a graph without ui_review is never done"
assert_contains "$DRIVER_OUT" "implementation done, UI unverified: the project graph has no ui_review node" "that outcome says the screens were not verified and how to fix it"
assert_eq "null" "$(run_state .publish)" "nothing is published without UI verification"

# 전이는 저장소 그래프가 정한다: review -> done 엣지를 지우면 done에 갈 수 없다.
new_driver_repo graph_driven
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.from == "review" and .to == "publish"))' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "40" "$DRIVER_RC" "an edge missing from the project graph cannot be taken"
assert_contains "$DRIVER_OUT" "graph declares no transition from 'review'" "the runner names the undeclared edge"

# harness.json의 approval·git_policy가 사람 대기와 git 단계를 정한다.
with_policy() { # git_policy 개인 승인 모드 → 저장소 manifest와 개인 설정을 준비한다
  mkdir -p "$DRIVER_REPO/.ai-harness"
  jq -n --arg g "$1" --arg id "$(basename "$DRIVER_REPO")" '{project_id:$id, level:"standard", git_policy:$g}' >"$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m manifest
  git init -q --bare "$DRIVER_TMP/remote-$FAKE_SCENARIO.git"
  git -C "$DRIVER_REPO" remote add origin "$DRIVER_TMP/remote-$FAKE_SCENARIO.git"
  if [[ -n "$2" ]]; then printf 'HM_APPROVAL=%s\n' "$2" >"$DRIVER_TMP/data/config"; else : >"$DRIVER_TMP/data/config"; fi
}
new_driver_repo auto_pr
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:auto-policy" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source)" "approval auto passes the gate without a person and reaches done"
assert_contains "$(run_state '[.history[].outcome] | join(",")')" "auto_approved_by_policy" "auto approval follows the declared graph edge"
assert_file "$(run_state .approval.brief)"
assert_eq "HM_APPROVAL" "$(run_state .policy.approval_source)" "the selected approval source stays in run state"
APPROVAL_BRIEF="$(run_state .approval.brief)"
assert_contains "$(<"$APPROVAL_BRIEF")" "승인 모드: auto (출처: HM_APPROVAL)" "brief.md records the approval mode and source for the PR body"
assert_eq "https://example.test/pr/7" "$(run_state .publish.pr_url)" "pr-only opens a PR in the publish node"
assert_contains "$DRIVER_OUT" "PR: https://example.test/pr/7" "done reports the PR"
assert_eq "publish workspace-write schema=yes net=yes;remote_ci workspace-write schema=yes net=yes" "$(tail -n 2 "$FAKE_LOG" | paste -sd ';' -)" "publish writes with network access, then remote_ci reads CI with network access and a schema"
assert_eq "passed:$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(run_state '"\(.remote_ci.status):\(.remote_ci.head)"')" "done waits for remote CI of the pushed commit"
assert_contains "$DRIVER_OUT" "remote CI: passed" "done reports the remote CI result"
assert_contains "$(<"$FAKE_LOG.remote_ci.prompt")" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "remote_ci is told the exact pushed commit"
assert_contains "$(<"$FAKE_LOG.remote_ci.prompt")" "A local run of the CI commands is not a remote result" "a local CI-equivalent run does not stand in for remote CI"
assert_eq "1" "$(run_state '.checkpoints | length')" "the runner commits a local checkpoint after deliver"
assert_contains "$(git -C "$DRIVER_REPO" log --format=%s)" "wip(implement-feature): deliver" "checkpoint commit is on the branch"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(git -C "$DRIVER_TMP/remote-auto_pr.git" rev-parse feat/add-feature)" "the work branch is pushed"

# 원격 CI 실패는 같은 수리 루프로 고쳐 일반 push 후 다시 본다. 볼 수 없으면 done이 아니라 미확인으로 사람에게 간다.
new_driver_repo ci_fail_once
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:passed:1" "$DRIVER_RC:$(run_state .status):$(run_state .remote_ci.status):$(run_state .attempts)" "a remote CI failure goes back through repair and is checked again"
assert_contains "$(<"$FAKE_LOG.repair.prompt")" "remote CI failed: test (ubuntu): expected 12:00:00.123456" "repair receives the failing remote check and its log lines"
assert_contains "$(run_state '[.history[].outcome] | join(",")')" "remote_ci_failed" "the failure follows the declared remote_ci -> repair edge"
assert_eq "2" "$(grep -c '^publish ' "$FAKE_LOG")" "the repaired commit is published again"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "push to it and return its URL instead of opening another" "a repeated publish reuses the open PR"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(git -C "$DRIVER_TMP/remote-ci_fail_once.git" rev-parse feat/add-feature)" "the repair is pushed with a normal push"
new_driver_repo ci_always_fail
with_policy pr-only auto
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_repair_attempts = 2' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "remote CI that stays red stops at the graph repair limit"
new_driver_repo ci_unverified
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "remote CI that cannot be observed is never done"
assert_contains "$DRIVER_OUT" "remote CI unverified: no CI tool or token for this host; PR: https://example.test/pr/7" "the outcome says remote CI is unverified and names the PR"
new_driver_repo ci_stale
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .remote_ci.status)" "a CI result for another commit does not count"
new_driver_repo ci_pending
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "30:incomplete:remote_ci" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "remote CI still running leaves the run resumable at remote_ci"
assert_contains "$DRIVER_OUT" "run resume to check again" "the runner says how to check again"
new_driver_repo ci_none
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:none" "$DRIVER_RC:$(run_state .status):$(run_state .remote_ci.status)" "a repository without remote CI is done after the PR"
new_driver_repo ci_none_but_configured
with_policy pr-only auto
mkdir -p "$DRIVER_REPO/.github/workflows" && echo "on: push" >"$DRIVER_REPO/.github/workflows/test.yml"
git -C "$DRIVER_REPO" add .github && git -C "$DRIVER_REPO" commit -q -m ci
driver start --runtime codex --request "add feature"
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .remote_ci.status)" "a 'no remote CI' report is not trusted when the repository has CI configuration"
new_driver_repo ci_rewrites_remote
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "remote_ci may only read CI: a moved remote branch stops the run"
# 갱신하지 않은 프로젝트 그래프(publish → done)는 그대로 따르되, 원격 CI를 보지 않았다고 밝힌다.
new_driver_repo legacy_publish_graph
with_policy pr-only auto
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.nodes.remote_ci) | .transitions |= (map(select(.from != "remote_ci")) | map(if .to == "remote_ci" then .to = "done" else . end))' \
  "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
assert_eq "0:done:null" "$DRIVER_RC:$(run_state .status):$(run_state .remote_ci)" "a project graph without remote_ci still ends at publish"
assert_contains "$DRIVER_OUT" "remote CI: unverified — the project graph has no remote_ci node" "that outcome says remote CI was not checked"

new_driver_repo dirty_start
with_policy pr-only auto
echo wip >"$DRIVER_REPO/notes.txt"
driver start --runtime codex --request "add feature"
assert_eq "2" "$DRIVER_RC" "a runner that may commit refuses to start on a dirty tree"
rm "$DRIVER_REPO/notes.txt"
git -C "$DRIVER_REPO" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$(git -C "$DRIVER_REPO" rev-parse --abbrev-ref HEAD)"
driver start --runtime codex --request "add feature"
assert_eq "2" "$DRIVER_RC" "pr-only refuses to start on the base branch"
assert_contains "$DRIVER_OUT" "not the base branch" "the runner says why"

new_driver_repo auto_questions
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "auto approval waits for a person when the brief comes back in the legacy open_questions format"
new_driver_repo auto_legacy
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "auto approval waits when the brief recorded no decisions, even without open questions"

# auto에서 brief 노드는 판단이 갈리는 점을 추천안으로 정하고(decisions), 사람만 정할 수 있는 것만 needs_human에 남긴다.
new_driver_repo auto_decisions
with_policy direct auto
driver start --runtime codex --request "add feature"
assert_eq "0:done:auto-policy" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source)" "auto approval with decisions and no needs_human reaches done in one start"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "needs_human" "auto approval asks the brief node to decide and list what only a person can decide"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "migration" "the needs_human criteria name hard-to-reverse choices"
assert_contains "$(<"$(dirname "$(run_state .approval.brief)")/brief.md")" "## 결정 사항" "brief.md keeps the decisions section"
assert_contains "$(<"$(dirname "$(run_state .approval.brief)")/brief.md")" "which plan tier? → free tier only — smallest scope that meets the request" "brief.md records question, choice, and rationale"
assert_contains "$(<"$FAKE_LOG.deliver.prompt")" "free tier only" "deliver implements the brief with its decisions"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "which plan tier? → free tier only" "publish receives the decisions"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "승인 모드: auto (출처: HM_APPROVAL)" "PR instructions carry the resolved approval mode and source"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" '"결정 사항"' "publish is told to copy decisions into the PR body section"

new_driver_repo auto_needs_human
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "10:approval:waiting_approval" "$DRIVER_RC:$(run_state .node):$(run_state .status)" "auto approval stops at the approval node when the brief needs a person"
assert_contains "$DRIVER_OUT" "drop the legacy plans table?" "the person sees what only they can decide"
assert_contains "$DRIVER_OUT" "which plan tier? → free tier only" "the person also sees the decisions the agent made"
assert_eq "discover;brief" "$(cut -d' ' -f1 "$FAKE_LOG" | paste -sd ';' -)" "nothing writes while needs_human is open"
say_in_claude "승인"
driver resume
assert_eq "0:done:claude-transcript" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source)" "a person's approval resolves needs_human and the run continues"

new_driver_repo auto_no_edge
with_policy pr-only auto
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.when == "auto_approved_by_policy"))' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --runtime codex --request "add feature"
assert_eq "10" "$DRIVER_RC" "a project graph without the auto edge keeps the human gate"

new_driver_repo human_pr
with_policy pr-only ""
FAKE_CHECK="grep -q fixed feature.txt" driver start --runtime codex --request "add feature"
assert_eq "10:human:default" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "approval defaults to human and records the default source"
say_in_claude "승인"
driver resume
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state '.checkpoints | length')" "a human-approved pr-only run checkpoints deliver and each repair, then opens a PR"

new_driver_repo approval_repo
with_policy pr-only ""
printf 'HM_APPROVAL=auto\nHM_APPROVAL_REPOS="repo-approval_repo=human,elsewhere=auto"\n' >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "10:human:HM_APPROVAL_REPOS:repo-approval_repo" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "a matching repository approval setting overrides the global setting"

new_driver_repo approval_global
with_policy pr-only ""
printf 'HM_APPROVAL=auto\nHM_APPROVAL_REPOS="another=human"\n' >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "0:auto:HM_APPROVAL" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "the global approval setting applies without a matching repository entry"

new_driver_repo manifest_approval
with_policy pr-only ""
jq '.approval = "auto"' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/manifest.json" && mv "$DRIVER_REPO/manifest.json" "$DRIVER_REPO/.ai-harness/harness.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m legacy-approval
: >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "10:human:default" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "a legacy manifest approval value is ignored"
assert_eq "1" "$(grep -c 'notice: .ai-harness/harness.json approval is ignored' <<<"$DRIVER_OUT")" "a legacy manifest approval value produces one migration notice"

# 승인 모드 오타를 human으로 조용히 읽지 않는다 — 시작하지 않고 고칠 키를 알린다.
new_driver_repo approval_invalid
with_policy pr-only ""
printf 'HM_APPROVAL=yes\n' >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "2" "$DRIVER_RC" "an invalid personal approval value stops the start"
assert_contains "$DRIVER_OUT" "approval must be human or auto" "the invalid approval value is named"
assert_contains "$DRIVER_OUT" "HM_APPROVAL in $DRIVER_TMP/data/config" "the invalid approval names the config file it came from"
: >"$DRIVER_TMP/data/config"
# 값이 환경변수에서 왔으면 config 파일이 아니라 환경변수라고 말한다(#310).
DRIVER_RC=0
DRIVER_OUT="$(HM_APPROVAL=yes HM_APPROVAL_REPOS='' HARNESS_METRICS_DIR="$DRIVER_TMP/data" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" CLAUDE_CONFIG_DIR="$DRIVER_TMP/claude" CODEX_HOME="$DRIVER_TMP/codex" \
  FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO="$FAKE_SCENARIO" PATH="$ROOT/tests/fixtures/driver:$PATH" \
  bash "$DRIVER" start --runtime codex --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "an invalid approval from the environment stops the start"
assert_contains "$DRIVER_OUT" "HM_APPROVAL in the environment" "the invalid approval names the environment as its source"
[[ "$DRIVER_OUT" != *"config is"* ]] || fail "an environment value is not reported as a config file value"

# 업그레이드 전에 시작된 실행에는 approval_source가 없다 — 기본값(default)이 아니라 legacy로 보인다(#310).
new_driver_repo approval_legacy_status
with_policy pr-only ""
driver start --runtime codex --request "add feature"
LEGACY_STATE="$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
jq 'del(.policy.approval_source)' "$LEGACY_STATE" >"$LEGACY_STATE.tmp" && mv "$LEGACY_STATE.tmp" "$LEGACY_STATE"
driver status --workflow feature --run "$(run_state .run_id)"
assert_contains "$DRIVER_OUT" "approval human (legacy)" "a run without a recorded approval source shows legacy"
[[ "$DRIVER_OUT" != *"(default)"* ]] || fail "a legacy run is not shown as using the default approval"

new_driver_repo publish_unpushed
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a publish the runner cannot verify goes to a person"
assert_contains "$(run_state '.findings | join(";")')" "HEAD is not pushed to its upstream" "publish is judged by git state, not the session report"
assert_contains "$(run_state '.findings | join(";")')" "pr_url is empty" "pr-only without a PR is not done"

# 사용자가 손대 갱신되지 않은 0.38 그래프(publish·auto 엣지 없음, 횟수가 박힌 엣지 이름)에서도 러너는 그 그래프대로 간다.
legacy_graph() {
  mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
  jq '.limits.max_repair_attempts = 2 | del(.nodes.publish)
      | .transitions |= (map(select(.from != "publish" and .when != "auto_approved_by_policy"))
        | map(if .to == "publish" then .to = "done" else . end
              | if .from == "repair" and .to == "user_decision" then .when = "same_root_cause_after_two_attempts_or_product_decision" else . end))' \
    "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
  git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m legacy-graph
}
new_driver_repo legacy_ok
with_policy pr-only auto
legacy_graph
driver start --runtime codex --request "add feature"
assert_eq "10" "$DRIVER_RC" "a legacy graph without the auto edge waits for a person"
say_in_claude "승인"
driver resume
assert_eq "0:done:null" "$DRIVER_RC:$(run_state .status):$(run_state .publish)" "a legacy graph reaches done without a publish node"
new_driver_repo review_blocks_legacy
FAKE_SCENARIO=review_blocks
legacy_graph
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "the escalation edge and repair limit come from the project graph"
pass "feature delivery graph runner enforces the graph outside the model"

# 버그 수정·변경 검토도 같은 러너가 실행한다. (#154)
BUG_FIX_GRAPH_TEMPLATE="$ROOT/templates/fix-bug/references/bug-fix-graph.json"
REVIEW_GRAPH_TEMPLATE="$ROOT/templates/review/references/review-graph.json"
run_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
bug_run() { # scenario [start args...] → 승인 뒤 resume까지
  new_driver_repo "$1"
  shift
  driver start --workflow bug-fix --runtime codex --request "total ignores tax" "$@"
  [[ "$DRIVER_RC" == 10 ]] || return 0
  say_in_claude "승인"
  driver resume
}
new_driver_repo bug_ok
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
assert_eq "10:approval:bug-fix" "$DRIVER_RC:$(run_state .node):$(run_state .workflow)" "a bug fix stops at approval after triage, reproduce, and brief"
assert_eq "triage read-only schema=;reproduce workspace-write schema=yes add-dir=yes;brief read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "nothing writes before approval; reproduce may run commands and keeps its notes in the run directory"
assert_contains "$DRIVER_OUT" "Bug Fix Brief" "the person sees a Bug Fix Brief"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "expected 110, got 100" "the brief carries the reproduction evidence"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" ".ai-harness/workflows/fix-bug.md" "bug-fix nodes read the project bug-fix workflow"
assert_contains "$(run_state .graph)" "bug-fix-graph.json" "the run follows the bug-fix graph"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an approved bug fix reaches done"
assert_contains "$(run_state '[.history[].to] | join(",")')" "regression,fix,verify,review,publish,remote_ci,done" "the runner follows the bug-fix graph"
assert_eq "regression workspace-write;fix workspace-write;review read-only" "$(tail -n 3 "$FAKE_LOG" | cut -d' ' -f1,2 | paste -sd ';' -)" "regression and fix write after approval; review stays read-only"
bug_run repro_blocked
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a bug that can be neither reproduced nor observed goes to a person before approval"
assert_contains "$(<"$(run_dir)/unresolved.json")" "a sample order export" "the person sees what is needed to reproduce"
[[ "$(<"$FAKE_LOG")" != *regression* ]] || fail "nothing writes when the bug cannot be reproduced"
bug_run repro_hollow
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "reproduced without evidence is not a reproduction"
bug_run repro_writes
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "reproduce that writes into the repository stops the run"
FAKE_CHECK="grep -q fixed feature.txt" bug_run bug_fixcheck
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failing verify goes to repair, then verify and review again"
assert_eq "fix;repair;review" "$(grep -E '^(fix|repair|review) ' "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "the failed check is repaired before review"
bug_run bug_noop
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a bug fix without a change is not done"
bug_run bug_fix_noop
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a regression test alone does not count as a fix"
bug_run ui_bug
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a bug fix that changes a screen goes through ui_review"
assert_file "$(run_state .ui_review.evidence_dir)/default.png"
new_driver_repo bug_pr
with_policy pr-only auto
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state '.checkpoints | length')" "an auto-approved pr-only bug fix checkpoints regression and fix, then opens a PR"
assert_contains "$(git -C "$DRIVER_REPO" log --format=%s)" "wip(fix-bug): regression" "bug-fix checkpoints name the workflow"
new_driver_repo bug_legacy_verify
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.from == "verify" and .when == "required_checks_fail"))' "$BUG_FIX_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/bug-fix-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
FAKE_CHECK=false driver start --workflow bug-fix --runtime codex --request "total ignores tax"
say_in_claude "승인"
FAKE_CHECK=false driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a graph without the verify failure edge hands a failed check to a person"
assert_contains "$DRIVER_OUT" "no verify -> repair edge" "that outcome says how to fix it"
# 실행의 워크플로는 상태가 정한다. 다른 워크플로로 이어 가지 않는다.
driver status --workflow review --run "$(run_state .run_id)"
assert_eq "2" "$DRIVER_RC" "a run cannot be resumed as another workflow"
DRIVER_RC=0
DRIVER_OUT="$(HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER_SHIM" status --repo "$DRIVER_REPO" 2>&1)" || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "the old feature entry point does not resume a bug-fix run"
new_driver_repo shim_ok
DRIVER_RC=0
DRIVER_OUT="$(HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO=shim_ok PATH="$ROOT/tests/fixtures/driver:$PATH" \
  bash "$DRIVER_SHIM" start --runtime codex --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
assert_eq "10:feature" "$DRIVER_RC:$(run_state .workflow)" "the old entry point runs the feature workflow"
DRIVER_RC=0
HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER_SHIM" status --workflow review --repo "$DRIVER_REPO" >/dev/null 2>&1 || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "the old entry point refuses another workflow instead of running the feature one"
# 이 구분 전의 feature 실행(latest-feature 없음)은 그 뒤 다른 워크플로를 시작해도 이어 갈 수 있다.
rm -f "$(dirname "$(run_dir)")/latest-feature"
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
DRIVER_RC=0
DRIVER_OUT="$(HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" bash "$DRIVER_SHIM" status --repo "$DRIVER_REPO" 2>&1)" || DRIVER_RC=$?
assert_eq "0" "$DRIVER_RC" "an older feature run is still found after another workflow started"
assert_contains "$DRIVER_OUT" "workflow feature" "the old entry point resumes the feature run, not the newer bug-fix run"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
export HM_SMOKE_RETRY_SECONDS=0
as_host_repo() { # host/owner/repo → origin을 그 호스트 주소로 두고 실제 push는 bare 저장소로 보낸다(insteadOf)
  git -C "$DRIVER_REPO" config remote.origin.url "https://$1.git"
  git -C "$DRIVER_REPO" config "url.$DRIVER_TMP/remote-$FAKE_SCENARIO.git.insteadOf" "https://$1.git"
}
MR_DATA="$DRIVER_TMP/merge-data"
mkdir -p "$MR_DATA"
merge_config() { # merge-settings-json → 개인 config: 검증에 배포·스모크·재발 추적이 있으면 단계 deploy, 아니면 merge
  jq -r '"HM_APPROVAL=auto", "HM_DELIVERY_LEVEL=" + (if (.verify // []) | any(IN("deploy", "smoke", "monitor")) then "deploy" else "merge" end)' <<<"$1" >"$MR_DATA/config"
}
merge_run() { # scenario merge-settings-json [host/owner/repo] → 저장소 사실은 manifest에, 단계는 개인 config에 두고 approval auto로 실행한다
  new_driver_repo "$1"
  with_policy pr-only auto
  as_host_repo "${3:-github.com/acme/app}"
  jq --argjson m "$2" '.merge_policy = ($m | del(.require, .min_approvals, .method))' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" \
    && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  merge_config "$2"
  cp "$MR_DATA/config" "$DRIVER_TMP/data/config"
  DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "add feature"
}
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
MP_BASIC='{"verify":["target_ci"],"base":"main"}'
merge_run merge_ok "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "merge policy merges and verifies when every condition holds"
assert_contains "$(<"$FAKE_LOG")" "gh merge https://github.com/acme/app/pull/7 --squash --match-head-commit $(git -C "$DRIVER_REPO" rev-parse HEAD)" "the runner merges with the head pinned to the reviewed, pushed commit"
assert_contains "$(<"$FAKE_LOG")" "gh api repos/acme/app" "the merge method is read from the repository settings"
assert_eq "remote_ci,merge,post_merge_verify" "$(run_state '[.history[] | select(.from | IN("remote_ci", "merge", "post_merge_verify")) | .from] | join(",")')" "merge follows remote CI and is verified after"
assert_eq "1111111111111111111111111111111111111111:alice:passed" "$(run_state '"\(.merge.commit):\(.merge.approvals | join(",")):\(.post_merge.target_ci.status)"')" "the merge commit and the approvers are recorded"
assert_contains "$DRIVER_OUT" "merged: 111111111111 (squash); after merge: target_ci passed" "done reports the merge and the post-merge checks"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "Never merge (under merge the driver merges later" "the publish node still never merges by itself"
# 승인이 아직 없으면 병합하지 않고 기다리며, resume이 다시 본다.
merge_run merge_wait "$MP_BASIC"
assert_eq "30:incomplete:merge" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "missing human approval waits at merge"
assert_contains "$DRIVER_OUT" "human approval: 0 of 1 on the current head" "the wait names the unmet condition"
assert_eq "0" "$(grep -c '^gh merge' "$FAKE_LOG" || true)" "nothing is merged while a condition is unmet"
touch "$FAKE_LOG.approved"
driver resume
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG")" "resume merges once the approval arrives"
# 승인은 지금 head에 대한 것이고 작성자 본인이 아니어야 한다.
merge_run merge_stale "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval of an older commit does not count"
merge_run merge_self "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "the author's own approval does not count"
merge_run merge_outsider "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval from an account without write access does not count"
merge_run merge_bot "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "a bot's approval does not count"
merge_run merge_dismissed "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "a dismissed approval does not count"
merge_run merge_rereviewed "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a reviewer who requested changes and then approved counts as approving"
merge_run merge_draft "$MP_BASIC"
assert_contains "$DRIVER_RC:$DRIVER_OUT" "30:" "a draft pull request waits"
assert_contains "$DRIVER_OUT" "the pull request is a draft" "the draft condition is named"
# 고를 수 없는 상태는 사람에게 넘긴다.
for s in merge_changes:"a reviewer requested changes" merge_conflict:"merge conflicts" merge_closed:"closed without merging" \
  merge_otherbase:"targets release, not the base branch main" merge_hostci_fail:"the host reports the checks on the head as failed" \
  merge_headmoved:"is not the pushed and reviewed commit" merge_host_down:"cannot read the pull request state" merge_cmd_fail:"merging failed"; do
  merge_run "${s%%:*}" "$MP_BASIC"
  assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "${s%%:*} goes to a person"
  assert_contains "$DRIVER_OUT" "merge blocked: " "${s%%:*} says the merge was blocked"
  assert_contains "$DRIVER_OUT" "${s#*:}" "${s%%:*} names the reason"
done
assert_eq "0" "$(grep -c '^gh merge' "$DRIVER_TMP/merge_changes.log" || true)" "requested changes are never merged over"
# 다른 저장소의 PR은 병합하지 않는다.
merge_run merge_otherrepo "$MP_BASIC" github.com/acme/other
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a pull request outside this repository is never merged"
assert_contains "$DRIVER_OUT" "is not in this repository" "the repository mismatch is named"
# Bitbucket: 승인은 마지막 push 뒤의 것만 센다. 자격증명은 stdin으로 넘긴다.
export ATLASSIAN_USER='me@example.com' BITBUCKET_API_TOKEN='tok"en' FAKE_PROTECTION=bb_glob
merge_run bb_merge "$(jq -c '.verify = []' <<<"$MP_BASIC")" bitbucket.org/acme/app
assert_eq "0:done:111111111111:repository default" "$DRIVER_RC:$(run_state .status):$(run_state .merge.commit):$(run_state .merge.method)" "a Bitbucket pull request is merged when its conditions hold"
assert_contains "$(<"$FAKE_LOG")" "curl POST acme/app/pullrequests/7/merge" "the Bitbucket merge endpoint is called"
assert_contains "$(<"$FAKE_LOG")" 'curl body {"close_source_branch": false}' "Bitbucket merges with the repository's default strategy"
merge_run bb_stale "$(jq -c '.verify = []' <<<"$MP_BASIC")" bitbucket.org/acme/app
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "a Bitbucket approval from before the last push does not count"
unset ATLASSIAN_USER BITBUCKET_API_TOKEN
export FAKE_PROTECTION=classic
# 사람이 먼저 병합했으면 그 병합 커밋으로 병합 후 검증을 이어 간다.
merge_run merge_outside "$MP_BASIC"
assert_eq "0:done:outside the runner:0" "$DRIVER_RC:$(run_state .status):$(run_state .merge.method):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a pull request merged by a person is verified without merging again"
# 호스트 보호가 필수 승인을 걸면 그 승인을 기다린다. 방식은 저장소가 허용한 방식을 따른다.
export FAKE_MERGE_METHODS=merge_only
merge_run merge_noapproval '{"verify":[],"base":"main"}'
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "the host's required approval is waited for"
assert_contains "$DRIVER_OUT" "human approval: 0 of 1" "the wait names the approval the host requires"
touch "$FAKE_LOG.approved"
DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver resume
assert_eq "0:done:merge" "$DRIVER_RC:$(run_state .status):$(run_state .merge.method)" "resume merges once the host-required approval arrives"
assert_contains "$(<"$FAKE_LOG")" "--merge --match-head-commit" "the merge method is the one the repository allows"
for m in unknown:"the repository settings do not say which merge methods are allowed" denied:"cannot read which merge methods the repository allows"; do
  export FAKE_MERGE_METHODS="${m%%:*}"
  merge_run "merge_method_${m%%:*}" "$MP_BASIC"
  assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "merge methods ${m%%:*}: the runner does not guess a merge method"
  assert_contains "$DRIVER_OUT" "${m#*:}" "merge methods ${m%%:*}: the person is told why"
done
unset FAKE_MERGE_METHODS
# 원격 CI가 없다는 보고는 remote_ci 조건을 채우지 못한다.
merge_run merge_ci_none "$MP_BASIC"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "require remote_ci needs a passed remote CI, not 'no CI'"
# 무인 실행은 병합하지 않는다.
HM_INTERNAL_SESSION=1 merge_run merge_unattended "$MP_BASIC"
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh ' "$FAKE_LOG" || true)" "an unattended run never merges"
assert_contains "$DRIVER_OUT" "merge: not done — unattended run" "the outcome says the merge was left to a person"
# PR 호스트를 읽을 수 없는 URL이면 병합하지 않는다.
merge_run ok_unknown_host "$MP_BASIC"
assert_contains "$DRIVER_RC:$DRIVER_OUT" "20:" "an unsupported pull request host is not merged"
assert_contains "$DRIVER_OUT" "unsupported pull request host" "the reason names the host"
# 병합 후 검증: 타깃 CI → 배포 확인 → 스모크. 실패는 되돌리지 않고 사람에게, 배포 미관측은 기한까지 resume.
merge_run pm_ci_fail "$MP_BASIC"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a failed CI on the merge commit goes to a person"
assert_contains "$DRIVER_OUT" "post-merge check failed: CI on main for the merge commit" "the failure is reported as post-merge"
assert_contains "$(run_state '.findings[1]')" "git revert 1111111111111111111111111111111111111111" "rollback instructions are given, not executed"
# 배포 확인 명령을 실행할 수 없으면(127) 기한까지 기다리지 않는다.
merge_run pm_deploy_missing '{"base":"main","verify":["deploy"],"deploy_check_cmd":"no-such-deploy-check"}'
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a deploy check that cannot run is reported at once"
assert_contains "$DRIVER_OUT" "could not run (exit 127" "the broken command is named"
# base가 manifest에도 origin 기본 브랜치에도 없으면 시작하지 않는다.
merge_run merge_nobase '{}'
assert_eq "2" "$DRIVER_RC" "merge needs to know the base branch it may merge into"
assert_contains "$DRIVER_OUT" "merge_policy.base" "the error says how to set the base branch"
merge_run pm_ci_other "$MP_BASIC"
assert_eq "20:unverified" "$DRIVER_RC:$(run_state .post_merge.target_ci.status)" "a CI result for another commit does not verify the merge"
MP_DEPLOY="$(jq -cn --arg d "test -f $DRIVER_TMP/deployed-\$FAKE_SCENARIO" '{base:"main", verify:["target_ci","deploy","smoke"], deploy_check_cmd:$d, deploy_timeout_minutes:30, smoke_cmd:"test \"$HM_MERGE_COMMIT\" = 1111111111111111111111111111111111111111"}')"
merge_run pm_deploy "$MP_DEPLOY"
assert_eq "30:incomplete:post_merge_verify" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "a deploy not observed yet leaves the run resumable"
assert_contains "$DRIVER_OUT" "not deployed yet" "the wait says the deploy is not observed"
touch "$DRIVER_TMP/deployed-pm_deploy"
driver resume
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^post_merge_verify ' "$FAKE_LOG")" "resume finishes deploy and smoke without rerunning the passed CI step"
assert_contains "$DRIVER_OUT" "target_ci passed, deploy passed, smoke passed" "every post-merge check is reported"
merge_run pm_deploy_late "$MP_DEPLOY"
jq '.merge.merged_epoch -= 3600' "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)" >"$DRIVER_TMP/s.json" \
  && mv "$DRIVER_TMP/s.json" "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a deploy not observed within the timeout goes to a person"
assert_contains "$DRIVER_OUT" "was not observed as deployed within 30 minutes" "the timeout is named"
merge_run pm_smoke_fail '{"verify":["smoke"],"smoke_cmd":"false","base":"main"}'
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a smoke check that fails twice goes to a person"
assert_contains "$DRIVER_OUT" "the smoke check failed twice" "the smoke failure is named"
# 모니터링 재발 확인: 관찰 창이 길어 러너는 고친 에러를 /autofix 추적에 올리는 데까지 한다.
monitor_run() { # scenario [--monitor-error 파일] → monitor 설정·project_id가 있는 저장소에서 단계 deploy·verify monitor로 실행한다
  local scenario="$1"
  shift
  new_driver_repo "$scenario"
  with_policy pr-only auto
  as_host_repo github.com/acme/app
  jq --arg local "${MONITOR_LOCAL:-}" '.project_id = "acme-app" | .monitor = {provider: "command", command: "bin/errors", window_hours: 168}
    | .merge_policy = {verify: ["monitor", "target_ci"], base: "main"} | if $local == "1" then del(.monitor) else . end' \
    "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  merge_config '{"verify":["monitor"]}'
  cp "$MR_DATA/config" "$DRIVER_TMP/data/config"
  DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "fix the crash" "$@"
}
mkdir -p "$DRIVER_TMP/plugin/scripts"
cat >"$DRIVER_TMP/plugin/scripts/autofix-auto.sh" <<'EOF'
printf 'autofix %s\n' "$*" >>"$FAKE_LOG"
[[ "$FAKE_SCENARIO" != pm_monitor_fail ]] || { echo "state lock failed" >&2; exit 1; }
EOF
printf '%s\n' '{"signature":"sig-42","title":"NullPointerException in Checkout","count":12,"meta":{"id":"42"}}' >"$DRIVER_TMP/monitor-error.json"
export HM_PLUGIN_ROOT="$DRIVER_TMP/plugin"
monitor_run pm_monitor --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "the monitor step finishes the run once the error is tracked"
assert_contains "$(<"$FAKE_LOG")" "autofix track --project acme-app --candidate {\"window_hours\":168,\"signature\":\"sig-42\"" "the fixed error is registered with /autofix, with the manifest's observation window"
assert_contains "$(<"$FAKE_LOG")" "--pr https://github.com/acme/app/pull/7" "the tracked pull request is the merged one"
assert_eq "target_ci,monitor" "$(run_state '.post_merge | keys_unsorted | join(",")')" "post-merge checks run in the fixed order whatever order the manifest lists"
assert_contains "$DRIVER_OUT" "monitor tracked (recurrence of sig-42 is handed to /autofix" "done says the recurrence check continues in /autofix"
monitor_run pm_monitor_none
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^autofix ' "$FAKE_LOG" || true)" "a run without a monitoring error has nothing to track"
assert_contains "$DRIVER_OUT" "monitor skipped (no monitoring error was given" "the skip is reported, not hidden"
monitor_run pm_monitor_fail --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a failed registration goes to a person"
assert_contains "$(run_state '.findings[1]')" "register the error by hand: <ai-harness plugin>/scripts/autofix-auto.sh track --project acme-app --candidate" "the person gets the track command, not rollback advice"
# 개인 로컬 monitor 설정(~/.ai-harness/autofix/monitors/<project_id>.json)만 있어도 시작하고, 그 관찰 창을 쓴다.
mkdir -p "$MR_DATA/autofix/monitors"
printf '%s\n' '{"provider":"command","command":"bin/errors","window_hours":48}' >"$MR_DATA/autofix/monitors/acme-app.json"
MONITOR_LOCAL=1 monitor_run pm_monitor_local --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a local monitor file satisfies verify monitor"
assert_contains "$(<"$FAKE_LOG")" "autofix track --project acme-app --candidate {\"window_hours\":48," "the local file's observation window is used"
printf 'not json\n' >"$MR_DATA/autofix/monitors/acme-app.json"
monitor_run pm_monitor_local_bad --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "2" "$DRIVER_RC" "a broken local monitor file does not start, even with a manifest monitor"
assert_contains "$DRIVER_OUT" "autofix/monitors/acme-app.json" "the error names the broken local file"
find "$MR_DATA/autofix/monitors/acme-app.json" -delete
unset HM_PLUGIN_ROOT
printf '%s\n' '{"title":"no signature"}' >"$DRIVER_TMP/bad-error.json"
monitor_run pm_monitor_bad --monitor-error "$DRIVER_TMP/bad-error.json"
assert_eq "2" "$DRIVER_RC" "a monitoring error without a signature does not start"
cat "$DRIVER_TMP/monitor-error.json" "$DRIVER_TMP/monitor-error.json" >"$DRIVER_TMP/two-errors.json"
monitor_run pm_monitor_two --monitor-error "$DRIVER_TMP/two-errors.json"
assert_eq "2:no run" "$DRIVER_RC:$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*" -name state.json | grep -q . && echo run || echo "no run")" "several monitoring errors in one file are refused before a run is created"
merge_run pm_monitor_noconfig '{"verify":["monitor"],"base":"main"}'
assert_eq "2" "$DRIVER_RC" "verify monitor without the monitor settings does not start"
assert_contains "$DRIVER_OUT" "needs the monitor settings (/autofix setup)" "the error points at /autofix setup"
# merge 노드가 없는 옛 그래프는 병합하지 않고 PR까지로 끝낸다.
new_driver_repo merge_oldgraph
with_policy pr-only auto
as_host_repo github.com/acme/app
jq '.merge_policy = {base: "main"}' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.nodes.merge, .nodes.post_merge_verify) | .transitions |= map(select(.from != "merge" and .from != "post_merge_verify" and .to != "merge"))' \
  "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add -A && git -C "$DRIVER_REPO" commit -qm "old graph"
merge_config "$MP_BASIC"
cp "$MR_DATA/config" "$DRIVER_TMP/data/config"
DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "add feature"
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh ' "$FAKE_LOG" || true)" "a project graph without the merge node never merges"
assert_contains "$DRIVER_OUT" "the project graph has no merge node" "the outcome asks for a harness sync"
rm -f "$MR_DATA/config"
unset FAKE_PROTECTION
pass "merge node: host rules, repository facts, merge by the runner, post-merge checks"

# 개인 자동화 단계(#242): 병합 여부는 사용자 config의 단계가, 병합 조건은 호스트 브랜치 보호가 정한다(#384). 저장소 merge_policy는 사실만 준다.
DL_DATA="$DRIVER_TMP/delivery-data"
mkdir -p "$DL_DATA"
delivery_run() { # scenario git_policy harness-jq-filter config-text [host/owner/repo] → 사용자 config를 두고 approval auto로 실행한다
  new_driver_repo "$1"
  with_policy "$2" auto
  as_host_repo "${5:-github.com/acme/app}"
  jq "$3" "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  printf 'HM_APPROVAL=auto\n%s\n' "$4" >"$DL_DATA/config"
  cp "$DL_DATA/config" "$DRIVER_TMP/data/config"
  DRIVER_DATA_OVERRIDE="$DL_DATA" HARNESS_METRICS_DIR="$DL_DATA" driver start --runtime codex --request "add feature"
}
DL_FACTS='.project_id = "acme-app" | .merge_policy = {base: "main", deploy_check_cmd: "true", smoke_cmd: "true"}'
gh_merges() { grep -c '^gh merge' "$FAKE_LOG" || true; }
export FAKE_PROTECTION=classic
delivery_run dl_pr merge ".merge_policy = $MP_BASIC" 'HM_DELIVERY_LEVEL=pr'
assert_eq "0:done:0:pr-only" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .policy.git)" "level pr stops at the pull request even when the repository says git_policy merge"
[[ "$(run_state '[.history[].to] | join(",")')" != *merge* ]] || fail "level pr never reaches the merge node"
assert_contains "$DRIVER_OUT" "notice: the repository git_policy merge is no longer used and is read as pr-only" "done says the repository merge setting is no longer used"
# 저장소 merge_policy의 병합 조건(require·min_approvals·method)은 개인 경로에 영향이 없다.
delivery_run dl_merge pr-only "$DL_FACTS"' | .merge_policy += {require: ["remote_ci"], min_approvals: 3, method: "rebase"}' 'HM_DELIVERY_LEVEL="merge"  # 내 단계'
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(gh_merges)" "level merge merges a pr-only repository's pull request"
assert_eq "target_ci" "$(run_state '.post_merge | keys_unsorted | join(",")')" "level merge verifies up to the target branch CI, not deploy or smoke"
assert_eq "1:1:main" "$(run_state '"\(.protection.approvals):\(.protection.checks):\(.protection.base)"')" "the merge node read the base branch protection from the host"
assert_contains "$(<"$FAKE_LOG")" "gh api repos/acme/app/branches/main/protection" "classic branch protection is read for the base branch"
assert_eq "false:squash" "$(run_state '"\(.policy.merge | has("require") or has("min_approvals") or has("method")):\(.merge.method)"')" "the repository merge_policy conditions are not used; the method is the repository's allowed one"
assert_contains "$DRIVER_OUT" "notice: merge_policy require, min_approvals, and method in .ai-harness/harness.json are no longer used; merges follow the branch protection" "the ignored repository merge conditions are named"
delivery_run dl_deploy pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=deploy'
assert_eq "0:done:target_ci,deploy,smoke" "$DRIVER_RC:$(run_state .status):$(run_state '.post_merge | keys_unsorted | join(",")')" "level deploy goes on to the repository's deploy and smoke checks"
delivery_run dl_deploy_nocmd pr-only '.merge_policy = {base: "main"}' 'HM_DELIVERY_LEVEL=deploy'
assert_eq "0:done:target_ci" "$DRIVER_RC:$(run_state .status):$(run_state '.post_merge | keys_unsorted | join(",")')" "level deploy without deploy or smoke commands stops after the merge"
assert_contains "$DRIVER_OUT" "delivery level deploy: the repository has no deploy or smoke check" "the result says why deploy was not verified"
delivery_run dl_repo_level pr-only "$DL_FACTS" "$(printf '%s\n' 'HM_DELIVERY_LEVEL=pr' 'HM_DELIVERY_LEVEL_REPOS="other=deploy, acme-app=merge"' 'HM_MERGE_REQUIRE="human_approval remote_ci"' 'HM_MERGE_METHOD=merge')"
assert_eq "0:done:1:HM_DELIVERY_LEVEL_REPOS:acme-app" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .policy.delivery.source)" "a per-repository level overrides the default level"
assert_contains "$(<"$FAKE_LOG")" "--squash --match-head-commit" "an old personal HM_MERGE_METHOD is not used"
assert_contains "$DRIVER_OUT" "notice: HM_MERGE_REQUIRE, HM_MERGE_MIN_APPROVALS, and HM_MERGE_METHOD in ~/.ai-harness/config are no longer used" "the ignored personal merge settings are named"
export FAKE_PROTECTION=ruleset
delivery_run dl_ruleset pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
assert_eq "30:merge:0" "$DRIVER_RC:$(run_state .node):$(gh_merges)" "the host's required approval count is the condition"
assert_contains "$DRIVER_OUT" "human approval: 1 of 2" "the runner waits for the approvals the host ruleset requires"
# 보호가 없거나 필수 체크만 있으면 저장소 규칙대로 승인 없이 병합한다. 보호를 읽지 못하면 사람에게 넘긴다.
for p in none:"" checks_only:remote_ci; do
  export FAKE_PROTECTION="${p%%:*}"
  delivery_run "dl_prot_${p%%:*}" pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
  assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(gh_merges)" "protection ${p%%:*}: the runner merges by the repository's own rules"
  assert_eq "0" "$(run_state .protection.approvals)" "protection ${p%%:*}: no approval is required"
done
export FAKE_PROTECTION=denied
delivery_run dl_prot_denied pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(gh_merges)" "protection denied: the runner does not merge without knowing the repository's rules"
assert_contains "$DRIVER_OUT" "cannot read the branch protection of main from the host" "protection denied: the person is told why"
export ATLASSIAN_USER='me@example.com' BITBUCKET_API_TOKEN='token'
export FAKE_PROTECTION=bb_glob
delivery_run dl_bb_glob pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge' bitbucket.org/acme/app
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .protection.approvals)" "a Bitbucket branch restriction matching the base by glob allows the merge"
export FAKE_PROTECTION=bb_model
delivery_run dl_bb_model pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge' bitbucket.org/acme/app
assert_eq "30:2:0" "$DRIVER_RC:$(run_state .protection.approvals):$(run_state .protection.checks)" "a branching-model restriction applies to the development branch; other patterns do not"
export FAKE_PROTECTION=bb_denied
delivery_run dl_bb_denied pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge' bitbucket.org/acme/app
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "unreadable Bitbucket branch restrictions are not merged over"
unset ATLASSIAN_USER BITBUCKET_API_TOKEN
export FAKE_PROTECTION=none
# 개인 단계가 없으면 항상 PR까지다. 예전 저장소 git_policy merge·merge_policy로는 병합하지 않고 안내만 남긴다.
delivery_run dl_legacy merge ".merge_policy = $MP_BASIC" ''
assert_eq "0:done:0:pr-only:null:0" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .policy.git):$(run_state .policy.merge):$(grep -c '^gh api' "$FAKE_LOG" || true)" "without a personal level git_policy merge stops at the pull request"
[[ "$(run_state '[.history[].to] | join(",")')" != *merge* ]] || fail "without a personal level the merge node is never reached"
assert_contains "$DRIVER_OUT" "PR: https://github.com/acme/app/pull/7" "the legacy merge setting still opens the pull request"
assert_contains "$DRIVER_OUT" "notice: the repository git_policy merge is no longer used and is read as pr-only; choose how far runs go with a personal delivery level (/ai-harness:setup)" "the result tells how to choose a personal level"
assert_eq "2" "$(grep -c 'notice: the repository git_policy merge is no longer used' <<<"$DRIVER_OUT")" "the notice is shown at start and in the result"
delivery_run dl_none_pr pr-only "$DL_FACTS" ''
assert_eq "0:done:0:[]" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state ".policy.notices | tostring")" "pr-only without a personal level stops at the pull request without a notice"
[[ "$DRIVER_OUT" != *"notice:"* ]] || fail "repository facts alone raise no notice"
# 이전 버전이 시작 때 정한 병합 조건(require·min_approvals·method)으로 대기하던 실행을 resume하면 호스트 규칙으로 다시 판정한다.
state_file="$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
jq '.node = "merge" | .status = "running" | .policy.git = "merge" | .policy.delivery = null
  | .policy.merge = {require: ["remote_ci"], min_approvals: 1, method: "squash", verify: [], base: "main"}' "$state_file" >"$DRIVER_TMP/s.json" && mv "$DRIVER_TMP/s.json" "$state_file"
driver resume
assert_eq "0:done:1:squash" "$DRIVER_RC:$(run_state .status):$(gh_merges):$(run_state .merge.method)" "a legacy merge run resumed after the update follows the host rules, not its old conditions"
export FAKE_PROTECTION=classic
HM_INTERNAL_SESSION=1 delivery_run dl_unattended pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=merge'
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh ' "$FAKE_LOG" || true)" "an unattended run does not merge on a personal level either"
assert_contains "$DRIVER_OUT" "merge: not done — unattended run" "the unattended outcome says the merge was left to a person"
unset FAKE_PROTECTION
delivery_run dl_bad pr-only "$DL_FACTS" 'HM_DELIVERY_LEVEL=ship'
assert_eq "2" "$DRIVER_RC" "an unknown delivery level does not start"
assert_contains "$DRIVER_OUT" "must be pr, merge, or deploy" "the error names the levels"
delivery_run dl_old_require pr-only "$DL_FACTS" "$(printf '%s\n' 'HM_DELIVERY_LEVEL=merge' 'HM_MERGE_REQUIRE=lgtm')"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an old personal merge condition no longer stops the start"
assert_contains "$DRIVER_OUT" "HM_MERGE_REQUIRE, HM_MERGE_MIN_APPROVALS, and HM_MERGE_METHOD in ~/.ai-harness/config are no longer used" "the notice names the old settings"
rm -f "$DL_DATA/config"
pass "delivery level: personal stage, repository facts, host rules"

# review: 승인 노드가 없는 그래프다. 수리는 사람이 동의한 뒤에만 하고, 커밋하지 않는다.
review_run() { # scenario → 커밋 안 된 변경을 검토하기 시작한다
  new_driver_repo "$1"
  echo change >"$DRIVER_REPO/feature.txt"
  driver start --workflow review --runtime codex --request "review my uncommitted change"
}
review_run rv_clean
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a review without blocking findings is done"
assert_eq "scope read-only schema=yes;inspect read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "the initial review is read-only"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(run_state .diff_base)" "the review measures the change from the base the scope node named"
new_driver_repo rv_empty
driver start --workflow review --runtime codex --request "review my uncommitted change"
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a review with nothing to review stops instead of passing"
assert_contains "$DRIVER_OUT" "nothing to review" "the person is told the review target is empty"
review_run rv_blocks
assert_eq "10:waiting_approval:classify" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "blocking findings wait for the person before any repair"
assert_contains "$DRIVER_OUT" "feature.txt: missing case" "the person sees the findings to repair"
assert_contains "$DRIVER_OUT" "수리하지 않으면 여기서 끝난다" "the person can keep the review without a repair"
driver resume
assert_eq "10:1" "$DRIVER_RC:$(grep -c '^inspect ' "$FAKE_LOG")" "resume without approval keeps waiting and does not review again"
say_in_claude "승인"
driver resume
assert_eq "0:done:1:claude-transcript" "$DRIVER_RC:$(run_state .status):$(run_state .attempts):$(run_state .approval.source)" "an approved repair goes through verify and re-review to done"
assert_eq "repair;re_review" "$(tail -n 2 "$FAKE_LOG" | cut -d' ' -f1 | paste -sd ';' -)" "every repair is followed by checks and re-review"
assert_eq "fixed:1" "$(<"$DRIVER_REPO/feature.txt"):$(git -C "$DRIVER_REPO" rev-list --count HEAD)" "the repair stays uncommitted in the working tree"
assert_contains "$DRIVER_OUT" "left uncommitted" "the outcome says the repair is not committed"
review_run rv_decision
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a finding that needs a product decision goes to a person"
review_run scope_bad_base
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a review base that is not a commit stops the run"
review_run scope_nocheck
assert_eq "30:incomplete" "$DRIVER_RC:$(run_state .status)" "a repair needs a verification command"
new_driver_repo rv_auto
with_policy pr-only auto
echo change >"$DRIVER_REPO/feature.txt"
driver start --workflow review --runtime codex --request "review my uncommitted change"
assert_eq "0:done:auto-policy:0" "$DRIVER_RC:$(run_state .status):$(run_state .approval.source):$(run_state '.checkpoints | length')" "approval auto authorizes the repair, and review never commits"
new_driver_repo rv_always_blocks
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_repair_attempts = 2' "$REVIEW_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/review-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
echo change >"$DRIVER_REPO/feature.txt"
driver start --workflow review --runtime codex --request "review my uncommitted change"
say_in_claude "승인"
driver resume
assert_eq "10" "$DRIVER_RC" "a finding the person has not seen asks again before it is repaired"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "re-review stops at the graph's repair limit"
FAKE_CHECK="test -f $DRIVER_TMP/rv_verify_fail.seen || { touch $DRIVER_TMP/rv_verify_fail.seen; false; }"
review_run rv_verify_fail
say_in_claude "승인"
driver resume
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a failed check after repair goes back to repair"
FAKE_CHECK=false
new_driver_repo rv_verify_limit
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_repair_attempts = 1' "$REVIEW_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/review-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
echo change >"$DRIVER_REPO/feature.txt"
driver start --workflow review --runtime codex --request "review my uncommitted change"
say_in_claude "승인"
driver resume
assert_eq "20:user_decision:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "checks that keep failing reach the repair limit and go to a person"
unset FAKE_CHECK
review_run rv_new_finding
say_in_claude "승인"
driver resume
assert_eq "10:re_review" "$DRIVER_RC:$(run_state .node)" "a new finding outside the approved repair scope asks again"
assert_contains "$DRIVER_OUT" "auth flow must be redesigned" "the person sees the new finding before it is repaired"
assert_eq "1" "$(grep -c '^repair ' "$FAKE_LOG")" "nothing repairs the new finding before the person agrees"
say_in_claude "승인"
driver resume
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "after the second agreement the new finding is repaired and re-reviewed"
review_run rv_ui
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a review of a screen change verifies the rendered screen"
assert_contains "$(<"$FAKE_LOG")" "ui_review workspace-write schema=yes net=yes add-dir=yes" "review keeps captures in the run directory too"
assert_file "$(run_state .ui_review.evidence_dir)/default.png"
new_driver_repo rv_clean_screen
mkdir -p "$DRIVER_REPO/templates"
echo '<summary>반려하기</summary>' >"$DRIVER_REPO/templates/approve.html"
driver start --workflow review --runtime codex --request "review my uncommitted change"
assert_eq "0:done:verified" "$DRIVER_RC:$(run_state .status):$(run_state .ui_review.status)" "a changed screen file is verified even when the reviewer listed no scenario"
pass "bug-fix and review graphs run through the same runner"

# /investigate가 남긴 조사 보고를 받으면 fix-bug는 triage·reproduce를 다시 하지 않고 brief부터 시작한다. (#338)
INVESTIGATION_REPORT="$DRIVER_TMP/investigation.md"
printf '%s\n' '# Investigation: total ignores tax' 'root cause: tax is skipped when the discount is zero' \
  'evidence: npm test -- total: expected 110, got 100 (origin/develop)' >"$INVESTIGATION_REPORT"
new_driver_repo bug_investigated
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$INVESTIGATION_REPORT"
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "an investigated bug still stops at approval"
assert_eq "brief read-only schema=yes;" "$(tr '\n' ';' <"$FAKE_LOG")" "an investigation report skips triage and reproduce"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "tax is skipped when the discount is zero" "the brief reads the investigation report"
assert_contains "$(run_state '[.history[] | .from + ">" + .to] | join(",")')" "triage>brief" "the skip is a declared graph edge"
assert_eq "investigation_report_provided" "$(run_state 'first(.history[] | select(.from == "triage")) | .outcome')" "the skip names its outcome"
# 그 전이가 없는 옛 프로젝트 그래프는 평소대로 triage·reproduce를 돈다.
new_driver_repo bug_investigated_legacy
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.transitions[] | select(.when == "investigation_report_provided"))' "$BUG_FIX_GRAPH_TEMPLATE" >"$DRIVER_REPO/.ai-harness/workflows/bug-fix-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m graph
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$INVESTIGATION_REPORT"
assert_eq "10" "$DRIVER_RC" "a legacy graph still reaches approval"
assert_contains "$(<"$FAKE_LOG")" "triage read-only" "a legacy graph without the skip edge runs triage"
assert_contains "$(<"$FAKE_LOG.triage.prompt")" "tax is skipped when the discount is zero" "a legacy triage still reads the report"
new_driver_repo feature_investigated
driver start --runtime codex --request "add feature" --investigation "$INVESTIGATION_REPORT"
assert_eq "2" "$DRIVER_RC" "only bug-fix takes an investigation report"
new_driver_repo bug_investigation_missing
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$DRIVER_TMP/no-such-report.md"
assert_eq "2" "$DRIVER_RC" "a missing investigation report is a usage error"
: >"$DRIVER_TMP/empty-investigation.md"
driver start --workflow bug-fix --runtime codex --request "total ignores tax" --investigation "$DRIVER_TMP/empty-investigation.md"
assert_eq "2" "$DRIVER_RC" "an empty investigation report does not skip reproduce"
pass "fix-bug starts from the brief with an investigation report"

# fix-bug 템플릿은 standard 초기화가 만드는 프로젝트 로컬 재현·수정·검증 게이트의 원본이다.
BUG_FIX_SKILL="$ROOT/templates/fix-bug/SKILL.md"
BUG_FIX_GRAPH="$ROOT/templates/fix-bug/references/bug-fix-graph.json"
assert_file "$BUG_FIX_SKILL"
assert_not_file "$ROOT/skills/fix-bug/SKILL.md"
BUG_FIX_SKILL_CONTENT="$(<"$BUG_FIX_SKILL")"
assert_contains "$BUG_FIX_SKILL_CONTENT" "This is a project adapter" "bug-fix skill is a thin adapter"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for content in "$FEATURE_SKILL_CONTENT" "$BUG_FIX_SKILL_CONTENT"; do
  assert_contains "$content" 'report "remote CI unverified" with the PR link instead of done' "adapters never report unobserved remote CI as done"
  assert_contains "$content" "A local run of the CI-equivalent commands does not stand in for remote CI" "adapters do not let local CI-equivalent runs replace remote CI"
  assert_contains "$content" '(`limits.max_repair_attempts`), push with a normal push, and check again' "adapters repair remote CI failures in the graph loop"
done
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
assert_contains "$HARNESS_INIT_CONTENT" '원격 CI 확인 수단(실측' "project workflows record how to read remote CI for the remote_ci node"
assert_contains "$BUG_FIX_SKILL_CONTENT" ".ai-harness/workflows/fix-bug.md" "bug-fix skill references project workflow"
assert_contains "$BUG_FIX_SKILL_CONTENT" ".ai-harness/workflows/bug-fix-graph.json" "bug-fix skill references project graph"
assert_contains "$BUG_FIX_SKILL_CONTENT" "Do not edit before explicit approval" "bug-fix skill keeps approval gate"
assert_file "$BUG_FIX_GRAPH"
"$ROOT/scripts/validate-bug-fix-graph.sh" "$BUG_FIX_GRAPH" >/dev/null
assert_eq "false" "$(jq -r '.nodes.approval.write' "$BUG_FIX_GRAPH")" "bug-fix approval node is read-only"
assert_eq "true" "$(jq -r '.nodes.regression.write' "$BUG_FIX_GRAPH")" "bug-fix regression node can write"
assert_contains "$HARNESS_INIT_CONTENT" "templates/fix-bug/" "harness init uses the local bug-fix template"
assert_contains "$HARNESS_INIT_CONTENT" "회귀 테스트는 test-engineer, production 수정은 developer" "fix-bug assigns the regression test to the test role"
assert_contains "$HARNESS_INIT_CONTENT" "역할 범위 위반을 발견하면 변경을 폐기하지 않는다" "role violations preserve the diff instead of discarding it"
assert_contains "$HARNESS_INIT_CONTENT" "-s <read-only|workspace-write>" "Codex exec fallback names the sandbox for write steps"
assert_contains "$HARNESS_INIT_CONTENT" "존재하지 않는 도구를 적지 않는다" "workflow bodies must not reference nonexistent tools"
assert_contains "$HARNESS_INIT_CONTENT" "<module>/src/main/**" "persona write scopes follow the measured module layout"
assert_contains "$HARNESS_INIT_CONTENT" "rev-parse --show-toplevel)/.ai-harness/hooks/direct-edit-guard.sh" "guard hook path does not depend on CLAUDE_PROJECT_DIR"
assert_contains "$HARNESS_INIT_CONTENT" ".ai-harness/workflows/bug-fix-graph.json" "harness init copies the local bug-fix graph"
pass "bug-fix graph adapters"

# review 템플릿은 blocking finding을 수리·검증·재검토 없이 완료하지 않는다.
REVIEW_SKILL="$ROOT/templates/review/SKILL.md"
REVIEW_GRAPH="$ROOT/templates/review/references/review-graph.json"
assert_file "$REVIEW_SKILL"
assert_file "$REVIEW_GRAPH"
"$ROOT/scripts/validate-review-graph.sh" "$REVIEW_GRAPH" >/dev/null
assert_contains "$(<"$REVIEW_SKILL")" "do not report completion while a blocking finding remains" "review blocks completion"
assert_contains "$HARNESS_INIT_CONTENT" "templates/review/" "harness init uses the local review template"
pass "review graph adapters"

# investigate 템플릿은 코드를 바꾸지 않는 원인 조사 진입점이다. triage·reproduce는 fix-bug와 같은 정의를 쓴다. (#338)
INVESTIGATE_SKILL="$ROOT/templates/investigate/SKILL.md"
INVESTIGATE_GRAPH="$ROOT/templates/investigate/references/investigate-graph.json"
BUG_FIX_GRAPH="$ROOT/templates/fix-bug/references/bug-fix-graph.json"
assert_file "$INVESTIGATE_SKILL"
assert_file "$INVESTIGATE_GRAPH"
assert_file "$ROOT/templates/investigate/agents/openai.yaml"
"$ROOT/scripts/validate-investigate-graph.sh" "$INVESTIGATE_GRAPH" >/dev/null || fail "investigate graph is valid"
assert_eq "0" "$(jq '[.nodes[] | select(.write != false)] | length' "$INVESTIGATE_GRAPH")" "no investigate node writes to the repository"
for shared in triage reproduce; do
  assert_eq "$(jq -c --arg n "$shared" '.nodes[$n]' "$BUG_FIX_GRAPH")" "$(jq -c --arg n "$shared" '.nodes[$n]' "$INVESTIGATE_GRAPH")" "investigate shares the $shared node with fix-bug"
done
assert_eq "$(jq -c '[.transitions[] | select(.from == "reproduce") | .when] | sort' "$BUG_FIX_GRAPH")" \
  "$(jq -c '[.transitions[] | select(.from == "reproduce") | .when] | sort' "$INVESTIGATE_GRAPH")" "investigate leaves reproduce on the same outcomes as fix-bug"
INVALID_GRAPH="$TEST_TMP/investigate-invalid.json"
jq '.nodes.report.write = true' "$INVESTIGATE_GRAPH" >"$INVALID_GRAPH"
if "$ROOT/scripts/validate-investigate-graph.sh" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "an investigate graph with a writing node is invalid"; fi
jq '.nodes.fix = {"write": false, "output": "fix_evidence"}' "$INVESTIGATE_GRAPH" >"$INVALID_GRAPH"
if "$ROOT/scripts/validate-investigate-graph.sh" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "an investigate graph with a fix node is invalid"; fi
jq '.transitions += [{"from": "domain_docs", "to": "report"}]' "$INVESTIGATE_GRAPH" >"$INVALID_GRAPH"
if "$ROOT/scripts/validate-investigate-graph.sh" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "an investigate graph that reports without reproduce is invalid"; fi
jq 'del(.transitions[] | select(.from == "triage" and .to == "baseline"))' "$INVESTIGATE_GRAPH" >"$INVALID_GRAPH"
if "$ROOT/scripts/validate-investigate-graph.sh" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "an investigate graph that skips the remote baseline is invalid"; fi
INVESTIGATE_SKILL_CONTENT="$(<"$INVESTIGATE_SKILL")"
assert_contains "$INVESTIGATE_SKILL_CONTENT" "This is a project adapter" "investigate skill is a thin adapter"
assert_contains "$INVESTIGATE_SKILL_CONTENT" ".ai-harness/workflows/investigate.md" "investigate skill references the project workflow"
assert_contains "$INVESTIGATE_SKILL_CONTENT" ".ai-harness/workflows/investigate-graph.json" "investigate skill references the project graph"
assert_contains "$INVESTIGATE_SKILL_CONTENT" "git show origin/<base>:<path>" "investigate reads code at the remote base when the checkout is behind"
assert_contains "$INVESTIGATE_SKILL_CONTENT" "Do not edit, create, or delete any file in the repository" "investigate never edits code"
assert_contains "$INVESTIGATE_SKILL_CONTENT" "a person posts it" "external writes stay drafts"
assert_contains "$INVESTIGATE_SKILL_CONTENT" "--investigation <report>" "investigate hands a fix to fix-bug with the report"
assert_contains "$(<"$ROOT/templates/fix-bug/SKILL.md")" "--investigation <report>" "fix-bug takes an investigation report"
assert_eq "brief" "$(jq -r 'first(.transitions[] | select(.from == "triage" and .when == "investigation_report_provided") | .to)' "$BUG_FIX_GRAPH")" "fix-bug goes from triage to brief with an investigation report"
jq '.transitions += [{"from": "triage", "to": "brief", "when": "looks_obvious"}]' "$BUG_FIX_GRAPH" >"$INVALID_GRAPH"
if "$ROOT/scripts/validate-bug-fix-graph.sh" "$INVALID_GRAPH" >/dev/null 2>&1; then fail "fix-bug skips reproduce only with an investigation report"; fi
jq 'del(.transitions[] | select(.when == "investigation_report_provided"))' "$BUG_FIX_GRAPH" >"$INVALID_GRAPH"
"$ROOT/scripts/validate-bug-fix-graph.sh" "$INVALID_GRAPH" >/dev/null || fail "a bug-fix graph without the investigation edge stays valid for unsynced projects"
assert_eq "3" "$(jq '[.artifacts[] | select(.workflow == "investigate" and .level == "standard")] | length' "$ROOT/templates/managed-files.json")" "investigate ships its graph and both entry points"
assert_eq "copy" "$(jq -r '.artifacts[] | select(.path == ".ai-harness/workflows/investigate-graph.json") | .mode' "$ROOT/templates/managed-files.json")" "the investigate graph is copied as is"
assert_contains "$HARNESS_INIT_CONTENT" "templates/investigate/" "harness init uses the local investigate template"
assert_contains "$HARNESS_INIT_CONTENT" ".ai-harness/workflows/investigate-graph.json" "harness init copies the investigate graph"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
assert_contains "$HARNESS_INIT_CONTENT" '`/implement-feature`·`/fix-bug`·`/investigate`·`/review`를 프로젝트 진입점으로' "AGENTS.md lists investigate as a project entry point"
assert_contains "$(<"$ROOT/README.md")" "/investigate" "README documents investigate"
pass "investigate graph adapters"

finish_tests
