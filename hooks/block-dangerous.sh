#!/bin/bash
# block-dangerous.sh — PreToolUse Hook
# 위험한 명령/패턴을 실행 전에 차단한다.
# exit 0 = 통과, exit 2 = 차단

TOOL_NAME="$1"
TOOL_INPUT="$2"

# 하네스 자기 보호: 에이전트가 하네스를 비활성화하는 시도 차단
if echo "$TOOL_INPUT" | grep -qE 'HARNESS_BYPASS|ai-harness\s+(bypass|uninstall)|ai-harness\s+hook\s+disable'; then
  echo "BLOCKED: 에이전트의 하네스 비활성화 시도가 차단되었습니다."
  exit 2
fi

# Bash 도구에서 위험 명령 체크
if [ "$TOOL_NAME" = "Bash" ]; then
  # rm -rf 차단 (rm과 -r, -f 플래그 조합)
  if echo "$TOOL_INPUT" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\b'; then
    echo "BLOCKED: rm -rf 명령은 하네스 보안 정책에 의해 차단됩니다. 대안: 개별 파일 삭제 또는 rimraf 사용"
    exit 2
  fi

  # DROP TABLE/DATABASE/INDEX 차단
  if echo "$TOOL_INPUT" | grep -qiE 'DROP\s+(TABLE|DATABASE|INDEX)'; then
    echo "BLOCKED: DROP 명령은 하네스 보안 정책에 의해 차단됩니다. 대안: 마이그레이션 스크립트 사용"
    exit 2
  fi

  # TRUNCATE TABLE 차단
  if echo "$TOOL_INPUT" | grep -qiE 'TRUNCATE\s+TABLE'; then
    echo "BLOCKED: TRUNCATE TABLE은 하네스 보안 정책에 의해 차단됩니다."
    exit 2
  fi

  # git push --force (main/master) 차단
  if echo "$TOOL_INPUT" | grep -qE 'git\s+push\s+.*--force'; then
    echo "BLOCKED: force push는 하네스 보안 정책에 의해 차단됩니다. 대안: --force-with-lease 사용"
    exit 2
  fi

  # chmod 777 차단
  if echo "$TOOL_INPUT" | grep -qE 'chmod\s+777'; then
    echo "BLOCKED: chmod 777은 하네스 보안 정책에 의해 차단됩니다."
    exit 2
  fi

  # sudo 차단
  if echo "$TOOL_INPUT" | grep -qE '^\s*sudo\s'; then
    echo "BLOCKED: sudo 명령은 하네스 보안 정책에 의해 차단됩니다."
    exit 2
  fi
fi

# 통과
exit 0
