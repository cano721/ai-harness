#!/usr/bin/env bash
# 회귀 테스트 — setup 카탈로그·팀 규칙·디자인 스킬·자격 증명·langfuse
# 실행: bash tests/run.sh setup
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 기본 스킬 카탈로그: 플러그인 스킬이 아니라 선택 설치 원본이며, Codex도 읽을 수 있는 frontmatter만 쓴다.
CATALOG_NAMES="$(jq -r '.skills[].name' "$ROOT/catalog/catalog.json" | sort | paste -sd' ' -)"
assert_eq "$CATALOG_NAMES" "$(find "$ROOT/catalog" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | paste -sd' ' -)" "catalog.json lists every catalog skill"
for name in $CATALOG_NAMES; do
  skill_md="$ROOT/catalog/$name/SKILL.md"
  assert_file "$skill_md"
  assert_eq "name: $name" "$(sed -n '2p' "$skill_md")" "catalog $name frontmatter name"
  assert_eq "description" "$(sed -n '3p' "$skill_md" | cut -d: -f1)" "catalog $name frontmatter description"
  assert_eq "---" "$(sed -n '4p' "$skill_md")" "catalog $name frontmatter has only name and description"
  [[ ! -e "$ROOT/skills/$name" ]] || fail "catalog skill $name must not be a plugin skill"
  if grep -qiE 'midas|jobda|khb1122' "$skill_md"; then fail "catalog $name carries organization-specific values"; fi
  if grep -qE 'curl[^|]*(-u |-H .(DD-API-KEY|Authorization))' "$skill_md"; then fail "catalog $name puts credentials on argv"; fi
done
pass "skill catalog is generic and stays out of plugin skills"

SETUP_T="$TEST_TMP/setup"
SETUP_CATALOG="$SETUP_T/catalog"
mkdir -p "$SETUP_T"
cp -R "$ROOT/catalog" "$SETUP_CATALOG"
printf '{"env":{"SENTRY_AUTH_TOKEN":"sntrys_secret_value"}}\n' >"$SETUP_T/settings.json"
setup_cmd() {
  env -u DATADOG_API_KEY -u DD_API_KEY -u SENTRY_AUTH_TOKEN -u SENTRY_ORG -u ATLASSIAN_USER -u ATLASSIAN_API_TOKEN \
    -u LANGFUSE_PUBLIC_KEY -u LANGFUSE_SECRET_KEY -u LANGFUSE_HOST \
    HARNESS_METRICS_DIR="$SETUP_T/data" HM_SETUP_CATALOG_DIR="$SETUP_CATALOG" HARNESS_CLAUDE_SETTINGS="$SETUP_T/settings.json" \
    HM_CLAUDE_SKILLS_DIR="$SETUP_T/claude" HM_CODEX_SKILLS_DIR="$SETUP_T/codex" HM_SETUP_HINT=1 \
    "${SETUP_ENV[@]+"${SETUP_ENV[@]}"}" "$ROOT/scripts/setup.sh" "$@"
}
setup_status() { setup_cmd list | jq -r --arg n "$1" --arg t "$2" 'select(.name == $n) | .status[$t]'; }
SETUP_ENV=()
mkdir -p "$SETUP_T/claude/jira"
printf 'my own jira\n' >"$SETUP_T/claude/jira/SKILL.md"

SETUP_ENV=(DATADOG_API_KEY=dd_secret_value)
SETUP_LIST="$(setup_cmd list)"
SETUP_ENV=()
assert_eq "env" "$(jq -r 'select(.name=="datadog") | .env[0].source' <<<"$SETUP_LIST")" "env key found in process env"
assert_eq "settings" "$(jq -r 'select(.name=="sentry") | .env[0].source' <<<"$SETUP_LIST")" "env key found in Claude settings"
assert_eq "missing" "$(jq -r 'select(.name=="sentry") | .env[1].source' <<<"$SETUP_LIST")" "missing env key reported"
if grep -qE 'dd_secret_value|sntrys_secret_value' <<<"$SETUP_LIST"; then fail "setup list must not print credential values"; fi
assert_eq "foreign" "$(jq -r 'select(.name=="jira") | .status.claude' <<<"$SETUP_LIST")" "pre-existing skill is foreign"

SETUP_OUT="$(setup_cmd install --tool claude datadog jira nope)"
assert_eq "installed" "$(jq -r 'select(.name=="datadog") | .action' <<<"$SETUP_OUT")" "install catalog skill"
assert_eq "skipped foreign" "$(jq -r 'select(.name=="jira") | "\(.action) \(.detail)"' <<<"$SETUP_OUT")" "foreign skill is kept"
assert_eq "unknown" "$(jq -r 'select(.name=="nope") | .action' <<<"$SETUP_OUT")" "unknown skill rejected"
assert_eq "my own jira" "$(cat "$SETUP_T/claude/jira/SKILL.md")" "foreign skill content untouched"
cmp -s "$SETUP_CATALOG/datadog/SKILL.md" "$SETUP_T/claude/datadog/SKILL.md" || fail "installed copy matches catalog"
assert_eq "current" "$(setup_status datadog claude)" "fresh install is current"
assert_eq "absent" "$(setup_status datadog codex)" "other tool untouched"
assert_eq "unchanged" "$(setup_cmd install --tool claude datadog | jq -r '.action')" "reinstall is a no-op"

# 카탈로그가 바뀌면 손대지 않은 사본만 SessionStart가 갱신하고, 고친 사본은 남긴다.
setup_cmd install --tool claude sentry >/dev/null
printf '\nlocal note\n' >>"$SETUP_T/claude/sentry/SKILL.md"
assert_eq "modified" "$(setup_status sentry claude)" "user-edited copy is modified"
printf '\n<!-- v2 -->\n' >>"$SETUP_CATALOG/datadog/SKILL.md"
printf '\n<!-- v2 -->\n' >>"$SETUP_CATALOG/sentry/SKILL.md"
assert_eq "outdated" "$(setup_status datadog claude)" "untouched copy becomes outdated"
setup_cmd 'done' >/dev/null
REFRESH_NOTICE="$(printf '{}' | setup_cmd notify)"
assert_contains "$(jq -r '.systemMessage' <<<"$REFRESH_NOTICE")" "갱신했습니다: datadog" "SessionStart refreshes untouched copies"
cmp -s "$SETUP_CATALOG/datadog/SKILL.md" "$SETUP_T/claude/datadog/SKILL.md" || fail "refreshed copy matches new catalog"
assert_contains "$(cat "$SETUP_T/claude/sentry/SKILL.md")" "local note" "edited copy kept on refresh"
assert_eq "" "$(printf '{}' | setup_cmd notify)" "nothing to refresh or announce"

