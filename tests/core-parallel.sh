#!/usr/bin/env bash
# 회귀 테스트 — tests/run.sh 병렬 실행·slow-areas.txt·HM_TEST_JOBS·문서의 -j 표기
# 실행: bash tests/run.sh core-parallel
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

finish_tests
