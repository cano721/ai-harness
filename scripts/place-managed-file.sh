#!/usr/bin/env bash
# harness-init(대화형·무인 sync)이 관리 생성물을 템플릿에서 옮기는 경로.
# 무인 실행의 허용 목록에는 셸 복사가 없고, 큰 실행 스크립트(workflow-driver.sh 1천 줄 이상)를 Read 후 Write로
# 옮겨 적으면 틀어질 수 있어 에이전트가 건너뛰었다 — 그래서 자동 sync 대부분이 일부 적용으로 끝났다.
# - 경로는 플러그인 카탈로그(templates/managed-files.json)의 mode:copy·render 항목만 받는다. 원본은 카탈로그가 정하고 호출자가 고르지 못한다
# - copy는 템플릿 바이트 그대로, render(워크플로 진입점)는 render-managed-file.sh 결과를 쓴다(#316)
# - manifest에 renderer 표시가 없는 기존 render(예전 손 렌더)는 저장소 맞춤이 있을 수 있어 --first-render 없이는 덮어쓰지 않는다
# - .claude/ 아래도 같은 방식으로 쓴다(보호 경로라 Write가 막힌다). 카탈로그에 없는 settings·hook은 받지 않는다
# - 덮어쓰기는 harness.json에 기록된 해시와 지금 내용이 같은(사람이 고치지 않은) 파일만 한다. 없는 파일은 새로 만든다
# - 실행 비트는 템플릿을 따른다
# - 하나라도 거부되면 아무것도 만들거나 쓰지 않는다(종료 코드 2)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$DIR/.." && pwd -P)"
TEMPLATES="$PLUGIN_ROOT/templates"
CATALOG="$TEMPLATES/managed-files.json"

usage() {
  printf 'usage: %s --root <project-root> --path <카탈로그 경로> [--path <카탈로그 경로>]... [--first-render]\n' "$0" >&2
  exit 2
}
fail() { printf 'place-managed-file: %s\n' "$1" >&2; exit 2; }
sha256_of() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | awk '{print $1}'; }

root="" paths=() first_render=0
while (($#)); do
  case "$1" in
    --root) (($# >= 2)) || usage; root="$2"; shift 2 ;;
    --path) (($# >= 2)) || usage; paths+=("$2"); shift 2 ;;
    --first-render) first_render=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$root" && -d "$root" && ${#paths[@]} -gt 0 ]] || usage
root="$(cd "$root" && pwd -P)"
manifest="$root/.ai-harness/harness.json"

kinds=() srcs=() dests=()
for path in "${paths[@]}"; do
  case "$path" in
    ""|*..*|/*) fail "invalid path: $path" ;;
  esac
  kind="$(jq -r --arg p "$path" '[.artifacts[] | select(.path == $p and (.mode == "copy" or .mode == "render")) | .mode] | if length == 1 then .[0] else empty end' "$CATALOG")"
  [[ -n "$kind" ]] || fail "not a managed artifact in the catalog: $path"
  src=""
  if [[ "$kind" == render ]]; then
    # 렌더가 실패할 항목이 있으면 아무것도 쓰기 전에 거부한다. 결과는 아래에서 대상 옆 임시 파일에 바로 렌더한다
    "$DIR/render-managed-file.sh" --path "$path" >/dev/null || fail "render failed: $path"
  else
    source_rel="$(jq -r --arg p "$path" 'first(.artifacts[] | select(.path == $p and .mode == "copy") | .source)' "$CATALOG")"
    src="$PLUGIN_ROOT/$source_rel"
    [[ -f "$src" && ! -L "$src" ]] || fail "template missing: $source_rel"
    src="$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")"
    case "$src" in "$TEMPLATES/"*) ;; *) fail "template outside plugin templates: $source_rel" ;; esac
  fi

  # 저장소 안 디렉토리가 심볼릭 링크로 밖을 가리키면 거기에 쓰게 된다. 이미 있는 가장 가까운 조상을 실제 경로로 풀어 본다
  # (mkdir -p는 링크를 따라가 밖에 디렉토리를 만들므로 만들기 전에 확인한다).
  existing="$root/$(dirname "$path")"
  while [[ ! -e "$existing" && ! -L "$existing" ]]; do existing="$(dirname "$existing")"; done
  [[ -d "$existing" ]] || fail "target parent is not a directory: $path"
  case "$(cd "$existing" && pwd -P)/" in "$root/"*) ;; *) fail "target escapes the project: $path" ;; esac
  dest="$root/$path"
  [[ ! -L "$dest" ]] || fail "target is a symlink: $path"
  [[ ! -d "$dest" ]] || fail "target is a directory: $path"
  same=0
  if [[ -f "$dest" ]]; then
    if [[ "$kind" == render ]]; then
      if cmp -s "$dest" <("$DIR/render-managed-file.sh" --path "$path"); then same=1; fi
    elif cmp -s "$src" "$dest"; then
      same=1
    fi
  fi
  if [[ -f "$dest" ]] && (( same == 0 )); then
    recorded="$(jq -r --arg p "$path" '.managed_files[$p].content_sha256? // empty' "$manifest" 2>/dev/null || true)"
    [[ -n "$recorded" ]] || fail "existing file is not a recorded managed file (untracked): $path"
    [[ "$(sha256_of "$dest")" == "$recorded" ]] || fail "existing file was modified since it was recorded: $path"
    # 표시 없는 render 기록은 예전 손 렌더라 저장소 맞춤이 들어 있을 수 있다. 첫 결정적 render는 사람이 diff를 본 뒤에만
    # (--first-render) 덮어쓴다(#316).
    if [[ "$kind" == render && "$first_render" != 1 ]] \
      && [[ "$(jq -r --arg p "$path" '.managed_files[$p].renderer? // empty' "$manifest" 2>/dev/null || true)" != 1 ]]; then
      fail "first deterministic render needs a person (no renderer mark; rerun with --first-render after review): $path"
    fi
  fi
  kinds+=("$kind")
  srcs+=("$src")
  dests+=("$dest")
done

# 모든 임시 파일을 먼저 만든 뒤 한꺼번에 옮긴다. 임시 파일은 mktemp로 새로 만들어 미리 놓인 링크를 따라가지 않는다.
# tmps는 paths와 인덱스가 1:1이다(render와 copy를 섞어도 어긋나지 않게 다른 임시 파일을 넣지 않는다).
tmps=()
cleanup() { local t; for t in ${tmps[@]+"${tmps[@]}"}; do rm -f "$t"; done; }
trap cleanup EXIT
i=0
while (( i < ${#paths[@]} )); do
  mkdir -p "$(dirname "${dests[$i]}")"
  tmp="$(mktemp "$(dirname "${dests[$i]}")/.place.XXXXXX")"
  tmps+=("$tmp")
  if [[ "${kinds[$i]}" == render ]]; then
    "$DIR/render-managed-file.sh" --path "${paths[$i]}" >"$tmp" || fail "render failed: ${paths[$i]}"
    chmod 644 "$tmp"
  else
    cp "${srcs[$i]}" "$tmp"
    if [[ -x "${srcs[$i]}" ]]; then chmod 755 "$tmp"; else chmod 644 "$tmp"; fi
  fi
  i=$((i + 1))
done
i=0
while (( i < ${#paths[@]} )); do
  mv -f "${tmps[$i]}" "${dests[$i]}"
  printf 'placed %s\n' "${paths[$i]}"
  i=$((i + 1))
done
