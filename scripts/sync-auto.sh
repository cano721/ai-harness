#!/usr/bin/env bash
# 저장소에 깔린 하네스 생성물이 플러그인보다 뒤처졌는지 판정한다. 플러그인은 마켓플레이스 auto-update로
# 최신이 되지만 각 저장소의 생성물·harness_version은 /harness-init --sync를 돌려야만 따라온다.
#   outdated: 자동 sync(harvest-auto.sh sweep, opt-in HM_SYNC_AUTO=1)의 후보 목록
#   notify:   SessionStart 알림. 같은 저장소·플러그인 버전 조합은 한 번만
#   repos:    세션 기록에 나온 하네스 저장소 전부(버전 무관) — 자동 버그 수정(autofix-auto.sh)의 대상 목록
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

SYNC_DIR="$HM_DATA_DIR/sync-auto"

usage() {
  cat >&2 <<'EOF'
usage:
  sync-auto.sh outdated [--fetch] [--root <dir>]...   # 뒤처진 하네스 저장소(JSON lines). --root 없으면 세션 기록에서 찾는다
  sync-auto.sh notify                                  # SessionStart hook 입력(stdin)의 cwd 기준 알림
  sync-auto.sh repos [--root <dir>]...                 # 하네스 저장소(JSON lines: repo, project, base, manifest)
EOF
  exit 2
}

plugin_version() {
  jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null \
    || jq -r '.version // empty' "$ROOT/.codex-plugin/plugin.json" 2>/dev/null
}

