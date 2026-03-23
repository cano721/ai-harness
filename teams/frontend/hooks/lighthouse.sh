#!/bin/bash
# lighthouse.sh — PreToolUse Hook
# CSS/HTML 작성 시 Lighthouse 성능 점수에 영향을 주는 안티패턴을 차단한다.
# Write 도구 대상으로 동작.
# exit 0 = 통과, exit 2 = 차단

TOOL_NAME="$1"
TOOL_INPUT="$2"

# Write 도구만 검사
if [ "$TOOL_NAME" != "Write" ]; then
  exit 0
fi

# @import url() — CSS 동기 외부 리소스 로딩 차단
if echo "$TOOL_INPUT" | grep -qE '@import\s+url\('; then
  echo "BLOCKED: @import url()은 렌더링을 블로킹합니다. <link rel='stylesheet'>를 사용하세요."
  exit 2
fi

# document.write 차단
if echo "$TOOL_INPUT" | grep -qE 'document\.write\s*\('; then
  echo "BLOCKED: document.write()는 파서를 블로킹하고 Lighthouse 점수를 낮춥니다. DOM API를 사용하세요."
  exit 2
fi

# <script src= without async/defer 차단
if echo "$TOOL_INPUT" | grep -qE '<script\s+src='; then
  if ! echo "$TOOL_INPUT" | grep -qE '<script\s[^>]*(async|defer)[^>]*src=|<script\s[^>]*src=[^>]*(async|defer)'; then
    echo "BLOCKED: <script src=>에는 async 또는 defer 속성이 필요합니다. (예: <script src='...' defer>)"
    exit 2
  fi
fi

# 인라인 style에 !important 과다 사용 경고 (3개 이상)
IMPORTANT_COUNT=$(echo "$TOOL_INPUT" | grep -o '!important' | wc -l | tr -d ' ')
if [ "$IMPORTANT_COUNT" -ge 3 ]; then
  echo "WARNING: !important가 ${IMPORTANT_COUNT}회 사용되었습니다. CSS 명시도 설계를 재검토하세요."
fi

# 통과
exit 0
