#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: HM_TARGET_CI wait·notify(분리 감시)
# 실행: bash tests/run.sh workflow-merge-tci
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"
# shellcheck source=tests/lib-merge-tci.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge-tci.sh"

# B1: 설정이 없으면 wait — 지금처럼 기다리고, 끝까지 진행 중이면 incomplete로 resume을 기다린다.
tci_run pm_tci_wait
assert_eq "0:done:wait:default" "$DRIVER_RC:$(run_state .status):$(run_state .policy.merge.target_ci):$(run_state .policy.merge.target_ci_source)" "target CI waits by default"
FAKE_TCI_WATCH=pending tci_run pm_tci_wait_pending "HM_TARGET_CI=wait"
assert_eq "30:incomplete:post_merge_verify" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "wait leaves a still-running merge CI resumable"
assert_eq "null" "$(run_state '.post_merge.target_ci.watcher // null')" "wait starts no watcher"
pass "HM_TARGET_CI wait keeps waiting for the merge commit CI"

# B2: notify에서 한 번 읽은 결과가 진행 중이면 tracked로 두고 감시를 띄운 뒤 done. 감시는 끝나면 결과를 상태에 남긴다.
# 감시는 게이트 파일이 생길 때까지 결과를 내지 않는다. 러너가 남긴 tracked를 본 뒤 게이트를 연다(#658).
TCI_GATE="$DRIVER_TMP/tci-watch.gate"
FAKE_TCI_ONCE=pending FAKE_TCI_WATCH=passed FAKE_TCI_WATCH_GATE="$TCI_GATE" tci_run pm_tci_notify "HM_TARGET_CI=notify"
assert_eq "0:done:notify:HM_TARGET_CI" "$DRIVER_RC:$(run_state .status):$(run_state .policy.merge.target_ci):$(run_state .policy.merge.target_ci_source)" "notify finishes the run while the merge CI is still running"
assert_eq "tracked" "$(run_state .post_merge.target_ci.status)" "the pending merge CI is tracked"
[[ "$(run_state '.post_merge.target_ci.watcher.pid')" =~ ^[0-9]+$ ]] || fail "the watcher pid is recorded (actual=$(run_state '.post_merge.target_ci.watcher.pid'))"
assert_contains "$(<"$(tci_dir)/post-merge-ci.prompt")" "Do not wait" "the notify read is told not to wait"
assert_contains "$DRIVER_OUT" "target_ci tracked" "done reports the tracked merge CI"
touch "$TCI_GATE"
for _ in $(seq 1 100); do
  [[ "$(run_state '.post_merge.target_ci.watched_at // ""')" == "" ]] || break
  sleep 0.2
done
assert_eq "passed:done:0" "$(run_state '"\(.post_merge.target_ci.status):\(.status):\(.alerts // [] | length)"')" "the watcher records a passing merge CI without an alert and leaves the run done"
grep -q "ALERT:" "$(tci_dir)/progress.log" && fail "a passing merge CI raises no alert"
pass "HM_TARGET_CI notify tracks a running merge CI with a detached watcher"

finish_tests
