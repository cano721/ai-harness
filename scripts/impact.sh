#!/usr/bin/env bash
# 하네스 도입 효과 (읽기 전용 집계 + 리포트).
#   impact.sh compare [--root <dir>] [--project <id>] [--at YYYY-MM-DD] [--window <days>] [--today YYYY-MM-DD] [--author <pattern>]
#       최근 window일(후)과 설치일 직전 같은 길이(전)를 비교한 JSON을 낸다.
#       설치일: --at → <root>/.ai-harness/harness.json initialized → AGENTS.md 첫 커밋 날짜. 셋 다 없으면 exit 3.
#   impact.sh render --data <json> [--highlights <json>] [--out <html>]
#       compare JSON과 (에이전트가 교정을 묶은) 하이라이트 JSON을 오프라인 HTML 한 파일로 만든다. 경로를 출력한다.
#   impact.sh notify   (SessionStart stdin JSON)
#       설치 후 HM_IMPACT_HINT_DAYS(기본 30)일이 지난 하네스 프로젝트에서 한 번만 안내한다. HM_IMPACT_HINT=0이면 끈다.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DIR/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh" || { [[ "${1:-}" == "notify" ]] && exit 0; exit 1; }

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

valid_date() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }

git_root() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || true; }

# 설치일과 그 출처를 "date<TAB>source"로 낸다.
install_date() { # $1=root $2=--at
  local root="$1" at="$2" d=""
  if [[ -n "$at" ]]; then printf '%s\tat\n' "$at"; return 0; fi
  if [[ -f "$root/.ai-harness/harness.json" ]]; then
    d="$(jq -r '.initialized // empty' "$root/.ai-harness/harness.json" 2>/dev/null || true)"
    if valid_date "$d"; then printf '%s\tharness.json\n' "$d"; return 0; fi
  fi
  if [[ -n "$(git_root "$root")" ]]; then
    d="$(git -C "$root" log --diff-filter=A --format=%as -- AGENTS.md 2>/dev/null | tail -1)"
    if valid_date "$d"; then printf '%s\tagents_md_commit\n' "$d"; return 0; fi
  fi
  return 1
}

prev_day() { jq -rn --arg d "$1" '$d + "T00:00:00Z" | fromdateiso8601 - 86400 | todate[0:10]'; }

rework_json() { # repo author since until(포함) → JSON 또는 null
  local out=""
  out="$("$DIR/rework.sh" --repo "$1" --author "$2" --since "$3" --until "$4" 2>/dev/null)" || out=""
  if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then printf '%s\n' "$out"; else printf 'null\n'; fi
}

