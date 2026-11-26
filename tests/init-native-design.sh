#!/usr/bin/env bash
# 회귀 테스트 — harness-init 네이티브 앱 감지·native-ui 계약, 디자인 스킬 지도, 디자인 감사, 직접 수정 가드, 러너 템플릿 배치
# 실행: bash tests/run.sh init-native-design
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 앞 영역들이 만들던 frontend·frontend-team 스택 계획: 디자인 지도·Figma 단언이 FE_PLAN·TEAM_PLAN과 비교한다.
FE_ROOT="$TEST_TMP/frontend-project"
mkdir -p "$FE_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"frontend-project","level":"standard","integrations":["codex"],"stacks":["frontend"],"harness_version":"0.18.0"}' >"$FE_ROOT/.ai-harness/harness.json"
FE_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$FE_ROOT" --catalog "$ROOT/templates/managed-files.json")"
TEAM_ROOT="$TEST_TMP/frontend-team-project"
mkdir -p "$TEAM_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"frontend-team-project","level":"standard","integrations":["claude"],"stacks":["frontend","frontend-team","design-system"],"harness_version":"0.44.0"}' >"$TEAM_ROOT/.ai-harness/harness.json"
TEAM_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$TEAM_ROOT" --catalog "$ROOT/templates/managed-files.json")"

AUDIT="$(<"$ROOT/templates/design-audit/SKILL.md")"
# 앞 영역(init-frontend-ui)이 만들던 ui 스택 계획: native-ui 단언이 UI_PLAN과 비교한다.
UI_ROOT="$TEST_TMP/ui-project"
mkdir -p "$UI_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"ui-project","level":"standard","integrations":["codex","claude"],"stacks":["ui"],"harness_version":"0.42.0"}' >"$UI_ROOT/.ai-harness/harness.json"
UI_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$UI_ROOT" --catalog "$ROOT/templates/managed-files.json")"

# 네이티브 앱: harness-init이 RN·Flutter·iOS·Android를 stack native로 감지하고, native-ui가 ui-review 계약을 사본으로 공유한다. (#186)
# 감지는 harness-init 문서 규칙(에이전트가 실측해 판단)이라 실행 코드가 없다. 판정 근거가 되는 문구를 고정한다.
for NATIVE_SIGNAL in "**네이티브 앱 감지**" "\`react-native\` 또는 \`expo\`" "\`pubspec.yaml\`의 \`flutter:\`" "\`*.xcodeproj\`·\`*.xcworkspace\`·\`Podfile\`" \
  "\`com.android.application\` 플러그인, 또는 화면을 가진 \`com.android.library\`" "화면 없는 SDK 라이브러리는 제외" "androidx.compose" "org.springframework.boot" "React Native·Expo 저장소는 웹 프론트(\`frontend\`)나 웹 UI(\`ui\`)로 잡지 않는다" \
  "\`react-native-web\`으로 웹도 내면 \`native\`와 웹 쪽 stack을 둘 다" "6-2. **네이티브 UI 검토**" "\`*/skills/native-ui\`가 있으면 \`native\`"; do
  assert_contains "$HARNESS_INIT_CONTENT" "$NATIVE_SIGNAL" "harness init native detection: $NATIVE_SIGNAL"
done
assert_contains "$HARNESS_INIT_CONTENT" "\`react-native\`나 \`expo\`가 함께 있으면 \`react\`는 웹 프론트의 근거가 아니다" "React Native is not detected as a web frontend"
NATIVE_DIR="$ROOT/templates/native-ui"
NATIVE_SKILL="$(<"$NATIVE_DIR/SKILL.md")"
NATIVE_CHECKLIST="$(<"$NATIVE_DIR/references/checklist.md")"
NATIVE_PLATFORMS="$(<"$NATIVE_DIR/references/platforms.md")"
assert_contains "$NATIVE_SKILL" "name: native-ui" "native-ui names itself"
assert_contains "$NATIVE_SKILL" "references/ui-review-contract.md" "native-ui reuses the ui-review contract"
assert_contains "$NATIVE_SKILL" "\`unverified\`" "native-ui reports unverified when the app cannot run"
assert_contains "$NATIVE_SKILL" "증거 출처" "native-ui records where evidence came from"
for NATIVE_ITEM in "안전 영역" "44×44pt" "48×48dp" "8dp" "Dynamic Type" "\`sp\`" "다크" "VoiceOver·TalkBack" "감소 모션" "크로스페이드" "뒤로 가기가 상태를 지킨다" "모달은 닫는 길이 둘이다" "제스처에 대안이 있다" "긴 목록" "300ms" "크기 등급"; do
  assert_contains "$NATIVE_CHECKLIST" "$NATIVE_ITEM" "native checklist covers: $NATIVE_ITEM"
done
for NATIVE_ITEM in "Apple Human Interface Guidelines" "Material Design 3" "2~5개" "3~5개" "내비게이션 레일" "predictive back" "edge-to-edge" \
  "xcrun simctl io booted screenshot" "xcrun simctl ui booted appearance dark" "adb exec-out screencap -p" "settings put system font_scale 1.3" "## React Native·Expo" "## Flutter" "프로젝트 결정"; do
  assert_contains "$NATIVE_PLATFORMS" "$NATIVE_ITEM" "native platform reference covers: $NATIVE_ITEM"
done
assert_contains "$(<"$ROOT/templates/workflow-driver/workflow-driver.sh")" "native-ui skill" "the ui_review node follows native-ui for native screens"
assert_eq "12" "$(jq '[.artifacts[] | select(.skill == "native-ui" and .stack == "native")] | length' "$ROOT/templates/managed-files.json")" "native-ui ships six files per integration behind the native stack"
assert_eq "templates/ui-review/references/checklist.md" "$(jq -r '.artifacts[] | select(.path == ".claude/skills/native-ui/references/web-checklist.md") | .source' "$ROOT/templates/managed-files.json")" "native-ui ships the shared web checklist it points to"
assert_eq "templates/ui-review/SKILL.md" "$(jq -r '.artifacts[] | select(.path == ".claude/skills/native-ui/references/ui-review-contract.md") | .source' "$ROOT/templates/managed-files.json")" "native-ui copies the ui-review contract instead of restating it"
NATIVE_ROOT="$TEST_TMP/native-project"
mkdir -p "$NATIVE_ROOT/.ai-harness"
printf '%s\n' '{"project_id":"native-project","level":"standard","integrations":["codex","claude"],"stacks":["native"],"harness_version":"0.50.0"}' >"$NATIVE_ROOT/.ai-harness/harness.json"
NATIVE_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$NATIVE_ROOT" --catalog "$ROOT/templates/managed-files.json")"
for path in .agents/skills/native-ui/SKILL.md .claude/skills/native-ui/references/checklist.md .claude/skills/native-ui/references/platforms.md .agents/skills/native-ui/references/ui-review-contract.md .claude/skills/native-ui/references/design-handoff.md; do
  assert_eq "add" "$(printf '%s' "$NATIVE_PLAN" | jq -r --arg p "$path" '.items[] | select(.path==$p) | .action')" "native stack selects $path"
