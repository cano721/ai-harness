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
# Codex는 settings.json env가 없으므로 셸 프로파일이 source하는 파일에 둔다.
SECRETS_FILE="$HM_DATA_DIR/secrets.env"
PROFILE_DIR="$HM_DATA_DIR/skills"
# 외부 디자인 스킬은 복사본을 두지 않고 원본 저장소의 고정 커밋에서 받는다.
DESIGN_CATALOG="${HM_SETUP_DESIGN_CATALOG:-$CATALOG_DIR/design-skills.json}"
GIT_BASE="${HM_SETUP_GIT_BASE:-https://github.com}"

usage() {
  cat >&2 <<'EOF'
usage: setup.sh list
       setup.sh install --tool claude|codex|both [--replace] <skill>...
       setup.sh remove --tool claude|codex|both [--force] <skill>...
       setup.sh update [--tool claude|codex|both]
       setup.sh set --tool claude|codex|both <KEY> [VALUE]   (secret 키는 VALUE 없이 숨김 입력)
       setup.sh check <skill>
       setup.sh detect <skill>
       setup.sh design list
       setup.sh design install --tool claude|codex|both [--replace] <skill|core|extra|all>...
       setup.sh design remove --tool claude|codex|both [--force] <skill>...   (이름만, 묶음 core|extra|all 아님)
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
# symlink와 빈 디렉터리도 넣는다 — 사용자가 더한 링크를 "손대지 않은 사본"으로 보고 지우지 않게.
# 일반 파일 줄의 형식은 그대로라 파일만 있는 기존 기록 해시는 바뀌지 않는다.
tree_sha() {
  (
    cd "$1"
    find . \( -type f -o -type l -o -type d -empty \) ! -name '.DS_Store' | LC_ALL=C sort | while IFS= read -r f; do
      if [[ -L "$f" ]]; then
        printf '%s -> %s\n' "$f" "$(readlink "$f")"
      elif [[ -d "$f" ]]; then
        printf '%s/\n' "$f"
      else
        printf '%s %s\n' "$f" "$(sha256_stdin <"$f")"
      fi
    done
  ) | sha256_stdin
}

# 스킬 자리에 디렉터리가 아닌 것(파일·symlink·깨진 링크)이 있으면 우리가 깐 사본이 아니다.
foreign_entry() { [[ -L "$1" || (-e "$1" && ! -d "$1") ]]; }

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
  foreign_entry "$target" && { printf 'foreign\n'; return; }
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

secrets_value() { # KEY → 값 (secrets.env를 source하지 않고 우리가 쓴 형식만 읽는다)
  local line re="^export $1='(.*)'\$" q="'"
  [[ -f "$SECRETS_FILE" ]] || return 1
  while IFS= read -r line; do
    if [[ "$line" =~ $re ]]; then
      local v="${BASH_REMATCH[1]}"
      printf '%s' "${v//$q\\$q$q/$q}"
      return 0
    fi
  done <"$SECRETS_FILE"
  return 1
}

settings_value() { [[ -f "$CLAUDE_SETTINGS" ]] && jq -er --arg k "$1" '.env[$k] // empty | select(. != "")' "$CLAUDE_SETTINGS" 2>/dev/null; }

# 키가 어디에 있는지: 프로세스 환경 → Claude settings.json env → secrets.env.
# 방금 넣은 값은 실행 중인 세션 환경에 없으므로 파일까지 본다.
env_source() {
  local key="$1"
  if [[ -n "${!key:-}" ]]; then
    printf 'env\n'
  elif settings_value "$key" >/dev/null; then
    printf 'settings\n'
  elif secrets_value "$key" >/dev/null; then
    printf 'secrets\n'
  else
    printf 'missing\n'
  fi
}

# 값은 이 프로세스 안에서만 쓰고 출력하지 않는다.
resolve_value() {
  local key="$1"
  if [[ -n "${!key:-}" ]]; then printf '%s' "${!key}"; return 0; fi
  settings_value "$key" && return 0
  secrets_value "$key"
}

first_value() { local k; for k in "$@"; do resolve_value "$k" && return 0; done; return 1; }

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
      '. + [{keys:$e.any, required:($e.required // false), secret:($e.secret // false), note:($e.note // null), issue:($e.issue // null),
             found:(if $f == "" then null else $f end), source:$s}]' <<<"$out")"
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
    local profile="$PROFILE_DIR/$name.md"
    jq -cn --arg n "$name" --argjson st "$statuses" --argjson env "$(env_report "$name")" --slurpfile c "$CATALOG" \
      --arg profile "$profile" --argjson has_profile "$([[ -s "$profile" ]] && echo true || echo false)" \
      '($c[0].skills[] | select(.name == $n)) as $s
       | {name:$n, summary:$s.summary, status:$st, env:$env, profile:{path:$profile, exists:$has_profile, questions:($s.profile // [])}}'
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
        current | outdated | superseded)
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

design_entry() { jq -c --arg n "$1" '.skills[] | select(.name == $n)' "$DESIGN_CATALOG"; }

design_names() { # core | extra | all | <name> → 이름 목록
  case "$1" in
    all) jq -r '.skills[].name' "$DESIGN_CATALOG" ;;
    core | extra) jq -r --arg b "$1" '.skills[] | select(.bundle == $b) | .name' "$DESIGN_CATALOG" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

design_path() { # entry tool → 원본 저장소 안 스킬 폴더 경로 (도구마다 다를 수 있다)
  jq -r --arg t "$2" '.source.path // "" | if type == "object" then (.[$t] // "") else . end' <<<"$1"
}

# builtin(그 도구나 ai-harness에 내장) | unavailable(내장이지만 이 도구엔 없음) | manual(원본 미고정 — setup이 설치하지 않음)
# | superseded(setup이 예전에 깐 사본인데 이제 ai-harness에 내장 — 지워도 된다)
# | absent | current | outdated(고정 ref가 바뀜) | modified | foreign
design_status() { # tool entry
  local tool="$1" entry="$2" name target recorded builtin
  name="$(jq -r '.name' <<<"$entry")"
  builtin="$(jq -r '.builtin // ""' <<<"$entry")"
  target="$(skills_dir "$tool")/$name"
  if [[ "$builtin" == ai-harness ]]; then
    # 사용자가 직접 둔 같은 이름 폴더는 foreign으로 남기고, setup이 기록한 사본만 superseded로 알린다.
    foreign_entry "$target" && { printf 'foreign\n'; return; }
    [[ -d "$target" ]] || { printf 'builtin\n'; return; }
    recorded="$(record_sha "$tool" "$name")"
    [[ -n "$recorded" ]] || { printf 'foreign\n'; return; }
    [[ "$(tree_sha "$target")" == "$recorded" ]] && printf 'superseded\n' || printf 'modified\n'
    return
  fi
  if [[ -n "$builtin" ]]; then
    [[ "$builtin" == "$tool" ]] && printf 'builtin\n' || printf 'unavailable\n'
    return
  fi
  if [[ "$(jq -r 'if .installable == false then "false" else "true" end' <<<"$entry")" == false ]]; then
    [[ -e "$target" || -L "$target" ]] && printf 'foreign\n' || printf 'manual\n'
    return
  fi
  foreign_entry "$target" && { printf 'foreign\n'; return; }
  [[ -d "$target" ]] || { printf 'absent\n'; return; }
  recorded="$(record_sha "$tool" "$name")"
  [[ -n "$recorded" ]] || { printf 'foreign\n'; return; }
  if [[ "$(tree_sha "$target")" != "$recorded" ]]; then
    printf 'modified\n'
  elif [[ "$(read_state | jq -r --arg k "$tool:$name" '.installed[$k].ref // ""')" == "$(jq -r '.source.ref' <<<"$entry")" ]]; then
    printf 'current\n'
  else
    printf 'outdated\n'
  fi
}

command_design_list() {
  local entry tool
  while IFS= read -r entry; do
    local statuses='{}'
    for tool in claude codex; do
      statuses="$(jq -c --arg t "$tool" --arg s "$(design_status "$tool" "$entry")" '. + {($t):$s}' <<<"$statuses")"
    done
    # 내장 스킬과 같은 이름으로 사용자가 직접 둔 폴더는 지우지 않지만, 이름이 겹친다는 사실은 알린다.
    jq -c --argjson st "$statuses" '{name, bundle, summary, builtin:(.builtin // null), license:(.license // null), source:(.source // null),
      review:(.review // null), overlaps:(.overlaps // null), absorbed:(.absorbed // null), note:(.note // null), status:$st,
      conflict:(if .builtin == "ai-harness" then ([$st | to_entries[] | select(.value == "foreign") | {key, value:"같은 이름 내장 스킬 있음 — 직접 둔 폴더라 지우지 않음, 필요하면 직접 정리"}] | from_entries | if . == {} then null else . end) else null end)}' <<<"$entry"
  done < <(jq -c '.skills[]' "$DESIGN_CATALOG")
}

# 카탈로그 값이 git 인자·경로로 들어가기 전에 모양을 확인한다(HM_SETUP_DESIGN_CATALOG로 바꿀 수 있으므로).
design_source_error() { # entry → 문제가 있으면 사유 출력
  jq -r '
    # 세그먼트는 허용 문자만: glob(*, [, 선행 !)은 sparse 패턴을 넓히고, "."은 .git까지 복사하며, ".."은 원본 밖을 가리킨다.
    def bad_segments: split("/") | any(. == "" or . == "." or . == ".." or startswith("-"));
    def bad_path: type != "string" or (test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$") | not) or bad_segments;
    if (.source.repo // "" | (test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") | not) or bad_segments) then "invalid source.repo"
    elif (.source.ref // "" | test("^[0-9a-f]{40}$") | not) then "source.ref must be a 40-character commit"
    elif (.source.path | if type == "object" then ((.claude // "" | bad_path) or (.codex // "" | bad_path)) else bad_path end) then "invalid source.path"
    else empty end' <<<"$1"
}

# 원본 저장소용 git: 자격 증명·SSH 프롬프트에서 멈추지 않고, 느린 연결은 30초 뒤 끊고, 받은 저장소의 hook·LFS 필터를 돌리지 않는다.
design_git() { # work_dir git-args...
  local work="$1"
  shift
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' GIT_LFS_SKIP_SMUDGE=1 \
    git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 -c core.hooksPath=/dev/null \
    -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false -C "$work" "$@"
}

# 원본 저장소의 고정 커밋에서 필요한 폴더와 루트 라이선스만 받는다(부분 클론 + sparse checkout).
fetch_design_source() { # entry work_dir — 실패 사유는 $STATE_DIR/.err
  local entry="$1" work="$2" repo ref p patterns=('/LICENSE*' '/COPYING*' '/NOTICE*')
  repo="$(jq -r '.source.repo' <<<"$entry")"
  ref="$(jq -r '.source.ref' <<<"$entry")"
  while IFS= read -r p; do patterns+=("/$p/"); done < <(jq -r '.source.path | if type == "object" then .[] else . end' <<<"$entry")
  : >"$STATE_DIR/.err"
  rm -rf "$work"
  mkdir -p "$work" \
    && design_git "$work" init -q 2>>"$STATE_DIR/.err" \
    && design_git "$work" remote add origin "$GIT_BASE/$repo" 2>>"$STATE_DIR/.err" \
    && design_git "$work" sparse-checkout set --no-cone "${patterns[@]}" 2>>"$STATE_DIR/.err" \
    || return 1
  design_git "$work" fetch -q --depth 1 --filter=blob:none origin "$ref" 2>"$STATE_DIR/.err" \
    || design_git "$work" fetch -q --depth 1 origin "$ref" 2>"$STATE_DIR/.err" || return 1
  design_git "$work" -c advice.detachedHead=false checkout -q FETCH_HEAD 2>>"$STATE_DIR/.err" || return 1
  [[ "$(design_git "$work" rev-parse HEAD)" == "$ref" ]] || { printf 'fetched commit is not %s\n' "$ref" >"$STATE_DIR/.err"; return 1; }
}

# 설치할 사본을 스킬 폴더 밖에 먼저 만들고 검증한다. 성공하면 그 경로, 실패하면 사유를 출력한다.
# 사용자 폴더는 이 단계가 끝날 때까지 건드리지 않는다.
stage_design_skill() { # tool entry work_dir
  local tool="$1" entry="$2" work="$3" name path src tmp lic
  name="$(jq -r '.name' <<<"$entry")"
  path="$(design_path "$entry" "$tool")"
  src="$work/$path"
  [[ -f "$src/SKILL.md" ]] || { printf 'SKILL.md not found at %s\n' "$path"; return 1; }
  grep -qE "^name:[[:space:]]*['\"]?${name}['\"]?[[:space:]]*\$" "$src/SKILL.md" || { printf 'SKILL.md name is not %s\n' "$name"; return 1; }
  tmp="$STATE_DIR/tmp/$tool-$name.$$"
  rm -rf "$tmp"
  cp -R "$src" "$tmp" || { rm -rf "$tmp"; printf 'copy failed\n'; return 1; }
  # 스킬 폴더에 라이선스가 없으면 원본 저장소 루트의 것을 함께 둔다 — 사용자 PC의 사본도 출처·조건을 안다.
  if ! compgen -G "$tmp/LICENSE*" >/dev/null; then
    for lic in "$work"/LICENSE* "$work"/COPYING* "$work"/NOTICE*; do
      [[ -f "$lic" ]] || continue
      cp "$lic" "$tmp/" || { rm -rf "$tmp"; printf 'copy failed\n'; return 1; }
    done
  fi
  printf '%s\n' "$tmp"
}

# 준비된 사본을 제자리에 둔다. 옮기다 실패하면 원래 폴더(또는 백업)를 되돌린다.
place_design_skill() { # tool entry staged backup → 실패 사유를 stdout
  local tool="$1" entry="$2" staged="$3" backup="$4" name dest old
  name="$(jq -r '.name' <<<"$entry")"
  dest="$(skills_dir "$tool")/$name"
  # 옮겨 둔 기존 폴더는 tmp가 아니라 backups에 둔다 — 중단돼도 with_lock trap이 tmp와 함께 지우지 않는다.
  old="$STATE_DIR/backups/old-$tool-$name-$(date +%Y%m%d%H%M%S).$$"
  mkdir -p "$(skills_dir "$tool")" "$STATE_DIR/backups" || { printf 'cannot create %s\n' "$(skills_dir "$tool")"; return 1; }
  if [[ -e "$dest" || -L "$dest" ]]; then
    rm -rf "$old"
    mv "$dest" "$old" || { rm -rf "$staged"; printf 'cannot move existing %s\n' "$dest"; return 1; }
  fi
  if ! mv "$staged" "$dest"; then
    rm -rf "$staged" "$dest"
    if [[ -e "$old" || -L "$old" ]]; then mv "$old" "$dest"; elif [[ -n "$backup" ]]; then mv "$backup" "$dest"; fi
    printf 'cannot place %s\n' "$dest"
    return 1
  fi
  rm -rf "$old"
  read_state | jq --arg k "$tool:$name" --arg sha "$(tree_sha "$dest")" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg src "$(jq -r '.source.repo' <<<"$entry")" --arg ref "$(jq -r '.source.ref' <<<"$entry")" \
    '.installed[$k] = {sha:$sha, at:$now, source:$src, ref:$ref}' | write_state
}

command_design_install() {
  parse_tool_args "$@"
  [[ -n "$TOOL" && ${#NAMES[@]} -gt 0 ]] || usage
  local arg name entry tool status backup work fetched why staged names=()
  for arg in "${NAMES[@]}"; do
    while IFS= read -r name; do names+=("$name"); done < <(design_names "$arg")
  done
  mkdir -p "$STATE_DIR/tmp"
  for name in "${names[@]+"${names[@]}"}"; do
    entry="$(design_entry "$name")"
    [[ -n "$entry" ]] || { result "-" "$name" "unknown"; continue; }
    work="$STATE_DIR/tmp/src-$name.$$"
    fetched=""
    while IFS= read -r tool; do
      status="$(design_status "$tool" "$entry")"
      # ai-harness에 내장된 스킬은 받지 않는다(--replace여도). 남아 있는 예전 사본은 remove가 지운다.
      if [[ "$(jq -r '.builtin // ""' <<<"$entry")" == ai-harness ]]; then
        result "$tool" "$name" "builtin"
        continue
      fi
      # 원본을 고정할 수 없는 스킬은 사용자가 직접 깐 사본이 있어도(--replace여도) 받지 않는다.
      if [[ "$(jq -r 'if .installable == false then "false" else "true" end' <<<"$entry")" == false ]]; then
        result "$tool" "$name" "skipped" "manual"
        continue
      fi
      case "$status" in
        builtin) result "$tool" "$name" "builtin" ;;
        unavailable) result "$tool" "$name" "skipped" "unavailable" ;;
        current) result "$tool" "$name" "unchanged" ;;
        absent | outdated | modified | foreign)
          if [[ "$status" == modified || "$status" == foreign ]] && ((FLAG == 0)); then
            result "$tool" "$name" "skipped" "$status"
            continue
          fi
          if [[ -z "$fetched" ]]; then
            why="$(design_source_error "$entry")"
            if [[ -n "$why" ]]; then
              printf '%s\n' "$why" >"$STATE_DIR/.err"; fetched=fail
            elif fetch_design_source "$entry" "$work"; then
              fetched=ok
            else
              fetched=fail
            fi
          fi
          if [[ "$fetched" == fail ]]; then
            result "$tool" "$name" "failed" "$(head -n 3 "$STATE_DIR/.err" 2>/dev/null | paste -sd' ' -)"
            continue
          fi
          if ! staged="$(stage_design_skill "$tool" "$entry" "$work")"; then
            result "$tool" "$name" "failed" "$staged"
            continue
          fi
          backup=""
          if [[ "$status" == modified || "$status" == foreign ]]; then
            backup="$(backup_skill "$tool" "$name")"
          fi
          if ! why="$(place_design_skill "$tool" "$entry" "$staged" "$backup")"; then
            result "$tool" "$name" "failed" "$why"
            continue
          fi
          case "$status" in
            absent) result "$tool" "$name" "installed" ;;
            outdated) result "$tool" "$name" "updated" ;;
            *) result "$tool" "$name" "replaced" "$backup" ;;
          esac
          ;;
      esac
    done < <(tools_for "$TOOL")
    rm -rf "$work"
  done
}

command_design_remove() {
  parse_tool_args "$@"
  [[ -n "$TOOL" && ${#NAMES[@]} -gt 0 ]] || usage
  local name entry tool status backup dir
  for name in "${NAMES[@]}"; do
    entry="$(design_entry "$name")"
    [[ -n "$entry" ]] || { result "-" "$name" "unknown"; continue; }
    while IFS= read -r tool; do
      status="$(design_status "$tool" "$entry")"
      case "$status" in
        absent | manual) forget_skill "$tool" "$name"; result "$tool" "$name" "absent" ;;
        builtin | unavailable) result "$tool" "$name" "skipped" "$status" ;;
        current | outdated | superseded)
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

command_design() {
  local sub="${1:-}"
  (($#)) && shift
  case "$sub" in
    list) command_design_list ;;
    install) with_lock command_design_install "$@" ;;
    remove) with_lock command_design_remove "$@" ;;
    *) usage ;;
  esac
}

key_is_known() { jq -e --arg k "$1" 'any(.skills[].env[]?; .any | index($k))' "$CATALOG" >/dev/null; }
key_is_secret() { jq -e --arg k "$1" 'any(.skills[].env[]?; (.any | index($k)) and (.secret // false))' "$CATALOG" >/dev/null; }

write_claude_env() { # KEY, 값은 stdin — jq 인자에 값을 싣지 않는다
  local tmp current='{}'
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  if [[ -f "$CLAUDE_SETTINGS" ]]; then
    jq -e 'type == "object"' "$CLAUDE_SETTINGS" >/dev/null 2>&1 || { printf 'not a JSON object, left unchanged: %s\n' "$CLAUDE_SETTINGS" >&2; return 1; }
    current="$(cat "$CLAUDE_SETTINGS")"
  fi
  tmp="$CLAUDE_SETTINGS.tmp.$$"
  (umask 077; jq -Rs --arg k "$1" --argjson cur "$current" '. as $v | $cur | .env = ((.env // {}) + {($k): $v})' >"$tmp")
  [[ -f "$CLAUDE_SETTINGS" ]] && chmod "$(filemode "$CLAUDE_SETTINGS")" "$tmp" 2>/dev/null
  mv "$tmp" "$CLAUDE_SETTINGS"
}

write_secret_env() { # KEY, 값은 stdin
  local value tmp q="'"
  value="$(cat)"
  tmp="$SECRETS_FILE.tmp.$$"
  (
    umask 077
    : >"$tmp"
    if [[ -f "$SECRETS_FILE" ]]; then grep -v "^export $1=" "$SECRETS_FILE" >"$tmp" || true; fi
    printf "export %s='%s'\n" "$1" "${value//$q/$q\\$q$q}" >>"$tmp"
  )
  mv "$tmp" "$SECRETS_FILE"
}

# 접속 정보 저장. secret 키는 명령 인자로 받지 않는다(셸 기록·프로세스 목록·대화 기록에 남지 않게):
# 터미널이면 숨김 입력, 아니면 stdin 한 줄(예: pbpaste | setup.sh set ...).
command_set() {
  local tool="" key="" value="" have_value=0 t
  while (($#)); do
    case "$1" in
      --tool) tool="${2:-}"; shift 2 ;;
      -*) usage ;;
      *) if [[ -z "$key" ]]; then key="$1"; else value="$1"; have_value=1; fi; shift ;;
    esac
  done
  [[ -n "$tool" && "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || usage
  key_is_known "$key" || { printf 'unknown key: %s\n' "$key" >&2; exit 2; }
  if ((have_value)); then
    key_is_secret "$key" && { printf '%s is a secret: run without VALUE and enter it at the hidden prompt\n' "$key" >&2; exit 2; }
  elif [[ -t 0 ]]; then
    printf '%s (입력이 보이지 않습니다): ' "$key" >&2
    IFS= read -rs value
    printf '\n' >&2
  else
    IFS= read -r value || true
  fi
  [[ -n "$value" ]] || { printf 'empty value, nothing saved\n' >&2; exit 1; }
  while IFS= read -r t; do
    case "$t" in
      claude) printf '%s' "$value" | write_claude_env "$key"; jq -cn --arg k "$key" --arg p "$CLAUDE_SETTINGS" '{key:$k, tool:"claude", saved:$p}' ;;
      codex)
        printf '%s' "$value" | write_secret_env "$key"
        jq -cn --arg k "$key" --arg p "$SECRETS_FILE" '{key:$k, tool:"codex", saved:$p, shell_profile_line:"[ -f \"\($p)\" ] && . \"\($p)\""}'
        ;;
    esac
  done < <(tools_for "$tool")
}

# 연결 확인과 자동 감지는 읽기 전용 호출만 한다. 자격 증명은 curl 설정(stdin)으로 넘긴다.
http_get() { # url, curl 설정은 stdin → 본문 출력, 실패 시 "HTTP <code>"를 stderr
  local body code out
  if [[ -n "${HM_SETUP_HTTP:-}" ]]; then
    "$HM_SETUP_HTTP" "$1"
    return
  fi
  out="$(mktemp "${TMPDIR:-/tmp}/ai-harness-setup.XXXXXX")"
  code="$(curl -sS -o "$out" -w '%{http_code}' --connect-timeout 5 --max-time 20 -K - "$1" 2>/dev/null || true)"
  body="$(cat "$out")"; rm -f "$out"
  printf '%s' "$body"
  [[ "$code" =~ ^2 ]] || { printf 'HTTP %s\n' "${code:-000}" >&2; return 1; }
}

dd_conf() { printf 'header = "DD-API-KEY: %s"\nheader = "DD-APPLICATION-KEY: %s"\n' "$(first_value DATADOG_API_KEY DD_API_KEY)" "$(first_value DATADOG_APP_KEY DD_APP_KEY)"; }
dd_base() { printf 'https://api.%s' "$(first_value DATADOG_SITE DD_SITE || echo datadoghq.com)"; }
atl_conf() { printf 'user = "%s:%s"\n' "$(resolve_value ATLASSIAN_USER)" "$(resolve_value ATLASSIAN_API_TOKEN)"; }
st_conf() { printf 'header = "Authorization: Bearer %s"\n' "$(resolve_value SENTRY_AUTH_TOKEN)"; }
st_base() { local u; u="$(resolve_value SENTRY_URL || echo https://sentry.io)"; printf '%s/api/0/organizations/%s' "${u%/}" "$(resolve_value SENTRY_ORG)"; }
lf_conf() { printf 'user = "%s:%s"\n' "$(resolve_value LANGFUSE_PUBLIC_KEY)" "$(resolve_value LANGFUSE_SECRET_KEY)"; }
lf_base() { local u; u="$(resolve_value LANGFUSE_HOST || echo https://cloud.langfuse.com)"; printf '%s' "${u%/}"; }
mask_email() { sed -E 's/^(.).*@/\1***@/'; }

check_hint() { # skill, http 오류 → 원인 안내
  case "$1:$2" in
    langfuse:"HTTP 401") printf '키가 틀렸거나 리전(host)이 다름 — 키를 만든 주소가 us.·jp.cloud.langfuse.com이면 LANGFUSE_HOST를 그 주소로 set한다' ;;
    *:"HTTP 401") printf '자격 증명이 틀렸거나 만료됨 — 토큰을 다시 발급해 set으로 넣는다' ;;
    datadog:"HTTP 403") printf 'Application key scope 부족 — user_access_read 등 읽기 scope를 더한다' ;;
    sentry:"HTTP 403") printf '토큰 scope 부족 — org:read, project:read, event:read' ;;
    *:"HTTP 403") printf '계정 권한 부족' ;;
    *:"HTTP 404") printf '주소가 틀림 — base URL·사이트·조직 slug를 확인한다' ;;
    *:"HTTP 000") printf '연결 실패 — 주소·네트워크·VPN을 확인한다' ;;
    *) printf '%s' "$2" ;;
  esac
}

