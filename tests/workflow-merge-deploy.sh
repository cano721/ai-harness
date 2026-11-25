#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 병합 후 배포 확인·스모크
# 실행: bash tests/run.sh workflow-merge-deploy
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
# 병합 후 검증: 타깃 CI → 배포 확인 → 스모크. 실패는 되돌리지 않고 사람에게, 배포 미관측은 기한까지 resume.
MP_DEPLOY="$(jq -cn --arg d "test -f $DRIVER_TMP/deployed-\$FAKE_SCENARIO" '{base:"main", verify:["target_ci","deploy","smoke"], deploy_check_cmd:$d, deploy_timeout_minutes:30, smoke_cmd:"test \"$HM_MERGE_COMMIT\" = 1111111111111111111111111111111111111111"}')"
merge_run pm_deploy "$MP_DEPLOY"
assert_eq "30:incomplete:post_merge_verify" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "a deploy not observed yet leaves the run resumable"
assert_contains "$DRIVER_OUT" "not deployed yet" "the wait says the deploy is not observed"
touch "$DRIVER_TMP/deployed-pm_deploy"
driver resume
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^post_merge_verify ' "$FAKE_LOG")" "resume finishes deploy and smoke without rerunning the passed CI step"
assert_contains "$DRIVER_OUT" "target_ci passed, deploy passed, smoke passed" "every post-merge check is reported"
merge_run pm_deploy_late "$MP_DEPLOY"
jq '.merge.merged_epoch -= 3600' "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)" >"$DRIVER_TMP/s.json" \
  && mv "$DRIVER_TMP/s.json" "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a deploy not observed within the timeout goes to a person"
assert_contains "$DRIVER_OUT" "was not observed as deployed within 30 minutes" "the timeout is named"
merge_run pm_smoke_fail '{"verify":["smoke"],"smoke_cmd":"false","base":"main"}'
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a smoke check that fails twice goes to a person"
assert_contains "$DRIVER_OUT" "the smoke check failed twice" "the smoke failure is named"
unset FAKE_PROTECTION
pass "merge node: post-merge deploy check and smoke (deploy)"

finish_tests