need_value() { (($# >= 2)) || usage; }

command_compare() {
  local root="" project="" at="" window=30 today="" author="" installed="" inst_date="" inst_src=""
  while (($#)); do
    case "$1" in
      --root) root="${2:-}"; need_value "$@"; shift 2 ;;
      --project) project="${2:-}"; need_value "$@"; shift 2 ;;
      --at) at="${2:-}"; need_value "$@"; shift 2 ;;
      --window) window="${2:-}"; need_value "$@"; shift 2 ;;
      --today) today="${2:-}"; need_value "$@"; shift 2 ;;
      --author) author="${2:-}"; need_value "$@"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$window" =~ ^[1-9][0-9]*$ ]] || { echo "잘못된 --window: $window" >&2; exit 2; }
  for d in "$at" "$today"; do
    [[ -z "$d" ]] || valid_date "$d" || { echo "잘못된 날짜: $d (YYYY-MM-DD)" >&2; exit 2; }
  done
  [[ -n "$today" ]] || today="$(date -u +%Y-%m-%d)"
  if [[ -z "$root" ]]; then
    root="$(git_root "$PWD")"
    [[ -n "$root" ]] || root="$PWD"
  fi
  if [[ -z "$project" && -f "$root/.ai-harness/harness.json" ]]; then
    project="$(jq -r '.project_id // empty' "$root/.ai-harness/harness.json" 2>/dev/null || true)"
  fi
  [[ -n "$project" ]] || project="$(project_id_for_cwd "$root")"
  installed="$(install_date "$root" "$at")" || {
    echo "설치일을 찾지 못함: $root 에 .ai-harness/harness.json(initialized)·AGENTS.md 커밋이 없음. --at YYYY-MM-DD 로 지정" >&2
    exit 3
  }
  inst_date="${installed%%$'\t'*}"
  inst_src="${installed#*$'\t'}"

  # 구간: 후 = 최근 window일(설치일보다 앞서지 않게), 전 = 설치일 직전 같은 길이. 지금 체감과 설치 전을 맞댄다.
  local range=""
  range="$(jq -rn --arg at "$inst_date" --arg today "$today" --argjson w "$window" '
    def ep: . + "T00:00:00Z" | fromdateiso8601;
    def day: todate[0:10];
    ($at | ep) as $a
    | (($today | ep) + 86400) as $u
    | ([($u - $w * 86400), $a] | max) as $asince
    | ([((($u - $asince) / 86400) | floor), 0] | max) as $len
    | [($a - $len * 86400 | day), ($asince | day), ($u | day), ($len | tostring)] | join("\t")')"
  local before_since="" after_since="" after_until="" len=""
  IFS=$'\t' read -r before_since after_since after_until len <<<"$range"

  shopt -s nullglob
  local files=("$HM_DATA_DIR"/events/*.jsonl) rollup=""
  for rollup in "$HM_DATA_DIR"/rollups/*.jsonl; do
    [[ -f "$HM_DATA_DIR/events/$(basename "$rollup")" ]] || files+=("$rollup")
  done
  local digests=("$HM_DATA_DIR"/digests/*.json)
  local history="" qkey=""
  qkey="$(hm_project_key "$project")"
  history="$HM_DATA_DIR/harvest-queue/$qkey/review-history.jsonl"
  local applied="$HM_DATA_DIR/applied/applied.jsonl"
  IMPACT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-harness-impact.XXXXXX")"
  trap 'find "$IMPACT_TMP" -depth -delete 2>/dev/null || true' EXIT
  local tmp="$IMPACT_TMP"

  # 세션별 이벤트 파일 이름(확장자 뺀 것)이 digest 파일 이름과 같다.
  if ((${#files[@]} > 0)); then
    # 기록 중인 파일의 잘린 마지막 줄 같은 깨진 줄은 건너뛴다.
    jq -cRn 'inputs | (fromjson? // empty) | select(type == "object" and .kind != null)
      | . + {_f: (input_filename | split("/") | last | rtrimstr(".jsonl"))}' "${files[@]}" >"$tmp/events.jsonl"
  else
    : >"$tmp/events.jsonl"
  fi
  if ((${#digests[@]} > 0)); then
    # LLM이 쓴 JSON이라 파일 단위로 읽고, 깨진 파일은 건너뛴다(-R 줄 단위 → 파일별로 다시 붙여 파싱).
    jq -cRn '[inputs | {f: input_filename, l: .}] | group_by(.f)
      | map((.[0].f | split("/") | last | rtrimstr(".json")) as $k
        | (map(.l) | join("\n") | fromjson? // null) as $j
        | select($j | type == "object" and (((.v // 0) | numbers) >= 2))
        | {($k): [($j.findings // [])[]? | objects | select(.category == "correction") | {summary, evidence}]})
      | add // {}' "${digests[@]}" >"$tmp/digests.json"
  else
    printf '{}\n' >"$tmp/digests.json"
  fi
  { [[ -f "$history" ]] && jq -cR 'fromjson?' "$history"; true; } | jq -s . >"$tmp/history.json"
  { [[ -f "$applied" ]] && jq -cR 'fromjson?' "$applied"; true; } | jq -s . >"$tmp/applied.json"

  # rework.sh의 --until은 그 날을 포함하므로 미포함 끝의 전날을 넘긴다.
  local rework_before="null" rework_after="null"
  if [[ -n "$author" && -n "$(git_root "$root")" ]]; then
    rework_before="$(rework_json "$root" "$author" "$before_since" "$(prev_day "$inst_date")")"
    rework_after="$(rework_json "$root" "$author" "$after_since" "$(prev_day "$after_until")")"
  fi

  jq -n \
    --arg project "$project" --arg root "$root" --arg inst "$inst_date" --arg src "$inst_src" \
    --arg bs "$before_since" --arg asince "$after_since" --arg au "$after_until" --argjson len "$len" --arg today "$today" \
    --slurpfile digests "$tmp/digests.json" --slurpfile history "$tmp/history.json" --slurpfile applied "$tmp/applied.json" \
    --argjson rb "$rework_before" --argjson ra "$rework_after" \
    -f "$DIR/impact.jq" "$tmp/events.jsonl"
}

command_render() {
  local data="" highlights="" out=""
  while (($#)); do
    case "$1" in
      --data) data="${2:-}"; need_value "$@"; shift 2 ;;
      --highlights) highlights="${2:-}"; need_value "$@"; shift 2 ;;
      --out) out="${2:-}"; need_value "$@"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -f "$data" ]] || { echo "데이터 파일 없음: $data" >&2; exit 2; }
  [[ -z "$highlights" || -f "$highlights" ]] || { echo "하이라이트 파일 없음: $highlights" >&2; exit 2; }
  if [[ -z "$out" ]]; then
    out="$HM_DATA_DIR/reports/impact-$(hm_short_key "$(jq -r '.project // "project"' "$data")")-$(date -u +%Y-%m-%d).html"
  fi
  mkdir -p "$(dirname "$out")"
  local hl_json="null"
  [[ -n "$highlights" ]] && hl_json="$(jq -c . "$highlights")"
  # 데이터 속 '<'를 <로 바꿔 </script>·<!-- 가 페이지 구조를 깨지 못하게 한다.
  jq -rn --rawfile t "$ROOT_DIR/skills/harness-impact/report-template.html" \
    --slurpfile d "$data" --argjson h "$hl_json" '
    def safe: tojson | gsub("<"; "\\u003c");
    $t | split("/*__IMPACT_DATA__*/null") | join($d[0] | safe)
       | split("/*__IMPACT_HIGHLIGHTS__*/null") | join($h | safe)' >"$out"
  printf '%s\n' "$out"
}

