#!/usr/bin/env bash
# 회귀 테스트 — SessionStart 안내·워크플로 진입점 계약(feature·bug-fix·review·investigate 어댑터) (design-polish 러너는 workflow-polish*)
# 실행: bash tests/run.sh workflow
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
make_project_repo


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

# merge·deploy 개인 단계를 정한 작업은 원본 어댑터가 러너로 보내며, 불가하면 첫 줄에서 누락 사실을 설명한다. (#478)
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for adapter in implement-feature fix-bug; do
  ADAPTER_CONTENT="$(<"$ROOT/templates/$adapter/SKILL.md")"
  assert_contains "$ADAPTER_CONTENT" 'HM_DELIVERY_LEVEL_REPOS' "$adapter adapter resolves repository-specific delivery levels"
  assert_contains "$ADAPTER_CONTENT" 'must use the runner' "$adapter adapter requires the runner for merge and deploy"
  assert_contains "$ADAPTER_CONTENT" 'first line' "$adapter adapter reports an unapplied delivery level first"
  assert_contains "$ADAPTER_CONTENT" 'delivery level, its setting source, and why it could not be applied' "$adapter adapter names every required first-line report field"
  assert_contains "$ADAPTER_CONTENT" 'delegated agent' "$adapter adapter preserves the delivery level when delegating"
  assert_contains "$ADAPTER_CONTENT" 'takes precedence over “PR only, do not merge”' "$adapter adapter gives delivery level precedence over delegation limits"
done
pass "delivery levels require the runner or report why they were not applied"

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
  assert_eq "done repair user_decision merge sync_base" "$(jq -r '[.transitions[] | select(.from == "remote_ci") | .to] | join(" ")' "$graph")" "$(basename "$graph") routes remote CI pass, failure, unverified, and merge under git_policy merge"
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
assert_contains "$HARNESS_INIT_CONTENT" '`/implement-feature`·`/fix-bug`·`/investigate`·`/design-polish`·`/review`·`/release`를 프로젝트 진입점으로' "AGENTS.md lists investigate and design-polish as project entry points"
assert_contains "$(<"$ROOT/README.md")" "/investigate" "README documents investigate"
pass "investigate graph adapters"

# release 템플릿은 태그 방식 릴리스 진입점이다. 그래프·두 진입점이 standard에 항상 설치되고, 러너가 release_policy로 시작 여부를 정한다. (#493)
RELEASE_SKILL_CONTENT="$(<"$ROOT/templates/release/SKILL.md")"
assert_file "$ROOT/templates/release/agents/openai.yaml"
assert_eq "3" "$(jq '[.artifacts[] | select(.workflow == "release" and .level == "standard")] | length' "$ROOT/templates/managed-files.json")" "release ships its graph and both entry points"
assert_eq "copy" "$(jq -r '.artifacts[] | select(.path == ".ai-harness/workflows/release-graph.json") | .mode' "$ROOT/templates/managed-files.json")" "the release graph is copied as is"
assert_contains "$RELEASE_SKILL_CONTENT" "This is a project adapter" "release skill is a thin adapter"
assert_contains "$RELEASE_SKILL_CONTENT" ".ai-harness/workflows/release.md" "release skill references the project workflow"
assert_contains "$RELEASE_SKILL_CONTENT" "start --workflow release --version <x.y.z>" "release skill starts the runner"
assert_contains "$RELEASE_SKILL_CONTENT" "release_policy" "release skill names the manifest facts"
assert_contains "$RELEASE_SKILL_CONTENT" "merge commit only" "release skill keeps merge commits only"
assert_contains "$HARNESS_INIT_CONTENT" "templates/release/" "harness init uses the local release template"
assert_contains "$(<"$ROOT/README.md")" "--workflow release" "README documents the release runner"
for f in "$ROOT/.ai-harness/workflows/release-graph.json:$ROOT/templates/release/references/release-graph.json" "$ROOT/.ai-harness/workflows/workflow-driver.sh:$ROOT/templates/workflow-driver/workflow-driver.sh"; do
  cmp -s "${f%%:*}" "${f#*:}" || fail "${f%%:*} is the template copy"
