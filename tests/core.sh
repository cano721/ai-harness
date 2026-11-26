#!/usr/bin/env bash
# 회귀 테스트 — 프로젝트 ID·workspace 모드·문서 drift·워크플로 계약·플러그인 메타데이터
# 실행: bash tests/run.sh core
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_eq "service" "$(project_id_for_cwd "$PROJECT_REPO")" "origin project id"
assert_eq "service" "$(project_id_for_cwd "$PROJECT_WORKTREE")" "worktree project id"
assert_eq "jobda-agent" "$(project_id_for_cwd "/tmp/workspaces/jobda-agent/NJ-290")" "missing worktree fallback"
assert_eq "jobda-agent" "$(project_id_for_cwd "/gone/workspaces/jobda-agent/feature-NJ-612")" "branch-type worktree name uses the repo dir"
assert_eq "jobda-talent-pool" "$(project_id_for_cwd "/gone/workspaces/jobda-talent-pool/NJ-1866-embedding")" "issue-key worktree name uses the repo dir"
assert_eq "NJ-2299" "$(project_id_for_cwd "/gone/repositories/worktrees/NJ-2299")" "worktree container is not a project name"
assert_eq "jobda-agent" "$(project_id_for_cwd "/gone/workspaces/x/feature-NJ-612" "https://github.com/acme/jobda-agent.git")" "recorded repo URL beats path heuristics"
NFD_NAME="$(printf '\xe1\x84\x8c\xe1\x85\xa1\xe1\x86\xb8\xe1\x84\x83\xe1\x85\xa1')"
NFC_NAME="$(printf '\xec\x9e\xa1\xeb\x8b\xa4')"
assert_eq "$NFC_NAME" "$(project_id_for_cwd "/gone/$NFD_NAME")" "NFD path name normalizes to NFC"
assert_eq "$NFC_NAME" "$(project_id_for_cwd "/gone/$NFC_NAME")" "NFC path name is unchanged"
pass "stable project IDs"

# workspace 모드: 여러 독립 git 저장소가 한 폴더에 있으면 라우팅 층만 만든다.
WS_ROOT="$TEST_TMP/ws"
mkdir -p "$WS_ROOT"
make_repo "$WS_ROOT/api" git@github.com:acme/acme-api.git
make_repo "$WS_ROOT/web"
make_repo "$WS_ROOT/api-clone" git@github.com:acme/acme-api.git
make_repo "$WS_ROOT/group/batch" git@github.com:acme/acme-batch.git
mkdir -p "$WS_ROOT/api/.ai-harness" "$WS_ROOT/api/node_modules/dep"
git -C "$WS_ROOT/api/node_modules/dep" init -q
jq -n '{project_id:"acme-api", level:"standard", test_policy:"tdd", git_policy:"pr-only", edit_guard:true}' > "$WS_ROOT/api/.ai-harness/harness.json"
git -C "$PROJECT_REPO" worktree add -q -b ws-linked "$WS_ROOT/service-wt-1"
mkdir -p "$WS_ROOT/api/.claude/agents" "$TEST_TMP/user-agents"
touch "$WS_ROOT/api/.claude/agents/developer.md" "$WS_ROOT/api/.claude/agents/reviewer.md" "$TEST_TMP/user-agents/developer.md"
WS_SCAN="$(HM_USER_AGENTS_DIR="$TEST_TMP/user-agents" "$ROOT/scripts/workspace-scan.sh" scan --root "$WS_ROOT")"
assert_eq "api:developer" "$(jq -r '.persona_shadows[] | "\(.member):\(.personas | join(","))"' <<<"$WS_SCAN")" "member personas shadowed by same-named user personas are reported"
assert_eq "false" "$(jq -r '.root_is_git' <<<"$WS_SCAN")" "workspace root is not a git repo"
assert_eq "true" "$(jq -r '.candidate' <<<"$WS_SCAN")" "two independent repos make a workspace candidate"
assert_eq "api group/batch web" "$(jq -r '[.members[].path] | sort | join(" ")' <<<"$WS_SCAN")" "members deduplicate clones, skip .git files and node_modules"
assert_eq "api-clone" "$(jq -r '.members[] | select(.path=="api") | .also_paths | join(",")' <<<"$WS_SCAN")" "clone of the same repo is folded into one member"
assert_eq "acme-api true tdd" "$(jq -r '.members[] | select(.path=="api") | "\(.project_id) \(.harness) \(.test_policy)"' <<<"$WS_SCAN")" "member with harness reports its manifest policy"
assert_eq "web false" "$(jq -r '.members[] | select(.path=="web") | "\(.project_id) \(.harness)"' <<<"$WS_SCAN")" "member without harness is marked, not initialized"
assert_eq "api web" "$(jq -r '[.members[].path] | sort | join(" ")' <<<"$("$ROOT/scripts/workspace-scan.sh" scan --root "$WS_ROOT" --depth 1)")" "depth 1 stops before group folders"
assert_eq "false" "$(jq -r '.candidate' <<<"$("$ROOT/scripts/workspace-scan.sh" scan --root "$PROJECT_REPO")")" "a single git repo is never a workspace candidate"
WT_ONLY="$TEST_TMP/wt-only"
mkdir -p "$WT_ONLY"
git -C "$PROJECT_REPO" worktree add -q -b wt-only-a "$WT_ONLY/service-wt-2"
git -C "$PROJECT_REPO" worktree add -q -b wt-only-b "$WT_ONLY/service-wt-3"
assert_eq "false 0" "$(jq -r '"\(.candidate) \(.members|length)"' <<<"$("$ROOT/scripts/workspace-scan.sh" scan --root "$WT_ONLY")")" "worktree-only folder is not proposed as a workspace"
assert_eq "[]" "$(workspace_members_for_cwd "$WS_ROOT")" "no manifest means no members"
"$ROOT/scripts/workspace-scan.sh" write --root "$WS_ROOT" --workspace-id acme --integrations claude --version 0.22.0 >/dev/null
WS_MANIFEST="$WS_ROOT/.ai-harness/workspace.json"
assert_file "$WS_MANIFEST"
assert_eq "workspace acme claude 0.22.0" "$(jq -r '"\(.kind) \(.workspace_id) \(.integrations|join(",")) \(.harness_version)"' "$WS_MANIFEST")" "workspace manifest records identity"
assert_eq "null" "$(jq -r '.managed_files' "$WS_MANIFEST")" "workspace manifest has no managed files"
assert_eq "acme" "$(project_id_for_cwd "$WS_ROOT")" "workspace root resolves to workspace_id instead of the folder heuristic"
assert_eq "acme-api" "$(project_id_for_cwd "$WS_ROOT/api")" "member cwd still resolves to its own project"
assert_eq "$WS_ROOT/api acme-api" "$(workspace_members_for_cwd "$WS_ROOT" | jq -r '.[] | select(.project_id=="acme-api") | "\(.path) \(.project_id)"')" "members resolve to absolute paths"
if "$ROOT/scripts/workspace-scan.sh" write --root "$PROJECT_REPO" --workspace-id nope >/dev/null 2>&1; then
  fail "write must refuse a git repo root"
fi
if "$ROOT/scripts/workspace-scan.sh" write --root "$WT_ONLY" --workspace-id nope >/dev/null 2>&1; then
  fail "write must refuse to create a manifest without two independent repos"
fi
# origin도 manifest도 없는 무관한 두 저장소는 폴더명이 같아도 하나로 접히지 않는다.
SAME_LEAF="$TEST_TMP/same-leaf"
make_repo "$SAME_LEAF/teamA/backend"
make_repo "$SAME_LEAF/teamB/backend"
SAME_LEAF_SCAN="$("$ROOT/scripts/workspace-scan.sh" scan --root "$SAME_LEAF")"
assert_eq "true 2" "$(jq -r '"\(.candidate) \(.members|length)"' <<<"$SAME_LEAF_SCAN")" "folder-name fallback ids never fold unrelated repos"
assert_eq "path path" "$(jq -r '[.members[].id_source] | join(" ")' <<<"$SAME_LEAF_SCAN")" "fallback ids are labeled as path-derived"
assert_eq "manifest origin" "$(jq -r '[(.members[] | select(.path=="api") | .id_source), (.members[] | select(.path=="group/batch") | .id_source)] | join(" ")' <<<"$WS_SCAN")" "manifest and origin ids are labeled by source"
# 멤버 안에 중첩된 .git은 그 멤버의 일부다. 단일 저장소가 workspace로 오판되면 안 된다.
NESTED="$TEST_TMP/nested"
make_repo "$NESTED/outer" git@github.com:acme/outer.git
make_repo "$NESTED/outer/vendor/lib" git@github.com:vendor/lib.git
assert_eq "false 1 outer" "$(jq -r '"\(.candidate) \(.members|length) \(.members[0].path)"' <<<"$("$ROOT/scripts/workspace-scan.sh" scan --root "$NESTED" --depth 3)")" "a .git nested inside a member is not a separate member"
# 멤버 체크아웃이 뒤처져 있어도 원격 기준 브랜치의 하네스를 읽는다. 워킹트리는 건드리지 않는다.
# 기준 브랜치는 추측하지 않는다: 기본은 origin/HEAD, 통합 브랜치는 --base로 지정하고 manifest에 남는다.
STALE_WS="$TEST_TMP/stale-ws"
git init -q --bare "$TEST_TMP/stale-remote.git"
git -C "$TEST_TMP/stale-remote.git" symbolic-ref HEAD refs/heads/main
make_repo "$STALE_WS/front" "$TEST_TMP/stale-remote.git"
git -C "$STALE_WS/front" push -q origin HEAD:refs/heads/main HEAD:refs/heads/develop
STALE_PUSHER="$TEST_TMP/stale-pusher"
git clone -q -b develop "$TEST_TMP/stale-remote.git" "$STALE_PUSHER"
mkdir -p "$STALE_PUSHER/.ai-harness"
jq -n '{project_id:"acme-front", level:"standard", test_policy:"tdd", git_policy:"pr-only", edit_guard:false, harness_version:"0.45.0"}' > "$STALE_PUSHER/.ai-harness/harness.json"
git -C "$STALE_PUSHER" -c user.email=t@e -c user.name=t add .ai-harness
git -C "$STALE_PUSHER" -c user.email=t@e -c user.name=t commit -q -m harness
git -C "$STALE_PUSHER" push -q origin develop
make_repo "$STALE_WS/back"
assert_eq "false" "$(jq -r '.members[] | select(.path=="front") | .harness' <<<"$("$ROOT/scripts/workspace-scan.sh" scan --root "$STALE_WS")")" "without fetch the stale remote-tracking refs have no harness"
assert_eq "false origin/main" "$(jq -r '.members[] | select(.path=="front") | "\(.harness) \(.base_ref)"' <<<"$("$ROOT/scripts/workspace-scan.sh" scan --root "$STALE_WS" --fetch)")" "by default the base is the origin default branch, not a guessed develop"
STALE_SCAN="$("$ROOT/scripts/workspace-scan.sh" scan --root "$STALE_WS" --fetch --base develop)"
assert_eq "acme-front true origin/develop origin/develop 1 0.45.0" "$(jq -r '.members[] | select(.path=="front") | "\(.project_id) \(.harness) \(.manifest_ref) \(.base_ref) \(.behind) \(.harness_version)"' <<<"$STALE_SCAN")" "a stale member checkout reports the harness on the named base branch"
[[ ! -e "$STALE_WS/front/.ai-harness" ]] || fail "scan must not touch the member working tree"
assert_eq "worktree null" "$(jq -r '.members[] | select(.path=="api") | "\(.manifest_ref) \(.base_ref)"' <<<"$WS_SCAN")" "a member without a remote base falls back to its working tree manifest"
"$ROOT/scripts/workspace-scan.sh" write --root "$STALE_WS" --fetch --base develop --workspace-id stale >/dev/null
assert_eq "develop" "$(jq -r '.base_branch' "$STALE_WS/.ai-harness/workspace.json")" "the named base branch is kept in the manifest"
assert_eq "true origin/develop" "$(jq -r '.members[] | select(.path=="front") | "\(.harness) \(.base_ref)"' <<<"$("$ROOT/scripts/workspace-scan.sh" scan --root "$STALE_WS")")" "a rescan reuses the manifest base branch"
if "$ROOT/scripts/workspace-scan.sh" scan --root "$STALE_WS" --base 'bad..ref' >/dev/null 2>&1; then
  fail "an invalid base branch must be rejected"
