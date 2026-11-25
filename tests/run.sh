#!/usr/bin/env bash
# 회귀 테스트 진입점. 영역 파일(tests/<영역>.sh)을 골라 하나씩 별도 프로세스로 돌린다.
#
#   bash tests/run.sh                  전체 (CI·PR 직전)
#   bash tests/run.sh board init       고른 영역만
#   bash tests/run.sh --changed        origin/develop 대비 바뀐 파일을 다루는 영역만 (평소 작업 중)
#   bash tests/run.sh --changed --explain  실행하지 않고 파일별 선택 근거와 최종 선택만 낸다
#   bash tests/run.sh --fast           느린 영역(tests/slow-areas.txt)을 뺀다. 다른 선택과 같이 쓸 수 있다
#   bash tests/run.sh -j 2             최대 2개 영역을 병렬 실행한다 (없으면 HM_TEST_JOBS, 그것도 없으면 직렬)
#   bash tests/run.sh --lint           바뀐 셸 파일만 bash -n + shellcheck -S style -x + bash 3.2 중괄호 검사 (파일마다 따로)
#   bash tests/run.sh --list           영역 목록
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SLOW_AREAS_FILE="$TESTS_DIR/slow-areas.txt"

# 느린 영역 목록(한 줄에 하나, # 주석·빈 줄 무시). --fast에서 빼고, -j에서는 이 순서(긴 것부터)로 먼저 시작한다. 파일이 없으면 빈 목록.
slow_area_lines() { # file
  [[ -f "$1" ]] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -v '^$' || true
}
SLOW_AREAS="$(slow_area_lines "$SLOW_AREAS_FILE" | tr '\n' ' ')"

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

all_areas() {
  local f n
  for f in "$TESTS_DIR"/*.sh; do
    n="${f##*/}"
    n="${n%.sh}"
    case "$n" in run | lib | lib-*) continue ;; esac # lib-*.sh: 여러 영역이 source하는 공용 헬퍼
    printf '%s\n' "$n"
  done
}

# 바뀐 파일 하나를 다루는 영역: 경로를 그대로 언급하는 영역 파일, 없으면 상위 폴더를 언급하는 영역 파일.
areas_for_file() {
  local file="$1" probe="$1" hits hit n
  case "$file" in
    tests/lib.sh | tests/run.sh | scripts/lib.sh) all_areas; return ;;
    tests/slow-areas.txt) slow_list_areas; return ;;
    tests/fixtures/*) ;;
    tests/lib-*.sh)
      # 공용 헬퍼는 그 파일 이름을 언급(source)하는 영역들로 잇는다.
      n="${file#tests/}"
      (cd "$TESTS_DIR" && grep -lF -- "$n" *.sh 2>/dev/null | grep -vxE 'run\.sh|lib\.sh|lib-.*\.sh' || true) | sed 's/\.sh$//'
      return ;;
    tests/*.sh) n="${file#tests/}"; printf '%s\n' "${n%.sh}"; return ;;
  esac
  while [[ "$probe" == */* ]]; do
    hits="$(cd "$TESTS_DIR" && grep -lF -- "$probe" *.sh 2>/dev/null | grep -vxE 'run\.sh|lib\.sh' || true)"
    if [[ -n "$hits" ]]; then
      while IFS= read -r hit; do
        case "$hit" in
          lib-*.sh) areas_for_file "tests/$hit" ;; # 공용 헬퍼에만 적힌 경로는 그 헬퍼를 source하는 영역으로
          *) printf '%s\n' "${hit%.sh}" ;;
        esac
      done <<<"$hits"
      return
    fi
    probe="${probe%/*}"
    # 최상위 폴더(scripts/, skills/ ...)만 남으면 모든 영역에 걸리므로 멈춘다
    [[ "$probe" == */* ]] || break
  done
  printf 'run.sh: 이 파일을 다루는 영역이 없음 — PR 전 전체 실행으로 확인: %s\n' "$file" >&2
}

# 느린 영역 목록이 바뀌면 추가·삭제된 줄의 영역만 고른다(실제 영역만). 미추적 새 파일이면 적힌 영역 전체.
slow_list_areas() {
  local names name all
  if git -C "$ROOT" ls-files --error-unmatch tests/slow-areas.txt >/dev/null 2>&1 \
    || git -C "$ROOT" cat-file -e "$MERGE_BASE:tests/slow-areas.txt" 2>/dev/null; then
    names="$(git -C "$ROOT" diff --no-color -U0 "$MERGE_BASE" -- tests/slow-areas.txt \
      | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)( |$)' | cut -c2- | sed -e 's/#.*//' -e 's/[[:space:]]//g' | grep -v '^$' || true)"
  else
    names="$(slow_area_lines "$SLOW_AREAS_FILE")"
  fi
  [[ -n "$names" ]] || return 0
  all=" $(all_areas | tr '\n' ' ') "
  while IFS= read -r name; do
    case "$all" in *" $name "*) printf '%s\n' "$name" ;; esac
  done <<<"$names"
}

