#!/bin/bash
# infra-change-review.sh — PreToolUse Hook
# 인프라 파일 변경에서 위험한 작업과 하드코딩된 시크릿을 차단한다.
# Write, Edit, Bash 도구 대상으로 동작.
# exit 0 = 통과, exit 2 = 차단

TOOL_NAME="$1"
TOOL_INPUT="$2"

# Write, Edit, Bash 도구만 검사
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Bash 도구: 위험한 인프라 명령 차단
if [ "$TOOL_NAME" = "Bash" ]; then
  # terraform destroy 차단
  if echo "$TOOL_INPUT" | grep -qE 'terraform\s+destroy'; then
    echo "BLOCKED: terraform destroy는 하네스 보안 정책에 의해 차단됩니다. 인프라 삭제는 수동으로 검토 후 실행하세요."
    exit 2
  fi

  # kubectl delete namespace 차단
  if echo "$TOOL_INPUT" | grep -qE 'kubectl\s+delete\s+namespace|kubectl\s+delete\s+ns\b'; then
    echo "BLOCKED: kubectl delete namespace는 하네스 보안 정책에 의해 차단됩니다. 네임스페이스 삭제는 수동으로 검토 후 실행하세요."
    exit 2
  fi

  # helm uninstall/delete 차단
  if echo "$TOOL_INPUT" | grep -qE 'helm\s+(uninstall|delete)\b'; then
    echo "BLOCKED: helm uninstall/delete는 하네스 보안 정책에 의해 차단됩니다. 프로덕션 릴리즈 삭제는 수동으로 검토 후 실행하세요."
    exit 2
  fi

  exit 0
fi

# Write, Edit 도구: .tf 파일의 하드코딩 시크릿 차단
if echo "$TOOL_INPUT" | grep -qE '\.tf\b|terraform'; then
  if echo "$TOOL_INPUT" | grep -qiE '(password|secret_key|access_key|api_key|private_key)\s*=\s*"[^$"{][^"]{3,}"'; then
    echo "BLOCKED: Terraform 파일에 하드코딩된 시크릿이 감지되었습니다. AWS Secrets Manager, Vault 또는 환경 변수를 사용하세요."
    exit 2
  fi
fi

# 통과
exit 0
