#!/usr/bin/env bash
# 개인 소유 지침(전역 CLAUDE.md·Codex AGENTS.md, workspace 루트 AGENTS.md)에 자동 harvest가 규칙을 넣고 빼는
# 유일한 경로. 사람 검토 대신 아래 장치로 안전을 묶는다.
# - 지정된 블록(<!-- ai-harness:auto:start --> … end) 안에서만 고친다. 사람이 쓴 내용은 건드리지 않는다
# - 적용마다 이전 파일을 ~/.ai-harness/applied/에 남기고 규칙 단위로 되돌릴 수 있다
# - 기대효과(expected)를 남겨 다음 harvest가 재발 여부로 효과를 판정·되돌린다
# - 다음 세션 시작에 무엇을 바꿨는지 알린다
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

APPLIED_DIR="$HM_DATA_DIR/applied"
LOG="$APPLIED_DIR/applied.jsonl"
START='<!-- ai-harness:auto:start -->'
END='<!-- ai-harness:auto:end -->'
CLAUDE_GLOBAL="${HM_GLOBAL_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
CODEX_GLOBAL="${HM_GLOBAL_CODEX_AGENTS_MD:-$HOME/.codex/AGENTS.md}"

usage() {
  cat >&2 <<'EOF'
usage:
  auto-apply.sh apply --scope global|workspace --rule-id <id> --text <규칙 한 줄> \
      --evidence <근거> --expected <다음 harvest가 효과를 판정할 기준> [--workspace <루트>] [--project <id>]
  auto-apply.sh revert --rule-id <id> [--reason <이유>]
  auto-apply.sh list [--active]
  auto-apply.sh notify                     # SessionStart: 아직 알리지 않은 적용·되돌림을 한 번 알린다
EOF
  exit 2
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

targets_for() { # $1=scope $2=workspace → 대상 파일 목록
  case "$1" in
    global) printf '%s\n%s\n' "$CLAUDE_GLOBAL" "$CODEX_GLOBAL" ;;
    workspace)
      [[ -n "$2" && -f "$2/.ai-harness/workspace.json" ]] || { echo "workspace 루트가 아닙니다: $2" >&2; exit 3; }
      printf '%s\n' "$2/AGENTS.md"
      ;;
    *) usage ;;
  esac
}

# 블록이 없으면 파일 끝에 만든다. 블록 밖은 그대로 둔다.
ensure_block() { # $1=file
  local file="$1"
  mkdir -p "${file%/*}"
  [[ -f "$file" ]] || : >"$file"
  grep -qF "$START" "$file" && grep -qF "$END" "$file" && return 0
  # 줄바꿈 없이 끝나는 파일도 사람이 쓴 마지막 줄과 섞이지 않게 빈 줄로 구분한다.
  local lead=""
  if [[ -s "$file" ]]; then
    [[ "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" == '\n' ]] || lead=$'\n'
    lead+=$'\n'
  fi
  {
    printf '%s' "$lead"
    printf '## ai-harness 자동 개선\n\n'
    printf '%s\n' "$START"
    printf '<!-- 이 블록은 ai-harness 자동 harvest가 관리합니다. 직접 쓰는 규칙은 블록 밖에 두세요. -->\n'
    printf '%s\n' "$END"
  } >>"$file"
}

