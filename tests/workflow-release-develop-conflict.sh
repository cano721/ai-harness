#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — release 워크플로(#493): merge commit만 허용·develop 이동 충돌·그래프 계약·release-verify
# 실행: bash tests/run.sh workflow-release-develop-conflict
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

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

# 6. merge commit만: 호스트가 squash를 허용해도 --merge, merge commit이 허용되지 않으면 병합 호출 없이 사람에게.
rel_repo rel_method_all '.' merge
FAKE_MERGE_METHODS=all driver start --runtime codex --workflow release --version 1.3.0
assert_contains "$(<"$FAKE_LOG")" "gh merge https://github.com/acme/app/pull/7 --merge" "the release is merged with a merge commit"
assert_eq "0" "$(grep -c -- '--squash\|--rebase' "$FAKE_LOG" || true)" "never squash or rebase a release"
rel_repo rel_squash_only '.' merge
FAKE_MERGE_METHODS=squash_only driver start --runtime codex --workflow release --version 1.3.0
assert_eq "20:0" "$DRIVER_RC:$(grep -c '^gh merge' "$FAKE_LOG" || true)" "a repository without merge commits is not merged"
assert_contains "$(run_state '.merge.blocked | join(" ")')" "merge commit" "merge_blocked names the missing merge commit"
pass "release merges only with a merge commit"

# 10. 그래프 계약과 검증 스크립트.
bash "$ROOT/scripts/validate-release-graph.sh" "$RELEASE_GRAPH" >/dev/null || fail "the release graph is valid"
jq 'del(.nodes.revalidate)' "$RELEASE_GRAPH" >"$DRIVER_TMP/bad-graph.json"
if bash "$ROOT/scripts/validate-release-graph.sh" "$DRIVER_TMP/bad-graph.json" >/dev/null 2>&1; then fail "a release graph without revalidate is invalid"; fi
jq '.transitions += [{"from":"plan","to":"prepare","when":"x"}]' "$RELEASE_GRAPH" >"$DRIVER_TMP/bad-graph.json"
if bash "$ROOT/scripts/validate-release-graph.sh" "$DRIVER_TMP/bad-graph.json" >/dev/null 2>&1; then fail "a release graph that writes before approval is invalid"; fi
jq '.invariants |= map(select(startswith("No tag or release") | not))' "$RELEASE_GRAPH" >"$DRIVER_TMP/bad-graph.json"
if bash "$ROOT/scripts/validate-release-graph.sh" "$DRIVER_TMP/bad-graph.json" >/dev/null 2>&1; then fail "a release graph without the notes invariant is invalid"; fi
pass "release graph contract"

# 11. ai-harness 자신의 릴리스 확인·마일스톤 스크립트: GitHub 결과를 읽고, 진행 중이면 실패(재시도)한다.
REL_VERIFY_REPO="$DRIVER_TMP/verify-repo"
git init -q --bare "$DRIVER_TMP/verify-remote.git"
git init -q "$REL_VERIFY_REPO"
git -C "$REL_VERIFY_REPO" config user.email t@t && git -C "$REL_VERIFY_REPO" config user.name t
printf '{"version":"1.3.0"}\n' >"$REL_VERIFY_REPO/release.json"
git -C "$REL_VERIFY_REPO" add release.json && git -C "$REL_VERIFY_REPO" commit -qm init
git -C "$REL_VERIFY_REPO" remote add origin "$DRIVER_TMP/verify-remote.git"
git -C "$REL_VERIFY_REPO" push -q origin HEAD:refs/heads/main
rv() { (cd "$REL_VERIFY_REPO" && FAKE_LOG="$DRIVER_TMP/verify.log" PATH="$ROOT/tests/fixtures/driver:$PATH" bash "$ROOT/scripts/release-verify.sh" "$@" >/dev/null 2>&1); }
FAKE_RUN_STATUS=completed:success rv 1.3.0 || fail "release-verify passes when the release workflow succeeded and main has the version"
if FAKE_RUN_STATUS=in_progress: rv 1.3.0; then fail "release-verify fails while the release workflow runs"; fi
if FAKE_RUN_STATUS=completed:success rv 1.4.0; then fail "release-verify fails when main has another version"; fi
assert_contains "$(<"$DRIVER_TMP/verify.log")" "--workflow release" "release-verify reads the release workflow runs"
pass "release-verify checks the release workflow and main"

finish_tests
