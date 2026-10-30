#!/usr/bin/env bash
# 기본 스킬 카탈로그(catalog/)를 사용자 전역 스킬 폴더에 선택 설치·관리한다.
# 플러그인 스킬로 두지 않는 이유: 플러그인 스킬은 개별로 끌 수 없어 쓰지 않는 도구(Jira 등)의 설명까지 매 세션에 실린다.
# 설치한 사본은 해시로 추적한다 — 손대지 않은 사본만 자동 갱신하고, 사용자가 고쳤거나 원래 있던 같은 이름 스킬은 건드리지 않는다.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

CATALOG_DIR="${HM_SETUP_CATALOG_DIR:-$ROOT/catalog}"
CATALOG="$CATALOG_DIR/catalog.json"
STATE_DIR="$HM_DATA_DIR/setup"
STATE="$STATE_DIR/state.json"
LOCK="$STATE_DIR/.lock"
CLAUDE_SETTINGS="${HARNESS_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

usage() {
  cat >&2 <<'EOF'
usage: setup.sh list
       setup.sh install --tool claude|codex|both [--replace] <skill>...
       setup.sh remove --tool claude|codex|both [--force] <skill>...
       setup.sh update [--tool claude|codex|both]
       setup.sh done
       setup.sh notify < SessionStart input
EOF
  exit 2
}

skills_dir() {
  case "$1" in
    claude) printf '%s\n' "${HM_CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" ;;
    codex) printf '%s\n' "${HM_CODEX_SKILLS_DIR:-$HOME/.agents/skills}" ;;
  esac
}

tools_for() {
  case "$1" in
    claude | codex) printf '%s\n' "$1" ;;
    both) printf '%s\n' claude codex ;;
    *) printf 'unknown tool: %s\n' "$1" >&2; exit 2 ;;
  esac
}

