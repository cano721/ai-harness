#!/bin/bash
# audit-logger.sh — PostToolUse Hook
# 모든 AI 에이전트 액션을 JSONL로 기록한다.
# 항상 exit 0 (로깅 실패가 도구 실행을 차단하면 안 됨)

TOOL_NAME="$1"
TOOL_INPUT="$2"

# 글로벌 제외 프로젝트 체크
GLOBAL_CONFIG="$HOME/.ai-harness/config.yaml"
if [ -f "$GLOBAL_CONFIG" ]; then
  CURRENT_DIR="$(pwd)"
  if grep -q "exclude_projects:" "$GLOBAL_CONFIG" 2>/dev/null; then
    if grep -q "  - $CURRENT_DIR" "$GLOBAL_CONFIG" 2>/dev/null; then
      exit 0
    fi
  fi
fi

# 로그 디렉토리
LOG_DIR=".ai-harness/logs"
mkdir -p "$LOG_DIR"

# 오늘 날짜 로그 파일
TODAY=$(date -u +"%Y-%m-%d")
LOG_FILE="$LOG_DIR/$TODAY.jsonl"

# 타임스탬프
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# 사용자 (Git user 또는 시스템 사용자)
USER=$(git config user.name 2>/dev/null || whoami)

# 프로젝트 (Git 저장소명)
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || basename "$(pwd)")

# 입력 내용 마스킹
MASKED_INPUT="$TOOL_INPUT"

# Bearer/Authorization 토큰 마스킹
MASKED_INPUT=$(echo "$MASKED_INPUT" | sed -E 's/(Bearer|Authorization:?\s*)[A-Za-z0-9._~+\/=-]{10,}/\1***REDACTED***/gi' 2>/dev/null || echo "$MASKED_INPUT")

# password= 뒤의 값 마스킹
MASKED_INPUT=$(echo "$MASKED_INPUT" | sed -E 's/(password\s*[=:]\s*)['"'"'""][^'"'"'"]*['"'"'"]/\1"***REDACTED***"/gi' 2>/dev/null || echo "$MASKED_INPUT")

# 200자 초과 시 truncate
if [ ${#MASKED_INPUT} -gt 200 ]; then
  MASKED_INPUT="${MASKED_INPUT:0:50}... (truncated)"
fi

# JSON 특수문자 이스케이프
MASKED_INPUT=$(echo "$MASKED_INPUT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' ')

# JSONL 엔트리 작성
echo "{\"timestamp\":\"$TIMESTAMP\",\"event_type\":\"tool_use\",\"tool\":\"$TOOL_NAME\",\"action\":\"$MASKED_INPUT\",\"result\":\"success\",\"user\":\"$USER\",\"project\":\"$PROJECT\"}" >> "$LOG_FILE"

# 항상 통과
exit 0
