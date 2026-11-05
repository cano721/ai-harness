#!/usr/bin/env bash
# workspace 감지·매니페스트 기록. 여러 독립 git 저장소가 한 폴더에 있을 때 /harness-init이 쓴다.
#   scan  --root <dir> [--depth N] [--fetch] [--base <branch>]   : 후보 여부·멤버·기존 manifest와의 diff를 JSON으로
#   write --root <dir> [--depth N] [--fetch] [--base <branch>] [--workspace-id <id>] [--integrations a,b] [--version <v>]
#         [--team-rules <git URL|경로> [--team-rules-ref <ref>]]
#         : scan 결과로 .ai-harness/workspace.json을 기록 (생략한 값은 기존 manifest 유지)
# 멤버 하네스는 원격 기준 브랜치의 harness.json을 먼저 읽는다. 기준은 --base(없으면 manifest의 base_branch)가
# 멤버 origin에 있으면 그 브랜치, 아니면 origin 기본 브랜치(origin/HEAD)다. 브랜치 이름을 추측하지 않는다.
# 멤버 체크아웃은 자주 뒤처져 있어 작업 트리만 읽으면 원격에 생긴 하네스를 놓친다.
# 워킹트리는 건드리지 않는다. --fetch는 멤버마다 git fetch origin을 먼저 한다(실패해도 계속).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

usage() {
  printf 'usage: %s <scan|write> --root <dir> [--depth N] [--fetch] [--base <branch>] [--workspace-id <id>] [--integrations a,b] [--version <v>] [--team-rules <source> [--team-rules-ref <ref>]]\n' "$0" >&2
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
fetch=false
base_branch=""
team_rules=""
team_rules_ref=""
while (($#)); do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --depth) depth="${2:-}"; shift 2 ;;
    --workspace-id) workspace_id="${2:-}"; shift 2 ;;
    --integrations) integrations="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --fetch) fetch=true; shift ;;
    --base) base_branch="${2:-}"; shift 2 ;;
    --team-rules) team_rules="${2:-}"; shift 2 ;;
    --team-rules-ref) team_rules_ref="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$root" && -d "$root" ]] || usage
if [[ -n "$base_branch" ]] && ! git check-ref-format --branch "$base_branch" >/dev/null 2>&1; then
  printf 'invalid base branch: %s\n' "$base_branch" >&2
  exit 2
fi
[[ "$depth" =~ ^[0-9]+$ && "$depth" -ge 1 ]] || { printf 'depth must be a positive integer: %s\n' "$depth" >&2; exit 2; }
root="$(cd "$root" && pwd -P)"
manifest_path="$root/.ai-harness/workspace.json"
existing='null'
if [[ -f "$manifest_path" ]]; then
  existing="$(jq -c '.' "$manifest_path" 2>/dev/null || printf 'null')"
fi
if [[ -z "$base_branch" ]]; then
  base_branch="$(jq -r '.base_branch // empty' <<<"$existing" 2>/dev/null || true)"
fi

root_is_git=false
if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
  root_is_git=true
fi

# .git 디렉터리만 멤버 후보다. 서브모듈·worktree는 .git이 파일이라 제외되고,
# node_modules 아래는 의존성 저장소라 내려가지 않는다.
# 멤버의 원격 기준 ref. 지정한 기준 브랜치가 멤버 origin에 있으면 그것, 없으면 origin 기본 브랜치.
member_base_ref() {
  local repo="$1" head=""
  if [[ -n "$base_branch" ]] && git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$base_branch" >/dev/null 2>&1; then
    printf 'origin/%s\n' "$base_branch"
    return
  fi
  if [[ -z "$(git -C "$repo" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)" && "$fetch" == true ]]; then
    git -C "$repo" remote set-head origin --auto >/dev/null 2>&1 || true
  fi
  head="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$head" ]] && git -C "$repo" rev-parse -q --verify "refs/remotes/$head" >/dev/null 2>&1; then
    printf '%s\n' "$head"
  fi
}

