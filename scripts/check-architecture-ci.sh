#!/bin/bash
# check-architecture-ci.sh — CI 환경에서 아키텍처 경계 위반을 검증합니다
# PR 단계에서 Hook과 별개로 한번 더 검증하여 이중 안전망을 제공합니다.
#
# 사용법:
#   bash scripts/check-architecture-ci.sh [src_dir]
#   기본 src_dir: src/main/java
#
# 종료 코드:
#   0 = 위반 없음
#   1 = 위반 발견

SRC_DIR="${1:-src/main/java}"
VIOLATIONS=0
VIOLATION_DETAILS=""

# 색상 (CI 로그 가독성)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 레이어 판별
get_layer() {
  local path="$1"
  if echo "$path" | grep -qiE '/(controller|rest|api|endpoint|resource)/'; then
    echo 5
  elif echo "$path" | grep -qiE '/(service|usecase|application)/'; then
    echo 4
  elif echo "$path" | grep -qiE '/(repository|repo|dao|mapper|persistence)/'; then
    echo 3
  elif echo "$path" | grep -qiE '/(config|configuration)/'; then
    echo 2
  elif echo "$path" | grep -qiE '/(dto|entity|model|domain|type|vo|enum)/'; then
    echo 1
  else
    echo 0
  fi
}

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

echo "========================================="
echo " Architecture Boundary Check"
echo " Source: $SRC_DIR"
echo "========================================="
echo ""

# SRC_DIR이 없으면 스킵
if [ ! -d "$SRC_DIR" ]; then
  echo -e "${YELLOW}SKIP: $SRC_DIR 디렉토리가 없습니다${NC}"
  exit 0
fi

# 모든 Java 파일 검사
while IFS= read -r file; do
  SOURCE_LAYER=$(get_layer "$file")

  # 레이어 판별 불가 시 스킵
  [ "$SOURCE_LAYER" -eq 0 ] && continue

  SOURCE_NAME=$(get_layer_name "$SOURCE_LAYER")

  # import 문 추출
  while IFS= read -r import_line; do
    IMPORT_LAYER=0
    IMPORT_NAME=""

    if echo "$import_line" | grep -qiE '\.(controller|rest|endpoint|resource)\.'; then
      IMPORT_LAYER=5; IMPORT_NAME="Controller"
    elif echo "$import_line" | grep -qiE '\.(service|usecase|application)\.'; then
      IMPORT_LAYER=4; IMPORT_NAME="Service"
    elif echo "$import_line" | grep -qiE '\.(repository|repo|dao|mapper|persistence)\.'; then
      IMPORT_LAYER=3; IMPORT_NAME="Repository"
    elif echo "$import_line" | grep -qiE '\.(config|configuration)\.'; then
      IMPORT_LAYER=2; IMPORT_NAME="Config"
    fi

    # 상위 레이어 참조 감지
    if [ "$IMPORT_LAYER" -gt 0 ] && [ "$IMPORT_LAYER" -gt "$SOURCE_LAYER" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      DETAIL="  ${RED}✗${NC} $file\n    ${SOURCE_NAME}(L${SOURCE_LAYER}) → ${IMPORT_NAME}(L${IMPORT_LAYER}): $import_line"
      VIOLATION_DETAILS="${VIOLATION_DETAILS}\n${DETAIL}"
    fi
  done < <(grep -E '^import\s' "$file" 2>/dev/null)

done < <(find "$SRC_DIR" -name "*.java" -type f 2>/dev/null)

# 결과 출력
echo "Direction: Types/Entity(1) → Config(2) → Repository(3) → Service(4) → Controller(5)"
echo ""

if [ "$VIOLATIONS" -gt 0 ]; then
  echo -e "${RED}FAIL: ${VIOLATIONS}건의 아키텍처 경계 위반 발견${NC}"
  echo ""
  echo -e "$VIOLATION_DETAILS"
  echo ""
  echo "해결 방법:"
  echo "  1. 인터페이스를 하위 레이어에 정의하고 상위 레이어에서 구현"
  echo "  2. 이벤트/콜백 패턴으로 의존성 역전"
  echo "  3. DTO를 통해 레이어 간 데이터 전달"
  exit 1
else
  echo -e "${GREEN}PASS: 아키텍처 경계 위반 없음${NC}"
  exit 0
fi
