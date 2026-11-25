#!/usr/bin/env bash
# 회귀 테스트 — 업데이트 확인·릴리스 메타데이터
# 실행: bash tests/run.sh release
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

finish_tests
