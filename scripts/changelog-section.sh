#!/usr/bin/env bash
# CHANGELOG.md에서 한 버전의 절만 꺼낸다. 릴리스 노트 발행과 오프라인 변경점 설명이 같은 출처를 쓴다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
CHANGELOG="${2:-$ROOT/CHANGELOG.md}"

if [[ -z "$VERSION" ]]; then
  printf 'usage: %s <version> [changelog path]\n' "${0##*/}" >&2
  exit 2
fi

VERSION="${VERSION#v}"
[[ -f "$CHANGELOG" ]] || { printf 'changelog not found: %s\n' "$CHANGELOG" >&2; exit 1; }

section="$(awk -v version="$VERSION" '
  $0 ~ "^## v" version "( |$|\\()" { inside = 1; next }
  inside && /^## / { exit }
  inside { print }
' "$CHANGELOG")"

# 앞뒤 빈 줄 제거
section="$(printf '%s' "$section" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

if [[ -z "$section" ]]; then
  printf 'no changelog section for v%s\n' "$VERSION" >&2
  exit 1
fi

printf '%s\n' "$section"