fi
pass "workspace mode detection"

# 코드↔docs drift: 빌드 파일의 검증 태스크와 문서에 적힌 명령 호출을 대조한다.
DRIFT="$TEST_TMP/drift"
mkdir -p "$DRIFT/.ai-harness/docs" "$DRIFT/api"
cat >"$DRIFT/build.gradle" <<'GRADLE'
tasks.register("integrationTest", Test) {
    useJUnitPlatform { includeTags 'integration' }
}
tasks.named("test") {
    useJUnitPlatform { excludeTags 'regression' }
}
task regressionTest(type: Test) { }
task createProperties { }
GRADLE
cat >"$DRIFT/api/build.gradle" <<'GRADLE'
task createProperties { }
tasks.register("integrationTest", Test) { }
GRADLE
cat >"$DRIFT/.ai-harness/docs/testing.md" <<'DOC'
| 태스크 | 용도 |
|---|---|
| `./gradlew test` | 단위 |
| `./gradlew testCoverage` | 커버리지 |
| `./gradlew regressionTest` | 회귀 (regression 태그) |
DOC
cat >"$DRIFT/AGENTS.md" <<'DOC'
# AGENTS

Quick: `./gradlew build`
DOC
DRIFT_SCAN="$("$ROOT/scripts/docs-drift.sh" scan --root "$DRIFT")"
assert_eq "gradle" "$(jq -r '.stacks | join(",")' <<<"$DRIFT_SCAN")" "drift scan detects the gradle stack"
assert_eq "true" "$(jq -r '.drift' <<<"$DRIFT_SCAN")" "drift is reported when docs and build disagree"
assert_eq "integrationTest" "$(jq -r '[.missing_in_docs[] | select(.kind=="gradle_task") | .value] | join(",")' <<<"$DRIFT_SCAN")" "a verification task absent from every doc is reported"
assert_eq "api/build.gradle, build.gradle" "$(jq -r '.missing_in_docs[] | select(.value=="integrationTest") | .where' <<<"$DRIFT_SCAN")" "the same task in two modules folds into one row with both sources"
assert_eq "" "$(jq -r '[.facts[] | select(.value=="createProperties")] | join(",")' <<<"$DRIFT_SCAN")" "internal tasks nobody documents are not facts"
assert_eq "testCoverage" "$(jq -r '[.stale_in_docs[] | select(.kind=="gradle_task") | .value] | join(",")' <<<"$DRIFT_SCAN")" "a task documented but absent from the build is reported, and gradle builtins are not"
assert_eq "integration,regression" "$(jq -r '[.facts[] | select(.kind=="junit_tag") | .value] | sort | join(",")' <<<"$DRIFT_SCAN")" "include and exclude tag filters are both facts"
assert_eq "integration" "$(jq -r '[.missing_in_docs[] | select(.kind=="junit_tag") | .value] | join(",")' <<<"$DRIFT_SCAN")" "a tag the docs never mention is reported, one they do mention is not"

# 문서가 빌드와 맞으면 아무것도 보고하지 않는다.
CLEAN="$TEST_TMP/drift-clean"
mkdir -p "$CLEAN/.ai-harness/docs"
printf 'tasks.register("integrationTest", Test) { }\n' >"$CLEAN/build.gradle"
cat >"$CLEAN/.ai-harness/docs/testing.md" <<'DOC'
Run `./gradlew integrationTest` before the PR.
DOC
CLEAN_SCAN="$("$ROOT/scripts/docs-drift.sh" scan --root "$CLEAN")"
assert_eq "false 0 0" "$(jq -r '"\(.drift) \(.missing_in_docs|length) \(.stale_in_docs|length)"' <<<"$CLEAN_SCAN")" "a project whose docs match the build reports no drift"

# npm 하위 명령은 스크립트 이름이 아니다.
NPMP="$TEST_TMP/drift-npm"
mkdir -p "$NPMP/.ai-harness/docs"
printf '{"scripts":{"test":"vitest","lint":"eslint ."}}\n' >"$NPMP/package.json"
cat >"$NPMP/.ai-harness/docs/testing.md" <<'DOC'
Install with `npm install`, then `npm test`.
DOC
NPM_SCAN="$("$ROOT/scripts/docs-drift.sh" scan --root "$NPMP")"
assert_eq "lint" "$(jq -r '[.missing_in_docs[].value] | join(",")' <<<"$NPM_SCAN")" "an undocumented npm script is reported"
assert_eq "0" "$(jq -r '.stale_in_docs | length' <<<"$NPM_SCAN")" "npm subcommands like install are not mistaken for scripts"
pass "code-to-docs drift report"

# 타임스탬프는 커밋터 오프셋이 섞여도 맞아야 한다 — 표시는 ISO, 비교는 epoch.
TSREPO="$TEST_TMP/drift-ts"
mkdir -p "$TSREPO/.ai-harness/docs"
git -C "$TSREPO" init -q .
git -C "$TSREPO" config user.email t@example.com
git -C "$TSREPO" config user.name tester
cat >"$TSREPO/.ai-harness/docs/testing.md" <<'DOC'
Run `./gradlew integrationTest`.
DOC
git -C "$TSREPO" add -A
GIT_COMMITTER_DATE="2026-09-01T10:00:00+09:00" git -C "$TSREPO" commit -q -m docs --date="2026-09-01T10:00:00+09:00"
printf 'tasks.register("integrationTest", Test) { }\n' >"$TSREPO/build.gradle"
git -C "$TSREPO" add -A
GIT_COMMITTER_DATE="2026-09-05T01:00:00+00:00" git -C "$TSREPO" commit -q -m build --date="2026-09-05T01:00:00+00:00"
TS_SCAN="$("$ROOT/scripts/docs-drift.sh" scan --root "$TSREPO")"
assert_eq "true" "$(jq -r '.timestamps.docs_older_than_build' <<<"$TS_SCAN")" "a build committed after the docs is flagged even when the UTC offsets differ"
assert_eq "true" "$(jq -r '.timestamps.build_last_commit != null and .timestamps.docs_last_commit != null' <<<"$TS_SCAN")" "commit timestamps are reported"
pass "drift timestamp signal"

# 주석 처리된 선언과 워크스페이스 호출 문법은 오탐을 만들면 안 된다.
NOISE="$TEST_TMP/drift-noise"
mkdir -p "$NOISE/.ai-harness/docs"
cat >"$NOISE/build.gradle" <<'GRADLE'
// tasks.register("ghostTest", Test) { }
/* task legacyCheckTask(type: Test) { } */
jacoco {
    excludes = ['com/example/**/config/**', 'com/example/**/dto/**']
}
tasks.register("realTest", Test) { }
tasks.register("detektMain") { }
GRADLE
cat >"$NOISE/package.json" <<'JSON'
{"scripts":{"test":"vitest","build":"tsc"}}
JSON
cat >"$NOISE/.ai-harness/docs/testing.md" <<'DOC'
- `pnpm --filter api test`
- `yarn workspace web run build`
- `./gradlew realTest`
- `./gradlew detektMain`
DOC
NOISE_SCAN="$("$ROOT/scripts/docs-drift.sh" scan --root "$NOISE")"
assert_eq "" "$(jq -r '[.facts[] | select(.value=="ghostTest" or .value=="legacyCheckTask") | .value] | join(",")' <<<"$NOISE_SCAN")" "a commented-out task declaration is not a fact"
assert_eq "detektMain,realTest" "$(jq -r '[.facts[] | select(.kind=="gradle_task") | .value] | sort | join(",")' <<<"$NOISE_SCAN")" "quality gates like detekt count as verification tasks"
assert_eq "detektMain,realTest" "$(jq -r '[.facts[] | select(.kind=="gradle_task") | .value] | sort | join(",")' <<<"$NOISE_SCAN")" "a glob like com/**/config/** inside a string does not open a block comment and swallow the rest of the file"
assert_eq "false 0 0" "$(jq -r '"\(.drift) \(.missing_in_docs|length) \(.stale_in_docs|length)"' <<<"$NOISE_SCAN")" "workspace invocation syntax resolves to the script name, not the flag"
pass "drift false-positive suppression"

# 실제 저장소(Kotlin DSL 멀티모듈)에서 나온 오탐 4건 — 문서와 빌드가 맞는데 drift로 보고됐다.
KTS="$TEST_TMP/drift-kts"
mkdir -p "$KTS/.ai-harness/docs"
cat >"$KTS/build.gradle.kts" <<'GRADLE'
subprojects {
    tasks.register<Test>("integrationTest") { }
    tasks.register<Test>("syntheticTalentExport") { }
    tasks.register<Test>("seedFixtures") { }
}
tasks.register("jacocoAggregatedReport") { }
val jacocoAggregatedVerification = tasks.register("jacocoAggregatedVerification") { }
tasks.register("printVersion") { }
listOf("api").forEach { tasks.register<JacocoCoverageVerification>("jacocoVerification${it}") { } }
GRADLE
cat >"$KTS/.ai-harness/docs/testing.md" <<'DOC'
- 실측: `./gradlew test integrationTest --rerun-tasks`
- 리포트: `./gradlew jacocoAggregatedReport`
- 게이트: `./gradlew jacocoAggregatedVerification`
- 시드: `SYNTHETIC_ANCHOR=x ./gradlew :talent-pool-api:syntheticTalentExport`
- 버전: `./gradlew printVersion`
- 모듈 게이트: `./gradlew jacocoVerificationApi`
- run ./gradlew build to verify
- 콘솔 출력: `./gradlew --console plain integrationTest`
- 빠른 빌드: `./gradlew build -x seedFixtures`
DOC
KTS_SCAN="$("$ROOT/scripts/docs-drift.sh" scan --root "$KTS")"
assert_eq "" "$(jq -r '[.stale_in_docs[].value] | join(",")' <<<"$KTS_SCAN")" "a documented task the build declares is never stale, whatever its name, and a flag value (--console plain) is not a task"
assert_eq "seedFixtures" "$(jq -r '[.missing_in_docs[].value] | join(",")' <<<"$KTS_SCAN")" "a later task in a multi-task gradlew call counts as documented, an excluded (-x) task does not, and an undocumented Test-typed task is reported"
assert_eq "true" "$(jq -r '[.facts[] | select(.kind=="gradle_task") | .value] | index("jacocoAggregatedVerification") != null' <<<"$KTS_SCAN")" "a Verification task is a verification task"
assert_eq "" "$(jq -r '[.facts[] | select(.value=="printVersion")] | join(",")' <<<"$KTS_SCAN")" "an internal task stays out of the facts even when documented"
assert_eq "" "$(jq -r '[.facts[] | select(.value|startswith("jacocoVerification"))] | join(",")' <<<"$KTS_SCAN")" "an interpolated task name is not a fact, and a documented completion of it is not stale"
pass "drift kotlin dsl and multi-task calls"

