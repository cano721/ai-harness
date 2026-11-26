#!/usr/bin/env bash
# 회귀 테스트 — tests/run.sh CPU 기본 동시 실행 수·--profile·--shard·CI 샤드·--changed 메타 파일
# 실행: bash tests/run.sh core-runner
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# core-parallel 영역 앞 블록이 남기던 상태를 다시 만든다: -j 없는 실행은 직렬, run.sh 사본과 서로의 표지를 기다리는 두 영역 pa·pb.
export HM_TEST_JOBS=1
SLOW_FIXTURE="$TEST_TMP/slow-list-runner"
mkdir -p "$SLOW_FIXTURE/tests"
cp "$ROOT/tests/run.sh" "$SLOW_FIXTURE/tests/run.sh"
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

# -j도 HM_TEST_JOBS도 없으면 동시 실행 수는 max(1, min(ncpu/2, 6))다. ncpu는 러너 resolve_check_jobs처럼 getconf부터 구한다. (#556)
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
# 상한은 6이다(#585). 영역 q1..q7은 표지가 JOBS_BARRIER개 모일 때까지 기다린 뒤(동시 실행 수가 그 값 이상이어야 통과),
# 잠깐 머물며 그때 함께 도는 영역 수를 남긴다. 남긴 수의 최댓값이 동시 실행 수의 상한을 보인다.
for n in q1 q2 q3 q4 q5 q6 q7; do
  cat >"$SLOW_FIXTURE/tests/$n.sh" <<AREA
#!/usr/bin/env bash
: >"$TEST_TMP/jobs-mark-$n"
marks=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  marks=\$(find "$TEST_TMP" -maxdepth 1 -name 'jobs-mark-q*' | wc -l)
  [[ \$marks -ge \$JOBS_BARRIER ]] && break
  sleep 0.2
done
[[ \$marks -ge \$JOBS_BARRIER ]] || { printf '$n: only %s areas ran at once\n' "\$marks"; exit 1; }
sleep 0.3
running=\$(( \$(find "$TEST_TMP" -maxdepth 1 -name 'jobs-mark-q*' | wc -l) - \$(find "$TEST_TMP" -maxdepth 1 -name 'jobs-done-q*' | wc -l) ))
printf '%s\n' "\$running" >"$TEST_TMP/jobs-peak-$n"
: >"$TEST_TMP/jobs-done-$n"
printf 'ok 1 - $n\n'
AREA
done
jobs_peak() { cat "$TEST_TMP"/jobs-peak-q* | sort -n | tail -n 1; }
rm -f "$TEST_TMP"/jobs-done-* "$TEST_TMP"/jobs-peak-*
JOBS_BARRIER=6 cpu_jobs 16 q1 q2 q3 q4 q5 q6 q7
assert_eq "0" "$jobs_rc" "16 CPUs run six areas at once by default: $(<"$TEST_TMP/jobs-cpu.out")"
assert_eq "6" "$(jobs_peak)" "16 CPUs are capped at six areas at once"
rm -f "$TEST_TMP"/jobs-done-* "$TEST_TMP"/jobs-peak-*
JOBS_BARRIER=6 cpu_jobs 12 q1 q2 q3 q4 q5 q6 q7
assert_eq "0" "$jobs_rc" "12 CPUs run six areas at once by default: $(<"$TEST_TMP/jobs-cpu.out")"
assert_eq "6" "$(jobs_peak)" "12 CPUs run at most six areas at once"
rm -f "$TEST_TMP"/jobs-done-* "$TEST_TMP"/jobs-peak-*
JOBS_BARRIER=2 cpu_jobs 4 q1 q2 q3
assert_eq "0" "$jobs_rc" "4 CPUs run two areas at once by default: $(<"$TEST_TMP/jobs-cpu.out")"
assert_eq "2" "$(jobs_peak)" "4 CPUs run no more than two areas at once"
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

# CI는 lint job과 shard matrix 샤드로 나뉜다: matrix shard 목록은 1..N이고 run.sh --shard가 같은 N을 쓴다. (#556)
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
