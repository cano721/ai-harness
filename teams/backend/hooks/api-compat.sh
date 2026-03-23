#!/bin/bash
# api-compat.sh — PreToolUse Hook
# Controller/API 변경 시 하위 호환성과 컨벤션을 검사한다.
# Write, Edit 도구 대상으로 동작.
# exit 0 = 통과, exit 2 = 차단

TOOL_NAME="$1"
TOOL_INPUT="$2"

# Write, Edit 도구만 검사
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

# ── 차단 (exit 2) — 도구/언어 무관 ────────────────────────

# RequestBody 필드 삭제/타입 변경 차단
if echo "$TOOL_INPUT" | grep -qiE '//\s*(removed|deleted)\s*:'; then
  echo "BLOCKED: RequestBody 필드 삭제는 하위 호환성을 깨뜨립니다. @Deprecated 어노테이션으로 Deprecation 절차를 사용하세요."
  exit 2
fi

# System.out.println 차단
if echo "$TOOL_INPUT" | grep -qE 'System\.(out|err)\.(print|println)'; then
  echo "BLOCKED: System.out 사용은 금지되어 있습니다. @Slf4j + log.info/warn/error를 사용하세요."
  exit 2
fi

# API/Controller 관련 내용이 없으면 나머지 검사 스킵
if ! echo "$TOOL_INPUT" | grep -qE '(@(Controller|RestController|RequestMapping|GetMapping|PostMapping|PutMapping|DeleteMapping)|/api/)'; then
  exit 0
fi

# ── 차단 (exit 2) — API 관련 ──────────────────────────────

# API 버전 없는 경로 차단 (/api/xxx → /api/v1/xxx 필요)
if echo "$TOOL_INPUT" | grep -qE '"/api/[^v/][^/]*"'; then
  echo "BLOCKED: API 경로에 버전이 없습니다. /api/v{N}/... 형식을 사용하세요. (예: /api/v1/applicants)"
  exit 2
fi

# ── 경고 (exit 0 + WARNING) — API 관련 ───────────────────

# @DeleteMapping 사용 경고 (breaking change)
if echo "$TOOL_INPUT" | grep -qE '@DeleteMapping'; then
  echo "WARNING: @DeleteMapping은 기존 엔드포인트를 삭제하는 breaking change일 수 있습니다. 클라이언트 호환성을 확인하세요."
fi

# @RequestMapping path 변경 경고
if echo "$TOOL_INPUT" | grep -qE '@RequestMapping\s*\(.*path\s*='; then
  echo "WARNING: @RequestMapping path 변경은 기존 클라이언트에 영향을 줄 수 있습니다."
fi

# @RequestParam required 추가 경고
if echo "$TOOL_INPUT" | grep -qE '@RequestParam\s*\(' && echo "$TOOL_INPUT" | grep -qE 'required\s*=\s*true'; then
  echo "WARNING: @RequestParam(required=true) 추가는 기존 호출을 깨뜨릴 수 있습니다. 기본값(defaultValue)을 고려하세요."
fi

# Swagger 어노테이션 누락 경고
if echo "$TOOL_INPUT" | grep -qE '@(GetMapping|PostMapping|PutMapping|DeleteMapping)' && ! echo "$TOOL_INPUT" | grep -qE '@Operation'; then
  echo "WARNING: API 메서드에 @Operation 어노테이션이 없습니다. Swagger 문서화를 위해 추가하세요."
fi

# 통과
exit 0
