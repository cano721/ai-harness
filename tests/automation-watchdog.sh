#!/usr/bin/env bash
# 회귀 테스트 — 백그라운드 명령 감시자·무거운 명령 슬롯
# 실행: bash tests/run.sh automation-watchdog
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"


# 백그라운드 Bash 감시자 hook: 명령을 바꾸지 않고(권한 판정이 그대로) 아무것도 출력하지 않는다. 등록·끄기·오류 통과.
BG_HOOK="$(jq -c '.hooks.PreToolUse[] | select(.matcher == "Bash" and (.hooks[0].command | contains("background-watchdog")))' "$ROOT/hooks/hooks.json")"
assert_eq "$LITERAL_PLUGIN_ROOT/scripts/background-watchdog-hook.sh\"" "$(jq -r '.hooks[0].command' <<<"$BG_HOOK")" "Bash PreToolUse registers the background watchdog"
assert_eq "3" "$(jq -r '.hooks[0].timeout' <<<"$BG_HOOK")" "background watchdog hook stays inside a short budget"
bg_hook() { "$ROOT/scripts/background-watchdog-hook.sh"; printf '|%s' "$?"; }
assert_eq "|0" "$(jq -cn '{tool_input:{command:"echo bg",run_in_background:true}}' | bg_hook)" "background input gets no hook output (command and permissions untouched)"
assert_eq "|0" "$(jq -cn '{tool_input:{command:"echo fg",run_in_background:false}}' | bg_hook)" "foreground input passes through"
assert_eq "|0" "$(printf '%s\n' '{broken' | bg_hook)" "malformed input fails open silently"
assert_eq "|0" "$(jq -cn '{tool_input:{command:["a"],run_in_background:true}}' | bg_hook)" "non-string command fails open silently"
pass "background command watchdog hook"

# 감시자는 실제 프로세스 그룹에서: 가짜 에이전트가 hook을 부르고, Claude Code처럼 명령을 eval '…'로 넣은 셸을 새 그룹 리더로 띄운다.
# 이 검사는 ps를 통한 실프로세스 관찰이 가능할 때만 유효하다.
if ! ps -A -o pid=,ppid=,pgid=,args= >/dev/null 2>&1; then
  printf '%s\n' '# skip: background watchdog process tests need ps access'