assert_eq "skipped modified" "$(setup_cmd remove --tool claude sentry | jq -r '"\(.action) \(.detail)"')" "edited copy not removed without force"
SETUP_OUT="$(setup_cmd install --tool claude --replace jira)"
assert_eq "replaced" "$(jq -r '.action' <<<"$SETUP_OUT")" "replace foreign skill on request"
assert_eq "my own jira" "$(cat "$(jq -r '.detail' <<<"$SETUP_OUT")/SKILL.md")" "replaced skill backed up"
assert_eq "current" "$(setup_status jira claude)" "replaced skill is managed"
assert_eq "removed" "$(setup_cmd remove --tool claude datadog | jq -r '.action')" "remove managed copy"
[[ ! -e "$SETUP_T/claude/datadog" ]] || fail "removed skill dir still exists"
assert_eq "installed installed" "$(setup_cmd install --tool both confluence | jq -r '.action' | paste -sd' ' -)" "install for both tools"
assert_file "$SETUP_T/codex/confluence/SKILL.md"
pass "setup installs, refreshes and removes only managed copies"

# 셋업 안내: 처음 한 번, 셋업 뒤에는 카탈로그에 새 스킬이 생길 때만. Codex 세션은 슬래시 대신 스킬 이름으로 안내한다.
SETUP_T="$TEST_TMP/setup-hint"
SETUP_CATALOG="$SETUP_T/catalog"
mkdir -p "$SETUP_T"
cp -R "$ROOT/catalog" "$SETUP_CATALOG"
HINT_OUT="$(printf '{"transcript_path":"/x/rollout-2026-10-30T00-00-00-abc.jsonl"}' | setup_cmd notify | jq -r '.systemMessage')"
assert_contains "$HINT_OUT" "ai-harness setup 스킬" "Codex hint names the skill"
assert_contains "$HINT_OUT" "datadog·sentry·jira·confluence" "first hint lists the catalog"
assert_eq "" "$(printf '{}' | setup_cmd notify)" "first hint shown once"
setup_cmd 'done' >/dev/null
jq '.version += 1 | .skills += [{name:"pagerduty", since:.version, summary:"x", env:[]}]' "$SETUP_CATALOG/catalog.json" >"$SETUP_T/c.json"
mv "$SETUP_T/c.json" "$SETUP_CATALOG/catalog.json"
NEW_HINT="$(printf '{"transcript_path":"/x/a.jsonl"}' | setup_cmd notify | jq -r '.systemMessage')"
assert_contains "$NEW_HINT" "새 기본 스킬이 추가됐습니다: pagerduty" "new catalog skills announced"
assert_contains "$NEW_HINT" "/ai-harness:setup" "Claude hint uses the slash command"
assert_eq "" "$(printf '{}' | setup_cmd notify)" "new-skill hint shown once"
SETUP_T="$TEST_TMP/setup-off"
mkdir -p "$SETUP_T"
SETUP_ENV=(HM_SETUP_HINT=0)
assert_eq "" "$(printf '{}' | setup_cmd notify)" "HM_SETUP_HINT=0 silences the hint"
SETUP_ENV=()
assert_contains "$(<"$ROOT/scripts/session-start.sh")" 'setup.sh" notify' "SessionStart carries the setup notice"
pass "setup hint on first session and on new catalog skills"

