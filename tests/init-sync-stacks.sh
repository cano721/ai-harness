#!/usr/bin/env bash
# 회귀 테스트 — harness-init 동기화 — 켤 수 있는 stack 후보, 프론트 판단 Skill stack 게이트
# 실행: bash tests/run.sh init-sync-stacks
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 켤 수 있는 stack: 화면 파일(단일 HTML 포함)·디자인 규칙 문서 + 기준 화면이 init 뒤에 생겨도 sync 보고가 알린다. manifest는 바꾸지 않는다.
STACK_ROOT="$TEST_TMP/stack-candidates"
mkdir -p "$STACK_ROOT/.ai-harness" "$STACK_ROOT/scripts/board" "$STACK_ROOT/tests/fixtures/page" "$STACK_ROOT/docs/design-system"
printf '%s\n' '{"project_id":"stack-candidates","level":"standard","integrations":["codex"],"stacks":[]}' >"$STACK_ROOT/.ai-harness/harness.json"
printf '%s\n' '<!doctype html><title>board</title>' >"$STACK_ROOT/scripts/board/template.html"
printf '%s\n' '<!doctype html><title>fixture</title>' >"$STACK_ROOT/tests/fixtures/page/index.html"
printf '%s\n' '# rules' '## 메타' '- 기준 화면: <URL path or Storybook command and address>' '## 컴포넌트' >"$STACK_ROOT/docs/design-system.md"
STACK_MANIFEST_BEFORE="$(shasum -a 256 <"$STACK_ROOT/.ai-harness/harness.json")"
STACK_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$STACK_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "scripts/board/template.html" "$(jq -r '.stack_candidates[] | select(.stack=="ui") | .evidence | join(",")' <<<"$STACK_PLAN")" "a standalone HTML screen makes ui a candidate; fixture HTML does not"
assert_eq "" "$(jq -r '.stack_candidates[] | select(.stack=="design-system") | .stack' <<<"$STACK_PLAN")" "a rule document without a reference screen is not a design-system candidate"
printf '%s\n' '<!doctype html><title>reference</title>' >"$STACK_ROOT/docs/design-system/reference.html"
STACK_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$STACK_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "docs/design-system.md,docs/design-system/reference.html" "$(jq -r '.stack_candidates[] | select(.stack=="design-system") | .evidence | join(",")' <<<"$STACK_PLAN")" "rule document plus reference screen makes design-system a candidate"
assert_contains "$(jq -r '.stack_candidates[0].detail' <<<"$STACK_PLAN")" "Never enabled automatically" "candidates say they are not enabled automatically"
assert_eq "$STACK_MANIFEST_BEFORE" "$(shasum -a 256 <"$STACK_ROOT/.ai-harness/harness.json")" "plan does not change the manifest stacks"
jq '.stacks = ["ui","design-system"]' "$STACK_ROOT/.ai-harness/harness.json" >"$STACK_ROOT/hj" && mv "$STACK_ROOT/hj" "$STACK_ROOT/.ai-harness/harness.json"
assert_eq "0" "$("$ROOT/scripts/harness-sync-state.sh" plan --root "$STACK_ROOT" --catalog "$ROOT/templates/managed-files.json" | jq '.stack_candidates | length')" "enabled stacks are not proposed again"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "stack_candidates" "harness init reports stack candidates in sync"
pass "sync plan proposes ui and design-system stacks it can enable"

# 프론트 판단 Skill: templates로 옮겨 전역 노출을 끊고, stack 게이트로 프론트 프로젝트에서만 생성한다.
for fs in declarative-code frontend-testing no-unnecessary-effects frontend-fundamentals feature-sliced-design; do
  assert_file "$ROOT/templates/$fs/SKILL.md"
  assert_not_file "$ROOT/skills/$fs/SKILL.md"
