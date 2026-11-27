#!/usr/bin/env bash
# 회귀 테스트 — 편집·조회 가드, 훅 기반 스케줄, 위임 대기, 규칙 품질
# 실행: bash tests/run.sh automation-guards
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 무인 실행 스텁(automation.sh의 자동 harvest 블록과 같은 것): 스케줄 tick 블록이 쓴다.
AUTO_STUB="$TEST_TMP/auto-stub.sh"
cat >"$AUTO_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "${HM_HARVEST_RUNNING:-}" "$(pwd -P)" >>"$AUTO_STUB_OUT"
case "${AUTO_STUB_MODE:-}" in
  improve)
    # mark-reviewed가 남기는 review-history 레코드 형태
    mkdir -p "$HARNESS_METRICS_DIR/harvest-queue/p-$1"
    jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{reviewed_at:$at,review:{outcome:"improved",artifact:"https://example.com/pr/1"}}' \
      >>"$HARNESS_METRICS_DIR/harvest-queue/p-$1/review-history.jsonl"
    ;;
  fail) exit 3 ;;
  cost) echo "Ignoring 19 permissions.allow entries: workspace not trusted" >&2; echo '{"type":"result","total_cost_usd":0.12}' ;;
  limit) echo '{"type":"result","is_error":true,"api_error_status":429,"api_error":"usage_limit_reached","total_cost_usd":0}'; exit 1 ;;
esac
STUB
chmod +x "$AUTO_STUB"