# 팀 규칙: 개인 config → 저장소 표식 순으로 원본을 찾고, 차이를 보여 준 sha로만 팀 블록을 쓴다. 개인 블록은 유지. (#243)
SETUP_T="$TEST_TMP/setup-team"
SETUP_CATALOG="$ROOT/catalog"
TEAM_SRC="$SETUP_T/team-rules"
TEAM_REPO="$SETUP_T/repo"
mkdir -p "$TEAM_SRC/skills" "$TEAM_REPO/.ai-harness" "$TEAM_REPO/src/deep" "$SETUP_T/data/skills"
printf -- '- 에이전트는 Story를 만들지 않는다\n' >"$TEAM_SRC/skills/jira.md"
printf 'not a catalog skill\n' >"$TEAM_SRC/skills/notes.md"
SETUP_ENV=(HM_TEAM_RULES_REFRESH_HOURS=0)
team_cmd() { (cd "${TEAM_CWD:-$TEAM_REPO/src/deep}" && HOME="$SETUP_T/home" setup_cmd team "$@"); }
assert_eq "null" "$(team_cmd source | jq -r '.source')" "no source without config or repo marker"
assert_eq "[]" "$(team_cmd list | jq -c '.skills')" "list without a source is empty"
jq -n '{project_id:"svc", team_rules:{source:"../team-rules"}}' >"$TEAM_REPO/.ai-harness/harness.json"
TEAM_REAL="$(cd "$TEAM_SRC" && pwd -P)"
assert_eq "$TEAM_REAL" "$(team_cmd source | jq -r '.source')" "repo marker found from a subdirectory, relative to the repo root"
assert_contains "$(team_cmd source | jq -r '.from')" ".ai-harness/harness.json" "source names the marker file"
mkdir -p "$SETUP_T/other/skills"
SETUP_ENV=(HM_TEAM_RULES_REFRESH_HOURS=0 HM_TEAM_RULES="$SETUP_T/other")
assert_eq "config" "$(team_cmd source | jq -r '.from')" "personal config wins over the repo marker"
SETUP_ENV=(HM_TEAM_RULES_REFRESH_HOURS=0)
TEAM_LIST="$(team_cmd list)"
assert_eq "jira:new" "$(jq -r '[.skills[] | "\(.name):\(.state)"] | join(" ")' <<<"$TEAM_LIST")" "list shows only catalog skills the source has"
TEAM_SHA="$(jq -r '.skills[0].sha256' <<<"$TEAM_LIST")"
printf '# jira 사용자 규칙\n- 기본 프로젝트: NJ\n' >"$SETUP_T/data/skills/jira.md"
assert_eq "untracked" "$(team_cmd list | jq -r '.skills[0].state')" "a profile without a team block is untracked"
TEAM_DIFF="$(team_cmd diff jira)"
assert_contains "$TEAM_DIFF" "+- 에이전트는 Story를 만들지 않는다" "diff shows the team rule to add"
assert_contains "$TEAM_DIFF" "sha256 $TEAM_SHA" "diff names the sha to apply"
assert_eq "# jira 사용자 규칙" "$(head -1 "$SETUP_T/data/skills/jira.md")" "diff does not write"
assert_eq "stale" "$(team_cmd apply jira --sha "$(printf '%064d' 0)" 2>/dev/null | jq -r '.action')" "apply refuses a sha other than the diffed source"
assert_eq "applied" "$(team_cmd apply jira --sha "$TEAM_SHA" | jq -r '.action')" "apply writes after confirmation"
TEAM_FILE="$(<"$SETUP_T/data/skills/jira.md")"
assert_contains "$TEAM_FILE" "sha256=\"$TEAM_SHA\"" "team block records the source sha"
assert_contains "$TEAM_FILE" "- 기본 프로젝트: NJ" "personal rules kept"
assert_eq "current" "$(team_cmd list | jq -r '.skills[0].state')" "applied block is current"
assert_eq "unchanged" "$(team_cmd apply jira --sha "$TEAM_SHA" | jq -r '.action')" "re-apply of the same source is a no-op"
# 원본이 바뀌면: SessionStart는 알리기만 하고(같은 sha는 한 번), 재적용은 팀 블록만 바꾼다.
printf -- '- 이슈 타입: 에픽 > Task > SubTask, 에이전트는 Story를 만들지 않는다\n- Drop 상태를 쓰지 않는다\n' >"$TEAM_SRC/skills/jira.md"
printf '\n- 개인 메모\n' >>"$SETUP_T/data/skills/jira.md"
setup_cmd 'done' >/dev/null
TEAM_NOTE="$(printf '{"cwd":"%s"}' "$TEAM_REPO" | setup_cmd notify | jq -r '.systemMessage')"
assert_contains "$TEAM_NOTE" "팀 규칙 원본이 갱신됐습니다: jira" "SessionStart notices a changed team source"
assert_contains "$TEAM_NOTE" "자동으로 덮어쓰지 않습니다" "the notice does not overwrite"
assert_contains "$(<"$SETUP_T/data/skills/jira.md")" "에이전트는 Story를 만들지 않는다
<!--" "SessionStart leaves the profile alone"
assert_eq "" "$(printf '{"cwd":"%s"}' "$TEAM_REPO" | setup_cmd notify)" "the same change is announced once"
assert_eq "changed" "$(team_cmd list | jq -r '.skills[0].state')" "list shows the source changed"
TEAM_SHA="$(team_cmd list | jq -r '.skills[0].sha256')"
team_cmd apply jira --sha "$TEAM_SHA" >/dev/null
TEAM_FILE="$(<"$SETUP_T/data/skills/jira.md")"
assert_contains "$TEAM_FILE" "- Drop 상태를 쓰지 않는다" "re-apply updates the team block"
assert_eq "1" "$(grep -c '에이전트는 Story' "$SETUP_T/data/skills/jira.md")" "old team block replaced, not duplicated"
assert_contains "$TEAM_FILE" "- 기본 프로젝트: NJ" "re-apply keeps personal rules"
assert_contains "$TEAM_FILE" "- 개인 메모" "re-apply keeps personal edits"
# 새 파일은 팀 블록 + 빈 개인 블록으로 만든다.
printf -- '- 기본 스페이스: ENG\n' >"$TEAM_SRC/skills/confluence.md"
team_cmd apply confluence --sha "$(team_cmd list | jq -r '.skills[] | select(.name=="confluence") | .sha256')" >/dev/null
assert_contains "$(<"$SETUP_T/data/skills/confluence.md")" "# confluence 개인 규칙" "new profile gets a personal section"
# 깨진 마커·마커를 품은 원본은 쓰지 않는다.
printf '<!-- ai-harness:team-rules:end -->\n' >>"$SETUP_T/data/skills/confluence.md"
assert_eq "broken" "$(team_cmd list | jq -r '.skills[] | select(.name=="confluence") | .state')" "a profile with broken markers is reported"
if team_cmd apply confluence --sha "$(team_cmd list | jq -r '.skills[] | select(.name=="confluence") | .sha256')" >/dev/null 2>&1; then fail "apply over broken markers"; fi
printf '<!-- ai-harness:team-rules:begin source="x" ref="" sha256="%s" -->\n' "$(printf '%064d' 0)" >"$TEAM_SRC/skills/sentry.md"
if team_cmd diff sentry >/dev/null 2>&1; then fail "a source carrying a marker is accepted"; fi
if team_cmd diff nope >/dev/null 2>&1; then fail "unknown skill accepted"; fi
# 저장소 표식이 가리키지만 아직 가져오지 않은 원본은 원본마다 한 번 알린다.
TEAM_REPO2="$SETUP_T/repo2"
mkdir -p "$TEAM_REPO2/.ai-harness" "$SETUP_T/team2/skills"
jq -n --arg s "$SETUP_T/team2" '{team_rules:{source:$s}}' >"$TEAM_REPO2/.ai-harness/workspace.json"
assert_contains "$(printf '{"cwd":"%s"}' "$TEAM_REPO2" | setup_cmd notify | jq -r '.systemMessage')" "팀 규칙 원본이 지정돼 있습니다" "workspace marker offers the source once"
assert_eq "" "$(printf '{"cwd":"%s"}' "$TEAM_REPO2" | setup_cmd notify)" "the offer is shown once"
SETUP_ENV=(HM_TEAM_RULES_REFRESH_HOURS=0 HM_TEAM_RULES_HINT=0)
cp "$TEAM_SRC/skills/jira.md" "$SETUP_T/jira.keep"
printf -- '- 바뀜\n' >"$TEAM_SRC/skills/jira.md"
assert_eq "" "$(printf '{}' | setup_cmd notify)" "HM_TEAM_RULES_HINT=0 silences team notices"
mv "$SETUP_T/jira.keep" "$TEAM_SRC/skills/jira.md"
# git 원본: skills/만 캐시로 받고, ref를 따른다. SessionStart는 네트워크 없이 캐시와 비교한다.
TEAM_GIT="$SETUP_T/team-git"
mkdir -p "$TEAM_GIT/skills" "$TEAM_GIT/other"
printf -- '- git v1\n' >"$TEAM_GIT/skills/datadog.md"
printf 'secret-ish\n' >"$TEAM_GIT/other/x.txt"
git -C "$TEAM_GIT" init -q -b main
git -C "$TEAM_GIT" add -A && git -C "$TEAM_GIT" -c user.name=t -c user.email=t@t commit -qm v1
SETUP_ENV=(HM_TEAM_RULES_REFRESH_HOURS=0 HM_TEAM_RULES="file://$TEAM_GIT" HM_TEAM_RULES_REF=main)
TEAM_LIST="$(team_cmd list)"
assert_eq "datadog:new" "$(jq -r '[.skills[] | "\(.name):\(.state)"] | join(" ")' <<<"$TEAM_LIST")" "git source lists its rules"
[[ -z "$(find "$SETUP_T/data/setup/team" -path '*/src/other' 2>/dev/null)" ]] || fail "git fetch takes only skills/"
team_cmd apply datadog --sha "$(jq -r '.skills[0].sha256' <<<"$TEAM_LIST")" >/dev/null
assert_contains "$(<"$SETUP_T/data/skills/datadog.md")" 'ref="main"' "team block records the ref"
printf -- '- git v2\n' >"$TEAM_GIT/skills/datadog.md"
git -C "$TEAM_GIT" -c user.name=t -c user.email=t@t commit -qam v2
assert_eq "" "$(printf '{}' | setup_cmd notify)" "SessionStart does not fetch"
setup_cmd team refresh
assert_contains "$(printf '{}' | setup_cmd notify | jq -r '.systemMessage')" "갱신됐습니다: datadog" "refreshed git cache shows the change"
SETUP_ENV=(HM_TEAM_RULES_REFRESH_HOURS=0 HM_TEAM_RULES="file://$TEAM_GIT" HM_TEAM_RULES_REF="--upload-pack=touch")
if team_cmd list >/dev/null 2>&1; then fail "an option-like ref is accepted"; fi
SETUP_ENV=(HM_TEAM_RULES_REFRESH_HOURS=0 HM_TEAM_RULES='ext::sh -c touch% /tmp/pwned')
assert_eq "config" "$(team_cmd source | jq -r '.from')" "config source is reported"
if team_cmd list >/dev/null 2>&1; then fail "a non-git, non-directory source is accepted"; fi
SETUP_ENV=()
pass "setup imports team rules with diff, confirmation and update notices"

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

