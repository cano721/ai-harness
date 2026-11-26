#!/usr/bin/env bash
# 회귀 테스트 — setup 외부 디자인 스킬(고정 커밋 설치)
# 실행: bash tests/run.sh setup-design
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-setup.sh"

# 외부 디자인 스킬: 사본을 들지 않고 원본 저장소의 고정 커밋에서 스킬 폴더만 받는다. 직접 깐 같은 이름 스킬은 명시 없이 바꾸지 않는다. (#210)
SETUP_T="$TEST_TMP/setup-design"
SETUP_CATALOG="$SETUP_T/catalog"
DESIGN_REMOTE="$SETUP_T/remote/acme/skills"
mkdir -p "$SETUP_T" "$DESIGN_REMOTE/skills/foo" "$DESIGN_REMOTE/a/bar" "$DESIGN_REMOTE/b/bar" "$DESIGN_REMOTE/unrelated"
cp -R "$ROOT/catalog" "$SETUP_CATALOG"
printf -- '---\nname: foo\n---\nfoo v1\n' >"$DESIGN_REMOTE/skills/foo/SKILL.md"
printf -- '---\nname: bar\n---\nclaude bar\n' >"$DESIGN_REMOTE/a/bar/SKILL.md"
printf -- '---\nname: bar\n---\ncodex bar\n' >"$DESIGN_REMOTE/b/bar/SKILL.md"
printf 'MIT upstream\n' >"$DESIGN_REMOTE/LICENSE"
printf 'not part of any skill\n' >"$DESIGN_REMOTE/unrelated/big.txt"
git -C "$DESIGN_REMOTE" init -q
git -C "$DESIGN_REMOTE" add -A
git -C "$DESIGN_REMOTE" -c user.name=t -c user.email=t@t commit -qm v1
DESIGN_REF1="$(git -C "$DESIGN_REMOTE" rev-parse HEAD)"
design_catalog() { # foo ref
  jq -n --arg ref "$1" '{version:1, skills:[
    {name:"foo", bundle:"core", summary:"foo", source:{repo:"acme/skills", ref:$ref, path:"skills/foo"}, license:"MIT", review:{runs:"none", network:"none"}},
    {name:"viz", bundle:"core", summary:"viz", builtin:"claude", note:"built in"},
    {name:"bar", bundle:"extra", summary:"bar", source:{repo:"acme/skills", ref:$ref, path:{claude:"a/bar", codex:"b/bar"}}, license:"MIT", review:{runs:"none", network:"none"}},
    {name:"hand", bundle:"extra", summary:"hand", installable:false, note:"install by hand"},
    {name:"wrongname", bundle:"extra", summary:"x", source:{repo:"acme/skills", ref:$ref, path:"a/bar"}, license:"MIT", review:{runs:"none", network:"none"}},
    {name:"badref", bundle:"extra", summary:"x", source:{repo:"acme/skills", ref:"0000000000000000000000000000000000000000", path:"skills/foo"}, license:"MIT", review:{runs:"none", network:"none"}}
  ]}' >"$SETUP_CATALOG/design-skills.json"
}
design_catalog "$DESIGN_REF1"
SETUP_ENV=(HM_SETUP_GIT_BASE="$SETUP_T/remote")
design_status() { setup_cmd design list | jq -r --arg n "$1" --arg t "$2" 'select(.name == $n) | .status[$t]'; }
assert_eq "absent" "$(design_status foo claude)" "design skill starts absent"
DESIGN_OUT="$(setup_cmd design install --tool both core)"
assert_eq "installed installed" "$(jq -r 'select(.name=="foo") | .action' <<<"$DESIGN_OUT" | paste -sd' ' -)" "core bundle installs foo for both tools"
assert_eq "builtin" "$(jq -r 'select(.name=="viz" and .tool=="claude") | .action' <<<"$DESIGN_OUT")" "built-in skill needs no install"
assert_eq "skipped unavailable" "$(jq -r 'select(.name=="viz" and .tool=="codex") | "\(.action) \(.detail)"' <<<"$DESIGN_OUT")" "built-in skill is unavailable on the other tool"
assert_eq "0" "$(jq -r 'select(.name=="bar")' <<<"$DESIGN_OUT" | grep -c . || true)" "core bundle leaves extras alone"
assert_contains "$(cat "$SETUP_T/claude/foo/SKILL.md")" "foo v1" "installed copy comes from the pinned commit"
assert_eq "MIT upstream" "$(cat "$SETUP_T/codex/foo/LICENSE")" "upstream license travels with a skill folder that has none"
[[ ! -e "$SETUP_T/claude/foo/unrelated" && ! -e "$SETUP_T/claude/unrelated" ]] || fail "only the skill folder is installed"
assert_eq "$DESIGN_REF1" "$(jq -r '.installed["claude:foo"].ref' "$SETUP_T/data/setup/state.json")" "state records the pinned commit"
assert_eq "current" "$(design_status foo codex)" "installed design skill is current"
[[ -z "$(find "$SETUP_T/data/setup/tmp" -mindepth 1 -maxdepth 1 2>/dev/null)" ]] || fail "fetch work dirs are cleaned up"
setup_cmd design install --tool both bar >/dev/null
assert_contains "$(cat "$SETUP_T/claude/bar/SKILL.md")" "claude bar" "per-tool path installs the Claude variant"
assert_contains "$(cat "$SETUP_T/codex/bar/SKILL.md")" "codex bar" "per-tool path installs the Codex variant"
assert_eq "skipped manual" "$(setup_cmd design install --tool claude hand | jq -r '"\(.action) \(.detail)"')" "unpinnable skill is not installed"
assert_eq "manual" "$(design_status hand claude)" "unpinnable skill reports manual"
assert_contains "$(setup_cmd design install --tool claude wrongname | jq -r '"\(.action) \(.detail)"')" "failed SKILL.md name is not wrongname" "folder whose SKILL.md names another skill is refused"
[[ ! -e "$SETUP_T/claude/wrongname" ]] || fail "refused skill left a folder"
assert_eq "failed" "$(setup_cmd design install --tool claude badref | jq -r '.action')" "unknown pinned commit fails"
assert_eq "unknown" "$(setup_cmd design install --tool claude nope | jq -r '.action')" "unknown design skill rejected"
# 검증에 실패하는 교체는 사용자 폴더를 옮기기 전에 멈춘다.
mkdir -p "$SETUP_T/claude/wrongname"
printf 'mine\n' >"$SETUP_T/claude/wrongname/SKILL.md"
assert_eq "failed" "$(setup_cmd design install --tool claude --replace wrongname | jq -r '.action')" "invalid replacement fails"
assert_eq "mine" "$(cat "$SETUP_T/claude/wrongname/SKILL.md")" "failed replacement keeps the user's folder in place"
rm -rf "$SETUP_T/claude/wrongname"
# 원본을 고정할 수 없는 스킬은 직접 깐 사본이 있어도 --replace로 받으러 가지 않는다.
mkdir -p "$SETUP_T/claude/hand"
printf 'hand made\n' >"$SETUP_T/claude/hand/SKILL.md"
assert_eq "foreign" "$(design_status hand claude)" "hand-installed unpinnable skill shows as foreign"
assert_eq "skipped manual" "$(setup_cmd design install --tool claude --replace hand | jq -r '"\(.action) \(.detail)"')" "unpinnable skill is never fetched"
assert_eq "hand made" "$(cat "$SETUP_T/claude/hand/SKILL.md")" "hand-installed unpinnable skill untouched"
# 카탈로그 값은 git 인자·경로가 되기 전에 확인한다.
jq '.skills += [{name:"escape", bundle:"extra", summary:"x", source:{repo:"acme/skills", ref:"'"$DESIGN_REF1"'", path:"../.."}, license:"MIT", review:{runs:"none", network:"none"}},
  {name:"nocodex", bundle:"extra", summary:"x", source:{repo:"acme/skills", ref:"'"$DESIGN_REF1"'", path:{claude:"skills/foo"}}, license:"MIT", review:{runs:"none", network:"none"}}]' \
  "$SETUP_CATALOG/design-skills.json" >"$SETUP_T/d.json" && mv "$SETUP_T/d.json" "$SETUP_CATALOG/design-skills.json"
