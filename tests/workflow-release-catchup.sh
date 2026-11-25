#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — release 워크플로(#493) — develop 이동 따라잡기·revalidate·plan 프롬프트 단계 문구
# 실행: bash tests/run.sh workflow-release-catchup
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

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
