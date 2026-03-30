#!/bin/bash
# guardrails-check.sh — PreToolUse Hook
# config.yaml의 guardrails 값을 실제로 강제한다.
# - max_files_changed: git 변경 파일 수 제한
# exit 0 = 통과, exit 2 = 차단

TOOL_NAME="$1"
TOOL_INPUT="$2"

# Write, Edit 도구만 검사
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

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

# config.yaml 찾기 (로컬 우선, 글로벌 폴백)
CONFIG_FILE=".ai-harness/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="$HOME/.ai-harness/config.yaml"
fi
if [ ! -f "$CONFIG_FILE" ]; then
  exit 0
fi

# max_files_changed 추출
MAX_FILES=$(grep -E '^\s+max_files_changed:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*:\s*//')
if [ -z "$MAX_FILES" ]; then
  MAX_FILES=20
fi

# git 변경 파일 수 체크 (git 저장소일 때만)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')
  STAGED_FILES=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  TOTAL=$((CHANGED_FILES + STAGED_FILES + UNTRACKED))

  if [ "$TOTAL" -ge "$MAX_FILES" ]; then
    echo "BLOCKED: 변경된 파일 수(${TOTAL}개)가 guardrail 한도(${MAX_FILES}개)에 도달했습니다. 현재 변경 사항을 커밋하거나, config.yaml의 max_files_changed를 조정하세요."
    exit 2
  fi
fi

# 통과
exit 0