# 플러그인 편집 가드: 세션이 열린 곳과 다른 하네스 저장소의 코드 편집은 워크플로를 읽었어도 모델이 혼자 진행하지 못한다.
# 기본은 사용자 확인(permissionDecision: ask)이고, HM_MEMBER_GUARD=block이면 예전처럼 막고 멤버 세션으로 인계하게 한다.
assert_contains "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("member-edit-guard")) | .hooks[0].command' "$ROOT/hooks/hooks.json")" "scripts/member-edit-guard.sh" "PreToolUse hook runs the member edit guard"
assert_eq "Edit|Write|MultiEdit|NotebookEdit" "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("member-edit-guard")) | .matcher' "$ROOT/hooks/hooks.json")" "member edit guard matches Claude edit tools"
assert_eq "3" "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("member-edit-guard")) | .hooks[0].timeout' "$ROOT/hooks/hooks.json")" "member edit guard stays inside a short budget"
GW="$TEST_TMP/guard-ws"
mkdir -p "$GW/acme/.ai-harness/workflows" "$GW/acme/src/main" "$GW/worktrees/NJ-1/acme/.ai-harness/workflows" "$GW/worktrees/NJ-1/acme/src/main" "$GW/plain/src/main" "$GW/t/sess"
git -C "$GW/acme" init -q
printf '{"project_id":"acme"}\n' >"$GW/acme/.ai-harness/harness.json"
printf '{"project_id":"acme"}\n' >"$GW/worktrees/NJ-1/acme/.ai-harness/harness.json"
touch "$GW/acme/.ai-harness/workflows/implement-feature.md" "$GW/worktrees/NJ-1/acme/.ai-harness/workflows/implement-feature.md"
guard_line() { # $1=tool name, $2=input json
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"%s","input":%s}]}}\n' "$1" "$2"
}
: >"$GW/t/none.jsonl"
guard_line Read "{\"file_path\":\"$GW/acme/.ai-harness/workflows/implement-feature.md\"}" >"$GW/t/read.jsonl"
guard_line Bash '{"command":"cd acme && sed -n 1,80p .ai-harness/workflows/implement-feature.md"}' >"$GW/t/cd.jsonl"
guard_line Bash '{"command":"cat worktrees/NJ-1/acme/.ai-harness/workflows/implement-feature.md"}' >"$GW/t/wt.jsonl"
cp "$GW/t/read.jsonl" "$GW/t/sess.jsonl"
mkdir -p "$GW/t/sess/subagents"
cp "$GW/t/read.jsonl" "$GW/t/sess/subagents/agent-a1.jsonl"
# 테스트 실행 셸의 개인 설정이 기본 guard 동작 검사를 끄지 않게 한다.
unset HM_MEMBER_GUARD
member_guard() { # $1=cwd, $2=file, $3=transcript, [$4=agent_id] -> ask(확인 요청) | exit code; stdout $GW/out, stderr $GW/err
  local agent="${4:-}" rc=0 member_guard_mode="${HM_MEMBER_GUARD:-1}"
  jq -cn --arg cwd "$1" --arg f "$2" --arg t "$3" --arg a "$agent" \
    '{tool_name:"Edit", cwd:$cwd, transcript_path:$t, tool_input:{file_path:$f}} + (if $a=="" then {} else {agent_id:$a} end)' \
    | HM_MEMBER_GUARD="$member_guard_mode" "$ROOT/scripts/member-edit-guard.sh" 2>"$GW/err" >"$GW/out" || rc=$?
  if [[ "$rc" == 0 && "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$GW/out" 2>/dev/null)" == ask ]]; then echo ask; else echo "$rc"; fi
}
guard_reason() { jq -r '.hookSpecificOutput.permissionDecisionReason' "$GW/out"; }
guard_context() { jq -r '.hookSpecificOutput.additionalContext' "$GW/out"; }
assert_eq "ask" "$(member_guard "$GW" "$GW/acme/src/main/App.java" "$GW/t/none.jsonl")" "workspace edit of member code asks the user instead of going ahead"
assert_eq "PreToolUse" "$(jq -r '.hookSpecificOutput.hookEventName' "$GW/out")" "ask decision names its hook event"
assert_eq "" "$(<"$GW/err")" "asking writes nothing to stderr (no hook error in the transcript)"
[[ "$(guard_reason)" == "[Direct edit guard] acme "* ]] || fail "ask reason starts with the guard prefix and names the member"
assert_contains "$(guard_reason)" "허용하면 이 편집만 진행" "ask reason tells the user what approving means"
[[ "$(guard_reason)" != *"claude --bg"* ]] || fail "the user's prompt stays short; handoff steps go to the model"
assert_contains "$(guard_context)" "거부되면 다시 시도하지 마세요" "the model is told not to retry a denied edit"
assert_contains "$(guard_context)" "Bash로 파일을 써서 우회하지 마세요" "the model is told not to route around the prompt with Bash"
assert_contains "$(guard_context)" '/cd acme' "handoff context offers /cd into the member"
assert_contains "$(guard_context)" 'cd acme && claude --bg -n <인계 이름> "<인계>"' "handoff context hands off to a Claude Code background session in the member"
assert_contains "$(guard_context)" 'notify_when_idle: true' "handoff context waits on the background session's turn-end notice"
assert_contains "$(guard_context)" 'orca orchestration check --wait' "handoff context keeps Orca supervision as an option when the user wants it"
assert_contains "$(guard_context)" '완료 파일(결과·PR 링크·원격 CI 상태)' "without supervised dispatch the handoff names a completion file to wait for"
assert_contains "$(guard_context)" "첫 지시로 멤버 워크플로 파일(\`.ai-harness/workflows/<name>.md\`)을 Read 하고 그 그래프대로 진행하라고 적습니다" "handoff context tells the handoff to open by reading the member workflow file"
[[ "$(guard_context)$(guard_reason)" != *"워크플로를 읽고"* ]] || fail "reading the workflow is never offered as the way through"
assert_eq "ask" "$(member_guard "$GW" "$GW/acme/src/main/App.java" "$GW/t/read.jsonl")" "reading the member workflow with Read still asks"
assert_eq "ask" "$(member_guard "$GW" "$GW/acme/src/main/App.java" "$GW/t/cd.jsonl")" "cd into the member in Bash then reading its workflow still asks"
assert_eq "ask" "$(member_guard "$GW" "$GW/worktrees/NJ-1/acme/src/main/App.java" "$GW/t/wt.jsonl")" "reading the worktree's workflow still asks"
assert_contains "$(guard_context)" "/cd worktrees/NJ-1/acme" "handoff context hands off to the worktree, not the main checkout"
assert_eq "ask" "$(member_guard "$GW" "$GW/acme/src/main/App.java" "$GW/t/sess.jsonl" a1)" "a subagent of a workspace session still asks even when it and its parent read the workflow"
assert_eq "ask" "$(member_guard "$GW" "$GW/acme/src/main/App.java" "$GW/t/missing.jsonl")" "the verdict does not depend on a readable transcript"
assert_eq "0" "$(member_guard "$GW/acme" "$GW/acme/src/main/App.java" "$GW/t/none.jsonl")" "a session opened in the member is left to the member's own guard"
assert_eq "0" "$(member_guard "$GW/acme/src" "$GW/acme/src/main/App.java" "$GW/t/none.jsonl")" "a session opened below the member root is inside the member"
assert_eq "0" "$(member_guard "$GW/acme" "$GW/acme/src/main/App.java" "$GW/t/none.jsonl" a1)" "a subagent of a member session passes"
assert_eq "0" "$(member_guard "$GW/worktrees/NJ-1/acme" "$GW/worktrees/NJ-1/acme/src/main/App.java" "$GW/t/none.jsonl")" "a session opened in the worktree passes"
assert_eq "ask" "$(member_guard "$GW/acme" "$GW/worktrees/NJ-1/acme/src/main/App.java" "$GW/t/none.jsonl")" "a worktree is its own member: a main-checkout session must ask"
assert_eq "0" "$(member_guard "$GW" "$GW/acme/.ai-harness/docs/domain.md" "$GW/t/none.jsonl")" "harness documents are not guarded"
assert_eq "0" "$(member_guard "$GW" "$GW/acme/.claude/settings.json" "$GW/t/none.jsonl")" "tool settings are not guarded"
assert_eq "0" "$(member_guard "$GW" "$GW/acme/docs/handoff.md" "$GW/t/none.jsonl")" "markdown documents are not guarded"
assert_eq "0" "$(member_guard "$GW" "$GW/plain/src/main/App.java" "$GW/t/none.jsonl")" "code outside any harness is not guarded"
assert_eq "0" "$(jq -cn '{tool_name:"Bash", cwd:"/", tool_input:{command:"ls"}}' | "$ROOT/scripts/member-edit-guard.sh" >/dev/null 2>&1 && echo 0 || echo $?)" "non-edit tools pass"
ln -s "$GW/acme" "$GW/acme-link"
assert_eq "0" "$(member_guard "$GW/acme-link" "$GW/acme/src/main/App.java" "$GW/t/none.jsonl")" "a session in a symlinked path of the same member is not blocked"
assert_eq "0" "$(member_guard "$GW/acme" "$GW/acme/src/../src/main/App.java" "$GW/t/none.jsonl")" "dot-dot in the edited path still resolves to the same member"
assert_eq "0" "$(HM_MEMBER_GUARD=0 member_guard "$GW" "$GW/acme/src/main/App.java" "$GW/t/none.jsonl")" "HM_MEMBER_GUARD=0 turns the guard off"
assert_eq "" "$(<"$GW/out")" "passing cases print no decision"
assert_eq "2" "$(HM_MEMBER_GUARD=block member_guard "$GW" "$GW/acme/src/main/App.java" "$GW/t/none.jsonl")" "HM_MEMBER_GUARD=block keeps the hard block"
[[ "$(<"$GW/err")" == "[Direct edit guard] "* ]] || fail "hard block stderr starts with the counted guard prefix"
assert_contains "$(<"$GW/err")" '/cd acme' "hard block still hands off to the member"
assert_contains "$(<"$GW/err")" "Bash로 파일을 써서 우회하지 마세요" "hard block still forbids writing around it with Bash"
assert_eq "" "$(<"$GW/out")" "hard block prints no ask decision"
assert_eq "0" "$(HM_MEMBER_GUARD=block member_guard "$GW/acme" "$GW/acme/src/main/App.java" "$GW/t/none.jsonl")" "block mode still passes a session opened in the member"
# 같은 저장소를 NFC(cwd)와 NFD(파일, git 표기) 두 정규화 형태로 가리켜도 다른 멤버로 오판하지 않는다(#479).
MG_NFC="$(printf '\355\224\204\353\241\234\354\240\235\355\212\270')"
MG_NFD="$(printf '\341\204\221\341\205\263\341\204\205\341\205\251\341\204\214\341\205\246\341\206\250\341\204\220\341\205\263')"
mkdir -p "$GW/$MG_NFD/.ai-harness" "$GW/$MG_NFD/src"
printf '{"project_id":"uni"}\n' >"$GW/$MG_NFD/.ai-harness/harness.json"
if [[ -d "$GW/$MG_NFC" ]]; then
  assert_eq "0" "$(member_guard "$GW/$MG_NFC" "$GW/$MG_NFD/src/a.sh" "$GW/t/none.jsonl")" "the same repo named in NFC (cwd) and NFD (file) is one member"
  assert_eq "" "$(<"$GW/out")" "a normalization-only difference prints no ask decision"
  assert_eq "0" "$(HM_MEMBER_GUARD=block member_guard "$GW/$MG_NFC" "$GW/$MG_NFD/src/a.sh" "$GW/t/none.jsonl")" "block mode does not block the same repo under another normalization"
  assert_eq "ask" "$(member_guard "$GW/$MG_NFC" "$GW/acme/src/main/App.java" "$GW/t/none.jsonl")" "a genuinely different repo still asks next to the normalization case"
else
  pass "skip on normalization-sensitive fs"
fi
pass "member edit guard"

# 인계 대기는 완료 파일만 보지 않는다 — 멤버 터미널이 승인·질문에서 멈추거나 끝나면 바로 끝내고 이유를 알린다.
WD="$TEST_TMP/wait-delegation"
mkdir -p "$WD/bin"
cat >"$WD/bin/orca" <<'EOF'
#!/usr/bin/env bash
# 실측(Orca 1.4.250): close 는 실제로 닫혀도 오류(tab_not_found)를 낼 수 있다 — 종료 코드가 아니라 list 로 판정해야 한다.
if [[ "${2:-}" == close ]]; then printf '%s\n' "$*" >>"$WD_DIR/closed"; [[ -f "$WD_DIR/close_noop" ]] && rm -f "$WD_DIR/closed"; echo tab_not_found >&2; exit 1; fi
if [[ "${2:-}" == list ]]; then [[ -f "$WD_DIR/closed" ]] && echo '{"ok":true,"result":{"terminals":[]}}' || echo '{"ok":true,"result":{"terminals":[{"handle":"term_3d258b5b-850f-4f77-a851-3013191cd199"}]}}'; exit 0; fi
[[ -f "$WD_DIR/fail" ]] && { echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1; }
jq -Rsc --arg s "$(cat "$WD_DIR/status" 2>/dev/null || echo running)" '{ok:true, result:{terminal:{status:$s, tail:(split("\n"))}}}' "$WD_DIR/screen"
EOF
chmod +x "$WD/bin/orca"
WD_HANDLE="term_3d258b5b-850f-4f77-a851-3013191cd199"
wait_delegation() { # 인자는 그대로 넘긴다. 출력 뒤에 exit=<code>
  local rc=0 out
  out="$(PATH="$WD/bin:$PATH" WD_DIR="$WD" "$ROOT/scripts/wait-delegation.sh" --interval 0 "$@" 2>"$WD/err")" || rc=$?
  printf '%s\nexit=%s' "$out" "$rc"
}
printf 'done\n' >"$WD/finished.md"
WD_OUT="$(wait_delegation --done "$WD/finished.md" --terminal "$WD_HANDLE")"
assert_contains "$WD_OUT" "reason=done" "an existing completion file ends the wait as done"
assert_contains "$WD_OUT" "exit=0" "done exits 0"
printf '구현 계획 brief 입니다.\n승인할까요?\n\n❯ \n⏵⏵ bypass permissions on\n' >"$WD/screen"
WD_OUT="$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --input-idle 0)"
assert_contains "$WD_OUT" "reason=awaiting_input" "a member waiting on a free-text approval question ends the wait"
assert_contains "$WD_OUT" "승인할까요?" "the last screen lines come with the reason"
assert_contains "$WD_OUT" "exit=10" "awaiting_input exits 10"
printf 'Which approach?\n❯ 1. A\n  2. B\nEnter to select · ↑/↓ to navigate\n' >"$WD/screen"
assert_contains "$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --input-idle 0)" "reason=awaiting_input" "a question with choices ends the wait"
# 실측: 새 폴더에서 뜬 Claude 의 신뢰 확인 창은 번호 없는 선택지와 'Enter to confirm' 이다.
printf ' Quick safety check: Is this a project you created or one you trust? (Like your own code, a\n ❯ No, exit\n   Yes, I trust this folder\n Enter to confirm · Esc to cancel\n' >"$WD/screen"
assert_contains "$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --input-idle 0)" "reason=awaiting_input" "the folder trust prompt ends the wait"
printf '✻ Running tests\n' >"$WD/screen"
WD_OUT="$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --input-idle 0 --stall 0)"
assert_contains "$WD_OUT" "reason=stalled" "an unchanged screen without a question ends the wait as stalled"
assert_contains "$WD_OUT" "exit=11" "stalled exits 11"
assert_contains "$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --timeout 1 --interval 1)" "reason=timeout" "a working screen waits until the timeout"
echo exited >"$WD/status"
assert_contains "$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE")" "reason=exited" "an exited member terminal ends the wait"
rm -f "$WD/status"; : >"$WD/fail"
WD_OUT="$(wait_delegation --done "$WD/none.md" --terminal term_3d258b5b)"
assert_contains "$WD_OUT" "reason=terminal_unavailable" "an unreadable terminal handle ends the wait instead of hanging"
assert_contains "$(<"$WD/err")" "short handles go stale" "a short terminal handle is warned about"
rm -f "$WD/fail"
assert_contains "$(wait_delegation --done "$WD/none.md" --timeout 1 --interval 1)" "reason=timeout" "without a terminal the wait watches the file only"
assert_contains "$(wait_delegation --terminal "$WD_HANDLE")" "exit=2" "the completion file is required"
pass "delegation wait reports input gates"