# 접속 정보: secret은 인자로 받지 않고 stdin으로만, 저장한 파일에서 바로 연결 확인. 자격 증명은 HTTP 호출 인자에도 싣지 않는다.
SETUP_T="$TEST_TMP/setup-creds"
SETUP_CATALOG="$ROOT/catalog"
mkdir -p "$SETUP_T"
printf '{"model":"opus","env":{"KEEP":"1"}}\n' >"$SETUP_T/settings.json"
cat >"$SETUP_T/http.sh" <<'STUB'
#!/usr/bin/env bash
conf="$(cat)"
printf '%s\n' "$*" >>"${0%/*}/argv.log"
case "$conf" in *bad-token*) printf 'HTTP 401\n' >&2; exit 1 ;; esac
case "$conf" in *pk-lf-from-cmd:sk-lf-from-cmd*) printf '{"data":[{"id":"p2","name":"FromCmd"}]}'; exit 0 ;; esac
case "$1" in
  */rest/api/3/myself) printf '{"displayName":"Kim"}' ;;
  */rest/api/3/field) printf '[{"id":"customfield_10113","name":"스프린트","schema":{"custom":"com.pyxis.greenhopper.jira:gh-sprint"}},{"id":"customfield_1","name":"x","schema":{"type":"string"}}]' ;;
  */rest/api/3/project/recent*) printf '[{"key":"ABC","name":"Alpha"}]' ;;
  */rest/api/3/issue/createmeta/*/issuetypes*) printf '{"issueTypes":[{"id":"1","name":"Epic","subtask":false,"hierarchyLevel":1},{"id":"2","name":"Task","subtask":false,"hierarchyLevel":0},{"id":"3","name":"Story","subtask":false,"hierarchyLevel":0},{"id":"4","name":"Sub-task","subtask":true,"hierarchyLevel":-1}]}' ;;
  */rest/api/3/search/jql*) printf '{"issues":[{"key":"%s-7"}]}' "$(sed -E 's/.*project%3D([A-Z0-9_]+).*/\1/' <<<"$1")" ;;
  */rest/api/3/issue/*-7/transitions) printf '{"transitions":[{"id":"11","name":"진행","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},{"id":"31","name":"Drop","to":{"name":"Drop","statusCategory":{"key":"done"}}}]}' ;;
  */api/public/projects) printf '{"data":[{"id":"p1","name":"Demo"}]}' ;;
  *) printf 'HTTP 404\n' >&2; exit 1 ;;
