#!/usr/bin/env bash
# 회귀 테스트 — harness-init 프론트엔드 — UI 검토 계약, 프론트 팀 역할 세트, 시안 정책, UI 검토 체크리스트
# 실행: bash tests/run.sh init-frontend-ui
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 앞 영역(init-sync-stacks)이 만들던 frontend 스택 계획: 이 영역의 단언이 FE_PLAN을 비교 대상으로 쓴다.
FE_ROOT="$TEST_TMP/frontend-project"
mkdir -p "$FE_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"frontend-project","level":"standard","integrations":["codex"],"stacks":["frontend"],"harness_version":"0.18.0"}' >"$FE_ROOT/.ai-harness/harness.json"
FE_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$FE_ROOT" --catalog "$ROOT/templates/managed-files.json")"

# UI 검토 계약: 서버 렌더링 화면까지 stack 게이트 ui로 생성하고, 실제 렌더링·조작 근거를 요구한다. (#150)
UIR_CONTENT="$(<"$ROOT/templates/ui-review/SKILL.md")"
assert_file "$ROOT/templates/ui-review/references/checklist.md"
assert_contains "$UIR_CONTENT" "Flask/Jinja" "ui-review covers server-rendered screens"
assert_contains "$UIR_CONTENT" "## 거짓 통과" "ui-review lists false passes"
assert_contains "$UIR_CONTENT" "\`unverified\`는 완료가 아니다" "ui-review never calls an unverified UI done"
assert_contains "$UIR_CONTENT" "작업 트리를 바꾸지 않는다" "ui-review separates inspection from authoring"
assert_contains "$UIR_CONTENT" "증거가 있고 지금 작업 트리에 대한" "ui-review states what automatic gates cannot judge"
assert_contains "$(<"$ROOT/templates/ui-review/references/checklist.md")" "기본 상태로 식별" "the checklist starts from discoverability in the default state"
UI_ROOT="$TEST_TMP/ui-project"
mkdir -p "$UI_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"ui-project","level":"standard","integrations":["codex","claude"],"stacks":["ui"],"harness_version":"0.42.0"}' >"$UI_ROOT/.ai-harness/harness.json"
UI_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$UI_ROOT" --catalog "$ROOT/templates/managed-files.json")"
for path in .ai-harness/workflows/ui-review-graph.json .agents/skills/ui-review/SKILL.md .claude/skills/ui-review/references/checklist.md; do
  assert_eq "add" "$(printf '%s' "$UI_PLAN" | jq -r --arg p "$path" '.items[] | select(.path==$p) | .action')" "ui stack selects $path"
done
assert_eq "0" "$(printf '%s' "$UI_PLAN" | jq -r '[.items[] | select(.path==".agents/skills/frontend-fundamentals/SKILL.md")] | length')" "a server-rendered UI project does not get React judgment skills"
assert_eq "0" "$(printf '%s' "$FE_PLAN" | jq -r '[.items[] | select(.path | contains("ui-review"))] | length')" "the UI contract is opt-in: a frontend project without the ui stack is not given it"
assert_contains "$HARNESS_INIT_CONTENT" "서버 렌더링 템플릿" "harness init detects server-rendered UI"
assert_contains "$HARNESS_INIT_CONTENT" ".ai-harness/docs/ui.md" "harness init generates the UI context doc"
pass "ui review contract and stack gating"

# 프론트 팀 역할 세트: frontend-team stack이면 라우터·fe-architect·fe-implementer, design-system이면 fe-designer·design-audit까지.
for f in frontend-team/SKILL.md design-audit/SKILL.md frontend-team/personas/fe-architect.md frontend-team/personas/fe-implementer.md frontend-team/personas/fe-designer.md; do
  assert_file "$ROOT/templates/$f"
done
for role in fe-architect fe-implementer fe-designer; do
  PERSONA="$(<"$ROOT/templates/frontend-team/personas/$role.md")"
  assert_contains "$PERSONA" "name: $role" "$role persona names itself"
  grep -Eq '^model: (opus|sonnet|haiku)$' "$ROOT/templates/frontend-team/personas/$role.md" || fail "$role persona pins a model"
  assert_contains "$PERSONA" "다음 담당: <역할>:" "$role report ends with the handoff line"
  assert_contains "$PERSONA" ".ai-harness/docs/frontend.md" "$role reads project facts from frontend.md"
  assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "| $role |" "$role has a default model row"
  # frontmatter skills는 같은 stack 게이트에서 생성되는 템플릿만 가리킨다.
  while IFS= read -r skill; do
    assert_file "$ROOT/templates/$skill/SKILL.md"
  done < <(awk '/^---$/{n++; next} n==1 && /^  - /{print $2}' "$ROOT/templates/frontend-team/personas/$role.md")
