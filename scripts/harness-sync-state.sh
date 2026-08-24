#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s <status|record|plan|forget> --root <project-root> [--catalog <catalog.json>] [--version <version>] [--file <relative-path>]...\n' "$0" >&2
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
catalog=""
files=()
while (($#)); do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --catalog) catalog="${2:-}"; shift 2 ;;
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
  plan)
    ((${#files[@]} == 0)) || usage
    [[ -n "$catalog" && -f "$catalog" ]] || {
      printf 'catalog not found: %s\n' "$catalog" >&2
      exit 2
    }
    level="$(jq -r '.level // ""' "$manifest")"
    integrations="$(jq -c '.integrations // []' "$manifest")"
    plan_items="$(
      while IFS= read -r artifact; do
        path="$(jq -r '.path' <<<"$artifact")"
        artifact_level="$(jq -r '.level // ""' <<<"$artifact")"
        integration="$(jq -r '.integration // ""' <<<"$artifact")"
        [[ "$artifact_level" == "$level" ]] || continue
        if [[ -n "$integration" ]] && ! jq -e --arg integration "$integration" 'index($integration)' <<<"$integrations" >/dev/null; then
          continue
        fi
        target="$root/$path"
        baseline="$(jq -r --arg path "$path" '.managed_files[$path].content_sha256 // ""' "$manifest")"
        state="missing"
        action="add"
        if [[ -f "$target" ]]; then
          current_sha="$(sha256_file "$target")"
          if [[ -z "$baseline" ]]; then
            state="untracked"
            action="approval_required"
          elif [[ "$current_sha" == "$baseline" ]]; then
            state="unchanged"
            action="refresh"
          else
            state="modified"
            action="approval_required"
          fi
        fi
        jq -cn --arg path "$path" --arg state "$state" --arg action "$action" \
          --arg source "$(jq -r '.source' <<<"$artifact")" --arg mode "$(jq -r '.mode' <<<"$artifact")" \
          --arg workflow "$(jq -r '.workflow // ""' <<<"$artifact")" \
          '{path:$path,state:$state,action:$action,source:$source,mode:$mode}
            + (if $workflow == "" then {} else {workflow: $workflow} end)'
      done < <(jq -c '.artifacts[]' "$catalog") | jq -s '.'
    )"
    # 새 진입점(add)이 생기면 보호 파일 쪽 후속 조치를 제안한다: 참조되는
    # 워크플로 본문 부재, AGENTS.md 커맨드 표 미등재. 제안일 뿐 자동 편집 근거가 아니다.
    suggestions="$(
      jq -r '[.[] | select(.action == "add") | .workflow // empty] | unique | .[]' <<<"$plan_items" \
        | while IFS= read -r workflow_name; do
            body_path=".ai-harness/workflows/$workflow_name.md"
            if [[ ! -f "$root/$body_path" ]]; then
              jq -cn --arg workflow "$workflow_name" --arg target "$body_path" \
                '{type:"workflow_body_missing",workflow:$workflow,target:$target,detail:"new entry point references a workflow body that does not exist yet; generate it from project policy (not tracked as managed)"}'
            fi
            if [[ -f "$root/AGENTS.md" ]] && ! grep -qF -- "/$workflow_name" "$root/AGENTS.md"; then
              jq -cn --arg workflow "$workflow_name" \
                '{type:"agents_md_reference",workflow:$workflow,target:"AGENTS.md",detail:"AGENTS.md does not reference the new entry point; propose a command-table row and edit only after user approval"}'
            fi
          done | jq -s '.'
    )"
    # 템플릿에서 빠진 생성물은 카탈로그를 순회하는 items에 절대 나타나지 않는다.
    # manifest에만 남은 항목을 따로 짚어 주지 않으면 낡은 사본이 프로젝트에 방치된다.
    retired="$(
      jq -r --slurpfile catalog "$catalog" '
        [$catalog[0].artifacts[].path] as $known
        | (.managed_files // {})
        | keys[] as $path
        | select($known | index($path) | not)
        | select($path != "" and ($path | startswith("/") | not) and ($path | contains("..") | not))
        | $path
      ' "$manifest" \
        | while IFS= read -r path; do
            present="false"
            if [[ -f "$root/$path" ]]; then
              present="true"
            fi
            jq -cn --arg path "$path" --argjson present "$present" \
              '{path:$path,present:$present,detail:"tracked in the manifest but no longer declared by the template catalog; confirm removal of the file and its manifest entry with the user"}'
          done | jq -s '.'
    )"
    jq -n --argjson items "$plan_items" --argjson suggestions "$suggestions" --argjson retired "$retired" \
      '{items: $items,
        counts: ($items | group_by(.action) | map({key: .[0].action, value: length}) | from_entries),
        suggestions: $suggestions,
        retired: $retired}'
    ;;
  forget)
    ((${#files[@]} > 0)) || usage
    temp_manifest="$(mktemp "${TMPDIR:-/tmp}/ai-harness-sync-state.XXXXXX")"
    trap 'rm -f "$temp_manifest"' EXIT
    cp "$manifest" "$temp_manifest"
    for path in "${files[@]}"; do
      case "$path" in
        ""|/*|*'..'*) printf 'invalid managed path: %s\n' "$path" >&2; exit 2 ;;
      esac
      next_manifest="$(mktemp "${TMPDIR:-/tmp}/ai-harness-sync-state.XXXXXX")"
      jq --arg path "$path" '
        .managed_files = ((.managed_files // {}) | del(.[$path]))
      ' "$temp_manifest" >"$next_manifest"
      mv "$next_manifest" "$temp_manifest"
    done
    mv "$temp_manifest" "$manifest"
    trap - EXIT
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
