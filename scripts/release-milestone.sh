#!/usr/bin/env bash
# 릴리스 기록(ai-harness 전용, release_policy.record_cmds). 그래프 러너의 record 노드가 태그 발행 뒤 실행한다.
#   release-milestone.sh <version>
#   - 마일스톤 v<version>이 열려 있으면 닫는다
#   - 다음 MINOR 마일스톤 v<major>.<minor+1>.0이 없으면 연다
# 저장소는 origin 주소에서 읽는다(하드코딩하지 않는다).
set -euo pipefail

usage() { printf 'usage: %s <version>\n' "${0##*/}" >&2; exit 2; }
version="${1:-}"
version="${version#v}"
[[ "$version" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || usage
next="v${BASH_REMATCH[1]}.$((BASH_REMATCH[2] + 1)).0"

origin="$(git remote get-url origin 2>/dev/null)" || { printf 'no origin remote\n' >&2; exit 1; }
slug="$(sed -E 's#^[a-z+]+://##; s#^[^@/]+@##; s#:([^0-9/][^/]*/)#/\1#; s#\.git/?$##' <<<"$origin" | cut -d/ -f2-3)"
[[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { printf 'cannot read owner/repo from origin %s\n' "$origin" >&2; exit 1; }

milestones="$(gh api "repos/$slug/milestones?state=all&per_page=100")"
current="$(jq -r --arg t "v$version" '[.[]? | select(.title == $t and .state == "open") | .number][0] // ""' <<<"$milestones")"
if [[ -n "$current" ]]; then
  gh api -X PATCH "repos/$slug/milestones/$current" -f state=closed --silent
  printf 'closed milestone v%s\n' "$version"
fi
if [[ -z "$(jq -r --arg t "$next" '[.[]? | select(.title == $t) | .number][0] // ""' <<<"$milestones")" ]]; then
  gh api -X POST "repos/$slug/milestones" -f title="$next" --silent
  printf 'opened milestone %s\n' "$next"
fi
