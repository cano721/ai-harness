#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 병합 성공·승인 대기·현재 head/작성자/권한 승인 조건
# 실행: bash tests/run.sh workflow-merge
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
merge_run merge_ok "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "merge policy merges and verifies when every condition holds"
assert_contains "$(<"$FAKE_LOG")" "gh merge https://github.com/acme/app/pull/7 --squash --match-head-commit $(git -C "$DRIVER_REPO" rev-parse HEAD)" "the runner merges with the head pinned to the reviewed, pushed commit"
assert_contains "$(<"$FAKE_LOG")" "gh api repos/acme/app" "the merge method is read from the repository settings"
assert_eq "remote_ci,merge,post_merge_verify" "$(run_state '[.history[] | select(.from | IN("remote_ci", "merge", "post_merge_verify")) | .from] | join(",")')" "merge follows remote CI and is verified after"
assert_eq "1111111111111111111111111111111111111111:alice:passed" "$(run_state '"\(.merge.commit):\(.merge.approvals | join(",")):\(.post_merge.target_ci.status)"')" "the merge commit and the approvers are recorded"
assert_contains "$DRIVER_OUT" "merged: 111111111111 (squash); after merge: target_ci passed" "done reports the merge and the post-merge checks"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "Never merge (under merge the driver merges later" "the publish node still never merges by itself"
# 승인이 아직 없으면 병합하지 않고 기다리며, resume이 다시 본다.
merge_run merge_wait "$MP_BASIC"
assert_eq "30:incomplete:merge" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "missing human approval waits at merge"
assert_contains "$DRIVER_OUT" "human approval: 0 of 1 on the current head" "the wait names the unmet condition"
assert_eq "0" "$(grep -c '^gh merge' "$FAKE_LOG" || true)" "nothing is merged while a condition is unmet"
touch "$FAKE_LOG.approved"
driver resume
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG")" "resume merges once the approval arrives"
# 승인은 지금 head에 대한 것이고 작성자 본인이 아니어야 한다.
merge_run merge_stale "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval of an older commit does not count"
merge_run merge_self "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "the author's own approval does not count"
merge_run merge_outsider "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval from an account without write access does not count"
unset FAKE_PROTECTION
pass "merge node: host rules, repository facts, merge by the runner (approval conditions)"

# 병합 뒤 target_ci 개인 설정 HM_TARGET_CI(wait 기본|notify, 저장소별 HM_TARGET_CI_REPOS가 우선). (#557)
# notify는 한 번만 읽고, 진행 중이면 분리 감시(watch-target-ci)를 띄운 뒤 done으로 끝난다. 감시는 실패를 ALERT·.alerts·데스크톱 알림으로 남긴다.
export FAKE_PROTECTION=classic HM_DESKTOP_NOTIFY=0
NOTIFY_BIN="$DRIVER_TMP/notify-bin"
NOTIFY_LOG="$DRIVER_TMP/notify.log"
mkdir -p "$NOTIFY_BIN"
for notifier in osascript notify-send; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >>%q\n' "$notifier" "$NOTIFY_LOG" >"$NOTIFY_BIN/$notifier"
  chmod +x "$NOTIFY_BIN/$notifier"
done
tci_run() { # scenario [config-line] → 단계 merge, target_ci만 검증하는 런
  new_driver_repo "$1"
  with_policy pr-only auto
  as_host_repo github.com/acme/app
  jq '.merge_policy = {"verify":["target_ci"],"base":"main"}' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" \
    && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  printf 'HM_APPROVAL=auto\nHM_DELIVERY_LEVEL=merge\n%s\n' "${2:-}" >"$MR_DATA/config"
  DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "add feature"
}
tci_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }

# B1: 설정이 없으면 wait — 지금처럼 기다리고, 끝까지 진행 중이면 incomplete로 resume을 기다린다.
tci_run pm_tci_wait
assert_eq "0:done:wait:default" "$DRIVER_RC:$(run_state .status):$(run_state .policy.merge.target_ci):$(run_state .policy.merge.target_ci_source)" "target CI waits by default"
FAKE_TCI_WATCH=pending tci_run pm_tci_wait_pending "HM_TARGET_CI=wait"
assert_eq "30:incomplete:post_merge_verify" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "wait leaves a still-running merge CI resumable"
assert_eq "null" "$(run_state '.post_merge.target_ci.watcher // null')" "wait starts no watcher"
pass "HM_TARGET_CI wait keeps waiting for the merge commit CI"

# B2: notify에서 한 번 읽은 결과가 진행 중이면 tracked로 두고 감시를 띄운 뒤 done. 감시는 끝나면 결과를 상태에 남긴다.
FAKE_TCI_ONCE=pending FAKE_TCI_WATCH=passed tci_run pm_tci_notify "HM_TARGET_CI=notify"
assert_eq "0:done:notify:HM_TARGET_CI" "$DRIVER_RC:$(run_state .status):$(run_state .policy.merge.target_ci):$(run_state .policy.merge.target_ci_source)" "notify finishes the run while the merge CI is still running"
assert_eq "tracked" "$(run_state .post_merge.target_ci.status)" "the pending merge CI is tracked"
[[ "$(run_state '.post_merge.target_ci.watcher.pid')" =~ ^[0-9]+$ ]] || fail "the watcher pid is recorded (actual=$(run_state '.post_merge.target_ci.watcher.pid'))"
assert_contains "$(<"$(tci_dir)/post-merge-ci.prompt")" "Do not wait" "the notify read is told not to wait"
assert_contains "$DRIVER_OUT" "target_ci tracked" "done reports the tracked merge CI"
for _ in $(seq 1 100); do
  [[ "$(run_state '.post_merge.target_ci.watched_at // ""')" == "" ]] || break
  sleep 0.2
done
assert_eq "passed:done:0" "$(run_state '"\(.post_merge.target_ci.status):\(.status):\(.alerts // [] | length)"')" "the watcher records a passing merge CI without an alert and leaves the run done"
grep -q "ALERT:" "$(tci_dir)/progress.log" && fail "a passing merge CI raises no alert"
pass "HM_TARGET_CI notify tracks a running merge CI with a detached watcher"

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

# B5: 저장소별 설정이 전체 설정보다 우선하고, 잘못된 값은 start를 막는다.
FAKE_TCI_ONCE=passed tci_run pm_tci_repos "HM_TARGET_CI=wait
HM_TARGET_CI_REPOS=repo-pm_tci_repos=notify"
assert_eq "notify:HM_TARGET_CI_REPOS:repo-pm_tci_repos" "$(run_state .policy.merge.target_ci):$(run_state .policy.merge.target_ci_source)" "HM_TARGET_CI_REPOS wins over HM_TARGET_CI"
tci_run pm_tci_bogus "HM_TARGET_CI=bogus"
assert_eq "2" "$DRIVER_RC" "an unknown HM_TARGET_CI stops start"
assert_contains "$DRIVER_OUT" "HM_TARGET_CI in $MR_DATA/config is \"bogus\"; target CI must be wait or notify" "the error names the setting and the allowed values"
unset FAKE_PROTECTION HM_DESKTOP_NOTIFY
pass "HM_TARGET_CI_REPOS wins and an invalid HM_TARGET_CI is refused"

finish_tests
