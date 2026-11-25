#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — sync_base 노드 — 바깥에서 들어온 base 병합·bug-fix 그래프·UNKNOWN 재조회·전체 회귀 커버·원격 CI 관문 (#508)
# 실행: bash tests/run.sh workflow-merge-sync-outside
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 병합 단계 사용자(HM_DELIVERY_LEVEL=merge), 승인 auto, 호스트 보호는 승인 1·체크 1(classic).
export HM_SMOKE_RETRY_SECONDS=0 FAKE_PROTECTION=classic
SY_DATA="$DRIVER_TMP/sync-data"
mkdir -p "$SY_DATA"
printf 'HM_APPROVAL=auto\nHM_DELIVERY_LEVEL=merge\n' >"$SY_DATA/config"
sync_repo() { # scenario → 병합 정책이 있는 저장소. 원격 main은 작업 시작 커밋이다.
  new_driver_repo "$1"
  with_policy pr-only auto
  as_host_repo github.com/acme/app
  jq '.merge_policy = {"verify":["target_ci"],"base":"main"}' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" \
    && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/main
}
sy_remote() { printf '%s' "$DRIVER_TMP/remote-$FAKE_SCENARIO.git"; }
base_commit() { # file content → 원격 main에만 커밋 하나를 더한다(작업 브랜치에는 없다)
  local clone="$DRIVER_TMP/base-$FAKE_SCENARIO"
  rm -rf "$clone"
  git clone -q -b main "$(sy_remote)" "$clone"
  git -C "$clone" config user.email t@t
  git -C "$clone" config user.name t
  printf '%s\n' "$2" >"$clone/$1"
  git -C "$clone" add "$1"
  git -C "$clone" commit -qm "base: $1"
  git -C "$clone" push -q origin HEAD:refs/heads/main
}
sync_start() { # [workflow]
  DRIVER_DATA_OVERRIDE="$SY_DATA" HARNESS_METRICS_DIR="$SY_DATA" driver start --workflow "${1:-feature}" --runtime codex --request "add feature"
}
remote_head() { git --git-dir "$(sy_remote)" rev-parse "refs/heads/feat/add-feature${1:-}" 2>/dev/null || true; }
sync_path() { run_state '[.history[] | select(.from | IN("remote_ci", "merge", "sync_base", "post_merge_verify")) | .from] | join(",")'; }

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

# 원격 CI가 최종 관문인 런(.policy.final_gate == remote_ci)에서 sync_base는 checks만 다시 돌린다.
# push한 merge 커밋은 remote_ci를 다시 거치므로 로컬 final_checks는 돌지 않는다. (#557)
sync_repo merge_conflict_remote_gate
mkdir -p "$DRIVER_REPO/.github/workflows"
printf 'on: push\n' >"$DRIVER_REPO/.github/workflows/test.yml"
git -C "$DRIVER_REPO" add .github && git -C "$DRIVER_REPO" commit -qm ci
git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/main
GATE_SYNC_LOG="$DRIVER_TMP/remote-gate-sync.log"
: >"$GATE_SYNC_LOG"
base_commit base.txt base
FAKE_CHECK="printf 'C\\n' >>'$GATE_SYNC_LOG'" FAKE_FINAL_CHECK="printf 'F\\n' >>'$GATE_SYNC_LOG'" sync_start
assert_eq "0:done:1:remote_ci" "$DRIVER_RC:$(run_state .status):$(run_state '.base_syncs | length'):$(run_state .policy.final_gate)" "a remote-gated run syncs the base and merges"
assert_eq "0" "$(grep -c '^F$' "$GATE_SYNC_LOG" || true)" "neither the final gate nor sync_base runs the final checks locally"
[[ "$(grep -c '^C$' "$GATE_SYNC_LOG")" -ge 2 ]] || fail "sync_base runs the checks again (log=$(paste -sd ';' "$GATE_SYNC_LOG"))"
pass "sync_base runs only the checks when remote CI is the final gate"

finish_tests
