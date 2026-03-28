#!/bin/bash
# check-architecture.sh — PreToolUse Hook
# 아키텍처 경계(의존성 방향)를 기계적으로 강제한다.
# Write, Edit 도구 대상으로 동작.
# exit 0 = 통과, exit 2 = 차단
#
# 의존성 방향: Types → Config → Repository → Service → Controller
# 하위 레이어가 상위 레이어를 import하면 차단한다.

TOOL_NAME="$1"
TOOL_INPUT="$2"

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

# Write, Edit 도구만 검사
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

# 아키텍처 검증 활성화 확인
LOCAL_CONFIG=".ai-harness/config.yaml"
if [ -f "$LOCAL_CONFIG" ]; then
  if grep -q "check-architecture:" "$LOCAL_CONFIG" 2>/dev/null; then
    if grep -A1 "check-architecture:" "$LOCAL_CONFIG" | grep -q "enabled: false"; then
      exit 0
    fi
  fi
fi

# 파일 경로 추출
FILE_PATH=""
if [ "$TOOL_NAME" = "Write" ]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | grep -oE '"file_path"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
elif [ "$TOOL_NAME" = "Edit" ]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | grep -oE '"file_path"\s*:\s*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')
fi

# Java 파일만 검사
if ! echo "$FILE_PATH" | grep -qE '\.java$'; then
  exit 0
fi

# 레이어 판별 (디렉토리 경로 기반, 경로 구분자 포함)
get_layer() {
  local path="$1"
  if echo "$path" | grep -qiE '/(controller|rest|endpoint|resource)/'; then
    echo 5
  elif echo "$path" | grep -qiE '/(service|usecase|application)/'; then
    echo 4
  elif echo "$path" | grep -qiE '/(repository|repo|dao|mapper|persistence)/'; then
    echo 3
  elif echo "$path" | grep -qiE '/(config|configuration|properties)/'; then
    echo 2
  elif echo "$path" | grep -qiE '/(dto|entity|model|domain|type|vo|enum)/'; then
    echo 1
  else
    echo 0  # 판별 불가 → 검사 스킵
  fi
}

# 레이어명
get_layer_name() {
  case "$1" in
    5) echo "Controller" ;;
    4) echo "Service" ;;
    3) echo "Repository" ;;
    2) echo "Config" ;;
    1) echo "Types/Entity" ;;
    *) echo "Unknown" ;;
  esac
}

# import에서 참조하는 레이어 추출
check_import_violation() {
  local source_layer="$1"
  local content="$2"

  # source_layer가 0이면 검사 스킵
  if [ "$source_layer" -eq 0 ]; then
    return 0
  fi

  # import 문에서 상위 레이어 참조 감지
  local violations=""

  # Controller import 감지 (Service 이하에서 위반)
  if [ "$source_layer" -le 4 ]; then
    if echo "$content" | grep -qE 'import\s+.*\.(controller|rest|endpoint|resource)\.'; then
      violations="Controller"
    fi
  fi

  # Service import 감지 (Repository 이하에서 위반, domain.service 패키지는 예외)
  if [ "$source_layer" -le 3 ]; then
    if echo "$content" | grep -qE 'import\s+.*\.(service|usecase|application)\.'; then
      if ! echo "$content" | grep -qE 'import\s+.*\.domain\.service\.'; then
        violations="${violations:+$violations, }Service"
      fi
    fi
  fi

  # Repository import 감지 (Types/Entity 이하에서 위반)
  if [ "$source_layer" -le 1 ]; then
    if echo "$content" | grep -qE 'import\s+.*\.(repository|repo|dao|mapper|persistence)\.'; then
      violations="${violations:+$violations, }Repository"
    fi
  fi

  # Config import 감지 (Types/Entity 이하에서 위반)
  if [ "$source_layer" -le 1 ]; then
    if echo "$content" | grep -qE 'import\s+.*\.(config|configuration)\.'; then
      violations="${violations:+$violations, }Config"
    fi
  fi

  if [ -n "$violations" ]; then
    echo "$violations"
    return 1
  fi
  return 0
}

# 현재 파일의 레이어
SOURCE_LAYER=$(get_layer "$FILE_PATH")
SOURCE_NAME=$(get_layer_name "$SOURCE_LAYER")

# 레이어 판별 불가 시 스킵
if [ "$SOURCE_LAYER" -eq 0 ]; then
  exit 0
fi

# 코드 내용 추출 (jq 사용, fallback으로 grep)
CONTENT=""
if command -v jq &>/dev/null; then
  if [ "$TOOL_NAME" = "Write" ]; then
    CONTENT=$(echo "$TOOL_INPUT" | jq -r '.content // empty' 2>/dev/null)
  elif [ "$TOOL_NAME" = "Edit" ]; then
    CONTENT=$(echo "$TOOL_INPUT" | jq -r '.new_string // empty' 2>/dev/null)
  fi
fi

# jq 실패 시 grep fallback
if [ -z "$CONTENT" ]; then
  if [ "$TOOL_NAME" = "Write" ]; then
    CONTENT=$(echo "$TOOL_INPUT" | grep -oE '"content"\s*:\s*"[^"]*"' | head -1)
  elif [ "$TOOL_NAME" = "Edit" ]; then
    CONTENT=$(echo "$TOOL_INPUT" | grep -oE '"new_string"\s*:\s*"[^"]*"' | head -1)
  fi
fi

# 위반 검사 (함수 호출과 결과 캡처 분리)
if ! VIOLATIONS=$(check_import_violation "$SOURCE_LAYER" "$CONTENT"); then
  echo "BLOCKED: 아키텍처 경계 위반 — ${SOURCE_NAME} 레이어에서 상위 레이어(${VIOLATIONS})를 참조할 수 없습니다."
  echo ""
  echo "의존성 방향: Types/Entity → Config → Repository → Service → Controller"
  echo ""
  echo "해결 방법:"
  echo "  1. 인터페이스를 하위 레이어에 정의하고 상위 레이어에서 구현하세요"
  echo "  2. 이벤트/콜백 패턴으로 의존성을 역전하세요"
  echo "  3. DTO를 통해 레이어 간 데이터를 전달하세요"
  exit 2
fi

# 통과
exit 0
