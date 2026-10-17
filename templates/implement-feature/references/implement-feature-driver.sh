#!/usr/bin/env bash
# feature-delivery-graph.json을 모델 밖에서 강제하는 드라이버.
# 단계마다 별도 에이전트 세션을 띄우고, 전이는 이 스크립트가 정한다:
#   - discover·brief·review 세션은 읽기 전용(Codex sandbox read-only, Claude는 읽기 도구만)으로 띄우고
#     세션 전후 작업 트리 지문을 비교해 바뀌었으면 중단한다.
#   - 승인은 터미널(/dev/tty)에서 사람이 직접 한다. tty가 없으면 Brief만 남기고 멈춘다.
#   - 필수 검증 명령은 에이전트 보고가 아니라 이 스크립트가 직접 실행해 종료 코드로 판정한다.
#   - review 결과는 JSON으로 받아 blocking finding이 0개이고 검증이 통과할 때만 done이다.
#   - 수정은 최대 --max-repair회. 넘으면 user_decision으로 멈춘다.
#   - 커밋·푸시는 하지 않는다. 실행 중 HEAD가 움직이면 중단한다.
#
# 사람이 터미널에서 실행한다. 에이전트가 대신 실행하면 tty가 없어 승인 단계에서 멈춘다.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: implement-feature-driver.sh --check "<command>" [--check ...]
         (--request "<text>" | --request-file <file> | --approved-brief <file>)
         [--runtime codex|claude] [--repo <dir>] [--state-dir <dir>] [--max-repair <n>]

  --check           필수 검증 명령. 저장소 루트에서 bash -c로 실행한다. 1개 이상 필요.
  --request         구현할 기능 요청. discover·brief 세션이 Implementation Brief를 만든다.
  --approved-brief  사람이 이미 승인한 Brief 파일. discover·brief·승인을 건너뛴다.
  --runtime         에이전트 CLI (기본: codex가 있으면 codex, 없으면 claude)

exit: 0 done · 10 approval_required/rejected · 20 user_decision · 30 incomplete · 40 invariant_violation · 2 usage
EOF
  exit 2
}

REPO="."
RUNTIME=""
STATE_DIR=""
REQUEST=""
APPROVED_BRIEF=""
MAX_REPAIR=2
CHECKS=()

