#!/usr/bin/env bash
# PreToolUse(Bash) 가드(opt-in): 스키마 조건 없는 information_schema 정의·메타 테이블 조회를 실행 전에 막는다.
# 켜기: HM_DB_SCAN_GUARD=1. 판정 기준은 README "DB 스캔 가드". 어떤 오류든 통과(fail-open)한다.
set -uo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)" || exit 0
cmd="$(jq -r '.tool_input.command // "" | if type == "array" then join(" ") else tostring end' <<<"$input" 2>/dev/null)" || exit 0

# 대부분의 Bash 호출은 여기서 끝난다.
shopt -s nocasematch
[[ "$cmd" == *information_schema* ]] || exit 0
shopt -u nocasematch

# 설정은 다른 HM_* 값처럼 hm_load_config로 읽는다 — config를 셸로 실행하지 않는다.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh" 2>/dev/null || exit 0
[[ "${HM_DB_SCAN_GUARD:-0}" == 1 ]] || exit 0

# 명령을 따옴표·주석·heredoc을 지켜 나눠 REC에 쌓는다. 바이트 단위로 읽어 멀티바이트 문자에서도 위치 계산이 일정하다.
# 레코드: "w<단어>"(따옴표 제거), "|"(같은 파이프라인의 다음 명령), "h<heredoc 본문>", "p"(; && || & ( ) ` 줄바꿈 — 파이프라인 끝)
LC_ALL=C
REC=()
flush() {
  if ((has_word)); then REC+=("w$word"); fi
  word="" has_word=0
}
lex() {
  local s="$1" n=${#1} i=0 c="" nx="" q="" word="" has_word=0 rest="" line="" cmp="" doc="" strip="" delim="" body=""
  local -a docs=()
  while ((i < n)); do
    c="${s:i:1}"
    if [[ -n "$q" ]]; then
      if [[ "$c" == "$q" ]]; then
        q=""
      elif [[ "$q" == '"' && "$c" == "\\" ]]; then
        i=$((i + 1)); nx="${s:i:1}"
        case "$nx" in '"' | "\\" | '$' | '`') word+="$nx" ;; $'\n') ;; *) word+="\\$nx" ;; esac
      else
        word+="$c"
      fi
      i=$((i + 1)); continue
    fi
    case "$c" in
      "'" | '"') q="$c"; has_word=1 ;;
      "\\")
        i=$((i + 1)); nx="${s:i:1}"
        if [[ "$nx" != $'\n' ]]; then word+="$nx"; has_word=1; fi ;;
      ' ' | $'\t') flush ;;
      '#')
        if ((has_word)); then
          word+="$c"
        else
          rest="${s:i}"; rest="${rest%%$'\n'*}"; i=$((i + ${#rest} - 1))
        fi ;;
      ';' | '(' | ')' | '`') flush; REC+=("p") ;;
      '&')
        nx="${s:i+1:1}"
        if [[ "$nx" == '>' ]] || { ((i > 0)) && [[ "${s:i-1:1}" == [\<\>] ]]; }; then
          word+="$c"; has_word=1
        else
          flush; REC+=("p")
          if [[ "$nx" == '&' ]]; then i=$((i + 1)); fi
        fi ;;
      '|')
        flush
        nx="${s:i+1:1}"
        if [[ "$nx" == '|' ]]; then
          REC+=("p"); i=$((i + 1))
        else
          REC+=("|")
          if [[ "$nx" == '&' ]]; then i=$((i + 1)); fi
        fi ;;
      $'\n')
        flush
        # heredoc 본문은 선언한 줄의 다음 줄부터 구분자 줄 앞까지다.
        for doc in ${docs[@]+"${docs[@]}"}; do
          strip="${doc%% *}" delim="${doc#* }" body=""
          while ((i + 1 < n)); do
            line="${s:i+1}"; line="${line%%$'\n'*}"
            i=$((i + ${#line} + 1))
            cmp="$line"
            if [[ "$strip" == 1 ]]; then
              while [[ "$cmp" == $'\t'* ]]; do cmp="${cmp#$'\t'}"; done
            fi
            if [[ "$cmp" == "$delim" ]]; then break; fi
            body+="$line"$'\n'
          done
          REC+=("h$body")
        done
        docs=()
        REC+=("p") ;;
      '<')
        if [[ "${s:i:3}" == '<<<' ]]; then
          word+='<<<'; has_word=1; i=$((i + 2))
        elif [[ "${s:i:2}" == '<<' ]]; then
          flush
          i=$((i + 2)); strip=0
          if [[ "${s:i:1}" == '-' ]]; then strip=1; i=$((i + 1)); fi
          while [[ "${s:i:1}" == [' '$'\t'] ]]; do i=$((i + 1)); done
          delim=""
          while ((i < n)); do
            c="${s:i:1}"
            case "$c" in
              ' ' | $'\t' | $'\n' | ';' | '|' | '&' | '<' | '>' | '(' | ')') break ;;
              "'" | '"' | "\\") ;;
              *) delim+="$c" ;;
            esac
            i=$((i + 1))
          done
          docs+=("$strip $delim")
          continue
        else
          word+="$c"; has_word=1
        fi ;;
      *) word+="$c"; has_word=1 ;;
    esac
    i=$((i + 1))
  done
  flush
  REC+=("p")
}
lex "$cmd"

