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
: >"$TMP/build.txt"
: >"$TMP/docs.txt"

rel() { printf '%s' "${1#"$root"/}"; }

# ── 빌드 파일 수집 (루트와 한 단계 아래 모듈까지) ────────────────────────────
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  printf '%s\n' "$f" >>"$TMP/build.txt"
done < <(find "$root" -maxdepth 2 \
  \( -name node_modules -o -name .git -o -name build -o -name target -o -name .gradle \) -prune -o \
  -type f \( -name 'build.gradle' -o -name 'build.gradle.kts' -o -name 'package.json' \
             -o -name 'pom.xml' -o -name 'pyproject.toml' -o -name 'pytest.ini' -o -name 'setup.cfg' \) \
  -print 2>/dev/null | sort)

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
  printf '%s' "$1" | grep -qiE 'test|check|verify|lint|coverage|e2e|integration|regression|migrat|format'
}

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  base="$(basename "$f")"
  case "$base" in
    build.gradle|build.gradle.kts)
      add_stack gradle
      # tasks.register("x") / tasks.register<Test>("x") / tasks.named("x") / task x(...)
      while IFS= read -r t; do
        [[ -n "$t" ]] && gradle_relevant "$t" && add_fact gradle_task "$t" "$f"
      done < <(grep -oE 'tasks\.(register|named)(<[A-Za-z.]+>)?\(("|'"'"')[A-Za-z0-9_-]+' "$f" 2>/dev/null \
                 | sed -E 's/.*["'"'"']//' | sort -u)
      while IFS= read -r t; do
        [[ -n "$t" ]] && gradle_relevant "$t" && add_fact gradle_task "$t" "$f"
      done < <(grep -oE '^[[:space:]]*task[[:space:]]+[A-Za-z0-9_-]+' "$f" 2>/dev/null \
                 | awk '{print $2}' | sort -u)
      # JUnit 태그 필터 — 어떤 테스트가 기본 실행에서 빠지는지 가르는 사실이다.
      while IFS= read -r t; do
        [[ -n "$t" ]] && add_fact junit_tag "$t" "$f"
      done < <(grep -oE '(include|exclude)Tags[[:space:]]*\(?[[:space:]]*("|'"'"')[A-Za-z0-9_-]+' "$f" 2>/dev/null \
                 | sed -E 's/.*["'"'"']//' | sort -u)
      ;;
    package.json)
      if jq -e '.scripts' "$f" >/dev/null 2>&1; then
        add_stack npm
        while IFS= read -r t; do
          [[ -n "$t" ]] && add_fact npm_script "$t" "$f"
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
  while IFS= read -r t; do
    [[ -n "$t" ]] && printf 'gradle_task\t%s\t%s\n' "$t" "$(rel "$d")" >>"$TMP/uses.tsv"
  done < <(grep -oE '(\./)?gradlew[a-z.]*[[:space:]]+(-[^[:space:]]+[[:space:]]+)*:?[A-Za-z0-9_:-]+' "$d" 2>/dev/null \
             | awk '{print $NF}' | sed -E 's/^.*://' | grep -vE '^-' | sort -u)
  while IFS= read -r t; do
    [[ -n "$t" ]] && printf 'npm_script\t%s\t%s\n' "$t" "$(rel "$d")" >>"$TMP/uses.tsv"
  done < <(grep -oE '(npm|pnpm|yarn)[[:space:]]+(run[[:space:]]+)?[A-Za-z0-9_:-]+' "$d" 2>/dev/null \
             | awk '{print $NF}' | sort -u)
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
  if ! awk -F'\t' -v k="$kind" -v v="$value" '$1==k && $2==v {found=1} END{exit !found}' "$TMP/uses.tsv"; then
    printf '%s\t%s\t%s\n' "$kind" "$value" "$source" >>"$TMP/missing.tsv"
  fi
done < <(sort -u "$TMP/facts.tsv")
while IFS=$'\t' read -r kind value doc; do
  [[ -n "$kind" ]] || continue
  [[ "$kind" == "npm_script" ]] && printf '%s' "$value" | grep -qE "$NPM_BUILTIN" && continue
  [[ "$kind" == "gradle_task" ]] && printf '%s' "$value" | grep -qE "$GRADLE_BUILTIN" && continue
  # 문서가 언급한 스택의 사실이 하나도 없으면 비교 자체가 무의미하다 (그 스택을 안 쓰는 프로젝트).
  awk -F'\t' -v k="$kind" '$1==k {found=1} END{exit !found}' "$TMP/facts.tsv" || continue
  if ! awk -F'\t' -v k="$kind" -v v="$value" '$1==k && $2==v {found=1} END{exit !found}' "$TMP/facts.tsv"; then
    printf '%s\t%s\t%s\n' "$kind" "$value" "$doc" >>"$TMP/stale.tsv"
  fi
done < <(sort -u "$TMP/uses.tsv")

# ── 타임스탬프 약한 신호 ───────────────────────────────────────────────────
git_last() {
  local out
  out="$(git -C "$root" log -1 --format=%cI -- "$@" 2>/dev/null || true)"
  printf '%s' "$out"
}
build_ts=""; docs_ts=""
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ -s "$TMP/build.txt" ]]; then
    # shellcheck disable=SC2046  # 경로 목록을 인자로 펼쳐야 한다
    build_ts="$(cd "$root" && git log -1 --format=%cI -- $(sed "s|^$root/||" "$TMP/build.txt" | tr '\n' ' ') 2>/dev/null || true)"
  fi
  if [[ -s "$TMP/docs.txt" ]]; then
    # shellcheck disable=SC2046
    docs_ts="$(cd "$root" && git log -1 --format=%cI -- $(sed "s|^$root/||" "$TMP/docs.txt" | tr '\n' ' ') 2>/dev/null || true)"
  fi
fi
docs_older=false
if [[ -n "$build_ts" && -n "$docs_ts" && "$build_ts" > "$docs_ts" ]]; then
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
  '{
     root: $root,
     stacks: ($stacks | if .=="" then [] else split(" ") end),
     build_files: $build_files,
     docs: $docs,
     facts: $facts,
     missing_in_docs: $missing_in_docs,
     stale_in_docs: $stale_in_docs,
     timestamps: {
       build_last_commit: (if $build_last_commit=="" then null else $build_last_commit end),
       docs_last_commit: (if $docs_last_commit=="" then null else $docs_last_commit end),
       docs_older_than_build: $docs_older
     },
     drift: (($missing_in_docs|length) + ($stale_in_docs|length) > 0 or $docs_older)
   }'