done
assert_eq "0" "$(printf '%s' "$NATIVE_PLAN" | jq -r '[.items[] | select(.path | test("skills/(ui-review|frontend-fundamentals|frontend-team)/"))] | length')" "a native-only project gets neither the web UI contract nor web frontend skills"
# native-ui에 복사된 계약의 상대 링크는 native-ui에 배포되는 파일을 가리키거나, native-ui 본문이 웹 전용이라 무시한다고 적은 것이어야 한다.
while IFS= read -r NATIVE_LINK; do
  if [[ -n "$(printf '%s' "$NATIVE_PLAN" | jq -r --arg p ".claude/skills/native-ui/$NATIVE_LINK" '.items[] | select(.path==$p) | .path')" ]]; then continue; fi
  assert_contains "$NATIVE_SKILL" "계약 안의 \`$NATIVE_LINK\`" "native-ui says how to read the contract link $NATIVE_LINK"
  assert_contains "$(grep -F "계약 안의 \`$NATIVE_LINK\`" "$NATIVE_DIR/SKILL.md")" "무시한다" "native-ui ignores the web-only contract link $NATIVE_LINK"
done < <(grep -oE '\]\(references/[^)]+\)' "$ROOT/templates/ui-review/SKILL.md" | sed -E 's/^\]\(//; s/\)$//' | sort -u)
assert_eq "0" "$(printf '%s' "$NATIVE_PLAN" | jq -r '[.items[] | select(.path | endswith("design-skills.md"))] | length')" "a native-only project gets no web design skill map"
assert_eq "0" "$(printf '%s' "$UI_PLAN" | jq -r '[.items[] | select(.path | contains("native-ui"))] | length')" "a web UI project does not get native-ui"
# 기존 ui 프로젝트: 손대지 않은 계약은 갱신(refresh), 새 시안 처리 규칙은 추가(add)로 sync 계획에 오른다.
SYNC_UI_ROOT="$TEST_TMP/ui-sync-project"
mkdir -p "$SYNC_UI_ROOT/.ai-harness" "$SYNC_UI_ROOT/.claude/skills/ui-review/references"
printf '%s\n' '{"project_id":"ui-sync-project","level":"standard","integrations":["claude"],"stacks":["ui"],"harness_version":"0.50.0"}' >"$SYNC_UI_ROOT/.ai-harness/harness.json"
printf '%s\n' 'older checklist' >"$SYNC_UI_ROOT/.claude/skills/ui-review/references/checklist.md"
"$ROOT/scripts/harness-sync-state.sh" record --root "$SYNC_UI_ROOT" --version 0.50.0 --file .claude/skills/ui-review/references/checklist.md >/dev/null
SYNC_UI_PLAN="$("$ROOT/scripts/harness-sync-state.sh" plan --root "$SYNC_UI_ROOT" --catalog "$ROOT/templates/managed-files.json")"
assert_eq "refresh" "$(printf '%s' "$SYNC_UI_PLAN" | jq -r '.items[] | select(.path==".claude/skills/ui-review/references/checklist.md") | .action')" "sync refreshes an untouched checklist to the new items"
assert_eq "add" "$(printf '%s' "$SYNC_UI_PLAN" | jq -r '.items[] | select(.path==".claude/skills/ui-review/references/design-handoff.md") | .action')" "sync adds the design handoff to an existing UI project"
pass "native app detection and native-ui contract"
# 디자인 스킬 지도: 작업마다 주도 하나, 영역마다 주인 하나. 한 원본을 바이트 단위로 같은 사본으로 나눠 읽고, 설치된 스킬만 쓴다. (#210)
MAP_SRC="$ROOT/templates/ui-review/references/design-skills.md"
assert_file "$MAP_SRC"
for MAP_COPY in "$ROOT/skills/landing-page/references/design-skills.md" "$ROOT/skills/design-system-builder/references/design-skills.md"; do
  cmp -s "$MAP_COPY" "$MAP_SRC" || fail "$MAP_COPY must match templates/ui-review/references/design-skills.md byte for byte"
done
for MAP_SKILL in ui-review frontend-team design-audit; do
  for MAP_BASE in .agents .claude; do
    assert_eq "templates/ui-review/references/design-skills.md" "$(jq -r --arg p "$MAP_BASE/skills/$MAP_SKILL/references/design-skills.md" '.artifacts[] | select(.path==$p) | .source' "$ROOT/templates/managed-files.json")" "$MAP_BASE $MAP_SKILL ships the design skill map"
  done
done
for MAP_READER in skills/landing-page/SKILL.md skills/design-system-builder/SKILL.md templates/ui-review/SKILL.md templates/frontend-team/SKILL.md templates/design-audit/SKILL.md; do
  assert_contains "$(<"$ROOT/$MAP_READER")" "references/design-skills.md" "$MAP_READER points at the design skill map"
done
assert_eq "add" "$(printf '%s' "$UI_PLAN" | jq -r '.items[] | select(.path==".claude/skills/ui-review/references/design-skills.md") | .action')" "ui stack syncs the map"
assert_eq "add" "$(printf '%s' "$TEAM_PLAN" | jq -r '.items[] | select(.path==".claude/skills/design-audit/references/design-skills.md") | .action')" "design-system stack syncs the map"
assert_eq "0" "$(printf '%s' "$FE_PLAN" | jq -r '[.items[] | select(.path | endswith("design-skills.md"))] | length')" "a frontend project without UI contracts gets no map copy"
MAP_CONTENT="$(<"$MAP_SRC")"
assert_contains "$MAP_CONTENT" "**Installed skills only.**" "map uses installed skills only"
assert_contains "$MAP_CONTENT" "work exactly as you would without this map" "map keeps current behavior when a skill is missing"
assert_contains "$MAP_CONTENT" "A skill on this map never overrides a project value" "project rules stay above the map"
assert_contains "$MAP_CONTENT" "## Forbidden pairs" "map names forbidden pairs"
# 표의 주도 칸에는 스킬이 하나뿐이고, 영역 표의 영역마다 주인이 하나다.
MAP_JOBS="$(awk '/^## Jobs/{f=1;next} /^## /{f=0} f && /^\| / && !/^\| Job/ && !/^\|---/' "$MAP_SRC")"
assert_eq "7" "$(grep -c . <<<"$MAP_JOBS")" "map lists seven jobs"
while IFS= read -r MAP_ROW; do
  MAP_LEAD="$(awk -F'|' '{print $3}' <<<"$MAP_ROW")"
  [[ "$MAP_LEAD" != *"·"* && "$MAP_LEAD" != *","* ]] || fail "map job has more than one lead: $MAP_ROW"
done <<<"$MAP_JOBS"
MAP_LANES="$(awk '/^## Lanes/{f=1;next} /^## /{f=0} f && /^\| / && !/^\| Lane/ && !/^\|---/' "$MAP_SRC" | awk -F'|' '{print $2}')"
assert_eq "$(grep -c . <<<"$MAP_LANES")" "$(sort -u <<<"$MAP_LANES" | grep -c .)" "each lane appears once"
# 카탈로그의 모든 외부 디자인 스킬이 지도에 자리가 있다.
DESIGN_CATALOG="$ROOT/catalog/design-skills.json"
while IFS= read -r DESIGN_NAME; do
  assert_contains "$MAP_CONTENT" "\`$DESIGN_NAME\`" "map assigns $DESIGN_NAME"
done < <(jq -r '.skills[].name' "$DESIGN_CATALOG")
# 설치 가능한 항목은 원본 저장소·40자 커밋·경로·라이선스·실행/네트워크 검토를 모두 적었다.
assert_eq "0" "$(jq '[.skills[] | select((.builtin // null) == null and .installable != false)
  | select((.source.repo | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") | not) or (.source.ref | test("^[0-9a-f]{40}$") | not)
           or (.source.path == null) or (.license // "") == "" or (.review.runs // "") == "" or (.review.network // "") == "")] | length' "$DESIGN_CATALOG")" "every installable design skill records repo, pinned commit, path, license and review"
assert_eq "dataviz,impeccable" "$(jq -r '[.skills[] | select(.bundle=="core") | .name] | sort | join(",")' "$DESIGN_CATALOG")" "core bundle is impeccable plus dataviz"
assert_eq "0" "$(jq '[.skills[] | select(.installable == false and ((.note // "") == ""))] | length' "$DESIGN_CATALOG")" "skills setup cannot pin say where to get them"
HARNESS_INIT_DESIGN="$(<"$ROOT/skills/harness-init/SKILL.md")"
assert_contains "$HARNESS_INIT_DESIGN" "백엔드·라이브러리 저장소에는 권하지 않는다" "harness init suggests design skills only for UI repositories"
assert_contains "$HARNESS_INIT_DESIGN" "\`ui\`·\`frontend-team\`·\`design-system\` 중 하나가 있을 때만" "harness init suggests design skills only where the map ships"
assert_contains "$HARNESS_INIT_DESIGN" "/ai-harness:setup design" "harness init points at setup for design skills"
# 독립 디자인 검토는 플러그인 전역 에이전트다. 렌더링에 Bash를 쓰되 편집 도구는 없다.
# Bash가 있으면 쓰기를 기술적으로 막지 못하므로 "읽기 전용"이라 주장하지 않고, Skill 도구가 없으므로 외부 스킬을 쓴다고 하지 않는다.
DESIGN_REVIEWER="$ROOT/agents/design-reviewer.md"
assert_file "$DESIGN_REVIEWER"
DESIGN_REVIEWER_TOOLS="$(grep '^tools:' "$DESIGN_REVIEWER")"
assert_eq "tools: Read, Grep, Glob, Bash" "$DESIGN_REVIEWER_TOOLS" "design reviewer has no edit or skill tools"
DESIGN_REVIEWER_CONTENT="$(<"$DESIGN_REVIEWER")"
assert_contains "$DESIGN_REVIEWER_CONTENT" "**쓰기 도구가 없다. Bash는 렌더링 한정이다.**" "design reviewer limits Bash to rendering"
assert_contains "$DESIGN_REVIEWER_CONTENT" "기술적 강제가 아니라" "design reviewer does not overstate its Bash restriction"
if grep -qiE "읽기 전용이다|read-only" "$DESIGN_REVIEWER"; then fail "design reviewer claims to be read-only while it has Bash"; fi
if [[ "$DESIGN_REVIEWER_TOOLS" != *Skill* ]]; then
  assert_contains "$DESIGN_REVIEWER_CONTENT" "외부 디자인 스킬(\`impeccable\` 등)은 쓰지 않는다" "design reviewer without the Skill tool does not promise outside skills"
  assert_contains "$DESIGN_REVIEWER_CONTENT" "skills/web-design-guidelines/references/web-interface-guidelines.md" "design reviewer reads the built-in interface guideline rules"
  if grep -q "^외부 스킬:" "$DESIGN_REVIEWER"; then fail "design reviewer report still has an outside-skill line"; fi
  MAP_REVIEW_ROW="$(grep '^| Independent review' "$MAP_SRC")"
  assert_contains "$MAP_REVIEW_ROW" "in a fresh reviewer session only" "map keeps outside review skills out of the design-reviewer agent"
fi
assert_contains "$(<"$DESIGN_REVIEWER")" "\`unverified\`" "design reviewer does not pass what it could not render"
# 작고 안정적인 세 스킬은 내장이다: 고정 사본을 담고, setup이 설치하지 않으며, 네트워크 없이 동작한다.
assert_eq "design-system-patterns,emil-design-eng,web-design-guidelines" "$(jq -r '[.skills[] | select(.builtin=="ai-harness") | .name] | sort | join(",")' "$DESIGN_CATALOG")" "three small design skills are built into ai-harness"
assert_eq "0" "$(jq '[.skills[] | select(.builtin=="ai-harness")
  | select((.source.ref // "" | test("^[0-9a-f]{40}$") | not) or (.license // "") == "" or (.absorbed // "") == "" or (.note // "") == "")] | length' "$DESIGN_CATALOG")" "built-in design skills record the pinned origin, license, where they live and what to do with old copies"
while IFS= read -r BUILTIN_REPO; do
  assert_contains "$(<"$ROOT/THIRD-PARTY-LICENSES.md")" "https://github.com/$BUILTIN_REPO" "THIRD-PARTY-LICENSES names $BUILTIN_REPO"
done < <(jq -r '.skills[] | select(.builtin=="ai-harness") | .source.repo' "$DESIGN_CATALOG")
assert_contains "$MAP_CONTENT" "## Built in" "map lists the built-in design skills"
WIG_SRC="$ROOT/templates/ui-review/references/web-interface-guidelines.md"
assert_file "$WIG_SRC"
cmp -s "$ROOT/skills/web-design-guidelines/references/web-interface-guidelines.md" "$WIG_SRC" \
  || fail "skills/web-design-guidelines/references/web-interface-guidelines.md must match templates/ui-review/references/web-interface-guidelines.md byte for byte"
assert_contains "$(<"$WIG_SRC")" "## Output Format" "pinned interface guideline rules keep the upstream output format"
for WIG_BASE in .claude .agents; do
  assert_eq "templates/ui-review/references/web-interface-guidelines.md" "$(jq -r --arg p "$WIG_BASE/skills/ui-review/references/web-interface-guidelines.md" '.artifacts[] | select(.path==$p) | .source' "$ROOT/templates/managed-files.json")" "$WIG_BASE ui-review ships the pinned interface guideline rules"
done
assert_contains "$(<"$ROOT/templates/ui-review/SKILL.md")" "references/web-interface-guidelines.md" "ui-review checks code against the pinned interface guideline rules"
assert_eq "add" "$(printf '%s' "$UI_PLAN" | jq -r '.items[] | select(.path==".claude/skills/ui-review/references/web-interface-guidelines.md") | .action')" "ui stack syncs the interface guideline rules"
WIG_SKILL="$(<"$ROOT/skills/web-design-guidelines/SKILL.md")"
assert_contains "$WIG_SKILL" "references/web-interface-guidelines.md" "web-design-guidelines reads its pinned rules"
# 규칙을 받는 도구 호출은 금지하고, 출처 URL 언급은 허용한다.
if grep -qiE "\b(webfetch|web_fetch|curl|wget|fetch the latest|fetch fresh)\b" "$ROOT/skills/web-design-guidelines/SKILL.md"; then fail "web-design-guidelines still fetches its rules"; fi
for BUILTIN_SKILL in web-design-guidelines emil-design-eng; do
  assert_contains "$(sed -n '1,4p' "$ROOT/skills/$BUILTIN_SKILL/SKILL.md")" "description: Built into ai-harness as a pinned" "$BUILTIN_SKILL description says it is the built-in pinned copy"
done
assert_contains "$MAP_CONTENT" "use the \`ai-harness:\`-prefixed one" "map picks the ai-harness skill when two share a name"
EMIL_SKILL="$ROOT/skills/emil-design-eng/SKILL.md"
assert_contains "$(sed -n '1,8p' "$EMIL_SKILL")" "license: MIT" "emil-design-eng copy names its license"
assert_contains "$(sed -n '1,8p' "$EMIL_SKILL")" "emilkowalski/skill@$(jq -r '.skills[] | select(.name=="emil-design-eng") | .source.ref' "$DESIGN_CATALOG")" "emil-design-eng copy names the pinned commit the catalog records"
assert_file "$ROOT/skills/design-system-builder/references/theme-and-components.md"
assert_contains "$(<"$ROOT/skills/design-system-builder/SKILL.md")" "references/theme-and-components.md" "design-system-builder reads the absorbed theme and component patterns"
assert_contains "$(<"$ROOT/skills/design-system-builder/references/theme-and-components.md")" "tokens.md\` owns token layers, names" "absorbed patterns defer token naming to design-system-builder"
pass "design skill map, catalog and independent reviewer"

# 디자이너 Figma 흐름: 공용 Figma MCP 규칙과 채점 기준은 바이트 단위 사본이고, design-screen은 Figma·코드 어느 대상이든 design-audit 기준으로 루프를 돈다.
FIGMA_MCP_SRC="$ROOT/templates/design-audit/references/figma-mcp.md"
assert_file "$FIGMA_MCP_SRC"
for FIGMA_COPY in "$ROOT/skills/design-system-builder/references/figma-mcp.md" "$ROOT/skills/design-screen/references/figma-mcp.md" "$ROOT/skills/landing-page/references/figma-mcp.md"; do
  cmp -s "$FIGMA_COPY" "$FIGMA_MCP_SRC" || fail "$FIGMA_COPY must match templates/design-audit/references/figma-mcp.md byte for byte"
done
for FIGMA_BASE in .claude .agents; do
  assert_eq "templates/design-audit/references/figma-mcp.md" "$(jq -r --arg p "$FIGMA_BASE/skills/design-audit/references/figma-mcp.md" '.artifacts[] | select(.path==$p) | .source' "$ROOT/templates/managed-files.json")" "$FIGMA_BASE design-audit ships the Figma MCP rules"
done
assert_eq "add" "$(printf '%s' "$TEAM_PLAN" | jq -r '.items[] | select(.path==".claude/skills/design-audit/references/figma-mcp.md") | .action')" "design-system stack syncs the Figma MCP rules"
FIGMA_MCP="$(<"$FIGMA_MCP_SRC")"
assert_contains "$FIGMA_MCP" "\`use_figma\`" "Figma MCP rules name the write tool"
assert_contains "$FIGMA_MCP" "Do not fall back to a different output silently" "Figma preflight stops instead of improvising"
assert_contains "$FIGMA_MCP" "Never detach an instance" "Figma writing keeps library instances"
assert_contains "$FIGMA_MCP" "\`create_session\`" "Figma MCP rules open the server session first"
assert_contains "$FIGMA_MCP" "### When Figma's skill and ai-harness disagree" "ai-harness rules win over Figma's own skills on what is written"
assert_contains "$FIGMA_MCP" "**Per-node facts come from a read-only \`use_figma\` script**" "bound or raw is judged per node, not from the variable union"
assert_contains "$FIGMA_MCP" "**Sizing is not a token value.**" "sizing to match siblings is not a raw-value violation"
assert_contains "$FIGMA_MCP" "**A View seat has a small MCP tool-call limit**" "Figma preflight warns that a View seat cannot finish the loop"
assert_contains "$FIGMA_MCP" "never swap in a nearby variable" "a value with no variable keeps the spec value"
assert_contains "$FIGMA_MCP" "**The library's fonts load in the target.**" "every Figma writer checks library fonts before writing text"
assert_contains "$FIGMA_MCP" "**Hidden layers are not part of the design.**" "hidden spec layers are not read as differences"
assert_contains "$AUDIT" "## Figma 프레임이 대상일 때" "design-audit scores Figma frames"
assert_contains "$(<"$ROOT/templates/design-audit/SKILL.md")" "references/figma-mcp.md" "design-audit reads the Figma MCP rules"
assert_contains "$(<"$ROOT/templates/design-audit/SKILL.md")" "Figma 파일에 점수를 남기지 않는다" "design-audit keeps scores out of the Figma file"
DSB_SKILL="$(<"$ROOT/skills/design-system-builder/SKILL.md")"
assert_contains "$DSB_SKILL" "references/figma-output.md" "design-system-builder publishes a Figma library through its reference"
assert_contains "$DSB_SKILL" "references/figma-mcp.md" "design-system-builder reads the Figma MCP rules"
FIGMA_OUT="$(<"$ROOT/skills/design-system-builder/references/figma-output.md")"
assert_contains "$FIGMA_OUT" "**The token file is the source. The Figma library is generated from it.**" "token file stays the source of truth for Figma"
assert_contains "$FIGMA_OUT" "\`--color-text-muted\` → \`color/text-muted\`" "Figma variable names derive mechanically from token names"
assert_contains "$FIGMA_OUT" "## Drift check" "Figma output reports drift instead of overwriting"
assert_contains "$(<"$ROOT/skills/design-system-builder/references/output-format.md")" "- Figma 라이브러리:" "rule document meta records the Figma library"
DESIGN_SCREEN_DIR="$ROOT/skills/design-screen"
assert_file "$DESIGN_SCREEN_DIR/agents/openai.yaml"
cmp -s "$DESIGN_SCREEN_DIR/references/design-audit.md" "$ROOT/templates/design-audit/SKILL.md" \
  || fail "skills/design-screen/references/design-audit.md must match templates/design-audit/SKILL.md byte for byte"
DESIGN_SCREEN="$(<"$DESIGN_SCREEN_DIR/SKILL.md")"
assert_contains "$(sed -n '1,4p' "$DESIGN_SCREEN_DIR/SKILL.md")" "name: design-screen" "design-screen names itself"
assert_contains "$DESIGN_SCREEN" "references/design-audit.md" "design-screen scores with the design-audit copy"
assert_contains "$(<"$DESIGN_SCREEN_DIR/references/figma-target.md")" "](figma-mcp.md)" "design-screen Figma target reads the Figma MCP rules"
assert_contains "$DESIGN_SCREEN" "references/figma-target.md" "design-screen routes Figma drawing to its reference"
assert_contains "$DESIGN_SCREEN" "references/code-target.md" "design-screen routes code drawing to its reference"
assert_contains "$DESIGN_SCREEN" "A Figma spec does not make the target Figma" "the spec format does not pick the target"
assert_contains "$DESIGN_SCREEN" "Do not draw the target from the other side's raw values." "a missing design system side stops instead of improvising"
DESIGN_SCREEN_CODE="$(<"$DESIGN_SCREEN_DIR/references/code-target.md")"
assert_contains "$DESIGN_SCREEN_CODE" "**Data is a local fixture.**" "code target draws with fixtures, not real data"
assert_contains "$DESIGN_SCREEN_CODE" "Do not add a prop, variant, or style override to a shared component" "code target leaves shared components to design-system-builder"
assert_contains "$DESIGN_SCREEN_CODE" "Leave every change uncommitted." "code target does not commit"
assert_contains "$DESIGN_SCREEN_CODE" "Keep captures outside the repository" "code target captures stay out of the repository"
assert_contains "$DESIGN_SCREEN" "**Stop when the verdict is 통과 and no axis is below half or \`미확인\`.**" "design-screen loop stops only on a complete pass"
assert_contains "$DESIGN_SCREEN" "**At most three audits**, the clean-up audit included." "the clean-up audit counts toward the cap"
assert_contains "$(<"$DESIGN_SCREEN_DIR/references/figma-target.md")" "**Same organization as the library.**" "design-screen checks fonts and organization before drawing"
assert_contains "$AUDIT" "**대상 파일에도, 다른 어떤 파일에도 쓰지 않는다**" "Figma audit never writes"
assert_contains "$AUDIT" "라이브러리 검색에 같은 역할의 컴포넌트가 없고" "a proposal name alone does not escape the deduction"
assert_contains "$(<"$MAP_SRC")" "| Draw or extend a product screen from the design system, in Figma or in code | \`design-screen\` |" "design skill map routes design system screens to design-screen"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "\`/design-screen\`도 **플러그인 전역 Skill**" "harness-init documents design-screen"
assert_eq ".agents/skills/design-audit/references/figma-mcp.md" "$(jq -r '.artifacts[] | select(.path==".agents/skills/design-audit/references/figma-mcp.md") | .path' "$ROOT/templates/managed-files.json")" "codex design-audit ships the Figma MCP rules"
# Agent Skills 규격: description은 1024자 이하.
for SKILL_FILE in "$ROOT"/skills/*/SKILL.md; do
  DESC_LEN="$(python3 -c 'import re,sys; s=open(sys.argv[1],encoding="utf-8").read().split("---")[1]; m=re.search(r"^description:\s*(.*?)(?=^[A-Za-z_-]+:|\Z)",s,re.S|re.M); d=m.group(1).strip(); d=" ".join(l.strip() for l in d[1:].splitlines()).strip() if d.startswith(">") else d; print(len(d))' "$SKILL_FILE")"
  [ "$DESC_LEN" -le 1024 ] || fail "$SKILL_FILE description is $DESC_LEN characters (max 1024)"
done
assert_contains "$DESIGN_SCREEN" "**The audit is independent.**" "design-screen does not score its own drawing"
assert_contains "$DESIGN_SCREEN" "the brief's **decision list**" "the independent audit gets decisions, not reasoning"
assert_contains "$DESIGN_SCREEN" "report it as \`불성립\`" "an unfinished audit round is reported, not hidden"
assert_contains "$DESIGN_SCREEN" "**Each state must be coherent.**" "design-screen checks actions per state"
assert_contains "$(<"$ROOT/skills/design-system-builder/references/extract.md")" "### A Figma design kit as the source" "design-system-builder extracts rules from an existing Figma kit"
assert_contains "$DESIGN_SCREEN" "Never raise the score by removing what the requirement asked for" "design-screen does not trade requirements for score"
assert_contains "$DESIGN_SCREEN" "Do not edit the design system" "design-screen leaves the design system to design-system-builder"
assert_contains "$(<"$ROOT/README.md")" "| \`/design-screen\` |" "README lists design-screen"
pass "designer Figma flow"

# 무인 실행은 .claude/ 아래를 Write/Edit로 쓸 수 없어(보호 경로) 스크립트로 옮긴다. settings·hook과 저장소 밖은 막는다.
PLACE_ROOT="$TEST_TMP/place-project"
mkdir -p "$PLACE_ROOT/.ai-harness-stage" "$PLACE_ROOT/.claude"
printf '%s\n' 'rendered' >"$PLACE_ROOT/.ai-harness-stage/review.md"
"$ROOT/scripts/place-claude-file.sh" --root "$PLACE_ROOT" --from "$PLACE_ROOT/.ai-harness-stage/review.md" --to .claude/commands/review.md >/dev/null
assert_eq "rendered" "$(<"$PLACE_ROOT/.claude/commands/review.md")" "staged file is placed under .claude/commands"
assert_not_file "$PLACE_ROOT/.ai-harness-stage/review.md"
TEMPLATE_JS="$(find "$ROOT/templates" -name '*.js' -path '*workflows*' | head -n 1)"
[[ -n "$TEMPLATE_JS" ]] || TEMPLATE_JS="$(find "$ROOT/templates" -type f -name '*.md' | head -n 1)"
"$ROOT/scripts/place-claude-file.sh" --root "$PLACE_ROOT" --from "$TEMPLATE_JS" --to .claude/workflows/review.js >/dev/null
cmp -s "$TEMPLATE_JS" "$PLACE_ROOT/.claude/workflows/review.js" || fail "plugin template is copied verbatim"
assert_file "$TEMPLATE_JS"
printf '%s\n' '{}' >"$PLACE_ROOT/.ai-harness-stage/settings.json"
for bad in .claude/settings.json .claude/settings.local.json .claude/hooks/guard.sh .claude/commands/../settings.json AGENTS.md; do
  if "$ROOT/scripts/place-claude-file.sh" --root "$PLACE_ROOT" --from "$PLACE_ROOT/.ai-harness-stage/settings.json" --to "$bad" 2>/dev/null; then
    fail "place-claude-file must refuse $bad"
  fi
done
printf '%s\n' 'secret' >"$TEST_TMP/outside.txt"
if "$ROOT/scripts/place-claude-file.sh" --root "$PLACE_ROOT" --from "$TEST_TMP/outside.txt" --to .claude/agents/x.md 2>/dev/null; then
  fail "place-claude-file must refuse sources outside the project and plugin templates"
fi
mkdir -p "$TEST_TMP/escape"
ln -s "$TEST_TMP/escape" "$PLACE_ROOT/.claude/agents"
if "$ROOT/scripts/place-claude-file.sh" --root "$PLACE_ROOT" --from "$PLACE_ROOT/.ai-harness-stage/settings.json" --to .claude/agents/x.md 2>/dev/null; then
  fail "place-claude-file must refuse a symlinked directory that leaves .claude"
fi
assert_not_file "$TEST_TMP/escape/x.md"
pass "unattended .claude writes go through a restricted placer"

# 무인 sync는 셸 복사가 없어 큰 러너를 옮기지 못하고 일부 적용으로 끝났다. 카탈로그 copy 항목은 이 스크립트로 바이트 그대로 옮긴다.
mf_refuse() { # expected-message root path...
  local want="$1" root="$2" rc=0 err=""
  shift 2
  local args=() p
  for p in "$@"; do args+=(--path "$p"); done
  err="$("$ROOT/scripts/place-managed-file.sh" --root "$root" "${args[@]}" 2>&1 >/dev/null)" || rc=$?
  [[ "$rc" == 2 ]] || fail "place-managed-file must refuse $* with exit 2 (got $rc: $err)"
  assert_contains "$err" "$want" "refusal reason for $*"
}
mf_sha() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | awk '{print $1}'; }
MF_ROOT="$TEST_TMP/managed-place"
mkdir -p "$MF_ROOT"
MF_RUNNER=".ai-harness/workflows/workflow-driver.sh"
MF_SKILL=".claude/skills/frontend-testing/SKILL.md"
assert_eq "copy|copy" "$(jq -r --arg a "$MF_RUNNER" --arg b "$MF_SKILL" '[.artifacts[] | select(.path == $a or .path == $b) | .mode] | join("|")' "$ROOT/templates/managed-files.json")" "fixture paths are copy artifacts"
"$ROOT/scripts/place-managed-file.sh" --root "$MF_ROOT" --path "$MF_RUNNER" --path "$MF_SKILL" >/dev/null
cmp -s "$ROOT/templates/workflow-driver/workflow-driver.sh" "$MF_ROOT/$MF_RUNNER" || fail "runner is copied byte for byte"
cmp -s "$ROOT/templates/frontend-testing/SKILL.md" "$MF_ROOT/$MF_SKILL" || fail "copy artifact under .claude is placed"
[[ -x "$MF_ROOT/$MF_RUNNER" ]] || fail "runner keeps the template's executable bit"
[[ ! -x "$MF_ROOT/$MF_SKILL" ]] || fail "non-executable template stays non-executable"
[[ -z "$(find "$MF_ROOT" -name '.place.*')" ]] || fail "no temporary files are left behind"
# 기록된 해시와 같은(사람이 고치지 않은) 옛 사본만 덮어쓴다.
printf 'old\n' >"$MF_ROOT/$MF_RUNNER"
mkdir -p "$MF_ROOT/.ai-harness"
jq -n --arg p "$MF_RUNNER" --arg h "$(mf_sha "$MF_ROOT/$MF_RUNNER")" '{managed_files: {($p): {content_sha256: $h}}}' >"$MF_ROOT/.ai-harness/harness.json"
"$ROOT/scripts/place-managed-file.sh" --root "$MF_ROOT" --path "$MF_RUNNER" >/dev/null
cmp -s "$ROOT/templates/workflow-driver/workflow-driver.sh" "$MF_ROOT/$MF_RUNNER" || fail "an unchanged older copy is refreshed"
printf 'edited by a person\n' >"$MF_ROOT/$MF_RUNNER"
mf_refuse "modified since it was recorded" "$MF_ROOT" "$MF_RUNNER"
assert_eq "edited by a person" "$(<"$MF_ROOT/$MF_RUNNER")" "a modified managed file is not overwritten"
printf 'mine\n' >"$MF_ROOT/$MF_SKILL"
mf_refuse "untracked" "$MF_ROOT" "$MF_SKILL"
assert_eq "mine" "$(<"$MF_ROOT/$MF_SKILL")" "an unrecorded existing file is not overwritten"
mf_refuse "not a managed artifact" "$MF_ROOT" .claude/settings.json
mf_refuse "not a managed artifact" "$MF_ROOT" AGENTS.md
for bad in ../outside.sh /etc/passwd .ai-harness/workflows/../../x.sh; do
  mf_refuse "invalid path" "$MF_ROOT" "$bad"
done
assert_not_file "$MF_ROOT/AGENTS.md"
MF_FRESH="$TEST_TMP/managed-place-fresh"
mkdir -p "$MF_FRESH"
mf_refuse "not a managed artifact" "$MF_FRESH" "$MF_RUNNER" AGENTS.md
assert_not_file "$MF_FRESH/$MF_RUNNER"
[[ ! -d "$MF_FRESH/.ai-harness" ]] || fail "a rejected call creates no directories"
mkdir -p "$TEST_TMP/mf-escape" "$MF_FRESH/.claude"
ln -s "$TEST_TMP/mf-escape" "$MF_FRESH/.claude/skills"
mf_refuse "escapes the project" "$MF_FRESH" "$MF_SKILL"
[[ ! -e "$TEST_TMP/mf-escape/frontend-testing" ]] || fail "nothing is created through the escaping link"
mkdir -p "$MF_FRESH/.ai-harness/workflows"
ln -s "$TEST_TMP/mf-escape/target.sh" "$MF_FRESH/$MF_RUNNER"
mf_refuse "is a symlink" "$MF_FRESH" "$MF_RUNNER"
assert_not_file "$TEST_TMP/mf-escape/target.sh"
rm -f "$MF_FRESH/$MF_RUNNER" && mkdir -p "$MF_FRESH/$MF_RUNNER"
mf_refuse "is a directory" "$MF_FRESH" "$MF_RUNNER"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "place-managed-file.sh --root . --path" "unattended sync copies copy artifacts with the placer"
pass "unattended sync places copy artifacts byte for byte"

# 워크플로 진입점(mode:render)은 LLM이 손으로 써서 결과가 흔들렸고 자동 병합이 검증하지 못했다(#316).
# 스크립트가 같은 입력에서 바이트 같은 결과를 내고, 이 저장소 생성물이 그 결과(golden)와 같아야 한다.
RD_PATHS="$(jq -r '.artifacts[] | select(.mode == "render") | .path' "$ROOT/templates/managed-files.json")"
assert_eq "12" "$(grep -c . <<<"$RD_PATHS")" "twelve workflow entry points are render artifacts"
while IFS= read -r rd_path; do
  "$ROOT/scripts/render-managed-file.sh" --path "$rd_path" >"$TEST_TMP/render-1" || fail "render $rd_path"
  "$ROOT/scripts/render-managed-file.sh" --path "$rd_path" >"$TEST_TMP/render-2" || fail "render $rd_path again"
  cmp -s "$TEST_TMP/render-1" "$TEST_TMP/render-2" || fail "render is deterministic: $rd_path"
  cmp -s "$TEST_TMP/render-1" "$ROOT/$rd_path" || fail "generated $rd_path matches the render script"
done <<<"$RD_PATHS"
"$ROOT/scripts/render-managed-file.sh" --path .agents/skills/review/SKILL.md >"$TEST_TMP/render-codex"
cmp -s "$ROOT/templates/review/SKILL.md" "$TEST_TMP/render-codex" || fail "the Codex skill is the template as is"
"$ROOT/scripts/render-managed-file.sh" --path .claude/commands/review.md >"$TEST_TMP/render-claude"
RD_CLAUDE="$(<"$TEST_TMP/render-claude")"
assert_eq "---" "$(sed -n 1p "$TEST_TMP/render-claude")" "the command keeps its frontmatter"
assert_eq "$(sed -n 's/^description: //p' "$ROOT/templates/review/SKILL.md")" "$(sed -n 's/^description: //p' "$TEST_TMP/render-claude")" "the command keeps the template description"
assert_eq '0' "$(grep -c '^name:' "$TEST_TMP/render-claude" || true)" "the command drops the skill name"
assert_eq 'argument-hint: "<PR 번호, 브랜치, 또는 diff>"' "$(sed -n 3p "$TEST_TMP/render-claude")" "the command takes its argument hint from the catalog"
assert_eq "---" "$(sed -n 4p "$TEST_TMP/render-claude")" "the hint closes the frontmatter"
assert_contains "$RD_CLAUDE" $'1. @AGENTS.md\n2. @.ai-harness/workflows/review.md\n3. @.ai-harness/workflows/review-graph.json' "startup reads are imported with @"
# shellcheck disable=SC2016  # $ARGUMENTS는 Claude 커맨드 자리표시자다
assert_eq $'\n## Request\n\n$ARGUMENTS' "$(tail -n 4 "$TEST_TMP/render-claude")" "the command ends with the request"
for rd_bad in .ai-harness/workflows/workflow-driver.sh AGENTS.md ../x.md; do
  if "$ROOT/scripts/render-managed-file.sh" --path "$rd_bad" >/dev/null 2>&1; then fail "render refuses $rd_bad"; fi
done
# 배치도 같은 스크립트로 한다. 사람이 고친 render 파일은 지금처럼 덮어쓰지 않는다.
RD_ROOT="$TEST_TMP/render-place"
mkdir -p "$RD_ROOT"
"$ROOT/scripts/place-managed-file.sh" --root "$RD_ROOT" --path .claude/commands/review.md --path .agents/skills/review/SKILL.md >/dev/null
cmp -s "$TEST_TMP/render-claude" "$RD_ROOT/.claude/commands/review.md" || fail "the placer writes the rendered command"
cmp -s "$TEST_TMP/render-codex" "$RD_ROOT/.agents/skills/review/SKILL.md" || fail "the placer writes the rendered Codex skill"
[[ ! -x "$RD_ROOT/.claude/commands/review.md" ]] || fail "a rendered file is not executable"
# render와 copy를 한 호출에 섞어도(순서와 상관없이) 각 파일이 제 내용을 받는다.
for rd_order in render-first copy-first; do
  RD_MIX="$TEST_TMP/render-mix-$rd_order"
  mkdir -p "$RD_MIX"
  if [[ "$rd_order" == render-first ]]; then
    "$ROOT/scripts/place-managed-file.sh" --root "$RD_MIX" --path .claude/commands/review.md --path .ai-harness/workflows/review-graph.json >/dev/null
  else
    "$ROOT/scripts/place-managed-file.sh" --root "$RD_MIX" --path .ai-harness/workflows/review-graph.json --path .claude/commands/review.md >/dev/null
  fi
  cmp -s "$TEST_TMP/render-claude" "$RD_MIX/.claude/commands/review.md" || fail "mixed placement ($rd_order) writes the rendered command"
  cmp -s "$ROOT/templates/review/references/review-graph.json" "$RD_MIX/.ai-harness/workflows/review-graph.json" || fail "mixed placement ($rd_order) copies the graph"
  [[ -z "$(find "$RD_MIX" -name '.place.*')" ]] || fail "mixed placement ($rd_order) leaves no temporary files"
done
printf 'old\n' >"$RD_ROOT/.claude/commands/review.md"
mkdir -p "$RD_ROOT/.ai-harness"
jq -n --arg h "$(mf_sha "$RD_ROOT/.claude/commands/review.md")" '{managed_files: {".claude/commands/review.md": {content_sha256: $h}}}' >"$RD_ROOT/.ai-harness/harness.json"
# 표시 없는 기록(예전 손 렌더)은 해시가 맞아도 저장소 맞춤이 있을 수 있어 사람이 본 뒤(--first-render)에만 바꾼다(#316).
mf_refuse "first deterministic render needs a person" "$RD_ROOT" .claude/commands/review.md
assert_eq "old" "$(<"$RD_ROOT/.claude/commands/review.md")" "an unmarked hand render is not overwritten without review"
"$ROOT/scripts/place-managed-file.sh" --root "$RD_ROOT" --path .claude/commands/review.md --first-render >/dev/null
cmp -s "$TEST_TMP/render-claude" "$RD_ROOT/.claude/commands/review.md" || fail "a reviewed first render replaces the hand render"
# record는 스크립트 결과와 같은 render에만 표시를 남기고, 표시가 있으면 다음 sync는 그냥 갱신한다.
"$ROOT/scripts/harness-sync-state.sh" record --root "$RD_ROOT" --version 9.9.9 --file .claude/commands/review.md
assert_eq "1" "$(jq -r '.managed_files[".claude/commands/review.md"].renderer' "$RD_ROOT/.ai-harness/harness.json")" "record marks a deterministic render"
printf 'old\n' >"$RD_ROOT/.claude/commands/review.md"
"$ROOT/scripts/harness-sync-state.sh" record --root "$RD_ROOT" --version 9.9.9 --file .claude/commands/review.md
assert_eq "null" "$(jq -r '.managed_files[".claude/commands/review.md"].renderer' "$RD_ROOT/.ai-harness/harness.json")" "record does not mark a render that differs from the script"
jq --arg h "$(mf_sha "$RD_ROOT/.claude/commands/review.md")" '.managed_files[".claude/commands/review.md"] = {content_sha256: $h, renderer: 1}' "$RD_ROOT/.ai-harness/harness.json" >"$RD_ROOT/.ai-harness/h2" && mv "$RD_ROOT/.ai-harness/h2" "$RD_ROOT/.ai-harness/harness.json"
"$ROOT/scripts/place-managed-file.sh" --root "$RD_ROOT" --path .claude/commands/review.md >/dev/null
cmp -s "$TEST_TMP/render-claude" "$RD_ROOT/.claude/commands/review.md" || fail "an unchanged marked render is refreshed"
rd_rc=0; "$ROOT/scripts/place-managed-file.sh" --root "$RD_ROOT" --path >/dev/null 2>&1 || rd_rc=$?
assert_eq "2" "$rd_rc" "place-managed-file exits 2 on --path without a value"
rd_rc=0; "$ROOT/scripts/render-managed-file.sh" --path >/dev/null 2>&1 || rd_rc=$?
assert_eq "2" "$rd_rc" "render-managed-file exits 2 on --path without a value"
printf 'team wording\n' >>"$RD_ROOT/.claude/commands/review.md"
mf_refuse "modified since it was recorded" "$RD_ROOT" .claude/commands/review.md
assert_contains "$(<"$RD_ROOT/.claude/commands/review.md")" "team wording" "a render a person changed is not overwritten"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
[[ "$(<"$ROOT/skills/harness-init/SKILL.md")" != *'`mode:"render"` 항목만 직접 쓴다'* ]] || fail "harness init no longer writes render artifacts by hand"
pass "workflow entry points render deterministically"

# 편집 가드 예시는 Read 도구 호출만 '읽음'으로 인정한다 — 문서를 Edit·Write만 한 세션이 transcript 문자열 grep으로 통과하던 문제(#372).
DG="$TEST_TMP/direct-guard"
DG_GUARD="$ROOT/skills/harness-init/references/direct-edit-guard.sh"
assert_file "$DG_GUARD"
mkdir -p "$DG/repo/.ai-harness/docs" "$DG/repo/src/main" "$DG/repo/src/test" "$DG/t/sess/subagents"
git -C "$DG/repo" init -q
DGR="$(git -C "$DG/repo" rev-parse --show-toplevel)"
DG_CONV="$DGR/.ai-harness/docs/code-conventions.md"
DG_TEST="$DGR/.ai-harness/docs/testing.md"
DG_N=0
dg_call() { # $1=tool name, $2=input json, [$3=is_error] -> tool_use 줄과 짝 tool_result 줄
  DG_N=$((DG_N + 1))
  jq -cn --arg n "$1" --argjson i "$2" --arg id "t$DG_N" '{type:"assistant",message:{content:[{type:"tool_use",id:$id,name:$n,input:$i}]}}'
  jq -cn --arg id "t$DG_N" --arg e "${3:-false}" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,is_error:($e=="true"),content:"x"}]}}'
}
dg_line() { # $1=tool name, $2=file_path, [$3=is_error]
  dg_call "$1" "$(jq -cn --arg f "$2" '{file_path:$f}')" "${3:-false}"
}
dg_bash() { # $1=command, [$2=is_error]
  dg_call Bash "$(jq -cn --arg c "$1" '{command:$c}')" "${2:-false}"
}
dg_codex() { # $1=command, $2=exit code
  DG_N=$((DG_N + 1))
  jq -cn --arg c "$1" --arg id "c$DG_N" '{type:"response_item",payload:{type:"function_call",name:"exec_command",call_id:$id,arguments:({cmd:$c}|tojson)}}'
  jq -cn --arg id "c$DG_N" --arg x "$2" '{type:"response_item",payload:{type:"function_call_output",call_id:$id,output:("Process exited with code " + $x + "\nOutput:\n")}}'
}
: >"$DG/t/none.jsonl"
{ dg_line Write "$DG_CONV"; dg_line Edit "$DG_CONV"; dg_line MultiEdit "$DG_CONV"; } >"$DG/t/write.jsonl"
dg_line Read "$DG_CONV" >"$DG/t/read.jsonl"
dg_line Read "$DG_CONV" true >"$DG/t/read-failed.jsonl"
jq -cn --arg f "$DG_CONV" '{type:"assistant",message:{content:[{type:"tool_use",id:"t0",name:"Read",input:{file_path:$f}}]}}' >"$DG/t/read-no-result.jsonl"
{ dg_line Read "$DG_CONV"; dg_line Write "$DG_TEST"; } >"$DG/t/read-conv-write-test.jsonl"
{ dg_line Read "$DG_CONV"; dg_line Read "$DG_TEST"; } >"$DG/t/read-both.jsonl"
printf '{"type":"user","message":{"content":"please check \\"file_path\\":\\"%s\\""}}\n' "$DG_CONV" >"$DG/t/mention.jsonl"
dg_bash "cat $DG_CONV" >"$DG/t/bash-cat.jsonl"
dg_bash "cat $DG_CONV" true >"$DG/t/bash-cat-failed.jsonl"
dg_bash "sed -n '1,80p' .ai-harness/docs/code-conventions.md" >"$DG/t/bash-sed.jsonl"
dg_bash "grep -rn .ai-harness/docs/code-conventions.md scripts" >"$DG/t/bash-grep-pattern.jsonl"
dg_bash "grep -n rule .ai-harness/docs/code-conventions.md" >"$DG/t/bash-grep-file.jsonl"
{ dg_bash "sed -n 'w .ai-harness/docs/code-conventions.md' README.md"; dg_bash "sed -n 's/a/b/gw .ai-harness/docs/code-conventions.md' README.md"; } >"$DG/t/bash-sed-w.jsonl"
{ dg_bash "grep -e .ai-harness/docs/code-conventions.md scripts"; dg_bash "grep -A 3 .ai-harness/docs/code-conventions.md scripts"; } >>"$DG/t/bash-grep-pattern.jsonl"
jq -cn '{type:"response_item",payload:{type:"function_call",name:"exec_command",call_id:"cb",arguments:({cmd:"cat .ai-harness/docs/code-conventions.md"}|tojson)}}' >"$DG/t/codex-read-body.jsonl"
jq -cn '{type:"response_item",payload:{type:"function_call_output",call_id:"cb",output:"Process exited with code 0\nOutput:\nfoo exited with code 1\n"}}' >>"$DG/t/codex-read-body.jsonl"
dg_bash "cat code-conventions.md" | jq -c --arg d "$DGR/.ai-harness/docs" 'if .type == "assistant" then . + {cwd: $d} else . end' >"$DG/t/bash-row-cwd.jsonl"
{ dg_bash "cat > $DG_CONV <<'X'"; dg_bash "echo x | tee $DG_CONV"; dg_bash "sed -i '' 's/a/b/' $DG_CONV"; dg_bash "git add $DG_CONV"; dg_bash "cat $DG_CONV && git add $DG_CONV"; } >"$DG/t/bash-write.jsonl"
dg_codex "sed -n '1,200p' .ai-harness/docs/code-conventions.md" 0 >"$DG/t/codex-read.jsonl"
dg_codex "sed -n '1,200p' .ai-harness/docs/code-conventions.md" 1 >"$DG/t/codex-read-failed.jsonl"
dg_codex "cat > .ai-harness/docs/code-conventions.md <<'X'" 0 >"$DG/t/codex-write.jsonl"
cp "$DG/t/none.jsonl" "$DG/t/sess.jsonl"
dg_line Read "$DG_CONV" >"$DG/t/sess/subagents/agent-a1.jsonl"
direct_guard() { # $1=edited file, $2=transcript, [$3=agent_id, $4=tool] -> exit code; stderr to $DG/err
  jq -cn --arg cwd "$DGR" --arg f "$1" --arg t "$2" --arg a "${3:-}" --arg n "${4:-Edit}" \
    '{tool_name:$n, cwd:$cwd, transcript_path:$t, tool_input:{file_path:$f}} + (if $a=="" then {} else {agent_id:$a} end)' \
    | bash "$DG_GUARD" 2>"$DG/err" >/dev/null && echo 0 || echo $?
}
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/none.jsonl")" "edit without reading the conventions is blocked"
assert_eq "[Direct edit guard] " "$(head -1 "$DG/err" | cut -c1-20)" "block message starts with the counted guard prefix"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/write.jsonl")" "writing the conventions with Write/Edit/MultiEdit is not reading them"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/mention.jsonl")" "a file_path string inside a user message is not a read"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/read.jsonl")" "reading the conventions with Read lets the edit through"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/read.jsonl" "" Write)" "Write of a source file passes after Read"
assert_eq "2" "$(direct_guard "$DGR/src/test/AppTest.java" "$DG/t/read-conv-write-test.jsonl")" "a test edit also needs testing.md read, and writing it does not count"
assert_eq "0" "$(direct_guard "$DGR/src/test/AppTest.java" "$DG/t/read-both.jsonl")" "a test edit passes after reading both docs"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/codex-read.jsonl")" "a Codex read-only shell command counts as reading"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/read-failed.jsonl")" "a Read that failed is not reading"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/read-no-result.jsonl")" "a Read without a result is not reading"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/bash-cat.jsonl")" "a successful Bash cat of the doc counts as reading"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/bash-sed.jsonl")" "a successful Bash sed -n with a relative path counts as reading"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/bash-grep-pattern.jsonl")" "a grep that only searches for the doc path is not reading"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/bash-grep-file.jsonl")" "a grep over the doc counts as reading"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/bash-sed-w.jsonl")" "a sed script that writes the doc is not reading"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/bash-row-cwd.jsonl")" "a Bash relative path resolves against that row's cwd"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/bash-cat-failed.jsonl")" "a failed Bash cat is not reading"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/bash-write.jsonl")" "Bash commands that write or stage the doc are not reading"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/codex-read-body.jsonl")" "a failure phrase inside the read doc's text does not fail the read"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/codex-read-failed.jsonl")" "a Codex read that exited non-zero is not reading"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/codex-write.jsonl")" "a Codex shell command that writes the doc is not reading it"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/sess.jsonl" a1)" "a subagent's own Read in its transcript counts"
assert_eq "2" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/sess.jsonl" a2)" "another subagent's Read does not count"
assert_eq "0" "$(direct_guard "$DGR/src/main/App.java" "$DG/t/missing.jsonl")" "an unreadable transcript fails open"
assert_eq "0" "$(direct_guard "$DGR/.ai-harness/docs/domain.md" "$DG/t/none.jsonl")" "harness documents are not guarded"
assert_eq "0" "$(direct_guard "$DGR/README.md" "$DG/t/none.jsonl")" "files outside source paths are not guarded"
assert_eq "0" "$(jq -cn '{tool_name:"Bash", cwd:"/", tool_input:{command:"ls"}}' | bash "$DG_GUARD" >/dev/null 2>&1 && echo 0 || echo $?)" "non-edit tools pass"
assert_eq "0" "$(grep -v '^[[:space:]]*#' "$DG_GUARD" | grep -c -E '(^|[|;&(])[[:space:]]*grep[[:space:]]' || true)" "the example guard parses the transcript with jq instead of grepping it"
pass "direct edit guard counts only successful reads as reading"

# 화면 검증 서버 수명: dev 서버를 nohup &로 띄우고 포트로 끄면 워커가 고아로 남아 수 GB를 쥔다(실측). 계약과 러너가
# 운영 빌드 우선·백그라운드 실행·재사용·그룹 종료 확인을 지시한다. (#435)
UIR_CONTENT="$(<"$ROOT/templates/ui-review/SKILL.md")"
assert_contains "$UIR_CONTENT" "## 앱 서버 수명" "ui-review has a server lifecycle section"
assert_contains "$UIR_CONTENT" "운영 빌드" "ui-review prefers a production build for one-shot review"
assert_contains "$UIR_CONTENT" "백그라운드 실행" "ui-review starts servers with the tool's background run"
assert_contains "$UIR_CONTENT" "이미 떠 있는 서버" "ui-review reuses a running server"
assert_contains "$UIR_CONTENT" "프로세스 그룹" "ui-review stops the whole process group"
assert_contains "$UIR_CONTENT" "포트가 비었다는 것만으로" "ui-review does not treat a free port as stopped"
DRIVER_SRC="$(<"$ROOT/templates/workflow-driver/workflow-driver.sh")"
# 어느 노드 프롬프트가 어느 규칙을 쓰는지: 직전 "You are the <node> node" 기준으로 묶는다.
rule_nodes() { awk -v rule="\$$1" 'match($0, /You are the [a-z_]+ node/) { node = substr($0, RSTART + 12, RLENGTH - 17) } $0 == rule { print node }' "$ROOT/templates/workflow-driver/workflow-driver.sh" | sort | paste -sd' ' -; }
assert_eq "measure reproduce ui_review" "$(rule_nodes APP_SERVER_RULE)" "measure, reproduce, and ui_review prompts carry the server lifecycle rule"
assert_eq "measure ui_review" "$(rule_nodes APP_BUILD_RULE)" "only the one-shot render prompts prefer a production build"
assert_contains "$DRIVER_SRC" "the tool's background run, not with &, nohup, or setsid" "the runner rule starts servers in the background run"
assert_contains "$DRIVER_SRC" "Reuse a server already running for this working tree" "the runner rule reuses a running server"
assert_contains "$DRIVER_SRC" "stop the whole process group" "the runner rule stops the process group"
assert_contains "$DRIVER_SRC" "a free port does not mean it stopped" "the runner rule does not trust a free port"
assert_contains "$DRIVER_SRC" "prefer the project's production build" "the runner rule prefers a production build"
assert_contains "$DRIVER_SRC" "keep build output in ignored paths" "the runner keeps build output out of the change check"
pass "ui review server lifecycle"

# 편집 가드는 경로를 유니코드 정규화 없이 비교하면 macOS에서 NFD 폴더의 저장소를 저장소 밖으로 오판해 통과시킨다(#479).
# git은 NFD를, bash 3.2의 cd/pwd -P는 입력 형태(NFC)를 그대로 돌려준다.
NF_NFC="$(printf '\355\224\204\353\241\234\354\240\235\355\212\270')"
NF_NFD="$(printf '\341\204\221\341\205\263\341\204\205\341\205\251\341\204\214\341\205\246\341\206\250\341\204\220\341\205\263')"
NF="$TEST_TMP/direct-guard-nfd"
mkdir -p "$NF/$NF_NFD/src" "$NF/$NF_NFD/.ai-harness/docs" "$NF/t"
git -C "$NF/$NF_NFD" init -q
NF_ROOT="$(git -C "$NF/$NF_NFD" rev-parse --show-toplevel)"
NF_NFC_ROOT="$NF/$NF_NFC"
NF_NFD_ROOT="$NF/$NF_NFD"
: >"$NF_NFD_ROOT/.ai-harness/docs/code-conventions.md"
: >"$NF/t/none.jsonl"
dg_line Read "$NF_NFC_ROOT/.ai-harness/docs/code-conventions.md" >"$NF/t/read-nfc.jsonl"
nf_guard() { # $1=edited file, $2=transcript, [$3=PATH 재정의] -> exit code
  local guard_bash rc=0
  guard_bash="$(command -v bash)"
  jq -cn --arg cwd "$NF_ROOT" --arg f "$1" --arg t "$2" \
    '{tool_name:"Edit", cwd:$cwd, transcript_path:$t, tool_input:{file_path:$f}}' \
    | PATH="${3:-$PATH}" "$guard_bash" "$DG_GUARD" 2>"$NF/err" >/dev/null || rc=$?
  echo "$rc"
}
assert_eq "2" "$(nf_guard "$NF_NFC_ROOT/src/a.sh" "$NF/t/none.jsonl")" "NFC edit path in an NFD-named repo is still guarded when the conventions were not read"
assert_eq "0" "$(nf_guard "$NF_NFC_ROOT/src/a.sh" "$NF/t/read-nfc.jsonl")" "NFC edit path passes after reading the conventions by NFC path"
assert_eq "2" "$(nf_guard "$NF_NFD_ROOT/src/a.sh" "$NF/t/none.jsonl")" "NFD edit path is guarded when the conventions were not read"
assert_eq "0" "$(nf_guard "$NF_NFD_ROOT/src/a.sh" "$NF/t/read-nfc.jsonl")" "NFD edit path passes after reading the conventions by NFC path"
# python3가 없으면 정규화 못 하고 원래 값으로 비교한다 — NFC 입력은 예전처럼 통과(fail-open), NFD 입력은 막는다.
# macOS의 /usr/bin/python3는 스텁이라 PATH에서 디렉토리를 빼는 것으로는 부족하다. 가드가 쓰는 명령만 링크한 PATH를 쓴다.
NF_BIN="$TEST_TMP/nopy"
mkdir -p "$NF_BIN"
for nf_cmd in jq git cat dirname basename; do
  ln -sf "$(command -v "$nf_cmd")" "$NF_BIN/$nf_cmd"
done
assert_eq "0" "$(nf_guard "$NF_NFC_ROOT/src/a.sh" "$NF/t/none.jsonl" "$NF_BIN")" "without python3 an NFC edit path keeps the old fail-open verdict"
assert_eq "2" "$(nf_guard "$NF_NFD_ROOT/src/a.sh" "$NF/t/none.jsonl" "$NF_BIN")" "without python3 an NFD edit path is still guarded"
pass "direct edit guard compares paths across unicode normalization"

# 릴리스 방식 감지(#493): harness-init이 태그 방식 근거를 보고 manifest release_policy에 근거와 확장점을 남기고, sync가 사람 확인 뒤에만 쓴다.
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for phrase in '**릴리스 방식 감지**' '`git ls-remote --tags origin`' '`CHANGELOG.md`에 버전 절' 'flow:"unknown"' '`evidence`에 문장으로' \
  '`release_policy`: §1 릴리스 방식 감지 결과' '"branch_prefix": "release/v"' '"record_cmds": ["<기록 명령>"]' '릴리스 병합 기준은 `release_policy.base`' \
  '**릴리스 방식** (manifest 정책 필드 — **사람 확인 뒤에만** 쓴다)' '팀 전용 도구 이름은 템플릿·예시에 넣지 않고'; do
  assert_contains "$HARNESS_INIT_CONTENT" "$phrase" "harness-init release detection: $phrase"
done
pass "harness-init detects tag-based releases into release_policy"

# 데이터 접근 계층이 있는 프로젝트는 측정으로 검증된 대량 조회 메모리 규칙을 실측 원칙의 예외로 받는다. (#499)
for phrase in "대량 조회 메모리" "검증된 기본 규칙" "projection 조회" "건수 상한 × 행 크기" "판정·집계용 읽기 경로" "호출부가 diff 안이면 제외하지 않는다" "딸려 오는 엔티티·테이블의 컬럼 정의"; do
  assert_contains "$HARNESS_INIT_CONTENT" "$phrase" "harness-init bulk read rule: $phrase"
done
pass "harness-init writes the bulk read memory rule for projects with data access"

# design-audit가 축 A에서 여백 관계와 묶기를 잰다. 규칙 문서에 하위 절이 없으면 감점하지 않고 규칙 결정 필요로 올리고,
# 소스로 못 정하는 여백은 렌더 확인으로 보낸다. 사본 세 곳과 harness.json hash도 맞춘다. (#514)
SR_AUDIT="$(<"$ROOT/templates/design-audit/SKILL.md")"
for phrase in "여백 관계와 묶기는 축 A에서 잰다" "관계에 맞지 않는 단계" "안쪽이 바깥쪽보다 크거나 같은 역전" "중첩 한도" "하위 절이 없으면 감점하지 않고"; do
  assert_contains "$SR_AUDIT" "$phrase" "design-audit spacing and grouping: $phrase"
done
SR_PARA="$(awk '/^\*\*여백 관계와 묶기는 축 A에서 잰다/{f=1} f&&/^$/{exit} f' "$ROOT/templates/design-audit/SKILL.md")"
assert_contains "$SR_PARA" "렌더 확인 필요" "design-audit sends unresolvable spacing to render check"
assert_contains "$SR_PARA" "규칙 결정 필요" "design-audit holds missing subsections as rule decisions"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
SR_AROW="$(grep '^| A\. 골격·위계 | 30 | `## 레이아웃`:' "$ROOT/templates/design-audit/SKILL.md")"
assert_contains "$SR_AROW" "여백 관계" "design-audit axis A row names spacing relationships"
for SR_COPY in skills/design-screen/references/design-audit.md .claude/skills/design-audit/SKILL.md .agents/skills/design-audit/SKILL.md; do
  cmp -s "$ROOT/$SR_COPY" "$ROOT/templates/design-audit/SKILL.md" || fail "$SR_COPY must match templates/design-audit/SKILL.md byte for byte"
