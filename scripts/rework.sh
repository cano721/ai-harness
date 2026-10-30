#!/usr/bin/env bash
# 재작업 비율 (읽기 전용, git 기록만 본다).
#   rework.sh --repo <dir> [--repo <dir>]... [--author <pattern>] [--since YYYY-MM-DD] [--until YYYY-MM-DD]
#             [--window <days>] [--key-pattern <ERE>] [--exclude-key <KEY>]... [--now <epoch>]
# 기간 안에 머지된 PR 중, 머지 뒤 window일 안에 같은 이슈 키로 새 PR 작업이 시작된 비율을 JSON으로 낸다.
# PR은 원격 브랜치의 머지 커밋 제목으로 찾는다 — Bitbucket "Merged in <branch> (pull request #N)",
# GitHub "Merge pull request #N from <owner>/<branch>", 스쿼시 "<title> (#N)". 이슈 키는 제목에서 뽑는다.
# 후속 PR의 시작 시각은 그 PR이 들여온 커밋 중 가장 이른 author 시각이다. 원본 머지 전에 시작한
# 분할 PR은 후속으로 세지 않는다. 아직 머지되지 않은 후속 PR은 git에 없으므로 세지 못한다(과소 추정 방향).
set -euo pipefail

usage() {
  printf 'usage: %s --repo <dir> [--repo <dir>]... [--author <pattern>] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--window <days>] [--key-pattern <ERE>] [--exclude-key <KEY>]... [--now <epoch>]\n' "$0" >&2
  exit 2
}

date_to_epoch() { # YYYY-MM-DD (UTC 자정)
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s
}

repos=()
author=""
since=""
until=""
window=7
key_pattern='[A-Z][A-Z0-9]+-[0-9]+'
excluded=()
now="$(date +%s)"
while (($#)); do
  case "$1" in
    --repo) repos+=("${2:-}"); shift 2 ;;
    --author) author="${2:-}"; shift 2 ;;
    --since) since="${2:-}"; shift 2 ;;
    --until) until="${2:-}"; shift 2 ;;
    --window) window="${2:-}"; shift 2 ;;
    --key-pattern) key_pattern="${2:-}"; shift 2 ;;
    --exclude-key) excluded+=("${2:-}"); shift 2 ;;
    --now) now="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
((${#repos[@]} > 0)) || usage
[[ "$window" =~ ^[0-9]+$ ]] || usage

since_epoch=0
[[ -n "$since" ]] && since_epoch="$(date_to_epoch "$since")"
until_epoch="$now"
# --until은 그날 끝까지 포함한다.
[[ -n "$until" ]] && until_epoch=$(($(date_to_epoch "$until") + 86399))
window_secs=$((window * 86400))

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rework.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/prs.jsonl"

for repo in "${repos[@]}"; do
  [[ -d "$repo" ]] || { printf 'not a directory: %s\n' "$repo" >&2; exit 2; }
  name="$(basename "$(cd "$repo" && pwd -P)")"
  # 후속 PR은 기간 끝 뒤에 머지될 수 있으므로 기간 시작부터 지금까지 전부 모은다.
  since_args=()
  [[ -n "$since" ]] && since_args=("--since=$since 00:00:00 +0000")
  log="$(git -C "$repo" log --remotes --format='%H%x09%P%x09%ct%x09%s' ${since_args[@]+"${since_args[@]}"} 2>/dev/null || true)"
  [[ -n "$log" ]] || continue
  while IFS=$'\t' read -r sha parents merged_at subject; do
    [[ -n "$sha" ]] || continue
    pr=""
    if [[ "$subject" =~ ^Merged\ in\ .*\(pull\ request\ \#([0-9]+)\)$ ]]; then
      pr="${BASH_REMATCH[1]}"
    elif [[ "$subject" =~ ^Merge\ pull\ request\ \#([0-9]+)\ from ]]; then
      pr="${BASH_REMATCH[1]}"
    elif [[ "$subject" =~ \(\#([0-9]+)\)$ ]]; then
      pr="${BASH_REMATCH[1]}"
    fi
    [[ -n "$pr" ]] || continue
    key="$(grep -oE "$key_pattern" <<<"$subject" | head -1 || true)"
    [[ -n "$key" ]] || continue
    # 머지 커밋이면 그 PR이 들여온 커밋(첫 부모에 없던 것), 아니면(스쿼시) 그 커밋 하나.
    read -r -a parent_list <<<"$parents"
    if ((${#parent_list[@]} > 1)); then
      commits="$(git -C "$repo" log --format='%at%x09%ae%x09%an' "${parent_list[0]}..${parent_list[1]}" 2>/dev/null || true)"
    else
      commits="$(git -C "$repo" log -1 --format='%at%x09%ae%x09%an' "$sha")"
    fi
    [[ -n "$commits" ]] || continue
    started_at="$(cut -f1 <<<"$commits" | sort -n | head -1)"
    authors="$(cut -f2,3 <<<"$commits" | tr '\t' ' ' | sort -u | jq -R . | jq -sc .)"
    jq -cn --arg repo "$name" --arg pr "$pr" --arg key "$key" --arg subject "$subject" \
      --argjson merged_at "$merged_at" --argjson started_at "$started_at" --argjson authors "$authors" \
      '{repo:$repo, pr:($pr|tonumber), key:$key, subject:$subject, merged_at:$merged_at, started_at:$started_at, authors:$authors}' \
      >>"$TMP/prs.jsonl"
  done <<<"$log"
done

excluded_json="$(printf '%s\n' "${excluded[@]+"${excluded[@]}"}" | jq -R 'select(. != "")' | jq -sc .)"

jq -s --arg author "$author" --argjson since "$since_epoch" --argjson until "$until_epoch" \
  --argjson window "$window_secs" --argjson days "$window" --argjson now "$now" --argjson excluded "$excluded_json" '
  # 같은 PR이 여러 대상 브랜치(develop·release)에 머지되면 처음 머지를 쓴다.
  (group_by([.repo, .pr]) | map(min_by(.merged_at))) as $prs
  | ($prs | map(select((.key as $k | $excluded | index($k)) | not))) as $prs
  | [$prs[]
      | select(.merged_at >= $since and .merged_at <= $until)
      | select($author == "" or any(.authors[]; test($author; "i")))
      | . as $o
      | ([$prs[] | select(.repo == $o.repo and .key == $o.key and .pr != $o.pr
            and .started_at > $o.merged_at and .started_at <= $o.merged_at + $window)
          | {pr, started_at, merged_at}]) as $followups
      | $o + {followups: $followups,
              rework: ($followups | length > 0),
              pending: (($followups | length) == 0 and $o.merged_at + $window > $now)}]
  | . as $items
  | ($items | map(select(.pending | not))) as $settled
  | {window_days: $days,
     since: (if $since > 0 then ($since | todate) else null end),
     until: ($until | todate),
     author: (if $author == "" then null else $author end),
     merged_prs: ($items | length),
     settled_prs: ($settled | length),
     rework_prs: ($settled | map(select(.rework)) | length),
     pending_prs: ($items | map(select(.pending)) | length),
     rework_ratio: (if ($settled | length) == 0 then null
                    else (($settled | map(select(.rework)) | length) * 1000 / ($settled | length) | round / 10) end),
     by_repo: ($settled | group_by(.repo) | map({repo: .[0].repo, prs: length, rework: map(select(.rework)) | length})),
     rework: ($settled | map(select(.rework) | {repo, pr, key, merged_at: (.merged_at | todate),
              followups: (.followups | map({pr, started_at: (.started_at | todate)}))}))}
' "$TMP/prs.jsonl"
