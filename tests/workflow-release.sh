#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — release 워크플로(#493): 버전 확정·릴리스 브랜치·PR·단계 게이트·merge commit·노트·태그·기록·ff 안내
# 실행: bash tests/run.sh workflow-release
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

RELEASE_GRAPH="$ROOT/templates/release/references/release-graph.json"
export FAKE_PROTECTION=none HM_MERGE_POLL_SECONDS=0

# 릴리스 저장소: bare 원격에 main(릴리스된 상태)·develop(다음 릴리스)·태그 v1.2.0을 두고, 작업 브랜치 work에서 시작한다.
# release_policy는 manifest에, 단계는 개인 config에 둔다. origin은 github.com/acme/app 주소이고 실제 push는 bare로 간다.
rel_repo() { # scenario [release_policy-jq-filter] [delivery level]
  local s="$1" filter="${2:-.}" level="${3:-}"
  new_driver_repo "$s"
  with_policy pr-only auto
  as_host_repo github.com/acme/app
  jq --arg t "$DRIVER_TMP" --arg s "$s" '.release_policy = {flow:"tag", evidence:["test"], base:"main", source:"develop", branch_prefix:"release/v", tag_prefix:"v",
      prepare_cmd:"printf \"%s\\n\" \"$HM_RELEASE_VERSION\" >VERSION", notes_cmd:"printf \"notes for %s\\n\" \"$HM_RELEASE_TAG\"",
      generate_notes:true, verify_cmd:"", verify_timeout_minutes:60, record_cmds:["touch " + $t + "/recorded-" + $s]}' \
    "$DRIVER_REPO/.ai-harness/harness.json" | jq "$filter" >"$DRIVER_TMP/m.json"
  mv "$DRIVER_TMP/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -q --allow-empty -am "release policy"
  git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/main HEAD:refs/tags/v1.2.0
  printf 'feature\n' >"$DRIVER_REPO/feature.txt"
  git -C "$DRIVER_REPO" add feature.txt
  git -C "$DRIVER_REPO" commit -qm "feat: feature"
  git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/develop
  git -C "$DRIVER_REPO" checkout -q -b work
  { printf 'HM_APPROVAL=auto\n'; [[ -z "$level" ]] || printf 'HM_DELIVERY_LEVEL=%s\n' "$level"; } >"$DRIVER_TMP/data/config"
  REL_CHECKS="$DRIVER_TMP/checks-$s.log"
  : >"$REL_CHECKS"
  export FAKE_CHECK="echo run >>$REL_CHECKS"
}
remote_of() { printf '%s' "$DRIVER_TMP/remote-$FAKE_SCENARIO.git"; }
# 다른 사람이 원격 develop에 커밋을 push한다(bare 원격을 직접 클론해서). file content
move_develop_cmd() {
  # shellcheck disable=SC2016  # $d는 나중에 그 명령을 실행하는 셸이 펼친다
  printf 'd=$(mktemp -d "%s/mv.XXXX") && git clone -q -b develop %q "$d/c" && cd "$d/c" && git config user.email t@t && git config user.name t && printf %%s %q >%q && git add -A && git commit -qm "feat: moved" && git push -q origin develop' \
    "$DRIVER_TMP" "$(remote_of)" "$2" "$1"
}
remote_ref() { git --git-dir="$(remote_of)" rev-parse --verify --quiet "$1" || true; }

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

# 5. 단계 deploy: verify_cmd가 더해진다. 기한 안 실패는 resume(30), 기한을 넘기면 사람(20).
rel_repo rel_deploy ".release_policy.verify_cmd = \"test -f $DRIVER_TMP/deployed-rel_deploy\"" deploy
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "30:verify" "$DRIVER_RC:$(run_state .node)" "a release not observed yet is resumable"
touch "$DRIVER_TMP/deployed-rel_deploy"
driver resume
assert_eq "0:done:passed" "$DRIVER_RC:$(run_state .status):$(run_state .release.verify.status)" "resume finishes once verify_cmd passes"
assert_eq "1" "$(grep -c '^gh release create' "$FAKE_LOG")" "the release is not created again on resume"
rel_repo rel_deploy_late '.release_policy.verify_cmd = "false" | .release_policy.verify_timeout_minutes = 30' deploy
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "30" "$DRIVER_RC" "verify fails within the deadline"
state_file="$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
jq '.merge.merged_epoch -= 3600' "$state_file" >"$DRIVER_TMP/s.json" && mv "$DRIVER_TMP/s.json" "$state_file"
driver resume
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "verify past the deadline goes to a person"
pass "release stage deploy adds verify_cmd"

