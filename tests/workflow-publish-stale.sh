#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 되돌림 검사(#601): publish 전후 base 되돌림·남의 changelog 조각 삭제·fork 지점 이동, revert-check 하위 명령
# 실행: bash tests/run.sh workflow-publish-stale
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

stale_repo() { # scenario → merge_policy.base=develop인 저장소. 원격 develop은 작업 시작 커밋이다.
  new_driver_repo "$1"
  with_policy pr-only auto
  echo v1 >"$DRIVER_REPO/shared.txt"
  jq '.merge_policy = {"base":"develop"}' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" \
    && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" add -A
  git -C "$DRIVER_REPO" commit -qm "repository facts"
  git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/develop
}
develop_advance() { # file content [file content]... → 다른 사람이 원격 develop에 커밋 하나를 push한다(작업 저장소는 fetch하지 않는다)
  local clone="$DRIVER_TMP/other-$FAKE_SCENARIO"
  rm -rf "$clone"
  git clone -q -b develop "$DRIVER_TMP/remote-$FAKE_SCENARIO.git" "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name test
  while (($# >= 2)); do
    mkdir -p "$clone/$(dirname "$1")"
    printf '%s\n' "$2" >"$clone/$1"
    shift 2
  done
  git -C "$clone" add -A
  git -C "$clone" commit -qm "other work"
  git -C "$clone" push -q origin HEAD:refs/heads/develop
}
remote_branch() { git --git-dir "$DRIVER_TMP/remote-$FAKE_SCENARIO.git" rev-parse -q --verify refs/heads/feat/add-feature 2>/dev/null || true; }

# A1: #594 재현 — publish 세션이 develop 진전을 fetch한 뒤 git reset --soft origin/develop로 wip를 합쳐 commit·push한다.
# 트리는 리뷰한 트리와 같고 start_head는 새 develop의 조상이라 예전 판정은 통과했다. 이제 되돌림과 fork 이동으로 막힌다.
stale_repo stale_reset
develop_advance shared.txt v2 changelog.d/999-other.md "- other"
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "publish that soft-reset onto a newer develop goes to a person"
assert_eq "publish_failed" "$(run_state '.history | last | .outcome')" "the publish node fails"
FINDINGS="$(run_state '.findings | join("\n")')"
assert_contains "$FINDINGS" "reverts origin/develop change: shared.txt" "the stale blob revert is named with its path"
assert_contains "$FINDINGS" "deletes changelog fragment added on origin/develop for an issue this branch does not handle: changelog.d/999-other.md" "the deleted fragment of another issue is named"
assert_contains "$FINDINGS" "publish moved the branch onto a different point of origin/develop" "the fork point move is named"
assert_eq "changelog.d/999-other.md,shared.txt" "$(run_state '[.publish.revert_check.findings[].path] | sort | join(",")')" "the file list stays in .publish.revert_check"
# shellcheck disable=SC2016  # 안내 문구의 $(...)를 문자 그대로 찾는다
assert_contains "$(<"$FAKE_LOG.publish.prompt")" 'git reset --soft $(git merge-base HEAD origin/develop)' "the publish prompt tells the session how to squash safely"
pass "publish catches a soft reset onto a newer base (#594)"

# A2: wip를 merge-base 위로 합치면 그대로 통과한다.
stale_repo stale_safe
develop_advance shared.txt v2 changelog.d/999-other.md "- other"
driver start --runtime codex --request "add feature"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "squashing onto the merge-base publishes"
assert_eq "develop:0" "$(run_state '"\(.publish.revert_check.base):\(.publish.revert_check.findings | length)"')" "the clean check is recorded"
pass "a squash onto the merge-base passes"

# A3: develop만 앞서 있고 브랜치가 아무것도 되돌리지 않으면 오탐이 없다.
stale_repo stale_moved
develop_advance shared.txt v2 changelog.d/999-other.md "- other"
driver start --runtime codex --request "add feature"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a base that only moved ahead is not a revert"
pass "a base that moved ahead is not a stale revert"

# A4: deliver가 런 도중 develop을 merge한 뒤 그 develop이 추가한 남의 조각을 지웠다. 리뷰한 HEAD에서 잡혀 publish 세션 없이 멈춘다.
stale_repo stale_deliver_fragment
develop_advance changelog.d/777-other.md "- other"
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision:publish_failed" "$DRIVER_RC:$(run_state .status):$(run_state '.history | last | .outcome')" "a reviewed head that deletes another issue's fragment does not publish"
assert_eq "" "$(grep '^publish ' "$FAKE_LOG" || true)" "no publish session runs"
assert_eq "" "$(remote_branch)" "nothing is pushed"
assert_contains "$(run_state '.findings | join("\n")')" "changelog.d/777-other.md" "the deleted fragment is named"
assert_eq "changelog.d/777-other.md" "$(run_state '[.publish.revert_check.findings[].path] | join(",")')" "the file list stays in .publish.revert_check"
pass "the reviewed head is checked before the publish session"

# A4: 브랜치가 다루는 이슈(요청의 #N)의 조각은 지워도 잡지 않는다.
stale_repo stale_deliver_fragment_own
develop_advance changelog.d/777-other.md "- other"
driver start --runtime codex --request "add feature (#777)"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "deleting the fragment of the issue the run handles passes"
pass "a fragment of the run's own issue may be removed"

# A5: base를 정할 수 없으면(merge_policy.base·origin/HEAD 없음) 검사를 건너뛴 사유를 남기고 판정은 그대로다.
new_driver_repo stale_nobase
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a repository without a base branch still publishes"
assert_contains "$(run_state '.publish.revert_check.skipped // ""')" "base" "the skipped check says why"
# 원격에 base 브랜치가 없으면(ls-remote 2) 건너뛴다.
stale_repo stale_nobranch
git --git-dir "$DRIVER_TMP/remote-stale_nobranch.git" update-ref -d refs/heads/develop
driver start --runtime codex --request "add feature"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a base branch missing on origin skips the check"
assert_contains "$(run_state '.publish.revert_check.skipped // ""')" "develop" "the skipped check names the missing branch"
pass "the revert check is skipped with a reason when there is no base"

# A7: 하위 명령 revert-check. #594 모양 저장소에서 exit 1과 경로, 안전한 저장소에서 exit 0, --issue로 그 조각을 빼고, --base 없이는 exit 2.
RC_DIR="$TEST_TMP/revert-check"
mkdir -p "$RC_DIR"
git init -q --bare "$RC_DIR/remote.git"
git init -q "$RC_DIR/seed"
git -C "$RC_DIR/seed" config user.email test@example.com
git -C "$RC_DIR/seed" config user.name test
echo v1 >"$RC_DIR/seed/shared.txt"
git -C "$RC_DIR/seed" add shared.txt
git -C "$RC_DIR/seed" commit -qm base
git -C "$RC_DIR/seed" push -q "$RC_DIR/remote.git" HEAD:refs/heads/develop
RC_START="$(git -C "$RC_DIR/seed" rev-parse HEAD)"
rc_clone() { # name → develop에서 딴 작업 clone에 wip 커밋 두 개
  git clone -q -b develop "$RC_DIR/remote.git" "$RC_DIR/$1"
  git -C "$RC_DIR/$1" config user.email test@example.com
  git -C "$RC_DIR/$1" config user.name test
  git -C "$RC_DIR/$1" checkout -q -b feat/601-guard
  for n in 1 2; do
    echo "wip $n" >"$RC_DIR/$1/feature.txt"
    git -C "$RC_DIR/$1" add feature.txt
    git -C "$RC_DIR/$1" commit -qm "wip $n"
  done
}
rc_clone stale
rc_clone safe
git clone -q -b develop "$RC_DIR/remote.git" "$RC_DIR/other"
git -C "$RC_DIR/other" config user.email test@example.com
git -C "$RC_DIR/other" config user.name test
echo v2 >"$RC_DIR/other/shared.txt"
mkdir -p "$RC_DIR/other/changelog.d"
echo '- other' >"$RC_DIR/other/changelog.d/999-other.md"
git -C "$RC_DIR/other" add -A
git -C "$RC_DIR/other" commit -qm "other (#999)"
git -C "$RC_DIR/other" push -q origin HEAD:refs/heads/develop
git -C "$RC_DIR/stale" fetch -q origin
git -C "$RC_DIR/stale" reset -q --soft origin/develop
git -C "$RC_DIR/stale" commit -qm "feat: guard (#601)"
git -C "$RC_DIR/safe" fetch -q origin
git -C "$RC_DIR/safe" reset -q --soft "$(git -C "$RC_DIR/safe" merge-base HEAD origin/develop)"
git -C "$RC_DIR/safe" commit -qm "feat: guard (#601)"
revert_check() { # dir args... → RC_RC, RC_OUT
  RC_RC=0
  RC_OUT="$(bash "$DRIVER" revert-check "${@:2}" --repo "$RC_DIR/$1" 2>/dev/null)" || RC_RC=$?
}
revert_check stale --base develop --since "$RC_START"
assert_eq "1" "$RC_RC" "revert-check exits 1 on the #594 commit"
assert_contains "$RC_OUT" "reverts origin/develop change: shared.txt" "revert-check names the reverted file"
assert_contains "$RC_OUT" "changelog.d/999-other.md" "revert-check names the deleted fragment"
assert_eq "2" "$(grep -c . <<<"$RC_OUT")" "one finding per line"
revert_check stale --base develop
assert_eq "1" "$RC_RC" "revert-check catches the revert without --since"
revert_check stale --base develop --issue 999
assert_eq "1" "$RC_RC" "the stale blob is still caught with --issue"
assert_eq "" "$(grep 'changelog.d/999-other.md' <<<"$RC_OUT" || true)" "--issue 999 drops the fragment finding"
revert_check safe --base develop --since "$RC_START"
assert_eq "0:" "$RC_RC:$RC_OUT" "a merge-base squash is clean"
revert_check stale
assert_eq "2" "$RC_RC" "revert-check needs --base"
revert_check stale --base nope
assert_eq "2" "$RC_RC" "an unknown base is a usage error"
assert_contains "$(bash "$DRIVER" --help 2>&1 || true)" "revert-check" "usage lists revert-check"
pass "revert-check reports stale reverts with exit codes"

finish_tests
