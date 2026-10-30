#!/usr/bin/env bash
# 코드↔docs drift 리포트 (읽기 전용). /harness-init --sync 계획에 붙인다.
#   scan --root <dir>  : 빌드 파일에서 뽑은 사실과 문서에 적힌 명령 호출을 대조해 JSON으로 낸다.
# 문서를 이해하려 들지 않는다. 기계로 확인 가능한 토큰(태스크·스크립트·프로파일·태그)만 본다.
set -euo pipefail

usage() {
  printf 'usage: %s scan --root <dir>\n' "$0" >&2
  exit 2
}

command_name="${1:-}"
[[ -n "$command_name" ]] || usage
shift

root=""
while (($#)); do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$command_name" == "scan" ]] || usage
[[ -n "$root" && -d "$root" ]] || usage
root="$(cd "$root" && pwd -P)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/docs-drift.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/facts.tsv"   # kind \t value \t source
: >"$TMP/uses.tsv"    # kind \t value \t doc
: >"$TMP/declared.txt"   # 선언된 Gradle 태스크 전부 (관련성 필터 없음) — stale 판정 기준
: >"$TMP/declared-prefix.txt" # "jacocoVerification${suffix}"처럼 이름이 보간되는 선언의 고정 앞부분
: >"$TMP/extra-uses.tsv" # 한 gradlew 호출의 둘째 이후 태스크 — missing 해소에만 쓴다
: >"$TMP/build.txt"
: >"$TMP/docs.txt"
: >"$TMP/tag-filters.tsv" # task \t include|exclude \t tag
: >"$TMP/targeted.tsv"    # doc \t line \t task \t tag \t use_instead
: >"$TMP/npm-declared.txt" # 워크스페이스 포함 선언된 npm 스크립트 전부 — stale 판정 기준
: >"$TMP/gate-lines.txt"  # dependsOn·executionData 줄 — 게이트에 물린 태스크 판정용

rel() { printf '%s' "${1#"$root"/}"; }

# ── 빌드 파일 수집 (루트와 한 단계 아래 모듈까지) ────────────────────────────
# package.json만 두 단계 아래(apps/<pkg>, packages/<pkg>)까지 본다. JS 워크스페이스는 그 깊이에 있어,
# 못 보면 워크스페이스 스크립트가 문서에 있는데도 stale로 오른다.
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  printf '%s\n' "$f" >>"$TMP/build.txt"
done < <({ find "$root" -maxdepth 2 \
  \( -name node_modules -o -name .git -o -name build -o -name target -o -name .gradle \) -prune -o \
  -type f \( -name 'build.gradle' -o -name 'build.gradle.kts' \
             -o -name 'pom.xml' -o -name 'pyproject.toml' -o -name 'pytest.ini' -o -name 'setup.cfg' \) \
  -print 2>/dev/null
  find "$root" -maxdepth 3 \
  \( -name node_modules -o -name .git -o -name build -o -name dist -o -name target -o -name .gradle \) -prune -o \
  -type f -name 'package.json' -print 2>/dev/null; } | sort)

# ── 문서 수집 ──────────────────────────────────────────────────────────────
for d in "$root/AGENTS.md" "$root/CLAUDE.md"; do
  [[ -f "$d" ]] && printf '%s\n' "$d" >>"$TMP/docs.txt"
done
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  printf '%s\n' "$f" >>"$TMP/docs.txt"
done < <(find "$root/.ai-harness" -type f -name '*.md' -print 2>/dev/null | sort)

stacks=""
add_stack() { case " $stacks " in *" $1 "*) ;; *) stacks="$stacks $1" ;; esac; }
add_fact() { printf '%s\t%s\t%s\n' "$1" "$2" "$(rel "$3")" >>"$TMP/facts.tsv"; }
# 문서에 적힐 값어치가 있는 Gradle 태스크만 본다. bootJar·classes·createProperties 같은 내부 태스크는
# 아무도 문서에 적지 않고, 적을 이유도 없다. 실제 피해는 "검증 명령이 문서에 없어 게이트를 비켜간 테스트"였다.
gradle_relevant() {
  printf '%s' "$1" | grep -qiE 'test|check|verif|lint|coverage|e2e|integration|regression|migrat|format|detekt|spotbugs|sonar|pitest|audit'
}

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  base="$(basename "$f")"
  case "$base" in
    build.gradle|build.gradle.kts)
      add_stack gradle
      # 주석 처리된 선언은 존재하지 않는 태스크다. CI에서 잠시 꺼둔 태스크가 흔해서
      # 그대로 두면 "문서에 없는 태스크"로 오탐이 난다. 파싱 전에 //와 /* */를 지운다.
      stripped="$TMP/stripped.gradle"
      # 주석 처리된 선언은 존재하지 않는 태스크다. CI에서 잠시 꺼둔 태스크가 흔해서
      # 그대로 두면 "문서에 없는 태스크"로 오탐이 난다. 파싱 전에 //와 /* */를 지운다.
      # 문자열 안의 /*는 주석이 아니다 — Jacoco 제외 글롭('com/**/config/**')이 대표적이라
      # 따옴표 상태를 추적하지 않으면 파일 뒷부분을 통째로 삼킨다.
      awk '{
        out = ""; i = 1; n = length($0); q = ""
        while (i <= n) {
          c = substr($0, i, 1); two = substr($0, i, 2)
          if (inblk) { if (two == "*/") { inblk = 0; i += 2 } else { i++ }; continue }
          if (q != "") {
            out = out c
            if (c == "\\" && i < n) { out = out substr($0, i + 1, 1); i += 2; continue }
            if (c == q) { q = "" }
            i++; continue
          }
          if (c == "\047" || c == "\"") { q = c; out = out c; i++; continue }
          if (two == "/*") { inblk = 1; i += 2; continue }
          if (two == "//") { break }
          out = out c; i++
        }
        print out
      }' "$f" >"$stripped" 2>/dev/null || cp "$f" "$stripped"
      # <Test> 타입 태스크는 이름과 무관하게 테스트 실행이다 — 문서에 없으면 게이트를 비켜간다.
      # 이름이 보간되면("jacocoVerification${x}") 실제 태스크명을 알 수 없다 — 사실로 올리지 않고
      # 앞부분만 기록해 문서의 완성된 이름이 stale로 오르지 않게 한다.
      while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        if [[ "$m" == *'$' ]]; then
          printf '%s' "$m" | sed -E 's/.*["'"'"']//; s/\$$//' >>"$TMP/declared-prefix.txt"
          printf '\n' >>"$TMP/declared-prefix.txt"
          continue
        fi
        t="$(printf '%s' "$m" | sed -E 's/.*["'"'"']//; s/["'"'"']$//')"
        printf '%s\n' "$t" >>"$TMP/declared.txt"
        if gradle_relevant "$t" || [[ "$m" == *"<Test>"* ]]; then add_fact gradle_task "$t" "$f"; fi
      done < <(grep -oE 'tasks\.(register|named)(<[A-Za-z.]+>)?\(("|'"'"')[A-Za-z0-9_-]+("|'"'"'|\$)' "$stripped" 2>/dev/null \
                 | sed -E 's/["'"'"']$//' | sort -u)
      while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        printf '%s\n' "$t" >>"$TMP/declared.txt"
        gradle_relevant "$t" && add_fact gradle_task "$t" "$f"
      done < <(grep -oE '^[[:space:]]*task[[:space:]]+[A-Za-z0-9_-]+' "$stripped" 2>/dev/null \
                 | awk '{print $2}' | sort -u)
      # JUnit 태그 필터 — 어떤 테스트가 기본 실행에서 빠지는지 가르는 사실이다.
      while IFS= read -r t; do
        [[ -n "$t" ]] && add_fact junit_tag "$t" "$f"
      done < <(grep -oE '(include|exclude)Tags[[:space:]]*\(?[[:space:]]*("|'"'"')[A-Za-z0-9_-]+' "$stripped" 2>/dev/null \
                 | sed -E 's/.*["'"'"']//' | sort -u)
      # 태스크별 태그 필터 (task \t include|exclude \t tag). `test`가 integration을 빼면
      # `./gradlew test --tests <통합테스트>`는 아무것도 실행하지 않는다 — targeted 명령 검사의 근거다.
      awk '
        function ctx_name(s,   m) {
          if (match(s, /^[[:space:]]*test[[:space:]]*\{/) || s ~ /tasks\.test[[:space:]]*\{/) return "test"
          if (match(s, /tasks\.(named|register)(<[A-Za-z.]+>)?\([[:space:]]*["\047][A-Za-z0-9_-]+/)) {
            m = substr(s, RSTART, RLENGTH); sub(/.*["\047]/, "", m); return m
          }
          if (match(s, /val[[:space:]]+[A-Za-z0-9_]+[[:space:]]+by[[:space:]]+tasks\.(registering|existing)/)) {
            m = substr(s, RSTART, RLENGTH); sub(/^val[[:space:]]+/, "", m); sub(/[[:space:]].*/, "", m); return m
          }
          if (match(s, /^[[:space:]]*task[[:space:]]+[A-Za-z0-9_-]+/)) {
            m = substr(s, RSTART, RLENGTH); sub(/^[[:space:]]*task[[:space:]]+/, "", m); return m
          }
          return ""
        }
        {
          line = $0
          name = ctx_name(line)
          if (name != "" && index(line, "{")) { sp++; stack_name[sp] = name; stack_depth[sp] = depth + 1 }
          cur = (sp > 0) ? stack_name[sp] : ""
          rest = line
          while (cur != "" && match(rest, /(include|exclude)Tags[^;)}]*/)) {
            seg = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
            kind = (seg ~ /^include/) ? "include" : "exclude"
            while (match(seg, /["\047][A-Za-z0-9_-]+["\047]/)) {
              tag = substr(seg, RSTART + 1, RLENGTH - 2); seg = substr(seg, RSTART + RLENGTH)
              print cur "\t" kind "\t" tag
            }
          }
          n = length(line)
          for (i = 1; i <= n; i++) {
            c = substr(line, i, 1)
            if (c == "{") depth++
            else if (c == "}") { depth--; while (sp > 0 && depth < stack_depth[sp]) sp-- }
          }
        }' "$stripped" >>"$TMP/tag-filters.tsv" 2>/dev/null || true
      grep -E 'dependsOn|executionData' "$stripped" >>"$TMP/gate-lines.txt" 2>/dev/null || true
      ;;
    package.json)
      if jq -e '.scripts' "$f" >/dev/null 2>&1; then
        add_stack npm
        # 워크스페이스 패키지의 eject·postbuild 같은 스크립트까지 올리면 missing이 묻힌다 — 검증 스크립트만 사실로 본다.
        while IFS= read -r t; do
          [[ -n "$t" ]] || continue
          printf '%s\n' "$t" >>"$TMP/npm-declared.txt"
          if [[ "$f" == "$root/package.json" ]] || gradle_relevant "$t" || [[ "$t" == *type* ]]; then
            add_fact npm_script "$t" "$f"
          fi
        done < <(jq -r '.scripts | keys[]' "$f" 2>/dev/null | sort -u)
      fi
      ;;
    pom.xml)
      add_stack maven
      while IFS= read -r t; do
        [[ -n "$t" ]] && add_fact maven_profile "$t" "$f"
      done < <(grep -oE '<id>[A-Za-z0-9_.-]+</id>' "$f" 2>/dev/null | sed -E 's|</?id>||g' | sort -u)
      ;;
    pyproject.toml|pytest.ini|setup.cfg)
      if grep -qE '^[[:space:]]*markers[[:space:]]*=' "$f" 2>/dev/null; then
        add_stack pytest
        while IFS= read -r t; do
          [[ -n "$t" ]] && add_fact pytest_marker "$t" "$f"
        done < <(sed -n -E '/^[[:space:]]*markers[[:space:]]*=/,/^[[:space:]]*[]$]/p' "$f" 2>/dev/null \
                   | grep -oE '[A-Za-z0-9_-]+[[:space:]]*:' | sed -E 's/[[:space:]]*:$//' | sort -u)
      fi
      ;;
  esac
done <"$TMP/build.txt"

# ── 문서에 적힌 명령 호출 수집 ─────────────────────────────────────────────
# 임의 단어가 아니라 실제 호출 형태만 본다 — 문서에 흔한 단어가 사실로 둔갑하지 않게.
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  # `./gradlew test integrationTest`처럼 한 호출에 태스크가 여럿 온다. 첫 태스크만 사용·stale 양쪽에 쓰고,
  # 둘째부터는 missing 해소에만 쓴다 — 산문("run ./gradlew build to verify")의 뒷단어가 stale로 둔갑하지 않게.
  while IFS=$'\t' read -r pos t; do
    [[ -n "$t" ]] || continue
    if [[ "$pos" == 1 ]]; then
      printf 'gradle_task\t%s\t%s\n' "$t" "$(rel "$d")" >>"$TMP/uses.tsv"
    else
      printf 'gradle_task\t%s\t%s\n' "$t" "$(rel "$d")" >>"$TMP/extra-uses.tsv"
    fi
  done < <(grep -oE '(\./)?gradlew[a-z.]*([[:space:]]+(-[^[:space:]]+|:?[A-Za-z0-9_:-]+))+' "$d" 2>/dev/null \
             | awk '{
                 # 값을 받는 플래그(--console plain)의 값은 태스크가 아니고, -x로 뺀 태스크는 실행이 아니다.
                 n = 0; skip = 0
                 for (i = 2; i <= NF; i++) {
                   if (skip) { skip = 0; continue }
                   if ($i ~ /^-/) {
                     if ($i ~ /^(-x|--exclude-task|-p|--project-dir|-c|--settings-file|-I|--init-script|-g|--gradle-user-home|--project-cache-dir|--console|--warning-mode|--max-workers|--priority|--tests|-D|-P)$/) skip = 1
                     continue
                   }
                   t = $i; sub(/^.*:/, "", t); if (t == "") continue
                   print ++n "\t" t
                 }
               }' \
             | sort -u)
  # pnpm --filter api test / yarn workspace web run build 처럼 스크립트명 앞에 다른 토큰이 온다.
  # 플래그와 워크스페이스 지정을 건너뛰고 첫 실제 토큰만 스크립트명으로 본다.
  # `yarn web test:ci`처럼 루트 별칭 스크립트(web → yarn workspace ...)를 거치면 둘째 토큰이 워크스페이스 스크립트다.
  # gradle과 같이 둘째 토큰은 missing 해소에만 쓴다.
  while IFS=$'\t' read -r pos t; do
    [[ -n "$t" ]] || continue
    if [[ "$pos" == 1 ]]; then
      printf 'npm_script\t%s\t%s\n' "$t" "$(rel "$d")" >>"$TMP/uses.tsv"
    else
      printf 'npm_script\t%s\t%s\n' "$t" "$(rel "$d")" >>"$TMP/extra-uses.tsv"
    fi
  done < <(grep -oE '(npm|pnpm|yarn)([[:space:]]+[^[:space:]`|&;"'"'"']+){1,4}' "$d" 2>/dev/null \
             | awk '{
                 i = 2; n = 0
                 while (i <= NF) {
                   t = $i
                   if (t ~ /^-/) { if (t == "--filter" || t == "-F") { i++ } ; i++ ; continue }
                   if (t == "run") { i++ ; continue }
                   # exec·dlx 뒤는 패키지 바이너리(tsc·vitest)다 — 스크립트가 아니다.
                   if (t == "exec" || t == "dlx") break
                   if (t == "workspace" || t == "workspaces") { i += 2 ; continue }
                   print ++n "\t" t
                   if (n == 2) break
                   i++
                 }
               }' | sort -u)
  while IFS= read -r t; do
    [[ -n "$t" ]] && printf 'maven_profile\t%s\t%s\n' "$t" "$(rel "$d")" >>"$TMP/uses.tsv"
  done < <(grep -oE '\-P[A-Za-z0-9_.-]+' "$d" 2>/dev/null | sed -E 's/^-P//' | sort -u)
  while IFS= read -r t; do
    [[ -n "$t" ]] && printf 'pytest_marker\t%s\t%s\n' "$t" "$(rel "$d")" >>"$TMP/uses.tsv"
  done < <(grep -oE '\-m[[:space:]]+("|'"'"')?[A-Za-z0-9_-]+' "$d" 2>/dev/null \
             | sed -E 's/^-m[[:space:]]*//; s/^["'"'"']//' | sort -u)
  # 태그는 호출이 아니라 서술로 등장한다 ("integration 태그는 제외됨"). 단순 언급도 사용으로 본다.
  while IFS=$'\t' read -r _ tag _; do
    [[ -n "$tag" ]] || continue
    if grep -qE "(^|[^A-Za-z0-9_-])$tag([^A-Za-z0-9_-]|$)" "$d" 2>/dev/null; then
      printf 'junit_tag\t%s\t%s\n' "$tag" "$(rel "$d")" >>"$TMP/uses.tsv"
    fi
  done < <(awk -F'\t' '$1=="junit_tag"' "$TMP/facts.tsv" | sort -u)
done <"$TMP/docs.txt"

# ── 대조 ───────────────────────────────────────────────────────────────────
# npm/pnpm/yarn은 하위 명령(install, run 등)이 스크립트 이름과 같은 자리에 오므로 제외한다.
NPM_BUILTIN='^(install|i|ci|run|test|start|publish|add|remove|exec|dlx|why|link|init)$'
# Gradle 내장 라이프사이클 태스크는 build.gradle에 선언이 없어도 존재한다 — 문서에 있다고 drift가 아니다.
GRADLE_BUILTIN='^(build|test|clean|check|assemble|jar|war|bootRun|bootJar|publish|publishToMavenLocal|dependencies|tasks|wrapper|javadoc|compileJava|compileTestJava|processResources|classes|install)$'
: >"$TMP/missing.tsv"
: >"$TMP/stale.tsv"
while IFS=$'\t' read -r kind value source; do
  [[ -n "$kind" ]] || continue
  if ! awk -F'\t' -v k="$kind" -v v="$value" '$1==k && $2==v {found=1} END{exit !found}' "$TMP/uses.tsv" "$TMP/extra-uses.tsv"; then
    printf '%s\t%s\t%s\n' "$kind" "$value" "$source" >>"$TMP/missing.tsv"
  fi
done < <(sort -u "$TMP/facts.tsv")
while IFS=$'\t' read -r kind value doc; do
  [[ -n "$kind" ]] || continue
  [[ "$kind" == "npm_script" ]] && printf '%s' "$value" | grep -qE "$NPM_BUILTIN" && continue
  [[ "$kind" == "npm_script" ]] && grep -qxF -- "$value" "$TMP/npm-declared.txt" && continue
  [[ "$kind" == "gradle_task" ]] && printf '%s' "$value" | grep -qE "$GRADLE_BUILTIN" && continue
  # 문서가 언급한 스택의 사실이 하나도 없으면 비교 자체가 무의미하다 (그 스택을 안 쓰는 프로젝트).
  awk -F'\t' -v k="$kind" '$1==k {found=1} END{exit !found}' "$TMP/facts.tsv" || continue
  # 태스크는 관련성 필터와 무관하게 선언돼 있으면 존재한다 — 필터는 missing 쪽 소음을 줄이는 용도다.
  if [[ "$kind" == "gradle_task" ]]; then
    grep -qxF -- "$value" "$TMP/declared.txt" && continue
    while IFS= read -r pre; do
      [[ -n "$pre" && "$value" == "$pre"* ]] && continue 2
    done <"$TMP/declared-prefix.txt"
    printf '%s\t%s\t%s\n' "$kind" "$value" "$doc" >>"$TMP/stale.tsv"
    continue
  fi
  if ! awk -F'\t' -v k="$kind" -v v="$value" '$1==k && $2==v {found=1} END{exit !found}' "$TMP/facts.tsv"; then
    printf '%s\t%s\t%s\n' "$kind" "$value" "$doc" >>"$TMP/stale.tsv"
  fi
done < <(sort -u "$TMP/uses.tsv")

# ── 태그로 빠진 테스트의 targeted 명령 ─────────────────────────────────────
# `test`가 integration 태그를 빼고 `integrationTest`가 그 태그만 돌리는 구성에서, 문서가 targeted 실행을
# `./gradlew test --tests`로만 안내하면 통합 테스트를 고친 에이전트는 "No tests found"나 엉뚱한 통과를 본다.
# 토큰 대조라 서술은 이해하지 못한다 — 같은 문서에 담당 태스크의 targeted 호출이 하나라도 있으면 안내한 것으로 본다.
# 담당 태스크가 dependsOn·executionData로 빌드 게이트에 물린 경우만 본다. regression·e2e처럼 게이트 밖 태그까지
# 올리면 targeted 명령을 쓴 문서마다 행이 생겨 진짜 공백이 묻힌다.
while IFS=$'\t' read -r task tag; do
  [[ -n "$task" ]] || continue
  owner="$(awk -F'\t' -v t="$task" -v g="$tag" '$1!=t && $2=="include" && $3==g {print $1; exit}' "$TMP/tag-filters.tsv")"
  [[ -n "$owner" ]] || continue
  grep -qE "(^|[^A-Za-z0-9_])${owner}([^A-Za-z0-9_]|$)" "$TMP/gate-lines.txt" || continue
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    hit="$(grep -nE "gradlew[a-z.]*([[:space:]]+[^[:space:]\`]+)*[[:space:]]+(:?[A-Za-z0-9_-]+:)*${task}([[:space:]]+[^[:space:]\`]+)*[[:space:]]+--tests" "$d" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    [[ -n "$hit" ]] || continue
    grep -qE "gradlew[a-z.]*([[:space:]]+[^[:space:]\`]+)*[[:space:]]+(:?[A-Za-z0-9_-]+:)*${owner}([[:space:]]+[^[:space:]\`]+)*[[:space:]]+--tests" "$d" 2>/dev/null && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$(rel "$d")" "$hit" "$task" "$tag" "$owner" >>"$TMP/targeted.tsv"
  done <"$TMP/docs.txt"
done < <(awk -F'\t' '$2=="exclude" {print $1 "\t" $3}' "$TMP/tag-filters.tsv" | sort -u)

# ── 타임스탬프 약한 신호 ───────────────────────────────────────────────────
# 빌드 파일이 문서보다 최근에 커밋됐으면 "검토 필요". 정확도는 낮지만 비용이 거의 없다.
# 표시는 ISO, 비교는 epoch로 한다 — %cI는 커밋터 로컬 오프셋이라 문자열 비교가 어긋난다.
last_commit_for() {
  local list="$1" fmt="$2"
  [[ -s "$list" ]] || return 0
  local paths=() p=""
  while IFS= read -r p; do
    [[ -n "$p" ]] && paths+=("${p#"$root"/}")
  done <"$list"
  ((${#paths[@]})) || return 0
  git -C "$root" log -1 --format="$fmt" -- "${paths[@]}" 2>/dev/null || true
}
build_ts=""
docs_ts=""
build_epoch=""
docs_epoch=""
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  build_ts="$(last_commit_for "$TMP/build.txt" %cI)"
  docs_ts="$(last_commit_for "$TMP/docs.txt" %cI)"
  build_epoch="$(last_commit_for "$TMP/build.txt" %ct)"
  docs_epoch="$(last_commit_for "$TMP/docs.txt" %ct)"
fi
docs_older=false
if [[ -n "$build_epoch" && -n "$docs_epoch" && "$build_epoch" -gt "$docs_epoch" ]]; then
  docs_older=true
fi

tsv_to_json() {
  jq -R -s -c 'split("\n") | map(select(length>0) | split("\t"))
               | group_by([.[0], .[1]])
               | map({kind:.[0][0], value:.[0][1],
                      where:(map(.[2]) | unique | (if length > 3 then .[0:3] + ["+\(length-3)"] else . end) | join(", "))})' "$1"
}

jq -n \
  --arg root "$root" \
  --arg stacks "${stacks# }" \
  --argjson build_files "$(jq -R -s -c 'split("\n")|map(select(length>0))' <"$TMP/build.txt" | jq --arg r "$root/" -c 'map(sub("^"+$r;""))')" \
  --argjson docs "$(jq -R -s -c 'split("\n")|map(select(length>0))' <"$TMP/docs.txt" | jq --arg r "$root/" -c 'map(sub("^"+$r;""))')" \
  --argjson facts "$(tsv_to_json "$TMP/facts.tsv")" \
  --argjson missing_in_docs "$(tsv_to_json "$TMP/missing.tsv")" \
  --argjson stale_in_docs "$(tsv_to_json "$TMP/stale.tsv")" \
  --arg build_last_commit "$build_ts" \
  --arg docs_last_commit "$docs_ts" \
  --argjson docs_older "$docs_older" \
  --argjson targeted "$(jq -R -s -c 'split("\n") | map(select(length>0) | split("\t")
                         | {doc:.[0], line:(.[1]|tonumber), task:.[2], excluded_tag:.[3], use_instead:.[4]})' "$TMP/targeted.tsv")" \
  '{
     root: $root,
     stacks: ($stacks | if .=="" then [] else split(" ") end),
     build_files: $build_files,
     docs: $docs,
     facts: $facts,
     missing_in_docs: $missing_in_docs,
     stale_in_docs: $stale_in_docs,
     targeted_command_gaps: $targeted,
     timestamps: {
       build_last_commit: (if $build_last_commit=="" then null else $build_last_commit end),
       docs_last_commit: (if $docs_last_commit=="" then null else $docs_last_commit end),
       docs_older_than_build: $docs_older
     },
     drift: (($missing_in_docs|length) + ($stale_in_docs|length) + ($targeted|length) > 0 or $docs_older)
   }'
