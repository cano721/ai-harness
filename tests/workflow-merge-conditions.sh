#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 현재 head·작성자·쓰기 권한 승인 조건
# 실행: bash tests/run.sh workflow-merge-conditions
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
# 승인은 지금 head에 대한 것이고 작성자 본인이 아니어야 한다.
merge_run merge_stale "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval of an older commit does not count"
merge_run merge_self "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "the author's own approval does not count"
merge_run merge_outsider "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval from an account without write access does not count"
unset FAKE_PROTECTION
pass "merge node: host rules, repository facts, merge by the runner (approval conditions)"

finish_tests
