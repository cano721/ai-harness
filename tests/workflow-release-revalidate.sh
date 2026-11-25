#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — release 워크플로(#493): revalidate는 prepare_cmd를 다시 돌리지 않음·plan 프롬프트 단계 문구
# 실행: bash tests/run.sh workflow-release-revalidate
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

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