command_check() {
  local name="${1:-}" body err="" ok=true who=""
  in_catalog "$name" || usage
  local missing
  missing="$(env_report "$name" | jq -r '[.[] | select(.required and .found == null) | .keys[0]] | join(",")')"
  if [[ -n "$missing" ]]; then
    jq -cn --arg n "$name" --arg m "$missing" '{name:$n, ok:false, missing:($m | split(",")), hint:"필수 키가 없다 — set으로 넣는다"}'
    return 0
  fi
  case "$name" in
    datadog)
      if body="$(dd_conf | http_get "$(dd_base)/api/v1/validate" 2>"$STATE_DIR/.err")" && [[ "$(jq -r '.valid' <<<"$body" 2>/dev/null)" == true ]]; then
        if body="$(dd_conf | http_get "$(dd_base)/api/v2/current_user" 2>"$STATE_DIR/.err")"; then
          who="$(jq -r '.data.attributes.email // .data.attributes.handle // ""' <<<"$body" | mask_email)"
        else ok=false; err="$(cat "$STATE_DIR/.err")"; fi
      else ok=false; err="$(cat "$STATE_DIR/.err")"; [[ -n "$err" ]] || err="HTTP 403"; fi
      ;;
    sentry)
      if body="$(st_conf | http_get "$(st_base)/" 2>"$STATE_DIR/.err")"; then who="$(jq -r '.name // .slug' <<<"$body")"
      else ok=false; err="$(cat "$STATE_DIR/.err")"; fi
      ;;
    jira)
      if body="$(atl_conf | http_get "$(resolve_value JIRA_BASE_URL | sed 's:/*$::')/rest/api/3/myself" 2>"$STATE_DIR/.err")"; then who="$(jq -r '.displayName // ""' <<<"$body")"
      else ok=false; err="$(cat "$STATE_DIR/.err")"; fi
      ;;
    confluence)
      if body="$(atl_conf | http_get "$(resolve_value CONFLUENCE_BASE_URL | sed 's:/*$::')/rest/api/user/current" 2>"$STATE_DIR/.err")" \
        && [[ "$(jq -r '.type' <<<"$body" 2>/dev/null)" != anonymous ]]; then who="$(jq -r '.displayName // ""' <<<"$body")"
      else ok=false; err="$(cat "$STATE_DIR/.err" 2>/dev/null)"; [[ -n "$err" ]] || err="HTTP 401"; fi
      ;;
    langfuse)
      if body="$(lf_conf | http_get "$(lf_base)/api/public/projects" 2>"$STATE_DIR/.err")"; then who="$(jq -r '[.data[]?.name] | join(", ")' <<<"$body")"
      else ok=false; err="$(cat "$STATE_DIR/.err")"; fi
      ;;
  esac
  rm -f "$STATE_DIR/.err"
  err="$(printf '%s' "$err" | head -1)"
  jq -cn --arg n "$name" --argjson ok "$ok" --arg who "$who" --arg err "$err" --arg hint "$( [[ $ok == true ]] || check_hint "$name" "$err")" \
    '{name:$n, ok:$ok} + (if $ok then {as:$who} else {error:$err, hint:$hint} end)'
}

