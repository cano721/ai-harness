#!/bin/bash
# entity-review.sh — PreToolUse Hook
# JPA Entity 코드의 컨벤션을 검사한다.
# Write, Edit 도구 대상으로 동작.
# exit 0 = 통과 (경고만), exit 2 = 차단 없음 (모두 경고)

TOOL_NAME="$1"
TOOL_INPUT="$2"

# Write, Edit 도구만 검사
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
  exit 0
fi

# @Entity가 없으면 통과 (Entity 파일이 아님)
if ! echo "$TOOL_INPUT" | grep -qE '@Entity'; then
  exit 0
fi

# ── 경고 (exit 0 + WARNING) ───────────────────────────────

# @Entity + @Setter 동시 사용 경고
if echo "$TOOL_INPUT" | grep -qE '@Setter'; then
  echo "WARNING: Entity에 @Setter는 권장되지 않습니다. 비즈니스 메서드로 상태를 변경하세요. (예: user.updateName(name))"
fi

# Enum 필드에 @Enumerated(EnumType.STRING) 누락 경고
if echo "$TOOL_INPUT" | grep -qE '\bEnum\b|enum\s' && ! echo "$TOOL_INPUT" | grep -qE '@Enumerated\s*\(\s*EnumType\.STRING\s*\)'; then
  echo "WARNING: Enum 필드에 @Enumerated(EnumType.STRING)이 없습니다. 기본값 ORDINAL은 순서 변경 시 데이터가 깨집니다."
fi

# @NoArgsConstructor 누락 경고
if ! echo "$TOOL_INPUT" | grep -qE '@NoArgsConstructor'; then
  echo "WARNING: Entity에 @NoArgsConstructor가 없습니다. JPA는 기본 생성자가 필수입니다. @NoArgsConstructor(access = AccessLevel.PROTECTED) 추가를 권장합니다."
fi

# @NoArgsConstructor access = PROTECTED 권장
if echo "$TOOL_INPUT" | grep -qE '@NoArgsConstructor\s*$' || echo "$TOOL_INPUT" | grep -qE '@NoArgsConstructor\(\s*\)'; then
  echo "WARNING: @NoArgsConstructor(access = AccessLevel.PROTECTED)를 사용하여 외부에서 직접 생성을 방지하세요."
fi

# @Builder가 클래스에 붙어있으면 경고 (생성자에 붙여야 함)
if echo "$TOOL_INPUT" | grep -qE '@Builder' && ! echo "$TOOL_INPUT" | grep -B2 '@Builder' | grep -qE '(public|private|protected)\s+\w+\s*\('; then
  echo "WARNING: @Builder는 클래스가 아닌 생성자에 적용하세요. 클래스에 붙이면 모든 필드가 노출됩니다."
fi

# @Column 없이 필드 선언 경고 (nullable, length 등 명시 권장)
FIELD_COUNT=$(echo "$TOOL_INPUT" | grep -cE '^\s+private\s+(String|Long|Integer|Boolean)\s+\w+;')
COLUMN_COUNT=$(echo "$TOOL_INPUT" | grep -cE '@Column')
if [ "$FIELD_COUNT" -gt 0 ] && [ "$COLUMN_COUNT" -eq 0 ]; then
  echo "WARNING: Entity 필드에 @Column 어노테이션이 없습니다. nullable, length 등을 명시하여 DB 스키마를 명확히 하세요."
fi

# 통과
exit 0