assert_eq "failed invalid source.path" "$(setup_cmd design install --tool claude escape | jq -r '"\(.action) \(.detail)"')" "path escaping the source repository is refused"
assert_eq "failed invalid source.path" "$(setup_cmd design install --tool codex nocodex | jq -r '"\(.action) \(.detail)"')" "missing per-tool path is refused"
jq '(.skills[] | select(.name=="badref") | .source.ref) = "--upload-pack=touch"' "$SETUP_CATALOG/design-skills.json" >"$SETUP_T/d.json" && mv "$SETUP_T/d.json" "$SETUP_CATALOG/design-skills.json"
assert_eq "failed source.ref must be a 40-character commit" "$(setup_cmd design install --tool claude badref | jq -r '"\(.action) \(.detail)"')" "a non-commit ref is refused before git runs"
# "."은 .git까지 복사하고, glob은 sparse 패턴을 넓히고, ".."은 원본 저장소 밖을 가리킨다.
for DESIGN_BAD in 'path:"."' 'path:"a/*"' 'path:"!a"' 'path:"a//b"' 'path:"a/./b"' 'repo:"../x"' 'repo:"acme/.."'; do
  jq --arg ref "$DESIGN_REF1" ".skills += [{name:\"bad\", bundle:\"extra\", summary:\"x\", source:({repo:\"acme/skills\", ref:\$ref, path:\"skills/foo\"} + {$DESIGN_BAD}), license:\"MIT\", review:{runs:\"none\", network:\"none\"}}]" \
    "$SETUP_CATALOG/design-skills.json" >"$SETUP_T/bad.json"
  DESIGN_BAD_OUT="$(HM_SETUP_DESIGN_CATALOG="$SETUP_T/bad.json" setup_cmd design install --tool claude bad | jq -r '"\(.action) \(.detail)"')"
  assert_contains "$DESIGN_BAD_OUT" "failed invalid source." "catalog value $DESIGN_BAD is refused before git runs"
  [[ ! -e "$SETUP_T/claude/bad" ]] || fail "refused catalog value $DESIGN_BAD left a folder"
