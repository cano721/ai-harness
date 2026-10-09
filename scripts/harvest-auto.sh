#!/usr/bin/env bash
# analysis batch가 생기면 /harvest를 백그라운드 headless 세션으로 실행한다 (opt-in: HM_HARVEST_AUTO=1).
# 결과물은 draft PR까지만 만든다. 병합은 사람이 한다.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

AUTO_DIR="$HM_DATA_DIR/harvest-auto"
RUNS_FILE="$AUTO_DIR/runs.jsonl"
LOG_DIR="$AUTO_DIR/logs"
RUN_LOCK="$AUTO_DIR/running.lock"
DAILY_MAX="${HM_HARVEST_AUTO_DAILY_MAX:-2}"
[[ "$DAILY_MAX" =~ ^[0-9]+$ ]] || DAILY_MAX=2
BUDGET_USD="${HM_HARVEST_AUTO_BUDGET_USD:-5}"
[[ "$BUDGET_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || BUDGET_USD=5
LOG_KEEP=50

usage() {
  cat >&2 <<'EOF'
usage:
  harvest-auto.sh trigger <record-status-json> <cwd> [claude|codex]   # SessionEnd(collect.sh)에서 호출
  harvest-auto.sh run <project> <batch_id> <repo_root> <agent>       # trigger가 띄우는 detached worker
  harvest-auto.sh runs [--limit N]                                   # 최근 자동 실행 기록
EOF
  exit 2
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

append_run() { # $1=json
  mkdir -p "$AUTO_DIR"
  printf '%s\n' "$1" >>"$RUNS_FILE"
}

# batch_id는 세션 마커를 이어 붙인 값이라 길다. 실행 기록에는 짧은 키만 남긴다.
batch_key() { printf '%s' "$1" | { shasum 2>/dev/null || sha1sum; } | cut -c1-12; }

log_skip() { # $1=project $2=batch_id $3=reason
  append_run "$(jq -cn --arg at "$(now_iso)" --arg project "$1" --arg batch "$(batch_key "$2")" --arg reason "$3" \
    '{at:$at,event:"skipped",project:$project,batch:$batch,reason:$reason}')"
}

started_today() {
  [[ -f "$RUNS_FILE" ]] || { printf '0\n'; return; }
  jq -s --arg day "$(date -u +%Y-%m-%d)" \
    '[.[] | select(.event=="started" and (.at | startswith($day)))] | length' "$RUNS_FILE" 2>/dev/null || printf '0\n'
}

attempt_marker() { printf '%s/%s/auto-attempted-batch\n' "$HM_DATA_DIR/harvest-queue" "$(hm_project_key "$1")"; }

command_trigger() {
  local status="$1" cwd="$2" agent="${3:-}" project="" batch_id="" repo_root="" marker=""
  [[ "${HM_HARVEST_AUTO:-0}" == "1" ]] || return 0
  # 자동 harvest 세션 자신의 SessionEnd가 다시 harvest를 띄우지 않게 한다.
  [[ -z "${HM_HARVEST_RUNNING:-}" ]] || return 0
  [[ "$(printf '%s' "$status" | jq -r '.has_analysis_batch // false' 2>/dev/null)" == "true" ]] || return 0
  project="$(printf '%s' "$status" | jq -r '.project // empty')"
  batch_id="$(printf '%s' "$status" | jq -r '.batch_id // .created_at // empty')"
  [[ -n "$project" && -n "$batch_id" ]] || return 0

  marker="$(attempt_marker "$project")"
  [[ "$(jq -r '.batch_id // empty' "$marker" 2>/dev/null)" != "$batch_id" ]] || return 0
  mark_attempted() {
    mkdir -p "${marker%/*}"
    jq -cn --arg batch_id "$batch_id" --arg at "$(now_iso)" --arg result "$1" \
      '{batch_id:$batch_id,at:$at,result:$result}' >"$marker"
  }

  # 세션 수만 넘은 batch는 실측상 거의 노이즈였다. 교정·오류 등 신호가 있는 batch만 자동으로 돈다.
  if [[ "${HM_HARVEST_AUTO_SESSIONS_ONLY:-0}" != "1" ]] \
    && [[ "$(printf '%s' "$status" | jq -c '.reasons // []')" == '["sessions"]' ]]; then
    mark_attempted skipped
    log_skip "$project" "$batch_id" sessions_only
    return 0
  fi

  # 하네스가 없는 디렉토리나 workspace(git 아님, 로컬 적용에 사용자 확인 필요)는 사람 몫으로 남긴다.
  repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" || ! -f "$repo_root/.ai-harness/harness.json" ]]; then
    mark_attempted skipped
    log_skip "$project" "$batch_id" no_harness_repo
    return 0
  fi
  # 상한·동시 실행 제한은 batch를 소모하지 않고 다음 SessionEnd에서 다시 시도한다.
  if (( $(started_today) >= DAILY_MAX )); then
    log_skip "$project" "$batch_id" daily_max
    return 0
  fi
  if [[ -d "$RUN_LOCK" ]] && kill -0 "$(sed -n '1p' "$RUN_LOCK/pid" 2>/dev/null || echo x)" 2>/dev/null; then
    log_skip "$project" "$batch_id" busy
    return 0
  fi

  if [[ -z "$agent" ]]; then
    agent="claude"
  fi
  mark_attempted launched
  mkdir -p "$LOG_DIR"
  if [[ "${HM_HARVEST_AUTO_FOREGROUND:-0}" == "1" ]]; then
    "$DIR/harvest-auto.sh" run "$project" "$batch_id" "$repo_root" "$agent"
  else
    # SessionEnd hook timeout 안에 끝나도록 worker를 세션과 분리한다.
    nohup "$DIR/harvest-auto.sh" run "$project" "$batch_id" "$repo_root" "$agent" \
      </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

agent_command() { # $1=project $2=work_dir $3=agent → 실행할 argv를 AGENT_CMD에 채운다
  local project="$1" work_dir="$2" agent="$3" scripts_glob=""
  if [[ -n "${HM_HARVEST_AUTO_CMD:-}" ]]; then
    # 테스트·사용자 정의 실행기: "<cmd> <project>"
    read -r -a AGENT_CMD <<<"$HM_HARVEST_AUTO_CMD"
    AGENT_CMD+=("$project")
    return
  fi
  scripts_glob="$ROOT/scripts/*"
  case "$agent" in
    codex)
      AGENT_CMD=(codex exec -C "$work_dir" --full-auto
        -c sandbox_workspace_write.network_access=true
        "ai-harness harvest skill을 인자 \"$project --auto\"로 실행하라.")
      ;;
    *)
      AGENT_CMD=(claude -p "/ai-harness:harvest $project --auto"
        --permission-mode acceptEdits
        --allowedTools "Read" "Grep" "Glob" "Edit" "Write" "Agent"
        "Bash(git *)" "Bash(jq *)" "Bash(head *)" "Bash(tail *)"
        "Bash($scripts_glob)"
        --max-budget-usd "$BUDGET_USD"
        --output-format json)
      ;;
  esac
}

# origin 기본 브랜치 최신 커밋에서 detached worktree를 만든다. origin이 없으면 HEAD.
make_work_tree() { # $1=repo_root $2=project → 경로 출력
  local repo_root="$1" dir="" base=""
  dir="$AUTO_DIR/worktrees/$(hm_project_key "$2")-$(date +%s)"
  mkdir -p "${dir%/*}"
  if git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo_root" fetch -q origin >/dev/null 2>&1 || true
    base="$(git -C "$repo_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [[ -z "$base" ]]; then
      base="$(git -C "$repo_root" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -n 1)"
      [[ -n "$base" ]] && base="origin/$base"
    fi
  fi
  git -C "$repo_root" rev-parse --verify --quiet "${base:-HEAD}^{commit}" >/dev/null || base=""
  git -C "$repo_root" worktree add -q --detach "$dir" "${base:-HEAD}" >/dev/null 2>&1 || return 1
  printf '%s\n' "$dir"
}

last_review_after() { # $1=project $2=started_at → 이번 실행이 남긴 review-history 레코드
  local history_file
  history_file="$HM_DATA_DIR/harvest-queue/$(hm_project_key "$1")/review-history.jsonl"
  [[ -f "$history_file" ]] || { printf 'null\n'; return; }
  jq -sc --arg since "$2" '[.[] | select((.reviewed_at // "") >= $since)] | last // null' "$history_file" 2>/dev/null \
    || printf 'null\n'
}

prune_logs() {
  local logs=() i
  shopt -s nullglob
  logs=("$LOG_DIR"/*.log)
  shopt -u nullglob
  (( ${#logs[@]} > LOG_KEEP )) || return 0
  for (( i = 0; i < ${#logs[@]} - LOG_KEEP; i++ )); do
    find "${logs[$i]}" -maxdepth 0 -type f -delete
  done
}

command_run() {
  local project="$1" batch_id="$2" repo_root="$3" agent="$4"
  local started_at="" start_epoch=0 log_file="" exit_code=0 review="" cost="null" result="" work_dir=""
  mkdir -p "$LOG_DIR"
  hm_acquire_lock "$RUN_LOCK" 1 || { log_skip "$project" "$batch_id" busy; find "$(attempt_marker "$project")" -delete 2>/dev/null; return 0; }
  trap 'hm_release_lock "$RUN_LOCK"' EXIT

  started_at="$(now_iso)"
  start_epoch="$(date +%s)"
  log_file="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$(hm_project_key "$project").log"
  append_run "$(jq -cn --arg at "$started_at" --arg project "$project" --arg batch "$(batch_key "$batch_id")" \
    --arg agent "$agent" --arg repo "$repo_root" --arg log "$log_file" \
    '{at:$at,event:"started",project:$project,batch:$batch,agent:$agent,repo:$repo,log:$log}')"

  # headless 편집은 cwd 안에서만 허용되므로, 작업용 worktree를 만들어 그 안에서 에이전트를 띄운다.
  # 사용자 체크아웃은 구조적으로 건드릴 수 없다.
  work_dir="$(make_work_tree "$repo_root" "$project")" || work_dir=""
  if [[ -z "$work_dir" ]]; then
    printf 'worktree 생성 실패: %s\n' "$repo_root" >"$log_file"
    exit_code=70
  else
    agent_command "$project" "$work_dir" "$agent"
    (cd "$work_dir" && HM_HARVEST_RUNNING=1 HM_INTERNAL_SESSION=1 "${AGENT_CMD[@]}") </dev/null >"$log_file" 2>&1 || exit_code=$?
    git -C "$repo_root" worktree remove --force "$work_dir" >/dev/null 2>&1 \
      || find "$work_dir" -depth -delete 2>/dev/null || true
    git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
  fi

  review="$(last_review_after "$project" "$started_at")"
  if [[ "$agent" == "claude" ]]; then
    cost="$(jq -s '[.[] | objects | .total_cost_usd? // empty] | last // null' "$log_file" 2>/dev/null || printf 'null')"
  fi
  if (( exit_code != 0 )); then
    result="failed"
  elif [[ "$review" == "null" ]]; then
    # 사용자 확인이 필요한 분기 등으로 batch를 남긴 채 끝났다. 수동 /harvest 대상.
    result="left_for_user"
  else
    result="$(printf '%s' "$review" | jq -r '.review.outcome // "reviewed"')"
  fi
  append_run "$(jq -cn --arg at "$(now_iso)" --arg project "$project" --arg batch "$(batch_key "$batch_id")" \
    --arg result "$result" --argjson exit_code "$exit_code" \
    --argjson duration_s "$(( $(date +%s) - start_epoch ))" --argjson cost_usd "${cost:-null}" \
    --argjson review "$review" --arg log "$log_file" \
    '{at:$at,event:"finished",project:$project,batch:$batch,result:$result,exit_code:$exit_code,
      duration_s:$duration_s,cost_usd:$cost_usd,artifact:($review.review.artifact // null),log:$log}')"
  if (( exit_code == 0 )); then
    "$DIR/health.sh" success harvest_auto >/dev/null 2>&1 || true
  else
    "$DIR/health.sh" failure harvest_auto "exit_$exit_code" >/dev/null 2>&1 || true
  fi
  prune_logs
}

command_runs() {
  local limit=20
  [[ "${1:-}" == "--limit" && "${2:-}" =~ ^[0-9]+$ ]] && limit="$2"
  [[ -f "$RUNS_FILE" ]] || return 0
  tail -n "$limit" "$RUNS_FILE"
}

command="${1:-}"
shift || true
case "$command" in
  trigger) [[ $# -ge 2 ]] || usage; command_trigger "$@" ;;
  run) [[ $# -eq 4 ]] || usage; command_run "$@" ;;
  runs) command_runs "$@" ;;
  *) usage ;;
esac