# 끝난 멤버 탭을 닫는다(--close). 대화형 세션은 끝나도 입력 대기로 남아 세션당 수백 MB를 쥔다(2026-11-17: 끝난 세션
# 탭 십여 개·swap 27GB). 오래 켠 조율 세션은 나중에 추가된 문서 규칙을 못 읽으므로 대기 스크립트가 직접 닫는다.
# 완료 파일이 아직 미확인(CI 대기 등)이거나 user_decision이면, 화면이 일하는 중이거나 질문 중이면 닫지 않는다.
printf '## 결과\nPR: #12\n원격 CI: 성공\n' >"$WD/final.md"
printf '⏺ 끝났습니다.\n\n❯ \n⏵⏵ bypass permissions on\n' >"$WD/screen"
rm -f "$WD/closed" "$WD/close_noop"
WD_OUT="$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close)"
assert_contains "$WD_OUT" "reason=done" "closing still reports the completion"
assert_contains "$WD_OUT" "closed=yes" "a finished idle member tab is closed"
assert_contains "$(<"$WD/closed")" "terminal close --terminal $WD_HANDLE" "the member terminal is closed by its full handle"
case "$(<"$WD/closed")" in *--tab*) fail "close without --tab (with --tab Orca closes nothing for launched agents)" ;; esac
rm -f "$WD/closed"
assert_contains "$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE")" "reason=done" "without --close the wait only reports"
assert_not_file "$WD/closed"
printf '## 결과\n원격 CI: PLACEHOLDER\n' >"$WD/pending.md"
WD_OUT="$(wait_delegation --done "$WD/pending.md" --terminal "$WD_HANDLE" --close)"
assert_contains "$WD_OUT" "closed=no" "a completion file whose CI is still open keeps the tab"
assert_contains "$WD_OUT" "close_reason=done_file_pending" "the reason names the open completion file"
printf '## 결과\n그래프 종료: user_decision (원격 CI 미확인)\n' >"$WD/decision.md"
assert_contains "$(wait_delegation --done "$WD/decision.md" --terminal "$WD_HANDLE" --close)" "close_reason=user_decision" "a run that stopped for the user keeps its tab"
assert_not_file "$WD/closed"
printf '✻ Polling CI…\n⏵⏵ bypass permissions on · esc to interrupt\n' >"$WD/screen"
WD_OUT="$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close --close-wait 0)"
assert_contains "$WD_OUT" "close_reason=busy" "a member still working is not closed"
printf '✻ done 7:11 PM · 1 shell still running\n❯ \n' >"$WD/screen"
assert_contains "$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close --close-wait 0)" "close_reason=busy" "a member with a background shell is not closed"
printf '머지할까요?\n\n❯ \n' >"$WD/screen"
assert_contains "$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close --close-wait 0)" "close_reason=awaiting_input" "a member asking a question is not closed"
assert_not_file "$WD/closed"
printf '⏺ 끝났습니다.\n❯ \n' >"$WD/screen"
: >"$WD/close_noop"
assert_contains "$(wait_delegation --done "$WD/final.md" --terminal "$WD_HANDLE" --close)" "close_reason=still_listed" "a close that left the terminal listed is reported, not trusted"
rm -f "$WD/close_noop" "$WD/closed"
assert_contains "$(wait_delegation --done "$WD/final.md" --close)" "exit=2" "--close needs the member terminal"
WD_INIT="$(<"$ROOT/skills/harness-init/SKILL.md")"
assert_contains "$WD_INIT" 'wait-delegation.sh --done <완료 파일> --terminal <멤버 터미널 전체 handle> --close' "workspace delegation waits with --close"
assert_contains "$WD_INIT" "③이 끝난 멤버 탭을 닫지 않음" "sync flags a workspace that does not close finished member tabs"
pass "delegation wait closes a finished member tab"

