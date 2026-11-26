#!/usr/bin/env bash
# Harness Board 상태: ~/.ai-harness 데이터와 작업 세션(work.sh)을 칸반 항목 JSON으로 바꾼다.
# 출력: {generated_at, window_days, quiet_runs:[{kind, count, last_at}], items:[{section, kind, project, state, at, title, detail, link, log, cmd, id, actions}]}
# state: queued | running | needs_human | blocked | done
# 러너 칸은 state.json status마다 따로 나누고(#564), 모르는 status를 '작업 중'으로 두지 않는다. 오래된 결정 대기는 막힘으로 내린다.
set -euo pipefail

DATA="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAYS="${BOARD_DAYS:-7}"
STALE_HOURS="${BOARD_STALE_HOURS:-6}"
now_e=$(date -u +%s)
since=$(jq -rn --argjson e "$((now_e - DAYS * 86400))" '$e | todate')

result_excerpt() {
  local log=$1
  [ -f "$log" ] || return 0
  jq -r 'select(.type? == "result") | .result // empty' "$log" 2>/dev/null | tail -c 4000 |
    grep -v '^AI_HARNESS_' | grep -v '^[[:space:]]*$' | head -6 | cut -c1-240
}

last_progress() {
  local log=$1 line
  [ -s "$log" ] || return 0
  line=$(jq -R -r 'fromjson? | select(type == "object" and .type == "progress") | "\(.tool) \(.target // "")"' "$log" 2>/dev/null | tail -n 1)
  [ -z "$line" ] || printf '끊기기 전 마지막 진행: %s\n' "$line"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 작업(work.sh)과 하네스 칸(아래 1–5)을 합쳐 낸다. $1 = 하네스 칸 파일이 있는 폴더(이번에 만든 $tmp 또는 입력 캐시).
finish() {
  local h=$1
  bash "$(dirname "$0")/work.sh" > "$tmp/work.json" 2>/dev/null || echo '[]' > "$tmp/work.json"
  jq -e 'type == "array"' "$tmp/work.json" >/dev/null 2>&1 || echo '[]' > "$tmp/work.json"

  jq -s --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson days "$DAYS" --slurpfile work "$tmp/work.json" --slurpfile quiet "$h/quiet.json" \
    --slurpfile qhidden "$h/queue_hidden.json" \
    '{generated_at: $gen, window_days: $days, quiet_runs: $quiet[0], queue_hidden: $qhidden[0], items: ((add | map(
       .section = (if .kind == "runner" then "work" else "harness" end)
       | .id = "\(.kind)|\(.project)|\(.at)"
       | .actions = ([ (select(.state == "queued" and (.kind | startswith("harvest"))) | "harvest_now"),
                       (select(.state == "needs_human" and .repo != null) | "open_agent") ])
       | .cause = (if .state == "needs_human" and ((.detail // "") | test("whitelist|화이트리스트|HTTP 403|원격에 접근할 수 없|PR 생성 사전 점검 실패|PR을 열 수 없")) then "remote_blocked" else null end)))
       + $work[0] | sort_by(.at // "") | reverse)}' \
    "$h/runs2.json" "$h/skips.json" "$h/sched.json" "$h/runner.json" "$h/applied.json" "$h/queue.json"
}

# 입력 캐시(#380): 보드의 백그라운드 갱신은 BOARD_CACHE_SECONDS를 넘긴다. 하네스 기록 파일들의 크기·수정 시각이 그대로이고
# 그 초보다 젊으면 지난 하네스 칸을 다시 쓴다(시각에 따라 바뀌는 판정 — 멈춤·기간 — 은 그 초 안에서만 늦는다). 없으면(기본) 늘 새로 모은다.
PARTS="runs2 skips sched runner applied queue quiet queue_hidden"
CACHE_SECS="${BOARD_CACHE_SECONDS:-0}"
case "$CACHE_SECS" in ''|*[!0-9]*) CACHE_SECS=0 ;; esac
HCACHE="$DATA/board/status-cache"
hkey=""
if [ "$CACHE_SECS" -gt 0 ]; then
  if stat -c %s /dev/null >/dev/null 2>&1; then keys_of() { stat --printf '%s:%Y\t%n\n' "$@" 2>/dev/null; }
  else keys_of() { stat -f '%z:%m%t%N' "$@" 2>/dev/null; }; fi
  hkey=$({ printf '%s %s %s %s %s\n' "$DAYS" "$STALE_HOURS" "${BOARD_RUNNER_STALE_MIN:-}" "${BOARD_DECISION_STALE_DAYS:-}" "$SCRIPTS_DIR"
    keys_of "$DATA/harvest-auto/runs.jsonl" "$DATA/autofix/runs.jsonl" "$DATA/logs/schedule.jsonl" "$DATA/applied/applied.jsonl" \
      "$DATA"/runs/*/*/* "$DATA"/harvest-queue/*/analysis-batch.json "$DATA"/harvest-queue/*/auto-attempted-batch || true
  } | cksum | tr -d ' \t')
  ckey="" cat_e=0
  [ ! -f "$HCACHE/key" ] || read -r ckey cat_e <"$HCACHE/key" || true
  case "$cat_e" in ''|*[!0-9]*) cat_e=0 ;; esac
  hit=1
  for p in $PARTS; do [ -f "$HCACHE/$p.json" ] || hit=0; done
  if [ "$hit" = 1 ] && [ -n "$ckey" ] && [ "$ckey" = "$hkey" ] && [ "$now_e" -ge "$cat_e" ] && [ $((now_e - cat_e)) -lt "$CACHE_SECS" ]; then
    finish "$HCACHE"
    exit 0
  fi
fi

# 1) 무인 실행(harvest·sync): 로그 경로로 started/finished 짝을 맞춘다.
runs="$DATA/harvest-auto/runs.jsonl"
if [ -f "$runs" ]; then
  jq -c 'fromjson? // empty' -R "$runs" | jq -cs --arg since "$since" --argjson now "$now_e" --argjson stale "$STALE_HOURS" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def kind: if .scope == "sync" then "sync" elif .scope == "global" then "harvest-global" else "harvest" end;
    def failed: .event == "finished" and (.result == "failed" or ((.exit_code // 0) != 0));
    def rkey: .reason // "exit_\(.exit_code // "?")";
    def human_reason:
      if .exit_code == 143 then (if .duration_s != null then "\((.duration_s / 60) | round)분 시간 제한으로 중단됨" else "시간 제한으로 중단됨" end)
      elif .exit_code == 137 then "강제 종료됨"
      elif .reason == "usage_limit" then "사용량 한도에 닿음"
      elif .reason == "auth_expired" then "로그인 만료"
      elif .reason != null then "에이전트 오류 (\(.reason))"
      elif .exit_code == 70 then "작업 worktree를 만들지 못함"
      elif .exit_code == 71 then "동기화 계획을 세우지 못함"
      else "exit \(.exit_code // "?")" end;
    (map(select(.event == "started" and .log != null and .repo != null) | {(.log): .repo}) | add // {}) as $repos
    | (map(select(.event == "finished" or .event == "failed")) | group_by([.project, (.scope // "")])
       | map({key: "\(.[0].project)|\(.[0].scope // "")", value: (sort_by(.at) | reverse)}) | from_entries) as $byg
    | (map(select(.event == "finished" or .event == "failed")) | group_by([.project, .scope]) | map(max_by(.at)) | map(.log)) as $latest
    | (map(select(.event == "finished" or .event == "failed") | .log)) as $closed
    | [ .[] |
        if .event == "started" and ((.log as $l | $closed | index($l)) | not) then
          (if ($now - (.at | epoch)) > ($stale * 3600) then "blocked" else "running" end) as $st
          | {kind: kind, project, state: $st, at,
             title: (if $st == "running" then "실행 중 (\(.agent // "agent"))" else "시작 후 \($stale)시간 넘게 끝나지 않음" end),
             detail: (if $st == "blocked" then "worker가 멈췄거나 lock을 쥐고 있을 수 있음" else null end),
             link: null, log: .log, cmd: null}
        elif .event == "failed" and (.log as $l | $latest | index($l)) then
          {kind: kind, project, state: "needs_human", at, title: "실행 실패 (\(.reason // "exit \(.exit_code // "?")"))",
           detail: null, link: null, log: .log, cmd: null}
        elif .event == "finished" and .result == "no-change" then empty
        elif failed and ((.log as $l | $latest | index($l)) | not) then empty
        elif failed and .at >= $since then
          rkey as $k | $byg["\(.project)|\(.scope // "")"] as $g
          | ($g | map(failed and rkey == $k) | index(false) // length) as $streak
          | human_reason as $why
          | {kind: kind, project, state: "needs_human", at,
             title: ("실행 실패 (\($why))" + (if $streak >= 2 then " · \($streak)번 연속" else "" end)),
             detail: null, fail_reason: $why, reason_key: $k, streak: $streak, exit_code: (.exit_code // null),
             link: .artifact, log: .log, cost: .cost_usd, duration_s: .duration_s, result: .result, cmd: null}
        elif .event == "finished" and .at >= $since then
          (.log as $l | $latest | index($l)) as $is_latest
          | (if ($is_latest and (.result == "left_for_user" or .result == "partial" or (.artifact != null and .result == "improved"))) then "needs_human" else "done" end) as $st
          | {kind: kind, project, state: $st, at,
             title: (if $st == "done" and .artifact != null then "PR 생성 (\(.result))"
                     elif $st == "done" and .result == "left_for_user" then "적용 못 함 (이후 실행으로 대체)"
                     else ({"left_for_user": "사람 확인 필요 — 적용 못 함", "partial": "일부 적용 — draft PR 검토", "improved": "개선 — draft PR 검토", "no-change": "변경 없음"}[.result] // .result) end),
             detail: null, link: .artifact, log: .log,
             cost: .cost_usd, duration_s: .duration_s, result: .result,
             cmd: (if .result == "left_for_user" and .scope == "sync" then "/ai-harness:harness-init --sync --apply" else null end)}
        else empty end ] | map(. + {repo: ($repos[.log // ""] // null)})' > "$tmp/runs.json"

  # 로그가 없거나 비었으면 log는 null(실패 카드는 이유를 단다). 사람 필요·실패 항목에는 로그의 마지막 보고를 붙이고,
  # 보고(result)가 없으면 끊기기 전 마지막 진행 줄을 붙인다.
  jq -c '.[]' "$tmp/runs.json" | while IFS= read -r item; do
    log=$(jq -r '.log // empty' <<<"$item")
    if [ -n "$log" ] && [ ! -s "$log" ] && [ "$(jq -r '.state' <<<"$item")" != running ]; then
      item=$(jq -c '.log = null' <<<"$item")
      log=""
    fi
    # 이전 버전은 로그인 만료를 agent_error로 남겼다 — 로그가 인증 실패면 같은 원인으로 묶이게 이유를 바로잡는다(#315).
    if [ -n "$log" ] && [ "$(jq -r '.reason_key // empty' <<<"$item")" = agent_error ] \
      && [ "$(jq -Rrn -L "$SCRIPTS_DIR" 'include "fail-reason"; log_fail_reason' "$log" 2>/dev/null)" = auth_expired ]; then
      item=$(jq -c '.reason_key = "auth_expired"' <<<"$item")
    fi
    if [ "$(jq -r '.state' <<<"$item")" = needs_human ]; then
      ex=$(result_excerpt "$log" || true)
      [ -n "$ex" ] || ex=$(last_progress "$log" || true)
      item=$(jq -c --arg ex "$ex" '.detail = (if $ex == "" then .detail else $ex end)' <<<"$item")
    fi
    if [ -z "$log" ]; then
      jq -c 'if .fail_reason != null then .log_note = "중간에 끊겨 로그가 남지 않았습니다" else . end' <<<"$item"
    else
      printf '%s\n' "$item"
    fi
  done | jq -s . > "$tmp/runs2.json"

  # 최근 24시간 변경 없이 끝난 실행은 카드 대신 종류별 횟수로만 센다.
  jq -c 'fromjson? // empty' -R "$runs" | jq -cs --argjson now "$now_e" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def kind: if .scope == "sync" then "sync" elif .scope == "global" then "harvest-global" else "harvest" end;
    [ .[] | select(.event == "finished" and .result == "no-change" and ($now - (.at | epoch)) < 86400) ]
    | group_by(kind) | map({kind: (.[0] | kind), count: length, last_at: (map(.at) | max)})' > "$tmp/quiet.json"

  # 최근 2일 skip 이유를 프로젝트별 1건으로 묶는다.
  jq -c 'fromjson? // empty' -R "$runs" | jq -cs --argjson now "$now_e" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    ({"daily_max": "하루 실행 상한 도달", "no_harness_repo": "하네스 저장소를 찾지 못함", "sessions_only": "세션 기록만 있고 저장소 없음",
      "sync_pr_status_unknown": "지난 동기화 PR 상태를 확인할 수 없어 멈춤", "sync_pr_no_credentials": "PR 호스트 자격증명이 없어 동기화를 멈춤","sync_pr_in_review": "지난 동기화 PR을 사람이 검토 중이라 기다림",
      "busy": "다른 무인 실행이 돌고 있어 미룸", "needs_claude": "claude CLI를 찾지 못함", "marker_unwritable": "진행 표시 파일을 쓸 수 없음",
      "gave_up": "같은 근거로 여러 번 실패해 멈춤", "runs_unreadable": "실행 기록을 읽지 못해 멈춤"}) as $why
    | [ .[] | select(.event == "skipped" and ($now - (.at | epoch)) < 172800) ]
    | group_by([.project, .reason])
    | map(max_by(.at) as $last | {kind: "schedule", project: $last.project, state: "blocked", at: $last.at,
        title: ($why[$last.reason] // "무인 실행을 건너뜀"), detail: "최근 2일 \(length)회 건너뜀", reason: $last.reason, link: null, log: null, cmd: null})' > "$tmp/skips.json"
else
  echo '[]' > "$tmp/runs2.json"; echo '[]' > "$tmp/skips.json"; echo '[]' > "$tmp/quiet.json"
fi

# 로그인 만료(#315): 저장소마다 같은 이유로 실패한 카드를 한 장으로 묶고 할 일을 제목에 쓴다.
# 그 뒤 끝까지 돈 실행이 하나라도 있으면(다시 로그인함) 묶음 카드도, 남은 저장소별 실패 카드도 내린다.
# 성공 판정(run_ok)은 세션 시작 안내(harvest-auto.sh notify)와 같은 정의를 쓴다(#326).
# 자동 수정 실행의 로그인 만료도 같은 카드에 넣는다 — 자동 수정만 쓰는 사용자도 카드를 받는다(#326).
# 이전 버전이 agent_error로 남긴 자동 수정 실패는 로그로 판정한다.
af_runs="$DATA/autofix/runs.jsonl"
[ -f "$af_runs" ] || af_runs=/dev/null
h_runs="$runs"
[ -f "$h_runs" ] || h_runs=/dev/null
last_ok=$(jq -Rrn -L "$SCRIPTS_DIR" 'include "fail-reason"; [inputs | fromjson? | objects | select(run_ok) | .at] | max // ""' \
  "$h_runs" "$af_runs" 2>/dev/null || true)
jq -Rcn --arg ok "$last_ok" --arg since "$since" '[inputs | fromjson? | objects
  | select(.event == "finished" and (.at // "") > $ok and (.at // "") >= $since and (.reason == "auth_expired" or .reason == "agent_error"))] | .[]' \
  "$af_runs" 2>/dev/null | while IFS= read -r row; do
  if [ "$(jq -r '.reason' <<<"$row")" = agent_error ]; then
    log=$(jq -r '.log // empty' <<<"$row")
    if [ -z "$log" ] || [ "$(jq -Rrn -L "$SCRIPTS_DIR" 'include "fail-reason"; log_fail_reason' "$log" 2>/dev/null)" != auth_expired ]; then
      continue
    fi
  fi
  jq -c '{kind: "autofix", project, at, log, reason_key: "auth_expired"}' <<<"$row"
done | jq -s . > "$tmp/af-auth.json"
jq --arg ok "$last_ok" --slurpfile af "$tmp/af-auth.json" '
  ([.[] | select(.reason_key == "auth_expired" and .at > $ok)] + $af[0]) as $live
  | [.[] | select(.reason_key != "auth_expired")]
    + (if ($live | length) == 0 then [] else [{
        kind: "schedule", project: "무인 실행", state: "needs_human", at: ($live | map(.at) | max),
        title: "로그인이 만료돼 무인 실행이 멈췄어요 — claude auth login 또는 claude setup-token",
        detail: ("터미널에서 claude auth login으로 다시 로그인하거나, 무인 실행용으로 claude setup-token을 실행한 뒤 CLAUDE_CODE_OAUTH_TOKEN을 설정하세요. 다음 무인 실행이 정상으로 돌면 이 카드는 사라집니다.\n멈춘 대상: "
          + ($live | map("\(.project)(\(.kind))") | unique | join(", "))),
        reason: "auth_expired", link: null, log: ($live | max_by(.at) | .log), cmd: "claude auth login", repo: null}] end)' \
  "$tmp/runs2.json" > "$tmp/runs3.json" && mv "$tmp/runs3.json" "$tmp/runs2.json"

# 2) 스케줄 회차: 마지막 회차가 skip이면 막힘으로.
sched="$DATA/logs/schedule.jsonl"
if [ -f "$sched" ]; then
  tail -n 1 "$sched" | jq -c '
    ({"never_idle": "열린 세션이 계속 활동 중이라 정기 실행의 LLM 단계(세션 정리·자동 개선·동기화)를 미뤘습니다.", "usage_limit": "사용량 한도에 닿아 쉬는 중입니다.", "running": "이전 실행이 아직 진행 중입니다."}) as $why
    | [ if .llm == "skipped" then
          {kind: "schedule", project: "스케줄", state: "blocked", at, title: "정기 실행 LLM 단계 건너뜀",
           detail: ($why[.reason] // .reason), link: null, log: null, cmd: null}
        else
          {kind: "schedule", project: "스케줄", state: "done", at, title: "정기 실행 완료", detail: "LLM 단계 \(.llm)", link: null, log: null, cmd: null}
        end ]' > "$tmp/sched.json"
else
  echo '[]' > "$tmp/sched.json"
fi

# 3) 워크플로 러너: state.json 상태로 판정. state.json에는 프로세스 기록(pid)이 없어, 실행 폴더에 최근
# RUNNER_STALE_MIN분 안에 바뀐 파일이 있는지로 살아 있는지 본다(노드 로그·progress.log가 도구 호출마다 쌓인다).
# running인데 그 사이 기록이 없거나, 러너가 중간에 끝낸 incomplete·stop으로 멈춘 stopped는 '중단됨'(stall)이고 resume으로 이어 간다.
# 결정 대기(needs_user_decision·await 노드·user_decision·waiting_approval)는 사람 필요지만, presented_at부터
# DECISION_STALE_DAYS일이 지나면 막힘(decision_stale)으로 내린다. 모르는 status는 '작업 중'이 아니라 막힘으로 둔다(#564).
RUNNER_STALE_MIN="${BOARD_RUNNER_STALE_MIN:-60}"
case "$RUNNER_STALE_MIN" in ''|*[!0-9]*) RUNNER_STALE_MIN=60 ;; esac
DECISION_STALE_DAYS="${BOARD_DECISION_STALE_DAYS:-7}"
case "$DECISION_STALE_DAYS" in ''|*[!0-9]*) DECISION_STALE_DAYS=7 ;; esac
: > "$tmp/runner.jsonl"
for s in "$DATA"/runs/*/*/state.json; do
  [ -f "$s" ] || continue
  quiet=false
  if [ "$(jq -r '.status // ""' "$s" 2>/dev/null)" = running ] \
    && [ -z "$(find "${s%/*}" -maxdepth 1 -type f -mmin "-$RUNNER_STALE_MIN" 2>/dev/null | head -n 1)" ]; then
    quiet=true
  fi
  # 작업 브랜치(#605): 기록이 없는 옛 상태 파일이고 끝나지도 도는 중도 아니면 저장소의 현재 브랜치를 쓴다. 보드가 그 브랜치의 PR로 판정한다.
  repo_branch=""
  IFS=$'\037' read -r st_status st_branch st_repo <<<"$(jq -r '[(.status // ""), (.branch // .publish.branch? // ""), (.repo // "")] | join("\u001f")' "$s" 2>/dev/null || true)"
  case "$st_status" in
    done|abandoned|fix_list) ;;
    *)
      if [ -z "$st_branch" ] && { [ "$st_status" != running ] || [ "$quiet" = true ]; } && [ -n "$st_repo" ] && [ -d "$st_repo" ]; then
        repo_branch="$(git -C "$st_repo" symbolic-ref --short -q HEAD 2>/dev/null || true)"
      fi
      ;;
  esac
  jq -c --arg since "$since" --arg path "$s" --argjson quiet "$quiet" --arg stale_min "$RUNNER_STALE_MIN" \
    --argjson now "$now_e" --argjson decision_days "$DECISION_STALE_DAYS" --arg repo_branch "$repo_branch" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    . as $st
    | (.branch // .publish.branch? // (if $repo_branch == "" then null else $repo_branch end)) as $branch
    | (.repo | split("/") | map(select(. != "")) | .[-1]) as $proj
    | ((.repo | capture("worktrees/(?<k>[A-Z]+-[0-9]+)/") | .k)? // null) as $issue
    | (.request // "" | split("\n")[0] | sub("^#+ *"; "")) as $title0
    | (if $issue != null and ($title0 | startswith($issue) | not) then "\($issue) \($title0)" else $title0 end) as $title
    | (.workflow // "feature") as $wf
    | if .status == "done" or .status == "abandoned" or .status == "fix_list" then
        if (.finished_at // .started_at) >= $since then
          {kind: "runner", project: $proj, cwd: .repo, state: "done", at: (.finished_at // .started_at), title: $title,
           detail: (if .status == "done" then "워크플로 완료 · 정책 \(.policy.git // "?")"
                    else "워크플로 끝남(\(.status)) · 노드 \(.node)" end),
           link: (.publish.pr_url? // null), log: $path, cmd: null}
        else empty end
      elif .status == "baseline_changed" then
        {kind: "runner", project: $proj, cwd: .repo, state: "needs_human", at: (.finished_at // .started_at), title: $title,
         detail: "멈춘 뒤 저장소가 바뀌어 이어 가지 않음: \(.message // .node)", link: (.publish.pr_url? // null), log: $path, cmd: null}
      elif .status == "invariant_violation" then
        {kind: "runner", project: $proj, cwd: .repo, state: "needs_human", at: (.finished_at // .started_at), title: $title,
         detail: "불변식 위반: \(.message // .node)", link: (.publish.pr_url? // null), log: $path, cmd: null}
      elif (.needs_user_decision // false) or (.node | tostring | test("^await"))
           or .status == "user_decision" or .status == "waiting_approval" then
        (.presented_at // .finished_at // .started_at) as $at
        | (try (($now - ($at | epoch)) / 86400 | floor) catch null) as $age
        | (if .status == "user_decision" then null else "workflow-driver.sh approve --run \(.run_id)" end) as $cmd
        | (if .status == "user_decision" then "결정 필요: \(.message // "노드 \(.node)")"
           else "노드 \(.node)에서 사람 결정을 기다림" end) as $why
        | if $age != null and $age >= $decision_days then
            {kind: "runner", project: $proj, cwd: .repo, state: "blocked", stall: "decision_stale", at: $at, title: $title,
             detail: "\($why) — \($age)일째 응답 없음", link: (.publish.pr_url? // null), log: $path, cmd: $cmd}
          else
            {kind: "runner", project: $proj, cwd: .repo, state: "needs_human", at: $at, title: $title,
             detail: $why, link: (.publish.pr_url? // null), log: $path, cmd: $cmd}
          end
      elif .status == "failed" then
        {kind: "runner", project: $proj, cwd: .repo, state: "needs_human", at: (.finished_at // .started_at), title: $title,
         detail: "실패: \(.message // .node)", link: (.publish.pr_url? // null), log: $path, cmd: null}
      elif .status == "incomplete" or .status == "stopped" or (.status == "running" and $quiet) then
        (if .status == "running" then "no_activity" else .status end) as $why
        | {kind: "runner", project: $proj, cwd: .repo, state: "blocked", stall: $why, at: (.finished_at // .started_at), title: $title,
           detail: (if $why == "incomplete" then "노드 \(.node)에서 중단됨: \(.message // "이유 기록 없음")"
                    elif $why == "stopped" then "노드 \(.node)에서 stop으로 멈춤"
                    else "노드 \(.node)에서 \($stale_min)분 넘게 기록이 없음 — 러너 프로세스가 끝난 것으로 보임" end),
           link: (.publish.pr_url? // null), log: $path, cmd: "workflow-driver.sh resume --workflow \($wf)"}
      elif .status == "running" then
        {kind: "runner", project: $proj, cwd: .repo, state: "running", at: .started_at, title: $title,
         detail: "현재 노드: \(.node)", link: (.publish.pr_url? // null), log: $path, cmd: null}
      else
        {kind: "runner", project: $proj, cwd: .repo, state: "blocked", at: (.finished_at // .started_at), title: $title,
         detail: "알 수 없는 상태: \(.status) (노드 \(.node))", link: (.publish.pr_url? // null), log: $path, cmd: null}
      end
    | . + {branch: $branch, workflow: $wf, release_tag: ($st.release.tag? // null)}' "$s" >> "$tmp/runner.jsonl" 2>/dev/null || true
done
jq -s . "$tmp/runner.jsonl" > "$tmp/runner.json"

# 4) 자동 적용된 규칙.
applied="$DATA/applied/applied.jsonl"
if [ -f "$applied" ]; then
  jq -c 'fromjson? // empty' -R "$applied" | jq -cs --arg since "$since" '
    [ .[] | select(.at >= $since and (.event == "applied" or .event == "reverted")) |
      {kind: "rule", project: (.scope // "?"), state: "done", at,
       title: (if .event == "applied" then "규칙 자동 적용: \(.id)" else "규칙 되돌림: \(.id)" end),
       detail: (.text // "" | .[0:200]), link: null, log: null, cmd: null} ]' > "$tmp/applied.json"
else
  echo '[]' > "$tmp/applied.json"
fi

# 5) harvest 대기: analysis batch가 쌓였지만 아직 돌지 않은 프로젝트. '지금 돌리기'는 이 항목에만 붙는다.
# 무인 실행(harvest-auto.sh)은 batch 옆에 시도 표시(auto-attempted-batch)를 남긴다. 같은 batch가 이미 하네스 없음·
# 세션 수만·포기·실행됨으로 끝났으면 다음 실행에서 돌지 않으므로 카드 대신 이유별 수(queue_hidden)로만 센다.
# 하네스 없음(no_harness)은 매 실행 다시 확인되지만, 그 폴더에 하네스가 생기기 전에는 돌지 않는다.
# 표시가 없거나 다른(이전) batch를 가리키거나 일시 실패(failed)면 다음 실행 대상이다. batch 파일은 건드리지 않는다.
: > "$tmp/queue.jsonl"
: > "$tmp/queue_hidden.jsonl"
for b in "$DATA"/harvest-queue/*/analysis-batch.json; do
  [ -f "$b" ] || continue
  m="${b%/*}/auto-attempted-batch"
  mark='{}'
  [ ! -f "$m" ] || mark=$(jq -c 'if type == "object" then . else {} end' "$m" 2>/dev/null || echo '{}')
  jq -c --argjson m "$mark" 'select(.has_analysis_batch != false and .project != null) |
    if ($m.batch_id != null and $m.batch_id == (.batch_id // .created_at)
        and ($m.result | IN("no_harness", "sessions_only", "gave_up", "launched"))) then
      {hidden: $m.result, project}
    else
      {kind: "harvest", project, state: "queued", at: (.created_at // null),
       title: "harvest 대기 (세션 \(.counts.sessions // "?")개)",
       detail: (if (.reasons // []) == [] then null else "근거: " + (.reasons | join(", ")) end),
       link: null, log: null, cmd: "/ai-harness:harvest"}
    end' "$b" 2>/dev/null || true
done | while IFS= read -r q; do
  case "$q" in
    '{"hidden":'*) printf '%s\n' "$q" >> "$tmp/queue_hidden.jsonl" ;;
    *) printf '%s\n' "$q" >> "$tmp/queue.jsonl" ;;
  esac
done
jq -s . "$tmp/queue.jsonl" > "$tmp/queue.json"
jq -s 'group_by(.hidden) | map({reason: .[0].hidden, count: length})' "$tmp/queue_hidden.jsonl" > "$tmp/queue_hidden.json"

# 입력 캐시를 쓴다(0700 폴더·0600 파일). 칸 파일을 먼저 바꾸고 키는 마지막에 — 키가 맞으면 칸도 그 키의 것이다.
if [ -n "$hkey" ] && mkdir -p "$HCACHE" 2>/dev/null && chmod 700 "$HCACHE" 2>/dev/null; then
  saved=1
  for p in $PARTS; do
    { cp "$tmp/$p.json" "$HCACHE/.$p.json.$$" && chmod 600 "$HCACHE/.$p.json.$$" && mv -f "$HCACHE/.$p.json.$$" "$HCACHE/$p.json"; } 2>/dev/null || saved=0
  done
  if [ "$saved" = 1 ]; then
    { printf '%s %s\n' "$hkey" "$now_e" >"$HCACHE/.key.$$" && chmod 600 "$HCACHE/.key.$$" && mv -f "$HCACHE/.key.$$" "$HCACHE/key"; } 2>/dev/null || true
  fi
fi

finish "$tmp"
