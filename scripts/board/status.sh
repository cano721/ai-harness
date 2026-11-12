#!/usr/bin/env bash
# Harness Board 상태: ~/.ai-harness 데이터와 작업 세션(work.sh)을 칸반 항목 JSON으로 바꾼다.
# 출력: {generated_at, window_days, quiet_runs:[{kind, count, last_at}], items:[{section, kind, project, state, at, title, detail, link, log, cmd, id, actions}]}
# state: queued | running | needs_human | blocked | done
set -euo pipefail

DATA="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}"
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
             detail: null, fail_reason: $why, streak: $streak, exit_code: (.exit_code // null),
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
      "sync_pr_status_unknown": "지난 동기화 PR 상태를 확인할 수 없어 멈춤", "sync_pr_in_review": "지난 동기화 PR을 사람이 검토 중이라 기다림",
      "busy": "다른 무인 실행이 돌고 있어 미룸", "needs_claude": "claude CLI를 찾지 못함", "marker_unwritable": "진행 표시 파일을 쓸 수 없음",
      "gave_up": "같은 근거로 여러 번 실패해 멈춤", "runs_unreadable": "실행 기록을 읽지 못해 멈춤"}) as $why
    | [ .[] | select(.event == "skipped" and ($now - (.at | epoch)) < 172800) ]
    | group_by([.project, .reason])
    | map(max_by(.at) as $last | {kind: "schedule", project: $last.project, state: "blocked", at: $last.at,
        title: ($why[$last.reason] // "무인 실행을 건너뜀"), detail: "최근 2일 \(length)회 건너뜀", reason: $last.reason, link: null, log: null, cmd: null})' > "$tmp/skips.json"
else
  echo '[]' > "$tmp/runs2.json"; echo '[]' > "$tmp/skips.json"; echo '[]' > "$tmp/quiet.json"
fi

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

# 3) 워크플로 러너: state.json 상태로 판정.
: > "$tmp/runner.jsonl"
for s in "$DATA"/runs/*/*/state.json; do
  [ -f "$s" ] || continue
  jq -c --arg since "$since" --arg path "$s" '
    (.repo | split("/") | map(select(. != "")) | .[-1]) as $proj
    | ((.repo | capture("worktrees/(?<k>[A-Z]+-[0-9]+)/") | .k)? // null) as $issue
    | (.request // "" | split("\n")[0] | sub("^#+ *"; "")) as $title0
    | (if $issue != null and ($title0 | startswith($issue) | not) then "\($issue) \($title0)" else $title0 end) as $title
    | if .status == "done" then
        if (.finished_at // .started_at) >= $since then
          {kind: "runner", project: $proj, cwd: .repo, state: "done", at: (.finished_at // .started_at), title: $title,
           detail: "워크플로 완료 · 정책 \(.policy.git // "?")", link: (.publish.pr_url? // null), log: $path, cmd: null}
        else empty end
      elif (.needs_user_decision // false) or (.node | tostring | test("^await")) then
        {kind: "runner", project: $proj, cwd: .repo, state: "needs_human", at: (.presented_at // .started_at), title: $title,
         detail: "노드 \(.node)에서 사람 결정을 기다림", link: null, log: $path,
         cmd: "workflow-driver.sh approve --run \(.run_id)"}
      elif .status == "failed" then
        {kind: "runner", project: $proj, cwd: .repo, state: "needs_human", at: (.finished_at // .started_at), title: $title,
         detail: "실패: \(.message // .node)", link: null, log: $path, cmd: null}
      else
        {kind: "runner", project: $proj, cwd: .repo, state: "running", at: .started_at, title: $title,
         detail: "현재 노드: \(.node)", link: null, log: $path, cmd: null}
      end' "$s" >> "$tmp/runner.jsonl" 2>/dev/null || true
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
: > "$tmp/queue.jsonl"
for b in "$DATA"/harvest-queue/*/analysis-batch.json; do
  [ -f "$b" ] || continue
  jq -c 'select(.has_analysis_batch != false and .project != null) |
    {kind: "harvest", project, state: "queued", at: (.created_at // null),
     title: "harvest 대기 (세션 \(.counts.sessions // "?")개)",
     detail: (if (.reasons // []) == [] then null else "근거: " + (.reasons | join(", ")) end),
     link: null, log: null, cmd: "/ai-harness:harvest"}' "$b" >> "$tmp/queue.jsonl" 2>/dev/null || true
done
jq -s . "$tmp/queue.jsonl" > "$tmp/queue.json"

bash "$(dirname "$0")/work.sh" > "$tmp/work.json" 2>/dev/null || echo '[]' > "$tmp/work.json"
jq -e 'type == "array"' "$tmp/work.json" >/dev/null 2>&1 || echo '[]' > "$tmp/work.json"

jq -s --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson days "$DAYS" --slurpfile work "$tmp/work.json" --slurpfile quiet "$tmp/quiet.json" \
  '{generated_at: $gen, window_days: $days, quiet_runs: $quiet[0], items: ((add | map(
     .section = (if .kind == "runner" then "work" else "harness" end)
     | .id = "\(.kind)|\(.project)|\(.at)"
     | .actions = ([ (select(.state == "queued" and (.kind | startswith("harvest"))) | "harvest_now"),
                     (select(.state == "needs_human" and .repo != null) | "open_agent") ])
     | .cause = (if .state == "needs_human" and ((.detail // "") | test("whitelist|화이트리스트|HTTP 403|원격에 접근할 수 없|PR 생성 사전 점검 실패|PR을 열 수 없")) then "remote_blocked" else null end)))
     + $work[0] | sort_by(.at // "") | reverse)}' \
  "$tmp/runs2.json" "$tmp/skips.json" "$tmp/sched.json" "$tmp/runner.json" "$tmp/applied.json" "$tmp/queue.json"
