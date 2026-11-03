#!/usr/bin/env bash
# 현재 저장소의 origin을 보고 draft PR을 연다. GitHub는 gh, Bitbucket Cloud는 REST API.
# 자동 harvest가 curl 같은 범용 네트워크 권한 없이 PR을 만들 수 있게 하는 좁은 진입점이다.
# 성공 시 PR URL 한 줄을 출력한다.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: open-pr.sh --title <title> --body-file <file> [--base <branch>] [--head <branch>]
       open-pr.sh --check     # push 전에 PR을 열 수 있는지(원격 종류·인증·접근)만 확인
       open-pr.sh --status <PR URL>   # {state:open|merged|closed, merged_at, merge_commit, activity} — activity는 코멘트·리뷰·승인 수(GitHub는 봇 제외)
       open-pr.sh --decline <PR URL> [--comment <text>]   # PR을 병합 없이 닫는다(GitHub close, Bitbucket decline)
       open-pr.sh --merge <PR URL> --head <sha> [--method squash|merge|default]   # draft를 풀고 head가 같을 때만 병합
         --status는 head·base(대상 브랜치)·created(UTC, 초까지)·draft·ci(success|pending|failure|none)·mergeable(mergeable|conflicting|unknown)도 낸다
         --merge 종료 코드: 6 head가 바뀜 · 7 병합됐지만 병합된 head가 다름 · 8 실패 뒤 draft로 되돌리지 못함 · 5 그 밖의 실패
env:   Bitbucket은 ATLASSIAN_USER + BITBUCKET_API_TOKEN (Basic Auth)
       HM_OPEN_PR_DRY_RUN=1 이면 요청만 출력하고 보내지 않는다
EOF
  exit 2
}

title=""; body_file=""; base=""; head=""; check=0; status_url=""; decline_url=""; comment=""; merge_url=""; method="default"
while (( $# > 0 )); do
  case "$1" in
    --check) check=1; shift ;;
    --status) status_url="${2:-}"; shift 2 ;;
    --decline) decline_url="${2:-}"; shift 2 ;;
    --merge) merge_url="${2:-}"; shift 2 ;;
    --method) method="${2:-}"; shift 2 ;;
    --comment) comment="${2:-}"; shift 2 ;;
    --title) title="${2:-}"; shift 2 ;;
    --body-file) body_file="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
(( check == 1 )) || [[ -n "$status_url" || -n "$decline_url" ]] || [[ -n "$merge_url" && -n "$head" ]] \
  || [[ -n "$title" && -f "$body_file" ]] || usage
case "$method" in squash|merge|default) ;; *) usage ;; esac

# 자격증명은 프로세스 인자(ps에 보임) 대신 stdin 설정으로 넘기고, 응답 없는 네트워크에 묶이지 않게 30초로 제한한다.
bb_curl() {
  printf 'user = "%s:%s"\n' "$ATLASSIAN_USER" "$BITBUCKET_API_TOKEN" \
    | curl -sS --max-time 30 -K - -w '\n%{http_code}' "$@"
}

# PR URL만으로 닫는다 — 자동 sync가 새 버전 PR로 대체한 옛 PR을 정리할 때 쓴다.
if [[ -n "$decline_url" ]]; then
  case "$decline_url" in
    https://github.com/*/pull/[0-9]*)
      if [[ "${HM_OPEN_PR_DRY_RUN:-0}" == "1" ]]; then
        jq -cn --arg url "$decline_url" --arg comment "$comment" '{provider:"github",decline:$url,comment:$comment}'
        exit 0
      fi
      if [[ -n "$comment" ]]; then gh pr close "$decline_url" --comment "$comment" >/dev/null; else gh pr close "$decline_url" >/dev/null; fi
      ;;
    https://bitbucket.org/*/*/pull-requests/[0-9]*)
      rest="${decline_url#https://bitbucket.org/}"
      IFS=/ read -r ws repo _ id _ <<<"$rest"
      [[ "$id" =~ ^[0-9]+$ ]] || { echo "PR URL 형식이 아닙니다: $decline_url" >&2; exit 2; }
      payload="$(jq -cn --arg m "$comment" 'if $m == "" then {} else {message:$m} end')"
      if [[ "${HM_OPEN_PR_DRY_RUN:-0}" == "1" ]]; then
        jq -c --arg url "$decline_url" '{provider:"bitbucket",decline:$url} + .' <<<"$payload"
        exit 0
      fi
      [[ -n "${ATLASSIAN_USER:-}" && -n "${BITBUCKET_API_TOKEN:-}" ]] || { echo "Bitbucket에는 ATLASSIAN_USER와 BITBUCKET_API_TOKEN이 필요합니다" >&2; exit 4; }
      response="$(bb_curl -X POST -H 'Content-Type: application/json' --data "$payload" \
        "https://api.bitbucket.org/2.0/repositories/$ws/$repo/pullrequests/$id/decline")"
      code="${response##*$'\n'}"
      [[ "$code" == 2* ]] || { echo "Bitbucket PR 닫기 실패 (HTTP $code)" >&2; exit 5; }
      ;;
    *) echo "지원하지 않는 PR URL: $decline_url" >&2; exit 3 ;;
  esac
  printf 'declined %s\n' "$decline_url"
  exit 0