# 같은 저장소의 worktree·하위 디렉토리를 원본 체크아웃 하나로 접는다. 경로 비교는 NFC로 한다(macOS 한글 경로).
main_checkout() { # $1=dir → 원본 체크아웃 경로(없으면 빈 출력)
  local common=""
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 0
  [[ "$common" == /* ]] || common="$1/$common"
  common="$(cd "$common" 2>/dev/null && pwd -P)" || return 0
  [[ "${common##*/}" == ".git" ]] && printf '%s\n' "${common%/*}"
}

# 세션 기록에 나온 작업 경로와, 그 경로가 workspace 루트이면 멤버까지.
discover_dirs() {
  local cwd="" member=""
  while IFS= read -r cwd; do
    [[ -d "$cwd" ]] || continue
    printf '%s\n' "$cwd"
    [[ -f "$cwd/.ai-harness/workspace.json" ]] || continue
    while IFS= read -r member; do
      [[ -n "$member" ]] && printf '%s\n' "$cwd/$member"
    done < <(jq -r '.members[]?.path // empty' "$cwd/.ai-harness/workspace.json" 2>/dev/null)
  done < <(grep -ho '"cwd":"[^"]*"' "$HM_DATA_DIR"/events/*.jsonl 2>/dev/null | sort -u \
    | jq -Rr '("{" + . + "}" | fromjson? | .cwd) // empty' 2>/dev/null)
}

command_outdated() {
  local fetch="--no-fetch" plugin="" dir="" repo="" base="" manifest="" version="" project=""
  local -a roots=()
  while (( $# > 0 )); do
    case "$1" in
      --fetch) fetch=""; shift ;;
      --root) [[ -n "${2:-}" ]] || usage; roots+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  plugin="$(plugin_version)"
  [[ -n "$plugin" ]] || return 0
  local seen=$'\n'
  while IFS= read -r dir; do
    repo="$(main_checkout "$dir")"
    [[ -n "$repo" && "$seen" != *$'\n'"$(hm_nfc "$repo")"$'\n'* ]] || continue
    seen+="$(hm_nfc "$repo")"$'\n'
    base="$(hm_resolve_base "$repo" ${fetch:+"$fetch"})"
    # 사용자 체크아웃이 아니라 하네스가 실제로 들어 있는 기준 브랜치의 버전을 본다.
    manifest="$(git -C "$repo" show "$base:.ai-harness/harness.json" 2>/dev/null)" || continue
    version="$(jq -r '.harness_version // empty' <<<"$manifest" 2>/dev/null)"
    [[ -n "$version" ]] || continue
    hm_version_lt "$version" "$plugin" || continue
    project="$(jq -r '.project_id // empty' <<<"$manifest" 2>/dev/null)"
    [[ -n "$project" ]] || project="$(project_id_for_cwd "$repo")"
    # 같은 저장소의 별도 clone은 한 프로젝트다. 먼저 찾은 체크아웃 하나로만 sync한다.
    [[ "$seen" != *$'\n'"project:$project"$'\n'* ]] || continue
    seen+="project:$project"$'\n'
    jq -cn --arg repo "$repo" --arg project "$project" --arg base "$base" --arg version "$version" --arg plugin "$plugin" \
      '{repo:$repo,project:$project,base:$base,version:$version,plugin:$plugin}'
  done < <(if (( ${#roots[@]} > 0 )); then printf '%s\n' "${roots[@]}"; else discover_dirs; fi)
}

command_repos() {
  local dir="" repo="" base="" manifest="" project="" seen=$'\n'
  local -a roots=()
  while (( $# > 0 )); do
    case "$1" in
      --root) [[ -n "${2:-}" ]] || usage; roots+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  while IFS= read -r dir; do
    repo="$(main_checkout "$dir")"
    [[ -n "$repo" && "$seen" != *$'\n'"$(hm_nfc "$repo")"$'\n'* ]] || continue
    seen+="$(hm_nfc "$repo")"$'\n'
    base="$(hm_resolve_base "$repo" --no-fetch)"
    manifest="$(git -C "$repo" show "$base:.ai-harness/harness.json" 2>/dev/null | jq -c . 2>/dev/null)" || continue
    [[ -n "$manifest" ]] || continue
    project="$(jq -r '.project_id // empty' <<<"$manifest")"
    [[ -n "$project" ]] || project="$(project_id_for_cwd "$repo")"
    [[ "$seen" != *$'\n'"project:$project"$'\n'* ]] || continue
    seen+="project:$project"$'\n'
    jq -cn --arg repo "$repo" --arg project "$project" --arg base "$base" --argjson manifest "$manifest" \
      '{repo:$repo,project:$project,base:$base,manifest:$manifest}'
  done < <(if (( ${#roots[@]} > 0 )); then printf '%s\n' "${roots[@]}"; else discover_dirs; fi)
}

# SessionStart 3초 예산 안에서 돈다: 네트워크 없이 로컬에 있는 기준 브랜치 ref의 manifest를 본다 —
# 자동 sync와 같은 기준이라, 오래된 기능 브랜치 체크아웃 때문에 틀린 안내를 하지 않는다.
command_notify() {
  local input="" cwd="" plugin="" root="" file="" kind="" version="" key="" marker="" message=""
  input="$(cat)"
  cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
  [[ -n "$cwd" && -d "$cwd" ]] || return 0
  plugin="$(plugin_version)"
  [[ -n "$plugin" ]] || return 0
  if [[ -f "$cwd/.ai-harness/workspace.json" ]]; then
    root="$cwd"; file="$cwd/.ai-harness/workspace.json"; kind="workspace"
  else
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || return 0
    file="$root/.ai-harness/harness.json"; kind="project"
  fi
  if [[ "$kind" == "workspace" ]]; then
    version="$(jq -r '.harness_version // empty' "$file" 2>/dev/null)"
  else
    version="$(git -C "$root" show "$(hm_resolve_base "$root" --no-fetch):.ai-harness/harness.json" 2>/dev/null \
      | jq -r '.harness_version // empty' 2>/dev/null)"
  fi
  [[ -n "$version" ]] || return 0
  hm_version_lt "$version" "$plugin" || return 0

  key="$(hm_short_key "$(project_id_for_cwd "$root")")"
  marker="$SYNC_DIR/notified/$key-$plugin"
  [[ -e "$marker" ]] && return 0
  { mkdir -p "${marker%/*}" && : >"$marker"; } 2>/dev/null || return 0

  if [[ "$kind" == "workspace" ]]; then
    message="ai-harness: 이 workspace 하네스(매니페스트·AGENTS.md 라우팅)는 ${version}, 플러그인은 ${plugin}입니다. workspace 루트에서 /harness-init --sync --apply 로 맞추세요."
  elif [[ "${HM_SYNC_AUTO:-0}" == "1" ]]; then
    message="ai-harness: 이 저장소 하네스 생성물은 ${version}, 플러그인은 ${plugin}입니다. 자동 sync(HM_SYNC_AUTO=1)가 다음 정기 실행에서 기준 브랜치로 draft PR을 엽니다."
  else
    message="ai-harness: 이 저장소 하네스 생성물은 ${version}, 플러그인은 ${plugin}입니다. /harness-init --sync 로 갱신 계획을 보고 --apply 로 적용하세요. 자동으로 하려면 ~/.ai-harness/config에 HM_SYNC_AUTO=1 을 두세요 — 정기 실행이 draft PR을 엽니다."
  fi
  jq -cn --arg m "$message" '{systemMessage:$m}'
}

command="${1:-}"
shift || true
case "$command" in
  outdated) command_outdated "$@" ;;
  notify) command_notify ;;
  repos) command_repos "$@" ;;
  *) usage ;;
esac
