#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — stop 명령(자기 런만 멈춤)·stopped 재개·밖에서 끊긴 런(stale) 감지 (#495)
# 실행: bash tests/run.sh workflow-stop
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

use_repo() { # name → 그 저장소의 hang 시나리오로 driver·run_state를 맞춘다
  DRIVER_REPO="$(git -C "$DRIVER_TMP/repo-$1" rev-parse --show-toplevel)"
  FAKE_LOG="$DRIVER_TMP/$1.log"
  FAKE_SCENARIO=hang
}
start_hang() { # name → discover 노드에서 버티는 런을 백그라운드로 띄우고, 노드 자식 그룹이 기록될 때까지 기다린다
  new_driver_repo "$1"
  use_repo "$1"
  touch "$FAKE_LOG.hold"
  LC_ALL=C TZ=UTC driver start --runtime codex --request "add feature" &
  local child=""
  for _ in $(seq 1 50); do
    child="$(run_state '.process.child_pgid // ""' 2>/dev/null || true)"
    [[ -z "$child" ]] || return 0
    sleep 0.2
  done
  fail "the runner for $1 did not record its node process group within 10s"
}

# 1. 런 2개 중 하나만 멈춘다.
start_hang stopa
A_ID="$(run_state .run_id)" A_PID="$(run_state .process.pid)" A_CHILD="$(run_state .process.child_pgid)"
start_hang stopb
B_ID="$(run_state .run_id)" B_PID="$(run_state .process.pid)" B_CHILD="$(run_state .process.child_pgid)"
[[ "$A_PID" != "$B_PID" && "$A_CHILD" != "$B_CHILD" ]] || fail "each run records its own runner and node group"
use_repo stopa
# 러너는 LC_ALL=C TZ=UTC로 떴다. stop·resume은 다른 로케일·TZ에서 불러도 같은 러너로 알아봐야 한다(ps lstart 형식이 로케일·TZ를 따른다).
export LC_ALL=ko_KR.UTF-8 TZ=Pacific/Kiritimati
driver stop --run "$A_ID" --reason test
assert_eq "0" "$DRIVER_RC" "stop of a live run exits 0 ($DRIVER_OUT)"
assert_contains "$DRIVER_OUT" "stopped run $A_ID at discover" "stop says which run stopped at which node"
assert_eq "stopped:discover:test:true" "$(run_state '"\(.status):\(.stopped.node):\(.stopped.reason):\(.stopped.at != null)"')" "the stopped run records node, time, and reason"
! kill -0 "$A_PID" 2>/dev/null || fail "the stopped runner is gone"
! kill -0 -- "-$A_CHILD" 2>/dev/null || fail "the stopped node process group is gone"
use_repo stopb
kill -0 "$B_PID" 2>/dev/null || fail "the other run's runner keeps running"
kill -0 -- "-$B_CHILD" 2>/dev/null || fail "the other run's node process group keeps running"
assert_eq "running" "$(run_state .status)" "the other run stays running"
kill -0 $$ 2>/dev/null || fail "the shell that called stop is alive"
driver resume
assert_eq "2" "$DRIVER_RC" "resume of a live run is refused"
assert_contains "$DRIVER_OUT" "already running (pid $B_PID); stop it first: stop --run $B_ID" "the refusal points to stop"
driver stop --run "$B_ID"
assert_eq "0:stopped" "$DRIVER_RC:$(run_state .status)" "the other run stops too"
unset LC_ALL TZ
pass "stop ends only the processes its run recorded and leaves other runs and the caller alive, even from another locale and TZ"

# 2. 멈춘 런은 그 노드부터 resume으로 잇는다.
use_repo stopa
driver status
assert_contains "$DRIVER_OUT" "stopped at discover" "status shows where the run stopped"
assert_contains "$DRIVER_OUT" "test; continue with resume" "status shows the reason and the next step"
rm -f "$FAKE_LOG.hold"
driver resume
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "resume runs the stopped node again and reaches approval ($DRIVER_OUT)"
assert_contains "$(run_state '[.history[] | .from + ">" + .to] | join(",")')" "discover>brief" "the run continues from discover to brief"
driver stop
assert_eq "2" "$DRIVER_RC" "a run waiting for approval is not running"
assert_contains "$DRIVER_OUT" "is not running (status waiting_approval)" "stop says why it did nothing"
pass "a stopped run resumes at its node without --accept-changes"