command_notify() {
  local input="" cwd="" root="" inst="" today="" days="" key="" marker=""
  input="$(cat)"
  [[ "${HM_IMPACT_HINT:-1}" == "0" ]] && return 0
  cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null || true)"
  [[ -n "$cwd" && -d "$cwd" ]] || return 0
  root="$(git_root "$cwd")"
  [[ -n "$root" ]] || root="$cwd"
  [[ -f "$root/.ai-harness/harness.json" ]] || return 0
  inst="$(jq -r '.initialized // empty' "$root/.ai-harness/harness.json" 2>/dev/null || true)"
  valid_date "$inst" || return 0
  today="${HM_IMPACT_TODAY:-$(date -u +%Y-%m-%d)}"
  days="$(jq -rn --arg a "$inst" --arg b "$today" '(($b + "T00:00:00Z" | fromdateiso8601) - ($a + "T00:00:00Z" | fromdateiso8601)) / 86400 | floor' 2>/dev/null)" || return 0
  [[ "$days" =~ ^-?[0-9]+$ ]] || return 0
  (( days >= ${HM_IMPACT_HINT_DAYS:-30} )) || return 0
  key="$(jq -r '.project_id // empty' "$root/.ai-harness/harness.json" 2>/dev/null || true)"
  [[ -n "$key" ]] || key="$(project_id_for_cwd "$root")"
  key="$(hm_short_key "$key")"
  marker="$HM_DATA_DIR/impact-hint-shown/$key"
  [[ -e "$marker" ]] && return 0
  mkdir -p "${marker%/*}" 2>/dev/null && : >"$marker" 2>/dev/null || return 0
  jq -cn --arg d "$days" '{systemMessage:("하네스 도입 \($d)일째예요. \"하네스 효과 보여줘\"라고 하면 도입 전후 비교 리포트를 볼 수 있어요. (이 안내는 한 번만 표시됩니다)")}'
}

cmd="${1:-}"
shift || true
case "$cmd" in
  compare) command_compare "$@" ;;
  render) command_render "$@" ;;
  # SessionStart hook: 어떤 실패도 세션을 막거나 오류로 보이지 않게 한다.
  notify) command_notify "$@" 2>/dev/null || true; exit 0 ;;
  *) usage ;;
esac
