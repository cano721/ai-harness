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
  harvest-auto.sh sweep                                              # backfill 뒤 batch가 있는 모든 프로젝트 확인
  harvest-auto.sh trigger <record-status-json> <cwd> [claude|codex]
  harvest-auto.sh run <project> <batch_id> <repo_root> <agent>       # trigger가 띄우는 detached worker
  harvest-auto.sh agent                                              # 자동 실행에 쓸 에이전트(claude|codex)
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
  # 자동 harvest 세션 안에서 다시 harvest를 띄우지 않게 한다.
  [[ -z "${HM_HARVEST_RUNNING:-}" ]] || return 0
  [[ "$(printf '%s' "$status" | jq -r '.has_analysis_batch // false' 2>/dev/null)" == "true" ]] || return 0
  project="$(printf '%s' "$status" | jq -r '.project // empty')"
  batch_id="$(printf '%s' "$status" | jq -r '.batch_id // .created_at // empty')"
  [[ -n "$project" && -n "$batch_id" ]] || return 0

  marker="$(attempt_marker "$project")"
  local prev_result=""
  if [[ "$(jq -r '.batch_id // empty' "$marker" 2>/dev/null)" == "$batch_id" ]]; then
    prev_result="$(jq -r '.result // empty' "$marker" 2>/dev/null)"
    # 하네스 저장소를 못 찾아 넘긴 batch만 다시 본다(이전 버전의 구분 없는 "skipped"는 한 번 재판단).
    # 실행했거나 정책상 건너뛴 batch는 끝.
    case "$prev_result" in
      no_harness|skipped) ;;
      *) return 0 ;;
    esac
  fi
  mark_attempted() {
    mkdir -p "${marker%/*}"
    jq -cn --arg batch_id "$batch_id" --arg at "$(now_iso)" --arg result "$1" \
      '{batch_id:$batch_id,at:$at,result:$result}' >"$marker"
  }

  # 세션 수만 넘은 batch는 실측상 거의 노이즈였다. 교정·오류 등 신호가 있는 batch만 자동으로 돈다.
  if [[ "${HM_HARVEST_AUTO_SESSIONS_ONLY:-0}" != "1" ]] \
    && [[ "$(printf '%s' "$status" | jq -c '.reasons // []')" == '["sessions"]' ]]; then
    [[ "$prev_result" == "skipped" ]] && { mark_attempted sessions_only; return 0; }
    mark_attempted sessions_only
    log_skip "$project" "$batch_id" sessions_only
    return 0
  fi

  # 하네스가 없는 디렉토리나 workspace(git 아님, 로컬 적용에 사용자 확인 필요)는 사람 몫으로 남긴다.
  repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" || ! -f "$repo_root/.ai-harness/harness.json" ]]; then
    [[ "$prev_result" == "no_harness" ]] && return 0
    mark_attempted no_harness
    log_skip "$project" "$batch_id" no_harness_repo
    return 0
  fi
  # 상한·동시 실행 제한은 batch를 소모하지 않고 다음 sweep에서 다시 시도한다.
  if (( $(started_today) >= DAILY_MAX )); then
    log_skip "$project" "$batch_id" daily_max
    return 0
  fi
  if [[ -d "$RUN_LOCK" ]] && kill -0 "$(sed -n '1p' "$RUN_LOCK/pid" 2>/dev/null || echo x)" 2>/dev/null; then
    log_skip "$project" "$batch_id" busy
    return 0
  fi

  agent="$(resolve_agent)"
  mark_attempted launched
  LAUNCHED_NOW=1
  mkdir -p "$LOG_DIR"
  if [[ "${HM_HARVEST_AUTO_FOREGROUND:-0}" == "1" ]]; then
    "$DIR/harvest-auto.sh" run "$project" "$batch_id" "$repo_root" "$agent"
  else
    # 호출자(sweep·backfill-due)가 기다리지 않도록 worker를 분리한다.
    nohup "$DIR/harvest-auto.sh" run "$project" "$batch_id" "$repo_root" "$agent" \
      </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