# 6. merge commit만: 호스트가 squash를 허용해도 --merge, merge commit이 허용되지 않으면 병합 호출 없이 사람에게.
rel_repo rel_method_all '.' merge
FAKE_MERGE_METHODS=all driver start --runtime codex --workflow release --version 1.3.0
assert_contains "$(<"$FAKE_LOG")" "gh merge https://github.com/acme/app/pull/7 --merge" "the release is merged with a merge commit"
assert_eq "0" "$(grep -c -- '--squash\|--rebase' "$FAKE_LOG" || true)" "never squash or rebase a release"
rel_repo rel_squash_only '.' merge
FAKE_MERGE_METHODS=squash_only driver start --runtime codex --workflow release --version 1.3.0
assert_eq "20:0" "$DRIVER_RC:$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a repository without merge commits is not merged"
assert_contains "$(run_state '.merge.blocked | join(" ")')" "merge commit" "merge_blocked names the missing merge commit"
pass "release merges only with a merge commit"

# 7. 노트가 없으면 태그·릴리스를 만들지 않는다.
for n in 'exit 1' "printf '  \\n'"; do
  rel_repo "rel_nonotes_$( [[ "$n" == 'exit 1' ]] && echo fail || echo blank)" '.' merge
  jq --arg n "$n" '.release_policy.notes_cmd = $n' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_TMP/m.json" && mv "$DRIVER_TMP/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam notes && git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/develop
  driver start --runtime codex --workflow release --version 1.3.0
  assert_eq "20:0" "$DRIVER_RC:$(grep -c '^gh release' "$FAKE_LOG" || true)" "notes '$n': no release is created"
  assert_eq "" "$(remote_ref refs/tags/v1.3.0)" "notes '$n': no tag is pushed"
done
pass "a release without notes is not tagged"

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

rel_repo rel_move_conflict '.' merge
FAKE_ON_REMOTE_CI="$(move_develop_cmd VERSION 9.9.9)" driver start --runtime codex --workflow release --version 1.3.0
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a conflicting develop commit goes to a person"
assert_contains "$DRIVER_OUT" "VERSION" "the conflicting file is named"
assert_eq "" "$(git -C "$DRIVER_REPO" status --porcelain)" "the working tree is clean after the abort"
assert_not_file "$(git -C "$DRIVER_REPO" rev-parse --git-path MERGE_HEAD)"
assert_not_file "$(git -C "$DRIVER_REPO" rev-parse --git-path rebase-merge)"
assert_eq "0" "$(grep -c '^gh merge' "$FAKE_LOG" || true)" "nothing is merged after a conflict"
rel_repo rel_move_conflict_before
printf '[ -f %q ] || { touch %q; %s; }\n' "$DRIVER_TMP/moved-cb" "$DRIVER_TMP/moved-cb" "$(move_develop_cmd VERSION 9.9.9)" >"$DRIVER_TMP/move-cb.sh"
FAKE_CHECK="bash $DRIVER_TMP/move-cb.sh" driver start --runtime codex --workflow release --version 1.3.0
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a conflicting rebase goes to a person"
assert_eq "" "$(git -C "$DRIVER_REPO" status --porcelain)" "the working tree is clean after the rebase abort"
[[ ! -d "$(git -C "$DRIVER_REPO" rev-parse --git-path rebase-merge)" && ! -d "$(git -C "$DRIVER_REPO" rev-parse --git-path rebase-apply)" ]] || fail "no rebase is left in progress"
pass "release revalidates when develop moves"

# 9. resume: 태그가 이미 있으면 다시 만들지 않는다.
rel_repo rel_resume '.' merge
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "0" "$DRIVER_RC" "the release ran"
state_file="$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
jq '.node = "release" | .status = "incomplete"' "$state_file" >"$DRIVER_TMP/s.json" && mv "$DRIVER_TMP/s.json" "$state_file"
driver resume
assert_eq "0:1" "$DRIVER_RC:$(grep -c '^gh release create' "$FAKE_LOG")" "an existing tag is not created again"
assert_eq "existing" "$(run_state .release.published.status)" "the existing release is recorded"
rel_repo rel_release_fail '.' merge
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a failed release goes to a person"
pass "release resume does not tag twice"

