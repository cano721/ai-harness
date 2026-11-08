#!/usr/bin/env bash
# 예전 진입점. 그래프 러너는 workflow-driver.sh 하나이며, 이 파일은 기능 개발 워크플로로 넘긴다.
# 설치본은 같은 디렉터리에, 저장소 템플릿 배치에서는 templates/workflow-driver/에 있다.
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
driver="$dir/workflow-driver.sh"
[[ -f "$driver" ]] || driver="$dir/../../workflow-driver/workflow-driver.sh"
for arg in "$@"; do
  [[ "$arg" != --workflow ]] || { printf 'implement-feature-driver.sh runs the feature workflow only; use workflow-driver.sh --workflow <name>\n' >&2; exit 2; }
done
exec bash "$driver" "$@" --workflow feature
