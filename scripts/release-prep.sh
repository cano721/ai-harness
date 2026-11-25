#!/usr/bin/env bash
# 릴리스 준비. 기능 PR이 남긴 `changelog.d/<이슈>-<요약>.md` 조각과 남아 있는 `## Unreleased` 본문을 소제목별로 합쳐
# 버전 절로 확정하고, 그 위에 빈 `## Unreleased` 머리를 남기며, 쓴 조각을 지우고, 메타데이터 네 곳을 한 번에 맞춘다.
#   release-prep.sh <version> [--date YYYY-MM-DD] [--root <dir>]
#   release-prep.sh --check [--root <dir>]   : 쓰지 않고 네 곳의 정합성과 조각 형식만 검사
#
# 기능 PR은 이 스크립트를 쓰지 않는다. 버전 파일·CHANGELOG 버전 절을 건드리는 건 릴리스 커밋 하나뿐이고,
# 기능 PR은 PR마다 조각 파일 하나에만 쓰므로 동시에 열린 PR들이 같은 줄에서 충돌하지 않는다.
# 조각 형식(CONTRIBUTING.md "CHANGELOG"): `### <소제목>`(새 기능·버그 수정·동작 변경·업데이트 후 해야 할 일) 아래
# `- ` 항목, 공백·탭으로 들여쓴 이어지는 줄, 빈 줄, HTML 주석(합칠 때 버린다)만 쓴다.
set -euo pipefail

usage() {
  printf 'usage: %s <version> [--date YYYY-MM-DD] [--root <dir>]\n       %s --check [--root <dir>]\n' "$0" "$0" >&2
  exit 2
}

version=""
date_arg=""
root=""
check_only=false
while (($#)); do
  case "$1" in
    --check) check_only=true; shift ;;
    --date) date_arg="${2:-}"; shift 2 ;;
    --root) root="${2:-}"; shift 2 ;;
    -*) usage ;;
    *) [[ -n "$version" ]] && usage; version="$1"; shift ;;
  esac
done

if [[ -z "$root" ]]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fi
[[ -d "$root" ]] || usage

claude_manifest="$root/.claude-plugin/plugin.json"
codex_manifest="$root/.codex-plugin/plugin.json"
release_manifest="$root/release.json"
changelog="$root/CHANGELOG.md"
for f in "$claude_manifest" "$codex_manifest" "$release_manifest" "$changelog"; do
  [[ -f "$f" ]] || { printf 'missing file: %s\n' "$f" >&2; exit 2; }
done

manifest_version() { jq -r '.version // empty' "$1"; }

fragment_dir="$root/changelog.d"

# 조각 파일 목록: 파일명 앞 이슈 번호의 숫자 오름차순, 같으면 파일명순. 규칙에 맞지 않는 .md 이름도 그대로 넣어
# 형식 검사가 실패로 보게 한다.
list_fragments() {
  [[ -d "$fragment_dir" ]] || return 0
  local f
  for f in "$fragment_dir"/*.md; do
    [[ -e "$f" ]] || continue
    printf '%s\n' "${f##*/}"
  done | LC_ALL=C sort -t- -k1,1n -k2
}

