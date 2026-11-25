#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — revise 복귀·HM_TEST_JOBS 전달(feature)
# 실행: bash tests/run.sh workflow-feature-revise
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-workflow-feature.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-workflow-feature.sh"

# 멈춘 deliver에서 revise하면 그래프의 deliver → brief 엣지로 Brief를 다시 만든다. 이전 승인은 무효다.
new_driver_repo revise_stopped
FAKE_SCENARIO=noop
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "30:incomplete:deliver" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "deliver stopped without a change"
rm -f "$DRIVER_TMP/claude/projects/p/noop.jsonl"
driver revise --feedback "CSV 내보내기가 빠졌다"
assert_eq "10:waiting_approval:approval" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "revise at a stopped deliver rebuilds the brief and waits again"
assert_contains "$(brief_history)" "deliver --brief_revised--> brief" "revise follows the deliver -> brief edge"
assert_contains "$(<"$FAKE_LOG.revise")" "CSV 내보내기가 빠졌다" "the new brief gets the feedback"
assert_eq "null" "$(run_state .approval)" "the earlier approval no longer holds"

# 실행 중인 deliver에서 revise하면 러너를 죽이지 않고 요청 파일만 남긴다. 러너는 세션이 끝난 뒤 review 대신 brief로 간다.
new_driver_repo revise_midway
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "0" "$(<"$FAKE_LOG.midway.rc")" "revise during a running deliver ends with 0"
assert_contains "$(<"$FAKE_LOG.midway.out")" "brief" "revise says the run returns to the brief after the session"
assert_file "$FAKE_LOG.midway.requested"
assert_contains "$(brief_history)" "deliver --brief_revised--> brief" "the runner returns to the brief after the deliver session"
assert_eq "10:waiting_approval:approval" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "the new brief waits for its own approval"
assert_eq "discover;brief;deliver;brief" "$(cut -d' ' -f1 "$FAKE_LOG" | paste -sd ';' -)" "no review runs between the revised deliver and the new brief"
assert_not_file "$(run_dir)/revise-request.json"
assert_contains "$(<"$FAKE_LOG.revise")" "CSV 내보내기가 빠졌다" "the new brief gets the feedback written during deliver"
assert_contains "$(<"$FAKE_LOG.revise")" "Changes already made in this run" "the new brief sees what deliver already changed"
assert_contains "$(<"$FAKE_LOG.revise")" "feature.txt" "the changes deliver made stay"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "the run continues after the new brief is approved"

# brief_revised 엣지가 없는 노드에서는 revise를 받지 않는다.
new_driver_repo revise_refused
FAKE_SCENARIO=bad_review
driver start --runtime codex --request "add feature"
say_in_claude "승인"
driver resume
assert_eq "30:review" "$DRIVER_RC:$(run_state .node)" "review stopped on a broken output"
driver revise --feedback "x"
assert_eq "2" "$DRIVER_RC" "revise is refused at a node without a brief_revised edge"
assert_contains "$DRIVER_OUT" "approval, deliver" "the refusal names the nodes that take revise"
pass "revise returns from deliver to the brief without killing the runner"

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

finish_tests
