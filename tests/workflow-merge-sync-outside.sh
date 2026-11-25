#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — sync_base 노드(#508): remote_ci 도중 바깥 커밋
# 실행: bash tests/run.sh workflow-merge-sync-outside
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge-sync.sh"

# A8: remote_ci 도중 바깥에서 들어온 base 병합 커밋 하나(GitHub "Update branch")는 sync_base로 받는다.
outside_cmd() { # git-commands → remote_ci 도중 원격 작업 브랜치를 옮기는 명령
  local c="$DRIVER_TMP/outside-$FAKE_SCENARIO"
  printf 'rm -rf %q && git clone -q -b feat/add-feature %q %q && cd %q && git config user.email t@t && git config user.name t && %s && git push -q origin HEAD:refs/heads/feat/add-feature' \
    "$c" "$(sy_remote)" "$c" "$c" "$1"
}
sync_repo merge_outside_base
base_commit base.txt base
FAKE_ON_REMOTE_CI="$(outside_cmd 'git merge -q --no-edit origin/main')" sync_start
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a base merge pushed from outside during remote CI is taken in"
assert_eq "outside" "$(run_state '.base_syncs[0].resolved_by')" "the outside base merge is recorded"
assert_eq "remote_ci,sync_base,remote_ci,merge,post_merge_verify" "$(sync_path)" "the outside base merge goes through sync_base, remote CI, and merge"
assert_eq "$(remote_head)" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "the local branch follows the outside base merge"
pass "a single base merge commit pushed during remote CI goes through sync_base"

# 범위 4: remote_ci 도중 로컬 작업 브랜치에 base 병합 커밋 하나만 생긴 경우도 같은 경로로 받고, sync_base가 일반 push한다.
sync_repo merge_outside_local
base_commit base.txt base
FAKE_ON_REMOTE_CI='git fetch -q origin main && git merge -q --no-edit origin/main' sync_start
assert_eq "0:done:outside" "$DRIVER_RC:$(run_state .status):$(run_state '.base_syncs[0].resolved_by')" "a local base merge commit made during remote CI is taken in"
assert_eq "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$(remote_head)" "sync_base pushes the local base merge"
assert_eq "$(git --git-dir "$(sy_remote)" rev-parse refs/heads/main)" "$(remote_head '^2')" "the pushed commit merges origin/main"
pass "a single local base merge commit made during remote CI goes through sync_base"

# A9: 바깥에서 들어온 일반 커밋은 지금처럼 불변식 위반이다.
sync_repo merge_outside_commit
FAKE_ON_REMOTE_CI="$(outside_cmd 'echo x >other.txt && git add other.txt && git commit -qm other')" sync_start
assert_eq "40:invariant_violation" "$DRIVER_RC:$(run_state .status)" "an ordinary commit pushed during remote CI still stops the run"
assert_eq "0" "$(run_state '.base_syncs // [] | length')" "an ordinary commit is not synced"
pass "an ordinary commit pushed during remote CI is an invariant violation"

finish_tests
