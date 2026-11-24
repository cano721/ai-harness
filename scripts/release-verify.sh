#!/usr/bin/env bash
# 릴리스 배포 확인(ai-harness 전용, release_policy.verify_cmd). 그래프 러너의 verify 노드가 실행하고, 실패하면 기한 안에서 다시 본다.
#   release-verify.sh <version>
#   - GitHub `release` 워크플로가 태그 v<version>에서 모두 성공으로 끝났는가(진행 중·미등록이면 실패 — 러너가 resume으로 다시 본다)
#   - origin/main의 release.json version이 <version>인가(사용자가 /harness-update로 받는 버전)
set -euo pipefail

usage() { printf 'usage: %s <version>\n' "${0##*/}" >&2; exit 2; }
version="${1:-}"
version="${version#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
tag="v$version"

runs="$(gh run list --workflow release --branch "$tag" --json status,conclusion,headBranch --limit 20)" \
  || { printf 'cannot read the release workflow runs for %s\n' "$tag" >&2; exit 1; }
runs="$(jq -c --arg t "$tag" '[.[]? | select(.headBranch == $t)]' <<<"$runs")"
if [[ "$(jq 'length' <<<"$runs")" -eq 0 ]]; then
  printf 'the release workflow has not run for %s yet\n' "$tag" >&2
  exit 1
fi
if jq -e 'any(.[]; .status != "completed")' <<<"$runs" >/dev/null; then
  printf 'the release workflow for %s is still running\n' "$tag" >&2
  exit 1
fi
if jq -e 'any(.[]; .conclusion != "success")' <<<"$runs" >/dev/null; then
  printf 'the release workflow for %s did not succeed: %s\n' "$tag" "$(jq -r 'map(.conclusion // "none") | join(", ")' <<<"$runs")" >&2
  exit 1
fi

GIT_TERMINAL_PROMPT=0 git fetch -q origin main </dev/null || { printf 'git fetch origin main failed\n' >&2; exit 1; }
shipped="$(git show origin/main:release.json | jq -r '.version // ""')"
if [[ "$shipped" != "$version" ]]; then
  printf 'origin/main release.json is %s, not %s\n' "${shipped:-(none)}" "$version" >&2
  exit 1
fi
printf '%s is released: the release workflow passed and origin/main ships %s\n' "$tag" "$version"
