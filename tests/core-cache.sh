#!/usr/bin/env bash
# 회귀 테스트 — 가짜 저장소 기준 템플릿 캐시(HM_TEST_REPO_TEMPLATE·$TEST_TMP 폴백·원자적 생성·run.sh 실행 캐시 정리) (#614)
# 실행: bash tests/run.sh core-cache
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$ROOT/tests/lib-driver.sh"

template_digest() { # dir → 파일 목록과 내용 해시
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(shasum -a 256 "$f" 2>/dev/null || sha256sum "$f")" "$f"; done)
}
assert_fresh_driver_repo() { # label — DRIVER_REPO가 init 커밋 하나·user t@t·깨끗한 작업 트리인지
  assert_eq "init" "$(git -C "$DRIVER_REPO" log --format=%s)" "$1: one init commit"
  assert_eq "t@t" "$(git -C "$DRIVER_REPO" config user.email)" "$1: user email"
  assert_eq "" "$(git -C "$DRIVER_REPO" status --porcelain)" "$1: clean worktree"
}

# run.sh가 넘긴 템플릿이 있으면 new_driver_repo는 git init 대신 그 템플릿을 복사한다.
CACHE_T="$TEST_TMP/cache/repo-template"
mkdir -p "$TEST_TMP/cache"
ensure_repo_template "$CACHE_T"
export HM_TEST_REPO_TEMPLATE="$CACHE_T"
TEST_REPO_TEMPLATE=""
new_driver_repo s1
assert_fresh_driver_repo "template copy"
assert_eq "$(git -C "$CACHE_T" rev-parse HEAD)" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "the repo is a copy of the given template"
[[ ! -e "$TEST_TMP/repo-template" ]] || fail "a valid HM_TEST_REPO_TEMPLATE needs no per-area template"
pass "new_driver_repo copies the run template from HM_TEST_REPO_TEMPLATE"

# 복사본에 커밋·설정을 바꿔도 템플릿은 그대로다(읽기 전용 원본).
before="$(template_digest "$CACHE_T")"
printf 'x\n' >"$DRIVER_REPO/f"
git -C "$DRIVER_REPO" add f
git -C "$DRIVER_REPO" commit -q -m change
git -C "$DRIVER_REPO" config user.email other@example.com
new_driver_repo s1b
assert_fresh_driver_repo "second copy"
assert_eq "$before" "$(template_digest "$CACHE_T")" "template files and contents stay unchanged"
pass "changes in a copy leave the template untouched"

# 같은 경로에 동시에 만들어도 확정 템플릿은 하나이고 임시 디렉토리가 남지 않는다.
mkdir -p "$TEST_TMP/race"
for n in 1 2 3 4; do ensure_repo_template "$TEST_TMP/race/repo-template" & done
wait
assert_eq "repo-template" "$(ls -A "$TEST_TMP/race")" "one committed template, no leftover build dirs"
git -C "$TEST_TMP/race/repo-template" rev-parse -q --verify HEAD >/dev/null || fail "the raced template is a valid repo"
assert_eq ".git" "$(ls -A "$TEST_TMP/race/repo-template")" "the template holds only .git"
pass "concurrent template builds commit one template atomically"

# 영역 단독 실행(변수 없음·없는 경로): 처음 쓸 때 $TEST_TMP/repo-template에 한 번 만들어 같은 결과를 낸다.
unset HM_TEST_REPO_TEMPLATE
TEST_REPO_TEMPLATE=""
new_driver_repo s4
assert_fresh_driver_repo "unset fallback"
[[ -d "$TEST_TMP/repo-template/.git" ]] || fail "fallback template lives in TEST_TMP"
export HM_TEST_REPO_TEMPLATE="$TEST_TMP/missing-template"
TEST_REPO_TEMPLATE=""
new_driver_repo s4b
assert_fresh_driver_repo "missing path fallback"
assert_eq "$(git -C "$TEST_TMP/repo-template" rev-parse HEAD)" "$(git -C "$DRIVER_REPO" rev-parse HEAD)" "a missing template path falls back to TEST_TMP"
[[ ! -e "$TEST_TMP/missing-template" ]] || fail "the missing path is not created"
pass "without a run template the area builds one in TEST_TMP"

# NEW_REPO_LINKED: 복사한 저장소(DRIVER_MAIN) 위에 링크된 worktree를 DRIVER_REPO로 둔다.
NEW_REPO_LINKED=1 new_driver_repo s2
[[ -d "$DRIVER_MAIN/.git" ]] || fail "DRIVER_MAIN is the copied main repo"
assert_eq "$DRIVER_MAIN/.git" "$(cd "$(git -C "$DRIVER_REPO" rev-parse --git-common-dir)" && pwd -P)" "DRIVER_REPO is a linked worktree of DRIVER_MAIN"
[[ -f "$DRIVER_REPO/.git" ]] || fail "linked worktree has a .git file"
assert_eq "init" "$(git -C "$DRIVER_REPO" log --format=%s)" "linked worktree starts at init"
pass "NEW_REPO_LINKED makes a linked worktree on the copied repo"

# run.sh는 영역을 띄우기 전에 실행 캐시를 만들어 넘기고, 끝나면(직렬·-j) 지운다. 이름은 영역 정리 패턴에 걸리지 않는다.
RC_FIXTURE="$TEST_TMP/run-cache"
mkdir -p "$RC_FIXTURE/tests" "$TEST_TMP/rc-tmp"
cp "$ROOT/tests/run.sh" "$ROOT/tests/lib-repo-template.sh" "$RC_FIXTURE/tests/"
for n in ca cb; do
  cat >"$RC_FIXTURE/tests/$n.sh" <<AREA
#!/usr/bin/env bash
printf '%s\n' "\${HM_TEST_REPO_TEMPLATE:-}" >>"$TEST_TMP/rc-seen.$n"
git -C "\$HM_TEST_REPO_TEMPLATE" rev-parse -q --verify HEAD >/dev/null && printf 'ok 1 - $n\n1..1\n'
AREA
done
for jobs in 1 2; do # 1: 직렬 경로(HM_TEST_JOBS=1), 2: 병렬 경로
  rm -f "$TEST_TMP"/rc-seen.*
  TMPDIR="$TEST_TMP/rc-tmp" HM_TEST_JOBS="$jobs" bash "$RC_FIXTURE/tests/run.sh" ca cb >"$TEST_TMP/rc.out" 2>&1 || fail "run.sh -j $jobs passes: $(<"$TEST_TMP/rc.out")"
  seen="$(<"$TEST_TMP/rc-seen.ca")"
  assert_eq "$seen" "$(<"$TEST_TMP/rc-seen.cb")" "-j $jobs: both areas share one run template"
  case "$seen" in "$TEST_TMP/rc-tmp/ai-harness-testcache."*/repo-template) ;; *) fail "-j $jobs: run template lives in TMPDIR/ai-harness-testcache.* ($seen)" ;; esac
  cache_name="${seen%/repo-template}"
  case "/${cache_name##*/}" in */ai-harness-tests.*) fail "-j $jobs: run cache must not match the area cleanup pattern ($seen)" ;; esac
  assert_eq "" "$(ls -A "$TEST_TMP/rc-tmp")" "-j $jobs: run cache is removed when run.sh ends"
done
pass "run.sh creates the run template cache before areas and removes it at the end"

finish_tests