# 10. 그래프 계약과 검증 스크립트.
bash "$ROOT/scripts/validate-release-graph.sh" "$RELEASE_GRAPH" >/dev/null || fail "the release graph is valid"
jq 'del(.nodes.revalidate)' "$RELEASE_GRAPH" >"$DRIVER_TMP/bad-graph.json"
if bash "$ROOT/scripts/validate-release-graph.sh" "$DRIVER_TMP/bad-graph.json" >/dev/null 2>&1; then fail "a release graph without revalidate is invalid"; fi
jq '.transitions += [{"from":"plan","to":"prepare","when":"x"}]' "$RELEASE_GRAPH" >"$DRIVER_TMP/bad-graph.json"
if bash "$ROOT/scripts/validate-release-graph.sh" "$DRIVER_TMP/bad-graph.json" >/dev/null 2>&1; then fail "a release graph that writes before approval is invalid"; fi
jq '.invariants |= map(select(startswith("No tag or release") | not))' "$RELEASE_GRAPH" >"$DRIVER_TMP/bad-graph.json"
if bash "$ROOT/scripts/validate-release-graph.sh" "$DRIVER_TMP/bad-graph.json" >/dev/null 2>&1; then fail "a release graph without the notes invariant is invalid"; fi
pass "release graph contract"

# 11. ai-harness 자신의 릴리스 확인·마일스톤 스크립트: GitHub 결과를 읽고, 진행 중이면 실패(재시도)한다.
REL_VERIFY_REPO="$DRIVER_TMP/verify-repo"
git init -q --bare "$DRIVER_TMP/verify-remote.git"
git init -q "$REL_VERIFY_REPO"
git -C "$REL_VERIFY_REPO" config user.email t@t && git -C "$REL_VERIFY_REPO" config user.name t
printf '{"version":"1.3.0"}\n' >"$REL_VERIFY_REPO/release.json"
git -C "$REL_VERIFY_REPO" add release.json && git -C "$REL_VERIFY_REPO" commit -qm init
git -C "$REL_VERIFY_REPO" remote add origin "$DRIVER_TMP/verify-remote.git"
git -C "$REL_VERIFY_REPO" push -q origin HEAD:refs/heads/main
rv() { (cd "$REL_VERIFY_REPO" && FAKE_LOG="$DRIVER_TMP/verify.log" PATH="$ROOT/tests/fixtures/driver:$PATH" bash "$ROOT/scripts/release-verify.sh" "$@" >/dev/null 2>&1); }
FAKE_RUN_STATUS=completed:success rv 1.3.0 || fail "release-verify passes when the release workflow succeeded and main has the version"
if FAKE_RUN_STATUS=in_progress: rv 1.3.0; then fail "release-verify fails while the release workflow runs"; fi
if FAKE_RUN_STATUS=completed:success rv 1.4.0; then fail "release-verify fails when main has another version"; fi
assert_contains "$(<"$DRIVER_TMP/verify.log")" "--workflow release" "release-verify reads the release workflow runs"
pass "release-verify checks the release workflow and main"

