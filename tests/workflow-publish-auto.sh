#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 자동 승인의 결정 사항·needs_human·auto 엣지 없는 그래프
# 실행: bash tests/run.sh workflow-publish-auto
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

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
pass "auto approval records decisions and stops for what only a person can decide"

finish_tests
