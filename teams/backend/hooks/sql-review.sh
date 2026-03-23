#!/bin/bash
# sql-review.sh — PreToolUse Hook
# SQL 관련 코드에서 보안 취약점과 성능 안티패턴을 차단한다.
# Write, Edit, Bash 도구 대상으로 동작.
# exit 0 = 통과, exit 2 = 차단

TOOL_NAME="$1"
TOOL_INPUT="$2"

# Write, Edit, Bash 도구만 검사
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# SQL 관련 내용이 없으면 통과
if ! echo "$TOOL_INPUT" | grep -qiE '\b(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE)\b'; then
  exit 0
fi

# SELECT * 사용 차단
if echo "$TOOL_INPUT" | grep -qiE 'SELECT\s+\*\s+(FROM|,)'; then
  echo "BLOCKED: SELECT *는 금지되어 있습니다. 필요한 컬럼을 명시적으로 나열하세요. (예: SELECT id, name FROM ...)"
  exit 2
fi

# 문자열 연결 SQL 차단 (SQL Injection 위험)
if echo "$TOOL_INPUT" | grep -qE '"SELECT[^"]*"\s*\+|'"'"'SELECT[^'"'"']*'"'"'\s*\+'; then
  echo "BLOCKED: 문자열 연결로 SQL을 구성하면 SQL Injection 위험이 있습니다. PreparedStatement 또는 파라미터 바인딩을 사용하세요."
  exit 2
fi

# WHERE 절 없는 SELECT 경고
if echo "$TOOL_INPUT" | grep -qiE 'SELECT\s+\S+\s+FROM\s+\S+' && ! echo "$TOOL_INPUT" | grep -qiE '\bWHERE\b'; then
  echo "WARNING: WHERE 절 없는 SELECT는 전체 테이블을 조회합니다. 페이지네이션 또는 조건을 추가하세요."
fi

# @Transactional 없이 여러 UPDATE/INSERT 경고
UPDATE_COUNT=$(echo "$TOOL_INPUT" | grep -ciE '\b(UPDATE|INSERT)\b')
if [ "$UPDATE_COUNT" -ge 2 ] && ! echo "$TOOL_INPUT" | grep -qE '@Transactional'; then
  echo "WARNING: 여러 UPDATE/INSERT 실행 시 @Transactional을 사용하여 원자성을 보장하세요."
fi

# 통과
exit 0