# 정기 작업은 OS 스케줄러 없이 에이전트 hook이 깨운다. LLM 단계는 사용자가 쉴 때만, 한도 직후엔 쉰다.
assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$ROOT/hooks/hooks.json")" "scripts/tick.sh" "Stop hook ticks the scheduler"
assert_eq "3" "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$ROOT/hooks/hooks.json")" "tick stays inside a short budget"
TICK_DATA="$TEST_TMP/tick-data"
mkdir -p "$TICK_DATA"
printf '{}' | HARNESS_METRICS_DIR="$TICK_DATA" HM_INTERNAL_SESSION=1 HM_BACKFILL_INTERVAL_HOURS=6 "$ROOT/scripts/tick.sh"
assert_not_file "$TICK_DATA/health.json"
TICK_CLAUDE="$TEST_TMP/tick-claude/-tmp-x"
mkdir -p "$TICK_CLAUDE" "$TEST_TMP/tick-codex"
jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{type:"user",timestamp:$t}' >"$TICK_CLAUDE/active.jsonl"
run_tick_worker() {
  HARNESS_METRICS_DIR="$TICK_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/tick-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/tick-codex" \
    HM_BACKFILL_INTERVAL_HOURS=6 HM_BACKFILL_FOREGROUND=1 HM_HARVEST_AUTO=1 HM_HARVEST_GLOBAL_DAYS=0 \
    env "$@" "$ROOT/scripts/backfill-due.sh"
}
run_tick_worker HM_IDLE_MINUTES=20 HM_IDLE_WAIT_HOURS=0
assert_eq "success" "$(jq -r '.components.backfill.last_result' "$TICK_DATA/health.json")" "collection runs even while the user is active"
assert_not_file "$TICK_DATA/harvest-auto/runs.jsonl"
assert_eq "skipped:never_idle" "$(jq -r '"\(.llm):\(.reason)"' "$TICK_DATA/logs/schedule.jsonl" | tail -n 1)" "the schedule log says why LLM steps did not run"
jq '.components.backfill.last_attempt_at = "2020-01-01T00:00:00Z"' "$TICK_DATA/health.json" >"$TICK_DATA/h.tmp" && mv "$TICK_DATA/h.tmp" "$TICK_DATA/health.json"
mkdir -p "$TICK_DATA/harvest-auto"
jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at:$at,event:"finished",project:"x",result:"failed",reason:"usage_limit"}' >"$TICK_DATA/harvest-auto/runs.jsonl"
# 열린 세션은 쉬는 동안에도 시각 없는 줄(last-prompt·cost-state)을 덧붙인다. 파일 수정 시각이 아니라 마지막 기록 시각으로 판정한다.
{
  jq -cn '{type:"user",timestamp:"2000-01-01T00:00:00.000Z"}'
  jq -cn '{type:"last-prompt",lastPrompt:"x"}'
  jq -cn '{type:"cost-state",totalCostUSD:0}'
} >"$TICK_CLAUDE/active.jsonl"
run_tick_worker HM_IDLE_MINUTES=20 HM_IDLE_WAIT_HOURS=0
assert_eq "1" "$(wc -l <"$TICK_DATA/harvest-auto/runs.jsonl" | tr -d ' ')" "LLM steps rest right after a usage limit"
assert_eq "skipped:usage_backoff" "$(jq -r '"\(.llm):\(.reason)"' "$TICK_DATA/logs/schedule.jsonl" | tail -n 1)" "the schedule log names the usage backoff"
jq '.components.backfill.last_attempt_at = "2020-01-01T00:00:00Z"' "$TICK_DATA/health.json" >"$TICK_DATA/h.tmp" && mv "$TICK_DATA/h.tmp" "$TICK_DATA/health.json"
: >"$TICK_DATA/harvest-auto/runs.jsonl"
run_tick_worker HM_IDLE_MINUTES=20 HM_IDLE_WAIT_HOURS=0 HM_HARVEST_GLOBAL_DAYS=7 HM_HARVEST_AUTO_FOREGROUND=1 \
  HM_HARVEST_AUTO_AGENT=claude HM_HARVEST_AUTO_CMD="$AUTO_STUB" AUTO_STUB_OUT="$TEST_TMP/tick-stub.out"