members='[]'
while IFS= read -r gitdir; do
  [[ -n "$gitdir" ]] || continue
  repo="${gitdir%/.git}"
  rel="${repo#"$root"/}"
  if [[ "$fetch" == true ]]; then
    git -C "$repo" fetch -q origin >/dev/null 2>&1 || true
  fi
  base_ref="$(member_base_ref "$repo")"
  behind='null'
  remote_manifest=""
  if [[ -n "$base_ref" ]]; then
    behind="$(git -C "$repo" rev-list --count "HEAD..$base_ref" 2>/dev/null || printf 'null')"
    remote_manifest="$(git -C "$repo" show "$base_ref:.ai-harness/harness.json" 2>/dev/null || true)"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$remote_manifest" || remote_manifest=""
  fi
  member_manifest="$repo/.ai-harness/harness.json"
  manifest_json=""
  manifest_ref=""
  if [[ -n "$remote_manifest" ]]; then
    manifest_json="$remote_manifest"
    manifest_ref="$base_ref"
  elif [[ -f "$member_manifest" ]] && jq -e 'type == "object"' "$member_manifest" >/dev/null 2>&1; then
    manifest_json="$(<"$member_manifest")"
    manifest_ref="worktree"
  fi
  project_id="$(project_id_for_cwd "$repo")"
  # id_source: 폴더명 폴백(path)은 실제 identity가 아니므로 clone 접기 대상에서 제외한다.
  # 그렇지 않으면 origin도 manifest도 없는 무관한 두 저장소가 폴더명이 같다는 이유로 하나로 접힌다.
  id_source="path"
  if [[ -n "$manifest_json" ]] && [[ -n "$(jq -r '.project_id // empty' <<<"$manifest_json" 2>/dev/null)" ]]; then
    id_source="manifest"
  elif [[ -n "$(git -C "$repo" remote get-url origin 2>/dev/null || true)" ]]; then
    id_source="origin"
  fi
  if [[ -n "$manifest_json" ]] && entry="$(jq -c --arg path "$rel" --arg pid "$project_id" --arg src "$id_source" \
      --arg mref "$manifest_ref" --arg bref "$base_ref" --argjson behind "$behind" '{
        path: $path, project_id: (.project_id // $pid), id_source: $src, harness: true,
        level: (.level // null), test_policy: (.test_policy // null),
        git_policy: (.git_policy // null), edit_guard: (.edit_guard // false),
        harness_version: (.harness_version // null), manifest_ref: $mref,
        base_ref: (if $bref == "" then null else $bref end), behind: $behind
      }' <<<"$manifest_json" 2>/dev/null)"; then
    :
  else
    entry="$(jq -cn --arg path "$rel" --arg pid "$project_id" --arg src "$id_source" \
      --arg bref "$base_ref" --argjson behind "$behind" \
      '{path: $path, project_id: $pid, id_source: $src, harness: false,
        base_ref: (if $bref == "" then null else $bref end), behind: $behind}')"
  fi
  members="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$members")"
done < <(find "$root" -mindepth 2 -maxdepth "$((depth + 1))" \
  \( -name node_modules -prune -false \) -o \( -name .git -type d -prune -print \) 2>/dev/null | sort)

# 1) 다른 멤버 안에 중첩된 .git(실수로 커밋된 vendor clone 등)은 그 멤버의 일부이지 별도 멤버가 아니다.
# 2) 같은 저장소의 clone은 project_id가 같다. 하네스가 있는 쪽, 그다음 짧은 경로를 멤버로 삼고
#    나머지는 also_paths로 접는다. 폴더명 폴백(id_source=path)은 identity가 아니므로 접지 않는다.
members="$(jq -c '
  . as $all
  | map(select(.path as $p | ($all | any(.path as $q | $q != $p and ($p | startswith($q + "/"))) | not)))
  | group_by(if .id_source == "path" then "path:" + .path else "id:" + .project_id end)
  | map(sort_by([(.harness | not), (.path | length), .path])
        | .[0] + (if length > 1 then {also_paths: (.[1:] | map(.path))} else {} end))
  | sort_by(.path)' <<<"$members")"

# workspace 세션의 subagent_type 위임은 멤버 페르소나가 아니라 같은 이름의 사용자 전역 페르소나로 갈 수 있다.
user_agents="${HM_USER_AGENTS_DIR:-$HOME/.claude/agents}"
shadows='[]'
while IFS= read -r path; do
  [[ -n "$path" && -d "$root/$path/.claude/agents" ]] || continue
  names='[]'
  for f in "$root/$path/.claude/agents"/*.md; do
    [[ -f "$f" && -f "$user_agents/${f##*/}" ]] || continue
    names="$(jq -c --arg n "$(basename "$f" .md)" '. + [$n]' <<<"$names")"
  done
  [[ "$names" == '[]' ]] || shadows="$(jq -c --arg m "$path" --argjson p "$names" '. + [{member:$m, personas:$p}]' <<<"$shadows")"
done < <(jq -r '.[] | select(.harness) | .path' <<<"$members")

scan="$(jq -cn --arg root "$root" --argjson depth "$depth" --argjson root_is_git "$root_is_git" \
  --argjson members "$members" --argjson existing "$existing" --argjson shadows "$shadows" --arg base "$base_branch" '
  def key: {harness, level, test_policy, git_policy, edit_guard, project_id};
  ($existing.members // []) as $old
  | ($members | map(.path)) as $now_paths
  | ($old | map(.path)) as $old_paths
  | {
      root: $root, depth: $depth, root_is_git: $root_is_git,
      candidate: (($root_is_git | not) and ($members | length) >= 2),
      base_branch: (if $base == "" then null else $base end),
      members: $members,
      persona_shadows: $shadows,
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
    # 첫 기록은 후보일 때만. 기존 manifest의 재기록(동기화)은 멤버가 줄어도 허용한다.
    if [[ "$existing" == null && "$(jq -r '.candidate' <<<"$scan")" != true ]]; then
      printf 'refusing to create a workspace manifest: fewer than two independent repositories under %s\n' "$root" >&2
      exit 2
    fi
    if [[ -z "$version" ]]; then
      version="$(jq -r '.version // empty' "$DIR/../release.json" 2>/dev/null || true)"
    fi
    mkdir -p "$root/.ai-harness"
    tmp="$(mktemp "$root/.ai-harness/.workspace.XXXXXX")"
    if jq -n --argjson scan "$scan" --arg wid "$workspace_id" --arg integrations "$integrations" \
        --arg version "$version" --arg today "$(date +%Y-%m-%d)" --arg folder "$(basename "$root")" \
        --arg team_rules "$team_rules" --arg team_rules_ref "$team_rules_ref" '
        ($scan.manifest // {}) as $old
        | {
            kind: "workspace",
            workspace_id: (if $wid != "" then $wid else ($old.workspace_id // $folder) end),
            integrations: (if $integrations != "" then ($integrations | split(",") | map(select(. != ""))) else ($old.integrations // []) end),
            members: $scan.members,
            base_branch: $scan.base_branch,
            initialized: ($old.initialized // $today),
            harness_version: (if $version != "" then $version else ($old.harness_version // null) end)
          }
        # 팀 규칙 원본 표식: 지정하면 바꾸고, 생략하면 기존 값을 유지한다.
        + (if $team_rules != "" then {team_rules: ({source: $team_rules} + (if $team_rules_ref != "" then {ref: $team_rules_ref} else {} end))}
           elif $old.team_rules then {team_rules: $old.team_rules} else {} end)' > "$tmp"; then
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