done
pass "release graph adapters"

# 개인 기본 런타임(#488): 어댑터가 습관적으로 --runtime을 넘기면 개인 설정이 무력해진다. 다섯 어댑터와 렌더 생성물이 우선순위를 안내한다.
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for wf in implement-feature fix-bug review design-polish investigate release; do
  for f in "$ROOT/templates/$wf/SKILL.md" "$ROOT/.agents/skills/$wf/SKILL.md" "$ROOT/.claude/commands/$wf.md"; do
    assert_contains "$(<"$f")" 'then `HM_RUNTIME_REPOS` (matching repository), then `HM_RUNTIME` in `~/.ai-harness/config`' "$f explains the runtime precedence"
    assert_contains "$(<"$f")" 'pass `--runtime` only when the user asks for a specific CLI' "$f keeps --runtime for explicit requests"
  done
done
pass "workflow adapters explain the personal runtime precedence"


# 완료 조건 대응표(#501): 그래프는 대응 없는 Brief의 사람 인계와 deliver → brief 복귀를 선언하고, 문서는 게이트와 revise를 안내한다.
BUG_FIX_GRAPH="$ROOT/templates/fix-bug/references/bug-fix-graph.json"
for graph in "$FEATURE_GRAPH" "$BUG_FIX_GRAPH"; do
  assert_eq "2" "$(jq -r '.limits.max_brief_rewrites' "$graph")" "$(basename "$graph") limits brief rewrites"
  assert_contains "$(jq -r '.invariants[0]' "$graph")" "acceptance_map" "$(basename "$graph") states the coverage gate in its approval invariant"
done
assert_eq "user_decision" "$(jq -r 'first(.transitions[] | select(.from == "approval" and .when == "brief_coverage_incomplete") | .to)' "$BUG_FIX_GRAPH")" "bug-fix hands an uncovered brief to a person"
COVERAGE_GRAPH="$TEST_TMP/coverage-graph.json"
jq 'del(.transitions[] | select(.when == "brief_revised"))' "$FEATURE_GRAPH" >"$COVERAGE_GRAPH"
if "$ROOT/scripts/validate-feature-graph.sh" "$COVERAGE_GRAPH" >/dev/null 2>&1; then fail "a feature graph without deliver -> brief is invalid"; fi
jq 'del(.transitions[] | select(.when == "brief_coverage_incomplete"))' "$FEATURE_GRAPH" >"$COVERAGE_GRAPH"
if "$ROOT/scripts/validate-feature-graph.sh" "$COVERAGE_GRAPH" >/dev/null 2>&1; then fail "a feature graph without the coverage hand-off is invalid"; fi
jq 'del(.transitions[] | select(.when == "brief_coverage_incomplete"))' "$BUG_FIX_GRAPH" >"$COVERAGE_GRAPH"
if "$ROOT/scripts/validate-bug-fix-graph.sh" "$COVERAGE_GRAPH" >/dev/null 2>&1; then fail "a bug-fix graph without the coverage hand-off is invalid"; fi
for f in "$ROOT/.ai-harness/workflows/feature-delivery-graph.json:$FEATURE_GRAPH" "$ROOT/.ai-harness/workflows/bug-fix-graph.json:$BUG_FIX_GRAPH"; do
  cmp -s "${f%%:*}" "${f#*:}" || fail "${f%%:*} is the template copy"
done
for f in "$ROOT/README.md" "$ROOT/skills/harness-init/SKILL.md" "$ROOT/templates/implement-feature/SKILL.md" "$ROOT/templates/fix-bug/SKILL.md"; do
  assert_contains "$(<"$f")" "acceptance_map" "$(basename "$(dirname "$f")")/$(basename "$f") documents the completion-condition map"
  assert_contains "$(<"$f")" "brief_coverage_incomplete" "$(basename "$(dirname "$f")")/$(basename "$f") documents the coverage gate"