done
# 빈 묶음도 bash 3.2 set -u에서 멈추지 않는다.
jq '.skills |= map(select(.bundle != "extra"))' "$SETUP_CATALOG/design-skills.json" >"$SETUP_T/core-only.json"
HM_SETUP_DESIGN_CATALOG="$SETUP_T/core-only.json" setup_cmd design install --tool claude extra >/dev/null || fail "an empty bundle fails under set -u"
# 스킬 자리에 파일이나 symlink가 있으면 우리가 깐 사본이 아니다.
printf 'a file\n' >"$SETUP_T/claude/bar2"
jq '.skills += [(.skills[] | select(.name=="bar") | .name = "bar2" | .source.path = "a/bar")]' "$SETUP_CATALOG/design-skills.json" >"$SETUP_T/bar2.json"
assert_eq "skipped foreign" "$(HM_SETUP_DESIGN_CATALOG="$SETUP_T/bar2.json" setup_cmd design install --tool claude bar2 | jq -r '"\(.action) \(.detail)"')" "a file in the skill slot is foreign"
assert_eq "a file" "$(cat "$SETUP_T/claude/bar2")" "a file in the skill slot is kept"
rm -f "$SETUP_T/claude/bar2"
# 관리 사본에 사용자가 더한 symlink·빈 디렉터리는 수정으로 본다 — 지우지 않는다.
ln -s /etc/hosts "$SETUP_T/claude/bar/my-link"
assert_eq "modified" "$(design_status bar claude)" "a symlink added to a managed copy counts as modified"
assert_eq "skipped modified" "$(setup_cmd design remove --tool claude bar | jq -r '"\(.action) \(.detail)"')" "a managed copy with a user symlink is not removed"
[[ -L "$SETUP_T/claude/bar/my-link" ]] || fail "user symlink removed"
rm "$SETUP_T/claude/bar/my-link"
mkdir "$SETUP_T/claude/bar/my-empty"
assert_eq "modified" "$(design_status bar claude)" "an empty directory added to a managed copy counts as modified"
rmdir "$SETUP_T/claude/bar/my-empty"
assert_eq "current" "$(design_status bar claude)" "the untouched managed copy is current again"
# 외부 git은 프롬프트·hook·LFS 필터 없이, 느린 연결을 끊고 돈다.
SETUP_SRC="$(<"$ROOT/scripts/setup.sh")"
for DESIGN_GIT_OPT in "GIT_TERMINAL_PROMPT=0" "GIT_SSH_COMMAND='ssh -o BatchMode=yes'" "http.lowSpeedLimit=1000" "http.lowSpeedTime=30" "core.hooksPath=/dev/null" "filter.lfs.process=" "GIT_LFS_SKIP_SMUDGE=1"; do
  assert_contains "$SETUP_SRC" "$DESIGN_GIT_OPT" "design git runs with $DESIGN_GIT_OPT"
