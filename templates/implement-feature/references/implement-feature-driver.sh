#!/usr/bin/env bash
# feature-delivery-graph.json을 실행하는 그래프 러너. 모델이 아니라 이 스크립트가 전이를 정한다.
#   - 노드: 그래프의 nodes. write:false 노드는 읽기 전용 세션(Codex sandbox read-only, Claude는 읽기 도구만)으로 띄우고
#     세션 전후 작업 트리 지문이 다르면 멈춘다. actor:human 노드에서는 실행을 멈추고(interrupt) 사람을 기다린다.
#   - 엣지: 노드가 낸 결과(outcome)와 같은 when을 가진 전이만 따른다. 그래프에 없는 전이는 불변식 위반이다.
#   - 상태: 노드마다 state.json에 체크포인트를 남겨 resume이 멈춘 노드부터 이어 간다.
#   - 승인: 사용자가 대화에 직접 입력한 "승인"(Claude·Codex 트랜스크립트의 사용자 메시지) 또는 터미널의 approve.
#     모델이 쓰는 도구 출력·자기 메시지는 사용자 메시지가 아니므로 승인이 되지 않는다.
#     .ai-harness/harness.json의 approval이 auto이고 Brief에 열린 질문이 없으면 그래프의 auto_approved_by_policy 엣지로 통과한다.
#   - 검증: Brief에 담겨 함께 승인된 검증 명령을 이 스크립트가 직접 실행해 종료 코드로 판정한다.
#   - git: harness.json의 git_policy가 pr-only·direct면 deliver·repair 뒤 로컬 체크포인트 커밋을 남기고, publish 노드가
#     커밋·일반 push·PR을 맡는다. 그 밖의 값이면 커밋하지 않는다. publish 밖에서 이 스크립트가 아닌 누군가 HEAD를 움직이면 멈춘다.
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

  공통: [--run <id>] (기본: 이 저장소의 최근 실행) [--repo <dir>] [--runtime codex|claude]

  정책: .ai-harness/harness.json의 approval(human|auto, 기본 human)과 git_policy(pr-only|direct|그 밖)를 start 때 읽는다.

exit: 0 done · 10 승인 대기 · 20 사람 판단 필요 · 30 미완료 · 40 불변식 위반 · 2 사용법
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
mkdir -p "$RUNS_DIR"

log() { printf '[implement-feature] %s\n' "$*" >&2; }

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

# run_agent <node> <label> <prompt> [schema] → $RUN/<label>.out. 쓰기 권한은 그래프의 nodes.<node>.write가 정한다.
run_agent() {
  local node="$1" label="$2" prompt="$3" schema="${4:-}" rc=0 writable
  local out="$RUN/$label.out"
  writable="$(jq -r --arg n "$node" '.nodes[$n].write' "$GRAPH")"
  printf '%s\n' "$prompt" >"$RUN/$label.prompt"
  log "$label ($([[ "$writable" == true ]] && echo write || echo read-only), $(state .runtime))"
  case "$(state .runtime)" in
    codex)
      local args=(exec -C "$REPO" -s "$([[ "$writable" == true ]] && echo workspace-write || echo read-only)" -o "$out")
      [[ -n "$schema" ]] && args+=(--output-schema "$schema")
      # push·PR 노드는 네트워크가 필요하다. workspace-write sandbox는 기본으로 네트워크를 막는다.
      [[ "$(jq -r --arg n "$node" '.nodes[$n].network // false' "$GRAPH")" == true ]] && args+=(-c sandbox_workspace_write.network_access=true)
      codex "${args[@]}" - <"$RUN/$label.prompt" >"$RUN/$label.log" 2>&1 || rc=$?
      ;;
    claude)
      # --tools는 내장 도구만 제한한다. MCP 도구(IDE 파일 편집 등)는 --strict-mcp-config로 함께 끈다.
      # 쓰기 노드는 Agent로 프로젝트 페르소나에 위임할 수 있다.
      local args=(-p --strict-mcp-config --output-format json)
      if [[ "$writable" == true ]]; then
        args+=(--tools "Read,Grep,Glob,Edit,Write,Bash,Agent" --permission-mode acceptEdits --allowedTools "Bash")
      else
        args+=(--tools "Read,Grep,Glob" --permission-mode dontAsk)
      fi
      [[ -n "$schema" ]] && args+=(--json-schema "$(<"$schema")")
      (cd "$REPO" && claude "${args[@]}" <"$RUN/$label.prompt") >"$RUN/$label.json" 2>"$RUN/$label.log" || rc=$?
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
    [[ "$(fingerprint)" == "$before" ]] || finish invariant_violation 40 "read-only node '$node' changed the working tree"
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
  jq -r '.brief' "$RUN/brief.json"
  printf '\n== 드라이버가 직접 실행할 검증 ==\n'
  state '.checks[] | "- " + .'
  jq -r 'if (.open_questions | length) > 0 then "\n== 확인이 필요한 점 ==\n" + (.open_questions | map("- " + .) | join("\n")) else empty end' "$RUN/brief.json"
  if [[ "${1:-}" == auto ]]; then
    printf '\n== 정책 승인 (approval: auto) ==\nBrief는 %s에 남고 PR 본문에 들어간다.\n' "$RUN/brief.md"
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
- pr-only: push the work branch with a normal push that sets its upstream, then open a pull request against the base branch. Put the approved brief and the checks below in the PR body.
- direct: push the current branch with a normal push that sets its upstream; open a pull request only when the project workflow requires one.
- Never merge, never force-push, never push to the base branch under pr-only, and do not change file contents: the committed tree must equal the reviewed one.
Return only JSON matching the schema; pr_url is empty when no PR was opened.

