#!/usr/bin/env bash
# 사람이 시킨 작업(에이전트 세션) 상태. 출처: Claude Code 공식 `claude agents --json --all` + 세션 transcript.
# 어느 터미널에서 띄운 세션이든 잡힌다. Orca는 필요 없다.
# 항목 state: needs_human(응답 대기·실패) | running(작업 중) | done(끝남·입력 가능, 최근 DONE_HOURS 이내)
set -uo pipefail
DONE_HOURS="${BOARD_DONE_HOURS:-48}"
PROJECTS="${HARNESS_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

command -v claude >/dev/null 2>&1 || { echo '[]'; exit 0; }
agents=$(claude agents --json --all 2>/dev/null) || { echo '[]'; exit 0; }
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$agents" || { echo '[]'; exit 0; }

now_ms=$(( $(date +%s) * 1000 ))
jq -c '.[]' <<<"$agents" | while IFS= read -r a; do
  sid=$(jq -r '.sessionId // empty' <<<"$a")
  [ -n "$sid" ] || continue
  t=""
  for f in "$PROJECTS"/*/"$sid".jsonl; do [ -f "$f" ] && t=$f && break; done
  summary='{}'
  titles='{}'
  if [ -n "$t" ]; then
    # Claude가 붙인 요약 제목(ai-title)과 사람이 바꾼 제목(custom-title, /rename)
    titles=$({ grep -hE '"type":"(ai-title|custom-title)"' "$t" || true; } | jq -cs '{ai: (map(select(.type == "ai-title") | .aiTitle) | last),
      custom: (map(select(.type == "custom-title") | .customTitle) | last)}' 2>/dev/null || echo '{}')
    # 긴 transcript는 끝부분만 본다. 사람 요청(tool_result 제외)과 마지막 답변, 마지막 기록 시각.
    summary=$(tail -n 600 "$t" | jq -cs '
      def text: if type == "string" then . else (map(select(.type? == "text") | .text) | join(" ")) end;
      (map(select(.type == "user" and ((.message.content | type) == "string" or (.message.content | any(.type? == "text")))
                  and (.isMeta != true)
                  and ((.message.content | text | sub("^\\s+"; "")) | test("^(<(command|local-command|system)|Base directory for this skill|Caveat:|<task-notification|This session is being continued|You have [0-9]+ new orchestration message|Another Claude session sent a message)") | not))) | last) as $u
      | (map(select(.type == "assistant" and (.message.content | any(.type? == "text")))) | last) as $r
      | {prompt: ($u.message.content | text? // null), reply: ($r.message.content | text? // null),
         # 사람이 마지막 답 뒤에 아직 말하지 않았을 때만 그 답의 끝부분을 싣는다 — 보드가 본문으로 묻는 질문을 찾는다(asks.py).
         reply_tail: (if $r and (($r.timestamp // "") > ($u.timestamp // "")) then ($r.message.content | text? // "" | .[-400:]) else null end),
         last: (map(.timestamp // empty) | max // null)}' 2>/dev/null || echo '{}')
  fi
  jq -c --argjson s "$summary" --argjson ti "$titles" --arg path "${t:-}" --argjson now "$now_ms" --argjson hours "$DONE_HOURS" '
    def clip($n): if . == null then null else gsub("\\s+"; " ") | if length > $n then .[0:$n] + "…" else . end end;
    (if .status == "waiting" then "needs_human"
     elif .status == "busy" then "running"
     elif .state == "failed" then "needs_human"
     else "done" end) as $st
    | (($s.last // null) // (if .startedAt then (.startedAt / 1000 | floor | todate) else null end)) as $at
    | select(.pid != null or ($at != null and ($now / 1000 - ($at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) < $hours * 3600))
    | {section: "work", kind: (if .kind == "background" then "bg" else "agent" end), state: $st,
       project: (.cwd // "?" | split("/") | map(select(. != "")) | .[-1]),
       at: $at,
       title: ($ti.custom // (if (.name // "" | test("-[0-9a-f]{2}$")) then $ti.ai else null end) // .name // $ti.ai // .sessionId[0:8]),
       term: .name,
       detail: ((if .status == "waiting" then "에이전트가 응답·권한을 기다림\n"
                 elif .state == "failed" then "백그라운드 세션이 실패함\n"
                 elif .pid == null then "세션 종료됨\n" else "" end)
                + (if $s.prompt then "요청: " + ($s.prompt | clip(140)) else "" end)
                + (if $s.reply then "\n— " + ($s.reply | clip(220)) else "" end)),
       reply_tail: ($s.reply_tail // null),
       agent: "claude", sid: .sessionId, short_id: (.id // .sessionId[0:8]), pid, cwd,
       transcript: (if $path == "" then null else $path end),
       live: (.pid != null), status: .status, bg_state: .state,
       link: null, log: null, cmd: (if .kind == "background" then "claude attach \(.id // .sessionId[0:8])" else null end),
       id: "claude|\(.sessionId)"}
    | .actions = ((if .transcript then ["view"] else [] end)
                  + (if .kind == "bg" and (.status == "idle" or .status == "waiting" or .pid == null) then ["send"] else [] end))' <<<"$a"
done | jq -s .