# test가 integration 태그를 빼면 `./gradlew test --tests`만 안내한 문서는 통합 테스트를 targeted로 못 돌린다.
TAGGED="$TEST_TMP/drift-tagged"
mkdir -p "$TAGGED/.ai-harness/workflows" "$TAGGED/.ai-harness/docs"
cat >"$TAGGED/build.gradle" <<'GRADLE'
test {
    useJUnitPlatform {
        excludeTags 'regression', 'integration'
    }
}
tasks.register('integrationTest', Test) {
    useJUnitPlatform { includeTags 'integration' }
}
tasks.register('regressionTest', Test) {
    useJUnitPlatform { includeTags 'regression' }
}
jacocoTestReport {
    dependsOn test, tasks.named('integrationTest')
}
GRADLE
cat >"$TAGGED/.ai-harness/workflows/fix-bug.md" <<'DOC'
- 단위/통합 테스트: `./gradlew test --tests {pattern}`
- 전체: `./gradlew build`, 회귀: `./gradlew regressionTest`
DOC
cat >"$TAGGED/.ai-harness/docs/testing.md" <<'DOC'
./gradlew test --tests "{ClassName}"
./gradlew integrationTest --tests "{ClassName}"
DOC
TAGGED_SCAN="$("$ROOT/scripts/docs-drift.sh" scan --root "$TAGGED")"
assert_eq ".ai-harness/workflows/fix-bug.md:1 integration integrationTest" "$(jq -r '[.targeted_command_gaps[] | "\(.doc):\(.line) \(.excluded_tag) \(.use_instead)"] | join(",")' <<<"$TAGGED_SCAN")" "a doc that targets only the tag-excluding task is reported; one that also targets the owner, and an ungated tag, are not"
assert_eq "true" "$(jq -r '.drift' <<<"$TAGGED_SCAN")" "a targeted command gap counts as drift"
mkdir -p "$TAGGED-kts/.ai-harness/workflows"
cat >"$TAGGED-kts/build.gradle.kts" <<'GRADLE'
tasks.test {
    useJUnitPlatform { excludeTags("integration", "e2e") }
}
val integrationTest by tasks.registering(Test::class) {
    useJUnitPlatform { includeTags("integration") }
}
tasks.named<JacocoReport>("jacocoTestReport") {
    executionData(tasks.test.get(), integrationTest.get())
}
GRADLE
cat >"$TAGGED-kts/.ai-harness/workflows/fix-bug.md" <<'DOC'
- `./gradlew test --tests {pattern}`
DOC
assert_eq "integrationTest" "$(jq -r '[.targeted_command_gaps[].use_instead] | join(",")' <<<"$("$ROOT/scripts/docs-drift.sh" scan --root "$TAGGED-kts")")" "kotlin dsl tag filters and executionData gating are understood"
pass "drift targeted command for tag-excluded tests"

# JS 워크스페이스(apps/<pkg>/package.json)는 두 단계 아래에 있다. exec 뒤 바이너리와 별칭 경유 호출도 오탐을 만들면 안 된다.
WS="$TEST_TMP/drift-workspace"
mkdir -p "$WS/apps/web" "$WS/.ai-harness/docs"
printf '{"scripts":{"web":"yarn workspace web","lint":"eslint ."}}\n' >"$WS/package.json"
printf '{"scripts":{"test:ci":"vitest run --coverage","storybook":"storybook dev","eject":"x","lint:error":"eslint --quiet ."}}\n' >"$WS/apps/web/package.json"
cat >"$WS/.ai-harness/docs/testing.md" <<'DOC'
- `yarn web test:ci`, `yarn lint`
- `pnpm --filter web storybook`
- `pnpm --filter web exec tsc --noEmit`
DOC
WS_SCAN="$("$ROOT/scripts/docs-drift.sh" scan --root "$WS")"
assert_eq "" "$(jq -r '[.stale_in_docs[].value] | join(",")' <<<"$WS_SCAN")" "a workspace script is not stale, and a binary after exec is not a script"
assert_eq "lint:error" "$(jq -r '[.missing_in_docs[].value] | join(",")' <<<"$WS_SCAN")" "a script reached through a root alias counts as documented; only verification scripts of a workspace become facts"
pass "drift js workspaces"

# Workflow contract: protected workflow bodies, personas and settings checked against the managed graph
CONTRACT="$TEST_TMP/contract-bad"
mkdir -p "$CONTRACT/.ai-harness/workflows" "$CONTRACT/.ai-harness/agents" "$CONTRACT/.claude/commands" "$CONTRACT/api/src/main/java" "$CONTRACT/api/src/test/java"
cp "$ROOT/templates/implement-feature/references/feature-delivery-graph.json" "$CONTRACT/.ai-harness/workflows/"
cp "$ROOT/templates/fix-bug/references/bug-fix-graph.json" "$CONTRACT/.ai-harness/workflows/"
cp "$ROOT/templates/implement-feature/SKILL.md" "$CONTRACT/.claude/commands/implement-feature.md"
touch "$CONTRACT/api/src/main/java/App.java" "$CONTRACT/api/src/test/java/AppTest.java"
cat >"$CONTRACT/.ai-harness/workflows/implement-feature.md" <<'DOC'
# Implement Feature

- 위반 시 즉시 변경을 폐기하고 적절한 서브 에이전트에게 재위임.
- 계획은 `/plan` 스킬로, 협업은 `/team`으로.
- Claude Code: **Task 도구**로 호출.
- Codex CLI: `codex exec`을 페르소나 본문 + 입력으로 분리 호출.

### Step 7. Ralph 반복

**안전 한도**: 최대 5회. 초과 시 멈추고 사용자에게 보고.

### Step 8. 커밋 + PR 생성

PR을 만든다.
DOC
cat >"$CONTRACT/.ai-harness/workflows/fix-bug.md" <<'DOC'
# Fix Bug

3. developer 페르소나로 수정 + 회귀 테스트 추가
DOC
cat >"$CONTRACT/.ai-harness/agents/developer.md" <<'DOC'
# developer

Write scope: `src/main/**`, `build.gradle`
- 금지: `src/test/**` 편집
DOC
cat >"$CONTRACT/.ai-harness/agents/test-engineer.md" <<'DOC'
# test-engineer

Write scope: `api/src/test/**`
DOC
# shellcheck disable=SC2016  # 정규식·백틱·변수 이름을 문자 그대로 쓴다
printf '{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"${CLAUDE_PROJECT_DIR}/.ai-harness/hooks/direct-edit-guard.sh"}]}]}}\n' >"$CONTRACT/.claude/settings.json"
mkdir -p "$CONTRACT/.ai-harness/hooks"
# shellcheck disable=SC2016  # 옛 가드 본문을 문자 그대로 쓴다
printf '%s\n' '#!/usr/bin/env bash' 'grep -q "\"file_path\":\"[^\"]*code-conventions.md\"" "$transcript" || exit 2' >"$CONTRACT/.ai-harness/hooks/direct-edit-guard.sh"
CONTRACT_SCAN="$("$ROOT/scripts/workflow-contract.sh" scan --root "$CONTRACT")"
contract_checks() { jq -r '[.findings[].check] | unique | join(",")' <<<"$1"; }
assert_eq "codex_exec_unbounded,discard_on_violation,guard_project_dir,guard_read_by_grep,nonexistent_tool,pr_step_forbidden_by_adapter,regression_role,repair_limit,write_scope_unmatched" "$(contract_checks "$CONTRACT_SCAN")" "contract scan reports every class of drift"
assert_eq "true" "$(jq -r '.contract_drift' <<<"$CONTRACT_SCAN")" "contract drift flag"
assert_eq "/plan,/team,Task 도구" "$(jq -r '[.findings[] | select(.check=="nonexistent_tool") | .token] | join(",")' <<<"$CONTRACT_SCAN")" "nonexistent tools are named"
assert_eq ".ai-harness/workflows/implement-feature.md:10 5 10" "$(jq -r '.findings[] | select(.check=="repair_limit") | "\(.file):\(.line) \(.token) \(.expected)"' <<<"$CONTRACT_SCAN")" "repair limit compares the body with the graph"
assert_eq "src/main/**" "$(jq -r '[.findings[] | select(.check=="write_scope_unmatched") | .token] | join(",")' <<<"$CONTRACT_SCAN")" "a write scope that matches no file is reported, a measured module path is not"
assert_eq ".ai-harness/workflows/fix-bug.md" "$(jq -r '.findings[] | select(.check=="regression_role") | .file' <<<"$CONTRACT_SCAN")" "fix-bug giving regression tests to a developer barred from tests"

CONTRACT_OK="$TEST_TMP/contract-ok"
mkdir -p "$CONTRACT_OK/.ai-harness/workflows" "$CONTRACT_OK/.ai-harness/agents" "$CONTRACT_OK/src/main"
cp "$ROOT/templates/implement-feature/references/feature-delivery-graph.json" "$CONTRACT_OK/.ai-harness/workflows/"
touch "$CONTRACT_OK/src/main/App.java"
cat >"$CONTRACT_OK/.ai-harness/workflows/implement-feature.md" <<'DOC'
# Implement Feature

- Claude: Agent 도구의 `subagent_type`으로 위임. 위반은 diff를 보존하고 재위임.
- 역할 범위 위반을 발견하면 변경을 폐기하지 않는다 — diff를 보존하고 재위임한다.
- Do not discard the diff on a scope violation.
- Codex: `codex exec -C <repo> -s workspace-write -o out.md`
- 같은 원인이 최대 10회 수정 뒤에도 남으면 사용자 판단.
DOC
# shellcheck disable=SC2016  # 정규식·백틱·변수 이름을 문자 그대로 쓴다
printf '# developer\n\nWrite scope: `src/main/**`\n' >"$CONTRACT_OK/.ai-harness/agents/developer.md"
mkdir -p "$CONTRACT_OK/.ai-harness/hooks"
cp "$ROOT/skills/harness-init/references/direct-edit-guard.sh" "$CONTRACT_OK/.ai-harness/hooks/direct-edit-guard.sh"
CONTRACT_OK_SCAN="$("$ROOT/scripts/workflow-contract.sh" scan --root "$CONTRACT_OK")"
assert_eq "false 0" "$(jq -r '"\(.contract_drift) \(.findings|length)"' <<<"$CONTRACT_OK_SCAN")" "a body consistent with the graph and tools reports nothing"
assert_contains "$(<"$ROOT/skills/harness-init/SKILL.md")" "scripts/workflow-contract.sh scan --root ." "harness init sync runs the contract scan"

# Read 판정(.name == "Read")을 쓰는 새 가드라도 NFC 정규화 흔적이 없으면 macOS NFD 경로에서 fail-open한다 — guard_no_nfc(#479).
CONTRACT_NFC="$TEST_TMP/contract-nfc"
mkdir -p "$CONTRACT_NFC/.ai-harness/hooks"
sed 's/unicodedata/uni_code_data/g; s/NFC/N_F_C/g' "$ROOT/skills/harness-init/references/direct-edit-guard.sh" >"$CONTRACT_NFC/.ai-harness/hooks/direct-edit-guard.sh"
assert_contains "$(<"$CONTRACT_NFC/.ai-harness/hooks/direct-edit-guard.sh")" '.name == "Read"' "the no-NFC fixture guard keeps the Read judgment"
assert_eq "guard_no_nfc" "$(contract_checks "$("$ROOT/scripts/workflow-contract.sh" scan --root "$CONTRACT_NFC")")" "a Read-judging guard without NFC handling is flagged guard_no_nfc only"