Checks the driver ran: $(state '.checks | join(" ; ")')

Approved brief:
$(jq -r '.brief' "$RUN/brief.json")" "$PUBLISH_SCHEMA"
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

CONTEXT="Read AGENTS.md, .ai-harness/workflows/implement-feature.md, .ai-harness/workflows/feature-delivery-graph.json and the project docs they select before anything else."

BRIEF_SCHEMA="$RUN/brief-schema.json"
REVIEW_SCHEMA="$RUN/review-schema.json"
PUBLISH_SCHEMA="$RUN/publish-schema.json"

execute() {
  local node brief blocking
  while :; do
    node="$(state .node)"
    if jq -e --arg n "$node" '.terminals | index($n)' "$GRAPH" >/dev/null; then
      case "$node" in
        done) finish "done" 0 "required checks passed (run by the driver) and no blocking findings remain$(state 'if (.publish.pr_url // "") != "" then "; PR: " + .publish.pr_url elif .publish.skipped then "; " + .publish.skipped else "" end')" ;;
        *) printf '%s\n' "$(state '.findings')" >"$RUN/unresolved.json"
           finish "$node" 20 "a person must decide; see $RUN/unresolved.json" ;;
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
Put anything the person must decide in open_questions.

Request:
$(state .request)

Project contract from the discover node:
$(cat "$RUN/discover.out")
$(if [[ "$(state '.feedback // ""')" != "" ]]; then printf '\nPrevious brief:\n%s\n\nRevise it with this feedback from the person:\n%s\n' "$(jq -r '.brief' "$RUN/brief.json")" "$(state .feedback)"; fi)" "$BRIEF_SCHEMA"
        brief="$RUN/brief-$(state '.history | length').out"
        jq -e '(.brief | type) == "string" and (.checks | type) == "array" and (.open_questions | type) == "array"' "$brief" >/dev/null 2>&1 \
          || finish incomplete 30 "brief output does not match the schema ($brief)"
        cp "$brief" "$RUN/brief.json"
        jq -r '.brief' "$brief" >"$RUN/brief.md"
        # 승인 대상은 Brief 본문과 검증 명령 전체다. 둘 중 하나라도 바뀌면 이전 승인은 무효다.
        state_set '.checks = ([.cli_checks[], $b[0].checks[]] | map(select(length > 0)) | unique)
          | .presented_at = $t | .feedback = null | .approval = null' --slurpfile b "$RUN/brief.json" --arg t "$(now_utc)"
        state_set '.brief_hash = $h' --arg h "$({ jq -r '.brief' "$RUN/brief.json"; state '.checks[]'; } | git hash-object --stdin)"
        [[ "$(state '.checks | length')" -gt 0 ]] \
          || finish incomplete 30 "the brief has no verification command; revise with a check or start again with --check"
        go brief ""
        ;;
      approval)
        if [[ "$(state '.approval.brief_hash // ""')" != "$(state .brief_hash)" && "$(state '.policy.approval // "human"')" == auto ]]; then
          # auto는 사람 대신 정책이 승인한다. 열린 질문이 있거나 그래프가 auto 엣지를 지웠으면 사람을 기다린다.
          if [[ "$(jq '.open_questions | length' "$RUN/brief.json")" -gt 0 ]]; then
            log "approval is auto, but the brief has open questions; waiting for a person"
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
$(jq -r '.brief' "$RUN/brief.json")"
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
$(jq -r '.brief' "$RUN/brief.json")" "$REVIEW_SCHEMA"
          local review_out
          review_out="$RUN/review-$(state .attempts).out"
          jq -e '(.blocking_findings | type) == "array" and (.needs_user_decision | type) == "boolean"' "$review_out" >/dev/null 2>&1 \
            || finish incomplete 30 "review output does not match the schema; the feature is not done ($review_out)"
          state_set '.findings = $r[0].blocking_findings | .needs_user_decision = $r[0].needs_user_decision' --slurpfile r "$review_out"
        fi
        if [[ "$(state '.findings | length')" -eq 0 ]]; then
          state_set '.reviewed_tree = $t' --arg t "$(worktree_tree)"
          go review no_blocking_findings
        else
          go review blocking_findings
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
$(jq -r '.brief' "$RUN/brief.json")"
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
  resume|approve|revise|status)
    [[ -f "$STATE" ]] || { printf 'run not found: %s\n' "$RUN" >&2; exit 2; }
    ;;
  *) usage ;;
esac

cat >"$BRIEF_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["brief","checks","open_questions"],
 "properties":{"brief":{"type":"string"},"checks":{"type":"array","items":{"type":"string"}},"open_questions":{"type":"array","items":{"type":"string"}}}}
EOF
cat >"$REVIEW_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","blocking_findings","non_blocking_findings","needs_user_decision"],
 "properties":{"summary":{"type":"string"},"blocking_findings":{"type":"array","items":{"type":"string"}},
  "non_blocking_findings":{"type":"array","items":{"type":"string"}},"needs_user_decision":{"type":"boolean"}}}
EOF
cat >"$PUBLISH_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","branch","pr_url"],
 "properties":{"summary":{"type":"string"},"branch":{"type":"string"},"pr_url":{"type":"string"}}}
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
