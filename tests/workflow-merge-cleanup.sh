#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 병합 뒤 worktree 정리 가능 판정(지우지 않음)
# 실행: bash tests/run.sh workflow-merge-cleanup
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합이 호스트에서 확인돼도 러너는 worktree를 지우지 않는다(#454). 안전 조건(PR MERGED·깨끗함·미푸시 커밋 없음·중첩 clone 없음·링크된 worktree)만
# 판정해 state.json의 worktree_cleanup {eligible, reason, path, branch}과 progress 로그에 남기고, 정리는 사람이나 보드가 한다.
# orca 삭제 명령은 어느 경우에도 부르지 않는다 — 가짜 orca가 모든 호출을 기록하고, 작업 폴더·브랜치가 남았는지도 본다.
export FAKE_PROTECTION=classic
WTC_BIN="$DRIVER_TMP/wtc-bin"
mkdir -p "$WTC_BIN"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$*" >>"%s/orca.log"\n' "$DRIVER_TMP"
  printf 'printf "{\\"ok\\":true,\\"message\\":\\"removed\\"}\\n"\n'
} >"$WTC_BIN/orca"
chmod +x "$WTC_BIN/orca"
export ORCA_CLI_COMMAND="$WTC_BIN/orca"
wtc_run() { # scenario linked(1|"") [merge-settings-json] → 병합까지 끝낸 뒤 worktree_cleanup 판정을 본다
  : >"$DRIVER_TMP/orca.log"
  NEW_REPO_LINKED="$2" merge_run "$1" "${3:-$MP_BASIC}"
}
wtc_assert_kept() { # 라벨 — orca 호출 없음, 작업 폴더·브랜치 그대로
  assert_eq "" "$(<"$DRIVER_TMP/orca.log")" "$1: the runner never calls orca to remove anything"
  [[ -e "$DRIVER_REPO/.git" ]] || fail "$1: the work folder is still there"
  assert_eq "feat/add-feature" "$(git -C "$DRIVER_REPO" symbolic-ref --short HEAD)" "$1: the work branch is still checked out"
}
wtc_progress() { cat "$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")/progress.log"; }
# 링크된 worktree + MERGED·깨끗함·푸시됨 → eligible, 하지만 지우지 않는다.
wtc_run wtc_linked_ok 1
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "wtc: the linked-worktree run merges"
assert_eq "true:null:$DRIVER_REPO:feat/add-feature" "$(run_state '"\(.worktree_cleanup.eligible):\(.worktree_cleanup.reason):\(.worktree_cleanup.path):\(.worktree_cleanup.branch)"')" "a merged, clean, pushed linked worktree is recorded as eligible"
wtc_assert_kept "eligible linked worktree"
assert_contains "$(git -C "$DRIVER_MAIN" worktree list --porcelain)" "$DRIVER_REPO" "the eligible linked worktree is still registered"
assert_contains "$(wtc_progress)" "worktree cleanup" "the verdict is one progress line"
# 메인 체크아웃(링크된 worktree 아님)은 병합돼도 eligible=false. rev-parse --git-dir 상대경로 비교 버그를 잡는다.
wtc_run wtc_main ""
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "wtc: the main-checkout run merges"
assert_eq "false" "$(run_state '.worktree_cleanup.eligible')" "the main checkout is never eligible"
assert_contains "$(run_state '.worktree_cleanup.reason')" "not a removable linked worktree" "the main checkout reason says it is not a linked worktree"
assert_eq "$DRIVER_REPO" "$(run_state '.worktree_cleanup.path')" "the verdict records the checkout path"
wtc_assert_kept "main checkout"
# 커밋 안 한 변경 · 원격에 없는 커밋 · 병합 확인 실패는 eligible=false와 사유.
wtc_run wtc_dirty 1
assert_eq "0:done:false" "$DRIVER_RC:$(run_state .status):$(run_state '.worktree_cleanup.eligible')" "wtc: uncommitted changes make the worktree ineligible"
assert_contains "$(run_state '.worktree_cleanup.reason')" "working tree is not clean" "the dirty reason is recorded"
wtc_assert_kept "dirty worktree"
# 미푸시 커밋은 병합 뒤 검증(smoke) 명령이 남긴다 — 병합 확인 이후 HEAD가 원격에 없는 커밋을 갖게 되는 경우.
wtc_run wtc_unpushed 1 '{"verify":["smoke"],"smoke_cmd":"git -c user.email=t@t -c user.name=t commit -q --allow-empty -m late","base":"main"}'
assert_eq "0:done:false" "$DRIVER_RC:$(run_state .status):$(run_state '.worktree_cleanup.eligible')" "wtc: a commit absent from every remote makes the worktree ineligible"
assert_contains "$(run_state '.worktree_cleanup.reason')" "commits are absent from remotes" "the unpushed reason is recorded"
wtc_assert_kept "unpushed worktree"
wtc_run wtc_unmerged 1 '{"verify":["smoke"],"smoke_cmd":"touch '"$DRIVER_TMP"'/wtc_unmerged.log.reopen","base":"main"}'
assert_eq "0:done:false" "$DRIVER_RC:$(run_state .status):$(run_state '.worktree_cleanup.eligible')" "wtc: a pull request the host no longer reports as merged makes the worktree ineligible"
assert_contains "$(run_state '.worktree_cleanup.reason')" "merge is not confirmed" "the unmerged reason is recorded"
wtc_assert_kept "unmerged worktree"
unset ORCA_CLI_COMMAND
pass "merge cleanup judges worktree eligibility without removing anything"

finish_tests