assert_eq "_global" "$(cut -d'|' -f1 "$TEST_TMP/tick-stub.out")" "a session file touched only by untimestamped lines counts as idle, so LLM steps run"
assert_eq "ran" "$(jq -r .llm "$TICK_DATA/logs/schedule.jsonl" | tail -n 1)" "the schedule log records the run"
assert_eq "true" "$(jq -r '.started_at <= .at' "$TICK_DATA/logs/schedule.jsonl" | tail -n 1)" "the schedule log keeps when the round started"
idle_check() { # → active|idle (HM_IDLE_MINUTES=20 기준, 위 tick 디렉터리)
  HARNESS_METRICS_DIR="$TICK_DATA" HARNESS_CLAUDE_PROJECTS_DIR="$TEST_TMP/tick-claude" HARNESS_CODEX_SESSIONS_DIR="$TEST_TMP/tick-codex" \
    bash -c 'source "$1"; hm_recently_active 20 && echo active || echo idle' _ "$ROOT/scripts/lib.sh"
}
assert_eq "idle" "$(idle_check)" "untimestamped tail lines alone are idle"
mkdir -p "$TEST_TMP/tick-codex/2999/01/01"
jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{timestamp:$t,type:"event_msg"}' >"$TEST_TMP/tick-codex/2999/01/01/rollout-x.jsonl"
assert_eq "active" "$(idle_check)" "a fresh Codex rollout line counts as activity"
jq -cn '{timestamp:"2000-01-01T00:00:00.000Z",type:"event_msg"}' >"$TEST_TMP/tick-codex/2999/01/01/rollout-x.jsonl"
assert_eq "idle" "$(idle_check)" "a Codex rollout touched recently but last stamped long ago is idle"
pass "hook-driven schedule with idle and usage gates"

