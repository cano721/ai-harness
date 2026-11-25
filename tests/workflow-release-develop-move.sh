#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — release 워크플로(#493): develop 이동 따라잡기(rebase·merge)
# 실행: bash tests/run.sh workflow-release-develop-move
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

# 8. develop 이동: push 전에는 rebase, push 뒤에는 merge로 따라잡고 checks를 다시 돈다. 충돌이면 진행 상태 없이 사람에게.
rel_repo rel_move_before
REL_MOVER="$DRIVER_TMP/move-before.sh"
printf '[ -f %q ] || { touch %q; %s; }\n' "$DRIVER_TMP/moved-before" "$DRIVER_TMP/moved-before" "$(move_develop_cmd other.txt moved)" >"$REL_MOVER"
FAKE_CHECK="echo run >>$REL_CHECKS; bash $REL_MOVER" driver start --runtime codex --workflow release --version 1.3.0
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a release catches up when develop moves before publish"
git -C "$DRIVER_REPO" merge-base --is-ancestor "$(remote_ref refs/heads/develop)" HEAD || fail "the release branch was rebased onto the moved develop"
assert_eq "2" "$(wc -l <"$REL_CHECKS" | tr -d ' ')" "checks ran again after the rebase"
assert_eq "0" "$(git -C "$DRIVER_REPO" rev-list --merges --count "$(remote_ref refs/heads/develop)..HEAD")" "before the push the branch is rebased, not merged"
assert_contains "$(run_state '.history | map(.to) | join(",")')" "revalidate" "the run went through revalidate"

rel_repo rel_move_after '.' merge
FAKE_ON_REMOTE_CI="$(move_develop_cmd other.txt moved)" driver start --runtime codex --workflow release --version 1.3.0
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a release catches up when develop moves before the merge"
first_push="$(run_state '.release.revalidated[0].from')"
git --git-dir="$(remote_of)" merge-base --is-ancestor "$first_push" refs/heads/release/v1.3.0 || fail "the pushed release branch was not rewritten (no force push)"
git --git-dir="$(remote_of)" merge-base --is-ancestor refs/heads/develop refs/heads/release/v1.3.0 || fail "the release branch contains the moved develop"
assert_eq "2" "$(wc -l <"$REL_CHECKS" | tr -d ' ')" "checks ran again after the merge"
assert_eq "2" "$(grep -c '^remote_ci ' "$FAKE_LOG")" "remote CI is checked again after the catch-up push"
assert_eq "merge" "$(run_state '.release.revalidated[0].method')" "after the push the branch catches up with a merge"
pass "release catches up when develop moves before publish and before the merge"

finish_tests