# PR 단계는 manifest git_policy가 허용하면 계약 위반이 아니다. git_policy를 모르는 이전 어댑터는 갱신 대상으로 짚는다.
CONTRACT_PR="$TEST_TMP/contract-pr"
mkdir -p "$CONTRACT_PR/.ai-harness/workflows" "$CONTRACT_PR/.claude/commands"
jq -n '{level:"standard", git_policy:"pr-only"}' >"$CONTRACT_PR/.ai-harness/harness.json"
cp "$ROOT/templates/implement-feature/SKILL.md" "$CONTRACT_PR/.claude/commands/implement-feature.md"
printf '# Implement Feature\n\n### Step 8. 커밋 + PR 생성\n' >"$CONTRACT_PR/.ai-harness/workflows/implement-feature.md"
assert_eq "0" "$("$ROOT/scripts/workflow-contract.sh" scan --root "$CONTRACT_PR" | jq '.findings | length')" "a PR step is allowed when git_policy is pr-only"
printf '%s\n' 'Do not commit, push, create a PR, merge, or change project policy unless separately authorized.' >"$CONTRACT_PR/.claude/commands/implement-feature.md"
assert_contains "$("$ROOT/scripts/workflow-contract.sh" scan --root "$CONTRACT_PR" | jq -r '.findings[] | select(.check=="pr_step_forbidden_by_adapter") | .message')" "--sync" "a legacy adapter that ignores git_policy is flagged for sync"
jq 'del(.limits) | (.transitions[] | select(.to == "user_decision" and .from == "repair") | .when) = "same_root_cause_after_two_attempts_or_product_decision"' \
  "$ROOT/templates/implement-feature/references/feature-delivery-graph.json" >"$CONTRACT_PR/.ai-harness/workflows/feature-delivery-graph.json"
assert_eq "2" "$("$ROOT/scripts/workflow-contract.sh" scan --root "$CONTRACT_PR" | jq -r '.graph_repair_limit')" "a graph without limits falls back to the limit in its edge name"
assert_eq "10" "$("$ROOT/scripts/workflow-contract.sh" scan --root "$CONTRACT_OK" | jq -r '.graph_repair_limit')" "the repair limit comes from the graph limits"
pass "workflow contract scan"

rm -rf "$WS_ROOT/web"
mkdir -p "$WS_ROOT/group/batch/.ai-harness"
jq -n '{project_id:"acme-batch", level:"minimal", test_policy:"none", git_policy:"direct"}' > "$WS_ROOT/group/batch/.ai-harness/harness.json"
WS_RESCAN="$("$ROOT/scripts/workspace-scan.sh" scan --root "$WS_ROOT")"
assert_eq "web" "$(jq -r '.diff.removed | join(",")' <<<"$WS_RESCAN")" "rescan reports a member that disappeared"
assert_eq "group/batch" "$(jq -r '.diff.changed | join(",")' <<<"$WS_RESCAN")" "rescan reports a member whose harness changed"
assert_eq "web" "$(jq -r '.members[] | select(.path=="web") | .path' "$WS_MANIFEST")" "scan alone never rewrites the manifest"
"$ROOT/scripts/workspace-scan.sh" write --root "$WS_ROOT" --team-rules https://git.example/acme/team-rules.git --team-rules-ref main >/dev/null
assert_eq "https://git.example/acme/team-rules.git main" "$(jq -r '"\(.team_rules.source) \(.team_rules.ref)"' "$WS_MANIFEST")" "workspace manifest records the team rules marker"
"$ROOT/scripts/workspace-scan.sh" write --root "$WS_ROOT" >/dev/null
assert_eq "https://git.example/acme/team-rules.git" "$(jq -r '.team_rules.source' "$WS_MANIFEST")" "rewrite keeps the team rules marker"
assert_eq "acme claude $(jq -r '.version' "$ROOT/release.json")" "$(jq -r '"\(.workspace_id) \(.integrations|join(",")) \(.harness_version)"' "$WS_MANIFEST")" "rewrite keeps identity and stamps the current plugin version"
assert_eq "api group/batch" "$(jq -r '[.members[].path] | sort | join(" ")' "$WS_MANIFEST")" "rewrite applies the rescanned members"
HARNESS_INIT_CONTENT="$(<"$ROOT/skills/harness-init/SKILL.md")"
assert_contains "$HARNESS_INIT_CONTENT" "workspace-scan.sh scan" "harness init detects workspaces with the scan script"
assert_contains "$HARNESS_INIT_CONTENT" ".ai-harness/workspace.json" "harness init documents the workspace manifest"
assert_contains "$HARNESS_INIT_CONTENT" "workspace-scan.sh write" "harness init records the manifest with the script"
assert_contains "$HARNESS_INIT_CONTENT" "\"team_rules\": {\"source\"" "harness init documents the team rules marker"
assert_contains "$HARNESS_INIT_CONTENT" "--team-rules <source>" "workspace init records the team rules marker with the script"
assert_contains "$HARNESS_INIT_CONTENT" "**팀 규칙 원본**" "harness init asks about a team rules source"
assert_contains "$HARNESS_INIT_CONTENT" "harness:false" "harness init marks members without a harness"
assert_contains "$HARNESS_INIT_CONTENT" "지금 init할 멤버" "member init is an opt-in follow-up"
assert_contains "$HARNESS_INIT_CONTENT" "rev-list --count HEAD..origin/<base>" "workspace preflight checks member checkout freshness"
# Preflight 번호는 ⑤ 병합된 worktree 정리, ⑥ 멤버 최신 여부 확인이다. 본문의 번호 참조가 실제 단계와 어긋나면 안 된다.
HARNESS_INIT_PREFLIGHT="$(grep -F -- '- **Preflight**: ①' <<<"$HARNESS_INIT_CONTENT")"
assert_contains "$HARNESS_INIT_PREFLIGHT" "⑤ 각 멤버의 \`git worktree list --porcelain\`" "workspace preflight step 5 is the merged-worktree cleanup"
assert_contains "$HARNESS_INIT_PREFLIGHT" "⑥ 멤버 코드로 \"현재 상태\"" "workspace preflight step 6 is the member freshness check"
assert_contains "$HARNESS_INIT_CONTENT" "Preflight ⑥ 멤버 최신 여부 확인이 없음" "workspace sync proposes the freshness step (6) for an existing AGENTS.md"
assert_contains "$HARNESS_INIT_CONTENT" "체크아웃 최신화는 Preflight ⑥ 조건에서만" "the scan note points to the freshness step by its current number"
[[ "$HARNESS_INIT_CONTENT" != *"Preflight ⑤ 조건"* ]] || fail "no reference still calls the freshness step 5"
assert_contains "$HARNESS_INIT_CONTENT" "병합된 worktree" "workspace preflight cleans a safely merged worktree"
assert_contains "$HARNESS_INIT_CONTENT" "git log HEAD --not --remotes" "workspace preflight keeps worktrees with commits absent from every remote"
assert_contains "$HARNESS_INIT_CONTENT" "git worktree remove" "workspace preflight has a non-Orca cleanup path"
assert_contains "$HARNESS_INIT_CONTENT" "orca worktree rm --delete-branch" "workspace preflight removes a merged Orca worktree and its local branch"
assert_contains "$HARNESS_INIT_CONTENT" "중첩 clone" "workspace preflight preserves a nested clone"
assert_contains "$HARNESS_INIT_CONTENT" "/cd <member>" "workspace routing moves implementation into the member with /cd or a member session"
assert_contains "$HARNESS_INIT_CONTENT" "rev-parse --show-toplevel\`)로 멤버를 정한다" "workspace preflight resolves the member by git root, not the first path segment"
assert_contains "$HARNESS_INIT_CONTENT" "같은 이름의 사용자 전역 페르소나" "workspace preflight warns that delegation can hit a same-named user persona"
assert_contains "$HARNESS_INIT_CONTENT" 'check --wait --types worker_done,escalation,question' "workspace handoff waits for the supervised worker's completion signal"
assert_contains "$HARNESS_INIT_CONTENT" '.ai-harness/handoffs/<인계 이름>.done.md' "workspace handoff without supervision waits for a completion file"
assert_contains "$HARNESS_INIT_CONTENT" 'heartbeat 를 진행 신호로 보지 않는다' "workspace handoff does not treat heartbeats as progress"
assert_contains "$HARNESS_INIT_CONTENT" '로 worker 터미널 출력이 바뀌었는지' "workspace handoff checks a stalled worker's terminal while waiting"
assert_contains "$HARNESS_INIT_CONTENT" '이 장치 없이 사용자에게 "끝나면 알려 주겠다"고 하지 않는다' "the coordinator does not promise to report completion it cannot observe"
assert_contains "$HARNESS_INIT_CONTENT" '완료 신호(백그라운드 세션 알림·감독 디스패치·완료 파일)를 기다리지 않음' "workspace sync flags a Preflight that hands off without waiting"
assert_contains "$HARNESS_INIT_CONTENT" '백그라운드 세션 없이 Orca 감독 디스패치를 기본 경로로 둠' "workspace sync flags a Preflight that still defaults to Orca supervision"
assert_contains "$HARNESS_INIT_CONTENT" 'claude --bg -n <인계 이름> "<인계>"' "workspace handoff defaults to a Claude Code background session in the member"
assert_contains "$HARNESS_INIT_CONTENT" 'notify_when_idle: true' "workspace handoff subscribes to the worker's turn-end notice"
assert_contains "$HARNESS_INIT_CONTENT" '알림은 worker 가 **턴을 끝낼 때마다** 한 번 오며 완료를 뜻하지 않는다' "a turn-end notice is not treated as completion"
assert_contains "$HARNESS_INIT_CONTENT" '권한 모드는 조율 세션과 맞춘다' "the background worker matches the coordinator's permission mode so messages are not held"
assert_contains "$HARNESS_INIT_CONTENT" 'claude respawn <id>' "a background session stuck without a transcript restarts only that session"
assert_contains "$HARNESS_INIT_CONTENT" "진행 방식의 **첫 지시**는 멤버 워크플로 파일(\`.ai-harness/workflows/<name>.md\`)을 Read 하고 그 그래프대로 진행하라는 것이다" "workspace handoff opens with reading the member workflow file, not just its name"
assert_contains "$HARNESS_INIT_CONTENT" '러너 시작 명령(`bash .ai-harness/workflows/workflow-driver.sh start' "workspace handoff names the runner start command when the member has one"
assert_contains "$HARNESS_INIT_CONTENT" 'Preflight 의 워크플로 선택을 건너뛴다' "workspace handoff explains why a workflow name alone is not enough"
assert_contains "$HARNESS_INIT_CONTENT" '③ 인계 프롬프트에 멤버 워크플로 파일 Read 지시가 없음' "workspace sync flags a Preflight whose handoff omits the workflow file read"
assert_contains "$HARNESS_INIT_CONTENT" '병합된 worktree 정리 단계가 없음' "workspace sync recognizes an old preflight without merged worktree cleanup"
[[ "$HARNESS_INIT_CONTENT" != *'respawn --all 후'* ]] || fail "handoff does not restart every background session"
assert_contains "$HARNESS_INIT_CONTENT" '메시지 없이 — 구독만 하고 worker 를 방해하지 않는다' "the turn-end subscription sends no message to the worker"
assert_contains "$HARNESS_INIT_CONTENT" '사용자가 Orca 감독을 요청했거나 재시도·의존 관계 관리가 필요하면' "Orca supervision is an opt-in path, not the default"
assert_contains "$HARNESS_INIT_CONTENT" 'Codex 멤버는 새 터미널 탭에서' "Codex members keep the interactive launch"
assert_contains "$HARNESS_INIT_CONTENT" '로 띄우고 아래 완료 파일 방식으로 기다린다' "Codex members wait on a completion file"
assert_contains "$HARNESS_INIT_CONTENT" 'heartbeat 만 든 batch 는 사용자에게 보고하지 않고 ack 한 뒤 다시 건다' "Orca supervision does not report heartbeat-only batches to the user"
HARVEST_CONTENT="$(<"$ROOT/skills/harvest/SKILL.md")"
assert_contains "$HARVEST_CONTENT" "local:<path>" "harvest records a local artifact for non-git workspaces"
assert_contains "$HARVEST_CONTENT" "### 6.5. 독립 검토" "harvest reviews proposals before applying them"
assert_contains "$HARVEST_CONTENT" "\`ai-harness:harvest-reviewer\` 서브에이전트" "harvest hands proposals to the bundled reviewer agent"
assert_contains "$HARVEST_CONTENT" "최대 2회" "harvest review loop is bounded"
assert_contains "$HARVEST_CONTENT" "관례 키(예: \`NJ-00000\`)" "harvest reuses the repo's no-issue key instead of a new issue"
REVIEWER_AGENT="$ROOT/agents/harvest-reviewer.md"
assert_file "$REVIEWER_AGENT"
assert_eq "tools: Read, Grep, Glob" "$(grep '^tools:' "$REVIEWER_AGENT")" "harvest reviewer is read-only"
pass "workspace mode scan, manifest, and routing"