done
for f in "$ROOT/README.md" "$ROOT/skills/harness-init/SKILL.md" "$ROOT/templates/implement-feature/SKILL.md"; do
  assert_contains "$(<"$f")" "brief_revised" "$(basename "$(dirname "$f")")/$(basename "$f") documents revise during deliver"
done
pass "completion-condition map: graphs, validators, and docs"

# base 충돌 동기화(#508): feature·bug-fix 그래프는 merge가 충돌로만 막히면 쓰기 노드 sync_base로 가고, sync_base는 remote_ci나 사람에게만 간다.
for pair in "validate-feature-graph.sh:$FEATURE_GRAPH" "validate-bug-fix-graph.sh:$BUG_FIX_GRAPH"; do
  validator="$ROOT/scripts/${pair%%:*}"
  graph="${pair#*:}"
  name="$(basename "$graph")"
  "$validator" "$graph" >/dev/null || fail "$name with sync_base is valid"
  assert_eq "true:true:3" "$(jq -r '"\(.nodes.sync_base.write):\(.nodes.sync_base.network):\(.limits.max_base_syncs)"' "$graph")" "$name: sync_base writes, needs the network, and is limited to 3"
  assert_eq "sync_base:base_conflict" "$(jq -r 'first(.transitions[] | select(.from == "merge" and .to == "sync_base")) | "\(.to):\(.when)"' "$graph")" "$name: a base conflict goes to sync_base"
  assert_eq "base_merged_outside" "$(jq -r 'first(.transitions[] | select(.from == "remote_ci" and .to == "sync_base")) | .when' "$graph")" "$name: an outside base merge goes to sync_base"
  assert_eq "remote_ci:base_synced,user_decision:base_sync_failed_or_limit_reached" "$(jq -r '[.transitions[] | select(.from == "sync_base") | "\(.to):\(.when)"] | sort | join(",")' "$graph")" "$name: sync_base goes back to remote CI or to a person"
  assert_contains "$(jq -r '.invariants | join(" ")' "$graph")" "sync_base" "$name states the sync_base invariant"
  jq '.nodes.sync_base.write = false' "$graph" >"$TEST_TMP/sync-graph.json"
  if "$validator" "$TEST_TMP/sync-graph.json" >/dev/null 2>&1; then fail "$name: a read-only sync_base is invalid"; fi
  jq '.transitions += [{"from": "sync_base", "to": "done", "when": "base_synced_done"}]' "$graph" >"$TEST_TMP/sync-graph.json"
  if "$validator" "$TEST_TMP/sync-graph.json" >/dev/null 2>&1; then fail "$name: sync_base -> done is invalid"; fi
  jq '.transitions += [{"from": "review", "to": "sync_base", "when": "x"}]' "$graph" >"$TEST_TMP/sync-graph.json"
  if "$validator" "$TEST_TMP/sync-graph.json" >/dev/null 2>&1; then fail "$name: sync_base is reached only from merge and remote_ci"; fi
  jq 'del(.nodes.sync_base) | .transitions |= map(select(.from != "sync_base" and .to != "sync_base")) | del(.limits.max_base_syncs)' "$graph" >"$TEST_TMP/sync-graph.json"
  "$validator" "$TEST_TMP/sync-graph.json" >/dev/null || fail "$name: a graph synced before sync_base stays valid"
done
README_CONTENT="$(<"$ROOT/README.md")"
assert_contains "$README_CONTENT" "merge --> sync_base" "README graph shows merge -> sync_base"
assert_contains "$README_CONTENT" "sync_base --> remote_ci" "README graph shows sync_base -> remote_ci"
assert_contains "$README_CONTENT" "sync_base --> user_decision" "README graph shows sync_base -> user_decision"
[[ "$(grep -E 'merge -->.*user_decision' "$ROOT/README.md")" != *충돌* ]] || fail "README graph no longer sends a conflict from merge straight to a person"
for f in "$ROOT/README.md" "$ROOT/skills/harness-init/SKILL.md" "$ROOT/templates/implement-feature/SKILL.md" "$ROOT/templates/fix-bug/SKILL.md" \
  "$ROOT/.ai-harness/workflows/implement-feature.md" "$ROOT/.ai-harness/workflows/fix-bug.md"; do
  assert_contains "$(<"$f")" "sync_base" "$(basename "$(dirname "$f")")/$(basename "$f") documents sync_base"
