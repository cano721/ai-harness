#!/usr/bin/env bash
# 현재 저장소의 origin을 보고 draft PR을 연다. GitHub는 gh, Bitbucket Cloud는 REST API.
# 자동 harvest가 curl 같은 범용 네트워크 권한 없이 PR을 만들 수 있게 하는 좁은 진입점이다.
# 성공 시 PR URL 한 줄을 출력한다.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: open-pr.sh --title <title> --body-file <file> [--base <branch>] [--head <branch>]
       open-pr.sh --check     # push 전에 PR을 열 수 있는지(원격 종류·인증·접근)만 확인
env:   Bitbucket은 ATLASSIAN_USER + BITBUCKET_API_TOKEN (Basic Auth)
       HM_OPEN_PR_DRY_RUN=1 이면 요청만 출력하고 보내지 않는다
EOF
  exit 2
}

title=""; body_file=""; base=""; head=""; check=0
while (( $# > 0 )); do
  case "$1" in
    --check) check=1; shift ;;
    --title) title="${2:-}"; shift 2 ;;
    --body-file) body_file="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
(( check == 1 )) || [[ -n "$title" && -f "$body_file" ]] || usage

remote="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "$remote" ]] || { echo "origin 원격이 없습니다" >&2; exit 3; }
[[ -n "$head" ]] || head="$(git rev-parse --abbrev-ref HEAD)"
if [[ -z "$base" ]]; then
  base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  base="${base#origin/}"
  [[ -n "$base" ]] || base="main"
fi

# git@host:owner/repo.git, https://[user@]host/owner/repo(.git) → host, owner/repo
path="${remote%.git}"
path="${path%/}"
case "$path" in
  git@*:*) host="${path#git@}"; host="${host%%:*}"; slug="${path#*:}" ;;
  ssh://*) host="${path#ssh://}"; host="${host#*@}"; host="${host%%/*}"; slug="${path#ssh://*/}" ;;
  http://*|https://*) host="${path#*://}"; host="${host#*@}"; host="${host%%/*}"; slug="${path#*://*/}" ;;
  *) echo "지원하지 않는 원격 형식: $remote" >&2; exit 3 ;;
esac

if (( check == 1 )); then
  case "$host" in
    github.com)
      gh repo view "$slug" --json name >/dev/null 2>&1 || { echo "GitHub 저장소에 접근할 수 없습니다: $slug" >&2; exit 5; }
      ;;
    bitbucket.org)
      if [[ -z "${ATLASSIAN_USER:-}" || -z "${BITBUCKET_API_TOKEN:-}" ]]; then
        echo "Bitbucket PR에는 ATLASSIAN_USER와 BITBUCKET_API_TOKEN이 필요합니다" >&2
        exit 4
      fi
      response="$(curl -sS -w '\n%{http_code}' -u "$ATLASSIAN_USER:$BITBUCKET_API_TOKEN" \
        "https://api.bitbucket.org/2.0/repositories/$slug/pullrequests?pagelen=1")"
      status="${response##*$'\n'}"
      if [[ "$status" != 2* ]]; then
        echo "Bitbucket 저장소 접근 불가 (HTTP $status): $(printf '%s' "${response%$'\n'*}" | head -c 200)" >&2
        exit 5
      fi
      ;;
    *) echo "PR을 열 수 없는 원격 호스트: $host" >&2; exit 3 ;;
  esac
  echo "ok $host $slug"
  exit 0
fi

case "$host" in
  github.com)
    if [[ "${HM_OPEN_PR_DRY_RUN:-0}" == "1" ]]; then
      jq -cn --arg slug "$slug" --arg base "$base" --arg head "$head" --arg title "$title" \
        '{provider:"github",slug:$slug,base:$base,head:$head,title:$title,draft:true}'
      exit 0
    fi
    gh pr create --draft --base "$base" --head "$head" --title "$title" --body-file "$body_file"
    ;;
  bitbucket.org)
    payload="$(jq -cn --arg title "$title" --rawfile body "$body_file" --arg base "$base" --arg head "$head" '{
      title:$title, description:$body, draft:true,
      source:{branch:{name:$head}}, destination:{branch:{name:$base}}
    }')"
    if [[ "${HM_OPEN_PR_DRY_RUN:-0}" == "1" ]]; then
      jq -c --arg slug "$slug" '{provider:"bitbucket",slug:$slug} + .' <<<"$payload"
      exit 0
    fi
    if [[ -z "${ATLASSIAN_USER:-}" || -z "${BITBUCKET_API_TOKEN:-}" ]]; then
      echo "Bitbucket PR에는 ATLASSIAN_USER와 BITBUCKET_API_TOKEN이 필요합니다" >&2
      exit 4
    fi
    response="$(curl -sS -w '\n%{http_code}' -X POST \
      -u "$ATLASSIAN_USER:$BITBUCKET_API_TOKEN" -H 'Content-Type: application/json' \
      --data "$payload" "https://api.bitbucket.org/2.0/repositories/$slug/pullrequests")"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    if [[ "$status" != 2* ]]; then
      echo "Bitbucket PR 생성 실패 (HTTP $status): $(jq -r '.error.message // .' <<<"$body" 2>/dev/null | head -c 300)" >&2
      exit 5
    fi
    jq -r '.links.html.href' <<<"$body"
    ;;
  *)
    echo "PR을 열 수 없는 원격 호스트: $host" >&2
    exit 3
    ;;
esac