# manifest versions and marketplace policy stay aligned
CLAUDE_PLUGIN_VERSION="$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json")"
[[ "$CLAUDE_PLUGIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]] \
  || fail "Claude plugin version is not semver: $CLAUDE_PLUGIN_VERSION"
assert_eq "$CLAUDE_PLUGIN_VERSION" "$(jq -r '.version' "$ROOT/.codex-plugin/plugin.json")" "Codex plugin version matches Claude"
assert_eq "$CLAUDE_PLUGIN_VERSION" "$(jq -r '.version' "$ROOT/release.json")" "release version matches plugins"
assert_eq "MIT" "$(jq -r '.license' "$ROOT/.claude-plugin/plugin.json")" "Claude plugin license"
assert_eq "MIT" "$(jq -r '.license' "$ROOT/.codex-plugin/plugin.json")" "Codex plugin license"
assert_file "$ROOT/LICENSE"
assert_contains "$(<"$ROOT/LICENSE")" "MIT License" "LICENSE is MIT"
assert_eq "ON_INSTALL" "$(jq -r '.plugins[0].policy.authentication' "$ROOT/.agents/plugins/marketplace.json")" "marketplace auth policy"
pass "plugin metadata"

# macOS /bin/bash 3.2는 단일 명령의 `read ... < <(...)`가 연 fd를 닫지 않는다. 반복 안에서 쓰면 fd 한도(256)에 닿아
# 무인 실행 하위 셸이 CPU 100%로 며칠씩 멈췄다. 한 줄 읽기는 here-string으로 한다.
FD_LEAK="$(grep -rnE '^[^#]*\bread\b[^|;#]*< <\(' "$ROOT/scripts" "$ROOT/templates" "$ROOT/hooks" 2>/dev/null || true)"
[[ -z "$FD_LEAK" ]] || fail "single-command read from a process substitution leaks a file descriptor on bash 3.2: $FD_LEAK"
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" == 3 ]]; then
  assert_eq "ok" "$(cd "$TEST_TMP" && /bin/bash -c 'for i in $(seq 1 300); do IFS=$'"'"'\t'"'"' read -r a b <<<"$(printf "x\ty\n" | head -n 1)"; done; echo ok')" "here-string reads do not exhaust file descriptors on bash 3.2"
fi
pass "bash 3.2 file descriptor safety"

# macOS /bin/bash 3.2는 명령 인자인 "$(... "{a, b}" ...)" 안 큰따옴표 문자열의 중괄호를 펼친다(#410 — 보드 openable
# 단언이 node에 깨진 JS를 넘겨 로컬 스위트가 끊겼다). CI의 bash 5는 못 잡으므로 따옴표 구조로 검사한다.
B32_DIR="$TEST_TMP/bash32"
mkdir -p "$B32_DIR"
cat >"$B32_DIR/bad.sh" <<'EOF'
V=x
echo "$(node -e "${V} f({ a: 1, b: 2 })")"
f "$(printf '%s' "{\"t\":\"$V\",\"r\":\"x\"}")"
echo "$(echo "{a,
b}")"
EOF
cat >"$B32_DIR/good.sh" <<'EOF'
V=x
x="$(echo "{a, b}")"
[[ "$(echo "{a,b}")" == "{a,b}" ]]
echo "$(jq -cn --arg r "$V" '{r:$r, log:1}')"
echo "$(echo "${V:-a,b}")" "{a, b}"
cat <<EOT
"$(echo "{a, b}")"
EOT
# echo "$(echo "{a, b}")"
EOF
B32_OUT="$(python3 -I "$ROOT/tests/bash32-check.py" "$B32_DIR/bad.sh" 2>&1 || true)"
assert_eq "2 3 4" "$(sed -n 's/.*bad\.sh:\([0-9]*\):.*/\1/p' <<<"$B32_OUT" | tr '\n' ' ' | sed 's/ $//')" "bash 3.2 brace check flags braces inside a quoted command substitution argument"
python3 -I "$ROOT/tests/bash32-check.py" "$B32_DIR/good.sh" >/dev/null || fail "bash 3.2 brace check leaves assignments, [[ ]], single quotes, heredocs and comments alone"
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" == 3 ]]; then
  assert_eq "a b" "$(/bin/bash -c 'echo "$(echo "{a, b}")"' | tr -s ' \n' ' ' | sed 's/ $//')" "bash 3.2 really expands braces the check looks for"
fi
B32_FILES=()
while IFS= read -r f; do B32_FILES+=("$f"); done < <(find "$ROOT/scripts" "$ROOT/tests" "$ROOT/hooks" "$ROOT/templates" "$ROOT/skills" "$ROOT/.ai-harness" -name '*.sh' -not -path '*/fixtures/*' 2>/dev/null)
python3 -I "$ROOT/tests/bash32-check.py" "${B32_FILES[@]}" || fail "shell files avoid braces that bash 3.2 expands inside quoted command substitutions"
pass "bash 3.2 brace expansion safety"

# 병렬 실행은 영역 출력·실패 요약을 섞지 않고, -j 인자 오류도 기존 사용법처럼 거부한다.
# 그래프 러너가 넘기는 HM_TEST_JOBS·CPU 기본값과 상관없이 -j 없는 실행은 직렬로 둔다.
export HM_TEST_JOBS=1
RUNNER_FIXTURE="$TEST_TMP/parallel-runner"
mkdir -p "$RUNNER_FIXTURE/tests"
cp "$ROOT/tests/run.sh" "$RUNNER_FIXTURE/tests/run.sh"
cp "$ROOT/tests/slow-areas.txt" "$RUNNER_FIXTURE/tests/slow-areas.txt"
cat >"$RUNNER_FIXTURE/tests/alpha.sh" <<'EOF'
#!/usr/bin/env bash
printf 'alpha: begin\n'
sleep 1
printf 'ok 1 - alpha\n'
EOF
cat >"$RUNNER_FIXTURE/tests/beta.sh" <<'EOF'
#!/usr/bin/env bash
printf 'beta: begin\n'
sleep 1
printf 'ok 1 - beta\n'
EOF
cat >"$RUNNER_FIXTURE/tests/fail.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fail: begin\n'
exit 1
EOF
cat >"$RUNNER_FIXTURE/tests/after.sh" <<'EOF'
#!/usr/bin/env bash
printf 'after: ran\n'
printf 'ok 1 - after\n'
EOF
cat >"$RUNNER_FIXTURE/tests/workflow.sh" <<'EOF'
#!/usr/bin/env bash
printf 'workflow: ran\n'
printf 'ok 1 - workflow\n'
EOF
chmod +x "$RUNNER_FIXTURE/tests/"*.sh
git -C "$RUNNER_FIXTURE" init -q
git -C "$RUNNER_FIXTURE" config user.email test@example.com
git -C "$RUNNER_FIXTURE" config user.name test
git -C "$RUNNER_FIXTURE" add tests
git -C "$RUNNER_FIXTURE" commit -q -m baseline
parallel_out="$TEST_TMP/parallel.out"
parallel_rc=0
bash "$RUNNER_FIXTURE/tests/run.sh" -j 2 alpha beta >"$parallel_out" 2>&1 || parallel_rc=$?
assert_eq "0" "$parallel_rc" "-j runs selected passing areas"
assert_contains "$(<"$parallel_out")" "# alpha" "parallel output keeps an area heading"
assert_contains "$(<"$parallel_out")" "# beta" "parallel output keeps every area heading"
assert_contains "$(<"$parallel_out")" "# all passed: 2 tests in alpha beta" "parallel output preserves the aggregate summary"
alpha_block="$(sed -n '/^# alpha$/,/^# alpha: /p' "$parallel_out")"
assert_contains "$alpha_block" "ok 1 - alpha" "an area's lines stay in its own block"
[[ "$alpha_block" != *"beta"* ]] || fail "parallel output interleaves another area inside a block: $alpha_block"
fast_out="$TEST_TMP/parallel-fast.out"
HM_TEST_BASE=HEAD bash "$RUNNER_FIXTURE/tests/run.sh" -j 2 --fast workflow alpha >"$fast_out" 2>&1
assert_contains "$(<"$fast_out")" "# all passed: 1 tests in alpha" "--fast filters slow areas before parallel scheduling"
[[ "$(<"$fast_out")" != *"# workflow"* ]] || fail "--fast must exclude slow areas during parallel scheduling"
printf '# changed for --changed selection\n' >>"$RUNNER_FIXTURE/tests/beta.sh"
changed_out="$TEST_TMP/parallel-changed.out"
HM_TEST_BASE=HEAD bash "$RUNNER_FIXTURE/tests/run.sh" -j 2 --changed >"$changed_out" 2>&1
assert_contains "$(<"$changed_out")" "# all passed: 1 tests in beta" "--changed selects only changed areas before parallel scheduling"
# 여러 영역이 쓰는 공용 헬퍼(tests/lib-*.sh)는 영역이 아니고, 바뀌면 그 헬퍼를 source하는 영역만 고른다. (#467)
printf '# shared helper\n' >"$RUNNER_FIXTURE/tests/lib-shared.sh"
printf '# source lib-shared.sh\n' >>"$RUNNER_FIXTURE/tests/alpha.sh"
git -C "$RUNNER_FIXTURE" add tests && git -C "$RUNNER_FIXTURE" commit -q -m helper
assert_eq "" "$(bash "$RUNNER_FIXTURE/tests/run.sh" --list | grep -x 'lib-shared' || true)" "a lib-*.sh helper is not listed as an area"
printf '# changed helper\n' >>"$RUNNER_FIXTURE/tests/lib-shared.sh"
helper_out="$TEST_TMP/parallel-helper.out"
HM_TEST_BASE=HEAD bash "$RUNNER_FIXTURE/tests/run.sh" --changed >"$helper_out" 2>&1
assert_contains "$(<"$helper_out")" "# all passed: 1 tests in alpha" "a changed lib-*.sh helper selects the areas that source it"
git -C "$RUNNER_FIXTURE" checkout -q -- tests
# 경로가 공용 헬퍼에만 적혀 있어도 그 헬퍼를 source하는 영역을 고른다(러너 경로는 lib-driver.sh에만 있다).
mkdir -p "$RUNNER_FIXTURE/scripts"
printf 'x\n' >"$RUNNER_FIXTURE/scripts/helper-only.sh"
printf '# runs scripts/helper-only.sh\n' >>"$RUNNER_FIXTURE/tests/lib-shared.sh"
git -C "$RUNNER_FIXTURE" add tests scripts && git -C "$RUNNER_FIXTURE" commit -q -m helper-path
printf 'y\n' >>"$RUNNER_FIXTURE/scripts/helper-only.sh"
helper_path_out="$TEST_TMP/parallel-helper-path.out"
HM_TEST_BASE=HEAD bash "$RUNNER_FIXTURE/tests/run.sh" --changed >"$helper_path_out" 2>&1
assert_contains "$(<"$helper_path_out")" "# all passed: 1 tests in alpha" "a path named only in a lib-*.sh helper selects the areas that source it"
git -C "$RUNNER_FIXTURE" checkout -q -- scripts
parallel_fail_out="$TEST_TMP/parallel-fail.out"
parallel_fail_rc=0
bash "$RUNNER_FIXTURE/tests/run.sh" -j 2 fail after >"$parallel_fail_out" 2>&1 || parallel_fail_rc=$?
assert_eq "1" "$parallel_fail_rc" "parallel runner returns failure when one area fails"
assert_contains "$(<"$parallel_fail_out")" "after: ran" "parallel runner continues areas after a failure"
assert_contains "$(<"$parallel_fail_out")" "# FAILED: fail (1 passed)" "parallel runner summarizes failed areas and passed tests"
# 실패 요약은 시작 순서(느린 영역 먼저)가 아니라 선택 순서를 따른다 — 직렬과 같다.
order_rc=0
bash "$RUNNER_FIXTURE/tests/run.sh" -j 2 fail workflow >"$TEST_TMP/parallel-order.out" 2>&1 || order_rc=$?
assert_eq "1" "$order_rc" "a failing area fails the parallel run"
cat >"$RUNNER_FIXTURE/tests/workflow.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
bash "$RUNNER_FIXTURE/tests/run.sh" -j 2 fail workflow >"$TEST_TMP/parallel-order.out" 2>&1 || true
assert_contains "$(<"$TEST_TMP/parallel-order.out")" "# FAILED: fail workflow" "failed areas are listed in selection order"
# 중단(TERM)하면 돌던 영역을 끝내고 임시 파일을 남기지 않는다.
term_tmp="$TEST_TMP/term-tmpdir"
mkdir -p "$term_tmp"
cat >"$RUNNER_FIXTURE/tests/hang.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" >"$TEST_TMP/hang.pid"
exec sleep 30
EOF
TMPDIR="$term_tmp" bash "$RUNNER_FIXTURE/tests/run.sh" -j 2 hang after >"$TEST_TMP/parallel-term.out" 2>&1 &
term_runner=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -s "$TEST_TMP/hang.pid" ]] && break
  sleep 0.25