done
for SR_COPY in .claude/skills/design-audit/SKILL.md .agents/skills/design-audit/SKILL.md; do
  SR_SUM="$( (shasum -a 256 "$ROOT/$SR_COPY" 2>/dev/null || sha256sum "$ROOT/$SR_COPY") | cut -d' ' -f1)"
  assert_eq "$SR_SUM" "$(jq -r --arg p "$SR_COPY" '.managed_files[$p].content_sha256' "$ROOT/.ai-harness/harness.json")" "harness.json records the current hash of $SR_COPY"
done
pass "design-audit scores spacing relationships and grouping under axis A and its copies stay in sync"

# design-audit 축 E는 `## 원칙`의 `### 서비스`(성격·피할 것)를 톤 근거로 함께 읽는다(#514). 문구 규칙 원본이 ux-writing.md면
# 말투·어미·용어·금지어는 ux-writing-audit로 넘기고 E는 정직성과 서비스 톤 일관성만 잰다. 가리키기 형태 `## 문구`는
# 절 없음이 아니고, 두 문서가 다 가득하면 감점 없이 규칙 결정으로 올린다. (#516)
SV_AUDIT_FILE="$ROOT/templates/design-audit/SKILL.md"
SV_AUDIT="$(<"$SV_AUDIT_FILE")"
SV_EREAD="$(grep '^   | E\. 톤·정직성 |' "$SV_AUDIT_FILE")"
assert_contains "$SV_EREAD" "### 서비스" "design-audit axis E reads the service section"
assert_contains "$(grep '^| E\. 톤·정직성 | 15 |' "$SV_AUDIT_FILE")" "### 서비스" "design-audit axis E score row names the service section"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
for phrase in '`### 서비스`가 없으면 지금처럼 `## 문구`만으로 잰다' '`원본: <경로>`' '절 없음으로 보지 않는다' '말투·어미·용어·금지어' \
  '`ux-writing-audit`로 넘긴다' 'E는 정직성과 `### 서비스` 톤 일관성만' '규칙 결정 필요: 문구 규칙 중복' '`ux-writing-audit`의 감지 규칙'; do
  assert_contains "$SV_AUDIT" "$phrase" "design-audit axis E copy source: $phrase"
