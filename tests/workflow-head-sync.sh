#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — start가 기준 브랜치보다 뒤처진 작업 브랜치를 따라잡고, 노드 프롬프트가 HEAD 이동 git 작업을 금지한다(#653)
# 실행: bash tests/run.sh workflow-head-sync
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

# 작업 브랜치(fix/x)가 origin/develop보다 커밋 1개 뒤처진 저장소를 만든다: scenario git_policy 승인모드 [own|dirty]
behind_repo() {
  new_driver_repo "$1"
  with_policy "$2" "$3"
  git -C "$DRIVER_REPO" branch -M develop
  git -C "$DRIVER_REPO" push -q origin develop
  git -C "$DRIVER_REPO" fetch -q origin
  git -C "$DRIVER_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  git -C "$DRIVER_REPO" switch -q -c fix/x
  BEHIND_OLD="$(git -C "$DRIVER_REPO" rev-parse HEAD)"
  if [[ "${4:-}" == own ]]; then git -C "$DRIVER_REPO" commit -q --allow-empty -m own; fi
  local ahead
  ahead="$(git -C "$DRIVER_REPO" commit-tree -p "$BEHIND_OLD" -m "base ahead" "$BEHIND_OLD^{tree}")"
  git -C "$DRIVER_REPO" push -q origin "$ahead:refs/heads/develop"
  git -C "$DRIVER_REPO" fetch -q origin
  BEHIND_BASE="$(git -C "$DRIVER_REPO" rev-parse origin/develop)"
  if [[ "${4:-}" == dirty ]]; then echo wip >"$DRIVER_REPO/untracked.txt"; fi
}
run_progress() { cat "$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")/progress.log"; }

# 깨끗한 트리·자기 커밋 0개인 작업 브랜치는 첫 노드 전에 origin/develop으로 fast-forward된다. 상태의 기준 HEAD도 그 뒤 값이다.
behind_repo hs_ff pr-only ""
driver start --workflow feature --runtime codex --request "add feature"
assert_eq "$BEHIND_BASE" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "start fast-forwarded the behind work branch to origin/develop"
assert_eq "$BEHIND_BASE:$BEHIND_BASE" "$(run_state .start_head):$(run_state .repo_baseline.head)" "start_head and the baseline head are the post-fast-forward HEAD"
assert_contains "$(run_progress)" "fast-forward" "progress.log records the fast-forward"
assert_file "$FAKE_LOG.discover.prompt" "the first node ran after the fast-forward"
pass "feature start fast-forwards a clean behind work branch (feature)"

# bug-fix도 triage 전에 같은 방식으로 따라잡는다.
behind_repo hs_bug_ff pr-only ""
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
assert_eq "$BEHIND_BASE" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "bug-fix start fast-forwarded the behind work branch to origin/develop"
assert_eq "$BEHIND_BASE" "$(run_state .start_head)" "bug-fix start_head is the post-fast-forward HEAD"
assert_contains "$(run_progress)" "fast-forward" "bug-fix progress.log records the fast-forward"
assert_file "$FAKE_LOG.triage.prompt" "triage ran after the fast-forward"
pass "bug-fix start fast-forwards a clean behind work branch"

# 작업 브랜치에 자기 커밋이 있으면 건드리지 않는다(앞서 간 이력을 러너가 합치지 않는다).
behind_repo hs_own pr-only "" own
OWN_HEAD="$(git -C "$DRIVER_REPO" rev-parse HEAD)"
driver start --workflow feature --runtime codex --request "add feature"
assert_eq "$OWN_HEAD" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "a branch with its own commit keeps its HEAD"
case "$(run_progress)" in *fast-forward*) fail "no fast-forward line expected for a branch with its own commit" ;; esac
pass "start does not fast-forward a work branch that has its own commits"

# 작업 트리가 더러우면 건드리지 않는다. 커밋 정책이 없으면 더러운 트리로도 시작한다.
behind_repo hs_dirty none "" dirty
driver start --workflow feature --runtime codex --request "add feature"
assert_eq "$BEHIND_OLD" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "a dirty tree keeps its HEAD"
case "$(run_progress)" in *fast-forward*) fail "no fast-forward line expected for a dirty tree" ;; esac
pass "start does not fast-forward when the working tree is dirty"

# 노드 프롬프트는 HEAD를 옮기는 git 작업을 금지하고 sync_base를 안내한다. brief는 뒤처짐을 사실로만 말하게 한다.
behind_repo hs_feat pr-only auto
driver start --workflow feature --runtime codex --request "add feature"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "the auto feature run reaches done"
for node in brief deliver; do
  assert_contains "$(cat "$FAKE_LOG.$node.prompt")" "move HEAD" "feature $node prompt forbids HEAD-moving git operations"
  assert_contains "$(cat "$FAKE_LOG.$node.prompt")" "sync_base" "feature $node prompt names sync_base"
done
assert_contains "$(cat "$FAKE_LOG.brief.prompt")" "state it as a fact" "feature brief prompt tells the planner to state a behind branch as a fact"
behind_repo hs_bug pr-only auto
driver start --workflow bug-fix --runtime codex --request "total ignores tax"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "the auto bug-fix run reaches done"
for node in brief regression fix; do
  assert_contains "$(cat "$FAKE_LOG.$node.prompt")" "move HEAD" "bug-fix $node prompt forbids HEAD-moving git operations"
  assert_contains "$(cat "$FAKE_LOG.$node.prompt")" "sync_base" "bug-fix $node prompt names sync_base"
done
assert_contains "$(cat "$FAKE_LOG.brief.prompt")" "state it as a fact" "bug-fix brief prompt tells the planner to state a behind branch as a fact"
pass "node prompts forbid HEAD-moving git operations and brief states a behind branch as a fact"

# repair 프롬프트는 가짜 fixture로 닿기 어려워 원본에서 확인한다: HEAD_RULE 상수가 금지 문구를 갖고 repair 프롬프트가 그것을 넣는다.
assert_contains "$(grep -E '^HEAD_RULE=' "$DRIVER")" "move HEAD" "HEAD_RULE forbids HEAD-moving operations"
assert_contains "$(grep -E '^HEAD_RULE=' "$DRIVER")" "sync_base" "HEAD_RULE names sync_base"
REPAIR_BLOCK="$(grep -A8 'You are the repair node' "$DRIVER")"
assert_contains "$REPAIR_BLOCK" "\$HEAD_RULE" "the repair prompt includes HEAD_RULE"
pass "HEAD_RULE constant exists and the repair prompt uses it"

finish_tests