done
# shellcheck disable=SC2016  # 셸 변수가 아니라 setup.sh 소스의 문자열을 찾는다
[[ "$(grep -cE '^[[:space:]]*(GIT_[A-Z_]+=[^ ]+ )*git -C "\$work"' "$ROOT/scripts/setup.sh")" == 0 ]] || fail "design fetch calls git without design_git"
# 교체하며 옮겨 둔 기존 폴더는 중단돼도 지워지는 tmp가 아니라 backups에 있다.
# shellcheck disable=SC2016  # 소스 문자열 그대로
assert_contains "$SETUP_SRC" 'old="$STATE_DIR/backups/old-' "replaced folder waits in backups, not tmp"
# 사용자가 원래 갖고 있던 같은 이름 스킬은 --replace 없이는 그대로 둔다.
setup_cmd design remove --tool claude foo >/dev/null
mkdir -p "$SETUP_T/claude/foo"
printf 'my own foo\n' >"$SETUP_T/claude/foo/SKILL.md"
assert_eq "skipped foreign" "$(setup_cmd design install --tool claude foo | jq -r '"\(.action) \(.detail)"')" "foreign design skill kept"
DESIGN_OUT="$(setup_cmd design install --tool claude --replace foo)"
assert_eq "replaced" "$(jq -r '.action' <<<"$DESIGN_OUT")" "foreign design skill replaced on request"
assert_eq "my own foo" "$(cat "$(jq -r '.detail' <<<"$DESIGN_OUT")/SKILL.md")" "replaced design skill backed up"
# 고정 커밋이 바뀌면 outdated. 고친 사본은 갱신하지 않는다. SessionStart·update는 네트워크로 외부 스킬을 갱신하지 않는다.
printf -- '---\nname: foo\n---\nfoo v2\n' >"$DESIGN_REMOTE/skills/foo/SKILL.md"
git -C "$DESIGN_REMOTE" -c user.name=t -c user.email=t@t commit -qam v2
design_catalog "$(git -C "$DESIGN_REMOTE" rev-parse HEAD)"
assert_eq "outdated" "$(design_status foo claude)" "new pinned commit makes the copy outdated"
printf '{}' | setup_cmd notify >/dev/null
setup_cmd update >/dev/null
assert_contains "$(cat "$SETUP_T/claude/foo/SKILL.md")" "foo v1" "SessionStart and update leave design skills alone"
printf 'local\n' >>"$SETUP_T/codex/foo/SKILL.md"
DESIGN_OUT="$(setup_cmd design install --tool both foo)"
assert_eq "updated" "$(jq -r 'select(.tool=="claude") | .action' <<<"$DESIGN_OUT")" "outdated design skill updates"
assert_eq "skipped modified" "$(jq -r 'select(.tool=="codex") | "\(.action) \(.detail)"' <<<"$DESIGN_OUT")" "edited design skill is not overwritten"
assert_contains "$(cat "$SETUP_T/claude/foo/SKILL.md")" "foo v2" "update installs the new pinned commit"
assert_eq "removed" "$(setup_cmd design remove --tool claude foo | jq -r '.action')" "remove managed design skill"
[[ ! -e "$SETUP_T/claude/foo" ]] || fail "removed design skill dir still exists"
assert_eq "skipped modified" "$(setup_cmd design remove --tool codex foo | jq -r '"\(.action) \(.detail)"')" "edited design skill is not removed without --force"
# ai-harness에 내장된 항목: 받지 않고, setup이 예전에 깐 사본만 superseded로 알려 지울 수 있게 한다. 사용자가 둔 폴더는 건드리지 않는다.
assert_eq "outdated" "$(design_status bar claude)" "bar is an unmodified managed copy (of an older pin) before it becomes built in"
jq '(.skills[] | select(.name=="bar")) += {builtin:"ai-harness"} | .skills += [{name:"mine", bundle:"extra", summary:"x", builtin:"ai-harness", note:"built in"}]' \
  "$SETUP_CATALOG/design-skills.json" >"$SETUP_T/d.json" && mv "$SETUP_T/d.json" "$SETUP_CATALOG/design-skills.json"
