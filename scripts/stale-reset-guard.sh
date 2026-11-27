#!/usr/bin/env bash
# PreToolUse(Bash) 가드(#601): HEAD의 조상이 아닌 커밋 위로 옮기는 git reset --soft <ref>를 실행 전에 막는다.
# soft reset은 인덱스(옛 트리)를 그대로 두므로 남의 새 커밋 위에서 커밋하면 그 변경을 옛 내용으로 되돌린다(#594).
# 기본 켬, 끄기: HM_STALE_RESET_GUARD=0. 판정 기준은 docs/guards-and-data.md "stale reset 가드". 어떤 오류든 통과(fail-open)한다.
set -uo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)" || exit 0
cmd="$(jq -r '.tool_input.command // "" | if type == "array" then join(" ") else tostring end' <<<"$input" 2>/dev/null)" || exit 0

# 대부분의 Bash 호출은 여기서 끝난다.
[[ "$cmd" == *reset* && "$cmd" == *--soft* ]] || exit 0

# 설정은 다른 HM_* 값처럼 hm_load_config로 읽는다 — config를 셸로 실행하지 않는다.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh" 2>/dev/null || exit 0
[[ "${HM_STALE_RESET_GUARD:-1}" != 0 ]] || exit 0

cwd="$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null)" || exit 0
[[ -n "$cwd" ]] || cwd="$PWD"

unquote() { # word → 감싼 따옴표를 벗긴다
  local w="$1"
  w="${w#[\"\']}"
  w="${w%[\"\']}"
  printf '%s' "$w"
}

# 조각 하나(git ... reset --soft <ref>)를 판정한다. 막아야 하면 ref를 내고 0, 아니면 1.
stale_ref() { # segment
  local -a words=()
  local i=0 n w dir="$cwd" ref="" soft=""
  read -r -a words <<<"$1"
  n=${#words[@]}
  # 명령 앞 변수 대입(FOO=bar)은 건너뛴다.
  while ((i < n)) && [[ "${words[i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do i=$((i + 1)); done
  ((i < n)) || return 1
  w="$(unquote "${words[i]}")"
  [[ "$w" == git || "$w" == */git ]] || return 1
  i=$((i + 1))
  # git 전역 옵션: -C <dir>는 저장소 위치로 쓰고, 값을 따로 받는 옵션은 값까지 건너뛴다.
  while ((i < n)); do
    w="${words[i]}"
    case "$w" in
      -C)
        ((i + 1 < n)) || return 1
        w="$(unquote "${words[i + 1]}")"
        if [[ "$w" == /* ]]; then dir="$w"; else dir="$dir/$w"; fi
        i=$((i + 2)) ;;
      -c | --git-dir | --work-tree | --namespace | --exec-path | --config-env) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  if ((i >= n)) || [[ "${words[i]}" != reset ]]; then return 1; fi
  i=$((i + 1))
  while ((i < n)); do
    w="${words[i]}"
    case "$w" in
      --) return 1 ;;
      --soft) soft=1 ;;
      -*) ;;
      *) if [[ -n "$soft" && -z "$ref" ]]; then ref="$w"; fi ;;
    esac
    i=$((i + 1))
  done
  [[ -n "$soft" && -n "$ref" ]] || return 1
  # 치환($(...)·백틱)은 정적으로 풀 수 없다. 권장 형태 $(git merge-base HEAD <ref>)는 늘 HEAD의 조상이다.
  [[ "$ref" != '$'* && "$ref" != '`'* ]] || return 1
  ref="$(unquote "$ref")"
  git -C "$dir" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 || return 1
  if git -C "$dir" merge-base --is-ancestor "$ref" HEAD >/dev/null 2>&1; then return 1; fi
  printf '%s' "$ref"
}

# ; && || | & 줄바꿈으로 나눈다.
segments="$cmd"
segments="${segments//&&/$'\n'}"
segments="${segments//||/$'\n'}"
segments="${segments//;/$'\n'}"
segments="${segments//|/$'\n'}"
segments="${segments//&/$'\n'}"
hit=""
while IFS= read -r seg; do
  [[ "$seg" == *reset* && "$seg" == *--soft* ]] || continue
  if hit="$(stale_ref "$seg")"; then break; fi
  hit=""
done <<<"$segments"
[[ -n "$hit" ]] || exit 0

reason="[Stale reset guard] ${hit}는 HEAD의 조상이 아니라 git reset --soft ${hit}가 남의 새 커밋 위로 브랜치를 옮기고, 그 변경을 옛 내용으로 되돌리는 커밋을 만듭니다(#594). 기준 브랜치를 따라가려면 git rebase ${hit}를 쓰고, 자기 wip 커밋만 합치려면 git reset --soft \$(git merge-base HEAD ${hit})를 쓰세요."
jq -cn --arg reason "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$reason}}'
