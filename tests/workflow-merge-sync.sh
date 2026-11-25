#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — sync_base 노드: 충돌만 막힘 → base 병합·재검사·push·remote_ci → merge, 반복 한도·미해결·검사 실패·변경 요청 (#508)
# 실행: bash tests/run.sh workflow-merge-sync
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

# A1: 충돌만으로 막히면 sync_base가 origin/main을 병합하고, 재검사·push 뒤 remote_ci → merge를 다시 거쳐 병합한다.
sync_repo merge_conflict
base_commit base.txt base
sync_start
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a merge blocked only by a base conflict syncs the base and merges"
assert_eq "remote_ci,merge,sync_base,remote_ci,merge,post_merge_verify" "$(sync_path)" "sync_base goes back through remote CI and merge"
assert_eq "1:driver:0" "$(run_state '"\(.base_syncs | length):\(.base_syncs[0].resolved_by):\(.base_syncs[0].conflicts | length)"')" "a clean base merge is recorded as done by the driver"
assert_eq "$(run_state '.base_syncs[0].from')" "$(remote_head '^1')" "the pushed merge commit's first parent is the reviewed head"
assert_eq "$(git --git-dir "$(sy_remote)" rev-parse refs/heads/main)" "$(remote_head '^2')" "the pushed merge commit's second parent is origin/main"
assert_eq "$(remote_head)" "$(run_state '.base_syncs[0].to')" "the record names the pushed commit"
assert_contains "$(<"$FAKE_LOG")" "gh merge https://github.com/acme/app/pull/7 --squash --match-head-commit $(remote_head)" "the merge is pinned to the synced head"
assert_eq "0" "$(grep -c '^sync_base' "$FAKE_LOG" || true)" "a clean base merge does not call an agent"
pass "a base conflict alone goes through sync_base, remote CI, and merge again"

# A2: 실제 텍스트 충돌은 sync_base 에이전트 세션이 풀고, 러너가 표식이 없음을 확인한 뒤 merge 커밋을 만든다.
sync_repo merge_conflict_text
base_commit feature.txt base
sync_start
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a text conflict resolved by the agent merges"
assert_eq "agent:feature.txt" "$(run_state '"\(.base_syncs[0].resolved_by):\(.base_syncs[0].conflicts | join(","))"')" "the record names the agent and the conflicted file"
assert_eq "" "$(git --git-dir "$(sy_remote)" grep -n -e '^<<<<<<<' -e '^>>>>>>>' "$(remote_head)" -- || true)" "the pushed commit has no conflict markers"
assert_contains "$(<"$FAKE_LOG.sync_base.prompt")" "feature.txt" "the sync_base session is told which files conflict"
assert_contains "$(<"$FAKE_LOG")" "sync_base workspace-write" "the sync_base session can write"
assert_eq "$(git --git-dir "$(sy_remote)" rev-parse refs/heads/main)" "$(remote_head '^2')" "the resolved merge commit merges origin/main"
pass "the sync_base agent resolves a text conflict and the driver commits the merge"

# A3: 반복 한도(limits.max_base_syncs)를 넘으면 user_decision이고 병합하지 않는다.
sync_repo merge_conflict_limit
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq '.limits.max_base_syncs = 1' "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -qm graph
git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/main
base_commit base.txt base
sync_start
assert_eq "20:user_decision:1" "$DRIVER_RC:$(run_state .status):$(run_state '.base_syncs | length')" "the base sync limit goes to a person"
assert_contains "$DRIVER_OUT" "base sync limit (1) reached" "the limit is named"
assert_eq "0" "$(grep -c '^gh merge' "$FAKE_LOG" || true)" "nothing is merged past the limit"
assert_eq "3" "$(jq -r '.limits.max_base_syncs' "$FEATURE_GRAPH")" "the template limit is 3"
pass "the base sync limit stops at user_decision"

# A4: 에이전트가 풀지 못한 충돌은 merge를 abort하고 push하지 않는다.
sync_repo merge_conflict_unresolved
base_commit feature.txt base
sync_start
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "an unresolved conflict goes to a person"
git -C "$DRIVER_REPO" rev-parse -q --verify MERGE_HEAD >/dev/null && fail "the unresolved merge was not aborted"
assert_eq "$(run_state .head)" "$(remote_head)" "nothing is pushed after an unresolved conflict"
assert_eq "$(run_state .head)" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "the local branch stays at the reviewed head"
assert_contains "$DRIVER_OUT" "feature.txt" "the unresolved file is named"
assert_eq "0" "$(run_state '.base_syncs // [] | length')" "an aborted sync is not recorded as done"
pass "an unresolved conflict aborts the merge and goes to a person"

# A5: 동기화 뒤 검사가 실패하면 push하지 않고 user_decision.
sync_repo merge_conflict_checkfail
base_commit broken.txt broken
FAKE_CHECK='test ! -f broken.txt' sync_start
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a check failing after the base sync goes to a person"
git --git-dir "$(sy_remote)" rev-parse -q --verify "refs/heads/feat/add-feature^2" >/dev/null && fail "the failing sync was pushed"
assert_contains "$DRIVER_OUT" "test ! -f broken.txt" "the failed check is named"
pass "a check failure after the base sync is not pushed"

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

# A7: 충돌과 다른 막힘(변경 요청)이 같이 있으면 sync하지 않고 사람에게 넘긴다.
sync_repo merge_conflict_changes
base_commit base.txt base
sync_start
assert_eq "20:user_decision:0" "$DRIVER_RC:$(run_state .status):$(run_state '.base_syncs // [] | length')" "a conflict with another blocker does not sync"
assert_contains "$DRIVER_OUT" "merge conflicts" "the conflict is named"
assert_contains "$DRIVER_OUT" "a reviewer requested changes" "the other blocker is named"
[[ "$(sync_path)" != *sync_base* ]] || fail "sync_base ran although another blocker was present"
pass "a conflict together with another blocker goes to a person"

finish_tests
