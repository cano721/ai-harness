#!/usr/bin/env bash
# 회귀 테스트 — 업데이트 확인·릴리스 메타데이터
# 실행: bash tests/run.sh release
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
make_project_repo
START_COMMAND="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/hooks/hooks.json")"
START_INPUT="$(jq -cn --arg cwd "$PROJECT_REPO" '{cwd:$cwd}')"

# 버전 확인은 캐시된 release metadata로만 판단하고 SessionStart는 설치를 실행하지 않는다.
UPDATE_DATA="$TEST_TMP/update-data"
mkdir -p "$UPDATE_DATA"
UPDATE_NOW="$(date +%s)"
jq -cn --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson checked_at_epoch "$UPDATE_NOW" \
  '{v:1,installed_version:"0.10.0",latest_version:"9.9.9",release_url:"https://example.test/releases/v9.9.9",notes_url:"https://example.test/releases/v9.9.9",last_result:"success",last_error:"",checked_at:$checked_at,checked_at_epoch:$checked_at_epoch}' \
  >"$UPDATE_DATA/update-check.json"
UPDATE_STATUS="$(HARNESS_METRICS_DIR="$UPDATE_DATA" HM_UPDATE_CHECK_ENABLED=0 "$ROOT/scripts/check-update.sh" status)"
assert_eq "true" "$(printf '%s' "$UPDATE_STATUS" | jq -r '.update_available')" "cached newer version detected"
assert_eq "9.9.9" "$(printf '%s' "$UPDATE_STATUS" | jq -r '.latest_version')" "cached latest version"
UPDATE_NOTICE="$(HARNESS_METRICS_DIR="$UPDATE_DATA" "$ROOT/scripts/check-update.sh" notify)"
assert_contains "$UPDATE_NOTICE" "/harness-update" "update notification directs explicit workflow"
SESSION_UPDATE_NOTICE="$(
  printf '%s' "$START_INPUT" \
    | CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$UPDATE_DATA" \
      /bin/sh -c "$START_COMMAND"
)"
assert_contains "$SESSION_UPDATE_NOTICE" "ai-harness 9.9.9 업데이트" "SessionStart forwards update notification"
UPDATE_STALE_TMP="$UPDATE_DATA/.update-check-stale.json"
jq -c '.checked_at_epoch = 0' "$UPDATE_DATA/update-check.json" >"$UPDATE_STALE_TMP"
mv "$UPDATE_STALE_TMP" "$UPDATE_DATA/update-check.json"
FAILED_UPDATE_STATUS="$(HARNESS_METRICS_DIR="$UPDATE_DATA" HM_UPDATE_RELEASE_URL="not-a-url" "$ROOT/scripts/check-update.sh" status)"
assert_eq "failure" "$(printf '%s' "$FAILED_UPDATE_STATUS" | jq -r '.last_result')" "invalid update source fails safely"
assert_eq "9.9.9" "$(printf '%s' "$FAILED_UPDATE_STATUS" | jq -r '.latest_version')" "failed refresh keeps prior release cache"
pass "cached update notification and explicit update flow"

# 조회 실패는 성공 TTL을 소비하지 않고, 별도의 짧은 백오프로만 재시도한다.
BACKOFF_DATA="$TEST_TMP/update-backoff"
mkdir -p "$BACKOFF_DATA"
BACKOFF_NOW="$(date +%s)"
BACKOFF_SUCCESS_EPOCH=$((BACKOFF_NOW - 90000))
jq -cn --argjson checked_at_epoch "$BACKOFF_SUCCESS_EPOCH" \
  '{v:1,installed_version:"0.10.0",latest_version:"9.9.9",release_url:"https://example.test/releases/tag/v9.9.9",notes_url:"https://example.test/releases/tag/v9.9.9",last_result:"success",last_error:"",checked_at:"2026-01-01T00:00:00Z",checked_at_epoch:$checked_at_epoch}' \
  >"$BACKOFF_DATA/update-check.json"
