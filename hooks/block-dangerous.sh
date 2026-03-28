#!/bin/bash
# block-dangerous.sh — PreToolUse Hook
# 위험한 명령/패턴을 실행 전에 차단한다.
# exit 0 = 통과, exit 2 = 차단

TOOL_NAME="$1"
TOOL_INPUT="$2"

# 글로벌 제외 프로젝트 체크
GLOBAL_CONFIG="$HOME/.ai-harness/config.yaml"
if [ -f "$GLOBAL_CONFIG" ]; then
  CURRENT_DIR="$(pwd)"
  if grep -q "exclude_projects:" "$GLOBAL_CONFIG" 2>/dev/null; then
    if grep -qF "  - $CURRENT_DIR" "$GLOBAL_CONFIG" 2>/dev/null; then
      exit 0
    fi
  fi
fi

# 하네스 자기 보호: 에이전트가 하네스를 비활성화하는 시도 차단
if echo "$TOOL_INPUT" | grep -qE 'HARNESS_BYPASS|ai-harness\s+(bypass|uninstall)|ai-harness\s+hook\s+disable'; then
  echo "BLOCKED: 에이전트의 하네스 비활성화 시도가 차단되었습니다."
  exit 2
fi

# Bash 도구에서 위험 명령 체크
if [ "$TOOL_NAME" = "Bash" ]; then
  # rm -rf 차단 (rm과 -r, -f 플래그 조합)
  if echo "$TOOL_INPUT" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\b'; then
    echo "BLOCKED: rm -rf 명령은 하네스 보안 정책에 의해 차단됩니다."
    echo ""
    echo "다음과 같이 수정하세요:"
    echo "  - 개별 파일 삭제: rm file1.txt file2.txt"
    echo "  - 디렉토리 내용 확인 후 삭제: ls target/ && rm -r target/"
    echo "  - Node.js: npx rimraf dist/"
    exit 2
  fi

  # DROP TABLE/DATABASE/INDEX 차단
  if echo "$TOOL_INPUT" | grep -qiE 'DROP\s+(TABLE|DATABASE|INDEX)'; then
    echo "BLOCKED: DROP 명령은 하네스 보안 정책에 의해 차단됩니다."
    echo ""
    echo "다음과 같이 수정하세요:"
    echo "  - Flyway: resources/db/migration/V{n}__drop_table.sql 생성"
    echo "  - Liquibase: changelog에 dropTable 추가"
    echo "  - /db-migration 스킬로 안전한 마이그레이션 생성"
    exit 2
  fi

  # TRUNCATE TABLE 차단
  if echo "$TOOL_INPUT" | grep -qiE 'TRUNCATE\s+TABLE'; then
    echo "BLOCKED: TRUNCATE TABLE은 하네스 보안 정책에 의해 차단됩니다."
    echo ""
    echo "다음과 같이 수정하세요:"
    echo "  - 테스트용: @Sql 또는 @DirtiesContext로 데이터 초기화"
    echo "  - 운영용: DELETE + WHERE 조건으로 범위 지정 삭제"
    exit 2
  fi

  # git push --force (main/master) 차단 (--force-with-lease는 허용)
  if echo "$TOOL_INPUT" | grep -qE 'git\s+push\s+.*--force' && \
     ! echo "$TOOL_INPUT" | grep -qE 'git\s+push\s+.*--force-with-lease'; then
    echo "BLOCKED: force push는 하네스 보안 정책에 의해 차단됩니다."
    echo ""
    echo "다음과 같이 수정하세요:"
    echo "  - 안전한 대안: git push --force-with-lease"
    echo "  - 리베이스 후: git push --force-with-lease origin <브랜치명>"
    exit 2
  fi

  # chmod 777 차단
  if echo "$TOOL_INPUT" | grep -qE 'chmod\s+777'; then
    echo "BLOCKED: chmod 777은 하네스 보안 정책에 의해 차단됩니다."
    echo ""
    echo "다음과 같이 수정하세요:"
    echo "  - 실행 권한만: chmod +x script.sh"
    echo "  - 읽기/쓰기: chmod 644 file.txt"
    echo "  - 디렉토리: chmod 755 dir/"
    exit 2
  fi

  # sudo 차단
  if echo "$TOOL_INPUT" | grep -qE '(^|[;&|])\s*sudo\s'; then
    echo "BLOCKED: sudo 명령은 하네스 보안 정책에 의해 차단됩니다."
    echo ""
    echo "다음과 같이 수정하세요:"
    echo "  - 권한 문제: 사용자에게 직접 실행 요청 (! sudo ...)"
    echo "  - npm 권한: npx 또는 --prefix 사용"
    exit 2
  fi
fi

# 통과
exit 0
