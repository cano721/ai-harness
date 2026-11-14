#!/usr/bin/env bash
# 워크플로 진입점(templates/managed-files.json의 mode:render 항목)을 템플릿에서 결정적으로 만들어 stdout에 낸다.
# 예전에는 LLM이 손으로 써서 결과가 흔들렸고(템플릿 줄이 빠진 채 남기도 했다) 자동 병합이 내용을 검증하지 못했다(#316).
# 같은 템플릿·카탈로그면 바이트 같은 결과를 낸다. 파일은 쓰지 않는다 — 배치는 place-managed-file.sh, 비교는 auto-merge.sh가 한다.
# - integration codex(.agents/skills/<wf>/SKILL.md): 템플릿 그대로
# - integration claude(.claude/commands/<wf>.md): frontmatter의 name 줄을 빼고 카탈로그 argument_hint를 넣는다.
#   첫 `## ` 앞의 시작 Read 목록(`N. `경로``)은 `N. @경로`로 바꿔 Claude가 바로 불러오게 하고, 끝에 `## Request`와 $ARGUMENTS를 붙인다
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$DIR/.." && pwd -P)"
TEMPLATES="$PLUGIN_ROOT/templates"
CATALOG="$TEMPLATES/managed-files.json"

usage() {
  printf 'usage: %s --path <카탈로그 render 경로>\n' "$0" >&2
  exit 2
}
fail() { printf 'render-managed-file: %s\n' "$1" >&2; exit 2; }

path=""
while (($#)); do
  case "$1" in
    --path) path="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$path" ]] || usage

entry="$(jq -c --arg p "$path" '[.artifacts[] | select(.path == $p and .mode == "render")] | if length == 1 then .[0] else empty end' "$CATALOG")"
[[ -n "$entry" ]] || fail "not a render artifact in the catalog: $path"
source_rel="$(jq -r '.source // empty' <<<"$entry")"
src="$PLUGIN_ROOT/$source_rel"
[[ -n "$source_rel" && -f "$src" && ! -L "$src" ]] || fail "template missing: $source_rel"
src="$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")"
case "$src" in "$TEMPLATES/"*) ;; *) fail "template outside plugin templates: $source_rel" ;; esac

case "$(jq -r '.integration // empty' <<<"$entry")" in
  codex) cat "$src" ;;
  claude)
    hint="$(jq -r '.argument_hint // empty' <<<"$entry")"
    [[ -n "$hint" ]] || fail "argument_hint missing in the catalog: $path"
    # awk -v는 백슬래시를 풀고, 따옴표는 YAML 문자열을 깬다
    case "$hint" in *'"'*|*\\*) fail "argument_hint must not contain quotes or backslashes: $path" ;; esac
    awk -v hint="$hint" '
      NR == 1 { if ($0 != "---") exit 3; fm = 1; print; next }
      fm == 1 && $0 == "---" { print "argument-hint: \"" hint "\""; print; fm = 2; next }
      fm == 1 && /^name:/ { next }
      fm == 2 && !body && /^## / { body = 1 }
      fm == 2 && !body && /^[0-9]+\. `[^`]+`$/ { sub(/`/, "@"); sub(/`$/, ""); print; next }
      { print }
      END { if (fm != 2) exit 3 }
    ' "$src" || fail "template has no frontmatter: $source_rel"
    printf '\n## Request\n\n%s\n' "\$ARGUMENTS"
    ;;
  *) fail "unknown integration for render: $path" ;;
esac