BACKOFF_FIRST="$(HARNESS_METRICS_DIR="$BACKOFF_DATA" HM_UPDATE_RELEASE_URL="not-a-url" "$ROOT/scripts/check-update.sh" status)"
assert_eq "failure" "$(printf '%s' "$BACKOFF_FIRST" | jq -r '.last_result')" "stale cache still refreshes after TTL"
assert_eq "1" "$(printf '%s' "$BACKOFF_FIRST" | jq -r '.failure_count')" "first failure counted"
assert_eq "$BACKOFF_SUCCESS_EPOCH" "$(jq -r '.checked_at_epoch' "$BACKOFF_DATA/update-check.json")" "failed refresh does not consume the success TTL"
assert_eq "2026-01-01T00:00:00Z" "$(jq -r '.checked_at' "$BACKOFF_DATA/update-check.json")" "failed refresh keeps the last success timestamp"
BACKOFF_RETRY_AT="$(jq -r '.next_retry_epoch' "$BACKOFF_DATA/update-check.json")"
[[ "$BACKOFF_RETRY_AT" -gt "$BACKOFF_NOW" ]] || fail "failure schedules a retry in the future (next_retry_epoch=$BACKOFF_RETRY_AT)"
BACKOFF_SECOND="$(HARNESS_METRICS_DIR="$BACKOFF_DATA" HM_UPDATE_RELEASE_URL="not-a-url" "$ROOT/scripts/check-update.sh" status)"
assert_eq "1" "$(printf '%s' "$BACKOFF_SECOND" | jq -r '.failure_count')" "retry is suppressed while the backoff window is open"
assert_eq "$BACKOFF_RETRY_AT" "$(jq -r '.next_retry_epoch' "$BACKOFF_DATA/update-check.json")" "suppressed retry leaves the backoff window unchanged"
BACKOFF_OPEN_TMP="$BACKOFF_DATA/.update-check-open.json"
jq -c '.next_retry_epoch = 0' "$BACKOFF_DATA/update-check.json" >"$BACKOFF_OPEN_TMP"
mv "$BACKOFF_OPEN_TMP" "$BACKOFF_DATA/update-check.json"
BACKOFF_THIRD="$(HARNESS_METRICS_DIR="$BACKOFF_DATA" HM_UPDATE_RELEASE_URL="not-a-url" HM_UPDATE_RETRY_MINUTES=10 HM_UPDATE_RETRY_MAX_MINUTES=60 "$ROOT/scripts/check-update.sh" status)"
assert_eq "2" "$(printf '%s' "$BACKOFF_THIRD" | jq -r '.failure_count')" "consecutive failures accumulate once the window closes"
BACKOFF_SECONDS=$(( $(jq -r '.next_retry_epoch' "$BACKOFF_DATA/update-check.json") - $(jq -r '.last_attempt_epoch' "$BACKOFF_DATA/update-check.json") ))
assert_eq "1200" "$BACKOFF_SECONDS" "backoff doubles on the second consecutive failure"
pass "failed release checks back off without spending the success TTL"

# 사용자가 직접 부르는 status는 성공 TTL 안이어도 다시 조회한다. 정기 refresh는 TTL을 지킨다.
FRESH_DATA="$TEST_TMP/update-fresh-status"
mkdir -p "$FRESH_DATA"
jq -cn --argjson checked_at_epoch "$(date +%s)" \
  '{v:1,installed_version:"0.10.0",latest_version:"9.9.9",release_url:"",notes_url:"",last_result:"success",last_error:"",checked_at:"2026-01-01T00:00:00Z",checked_at_epoch:$checked_at_epoch}' \
  >"$FRESH_DATA/update-check.json"
HARNESS_METRICS_DIR="$FRESH_DATA" HM_UPDATE_RELEASE_URL="not-a-url" "$ROOT/scripts/check-update.sh" refresh >/dev/null 2>&1
assert_eq "success" "$(jq -r '.last_result' "$FRESH_DATA/update-check.json")" "refresh honors the success TTL"
FRESH_STATUS="$(HARNESS_METRICS_DIR="$FRESH_DATA" HM_UPDATE_RELEASE_URL="not-a-url" "$ROOT/scripts/check-update.sh" status)"
assert_eq "failure" "$(printf '%s' "$FRESH_STATUS" | jq -r '.last_result')" "status looks up even inside the success TTL"
assert_eq "9.9.9" "$(printf '%s' "$FRESH_STATUS" | jq -r '.latest_version')" "status lookup failure keeps the cached release"
pass "explicit status bypasses the success TTL"

# 손상된 캐시가 조회 자체를 죽이면 알림이 조용히 사라진다.
CORRUPT_DATA="$TEST_TMP/update-corrupt"
mkdir -p "$CORRUPT_DATA"
jq -cn '{v:1,installed_version:"0.10.0",latest_version:"9.9.9",release_url:"",notes_url:"",last_result:"success",last_error:"",checked_at:"2026-01-01T00:00:00Z",checked_at_epoch:1,failure_count:"oops",next_retry_epoch:"nope"}' \
  >"$CORRUPT_DATA/update-check.json"
