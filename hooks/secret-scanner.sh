#!/bin/bash
# secret-scanner.sh — PreToolUse Hook
# 민감 정보가 코드에 포함되는 것을 방지한다.
# Write, Edit, Bash 도구 대상으로 동작.
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
  log_blocked "secret-scanner" "$TOOL_NAME" "$MSG"
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

# Write, Edit, Bash 도구만 검사
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# 허용 목록: EXAMPLE_, DUMMY_, FAKE_, TEST_ 접두사가 있으면 Generic Secret 체크 스킵 플래그
SKIP_GENERIC_SECRET=0
if echo "$TOOL_INPUT" | grep -qE '(EXAMPLE_|DUMMY_|FAKE_|TEST_)'; then
  SKIP_GENERIC_SECRET=1
fi

# AWS Access Key
if echo "$TOOL_INPUT" | grep -qE 'AKIA[0-9A-Z]{16}'; then
  block "AWS Access Key가 감지되었습니다. 시크릿 매니저를 사용하세요."
fi

# Private Key
if echo "$TOOL_INPUT" | grep -q -- '-----BEGIN.*PRIVATE KEY-----'; then
  block "Private Key가 감지되었습니다. 시크릿 매니저를 사용하세요."
fi

# Generic Secret (password, secret, token, api_key 등에 값이 할당된 경우)
if [ "$SKIP_GENERIC_SECRET" -eq 0 ]; then
  if echo "$TOOL_INPUT" | grep -qiE '(password|secret|api[_-]?key|api[_-]?secret|token)[[:space:]]*[=:][[:space:]]*[^ ]{8,}'; then
    block "하드코딩된 시크릿이 감지되었습니다. 환경 변수 또는 시크릿 매니저를 사용하세요."
  fi
fi

# .env 파일 쓰기/수정 시도 차단 (Write와 Edit 모두)
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  if echo "$TOOL_INPUT" | grep -qE '\.env($|\.)'; then
    block ".env 파일 직접 쓰기/수정이 차단되었습니다. .env.example을 사용하세요."
  fi
fi

# credentials/secrets 파일 쓰기 차단
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  if echo "$TOOL_INPUT" | grep -qiE '(credentials|secrets)\.(json|yaml|yml|xml|properties)'; then
    block "민감 정보 파일 직접 수정이 차단되었습니다. 시크릿 매니저를 사용하세요."
  fi
fi

# 통과
exit 0