sha256_stdin() { { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}'; }

# 폴더 내용 해시: 상대 경로와 파일 해시 목록의 해시. .DS_Store 같은 OS 부산물은 뺀다.
tree_sha() {
  (
    cd "$1"
    find . -type f ! -name '.DS_Store' | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$f" "$(sha256_stdin <"$f")"
    done
  ) | sha256_stdin
}

catalog_names() { jq -r '.skills[].name' "$CATALOG"; }
in_catalog() { jq -e --arg n "$1" 'any(.skills[]; .name == $n)' "$CATALOG" >/dev/null; }
catalog_version() { jq -r '.version' "$CATALOG"; }

read_state() {
  if [[ -f "$STATE" ]] && jq -e 'type == "object"' "$STATE" >/dev/null 2>&1; then
    cat "$STATE"
  else
    printf '{}\n'
  fi
}

write_state() { # stdin = new state
  local tmp="$STATE.tmp.$$"
  mkdir -p "$STATE_DIR"
  cat >"$tmp" && mv "$tmp" "$STATE"
}

record_sha() { read_state | jq -r --arg k "$1:$2" '.installed[$k].sha // ""'; }

# absent | current | outdated(관리 사본, 카탈로그가 더 새로움) | modified(관리 사본을 사용자가 고침) | foreign(우리가 깔지 않음)
skill_status() { # tool name
  local target recorded current
  target="$(skills_dir "$1")/$2"
  [[ -d "$target" ]] || { printf 'absent\n'; return; }
  recorded="$(record_sha "$1" "$2")"
  [[ -n "$recorded" ]] || { printf 'foreign\n'; return; }
  current="$(tree_sha "$target")"
  if [[ "$current" != "$recorded" ]]; then
    printf 'modified\n'
  elif [[ "$current" == "$(tree_sha "$CATALOG_DIR/$2")" ]]; then
    printf 'current\n'
  else
    printf 'outdated\n'
  fi
}

# 키 값은 읽지 않고 어디에 있는지만 본다: 프로세스 환경 → Claude settings.json env.
env_source() {
  local key="$1"
  if [[ -n "${!key:-}" ]]; then
    printf 'env\n'
  elif [[ -f "$CLAUDE_SETTINGS" ]] && jq -e --arg k "$key" '(.env[$k] // "") != ""' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
    printf 'settings\n'
  else
    printf 'missing\n'
  fi
}

env_report() { # name → [{keys, required, note, found:<key|null>, source}]
  local entries out='[]' entry key src found source
  entries="$(jq -c --arg n "$1" '.skills[] | select(.name == $n) | .env[]?' "$CATALOG")"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    found=""; source="missing"
    while IFS= read -r key; do
      src="$(env_source "$key")"
      if [[ "$src" != missing ]]; then found="$key"; source="$src"; break; fi
    done < <(jq -r '.any[]' <<<"$entry")
    out="$(jq -c --argjson e "$entry" --arg f "$found" --arg s "$source" \
      '. + [{keys:$e.any, required:($e.required // false), note:($e.note // null), found:(if $f == "" then null else $f end), source:$s}]' <<<"$out")"
  done <<<"$entries"
  printf '%s\n' "$out"
}

command_list() {
  local name tool status
  while IFS= read -r name; do
    local statuses='{}'
    for tool in claude codex; do
      status="$(skill_status "$tool" "$name")"
      statuses="$(jq -c --arg t "$tool" --arg s "$status" '. + {($t):$s}' <<<"$statuses")"
    done
    jq -cn --arg n "$name" --argjson st "$statuses" --argjson env "$(env_report "$name")" --slurpfile c "$CATALOG" \
      '($c[0].skills[] | select(.name == $n)) as $s | {name:$n, summary:$s.summary, status:$st, env:$env}'
  done < <(catalog_names)
}

copy_skill() { # tool name
  local dest tmp
  dest="$(skills_dir "$1")/$2"
  # 중간 사본을 스킬 폴더 밖에 둔다 — 중단돼 남아도 같은 이름 스킬이 둘 로드되지 않게.
  tmp="$STATE_DIR/tmp/$1-$2.$$"
  mkdir -p "$(skills_dir "$1")" "$STATE_DIR/tmp"
  rm -rf "$tmp"
  cp -R "$CATALOG_DIR/$2" "$tmp"
  rm -rf "$dest"
  mv "$tmp" "$dest"
  read_state | jq --arg k "$1:$2" --arg sha "$(tree_sha "$dest")" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.installed[$k] = {sha:$sha, at:$now}' | write_state
}

backup_skill() { # tool name → 백업 경로 출력
  local src backup
  src="$(skills_dir "$1")/$2"
  backup="$STATE_DIR/backups/$1-$2-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$STATE_DIR/backups"
  mv "$src" "$backup"
  printf '%s\n' "$backup"
}

forget_skill() { read_state | jq --arg k "$1:$2" 'del(.installed[$k])' | write_state; }

result() { jq -cn --arg tool "$1" --arg name "$2" --arg action "$3" --arg detail "${4:-}" \
  '{tool:$tool, name:$name, action:$action} + (if $detail == "" then {} else {detail:$detail} end)'; }

parse_tool_args() { # 공용 인자 파서: TOOL, FLAG, NAMES
  TOOL=""; FLAG=0; NAMES=()
  while (($#)); do
    case "$1" in
      --tool) TOOL="${2:-}"; shift 2 ;;
      --replace | --force) FLAG=1; shift ;;
      -*) usage ;;
      *) NAMES+=("$1"); shift ;;
    esac
  done
}

command_install() {
  parse_tool_args "$@"
  [[ -n "$TOOL" && ${#NAMES[@]} -gt 0 ]] || usage
  local name tool status backup
  for name in "${NAMES[@]}"; do
    in_catalog "$name" || { result "-" "$name" "unknown"; continue; }
    while IFS= read -r tool; do
      status="$(skill_status "$tool" "$name")"
      case "$status" in
        current) result "$tool" "$name" "unchanged" ;;
        absent | outdated) copy_skill "$tool" "$name"; result "$tool" "$name" "$([[ $status == absent ]] && echo installed || echo updated)" ;;
        modified | foreign)
          if ((FLAG)); then
            backup="$(backup_skill "$tool" "$name")"
            copy_skill "$tool" "$name"
            result "$tool" "$name" "replaced" "$backup"
          else
            result "$tool" "$name" "skipped" "$status"
          fi
          ;;
      esac
    done < <(tools_for "$TOOL")
  done
}

command_remove() {
  parse_tool_args "$@"
  [[ -n "$TOOL" && ${#NAMES[@]} -gt 0 ]] || usage
  local name tool status backup dir
  for name in "${NAMES[@]}"; do
    in_catalog "$name" || { result "-" "$name" "unknown"; continue; }
    while IFS= read -r tool; do
      status="$(skill_status "$tool" "$name")"
      case "$status" in
        absent) forget_skill "$tool" "$name"; result "$tool" "$name" "absent" ;;
        current | outdated)
          dir="$(skills_dir "$tool")"
          rm -rf "${dir:?}/$name"
          forget_skill "$tool" "$name"
          result "$tool" "$name" "removed"
          ;;
        modified)
          if ((FLAG)); then
            backup="$(backup_skill "$tool" "$name")"
            forget_skill "$tool" "$name"
            result "$tool" "$name" "removed" "$backup"
          else
            result "$tool" "$name" "skipped" "modified"
          fi
          ;;
        foreign) result "$tool" "$name" "skipped" "foreign" ;;
      esac
    done < <(tools_for "$TOOL")
  done
}