done
[[ -s "$TEST_TMP/hang.pid" ]] || fail "hang fixture area never started"
kill -TERM "$term_runner"
term_rc=0
wait "$term_runner" || term_rc=$?
assert_eq "143" "$term_rc" "TERM stops the parallel runner with the signal's exit code"
hang_pid="$(<"$TEST_TMP/hang.pid")"
sleep 0.5
if kill -0 "$hang_pid" 2>/dev/null; then
  kill "$hang_pid" 2>/dev/null || true
  fail "an interrupted parallel run leaves its areas running"
fi
assert_eq "" "$(ls -A "$term_tmp")" "an interrupted parallel run removes its temporary files"
# 터미널 Ctrl-C는 프로세스 그룹 전체에 INT를 보낸다: 폴링 중인 sleep이 먼저 죽어도 정리 경로를 탄다.
for n in g1 g2 g3; do
  cat >"$RUNNER_FIXTURE/tests/$n.sh" <<EOF
#!/usr/bin/env bash
trap 'printf "%s\\n" "$n" >>"$TEST_TMP/group-exits"' EXIT
printf 'started\\n' >>"$TEST_TMP/group-started"
sleep 8
EOF
done
: >"$TEST_TMP/group-started"
perl -e '$SIG{INT}="DEFAULT"; setpgrp(0,0); exec @ARGV' env TMPDIR="$term_tmp" bash "$RUNNER_FIXTURE/tests/run.sh" -j 2 g1 g2 g3 >"$TEST_TMP/parallel-int.out" 2>&1 &
int_runner=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ "$(wc -l <"$TEST_TMP/group-started")" -ge 2 ]] && break
  sleep 0.25
done
sleep 0.5
kill -INT -- "-$int_runner"
int_rc=0
wait "$int_runner" || int_rc=$?
assert_eq "130" "$int_rc" "Ctrl-C to the process group stops the parallel runner with 130"
assert_contains "$(<"$TEST_TMP/parallel-int.out")" "# interrupted:" "Ctrl-C runs the parallel cleanup path"
sleep 0.5
if pgrep -f "$RUNNER_FIXTURE/tests/g[123].sh" >/dev/null; then
  pkill -f "$RUNNER_FIXTURE/tests/g[123].sh" || true
  fail "Ctrl-C leaves parallel areas running"
fi
assert_eq "" "$(ls -A "$term_tmp")" "Ctrl-C removes the parallel run's temporary files"
# 슬롯이 비면 다음 영역을 바로 시작한다: 오래 걸리는 영역이 뒤 영역을 묶어 두지 않는다.
cat >"$RUNNER_FIXTURE/tests/slow.sh" <<EOF
#!/usr/bin/env bash
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$TEST_TMP/third-started" ]] && { printf 'ok 1 - slow\n'; exit 0; }
  sleep 0.5
done
printf 'slow: third area never started while slow was running\n'
exit 1
EOF
cat >"$RUNNER_FIXTURE/tests/quick.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ok 1 - quick\n'
EOF
cat >"$RUNNER_FIXTURE/tests/third.sh" <<EOF
#!/usr/bin/env bash
: >"$TEST_TMP/third-started"
printf 'ok 1 - third\n'
EOF
pool_out="$TEST_TMP/parallel-pool.out"
pool_rc=0
bash "$RUNNER_FIXTURE/tests/run.sh" -j 2 slow quick third >"$pool_out" 2>&1 || pool_rc=$?
assert_eq "0" "$pool_rc" "a free slot starts the next area while a slow area still runs: $(<"$pool_out")"
assert_contains "$(<"$pool_out")" "# all passed: 3 tests" "pool scheduling keeps the aggregate summary"
parallel_invalid_rc=0
bash "$RUNNER_FIXTURE/tests/run.sh" -j 0 >"$TEST_TMP/parallel-invalid.out" 2>&1 || parallel_invalid_rc=$?
assert_eq "2" "$parallel_invalid_rc" "-j rejects zero concurrency"
assert_contains "$(<"$TEST_TMP/parallel-invalid.out")" "-j" "invalid concurrency explains the option"
pass "parallel test runner buffers areas and preserves failures"

# 느린 영역 목록은 tests/slow-areas.txt에 있다. 그 파일만 바뀌면 --changed는 추가·삭제된 줄의 영역만 고르고,
# run.sh 본문이 바뀌면 지금처럼 전체를 고른다. --fast는 이 목록을 빼고, 파일이 없으면 아무것도 빼지 않는다. (#513)
export HM_TEST_JOBS=1
SLOW_FIXTURE="$TEST_TMP/slow-list-runner"
mkdir -p "$SLOW_FIXTURE/tests"
cp "$ROOT/tests/run.sh" "$SLOW_FIXTURE/tests/run.sh"
printf '# slow areas\nworkflow\nbeta\n' >"$SLOW_FIXTURE/tests/slow-areas.txt"
for n in alpha beta gamma workflow; do
  printf '#!/usr/bin/env bash\nprintf "ok 1 - %s\\n"\n' "$n" >"$SLOW_FIXTURE/tests/$n.sh"
done
git -C "$SLOW_FIXTURE" init -q
git -C "$SLOW_FIXTURE" config user.email test@example.com
git -C "$SLOW_FIXTURE" config user.name test
git -C "$SLOW_FIXTURE" add tests
git -C "$SLOW_FIXTURE" commit -q -m baseline
slow_base="$(git -C "$SLOW_FIXTURE" rev-parse HEAD)"
printf 'gamma\n' >>"$SLOW_FIXTURE/tests/slow-areas.txt"
git -C "$SLOW_FIXTURE" commit -q -am "gamma is slow"
slow_out="$(HM_TEST_BASE="$slow_base" bash "$SLOW_FIXTURE/tests/run.sh" --changed 2>&1)"
assert_contains "$slow_out" "# all passed: 1 tests in gamma" "adding one line to slow-areas.txt selects only that area"
[[ "$slow_out" != *"# alpha"* && "$slow_out" != *"# beta"* && "$slow_out" != *"# workflow"* ]] || fail "a slow-areas.txt line selected other areas: $slow_out"
git -C "$SLOW_FIXTURE" reset -q --hard "$slow_base"
printf '# slow areas\nworkflow\nno-such-area\n' >"$SLOW_FIXTURE/tests/slow-areas.txt"
slow_out="$(HM_TEST_BASE=HEAD bash "$SLOW_FIXTURE/tests/run.sh" --changed 2>&1)"
assert_contains "$slow_out" "# all passed: 1 tests in beta" "removing one line selects only that area and an unknown name is ignored"
git -C "$SLOW_FIXTURE" checkout -q -- tests
printf '# a logic change\n' >>"$SLOW_FIXTURE/tests/run.sh"
slow_out="$(HM_TEST_BASE=HEAD bash "$SLOW_FIXTURE/tests/run.sh" --changed 2>&1)"
assert_contains "$slow_out" "# all passed: 4 tests in alpha beta gamma workflow" "a run.sh body change still selects every area"
git -C "$SLOW_FIXTURE" checkout -q -- tests
slow_out="$(bash "$SLOW_FIXTURE/tests/run.sh" --fast 2>&1)"
assert_contains "$slow_out" "# all passed: 2 tests in alpha gamma" "--fast leaves out the areas slow-areas.txt lists"
git -C "$SLOW_FIXTURE" rm -q tests/slow-areas.txt
git -C "$SLOW_FIXTURE" commit -q -m "no slow list"
slow_rc=0
slow_out="$(bash "$SLOW_FIXTURE/tests/run.sh" --fast 2>&1)" || slow_rc=$?
assert_eq "0" "$slow_rc" "--fast runs without slow-areas.txt"
assert_contains "$slow_out" "# all passed: 4 tests in alpha beta gamma workflow" "--fast without slow-areas.txt leaves out nothing"
printf 'gamma\n' >"$SLOW_FIXTURE/tests/slow-areas.txt"
slow_out="$(HM_TEST_BASE=HEAD bash "$SLOW_FIXTURE/tests/run.sh" --changed 2>&1)"
assert_contains "$slow_out" "# all passed: 1 tests in gamma" "an untracked new slow-areas.txt selects every area it lists"
pass "slow-areas.txt drives --fast and a narrow --changed selection"

# -j가 없으면 run.sh는 HM_TEST_JOBS를 동시 실행 수로 쓰고, -j가 이긴다. 두 영역은 서로의 표지를 기다리므로 병렬일 때만 통과한다. (#513)
for n in pa pb; do
  other=pb
  [[ "$n" == pa ]] || other=pa
  cat >"$SLOW_FIXTURE/tests/$n.sh" <<AREA
#!/usr/bin/env bash
: >"$TEST_TMP/jobs-mark-$n"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [[ -f "$TEST_TMP/jobs-mark-$other" ]] && { printf 'ok 1 - $n\n'; exit 0; }
  sleep 0.2