# 블록 안에서 같은 id 규칙을 지우고(있으면), 필요하면 새 규칙을 블록 끝에 넣는다.
rewrite_block() { # $1=file $2=rule_id $3=text(빈 문자열이면 삭제만)
  local file="$1" id="$2" text="$3" tmp=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/ai-harness-apply.XXXXXX")"
  # awk -v는 백슬래시 이스케이프를 해석해 \n 등으로 블록 밖에 줄을 만들 수 있다 — 값은 ENVIRON으로 넘긴다.
  AH_START="$START" AH_END="$END" AH_OPEN="<!-- rule:$id -->" AH_CLOSE="<!-- /rule:$id -->" AH_TEXT="$text" awk '
    BEGIN { start = ENVIRON["AH_START"]; end = ENVIRON["AH_END"]; ropen = ENVIRON["AH_OPEN"]
            rclose = ENVIRON["AH_CLOSE"]; text = ENVIRON["AH_TEXT"] }
    $0 == start { inblock = 1; print; next }
    inblock && $0 == ropen { skip = 1; next }
    inblock && skip && $0 == rclose { skip = 0; next }
    # 닫는 마커가 지워졌어도 블록 끝에서 멈춘다 — 블록 뒤의 사람이 쓴 내용을 버리지 않는다.
    skip && $0 != end { next }
    inblock && $0 == end {
      skip = 0
      if (text != "") { print ropen; print "- " text; print rclose }
      inblock = 0; print; next
    }
    { print }
  ' "$file" >"$tmp"
  # 내용만 덮어써 심볼릭 링크(dotfiles 저장소 등)·권한·확장 속성을 보존한다.
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

append_log() { mkdir -p "$APPLIED_DIR"; printf '%s\n' "$1" >>"$LOG"; }

command_apply() {
  local scope="" id="" text="" evidence="" expected="" workspace="" project="" file="" snap=""
  while (( $# > 0 )); do
    case "$1" in
      --scope) scope="${2:-}"; shift 2 ;;
      --rule-id) id="${2:-}"; shift 2 ;;
      --text) text="${2:-}"; shift 2 ;;
      --evidence) evidence="${2:-}"; shift 2 ;;
      --expected) expected="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --project) project="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]{2,60}$ ]] || { echo "rule-id는 소문자·숫자·하이픈 3~61자" >&2; exit 2; }
  [[ -n "$text" && -n "$evidence" && -n "$expected" ]] || usage
  # 한 줄 규칙만 받는다. 블록 구조를 깨거나 다른 규칙을 흉내 내는 입력을 막는다.
  if [[ "$text" == *"<!--"* || "$text" == *"-->"* || "$text" == *\\* ]] || (( ${#text} > 400 )) \
    || printf '%s' "$text" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo "규칙은 400자 이내 한 줄이고 HTML 주석·백슬래시·제어문자를 포함할 수 없습니다" >&2
    exit 2
  fi
  # 규칙은 이후 모든 세션의 지침이 된다. transcript에서 온 문장이 명령 실행·외부 호출·지침 무력화를
  # 지시하지 못하게 막는다.
  if printf '%s' "$text" | grep -qiE '(https?://|`|\bcurl\b|\bwget\b|\b(ba|z)?sh -c\b|\beval\b|ignore (all |the )?(previous|above)|disregard|이전 지침|위 지침|무시하)'; then
    echo "규칙에 URL·코드 블록·명령 실행·지침 무력화 표현을 넣을 수 없습니다" >&2
    exit 2
  fi
  # 대상 검증은 반복 밖에서 한다 — 프로세스 치환 안의 실패는 호출자에게 전달되지 않는다.
  local targets=""
  targets="$(targets_for "$scope" "$workspace")" || exit $?
  mkdir -p "$APPLIED_DIR"
  snap="$(mktemp -d "$APPLIED_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$id.XXXX")"
  while IFS= read -r file; do
    ensure_block "$file"
    cp "$file" "$snap/$(printf '%s' "$file" | jq -sRr '@uri').before"
    rewrite_block "$file" "$id" "$text"
  done <<<"$targets"
  append_log "$(jq -cn --arg at "$(now_iso)" --arg id "$id" --arg scope "$scope" --arg text "$text" \
    --arg evidence "$evidence" --arg expected "$expected" --arg workspace "$workspace" --arg project "$project" \
    --arg snapshot "$snap" '{at:$at,event:"applied",id:$id,scope:$scope,text:$text,evidence:$evidence,
      expected:$expected,workspace:(if $workspace=="" then null else $workspace end),
      project:(if $project=="" then null else $project end),snapshot:$snapshot,notified:false}')"
  echo "applied $id ($scope)"
}

latest_entry() { # $1=rule_id
  [[ -f "$LOG" ]] || return 0
  jq -sc --arg id "$1" '[.[] | select(.id==$id and .event=="applied")] | last // empty' "$LOG"
}

command_revert() {
  local id="" reason="" entry="" scope="" workspace="" file=""
  while (( $# > 0 )); do
    case "$1" in
      --rule-id) id="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  entry="$(latest_entry "$id")"
  [[ -n "$entry" ]] || { echo "적용 기록이 없는 규칙: $id" >&2; exit 3; }
  scope="$(jq -r '.scope' <<<"$entry")"
  workspace="$(jq -r '.workspace // empty' <<<"$entry")"
  local targets=""
  targets="$(targets_for "$scope" "$workspace")" || exit $?
  while IFS= read -r file; do
    if [[ -f "$file" ]]; then rewrite_block "$file" "$id" ""; fi
  done <<<"$targets"
  append_log "$(jq -cn --arg at "$(now_iso)" --arg id "$id" --arg scope "$scope" --arg reason "$reason" \
    '{at:$at,event:"reverted",id:$id,scope:$scope,reason:(if $reason=="" then null else $reason end),notified:false}')"
  echo "reverted $id"
}

# 규칙별 마지막 상태. active = 마지막 이벤트가 applied.
command_list() {
  [[ -f "$LOG" ]] || return 0
  jq -sc --arg active "${1:-}" '
    group_by(.id) | map(last) | map(select($active != "--active" or .event == "applied"))
    | .[] | {id, state:(if .event=="applied" then "active" else "reverted" end), scope, at, text, expected}' "$LOG"
}

command_notify() {
  local pending="" tmp=""
  [[ -f "$LOG" ]] || return 0
  pending="$(jq -sr '[.[] | select(.notified == false)]
    | map(if .event=="applied" then "적용 \(.id) (\(.scope)): \(.text)" else "되돌림 \(.id) (\(.scope))" end)
    | join(" / ")' "$LOG" 2>/dev/null || true)"
  [[ -n "$pending" ]] || return 0
  tmp="$(mktemp "$APPLIED_DIR/.applied.XXXXXX")"
  jq -c '.notified = true' "$LOG" >"$tmp" && mv "$tmp" "$LOG"
  jq -cn --arg m "ai-harness 자동 개선 — $pending. 되돌리기: \"$DIR/auto-apply.sh\" revert --rule-id <id>" '{systemMessage:$m}'
}

# apply·revert·notify는 같은 로그와 파일을 읽고 고친다. 백그라운드 실행과 세션 시작이 겹치지 않게 직렬화한다.
mkdir -p "$APPLIED_DIR"
hm_acquire_lock "$APPLIED_DIR/.lock" 100 || { echo "auto-apply lock 대기 시간 초과" >&2; exit 4; }
trap 'hm_release_lock "$APPLIED_DIR/.lock"' EXIT

command="${1:-}"
shift || true
case "$command" in
  apply) command_apply "$@" ;;
  revert) command_revert "$@" ;;
  list) command_list "${1:-}" ;;
  notify) command_notify ;;
  *) usage ;;
esac
