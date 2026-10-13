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
# 자동 규칙 총량 상한. 지침 파일이 길어질수록 에이전트 성공률은 떨어지고 비용은 늘어난다는 보고가 있어
# (AGENTS.md류 연구, 2026), 상한에 닿으면 새 규칙 대신 기존 규칙 병합·정리를 요구한다.
RULES_MAX="${HM_AUTO_RULES_MAX:-12}"; [[ "$RULES_MAX" =~ ^[1-9][0-9]*$ ]] || RULES_MAX=12

usage() {
  cat >&2 <<'EOF'
usage:
  auto-apply.sh apply --scope global|workspace --rule-id <id> --text <규칙 한 줄> \
      --evidence <근거> --expected <다음 harvest가 효과를 판정할 기준> [--signal <정규식>] \
      [--workspace <루트>] [--project <id>]
  auto-apply.sh revert --rule-id <id> [--reason <이유>]
  auto-apply.sh list [--active]
  auto-apply.sh effect [--rule-id <id>]    # --signal이 있는 규칙의 적용 전후 100세션당 발생률
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
  local scope="" id="" text="" evidence="" expected="" workspace="" project="" file="" snap="" signal=""
  while (( $# > 0 )); do
    case "$1" in
      --scope) scope="${2:-}"; shift 2 ;;
      --rule-id) id="${2:-}"; shift 2 ;;
      --text) text="${2:-}"; shift 2 ;;
      --evidence) evidence="${2:-}"; shift 2 ;;
      --expected) expected="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --project) project="${2:-}"; shift 2 ;;
      --signal) signal="${2:-}"; shift 2 ;;
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
  # 보이지 않는 문자(제로폭·양방향 제어·BOM)는 사람이 읽는 내용과 모델이 읽는 내용을 다르게 만든다.
  # bash 3.2(macOS 기본)는 $'\u…'를 모르므로 UTF-8 바이트로 찾는다: U+200B–200F, U+202A–202E, U+2060, U+2066–2069, U+FEFF.
  if printf '%s' "$text" | LC_ALL=C grep -qE $'\xe2\x80[\x8b-\x8f\xaa-\xae]|\xe2\x81[\xa0\xa6-\xa9]|\xef\xbb\xbf'; then
    echo "규칙에 보이지 않는 유니코드 문자를 넣을 수 없습니다" >&2
    exit 2
  fi
  # 비밀값처럼 보이는 문자열(오류 발췌 가림 규칙에 걸리는 것)은 지침에 남기지 않는다.
  if [[ "$(printf '%s' "$text" | jq -Rr -L "$DIR" 'include "redact"; redact' 2>/dev/null)" != "$text" ]]; then
    echo "규칙에 비밀값처럼 보이는 문자열을 넣을 수 없습니다" >&2
    exit 2
  fi
  if [[ -n "$signal" ]] && ! jq -n --arg re "$signal" '"" | test($re)' >/dev/null 2>&1; then
    echo "--signal 정규식이 올바르지 않습니다" >&2
    exit 2
  fi
  if printf '%s' "$text" | grep -qiE '(https?://|`|\bcurl\b|\bwget\b|\b(ba|z)?sh -c\b|\beval\b|ignore (all |the )?(previous|above)|disregard|이전 지침|위 지침|무시하)'; then
    echo "규칙에 URL·코드 블록·명령 실행·지침 무력화 표현을 넣을 수 없습니다" >&2
    exit 2
  fi
  local active_count=0
  active_count="$(command_list --active | jq -s --arg scope "$scope" --arg ws "$workspace" --arg id "$id" \
    '[.[] | select(.scope == $scope and (.workspace // "") == $ws and .id != $id)] | length' 2>/dev/null || echo 0)"
  if (( active_count >= RULES_MAX )); then
    echo "자동 규칙 상한(${RULES_MAX}개)에 닿았습니다 — 비슷한 규칙을 같은 id로 병합하거나 효과 없는 규칙을 revert한 뒤 추가하세요" >&2
    exit 5
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
    --arg snapshot "$snap" --arg signal "$signal" '{at:$at,event:"applied",id:$id,scope:$scope,text:$text,evidence:$evidence,
      signal:(if $signal=="" then null else $signal end),
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
    | .[] | {id, state:(if .event=="applied" then "active" else "reverted" end), scope, at, text, expected,
             signal:(.signal // null), workspace:(.workspace // null), project:(.project // null)}' "$LOG"
}

# 규칙별 효과를 수치로: --signal 정규식에 맞는 오류 발췌·교정 신호가 있는 세션의 비율을
# 적용 전(직전 30일)과 적용 후(적용 뒤 시작한 세션)로 나눠 100세션당 값으로 낸다. 적용 후 세션이
# HM_EFFECT_MIN_SESSIONS(30)개 미만이거나, 적용 전 발생률로 예상되는 적용 후 건수가 HM_EFFECT_MIN_EXPECTED(5) 미만이면
# 표본이 작아 pending. 절반 이하로 줄면 improved, 그대로거나 늘면 no_effect. workspace 규칙은 그 프로젝트 세션만 센다.
command_effect() {
  local only="" rules=""
  [[ "${1:-}" == "--rule-id" ]] && only="${2:-}"
  rules="$(command_list --active | jq -sc --arg only "$only" '[.[] | select(.signal != null and ($only == "" or .id == $only))]')"
  [[ "$rules" != "[]" ]] || return 0
  shopt -s nullglob
  local files=("$HM_DATA_DIR"/events/*.jsonl "$HM_DATA_DIR"/rollups/*.jsonl)
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || return 0
  grep -h -E '"kind":"(session|error_sample|correction_mark|correction_candidate)"' "${files[@]}" 2>/dev/null \
    | jq -sc --argjson rules "$rules" --argjson min "${HM_EFFECT_MIN_SESSIONS:-30}" \
      --argjson min_expected "${HM_EFFECT_MIN_EXPECTED:-5}" '
      (map(select(.kind == "session" and ((.internal // false) | not)))
        # 지침 파일은 세션 시작 때 읽히므로, 적용 전에 시작한 세션은 새 규칙을 본 적이 없다 — 시작 시각으로 나눈다.
        | map({key:(.src + ":" + .sid), value:{at:(.started // .ended // ""), project}}) | from_entries) as $sessions
      | (map(select(.kind != "session")) | group_by(.src + ":" + .sid)
        | map({key:(.[0].src + ":" + .[0].sid), value:(map(.target // "") | join("\n"))}) | from_entries) as $signals
      | $rules[] as $r
      | ($r.at) as $at
      | ($at | sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime - 30 * 86400 | strftime("%Y-%m-%dT%H:%M:%SZ")) as $since
      | [$sessions | to_entries[]
          | select($r.scope == "global" or .value.project == $r.project)
          | {k:.key, at:.value.at, hit:(($signals[.key] // "") | test($r.signal))}] as $scoped
      | def rate($xs): {sessions:($xs | length), hits:([$xs[] | select(.hit)] | length),
          per100:(if ($xs | length) == 0 then null else (([$xs[] | select(.hit)] | length) * 100 / ($xs | length) * 10 | round / 10) end)};
        rate([$scoped[] | select(.at >= $since and .at < $at)]) as $before
        | rate([$scoped[] | select(.at >= $at)]) as $after
        # 세션 수만으로는 부족하다 — 드문 오류는 적용 후 기대 건수가 1건 미만이라 1건 차이도 노이즈다.
        # 적용 전 발생률로 예상되는 적용 후 건수가 $min_expected 이상일 때만 판정한다.
        | (if $before.per100 == null then 0 else $before.per100 * $after.sessions / 100 end) as $expected
        | ($after.sessions >= $min and $expected >= $min_expected) as $judgeable
        | {id:$r.id, signal:$r.signal, applied_at:$at, before:$before, after:$after,
           expected_after_hits:($expected * 10 | round / 10), judgeable:$judgeable,
           verdict:(if ($judgeable | not) or $before.per100 == null then "pending"
                    elif $after.per100 <= $before.per100 * 0.5 then "improved"
                    elif $after.per100 >= $before.per100 then "no_effect"
                    else "unclear" end)}'
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
  effect) command_effect "$@" ;;
  notify) command_notify ;;
  *) usage ;;
esac