# 3. 밖에서 끊긴 런은 stale로 보이고 resume으로 잇는다.
start_hang stale
S_PID="$(run_state .process.pid)" S_CHILD="$(run_state .process.child_pgid)"
kill -KILL "$S_PID" 2>/dev/null || true
kill -KILL -- "-$S_CHILD" 2>/dev/null || true
for _ in $(seq 1 25); do kill -0 "$S_PID" 2>/dev/null || break; sleep 0.2; done
driver status
assert_eq "0" "$DRIVER_RC" "status of a cut-off run exits 0"
assert_contains "$DRIVER_OUT" "stale: runner process $S_PID is gone (stopped outside the runner); continue with resume" "status shows the run as stale"
rm -f "$FAKE_LOG.hold"
driver resume
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "a stale run resumes to approval ($DRIVER_OUT)"
pass "a run killed outside the runner shows as stale and resumes"

# 3-1. 러너만 밖에서 죽고 노드 자식 그룹이 남으면, resume은 겹쳐 돌지 않게 거부하고 stop이 그 그룹을 끈다.
start_hang orphan
O_ID="$(run_state .run_id)" O_PID="$(run_state .process.pid)" O_CHILD="$(run_state .process.child_pgid)"
kill -KILL "$O_PID" 2>/dev/null || true
for _ in $(seq 1 25); do kill -0 "$O_PID" 2>/dev/null || break; sleep 0.2; done
kill -0 -- "-$O_CHILD" 2>/dev/null || fail "the node process group outlives a runner killed alone"
driver status
assert_contains "$DRIVER_OUT" "node process group $O_CHILD is still running" "status shows the orphaned node group"
driver resume
assert_eq "2" "$DRIVER_RC" "resume is refused while the orphaned node group runs"
assert_contains "$DRIVER_OUT" "stop it first: stop --run $O_ID" "the refusal points to stop"
kill -0 -- "-$O_CHILD" 2>/dev/null || fail "a refused resume leaves the node group alone"
driver stop --run "$O_ID"
assert_eq "0:stopped" "$DRIVER_RC:$(run_state .status)" "stop of a run whose runner is gone exits 0 and records stopped"
! kill -0 -- "-$O_CHILD" 2>/dev/null || fail "stop ends the orphaned node process group"
rm -f "$FAKE_LOG.hold"
driver resume
assert_eq "10:approval" "$DRIVER_RC:$(run_state .node)" "the run resumes after stop ($DRIVER_OUT)"
pass "a node group orphaned by a runner killed alone blocks resume until stop ends it"

# 4. --reason은 stop에만, 런이 없으면 2.
use_repo stopa
driver status --reason x
assert_eq "2" "$DRIVER_RC" "--reason belongs to stop"
new_driver_repo stopnone
driver stop
assert_eq "2" "$DRIVER_RC" "stop without a run exits 2"
pass "stop rejects --reason elsewhere and a missing run"

# 5. 실행 지침이 stop을 쓰고 패턴 kill을 금지한다.
for f in "$ROOT"/templates/{implement-feature,fix-bug,review,investigate,design-polish}/SKILL.md "$ROOT/skills/harness-init/SKILL.md"; do
  assert_contains "$(<"$f")" "workflow-driver.sh stop" "$f tells agents to stop a run with stop"
  assert_contains "$(<"$f")" "pkill" "$f forbids pattern kill"
done
cmp -s "$ROOT/templates/workflow-driver/workflow-driver.sh" "$ROOT/.ai-harness/workflows/workflow-driver.sh" || fail "the installed runner copy matches the template"
pass "adapters and delegation guide tell agents to use stop, not pattern kill"

finish_tests
