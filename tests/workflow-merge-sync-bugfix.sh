#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — sync_base 노드(#508): bug-fix 그래프·늦게 오는 충돌 결과
# 실행: bash tests/run.sh workflow-merge-sync-bugfix
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge-sync.sh"

# A10: bug-fix 그래프도 같은 sync_base 경로를 탄다.
sync_repo merge_conflict_bugfix
base_commit base.txt base
sync_start bug-fix
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a bug fix blocked only by a base conflict syncs and merges"
assert_eq "remote_ci,merge,sync_base,remote_ci,merge,post_merge_verify" "$(sync_path)" "the bug-fix graph goes through sync_base"
pass "the bug-fix graph syncs the base on a conflict"

# A11: 충돌 여부를 호스트가 아직 계산 중(UNKNOWN)이어도 다시 물어본 뒤 충돌이면 sync_base로 간다(#542). resume 없이 끝나야 한다.
sync_repo merge_conflict_pending
base_commit base.txt base
FAKE_UNKNOWN_N=1 HM_MERGE_PENDING_POLL_SECONDS=0 sync_start
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a conflict the host reports late still syncs the base and merges"
assert_contains "$(sync_path)" "sync_base" "the late conflict result goes through sync_base"
pass "a pending conflict check is asked again and then syncs the base"

finish_tests
