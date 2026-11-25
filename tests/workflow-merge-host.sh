#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: Bitbucket·사람이 먼저 병합·허용 병합 방식
# 실행: bash tests/run.sh workflow-merge-host
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
# Bitbucket: 승인은 마지막 push 뒤의 것만 센다. 자격증명은 stdin으로 넘긴다.
export ATLASSIAN_USER='me@example.com' BITBUCKET_API_TOKEN='tok"en' FAKE_PROTECTION=bb_glob
merge_run bb_merge "$(jq -c '.verify = []' <<<"$MP_BASIC")" bitbucket.org/acme/app
assert_eq "0:done:111111111111:repository default" "$DRIVER_RC:$(run_state .status):$(run_state .merge.commit):$(run_state .merge.method)" "a Bitbucket pull request is merged when its conditions hold"
assert_contains "$(<"$FAKE_LOG")" "curl POST acme/app/pullrequests/7/merge" "the Bitbucket merge endpoint is called"
assert_contains "$(<"$FAKE_LOG")" 'curl body {"close_source_branch": false}' "Bitbucket merges with the repository's default strategy"
merge_run bb_stale "$(jq -c '.verify = []' <<<"$MP_BASIC")" bitbucket.org/acme/app
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "a Bitbucket approval from before the last push does not count"
unset ATLASSIAN_USER BITBUCKET_API_TOKEN
export FAKE_PROTECTION=classic
# 사람이 먼저 병합했으면 그 병합 커밋으로 병합 후 검증을 이어 간다.
merge_run merge_outside "$MP_BASIC"
assert_eq "0:done:outside the runner:0" "$DRIVER_RC:$(run_state .status):$(run_state .merge.method):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a pull request merged by a person is verified without merging again"
# 호스트 보호가 필수 승인을 걸면 그 승인을 기다린다. 방식은 저장소가 허용한 방식을 따른다.
export FAKE_MERGE_METHODS=merge_only
merge_run merge_noapproval '{"verify":[],"base":"main"}'
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "the host's required approval is waited for"
assert_contains "$DRIVER_OUT" "human approval: 0 of 1" "the wait names the approval the host requires"
touch "$FAKE_LOG.approved"
DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver resume
assert_eq "0:done:merge" "$DRIVER_RC:$(run_state .status):$(run_state .merge.method)" "resume merges once the host-required approval arrives"
assert_contains "$(<"$FAKE_LOG")" "--merge --match-head-commit" "the merge method is the one the repository allows"
for m in unknown:"the repository settings do not say which merge methods are allowed" denied:"cannot read which merge methods the repository allows"; do
  export FAKE_MERGE_METHODS="${m%%:*}"
  merge_run "merge_method_${m%%:*}" "$MP_BASIC"
  assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG" || true)" "merge methods ${m%%:*}: the runner does not guess a merge method"
  assert_contains "$DRIVER_OUT" "${m#*:}" "merge methods ${m%%:*}: the person is told why"
done
unset FAKE_MERGE_METHODS
unset FAKE_PROTECTION
pass "merge node: Bitbucket, outside merge and merge methods (host rules)"

finish_tests