# 규칙 품질: 보이지 않는 문자·비밀값 거부, 총량 상한, 효과 수치 판정(세션 시작 시각 기준).
RQ_DIR="$TEST_TMP/rule-quality"
mkdir -p "$RQ_DIR/events"
run_rq() {
  HARNESS_METRICS_DIR="$RQ_DIR" HM_GLOBAL_CLAUDE_MD="$RQ_DIR/C.md" HM_GLOBAL_CODEX_AGENTS_MD="$RQ_DIR/X.md" \
    HM_AUTO_RULES_MAX=2 "$ROOT/scripts/auto-apply.sh" "$@"
}
RQ_RC=0; run_rq apply --scope global --rule-id zw-rule --text "$(printf '정상\342\200\213문구')" --evidence a --expected b >/dev/null 2>&1 || RQ_RC=$?
assert_eq "2" "$RQ_RC" "invisible unicode is rejected"
RQ_RC=0; run_rq apply --scope global --rule-id secret-rule --text '토큰은 api_key=sk1234abcd 로 넣는다' --evidence a --expected b >/dev/null 2>&1 || RQ_RC=$?
assert_eq "2" "$RQ_RC" "secret-looking text is rejected"
RQ_RC=0; run_rq apply --scope global --rule-id bad-signal --text t --evidence a --expected b --signal '(' >/dev/null 2>&1 || RQ_RC=$?
assert_eq "2" "$RQ_RC" "invalid signal regex is rejected"
run_rq apply --scope global --rule-id rule-one --text "첫 규칙" --evidence a --expected b --signal "boom" >/dev/null
run_rq apply --scope global --rule-id rule-two --text "둘째 규칙" --evidence a --expected b >/dev/null
RQ_RC=0; run_rq apply --scope global --rule-id rule-three --text "셋째" --evidence a --expected b >/dev/null 2>&1 || RQ_RC=$?
assert_eq "5" "$RQ_RC" "rule cap blocks a new rule"
run_rq apply --scope global --rule-id rule-two --text "둘째 규칙 강화" --evidence a --expected b >/dev/null
# 효과: 적용 전 10세션 중 6개, 적용 후 시작한 30세션 중 3개에서 신호 → 20→10... 절반 이하면 improved
RQ_AT="$(run_rq list --active | jq -r 'select(.id=="rule-one") | .at')"
make_rq_session() { # $1=sid $2=started $3=hit(1/0)
  jq -cn --arg sid "$1" --arg st "$2" '{kind:"session",src:"claude",sid:$sid,project:"p",started:$st,ended:$st}'
  if [[ "$3" == "1" ]]; then jq -cn --arg sid "$1" '{kind:"error_sample",src:"claude",sid:$sid,project:"p",target:"Bash: boom happened",n:1}'; fi
}
for i in $(seq 1 10); do make_rq_session "b$i" "2026-01-01T00:00:0${i: -1}Z" $(( i <= 6 ? 1 : 0 )); done >"$RQ_DIR/events/before.jsonl"
for i in $(seq 1 30); do make_rq_session "a$i" "2999-01-01T00:00:00Z" $(( i <= 3 ? 1 : 0 )); done >"$RQ_DIR/events/after.jsonl"
# 적용 전 창은 적용 시각 직전 30일이라, 테스트에선 before 세션을 그 창 안으로 옮긴다.
RQ_BEFORE_AT="$(jq -rn --arg at "$RQ_AT" '$at | sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime - 86400 | strftime("%Y-%m-%dT%H:%M:%SZ")')"
sed -i.bak "s/2026-01-01T00:00:0[0-9]Z/$RQ_BEFORE_AT/" "$RQ_DIR/events/before.jsonl"
# 적용 전에 시작해 적용 후에 끝난 세션은 '적용 후'가 아니다.
jq -cn --arg st "$RQ_BEFORE_AT" '{kind:"session",src:"claude",sid:"straddle",project:"p",started:$st,ended:"2999-01-01T00:00:00Z"}' >>"$RQ_DIR/events/before.jsonl"
RQ_EFFECT="$(run_rq effect --rule-id rule-one)"
assert_eq "11|6|30|3|improved" "$(jq -r '"\(.before.sessions)|\(.before.hits)|\(.after.sessions)|\(.after.hits)|\(.verdict)"' <<<"$RQ_EFFECT")" "effect compares rates by session start and judges improvement"
assert_eq "pending" "$(HM_EFFECT_MIN_SESSIONS=100 run_rq effect --rule-id rule-one | jq -r .verdict)" "small samples stay pending"
assert_eq "pending" "$(HM_EFFECT_MIN_EXPECTED=50 run_rq effect --rule-id rule-one | jq -r .verdict)" "rare signals stay pending until enough events are expected"
pass "rule quality gates and measured effect"

# PreToolUse(Bash) DB 스캔 가드(opt-in)는 명령 위치의 DB 클라이언트·드라이버 쿼리 중 스키마 조건 없는 information_schema 정의·메타 조회만 막는다.
DB_GUARD_HOOK="$(jq -c '.hooks.PreToolUse[] | select(.hooks[0].command | contains("db-scan-guard"))' "$ROOT/hooks/hooks.json")"
assert_eq "5" "$(jq '.hooks.PreToolUse | length' "$ROOT/hooks/hooks.json")" "db scan guard joins the existing PreToolUse array (edit guard, db scan, stale reset, background watchdog, heavy slot)"
assert_eq "3" "$(jq -r '.hooks[0].timeout' <<<"$DB_GUARD_HOOK")" "db scan guard stays inside a short budget"
GUARD_COMMAND="$(jq -r '.hooks[0].command' <<<"$DB_GUARD_HOOK")"
assert_contains "$GUARD_COMMAND" "$LITERAL_PLUGIN_ROOT" "db scan guard quoted plugin root"
assert_contains "$GUARD_COMMAND" "scripts/db-scan-guard.sh" "Bash PreToolUse hook runs the db scan guard"
GUARD_DATA="$TEST_TMP/guard-data"
mkdir -p "$GUARD_DATA"
run_db_guard() {
  jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | HM_DB_SCAN_GUARD="${2-1}" CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$GUARD_DATA" /bin/sh -c "$GUARD_COMMAND"
}
db_guard_verdict() { if [[ -n "$(run_db_guard "$1")" ]]; then echo deny; else echo allow; fi; }
GUARD_CASES=0
while IFS=$'\t' read -r expect command; do
  [[ -n "$expect" ]] || continue
  assert_eq "$expect" "$(db_guard_verdict "$command")" "db scan guard: $command"
  GUARD_CASES=$((GUARD_CASES + 1))