CORRUPT_STATUS="$(HARNESS_METRICS_DIR="$CORRUPT_DATA" HM_UPDATE_CHECK_ENABLED=0 "$ROOT/scripts/check-update.sh" status)"
assert_eq "9.9.9" "$(printf '%s' "$CORRUPT_STATUS" | jq -r '.latest_version')" "corrupt counters do not break the status report"
assert_eq "0" "$(printf '%s' "$CORRUPT_STATUS" | jq -r '.failure_count')" "corrupt failure_count falls back to zero"
assert_eq "0" "$(printf '%s' "$CORRUPT_STATUS" | jq -r '.next_retry_epoch')" "corrupt next_retry_epoch falls back to zero"
pass "malformed update cache degrades without failing the check"

# 0-패딩 값은 산술 확장에서 8진수로 읽혀 write_state를 mv 이전에 중단시킨다.
OCTAL_DATA="$TEST_TMP/update-octal"
mkdir -p "$OCTAL_DATA"
OCTAL_STATUS="$(HARNESS_METRICS_DIR="$OCTAL_DATA" HM_UPDATE_RELEASE_URL="not-a-url" \
  HM_UPDATE_CHECK_HOURS=08 HM_UPDATE_RETRY_MINUTES=09 "$ROOT/scripts/check-update.sh" status 2>&1)"
assert_eq "0" "$(printf '%s' "$OCTAL_STATUS" | grep -c 'value too great for base' || true)" \
  "zero-padded settings never reach arithmetic expansion"
assert_eq "1" "$(printf '%s' "$OCTAL_STATUS" | tail -n 1 | jq -r '.failure_count')" "zero-padded settings fall back to defaults"
assert_file "$OCTAL_DATA/update-check.json"
OCTAL_BACKOFF=$(( $(jq -r '.next_retry_epoch' "$OCTAL_DATA/update-check.json") - $(jq -r '.last_attempt_epoch' "$OCTAL_DATA/update-check.json") ))
assert_eq "900" "$OCTAL_BACKOFF" "rejected retry interval falls back to the 15 minute default"
OCTAL_COUNTER="$TEST_TMP/update-octal-counter"
mkdir -p "$OCTAL_COUNTER"
jq -cn --argjson checked_at_epoch "$((BACKOFF_NOW - 90000))" \
  '{v:1,latest_version:"9.9.9",last_result:"failure",last_error:"",checked_at:"2026-01-01T00:00:00Z",checked_at_epoch:$checked_at_epoch,failure_count:"09",next_retry_epoch:0}' \
  >"$OCTAL_COUNTER/update-check.json"
HARNESS_METRICS_DIR="$OCTAL_COUNTER" HM_UPDATE_RELEASE_URL="not-a-url" "$ROOT/scripts/check-update.sh" status >/dev/null 2>&1
assert_eq "1" "$(jq -r '.failure_count' "$OCTAL_COUNTER/update-check.json")" "zero-padded stored counter is rewritten instead of wedging the cache"
pass "zero-padded numbers fall back instead of wedging the state file"

# SessionStart는 3초 예산을 공유한다. 알림은 캐시만 읽고, 조회는 백그라운드 backfill-due가 맡는다.
FETCH_DATA="$TEST_TMP/update-fetch-split"
mkdir -p "$FETCH_DATA"
HARNESS_METRICS_DIR="$FETCH_DATA" HM_UPDATE_RELEASE_URL="not-a-url" "$ROOT/scripts/check-update.sh" notify >/dev/null 2>&1
assert_not_file "$FETCH_DATA/update-check.json"
HARNESS_METRICS_DIR="$FETCH_DATA" HM_UPDATE_RELEASE_URL="not-a-url" "$ROOT/scripts/check-update.sh" refresh >/dev/null 2>&1
assert_file "$FETCH_DATA/update-check.json"
assert_eq "failure" "$(jq -r '.last_result' "$FETCH_DATA/update-check.json")" "refresh performs the lookup notify skips"
FETCH_NOTICE="$(HARNESS_METRICS_DIR="$FETCH_DATA" "$ROOT/scripts/check-update.sh" notify)"
assert_eq "" "$FETCH_NOTICE" "cache-only notify stays silent without a cached newer version"
pass "release lookup moves off the SessionStart budget"