# 프로필 질문의 선택지를 계정에서 읽어 온다. 실패하면 빈 값 — 셋업은 사람에게 물어 진행한다.
command_detect() {
  local name="${1:-}" out='{}'
  in_catalog "$name" || usage
  case "$name" in
    datadog)
      out="$(dd_conf | HM_SETUP_POST='{"filter":{"query":"status:error","from":"now-24h","to":"now"},"compute":[{"aggregation":"count"}],"group_by":[{"facet":"service","limit":20}]}' \
        http_post "$(dd_base)/api/v2/logs/analytics/aggregate" 2>/dev/null \
        | jq -c '{error_services:([.data.buckets[]? | {service:.by.service, count:.computes.c0}] | sort_by(-.count))}' 2>/dev/null || echo '{}')"
      ;;
    sentry)
      out="$(st_conf | http_get "$(st_base)/projects/" 2>/dev/null | jq -c '{projects:[.[]? | {slug, platform}]}' 2>/dev/null || echo '{}')"
      ;;
    jira)
      local base fields projects
      base="$(resolve_value JIRA_BASE_URL | sed 's:/*$::')"
      fields="$(atl_conf | http_get "$base/rest/api/3/field" 2>/dev/null \
        | jq -c '[.[]? | select((.schema.custom // "") | test("gh-sprint$|gh-epic-link$")) | {id, name, type:(.schema.custom | sub(".*:"; ""))}]' 2>/dev/null || echo '[]')"
      projects="$(atl_conf | http_get "$base/rest/api/3/project/recent?maxResults=20" 2>/dev/null | jq -c '[.[]? | {key, name}]' 2>/dev/null || echo '[]')"
      out="$(jq -cn --argjson f "$fields" --argjson p "$projects" '{fields:$f, recent_projects:$p}')"
      ;;
    confluence)
      out="$(atl_conf | http_get "$(resolve_value CONFLUENCE_BASE_URL | sed 's:/*$::')/api/v2/spaces?limit=50&type=global" 2>/dev/null \
        | jq -c '{spaces:[.results[]? | {key, name}]}' 2>/dev/null || echo '{}')"
      ;;
  esac
  jq -c --arg n "$name" '{name:$n} + .' <<<"$out"
}

http_post() { # url, 본문은 HM_SETUP_POST, curl 설정은 stdin
  if [[ -n "${HM_SETUP_HTTP:-}" ]]; then
    "$HM_SETUP_HTTP" "$1" "$HM_SETUP_POST"
    return
  fi
  curl -sS --fail --connect-timeout 5 --max-time 20 -K - -X POST -H 'Content-Type: application/json' --data-binary "$HM_SETUP_POST" "$1"
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
  # 중간 사본(tmp)은 잠금을 쥔 실행만 쓴다. 중단돼도 다음 실행 전에 남지 않게 지운다.
  trap 'rm -rf "$STATE_DIR/tmp"; hm_release_lock "$LOCK"' EXIT
  "$@"
}

cmd="${1:-}"
(($#)) && shift
case "$cmd" in
  list) command_list ;;
  install) with_lock command_install "$@" ;;
  remove) with_lock command_remove "$@" ;;
  update) with_lock command_update "$@" ;;
  set) command_set "$@" ;;
  check) mkdir -p "$STATE_DIR"; command_check "$@" ;;
  detect) command_detect "$@" ;;
  design) command_design "$@" ;;
  done) with_lock command_done ;;
  notify) command_notify ;;
  *) usage ;;
esac