done
printf '$n: $other never started\n'
exit 1
AREA
done
rm -f "$TEST_TMP"/jobs-mark-*
jobs_rc=0
HM_TEST_JOBS=2 bash "$SLOW_FIXTURE/tests/run.sh" pa pb >"$TEST_TMP/jobs-env.out" 2>&1 || jobs_rc=$?
assert_eq "0" "$jobs_rc" "HM_TEST_JOBS=2 runs areas in parallel without -j: $(<"$TEST_TMP/jobs-env.out")"
rm -f "$TEST_TMP"/jobs-mark-*
jobs_rc=0
HM_TEST_JOBS=2 bash "$SLOW_FIXTURE/tests/run.sh" -j 1 pa pb >"$TEST_TMP/jobs-env.out" 2>&1 || jobs_rc=$?
assert_eq "1" "$jobs_rc" "-j 1 wins over HM_TEST_JOBS and runs the areas one at a time"
jobs_rc=0
HM_TEST_JOBS=x bash "$SLOW_FIXTURE/tests/run.sh" pa >"$TEST_TMP/jobs-env.out" 2>&1 || jobs_rc=$?
assert_eq "2" "$jobs_rc" "an invalid HM_TEST_JOBS is rejected like an invalid -j"
assert_contains "$(<"$TEST_TMP/jobs-env.out")" "HM_TEST_JOBS" "the rejection names HM_TEST_JOBS"
pass "run.sh takes HM_TEST_JOBS as its default concurrency"

# 에이전트가 베끼는 문서에 리터럴 `bash tests/run.sh -j N`이 있으면 러너가 넘기는 HM_TEST_JOBS가 무시된다.
# 문서는 `-j` 없는 `bash tests/run.sh`만 적고 병렬 수는 환경변수에 맡긴다. (#544)
JOBS_DOC_FILES="AGENTS.md .ai-harness/docs/testing.md .ai-harness/workflows/release.md .ai-harness/workflows/implement-feature.md .ai-harness/workflows/fix-bug.md templates/fix-bug/SKILL.md templates/implement-feature/SKILL.md .agents/skills/fix-bug/SKILL.md .agents/skills/implement-feature/SKILL.md .claude/commands/fix-bug.md .claude/commands/implement-feature.md skills/harness-init/SKILL.md"
JOBS_DOC_PATHS=""
for jobs_doc in $JOBS_DOC_FILES; do
  [[ -f "$ROOT/$jobs_doc" ]] || fail "doc missing: $jobs_doc"
  JOBS_DOC_PATHS="$JOBS_DOC_PATHS $ROOT/$jobs_doc"