# 업데이트를 적용해도 현재 세션은 재시작 전까지 옛 플러그인을 로드한 채 돈다.
SKEW_STATE="$TEST_TMP/installed_plugins.json"
LOADED_VERSION="$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json")"
jq -cn --arg version "$LOADED_VERSION" \
  '{"ai-harness@ai-harness":[{scope:"user",version:$version}]}' >"$SKEW_STATE"
assert_eq "" "$(HM_PLUGIN_STATE_FILE="$SKEW_STATE" "$ROOT/scripts/check-update.sh" skew)" "matching versions report no skew"
jq -cn '{"ai-harness@ai-harness":[{scope:"user",version:"0.1.0"},{scope:"user",version:"99.0.0"}]}' >"$SKEW_STATE"
SKEW_NOTICE="$(HM_PLUGIN_STATE_FILE="$SKEW_STATE" "$ROOT/scripts/check-update.sh" skew | jq -r '.systemMessage')"
assert_contains "$SKEW_NOTICE" "99.0.0" "skew notice names the installed version"
assert_contains "$SKEW_NOTICE" "$LOADED_VERSION" "skew notice names the loaded version"
assert_eq "" "$(HM_PLUGIN_STATE_FILE="$TEST_TMP/no-such-plugins.json" "$ROOT/scripts/check-update.sh" skew)" "missing plugin state degrades quietly"
pass "version skew between installed and loaded plugin is surfaced"

# 알림과 변경점 요약은 릴리스 메타데이터가 정확할 때만 동작한다.
RELEASE_VERSION="$(jq -r '.version' "$ROOT/release.json")"
assert_eq "$RELEASE_VERSION" "$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json")" "claude plugin version matches release.json"
assert_eq "$RELEASE_VERSION" "$(jq -r '.version' "$ROOT/.codex-plugin/plugin.json")" "codex plugin version matches release.json"
for RELEASE_FIELD in release_url notes_url; do
  RELEASE_LINK="$(jq -r --arg field "$RELEASE_FIELD" '.[$field] // ""' "$ROOT/release.json")"
  assert_contains "$RELEASE_LINK" "/releases/tag/v$RELEASE_VERSION" "$RELEASE_FIELD points at the released version"
done
pass "release metadata identifies the shipped version"

# 릴리스 준비: 버전 파일을 건드리는 건 이 스크립트 하나뿐이라 기능 PR끼리 버전에서 충돌하지 않는다.
"$ROOT/scripts/release-prep.sh" --check --root "$ROOT" >/dev/null || fail "release metadata is inconsistent on this branch"
REL="$TEST_TMP/release"
mkdir -p "$REL/.claude-plugin" "$REL/.codex-plugin"
printf '{"name":"ai-harness","version":"1.2.3"}\n' >"$REL/.claude-plugin/plugin.json"
printf '{"name":"ai-harness","version":"1.2.3"}\n' >"$REL/.codex-plugin/plugin.json"
cat >"$REL/release.json" <<'JSON'
{
  "version": "1.2.3",
  "channel": "stable",
  "release_url": "https://github.com/cano721/ai-harness/releases/tag/v1.2.3",
  "notes_url": "https://github.com/cano721/ai-harness/releases/tag/v1.2.3"
}
JSON
cat >"$REL/CHANGELOG.md" <<'DOC'
# Changelog

## Unreleased

<!-- 안내 주석은 릴리스 노트에 남기지 않는다. -->

### 버그 수정

- 무언가 고쳤다.

## v1.2.3 (2026-01-01)

- 이전 릴리스.
DOC
if "$ROOT/scripts/release-prep.sh" --check --root "$REL" >/dev/null 2>&1; then
  :
else
  fail "a branch carrying an Unreleased section should still pass the consistency check"