# 12. revalidate는 prepare_cmd를 다시 돌리지 않는다(#554): 따라잡은 뒤에는 checks·final_checks만 다시 돈다.
# 다시 돌면 scripts/release-prep.sh처럼 "이미 이 버전"이라며 exit 2로 거부하는 prepare_cmd가 있는 저장소에서 사람에게 넘어간다.
rel_refusing_prepare() { # scenario level
  local scn="$1" lvl="$2" cmd
  REL_PREPARE_LOG="$DRIVER_TMP/prepare-$scn.log"
  : >"$REL_PREPARE_LOG"
  rel_repo "$scn" '.' "$lvl"
  cmd="echo run >>$REL_PREPARE_LOG; if grep -qx \"\$HM_RELEASE_VERSION\" VERSION 2>/dev/null; then echo \"changelog already carries v\$HM_RELEASE_VERSION\"; exit 2; fi; printf \"%s\\n\" \"\$HM_RELEASE_VERSION\" >VERSION"
  jq --arg c "$cmd" '.release_policy.prepare_cmd = $c' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_TMP/m.json" && mv "$DRIVER_TMP/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "refusing prepare" && git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/develop
}
rel_refusing_prepare rel_reval_rebase ""
REL_MOVER="$DRIVER_TMP/move-reval.sh"
printf '[ -f %q ] || { touch %q; %s; }\n' "$DRIVER_TMP/moved-reval" "$DRIVER_TMP/moved-reval" "$(move_develop_cmd other.txt moved)" >"$REL_MOVER"
FAKE_CHECK="echo run >>$REL_CHECKS; bash $REL_MOVER" driver start --runtime codex --workflow release --version 1.3.0
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "rebase catch-up finishes with a prepare_cmd that refuses reruns"
assert_eq "2" "$(wc -l <"$REL_CHECKS" | tr -d ' ')" "checks ran again after the rebase"
assert_eq "1" "$(wc -l <"$REL_PREPARE_LOG" | tr -d ' ')" "prepare_cmd is not rerun by the rebase revalidate"
assert_eq "rebase" "$(run_state '.release.revalidated[0].method')" "before the push the branch catches up with a rebase"
case "$DRIVER_OUT$(run_state '.merge.blocked // [] | join(" ")')" in *"changelog already carries"*) fail "the prepare_cmd refusal is not surfaced after a rebase" ;; esac
REL_PLAN_PR="$(<"$FAKE_LOG.plan.prompt")"

rel_refusing_prepare rel_reval_merge merge
FAKE_ON_REMOTE_CI="$(move_develop_cmd other.txt moved)" driver start --runtime codex --workflow release --version 1.3.0
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "merge catch-up finishes with a prepare_cmd that refuses reruns"
assert_eq "2" "$(wc -l <"$REL_CHECKS" | tr -d ' ')" "checks ran again after the merge"
assert_eq "1" "$(wc -l <"$REL_PREPARE_LOG" | tr -d ' ')" "prepare_cmd is not rerun by the merge revalidate"
assert_eq "merge" "$(run_state '.release.revalidated[0].method')" "after the push the branch catches up with a merge"
case "$DRIVER_OUT$(run_state '.merge.blocked // [] | join(" ")')" in *"changelog already carries"*) fail "the prepare_cmd refusal is not surfaced after a merge" ;; esac
REL_PLAN_MERGE="$(<"$FAKE_LOG.plan.prompt")"
pass "release revalidate does not rerun prepare_cmd"

# 13. plan 프롬프트의 단계 문구(#554): $(case ...) 가 macOS /bin/bash 3.2에서 구문 오류를 내 문구가 깨졌다. 단계별 문장이 그대로 들어가야 한다.
assert_contains "$REL_PLAN_PR" "so the run stops at the pull request" "the pr stage plan prompt says the run stops at the pull request"
assert_contains "$REL_PLAN_MERGE" "merges it with a merge commit" "the merge stage plan prompt says it merges with a merge commit"
case "$REL_PLAN_PR$REL_PLAN_MERGE" in *"syntax error"* | *"esac)"* | *";;"*) fail "no plan prompt carries a shell syntax error or the unexpanded case text" ;; esac
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" == 3 ]]; then
  # PATH의 bash가 최신이어도 /bin/bash 3.2로 러너를 돌려, 사용자 macOS와 같은 조건으로 확인한다.
  mkdir -p "$DRIVER_TMP/bash32-shim"
  printf '#!/bin/sh\nexec /bin/bash "$@"\n' >"$DRIVER_TMP/bash32-shim/bash"
  chmod +x "$DRIVER_TMP/bash32-shim/bash"
  for lvl in "" merge; do
    rel_repo "rel_plan_b32_${lvl:-pr}" '.' "$lvl"
    PATH="$DRIVER_TMP/bash32-shim:$PATH" driver start --runtime codex --workflow release --version 1.3.0
    p32="$(<"$FAKE_LOG.plan.prompt")"
    case "$p32" in *"syntax error"* | *"esac)"* | *";;"*) fail "bash 3.2 plan prompt (${lvl:-pr}) has no syntax error or unexpanded case text" ;; esac
    if [[ -z "$lvl" ]]; then
      assert_contains "$p32" "so the run stops at the pull request" "bash 3.2 pr stage plan prompt wording"
    else
      assert_contains "$p32" "merges it with a merge commit" "bash 3.2 merge stage plan prompt wording"
    fi
  done
fi
pass "release plan prompt states the delivery stage"

finish_tests
