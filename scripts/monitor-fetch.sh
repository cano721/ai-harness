#!/usr/bin/env bash
# 저장소 manifest(.ai-harness/harness.json)의 `monitor` 설정을 읽어 모니터링 도구에서 에러를 가져온다.
# 도구마다 다른 응답을 한 형식으로 맞춘다 — 자동 버그 수정(autofix-auto.sh)의 감지·검증 단계가 쓴다.
#   list:   기준 시간 안에 min_events 이상 발생한 에러 묶음(JSON lines, 많은 순)
#   detail: 에러 하나의 스택·샘플(비밀값 가림)
#   count:  기준 시각 이후 같은 에러가 다시 나왔는지 — 수정 검증용
# 자격증명은 저장소 설정에 두지 않는다: 환경변수 → ~/.ai-harness/config → ~/.claude/settings.json env 순으로 찾는다.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  monitor-fetch.sh check  --root <repo>                                  # 설정·자격증명·접근 확인
  monitor-fetch.sh list   --root <repo> [--hours N]                       # 후보 에러(JSON lines)
  monitor-fetch.sh detail --root <repo> --meta <json>                     # 스택·샘플(JSON)
  monitor-fetch.sh count  --root <repo> --meta <json> --since <iso>       # {seen,count,last_seen}
env:
  HM_MONITOR_HTTP   테스트용 HTTP 실행기: "<cmd> <METHOD> <URL> [<body>]" → 응답 본문
  HM_SENTRY_URL     자체 호스팅 Sentry 주소(저장소 설정의 base_url은 *.sentry.io만 받는다)
EOF
  exit 2
}

ROOT_DIR=""; HOURS=""; META="{}"; SINCE=""
action="${1:-}"; shift || true
while (( $# > 0 )); do
  case "$1" in
    --root) ROOT_DIR="${2:-}"; shift 2 ;;
    --hours) HOURS="${2:-}"; shift 2 ;;
    --meta) META="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$ROOT_DIR" && -d "$ROOT_DIR" ]] || usage
jq -e 'type == "object"' <<<"$META" >/dev/null 2>&1 || { echo "--meta는 JSON 객체여야 합니다" >&2; exit 2; }

die() { printf '%s\n' "$1" >&2; exit "${2:-3}"; }

# 사용자 체크아웃이 아니라 하네스가 실제로 들어 있는 기준 브랜치의 설정을 본다(자동 sync와 같은 기준).
manifest="$(git -C "$ROOT_DIR" show "$(hm_resolve_base "$ROOT_DIR" --no-fetch):.ai-harness/harness.json" 2>/dev/null \
  || cat "$ROOT_DIR/.ai-harness/harness.json" 2>/dev/null)"
monitor="$(jq -c '.monitor // empty' <<<"$manifest" 2>/dev/null)"
[[ -n "$monitor" ]] || die "monitor 설정 없음: $ROOT_DIR/.ai-harness/harness.json" 4
cfg() { jq -r --arg k "$1" '.[$k] // empty | tostring' <<<"$monitor"; }
provider="$(cfg provider)"
[[ -n "$HOURS" ]] || HOURS="$(cfg window_hours)"
[[ "$HOURS" =~ ^[1-9][0-9]*$ ]] || HOURS=24
MIN_EVENTS="$(cfg min_events)"; [[ "$MIN_EVENTS" =~ ^[0-9]+$ ]] || MIN_EVENTS=10

# 자격증명: 환경변수 → ~/.ai-harness/config의 HM_ 키 → ~/.claude/settings.json의 env. launchd·백그라운드 실행에는
# 셸 환경변수가 없어서, Claude Code 사용자가 이미 settings.json env에 둔 키를 그대로 쓴다.
secret() { # $@=후보 변수 이름 → 첫 값
  local name="" value=""
  for name in "$@"; do
    value="${!name:-}"
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
  done
  for name in "$@"; do
    value="$(jq -r --arg k "$name" '.env[$k] // empty' "${HARNESS_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}" 2>/dev/null)"
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
  done
}