esac
STUB
chmod +x "$SETUP_T/http.sh"
SETUP_ENV=(HM_SETUP_HTTP="$SETUP_T/http.sh")
if setup_cmd set --tool claude ATLASSIAN_API_TOKEN "tok-in-argv" 2>/dev/null; then fail "secret accepted as an argument"; fi
assert_eq "missing" "$(setup_cmd check jira | jq -r 'if .missing then "missing" else "x" end')" "check reports missing keys"
setup_cmd set --tool claude JIRA_BASE_URL https://acme.atlassian.net/ >/dev/null
setup_cmd set --tool claude ATLASSIAN_USER me@acme.test >/dev/null
printf "good-tok'en\n" | setup_cmd set --tool both ATLASSIAN_API_TOKEN >/dev/null
assert_eq "1" "$(jq -r '.env.KEEP' "$SETUP_T/settings.json")" "settings.json keeps other env"
assert_eq "opus" "$(jq -r '.model' "$SETUP_T/settings.json")" "settings.json keeps other keys"
assert_eq "good-tok'en" "$(jq -r '.env.ATLASSIAN_API_TOKEN' "$SETUP_T/settings.json")" "secret saved to Claude settings"
# shellcheck disable=SC2016  # 변수는 source한 하위 셸에서 펼친다
assert_eq "good-tok'en" "$(env -i /bin/bash -c '. "$1"; printf %s "$ATLASSIAN_API_TOKEN"' _ "$SETUP_T/data/secrets.env")" "secret saved to sourceable Codex file"
assert_eq "600" "$(filemode "$SETUP_T/data/secrets.env")" "secrets file is private"
assert_eq "settings" "$(setup_cmd list | jq -r 'select(.name=="jira") | .env[2].source')" "saved secret visible without restart"
assert_eq "true Kim" "$(setup_cmd check jira | jq -r '"\(.ok) \(.as)"')" "check uses saved credentials"
DETECT="$(setup_cmd detect jira)"
assert_eq "customfield_10113 gh-sprint" "$(jq -r '.fields[0] | "\(.id) \(.type)"' <<<"$DETECT")" "detect finds sprint field by type"
assert_eq "1" "$(jq -r '.fields | length' <<<"$DETECT")" "detect ignores other fields"
assert_eq "ABC" "$(jq -r '.recent_projects[0].key' <<<"$DETECT")" "detect lists recent projects"
# 이슈 타입 계층·쓰지 않는 상태 질문의 선택지: 기본(최근) 프로젝트의 생성 가능 타입과 대표 이슈의 전환. (#243)
assert_eq "Epic:1 Task:0 Story:0 Sub-task:-1" "$(jq -r '[.issue_types[] | "\(.name):\(.hierarchy)"] | join(" ")' <<<"$DETECT")" "detect lists creatable issue types with hierarchy"
assert_eq "ABC-7 Drop:done" "$(jq -r '"\(.transitions.issue) \(.transitions.list[1] | "\(.name):\(.category)")"' <<<"$DETECT")" "detect lists transitions of a representative issue"
assert_eq "XY-7" "$(setup_cmd detect jira --project XY | jq -r '.transitions.issue')" "detect takes the project to inspect"
assert_eq "null 0" "$(setup_cmd detect jira --project 'a;b' | jq -r '"\(.project) \(.issue_types | length)"')" "detect ignores an invalid project key"
printf 'bad-token\n' | setup_cmd set --tool claude ATLASSIAN_API_TOKEN >/dev/null
assert_eq "false HTTP 401" "$(setup_cmd check jira | jq -r '"\(.ok) \(.error)"')" "check reports rejected credentials"
assert_eq "CONFLUENCE_BASE_URL" "$(setup_cmd check confluence | jq -r '.missing | join(",")')" "check names the missing base URL"
assert_eq "LANGFUSE_PUBLIC_KEY,LANGFUSE_SECRET_KEY" "$(setup_cmd check langfuse | jq -r '.missing | join(",")')" "langfuse check names missing project keys"
printf 'pk-lf-good\n' | setup_cmd set --tool claude LANGFUSE_PUBLIC_KEY >/dev/null
printf 'sk-lf-good\n' | setup_cmd set --tool claude LANGFUSE_SECRET_KEY >/dev/null
assert_eq "true Demo" "$(setup_cmd check langfuse | jq -r '"\(.ok) \(.as)"')" "langfuse check shows the project the keys point to"
assert_eq "https://cloud.langfuse.com/api/public/projects" "$(tail -1 "$SETUP_T/argv.log")" "langfuse check defaults to the EU cloud host"
setup_cmd set --tool claude LANGFUSE_HOST https://us.cloud.langfuse.com/ >/dev/null
setup_cmd check langfuse >/dev/null
assert_eq "https://us.cloud.langfuse.com/api/public/projects" "$(tail -1 "$SETUP_T/argv.log")" "langfuse check follows LANGFUSE_HOST"
printf 'sk-lf-bad-token\n' | setup_cmd set --tool claude LANGFUSE_SECRET_KEY >/dev/null
LF_CHECK="$(setup_cmd check langfuse)"
assert_eq "false HTTP 401" "$(jq -r '"\(.ok) \(.error)"' <<<"$LF_CHECK")" "langfuse check reports rejected keys"
assert_contains "$(jq -r '.hint' <<<"$LF_CHECK")" "LANGFUSE_HOST" "langfuse 401 points at key or region mismatch"
# 키 대신 비밀 저장소 명령(_CMD): 사용자 파일에 저장된 명령만 실행하고, 프로세스 환경의 명령은 무시한다.
jq 'del(.env.LANGFUSE_PUBLIC_KEY, .env.LANGFUSE_SECRET_KEY)' "$SETUP_T/settings.json" >"$SETUP_T/settings.tmp" && mv "$SETUP_T/settings.tmp" "$SETUP_T/settings.json"
SETUP_ENV=(HM_SETUP_HTTP="$SETUP_T/http.sh" LANGFUSE_PUBLIC_KEY_CMD="touch $SETUP_T/planted; printf pk-lf-from-cmd" LANGFUSE_SECRET_KEY_CMD="printf sk-lf-from-cmd")
assert_eq "LANGFUSE_PUBLIC_KEY,LANGFUSE_SECRET_KEY" "$(setup_cmd check langfuse | jq -r '.missing | join(",")')" "langfuse key commands in the process env are ignored"
[[ ! -e "$SETUP_T/planted" ]] || fail "a key command from the process env ran"
SETUP_ENV=(HM_SETUP_HTTP="$SETUP_T/http.sh")
setup_cmd set --tool claude LANGFUSE_PUBLIC_KEY_CMD 'printf "pk-lf-from-cmd\n"' >/dev/null
setup_cmd set --tool claude LANGFUSE_SECRET_KEY_CMD 'printf sk-lf-from-cmd' >/dev/null
assert_eq "true FromCmd" "$(setup_cmd check langfuse | jq -r '"\(.ok) \(.as)"')" "langfuse check runs the saved key commands"
assert_eq "LANGFUSE_SECRET_KEY_CMD settings" "$(setup_cmd list | jq -r 'select(.name=="langfuse") | .env[1] | "\(.found) \(.source)"')" "a saved key command counts as the key"
setup_cmd set --tool claude LANGFUSE_SECRET_KEY_CMD 'echo "session expired" >&2; exit 254' >/dev/null
LF_CHECK="$(setup_cmd check langfuse)"
assert_eq "false key command failed" "$(jq -r '"\(.ok) \(.error)"' <<<"$LF_CHECK")" "langfuse check reports a failing key command"
assert_contains "$(jq -r '.hint' <<<"$LF_CHECK")" "ssm:GetParameter" "failing key command hint names login and permissions"
if grep -qE "tok|bad-token|pk-lf|sk-lf" "$SETUP_T/argv.log"; then fail "credentials leaked into HTTP call arguments"; fi
if setup_cmd list | grep -q "tok'en"; then fail "list prints a credential"; fi
SETUP_ENV=()
for name in $CATALOG_NAMES; do
  assert_contains "$(<"$ROOT/catalog/$name/SKILL.md")" "/skills/$name.md" "catalog $name reads the user rule file"
  assert_eq "true" "$(jq -r --arg n "$name" '.skills[] | select(.name==$n) | all(.env[] | select(.secret); .issue.url != null)' "$ROOT/catalog/catalog.json")" "catalog $name secrets carry an issue URL"
