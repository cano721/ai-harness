#!/usr/bin/env bash
# 회귀 테스트 — harness-init 동기화 — 고아 생성물, 기존 에이전트 자산 인벤토리, 역할 매핑 계약
# 실행: bash tests/run.sh init-sync-orphans
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 고아 생성물: 설정에서 integration·stack을 빼거나 역할을 기존 에이전트에 넘기면 남은 관리 생성물이 제거 후보가 된다.
ORPHAN_ROOT="$TEST_TMP/orphan-project"
mkdir -p "$ORPHAN_ROOT/.ai-harness" "$ORPHAN_ROOT/.claude/commands" "$ORPHAN_ROOT/.claude/agents" "$ORPHAN_ROOT/.agents/skills/frontend-testing"
printf '%s\n' '{"project_id":"orphan-project","level":"standard","integrations":["codex","claude"],"stacks":["frontend"]}' >"$ORPHAN_ROOT/.ai-harness/harness.json"
printf '%s\n' 'claude review' >"$ORPHAN_ROOT/.claude/commands/review.md"
printf '%s\n' 'frontend testing' >"$ORPHAN_ROOT/.agents/skills/frontend-testing/SKILL.md"
printf '%s\n' '---' 'name: developer' 'model: sonnet' '---' >"$ORPHAN_ROOT/.claude/agents/developer.md"
printf '%s\n' '---' 'name: reviewer' 'model: opus' '---' >"$ORPHAN_ROOT/.claude/agents/reviewer.md"
"$ROOT/scripts/harness-sync-state.sh" record --root "$ORPHAN_ROOT" --version 0.37.0 \
  --file .claude/commands/review.md --file .agents/skills/frontend-testing/SKILL.md \
  --file .claude/agents/developer.md --file .claude/agents/reviewer.md
ORPHAN_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$ORPHAN_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "0" "$(printf '%s' "$ORPHAN_PLAN" | jq -r '.orphaned | length')" "artifacts inside the current config are not orphaned"
jq '.stacks = [] | .roles = {developer: {source: "existing", integrations: ["claude"], agents: ["sunwoong"]}}' \
  "$ORPHAN_ROOT/.ai-harness/harness.json" >"$ORPHAN_ROOT/manifest.tmp" && mv "$ORPHAN_ROOT/manifest.tmp" "$ORPHAN_ROOT/.ai-harness/harness.json"
ORPHAN_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$ORPHAN_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "stack_removed" "$(printf '%s' "$ORPHAN_PLAN" | jq -r '.orphaned[] | select(.path==".agents/skills/frontend-testing/SKILL.md") | .reason')" "dropped stack orphans its artifacts"
assert_eq "role_adopted" "$(printf '%s' "$ORPHAN_PLAN" | jq -r '.orphaned[] | select(.path==".claude/agents/developer.md") | .reason')" "role handed to an existing agent orphans the generated persona"
jq '.roles.developer |= del(.integrations)' "$ORPHAN_ROOT/.ai-harness/harness.json" >"$ORPHAN_ROOT/manifest.tmp" \
  && mv "$ORPHAN_ROOT/manifest.tmp" "$ORPHAN_ROOT/.ai-harness/harness.json"
assert_eq "role_adopted" "$("$ROOT/scripts/harness-sync-state.sh" plan --root "$ORPHAN_ROOT" --catalog "$ROOT/templates/managed-files.json" | jq -r '.orphaned[] | select(.path==".claude/agents/developer.md") | .reason')" "role without integrations defaults to claude like the contract check"
assert_eq "0" "$(printf '%s' "$ORPHAN_PLAN" | jq -r '[.orphaned[] | select(.path==".claude/agents/reviewer.md")] | length')" "unmapped role keeps its generated persona"
assert_eq "true" "$(printf '%s' "$ORPHAN_PLAN" | jq -r '.orphaned[] | select(.path==".claude/agents/developer.md") | .present')" "orphan reports whether the file is still on disk"
jq '.integrations = ["codex"]' "$ORPHAN_ROOT/.ai-harness/harness.json" >"$ORPHAN_ROOT/manifest.tmp" \
  && mv "$ORPHAN_ROOT/manifest.tmp" "$ORPHAN_ROOT/.ai-harness/harness.json"