mkdir -p "$SETUP_T/claude/mine" && printf 'my own\n' >"$SETUP_T/claude/mine/SKILL.md"
printf 'local\n' >>"$SETUP_T/codex/bar/SKILL.md"
assert_eq "superseded" "$(design_status bar claude)" "an old setup copy of a now built-in skill is superseded"
assert_eq "modified" "$(design_status bar codex)" "an edited old copy of a built-in skill stays modified"
assert_eq "foreign" "$(design_status mine claude)" "a hand-placed folder named like a built-in skill is foreign"
assert_eq "builtin" "$(design_status mine codex)" "a built-in skill with nothing installed is builtin"
assert_contains "$(setup_cmd design list | jq -r 'select(.name=="mine") | .conflict.claude')" "같은 이름 내장 스킬 있음" "list flags a hand-placed folder that shadows a built-in skill"
assert_eq "null null" "$(setup_cmd design list | jq -r 'select(.name=="mine" or .name=="foo") | .conflict.codex // "null"' | paste -sd' ' -)" "no conflict notice without a hand-placed folder"
assert_eq "ai-harness" "$(setup_cmd design list | jq -r 'select(.name=="bar") | .builtin')" "list says the skill is built into ai-harness"
assert_eq "builtin builtin" "$(setup_cmd design install --tool both --replace bar | jq -r '.action' | paste -sd' ' -)" "a built-in skill is never fetched, even with --replace"
assert_contains "$(cat "$SETUP_T/claude/bar/SKILL.md")" "claude bar" "install leaves the superseded copy in place"
assert_eq "skipped foreign" "$(setup_cmd design remove --tool claude mine | jq -r '"\(.action) \(.detail)"')" "a hand-placed folder is not removed"
assert_eq "skipped modified" "$(setup_cmd design remove --tool codex bar | jq -r '"\(.action) \(.detail)"')" "an edited superseded copy needs --force"
assert_eq "removed" "$(setup_cmd design remove --tool claude bar | jq -r '.action')" "a superseded copy is removable"
[[ ! -e "$SETUP_T/claude/bar" ]] || fail "removed superseded copy still exists"
assert_eq "builtin" "$(design_status bar claude)" "after removal only the built-in copy remains"
SETUP_ENV=()
# 기본 스킬 목록·안내에는 외부 디자인 스킬이 섞이지 않는다.
assert_eq "0" "$(setup_cmd list | jq -r 'select(.name=="foo" or .name=="impeccable") | .name' | grep -c . || true)" "plain list shows only the base catalog"
pass "setup installs design skills from pinned upstream commits"

finish_tests