done
pass "setup stores credentials off the transcript and checks them"

# langfuse 카탈로그 스킬은 scripts/까지 디렉터리째 설치·추적되고, 위험 등급 차단·별칭·키 파일 읽기는 네트워크 없이 확인한다.
SETUP_T="$TEST_TMP/setup-langfuse"
SETUP_CATALOG="$SETUP_T/catalog"
mkdir -p "$SETUP_T"
cp -R "$ROOT/catalog" "$SETUP_CATALOG"
assert_eq "installed installed" "$(setup_cmd install --tool both langfuse | jq -r '.action' | paste -sd' ' -)" "langfuse installs for both tools"
for tool in claude codex; do
  assert_eq "./SKILL.md ./scripts/lf.py ./scripts/register.py" "$(cd "$SETUP_T/$tool/langfuse" && find . -type f | LC_ALL=C sort | paste -sd' ' -)" "langfuse $tool copy carries its scripts"
  assert_eq "current" "$(setup_status langfuse "$tool")" "langfuse $tool copy is current"
done
printf '# local\n' >>"$SETUP_T/codex/langfuse/scripts/lf.py"
assert_eq "modified" "$(setup_status langfuse codex)" "edited script marks the copy modified"
printf '# v2\n' >>"$SETUP_CATALOG/langfuse/scripts/register.py"
assert_eq "outdated" "$(setup_status langfuse claude)" "changed catalog script marks the untouched copy outdated"
assert_eq "updated" "$(setup_cmd update --tool claude | jq -r 'select(.name=="langfuse") | .action')" "untouched copy refreshed with the new script"
assert_contains "$(<"$SETUP_T/claude/langfuse/scripts/register.py")" "# v2" "refreshed copy carries the new script"
assert_contains "$(<"$SETUP_T/codex/langfuse/scripts/lf.py")" "# local" "edited copy kept on refresh"
if grep -rhE '^(import|from) ' "$ROOT/catalog/langfuse/scripts" | grep -vqE '^import (argparse|base64|json|os|re|shutil|subprocess|sys|time|urllib\.(error|parse|request))$'; then
  fail "langfuse scripts use only the standard library"
fi

LF_T="$SETUP_T/lf"
mkdir -p "$LF_T/home/.cache/langfuse-skill" "$LF_T/data"
lf() {
  env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" \
    LANGFUSE_PUBLIC_KEY=pk-lf-default LANGFUSE_SECRET_KEY=sk-lf-default LANGFUSE_HOST=http://127.0.0.1:9 \
    LANGFUSE_PUBLIC_KEY_CHECKOUT_BOT=pk-lf-bot LANGFUSE_SECRET_KEY_CHECKOUT_BOT=sk-lf-bot \
    "${LF_ENV[@]+"${LF_ENV[@]}"}" python3 -I "$ROOT/catalog/langfuse/scripts/lf.py" "$@"
}
LF_ENV=()
# 도구 목록 캐시를 미리 둔다 — 호출 전에 차단되므로 127.0.0.1:9로는 요청이 나가지 않는다.
LF_TOOLS='[{"name":"listTraces","annotations":{"readOnlyHint":true}},{"name":"createComment","annotations":{}},{"name":"deleteDataset","annotations":{"destructiveHint":true}}]'
printf '%s' "$LF_TOOLS" >"$LF_T/home/.cache/langfuse-skill/http_127_0_0_1_9.tools.json"
printf '%s' "$LF_TOOLS" >"$LF_T/home/.cache/langfuse-skill/https_bot_example_test.tools.json"
LF_ENV=(LANGFUSE_HOST_CHECKOUT_BOT=https://bot.example.test)
assert_eq "read write destructive" "$(lf -p checkout-bot tools | awk '{print $2}' | paste -sd' ' -)" "tool risk comes from MCP annotations"
LF_ENV=()
set +e
LF_ERR="$(lf call createComment '{}' 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "write tool without --yes exits 2"
assert_contains "$LF_ERR" "BLOCKED" "write tool is blocked"
LF_ERR="$(lf call deleteDataset '{}' --yes 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "destructive tool with only --yes exits 2"
assert_contains "$LF_ERR" "--allow-destructive" "destructive block names the flag"
LF_ERR="$(lf rest DELETE /api/public/datasets/x --yes 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "REST DELETE is blocked"
LF_ERR="$(lf rest POST /api/public/comments 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "REST write without --yes is blocked"
LF_ERR="$(lf call listTraces '{}' 2>&1)"; LF_RC=$?
assert_eq "1" "$LF_RC" "unreachable host exits 1"
assert_contains "$LF_ERR" "cannot reach http://127.0.0.1:9" "unreachable host is reported without a traceback"
if grep -q "Traceback" <<<"$LF_ERR"; then fail "unreachable host leaks a Python traceback"; fi
LF_ERR="$(lf -p missing-proj tools 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "unknown alias stops instead of using the default keys"
assert_contains "$LF_ERR" "checkout-bot" "unknown alias lists registered aliases"
set -e
assert_eq "(default) checkout-bot" "$(lf aliases | paste -sd' ' -)" "aliases map env suffixes back to names"
cat >"$LF_T/data/secrets.env" <<'SECRETS'
export LANGFUSE_PUBLIC_KEY_QA='pk-lf-q'\''a'
export LANGFUSE_SECRET_KEY_QA='sk-lf-qa'
SECRETS
mkdir -p "$LF_T/home/.claude"
printf '{"env":{"LANGFUSE_HOST_QA":"https://qa.example.test"}}\n' >"$LF_T/home/.claude/settings.json"
LF_LOOKUP="$(env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lf", sys.argv[1]); lf = importlib.util.module_from_spec(spec); spec.loader.exec_module(lf)
print(lf.suffix("checkout-bot"), lf.lookup("LANGFUSE_PUBLIC_KEY_QA"), lf.credentials("qa")[0], ",".join(lf.aliases()))
' "$ROOT/catalog/langfuse/scripts/lf.py")"
assert_eq "_CHECKOUT_BOT pk-lf-q'a https://qa.example.test qa" "$LF_LOOKUP" "secrets.env and settings.json keys are read (quote escapes undone)"
[[ ! -e "$ROOT/catalog/langfuse/scripts/__pycache__" ]] || fail "tests leave no bytecode in the catalog (it would ship with installed copies)"