fi
"$ROOT/scripts/release-prep.sh" 1.3.0 --date 2026-02-02 --root "$REL" >/dev/null
assert_eq "1.3.0 1.3.0 1.3.0" "$(jq -r '.version' "$REL/.claude-plugin/plugin.json" "$REL/.codex-plugin/plugin.json" "$REL/release.json" | paste -sd " " -)" "one command moves every manifest to the new version"
assert_eq "https://github.com/cano721/ai-harness/releases/tag/v1.3.0" "$(jq -r '.notes_url' "$REL/release.json")" "the release urls follow the new tag"
assert_eq "1" "$(grep -c '^## v1.3.0 (2026-02-02)$' "$REL/CHANGELOG.md")" "the Unreleased section becomes the version section"
# 확정 뒤에도 빈 Unreleased 머리가 남아야 다음 PR들이 각자 머리를 만들다 맨 위에서 충돌하지 않는다 (#527).
assert_eq "1" "$(grep -c '^## Unreleased' "$REL/CHANGELOG.md")" "a fresh empty Unreleased heading is left above the new version"
REL_HEAD_LINE="$(grep -n '^## Unreleased' "$REL/CHANGELOG.md" | head -1 | cut -d: -f1)"
REL_VER_LINE="$(grep -n '^## v1.3.0 (2026-02-02)$' "$REL/CHANGELOG.md" | head -1 | cut -d: -f1)"
[[ -n "$REL_HEAD_LINE" && -n "$REL_VER_LINE" && "$REL_HEAD_LINE" -lt "$REL_VER_LINE" ]] || fail "the Unreleased heading should sit above the new version heading (unreleased=$REL_HEAD_LINE version=$REL_VER_LINE)"
REL_BETWEEN="$(awk '/^## Unreleased/ { inside = 1; next } /^## v1\.3\.0 / { inside = 0 } inside' "$REL/CHANGELOG.md" | tr -d '[:space:]')"
assert_eq "" "$REL_BETWEEN" "the new Unreleased heading has no body"
assert_eq "0" "$(grep -c '<!--' "$REL/CHANGELOG.md")" "the guidance comment does not reach the release notes"
assert_eq "1" "$(grep -c '무언가 고쳤다' "$REL/CHANGELOG.md")" "the entries written during development are kept"
REL_CHECK_ERR="$TEST_TMP/release-check.err"
"$ROOT/scripts/release-prep.sh" --check --root "$REL" >/dev/null 2>"$REL_CHECK_ERR" || fail "the prepared release should be consistent"
if grep -q 'Unreleased' "$REL_CHECK_ERR"; then
  fail "--check should not warn when the Unreleased heading is present"
fi
REL_AGAIN_ERR="$TEST_TMP/release-again.err"
if "$ROOT/scripts/release-prep.sh" 1.4.0 --root "$REL" >/dev/null 2>"$REL_AGAIN_ERR"; then
  fail "releasing again with an empty Unreleased section should be refused"
fi
assert_contains "$(cat "$REL_AGAIN_ERR")" "the Unreleased section is empty" "the leftover empty Unreleased heading is refused as empty"
if "$ROOT/scripts/release-prep.sh" 1.3.0 --root "$REL" >/dev/null 2>&1; then
  fail "reusing a version already in the changelog should be refused"
fi
pass "release preparation moves version metadata in one step"

# 머리가 사라진 브랜치(main 등)에서도 --check는 통과하되, 다음 PR 전에 머리를 만들라고 경고한다 (#527).
REL_NOHEAD="$TEST_TMP/release-nohead"
mkdir -p "$REL_NOHEAD/.claude-plugin" "$REL_NOHEAD/.codex-plugin"
printf '{"name":"ai-harness","version":"1.2.3"}\n' >"$REL_NOHEAD/.claude-plugin/plugin.json"
printf '{"name":"ai-harness","version":"1.2.3"}\n' >"$REL_NOHEAD/.codex-plugin/plugin.json"
jq '.version = "1.2.3" | .release_url = "https://github.com/cano721/ai-harness/releases/tag/v1.2.3" | .notes_url = .release_url' "$REL/release.json" >"$REL_NOHEAD/release.json"
cat >"$REL_NOHEAD/CHANGELOG.md" <<'DOC'
# Changelog

## v1.2.3 (2026-01-01)

- 이전 릴리스.
DOC
REL_NOHEAD_ERR="$TEST_TMP/release-nohead.err"
"$ROOT/scripts/release-prep.sh" --check --root "$REL_NOHEAD" >/dev/null 2>"$REL_NOHEAD_ERR" || fail "--check should keep passing when only the Unreleased heading is missing"
assert_contains "$(cat "$REL_NOHEAD_ERR")" "Unreleased" "--check warns when the changelog has no Unreleased heading"
pass "release consistency check warns about a missing Unreleased heading"