done
pass "design-audit axis E reads the service section and hands copy style to ux-writing-audit"

# deliver·repair 노드가 전체 회귀를 백그라운드로 띄우고 답을 끝내면 러너 검사와 겹치거나 테스트가 죽는다. 공용 규칙으로
# 전체 회귀는 러너가 돌리고 노드는 바뀐 영역만 포그라운드로 돌리게 지시한다. (#534)
assert_eq "deliver repair" "$(rule_nodes NODE_TEST_RULE)" "deliver and repair prompts carry the node test rule"
NTR_LINE="$(grep '^NODE_TEST_RULE=' "$ROOT/templates/workflow-driver/workflow-driver.sh" || true)"
assert_contains "$NTR_LINE" "foreground" "the node test rule runs changed-area tests in the foreground"
assert_contains "$NTR_LINE" "background" "the node test rule forbids leaving tests in the background"
assert_contains "$NTR_LINE" "tests/run.sh <area>" "the node test rule names the per-area test command"
NTR_REPAIR="$(awk '/You are the repair node/ { on = 1 } on { print } on && /brief_context/ { exit }' "$ROOT/templates/workflow-driver/workflow-driver.sh")"
assert_contains "$NTR_REPAIR" "the driver itself runs these checks" "the repair prompt tells which checks the driver runs afterwards"
pass "deliver and repair prompts say who runs the broad regression"

