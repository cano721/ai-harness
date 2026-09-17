#!/usr/bin/env bash
# 릴리스 준비. develop에 쌓인 `## Unreleased` 절을 버전 절로 확정하고 메타데이터 네 곳을 한 번에 맞춘다.
#   release-prep.sh <version> [--date YYYY-MM-DD] [--root <dir>]
#   release-prep.sh --check [--root <dir>]   : 쓰지 않고 네 곳의 정합성만 검사
#
# 기능 PR은 이 스크립트를 쓰지 않는다. 버전 파일을 건드리는 건 릴리스 커밋 하나뿐이고,
# 그래서 동시에 열린 PR들이 버전 파일에서 충돌하지 않는다.
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

# Unreleased 절이 비어 있으면 릴리스할 내용이 없다. 사용자 영향 기준의 본문을 요구한다.
# 안내용 HTML 주석은 본문이 아니다.
unreleased_body="$(awk '/^## Unreleased/{flag=1; next} /^## /{flag=0} flag' "$changelog" \
  | awk '/<!--/{inc=1} !inc{print} /-->/{inc=0}' | tr -d '[:space:]')"
[[ -n "$unreleased_body" ]] || {
  printf 'the Unreleased section is empty — write the user-facing changes first\n' >&2
  exit 2
}

release_date="${date_arg:-$(date +%Y-%m-%d)}"
[[ "$release_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
  printf 'date must be YYYY-MM-DD: %s\n' "$release_date" >&2
  exit 2
}

tmp="$(mktemp "${TMPDIR:-/tmp}/release-prep.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# Unreleased 헤더를 버전 헤더로 바꾸고, 그 아래 안내 주석은 릴리스 노트에 남기지 않는다.
awk -v header="## v$version ($release_date)" '
  /^## Unreleased/ { print header; promoted = 1; next }
  promoted && /<!--/ { inc = 1 }
  inc { if (/-->/) { inc = 0; promoted = 0 }; next }
  promoted && /^[[:space:]]*$/ { next }
  { promoted = 0; print }
' "$changelog" >"$tmp" && mv "$tmp" "$changelog"

for manifest in "$claude_manifest" "$codex_manifest"; do
  tmp="$(mktemp "${TMPDIR:-/tmp}/release-prep.XXXXXX")"
  jq --arg v "$version" '.version = $v' "$manifest" >"$tmp" && mv "$tmp" "$manifest"
done

tag_url="https://github.com/cano721/ai-harness/releases/tag/v$version"
tmp="$(mktemp "${TMPDIR:-/tmp}/release-prep.XXXXXX")"
jq --arg v "$version" --arg url "$tag_url" \
  '.version = $v | .release_url = $url | .notes_url = $url' "$release_manifest" >"$tmp" && mv "$tmp" "$release_manifest"

printf 'prepared v%s (%s)\n' "$version" "$release_date"
printf 'next: commit, open a PR from develop into main, then tag v%s and publish the notes\n' "$version"
