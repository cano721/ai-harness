#!/usr/bin/env bash
# 회귀 테스트 — setup 카탈로그·설치 힌트·버전 알림·팀 규칙
# 실행: bash tests/run.sh setup
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-setup.sh"

# 기본 스킬 카탈로그: 플러그인 스킬이 아니라 선택 설치 원본이며, Codex도 읽을 수 있는 frontmatter만 쓴다.
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
assert_contains "$HINT_OUT" "기능 소개는 보드(ai-harness board 스킬)의 하네스 안내 화면에서 볼 수 있습니다" "Codex first hint points to the board guide"
assert_eq "" "$(printf '{}' | setup_cmd notify)" "first hint shown once"
setup_cmd 'done' >/dev/null
jq '.version += 1 | .skills += [{name:"pagerduty", since:.version, summary:"x", env:[]}]' "$SETUP_CATALOG/catalog.json" >"$SETUP_T/c.json"
mv "$SETUP_T/c.json" "$SETUP_CATALOG/catalog.json"
NEW_HINT="$(printf '{"transcript_path":"/x/a.jsonl"}' | setup_cmd notify | jq -r '.systemMessage')"
assert_contains "$NEW_HINT" "새 기본 스킬이 추가됐습니다: pagerduty" "new catalog skills announced"
assert_contains "$NEW_HINT" "/ai-harness:setup" "Claude hint uses the slash command"
assert_eq "" "$(printf '{}' | setup_cmd notify)" "new-skill hint shown once"
SETUP_T="$TEST_TMP/setup-hint-claude"
mkdir -p "$SETUP_T"
CLAUDE_HINT="$(printf '{"transcript_path":"/x/a.jsonl"}' | setup_cmd notify | jq -r '.systemMessage')"
assert_contains "$CLAUDE_HINT" "기능 소개는 보드(/ai-harness:board)의 하네스 안내 화면에서 볼 수 있습니다" "Claude first hint points to the board guide"
SETUP_T="$TEST_TMP/setup-off"
mkdir -p "$SETUP_T"
SETUP_ENV=(HM_SETUP_HINT=0)
assert_eq "" "$(printf '{}' | setup_cmd notify)" "HM_SETUP_HINT=0 silences the hint"
SETUP_ENV=()
assert_contains "$(<"$ROOT/scripts/session-start.sh")" 'setup.sh" notify' "SessionStart carries the setup notice"
pass "setup hint on first session and on new catalog skills"

# 버전 바뀜 안내(#439): 확인한 버전(보드와 같은 board/version-seen.json)보다 플러그인이 높으면 그 버전에 대해 한 번 알린다.
# 상태가 없으면(첫 설치·이 기능 이전 사용자) 알리지 않고 현재 버전으로 기록한다 — 첫 설치 안내와 겹치지 않는다.
SETUP_T="$TEST_TMP/setup-version"
mkdir -p "$SETUP_T"
SETUP_ENV=(HM_SETUP_HINT=0 HM_PLUGIN_ROOT="$ROOT/tests/fixtures/changelog")
assert_eq "" "$(printf '{}' | setup_cmd notify)" "no version notice without a seen version"
assert_eq "0.10.0" "$(jq -r '.seen' "$SETUP_T/data/board/version-seen.json")" "the first session records the current version"
printf '{"seen":"0.9.0"}' >"$SETUP_T/data/board/version-seen.json"
VER_HINT="$(printf '{"transcript_path":"/x/a.jsonl"}' | setup_cmd notify | jq -r '.systemMessage')"
assert_eq "ai-harness가 v0.9.0에서 v0.10.0으로 올랐습니다. 업데이트 후 해야 할 일 1건과 바뀐 점은 보드(/ai-harness:board)의 하네스 안내에서 봅니다." "$VER_HINT" "version notice names the range, the to-dos and the board guide"
assert_eq "" "$(printf '{}' | setup_cmd notify)" "version notice shown once per version"
assert_eq "0.9.0" "$(jq -r '.seen' "$SETUP_T/data/board/version-seen.json")" "the notice does not mark the changes as seen"
SETUP_T="$TEST_TMP/setup-version-codex"
mkdir -p "$SETUP_T/data/board"
printf '{"seen":"0.9.1"}' >"$SETUP_T/data/board/version-seen.json"
VER_HINT="$(printf '{"transcript_path":"/x/rollout-2026-10-30T00-00-00-abc.jsonl"}' | setup_cmd notify | jq -r '.systemMessage')"
assert_contains "$VER_HINT" "v0.9.1에서 v0.10.0으로 올랐습니다" "Codex notice names the range"
assert_contains "$VER_HINT" "보드(ai-harness board 스킬)의 하네스 안내에서 봅니다" "Codex notice names the board skill"
printf '{"seen":"0.10.0"}' >"$SETUP_T/data/board/version-seen.json"
assert_eq "" "$(printf '{}' | setup_cmd notify)" "no notice once the changes are seen"
SETUP_ENV=()
pass "session start tells once that the plugin version went up and where to read the changes (#439)"

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

finish_tests
