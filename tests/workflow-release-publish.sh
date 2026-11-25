#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — release 워크플로(#493) — 버전 확정·단계 deploy·resume
# 실행: bash tests/run.sh workflow-release-publish
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

finish_tests