# 디자인 스킬 지도는 Terms 절에서 디자인 용어 8개를 한 줄 정의와 담당 스킬 하나로 정한다(#514).
# 기존 제품 화면 다듬기는 design-polish가 주도하고 impeccable은 비평 보조로 남으며, 랜딩 보조에 design-references가 있다.
TM_SRC="$ROOT/templates/ui-review/references/design-skills.md"
TM_ROWS="$(awk '/^## Terms/{f=1;next} /^## /{f=0} f && /^\| / && !/^\| Term/ && !/^\|---/' "$TM_SRC")"
assert_eq "8" "$(grep -c . <<<"$TM_ROWS")" "map Terms lists eight terms"
for TM_PAIR in '디자인 시스템 (design system)=design-system-builder' '규칙 문서 (rule document)=design-system-builder' \
  '기준 화면 (reference screen)=design-system-builder' '형제 화면 (sibling screen)=design-audit' '채점 (audit)=design-audit' \
  '검토 (review)=ui-review' '비평 (critique)=ai-harness:design-reviewer' '다듬기 (polish)=design-polish'; do
  TM_TERM="${TM_PAIR%%=*}"
  TM_OWNER="${TM_PAIR#*=}"
  assert_eq "1" "$(grep -cF "| $TM_TERM |" <<<"$TM_ROWS")" "map Terms defines $TM_TERM once"
  TM_CELL="$(grep -F "| $TM_TERM |" <<<"$TM_ROWS" | awk -F'|' '{print $4}')"
  assert_contains "$TM_CELL" "\`$TM_OWNER\`" "map Terms owner of $TM_TERM"