# 릴리스 노트의 단일 출처. 절이 없으면 발행할 노트도, 오프라인 설명도 없다.
CHANGELOG_SECTION="$("$ROOT/scripts/changelog-section.sh" "$RELEASE_VERSION" 2>/dev/null || true)"
[[ -n "${CHANGELOG_SECTION//[[:space:]]/}" ]] || fail "CHANGELOG.md has no section for v$RELEASE_VERSION"
assert_eq "1" "$(grep -c "^## v$RELEASE_VERSION " "$ROOT/CHANGELOG.md" || true)" "the shipped version appears once in the changelog"
if "$ROOT/scripts/changelog-section.sh" "99.9.9" >/dev/null 2>&1; then
  fail "changelog extraction should fail for a version it does not carry"
fi
pass "changelog carries the shipped version"

# CHANGELOG 조각(#558): 기능 PR은 changelog.d/<이슈>-<요약>.md에만 쓰고, 릴리스가 소제목별로 합친 뒤 조각을 지운다.
# 동시에 열린 PR들이 CHANGELOG.md 맨 위 한 줄에서 충돌하지 않게 하면서, 결과 형식은 보드·changelog-section.sh가 읽던 그대로다.
make_fragment_fixture() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/.claude-plugin" "$dir/.codex-plugin" "$dir/changelog.d"
  printf '{"name":"ai-harness","version":"1.2.3"}\n' >"$dir/.claude-plugin/plugin.json"
  printf '{"name":"ai-harness","version":"1.2.3"}\n' >"$dir/.codex-plugin/plugin.json"
  jq '.version = "1.2.3" | .release_url = "https://github.com/cano721/ai-harness/releases/tag/v1.2.3" | .notes_url = .release_url' "$REL/release.json" >"$dir/release.json"
  cat >"$dir/CHANGELOG.md" <<'DOC'
# Changelog

머리말.

## Unreleased

<!-- 안내 주석 -->

## v1.2.3 (2026-01-01)
### 새 기능