done
assert_contains "$(<"$ROOT/templates/workflow-driver/workflow-driver.sh")" "max_base_syncs" "the runner reads the base sync limit from the graph"
pass "base sync: graphs, validators, and docs"

# #543: base 대비 '건드리지 않았다' 검사는 merge-base 기준(origin/<base>...HEAD)이어야 런 도중 develop 릴리스로 거짓 실패하지 않는다.
MB_DOC="$(<"$ROOT/.ai-harness/workflows/implement-feature.md")"
# shellcheck disable=SC2016  # 백틱은 문서 속 명령을 찾는 literal이다
MB_CMD="$(printf '%s\n' "$MB_DOC" | grep -o '`git diff --quiet origin/develop\.\.\.HEAD -- [^`]*`' | head -n 1 || true)"
MB_CMD="${MB_CMD#\`}"
MB_CMD="${MB_CMD%\`}"
[[ -n "$MB_CMD" ]] || fail "implement-feature.md states the merge-base version check"
MB_DIR="$TEST_TMP/mb-$$"
MB_FILES=".claude-plugin/plugin.json .codex-plugin/plugin.json release.json"
mb_write_version() {
  local dir="$1" v="$2" f
  mkdir -p "$dir/.claude-plugin" "$dir/.codex-plugin"
  for f in $MB_FILES; do printf '{"version":"%s"}\n' "$v" >"$dir/$f"; done
}
mb_git_setup() {
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  git -C "$1" config commit.gpgsign false
}
mkdir -p "$MB_DIR"
git init --bare -q "$MB_DIR/remote.git"
git init -q "$MB_DIR/repo"
mb_git_setup "$MB_DIR/repo"
git -C "$MB_DIR/repo" checkout -q -b develop
mb_write_version "$MB_DIR/repo" 0.91.0
git -C "$MB_DIR/repo" add -A
git -C "$MB_DIR/repo" commit -q -m "release 0.91.0"
git -C "$MB_DIR/repo" remote add origin "$MB_DIR/remote.git"
git -C "$MB_DIR/repo" push -q origin develop
git -C "$MB_DIR/repo" checkout -q -b fix/work
printf 'unrelated\n' >"$MB_DIR/repo/unrelated.txt"
git -C "$MB_DIR/repo" add -A
git -C "$MB_DIR/repo" commit -q -m "unrelated change"
git clone -q "$MB_DIR/remote.git" "$MB_DIR/other"
mb_git_setup "$MB_DIR/other"
git -C "$MB_DIR/other" checkout -q develop
mb_write_version "$MB_DIR/other" 0.92.0
git -C "$MB_DIR/other" add -A
git -C "$MB_DIR/other" commit -q -m "release 0.92.0"
git -C "$MB_DIR/other" push -q origin develop
git -C "$MB_DIR/repo" fetch -q origin
# ① 작업 브랜치는 버전 파일을 건드리지 않았고 develop만 앞서 갔다 → 통과해야 한다.
# shellcheck disable=SC2086  # 파일 목록을 단어로 나눈다
if (cd "$MB_DIR/repo" && git diff --quiet origin/develop -- $MB_FILES); then
  fail "base tip comparison sees the moved base as a difference"