while (($#)); do
  case "$1" in
    --check) [[ $# -ge 2 ]] || usage; CHECKS+=("$2"); shift 2 ;;
    --request) [[ $# -ge 2 ]] || usage; REQUEST="$2"; shift 2 ;;
    --request-file) [[ $# -ge 2 && -f "$2" ]] || usage; REQUEST="$(<"$2")"; shift 2 ;;
    --approved-brief) [[ $# -ge 2 && -f "$2" ]] || usage; APPROVED_BRIEF="$2"; shift 2 ;;
    --runtime) [[ $# -ge 2 ]] || usage; RUNTIME="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || usage; REPO="$2"; shift 2 ;;
    --state-dir) [[ $# -ge 2 ]] || usage; STATE_DIR="$2"; shift 2 ;;
    --max-repair) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage; MAX_REPAIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage ;;
  esac
done

((${#CHECKS[@]})) || { printf 'at least one --check is required: done is judged by commands this driver runs\n' >&2; usage; }
[[ -n "$REQUEST" || -n "$APPROVED_BRIEF" ]] || usage
command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 2; }

REPO="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || { printf 'not a git repository: %s\n' "$REPO" >&2; exit 2; }
if [[ -z "$RUNTIME" ]]; then
  if command -v codex >/dev/null; then RUNTIME=codex; else RUNTIME=claude; fi
fi
case "$RUNTIME" in codex|claude) command -v "$RUNTIME" >/dev/null || { printf '%s not found\n' "$RUNTIME" >&2; exit 2; } ;; *) usage ;; esac

# 상태는 저장소 밖에 둔다. 저장소 안에 쓰면 읽기 전용 단계의 지문 비교가 무의미해진다.
if [[ -z "$STATE_DIR" ]]; then
  STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/implement-feature-run.XXXXXX")"
fi
mkdir -p "$STATE_DIR"
STATE_DIR="$(cd "$STATE_DIR" && pwd)"
case "$STATE_DIR/" in "$REPO"/*) printf 'state dir must be outside the repository: %s\n' "$STATE_DIR" >&2; exit 2 ;; esac

log() { printf '[implement-feature] %s\n' "$*" >&2; }

# 추적 파일 diff + 미추적 파일 내용까지 포함한 작업 트리 지문. .gitignore 대상(빌드 산출물)은 제외된다.
fingerprint() {
  {
    git -C "$REPO" rev-parse HEAD 2>/dev/null || true
    git -C "$REPO" diff HEAD --binary 2>/dev/null || true
    git -C "$REPO" ls-files --others --exclude-standard -z \
      | while IFS= read -r -d '' f; do printf '%s\0' "$f"; git -C "$REPO" hash-object -- "$f"; done
  } | git hash-object --stdin
}

START_HEAD="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf 'none')"
BRIEF_SHA=""
ATTEMPTS=0

finish() { # status exit_code message
  local status="$1" code="$2" message="$3"
  jq -n --arg status "$status" --arg message "$message" --arg runtime "$RUNTIME" --arg repo "$REPO" \
    --arg brief_sha "$BRIEF_SHA" --argjson attempts "$ATTEMPTS" --arg state_dir "$STATE_DIR" \
    '{status:$status,message:$message,runtime:$runtime,repo:$repo,brief_hash:$brief_sha,repair_attempts:$attempts,state_dir:$state_dir}' \
    >"$STATE_DIR/result.json"
  log "$status: $message"
  log "state: $STATE_DIR"
  exit "$code"
}

guard_head() {
  local head
  head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf 'none')"
  [[ "$head" == "$START_HEAD" ]] || finish invariant_violation 40 "HEAD moved during $1 ($START_HEAD -> $head); commits are not authorized"
}

# run_agent <ro|rw> <label> <prompt> [schema-file] → 마지막 메시지를 $STATE_DIR/<label>.out에 쓴다
run_agent() {
  local mode="$1" label="$2" prompt="$3" schema="${4:-}" rc=0
  local out="$STATE_DIR/$label.out"
  printf '%s\n' "$prompt" >"$STATE_DIR/$label.prompt"
  log "$label ($mode, $RUNTIME)"
  case "$RUNTIME" in
    codex)
      local sandbox=read-only args=()
      [[ "$mode" == rw ]] && sandbox=workspace-write
      args=(exec -C "$REPO" -s "$sandbox" -o "$out")
      [[ -n "$schema" ]] && args+=(--output-schema "$schema")
      codex "${args[@]}" - <"$STATE_DIR/$label.prompt" >"$STATE_DIR/$label.log" 2>&1 || rc=$?
      ;;
    claude)
      local tools="Read,Grep,Glob" args=()
      [[ "$mode" == rw ]] && tools="Read,Grep,Glob,Edit,Write,Bash"
      # --tools는 내장 도구만 제한한다. MCP 도구(IDE 파일 편집 등)는 --strict-mcp-config로 함께 끈다.
      args=(-p --tools "$tools" --strict-mcp-config --output-format json)
      if [[ "$mode" == rw ]]; then
        args+=(--permission-mode acceptEdits --allowedTools "Bash")
      else
        args+=(--permission-mode dontAsk)
      fi
      [[ -n "$schema" ]] && args+=(--json-schema "$(<"$schema")")
      (cd "$REPO" && claude "${args[@]}" <"$STATE_DIR/$label.prompt") >"$STATE_DIR/$label.json" 2>"$STATE_DIR/$label.log" || rc=$?
      if ((rc == 0)); then
        jq -r 'if .structured_output then (.structured_output | tojson) else (.result // empty) end' \
          "$STATE_DIR/$label.json" >"$out" 2>/dev/null || rc=1
      fi
      ;;
  esac
  ((rc == 0)) && [[ -s "$out" ]] || finish incomplete 30 "$label session failed (exit $rc); see $STATE_DIR/$label.log"
}

run_readonly() { # label prompt [schema]
  local before
  before="$(fingerprint)"
  run_agent ro "$@"
  [[ "$(fingerprint)" == "$before" ]] || finish invariant_violation 40 "read-only node '$1' changed the working tree"
  guard_head "$1"
}

run_checks() { # label → $STATE_DIR/<label>.checks.json, 실패 시 1
  local label="$1" i=0 failed=0 cmd rc results="[]" tail_out
  for cmd in "${CHECKS[@]}"; do
    i=$((i + 1))
    rc=0
    (cd "$REPO" && bash -c "$cmd") >"$STATE_DIR/$label.check$i.log" 2>&1 || rc=$?
    tail_out="$(tail -n 40 "$STATE_DIR/$label.check$i.log")"
    results="$(jq --arg cmd "$cmd" --argjson rc "$rc" --arg tail "$tail_out" '. + [{command:$cmd,exit:$rc,tail:$tail}]' <<<"$results")"
    if ((rc != 0)); then failed=1; log "check failed: $cmd (exit $rc)"; else log "check passed: $cmd"; fi
  done
  printf '%s\n' "$results" >"$STATE_DIR/$label.checks.json"
  return "$failed"
}

check_findings() { # label → blocking finding JSON 배열
  jq -c '[.[] | select(.exit != 0) | "required check failed: \(.command) (exit \(.exit))\n\(.tail)"]' "$STATE_DIR/$1.checks.json"
}

REVIEW_SCHEMA="$STATE_DIR/review-schema.json"
cat >"$REVIEW_SCHEMA" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["summary", "blocking_findings", "non_blocking_findings"],
  "properties": {
    "summary": {"type": "string"},
    "blocking_findings": {"type": "array", "items": {"type": "string"}},
    "non_blocking_findings": {"type": "array", "items": {"type": "string"}}
  }
}
EOF

CONTEXT="Read AGENTS.md, .ai-harness/workflows/implement-feature.md, .ai-harness/workflows/feature-delivery-graph.json and the project docs they select before anything else."

# discover + brief → approval
BRIEF_FILE="$STATE_DIR/brief.md"
if [[ -n "$APPROVED_BRIEF" ]]; then
  cp "$APPROVED_BRIEF" "$BRIEF_FILE"
  log "approval source: approved brief file $APPROVED_BRIEF"
else
  run_readonly brief "$CONTEXT

You are the discover and brief nodes of the feature-delivery graph. Do not edit any file.
Write an Implementation Brief for the request below: scope, out of scope, observable acceptance cases, expected change areas, and verification. The driver will run these required checks itself: ${CHECKS[*]}
Return only the brief in Markdown.

Request:
$REQUEST"
  cp "$STATE_DIR/brief.out" "$BRIEF_FILE"

  # 에이전트의 Bash 도구·codex exec에는 제어 터미널이 없어 여기서 열리지 않는다.
  if ! (exec 3<>/dev/tty) 2>/dev/null; then
    BRIEF_SHA="$(git hash-object "$BRIEF_FILE")"
    finish approval_required 10 "no terminal for human approval. Review $BRIEF_FILE and rerun with --approved-brief $BRIEF_FILE"
  fi
  exec 3<>/dev/tty
  {
    printf '\n----- Implementation Brief -----\n'
    cat "$BRIEF_FILE"
    printf '\n--------------------------------\nApprove this brief and allow file changes? [y/N] '
  } >&3
  answer=""
  IFS= read -r answer <&3 || true
  exec 3>&-
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]] || {
    BRIEF_SHA="$(git hash-object "$BRIEF_FILE")"
    finish approval_rejected 10 "brief not approved; no file was changed. Edit $BRIEF_FILE and rerun with --approved-brief, or rerun with a new request"
  }
  log "approval source: terminal"
fi
BRIEF_SHA="$(git hash-object "$BRIEF_FILE")"
BRIEF="$(<"$BRIEF_FILE")"

# deliver
before_deliver="$(fingerprint)"
run_agent rw deliver "$CONTEXT

You are the deliver node. Implement the approved Implementation Brief below in this repository. Follow the project test policy (Red -> Green -> Refactor only when TDD is required).
Do not commit, push, create a PR, or change scope. The driver runs the required checks itself after you finish: ${CHECKS[*]}
Return a concise summary of changed areas and the commands you ran.

Approved Implementation Brief:
$BRIEF"
guard_head deliver
[[ "$(fingerprint)" != "$before_deliver" ]] || finish incomplete 30 "deliver changed nothing; an approved feature cannot be done without a change"

label=deliver
while :; do
  blocking="[]"
  if ! run_checks "$label"; then
    blocking="$(check_findings "$label")"
  else
    run_readonly "review-$ATTEMPTS" "$CONTEXT

You are the review node. Do not edit any file. Review the current diff (git diff HEAD and untracked files) against the approved brief.
A blocking finding is incorrect or missing behavior, a regression, security or data risk, a broken required check, or a material scope violation. Everything else is non-blocking.
Return only JSON matching the schema.

Approved Implementation Brief:
$BRIEF" "$REVIEW_SCHEMA"
    review_out="$STATE_DIR/review-$ATTEMPTS.out"
    jq -e '(.blocking_findings | type) == "array" and (.non_blocking_findings | type) == "array"' "$review_out" >/dev/null 2>&1 \
      || finish incomplete 30 "review output is not valid JSON for the schema; not treating the feature as done ($review_out)"
    blocking="$(jq -c '.blocking_findings' "$review_out")"
  fi

  if [[ "$blocking" == "[]" ]]; then
    finish "done" 0 "required checks passed (run by the driver) and no blocking findings remain"
  fi
  if ((ATTEMPTS >= MAX_REPAIR)); then
    printf '%s\n' "$blocking" >"$STATE_DIR/unresolved.json"
    finish user_decision 20 "blocking findings remain after $ATTEMPTS repair attempt(s); see $STATE_DIR/unresolved.json"
  fi

  ATTEMPTS=$((ATTEMPTS + 1))
  run_agent rw "repair-$ATTEMPTS" "$CONTEXT

You are the repair node. Fix only these blocking findings for the approved feature. Follow the project test policy. Do not commit, push, create a PR, or change unrelated files.

Blocking findings:
$blocking

Approved Implementation Brief:
$BRIEF"
  guard_head "repair-$ATTEMPTS"
  label="repair-$ATTEMPTS"
done