done <<'CASES'
deny	mysql -h 127.0.0.1 -u dev -e "select table_schema, table_name from information_schema.views where view_definition like '%orders%' union all select routine_schema, routine_name from information_schema.routines where routine_definition like '%orders%' union all select trigger_schema, trigger_name from information_schema.triggers where event_object_table = 'orders' or action_statement like '%orders%'"
deny	mysql -h 127.0.0.1 -u dev -e "select count(*) from information_schema.columns where column_name = 'use_yn' and table_name = 'orders'"
deny	mysql -u dev -e "select table_name from information_schema.views where table_schema = 'app' union all select routine_name from information_schema.routines where routine_definition like '%x%'"
deny	mysql -u dev -e "select table_name from information_schema.tables where table_schema = 'app'; select trigger_name from information_schema.triggers"
deny	mysql -u dev -e "select routine_name from `information_schema`.`ROUTINES` where routine_definition like '%x%'"
deny	mysql -u dev information_schema -e "select trigger_name from triggers where action_statement like '%x%'"
deny	mysql -u dev -e "use information_schema; select table_name from views where view_definition like '%x%'"
deny	mysql -u dev -e "select table_name from information_schema.tables where table_schema != 'mysql'"
deny	mysql -u dev -e "select table_name from information_schema.tables where table_schema not in ('mysql', 'sys')"
deny	mariadb -u dev -e "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE WHERE REFERENCED_TABLE_NAME = 'orders'"
deny	python3 -c "import pymysql; c = pymysql.connect(host='127.0.0.1', user='dev').cursor(); c.execute('select * from information_schema.triggers')"
deny	psql -h localhost -d app -c "select table_name from information_schema.views where view_definition like '%orders%'"
deny	mysql -u dev -e "select table_name from information_schema.tables where 1=1 or table_schema = 'app'"
deny	mysql -u dev -e "select table_name from information_schema.tables where table_name = 'x' -- and table_schema = 'app'"
deny	mysql -u dev -e "select table_name from information_schema.views where view_definition like '%table_schema = 1%'"
deny	mysql -u dev -e "select table_name from information_schema.views where /* table_schema = 'app' and */ view_definition like '%x%'"
deny	echo "select * from information_schema.views" | mysql -u dev
deny	MYSQL_PWD=x /usr/local/bin/mysql -u dev --execute="select * from information_schema.routines"
deny	sudo -u postgres psql -c "select table_name from information_schema.views"
allow	mysql -u dev -e "select table_name from information_schema.views where table_schema = 'app' and view_definition like '%orders%'"
allow	mysql -u dev -e "select routine_name from information_schema.routines where routine_schema = 'app' and routine_definition like '%x%' union all select trigger_name from information_schema.triggers where trigger_schema='app' and action_statement like '%x%'"
allow	mysql -u dev -e "select table_name from information_schema.referential_constraints where constraint_schema = 'app'; select table_name from information_schema.tables where table_schema in ('app', 'app_batch')"
allow	mysql -u dev -e "select column_name from information_schema.columns where table_schema = database() and table_name = 'orders'"
allow	mysql -u dev -e "select table_name from information_schema.views where table_schema = 'app' and (view_definition like '%a%' or view_definition like '%b%')"
allow	mysql -u dev -e "select schema_name from information_schema.schemata"
allow	psql -h localhost -d app -c "select table_name from information_schema.columns where column_name = 'id'"
allow	git commit -m "docs: mysql information_schema.views note"
allow	grep -rn "mysql -e 'select * from information_schema.views'" docs/
allow	echo "mysql -u dev -e select * from information_schema.triggers"
allow	git log --oneline --grep "information_schema.triggers"
allow	cd /tmp && mysql -u dev -e "select 1" && echo 'information_schema.views'
CASES
assert_eq "31" "$GUARD_CASES" "db scan guard case count"
assert_eq "deny" "$(db_guard_verdict $'mysql -u dev <<\'SQL\'\nselect table_name from information_schema.views;\nSQL')" "db scan guard reads heredoc SQL fed to a client"
assert_eq "allow" "$(db_guard_verdict $'cat > notes.md <<\'EOF\'\nmysql -e "select * from information_schema.views"\nEOF')" "db scan guard ignores heredoc documents"
assert_eq "allow" "$(db_guard_verdict $'git commit -m "$(cat <<\'EOF\'\ndocs: guard\n\nmysql -e "select * from information_schema.views"\nEOF\n)"')" "db scan guard ignores commit message heredocs"
assert_eq "" "$(run_db_guard "ls -la && git status")" "db scan guard ignores ordinary commands"
DENY_OUT="$(run_db_guard "mysql -u dev -e \"select * from information_schema.triggers\"")"
assert_contains "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$DENY_OUT")" "[DB scan guard] information_schema.TRIGGERS" "db scan guard names the table"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$DENY_OUT")" "db scan guard denies through PreToolUse decision"
# 기본은 꺼져 있고, 켜는 값은 config에서도 읽되 config를 셸로 실행하지 않는다.
assert_eq "" "$(run_db_guard "mysql -u dev -e \"select * from information_schema.triggers\"" "")" "db scan guard is off by default"
printf 'HM_DB_SCAN_GUARD=1\ntouch "%s/pwned"\n' "$GUARD_DATA" >"$GUARD_DATA/config"
assert_contains "$(run_db_guard "mysql -u dev -e \"select * from information_schema.triggers\"" "")" "deny" "db scan guard opt-in by config"
[[ ! -e "$GUARD_DATA/pwned" ]] || fail "db scan guard executed config as shell"
rm -f "$GUARD_DATA/config"
assert_eq "" "$(printf 'not json' | HM_DB_SCAN_GUARD=1 CLAUDE_PLUGIN_ROOT="$ROOT" /bin/sh -c "$GUARD_COMMAND")" "db scan guard fails open on bad input"
pass "db scan guard"

# 제거: 사람이 블록 밖에 같은 규칙을 직접 쓰면 자동 규칙은 중복이다. 문구 비교는 공백·대소문자·목록 기호를 무시한다.
DUP_HOME="$TEST_TMP/dup-home"
mkdir -p "$DUP_HOME"
printf '# 내 규칙\n' >"$DUP_HOME/CLAUDE.md"
run_dup() {
  HARNESS_METRICS_DIR="$TEST_TMP/dup-data" HM_GLOBAL_CLAUDE_MD="$DUP_HOME/CLAUDE.md" \
    HM_GLOBAL_CODEX_AGENTS_MD="$DUP_HOME/codex/AGENTS.md" "$ROOT/scripts/auto-apply.sh" "$@"
}
run_dup apply --scope global --rule-id quote-equals --text "zsh에서 =로 시작하는 단어는 따옴표로 감싼다" --evidence x --expected y >/dev/null
run_dup apply --scope global --rule-id jq-null --text "jq 순회 전 null을 거른다" --evidence x --expected y >/dev/null
assert_eq "" "$(run_dup duplicates)" "rules only inside the block are not duplicates"
printf '%s\n' '# 내 규칙' '*   ZSH에서 =로 시작하는   단어는 따옴표로 감싼다' "$(tail -n +2 "$DUP_HOME/CLAUDE.md")" >"$DUP_HOME/CLAUDE.md.new" && mv "$DUP_HOME/CLAUDE.md.new" "$DUP_HOME/CLAUDE.md"
# global 규칙은 Claude·Codex 두 지침에 들어 있다 — 한쪽에만 중복이면 revert가 다른 쪽의 유일한 사본까지 지운다.
assert_eq "" "$(run_dup duplicates)" "a duplicate in only one target file is not reported"
printf '%s\n' '- zsh에서 =로 시작하는 단어는 따옴표로 감싼다' "$(<"$DUP_HOME/codex/AGENTS.md")" >"$DUP_HOME/codex/AGENTS.md.new" && mv "$DUP_HOME/codex/AGENTS.md.new" "$DUP_HOME/codex/AGENTS.md"
DUPS="$(run_dup duplicates)"
assert_eq "quote-equals" "$(jq -r '.id' <<<"$DUPS")" "rule restated outside the block in every target is a duplicate"
assert_eq "2" "$(jq -r '.files[] | select(.file | endswith("CLAUDE.md")) | .line' <<<"$DUPS")" "duplicate reports the human-written line"
assert_eq "2" "$(jq -r '.files | length' <<<"$DUPS")" "duplicate lists every target file"
assert_eq "1" "$(jq -s 'length' <<<"$DUPS")" "rules not restated are not reported"
assert_contains "$(<"$ROOT/skills/harvest/SKILL.md")" "auto-apply.sh duplicates" "harvest prunes duplicated auto rules"
pass "duplicate auto rules are removal candidates"

