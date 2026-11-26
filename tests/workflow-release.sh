#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — release 워크플로(#493): 시작 검사·버전 확정·단계 pr·단계 merge
# 실행: bash tests/run.sh workflow-release
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

# 1. 인자 검사: --version은 start --workflow release에서 semver만 받는다. release_policy가 없거나 flow가 tag가 아니면 시작하지 않는다.
rel_repo rel_args
driver start --runtime codex --workflow release --version 1.2
assert_eq "2" "$DRIVER_RC" "a version that is not x.y.z is refused"
driver start --runtime codex --workflow feature --version 1.2.3 --request x
assert_eq "2" "$DRIVER_RC" "--version belongs to the release workflow only"
rel_repo rel_nopolicy 'del(.release_policy)'
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "2" "$DRIVER_RC" "a repository without release_policy cannot start a release"
assert_contains "$DRIVER_OUT" "harness-init" "the refusal points at harness-init --sync"
rel_repo rel_unknown '.release_policy.flow = "unknown"'
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "2" "$DRIVER_RC" "flow unknown cannot start a release"
rel_repo rel_onsource
git -C "$DRIVER_REPO" checkout -q -b develop
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "2" "$DRIVER_RC" "a release does not start on the source branch"
pass "release start guards"

# 2. 버전: --version은 state에 남고 승인을 기다린다. 없으면 plan의 제안을 쓰고, 이미 있는 태그는 사람에게 넘긴다.
rel_repo rel_version
: >"$DRIVER_TMP/data/config"
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "10:1.3.0:release v1.3.0" "$DRIVER_RC:$(run_state .release.version):$(run_state .request)" "--version is kept and the plan waits for approval"
rel_repo rel_proposed
: >"$DRIVER_TMP/data/config"
driver start --runtime codex --workflow release
assert_eq "10:1.3.0" "$DRIVER_RC:$(run_state .release.version)" "the version the plan proposes is kept"
rel_repo rel_tag_exists
FAKE_RELEASE_VERSION=1.2.0 driver start --runtime codex --workflow release
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a version whose tag already exists goes to a person"
assert_contains "$DRIVER_OUT" "v1.2.0" "the existing tag is named"
rel_repo rel_older
FAKE_RELEASE_VERSION=1.1.9 driver start --runtime codex --workflow release
assert_eq "20" "$DRIVER_RC" "a version below the latest tag goes to a person"
pass "release version is fixed by --version or the plan and checked against the tags"

# 3. 단계 pr(설정 없음): 릴리스 브랜치·PR·원격 CI까지. 병합·태그는 하지 않고 남은 수동 절차를 남긴다.
rel_repo rel_pr
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "0:done:pr" "$DRIVER_RC:$(run_state .status):$(run_state .release.stage)" "stage pr ends after remote CI"
assert_eq "0" "$(grep -c '^gh merge\|^gh release' "$FAKE_LOG" || true)" "stage pr neither merges nor releases"
assert_eq "" "$(remote_ref refs/tags/v1.3.0)" "stage pr leaves no tag"
assert_contains "$(run_state .release.stopped_because)" "gh pr merge" "the manual merge step is left"
assert_contains "$(run_state .release.stopped_because)" "--merge" "the manual merge uses a merge commit"
assert_eq "release/v1.3.0" "$(git -C "$DRIVER_REPO" rev-parse --abbrev-ref HEAD)" "the release branch is cut by the runner"
assert_eq "chore: release v1.3.0" "$(git -C "$DRIVER_REPO" log -1 --format=%s)" "the release commit message"
assert_eq "1.3.0" "$(git --git-dir="$(remote_of)" show refs/heads/release/v1.3.0:VERSION)" "prepare_cmd ran with HM_RELEASE_VERSION"
git --git-dir="$(remote_of)" merge-base --is-ancestor refs/heads/develop refs/heads/release/v1.3.0 || fail "the release branch is cut from origin/develop"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "chore: release v1.3.0" "publish opens the release PR with the release title"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "main" "publish targets release_policy.base"
assert_contains "$DRIVER_OUT" "gh pr merge" "the done report names the manual steps"
pass "release stage pr stops at the pull request"

# 4. 단계 merge: 병합 → 타깃 CI → 태그·노트 → 기록 → sync 판정 → done. verify_cmd는 deploy 전용이다.
rel_repo rel_merge '.release_policy.verify_cmd = "false"' merge
dev_before="$(remote_ref refs/heads/develop)"
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "stage merge releases"
assert_eq "remote_ci,merge,post_merge_verify,release,record,sync" \
  "$(run_state '[.history[] | select(.from | IN("remote_ci", "merge", "post_merge_verify", "release", "verify", "record", "sync")) | .from] | join(",")')" "stage merge goes through release, record, and sync, not verify"
assert_eq "skipped" "$(run_state '.release.verify.status')" "verify is recorded as skipped below deploy"
assert_file "$DRIVER_TMP/recorded-rel_merge"
assert_contains "$(<"$FAKE_LOG")" "gh release create v1.3.0 --target 1111111111111111111111111111111111111111 --title v1.3.0 --notes-file" "the release is published at the merge commit"
assert_contains "$(<"$FAKE_LOG")" "--latest --generate-notes" "generate_notes adds GitHub notes"
assert_contains "$(run_state .release.notes)" "release-notes.md" "the notes file is recorded"
assert_contains "$(run_state .release.sync.command)" "git merge --ff-only origin/main" "sync leaves the fast-forward to a person"
assert_contains "$DRIVER_OUT" "git merge --ff-only origin/main" "the done report shows the sync command"
assert_eq "$dev_before" "$(remote_ref refs/heads/develop)" "the runner never pushes develop"
pass "release stage merge publishes, records, and leaves the sync"

# 5. 다른 worktree가 쓰는 릴리스 브랜치(#617): git switch -C는 다른 worktree에 체크아웃된 브랜치도 말없이 옮겨
# 그쪽(같은 버전의 다른 런)의 HEAD를 바꾼다. prepare는 브랜치를 옮기지 않고 사람에게 넘긴다.
rel_repo rel_other_wt
git -C "$DRIVER_REPO" branch -q release/v1.3.0 HEAD
git -C "$DRIVER_REPO" worktree add -q "$DRIVER_TMP/other-wt" release/v1.3.0
other_before="$(git -C "$DRIVER_TMP/other-wt" rev-parse HEAD)"
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "prepare stops when another worktree has the release branch checked out"
assert_contains "$(run_state .release.blocked)" "other-wt" "the reason names the other worktree"
assert_eq "$other_before" "$(git -C "$DRIVER_TMP/other-wt" rev-parse HEAD)" "the other worktree's branch is not moved"
assert_eq "" "$(git -C "$DRIVER_TMP/other-wt" status --porcelain)" "the other worktree is left clean"
pass "release prepare does not move a release branch checked out in another worktree"

finish_tests