# 자격증명은 프로세스 인자(ps에 보임) 대신 stdin 설정으로 넘긴다. $1=METHOD $2=URL [$3=body], 헤더는 HTTP_HEADERS.
HTTP_HEADERS=()
http() {
  if [[ -n "${HM_MONITOR_HTTP:-}" ]]; then
    local -a cmd=()
    read -r -a cmd <<<"$HM_MONITOR_HTTP"
    "${cmd[@]}" "$@"
    return
  fi
  local header="" response="" status=""
  local -a body=()
  [[ -n "${3:-}" ]] && body=(-H 'Content-Type: application/json' --data "$3")
  response="$(for header in "${HTTP_HEADERS[@]}"; do printf 'header = "%s"\n' "$header"; done \
    | curl -sS --max-time 30 -K - -X "$1" "${body[@]+"${body[@]}"}" -w '\n%{http_code}' "$2")" \
    || die "요청 실패: $2"
  status="${response##*$'\n'}"
  [[ "$status" == 2* ]] || die "HTTP $status: $2 — $(printf '%s' "${response%$'\n'*}" | head -c 200)"
  printf '%s\n' "${response%$'\n'*}"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Sentry: 이미 이슈로 묶여 있으므로 이슈 ID가 시그니처다 ──────────────────────────
sentry_setup() {
  local token="" base=""
  org="$(cfg org)"; project="$(cfg project)"; environment="$(cfg environment)"
  [[ "$org" =~ ^[A-Za-z0-9._-]+$ && "$project" =~ ^[A-Za-z0-9._-]+$ ]] || die "monitor.org·monitor.project가 필요합니다" 4
  # 저장소 설정이 자격증명을 보낼 곳을 정하지 못하게 한다 — 자체 호스팅 주소는 개인 config에서만 받는다.
  base="${HM_SENTRY_URL:-$(cfg base_url)}"
  [[ -n "$base" ]] || base="https://sentry.io"
  base="${base%/}"
  if [[ -z "${HM_SENTRY_URL:-}" && ! "$base" =~ ^https://([a-z0-9-]+\.)?sentry\.io$ ]]; then
    die "monitor.base_url은 *.sentry.io만 받습니다. 자체 호스팅은 ~/.ai-harness/config의 HM_SENTRY_URL로 지정하세요" 4
  fi
  SENTRY_BASE="$base"
  token="$(secret HM_SENTRY_TOKEN SENTRY_AUTH_TOKEN)"
  [[ -n "$token" || -n "${HM_MONITOR_HTTP:-}" ]] || die "Sentry 토큰 없음: SENTRY_AUTH_TOKEN(또는 HM_SENTRY_TOKEN)" 4
  HTTP_HEADERS=("Authorization: Bearer $token")
}

sentry_list() {
  # 24시간 창은 시간 단위 통계, 그보다 길면 14일 일 단위 통계에서 창만큼 더한다.
  local period="24h" buckets="$HOURS"
  (( HOURS > 24 )) && { period="14d"; buckets=$(( (HOURS + 23) / 24 )); }
  local url="$SENTRY_BASE/api/0/projects/$org/$project/issues/?query=is:unresolved&statsPeriod=$period&sort=freq&limit=50"
  [[ -n "$environment" ]] && url+="&environment=$(jq -rn --arg v "$environment" '$v|@uri')"
  http GET "$url" | jq -c --argjson min "$MIN_EVENTS" --argjson n "$buckets" --arg period "$period" '
    .[]? | {
      signature: ("sentry:" + (.id|tostring)), provider: "sentry",
      title: (.title // ""), culprit: (.culprit // ""),
      count: ([(.stats[$period] // [])[-$n:][]?[1]] | add // 0),
      first_seen: (.firstSeen // null), last_seen: (.lastSeen // null),
      link: (.permalink // null), meta: {id: (.id|tostring)}
    } | select(.count >= $min)'
}

sentry_detail() {
  local id=""
  id="$(jq -r '.id // empty' <<<"$META")"
  [[ "$id" =~ ^[0-9]+$ ]] || die "meta.id가 필요합니다" 2
  http GET "$SENTRY_BASE/api/0/organizations/$org/issues/$id/events/latest/" | jq -c '
    {
      message: (.message // .title // ""),
      exception: [(.entries // [])[] | select(.type == "exception") | .data.values[]? | {
        type, value,
        frames: [(.stacktrace.frames // [])[-15:] | reverse[] | {
          file: (.filename // .module // ""), function: (.function // ""), line: .lineNo, in_app: (.inApp // false)
        }]
      }],
      tags: [(.tags // [])[] | select(.key | test("^(environment|release|transaction|url|server_name)$")) | {(.key): .value}] | add,
      release: (.release.version? // null), date: (.dateCreated // null)
    }'
}

sentry_count() {
  local id=""
  id="$(jq -r '.id // empty' <<<"$META")"
  [[ "$id" =~ ^[0-9]+$ ]] || die "meta.id가 필요합니다" 2
  local url=""
  url="$SENTRY_BASE/api/0/organizations/$org/issues/$id/events/?start=$(jq -rn --arg v "$SINCE" '$v|@uri')&end=$(jq -rn --arg v "$(now_iso)" '$v|@uri')&per_page=100"
  # 다른 환경(스테이징 등)의 같은 이슈를 재발로 세지 않는다.
  [[ -n "$environment" ]] && url+="&environment=$(jq -rn --arg v "$environment" '$v|@uri')"
  http GET "$url" \
    | jq -c --arg since "$SINCE" '
      [.[]? | select((.dateCreated // "") >= $since)] as $e
      | {seen: ($e | length > 0), count: ($e | length), last_seen: ([$e[].dateCreated] | max)}'
}

# ── Datadog: 로그를 직접 묶는다. 같은 버그가 수정 커밋 뒤 줄 번호만 바뀌어도 같은 묶음이 되게 줄 번호를 지운다 ──
DD_GROUP='
  def frame: (.stack // "") | split("\n") | map(select(test("^\\s*(at |File \")")))
    | (first // "") | gsub("^\\s+"; "") | gsub(":[0-9]+(:[0-9]+)?\\)"; ")") | gsub(", line [0-9]+"; "");
  def norm: gsub("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"; "<uuid>")
    | gsub("0x[0-9a-fA-F]+"; "<hex>") | gsub("[0-9]+"; "<n>") | .[0:200];
  [.data[]?.attributes | {
      service: (.service // ""), ts: (.timestamp // ""),
      kind: (.attributes.error.kind // ""), message: (.attributes.error.message // .message // ""),
      stack: (.attributes.error.stack // "")
    }
    | . + {key: ([.service, .kind, (if (.|frame) != "" then (.|frame) else (.message|norm) end)] | join("|"))}]'

datadog_setup() {
  local site="" api="" app=""
  query="$(cfg query)"
  [[ -n "$query" ]] || die "monitor.query가 필요합니다 (예: service:api env:prod status:error)" 4
  site="$(cfg site)"; [[ -n "$site" ]] || site="datadoghq.com"
  # 자격증명을 보낼 곳은 공개 Datadog 사이트로만 한정한다.
  case "$site" in
    datadoghq.com|us3.datadoghq.com|us5.datadoghq.com|datadoghq.eu|ap1.datadoghq.com|ap2.datadoghq.com|ddog-gov.com) ;;
    *) die "지원하지 않는 monitor.site: $site" 4 ;;
  esac
  DD_BASE="https://api.$site"
  api="$(secret HM_DATADOG_API_KEY DATADOG_API_KEY DD_API_KEY)"
  app="$(secret HM_DATADOG_APP_KEY DATADOG_APP_KEY DD_APP_KEY)"
  [[ ( -n "$api" && -n "$app" ) || -n "${HM_MONITOR_HTTP:-}" ]] || die "Datadog 키 없음: DATADOG_API_KEY·DATADOG_APP_KEY" 4
  HTTP_HEADERS=("DD-API-KEY: $api" "DD-APPLICATION-KEY: $app")
}

datadog_search() { # $1=query $2=from
  http POST "$DD_BASE/api/v2/logs/events/search" \
    "$(jq -cn --arg q "$1" --arg from "$2" '{filter:{query:$q,from:$from,to:"now"},sort:"-timestamp",page:{limit:1000}}')"
}

hash16() { { shasum 2>/dev/null || sha1sum; } | cut -c1-16; }

# 묶음 키(정규화한 메시지·프레임)는 저장하지 않는다 — 사용자 데이터가 섞일 수 있어 해시만 상태·에이전트 입력에 남긴다.
datadog_list() {
  datadog_search "$query" "now-${HOURS}h" | jq -c --argjson min "$MIN_EVENTS" "$DD_GROUP"'
    | group_by(.key)[] | select(length >= $min)
    | {provider: "datadog", key: .[0].key, title: ((.[0].kind | if . == "" then "" else . + ": " end) + .[0].message | .[0:200]),
       culprit: .[0].service, count: length, first_seen: (map(.ts) | min), last_seen: (map(.ts) | max), link: null,
       meta: {kind: .[0].kind, service: .[0].service}}' \
    | while IFS= read -r row; do
        local h=""
        h="$(jq -r '.key' <<<"$row" | hash16)"
        jq -c --arg h "$h" '{signature: ("datadog:" + $h)} + (del(.key) | .meta.hash = $h)' <<<"$row"
      done
}

# 검색 결과에서 meta.hash에 맞는 묶음 키를 찾는다(없으면 빈 출력).
datadog_key_for_hash() { # stdin=검색 응답
  local want="" key=""
  want="$(jq -r '.hash // empty' <<<"$META")"
  [[ "$want" =~ ^[0-9a-f]{16}$ ]] || die "meta.hash가 필요합니다" 2
  while IFS= read -r key; do
    [[ "$(printf '%s\n' "$key" | hash16)" == "$want" ]] && { printf '%s' "$key"; return; }
  done < <(jq -r "$DD_GROUP"' | map(.key) | unique[]')
}

datadog_scoped_query() { # meta의 kind·service로 검색을 좁힌다(1000건 한도 안에 같은 에러가 들게)
  local q="$query" kind="" service=""
  kind="$(jq -r '.kind // empty' <<<"$META")"; service="$(jq -r '.service // empty' <<<"$META")"
  [[ -n "$kind" ]] && q+=" @error.kind:$(jq -rn --arg v "$kind" '$v|@json')"
  [[ -n "$service" ]] && q+=" service:$(jq -rn --arg v "$service" '$v|@json')"
  printf '%s' "$q"
}

datadog_detail() {
  local resp="" key=""
  resp="$(datadog_search "$(datadog_scoped_query)" "now-${HOURS}h")" || return
  key="$(datadog_key_for_hash <<<"$resp")"
  jq -c --arg key "$key" "$DD_GROUP"'
    | map(select(.key == $key)) | first // {} | {message, kind, service, stack: (.stack // "" | .[0:6000]), date: .ts}' <<<"$resp"
}

datadog_count() {
  local resp="" key=""
  resp="$(datadog_search "$(datadog_scoped_query)" "$SINCE")" || return
  key="$(datadog_key_for_hash <<<"$resp")"
  jq -c --arg key "$key" --arg since "$SINCE" "$DD_GROUP"'
    | map(select($key != "" and .key == $key and .ts >= $since)) | {seen: (length > 0), count: length, last_seen: (map(.ts) | max)}' <<<"$resp"
}

# ── command: 저장소 안의 어댑터 스크립트가 같은 형식을 낸다 ──────────────────────────
command_setup() {
  local rel=""
  rel="$(cfg command)"
  # 저장소 밖 실행 파일을 가리키지 못하게 상대 경로만 받는다.
  [[ -n "$rel" && "$rel" != /* && "$rel" != *..* ]] || die "monitor.command는 저장소 안 상대 경로여야 합니다" 4
  ADAPTER="$ROOT_DIR/$rel"
  [[ -x "$ADAPTER" ]] || die "실행할 수 없는 monitor.command: $ADAPTER" 4
}
adapter() { (cd "$ROOT_DIR" && hm_run_with_timeout 120 "$ADAPTER" "$@"); }

# 시그니처·meta는 검증 때 그대로 비교하는 키라 가리지 않는다(Datadog 키는 숫자를 이미 지운 정규화 문자열이다).
redact_json() {
  jq -c -L "$DIR" 'include "redact";
    with_entries(if .key == "signature" or .key == "meta" then . else .value |= walk(if type == "string" then redact else . end) end)'
}

case "$provider" in
  sentry) sentry_setup ;;
  datadog) datadog_setup ;;
  command) command_setup ;;
  "") die "monitor.provider가 필요합니다 (sentry | datadog | command)" 4 ;;
  *) die "지원하지 않는 monitor.provider: $provider" 4 ;;
esac

case "$action" in
  check)
    case "$provider" in
      sentry) sentry_list >/dev/null ;;
      datadog) datadog_search "$query" "now-1h" >/dev/null ;;
      command) adapter list 1 >/dev/null || die "어댑터 실행 실패: $ADAPTER" ;;
    esac || exit $?
    printf 'ok %s\n' "$provider"
    ;;
  list)
    case "$provider" in
      command) adapter list "$HOURS" | jq -c --argjson min "$MIN_EVENTS" 'select(.signature and (.count // 0) >= $min) | .meta //= {}' ;;
      *) "${provider}_list" ;;
    esac | jq -sc 'sort_by(-.count)[]' | redact_json
    ;;
  detail)
    case "$provider" in
      command) adapter detail "$META" ;;
      *) "${provider}_detail" ;;
    esac | redact_json
    ;;
  count)
    [[ -n "$SINCE" ]] || usage
    case "$provider" in
      command) adapter count "$META" "$SINCE" | jq -c '{seen: (.seen // ((.count // 0) > 0)), count: (.count // 0), last_seen: (.last_seen // null)}' ;;
      *) "${provider}_count" ;;
    esac
    ;;
  *) usage ;;
esac