# 제거 개선은 history에 change로 남아 다음 harvest가 '빠진 규칙이 필요했는가'로 검증한다.
CHG_DATA="$TEST_TMP/change-data"
mkdir -p "$CHG_DATA/harvest-queue/p-chg/sessions"
jq -n '{v:1,project:"chg",batch_id:"b1",created_at:"2026-01-01T00:00:00Z",counts:{},reasons:[],markers:[]}' >"$CHG_DATA/harvest-queue/p-chg/analysis-batch.json"
HARNESS_METRICS_DIR="$CHG_DATA" "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project chg --outcome improved \
  --summary "낡은 규칙 제거" --artifact "https://example.test/pr/1" --expected "같은 오류 재발 없음" --change remove >/dev/null
assert_eq "remove" "$(jq -r '.review.change' "$CHG_DATA/harvest-queue/p-chg/review-history.jsonl")" "review history records the change kind"
CHG_RC=0
HARNESS_METRICS_DIR="$CHG_DATA" "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project chg --change shrink >/dev/null 2>&1 || CHG_RC=$?
assert_eq "2" "$CHG_RC" "unknown change kind is rejected"
assert_contains "$(<"$ROOT/skills/harvest/SKILL.md")" "--change remove" "harvest records removals"
pass "harvest records removal changes"


# 상태 표시줄의 경과 시간·비용은 일이 멈춰도 바뀐다(#465). 화면 전체로 변화를 보면 정체(stalled)가 영원히 잡히지 않으므로
# 입력창 구분선 둘 중 위쪽 것 위의 내용만 본다.
cat >"$WD/bin/orca" <<'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == list ]]; then echo '{"ok":true,"result":{"terminals":[]}}'; exit 0; fi
n=$(( $(cat "$WD_DIR/clock" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$WD_DIR/clock"
sed "s/{{clock}}/$n/" "$WD_DIR/screen" | jq -Rsc '{ok:true, result:{terminal:{status:"running", tail:(split("\n"))}}}'
EOF
chmod +x "$WD/bin/orca"
WD_RULE="$(printf '%.0s─' {1..40})"
printf '✻ Running tests\n%s\n❯ \n%s\nctx 10%% | {{clock}}m | cost 0.10\n' "$WD_RULE" "$WD_RULE" >"$WD/screen"
rm -f "$WD/clock"
WD_OUT="$(wait_delegation --done "$WD/none.md" --terminal "$WD_HANDLE" --interval 1 --input-idle 100 --stall 2 --timeout 6)"
assert_contains "$WD_OUT" "reason=stalled" "a screen whose only change is the status line clock is stalled"
assert_contains "$(<"$ROOT/scripts/wait-delegation.sh")" "content_of" "the change hash reads only the content above the prompt"
pass "delegation wait sees a stall behind a ticking status line"

# 조율 세션 mod(mods/harness-delegations)는 wait-delegation.sh 와 같은 문구로 입력 대기·작업 중을 판정한다(#465).
# 한쪽만 고치면 프롬프트 위 줄과 대기 스크립트가 같은 화면을 다르게 읽는다.
WDM_SH="$(<"$ROOT/scripts/wait-delegation.sh")"
WDM_TS="$(<"$ROOT/mods/harness-delegations/hooks/register.tsx")"
wdm_ts() { sed -n "s#^const $1 = /\\(.*\\)/i\$#\\1#p" <<<"$WDM_TS" | sed 's#\\/#/#g'; }
WDM_ASK_SH="$(grep -o "grep -Eqi '[^']*Enter to (select|confirm)[^']*'" <<<"$WDM_SH" | sed "s/^grep -Eqi '//; s/'\$//")"
WDM_BUSY_SH="$(grep -o "grep -Eqi '[^']*esc to interrupt[^']*'" <<<"$WDM_SH" | sed "s/^grep -Eqi '//; s/'\$//")"
[ -n "$WDM_ASK_SH" ] && [ -n "$WDM_BUSY_SH" ] || fail "wait-delegation.sh patterns are readable"
assert_eq "$WDM_ASK_SH" "$(wdm_ts ASK)" "the mod reads an input prompt with the same pattern as wait-delegation.sh"
assert_eq "$WDM_BUSY_SH" "$(wdm_ts BUSY)" "the mod reads a working screen with the same pattern as wait-delegation.sh"
assert_eq "harness-delegations" "$(jq -r '.plugins[] | select(.source == "./mods/harness-delegations") | .name' "$ROOT/.claude-plugin/marketplace.json")" \
  "the marketplace lists the mod as its own optional plugin"
pass "delegation mod and wait script share their screen patterns"

finish_tests