register() { env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" python3 -I "$ROOT/catalog/langfuse/scripts/register.py" "$@"; }
for bad in Bad_Alias -lead 'a b' '../x'; do
  set +e
  LF_ERR="$(register "$bad" --stage pk 2>&1)"; LF_RC=$?
  set -e
  assert_eq "1" "$LF_RC" "register rejects alias '$bad'"
  assert_contains "$LF_ERR" "alias:" "register explains the alias rule for '$bad'"
done
[[ ! -e "$LF_T/data/langfuse-staging" ]] || fail "rejected alias leaves no staging directory"
mkdir -p "$LF_T/data/langfuse-staging"
printf 'pk-lf-x' >"$LF_T/data/langfuse-staging/bad-settings.pk"
printf 'sk-lf-x' >"$LF_T/data/langfuse-staging/bad-settings.sk"
printf '[]\n' >"$LF_T/home/.claude/settings.json"
set +e
LF_ERR="$(register bad-settings 2>&1)"; LF_RC=$?
set -e
assert_eq "1" "$LF_RC" "register stops when settings.json is not a JSON object"
assert_contains "$LF_ERR" "not a JSON object" "register names the unusable settings file"
assert_eq "[]" "$(<"$LF_T/home/.claude/settings.json")" "register leaves a non-object settings.json unchanged"
[[ -e "$LF_T/data/langfuse-staging/bad-settings.sk" ]] || fail "register keeps staged keys when it stops before saving"

# 비밀 저장소 명령(_CMD): 사용자 파일의 명령만 실행하고, 같은 별칭의 키 값이 있으면 그것이 먼저다. 실패·형식 오류는 값 없이 멈춘다.
jq -n '{env:{
  LANGFUSE_PUBLIC_KEY_CMD_VAULT:"printf pk-lf-vault", LANGFUSE_SECRET_KEY_CMD_VAULT:"printf \"sk-lf-vault\\n\"",
  LANGFUSE_PUBLIC_KEY_CMD_BROKEN:"printf pk-lf-b", LANGFUSE_SECRET_KEY_CMD_BROKEN:"echo expired-token >&2; exit 3",
  LANGFUSE_PUBLIC_KEY_CMD_NOISY:"printf pk-lf-n", LANGFUSE_SECRET_KEY_CMD_NOISY:"printf leaked-value"}}' >"$LF_T/home/.claude/settings.json"
LF_AUTH="$(env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" \
  LANGFUSE_PUBLIC_KEY_CMD_EVIL="touch $LF_T/planted; printf pk-lf-e" LANGFUSE_SECRET_KEY_CMD_EVIL="printf sk-lf-e" \
  python3 -I -B -c '
import base64, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("lf", sys.argv[1]); lf = importlib.util.module_from_spec(spec); spec.loader.exec_module(lf)
user = lambda a: base64.b64decode(lf.credentials(a)[1].split()[1]).decode()
first = user("vault")
os.environ["LANGFUSE_SECRET_KEY_VAULT"] = "sk-lf-direct"
print(first, user("vault"), ",".join(lf.aliases()))
' "$ROOT/catalog/langfuse/scripts/lf.py")"
assert_eq "pk-lf-vault:sk-lf-vault pk-lf-vault:sk-lf-direct broken,noisy,qa,vault" "$LF_AUTH" "key commands from the user files supply keys, stored values win, env commands are not aliases"
set +e
LF_ENV=(LANGFUSE_PUBLIC_KEY_CMD_EVIL="touch $LF_T/planted; printf pk-lf-e" LANGFUSE_SECRET_KEY_CMD_EVIL="printf sk-lf-e")
LF_ERR="$(lf -p evil tools 2>&1)"; LF_RC=$?
LF_ENV=()
assert_eq "2" "$LF_RC" "a key command in the process env is not run"
[[ ! -e "$LF_T/planted" ]] || fail "lf.py ran a key command from the process env"
LF_ERR="$(lf -p broken tools 2>&1)"; LF_RC=$?
assert_eq "1" "$LF_RC" "failing key command exits 1"
assert_contains "$LF_ERR" "LANGFUSE_SECRET_KEY_CMD_BROKEN failed (exit 3): expired-token" "failing key command names itself and shows its stderr"
LF_ERR="$(lf -p noisy tools 2>&1)"; LF_RC=$?
assert_eq "1" "$LF_RC" "key command printing a non-key exits 1"
assert_contains "$LF_ERR" "must print one line starting with sk-lf-" "non-key output is explained"
if grep -q "leaked-value" <<<"$LF_ERR"; then fail "key command output is printed on a format error"; fi
LF_ERR="$(lf -p cmd tools 2>&1)"; LF_RC=$?
assert_eq "2" "$LF_RC" "alias 'cmd' is reserved in lf.py"
for bad in CMD Vault cmd_x; do
  LF_ERR="$(lf -p "$bad" tools 2>&1)"; LF_RC=$?
  assert_eq "2" "$LF_RC" "lf.py rejects alias '$bad' before mapping it to env names"