done
# shellcheck disable=SC2086
jobs_hits="$(grep -nE '^bash tests/run\.sh -j' $JOBS_DOC_PATHS || true)"
[[ -z "$jobs_hits" ]] || fail "docs must not start a line with a literal 'bash tests/run.sh -j': $jobs_hits"
# shellcheck disable=SC2086,SC2016
jobs_hits="$(grep -nF 'run.sh -j "${HM_TEST_JOBS' $JOBS_DOC_PATHS || true)"
[[ -z "$jobs_hits" ]] || fail "docs must not pass \$HM_TEST_JOBS to -j by hand: $jobs_hits"
grep -Eq '^bash tests/run\.sh$' "$ROOT/.ai-harness/workflows/release.md" || fail "release.md lists a bare 'bash tests/run.sh' line"
grep -Eq '^bash tests/run\.sh +#' "$ROOT/AGENTS.md" || fail "AGENTS.md Quick Commands has a 'bash tests/run.sh   # ...' line without -j"
pass "docs tell agents to run bash tests/run.sh without a literal -j"

# -j도 HM_TEST_JOBS도 없으면 동시 실행 수는 max(1, min(ncpu/2, 4))다. ncpu는 러너 resolve_check_jobs처럼 getconf부터 구한다. (#556)
fake_cpu="$TEST_TMP/fake-cpu"
mkdir -p "$fake_cpu"
cpu_jobs() { # ncpu args... → jobs_rc
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$1" >"$fake_cpu/getconf"
  chmod +x "$fake_cpu/getconf"
  shift
  rm -f "$TEST_TMP"/jobs-mark-*
  jobs_rc=0
  env -u HM_TEST_JOBS PATH="$fake_cpu:$PATH" bash "$SLOW_FIXTURE/tests/run.sh" "$@" >"$TEST_TMP/jobs-cpu.out" 2>&1 || jobs_rc=$?
}
cpu_jobs 4 pa pb
assert_eq "0" "$jobs_rc" "4 CPUs run two areas at once by default: $(<"$TEST_TMP/jobs-cpu.out")"
cpu_jobs 1 pa pb
assert_eq "1" "$jobs_rc" "1 CPU runs the areas one at a time by default"
cpu_jobs 4 -j 1 pa pb
assert_eq "1" "$jobs_rc" "-j 1 wins over the CPU default"
printf '#!/usr/bin/env bash\nprintf "4\\n"\n' >"$fake_cpu/getconf"
rm -f "$TEST_TMP"/jobs-mark-*
jobs_rc=0
HM_TEST_JOBS=1 PATH="$fake_cpu:$PATH" bash "$SLOW_FIXTURE/tests/run.sh" pa pb >"$TEST_TMP/jobs-cpu.out" 2>&1 || jobs_rc=$?
assert_eq "1" "$jobs_rc" "HM_TEST_JOBS=1 wins over the CPU default"
pass "run.sh defaults its concurrency to the CPU count"

# --profile은 영역 출력을 그대로 흘리고, 끝에 블록(직전 ok부터 그 ok까지) 시간을 느린 순서로 낸다. 없으면 출력이 그대로다. (#556)
PROFILE_FIXTURE="$TEST_TMP/profile-runner"
mkdir -p "$PROFILE_FIXTURE/tests"
cp "$ROOT/tests/run.sh" "$PROFILE_FIXTURE/tests/run.sh"
[[ ! -f "$ROOT/tests/profile-blocks.py" ]] || cp "$ROOT/tests/profile-blocks.py" "$PROFILE_FIXTURE/tests/profile-blocks.py"
cat >"$PROFILE_FIXTURE/tests/pfa.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ok 1 - quick one\n'
sleep 0.3
printf 'ok 2 - sleepy block\n'
printf 'ok 3 - quick two\n'
EOF
cat >"$PROFILE_FIXTURE/tests/pfb.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ok 1 - other area\n'
EOF
profile_rc=0
HM_TEST_JOBS=1 bash "$PROFILE_FIXTURE/tests/run.sh" --profile pfa pfb >"$TEST_TMP/profile.out" 2>&1 || profile_rc=$?
assert_eq "0" "$profile_rc" "--profile passes: $(<"$TEST_TMP/profile.out")"
profile_out="$(<"$TEST_TMP/profile.out")"
assert_contains "$profile_out" "ok 2 - sleepy block" "--profile streams the area output"
assert_contains "$profile_out" "# all passed: 4 tests in pfa pfb" "--profile keeps the summary count"
assert_contains "$profile_out" "# profile: slowest blocks" "--profile prints a slowest-blocks section"
first="$(sed -n '/^# profile: slowest blocks$/{n;p;}' "$TEST_TMP/profile.out")"
[[ "$first" =~ ^\#\ \ \ ([0-9]+\.[0-9])s\ pfa\ ok\ 2\ -\ sleepy\ block$ ]] || fail "the slowest block comes first as '#   <s>s <area> ok <n> - <desc>': $first"
secs="${BASH_REMATCH[1]}"
[[ "${secs%.*}${secs#*.}" -ge 3 ]] || fail "the sleepy block takes at least 0.3s: $first"
HM_TEST_JOBS=1 bash "$PROFILE_FIXTURE/tests/run.sh" -j 2 --profile pfa pfb >"$TEST_TMP/profile-j.out" 2>&1 || fail "-j 2 --profile passes: $(<"$TEST_TMP/profile-j.out")"
first="$(sed -n '/^# profile: slowest blocks$/{n;p;}' "$TEST_TMP/profile-j.out")"
assert_contains "$first" "pfa ok 2 - sleepy block" "-j 2 --profile ranks the same slow block first"
assert_contains "$(<"$TEST_TMP/profile-j.out")" "# all passed: 4 tests in pfa pfb" "-j 2 --profile keeps the summary count"
plain="$(HM_TEST_JOBS=1 bash "$PROFILE_FIXTURE/tests/run.sh" pfa pfb 2>&1)"
[[ "$plain" != *profile* ]] || fail "without --profile the output has no profile section: $plain"
assert_contains "$plain" "# all passed: 4 tests in pfa pfb" "without --profile the summary count is the same"
pass "run.sh --profile reports the slowest blocks"

# --shard i/n은 고른 영역을 느린 영역 순서 다음 나머지 순서로 놓고 i번째 몫(k % n == i-1)만 돌린다 — CI matrix 샤딩용. (#556)
SHARD_FIXTURE="$TEST_TMP/shard-runner"
mkdir -p "$SHARD_FIXTURE/tests"
cp "$ROOT/tests/run.sh" "$SHARD_FIXTURE/tests/run.sh"
printf 's2\ns4\n' >"$SHARD_FIXTURE/tests/slow-areas.txt"
for n in s1 s2 s3 s4 s5; do
  printf '#!/usr/bin/env bash\nprintf "ok 1 - %s\\n"\n' "$n" >"$SHARD_FIXTURE/tests/$n.sh"
done
shard_areas() { sed -n 's/^# all passed: [0-9]* tests in //p' <<<"$1" | tr ' ' '\n' | grep -v '^$' | sort; }
one="$(HM_TEST_JOBS=1 bash "$SHARD_FIXTURE/tests/run.sh" --shard 1/2 2>&1)" || fail "--shard 1/2 passes: $one"
two="$(HM_TEST_JOBS=1 bash "$SHARD_FIXTURE/tests/run.sh" --shard 2/2 2>&1)" || fail "--shard 2/2 passes: $two"
assert_eq "" "$(comm -12 <(shard_areas "$one") <(shard_areas "$two") | tr '\n' ' ')" "shards do not overlap"
assert_eq "s1 s2 s3 s4 s5 " "$( { shard_areas "$one"; shard_areas "$two"; } | sort | tr '\n' ' ')" "shards together cover every area"
assert_contains " $(shard_areas "$one" | tr '\n' ' ')" " s2 " "the first slow area goes to shard 1"
assert_contains " $(shard_areas "$two" | tr '\n' ' ')" " s4 " "the second slow area goes to shard 2"
assert_contains "$(HM_TEST_JOBS=1 bash "$SHARD_FIXTURE/tests/run.sh" --shard 2/2 s2 2>&1)" "돌릴 영역이 없음" "an empty shard runs nothing"
for bad in 0/2 3/2 x 1/0; do
  shard_rc=0
  HM_TEST_JOBS=1 bash "$SHARD_FIXTURE/tests/run.sh" --shard "$bad" >"$TEST_TMP/shard-bad.out" 2>&1 || shard_rc=$?
  assert_eq "2" "$shard_rc" "--shard $bad is rejected"
done
shard_rc=0
HM_TEST_JOBS=1 bash "$SHARD_FIXTURE/tests/run.sh" --shard >"$TEST_TMP/shard-bad.out" 2>&1 || shard_rc=$?
assert_eq "2" "$shard_rc" "--shard without a value is rejected"
pass "run.sh --shard splits the selected areas into disjoint shards"

# CI는 lint job과 test matrix 샤드로 나뉜다: matrix shard 목록은 1..N이고 run.sh --shard가 같은 N을 쓴다. (#556)
CI_YML="$ROOT/.github/workflows/test.yml"
shard_line="$(grep -E -- '--shard \$\{\{ *matrix\.shard *\}\}/[0-9]+' "$CI_YML" || true)"
[[ -n "$shard_line" ]] || fail "test.yml runs run.sh --shard \${{ matrix.shard }}/N"
shard_n="$(sed -E 's/.*\}\}\/([0-9]+).*/\1/' <<<"$shard_line")"
matrix_list="$(sed -nE 's/^[[:space:]]*shard:[[:space:]]*\[(.*)\][[:space:]]*$/\1/p' "$CI_YML" | tr -d ' ')"
assert_eq "$(seq -s, 1 "$shard_n" | sed 's/,$//')" "$matrix_list" "matrix shard list is 1..N"
lint_job="$(sed -n '/^  lint:/,/^  [a-z]/p' "$CI_YML")"
assert_contains "$lint_job" "bash -n" "the lint job checks bash syntax"
assert_contains "$lint_job" "shellcheck -x" "the lint job runs shellcheck"
pass "CI shards the regression tests with a separate lint job"

# 브랜치 보호의 필수 체크는 집계 job `test` 하나다: matrix job은 `test`가 아니고, `test`는 if: always()로
# 워크플로의 다른 모든 job을 needs로 묶어 success가 아닌 결과를 실패로 본다. (#572)
agg_job="$(sed -n '/^  test:/,/^  [a-z]/p' "$CI_YML")"
[[ -n "$agg_job" ]] || fail "test.yml has an aggregate job named test"
[[ "$agg_job" != *matrix* ]] || fail "the matrix job is not the job named test"
assert_contains "$agg_job" "if: always()" "the test job runs even when a needed job fails"
agg_needs="$(sed -nE 's/^    needs:[[:space:]]*\[(.*)\][[:space:]]*$/\1/p' <<<"$agg_job" | tr -d ' ')"
ci_job_ids="$(sed -n '/^jobs:/,$p' "$CI_YML" | sed -nE 's/^  ([a-z][a-z0-9_-]*):.*/\1/p')"
for ci_job in $ci_job_ids; do
  [[ "$ci_job" == "test" ]] && continue
  [[ ",$agg_needs," == *",$ci_job,"* ]] || fail "the test job needs $ci_job (needs=[$agg_needs])"
done
assert_contains "$agg_job" "needs.*.result" "the test job reads the results of its needed jobs"
assert_contains "$agg_job" "success" "the test job treats any non-success result as failure"
agg_name="$(sed -nE 's/^    name:[[:space:]]*(.*)$/\1/p' <<<"$agg_job" | tr -d "\"' ")"
[[ -z "$agg_name" || "$agg_name" == "test" ]] || fail "the test job's check name is test (name=$agg_name)"
pass "CI aggregates lint and shard jobs into one required check named test"

# CHANGELOG·changelog.d·harness.json 해시 스탬프·생성물 사본은 메타 파일이다. --changed가 이 파일들 때문에
# 영역을 넓히지 않아야 평소 검사가 바뀐 코드에 맞게 좁게 돈다. 사본은 원본의 영역으로 옮긴다. (#559)
META_FIXTURE="$TEST_TMP/changed-meta"
mkdir -p "$META_FIXTURE/tests" "$META_FIXTURE/templates/x" "$META_FIXTURE/.claude/commands" "$META_FIXTURE/.ai-harness"
cp "$ROOT/tests/run.sh" "$META_FIXTURE/tests/run.sh"
printf '#!/usr/bin/env bash\n# checks templates/x/SKILL.md and .ai-harness/harness.json\nprintf "ok 1 - alpha\\n"\n' >"$META_FIXTURE/tests/alpha.sh"
printf '#!/usr/bin/env bash\n# checks .claude/commands/x.md\nprintf "ok 1 - beta\\n"\n' >"$META_FIXTURE/tests/beta.sh"
jq -n '{artifacts:[{path:".claude/commands/x.md", source:"templates/x/SKILL.md", mode:"copy"}]}' >"$META_FIXTURE/templates/managed-files.json"
printf 'skill\n' >"$META_FIXTURE/templates/x/SKILL.md"
printf 'skill\n' >"$META_FIXTURE/.claude/commands/x.md"
jq -n '{harness_version:"1.0.0", test_policy:"tdd", managed_files:{x:{content_sha256:"aaa", template_version:"1.0.0"}}}' >"$META_FIXTURE/.ai-harness/harness.json"
printf '# Changelog\n' >"$META_FIXTURE/CHANGELOG.md"
git -C "$META_FIXTURE" init -q
git -C "$META_FIXTURE" config user.email test@example.com
git -C "$META_FIXTURE" config user.name test
git -C "$META_FIXTURE" add -A
git -C "$META_FIXTURE" commit -q -m baseline
meta_explain() { HM_TEST_BASE=HEAD bash "$META_FIXTURE/tests/run.sh" --changed --explain 2>"$TEST_TMP/meta.err"; }
# changelog.d/ 아래 새 조각은 영역을 고르지 않고, explain 없이 돌리면 기존처럼 돌릴 영역이 없다.
mkdir -p "$META_FIXTURE/changelog.d"
printf -- '- note\n' >"$META_FIXTURE/changelog.d/559.md"
meta_out="$(meta_explain)"
assert_contains "$meta_out" "changelog.d/559.md -> 제외 (메타: changelog)" "a changelog.d fragment is reported as meta"
assert_eq "# 선택: (없음)" "$(tail -n 1 <<<"$meta_out")" "a changelog.d fragment selects no area"
meta_rc=0
meta_out="$(HM_TEST_BASE=HEAD bash "$META_FIXTURE/tests/run.sh" --changed 2>&1)" || meta_rc=$?
assert_eq "0" "$meta_rc" "meta-only changes still exit 0"
assert_contains "$meta_out" "run.sh: 돌릴 영역이 없음" "meta-only changes leave nothing to run"
[[ "$meta_out" != *"영역이 없음 —"* ]] || fail "meta-only changes must not warn about unmapped files: $meta_out"
rm -rf "$META_FIXTURE/changelog.d"
# harness.json은 해시·template_version·harness_version만 바뀌면 메타다. 다른 키나 새 항목은 지금처럼 경로로 고른다.
jq '.harness_version = "1.1.0" | .managed_files.x.content_sha256 = "bbb" | .managed_files.x.template_version = "1.1.0"' \
  "$META_FIXTURE/.ai-harness/harness.json" >"$TEST_TMP/harness.json" && mv "$TEST_TMP/harness.json" "$META_FIXTURE/.ai-harness/harness.json"
meta_out="$(meta_explain)"
assert_contains "$meta_out" ".ai-harness/harness.json -> 제외 (메타: harness.json 해시만)" "a hash-only harness.json change is meta"
assert_eq "# 선택: (없음)" "$(tail -n 1 <<<"$meta_out")" "a hash-only harness.json change selects no area"
jq '.test_policy = "none"' "$META_FIXTURE/.ai-harness/harness.json" >"$TEST_TMP/harness.json" && mv "$TEST_TMP/harness.json" "$META_FIXTURE/.ai-harness/harness.json"
assert_eq "# 선택: alpha" "$(meta_explain | tail -n 1)" "another harness.json key change selects by path"
git -C "$META_FIXTURE" checkout -q -- .ai-harness
jq '.managed_files.y = {content_sha256:"ccc", template_version:"1.0.0"}' "$META_FIXTURE/.ai-harness/harness.json" >"$TEST_TMP/harness.json" && mv "$TEST_TMP/harness.json" "$META_FIXTURE/.ai-harness/harness.json"
assert_eq "# 선택: alpha" "$(meta_explain | tail -n 1)" "a new managed_files entry selects by path"
git -C "$META_FIXTURE" checkout -q -- .ai-harness
# 생성물 사본만 바뀌면 사본을 언급하는 영역(beta)이 아니라 원본을 검사하는 영역(alpha)을 고른다.
printf 'drift\n' >>"$META_FIXTURE/.claude/commands/x.md"
meta_out="$(meta_explain)"
assert_contains "$meta_out" ".claude/commands/x.md -> alpha (생성물 사본, 원본 templates/x/SKILL.md)" "a generated copy is mapped to its source"
assert_eq "# 선택: alpha" "$(tail -n 1 <<<"$meta_out")" "a generated copy selects only the source's areas"
git -C "$META_FIXTURE" checkout -q -- .claude
# --explain은 실행하지 않는 선택 확인이고, --changed 없이 쓰면 사용법 오류다.
printf 'changed\n' >>"$META_FIXTURE/templates/x/SKILL.md"
meta_out="$(meta_explain)"
assert_contains "$meta_out" "templates/x/SKILL.md -> alpha" "explain shows the areas a path selects"
[[ "$meta_out" != *"# all passed"* && "$meta_out" != *"ok 1 - alpha"* ]] || fail "--changed --explain must not run areas: $meta_out"
assert_eq "# 선택: alpha beta" "$(HM_TEST_BASE=HEAD bash "$META_FIXTURE/tests/run.sh" --changed --explain -j 2 beta 2>/dev/null | tail -n 1)" "explain merges named areas into the final selection in area order and ignores -j"
git -C "$META_FIXTURE" checkout -q -- templates
meta_rc=0
HM_TEST_BASE=HEAD bash "$META_FIXTURE/tests/run.sh" --explain >"$TEST_TMP/meta.out" 2>"$TEST_TMP/meta.err" || meta_rc=$?
assert_eq "2" "$meta_rc" "--explain without --changed is a usage error"
assert_contains "$(<"$TEST_TMP/meta.err")" "run.sh: --explain은 --changed와 함께 씁니다" "--explain without --changed explains itself"
pass "--changed skips meta files and --explain shows why each file selects areas"

# 실제 영역 파일 기준 회귀: 디자인 Skill 문서와 CHANGELOG만 바꾼 변경은 그 Skill을 다루는 design·init 영역만 고른다. (#559)
# #570에서 그 블록이 design-references·init-native-design 영역으로 옮겨졌다.
# core.sh 자신이 그 경로를 통째로 언급하면 core도 걸리므로 경로를 나눠 적는다.
REAL_FIXTURE="$TEST_TMP/changed-meta-real"
dsb_dir="skills/design-system-builder"
mkdir -p "$REAL_FIXTURE/tests" "$REAL_FIXTURE/$dsb_dir"
cp "$ROOT"/tests/*.sh "$REAL_FIXTURE/tests/"
printf 'skill\n' >"$REAL_FIXTURE/$dsb_dir/SKILL.md"
printf '# Changelog\n' >"$REAL_FIXTURE/CHANGELOG.md"
git -C "$REAL_FIXTURE" init -q
git -C "$REAL_FIXTURE" config user.email test@example.com
git -C "$REAL_FIXTURE" config user.name test
git -C "$REAL_FIXTURE" add -A
git -C "$REAL_FIXTURE" commit -q -m baseline
printf 'more\n' >>"$REAL_FIXTURE/$dsb_dir/SKILL.md"
printf -- '- entry\n' >>"$REAL_FIXTURE/CHANGELOG.md"
real_rc=0
real_out="$(HM_TEST_BASE=HEAD bash "$REAL_FIXTURE/tests/run.sh" --changed --explain 2>"$TEST_TMP/real.err")" || real_rc=$?
assert_eq "0" "$real_rc" "--changed --explain exits 0"
assert_contains "$real_out" "CHANGELOG.md -> 제외 (메타: changelog)" "CHANGELOG.md is reported as meta"
real_line="$(grep "^$dsb_dir/SKILL.md -> " <<<"$real_out" || true)"
assert_contains "$real_line" "design" "the design Skill selects design"
assert_contains "$real_line" "init" "the design Skill selects init"
assert_eq "# 선택: design-references init-native-design" "$(tail -n 1 <<<"$real_out")" "a design Skill + CHANGELOG change selects only the design and init areas that cover it"
[[ "$(<"$TEST_TMP/real.err")" != *"영역이 없음"* ]] || fail "meta files must not warn about unmapped files: $(<"$TEST_TMP/real.err")"
pass "a design Skill + CHANGELOG change stays within design and init"

finish_tests
