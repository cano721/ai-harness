#!/usr/bin/env bash
# feature-delivery-graph.json을 실행하는 그래프 러너. 모델이 아니라 이 스크립트가 전이를 정한다.
#   - 노드: 그래프의 nodes. write:false 노드는 읽기 전용 세션(Codex sandbox read-only, Claude는 읽기 도구만)으로 띄우고
#     세션 전후 작업 트리 지문이 다르면 멈춘다. actor:human 노드에서는 실행을 멈추고(interrupt) 사람을 기다린다.
#   - 엣지: 노드가 낸 결과(outcome)와 같은 when을 가진 전이만 따른다. 그래프에 없는 전이는 불변식 위반이다.
#   - 상태: 노드마다 state.json에 체크포인트를 남겨 resume이 멈춘 노드부터 이어 간다.
#   - 승인: 사용자가 대화에 직접 입력한 "승인"(Claude·Codex 트랜스크립트의 사용자 메시지) 또는 터미널의 approve.
#     모델이 쓰는 도구 출력·자기 메시지는 사용자 메시지가 아니므로 승인이 되지 않는다.
#     .ai-harness/harness.json의 approval이 auto면 Brief가 열린 질문 대신 decisions(추천안과 근거)를 내고, 사람만 정할 수 있는 것
#     (needs_human)이 비어 있을 때 그래프의 auto_approved_by_policy 엣지로 통과한다. decisions는 brief.md와 PR 본문에 남는다.
#   - 검증: Brief에 담겨 함께 승인된 검증 명령을 이 스크립트가 직접 실행해 종료 코드로 판정한다.
#   - git: harness.json의 git_policy가 pr-only·direct면 deliver·repair 뒤 로컬 체크포인트 커밋을 남기고, publish 노드가
#     커밋·일반 push·PR을 맡는다. 그 밖의 값이면 커밋하지 않는다. publish 밖에서 이 스크립트가 아닌 누군가 HEAD를 움직이면 멈춘다.
#   - 원격 CI: push했으면 remote_ci 노드가 그 커밋의 원격 CI가 끝날 때까지 본다. 실패는 repair로 돌아가 다시 push하고,
#     볼 수단이 없으면 done이 아니라 사람에게 미확인으로 넘긴다. 로컬에서 같은 명령이 통과해도 원격 CI를 대신하지 못한다.
#   - 화면 검증: Brief가 ui_scenarios를 내면 review 뒤 ui_review 노드가 ui-review 계약대로 화면을 실제로 렌더링·조작한다.
#     주요 문제는 repair로 돌아가 다시 review·ui_review를 거치고, 검증하지 못하면 done이 아니라 사람에게 미검증으로 넘긴다.
# shellcheck disable=SC2016  # state_set·jq 인자의 $x는 셸이 아니라 jq 변수다
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: implement-feature-driver.sh <command> [options]

  start   --request "<기능>" | --request-file <file>   discover → brief를 실행하고 승인 대기에서 멈춘다
          [--check "<검증 명령>"]...                    Brief가 제안한 검증에 더할 명령
  revise  --feedback "<바꿀 점>"                         승인 대기 중인 Brief를 피드백으로 다시 만든다
  resume                                                승인을 확인하고 멈춘 노드부터 이어 간다
  approve                                               터미널에서 사람이 Brief를 보고 승인한 뒤 이어 간다
  status                                                현재 노드·이력·다음 행동을 보인다
  watch                                                 실행의 노드 전환·도구 호출을 따라 본다. 호출 때의 최근 실행을 계속 보고, 끝나도 대기한다 (Ctrl+C)

  공통: [--run <id>] (기본: 이 저장소의 최근 실행) [--repo <dir>] [--runtime codex|claude]

  정책: .ai-harness/harness.json의 approval(human|auto, 기본 human)과 git_policy(pr-only|direct|그 밖)를 start 때 읽는다.

exit: 0 done(push했으면 원격 CI 통과까지) · 10 승인 대기 · 20 사람 판단 필요(원격 CI·화면 미검증 포함) · 30 미완료(원격 CI 진행 중이면 resume) · 40 불변식 위반 · 2 사용법
EOF
  exit 2
}