done
LF_ERR="$(register cmd-x --stage pk 2>&1)"; LF_RC=$?
assert_eq "1" "$LF_RC" "alias 'cmd-*' is reserved in register.py"
set -e

# register.py --pk-cmd/--sk-cmd: 명령으로 키를 받아 리전을 확인하고 명령과 host만 저장한다. 다른 방식의 기존 값은 지운다.
cat >"$LF_T/server.py" <<'PY'
import http.server, os, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == "/api/public/projects" and self.headers.get("Authorization", "").startswith("Basic ")
        self.send_response(200 if ok else 401)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"p","name":"Stub"}]}' if ok else b'{}')
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.replace(sys.argv[1] + ".tmp", sys.argv[1])
s.serve_forever()
PY
python3 -I -B "$LF_T/server.py" "$LF_T/port" &
LF_SRV=$!
for _ in $(seq 100); do [[ -s "$LF_T/port" ]] && break; sleep 0.1; done
LF_HOST="http://127.0.0.1:$(<"$LF_T/port")"
regh() { env -i PATH="$PATH" HOME="$LF_T/home" HARNESS_METRICS_DIR="$LF_T/data" LANGFUSE_HOST="$LF_HOST" python3 -I -B "$ROOT/catalog/langfuse/scripts/register.py" "$@"; }
jq -n '{model:"opus", env:{KEEP:"1", LANGFUSE_PUBLIC_KEY_VAULT2:"pk-lf-old", LANGFUSE_SECRET_KEY_VAULT2:"sk-lf-old"}}' >"$LF_T/home/.claude/settings.json"
printf "export LANGFUSE_SECRET_KEY_VAULT2='sk-lf-old'\nexport OTHER='1'\n" >"$LF_T/data/secrets.env"
printf 'pk-lf-stale' >"$LF_T/data/langfuse-staging/vault2.pk"
set +e
LF_ERR="$(regh vault2 --pk-cmd 'printf pk-lf-v2' --sk-cmd 'echo denied >&2; exit 255' 2>&1)"; LF_RC=$?
set -e
assert_eq "1" "$LF_RC" "register stops when a key command fails"
assert_contains "$LF_ERR" "nothing saved" "failed key command saves nothing"
assert_eq "pk-lf-old" "$(jq -r '.env.LANGFUSE_PUBLIC_KEY_VAULT2' "$LF_T/home/.claude/settings.json")" "failed key command leaves settings unchanged"
LF_OUT="$(regh vault2 --pk-cmd 'printf pk-lf-v2' --sk-cmd 'printf sk-lf-v2' 2>&1)"
assert_contains "$LF_OUT" "project=['Stub']" "register checks the keys the commands print"
if grep -qE "pk-lf-v2|sk-lf-v2" <<<"$LF_OUT"; then fail "register prints keys from commands"; fi
assert_eq "printf pk-lf-v2|printf sk-lf-v2|$LF_HOST|null|null|1" \
  "$(jq -r '.env | [.LANGFUSE_PUBLIC_KEY_CMD_VAULT2, .LANGFUSE_SECRET_KEY_CMD_VAULT2, .LANGFUSE_HOST_VAULT2, .LANGFUSE_PUBLIC_KEY_VAULT2, .LANGFUSE_SECRET_KEY_VAULT2, .KEEP] | map(tostring) | join("|")' "$LF_T/home/.claude/settings.json")" \
  "register saves commands and host, drops the stored keys of that alias"
assert_eq "export OTHER='1'|export LANGFUSE_PUBLIC_KEY_CMD_VAULT2='printf pk-lf-v2'|export LANGFUSE_SECRET_KEY_CMD_VAULT2='printf sk-lf-v2'|export LANGFUSE_HOST_VAULT2='$LF_HOST'" \
  "$(paste -sd'|' "$LF_T/data/secrets.env")" "secrets.env gets the commands and loses the stored key"
[[ ! -e "$LF_T/data/langfuse-staging/vault2.pk" ]] || fail "saving commands clears staged keys of that alias"
mkdir -p "$LF_T/nohome"
env -i PATH="$PATH" HOME="$LF_T/nohome" HARNESS_METRICS_DIR="$LF_T/nohome/data" LANGFUSE_HOST="$LF_HOST" \
  python3 -I -B "$ROOT/catalog/langfuse/scripts/register.py" solo --pk-cmd 'printf pk-lf-s' --sk-cmd 'printf sk-lf-s' >/dev/null 2>&1
assert_contains "$(<"$LF_T/nohome/data/secrets.env")" "LANGFUSE_SECRET_KEY_CMD_SOLO='printf sk-lf-s'" "without ~/.claude register creates secrets.env"
assert_eq "600" "$(filemode "$LF_T/nohome/data/secrets.env")" "created secrets.env is private"
printf 'pk-lf-new' >"$LF_T/data/langfuse-staging/vault2.pk"
printf 'sk-lf-new' >"$LF_T/data/langfuse-staging/vault2.sk"
regh vault2 >/dev/null 2>&1
assert_eq "pk-lf-new|null|null" "$(jq -r '.env | [.LANGFUSE_PUBLIC_KEY_VAULT2, .LANGFUSE_PUBLIC_KEY_CMD_VAULT2, .LANGFUSE_SECRET_KEY_CMD_VAULT2] | map(tostring) | join("|")' "$LF_T/home/.claude/settings.json")" "registering keys drops the commands of that alias"
kill "$LF_SRV" 2>/dev/null || true
wait "$LF_SRV" 2>/dev/null || true
pass "langfuse catalog skill installs with scripts and enforces risk classes offline"

finish_tests