# 조각(과 Unreleased 본문)을 해석한다. mode=validate는 오류만 stderr에, mode=merge는 오류가 없을 때 합친 절을 stdout에 낸다.
# 오류가 하나라도 있으면 exit 1. unrel_file이 주어지면 그 파일을 "CHANGELOG.md ## Unreleased"(줄 번호는 unrel_offset 기준)로 부른다.
parse_entries() {
  local mode="$1" unrel_file="$2" unrel_offset="$3"
  shift 3
  # shellcheck disable=SC2016  # awk 프로그램을 문자 그대로 넘긴다
  awk -v mode="$mode" -v root="$root/" -v unrel_file="$unrel_file" -v unrel_offset="$unrel_offset" '
    BEGIN {
      name[1] = "업데이트 후 해야 할 일"; name[2] = "새 기능"; name[3] = "동작 변경"; name[4] = "버그 수정"
      errors = 0; total = 0; started = 0
    }
    function label() {
      if (file == unrel_file) return "CHANGELOG.md (## Unreleased)"
      if (index(file, root) == 1) return substr(file, length(root) + 1)
      return file
    }
    function lineno() { return (file == unrel_file) ? FNR + unrel_offset : FNR }
    function err(msg, with_line) {
      if (with_line) printf "%s: line %d: %s\n", label(), lineno(), msg > "/dev/stderr"
      else printf "%s: %s\n", label(), msg > "/dev/stderr"
      errors++
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function close_block() {
      if (block != "") { buf[cur] = (buf[cur] == "") ? block : buf[cur] "\n" block; total++ }
      block = ""; pending = ""
    }
    function close_heading() {
      close_block()
      if (cur && !items) err("heading \"### " name[cur] "\" has no entries", 0)
    }
    function end_file() {
      if (!started) return
      close_heading()
      if (fence) err("code fence is not closed", 0)
      if (comment) err("HTML comment is not closed", 0)
      if (!headings && file != unrel_file) err("no \"### \" heading with entries", 0)
    }
    FNR == 1 {
      end_file()
      started = 1; file = FILENAME
      cur = 0; items = 0; headings = 0; block = ""; pending = ""; fence = 0; comment = 0
      if (file != unrel_file) {
        base = file; sub(/.*\//, "", base)
        if (base !~ /^[0-9]+-[a-z0-9][a-z0-9-]*\.md$/) err("file name must look like <issue>-<summary>.md (lowercase, digits, hyphens)", 0)
      }
    }
    comment { if (index($0, "-->")) comment = 0; next }
    fence {
      block = block pending "\n" $0; pending = ""
      if (trim($0) ~ /^```/) fence = 0
      next
    }
    trim($0) ~ /^<!--/ {
      rest = substr($0, index($0, "<!--") + 4)
      if (!index(rest, "-->")) comment = 1
      next
    }
    /^### / {
      close_heading()
      h = trim(substr($0, 5)); cur = 0
      for (i = 1; i <= 4; i++) if (name[i] == h) cur = i
      if (!cur) err("unknown heading \"### " h "\" (use 새 기능, 버그 수정, 동작 변경, 업데이트 후 해야 할 일)", 1)
      items = cur ? 0 : 1; headings++
      next
    }
    /^- / {
      close_block()
      if (!cur) { if (!headings) err("entry before any \"### \" heading", 1); next }
      block = $0; items++
      next
    }
    /^[ \t]*$/ { if (block != "") pending = pending "\n"; next }
    /^[ \t]/ {
      if (block == "") { if (cur || !headings) err("indented line outside an entry", 1); next }
      block = block pending "\n" $0; pending = ""
      if (trim($0) ~ /^```/) fence = 1
      next
    }
    /^## / { err("\"## \" headings are not allowed; start with a \"### \" heading", 1); next }
    { err("text outside an entry (start entries with \"- \", indent continuation lines)", 1) }
    END {
      if (started) end_file()
      if (errors) exit 1
      if (mode != "merge") exit 0
      first = 1
      for (i = 1; i <= 4; i++) {
        if (buf[i] == "") continue
        if (!first) print ""
        print "### " name[i]; print ""; print buf[i]
        first = 0
      }
    }
  ' "$@"
}

# --check용: 조각 형식만 검사한다. 조각이 없으면 통과.
check_fragments() {
  local files=() f
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$fragment_dir/$f")
  done <<<"$(list_fragments)"
  [[ ${#files[@]} -gt 0 ]] || return 0
  parse_entries validate "" 0 "${files[@]}"
}

if [[ "$check_only" == true ]]; then
  [[ -z "$version" ]] || usage
  claude_v="$(manifest_version "$claude_manifest")"
  codex_v="$(manifest_version "$codex_manifest")"
  release_v="$(manifest_version "$release_manifest")"
  status=0
  if [[ "$claude_v" != "$codex_v" ]] || [[ "$claude_v" != "$release_v" ]]; then
    printf 'version mismatch: claude=%s codex=%s release=%s\n' "$claude_v" "$codex_v" "$release_v" >&2
    status=1
  fi
  for key in release_url notes_url; do
    url="$(jq -r --arg k "$key" '.[$k] // empty' "$release_manifest")"
    [[ "$url" == *"/tag/v$release_v" ]] || {
      printf '%s does not point at the v%s tag: %s\n' "$key" "$release_v" "$url" >&2
      status=1
    }
  done
  grep -q "^## v$release_v " "$changelog" || {
    printf 'changelog has no section for v%s\n' "$release_v" >&2
    status=1
  }
  grep -q '^## Unreleased' "$changelog" ||
    printf 'warning: changelog has no "## Unreleased" heading — add one before the next PR entry\n' >&2
  check_fragments || status=1
  [[ "$status" -eq 0 ]] && printf 'release metadata consistent at v%s\n' "$release_v"
  exit "$status"
fi

[[ -n "$version" ]] || usage
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'version must be MAJOR.MINOR.PATCH: %s\n' "$version" >&2
  exit 2
}
grep -q "^## v$version " "$changelog" && {
  printf 'changelog already carries v%s\n' "$version" >&2
  exit 2
}
grep -q '^## Unreleased' "$changelog" || {
  printf 'changelog has no Unreleased section — nothing to release\n' >&2
  exit 2
}

release_date="${date_arg:-$(date +%Y-%m-%d)}"
[[ "$release_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
  printf 'date must be YYYY-MM-DD: %s\n' "$release_date" >&2
  exit 2
}

work="$(mktemp -d "${TMPDIR:-/tmp}/release-prep.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 전환기에 옛 PR이 Unreleased에 쓴 항목도 조각과 같은 문법으로 읽어 먼저 둔다.
unreleased_line="$(grep -n '^## Unreleased' "$changelog" | head -1 | cut -d: -f1)"
awk '/^## Unreleased/ && !done { flag = 1; done = 1; next } /^## /{ flag = 0 } flag' "$changelog" >"$work/unreleased.md"
fragments=()
while IFS= read -r f; do
  [[ -n "$f" ]] && fragments+=("$fragment_dir/$f")
done <<<"$(list_fragments)"

# 모든 검증을 쓰기 전에 끝낸다. 형식 오류가 하나라도 있으면 어떤 파일도 바꾸지 않는다.
if ! parse_entries merge "$work/unreleased.md" "$unreleased_line" "$work/unreleased.md" ${fragments[@]+"${fragments[@]}"} >"$work/section.md"; then
  printf 'changelog entries are malformed — fix the files above and run again\n' >&2
  exit 2
fi
[[ -s "$work/section.md" ]] || {
  printf 'the Unreleased section is empty and changelog.d/ has no fragments — write the user-facing changes first\n' >&2
  exit 2
}

# Unreleased 머리 아래에 합친 버전 절을 놓고 그 위에 빈 Unreleased 머리를 남긴다(다음 릴리스도 같은 자리에서 시작한다).
# 옛 Unreleased 본문(안내 주석 포함)은 합친 절이 대신한다.
awk -v header="## v$version ($release_date)" -v section="$work/section.md" '
  /^## Unreleased/ && !done {
    print "## Unreleased"; print ""; print header
    while ((getline line < section) > 0) print line
    close(section); skipping = 1; done = 1; next
  }
  skipping && /^## / { skipping = 0; print "" }
  skipping { next }
  { print }
' "$changelog" >"$work/CHANGELOG.md"
mv "$work/CHANGELOG.md" "$changelog"

for manifest in "$claude_manifest" "$codex_manifest"; do
  jq --arg v "$version" '.version = $v' "$manifest" >"$work/manifest.json" && mv "$work/manifest.json" "$manifest"
done

tag_url="https://github.com/cano721/ai-harness/releases/tag/v$version"
jq --arg v "$version" --arg url "$tag_url" \
  '.version = $v | .release_url = $url | .notes_url = $url' "$release_manifest" >"$work/release.json" && mv "$work/release.json" "$release_manifest"

# 버전 절로 옮긴 조각은 지운다. 다음 릴리스가 같은 항목을 다시 합치지 않게.
if [[ ${#fragments[@]} -gt 0 ]]; then
  rm -f "${fragments[@]}"
fi

printf 'prepared v%s (%s)\n' "$version" "$release_date"
printf 'next:\n' >&2
printf '  1. commit and open a PR from develop into main\n' >&2
printf '  2. after the merge, publish the release from main:\n' >&2
printf '     scripts/changelog-section.sh %s > /tmp/notes.md\n' "$version" >&2
printf '     gh release create v%s --target main --title v%s --notes-file /tmp/notes.md --generate-notes --latest\n' "$version" "$version" >&2
printf '  3. close the v%s milestone and open the next one\n' "$version" >&2