ORPHAN_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$ORPHAN_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "integration_removed" "$(printf '%s' "$ORPHAN_PLAN" | jq -r '.orphaned[] | select(.path==".claude/commands/review.md") | .reason')" "dropped integration orphans its artifacts"
assert_eq "integration_removed" "$(printf '%s' "$ORPHAN_PLAN" | jq -r '.orphaned[] | select(.path==".claude/agents/reviewer.md") | .reason')" "dropped integration orphans its role personas"
assert_eq "0" "$(printf '%s' "$ORPHAN_PLAN" | jq -r '[.items[] | select(.path==".claude/commands/review.md")] | length')" "orphaned artifact is not a plan item"
pass "project harness sync orphans"

# 기존 에이전트 자산 인벤토리: init이 덮어쓰거나 옆에 중복을 세우지 않도록 사실만 모은다.
ASSET_ROOT="$TEST_TMP/asset-project"
mkdir -p "$ASSET_ROOT/.claude/agents" "$ASSET_ROOT/.claude/skills/orchestrator" "$ASSET_ROOT/.claude/skills/frontend-testing" "$ASSET_ROOT/.claude/commands"
git -C "$ASSET_ROOT" init -q
printf '%s\n' '.claude/' >"$ASSET_ROOT/.gitignore"
# shellcheck disable=SC2016  # 백틱은 마크다운 리터럴, 확장 의도 아님
printf '%s\n' '# Team rules' 'Route edits through `orchestrator`.' 'Dev server runs on `localhost:8080`.' >"$ASSET_ROOT/.claude/CLAUDE.md"
printf '%s\n' '# Conventions' >"$ASSET_ROOT/TEAM_CONVENTIONS.md"
printf '%s\n' '---' 'name: sunwoong' 'description: >' '  Builds screens fast.' 'model: opus' 'skills:' '  - frontend-testing' '---' 'body' >"$ASSET_ROOT/.claude/agents/sunwoong.md"
# shellcheck disable=SC2016  # 백틱은 마크다운 리터럴, 확장 의도 아님
printf '%s\n' '---' 'name: orchestrator' 'description: Routes work to sunwoong.' '---' '| review | `sunwoong` | own code goes to `oh-my-claudecode:code-reviewer` |' >"$ASSET_ROOT/.claude/skills/orchestrator/SKILL.md"
printf '%s\n' '---' 'name: frontend-testing' '---' >"$ASSET_ROOT/.claude/skills/frontend-testing/SKILL.md"
printf '%s\n' '# deploy' >"$ASSET_ROOT/.claude/commands/deploy.md"
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"fmt"}]}]},"permissions":{"allow":["Bash(ls)"]}}' >"$ASSET_ROOT/.claude/settings.json"
ASSETS="$("$ROOT/scripts/existing-assets.sh" scan --root "$ASSET_ROOT" --templates "$ROOT/templates")"
assert_eq ".claude/CLAUDE.md" "$(printf '%s' "$ASSETS" | jq -r '.instructions[] | select(.kind=="claude_md") | .path')" "nested CLAUDE.md is found"
assert_eq "../AGENTS.md" "$(printf '%s' "$ASSETS" | jq -r '.instructions[] | select(.kind=="claude_md") | .agents_import')" "import path is relative to the CLAUDE.md location"
assert_eq "false" "$(printf '%s' "$ASSETS" | jq -r '.instructions[] | select(.kind=="claude_md") | .imports_agents')" "missing AGENTS.md import is reported"
assert_eq "TEAM_CONVENTIONS.md" "$(printf '%s' "$ASSETS" | jq -r '.instructions[] | select(.kind=="convention_doc") | .path')" "root convention docs are listed"
assert_eq "opus" "$(printf '%s' "$ASSETS" | jq -r '.agents[] | select(.name=="sunwoong") | .model')" "agent model is read from frontmatter"
assert_eq "Builds screens fast." "$(printf '%s' "$ASSETS" | jq -r '.agents[] | select(.name=="sunwoong") | .description')" "folded description is read"
assert_eq "frontend-testing" "$(printf '%s' "$ASSETS" | jq -r '.agents[] | select(.name=="sunwoong") | .skills[0]')" "agent skill list is read"
assert_eq "true" "$(printf '%s' "$ASSETS" | jq -r '.skills[] | select(.name=="frontend-testing") | .template_collision')" "skill sharing a template name is flagged"
assert_eq "false" "$(printf '%s' "$ASSETS" | jq -r '.skills[] | select(.name=="orchestrator") | .template_collision')" "team-only skill is not a collision"
assert_eq "true" "$(printf '%s' "$ASSETS" | jq -r '.skills[] | select(.name=="orchestrator") | .routes_agents')" "skill naming local agents is a router candidate"
assert_eq "oh-my-claudecode:code-reviewer" "$(printf '%s' "$ASSETS" | jq -r '.external_refs[0].ref')" "plugin-namespaced agent reference is reported"
assert_eq ".claude/skills/orchestrator/SKILL.md" "$(printf '%s' "$ASSETS" | jq -r '.external_refs[0].file')" "external reference carries its file"
assert_eq "1" "$(printf '%s' "$ASSETS" | jq -r '.external_refs | length')" "host:port tokens are not plugin references"
assert_eq "deploy" "$(printf '%s' "$ASSETS" | jq -r '.commands[0]')" "existing commands are listed"
assert_eq "PostToolUse" "$(printf '%s' "$ASSETS" | jq -r '.settings.hook_events[0]')" "existing settings hooks are listed"
assert_eq "true" "$(printf '%s' "$ASSETS" | jq -r '.claude_dir_ignored')" "gitignored .claude is reported"
EMPTY_ASSETS="$("$ROOT/scripts/existing-assets.sh" scan --root "$TEST_TMP/orphan-project/.ai-harness" --templates "$ROOT/templates")"
assert_eq "0" "$(printf '%s' "$EMPTY_ASSETS" | jq -r '.agents | length')" "project without assets yields empty lists"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "existing-assets.sh scan" "harness init inventories existing assets"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "role_adopted" "harness init removes personas replaced by existing agents"
pass "existing agent asset inventory"

