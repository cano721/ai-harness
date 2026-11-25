#!/usr/bin/env bash
# 회귀 테스트 — design-system stack: 스토리북 없이 규칙 문서 + 서버 렌더링 기준 화면만으로 켜지는지(harness-sync-state plan)
# 실행: bash tests/run.sh design-stack
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# design-system stack은 규칙 문서 + 기준 화면(스토리북 또는 서버 렌더링 예시 페이지)이면 켤 수 있다.
# 프론트 팀 구성이 없으면 design-audit만 생기고, fe-designer는 frontend-team과 design-system을 둘 다 요구한다.
assert_contains "$HARNESS_INIT_CONTENT" "스토리북이든 서버 렌더링 앱의 예시 페이지" "design-system stack accepts a server-rendered reference screen"
if grep -q "스토리북을 갖춘 UI 패키지가 둘 다" "$ROOT/skills/harness-init/SKILL.md"; then fail "design-system stack still requires Storybook"; fi
assert_contains "$HARNESS_INIT_CONTENT" "\`*/skills/design-audit\`가 있으면 \`design-system\`도" "sync infers the design-system stack from design-audit"
SSR_ROOT="$TEST_TMP/ssr-design-project"
mkdir -p "$SSR_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"ssr-design-project","level":"standard","integrations":["claude","codex"],"stacks":["ui","design-system"],"harness_version":"0.50.0"}' >"$SSR_ROOT/.ai-harness/harness.json"
SSR_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$SSR_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "add" "$(printf '%s' "$SSR_PLAN" | jq -r '.items[] | select(.path==".claude/skills/design-audit/SKILL.md") | .action')" "design-system stack without frontend-team selects design-audit"
assert_eq "add" "$(printf '%s' "$SSR_PLAN" | jq -r '.items[] | select(.path==".agents/skills/design-audit/SKILL.md") | .action')" "design-system stack without frontend-team selects the codex design-audit"
assert_eq "0" "$(printf '%s' "$SSR_PLAN" | jq -r '[.items[] | select(.path | test("fe-designer|frontend-team"))] | length')" "fe-designer needs the frontend-team stack too"
mkdir -p "$SSR_ROOT/.claude/agents"
printf '%s\n' 'fe-designer' >"$SSR_ROOT/.claude/agents/fe-designer.md"
"$ROOT/scripts/harness-sync-state.sh" record --root "$SSR_ROOT" --version 0.50.0 --file .claude/agents/fe-designer.md >/dev/null
assert_eq "stack_removed" "$("$ROOT/scripts/harness-sync-state.sh" plan --root "$SSR_ROOT" --catalog "$ROOT/templates/managed-files.json" | jq -r '.orphaned[] | select(.path==".claude/agents/fe-designer.md") | .reason')" "fe-designer without frontend-team is an orphan"
pass "design-system stack accepts a non-Storybook reference screen"

finish_tests
