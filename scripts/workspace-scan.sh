#!/usr/bin/env bash
# workspace 감지·매니페스트 기록. 여러 독립 git 저장소가 한 폴더에 있을 때 /harness-init이 쓴다.
#   scan  --root <dir> [--depth N]   : 후보 여부·멤버·기존 manifest와의 diff를 JSON으로
#   write --root <dir> [--depth N] [--workspace-id <id>] [--integrations a,b] [--version <v>]
#         : scan 결과로 .ai-harness/workspace.json을 기록 (생략한 값은 기존 manifest 유지)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

usage() {
  printf 'usage: %s <scan|write> --root <dir> [--depth N] [--workspace-id <id>] [--integrations a,b] [--version <v>]\n' "$0" >&2
  exit 2
}

command_name="${1:-}"
[[ -n "$command_name" ]] || usage
shift

root=""
depth=2
workspace_id=""
integrations=""
version=""
while (($#)); do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --depth) depth="${2:-}"; shift 2 ;;
    --workspace-id) workspace_id="${2:-}"; shift 2 ;;
    --integrations) integrations="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$root" && -d "$root" ]] || usage
[[ "$depth" =~ ^[0-9]+$ && "$depth" -ge 1 ]] || { printf 'depth must be a positive integer: %s\n' "$depth" >&2; exit 2; }
root="$(cd "$root" && pwd -P)"
manifest_path="$root/.ai-harness/workspace.json"

root_is_git=false
if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
  root_is_git=true
fi

# .git 디렉터리만 멤버 후보다. 서브모듈·worktree는 .git이 파일이라 제외되고,
# node_modules 아래는 의존성 저장소라 내려가지 않는다.
members='[]'
while IFS= read -r gitdir; do
  [[ -n "$gitdir" ]] || continue
  repo="${gitdir%/.git}"
  rel="${repo#"$root"/}"
  project_id="$(project_id_for_cwd "$repo")"
  member_manifest="$repo/.ai-harness/harness.json"
  if [[ -f "$member_manifest" ]] && entry="$(jq -c --arg path "$rel" --arg pid "$project_id" '{
        path: $path, project_id: (.project_id // $pid), harness: true,
        level: (.level // null), test_policy: (.test_policy // null),
        git_policy: (.git_policy // null), edit_guard: (.edit_guard // false)
      }' "$member_manifest" 2>/dev/null)"; then
    :
  else
    entry="$(jq -cn --arg path "$rel" --arg pid "$project_id" '{path: $path, project_id: $pid, harness: false}')"
  fi
  members="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$members")"
done < <(find "$root" -mindepth 2 -maxdepth "$((depth + 1))" \
  \( -name node_modules -prune -false \) -o \( -name .git -type d -prune -print \) 2>/dev/null | sort)

# 같은 저장소의 clone은 project_id가 같다. 하네스가 있는 쪽, 그다음 짧은 경로를 멤버로 삼고
# 나머지는 also_paths로 접는다.
members="$(jq -c 'group_by(.project_id)
  | map(sort_by([(.harness | not), (.path | length), .path])
        | .[0] + (if length > 1 then {also_paths: (.[1:] | map(.path))} else {} end))
  | sort_by(.path)' <<<"$members")"

existing='null'
if [[ -f "$manifest_path" ]]; then
  existing="$(jq -c '.' "$manifest_path" 2>/dev/null || printf 'null')"
fi

scan="$(jq -cn --arg root "$root" --argjson depth "$depth" --argjson root_is_git "$root_is_git" \
  --argjson members "$members" --argjson existing "$existing" '
  def key: {harness, level, test_policy, git_policy, edit_guard, project_id};
  ($existing.members // []) as $old
  | ($members | map(.path)) as $now_paths
  | ($old | map(.path)) as $old_paths
  | {
      root: $root, depth: $depth, root_is_git: $root_is_git,
      candidate: (($root_is_git | not) and ($members | length) >= 2),
      members: $members,
      manifest: $existing,
      diff: {
        added: ($now_paths - $old_paths),
        removed: ($old_paths - $now_paths),
        changed: [ $members[] as $m | $old[] | select(.path == $m.path and (key != ($m | key))) | .path ]
      }
    }')"

case "$command_name" in
  scan)
    printf '%s\n' "$scan"
    ;;
  write)
    if [[ "$root_is_git" == true ]]; then
      printf 'refusing to write a workspace manifest inside a git repository: %s\n' "$root" >&2
      exit 2
    fi
    if [[ -z "$version" ]]; then
      version="$(jq -r '.version // empty' "$DIR/../release.json" 2>/dev/null || true)"
    fi
    mkdir -p "$root/.ai-harness"
    tmp="$(mktemp "$root/.ai-harness/.workspace.XXXXXX")"
    if jq -n --argjson scan "$scan" --arg wid "$workspace_id" --arg integrations "$integrations" \
        --arg version "$version" --arg today "$(date +%Y-%m-%d)" --arg folder "$(basename "$root")" '
        ($scan.manifest // {}) as $old
        | {
            kind: "workspace",
            workspace_id: (if $wid != "" then $wid else ($old.workspace_id // $folder) end),
            integrations: (if $integrations != "" then ($integrations | split(",") | map(select(. != ""))) else ($old.integrations // []) end),
            members: $scan.members,
            initialized: ($old.initialized // $today),
            harness_version: (if $version != "" then $version else ($old.harness_version // null) end)
          }' > "$tmp"; then
      mv "$tmp" "$manifest_path"
      jq -c '.' "$manifest_path"
    else
      rm -f "$tmp"
      printf 'failed to write workspace manifest\n' >&2
      exit 1
    fi
    ;;
  *) usage ;;
esac