done
assert_file "$ROOT/templates/frontend-fundamentals/references/readability.md"
assert_file "$ROOT/templates/feature-sliced-design/references/layer-structure.md"
# 상류 사본은 MIT 저작권 문구를 사본 안에 보존한다 (MIT 준수).
assert_file "$ROOT/THIRD-PARTY-LICENSES.md"
assert_contains "$(<"$ROOT/templates/no-unnecessary-effects/SKILL.md")" "Copyright (c) 2026 Dan Neciu" "nue copy keeps upstream copyright notice"
assert_contains "$(<"$ROOT/templates/feature-sliced-design/SKILL.md")" "MIT" "fsd copy names its license"
# 팀 맞춤본에서 역반영한 일반 규칙: mock되지 않은 HTTP는 실패로, 정리 훅은 렌더 정리 뒤에, 시각 회귀는 CI를 막는지 확인.
FT_CONTENT="$(<"$ROOT/templates/frontend-testing/SKILL.md")"
assert_contains "$FT_CONTENT" "HTTP는 mock한 것만 나간다" "frontend-testing fails unmocked HTTP"
assert_contains "$FT_CONTENT" "화면 정리(\`cleanup\`) 뒤에" "frontend-testing orders cleanup hooks after render cleanup"
assert_contains "$FT_CONTENT" "sequence.hooks: \"stack\"" "frontend-testing names the Vitest default hook order as a precondition"
assert_contains "$FT_CONTENT" "CI를 막는 설정인지" "frontend-testing checks the visual regression gate"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "다음 담당" "role personas end reports with a handoff line"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "두 번째 왕복에서 끊고" "handoff ping-pong is cut and raised to the user"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "라우터가 정한 넘김 형식을 우선" "an adopted router keeps its own handoff format"

# frontend 스택이면 프론트 Skill이 계획에 오르고, feature-sliced-design은 fsd opt-in일 때만 오른다.
FE_ROOT="$TEST_TMP/frontend-project"
mkdir -p "$FE_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"frontend-project","level":"standard","integrations":["codex"],"stacks":["frontend"],"harness_version":"0.18.0"}' >"$FE_ROOT/.ai-harness/harness.json"
FE_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$FE_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "add" "$(printf '%s' "$FE_PLAN" | jq -r '.items[] | select(.path==".agents/skills/frontend-fundamentals/SKILL.md") | .action')" "frontend stack selects frontend skill"
assert_eq "add" "$(printf '%s' "$FE_PLAN" | jq -r '.items[] | select(.path==".agents/skills/frontend-fundamentals/references/readability.md") | .action')" "frontend skill references are managed too"
assert_eq "0" "$(printf '%s' "$FE_PLAN" | jq -r '[.items[] | select(.path==".agents/skills/feature-sliced-design/SKILL.md")] | length')" "fsd skill excluded without fsd stack"
assert_eq "0" "$(printf '%s' "$FE_PLAN" | jq -r '[.items[] | select(.path | startswith(".claude/skills/"))] | length')" "claude frontend skills excluded for codex-only integration"

# fsd opt-in이면 FSD Skill과 references까지 계획에 오른다 (claude 통합).
FSD_ROOT="$TEST_TMP/fsd-project"
mkdir -p "$FSD_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"fsd-project","level":"standard","integrations":["claude"],"stacks":["frontend","fsd"],"harness_version":"0.18.0"}' >"$FSD_ROOT/.ai-harness/harness.json"
FSD_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$FSD_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "add" "$(printf '%s' "$FSD_PLAN" | jq -r '.items[] | select(.path==".claude/skills/feature-sliced-design/SKILL.md") | .action')" "fsd stack selects fsd skill for claude"
assert_eq "add" "$(printf '%s' "$FSD_PLAN" | jq -r '.items[] | select(.path==".claude/skills/feature-sliced-design/references/layer-structure.md") | .action')" "fsd references are managed too"
assert_eq "0" "$(printf '%s' "$FSD_PLAN" | jq -r '[.items[] | select(.path | startswith(".agents/skills/"))] | length')" "codex frontend skills excluded for claude-only integration"

assert_contains "$HARNESS_INIT_CONTENT" "stack" "harness init documents the stack gate"
assert_contains "$HARNESS_INIT_CONTENT" ".ai-harness/docs/frontend.md" "harness init generates the frontend context doc"
pass "frontend judgment skills stack gating"

finish_tests
