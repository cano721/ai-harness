#!/usr/bin/env bash
# PreToolUse: 세션이 열린 곳과 다른 하네스 저장소(멤버)의 코드 편집을 막고 멤버 세션으로 인계하게 한다.
# 저장소의 편집 가드·페르소나·권한은 그 저장소 .claude/에 있어 상위 폴더(workspace) 세션에서는 로드되지 않는다.
# 워크플로를 읽었는지와 무관하다 — 읽어도 그 저장소의 hook·페르소나는 여전히 빠진다. 서브에이전트도 같다.
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
[[ -n "$cwd" && -n "$file" ]] || exit 0
cwd="${cwd%/}"
[[ "$file" == /* ]] || file="$cwd/$file"

# 하네스 문서·도구 설정은 대상이 아니다 — workspace 세션이 하네스를 고치거나 인계 문서를 남길 수 있다.
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
# 심볼릭 링크·`..`가 섞인 경로도 같은 저장소면 통과한다(문자열만 비교하면 다른 저장소로 오판한다).
physical_dir() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
[[ -n "$session_member" && "$(physical_dir "$member")" == "$(physical_dir "$session_member")" ]] && exit 0

rel=""
case "$member" in "$cwd"/*) rel="${member#"$cwd"/}" ;; esac
shown="${rel:-$member}"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 쓴다
{
  printf '[Direct edit guard] %s 는 하네스가 있는 저장소입니다. 이 세션(서브에이전트 포함)은 그 저장소 밖에서 열려 저장소의 편집 가드·페르소나·권한이 빠져 있으므로 코드를 바꾸지 않습니다. 워크플로를 읽었어도 같습니다.\n' "$shown"
  printf '구현은 멤버 세션으로 인계하세요 — 인계 프롬프트에 이슈·범위·base 브랜치·이미 정한 결정·진행 방식을 담습니다:\n'
  printf '  (a) %s 에서 새 세션을 열고 인계 프롬프트를 넘긴다: `cd %s && claude "<인계>"` 또는 `codex -C %s "<인계>"`.\n' "$shown" "$shown" "$shown"
  printf '      완료를 알 수 있게 넘긴다 — 터미널 매니저가 감독 디스패치를 지원하면 그것으로 넘기고 완료 신호를 기다린다(Orca: `orca orchestration worker-start` → `orca orchestration check --wait`). 아니면 인계 프롬프트에 끝날 때 남길 완료 파일(결과·PR 링크·원격 CI 상태)을 지시하고 그 파일을 기다린다. 완료를 알 장치 없이 "끝나면 알려 주겠다"고 하지 마세요.\n'
  printf '  (b) `/cd %s` 로 이 세션을 옮긴다.\n' "$shown"
  printf '둘 다 할 수 없으면 구현하지 말고 사용자에게 `/cd`나 새 세션을 요청하고 멈추세요. Bash로 파일을 써서 우회하지 마세요.\n'
} >&2
exit 2