# batch의 세션 기록에서 하네스가 있는 저장소 cwd와 도구(src)를 고른다. 없으면 첫 cwd.
batch_origin() { # $1=batch_file → "cwd<TAB>src"
  local ev="" cwd="" src="" first="" root=""
  while IFS= read -r ev; do
    [[ -f "$ev" ]] || ev="$HM_DATA_DIR/rollups/${ev##*/}"
    [[ -f "$ev" ]] || continue
    IFS=$'\t' read -r cwd src < <(jq -r 'select(.kind=="session") | [(.cwd // ""), (.src // "claude")] | @tsv' "$ev" 2>/dev/null | head -n 1)
    [[ -n "$cwd" ]] || continue
    [[ -n "$first" ]] || first="$cwd"$'\t'"$src"
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$root" && -f "$root/.ai-harness/harness.json" ]]; then
      printf '%s\t%s\n' "$cwd" "$src"
      return
    fi
  done < <(jq -r '.event_files[]?' "$1" 2>/dev/null)
  # batch 세션의 작업 경로가 지워진 worktree뿐이면, 같은 프로젝트의 다른 세션 기록에서
  # 지금 살아 있고 프로젝트 ID가 일치하는 하네스 저장소를 찾는다(최근 기록부터 200개).
  local project=""
  project="$(jq -r '.project // empty' "$1" 2>/dev/null)"
  if [[ -n "$project" ]]; then
    while IFS= read -r ev; do
      IFS=$'\t' read -r cwd src < <(jq -r 'select(.kind=="session") | [(.cwd // ""), (.src // "claude")] | @tsv' "$ev" 2>/dev/null | head -n 1)
      [[ -n "$cwd" && -d "$cwd" ]] || continue
      root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
      [[ -n "$root" && -f "$root/.ai-harness/harness.json" ]] || continue
      [[ "$(project_id_for_cwd "$root")" == "$project" ]] || continue
      printf '%s\t%s\n' "$root" "$src"
      return
    done < <(grep -l -F "\"project\":$(jq -cn --arg p "$project" '$p')" "$HM_DATA_DIR"/events/*.jsonl 2>/dev/null \
      | xargs ls -t 2>/dev/null | head -n 200)
  fi
  # 그래도 없으면 기록에 나온 workspace 루트의 멤버 목록(.ai-harness/workspace.json)에서 찾는다.
  # Orca worktree에서만 작업한 저장소는 원본 체크아웃 경로가 세션 기록에 한 번도 나오지 않는다.
  if [[ -n "$project" ]]; then
    local ws="" member=""
    while IFS= read -r ws; do
      [[ -f "$ws/.ai-harness/workspace.json" ]] || continue
      member="$(jq -r --arg p "$project" '.members[]? | select(.project_id == $p) | .path' "$ws/.ai-harness/workspace.json" 2>/dev/null | head -n 1)"
      [[ -n "$member" ]] || continue
      member="$ws/$member"
      if [[ -f "$member/.ai-harness/harness.json" ]] && [[ "$(project_id_for_cwd "$member")" == "$project" ]]; then
        printf '%s\t%s\n' "$member" "claude"
        return
      fi
    done < <(grep -ho '"cwd":"[^"]*"' "$HM_DATA_DIR"/events/*.jsonl 2>/dev/null | sort -u \
      | jq -Rr '("{" + . + "}" | fromjson? | .cwd) // empty' 2>/dev/null)
  fi
  [[ -n "$first" ]] && printf '%s\n' "$first"
}

# 세션 종료 hook에 기대지 않고, backfill이 끝난 뒤 batch가 있는 프로젝트를 모두 확인한다.
# 터미널·탭을 닫아 끝난 세션만 있는 프로젝트도 여기서 자동 실행된다. 실행은 한 번에 하나다.
command_sweep() {
  local batch="" status="" origin="" cwd="" src="" project=""
  [[ "${HM_HARVEST_AUTO:-0}" == "1" ]] || return 0
  shopt -s nullglob
  local batches=("$HM_DATA_DIR"/harvest-queue/*/analysis-batch.json)
  shopt -u nullglob
  (( ${#batches[@]} > 0 )) || return 0
  while IFS= read -r batch; do
    status="$(jq -c '. + {has_analysis_batch:true}' "$batch" 2>/dev/null)" || continue
    project="$(jq -r '.project // empty' <<<"$status")"
    [[ -n "$project" ]] || continue
    origin="$(batch_origin "$batch")"
    [[ -n "$origin" ]] || continue
    IFS=$'\t' read -r cwd src <<<"$origin"
    # 이번 호출에서 실제로 띄웠을 때만 멈춘다. 지난 sweep에서 띄운 batch가 남아 있다고 멈추면
    # 그 뒤 프로젝트들은 차례가 오지 않는다.
    LAUNCHED_NOW=0
    command_trigger "$status" "$cwd" "$src"
    if (( LAUNCHED_NOW == 1 )); then break; fi
  done < <(for batch in "${batches[@]}"; do
      printf '%s\t%s\n' "$(jq -r '.created_at // ""' "$batch" 2>/dev/null)" "$batch"
    done | sort | cut -f2-)
  return 0
}

# 무인 실행 에이전트. 세션을 만든 도구가 아니라 실행 능력으로 고른다.
# Codex 샌드박스는 쓰기 허용 경로 안에서도 .git을 읽기 전용으로 두어 커밋·push를 할 수 없고,
# launchd 환경에는 Bitbucket 토큰이 없다(claude는 settings.json env를 스스로 읽는다).
resolve_agent() {
  case "${HM_HARVEST_AUTO_AGENT:-auto}" in
    claude) printf 'claude\n' ;;
    codex) printf 'codex\n' ;;
    *) if command -v claude >/dev/null 2>&1; then printf 'claude\n'; else printf 'codex\n'; fi ;;
  esac
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
      # --approve-for-me는 workspace-write 샌드박스다. 큐 기록(~/.ai-harness)은 쓸 수 있게 열지만,
      # .git은 샌드박스가 읽기 전용으로 두므로 커밋·push는 실패하고 분석·보고까지만 한다.
      AGENT_CMD=(codex exec -C "$work_dir" --approve-for-me --skip-git-repo-check
        --add-dir "$HM_DATA_DIR"
        -c sandbox_workspace_write.network_access=true
        "ai-harness harvest skill을 인자 \"$project --auto\"로 실행하라. 커밋·push가 막히면 개선안 보고로 끝내라.")
      ;;
    *)
      # 허용 목록의 스크립트 경로와 실제로 로드되는 스킬의 경로가 같아야 한다. launchd shim이 Codex 쪽
      # 설치본을 골라도 claude는 기본으로 자기 캐시의 플러그인을 로드하므로, 이 설치본을 명시해 맞춘다.
      AGENT_CMD=(claude -p "/ai-harness:harvest $project --auto"
        --plugin-dir "$ROOT"
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
    # stderr 안내 줄(예: 신뢰되지 않은 작업 공간)이 앞에 섞일 수 있어 JSON 줄만 읽는다.
    cost="$(jq -Rn '[inputs | fromjson? | objects | .total_cost_usd? // empty] | last // null' "$log_file" 2>/dev/null || printf 'null')"
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
  sweep) command_sweep ;;
  agent) resolve_agent ;;
  run) [[ $# -eq 4 ]] || usage; command_run "$@" ;;
  runs) command_runs "$@" ;;
  *) usage ;;
esac