else
# 띄우는 프로세스는 인자에 $TEST_TMP를 넣어 실패해도 cleanup이 끈다.
BG_LOOP='while :; do sleep 1; done'
cat >"$TEST_TMP/bg-agent.sh" <<'EOF'
#!/bin/bash
# bg-agent.sh <hook에 줄 명령> <실제로 띄울 명령> <출력 접두어> — BG_HOOK_CMD(hooks.json의 hook 명령)를 sh -c로 부른 뒤
# Claude Code처럼 eval '…' 뒤에 명령이 더 이어지는(그래서 exec되지 않는) 셸을 자식 그룹 리더로 띄우고 산다.
# hook 명령은 env로 받는다 — 이 프로세스(가짜 에이전트)의 인자에 hook 경로가 없어야 한다.
jq -cn --arg c "$1" --arg id "${BG_TOOL_USE_ID:-}" '{tool_input:{command:$c,run_in_background:true}} + (if $id == "" then {} else {tool_use_id:$id} end)' | /bin/sh -c "$BG_HOOK_CMD" >"$3.hook"
q="'"
esc="${2//$q/$q\"$q\"$q}"
perl -e 'setpgrp(0, 0); exec @ARGV' bash -c "eval '$esc' </dev/null && :" "$3.shell" >"$3.out" 2>"$3.err" &
echo $! >"$3.pid"
wait $!
echo $? >"$3.status"
while :; do sleep 1; done
EOF
bg_start() { # 이름 hook명령 [실행명령] → BG_AGENT, BG_GROUP
  rm -f "$TEST_TMP/$1".*
  BG_HOOK_CMD="$(jq -r '.hooks[0].command' <<<"$BG_HOOK")${BG_HOOK_SUFFIX:-}" CLAUDE_PLUGIN_ROOT="$ROOT" \
    bash "$TEST_TMP/bg-agent.sh" "$2" "${3:-$2}" "$TEST_TMP/$1" &
  BG_AGENT=$!
  track_test_process "$BG_AGENT"
  for _ in $(seq 1 50); do [[ -s "$TEST_TMP/$1.pid" ]] && break; sleep 0.1; done
  BG_GROUP="$(<"$TEST_TMP/$1.pid")"
  track_test_process "$BG_GROUP" "$BG_GROUP"
}
bg_watching() { pgrep -f "background-watchdog.sh $BG_AGENT " >/dev/null && echo true || echo false; }
bg_claimed() { [[ -d "$HARNESS_METRICS_DIR/bg-watchdog/$BG_GROUP" ]] && echo true || echo false; }
# shellcheck disable=SC2009  # ppid·pgid까지 보여야 해서 pgrep으로 대신할 수 없다
bg_procs() { ps -A -o pid=,ppid=,pgid=,args= | grep -F -e "$TEST_TMP" -e background-watchdog | grep -v grep | cut -c1-200; }
bg_group_gone() { # pgid 초 → 그 시간 안에 그룹이 비면 0
  local i
  for i in $(seq 1 $(($2 * 10))); do kill -0 -- "-$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}
bg_stop_agent() { kill -KILL "$BG_AGENT" 2>/dev/null; wait "$BG_AGENT" 2>/dev/null || true; }
bg_wait_claimed() { # 초 → 감시자가 그룹을 선점할 때까지(최대 그 시간) 기다린다. 판정은 뒤의 단언이 한다.
  local i
  for i in $(seq 1 $(($1 * 10))); do [[ "$(bg_claimed)" == true ]] && return 0; sleep 0.1; done
  return 0
}

# 에이전트가 강제로 끝나면 그룹 전체(ppid 1로 떨어진 손자 포함)를 끈다. hook 출력은 없다.
bg_start bg-kill "( bash -c '$BG_LOOP' '$TEST_TMP/bg-orphan' & ); bash -c '$BG_LOOP' '$TEST_TMP/bg-main'"
bg_wait_claimed 5
assert_eq "" "$(<"$TEST_TMP/bg-kill.hook")" "hook prints nothing for a background command"
assert_eq "true" "$(kill -0 -- "-$BG_GROUP" 2>/dev/null && echo true || echo false)" "background server keeps running while the agent lives"
[[ "$(bg_claimed)" == true ]] || fail "watchdog found and claimed the background command's group (hook run through /bin/sh like hooks.json): agent=$BG_AGENT group=$BG_GROUP
$(bg_procs)"
bg_stop_agent
bg_group_gone "$BG_GROUP" 8 || fail "process group (with an orphaned grandchild) survives after the agent is gone"

# hook을 감싼 sh가 마지막 명령을 exec하지 않아도(일부 dash) hook의 부모가 아니라 그 위 에이전트를 감시한다.
BG_HOOK_SUFFIX='; :' bg_start bg-wrap "bash -c '$BG_LOOP' '$TEST_TMP/bg-wrap'"
bg_wait_claimed 5
[[ "$(bg_claimed)" == true ]] || fail "watchdog watches the agent even when sh does not exec the hook: agent=$BG_AGENT group=$BG_GROUP
$(bg_procs)"
bg_stop_agent
bg_group_gone "$BG_GROUP" 8 || fail "group survives the agent when sh did not exec the hook"

# 명령이 먼저 끝나면 감시자도 바로 끝나고, 명령의 출력·종료 코드는 그대로다(작은따옴표가 든 명령도 찾는다).
bg_start bg-done "sleep 3; printf '%s' \"it's done\"; printf err >&2; exit 7"
bg_wait_claimed 3
assert_eq "true" "$(bg_claimed)" "watchdog found a command that contains single quotes"
for _ in $(seq 1 80); do [[ -s "$TEST_TMP/bg-done.status" ]] && break; sleep 0.1; done
assert_eq "it's done|err|7" "$(<"$TEST_TMP/bg-done.out")|$(<"$TEST_TMP/bg-done.err")|$(<"$TEST_TMP/bg-done.status")" "command output and exit status are unchanged"
BG_LEFT=true
for _ in $(seq 1 30); do [[ "$(bg_watching)" == false ]] && { BG_LEFT=false; break; }; sleep 0.1; done
assert_eq "false" "$BG_LEFT" "watchdog exits as soon as the command group is empty"
assert_eq "false" "$(bg_claimed)" "watchdog releases its claim when it ends"
bg_stop_agent

# 리더 셸이 먼저 끝나도(일부 pid만 꺼진 경우) 그룹에 남은 프로세스가 있으면 감시를 이어 간다.
bg_start bg-left "bash -c '$BG_LOOP' '$TEST_TMP/bg-left' & sleep 2; exit 0"
for _ in $(seq 1 50); do [[ -s "$TEST_TMP/bg-left.status" ]] && break; sleep 0.1; done
sleep 2
assert_eq "true" "$(bg_watching)" "watchdog keeps watching members left after the leader shell exits"
bg_stop_agent
bg_group_gone "$BG_GROUP" 8 || fail "group members left by an exited leader shell survive the agent"

# hook이 본 명령과 다른 그룹은 건드리지 않는다(못 찾으면 아무것도 하지 않는다).
bg_start bg-other "echo not-this-one" "bash -c '$BG_LOOP' '$TEST_TMP/bg-other'"
sleep 1
bg_stop_agent
# 잘못 잡은 감시자라면 1초 주기로 에이전트가 사라진 것을 보고 바로 TERM을 보낸다 — 2초면 그 주기를 넘긴다.
sleep 2
assert_eq "true" "$(kill -0 -- "-$BG_GROUP" 2>/dev/null && echo true || echo false)" "watchdog leaves a group it did not match"
kill -KILL -- "-$BG_GROUP" 2>/dev/null || true

# 너무 짧은 첫 줄(cd x 등)은 다른 명령과 헷갈리므로 감시하지 않는다.
bg_start bg-short "cd /
bash -c '$BG_LOOP' '$TEST_TMP/bg-short'"
sleep 1
assert_eq "false" "$(bg_watching)" "a too-short first line starts no watch"
bg_stop_agent
kill -KILL -- "-$BG_GROUP" 2>/dev/null || true

# 끄면 감시자를 띄우지 않는다.
HM_BACKGROUND_WATCHDOG=0 bg_start bg-off "bash -c '$BG_LOOP' '$TEST_TMP/bg-off'"
sleep 1
assert_eq "false" "$(bg_watching)" "HM_BACKGROUND_WATCHDOG=0 starts no watchdog"
bg_stop_agent
kill -KILL -- "-$BG_GROUP" 2>/dev/null || true

# 에이전트를 처음부터 볼 수 없으면 바로 물러난다.
BG_GONE="$(bash -c 'echo $$' "$TEST_TMP/bg-gone")"
BG_START=$SECONDS
"$ROOT/scripts/background-watchdog.sh" "$BG_GONE" " " "sleep 100" "$TEST_TMP/bg-claims"
assert_eq "0" "$((SECONDS - BG_START > 1))" "watchdog exits at once when the agent is already gone"
pass "background watchdog cleans the process group"
fi

# 무거운 명령 슬롯(#436): 병렬 세션의 빌드·dev 서버·전체 테스트를 메모리 기준 동시 수로 줄 세운다.
# hook은 이 테스트 셸에서 직접(명령 치환 없이) 불러 부모 pid(=에이전트)가 살아 있게 한다.
HS="$ROOT/scripts/heavy-slot-hook.sh"
HS_DIR="$HARNESS_METRICS_DIR/heavy-slots"
HS_PS_BIN="$TEST_TMP/hs-ps-bin"
mkdir -p "$HS_PS_BIN"
cat >"$HS_PS_BIN/ps" <<'EOF'
#!/usr/bin/env bash
# Codex sandbox may deny process enumeration. The hook needs only its direct
# shell parent's command name in these foreground tests; all other queries stay
# empty, as an inaccessible process list would be.
if [[ "$*" == "-o comm= -p "* ]]; then printf '%s\n' bash; fi
EOF
chmod +x "$HS_PS_BIN/ps"
HS_REG_PRE="$(jq -c '.hooks.PreToolUse[] | select(.matcher == "Bash" and (.hooks[0].command | contains("heavy-slot")))' "$ROOT/hooks/hooks.json")"
assert_eq "$LITERAL_PLUGIN_ROOT/scripts/heavy-slot-hook.sh\" pre" "$(jq -r '.hooks[0].command' <<<"$HS_REG_PRE")" "Bash PreToolUse registers the heavy slot hook"
assert_eq "600" "$(jq -r '.hooks[0].timeout' <<<"$HS_REG_PRE")" "the heavy slot hook may wait up to its timeout"
assert_eq "$LITERAL_PLUGIN_ROOT/scripts/heavy-slot-hook.sh\" post" "$(jq -r '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[0].command | select(contains("heavy-slot"))' "$ROOT/hooks/hooks.json")" "Bash PostToolUse releases heavy slots"
# 실패한 명령은 PostToolUse 대신 PostToolUseFailure가 온다(실측).
assert_eq "$LITERAL_PLUGIN_ROOT/scripts/heavy-slot-hook.sh\" post" "$(jq -r '.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[0].command | select(contains("heavy-slot"))' "$ROOT/hooks/hooks.json")" "Bash PostToolUseFailure releases heavy slots of failed commands"
hs_in() { # tool_use_id 명령 [bg] [transcript]
  jq -cn --arg id "$1" --arg c "$2" --argjson bg "${3:-false}" --arg t "${4:-}" \
    '{tool_name:"Bash", tool_use_id:$id, transcript_path:$t, tool_input:{command:$c, run_in_background:$bg}}'
}
hs_call() { # 모드 입력 → $TEST_TMP/hs.out, $TEST_TMP/hs.rc
  printf '%s' "$2" | PATH="$HS_PS_BIN:$PATH" "$HS" "$1" >"$TEST_TMP/hs.out" 2>"$TEST_TMP/hs.err"
  echo $? >"$TEST_TMP/hs.rc"
}
hs_slots() { find "$HS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | sed 's#.*/##; s#\.json$##' | sort | paste -sd' ' -; }

# 판정: 패키지 매니저 build·dev·start·test:ci, 프레임워크 CLI, 빌드 도구, compose up. 앞의 cd·env·nohup은 건너뛴다.
for c in "yarn web build" "cd apps/web && npm run dev" "nohup yarn dev -p 3100 > log 2>&1 &" "VAR_ENV=st yarn start -p 3999" \
  "(cd apps/web && pnpm build)" "yarn web test:ci" "npx next build" "./gradlew clean build" "docker compose up -d" "yarn workspace web dev"; do
  "$HS" match "$c" || fail "heavy command not matched: $c"
done
for c in "pnpm --filter web build" "pnpm -r build" "yarn workspace web run build" "yarn run build" "sudo docker compose up -d" "timeout 300 yarn build"; do
  "$HS" match "$c" || fail "heavy command not matched: $c"
done
for c in "ls -la" "grep -rn build src" "echo yarn build" "yarn web test src/a.spec.ts" "git status" "cat package.json" "yarn add build" "yarn remove dev" "echo 'a && yarn build'"; do
  ! "$HS" match "$c" || fail "light command matched as heavy: $c"
done
HM_HEAVY_PATTERNS='^make( |$)' "$HS" match "make all" || fail "HM_HEAVY_PATTERNS replaces the default patterns"
! HM_HEAVY_PATTERNS='^make( |$)' "$HS" match "yarn build" || fail "HM_HEAVY_PATTERNS replaces, not extends, the defaults"

# 기본은 꺼짐: 아무것도 쓰지 않고 출력도 없다.
hs_call pre "$(hs_in t-off "yarn build")"
assert_eq "0||" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "without HM_HEAVY_SLOTS the hook does nothing"

export HM_HEAVY_SLOTS=1 HM_HEAVY_MEM_FREE_PCT=80 HM_HEAVY_WAIT=0
# 가벼운 명령은 슬롯을 쓰지 않는다.
hs_call pre "$(hs_in t-light "git status")"
assert_eq "0||" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "light commands pass without a slot"
# 슬롯을 얻으면 출력 없이 통과하고, 다 찼으면 기다리다(여기서는 0초) 이유를 담아 거절한다.
hs_call pre "$(hs_in t1 "yarn web build")"
assert_eq "0||t1" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "a free slot is taken silently"
hs_call pre "$(hs_in t2 "npm run dev")"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")" "a full slot set denies the command"
HS_REASON="$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TEST_TMP/hs.out")"
assert_contains "$HS_REASON" "[Heavy slot] " "the denial starts with a bracketed hook prefix like the other guards"
assert_contains "$HS_REASON" "yarn web build" "the denial names the command holding the slot"
assert_contains "$HS_REASON" "같은 명령을 그대로 다시 실행하세요" "the denial tells the model a plain retry waits again (measured: models retry as is)"
assert_contains "$HS_REASON" "bash -c·스크립트로 감싸거나" "the denial forbids wrapping the command to dodge the wait"
assert_contains "$HS_REASON" "세 번 연속 거절되면" "the denial bounds retries before asking the user"
assert_eq "t1" "$(hs_slots)" "a denied command takes no slot"
# 같은 tool_use_id로 다시 오면 이미 쥔 슬롯이다.
hs_call pre "$(hs_in t1 "yarn web build")"
assert_eq "0|" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")" "a retried call keeps its own slot"
# PostToolUse(포그라운드)가 반환하면 다음 명령이 얻는다.
hs_call post "$(hs_in t1 "yarn web build")"
assert_eq "" "$(hs_slots)" "PostToolUse releases a foreground slot"
hs_call pre "$(hs_in tf "yarn web build")"
hs_call post "$(jq -cn '{tool_name:"Bash", tool_use_id:"tf", hook_event_name:"PostToolUseFailure", is_interrupt:false, error:"exit 1", tool_input:{command:"yarn web build"}}')"
assert_eq "" "$(hs_slots)" "PostToolUseFailure input releases the slot of a failed command"
hs_call pre "$(hs_in t2 "npm run dev")"
assert_eq "t2" "$(hs_slots)" "the next heavy command gets the released slot"

# 기다리는 동안 슬롯이 비면 얻는다.
( sleep 1; rm -f "$HS_DIR/t2.json" ) &
HS_START=$SECONDS
HM_HEAVY_WAIT=8 hs_call pre "$(hs_in t3 "yarn build")"
assert_eq "0||t3" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "a waiting command gets a slot once it frees"
assert_eq "1" "$((SECONDS - HS_START < 7))" "the wait ends as soon as a slot frees"
wait

# 회수: 주인 에이전트가 없거나, transcript에 그 호출의 결과(Esc·중단 포함)가 있으면 끝난 것이다.
HS_DEAD="$(bash -c 'echo $$')"
jq -cn --arg a "$HS_DEAD" '{tool_use_id:"t3", agent:($a|tonumber), cmd:"yarn build", bg:false, transcript:"", started:now|floor}' >"$HS_DIR/t3.json"
hs_call pre "$(hs_in t4 "yarn build")"
assert_eq "t4" "$(hs_slots)" "a slot whose agent is gone is reclaimed"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","is_error":true,"content":"interrupted"}]}}' >"$TEST_TMP/hs-transcript.jsonl"
jq --arg t "$TEST_TMP/hs-transcript.jsonl" '.transcript = $t' "$HS_DIR/t4.json" >"$TEST_TMP/hs.tmp" && mv "$TEST_TMP/hs.tmp" "$HS_DIR/t4.json"
hs_call pre "$(hs_in t5 "yarn build")"
assert_eq "t5" "$(hs_slots)" "a slot whose call already has a tool_result is reclaimed (no PostToolUse after Esc)"
rm -f "$HS_DIR"/*.json

# 메모리가 빠듯하면 상한보다 적게: 여유 15% 미만은 1, 30% 미만은 절반.
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=10 hs_call pre "$(hs_in m1 "yarn build")"
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=10 hs_call pre "$(hs_in m2 "yarn build")"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")" "under 15% free memory only one heavy command runs"
assert_contains "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TEST_TMP/hs.out")" "10%" "the denial reports the free memory"
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=25 hs_call pre "$(hs_in m2 "yarn build")"
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=25 hs_call pre "$(hs_in m3 "yarn build")"
assert_eq "deny|m1 m2" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")|$(hs_slots)" "under 30% free memory half the slots are used"
HM_HEAVY_SLOTS=4 HM_HEAVY_MEM_FREE_PCT=60 hs_call pre "$(hs_in m3 "yarn build")"
assert_eq "m1 m2 m3" "$(hs_slots)" "with enough memory the configured limit applies"
rm -f "$HS_DIR"/*.json

# 동시에 온 hook 여럿 중 상한만큼만 얻는다(lock).
# 각 hook의 부모(에이전트 역할) 서브셸은 끝까지 살아 있어야 한다 — 먼저 끝나면 그 슬롯이 회수돼 다른 hook이 얻는다.
# 여섯 hook이 모두 판정을 마칠 때까지 각 부모가 살아 있는다(고정 3초 대신 완료 표지를 기다린다).
rm -f "$TEST_TMP"/hs-conc-done-*
for i in 1 2 3 4 5 6; do
  {
    HM_HEAVY_SLOTS=2 hs_call pre "$(hs_in "c$i" "yarn build")"
    : >"$TEST_TMP/hs-conc-done-$i"
    for _ in $(seq 1 100); do [[ "$(find "$TEST_TMP" -maxdepth 1 -name 'hs-conc-done-*' | wc -l | tr -d ' ')" -ge 6 ]] && break; sleep 0.1; done
  } &
done
wait
assert_eq "6" "$(find "$TEST_TMP" -maxdepth 1 -name 'hs-conc-done-*' | wc -l | tr -d ' ')" "every concurrent hook finished its decision"
assert_eq "2" "$(find "$HS_DIR" -maxdepth 1 -name 'c*.json' | wc -l | tr -d ' ')" "concurrent hooks take exactly the configured number of slots"
rm -f "$HS_DIR"/*.json
# 죽은 pid가 쥔 lock은 회수한다.
HS_DEAD_LOCK="$(bash -c 'echo $$')"
mkdir -p "$HS_DIR/.lock" && printf '%s\n' "$HS_DEAD_LOCK" >"$HS_DIR/.lock/pid"
hs_call pre "$(hs_in l1 "yarn build")"
assert_eq "l1" "$(hs_slots)" "a stale lock from a dead hook is taken over"
rm -f "$HS_DIR"/*.json
# owner를 읽은 뒤 그 owner가 release하고 끝나 다른 프로세스가 새 lock을 잡았으면, 죽은 owner를 근거로 새 lock을 지우지 않는다.
# (지우면 둘이 동시에 lock 안에 들어가 상한보다 많은 슬롯을 쓴다 — CI flaky 'expected=2 actual=3'.)
HS_RACE_LOCK="$TEST_TMP/race.lock"
mkdir -p "$HS_RACE_LOCK" && printf '%s\n' "$HS_DEAD_LOCK" >"$HS_RACE_LOCK/pid"
HS_RACE_ROUND="$TEST_TMP/race.round"
: >"$HS_RACE_ROUND"
assert_eq "1|$$" "$(
  sed() { # 첫 owner 읽기 직후 다른 살아 있는 프로세스(이 테스트)가 lock을 새로 잡은 상황을 만든다
    command sed "$@"
    if [[ ! -s "$HS_RACE_ROUND" ]]; then printf x >"$HS_RACE_ROUND"; printf '%s\n' "$$" >"$HS_RACE_LOCK/pid"; fi
  }
  hm_acquire_lock "$HS_RACE_LOCK" 3 && r=0 || r=1
  printf '%s|%s' "$r" "$(command sed -n '1p' "$HS_RACE_LOCK/pid" 2>/dev/null)"
)" "a lock re-acquired after its dead owner was read is not deleted"
rm -rf "$HS_RACE_LOCK" "$HS_RACE_ROUND"

# 깨진 입력·tool_use_id 없음은 그대로 통과한다.
hs_call pre '{broken'
assert_eq "0|" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")" "malformed input fails open"
hs_call pre "$(jq -cn '{tool_name:"Bash", tool_input:{command:"yarn build"}}')"
assert_eq "0||" "$(<"$TEST_TMP/hs.rc")|$(<"$TEST_TMP/hs.out")|$(hs_slots)" "input without tool_use_id fails open"
unset HM_HEAVY_SLOTS HM_HEAVY_MEM_FREE_PCT HM_HEAVY_WAIT
pass "heavy command slots"

# 백그라운드 서버: PostToolUse는 띄운 직후 오므로 반환하지 않고, 감시자가 찾은 그룹이 사는 동안 쥔다.
# 이 하위 검사는 위 watchdog 검사와 같은 실프로세스 관찰 도구를 쓴다.
if ! ps -A -o pid=,ppid=,pgid=,args= >/dev/null 2>&1; then
  printf '%s\n' '# skip: background heavy process test needs ps access'
else
mkdir -p "$TEST_TMP/hs-bin"
printf '%s\n' '#!/bin/bash' 'while :; do sleep 1; done' >"$TEST_TMP/hs-bin/yarn"
chmod +x "$TEST_TMP/hs-bin/yarn"
HS_BG_CMD="yarn dev --port 39999 $TEST_TMP/hs-bg"
export HM_HEAVY_SLOTS=1 HM_HEAVY_MEM_FREE_PCT=80 HM_HEAVY_WAIT=0
hs_call pre "$(hs_in bg1 "$HS_BG_CMD" true)"
assert_eq "bg1" "$(hs_slots)" "a background heavy command takes a slot"
PATH="$TEST_TMP/hs-bin:$PATH" BG_TOOL_USE_ID=bg1 bg_start hs-bg "$HS_BG_CMD"
for _ in $(seq 1 50); do [[ -f "$HARNESS_METRICS_DIR/bg-watchdog/$BG_GROUP/tool_use_id" ]] && break; sleep 0.1; done
assert_eq "bg1" "$(cat "$HARNESS_METRICS_DIR/bg-watchdog/$BG_GROUP/tool_use_id" 2>/dev/null)" "the watchdog records which call its group belongs to"
hs_call post "$(hs_in bg1 "$HS_BG_CMD" true)"
assert_eq "bg1" "$(hs_slots)" "PostToolUse keeps a background slot"
jq '.started -= 600' "$HS_DIR/bg1.json" >"$TEST_TMP/hs.tmp" && mv "$TEST_TMP/hs.tmp" "$HS_DIR/bg1.json"
hs_call pre "$(hs_in bg2 "yarn build")"
assert_eq "deny|bg1" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")|$(hs_slots)" "a background slot is held while its watched group lives"
kill -KILL -- "-$BG_GROUP" 2>/dev/null || true
bg_group_gone "$BG_GROUP" 5 || fail "test group did not stop"
for _ in $(seq 1 30); do [[ -d "$HARNESS_METRICS_DIR/bg-watchdog/$BG_GROUP" ]] || break; sleep 0.2; done
hs_call pre "$(hs_in bg2 "yarn build")"
[[ "$(hs_slots)" == bg2 ]] || fail "the background slot frees once its group is gone: slots=$(hs_slots) claims=$(find "$HARNESS_METRICS_DIR/bg-watchdog" 2>/dev/null | tr '\n' ' ') slot=$(cat "$HS_DIR"/*.json 2>/dev/null) out=$(cat "$TEST_TMP/hs.out")"
bg_stop_agent
rm -f "$HS_DIR"/*.json
fi

# 감시자가 KILL로 죽어 선점 디렉토리만 남으면(그룹은 없음) 슬롯을 쥐지 않는다.
# ps가 막혀 위 실프로세스 검사가 건너뛰어도 이후 합성 슬롯 검사는 계속 켠다.
export HM_HEAVY_SLOTS=1 HM_HEAVY_MEM_FREE_PCT=80 HM_HEAVY_WAIT=0
jq -cn --argjson a "$$" '{tool_use_id:"bg3", agent:$a, cmd:"yarn dev", bg:true, transcript:"", started:((now|floor) - 600)}' >"$HS_DIR/bg3.json"
# 이 환경의 PID 한계보다 큰 수라 어떤 살아 있는 프로세스 그룹도 가리키지 않는다.
HS_DEAD_GROUP=2147483647
kill -0 -- "-$HS_DEAD_GROUP" 2>/dev/null && fail "the orphan claim fixture group must be absent"
mkdir -p "$HARNESS_METRICS_DIR/bg-watchdog/$HS_DEAD_GROUP" && printf bg3 >"$HARNESS_METRICS_DIR/bg-watchdog/$HS_DEAD_GROUP/tool_use_id"
hs_call pre "$(hs_in bg4 "yarn build")"
assert_eq "bg4" "$(hs_slots)" "a leftover claim whose group is gone does not hold the slot"
rm -rf "${HARNESS_METRICS_DIR:?}/bg-watchdog/$HS_DEAD_GROUP" "$HS_DIR"/*.json

# 상한을 이 세션의 백그라운드 서버만 쥐고 있으면 기다려도 풀리지 않는다 — 기다리지 않고 바로 알린다.
jq -cn --argjson a "$$" '{tool_use_id:"own1", agent:$a, cmd:"yarn dev -p 3000", bg:true, transcript:"", started:(now|floor)}' >"$HS_DIR/own1.json"
HS_START=$SECONDS
HM_HEAVY_WAIT=20 hs_call pre "$(hs_in own2 "yarn build")"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")" "a slot held only by this session's own server is denied"
assert_eq "1" "$((SECONDS - HS_START < 5))" "the own-server denial does not wait"
assert_contains "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TEST_TMP/hs.out")" "이 세션이 백그라운드로 띄운 서버" "the denial says the session's own server holds the slot"
# 다른 세션의 서버면 기다린다(여기서는 다른 살아 있는 pid로 흉내).
sleep 30 &
HS_OTHER=$!
jq --argjson a "$HS_OTHER" '.agent = $a' "$HS_DIR/own1.json" >"$TEST_TMP/hs.tmp" && mv "$TEST_TMP/hs.tmp" "$HS_DIR/own1.json"
# 백그라운드 명령은 감시자가 그룹을 놓치지 않게 HM_HEAVY_BG_WAIT(기본 60초)까지만 기다린다.
HS_START=$SECONDS
HM_HEAVY_WAIT=20 HM_HEAVY_BG_WAIT=1 hs_call pre "$(hs_in own3 "yarn start" true)"
assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$TEST_TMP/hs.out")" "a background command waiting for another session is denied after its short wait"
assert_eq "1" "$((SECONDS - HS_START < 8))" "a background command waits only HM_HEAVY_BG_WAIT"
kill "$HS_OTHER" 2>/dev/null; wait "$HS_OTHER" 2>/dev/null || true
unset HM_HEAVY_SLOTS HM_HEAVY_MEM_FREE_PCT HM_HEAVY_WAIT
rm -f "$HS_DIR"/*.json
pass "background heavy commands hold their slot while the server lives"

finish_tests
