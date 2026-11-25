#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — release 워크플로(#493): 단계 deploy verify_cmd
# 실행: bash tests/run.sh workflow-release-deploy
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

# 5. 단계 deploy: verify_cmd가 더해진다. 기한 안 실패는 resume(30), 기한을 넘기면 사람(20).
rel_repo rel_deploy ".release_policy.verify_cmd = \"test -f $DRIVER_TMP/deployed-rel_deploy\"" deploy
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "30:verify" "$DRIVER_RC:$(run_state .node)" "a release not observed yet is resumable"
touch "$DRIVER_TMP/deployed-rel_deploy"
driver resume
assert_eq "0:done:passed" "$DRIVER_RC:$(run_state .status):$(run_state .release.verify.status)" "resume finishes once verify_cmd passes"
assert_eq "1" "$(grep -c '^gh release create' "$FAKE_LOG")" "the release is not created again on resume"
rel_repo rel_deploy_late '.release_policy.verify_cmd = "false" | .release_policy.verify_timeout_minutes = 30' deploy
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "30" "$DRIVER_RC" "verify fails within the deadline"
state_file="$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
jq '.merge.merged_epoch -= 3600' "$state_file" >"$DRIVER_TMP/s.json" && mv "$DRIVER_TMP/s.json" "$state_file"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "verify past the deadline goes to a person"
pass "release stage deploy adds verify_cmd"

finish_tests
