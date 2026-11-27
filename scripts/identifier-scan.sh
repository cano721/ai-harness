#!/usr/bin/env bash
# 공개 저장소 식별자 검사. 회사명·사용자 ID·실명 같은 금지어 목록을 저장소 밖에서 읽어 파일을 검사한다.
# 목록을 소스에 두면 그 자체가 공개되므로, 목록은 환경변수나 개인 설정에만 둔다.
#   identifier-scan.sh            : 현재 저장소의 추적 파일(git ls-files) 전체
#   identifier-scan.sh <경로>...  : 주어진 파일·디렉토리만
# 목록 출처: HM_IDENTIFIER_DENYLIST 환경변수(줄바꿈·| 구분) → 비면 $HM_DATA_DIR/config의 같은 키(| 구분).
# 목록이 없으면 건너뛰고 0으로 끝난다(secret이 없는 fork PR의 CI).
# 금지어는 대소문자 무시 고정 문자열로 찾고 바이너리는 뺀다. 출력은 `파일:줄`만 — CI 로그도 공개라
# 금지어와 줄 내용은 찍지 않는다. 매치가 있으면 1, 없으면 0, 사용법·경로 오류는 2.
set -euo pipefail

# lib.sh는 source될 때 config 값으로 같은 이름의 환경변수를 덮어쓴다. env가 이기도록 먼저 저장한다.
denylist_env="${HM_IDENTIFIER_DENYLIST:-}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"
denylist="$denylist_env"
[[ -n "$denylist" ]] || denylist="${HM_IDENTIFIER_DENYLIST:-}"

list_file="$(mktemp "${TMPDIR:-/tmp}/identifier-scan.XXXXXX")"
trap 'rm -f "$list_file"' EXIT
# 빈 패턴은 grep -F에서 모든 줄과 일치하므로 앞뒤 공백·CR을 지우고 빈 항목을 버린다.
printf '%s\n' "$denylist" | tr '|' '\n' | tr -d '\r' \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | { grep -v '^$' || true; } >"$list_file"

if [[ ! -s "$list_file" ]]; then
  echo "identifier-scan: 건너뜀 (HM_IDENTIFIER_DENYLIST 없음)"
  exit 0
fi

rc=0
if [[ $# -eq 0 ]]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "identifier-scan: git 저장소 안에서 실행하거나 경로를 인자로 준다" >&2
    exit 2
  }
  hits="$(cd "$root" && git grep -I -i -n -F --no-color -f "$list_file")" || rc=$?
else
  for path in "$@"; do
    [[ -e "$path" ]] || { echo "identifier-scan: 경로 없음: $path" >&2; exit 2; }
  done
  # GNU grep은 -r에 파일 하나만 주면 파일명을 빼므로 -H로 늘 `파일:줄:내용` 형식을 맞춘다.
  hits="$(grep -r -H -I -i -n -F -f "$list_file" -- "$@")" || rc=$?
fi
# grep·git grep: 0 매치 있음, 1 매치 없음, 그 밖은 오류.
if [[ $rc -gt 1 ]]; then
  echo "identifier-scan: 검사 실패 (exit $rc)" >&2
  exit 2
fi
if [[ -z "$hits" ]]; then
  echo "identifier-scan: 통과"
  exit 0
fi
# 파일명 뒤 첫 `:숫자:`까지만 남긴다(줄 내용의 콜론에 흔들리지 않게). 형식이 어긋난 줄은 내용 대신 자리표시만 찍는다.
printf '%s\n' "$hits" | sed -E -e 's/^(([^:]|:[^0-9])*:[0-9]+):.*$/\1/' -e 't' -e 's/.*/(파일:줄 해석 실패)/'
echo "identifier-scan: 금지어 목록과 일치하는 줄 $(printf '%s\n' "$hits" | wc -l | tr -d ' ')건 (파일:줄)"
exit 1
