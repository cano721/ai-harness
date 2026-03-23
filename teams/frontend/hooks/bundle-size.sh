#!/bin/bash
# bundle-size.sh — PreToolUse Hook
# 번들 크기를 증가시키는 대형 라이브러리 import를 차단한다.
# Write, Edit 도구 대상으로 동작.
# exit 0 = 통과, exit 2 = 차단

TOOL_NAME="$1"
TOOL_INPUT="$2"

# Write, Edit 도구만 검사
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

# moment 전체 import 차단 (dayjs 권장)
if echo "$TOOL_INPUT" | grep -qE "import\s+.*\bmoment\b|require\(['\"]moment['\"]"; then
  echo "BLOCKED: moment.js는 번들 크기가 큽니다. dayjs를 사용하세요. (예: import dayjs from 'dayjs')"
  exit 2
fi

# lodash 전체 import 차단 (lodash-es 개별 import 권장)
if echo "$TOOL_INPUT" | grep -qE "import\s+.*from\s+['\"]lodash['\"]|require\(['\"]lodash['\"]"; then
  echo "BLOCKED: lodash 전체 import는 번들 크기를 증가시킵니다. lodash-es 개별 import를 사용하세요. (예: import { get } from 'lodash-es')"
  exit 2
fi

# jquery 차단
if echo "$TOOL_INPUT" | grep -qE "import\s+.*\bjquery\b|require\(['\"]jquery['\"]"; then
  echo "BLOCKED: jQuery는 번들 크기가 큽니다. 네이티브 DOM API 또는 경량 대안을 사용하세요."
  exit 2
fi

# import * as 전체 가져오기 경고
if echo "$TOOL_INPUT" | grep -qE "import\s+\*\s+as\s+\w+"; then
  echo "WARNING: 'import * as' 전체 가져오기는 트리 쉐이킹을 방해합니다. 필요한 항목만 named import하세요."
fi

# 통과
exit 0
