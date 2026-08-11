#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s <status|record> --root <project-root> [--version <version>] [--file <relative-path>]...\n' "$0" >&2
  exit 2
}

sha256_file() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' && return
  sha256sum "$1" | awk '{print $1}'
}

command_name="${1:-}"
[[ -n "$command_name" ]] || usage
shift

root=""
version=""
files=()
while (($#)); do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --file) files+=("${2:-}"); shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$root" && -d "$root" ]] || usage
root="$(cd "$root" && pwd -P)"
manifest="$root/.ai-harness/harness.json"
[[ -f "$manifest" ]] || {
  printf 'harness manifest not found: %s\n' "$manifest" >&2
  exit 2
}

case "$command_name" in
  status)
    ((${#files[@]} == 0)) || usage
    jq -r '.managed_files // {} | to_entries[] | [.key, (.value.content_sha256 // ""), (.value.template_version // "")] | @tsv' "$manifest" \
      | while IFS=$'\t' read -r path baseline_sha template_version; do
          case "$path" in
            ""|/*|*'..'*) continue ;;
          esac
          target="$root/$path"
          if [[ ! -f "$target" ]]; then
            jq -cn --arg path "$path" --arg template_version "$template_version" \
              '{path:$path,state:"missing",template_version:$template_version}'
            continue
          fi
          current_sha="$(sha256_file "$target")"
          state="modified"
          [[ "$current_sha" == "$baseline_sha" ]] && state="unchanged"
          jq -cn --arg path "$path" --arg state "$state" --arg template_version "$template_version" \
            --arg current_sha "$current_sha" '{path:$path,state:$state,template_version:$template_version,current_sha256:$current_sha}'
        done | jq -s '.'
    ;;
  record)
    [[ -n "$version" && ${#files[@]} -gt 0 ]] || usage
    mkdir -p "$(dirname "$manifest")"
    temp_manifest="$(mktemp "${TMPDIR:-/tmp}/ai-harness-sync-state.XXXXXX")"
    trap 'rm -f "$temp_manifest"' EXIT
    cp "$manifest" "$temp_manifest"
    for path in "${files[@]}"; do
      case "$path" in
        ""|/*|*'..'*) printf 'invalid managed path: %s\n' "$path" >&2; exit 2 ;;
      esac
      target="$root/$path"
      [[ -f "$target" ]] || {
        printf 'managed file not found: %s\n' "$target" >&2
        exit 2
      }
      checksum="$(sha256_file "$target")"
      next_manifest="$(mktemp "${TMPDIR:-/tmp}/ai-harness-sync-state.XXXXXX")"
      jq --arg version "$version" --arg path "$path" --arg checksum "$checksum" '
        .harness_version = $version
        | .managed_files = (.managed_files // {})
        | .managed_files[$path] = {
            content_sha256: $checksum,
            template_version: $version
          }
      ' "$temp_manifest" >"$next_manifest"
      mv "$next_manifest" "$temp_manifest"
    done
    mv "$temp_manifest" "$manifest"
    trap - EXIT
    ;;
  *) usage ;;
esac
