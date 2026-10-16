#!/usr/bin/env bash
# 기존 에이전트 자산 인벤토리 (읽기 전용). /harness-init이 덮어쓰거나 옆에 중복을 세우기 전에 본다.
#   scan --root <dir> [--templates <plugin templates dir>]
# 사실만 모은다 — 어느 기존 에이전트가 어느 하네스 역할을 맡을지는 판정하지 않는다(init이 사용자와 정한다).
set -euo pipefail

usage() {
  printf 'usage: %s scan --root <dir> [--templates <dir>]\n' "$0" >&2
  exit 2
}

command_name="${1:-}"
[[ "$command_name" == "scan" ]] || usage
shift

root=""
templates=""
while (($#)); do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --templates) templates="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$root" && -d "$root" ]] || usage
root="$(cd "$root" && pwd -P)"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

sha256_file() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' && return
  sha256sum "$1" | awk '{print $1}'
}

# YAML frontmatter에서 name·model·description·tools와 skills 목록만 뽑는다.
# description은 한 줄 값과 접힌(`>`/`|`) 블록 둘 다 받는다.
frontmatter_json() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    {
      if (block != "" && $0 ~ /^[[:space:]]+/) {
        line = $0; sub(/^[[:space:]]+/, "", line)
        if (block == "skills") { if (line ~ /^- /) { sub(/^- /, "", line); print "skill\t" line } }
        else { print "cont\t" block "\t" line }
        next
      }
      block = ""
      if (match($0, /^[A-Za-z_-]+:/)) {
        key = substr($0, 1, RLENGTH - 1); value = substr($0, RLENGTH + 1); sub(/^[[:space:]]+/, "", value)
        if (value == ">" || value == "|" || value == ">-" || value == "|-" || value == "") { block = key; next }
        print "kv\t" key "\t" value
      }
    }
  ' "$1" | jq -R -s '
    split("\n") | map(select(. != "") | split("\t"))
    | reduce .[] as $row ({skills: []};
        if $row[0] == "skill" then .skills += [$row[1]]
        elif $row[0] == "kv" then .[$row[1]] = ($row[2] | sub("^\"(?<v>.*)\"$"; "\(.v)"))
        else .[$row[1]] = (((.[$row[1]] // "") + " " + $row[2]) | ltrimstr(" ")) end)'
}

relative_agents_import() { # CLAUDE.md 위치 기준 AGENTS.md(루트) 상대 경로
  local dir depth prefix=""
  dir="$(dirname "$1")"
  [[ "$dir" == "." ]] && { printf 'AGENTS.md'; return; }
  depth="$(awk -F/ '{print NF}' <<<"$dir")"
  for ((i = 0; i < depth; i++)); do prefix+="../"; done
  printf '%sAGENTS.md' "$prefix"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/existing-assets.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/instructions.jsonl"; : >"$TMP/agents.jsonl"; : >"$TMP/skills.jsonl"; : >"$TMP/refs.jsonl"

# 1. 지침 파일
for rel in CLAUDE.md .claude/CLAUDE.md; do
  [[ -f "$root/$rel" ]] || continue
  import="$(relative_agents_import "$rel")"
  imports="false"
  grep -qxF "@$import" "$root/$rel" && imports="true"
  jq -cn --arg path "$rel" --arg import "$import" --argjson imports "$imports" --arg lines "$(wc -l <"$root/$rel" | tr -d ' ')" \
    '{kind:"claude_md", path:$path, lines:($lines|tonumber), agents_import:$import, imports_agents:$imports}' >>"$TMP/instructions.jsonl"
done
[[ -f "$root/AGENTS.md" ]] && jq -cn --arg lines "$(wc -l <"$root/AGENTS.md" | tr -d ' ')" \
  '{kind:"agents_md", path:"AGENTS.md", lines:($lines|tonumber)}' >>"$TMP/instructions.jsonl"
shopt -s nullglob
for f in "$root"/*CONVENTION*.md "$root"/DESIGN.md "$root"/STYLEGUIDE*.md "$root"/CONTRIBUTING.md \
         "$root"/.github/copilot-instructions.md "$root"/.cursorrules "$root"/.cursor/rules/*; do
  [[ -f "$f" ]] || continue
  rel="${f#"$root"/}"
  kind="convention_doc"
  case "$rel" in
    .github/*) kind="copilot_instructions" ;;
    .cursor*) kind="cursor_rules" ;;
  esac
  jq -cn --arg kind "$kind" --arg path "$rel" --arg lines "$(wc -l <"$f" | tr -d ' ')" \
    '{kind:$kind, path:$path, lines:($lines|tonumber)}' >>"$TMP/instructions.jsonl"
done

# 2. 에이전트
for f in "$root"/.claude/agents/*.md; do
  rel="${f#"$root"/}"
  base="$(basename "$f" .md)"
  frontmatter_json "$f" | jq -c --arg path "$rel" --arg base "$base" \
    '{name:(.name // $base), path:$path, integration:"claude", model:(.model // null),
      description:(.description // ""), skills:.skills, tools:(.tools // null)}' >>"$TMP/agents.jsonl"
done
for f in "$root"/.codex/agents/*.toml; do
  rel="${f#"$root"/}"
  name="$(awk -F'"' '/^name[[:space:]]*=/{print $2; exit}' "$f")"
  model="$(awk -F'"' '/^model[[:space:]]*=/{print $2; exit}' "$f")"
  jq -cn --arg path "$rel" --arg name "${name:-$(basename "$f" .toml)}" --arg model "$model" \
    '{name:$name, path:$path, integration:"codex", model:(if $model=="" then null else $model end), description:"", skills:[], tools:null}' >>"$TMP/agents.jsonl"
done
agent_names="$(jq -r '.name' "$TMP/agents.jsonl" | sort -u)"

# 3. 스킬 — 템플릿과 이름이 같으면 충돌, 본문이 로컬 에이전트를 부르면 라우터 후보
for f in "$root"/.claude/skills/*/SKILL.md "$root"/.agents/skills/*/SKILL.md; do
  rel="${f#"$root"/}"
  name="$(basename "$(dirname "$f")")"
  integration="claude"
  [[ "$rel" == .agents/* ]] && integration="codex"
  collision="false"; identical="false"
  if [[ -n "$templates" && -f "$templates/$name/SKILL.md" ]]; then
    collision="true"
    [[ "$(sha256_file "$f")" == "$(sha256_file "$templates/$name/SKILL.md")" ]] && identical="true"
  fi
  routes="false"
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    if grep -qF "\`$agent\`" "$f"; then routes="true"; break; fi
  done <<<"$agent_names"
  jq -cn --arg name "$name" --arg path "$rel" --arg integration "$integration" \
    --argjson collision "$collision" --argjson identical "$identical" --argjson routes "$routes" \
    '{name:$name, path:$path, integration:$integration, template_collision:$collision,
      identical_to_template:$identical, routes_agents:$routes}' >>"$TMP/skills.jsonl"
done

# 4. 설정·커맨드
settings='null'
enabled_plugins='[]'
if [[ -f "$root/.claude/settings.json" ]] && jq -e . "$root/.claude/settings.json" >/dev/null 2>&1; then
  settings="$(jq -c '{path:".claude/settings.json", hook_events:((.hooks // {}) | keys),
    allow_count:((.permissions.allow // []) | length), deny_count:((.permissions.deny // []) | length),
    enabled_plugins:((.enabledPlugins // {}) | keys)}' "$root/.claude/settings.json")"
  enabled_plugins="$(jq -c '.enabled_plugins | map(split("@")[0])' <<<"$settings")"
fi
commands="$(for f in "$root"/.claude/commands/*.md; do basename "$f" .md; done | jq -R -s -c 'split("\n") | map(select(. != ""))')"

# 5. 플러그인 네임스페이스 참조(`plugin:agent`) — 저장소가 그 플러그인을 선언하지 않으면 설치 안 한 팀원에게서 끊긴다
for f in "$root"/CLAUDE.md "$root"/.claude/CLAUDE.md "$root"/.claude/agents/*.md "$root"/.claude/skills/*/SKILL.md "$root"/.claude/commands/*.md; do
  [[ -f "$f" ]] || continue
  rel="${f#"$root"/}"
  # shellcheck disable=SC2016  # 백틱은 마크다운 리터럴, 확장 의도 아님
  { grep -noE '`[a-z0-9][a-z0-9-]*:[a-z0-9][a-z0-9-]*`' "$f" 2>/dev/null || true; } \
    | while IFS=: read -r line ref_a ref_b; do
        ref="${ref_a#\`}:${ref_b%\`}"
        [[ "${ref_b%\`}" =~ ^[0-9]+$ ]] && continue  # host:port 등 숫자는 플러그인 참조가 아니다
        jq -cn --arg ref "$ref" --arg file "$rel" --arg line "$line" --argjson plugins "$enabled_plugins" \
          '{ref:$ref, file:$file, line:($line|tonumber), declared:($plugins | index($ref | split(":")[0]) != null)}'
      done >>"$TMP/refs.jsonl"
done

ignored="false"
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && git -C "$root" check-ignore -q .claude/agents/ai-harness-probe.md 2>/dev/null; then
  ignored="true"
fi

jq -n --slurpfile instructions "$TMP/instructions.jsonl" --slurpfile agents "$TMP/agents.jsonl" \
  --slurpfile skills "$TMP/skills.jsonl" --slurpfile refs "$TMP/refs.jsonl" \
  --argjson commands "$commands" --argjson settings "$settings" --argjson ignored "$ignored" \
  '{instructions:$instructions, agents:$agents, skills:$skills, commands:$commands, settings:$settings,
    external_refs:($refs | unique_by([.ref, .file, .line]) | sort_by(.file, .line)), claude_dir_ignored:$ignored}'
