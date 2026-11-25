#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — HM_TEST_JOBS·검사 재사용·원격 CI 최종 관문(feature)
# 실행: bash tests/run.sh workflow-feature-jobs
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

run_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
brief_history() { run_state '.history | map("\(.from) --\(if .outcome == "" then "next" else .outcome end)--> \(.to)") | join(";")'; }

# 러너는 모든 검사에 HM_TEST_JOBS를 넘긴다: 설정이 없으면 max(1, min(ncpu/2, 4)), ~/.ai-harness/config의 값이 있으면 그 값,
# 1 이상의 정수가 아니면 기본값을 쓰고 안내를 남긴다. Brief는 병렬 옵션에 이 값을 넘기라는 안내를, deliver는 전체 회귀를 직접
# 돌리지 말라는 안내를 받는다. (#513)
unset HM_TEST_JOBS
JOBS_FILE="$DRIVER_TMP/check-jobs"
JOBS_CHECK="printf %s \"\$HM_TEST_JOBS\" >'$JOBS_FILE'"
FAKE_CHECK="$JOBS_CHECK" start_and_approve check_jobs_default
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a run whose check records HM_TEST_JOBS reaches done"
[[ "$(<"$JOBS_FILE")" =~ ^[1-4]$ ]] || fail "the default HM_TEST_JOBS is an integer from 1 to 4 (actual=$(<"$JOBS_FILE"))"
assert_contains "$(<"$FAKE_LOG.brief.prompt")" "\$HM_TEST_JOBS" "the brief node is told to pass HM_TEST_JOBS to the test runner's parallelism option"
assert_contains "$(<"$FAKE_LOG.deliver.prompt")" "run only the tests for the areas your Red/Green steps target" "deliver runs only the Red/Green target areas"
assert_contains "$(<"$FAKE_LOG.deliver.prompt")" "the driver runs the full regression (final_checks) once after the review finds nothing blocking, or leaves it to the remote CI" "deliver is told who runs the full regression"
new_driver_repo check_jobs_config
printf 'HM_TEST_JOBS=3\n' >"$DRIVER_TMP/data/config"
FAKE_CHECK="$JOBS_CHECK" driver start --runtime codex --request "add feature"
say_in_claude "승인"
FAKE_CHECK="$JOBS_CHECK" driver resume
assert_eq "0:3" "$DRIVER_RC:$(<"$JOBS_FILE")" "HM_TEST_JOBS in ~/.ai-harness/config sets the value checks receive"
new_driver_repo check_jobs_invalid
printf 'HM_TEST_JOBS=lots\n' >"$DRIVER_TMP/data/config"
FAKE_CHECK="$JOBS_CHECK" driver start --runtime codex --request "add feature"
say_in_claude "승인"
FAKE_CHECK="$JOBS_CHECK" driver resume
assert_eq "0" "$DRIVER_RC" "an invalid HM_TEST_JOBS does not stop the run"
[[ "$(<"$JOBS_FILE")" =~ ^[1-4]$ ]] || fail "an invalid HM_TEST_JOBS falls back to the default (actual=$(<"$JOBS_FILE"))"
assert_contains "$(<"$(run_dir)/progress.log")" "HM_TEST_JOBS in $DRIVER_TMP/data/config is not a positive integer" "an invalid HM_TEST_JOBS is reported once in the log"
: >"$DRIVER_TMP/data/config"
pass "the runner passes HM_TEST_JOBS to every check"

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

# 원격 CI가 있는 저장소(러너가 push하는 git_policy + CI 설정 파일)에서는 final_checks를 로컬에서 돌리지 않고
# 원격 CI를 최종 관문으로 삼는다. 시작 때 .policy.final_gate로 고정하고, 미룬 검사는 progress·상태·publish 프롬프트에 따로 남긴다. (#557)
GATE_LOG="$DRIVER_TMP/final-gate.log"
gate_repo() { # scenario git_policy(빈 값이면 manifest 없음) ci(yes면 CI 설정 파일을 커밋)
  new_driver_repo "$1"
  [[ -z "$2" ]] || with_policy "$2" ""
  if [[ "$3" == yes ]]; then
    mkdir -p "$DRIVER_REPO/.github/workflows"
    printf 'on: push\n' >"$DRIVER_REPO/.github/workflows/test.yml"
    git -C "$DRIVER_REPO" add .github && git -C "$DRIVER_REPO" commit -qm ci
  fi
  : >"$GATE_LOG"
}
gate_run() {
  FAKE_FINAL_CHECK="printf 'final\\n' >>'$GATE_LOG'" driver start --runtime codex --request "add feature"
  say_in_claude "승인"
  FAKE_FINAL_CHECK="printf 'final\\n' >>'$GATE_LOG'" driver resume
}
gate_repo gate_remote pr-only yes
gate_run
assert_eq "0:done:remote_ci" "$DRIVER_RC:$(run_state .status):$(run_state .policy.final_gate)" "a pushed run in a repository with CI fixes the final gate to remote CI"
assert_eq "" "$(cat "$GATE_LOG")" "the final checks do not run locally when remote CI is the final gate"
assert_contains "$(<"$(run_dir)/progress.log")" "final checks left to remote CI: printf 'final" "the deferred final checks are logged"
assert_eq "remote_ci:1" "$(run_state '"\(.final_gate.mode):\(.final_gate.deferred | length)"')" "the state records the deferred final checks"
GATE_PUBLISH="$(<"$FAKE_LOG.publish.prompt")"
assert_eq "Checks the driver ran: true" "$(grep '^Checks the driver ran:' <<<"$GATE_PUBLISH")" "publish lists only the checks the driver ran"
assert_contains "$GATE_PUBLISH" "Final checks left to remote CI: printf 'final" "publish names the final checks left to remote CI"
pass "remote CI is the final gate: final checks do not run locally"

gate_repo gate_no_ci pr-only no
gate_run
assert_eq "0:done:local" "$DRIVER_RC:$(run_state .status):$(run_state .policy.final_gate)" "a repository without CI configuration keeps the local final gate"
assert_eq "final" "$(cat "$GATE_LOG")" "the final checks run locally without remote CI"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "Checks the driver ran: true ; printf 'final" "publish lists the final checks the driver ran"
gate_repo gate_no_push "" yes
gate_run
assert_eq "0:done:local" "$DRIVER_RC:$(run_state .status):$(run_state .policy.final_gate)" "a git_policy that does not push keeps the local final gate even with CI configuration"
assert_eq "final" "$(cat "$GATE_LOG")" "the final checks run locally when nothing is pushed"
pass "the final checks run locally when the run cannot reach remote CI"

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