done
# 공개 템플릿에는 원본 팀의 실명·사내 패키지·디자인 시스템 이름이 남지 않는다.
for f in "$ROOT"/templates/frontend-team/SKILL.md "$ROOT"/templates/frontend-team/personas/*.md "$ROOT"/templates/design-audit/SKILL.md; do
  if ! bash "$ROOT/scripts/identifier-scan.sh" "$f"; then
    fail "internal name leaked into public template: $f"
  fi
done
TEAM_ROOT="$TEST_TMP/frontend-team-project"
mkdir -p "$TEAM_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"frontend-team-project","level":"standard","integrations":["claude"],"stacks":["frontend","frontend-team"],"harness_version":"0.44.0"}' >"$TEAM_ROOT/.ai-harness/harness.json"
TEAM_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$TEAM_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "add" "$(printf '%s' "$TEAM_PLAN" | jq -r '.items[] | select(.path==".claude/skills/frontend-team/SKILL.md") | .action')" "frontend-team stack selects the role router"
assert_eq "add" "$(printf '%s' "$TEAM_PLAN" | jq -r '.items[] | select(.path==".claude/agents/fe-architect.md") | .action')" "frontend-team stack selects fe-architect"
assert_eq "add" "$(printf '%s' "$TEAM_PLAN" | jq -r '.items[] | select(.path==".claude/agents/fe-implementer.md") | .action')" "frontend-team stack selects fe-implementer"
assert_eq "0" "$(printf '%s' "$TEAM_PLAN" | jq -r '[.items[] | select(.path | test("fe-designer|design-audit"))] | length')" "designer role needs the design-system stack"
jq '.stacks += ["design-system"]' "$TEAM_ROOT/.ai-harness/harness.json" >"$TEAM_ROOT/m" && mv "$TEAM_ROOT/m" "$TEAM_ROOT/.ai-harness/harness.json"
TEAM_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$TEAM_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "add" "$(printf '%s' "$TEAM_PLAN" | jq -r '.items[] | select(.path==".claude/agents/fe-designer.md") | .action')" "design-system stack selects fe-designer"
assert_eq "add" "$(printf '%s' "$TEAM_PLAN" | jq -r '.items[] | select(.path==".claude/skills/design-audit/SKILL.md") | .action')" "design-system stack selects design-audit"
assert_eq "0" "$(printf '%s' "$FE_PLAN" | jq -r '[.items[] | select(.path | test("frontend-team|fe-|design-audit"))] | length')" "plain frontend stack does not create the role set"
# 역할을 스택 역할 세트에 넘기면 범용 페르소나가 role_adopted로 정리 후보에 오르고, 세트 페르소나가 사라지면 계약 위반이다.
mkdir -p "$TEAM_ROOT/.claude/agents"
printf '%s\n' 'developer' >"$TEAM_ROOT/.claude/agents/developer.md"
"$ROOT/scripts/harness-sync-state.sh" record --root "$TEAM_ROOT" --version 0.44.0 --file .claude/agents/developer.md >/dev/null
jq '.roles = {developer: {source: "stack", stack: "frontend-team", integrations: ["claude"], agents: ["fe-implementer", "fe-architect"], router: ".claude/skills/frontend-team/SKILL.md"}}' \
  "$TEAM_ROOT/.ai-harness/harness.json" >"$TEAM_ROOT/m" && mv "$TEAM_ROOT/m" "$TEAM_ROOT/.ai-harness/harness.json"
assert_eq "role_adopted" "$("$ROOT/scripts/harness-sync-state.sh" plan --root "$TEAM_ROOT" --catalog "$ROOT/templates/managed-files.json" | jq -r '.orphaned[] | select(.path==".claude/agents/developer.md") | .reason')" "role handed to the stack role set orphans the generic persona"
TEAM_SCAN="$("$ROOT/scripts/workflow-contract.sh" scan --root "$TEAM_ROOT")"
assert_eq "fe-architect,fe-implementer" "$(printf '%s' "$TEAM_SCAN" | jq -r '[.findings[] | select(.check=="role_agent_missing") | .token] | sort | join(",")')" "missing stack role persona is a contract finding"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" '"source": "stack"' "harness init records stack role mapping"
pass "frontend team role set"

# 시안 처리 규칙은 landing-page 원본과 바이트 단위로 같은 사본을 ui-review·frontend-team·native-ui가 공유한다. (#186)
HANDOFF_SRC="$ROOT/templates/ui-review/references/design-handoff.md"
assert_file "$HANDOFF_SRC"
cmp -s "$ROOT/skills/landing-page/references/design-handoff.md" "$HANDOFF_SRC" \
  || fail "templates/ui-review/references/design-handoff.md must match skills/landing-page/references/design-handoff.md byte for byte"
for HANDOFF_PATH in .agents/skills/ui-review/references/design-handoff.md .claude/skills/ui-review/references/design-handoff.md \
  .agents/skills/frontend-team/references/design-handoff.md .claude/skills/frontend-team/references/design-handoff.md \
  .agents/skills/native-ui/references/design-handoff.md .claude/skills/native-ui/references/design-handoff.md; do
  assert_eq "templates/ui-review/references/design-handoff.md" "$(jq -r --arg p "$HANDOFF_PATH" '.artifacts[] | select(.path==$p) | .source' "$ROOT/templates/managed-files.json")" "$HANDOFF_PATH ships the shared design handoff"
done
assert_contains "$UIR_CONTENT" "references/design-handoff.md" "ui-review reconciles a mockup through the design handoff"
for HANDOFF_CLASS in "| 일치 |" "| 조정 |" "| 누락 |" "| 상충 |" "| 승인 없이 추가 |" "나란히 캡처"; do
  assert_contains "$UIR_CONTENT" "$HANDOFF_CLASS" "ui-review classifies mockup differences: $HANDOFF_CLASS"
done
assert_contains "$UIR_CONTENT" "증거 출처" "ui-review reports where mobile evidence came from"
assert_contains "$(<"$ROOT/templates/implement-feature/SKILL.md")" "the mockup source" "the feature brief carries the mockup source for UI scenarios"
assert_contains "$(<"$ROOT/templates/workflow-driver/workflow-driver.sh")" "the mockup source (file, frame, or node)" "the runner asks the brief for the mockup source"

# 시안 정책: 값은 토큰, 점수는 규칙 문서·형제, 구조는 시안. "시안은 기준이 아니다" 단정은 남지 않는다.
DESIGNER="$(<"$ROOT/templates/frontend-team/personas/fe-designer.md")"
IMPLEMENTER="$(<"$ROOT/templates/frontend-team/personas/fe-implementer.md")"
ARCHITECT="$(<"$ROOT/templates/frontend-team/personas/fe-architect.md")"
AUDIT="$(<"$ROOT/templates/design-audit/SKILL.md")"
for POLICY_FILE in fe-designer.md fe-implementer.md fe-architect.md; do
  if grep -n '시안은 기준이 아니다\|시안을 뒤집고\|시안의 픽셀·색은 따르지 않고' "$ROOT/templates/frontend-team/personas/$POLICY_FILE"; then
    fail "$POLICY_FILE still treats the mockup as no reference at all"
  fi
done
if grep -n '시안은 기준이 아니다' "$ROOT/templates/design-audit/SKILL.md"; then fail "design-audit still says the mockup is no reference"; fi
assert_contains "$DESIGNER" "구조·내용 순서·흐름의 기준은 시안이다" "fe-designer takes structure from the mockup"
assert_contains "$DESIGNER" "새 토큰 제안도 후보다" "fe-designer keeps new token proposals out of the rule document"
assert_contains "$IMPLEMENTER" "화면당 한 번(최대" "fe-implementer asks about new values once per screen"
assert_contains "$IMPLEMENTER" "PR의 \"결정 사항\"" "fe-implementer records unattended defaults in the PR"
assert_contains "$IMPLEMENTER" "제품 동작으로 성립하는 쪽" "fe-implementer still settles conflicting mockups by product behavior"
assert_contains "$ARCHITECT" "조용히 뒤집지 않는다" "fe-architect asks instead of silently overturning a mockup"
assert_contains "$ARCHITECT" "추천 기본값은 규칙" "fe-architect recommends the rule as the default"
assert_contains "$AUDIT" "점수는 디자인 규칙 문서와 형제 페이지로만 매긴다" "design-audit scores only against rules and siblings"
assert_contains "$AUDIT" "시안이 정한 구조가 형제와 달라 축 A·D에 걸린다" "design-audit holds mockup structure for a rule decision"
assert_contains "$AUDIT" "색만으로 상태를 전하면 축 B에서 잰다" "design-audit notes color-only state under axis B"
for AXIS_ROW in "| A. 골격·위계 | 30 |" "| B. 색·강조·상태 | 20 |" "| C. 컴포넌트 문법 | 20 |" "| D. 형제 정합 | 15 |" "| E. 톤·정직성 | 15 |"; do
  assert_contains "$AUDIT" "$AXIS_ROW" "design-audit keeps its axes and points: $AXIS_ROW"
done
assert_contains "$(<"$ROOT/templates/frontend-team/SKILL.md")" "references/design-handoff.md" "the role router points every role at the design handoff"
pass "design handoff shared with product UI and mockup policy"

# UI 검토 체크리스트: 모션 절과 WCAG 2.2 수치. 웹 터치 영역은 24px 하한 + 44px 권장이다. (#186)
UIR_CHECKLIST="$(<"$ROOT/templates/ui-review/references/checklist.md")"
for CHECK_ITEM in "## 모션" "prefers-reduced-motion: reduce" "전환이 다음 조작을 막지 않는다" "반복 애니메이션을 멈춘다" "1초에 3번" \
  "4.5:1" "3:1" "색만으로 상태를 전하지 않는다" "200%" "320 CSS px" "24×24 CSS px" "44×44 CSS px" \
  "aria-live" "aria-describedby" "autocomplete" "inputmode" "blur" "첫 사용" "진행률·남은 시간을 지어내지 않는다" \
  "401" "403" "429" "오프라인" "드래그에 대안이 있다" "합성 터치"; do
  assert_contains "$UIR_CHECKLIST" "$CHECK_ITEM" "ui-review checklist covers: $CHECK_ITEM"
done
if grep -n '(약 44px)' "$ROOT/templates/ui-review/references/checklist.md"; then fail "the 44px touch target is a recommendation, not the floor"; fi
assert_eq "37" "$(grep -cE '^[0-9]+\. \*\*' "$ROOT/templates/ui-review/references/checklist.md")" "checklist items are numbered without gaps"
for MOTION_RULE in "100–150ms" "150–250ms" "200–400ms" "퇴장은 진입보다 짧거나 같다" "bounce가 없다" "(hover: hover) and (pointer: fine)" "다음 조작을 막는가" "기본 상태에서 콘텐츠가 보인다"; do
  assert_contains "$ARCHITECT" "$MOTION_RULE" "fe-architect motion covers: $MOTION_RULE"
done
pass "ui review checklist covers motion and WCAG 2.2 numbers"

# 렌더 대상(#678): harness-init이 ui.md에 화면별 렌더 대상을 실측해 적고, ui-review 계약은 대체 렌더링을 막고 승인 뒤에만 설치한다.
RT_INIT="$(<"$ROOT/skills/harness-init/SKILL.md")"
RT_UIMD_LINE="$(grep -n 'ui.md' "$ROOT/skills/harness-init/SKILL.md" | grep '렌더 대상' || true)"
[[ -n "$RT_UIMD_LINE" ]] || fail "harness-init describes the render target in the ui.md item"
for v in chromium webkit firefox simulator emulator WKWebView; do
  assert_contains "$RT_UIMD_LINE" "$v" "the ui.md render target lists $v"
done
assert_contains "$RT_INIT" "실측" "harness-init measures the engine the app really uses"
RT_UIR="$(<"$ROOT/templates/ui-review/SKILL.md")"
for RT_ITEM in "렌더 대상" "다른 엔진으로 대신 렌더링했다" "선언한 렌더 대상을 쓸 수 없었" "사용자 승인 뒤에만"; do
  assert_contains "$RT_UIR" "$RT_ITEM" "ui-review contract covers: $RT_ITEM"
done
pass "harness-init and the ui-review contract declare and keep the render target (#678)"

finish_tests
