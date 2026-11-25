#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 검사 재사용·병렬 안내·원격 CI 수리(feature)
# 실행: bash tests/run.sh workflow-feature-checks
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-workflow-feature.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-workflow-feature.sh"

unset HM_TEST_JOBS
# 같은 트리에서 러너가 이미 통과시킨 같은 명령은 다시 돌리지 않고 재사용으로 남긴다. 트리가 바뀌면(미추적 파일 포함) 다시 돌고,
# 실패는 같은 트리에서도 다시 돈다. 명령마다 걸린 초를 progress.log·checks.json·status에 남긴다. (#513)
REUSE_LOG="$DRIVER_TMP/check-reuse.log"
: >"$REUSE_LOG"
REUSE_D="printf 'D\\n' >>'$REUSE_LOG'; grep -q fixed feature.txt"
FAKE_CHECK="printf 'C\\n' >>'$REUSE_LOG'" start_and_approve check_reuse --check "$REUSE_D"
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a run with a repaired check reaches done"
git -C "$DRIVER_REPO" ls-files --error-unmatch feature.txt >/dev/null 2>&1 && fail "feature.txt should stay untracked for this case"
assert_eq "2" "$(grep -c '^C$' "$REUSE_LOG")" "a passing check runs again after an untracked file changed the tree"
assert_eq "2" "$(grep -c '^D$' "$REUSE_LOG")" "a check that passed on this tree is not run again"
assert_contains "$(<"$(run_dir)/progress.log")" "check reused: $REUSE_D (tree " "the reuse is logged with the tree"
assert_eq "1" "$(jq -s '[.[][] | select(.reused == true and .command == $c)] | length' --arg c "$REUSE_D" "$(run_dir)"/*.checks.json)" "checks.json marks the reused check"
grep -Eq "check passed: printf 'C.* \([0-9]+s\)$" "$(run_dir)/progress.log" || fail "progress.log records the seconds a passing check took: $(<"$(run_dir)/progress.log")"
grep -Eq "check failed: printf 'D.* \(exit 1, [0-9]+s\)$" "$(run_dir)/progress.log" || fail "progress.log records the exit code and seconds of a failing check"
assert_eq "true" "$(jq -s 'map(.[] | select(.reused != true) | .seconds | type == "number" and . == floor) | all' "$(run_dir)"/*.checks.json)" "every run check records whole seconds"
driver status
assert_contains "$DRIVER_OUT" "printf 'D\\n' >>'$REUSE_LOG'; grep -q fixed feature.txt reused 0s" "status shows the latest checks with their outcome and seconds"
printf '%s\n' "$DRIVER_OUT" | grep -Eq "^checks [^:]+: printf 'C.* passed [0-9]+s$" || fail "status shows a passed check with its seconds: $DRIVER_OUT"
FAIL_LOG="$DRIVER_TMP/check-fail-rerun.log"
: >"$FAIL_LOG"
FAKE_CHECK="printf 'F\\n' >>'$FAIL_LOG'; false" start_and_approve check_fail_rerun
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a check that keeps failing goes to a person"
assert_eq "3" "$(grep -c '^F$' "$FAIL_LOG")" "a failing check runs again on the same tree (the second repair left the tree unchanged)"
pass "the runner reuses a check that passed on the same tree and records each check's seconds"

# Brief는 병렬 옵션을 checks·final_checks에 숫자로 적지 말라는 안내를 받는다 — 리터럴 -j N은 러너의 HM_TEST_JOBS를 무시한다. (#544)
unset HM_TEST_JOBS
start_and_approve brief_jobs_guidance
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "leave its parallelism option out of checks and final_checks" "the brief node is told to leave the parallelism option out of checks"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "never a literal number" "the brief node is told never to write a literal parallelism number"
pass "the brief prompt forbids a literal parallelism number in checks"
# 원격 CI가 실패하면 repair → 재리뷰를 거치고, 그 뒤에도 로컬 final_checks 없이 publish → remote_ci로 다시 간다.
gate_repo gate_ci_fail_once pr-only yes
gate_run
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state .attempts)" "a remote CI failure is repaired and pushed again"
assert_eq "" "$(cat "$GATE_LOG")" "the final checks do not run locally after the repair either"
assert_eq "remote_ci,repair,publish,remote_ci" "$(run_state '[.history[] | select(.from | IN("remote_ci", "repair", "publish")) | .from] | join(",")' | sed 's/^publish,//')" "the repair goes back through publish and remote CI"
pass "a remote CI failure goes back to remote CI without local final checks"

# 구현 노드와 brief 노드는 원격 CI가 있으면 그것이 최종 관문이라는 안내를 받는다.
assert_contains "$(<"$FAKE_LOG.deliver.prompt")" "the remote CI is the final gate" "deliver is told remote CI is the final gate"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "the remote CI is the final gate" "the brief node is told remote CI is the final gate"
pass "deliver and brief prompts name remote CI as the final gate"

finish_tests