- 이전 릴리스.
DOC
}
fragment_sums() {
  local dir="$1"
  cksum "$dir/CHANGELOG.md" "$dir/.claude-plugin/plugin.json" "$dir/.codex-plugin/plugin.json" "$dir/release.json" "$dir"/changelog.d/*.md 2>/dev/null
}

# A·B·C: Unreleased 본문과 조각 두 개를 소제목별로 한 번씩, 고정 순서·이슈 번호 숫자순으로 합치고 조각을 지운다.
FRAG="$TEST_TMP/release-fragments"
make_fragment_fixture "$FRAG"
cat >"$FRAG/CHANGELOG.md" <<'DOC'
# Changelog

머리말.

## Unreleased

### 버그 수정

- 옛 PR이 Unreleased에 쓴 수정. (#90)

## v1.2.3 (2026-01-01)
### 새 기능

- 이전 릴리스.
DOC
cat >"$FRAG/changelog.d/120-b.md" <<'DOC'
<!-- 조각 안내 주석은 버린다 -->
### 새 기능

- 백이십 기능. (#120)

### 버그 수정

- 백이십 수정. (#120)
DOC
cat >"$FRAG/changelog.d/99-a.md" <<'DOC'
### 업데이트 후 해야 할 일

- **구십구 할 일** — 설정을 다시 엽니다. (#99)
  요약: 구십구 요약 줄.

### 새 기능
- 구십구 기능. (#99)
DOC
"$ROOT/scripts/release-prep.sh" 1.3.0 --date 2026-02-02 --root "$FRAG" >/dev/null 2>&1 || fail "fragments and the Unreleased body should merge into a release"
assert_eq "1" "$(grep -c '^## v1.3.0 (2026-02-02)$' "$FRAG/CHANGELOG.md")" "the merged release heading appears once"
FRAG_SECTION="$(awk '/^## v1\.3\.0 /{inside=1; next} inside && /^## /{exit} inside' "$FRAG/CHANGELOG.md")"
assert_eq "### 업데이트 후 해야 할 일|### 새 기능|### 버그 수정" "$(printf '%s\n' "$FRAG_SECTION" | grep '^### ' | paste -sd '|' -)" "each heading appears once in the fixed order"
FRAG_FEATURES="$(printf '%s\n' "$FRAG_SECTION" | grep -E '^- (구십구|백이십) 기능' | paste -sd '|' -)"
assert_eq "- 구십구 기능. (#99)|- 백이십 기능. (#120)" "$FRAG_FEATURES" "fragments merge by numeric issue order"
FRAG_FIXES="$(printf '%s\n' "$FRAG_SECTION" | grep -E '수정\. \(#' | paste -sd '|' -)"
assert_eq "- 옛 PR이 Unreleased에 쓴 수정. (#90)|- 백이십 수정. (#120)" "$FRAG_FIXES" "Unreleased entries come before fragment entries"
assert_contains "$FRAG_SECTION" "$(printf -- '- **구십구 할 일** — 설정을 다시 엽니다. (#99)\n  요약: 구십구 요약 줄.')" "indented summary lines move with their entry"
assert_eq "## v1.3.0 (2026-02-02)|### 업데이트 후 해야 할 일|" "$(grep -A2 '^## v1.3.0 ' "$FRAG/CHANGELOG.md" | paste -sd '|' -)" "the first heading follows the version heading with one blank line before entries"
assert_eq "0" "$(grep -c '<!--' "$FRAG/CHANGELOG.md")" "fragment comments do not reach the release notes"
assert_eq "1" "$(grep -c '^## Unreleased$' "$FRAG/CHANGELOG.md")" "an empty Unreleased heading stays"
FRAG_BETWEEN="$(awk '/^## Unreleased/ { inside = 1; next } /^## v1\.3\.0 / { inside = 0 } inside' "$FRAG/CHANGELOG.md" | tr -d '[:space:]')"
assert_eq "" "$FRAG_BETWEEN" "the Unreleased heading left above the release has no body"
assert_eq "|## v1.2.3 (2026-01-01)" "$(grep -B1 '^## v1.2.3 ' "$FRAG/CHANGELOG.md" | paste -sd '|' -)" "one blank line separates the merged section from the previous release"
if compgen -G "$FRAG/changelog.d/*.md" >/dev/null; then
  fail "released fragments should be deleted"
fi
FRAG_NOTES="$("$ROOT/scripts/changelog-section.sh" 1.3.0 "$FRAG/CHANGELOG.md")"
assert_eq "### 업데이트 후 해야 할 일" "$(printf '%s\n' "$FRAG_NOTES" | head -1)" "changelog-section.sh extracts the merged section"
FRAG_PARSED="$(cd "$ROOT/scripts/board" && python3 -I -c '
import json, sys
sys.path.insert(0, ".")
import changes
v = [x for x in changes.parse(open(sys.argv[1], encoding="utf-8").read()) if x["version"] == "1.3.0"][0]
buckets = {}
for b, it in v["items"]:
    buckets[b] = buckets.get(b, 0) + 1
todo = [it for b, it in v["items"] if b == "todo"][0]
print(json.dumps({"total": len(v["items"]), "buckets": buckets, "summary": bool(todo.get("summary"))}, sort_keys=True))
' "$FRAG/CHANGELOG.md")"
assert_eq '{"buckets": {"feature": 2, "fix": 2, "todo": 1}, "summary": true, "total": 5}' "$FRAG_PARSED" "the board reads the merged section like any release"
pass "release preparation merges changelog fragments by heading and deletes them"

# D: --check가 조각 형식을 검사한다. 잘못된 조각은 파일 경로와 함께 exit 1.
FRAG_CHECK="$TEST_TMP/release-fragment-check"
for FRAG_CASE in unknown-heading empty-heading entry-first bad-name; do
  make_fragment_fixture "$FRAG_CHECK"
  FRAG_FILE="7-case.md"
  case "$FRAG_CASE" in
    unknown-heading) printf '### 기타\n\n- 무언가. (#7)\n' >"$FRAG_CHECK/changelog.d/$FRAG_FILE" ;;
    empty-heading) printf '### 새 기능\n\n### 버그 수정\n\n- 고침. (#7)\n' >"$FRAG_CHECK/changelog.d/$FRAG_FILE" ;;
    entry-first) printf -- '- 소제목 없는 항목. (#7)\n\n### 새 기능\n\n- 기능. (#7)\n' >"$FRAG_CHECK/changelog.d/$FRAG_FILE" ;;
    bad-name) FRAG_FILE="notes.md"; printf '### 새 기능\n\n- 기능. (#7)\n' >"$FRAG_CHECK/changelog.d/$FRAG_FILE" ;;
  esac
  FRAG_CHECK_ERR="$TEST_TMP/release-fragment-check.err"
  if "$ROOT/scripts/release-prep.sh" --check --root "$FRAG_CHECK" >/dev/null 2>"$FRAG_CHECK_ERR"; then
    fail "--check should reject the $FRAG_CASE fragment"
  fi
  assert_contains "$(cat "$FRAG_CHECK_ERR")" "changelog.d/$FRAG_FILE" "--check names the $FRAG_CASE fragment"
done
make_fragment_fixture "$FRAG_CHECK"
cat >"$FRAG_CHECK/changelog.d/7-case.md" <<'DOC'
### 새 기능

- 기능. (#7)
  요약: 요약.

  이어지는 문단.

  ```bash
  echo hi
  ```
DOC
FRAG_CHECK_OUT="$("$ROOT/scripts/release-prep.sh" --check --root "$FRAG_CHECK" 2>&1)" || fail "--check should accept a well-formed fragment: $FRAG_CHECK_OUT"
assert_contains "$FRAG_CHECK_OUT" "release metadata consistent at v1.2.3" "--check keeps its consistency message with fragments"
pass "release consistency check validates changelog fragments"

# E: 형식 오류 조각이 있으면 릴리스는 아무 파일도 바꾸지 않고 거부한다. 조각도 본문도 없으면 기존 문구로 거부한다.
FRAG_BAD="$TEST_TMP/release-fragment-bad"
make_fragment_fixture "$FRAG_BAD"
printf '### 새 기능\n\n- 좋은 기능. (#8)\n' >"$FRAG_BAD/changelog.d/8-good.md"
printf '### 기타\n\n- 나쁜 소제목. (#9)\n' >"$FRAG_BAD/changelog.d/9-bad.md"
FRAG_BAD_BEFORE="$(fragment_sums "$FRAG_BAD")"
FRAG_BAD_ERR="$TEST_TMP/release-fragment-bad.err"
FRAG_BAD_STATUS=0
"$ROOT/scripts/release-prep.sh" 1.3.0 --date 2026-02-02 --root "$FRAG_BAD" >/dev/null 2>"$FRAG_BAD_ERR" || FRAG_BAD_STATUS=$?
assert_eq "2" "$FRAG_BAD_STATUS" "a malformed fragment refuses the release"
assert_contains "$(cat "$FRAG_BAD_ERR")" "changelog.d/9-bad.md" "the refusal names the malformed fragment"
assert_eq "$FRAG_BAD_BEFORE" "$(fragment_sums "$FRAG_BAD")" "a refused release changes no file"
make_fragment_fixture "$FRAG_BAD"
FRAG_EMPTY_STATUS=0
"$ROOT/scripts/release-prep.sh" 1.3.0 --root "$FRAG_BAD" >/dev/null 2>"$FRAG_BAD_ERR" || FRAG_EMPTY_STATUS=$?
assert_eq "2" "$FRAG_EMPTY_STATUS" "nothing to release is refused"
assert_contains "$(cat "$FRAG_BAD_ERR")" "the Unreleased section is empty" "the empty refusal keeps its wording"
pass "release preparation refuses malformed or missing changelog entries"

# F: Unreleased 본문이 비어 있어도 조각이 있으면 릴리스한다.
FRAG_ONLY="$TEST_TMP/release-fragment-only"
make_fragment_fixture "$FRAG_ONLY"
printf '### 동작 변경\n\n- 조각만 있는 변경. (#10)\n' >"$FRAG_ONLY/changelog.d/10-only.md"
"$ROOT/scripts/release-prep.sh" 1.3.0 --date 2026-02-02 --root "$FRAG_ONLY" >/dev/null 2>&1 || fail "fragments alone should be enough to release"
assert_eq "### 동작 변경|- 조각만 있는 변경. (#10)" "$("$ROOT/scripts/changelog-section.sh" 1.3.0 "$FRAG_ONLY/CHANGELOG.md" | grep -v '^$' | paste -sd '|' -)" "the fragment becomes the release section"
assert_eq "1.3.0" "$(jq -r '.version' "$FRAG_ONLY/release.json")" "fragment-only release moves the manifests"
pass "release preparation accepts fragments with an empty Unreleased body"

# G: 저장소 자신의 조각이 형식을 지키고, 지시 문서가 조각 파일을 가리킨다.
for FRAG_DOC in AGENTS.md CONTRIBUTING.md .ai-harness/workflows/implement-feature.md .ai-harness/workflows/fix-bug.md \
  .ai-harness/workflows/review.md .ai-harness/workflows/release.md .ai-harness/agents/developer.md; do
  grep -q 'changelog\.d/' "$ROOT/$FRAG_DOC" || fail "$FRAG_DOC should direct entries to changelog.d/ fragments"
done
pass "contributor instructions point at changelog fragments"

finish_tests
