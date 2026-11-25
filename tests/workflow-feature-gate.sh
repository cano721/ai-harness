#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 원격 CI 최종 관문(feature)
# 실행: bash tests/run.sh workflow-feature-gate
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-workflow-feature.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-workflow-feature.sh"

# 원격 CI가 있는 저장소(러너가 push하는 git_policy + CI 설정 파일)에서는 final_checks를 로컬에서 돌리지 않고
# 원격 CI를 최종 관문으로 삼는다. 시작 때 .policy.final_gate로 고정하고, 미룬 검사는 progress·상태·publish 프롬프트에 따로 남긴다. (#557)
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

finish_tests