fi
(cd "$MB_DIR/repo" && bash -c "$MB_CMD") || fail "merge-base version check passes when only the base moved"
# ② 작업 브랜치가 버전 파일을 직접 고쳤다 → 실패해야 한다.
printf '{"version":"0.93.0"}\n' >"$MB_DIR/repo/release.json"
git -C "$MB_DIR/repo" add -A
git -C "$MB_DIR/repo" commit -q -m "bump version on the work branch"
if (cd "$MB_DIR/repo" && bash -c "$MB_CMD"); then
  fail "merge-base version check fails when the work branch touched a version file"
fi
MB_RULE_LINE="$(grep -m 1 '^MERGE_BASE_RULE=' "$ROOT/templates/workflow-driver/workflow-driver.sh" || true)"
[[ -n "$MB_RULE_LINE" ]] || fail "workflow-driver.sh defines MERGE_BASE_RULE"
assert_contains "$MB_RULE_LINE" 'origin/<base>...HEAD' "MERGE_BASE_RULE names the three-dot diff"
assert_contains "$MB_RULE_LINE" "merge base" "MERGE_BASE_RULE explains the merge base"
MB_BRIEF_BODY="$(sed -n '/^brief_prompt() {/,/^}/p' "$ROOT/templates/workflow-driver/workflow-driver.sh")"
# shellcheck disable=SC2016  # literal $MERGE_BASE_RULE를 센다
MB_BRIEF_USES="$(printf '%s\n' "$MB_BRIEF_BODY" | grep -o '\$MERGE_BASE_RULE' | wc -l | tr -d ' ' || true)"
assert_eq "2" "$MB_BRIEF_USES" "both brief roles append MERGE_BASE_RULE"
pass "merge-base version check: document command and brief rule (#543)"

# 렌더 대상(#678): 화면 검증 문구는 "real browser"가 아니라 ui.md가 화면에 선언한 렌더 대상이다. 이 저장소 ui.md는 화면마다 엔진을 적는다.
RT_UI="$(<"$ROOT/.ai-harness/docs/ui.md")"
assert_contains "$(grep '^| Harness Board' <<<"$RT_UI")" "webkit" "Harness Board renders in webkit like its window app"
assert_contains "$(grep '^| 하네스 효과 리포트' <<<"$RT_UI")" "chromium" "the impact report renders in chromium"
assert_contains "$RT_UI" "## 렌더 대상" "ui.md has a render target section"
RT_SECTION="$(sed -n '/^## 렌더 대상/,/^## /p' "$ROOT/.ai-harness/docs/ui.md")"
assert_contains "$RT_SECTION" "launchBrowser({ engine" "the section says how to pick the engine"
assert_contains "$RT_SECTION" "사용자 승인 뒤에만" "a missing engine is installed only after the user approves"
assert_contains "$RT_SECTION" "다른 엔진으로 대신" "the section forbids rendering with another engine"
for f in "$ROOT"/templates/{implement-feature,fix-bug,review,ui-review,design-polish}/references/*-graph.json \
  "$ROOT"/templates/{design-polish,fix-bug,implement-feature,review}/SKILL.md "$ROOT/templates/workflow-driver/workflow-driver.sh"; do
  if grep -nE 'real browser|in a browser \(a simulator' "$f"; then fail "$f still says real browser instead of the render target"; fi
done
for f in "$ROOT"/templates/{implement-feature,fix-bug,review,ui-review,design-polish}/references/*-graph.json; do
  assert_contains "$(jq -r '.invariants // .rules | if type == "array" then join("\n") else tostring end' "$f")" "render target" "$f invariant names the render target"
done
RT_DRIVER="$(<"$ROOT/templates/workflow-driver/workflow-driver.sh")"
assert_contains "$RT_DRIVER" "the render target .ai-harness/docs/ui.md declares" "the driver prompts point at the ui.md render target"
assert_contains "$RT_DRIVER" "use chromium and say so" "without a declaration the prompts fall back to chromium and record it"
cmp -s "$ROOT/.ai-harness/workflows/workflow-driver.sh" "$ROOT/templates/workflow-driver/workflow-driver.sh" || fail "the generated runner is the template copy"
pass "render target wording in graphs, skills, and the runner (#678)"

finish_tests
