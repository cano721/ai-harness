#!/usr/bin/env bash
# PreToolUse: 세션이 열린 곳과 다른 하네스 저장소(멤버)의 코드 편집을 모델 혼자 진행하지 못하게 한다.
# 기본은 사용자 확인(permissionDecision: ask) — 사용자가 허용하면 진행, 아니면 멤버 세션으로 인계한다.
# bypass 모드에서도 확인 창이 뜨고, 답할 사람이 없는 -p 실행은 거부되어 사유가 모델에게 간다(실측).
# HM_MEMBER_GUARD=block이면 예전처럼 exit 2로 막고, 0이면 끈다.
# 저장소의 편집 가드·페르소나·권한은 그 저장소 .claude/에 있어 상위 폴더(workspace) 세션에서는 로드되지 않는다.
# 워크플로를 읽었는지와 무관하다 — 읽어도 그 저장소의 hook·페르소나는 여전히 빠진다. 서브에이전트도 같다.
# 플러그인 hook은 cwd와 무관하게 로드되므로 여기서 그 빈자리를 막는다. 어떤 오류든 통과(fail-open)한다.
set -uo pipefail
trap 'exit 0' ERR

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh" 2>/dev/null || exit 0
mode="${HM_MEMBER_GUARD:-1}"
[[ "$mode" == 0 ]] && exit 0

input="$(cat)" || exit 0
tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)" || exit 0
case "$tool" in Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac

cwd="$(jq -r '.cwd // empty' <<<"$input")"
file="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")"
[[ -n "$cwd" && -n "$file" ]] || exit 0
cwd="${cwd%/}"
[[ "$file" == /* ]] || file="$cwd/$file"

nfc() { # Python이 없으면 기존 경로 표현을 유지한다.
  local value="$1"
  command -v python3 >/dev/null 2>&1 || { printf '%s\n' "$value"; return; }
  python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.argv[1]))' "$value" 2>/dev/null || printf '%s\n' "$value"
}

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
member="$(nfc "$member")"
session_member="$(nfc "$session_member")"
[[ "$member" == "$session_member" ]] && exit 0
# 심볼릭 링크·`..`가 섞인 경로도 같은 저장소면 통과한다(문자열만 비교하면 다른 저장소로 오판한다).
physical_dir() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
[[ -n "$session_member" && "$(physical_dir "$member")" == "$(physical_dir "$session_member")" ]] && exit 0

rel=""
case "$member" in "$cwd"/*) rel="${member#"$cwd"/}" ;; esac
shown="${rel:-$member}"
# shellcheck disable=SC2016  # 백틱을 문자 그대로 쓴다
handoff() {
  printf '구현은 멤버 세션으로 인계하세요 — 인계 프롬프트에 이슈·범위·base 브랜치·이미 정한 결정·진행 방식을 담고, 첫 지시로 멤버 워크플로 파일(`.ai-harness/workflows/<name>.md`)을 Read 하고 그 그래프대로 진행하라고 적습니다(러너가 있으면 `workflow-driver.sh start` 명령도. 이름만 적으면 멤버 세션이 워크플로 선택을 건너뜁니다):\n'
  printf '  (a) %s 에서 새 세션을 열고 인계 프롬프트를 넘긴다: `cd %s && claude --bg -n <인계 이름> "<인계>"`(조율 세션과 같은 권한 모드: bypass면 `--dangerously-skip-permissions`) 또는 `codex -C %s "<인계>"`.\n' "$shown" "$shown" "$shown"
  printf '      완료를 알 수 있게 넘긴다 — `claude --bg` 세션은 `SendMessage`(`notify_when_idle: true`)로 턴 종료 알림을 구독해 기다리고, 사용자는 `claude attach <id>`로 보고 끼어들 수 있다. 사용자가 Orca 감독을 원하면 `orca orchestration worker-start` → `orca orchestration check --wait`로 기다린다. Codex 이거나 둘 다 안 되면 인계 프롬프트에 끝날 때 남길 완료 파일(결과·PR 링크·원격 CI 상태)을 지시하고 그 파일을 기다린다. 완료를 알 장치 없이 "끝나면 알려 주겠다"고 하지 마세요.\n'
  printf '  (b) `/cd %s` 로 이 세션을 옮긴다.\n' "$shown"
}

# shellcheck disable=SC2016  # 백틱을 문자 그대로 쓴다
if [[ "$mode" == block ]]; then
  {
    printf '[Direct edit guard] %s 는 하네스가 있는 저장소입니다. 이 세션(서브에이전트 포함)은 그 저장소 밖에서 열려 저장소의 편집 가드·페르소나·권한이 빠져 있으므로 코드를 바꾸지 않습니다. 워크플로를 읽었어도 같습니다.\n' "$shown"
    handoff
    printf '둘 다 할 수 없으면 구현하지 말고 사용자에게 `/cd`나 새 세션을 요청하고 멈추세요. Bash로 파일을 써서 우회하지 마세요.\n'
  } >&2
  exit 2
fi

# 확인 창(reason)은 사용자가 읽으므로 무엇을 허용하는지만 적는다. 인계 절차는 모델이 읽는 additionalContext에 둔다 —
# 거부돼도 모델에게 전달된다(실측). 출력을 못 만들면 허용하지 않고 차단으로 떨어진다.
reason="[Direct edit guard] $shown 는 하네스가 있는 저장소입니다. 이 세션(서브에이전트 포함)은 그 저장소 밖에서 열려, 저장소의 편집 가드·페르소나·권한 없이 편집합니다. 허용하면 이 편집만 진행되고, 거부하면 그 저장소 세션으로 인계합니다."
# shellcheck disable=SC2016  # 백틱을 문자 그대로 쓴다
context="$(
  printf '[Direct edit guard] %s 코드 편집은 사용자 확인을 거칩니다. 사용자가 허용한 편집만 진행하고, 거부되면 다시 시도하지 마세요.\n' "$shown"
  handoff
  printf '거부됐는데 둘 다 할 수 없으면 사용자에게 `/cd`나 새 세션을 요청하고 멈추세요. Bash로 파일을 써서 우회하지 마세요.\n'
)"
out="$(jq -cn --arg r "$reason" --arg c "$context" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"ask", permissionDecisionReason:$r, additionalContext:$c}}')" \
  || { printf '%s\n%s' "$reason" "$context" >&2; exit 2; }
printf '%s\n' "$out"
exit 0
