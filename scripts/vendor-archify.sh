#!/usr/bin/env bash
# vendor/archify를 상류 릴리스 패키지로 교체하거나, 고정된 사본이 lock과 일치하는지 검증한다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor/archify"
LOCK="$ROOT/vendor/archify.lock.json"
SOURCE="https://github.com/tt-a1i/archify"

usage() {
  printf 'usage: %s <version> | --check\n' "$0" >&2
  exit 2
}

sha256_stdin() {
  shasum -a 256 2>/dev/null | awk '{print $1}' && return
  sha256sum | awk '{print $1}'
}

sha256_file() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' && return
  sha256sum "$1" | awk '{print $1}'
}

# 파일 경로와 내용 해시를 정렬해 한 번 더 해시한다. 파일 추가·삭제·수정 모두 값이 바뀐다.
tree_sha256() {
  local dir="$1" file
  (
    cd "$dir"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s  %s\n' "$(sha256_file "$file")" "${file#./}"
    done
  ) | sha256_stdin
}

check() {
  [[ -f "$LOCK" ]] || { printf 'missing lock: %s\n' "$LOCK" >&2; exit 1; }
  [[ -d "$VENDOR_DIR" ]] || { printf 'missing vendor dir: %s\n' "$VENDOR_DIR" >&2; exit 1; }
  local expected actual
  expected="$(jq -r '.tree_sha256' "$LOCK")"
  actual="$(tree_sha256 "$VENDOR_DIR")"
  if [[ "$expected" != "$actual" ]]; then
    printf 'vendor/archify differs from lock (expected=%s actual=%s)\n' "$expected" "$actual" >&2
    exit 1
  fi
  printf 'vendor/archify matches %s\n' "$(jq -r '.version' "$LOCK")"
}

update() {
  local version="$1" commit zip_sha
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/archify-vendor.XXXXXX")"
  trap 'find "$WORK" -depth -delete 2>/dev/null || true' EXIT
  local work="$WORK"

  git -c advice.detachedHead=false clone -q --depth 1 --branch "v$version" "$SOURCE.git" "$work/src"
  commit="$(git -C "$work/src" rev-parse HEAD)"
  # 상류가 커밋해 둔 배포 zip을 쓴다. test·개발 파일을 뺀 공식 구성이다.
  [[ -f "$work/src/archify.zip" ]] || { printf 'archify.zip not found at v%s\n' "$version" >&2; exit 1; }
  zip_sha="$(sha256_file "$work/src/archify.zip")"
  unzip -q "$work/src/archify.zip" -d "$work/pkg"
  [[ -f "$work/pkg/archify/SKILL.md" && -f "$work/pkg/archify/LICENSE" ]] \
    || { printf 'unexpected package layout in archify.zip\n' >&2; exit 1; }
  [[ "$(jq -r '.version' "$work/pkg/archify/skill-release.json")" == "$version" ]] \
    || { printf 'skill-release.json version does not match v%s\n' "$version" >&2; exit 1; }

  rm -rf "$VENDOR_DIR"
  mkdir -p "$ROOT/vendor"
  mv "$work/pkg/archify" "$VENDOR_DIR"

  jq -n \
    --arg version "$version" \
    --arg source "$SOURCE" \
    --arg commit "$commit" \
    --arg zip_sha "$zip_sha" \
    --arg tree_sha "$(tree_sha256 "$VENDOR_DIR")" \
    '{version: $version, source: $source, tag: ("v" + $version), commit: $commit, archive: "archify.zip", archive_sha256: $zip_sha, tree_sha256: $tree_sha, patches: []}' \
    >"$LOCK"
  printf 'vendored archify v%s (%s)\n' "$version" "$commit"
}

case "${1:-}" in
  --check) check ;;
  "") usage ;;
  *) update "$1" ;;
esac
