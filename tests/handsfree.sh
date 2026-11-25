#!/usr/bin/env bash
# 회귀 테스트 — 음성 입력 스킬 handsfree(scripts/handsfree)와 상태 화면 handsfree-ui
# 실행: bash tests/run.sh handsfree
# 마이크·whisper·Orca 없이 돈다. 분류·판단 흐름·설정 검증은 tests/handsfree/test_*.py(표준 unittest, 가짜 Orca)가 맡고,
# 여기서는 그것을 임시 데이터 폴더로 돌린 뒤 settings.json 을 고치는 CLI(hooks·statusline·unhook)를 실제로 실행해 본다.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HF="$ROOT/scripts/handsfree"
HF_DATA="$TEST_TMP/handsfree-data"
mkdir -p "$HF_DATA"

# 분류(호출어·명령·숫자·별명), 판단 흐름(입력 칸 확인·승인 창·위험 명령·긴 말 모드), 설정 검증과 잠금
for unit in test_router test_listener test_settings; do
  if ! out="$(HM_DATA_DIR="$HF_DATA" python3 "$ROOT/tests/handsfree/$unit.py" 2>&1)"; then
    printf '%s\n' "$out" >&2
    fail "handsfree $unit"
  fi
done
pass "handsfree routing, listener decisions, and settings validation"

# 훅·상태 표시줄은 고정 경로의 연결 스크립트로 넣는다. 플러그인 업데이트로 설치 경로가 바뀌어도 끊기지 않게.
HF_SETTINGS="$TEST_TMP/claude-settings.json"
jq -n '{hooks:{Stop:[{hooks:[{type:"command",command:"other-tool"}]}]}, statusLine:{type:"command",command:"echo base-line"}}' >"$HF_SETTINGS"
hf() { HM_DATA_DIR="$HF_DATA" HANDSFREE_CLAUDE_SETTINGS="$HF_SETTINGS" python3 "$HF/handsfree" "$@"; }

hf hooks >/dev/null
SHIM="$HF_DATA/handsfree/bin/speak"
[[ -x "$SHIM" ]] || fail "handsfree hooks writes an executable speak shim"
for event in Stop PermissionRequest Notification UserPromptSubmit; do
  assert_eq "1" "$(jq --arg e "$event" --arg c "$SHIM" '[.hooks[$e][]?.hooks[]? | select(.command == $c)] | length' "$HF_SETTINGS")" "hook for $event is added once"
done
hf hooks >/dev/null
assert_eq "1" "$(jq --arg c "$SHIM" '[.hooks.Stop[]?.hooks[]? | select(.command == $c)] | length' "$HF_SETTINGS")" "hooks is idempotent"
assert_eq "other-tool" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$HF_SETTINGS")" "other hooks are kept"
# 듣기가 꺼져 있으면 훅은 아무것도 출력하지 않고 끝난다 — 권한 결정으로 읽히면 안 된다.
assert_eq "" "$(printf '{"hook_event_name":"Stop"}' | HM_DATA_DIR="$HF_DATA" "$SHIM")" "speak hook is silent when the listener is off"
pass "handsfree hooks install through a stable shim, once, and stay silent"

hf statusline >/dev/null
assert_eq "$HF_DATA/handsfree/bin/statusline" "$(jq -r '.statusLine.command' "$HF_SETTINGS")" "statusline points at the shim"
assert_eq "echo base-line" "$(<"$HF_DATA/handsfree/statusline.orig")" "original statusline command is kept"
assert_eq "base-line" "$(printf '{}' | HM_DATA_DIR="$HF_DATA" "$HF_DATA/handsfree/bin/statusline")" "statusline shows the original line when not listening"
hf unhook >/dev/null
assert_eq "echo base-line" "$(jq -r '.statusLine.command' "$HF_SETTINGS")" "unhook restores the original statusline"
assert_eq "0" "$(jq --arg c "$SHIM" '[.hooks[]?[]?.hooks[]? | select(.command == $c)] | length' "$HF_SETTINGS")" "unhook removes handsfree hooks"
assert_eq "other-tool" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$HF_SETTINGS")" "unhook keeps other hooks"
pass "handsfree statusline wraps the original and unhook restores settings"

# 스킬 두 개가 Claude·Codex 양쪽에 노출되고, 안내 화면·README에 실린다.
for skill in handsfree handsfree-ui; do
  assert_file "$ROOT/skills/$skill/SKILL.md"
  assert_file "$ROOT/skills/$skill/agents/openai.yaml"
  assert_contains "$(<"$ROOT/README.md")" "| \`/$skill\` |" "README lists $skill"
  assert_contains "$(<"$ROOT/scripts/board/guide.json")" "\"skills/$skill\"" "board guide lists $skill"
done
pass "handsfree skills are published for both hosts and documented"

finish_tests