# 역할 매핑 계약: roles가 가리키는 기존 에이전트·라우터가 사라지면 위임이 조용히 깨진다.
ROLE_ROOT="$TEST_TMP/role-contract"
mkdir -p "$ROLE_ROOT/.ai-harness" "$ROLE_ROOT/.claude/agents"
printf '%s\n' '{"project_id":"role-contract","level":"standard","integrations":["claude"],"roles":{"developer":{"source":"existing","integrations":["claude"],"agents":["sunwoong","ghost"],"router":".claude/skills/orchestrator/SKILL.md"}}}' >"$ROLE_ROOT/.ai-harness/harness.json"
printf '%s\n' '---' 'name: sunwoong' '---' >"$ROLE_ROOT/.claude/agents/sunwoong.md"
ROLE_SCAN="$("$ROOT/scripts/workflow-contract.sh" scan --root "$ROLE_ROOT")"
assert_eq "ghost" "$(printf '%s' "$ROLE_SCAN" | jq -r '[.findings[] | select(.check=="role_agent_missing")][0].token')" "missing mapped agent is a contract finding"
assert_eq ".claude/skills/orchestrator/SKILL.md" "$(printf '%s' "$ROLE_SCAN" | jq -r '[.findings[] | select(.check=="role_router_missing")][0].token')" "missing router is a contract finding"
assert_eq "0" "$(printf '%s' "$ROLE_SCAN" | jq -r '[.findings[] | select(.token=="sunwoong")] | length')" "existing mapped agent passes"
pass "role mapping contract"

finish_tests
