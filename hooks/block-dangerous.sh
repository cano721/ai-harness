#!/bin/bash
# block-dangerous.sh — PreToolUse Hook
# 위험한 명령/패턴을 실행 전에 차단한다.
# exit 0 = 통과, exit 2 = 차단

TOOL_NAME="$1"
TOOL_INPUT="$2"

# 차단 로깅 헬퍼
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/log-blocked.sh" ]; then
  source "$SCRIPT_DIR/lib/log-blocked.sh"
else
  log_blocked() { :; }
fi

block() {
  local MSG="$1"
  echo "BLOCKED: $MSG"
  log_blocked "block-dangerous" "$TOOL_NAME" "$MSG"
  exit 2
}

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
  block "에이전트의 하네스 비활성화 시도가 차단되었습니다."
fi

# Bash 도구에서 위험 명령 체크
if [ "$TOOL_NAME" = "Bash" ]; then
  # rm -rf 차단 (rm과 -r, -f 플래그 조합)
  if echo "$TOOL_INPUT" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\b'; then
    block "rm -rf 명령은 하네스 보안 정책에 의해 차단됩니다. 대안: 개별 파일 삭제 또는 rimraf 사용"
  fi

  # DROP TABLE/DATABASE/INDEX 차단
  if echo "$TOOL_INPUT" | grep -qiE 'DROP\s+(TABLE|DATABASE|INDEX)'; then
    block "DROP 명령은 하네스 보안 정책에 의해 차단됩니다. 대안: 마이그레이션 스크립트 사용"
  fi

  # TRUNCATE TABLE 차단
  if echo "$TOOL_INPUT" | grep -qiE 'TRUNCATE\s+TABLE'; then
    block "TRUNCATE TABLE은 하네스 보안 정책에 의해 차단됩니다."
  fi

  # git push --force 차단 (--force-with-lease는 허용)
  if echo "$TOOL_INPUT" | grep -qE 'git\s+push\s+.*--force' && \
     ! echo "$TOOL_INPUT" | grep -qE 'git\s+push\s+.*--force-with-lease'; then
    block "force push는 하네스 보안 정책에 의해 차단됩니다. 대안: --force-with-lease 사용"
  fi

  # chmod 777 차단
  if echo "$TOOL_INPUT" | grep -qE 'chmod\s+777'; then
    block "chmod 777은 하네스 보안 정책에 의해 차단됩니다."
  fi

  # sudo 차단
  if echo "$TOOL_INPUT" | grep -qE '(^|[;&|])\s*sudo\s'; then
    block "sudo 명령은 하네스 보안 정책에 의해 차단됩니다."
  fi
fi

# 통과
exit 0
