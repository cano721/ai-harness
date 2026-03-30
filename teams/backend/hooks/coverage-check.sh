#!/bin/bash
# coverage-check.sh — PostToolUse Hook
# 테스트 실행 결과에서 커버리지와 실패를 감지한다.
# Bash 도구 대상으로 동작.
# exit 0 = 통과 (경고 포함 가능)

TOOL_NAME="$1"
TOOL_INPUT="$2"

# Bash 도구만 검사
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# 테스트 실행 관련 명령인지 확인
if ! echo "$TOOL_INPUT" | grep -qiE '(test|jest|vitest|pytest|mocha|jasmine|coverage|mvn\s+test|gradle\s+test|npm\s+test|yarn\s+test)'; then
  exit 0
fi

# 테스트 실패 감지
if echo "$TOOL_INPUT" | grep -qiE '\b(FAIL|FAILED|FAILURE)\b'; then
  echo "WARNING: 테스트 실패가 감지되었습니다. 실패한 테스트를 확인하고 수정하세요."
fi

# 커버리지 숫자 추출 및 검사
COVERAGE=$(echo "$TOOL_INPUT" | grep -oiE 'coverage[: ]+([0-9]+(\.[0-9]+)?)%' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)

if [ -n "$COVERAGE" ]; then
  # 소수점 제거 후 정수 비교
  COVERAGE_INT=$(echo "$COVERAGE" | cut -d'.' -f1)
  if [ "$COVERAGE_INT" -lt 80 ]; then
    echo "WARNING: 테스트 커버리지가 ${COVERAGE}%로 기준(80%) 미만입니다. 커버리지를 높이세요."
  fi
fi

# 통과
exit 0
