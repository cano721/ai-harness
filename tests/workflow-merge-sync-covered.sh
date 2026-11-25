#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — sync_base 노드(#508): 전체 회귀가 덮는 좁은 tests/run.sh 검사는 건너뜀
# 실행: bash tests/run.sh workflow-merge-sync-covered
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge-sync.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge-sync.sh"

# A6: sync_base는 checks와 final_checks를 함께 다시 돌린다. 전체 회귀(bash tests/run.sh -j 2)가 같이 있으면
# 그에 포함되는 --changed는 건너뛰고 전체 회귀만 한 번 돈다. (#513)
sync_repo merge_conflict_covered
COVER_LOG="$DRIVER_TMP/covered-run-args.log"
: >"$COVER_LOG"
mkdir -p "$DRIVER_REPO/tests"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>%q\n' "$COVER_LOG" >"$DRIVER_REPO/tests/run.sh"
git -C "$DRIVER_REPO" add tests && git -C "$DRIVER_REPO" commit -qm "fake test runner"
git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/main
base_commit base.txt base
FAKE_CHECK='bash tests/run.sh --changed' FAKE_FINAL_CHECK='bash tests/run.sh -j 2' sync_start
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state '.base_syncs | length')" "a run with a full regression in final_checks syncs the base and merges"
assert_eq "--changed;-j 2;-j 2" "$(paste -sd ';' "$COVER_LOG")" "sync_base runs the full regression once and not the --changed it covers"
assert_contains "$(<"$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")/progress.log")" \
  "check skipped (covered by bash tests/run.sh -j 2): bash tests/run.sh --changed" "the covered check is logged as skipped"
pass "sync_base skips a narrow tests/run.sh check covered by the full regression"

# A12: A6과 같은 동작을 -j 없는 전체 회귀로 잠근다 — 문서가 `bash tests/run.sh`만 적게 된 뒤에도
# 그에 포함되는 --changed는 건너뛰고 전체 회귀만 한 번 돈다. (#544)
sync_repo merge_conflict_covered_nojobs
COVER_LOG="$DRIVER_TMP/covered-run-args.log"
: >"$COVER_LOG"
mkdir -p "$DRIVER_REPO/tests"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>%q\n' "$COVER_LOG" >"$DRIVER_REPO/tests/run.sh"
git -C "$DRIVER_REPO" add tests && git -C "$DRIVER_REPO" commit -qm "fake test runner"
git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/main
base_commit base.txt base
FAKE_CHECK='bash tests/run.sh --changed' FAKE_FINAL_CHECK='bash tests/run.sh' sync_start
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(run_state '.base_syncs | length')" "a run with a -j-less full regression in final_checks syncs the base and merges"
assert_eq "--changed;;" "$(paste -sd ';' "$COVER_LOG")" "sync_base runs the -j-less full regression once and not the --changed it covers"
assert_contains "$(<"$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")/progress.log")" \
  "check skipped (covered by bash tests/run.sh): bash tests/run.sh --changed" "the covered check is logged as skipped"
pass "sync_base skips a narrow tests/run.sh check covered by a -j-less full regression"

finish_tests
