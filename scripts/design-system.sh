#!/usr/bin/env bash
set -euo pipefail

# 디자인 시스템 원본(docs/design-system/tokens.css, components.css)을 단일 HTML 화면에 넣고 지킨다.
# 보드·리포트·기준 화면은 오프라인 단일 파일이라 CSS를 <link>로 불러올 수 없다. 그래서 원본을
# `/* ds:<part>:start … */` 와 `/* ds:<part>:end */` 사이에 사본으로 넣고, 사본이 원본과 같은지 검사한다.
#
#   sync      원본을 각 화면의 표시 구간에 다시 넣는다
#   check     사본이 원본과 같은지 본다 (다르면 exit 1)
#   contrast  규칙 문서가 허용한 전경/배경 쌍의 대비를 라이트·다크로 계산한다 (미달이면 exit 1, --md 는 표)

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
MD=""

usage() {
  printf 'usage: design-system.sh <sync|check|contrast> [--root DIR] [--md]\n' >&2
  exit 2
}

[ $# -gt 0 ] || usage
CMD="$1"
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
    --md) MD="--md"; shift ;;
    *) usage ;;
  esac
done

DS="$ROOT/docs/design-system"

# 사본을 싣는 화면과 싣는 원본. 화면을 더하면 여기에 줄을 더하고 표시 구간을 넣는다.
targets() {
  printf '%s\n' \
    'docs/design-system/reference.html tokens components' \
    'scripts/board/template.html tokens' \
    'skills/harness-impact/report-template.html tokens'
}

# 화면 파일에서 표시 구간 안쪽만 원본으로 바꿔 stdout에 낸다. 표시가 정확히 한 쌍이 아니면 exit 3.
render() { # file part source
  awk -v part="$2" -v src="$3" '
    index($0, "/* ds:" part ":start") {
      print
      while ((getline line < src) > 0) print line
      close(src)
      skip = 1; starts++
      next
    }
    index($0, "/* ds:" part ":end") { skip = 0; ends++ }
    !skip { print }
    END { if (starts != 1 || ends != 1) exit 3 }
  ' "$1"
}

each_copy() { # mode(sync|check)
  local mode="$1" line file part tmp status=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/design-system.XXXXXX")"
  while IFS= read -r line; do
    file="${line%% *}"
    for part in ${line#* }; do
      [ -f "$DS/$part.css" ] || { printf 'missing source: %s\n' "$DS/$part.css" >&2; rm -f "$tmp"; exit 1; }
      [ -f "$ROOT/$file" ] || { printf 'missing screen: %s\n' "$ROOT/$file" >&2; rm -f "$tmp"; exit 1; }
      if ! render "$ROOT/$file" "$part" "$DS/$part.css" >"$tmp"; then
        printf '%s: ds:%s 표시 구간(start/end)이 정확히 한 쌍이어야 한다\n' "$file" "$part" >&2
        rm -f "$tmp"
        exit 1
      fi
      if cmp -s "$tmp" "$ROOT/$file"; then
        continue
      fi
      if [ "$mode" = sync ]; then
        cat "$tmp" >"$ROOT/$file"
        printf 'synced %s (%s)\n' "$file" "$part"
      else
        printf '%s: %s 사본이 docs/design-system/%s.css 와 다르다 — scripts/design-system.sh sync\n' "$file" "$part" "$part" >&2
        status=1
      fi
    done
  done <<EOF
$(targets)
EOF
  rm -f "$tmp"
  return "$status"
}

case "$CMD" in
  sync) each_copy sync ;;
  check) each_copy check ;;
  contrast)
    if [ -n "$MD" ]; then
      python3 -I "$DIR/design-contrast.py" "$DS/tokens.css" "$DS/contrast-pairs.tsv" --md
    else
      python3 -I "$DIR/design-contrast.py" "$DS/tokens.css" "$DS/contrast-pairs.tsv"
    fi
    ;;
  *) usage ;;
esac