fi

# PR URL만으로 병합한다 — 자동 병합(auto-merge.sh)이 판정을 마친 뒤 부른다. draft를 풀고,
# 판정한 head와 지금 head가 같을 때만 병합한다(GitHub는 --match-head-commit, Bitbucket은 직전 재조회).
if [[ -n "$merge_url" ]]; then
  [[ "$head" =~ ^[0-9a-f]{7,40}$ ]] || { echo "head는 커밋 해시여야 합니다: $head" >&2; exit 2; }
  case "$merge_url" in
    https://github.com/*/pull/[0-9]*)
      gh_method="squash"; [[ "$method" != merge ]] || gh_method="merge"
      if [[ "${HM_OPEN_PR_DRY_RUN:-0}" == "1" ]]; then
        jq -cn --arg url "$merge_url" --arg head "$head" --arg m "$gh_method" '{provider:"github",merge:$url,head:$head,method:$m}'
        exit 0
      fi
      # head를 먼저 맞춰 본 뒤 draft를 푼다. 병합이 실패하면 draft로 되돌려 사람이 보던 상태로 둔다.
      now_head="$(gh pr view "$merge_url" --json headRefOid -q .headRefOid)" || exit 5
      [[ "$now_head" == "$head"* && ${#now_head} -ge 40 ]] || { echo "head가 바뀌었습니다: $head → ${now_head:-?}" >&2; exit 6; }
      was_draft="$(gh pr view "$merge_url" --json isDraft -q .isDraft)" || exit 5
      [[ "$was_draft" != true ]] || gh pr ready "$merge_url" >/dev/null || exit 5
      if ! gh pr merge "$merge_url" "--$gh_method" --match-head-commit "$now_head" >/dev/null; then
        if [[ "$was_draft" == true ]] && ! gh pr ready --undo "$merge_url" >/dev/null 2>&1; then
          echo "GitHub 병합 실패, draft로 되돌리지 못함" >&2; exit 8
        fi
        echo "GitHub 병합 실패" >&2
        exit 5
      fi
      ;;
    https://bitbucket.org/*/*/pull-requests/[0-9]*)
      rest="${merge_url#https://bitbucket.org/}"
      IFS=/ read -r ws repo _ id _ <<<"$rest"
      [[ "$id" =~ ^[0-9]+$ ]] || { echo "PR URL 형식이 아닙니다: $merge_url" >&2; exit 2; }
      api="https://api.bitbucket.org/2.0/repositories/$ws/$repo/pullrequests/$id"
      case "$method" in
        squash) payload='{"close_source_branch":true,"merge_strategy":"squash"}' ;;
        merge) payload='{"close_source_branch":true,"merge_strategy":"merge_commit"}' ;;
        *) payload='{"close_source_branch":true}' ;;
      esac
      if [[ "${HM_OPEN_PR_DRY_RUN:-0}" == "1" ]]; then
        jq -c --arg url "$merge_url" --arg head "$head" '{provider:"bitbucket",merge:$url,head:$head} + .' <<<"$payload"
        exit 0
      fi
      [[ -n "${ATLASSIAN_USER:-}" && -n "${BITBUCKET_API_TOKEN:-}" ]] || { echo "Bitbucket에는 ATLASSIAN_USER와 BITBUCKET_API_TOKEN이 필요합니다" >&2; exit 4; }
      bb_redraft() { # 실패 뒤 draft로 되돌린다. 못 되돌리면 exit 8
        local r=""
        r="$(bb_curl -X PUT -H 'Content-Type: application/json' --data '{"draft":true}' "$api")"
        [[ "${r##*$'\n'}" == 2* ]] || { echo "draft로 되돌리지 못함" >&2; exit 8; }
      }
      bb_head_ok() { # PR JSON → head가 판정한 커밋(12자리 이상 접두)인지
        local h=""
        h="$(jq -r '.source.commit.hash // empty' <<<"$1")"
        [[ ${#h} -ge 12 && "$head" == "$h"* ]]
      }
      # Bitbucket merge API는 head를 고정할 수 없다. draft를 풀기 전, 푼 직후(응답), 병합 응답에서 head를 세 번 맞춰 본다.
      # 남는 틈(마지막 확인과 병합 사이 push)은 막지 못한다 — 병합 응답의 head가 다르면 exit 7로 알린다.
      response="$(bb_curl "$api")"
      code="${response##*$'\n'}"
      [[ "$code" == 2* ]] || { echo "Bitbucket PR 조회 실패 (HTTP $code)" >&2; exit 5; }
      bb_head_ok "${response%$'\n'*}" || { echo "head가 바뀌었습니다" >&2; exit 6; }
      was_draft="$(jq -r '.draft // false' <<<"${response%$'\n'*}")"
      if [[ "$was_draft" == true ]]; then
        response="$(bb_curl -X PUT -H 'Content-Type: application/json' --data '{"draft":false}' "$api")"
        code="${response##*$'\n'}"
        [[ "$code" == 2* ]] || { echo "Bitbucket draft 해제 실패 (HTTP $code)" >&2; exit 5; }
        bb_head_ok "${response%$'\n'*}" || { bb_redraft; echo "head가 바뀌었습니다" >&2; exit 6; }
      fi
      response="$(bb_curl -X POST -H 'Content-Type: application/json' --data "$payload" "$api/merge")"
      code="${response##*$'\n'}"
      if [[ "$code" != 2* ]]; then
        [[ "$was_draft" != true ]] || bb_redraft
        echo "Bitbucket 병합 실패 (HTTP $code): $(jq -r '.error.message // empty' <<<"${response%$'\n'*}" 2>/dev/null | head -c 300)" >&2
        exit 5
      fi
      bb_head_ok "${response%$'\n'*}" || { echo "병합은 됐지만 병합된 head가 판정한 커밋과 다릅니다" >&2; exit 7; }
      ;;
    *) echo "지원하지 않는 PR URL: $merge_url" >&2; exit 3 ;;
  esac
  printf 'merged %s\n' "$merge_url"
  exit 0
fi

# PR URL만으로 상태를 본다 — 원격·체크아웃과 무관하게 돈다.
if [[ -n "$status_url" ]]; then
  case "$status_url" in
    https://github.com/*/pull/[0-9]*)
      gh pr view "$status_url" --json state,createdAt,mergedAt,mergeCommit,comments,reviews,headRefOid,baseRefName,isDraft,mergeable,mergeStateStatus,statusCheckRollup \
        | jq -c '{state: (.state | ascii_downcase), merged_at: (.mergedAt // null), merge_commit: (.mergeCommit.oid? // null),
            activity: ([(.comments // [])[], (.reviews // [])[] | .author.login? // "" | select(test("\\[bot\\]$|^github-actions$") | not)] | length),
            head: (.headRefOid // null), base: (.baseRefName // null), draft: (.isDraft // false), created: ((.createdAt // "")[0:19]),
            mergeable: ((.mergeable // "UNKNOWN") | ascii_downcase),
            # 아직 생기지 않은 필수 검사는 rollup에 없다. 브랜치 보호가 막고 있으면(BLOCKED) 통과로 보지 않는다.
            ci: ((.statusCheckRollup // []) as $c | (.mergeStateStatus // "") as $ms
              | if ($c | length) == 0 then "none"
                elif any($c[]; ((.conclusion // "") | test("^(FAILURE|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE)$"))
                  or ((.state // "") | test("^(FAILURE|ERROR)$"))) then "failure"
                elif any($c[]; ((.status // "COMPLETED") != "COMPLETED") or ((.state // "") | test("^(PENDING|EXPECTED)$"))) then "pending"
                elif $ms == "BLOCKED" then "pending"
                else "success" end)}'
      ;;
    https://bitbucket.org/*/*/pull-requests/[0-9]*)
      [[ -n "${ATLASSIAN_USER:-}" && -n "${BITBUCKET_API_TOKEN:-}" ]] || { echo "Bitbucket 조회에는 ATLASSIAN_USER와 BITBUCKET_API_TOKEN이 필요합니다" >&2; exit 4; }
      rest="${status_url#https://bitbucket.org/}"
      IFS=/ read -r ws repo _ id _ <<<"$rest"
      [[ "$id" =~ ^[0-9]+$ ]] || { echo "PR URL 형식이 아닙니다: $status_url" >&2; exit 2; }
      response="$(bb_curl "https://api.bitbucket.org/2.0/repositories/$ws/$repo/pullrequests/$id")"
      code="${response##*$'\n'}"
      [[ "$code" == 2* ]] || { echo "Bitbucket PR 조회 실패 (HTTP $code)" >&2; exit 5; }
      pr_json="${response%$'\n'*}"
      head_hash="$(jq -r '.source.commit.hash // empty' <<<"$pr_json")"
      ci_json='{"values":[]}'
      if [[ "$head_hash" =~ ^[0-9a-f]+$ ]]; then
        # 빌드 상태가 한 페이지를 넘으면 다음 페이지까지 모두 모은다(실패가 뒤 페이지에 있으면 통과로 읽히지 않게).
        next="https://api.bitbucket.org/2.0/repositories/$ws/$repo/commit/$head_hash/statuses?pagelen=100"
        pages=0
        while [[ -n "$next" ]] && (( pages < 10 )); do
          response="$(bb_curl "$next")"
          code="${response##*$'\n'}"
          [[ "$code" == 2* ]] || { echo "Bitbucket 빌드 상태 조회 실패 (HTTP $code)" >&2; exit 5; }
          ci_json="$(jq -c --argjson acc "$ci_json" '{values: ($acc.values + (.values // []))}' <<<"${response%$'\n'*}")"
          next="$(jq -r '.next // empty' <<<"${response%$'\n'*}")"
          pages=$((pages + 1))
        done
        [[ -z "$next" ]] || ci_json='{"values":[{"state":"INPROGRESS"}]}'
      fi
      # Bitbucket은 병합 시각 필드가 없다. 병합된 PR은 이후 수정되지 않으므로 updated_on을 병합 시각으로 쓴다.
      # 충돌 여부를 미리 알려 주지 않아 mergeable은 unknown이다 — 병합 요청이 merge check로 거절한다.
      jq -c --argjson ci "$ci_json" '{state: (if .state == "MERGED" then "merged" elif .state == "OPEN" then "open" else "closed" end),
        merged_at: (if .state == "MERGED" then .updated_on else null end), merge_commit: (.merge_commit.hash? // null),
        activity: ((.comment_count // 0) + ([.participants[]? | select(.approved == true or (.state // null) != null)] | length)),
        head: (.source.commit.hash // null), base: (.destination.branch.name // null), draft: (.draft // false), mergeable: "unknown",
        created: ((.created_on // "")[0:19]),
        ci: (($ci.values // []) as $c
          | if ($c | length) == 0 then "none"
            elif any($c[]; .state == "FAILED" or .state == "STOPPED") then "failure"
            elif any($c[]; .state == "INPROGRESS") then "pending"
            else "success" end)}' <<<"$pr_json"
      ;;
    *) echo "지원하지 않는 PR URL: $status_url" >&2; exit 3 ;;
  esac
  exit
fi

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
      response="$(bb_curl "https://api.bitbucket.org/2.0/repositories/$slug/pullrequests?pagelen=1")"
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
    response="$(bb_curl -X POST -H 'Content-Type: application/json' --data "$payload" \
      "https://api.bitbucket.org/2.0/repositories/$slug/pullrequests")"
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