done
TM_JOBS="$(awk '/^## Jobs/{f=1;next} /^## /{f=0} f && /^\| / && !/^\| Job/ && !/^\|---/' "$TM_SRC")"
TM_POLISH="$(grep '^| Polish an existing product screen |' <<<"$TM_JOBS")"
assert_eq " \`design-polish\` " "$(awk -F'|' '{print $3}' <<<"$TM_POLISH")" "design-polish leads polishing an existing product screen"
TM_POLISH_SUP="$(awk -F'|' '{print $4}' <<<"$TM_POLISH")"
assert_contains "$TM_POLISH_SUP" "\`impeccable\`" "impeccable supports polishing"
assert_contains "$TM_POLISH_SUP" "critique" "impeccable supports polishing with critique only"
assert_contains "$(grep '^| Landing, ' <<<"$TM_JOBS" | awk -F'|' '{print $4}')" "\`design-references\`" "design-references supports landing pages"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 찾는다
if grep -qF 'on a product screen `impeccable` leads' "$TM_SRC"; then fail "map still says impeccable leads every product screen"; fi
for TM_COPY in skills/landing-page/references/design-skills.md skills/design-system-builder/references/design-skills.md \
  .claude/skills/ui-review/references/design-skills.md .agents/skills/ui-review/references/design-skills.md \
  .claude/skills/design-audit/references/design-skills.md .agents/skills/design-audit/references/design-skills.md; do
  cmp -s "$ROOT/$TM_COPY" "$TM_SRC" || fail "$TM_COPY must match templates/ui-review/references/design-skills.md byte for byte"
done
TM_README="$(grep '^| 제품 화면 다듬기 |' "$ROOT/README.md")"
assert_contains "$TM_README" "| \`/design-polish\` |" "README polish row is led by /design-polish"
assert_contains "$TM_README" "\`impeccable\`(비평)" "README polish row keeps impeccable as critique"
assert_contains "$(grep '^| 랜딩·소개 |' "$ROOT/README.md")" "\`design-references\`" "README landing row lists design-references"
pass "design skill map defines design terms and design-polish leads polishing (#514)"

finish_tests
