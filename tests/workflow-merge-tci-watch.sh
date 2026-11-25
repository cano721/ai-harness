#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: notify 실패 인계·watch-target-ci 알림
# 실행: bash tests/run.sh workflow-merge-tci-watch
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"
# shellcheck source=tests/lib-merge-tci.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge-tci.sh"

# B3: notify에서 한 번 읽은 결과가 실패면 지금처럼 사람에게 넘기고 되돌리기 안내를 붙인다.
FAKE_TCI_ONCE=failed tci_run pm_tci_notify_fail "HM_TARGET_CI=notify"
assert_eq "20:user_decision:failed" "$DRIVER_RC:$(run_state .status):$(run_state .post_merge.target_ci.status)" "a failed merge CI read once goes to a person"
assert_contains "$(run_state '.findings | join(" ")')" "git revert" "the failure carries rollback instructions"
assert_eq "null" "$(run_state '.post_merge.target_ci.watcher // null')" "an observed failure starts no watcher"
pass "HM_TARGET_CI notify hands an observed failure to a person"

# B4: 분리 감시를 직접 실행한다. 실패는 ALERT·.alerts·데스크톱 알림(HM_DESKTOP_NOTIFY=0이면 끔), 런의 status는 그대로다.
tci_run pm_tci_watch
TCI_RUN_ID="$(run_state .run_id)"
: >"$NOTIFY_LOG"
FAKE_TCI_WATCH=failed PATH="$NOTIFY_BIN:$PATH" driver watch-target-ci --run "$TCI_RUN_ID"
assert_eq "0:done:failed:1" "$DRIVER_RC:$(run_state .status):$(run_state .post_merge.target_ci.status):$(run_state '.alerts | length')" "the watcher records the failure and an alert without changing the run status"
assert_contains "$(<"$(tci_dir)/progress.log")" "ALERT: CI on main for merge commit 1111111111111111111111111111111111111111 failed" "the failure is an ALERT line in progress.log"
assert_contains "$(run_state '.alerts[0].rollback_hint')" "git revert" "the alert carries rollback instructions"
assert_eq "" "$(cat "$NOTIFY_LOG")" "HM_DESKTOP_NOTIFY=0 sends no desktop notification"
driver status --run "$TCI_RUN_ID"
assert_contains "$DRIVER_OUT" "ALERT " "status shows the alert"
FAKE_TCI_WATCH=failed HM_DESKTOP_NOTIFY=1 PATH="$NOTIFY_BIN:$PATH" driver watch-target-ci --run "$TCI_RUN_ID"
assert_eq "0:2" "$DRIVER_RC:$(run_state '.alerts | length')" "a second failure adds another alert"
assert_contains "$(cat "$NOTIFY_LOG")" "merge commit 1111111111111111111111111111111111111111" "a desktop notification is sent when allowed"
FAKE_TCI_WATCH=passed PATH="$NOTIFY_BIN:$PATH" driver watch-target-ci --run "$TCI_RUN_ID"
assert_eq "0:passed:2:done" "$DRIVER_RC:$(run_state .post_merge.target_ci.status):$(run_state '.alerts | length'):$(run_state .status)" "a passing result records passed without an alert"
pass "watch-target-ci alerts on a failed merge CI and leaves the finished run as it was"

finish_tests