hit="$(jq -rn '
  def pipelines:
    reduce $ARGS.positional[] as $r ({cur: {cmds: [[]], docs: []}, out: []};
      if $r == "p" then .out += [.cur] | .cur = {cmds: [[]], docs: []}
      elif $r == "|" then .cur.cmds += [[]]
      elif $r[0:1] == "h" then .cur.docs += [$r[1:]]
      else .cur.cmds |= (.[:-1] + [.[-1] + [$r[1:]]]) end)
    | .out[];
  # 명령 위치의 프로그램: 변수 대입·리다이렉션·래퍼(sudo·env·uv run 등)와 그 옵션을 건너뛴 첫 단어의 basename
  def program:
    reduce .[] as $w ({name: null, wrap: false, skip: false};
      if .name then .
      elif .skip then .skip = false
      elif ($w | test("^[A-Za-z_][A-Za-z0-9_]*=|^[0-9]*[<>]")) then .
      elif .wrap and ($w | test("^-")) then .skip = ($w | test("^-[ugCnks]$"))
      elif .wrap and ($w | test("^([0-9.]+[smhd]?|run)$")) then .
      elif ($w | sub(".*/"; "") | test("^(sudo|doas|env|command|exec|time|nice|nohup|timeout|stdbuf|uv|poetry|pipenv|pdm|hatch|rye)$")) then .wrap = true
      else .name = ($w | sub(".*/"; "")) end)
    | .name // "";
  # 인터프리터 코드 안의 문자열 리터럴 내용 — 쿼리는 여기에 있다.
  def literals:
    scan("\"\"\"([\\s\\S]*?)\"\"\"|'"'''"'([\\s\\S]*?)'"'''"'|\"((?:\\\\.|[^\"\\\\])*)\"|'"'"'((?:\\\\.|[^'"'"'\\\\])*)'"'"'|`((?:\\\\.|[^`\\\\])*)`")
    | map(values) | .[0];
  # SQL 문자열 리터럴·주석을 지운다. PostgreSQL의 큰따옴표는 식별자라 따옴표만 벗긴다.
  def strip($pg):
    gsub("'"'"'(?:'"''"'|\\\\.|[^'"'"'\\\\])*'"'"'|--[^\\n]*|#[^\\n]*|/\\*[\\s\\S]*?\\*/"
         + (if $pg then "|\\$\\$[\\s\\S]*?\\$\\$" else "|\"(?:\"\"|\\\\.|[^\"\\\\])*\"" end); " ")
    | gsub("[`\"]"; "");
  # 괄호 안을 접어 WHERE 최상위만 남긴다. IN (...)은 IN {}가 된다.
  def collapse: gsub("\\([^()]*\\)"; "{}") as $n | if $n == . then . else $n | collapse end;
  def scoped:
    collapse
    | ((capture("\\bwhere\\b(?<w>[\\s\\S]*)"; "i") | .w) // "")
    | test("\\b\\w*_schema\\s*(=|<=>|in\\s*\\{)"; "i") and (test("\\bor\\b|\\|\\|"; "i") | not);
  "^(mysql|mariadb|mysqlsh|mycli)$" as $my_cli
  | "^(psql|pgcli)$" as $pg_cli
  | "pymysql|mysql\\.connector|MySQLdb|aiomysql|mysql2|(mysql|mariadb)://|jdbc:(mysql|mariadb)" as $my_drv
  | "psycopg|asyncpg|pg8000|postgres(ql)?://|jdbc:postgresql" as $pg_drv
  | ($my_drv + "|" + $pg_drv + "|sqlalchemy|create_engine|jdbc:") as $drv
  | [ pipelines
      | ([.cmds[] | program]) as $progs
      | ([.cmds[][]] + .docs) as $texts
      | ($texts | join("\n")) as $all
      | ($progs | any(test($my_cli) or test($pg_cli) or test("^usql$"))) as $is_cli
      | (($progs | any(test("^(python[0-9.]*|pypy[0-9.]*|node|nodejs|deno|bun|ruby|perl|php)$")))
          and ($all | test($drv; "i"))) as $is_drv
      | select($is_cli or $is_drv)
      | ((($progs | any(test($pg_cli))) or ($all | test($pg_drv; "i")))
          and ((($progs | any(test($my_cli))) or ($all | test($my_drv; "i"))) | not)) as $pg
      | ((if $is_cli then $texts | map(sub("^--?[A-Za-z][A-Za-z0-9-]*="; "")) else [] end)
          + (if $is_drv then [$texts[] | literals] else [] end)
          | map(strip($pg))) as $sqls
      | (["views", "routines", "triggers", "events", "parameters"]
         + (if $pg then [] else
              ["tables", "columns", "statistics", "key_column_usage", "referential_constraints",
               "table_constraints", "check_constraints", "partitions",
               "view_table_usage", "view_routine_usage"] end)
         | join("|")) as $names
      | ("information_schema\\s*\\.\\s*(?<t>" + $names + ")\\b") as $qualified
      | ("\\b(from|join)\\s+(?<t>" + $names + ")\\b") as $bare
      # information_schema가 테이블 한정자가 아닌 자리(USE·DB 인자)에 나오면 비한정 이름도 대상이다.
      | ($sqls | any(test("information_schema(?!\\s*\\.)"; "i"))) as $in_ctx
      | $sqls[] | splits(";|\\bunion\\b"; "i")
      | (capture($qualified; "i") // (if $in_ctx then capture($bare; "i") else empty end)) as $ref
      | select(scoped | not)
      | $ref.t | ascii_upcase ]
  | first // empty
' --args ${REC[@]+"${REC[@]}"} 2>/dev/null)" || exit 0

[[ -n "$hit" ]] || exit 0

reason="[DB scan guard] information_schema.${hit}를 스키마 조건 없이 조회하면 모든 스키마를 훑습니다. 각 구문과 UNION 분기의 WHERE 최상위에 table_schema = 'app' 같은 *_schema 조건을 OR 없이 넣으세요. 전체 조회가 꼭 필요하면 사용자에게 직접 실행을 요청하세요."
jq -cn --arg reason "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$reason}}'
