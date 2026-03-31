#!/bin/bash
# log-blocked.sh — 차단 이벤트 로깅 헬퍼
# 사용법: source lib/log-blocked.sh && log_blocked "hook_name" "tool_name" "reason"

log_blocked() {
  local HOOK_NAME="$1"
  local TOOL_NAME="$2"
  local REASON="$3"

  # 로그 디렉토리
  local LOG_DIR
  if [ -d ".ai-harness" ]; then
    LOG_DIR=".ai-harness/logs"
  else
    LOG_DIR="$HOME/.ai-harness/logs"
  fi
  mkdir -p "$LOG_DIR"

  local TODAY=$(date -u +"%Y-%m-%d")
  local LOG_FILE="$LOG_DIR/$TODAY.jsonl"
  local TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
  local USER=$(git config user.name 2>/dev/null || whoami)
  local PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || basename "$(pwd)")

  # JSON 이스케이프
  REASON=$(echo "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' ')

  echo "{\"timestamp\":\"$TIMESTAMP\",\"event\":\"blocked\",\"hook\":\"$HOOK_NAME\",\"tool\":\"$TOOL_NAME\",\"reason\":\"$REASON\",\"result\":\"blocked\",\"user\":\"$USER\",\"project\":\"$PROJECT\"}" >> "$LOG_FILE"
}