# 손대지 않은 관리 사본만 카탈로그에 맞춘다. 갱신한 이름을 줄마다 출력.
refresh_outdated() { # tools...
  local key tool name
  while IFS= read -r key; do
    tool="${key%%:*}"; name="${key#*:}"
    [[ "$tool" == claude || "$tool" == codex ]] || continue
    if [[ $# -gt 0 && " $* " != *" $tool "* ]]; then continue; fi
    in_catalog "$name" || continue
    if [[ "$(skill_status "$tool" "$name")" == outdated ]]; then
      copy_skill "$tool" "$name"
      printf '%s\n' "$name"
    fi
  done < <(read_state | jq -r '.installed // {} | keys[]')
}

command_update() {
  parse_tool_args "$@"
  local tools=() name
  if [[ -n "$TOOL" ]]; then
    while IFS= read -r name; do tools+=("$name"); done < <(tools_for "$TOOL")
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] && result "-" "$name" "updated"
  done < <(refresh_outdated "${tools[@]+"${tools[@]}"}")
  return 0
}

command_done() {
  read_state | jq --argjson v "$(catalog_version)" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.catalog_version = $v | .done_at = $now' | write_state
  jq -cn --argjson v "$(catalog_version)" '{catalog_version:$v}'
}

# SessionStart: 관리 사본 갱신 + 셋업 안내. 안내는 카탈로그 버전마다 한 번만.
command_notify() {
  local input transcript seen shown version refreshed="" new_names messages=() setup_cmd
  input="$(cat)"
  [[ -f "$CATALOG" ]] || return 0
  mkdir -p "$STATE_DIR"
  hm_acquire_lock "$LOCK" 1 || return 0
  trap 'hm_release_lock "$LOCK"' EXIT

  refreshed="$(refresh_outdated 2>/dev/null | sort -u | paste -sd, - | sed 's/,/, /g' || true)"
  [[ -n "$refreshed" ]] && messages+=("ai-harness 기본 스킬을 새 버전으로 갱신했습니다: $refreshed")

  transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null || true)"
  setup_cmd="/ai-harness:setup"
  [[ "$(basename "${transcript:-x}")" == rollout-*.jsonl ]] && setup_cmd="ai-harness setup 스킬"
  version="$(catalog_version)"
  seen="$(read_state | jq -r '.catalog_version // 0')"
  shown="$(sed -n '1p' "$STATE_DIR/hint-shown" 2>/dev/null || true)"
  [[ "$shown" =~ ^[0-9]+$ ]] || shown=0
  if [[ "${HM_SETUP_HINT:-1}" != "0" ]] && ((version > seen && version > shown)); then
    if ((seen == 0)); then
      messages+=("ai-harness 기본 스킬($(catalog_names | paste -sd, - | sed 's/,/·/g'))을 골라 설치하려면 $setup_cmd 을 실행하세요. (이 안내는 한 번만 표시됩니다)")
    else
      new_names="$(jq -r --argjson s "$seen" '[.skills[] | select((.since // 1) > $s) | .name] | join(", ")' "$CATALOG")"
      [[ -n "$new_names" ]] && messages+=("ai-harness에 새 기본 스킬이 추가됐습니다: $new_names. 설치하려면 $setup_cmd 을 실행하세요.")
    fi
    printf '%s\n' "$version" >"$STATE_DIR/hint-shown"
  fi

  if ((${#messages[@]} > 0)); then
    jq -cn --arg m "$(IFS=$'\n'; printf '%s' "${messages[*]}")" '{systemMessage:$m}'
  fi
}

with_lock() {
  mkdir -p "$STATE_DIR"
  hm_acquire_lock "$LOCK" || { printf 'setup state busy: %s\n' "$LOCK" >&2; exit 1; }
  trap 'hm_release_lock "$LOCK"' EXIT
  "$@"
}

cmd="${1:-}"
(($#)) && shift
case "$cmd" in
  list) command_list ;;
  install) with_lock command_install "$@" ;;
  remove) with_lock command_remove "$@" ;;
  update) with_lock command_update "$@" ;;
  done) with_lock command_done ;;
  notify) command_notify ;;
  *) usage ;;
esac
