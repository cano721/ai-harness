#!/bin/bash
# secret-scanner.sh — PreToolUse Hook
# 민감 정보가 코드에 포함되는 것을 방지한다.
# Write, Edit 도구 대상으로 동작.
# exit 0 = 통과, exit 2 = 차단

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
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# 허용 목록: EXAMPLE_, DUMMY_, FAKE_, TEST_ 접두사가 있으면 Generic Secret 체크 스킵 플래그
SKIP_GENERIC_SECRET=0
if echo "$TOOL_INPUT" | grep -qE '(EXAMPLE_|DUMMY_|FAKE_|TEST_)'; then
  SKIP_GENERIC_SECRET=1
fi

# AWS Access Key
if echo "$TOOL_INPUT" | grep -qE 'AKIA[0-9A-Z]{16}'; then
  echo "BLOCKED: AWS Access Key가 감지되었습니다."
  echo ""
  echo "다음과 같이 수정하세요:"
  echo "  - 환경 변수: export AWS_ACCESS_KEY_ID=\${AWS_ACCESS_KEY_ID}"
  echo "  - Spring: application.yml에 \${AWS_ACCESS_KEY_ID} 플레이스홀더"
  echo "  - AWS SDK 기본 자격증명 체인 활용"
  exit 2
fi

# Private Key
if echo "$TOOL_INPUT" | grep -q -- '-----BEGIN.*PRIVATE KEY-----'; then
  echo "BLOCKED: Private Key가 감지되었습니다."
  echo ""
  echo "다음과 같이 수정하세요:"
  echo "  - 파일 참조: classpath:keys/private.pem (gitignore 추가)"
  echo "  - 환경 변수: \${PRIVATE_KEY}"
  echo "  - Vault/AWS Secrets Manager 연동"
  exit 2
fi

# Generic Secret (password, secret, token, api_key 등에 값이 할당된 경우)
if [ "$SKIP_GENERIC_SECRET" -eq 0 ]; then
  if echo "$TOOL_INPUT" | grep -qiE '(password|secret|api[_-]?key|api[_-]?secret|token)[[:space:]]*[=:][[:space:]]*[^ ]{8,}'; then
    echo "BLOCKED: 하드코딩된 시크릿이 감지되었습니다."
    echo ""
    echo "다음과 같이 수정하세요:"
    echo "  - Spring: \${DB_PASSWORD} 플레이스홀더 사용"
    echo "  - Node.js: process.env.API_KEY"
    echo "  - .env.example에 키 이름만 기록 (값 없이)"
    exit 2
  fi
fi

# .env 파일 쓰기 시도
if [ "$TOOL_NAME" = "Write" ]; then
  if echo "$TOOL_INPUT" | grep -qE '\.env($|\.)'; then
    echo "BLOCKED: .env 파일 직접 쓰기가 차단되었습니다."
    echo ""
    echo "다음과 같이 수정하세요:"
    echo "  - .env.example 생성 후 값은 빈칸으로"
    echo "  - README에 환경 변수 설정 방법 안내"
    echo "  - 사용자에게 직접 .env 작성 요청"
    exit 2
  fi
fi

# 통과
exit 0
