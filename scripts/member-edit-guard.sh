#!/usr/bin/env bash
# PreToolUse: 세션이 열린 곳과 다른 하네스 저장소(멤버)의 코드를 편집하기 전에 그 저장소의 워크플로를 읽었는지 본다.
# 저장소의 편집 가드는 그 저장소 .claude/settings.json에 있어 상위 폴더(workspace) 세션에서는 로드되지 않는다.
# 플러그인 hook은 cwd와 무관하게 로드되므로 여기서 그 빈자리를 막는다. 어떤 오류든 통과(fail-open)한다.
set -uo pipefail
trap 'exit 0' ERR

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh" 2>/dev/null || exit 0
[[ "${HM_MEMBER_GUARD:-1}" == 0 ]] && exit 0

input="$(cat)" || exit 0
tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)" || exit 0
case "$tool" in Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac

cwd="$(jq -r '.cwd // empty' <<<"$input")"
file="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")"
transcript="$(jq -r '.transcript_path // empty' <<<"$input")"
agent_id="$(jq -r '.agent_id // empty' <<<"$input")"
[[ -n "$cwd" && -n "$file" ]] || exit 0
cwd="${cwd%/}"
[[ "$file" == /* ]] || file="$cwd/$file"

# 하네스 문서·도구 설정은 대상이 아니다 — 워크플로를 고치려고 읽는 순서를 강요하지 않는다.
case "$file" in
  */.ai-harness/*|*/.claude/*|*/.agents/*|*/.codex/*|*.md) exit 0 ;;
esac

harness_root() { # 경로에서 위로 올라가 .ai-harness/harness.json이 있는 디렉토리
  local d="$1"
  while [[ -n "$d" && "$d" != "/" ]]; do
    [[ -f "$d/.ai-harness/harness.json" ]] && { printf '%s' "$d"; return 0; }
    d="${d%/*}"
  done
  return 1
}

member="$(harness_root "$(dirname "$file")")" || exit 0
session_member="$(harness_root "$cwd")" || session_member=""
[[ "$member" == "$session_member" ]] && exit 0

transcripts=()
[[ -n "$transcript" && -f "$transcript" ]] && transcripts+=("$transcript")
if [[ -n "$agent_id" && -n "$transcript" ]]; then
  sub="${transcript%.jsonl}/subagents/agent-${agent_id}.jsonl"
  [[ -f "$sub" ]] && transcripts+=("$sub")
fi
((${#transcripts[@]})) || exit 0

rel=""
case "$member" in "$cwd"/*) rel="${member#"$cwd"/}" ;; esac
physical="$(cd "$member" 2>/dev/null && pwd -P)" || physical="$member"
# shellcheck disable=SC2016  # 정규식 메타문자·백틱을 문자 그대로 쓴다
ere() { printf '%s' "$1" | sed 's/[][\.*^$(){}+?|/]/\\&/g'; }

read_workflow() {
  local c
  while IFS= read -r c; do
    [[ "$c" == *"$member/.ai-harness/workflows/"* || "$c" == *"$physical/.ai-harness/workflows/"* ]] && return 0
    [[ -n "$rel" ]] || continue
    grep -q -E "(^|[[:space:]\"'=(])(\./)?$(ere "$rel")/\.ai-harness/workflows/" <<<"$c" && return 0
    [[ "$c" == *.ai-harness/workflows/* ]] && grep -q -E "cd[[:space:]]+[\"']?(\./)?$(ere "$rel")[\"']?([[:space:]]|;|&&|$)" <<<"$c" && return 0
  done < <(grep -h -F '.ai-harness/workflows/' "${transcripts[@]}" 2>/dev/null \
             | jq -R -r 'fromjson? | .message.content[]? | select(type=="object" and .type=="tool_use")
                         | (.input.file_path // .input.command // empty) | select(type=="string")' 2>/dev/null)
  return 1
}
read_workflow && exit 0

shown="${rel:-$member}"
list=""
for w in "$member"/.ai-harness/workflows/*.md; do
  [[ -f "$w" ]] && list+="${list:+, }$shown/.ai-harness/workflows/${w##*/}"
done
# shellcheck disable=SC2016  # 정규식 메타문자·백틱을 문자 그대로 쓴다
{
  printf '[Direct edit guard] %s 는 하네스가 있는 저장소입니다. 코드를 바꾸기 전에 이 저장소의 워크플로를 읽고 그 절차를 따르세요: %s\n' "$shown" "${list:-$shown/AGENTS.md}"
  printf '구현은 그 저장소에서 연 세션이나 `/cd %s`에서 하는 것이 기본입니다 — 저장소의 편집 가드와 페르소나가 함께 로드됩니다.\n' "$shown"
} >&2
exit 2