# harness-init 재생성 스탬프(최상위 harness_version, managed_files.*의 content_sha256·template_version)만
# 바뀌었으면 참. 다른 키·항목 추가/삭제·기준에 없음·삭제됨·jq 실패는 거짓(경로로 고른다).
harness_stamp_only() {
  local f=".ai-harness/harness.json" old new
  local filter='del(.harness_version) | .managed_files = ((.managed_files // {}) | map_values(del(.content_sha256, .template_version)))'
  [[ -f "$ROOT/$f" ]] || return 1
  old="$(git -C "$ROOT" show "$MERGE_BASE:$f" 2>/dev/null | jq -S "$filter" 2>/dev/null)" || return 1
  new="$(jq -S "$filter" "$ROOT/$f" 2>/dev/null)" || return 1
  [[ -n "$old" && "$old" == "$new" ]]
}

# 생성물 사본(templates/managed-files.json의 artifacts[].path와 같은 경로)이면 그 원본 경로를 낸다.
copy_source() { # file
  local manifest="$ROOT/templates/managed-files.json"
  [[ -f "$manifest" ]] || return 0
  jq -r --arg p "$1" 'first((.artifacts // [])[] | select(.path == $p) | .source // empty) // empty' "$manifest" 2>/dev/null || true
}

# 바뀐 파일 하나의 영역. 메타 파일은 고르지 않고, 생성물 사본은 원본의 영역을 고른다.
# --explain이면 근거 한 줄을 fd 3(원래 stdout)에 낸다.
changed_file_areas() { # file
  local file="$1" src="" note="" meta="" areas
  case "$file" in
    CHANGELOG.md | changelog.d/*) meta="changelog" ;;
    .ai-harness/harness.json) harness_stamp_only && meta="harness.json 해시만" ;;
  esac
  if [[ -n "$meta" ]]; then
    [[ "$explain" == 0 ]] || printf '%s -> 제외 (메타: %s)\n' "$file" "$meta" >&3
    return 0
  fi
  src="$(copy_source "$file")"
  if [[ -n "$src" ]]; then
    areas="$(areas_for_file "$src" | awk '!seen[$0]++')"
    note=" (생성물 사본, 원본 $src)"
  else
    areas="$(areas_for_file "$file" | awk '!seen[$0]++')"
  fi
  [[ -z "$areas" ]] || printf '%s\n' "$areas"
  [[ "$explain" == 0 ]] && return 0
  if [[ -n "$areas" ]]; then
    printf '%s -> %s%s\n' "$file" "$(tr '\n' ' ' <<<"$areas" | sed 's/ $//')" "$note" >&3
  else
    printf '%s -> 영역 없음 — PR 전 전체 실행으로 확인\n' "$file" >&3
  fi
}

changed_areas() {
  local merge_base files file
  merge_base="$(merge_base_or_fail)" || {
    printf 'run.sh: 전체를 돈다\n' >&2
    all_areas
    return
  }
  MERGE_BASE="$merge_base"
  files="$(changed_files "$merge_base")"
  [[ -n "$files" ]] || return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] && changed_file_areas "$file"
  done <<<"$files"
}

merge_base_or_fail() {
  local base="${HM_TEST_BASE:-origin/develop}"
  git -C "$ROOT" merge-base HEAD "$base" 2>/dev/null || {
    printf 'run.sh: 기준 %s를 찾지 못함 (HM_TEST_BASE로 지정)\n' "$base" >&2
    return 1
  }
}

changed_files() { # merge_base
  {
    git -C "$ROOT" diff --name-only "$1"
    git -C "$ROOT" ls-files --others --exclude-standard
  } | sort -u
}

# 한 파일씩 따로 검사한다 — 큰 파일 여러 개를 한 프로세스로 분석하면 메모리가 크게 든다.
lint_changed() {
  local merge_base files file rc=0
  local sc=(shellcheck)
  command -v shellcheck >/dev/null 2>&1 || sc=(npx --yes shellcheck)
  merge_base="$(merge_base_or_fail)" || return 2
  files="$(changed_files "$merge_base" | grep -E '^(scripts|tests|hooks|templates)/.*\.sh$' || true)"
  if [[ -z "$files" ]]; then
    printf 'run.sh: 바뀐 셸 파일 없음\n'
    return 0
  fi
  while IFS= read -r file; do
    [[ -f "$ROOT/$file" ]] || continue
    printf '# lint %s\n' "$file"
    bash -n "$ROOT/$file" || rc=1
    (cd "$ROOT" && "${sc[@]}" -S style -x "$file") || rc=1
    python3 -I "$TESTS_DIR/bash32-check.py" "$ROOT/$file" || rc=1
  done <<<"$files"
  return "$rc"
}

selected=""
fast=0
changed=0
explain=0
jobs=1
parallel=0
expect_jobs=0
for arg in "$@"; do
  if [[ "$expect_jobs" == 1 ]]; then
    [[ "$arg" =~ ^[0-9]+$ ]] || { printf 'run.sh: -j 값은 1 이상의 정수여야 합니다\n' >&2; exit 2; }
    jobs="$arg"
    while [[ "$jobs" == 0* && "$jobs" != 0 ]]; do jobs="${jobs#0}"; done
    [[ "$jobs" != 0 ]] || { printf 'run.sh: -j 값은 1 이상의 정수여야 합니다\n' >&2; exit 2; }
    parallel=1
    expect_jobs=0
    continue
  fi
  case "$arg" in
    -h | --help) usage; exit 0 ;;
    --list) all_areas; exit 0 ;;
    --lint) lint_changed; exit $? ;;
    --fast) fast=1 ;;
    --changed) changed=1 ;;
    --explain) explain=1 ;;
    -j) expect_jobs=1 ;;
    -*) printf 'run.sh: 모르는 옵션 %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    *)
      [[ -f "$TESTS_DIR/$arg.sh" && "$arg" != run && "$arg" != lib ]] || { printf 'run.sh: 없는 영역 %s (--list 참고)\n' "$arg" >&2; exit 2; }
      selected="$selected $arg"
      ;;
  esac
done
[[ "$expect_jobs" == 0 ]] || { printf 'run.sh: -j 뒤에 동시 실행 수를 지정하세요\n' >&2; usage >&2; exit 2; }
# -j가 없으면 HM_TEST_JOBS(그래프 러너가 검사에 넘긴다)를 기본 동시 실행 수로 쓴다. -j가 이긴다.
if [[ "$parallel" == 0 && -n "${HM_TEST_JOBS:-}" ]]; then
  jobs="$HM_TEST_JOBS"
  while [[ "$jobs" == 0* && "$jobs" != 0 ]]; do jobs="${jobs#0}"; done
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'run.sh: -j 값은 1 이상의 정수여야 합니다 (HM_TEST_JOBS=%s)\n' "$HM_TEST_JOBS" >&2; exit 2; }
  [[ "$jobs" == 1 ]] || parallel=1
fi
if [[ "$explain" == 1 ]]; then
  [[ "$changed" == 1 ]] || { printf 'run.sh: --explain은 --changed와 함께 씁니다\n' >&2; exit 2; }
  exec 3>&1
fi
[[ "$changed" == 0 ]] || selected="$selected $(changed_areas | tr '\n' ' ')"
[[ -n "${selected// /}" || "$changed" == 1 ]] || selected="$(all_areas | tr '\n' ' ')"

# 영역 목록 순서를 지키고 중복을 없앤다
areas=""
for a in $(all_areas); do
  case " $selected " in *" $a "*) ;; *) continue ;; esac
  if [[ "$fast" == 1 ]]; then
    case " $SLOW_AREAS " in *" $a "*) continue ;; esac
  fi
  areas="$areas $a"
done
if [[ "$explain" == 1 ]]; then
  chosen="${areas# }"
  [[ -n "$chosen" ]] || chosen="(없음)"
  printf '# 선택: %s\n' "$chosen"
  exit 0
fi
if [[ -z "${areas// /}" ]]; then
  printf 'run.sh: 돌릴 영역이 없음\n'
  exit 0
fi

failed=""
total=0
if [[ "$parallel" == 0 ]]; then
  for a in $areas; do
    printf '# %s\n' "$a"
    start="$(date +%s)"
    out_file="$(mktemp "${TMPDIR:-/tmp}/ai-harness-test-out.XXXXXX")"
    if bash "$TESTS_DIR/$a.sh" 2>&1 | tee "$out_file"; then
      :
    else
      failed="$failed $a"
    fi
    n="$(grep -c '^ok ' "$out_file" || true)"
    rm -f "$out_file"
    total=$((total + n))
    printf '# %s: %d passed in %ds\n' "$a" "$n" "$(($(date +%s) - start))"
  done
else
  # Bash 3.2 호환: wait -n·mapfile 없이 kill -0 폴링으로 슬롯이 비는 즉시 다음 영역을 시작한다.
  # 느린 영역(SLOW_AREAS 순서)을 먼저 시작해 전체 시간이 가장 긴 영역 하나에 가깝게 한다.
  # 출력은 영역별 파일에 모았다가 시작 순서대로 블록째 내보내 섞이지 않게 하고,
  # 실패 요약은 직렬과 같은 선택 순서로 낸다. 실행 환경(HOME 등)은 직렬과 같다.
  area_list=()
  for s in $SLOW_AREAS; do
    for a in $areas; do [[ "$a" != "$s" ]] || area_list[${#area_list[@]}]="$a"; done
  done
  for a in $areas; do
    case " $SLOW_AREAS " in *" $a "*) ;; *) area_list[${#area_list[@]}]="$a" ;; esac
  done
  area_count="${#area_list[@]}"
  # 영역 수보다 큰 값은 실제 최대 영역 수로 제한해 큰 숫자의 산술 오버플로를 피한다.
  if [[ "${#jobs}" -gt "${#area_count}" ]]; then
    jobs="$area_count"
  elif [[ "${#jobs}" -eq "${#area_count}" ]] && [[ "$jobs" -gt "$area_count" ]]; then
    jobs="$area_count"
  fi
  next=0
  running=0
  shown=0
  # 중단되면 돌던 영역에 TERM을 보내(영역의 EXIT 트랩이 서버·TEST_TMP를 치운다) 기다리고,
  # 이미 끝난 영역의 블록은 내보낸 뒤 출력 파일을 지운다. Ctrl-C는 그룹 전체에 가서 폴링 중인
  # 명령이 먼저 죽을 수 있으므로 EXIT 트랩도 같은 정리를 탄다(정상 종료 전에 푼다).
  stop_parallel() { # exit-code
    local j=0 code="$1"
    [[ "$code" != 0 ]] || code=1
    trap - INT TERM EXIT
    while [[ "$j" -lt "$next" ]]; do
      if [[ -z "${ends[$j]:-}" && -n "${pids[$j]:-}" ]]; then
        kill -TERM "${pids[$j]}" 2>/dev/null || true
      fi
      j=$((j + 1))
    done
    wait 2>/dev/null || true
    j=0
    while [[ "$j" -lt "$next" ]]; do
      if [[ "$j" -ge "$shown" && -n "${ends[$j]:-}" && -f "${out_files[$j]:-}" ]]; then
        printf '# %s (finished before the interrupt)\n' "${area_list[$j]}"
        cat "${out_files[$j]}"
        [[ "${rcs[$j]:-1}" == 0 ]] || printf '# %s: failed\n' "${area_list[$j]}"
      fi
      [[ -z "${out_files[$j]:-}" ]] || rm -f "${out_files[$j]}"
      j=$((j + 1))
    done
    printf '# interrupted: %d of %d areas finished\n' "$shown" "$area_count" >&2
    exit "$code"
  }
  trap 'stop_parallel 130' INT
  trap 'stop_parallel 143' TERM
  trap 'stop_parallel "$?"' EXIT
  while [[ "$shown" -lt "$area_count" ]]; do
    while [[ "$running" -lt "$jobs" && "$next" -lt "$area_count" ]]; do
      out_files[next]="$(mktemp "${TMPDIR:-/tmp}/ai-harness-test-out.XXXXXX")"
      starts[next]="$(date +%s)"
      ends[next]=""
      bash "$TESTS_DIR/${area_list[$next]}.sh" >"${out_files[$next]}" 2>&1 &
      pids[next]=$!
      running=$((running + 1))
      next=$((next + 1))
    done
    i="$shown"
    while [[ "$i" -lt "$next" ]]; do
      if [[ -z "${ends[$i]}" ]] && ! kill -0 "${pids[$i]}" 2>/dev/null; then
        if wait "${pids[$i]}"; then rcs[i]=0; else rcs[i]=1; fi
        ends[i]="$(date +%s)"
        running=$((running - 1))
        # 앞 영역을 기다리느라 블록을 아직 못 내보내도 끝났다는 사실은 바로 알린다.
        [[ "$i" -eq "$shown" ]] || printf '# %s finished in %ds (output follows earlier areas)\n' "${area_list[$i]}" "$((${ends[$i]} - ${starts[$i]}))" >&2
      fi
      i=$((i + 1))
    done
    while [[ "$shown" -lt "$next" && -n "${ends[$shown]}" ]]; do
      a="${area_list[$shown]}"
      n="$(grep -c '^ok ' "${out_files[$shown]}" || true)"
      total=$((total + n))
      printf '# %s\n' "$a"
      cat "${out_files[$shown]}"
      printf '# %s: %d passed in %ds\n' "$a" "$n" "$((${ends[$shown]} - ${starts[$shown]}))"
      rm -f "${out_files[$shown]}"
      shown=$((shown + 1))
    done
    # sleep을 포그라운드로 두면 그 sleep이 막 정상 종료한 순간 온 Ctrl-C를 bash가 버린다.
    # 백그라운드 sleep을 wait 내장으로 기다리면 INT/TERM 트랩이 바로 돈다.
    if [[ "$shown" -lt "$area_count" ]]; then
      sleep 0.2 &
      wait "$!" || true
    fi
  done
  trap - INT TERM EXIT
  for a in $areas; do
    i=0
    while [[ "${area_list[$i]}" != "$a" ]]; do i=$((i + 1)); done
    [[ "${rcs[$i]}" == 0 ]] || failed="$failed $a"
  done
fi

if [[ -n "$failed" ]]; then
  printf '# FAILED:%s (%d passed)\n' "$failed" "$total" >&2
  exit 1
fi
printf '# all passed: %d tests in%s\n' "$total" "$areas"
