#!/usr/bin/env bash
# PreToolUse(Bash) 가드: 스키마 조건 없는 information_schema 정의·메타 테이블 조회를 실행 전에 막는다.
# 판정 기준은 README "DB 스캔 가드". 끄기: HM_DB_SCAN_GUARD=0. jq가 없거나 입력을 읽지 못하면 통과한다.
set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
cmd="$(jq -r '.tool_input.command // "" | if type == "array" then join(" ") else tostring end' <<<"$input" 2>/dev/null || true)"
[[ -n "$cmd" ]] || exit 0

# 대부분의 Bash 호출은 여기서 끝난다.
shopt -s nocasematch
[[ "$cmd" == *information_schema* ]] || exit 0
shopt -u nocasematch

# 환경변수가 없으면 다른 HM_* 설정과 같은 config에서 읽는다. lib.sh는 디렉터리 생성 같은 부수효과가 있어 쓰지 않는다.
if [[ -z "${HM_DB_SCAN_GUARD:-}" ]]; then
  config="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/config"
  # shellcheck source=/dev/null
  [[ -f "$config" ]] && source "$config"
fi
[[ "${HM_DB_SCAN_GUARD:-1}" == "0" ]] && exit 0

hit="$(jq -rn --arg s "$cmd" '
  def has($re): $s | test($re; "i");
  ("(^|[\\s;&|(`])(mysql|mariadb|mysqlsh|mycli|psql|pgcli|usql)(\\s|$)"
   + "|pymysql|mysql\\.connector|MySQLdb|aiomysql|mysql2|sqlalchemy|create_engine|jdbc:"
   + "|(mysql|mariadb|postgres(ql)?)://|psycopg|asyncpg|pg8000") as $client
  | ("(^|[\\s;&|(`])(psql|pgcli)(\\s|$)|postgres(ql)?://|jdbc:postgresql|psycopg|asyncpg|pg8000") as $pg
  | ("(^|[\\s;&|(`])(mysql|mariadb|mysqlsh|mycli)(\\s|$)|pymysql|mysql\\.connector|MySQLdb|aiomysql|mysql2|(mysql|mariadb)://|jdbc:(mysql|mariadb)") as $my
  | if has($client) | not then empty else
      (has($pg) and (has($my) | not)) as $is_pg
      | (["views", "routines", "triggers", "events", "parameters"]
         + (if $is_pg then [] else
              ["tables", "columns", "statistics", "key_column_usage", "referential_constraints",
               "table_constraints", "check_constraints", "partitions",
               "view_table_usage", "view_routine_usage"] end)
         | join("|")) as $names
      | ("`?information_schema`?\\s*\\.\\s*`?(?<t>" + $names + ")`?\\b") as $qualified
      | ("\\b(from|join)\\s+`?(?<t>" + $names + ")`?\\b") as $bare
      # information_schema가 테이블 한정자가 아닌 자리(USE·DB 인자)에 나오면 비한정 이름도 대상이다.
      | has("\\binformation_schema`?(?!`?\\s*\\.)") as $in_ctx
      | [ $s | splits(";|\\bunion\\b"; "i")
          | select(test("\\b\\w*_schema`?\\s*(=|<=>|in\\s*\\()"; "i") | not)
          | (capture($qualified; "i") // (if $in_ctx then capture($bare; "i") else empty end))
          | .t | ascii_upcase ]
      | first // empty
    end
' 2>/dev/null || true)"

[[ -n "$hit" ]] || exit 0

reason="[DB scan guard] information_schema.${hit}를 스키마 조건 없이 조회하면 모든 스키마를 훑습니다. 각 구문과 UNION 분기에 table_schema = 'app' 같은 *_schema 조건을 넣으세요. 전체 조회가 꼭 필요하면 사용자에게 직접 실행을 요청하세요."
jq -cn --arg reason "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$reason}}'
