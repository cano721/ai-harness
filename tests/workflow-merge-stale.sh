#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 병합 직전 되돌림 검사(#601): base 변경을 옛 내용으로 되돌린 head는 병합하지 않는다
# 실행: bash tests/run.sh workflow-merge-stale
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge-sync.sh"

outside_cmd() { # git-commands → remote_ci 도중 원격 작업 브랜치를 옮기는 명령
  local c="$DRIVER_TMP/outside-$FAKE_SCENARIO"
  printf 'rm -rf %q && git clone -q -b feat/add-feature %q %q && cd %q && git config user.email t@t && git config user.name t && %s && git push -q origin HEAD:refs/heads/feat/add-feature' \
    "$c" "$(sy_remote)" "$c" "$c" "$1"
}

# A6: remote_ci 도중 바깥에서 -s ours로 base를 병합하면(base 커밋을 부모로 두지만 내용은 버린다) sync_base는 받아들이지만,
# 병합 직전 검사가 base.txt를 되돌린 것을 잡아 사람에게 넘긴다.
sync_repo merge_stale_ours
base_commit base.txt base
FAKE_ON_REMOTE_CI="$(outside_cmd 'git merge -q --no-edit -s ours origin/main')" sync_start
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a head that drops a base change is not merged"
assert_eq "merge_blocked" "$(run_state '.history | last | .outcome')" "the merge node blocks"
assert_eq "null" "$(run_state '.merge.commit')" "nothing is merged"
assert_contains "$(run_state '.merge.blocked | join("\n")')" "reverts origin/main change: base.txt" "the blocked reason names the file"
assert_contains "$(run_state '.findings | join("\n")')" "base.txt" "the findings name the file"
pass "the merge node checks for stale reverts right before merging"

finish_tests