CMD="${1:-}"
[[ -n "$CMD" ]] || usage
shift
REPO="."
RUN_ID=""
RUNTIME=""
REQUEST=""
FEEDBACK=""
CLI_CHECKS=()
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || usage; REPO="$2"; shift 2 ;;
    --run) [[ $# -ge 2 ]] || usage; RUN_ID="$2"; shift 2 ;;
    --runtime) [[ $# -ge 2 ]] || usage; RUNTIME="$2"; shift 2 ;;
    --request) [[ $# -ge 2 ]] || usage; REQUEST="$2"; shift 2 ;;
    --request-file) [[ $# -ge 2 && -f "$2" ]] || usage; REQUEST="$(<"$2")"; shift 2 ;;
    --feedback) [[ $# -ge 2 ]] || usage; FEEDBACK="$2"; shift 2 ;;
    --check) [[ $# -ge 2 ]] || usage; CLI_CHECKS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage ;;
  esac
done

command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 2; }
REPO="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || { printf 'not a git repository: %s\n' "$REPO" >&2; exit 2; }

GRAPH="$REPO/.ai-harness/workflows/feature-delivery-graph.json"
[[ -f "$GRAPH" ]] || GRAPH="$SCRIPT_DIR/feature-delivery-graph.json"
jq -e '.entry and .nodes and .transitions and .terminals' "$GRAPH" >/dev/null 2>&1 || { printf 'invalid graph: %s\n' "$GRAPH" >&2; exit 2; }
MAX_REPAIR="$(jq -r '.limits.max_repair_attempts // 10' "$GRAPH")"
# 수리 한도·제품 판단으로 사람에게 넘기는 엣지. 이름은 그래프가 정한다.
ESCALATE="$(jq -r 'first(.transitions[] | select(.from == "repair" and .to == "user_decision") | .when) // empty' "$GRAPH")"

# 실행 상태는 저장소 밖에 둔다. 저장소 안에 쓰면 읽기 전용 노드의 지문 비교가 무의미해진다.
RUNS_DIR="${HM_FEATURE_RUNS_DIR:-$HOME/.ai-harness/runs}/$(basename "$REPO")-$(printf '%s' "$REPO" | git hash-object --stdin | cut -c1-8)"
# 프롬프트·세션 로그에 코드가 담긴다. 실행 디렉토리는 본인만 읽는다.
mkdir -p "$RUNS_DIR"
chmod 700 "$RUNS_DIR" 2>/dev/null || true

# 진행 줄은 stderr와 $RUN/progress.log에 함께 남긴다. watch와 백그라운드 실행의 모니터가 이 파일을 따라 읽는다.
log() {
  printf '[implement-feature] %s\n' "$*" >&2
  [[ -n "${RUN:-}" && -d "$RUN" ]] && printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$RUN/progress.log"
  return 0
}

if [[ "$CMD" == start ]]; then
  [[ -n "$REQUEST" ]] || usage
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
elif [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(cat "$RUNS_DIR/latest" 2>/dev/null)" || { printf 'no run for %s; use start\n' "$REPO" >&2; exit 2; }
fi
RUN="$RUNS_DIR/$RUN_ID"
STATE="$RUN/state.json"

state() { jq -r "$1" "$STATE"; }
state_set() { # jq-filter [jq args...]
  local filter="$1"
  shift
  jq "$@" "$filter" "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

finish() { # status exit_code message
  state_set '.status = $s | .message = $m | .finished_at = $t' --arg s "$1" --arg m "$3" --arg t "$(now_utc)"
  log "$1: $3"
  log "run: $RUN_ID ($RUN)"
  exit "$2"
}

# 추적 파일 diff + 미추적 파일 내용까지 포함한 작업 트리 지문. .gitignore 대상(빌드 산출물)은 제외된다.
fingerprint() {
  {
    git -C "$REPO" rev-parse HEAD 2>/dev/null || true
    git -C "$REPO" diff HEAD --binary 2>/dev/null || true
    git -C "$REPO" ls-files --others --exclude-standard -z \
      | while IFS= read -r -d '' f; do printf '%s\0' "$f"; git -C "$REPO" hash-object -- "$f"; done
  } | git hash-object --stdin
}

guard_head() {
  local head
  head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf 'none')"
  [[ "$head" == "$(state '.head // .start_head')" ]] || finish invariant_violation 40 "HEAD moved during $1; only the driver's checkpoints and the publish node may commit"
}

# 화면을 그리는 파일(템플릿·스타일·컴포넌트)이 바뀌었는지. Brief가 화면 변경을 놓쳐도 화면 검증을 건너뛰지 않게 하는 결정적 백스톱이다.
ui_files_changed() {
  { git -C "$REPO" diff --name-only "$(state .start_head)"; git -C "$REPO" ls-files --others --exclude-standard; } \
    | grep -E '\.(html?|jinja2?|j2|jsp|erb|haml|hbs|mustache|njk|twig|ftl|ejs|pug|cshtml|razor|blade\.php|vue|svelte|astro|tsx|jsx|svg|css|scss|sass|less)$' \
    | grep -vE '(^|/)(__tests__|tests?|spec)/|\.(test|spec)\.' | sort -u || true
}

has_edge() { # from outcome
  jq -e --arg f "$1" --arg o "$2" 'any(.transitions[]; .from == $f and (.when // "") == $o)' "$GRAPH" >/dev/null
}

# 작업 트리 전체(미추적 포함, .gitignore 제외)를 트리 객체로. 리뷰한 내용과 publish가 커밋한 내용을 비교한다.
worktree_tree() {
  local idx="$RUN/tree.index"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$REPO" read-tree HEAD 2>/dev/null || true
  GIT_INDEX_FILE="$idx" git -C "$REPO" add -A
  GIT_INDEX_FILE="$idx" git -C "$REPO" write-tree
  rm -f "$idx"
}

# git_policy가 커밋을 허용하면 쓰기 노드 뒤 로컬 커밋을 남긴다. worktree가 사라져도 사이클 단위로 남는다. push는 하지 않는다.
checkpoint() { # node
  [[ "$(state '.policy.commits // false')" == true ]] || return 0
  [[ -n "$(git -C "$REPO" status --porcelain --untracked-files=all)" ]] || return 0
  { git -C "$REPO" add -A && git -C "$REPO" commit -q -m "wip(implement-feature): $1 · run $RUN_ID"; } >"$RUN/checkpoint.log" 2>&1 \
    || finish incomplete 30 "checkpoint commit after $1 failed; see $RUN/checkpoint.log. Fix the cause and run resume"
  state_set '.head = $h | .checkpoints += [$h]' --arg h "$(git -C "$REPO" rev-parse HEAD)"
  log "checkpoint commit after $1: $(git -C "$REPO" rev-parse --short HEAD)"
}

go() { # from outcome → 그래프에 선언된 전이만 따른다
  local from="$1" outcome="$2" to
  to="$(jq -r --arg f "$from" --arg o "$outcome" \
    'first(.transitions[] | select(.from == $f and ((.when // "") == $o)) | .to) // empty' "$GRAPH")"
  [[ -n "$to" ]] || finish invariant_violation 40 "graph declares no transition from '$from' on '${outcome:-<always>}'"
  state_set '.node = $to | .history += [{from:$f, outcome:$o, to:$to, at:$t}]' \
    --arg to "$to" --arg f "$from" --arg o "$outcome" --arg t "$(now_utc)"
  log "$from --${outcome:-next}--> $to"
}

# claude stream-json 이벤트에서 도구 호출 한 줄과 최종 result만 남긴다. 원본은 파일 내용이 담긴 도구 입출력이라 디스크에 쓰지 않는다.
# Bash는 명령 대신 description(없으면 앞의 VAR=값을 건너뛴 실행어 이름)만 보인다. 명령 인자·환경 대입에 토큰이 들어갈 수 있다.
# Write·Edit 본문, Agent 프롬프트는 보이지 않는다. Grep·Glob은 검색어를 60자까지 보인다.
stream_progress() { # label → stdout: result 이벤트 한 줄
  local label="$1" kind line
  jq --unbuffered -rR --arg repo "$REPO/" 'fromjson? |
    if .type == "assistant" then
      .message.content[]? | select(.type == "tool_use") | .input as $in
      | "P\t" + .name + (
          if .name == "Bash" then ": " + ($in.description // ($in.command // "" | [scan("\\S+")]
            | map(select(test("^[A-Za-z_][A-Za-z0-9_]*=") | not)) | .[0] // "" | split("/") | last))
          elif .name == "Grep" or .name == "Glob" then
            " " + ($in.pattern // "" | tostring | .[:60]) + (($in.path // "" | tostring | ltrimstr($repo)) as $p | if $p == "" then "" else " in " + $p end)
          else ($in.file_path // $in.path // $in.description // "" | tostring | ltrimstr($repo)) as $a
            | if $a == "" then "" else " " + $a end
          end | gsub("[\t\n]"; " ") | .[:160])
    elif .type == "result" then "R\t" + tojson
    else empty end' |
  while IFS=$'\t' read -r kind line; do
    case "$kind" in
      P) log "$label · $line" ;;
      R) printf '%s\n' "$line" ;;
    esac
  done
}
# run_agent <node> <label> <prompt> [schema] → $RUN/<label>.out. 쓰기 권한은 그래프의 nodes.<node>.write가 정한다.
run_agent() {
  local node="$1" label="$2" prompt="$3" schema="${4:-}" rc=0 writable
  local out="$RUN/$label.out" network browser
  writable="$(jq -r --arg n "$node" '.nodes[$n].write' "$GRAPH")"
  # 화면 검증(browser)은 앱 서버를 띄우고 브라우저를 조종해야 하므로 네트워크 노드처럼 명령과 로컬 네트워크를 연다. 쓰기는 지문 비교가 막는다.
  browser="$(jq -r --arg n "$node" '.nodes[$n].browser // false' "$GRAPH")"
  network="$(jq -r --arg n "$node" '.nodes[$n].network // .nodes[$n].browser // false' "$GRAPH")"
  # 같은 label을 다시 쓰는 노드(publish 재실행·resume)가 이전 결과를 이번 결과로 읽지 않게 한다.
  rm -f "$out"
  printf '%s\n' "$prompt" >"$RUN/$label.prompt"
  log "$label ($([[ "$writable" == true ]] && echo write || echo read-only), $(state .runtime))"
  case "$(state .runtime)" in
    codex)
      # read-only sandbox는 네트워크를 열 수 없다. 네트워크가 필요한 읽기 노드(remote_ci)는 workspace-write로 띄우고 run_node의 지문 비교로 쓰기를 막는다.
      local args=(exec -C "$REPO" -s "$([[ "$writable" == true || "$network" == true ]] && echo workspace-write || echo read-only)" -o "$out")
      [[ -n "$schema" ]] && args+=(--output-schema "$schema")
      # push·PR·원격 CI 노드는 네트워크가 필요하다. workspace-write sandbox는 기본으로 네트워크를 막는다.
      [[ "$network" == true ]] && args+=(-c sandbox_workspace_write.network_access=true)
      # 화면 캡처는 저장소가 아니라 이 노드의 증거 디렉터리에 남긴다.
      [[ "$browser" == true ]] && args+=(--add-dir "$RUN/$label")
      # codex 출력은 원본(명령 출력·파일 내용)이다. 사람이 보는 터미널일 때만 함께 흘리고, 에이전트가 받는 stderr에는 넣지 않는다.
      if [[ -t 2 ]]; then
        codex "${args[@]}" - <"$RUN/$label.prompt" 2>&1 | tee "$RUN/$label.log" >&2 || rc=$?
      else
        codex "${args[@]}" - <"$RUN/$label.prompt" >"$RUN/$label.log" 2>&1 || rc=$?
      fi
      ;;
    claude)
      # --tools는 내장 도구만 제한한다. MCP 도구(IDE 파일 편집 등)는 --strict-mcp-config로 함께 끈다.
      # 쓰기 노드는 Agent로 프로젝트 페르소나에 위임할 수 있다.
      local args=(-p --strict-mcp-config --output-format stream-json --verbose)
      if [[ "$writable" == true ]]; then
        args+=(--tools "Read,Grep,Glob,Edit,Write,Bash,Agent" --permission-mode acceptEdits --allowedTools "Bash")
      elif [[ "$network" == true ]]; then
        # 원격 CI 조회는 gh·curl 같은 명령이 필요하다. 작업 트리를 바꾸면 run_node의 지문 비교가 멈춘다.
        args+=(--tools "Read,Grep,Glob,Bash" --permission-mode dontAsk --allowedTools "Bash")
      else
        args+=(--tools "Read,Grep,Glob" --permission-mode dontAsk)
      fi
      [[ -n "$schema" ]] && args+=(--json-schema "$(<"$schema")")
      [[ "$browser" == true ]] && args+=(--add-dir "$RUN/$label")
      (cd "$REPO" && claude "${args[@]}" <"$RUN/$label.prompt") 2>"$RUN/$label.log" | stream_progress "$label" >"$RUN/$label.json" || rc=$?
      if ((rc == 0)); then
        jq -r 'if .structured_output then (.structured_output | tojson) else (.result // empty) end' \
          "$RUN/$label.json" >"$out" 2>/dev/null || rc=1
      fi
      ;;
  esac
  ((rc == 0)) && [[ -s "$out" ]] || finish incomplete 30 "$label session failed (exit $rc); see $RUN/$label.log. Fix the cause and run resume"
}

run_node() { # node label prompt [schema]: 읽기 전용 노드는 지문으로, 쓰기 노드는 승인으로 지킨다
  local node="$1" before writable
  writable="$(jq -r --arg n "$node" '.nodes[$n].write' "$GRAPH")"
  if [[ "$writable" == true ]]; then
    [[ "$(state '.approval.brief_hash // ""')" == "$(state .brief_hash)" ]] \
      || finish invariant_violation 40 "write node '$node' reached without approval of the current brief"
    run_agent "$@"
  else
    before="$(fingerprint)"
    run_agent "$@"
    [[ "$(fingerprint)" == "$before" ]] \
      || finish invariant_violation 40 "read-only node '$node' changed the working tree: $(git -C "$REPO" status --porcelain | head -n 10 | paste -sd ';' -). Remove those changes before starting again"
  fi
  guard_head "$node"
}

run_checks() { # label → $RUN/<label>.checks.json, 하나라도 실패하면 1
  local label="$1" i=0 failed=0 cmd rc results="[]"
  while IFS= read -r cmd; do
    i=$((i + 1))
    rc=0
    (cd "$REPO" && bash -c "$cmd") >"$RUN/$label.check$i.log" 2>&1 </dev/null || rc=$?
    results="$(jq --arg cmd "$cmd" --argjson rc "$rc" --arg tail "$(tail -n 40 "$RUN/$label.check$i.log")" \
      '. + [{command:$cmd, exit:$rc, tail:$tail}]' <<<"$results")"
    if ((rc != 0)); then failed=1; log "check failed: $cmd (exit $rc)"; else log "check passed: $cmd"; fi
  done < <(state '.checks[]')
  printf '%s\n' "$results" >"$RUN/$label.checks.json"
  return "$failed"
}

check_findings() {
  jq -c '[.[] | select(.exit != 0) | "required check failed: \(.command) (exit \(.exit))\n\(.tail)"]' "$RUN/$1.checks.json"
}

print_brief() {
  printf '== Implementation Brief · run %s ==\n\n' "$RUN_ID"
  cat "$RUN/brief.md"
  printf '\n== 드라이버가 직접 실행할 검증 ==\n'
  state '.checks[] | "- " + .'
  jq -r 'if (.open_questions // [] | length) > 0 then "\n== 확인이 필요한 점 ==\n" + (.open_questions | map("- " + .) | join("\n")) else empty end' "$RUN/brief.json"
  jq -r 'if (.needs_human // [] | length) > 0 then "\n== 사람이 정할 점 ==\n" + (.needs_human | map("- " + .) | join("\n")) else empty end' "$RUN/brief.json"
  if [[ "${1:-}" == auto ]]; then
    # direct는 PR 없이 push까지 가므로 "병합 전에 뒤집는다"가 성립하지 않는다.
    if [[ "$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)" == direct ]]; then
      printf '\n== 정책 승인 (approval: auto) ==\nBrief와 결정 사항은 %s와 마지막 커밋 메시지에 남는다. git_policy direct라 PR 없이 push되므로, 결정을 뒤집으려면 이후 커밋으로 되돌린다.\n' "$RUN/brief.md"
    else
      printf '\n== 정책 승인 (approval: auto) ==\nBrief와 결정 사항은 %s에 남고 PR 본문에 들어간다. 사람은 병합 전에 PR에서 결정을 뒤집을 수 있다.\n' "$RUN/brief.md"
    fi
    return
  fi
  cat <<EOF

== 다음 ==
승인: 대화에 "승인"이라고 입력한 뒤 resume (터미널이면 approve)
수정: 바꿀 점을 말하면 revise --feedback "<바꿀 점>"으로 Brief를 다시 만든다
EOF
}

# 사용자가 직접 입력한 메시지만 본다: Claude는 type=user의 문자열 content(isMeta 제외), Codex는 event_msg user_message.
# 도구 결과·모델 메시지·드라이버가 띄운 세션의 프롬프트는 "승인"으로 시작하지 않으므로 걸리지 않는다.
transcript_approval() {
  local since="$1" marker="$RUN/brief.json" f cwd
  local re='^[[:space:]]*(승인|approve|approved)([[:space:][:punct:]]|$)'
  local claude_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" codex_root="${CODEX_HOME:-$HOME/.codex}/sessions"
  if [[ -d "$claude_root" ]]; then
    while IFS= read -r -d '' f; do
      jq -c --arg repo "$REPO" --arg since "$since" --arg re "$re" '
        select(.type == "user" and (.isMeta | not) and ((.message.content | type) == "string")
          and ((.cwd // "") as $c | $c == $repo or ($c | startswith($repo + "/")) or ("/private" + $c) == $repo)
          and ((.timestamp // "")[:19] > $since)
          and (.message.content | ascii_downcase | test($re)))
        | {source:"claude-transcript", at:.timestamp, text:(.message.content[:200])}' "$f" 2>/dev/null | head -n 1
    done < <(find "$claude_root" -name '*.jsonl' -newer "$marker" -print0 2>/dev/null)
  fi
  if [[ -d "$codex_root" ]]; then
    while IFS= read -r -d '' f; do
      cwd="$(jq -r 'select(.type == "session_meta") | .payload.cwd // empty' "$f" 2>/dev/null | head -n 1)"
      [[ "$cwd" == "$REPO" || "$cwd" == "$REPO"/* || "/private$cwd" == "$REPO" ]] || continue
      jq -c --arg since "$since" --arg re "$re" '
        select(.type == "event_msg" and .payload.type == "user_message"
          and ((.timestamp // "")[:19] > $since)
          and (.payload.message | ascii_downcase | test($re)))
        | {source:"codex-transcript", at:.timestamp, text:(.payload.message[:200])}' "$f" 2>/dev/null | head -n 1
    done < <(find "$codex_root" -name '*.jsonl' -newer "$marker" -print0 2>/dev/null)
  fi
}

record_approval() { # evidence-json
  state_set '.approval = ($e + {brief_hash: .brief_hash, recorded_at: $t})' --argjson e "$1" --arg t "$(now_utc)"
  log "approved by $(jq -r .source <<<"$1")"
}

# publish: git_policy가 허용할 때만 세션을 띄워 커밋·일반 push·PR을 맡기고, 결과를 이 스크립트가 git으로 확인한다.
publish() {
  local policy problems="[]" out pr_url
  policy="$(state '.policy.git // ""')"
  case "$policy" in
    pr-only|direct) ;;
    *)
      state_set '.publish = {skipped: $m}' --arg m "git_policy '${policy:-unset}' does not allow the agent to commit; changes are left uncommitted"
      go publish published_or_not_required
      return
      ;;
  esac
  [[ "$(state '.approval.brief_hash // ""')" == "$(state .brief_hash)" ]] \
    || finish invariant_violation 40 "write node 'publish' reached without approval of the current brief"
  run_agent publish publish "$CONTEXT

You are the publish node. The approved change below passed the checks the driver ran and a review with no blocking findings. git_policy in .ai-harness/harness.json is \"$policy\". Deliver it without asking anyone anything:
- Use the git conventions, base branch, and PR tool that AGENTS.md and the project workflow name (for example /bitbucket or gh). Reviewers, labels, and similar settings come from the project's default rules.
- Commit any remaining change. The driver's unpushed checkpoint commits (wip(implement-feature): ...) may be squashed or reworded into the project's commit convention; never rewrite $(state .start_head) or anything before it.
- pr-only: push the work branch with a normal push that sets its upstream, then open a pull request against the base branch. Put the approved brief and the checks below in the PR body. If a pull request for this branch is already open (a repair after remote CI failed), push to it and return its URL instead of opening another.
- direct: push the current branch with a normal push that sets its upstream; open a pull request only when the project workflow requires one.
- If the brief has a \"결정 사항\" section, the agent made those choices without asking a person. Copy it unchanged into a PR body section titled \"결정 사항\" so a person can overturn them before merging; when no PR is opened, put it in the body of the last commit message instead.
- Never merge, never force-push, never push to the base branch under pr-only, and do not change file contents: the committed tree must equal the reviewed one.
Return only JSON matching the schema; pr_url is empty when no PR was opened.

Checks the driver ran: $(state '.checks | join(" ; ")')

Approved brief:
$(<"$RUN/brief.md")" "$PUBLISH_SCHEMA"
  out="$RUN/publish.out"
  jq -e '(.pr_url | type) == "string" and (.branch | type) == "string"' "$out" >/dev/null 2>&1 \
    || problems="$(jq -c '. + ["publish output does not match the schema"]' <<<"$problems")"
  pr_url="$(jq -r '.pr_url // ""' "$out" 2>/dev/null || true)"
  # 세션의 보고가 아니라 git 상태로 판정한다.
  [[ -z "$(git -C "$REPO" status --porcelain --untracked-files=all)" ]] \
    || problems="$(jq -c '. + ["uncommitted changes remain after publish"]' <<<"$problems")"
  [[ "$(worktree_tree)" == "$(state '.reviewed_tree // ""')" ]] \
    || problems="$(jq -c '. + ["the committed tree differs from the reviewed tree"]' <<<"$problems")"
  if [[ "$(state .start_head)" != none ]] && ! git -C "$REPO" merge-base --is-ancestor "$(state .start_head)" HEAD 2>/dev/null; then
    problems="$(jq -c '. + ["history before the run was rewritten"]' <<<"$problems")"
  fi
  [[ "$(git -C "$REPO" rev-parse '@{upstream}' 2>/dev/null || true)" == "$(git -C "$REPO" rev-parse HEAD)" ]] \
    || problems="$(jq -c '. + ["HEAD is not pushed to its upstream"]' <<<"$problems")"
  [[ "$policy" != pr-only || -n "$pr_url" ]] \
    || problems="$(jq -c '. + ["git_policy pr-only requires a pull request, but pr_url is empty"]' <<<"$problems")"
  state_set '.head = $h | .publish = {pr_url: $u, branch: $b, problems: $p}' \
    --arg h "$(git -C "$REPO" rev-parse HEAD)" --arg u "$pr_url" \
    --arg b "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" --argjson p "$problems"
  if [[ "$problems" == "[]" ]]; then
    go publish published_or_not_required
  else
    state_set '.findings = $p' --argjson p "$problems"
    go publish publish_failed
  fi
}

# remote_ci: push한 커밋의 원격 CI가 끝날 때까지 본다. 로컬과 원격 환경(OS·DB·시각 정밀도)이 달라 로컬 통과가 원격 통과를 보장하지 않는다.
remote_ci() {
  local head branch pr_url label out status commit
  if [[ "$(state '.publish.skipped // ""')" != "" ]]; then
    state_set '.remote_ci = {status: "not_required", summary: "nothing was pushed"}'
    go remote_ci remote_ci_passed_or_not_required
    return
  fi
  head="$(git -C "$REPO" rev-parse HEAD)"
  branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  pr_url="$(state '.publish.pr_url // ""')"
  label="remote-ci-$(state .attempts)"
  run_node remote_ci "$label" "$CONTEXT

You are the remote_ci node. Do not edit any file, commit, or push. The publish node pushed commit $head on branch $branch${pr_url:+ (pull request $pr_url)}. Find out whether the remote CI for exactly that commit passed, without asking anyone anything:
- Use the PR or CI tool that AGENTS.md and the project workflow name (for example gh pr checks --watch, or the Bitbucket pipelines API through /bitbucket).
- Wait until every check or pipeline for the commit reaches a final state, polling about once a minute. A freshly pushed commit can take a few minutes before its checks appear.
- passed: every check finished successfully. failed: any check failed; put each failing check in failures with the decisive lines of its log, enough to repair it without rerunning CI. none: the repository defines no remote CI (no CI configuration in the repository and no checks reported after waiting). pending: checks are still running after about 60 minutes. unverified: you cannot read the CI result (no tool, no access); say why in summary.
- A local run of the CI commands is not a remote result. Never report passed from it.
Return only JSON matching the schema; commit is the SHA the result belongs to." "$REMOTE_CI_SCHEMA"
  out="$RUN/$label.out"
  jq -e '(.status | IN("passed", "failed", "none", "pending", "unverified")) and (.commit | type) == "string"
    and (.summary | type) == "string" and (.failures | type) == "array"' "$out" >/dev/null 2>&1 \
    || finish incomplete 30 "remote CI output does not match the schema ($out); run resume to check again"
  # 읽기 노드지만 네트워크·Bash가 있다. push한 브랜치가 원격에서 움직였으면(push·force push) 멈춘다.
  [[ "$(git -C "$REPO" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)" == "$head" ]] \
    || finish invariant_violation 40 "remote branch $branch moved during remote_ci; the node may only read CI"
  status="$(jq -r .status "$out")"
  commit="$(jq -r .commit "$out")"
  unverified_because() { # reason
    jq --arg r "$1" '.status = "unverified" | .summary = $r' "$out" >"$out.tmp" && mv "$out.tmp" "$out"
    status=unverified
  }
  # 세션의 보고가 push한 커밋의 것인지 확인한다. 이전 push의 결과는 이 커밋의 결과가 아니다.
  if [[ "$status" == passed || "$status" == failed || "$status" == none ]] && [[ ${#commit} -lt 7 || "$head" != "$commit"* ]]; then
    unverified_because "the CI result is for ${commit:-no commit}, not the pushed commit $head"
  fi
  # "원격 CI 없음"은 저장소에 CI 설정이 없을 때만 믿는다. 설정이 있는데 체크가 안 보이면 아직 등록 전이거나 볼 수단이 없는 것이다.
  if [[ "$status" == none && -n "$(git -C "$REPO" ls-files -- .github/workflows bitbucket-pipelines.yml .gitlab-ci.yml \
    Jenkinsfile .circleci azure-pipelines.yml .buildkite .drone.yml .travis.yml 2>/dev/null)" ]]; then
    unverified_because "the session reported no remote CI, but the repository has CI configuration"
  fi
  state_set '.remote_ci = ($r[0] + {head: $h, pr_url: $u, at: $t})' --slurpfile r "$out" --arg h "$head" --arg u "$pr_url" --arg t "$(now_utc)"
  case "$status" in
    passed|none) go remote_ci remote_ci_passed_or_not_required ;;
    failed)
      state_set '.findings = (.remote_ci | if (.failures | length) > 0 then .failures else [.summary] end | map("remote CI failed: " + .))
        | .needs_user_decision = false'
      go remote_ci remote_ci_failed
      ;;
    pending) finish incomplete 30 "remote CI for $head is still running${pr_url:+ ($pr_url)}; run resume to check again" ;;
    *)
      state_set '.findings = ["remote CI unverified: " + .remote_ci.summary]'
      go remote_ci remote_ci_unverified
      ;;
  esac
}

CONTEXT="Read AGENTS.md, .ai-harness/workflows/implement-feature.md, .ai-harness/workflows/feature-delivery-graph.json and the project docs they select before anything else."

BRIEF_SCHEMA="$RUN/brief-schema.json"
REVIEW_SCHEMA="$RUN/review-schema.json"
PUBLISH_SCHEMA="$RUN/publish-schema.json"
REMOTE_CI_SCHEMA="$RUN/remote-ci-schema.json"
UI_REVIEW_SCHEMA="$RUN/ui-review-schema.json"

execute() {
  local node brief blocking
  while :; do
    node="$(state .node)"
    if jq -e --arg n "$node" '.terminals | index($n)' "$GRAPH" >/dev/null; then
      case "$node" in
        done) finish "done" 0 "required checks passed (run by the driver) and no blocking findings remain$(state 'if (.publish.pr_url // "") != "" then "; PR: " + .publish.pr_url elif .publish.skipped then "; " + .publish.skipped else "" end')$(state 'if .remote_ci then (if .remote_ci.status != "not_required" then "; remote CI: " + .remote_ci.status + " — " + .remote_ci.summary else "" end)
          elif (.publish // {} | has("pr_url")) then "; remote CI: unverified — the project graph has no remote_ci node; sync the harness (/harness-init --sync)" else "" end')$(state 'if .ui_review then "; UI: verified — " + .ui_review.summary
          elif (.ui_scenarios // [] | length) > 0 then "; UI: unverified — the project graph has no ui_review node; sync the harness (/harness-init --sync)" else "" end')" ;;
        *) printf '%s\n' "$(state '.findings')" >"$RUN/unresolved.json"
           finish "$node" 20 "a person must decide$(state 'if .remote_ci.status == "unverified" then " (remote CI unverified: " + .remote_ci.summary + (if (.remote_ci.pr_url // "") != "" then "; PR: " + .remote_ci.pr_url else "" end) + ")" else "" end')$(state 'if .ui_review.status == "unverified" then " (implementation done, UI unverified: " + .ui_review.summary + "; evidence: " + .ui_review.evidence_dir + "; nothing was published — make verification possible, then start a new run or verify and publish by hand)" else "" end'); see $RUN/unresolved.json" ;;
      esac
    fi
    case "$node" in
      discover)
        run_node discover discover "$CONTEXT

You are the discover node of the feature-delivery graph. Do not edit any file.
Summarize the project contract that matters for the request below: relevant modules and files, conventions, the test policy, and the exact commands that verify a change (build, targeted tests, broad tests, lint).

Request:
$(state .request)"
        go discover ""
        ;;
      brief)
        run_node brief "brief-$(state '.history | length')" "$CONTEXT

You are the brief node of the feature-delivery graph. Do not edit any file.
Write an Implementation Brief in Markdown: scope, out of scope, observable acceptance cases, expected change areas, and verification.
Put the exact shell commands that must pass before the feature is done in checks. They run from the repository root with bash -c. Prefer targeted tests plus the project's required broad check.
If the change alters what users see or operate (markup, styles, server-rendered templates, user-facing text, or the behavior of buttons, links, disclosures, forms, and dialogs), put one entry per scenario in ui_scenarios: the user role, entry -> key action -> success check -> return, the states to see (default and collapsed, empty, error, permission), and the viewports and themes the project supports. Follow the analysis step of the project ui-review skill (.agents/skills/ui-review or .claude/skills/ui-review) when it exists. Leave ui_scenarios empty for changes users cannot see.
$(if [[ "$(state '.policy.approval // "human"')" == auto ]]; then cat <<'EOF'
approval is auto: no person reads this brief before delivery, so do not leave open questions. Wherever reasonable options diverge, choose the recommended one, write the brief to follow it, and record it in decisions as {question, choice, rationale}.
Put in needs_human only what a person alone can decide: a product judgment that changes the scope of the request; a hard-to-reverse choice such as deleting data, a migration, creating or dropping an index, or a deployment; a write to an external system. Leave needs_human empty otherwise. Any entry stops the run until a person approves.
EOF
else printf 'Put anything the person must decide in open_questions.\n'; fi)

Request:
$(state .request)

Project contract from the discover node:
$(cat "$RUN/discover.out")
$(if [[ "$(state '.feedback // ""')" != "" ]]; then printf '\nPrevious brief:\n%s\n\nRevise it with this feedback from the person:\n%s\n' "$(<"$RUN/brief.md")" "$(state .feedback)"; fi)" "$BRIEF_SCHEMA"
        brief="$RUN/brief-$(state '.history | length').out"
        # human은 open_questions, auto는 decisions·needs_human을 낸다. auto에서 예전 형식이 오면 승인 노드가 사람을 기다린다.
        jq -e '(.brief | type) == "string" and (.checks | type) == "array"
          and ((.open_questions | type) == "array"
            or ((.needs_human | type) == "array" and (.decisions | type) == "array"
              and all(.decisions[]; (.question | type) == "string" and (.choice | type) == "string" and (.rationale | type) == "string")))' \
          "$brief" >/dev/null 2>&1 || finish incomplete 30 "brief output does not match the schema ($brief)"
        cp "$brief" "$RUN/brief.json"
        jq -r '.brief + if (.decisions // [] | length) > 0
          then "\n\n## 결정 사항\n\n" + (.decisions | map("- \(.question) → \(.choice) — \(.rationale)") | join("\n")) else "" end
          + if (.ui_scenarios // [] | length) > 0
          then "\n\n## 화면 검증 시나리오\n\n" + (.ui_scenarios | map("- " + .) | join("\n")) else "" end' "$brief" >"$RUN/brief.md"
        # 승인 대상은 Brief 본문(결정 사항 포함)과 검증 명령 전체다. 둘 중 하나라도 바뀌면 이전 승인은 무효다.
        state_set '.checks = ([.cli_checks[], $b[0].checks[]] | map(select(length > 0)) | unique)
          | .ui_scenarios = ($b[0].ui_scenarios // [] | map(select(length > 0)))
          | .presented_at = $t | .feedback = null | .approval = null' --slurpfile b "$RUN/brief.json" --arg t "$(now_utc)"
        state_set '.brief_hash = $h' --arg h "$({ cat "$RUN/brief.md"; state '.checks[]'; } | git hash-object --stdin)"
        [[ "$(state '.checks | length')" -gt 0 ]] \
          || finish incomplete 30 "the brief has no verification command; revise with a check or start again with --check"
        go brief ""
        ;;
      approval)
        if [[ "$(state '.approval.brief_hash // ""')" != "$(state .brief_hash)" && "$(state '.policy.approval // "human"')" == auto ]]; then
          # auto는 사람 대신 정책이 승인한다. 사람만 정할 것이 있거나, 결정을 남기지 않은 예전 형식이거나, 그래프가 auto 엣지를 지웠으면 사람을 기다린다.
          if [[ "$(jq '.needs_human // [] | length' "$RUN/brief.json")" -gt 0 ]]; then
            log "approval is auto, but the brief lists decisions only a person can make; waiting for a person"
          elif ! jq -e '(.decisions | type) == "array" and (.open_questions // [] | length) == 0' "$RUN/brief.json" >/dev/null; then
            log "approval is auto, but the brief left open questions instead of recording decisions; waiting for a person"
          elif ! has_edge approval auto_approved_by_policy; then
            log "approval is auto, but the graph declares no auto_approved_by_policy edge; waiting for a person"
          else
            print_brief auto >&2
            record_approval "$(jq -n --arg t "$(now_utc)" --arg b "$RUN/brief.md" '{source:"auto-policy", at:$t, brief:$b}')"
            go approval auto_approved_by_policy
            continue
          fi
        fi
        if [[ "$(state '.approval.brief_hash // ""')" != "$(state .brief_hash)" ]]; then
          local evidence
          evidence="$(transcript_approval "$(state .presented_at | cut -c1-19)" | head -n 1)"
          [[ -n "$evidence" ]] && record_approval "$evidence"
        fi
        if [[ "$(state '.approval.brief_hash // ""')" == "$(state .brief_hash)" ]]; then
          go approval user_explicitly_approved
        else
          state_set '.status = "waiting_approval"'
          print_brief
          log "waiting for approval: run $RUN_ID"
          exit 10
        fi
        ;;
      deliver)
        local before
        before="$(fingerprint)"
        run_node deliver deliver "$CONTEXT

You are the deliver node. Implement the approved Implementation Brief below in this repository. Follow the project workflow and test policy (Red -> Green -> Refactor only when TDD is required), delegating to the project's role agents when the workflow says so.
Do not commit, push, create a PR, or change scope. After you finish, the driver itself runs these checks: $(state '.checks | join(" ; ")')
Return a concise summary of changed areas and the commands you ran.

Approved Implementation Brief:
$(<"$RUN/brief.md")"
        [[ "$(fingerprint)" != "$before" ]] || finish incomplete 30 "deliver changed nothing; an approved feature cannot be done without a change"
        checkpoint deliver
        go deliver ""
        ;;
      review)
        if ! run_checks "review-$(state .attempts)"; then
          blocking="$(check_findings "review-$(state .attempts)")"
          state_set '.findings = $f | .needs_user_decision = false' --argjson f "$blocking"
        else
          run_node review "review-$(state .attempts)" "$CONTEXT

You are the review node. Do not edit any file. Review every change since $(state .start_head) (git diff $(state .start_head), which includes the driver's checkpoint commits, and untracked files) against the approved brief. The driver already ran the required checks and they passed.
A blocking finding is incorrect or missing behavior, a regression, security or data risk, or a material scope violation. Everything else is non-blocking.
Set needs_user_decision to true only when a blocking finding needs a product or scope decision from a person.
Return only JSON matching the schema.

Approved Implementation Brief:
$(<"$RUN/brief.md")" "$REVIEW_SCHEMA"
          local review_out
          review_out="$RUN/review-$(state .attempts).out"
          jq -e '(.blocking_findings | type) == "array" and (.needs_user_decision | type) == "boolean"' "$review_out" >/dev/null 2>&1 \
            || finish incomplete 30 "review output does not match the schema; the feature is not done ($review_out)"
          state_set '.findings = $r[0].blocking_findings | .needs_user_decision = $r[0].needs_user_decision' --slurpfile r "$review_out"
        fi
        local ui_files
        ui_files="$(ui_files_changed)"
        if [[ "$(state '.findings | length')" -eq 0 && "$(state '.ui_scenarios // [] | length')" -eq 0 && -n "$ui_files" ]]; then
          log "the brief listed no UI scenarios, but screen files changed; verifying them anyway"
          state_set '.ui_scenarios = ($f | split("\n") | map(select(length > 0)
            | "Screen rendered by \(.): open the page that uses it; derive the user role, entry -> key action -> success check -> return, and the states from the approved brief"))' --arg f "$ui_files"
        fi
        if [[ "$(state '.findings | length')" -gt 0 ]]; then
          go review blocking_findings
        elif [[ "$(state '.ui_scenarios // [] | length')" -gt 0 ]]; then
          # 화면 검증 노드가 없는 그래프(동기화 전)로는 화면을 검증할 수 없다. 구현은 끝났어도 done이 아니다.
          if ! has_edge review no_blocking_findings_ui_affected; then
            local legacy="implementation done, UI unverified: the project graph has no ui_review node, so the screens were not verified; nothing was published. Sync the harness (/harness-init --sync), then start a new run or verify the screens and publish by hand"
            jq -n --arg m "$legacy" '[$m]' >"$RUN/unresolved.json"
            state_set '.node = "user_decision"'
            finish user_decision 20 "$legacy"
          fi
          go review no_blocking_findings_ui_affected
        else
          state_set '.reviewed_tree = $t' --arg t "$(worktree_tree)"
          go review no_blocking_findings
        fi
        ;;
      ui_review)
        local ui_label ui_out evidence
        ui_label="ui-review-$(state .attempts)"
        evidence="$RUN/$ui_label"
        # resume이 같은 시도를 다시 돌 때 이전 캡처가 이번 근거로 섞이지 않게 한다.
        rm -rf "${RUN:?}/$ui_label"
        mkdir -p "$evidence"
        run_node ui_review "$ui_label" "$CONTEXT

You are the ui_review node. Do not edit, create, or delete any file in the repository. Follow the project ui-review skill (.agents/skills/ui-review/SKILL.md or .claude/skills/ui-review/SKILL.md, with its references/checklist.md) and .ai-harness/docs/ui.md when they exist; project design documents, semantic tokens, shared components, and reference screens come first.
The driver already ran the required checks and a code review found no blocking findings. You review the rendered screens, not the code: start the app as the project documents say, open every scenario below in a real browser, and operate it as a first-time user with mouse, keyboard, and a mobile-width viewport, in each supported theme. Look at the default and collapsed states before hovering or focusing anything.
Save captures and notes only under $evidence. Run the app with the local or test configuration the project documents, never production credentials, and point anything it writes (database files, uploads, logs, browser profiles) at $evidence or a temporary directory: a new file in the repository stops the run. Stop any server you started before you finish.
If the change added or changed a design-system example or reference screen, open and operate that example too.
These are not evidence of a usable screen: a test that found and clicked an element by its text, a shared class or token in the markup, an attribute such as data-theme or aria-expanded being set, a screenshot file existing, or an earlier claim that something was fixed.
Report one scenarios entry per scenario, viewport, and theme you actually rendered and operated, with the URL you opened and the capture files you saved under $evidence.
status: verified when you rendered and operated every scenario, found no blocking UI issue, and have nothing in unverified; issues when there is at least one; unverified when you could not start the app, could not use a browser, or could not check any required scenario, viewport, or theme. A blocking UI issue means a user cannot find or misreads a key action, an action's name does not match its result, a required input or an error cannot be recovered from, a scenario cannot be finished with a keyboard or in a supported viewport or theme, a shared component exists for the role but a one-off was built, or a hard-to-reverse action has no confirmation.
Return only JSON matching the schema.

UI scenarios:
$(state '.ui_scenarios | map("- " + .) | join("\n")')

Approved Implementation Brief:
$(<"$RUN/brief.md")" "$UI_REVIEW_SCHEMA"
        ui_out="$RUN/$ui_label.out"
        jq -e '(.status | IN("verified", "issues", "unverified")) and (.blocking_findings | type) == "array" and (.unverified | type) == "array"' "$ui_out" >/dev/null 2>&1 \
          || finish incomplete 30 "ui_review output does not match the schema; the feature is not done ($ui_out)"
        state_set '.ui_review = ($r[0] | {status, summary, unverified, evidence_dir: $e})' --slurpfile r "$ui_out" --arg e "$evidence"
        # 검증하지 못했는데 문제만 적은 경우도 사람에게 넘긴다. issues인데 발견 사항이 비면 검증 근거가 없는 것이다.
        # verified는 발견 없음·미검증 없음·시나리오마다 조작 기록이 있을 때만 믿는다. 기록 없는 verified는 근거 없는 통과다.
        if [[ "$(state .ui_review.status)" == verified ]] \
          && jq -e --argjson n "$(state '.ui_scenarios | length')" \
            '(.blocking_findings | length) == 0 and (.unverified | length) == 0 and (.scenarios | length) >= $n
              and all(.scenarios[]; (.captures | length) > 0)' "$ui_out" >/dev/null \
          && [[ -n "$(find "$evidence" -type f -print -quit)" ]]; then
          state_set '.reviewed_tree = $t' --arg t "$(worktree_tree)"
          go ui_review ui_verified
        elif [[ "$(state .ui_review.status)" == issues && "$(jq '.blocking_findings | length' "$ui_out")" -gt 0 ]]; then
          state_set '.findings = ($r[0].blocking_findings + ($r[0].unverified | map("not yet verified: " + .))) | .needs_user_decision = false' --slurpfile r "$ui_out"
          go ui_review ui_issues
        else
          state_set '.ui_review.status = "unverified" | .ui_review.summary = (if $r[0].status == "verified" then "reported verified without a record for every scenario or with unverified items: " else "" end + $r[0].summary)
            | .findings = ($r[0].blocking_findings + $r[0].unverified + [$e])' --slurpfile r "$ui_out" --arg e "evidence: $evidence"
          go ui_review ui_unverified
        fi
        ;;
      repair)
        if [[ "$(state '.needs_user_decision // false')" == true || "$(state .attempts)" -ge "$MAX_REPAIR" ]]; then
          go repair "$ESCALATE"
          continue
        fi
        state_set '.attempts += 1'
        run_node repair "repair-$(state .attempts)" "$CONTEXT

You are the repair node. Fix only these blocking findings for the approved feature. Follow the project test policy. Do not commit, push, create a PR, or change unrelated files; the driver commits checkpoints itself.

Blocking findings:
$(state '.findings')

Approved Implementation Brief:
$(<"$RUN/brief.md")"
        checkpoint "repair-$(state .attempts)"
        if run_checks "repair-$(state .attempts)"; then
          go repair required_checks_pass
        else
          state_set '.findings = $f' --argjson f "$(check_findings "repair-$(state .attempts)")"
          go repair required_checks_fail
        fi
        ;;
      publish)
        publish
        ;;
      remote_ci)
        remote_ci
        ;;
      *) finish invariant_violation 40 "the driver has no handler for graph node '$node'" ;;
    esac
  done
}

case "$CMD" in
  start)
    case "${RUNTIME:-}" in
      "") if command -v codex >/dev/null; then RUNTIME=codex; else RUNTIME=claude; fi ;;
      codex|claude) ;;
      *) usage ;;
    esac
    command -v "$RUNTIME" >/dev/null || { printf '%s not found\n' "$RUNTIME" >&2; exit 2; }
    # 체크포인트는 git add -A로 커밋한다. 실행 전 변경이 섞이거나 기준 브랜치에 커밋이 쌓이지 않게 시작 조건을 막는다.
    case "$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)" in
      pr-only|direct)
        [[ -z "$(git -C "$REPO" status --porcelain --untracked-files=all)" ]] \
          || { printf 'git_policy lets the runner commit; commit or stash the existing changes first so they do not mix into the run\n' >&2; exit 2; }
        ;;
    esac
    if [[ "$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)" == pr-only ]]; then
      base="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      [[ -z "$base" || "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" != "${base#origin/}" ]] \
        || { printf 'git_policy pr-only: start on a work branch or worktree, not the base branch %s\n' "${base#origin/}" >&2; exit 2; }
    fi
    mkdir -p "$RUN"
    printf '%s\n' "$RUN_ID" >"$RUNS_DIR/latest"
    jq -n --arg id "$RUN_ID" --arg repo "$REPO" --arg rt "$RUNTIME" --arg req "$REQUEST" --arg graph "$GRAPH" \
      --arg node "$(jq -r .entry "$GRAPH")" --arg head "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf none)" --arg t "$(now_utc)" \
      --arg git "$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)" \
      --arg appr "$(jq -r '.approval // "human"' "$REPO/.ai-harness/harness.json" 2>/dev/null || printf human)" \
      --argjson cli "$(printf '%s\n' "${CLI_CHECKS[@]+"${CLI_CHECKS[@]}"}" | jq -R . | jq -s 'map(select(length > 0))')" \
      '{run_id:$id, repo:$repo, runtime:$rt, request:$req, graph:$graph, node:$node, start_head:$head, head:$head, started_at:$t,
        policy:{git:$git, approval:(if $appr == "auto" then "auto" else "human" end), commits:($git == "pr-only" or $git == "direct")},
        status:"running", attempts:0, cli_checks:$cli, checks:[], checkpoints:[], findings:[], history:[]}' >"$STATE"
    ;;
  watch)
    [[ -f "$STATE" ]] || { printf 'run not found: %s\n' "$RUN" >&2; exit 2; }
    touch "$RUN/progress.log"
    exec tail -n 50 -f "$RUN/progress.log"
    ;;
  resume|approve|revise|status)
    [[ -f "$STATE" ]] || { printf 'run not found: %s\n' "$RUN" >&2; exit 2; }
    ;;
  *) usage ;;
esac
# 실행을 이어 가는 명령마다 진행 파일 경로를 알린다. 새 세션에서 resume만 부른 에이전트도 모니터할 경로를 얻는다.
if [[ "$CMD" != status ]]; then
  log "run $RUN_ID · progress: $RUN/progress.log · follow with: bash $(printf '%q' "$SCRIPT_DIR/$(basename "$0")") watch --repo $(printf '%q' "$REPO")"
fi

if [[ "$(state '.policy.approval // "human"')" == auto ]]; then
  cat >"$BRIEF_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["brief","checks","ui_scenarios","decisions","needs_human"],
 "properties":{"brief":{"type":"string"},"checks":{"type":"array","items":{"type":"string"}},"ui_scenarios":{"type":"array","items":{"type":"string"}},
  "decisions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["question","choice","rationale"],
   "properties":{"question":{"type":"string"},"choice":{"type":"string"},"rationale":{"type":"string"}}}},
  "needs_human":{"type":"array","items":{"type":"string"}}}}
EOF
else
  cat >"$BRIEF_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["brief","checks","ui_scenarios","open_questions"],
 "properties":{"brief":{"type":"string"},"checks":{"type":"array","items":{"type":"string"}},"ui_scenarios":{"type":"array","items":{"type":"string"}},
  "open_questions":{"type":"array","items":{"type":"string"}}}}
EOF
fi
cat >"$REVIEW_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","blocking_findings","non_blocking_findings","needs_user_decision"],
 "properties":{"summary":{"type":"string"},"blocking_findings":{"type":"array","items":{"type":"string"}},
  "non_blocking_findings":{"type":"array","items":{"type":"string"}},"needs_user_decision":{"type":"boolean"}}}
EOF
cat >"$UI_REVIEW_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["status","summary","scenarios","blocking_findings","non_blocking_findings","unverified"],
 "properties":{"status":{"type":"string","enum":["verified","issues","unverified"]},"summary":{"type":"string"},
  "scenarios":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["scenario","viewport","theme","actions","captures","result"],
   "properties":{"scenario":{"type":"string"},"viewport":{"type":"string"},"theme":{"type":"string"},"actions":{"type":"string"},
    "captures":{"type":"array","items":{"type":"string"}},"result":{"type":"string"}}}},
  "blocking_findings":{"type":"array","items":{"type":"string"}},"non_blocking_findings":{"type":"array","items":{"type":"string"}},
  "unverified":{"type":"array","items":{"type":"string"}}}}
EOF
cat >"$PUBLISH_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","branch","pr_url"],
 "properties":{"summary":{"type":"string"},"branch":{"type":"string"},"pr_url":{"type":"string"}}}
EOF
cat >"$REMOTE_CI_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["status","commit","summary","failures"],
 "properties":{"status":{"type":"string","enum":["passed","failed","none","pending","unverified"]},"commit":{"type":"string"},
  "summary":{"type":"string"},"failures":{"type":"array","items":{"type":"string"}}}}
EOF

case "$CMD" in
  status)
    jq -r '"run \(.run_id) · node \(.node) · status \(.status) · repair \(.attempts) · approval \(.policy.approval // "human") · git_policy \(.policy.git // "")\n" + (.history | map("  \(.from) --\(if .outcome == "" then "next" else .outcome end)--> \(.to)") | join("\n"))' "$STATE"
    [[ "$(state .node)" == approval && -f "$RUN/brief.json" ]] && print_brief
    exit 0
    ;;
  revise)
    [[ -n "$FEEDBACK" ]] || usage
    [[ "$(state .node)" == approval ]] || { printf 'revise works only while waiting for approval (node: %s)\n' "$(state .node)" >&2; exit 2; }
    state_set '.feedback = $f' --arg f "$FEEDBACK"
    go approval brief_changed_or_not_approved
    ;;
  approve)
    [[ "$(state .node)" == approval ]] || { printf 'nothing to approve (node: %s)\n' "$(state .node)" >&2; exit 2; }
    # 에이전트의 Bash 도구·codex exec에는 제어 터미널이 없어 여기서 열리지 않는다.
    (exec 3<>/dev/tty) 2>/dev/null || { printf 'approve needs a terminal; in a conversation, type "승인" and run resume\n' >&2; exit 10; }
    exec 3<>/dev/tty
    print_brief >&3
    printf '\nApprove this brief and allow file changes? [y/N] ' >&3
    answer=""
    IFS= read -r answer <&3 || true
    exec 3>&-
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]] || { log "not approved; revise or start again"; exit 10; }
    record_approval "$(jq -n --arg t "$(now_utc)" '{source:"terminal", at:$t}')"
    ;;
esac

state_set '.status = "running"'
execute
