#!/usr/bin/env bash
# release 워크플로 영역(tests/workflow-release*.sh)이 source하는 공용 준비: 릴리스 저장소 만들기(rel_repo)와 원격 develop을 움직이는 헬퍼.
# tests/lib.sh·tests/lib-driver.sh 다음에 source한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
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
  printf 'feature\n' >"$DRIVER_REPO/feature.txt"
  git -C "$DRIVER_REPO" add feature.txt
  git -C "$DRIVER_REPO" commit -qm "feat: feature"
  # main·태그는 릴리스 정책 커밋, develop은 기능 커밋 — push 한 번으로 보낸다(#614).
  git -C "$DRIVER_REPO" push -q origin HEAD~1:refs/heads/main HEAD~1:refs/tags/v1.2.0 HEAD:refs/heads/develop
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
