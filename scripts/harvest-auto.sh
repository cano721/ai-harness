#!/usr/bin/env bash
# analysis batch가 생기면 /harvest를 백그라운드 headless 세션으로 실행한다 (opt-in: HM_HARVEST_AUTO=1).
# 결과물은 draft PR까지만 만든다. 병합은 사람이 한다.
# 같은 무인 실행 경로로, 하네스 생성물이 플러그인보다 뒤처진 저장소의 /harness-init --sync도 돌린다(opt-in: HM_SYNC_AUTO=1).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

AUTO_DIR="$HM_DATA_DIR/harvest-auto"
RUNS_FILE="$AUTO_DIR/runs.jsonl"
LOG_DIR="$AUTO_DIR/logs"
RUN_LOCK="$AUTO_DIR/running.lock"
MAX_FAILS="${HM_HARVEST_AUTO_MAX_FAILS:-3}"; [[ "$MAX_FAILS" =~ ^[1-9][0-9]*$ ]] || MAX_FAILS=3
DAILY_MAX="${HM_HARVEST_AUTO_DAILY_MAX:-2}"
[[ "$DAILY_MAX" =~ ^[0-9]+$ ]] || DAILY_MAX=2
BUDGET_USD="${HM_HARVEST_AUTO_BUDGET_USD:-5}"
[[ "$BUDGET_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || BUDGET_USD=5
LOG_KEEP=50
SYNC_DIR="$HM_DATA_DIR/sync-auto"
SYNC_DAILY_MAX="${HM_SYNC_AUTO_DAILY_MAX:-6}"
[[ "$SYNC_DAILY_MAX" =~ ^[0-9]+$ ]] || SYNC_DAILY_MAX=6

usage() {
  cat >&2 <<'EOF'
usage:
  harvest-auto.sh sweep                                              # backfill 뒤 batch가 있는 모든 프로젝트 확인
  harvest-auto.sh trigger <record-status-json> <cwd> [claude|codex]
  harvest-auto.sh run <project> <batch_id> <repo_root> <agent> [scope]  # trigger가 띄우는 detached worker
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

started_today() { # [$1=sync] — 자동 harvest와 자동 sync는 하루 상한을 따로 센다
  local want="${1:-harvest}"
  [[ -f "$RUNS_FILE" ]] || { printf '0\n'; return; }
  # 에이전트를 띄우지 않고 끝난 sync(no_agent)는 비용이 없어 상한에서 뺀다.
  # 깨진 줄 하나가 집계를 0으로 만들어 상한을 풀지 않게 줄 단위로 읽고, 읽기 자체가 실패하면 상한을 다 쓴 것으로 본다.
  # jq는 파일을 못 열어도 결과(0)를 출력한 뒤 실패하므로, 출력이 아니라 종료 코드로 판정한다.
  local out=""
  if [[ -r "$RUNS_FILE" ]] && out="$(jq -Rn --arg day "$(date -u +%Y-%m-%d)" --arg want "$want" \
    '[inputs | fromjson? | objects | select((.at // "") | startswith($day)) | select((.scope == "sync") == ($want == "sync"))]
      | ([.[] | select(.event=="started")] | length) - ([.[] | select(.event=="finished" and .no_agent == true)] | length)' \
    "$RUNS_FILE" 2>/dev/null)" && [[ "$out" =~ ^-?[0-9]+$ ]]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$RUNS_UNREADABLE"
  fi
}
RUNS_UNREADABLE=999999
# 실행 기록을 읽지 못해 상한을 닫은 것은 사람이 고쳐야 하므로 daily_max와 구분하고, 그 파일에는 못 쓸 수 있어 health에도 남긴다.
cap_reason() {
  if [[ "$1" == "$RUNS_UNREADABLE" ]]; then
    "$DIR/health.sh" failure harvest_auto runs_unreadable >/dev/null 2>&1 || true
    printf 'runs_unreadable\n'
  else
    printf 'daily_max\n'
  fi
}

short_key() { hm_short_key "$@"; }

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
  mark_attempted() {
    # 같은 batch를 다시 띄울 때도 누적 실패 횟수를 이어받는다(재시도 제한의 근거).
    local fails=0
    if [[ "$(jq -r '.batch_id // empty' "$marker" 2>/dev/null)" == "$batch_id" ]]; then
      fails="$(jq -r '.fails // 0' "$marker" 2>/dev/null || echo 0)"
      [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
    fi
    mkdir -p "${marker%/*}"
    jq -cn --arg batch_id "$batch_id" --arg at "$(now_iso)" --arg result "$1" --argjson fails "$fails" \
      '{batch_id:$batch_id,at:$at,result:$result,fails:$fails}' >"$marker"
  }
  local prev_result=""
  if [[ "$(jq -r '.batch_id // empty' "$marker" 2>/dev/null)" == "$batch_id" ]]; then
    prev_result="$(jq -r '.result // empty' "$marker" 2>/dev/null)"
    # 하네스 저장소를 못 찾아 넘긴 batch만 다시 본다(이전 버전의 구분 없는 "skipped"는 한 번 재판단).
    # 실행했거나 정책상 건너뛴 batch는 끝.
    case "$prev_result" in
      no_harness|skipped) ;;
      # 일시 실패는 다시 시도하되, 같은 batch가 연속 MAX_FAILS번 실패하면 포기한다 —
      # 결정적으로 실패하는 batch가 매번 하루 상한을 먹어 다른 프로젝트를 굶기지 않게.
      failed)
        if (( $(jq -r '.fails // 1' "$marker" 2>/dev/null || echo 1) >= MAX_FAILS )); then
          mark_attempted gave_up
          log_skip "$project" "$batch_id" gave_up
          return 0
        fi
        ;;
      *) return 0 ;;
    esac
  fi

  # 세션 수만 넘은 batch는 실측상 거의 노이즈였다. 교정·오류 등 신호가 있는 batch만 자동으로 돈다.
  if [[ "${HM_HARVEST_AUTO_SESSIONS_ONLY:-0}" != "1" ]] \
    && [[ "$(printf '%s' "$status" | jq -c '.reasons // []')" == '["sessions"]' ]]; then
    [[ "$prev_result" == "skipped" ]] && { mark_attempted sessions_only; return 0; }
    mark_attempted sessions_only
    log_skip "$project" "$batch_id" sessions_only
    return 0
  fi

  # 실행 범위: 팀 저장소(project)는 draft PR, 개인 소유인 workspace 루트와 전역 지침은 auto-apply.sh로
  # 표시된 블록 안에서만 직접 적용한다(되돌리기·효과 검증 포함).
  local scope="project"
  if [[ "$project" == "_global" ]]; then
    scope="global"
    repo_root="$HM_DATA_DIR"
  elif [[ -f "$cwd/.ai-harness/workspace.json" && "${HM_HARVEST_AUTO_WORKSPACE:-1}" == "1" ]]; then
    scope="workspace"
    repo_root="$cwd"
  else
    repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [[ "$scope" == "project" ]] && [[ -z "$repo_root" || ! -f "$repo_root/.ai-harness/harness.json" ]]; then
    [[ "$prev_result" == "no_harness" ]] && return 0
    mark_attempted no_harness
    log_skip "$project" "$batch_id" no_harness_repo
    return 0
  fi
  # 상한·동시 실행 제한은 batch를 소모하지 않고 다음 sweep에서 다시 시도한다.
  local used=""
  used="$(started_today)"
  if (( used >= DAILY_MAX )); then
    log_skip "$project" "$batch_id" "$(cap_reason "$used")"
    return 0
  fi
  if [[ -d "$RUN_LOCK" ]] && kill -0 "$(sed -n '1p' "$RUN_LOCK/pid" 2>/dev/null || echo x)" 2>/dev/null; then
    log_skip "$project" "$batch_id" busy
    return 0
  fi

  agent="$(resolve_agent)"
  # workspace·전역 적용은 auto-apply.sh만 허용하는 권한 구성이 필요해 claude로만 돈다.
  if [[ "$scope" != "project" && "$agent" != "claude" ]]; then
    log_skip "$project" "$batch_id" needs_claude
    return 0
  fi
  mark_attempted launched
  LAUNCHED_NOW=1
  mkdir -p "$LOG_DIR"
  if [[ "${HM_HARVEST_AUTO_FOREGROUND:-0}" == "1" ]]; then
    "$DIR/harvest-auto.sh" run "$project" "$batch_id" "$repo_root" "$agent" "$scope"
  else
    # 호출자(sweep·backfill-due)가 기다리지 않도록 worker를 분리한다.
    nohup "$DIR/harvest-auto.sh" run "$project" "$batch_id" "$repo_root" "$agent" "$scope" \
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
      | while IFS= read -r f; do printf '%s\t%s\n' "$(mtime "$f")" "$f"; done | sort -rn | cut -f2- | head -n 200)
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
  [[ "${HM_HARVEST_AUTO:-0}" == "1" || "${HM_SYNC_AUTO:-0}" == "1" ]] || return 0
  LAUNCHED_NOW=0
  [[ "${HM_HARVEST_AUTO:-0}" == "1" ]] && sweep_batches
  # 실행은 한 번에 하나다. 개선(harvest)이 먼저고, 이번에 아무것도 띄우지 않았을 때만 sync를 본다.
  (( LAUNCHED_NOW == 1 )) || maybe_sync_run
  return 0
}

sweep_batches() {
  local batch="" status="" origin="" cwd="" src="" project=""
  shopt -s nullglob
  local batches=("$HM_DATA_DIR"/harvest-queue/*/analysis-batch.json)
  shopt -u nullglob
  (( ${#batches[@]} > 0 )) || { maybe_global_run; return 0; }
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
  (( LAUNCHED_NOW == 1 )) || maybe_global_run
  return 0
}

# 여러 프로젝트에 걸친 반복(전역 지침 후보)은 프로젝트 batch로 잡히지 않는다. 주기(기본 7일)마다 한 번
# 전체를 가로질러 분석하고, 근거가 기준을 넘으면 전역 CLAUDE.md·Codex AGENTS.md 블록에 적용한다.
maybe_global_run() {
  local days="${HM_HARVEST_GLOBAL_DAYS:-7}" last="" last_epoch=0 status=""
  [[ "$days" =~ ^[0-9]+$ ]] || days=7
  (( days > 0 )) || return 0
  last="$(jq -sr '[.[] | select(.project=="_global" and .event=="started") | .at] | last // empty' "$RUNS_FILE" 2>/dev/null || true)"
  if [[ -n "$last" ]]; then
    last_epoch="$(iso_to_epoch "$last")"
    [[ "$last_epoch" =~ ^[0-9]+$ ]] && (( $(date +%s) - last_epoch < days * 86400 )) && return 0
  fi
  status="$(jq -cn --arg b "global-$(date -u +%Y%m%d)" '{project:"_global",batch_id:$b,has_analysis_batch:true,reasons:["global"]}')"
  command_trigger "$status" "$HM_DATA_DIR" claude
}

sync_marker() { printf '%s/%s.json\n' "$SYNC_DIR" "$(hm_short_key "$1")"; }

# 기준 브랜치의 harness_version이 플러그인보다 낮은 하네스 저장소를 /harness-init --sync로 따라오게 한다.
# 저장소·플러그인 버전 조합당 한 번이고, 일시 실패만 MAX_FAILS까지 다시 시도한다.
maybe_sync_run() {
  local row="" project="" repo="" plugin="" marker="" prev_plugin="" prev_result="" fails=0 agent=""
  [[ "${HM_SYNC_AUTO:-0}" == "1" && -z "${HM_HARVEST_RUNNING:-}" ]] || return 0
  while IFS= read -r row; do
    project="$(jq -r '.project' <<<"$row")"
    repo="$(jq -r '.repo' <<<"$row")"
    plugin="$(jq -r '.plugin' <<<"$row")"
    marker="$(sync_marker "$project")"
    prev_plugin="$(jq -r '.plugin // empty' "$marker" 2>/dev/null)"
    prev_result="$(jq -r '.result // empty' "$marker" 2>/dev/null)"
    fails=0
    if [[ "$prev_plugin" == "$plugin" ]]; then
      [[ "$prev_result" == "failed" ]] || continue
      fails="$(jq -r '.fails // 0' "$marker" 2>/dev/null)"
      [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
      (( fails < MAX_FAILS )) || continue
    fi
    local used=""
    used="$(started_today sync)"
    if (( used >= SYNC_DAILY_MAX )); then
      log_skip "$project" "sync-$plugin" "$(cap_reason "$used")"
      return 0
    fi
    if [[ -d "$RUN_LOCK" ]] && kill -0 "$(sed -n '1p' "$RUN_LOCK/pid" 2>/dev/null || echo x)" 2>/dev/null; then
      log_skip "$project" "sync-$plugin" busy
      return 0
    fi
    agent="$(resolve_agent)"
    # Codex 샌드박스는 .git이 읽기 전용이라 브랜치·커밋·PR까지 갈 수 없다.
    if [[ "$agent" != "claude" ]]; then
      log_skip "$project" "sync-$plugin" needs_claude
      return 0
    fi
    # 마커를 못 쓰면 버전당 1회를 지킬 수 없다 — 같은 저장소를 끝없이 다시 띄우지 않게 멈춘다.
    if ! { mkdir -p "$SYNC_DIR" && jq -cn --arg plugin "$plugin" --arg at "$(now_iso)" --argjson fails "$fails" \
        '{plugin:$plugin,at:$at,result:"launched",fails:$fails}' >"$marker"; } 2>/dev/null; then
      log_skip "$project" "sync-$plugin" marker_unwritable
      return 0
    fi
    LAUNCHED_NOW=1
    mkdir -p "$LOG_DIR"
    if [[ "${HM_HARVEST_AUTO_FOREGROUND:-0}" == "1" ]]; then
      "$DIR/harvest-auto.sh" run "$project" "sync-$plugin" "$repo" "$agent" sync
    else
      nohup "$DIR/harvest-auto.sh" run "$project" "sync-$plugin" "$repo" "$agent" sync </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
    return 0
  done < <("$DIR/sync-auto.sh" outdated --fetch 2>/dev/null)
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

agent_command() { # $1=project $2=work_dir $3=agent $4=base $5=scope → 실행할 argv를 AGENT_CMD에 채운다
  local project="$1" work_dir="$2" agent="$3" base="${4:-HEAD}" scope="${5:-project}" scripts_glob=""
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
        "ai-harness harvest skill을 인자 \"$project --auto --base $base\"로 실행하라. 커밋·push가 막히면 개선안 보고로 끝내라.")
      ;;
    *)
      # 허용 목록의 스크립트 경로와 실제로 로드되는 스킬의 경로가 같아야 한다. launchd shim이 Codex 쪽
      # 설치본을 골라도 claude는 기본으로 자기 캐시의 플러그인을 로드하므로, 이 설치본을 명시해 맞춘다.
      # 이벤트·큐(데이터 디렉토리)와 transcript는 작업 worktree 밖이라, 열어 주지 않으면 읽기가 거부돼
      # 건수만 보고 판단하게 된다(실측: jobda·jobda-agent·jobda-scheduler).
      local read_dirs=(--add-dir "$HM_DATA_DIR" --add-dir "$HM_CLAUDE_PROJECTS_DIR") codex_root=""
      # 읽기 위해 연 디렉토리는 쓰지 못하게 한다. 데이터 디렉토리의 config·shim은 이후 실행이 source·실행하므로
      # 여기를 고칠 수 있으면 transcript 속 지시가 샌드박스 밖 코드 실행으로 이어진다.
      local deny_args=(--disallowedTools "Edit(/$HM_DATA_DIR/**)" "Write(/$HM_DATA_DIR/**)"
        "Edit(/$HM_CLAUDE_PROJECTS_DIR/**)" "Write(/$HM_CLAUDE_PROJECTS_DIR/**)"
        "Bash(git -C *)" "Bash(git reset*)" "Bash(git clean*)" "Bash(git push --force*)" "Bash(git push -f*)"
        "Bash(git push origin --force*)" "Bash(git push origin -f*)" "Bash(git push origin +*)"
        "Bash(git push -u origin --force*)" "Bash(git push -u origin -f*)" "Bash(git push -u origin +*)"
        "Bash(git worktree*)" "Bash(git branch -D*)" "Bash(git checkout -- *)")
      while IFS= read -r codex_root; do
        [[ -d "$codex_root" ]] || continue
        read_dirs+=(--add-dir "$codex_root")
        deny_args+=("Edit(/$codex_root/**)" "Write(/$codex_root/**)")
      done < <(codex_session_roots)
      if [[ "$scope" == "project" || "$scope" == "sync" ]]; then
        local prompt="/ai-harness:harvest $project --auto --base $base"
        [[ "$scope" == "sync" ]] && prompt="/ai-harness:harness-init --sync --apply --auto --base $base"
        AGENT_CMD=(claude -p "$prompt"
          --plugin-dir "$ROOT" --no-session-persistence
          "${read_dirs[@]}"
          --permission-mode acceptEdits
          --allowedTools "Read" "Grep" "Glob" "Edit" "Write" "Agent"
          "Bash(git status*)" "Bash(git diff*)" "Bash(git log*)" "Bash(git show*)" "Bash(git add *)"
          "Bash(git commit *)" "Bash(git switch -c *)" "Bash(git checkout -b *)" "Bash(git fetch*)"
          "Bash(git push origin *)" "Bash(git push -u origin *)" "Bash(git rev-parse*)" "Bash(git branch --show-current*)"
          "Bash(git ls-remote*)"
          "Bash(jq *)" "Bash(head *)" "Bash(tail *)" "Bash($scripts_glob)"
          "${deny_args[@]}"
          --max-budget-usd "$BUDGET_USD"
          --output-format json)
      else
        # 개인 지침은 auto-apply.sh로만 바꾼다: 편집 도구를 금지하고, 미리 허용한 것 외에는 묻지 않고 거부한다.
        AGENT_CMD=(claude -p "/ai-harness:harvest $project --auto --scope $scope"
          --plugin-dir "$ROOT" --no-session-persistence
          "${read_dirs[@]}"
          --permission-mode dontAsk
          --allowedTools "Read" "Grep" "Glob" "Agent"
          "Bash(jq *)" "Bash(head *)" "Bash(tail *)" "Bash($scripts_glob)"
          --disallowedTools "Edit" "Write" "MultiEdit" "NotebookEdit" "Bash(git *)"
          --max-budget-usd "$BUDGET_USD"
          --output-format json)
      fi
      ;;
  esac
}

# 기준 브랜치 최신 커밋에서 detached worktree를 만든다.
make_work_tree() { # $1=repo_root $2=project $3=base → 경로 출력
  local repo_root="$1" dir=""
  dir="$AUTO_DIR/worktrees/$(short_key "$2")-$(date +%s)"
  mkdir -p "${dir%/*}"
  git -C "$repo_root" worktree add -q --detach "$dir" "$3" >/dev/null 2>&1 || return 1
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
  local project="$1" batch_id="$2" repo_root="$3" agent="$4" scope="${5:-project}"
  local started_at="" start_epoch=0 log_file="" exit_code=0 review="null" cost="null" result="" work_dir="" base_ref=""
  local artifact="" component="harvest_auto" ran_agent=1
  [[ "$scope" == "sync" ]] && component="sync_auto"
  mkdir -p "$LOG_DIR"
  if ! hm_acquire_lock "$RUN_LOCK" 1; then
    log_skip "$project" "$batch_id" busy
    if [[ "$scope" == "sync" ]]; then
      # 실패 횟수는 보존한다 — 지우면 MAX_FAILS가 초기화된다.
      jq -c '.result = "failed"' "$(sync_marker "$project")" >"$(sync_marker "$project").tmp" 2>/dev/null \
        && mv "$(sync_marker "$project").tmp" "$(sync_marker "$project")"
    else
      find "$(attempt_marker "$project")" -delete 2>/dev/null
    fi
    return 0
  fi
  trap 'hm_release_lock "$RUN_LOCK"' EXIT

  started_at="$(now_iso)"
  start_epoch="$(date +%s)"
  log_file="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$(short_key "$project").log"
  append_run "$(jq -cn --arg at "$started_at" --arg project "$project" --arg batch "$(batch_key "$batch_id")" \
    --arg agent "$agent" --arg repo "$repo_root" --arg log "$log_file" --arg scope "$scope" \
    '{at:$at,event:"started",project:$project,batch:$batch,scope:$scope,agent:$agent,repo:$repo,log:$log}')"

  # headless 편집은 cwd 안에서만 허용되므로, 작업용 worktree를 만들어 그 안에서 에이전트를 띄운다.
  # 사용자 체크아웃은 구조적으로 건드릴 수 없다.
  if [[ "$scope" == "project" || "$scope" == "sync" ]]; then
    base_ref="$(hm_resolve_base "$repo_root")"
    work_dir="$(make_work_tree "$repo_root" "$project" "$base_ref")" || work_dir=""
  else
    # workspace 루트·데이터 디렉토리에서 바로 돈다. 편집 도구가 없어 auto-apply.sh로만 바꿀 수 있다.
    work_dir="$repo_root"
  fi
  if [[ -z "$work_dir" ]]; then
    printf 'worktree 생성 실패: %s\n' "$repo_root" >"$log_file"
    exit_code=70
  else
    # 적용할 관리 생성물(add·refresh)이 없는 sync는 에이전트를 띄우지 않는다 — 버전만 다른 경우가 대부분이다.
    # 무인 sync가 적용하는 것은 add·refresh뿐이라, 그 밖(승인 필요·제외)만 남은 저장소에 에이전트를 띄우지 않는다.
    local pending=1
    if [[ "$scope" == "sync" ]]; then
      pending="$("$DIR/harness-sync-state.sh" plan --root "$work_dir" --catalog "$ROOT/templates/managed-files.json" 2>/dev/null \
        | jq '(.counts.add // 0) + (.counts.refresh // 0)' 2>/dev/null)"
      [[ "$pending" =~ ^[0-9]+$ ]] || pending=-1
    fi
    if (( pending == -1 )); then
      printf 'sync 계획 실패: %s (%s)\n' "$repo_root" "$base_ref" >"$log_file"
      exit_code=71
      ran_agent=0
    elif (( pending == 0 )); then
      printf '적용할 관리 생성물 없음: %s (%s)\n' "$repo_root" "$base_ref" >"$log_file"
      ran_agent=0
    else
      agent_command "$project" "$work_dir" "$agent" "${base_ref#origin/}" "$scope"
      # 응답 없는 에이전트가 실행 lock을 영원히 쥐지 않게 시간 제한을 둔다(기본 45분).
      (cd "$work_dir" && hm_run_with_timeout "$((${HM_HARVEST_AUTO_TIMEOUT_MIN:-45} * 60))" \
        env HM_HARVEST_RUNNING=1 HM_INTERNAL_SESSION=1 "${AGENT_CMD[@]}") </dev/null >"$log_file" 2>&1 || exit_code=$?
    fi
    if [[ "$scope" == "project" || "$scope" == "sync" ]]; then
      # 이번 worktree만 정리한다. 저장소 전체 prune은 잠시 분리된 사용자 worktree 메타까지 지울 수 있다.
      git -C "$repo_root" worktree remove --force "$work_dir" >/dev/null 2>&1 \
        || find "$work_dir" -depth -delete 2>/dev/null || true
    fi
  fi

  [[ "$scope" == "sync" ]] || review="$(last_review_after "$project" "$started_at")"
  if [[ "$agent" == "claude" ]] && (( ran_agent == 1 )); then
    # stderr 안내 줄(예: 신뢰되지 않은 작업 공간)이 앞에 섞일 수 있어 JSON 줄만 읽는다.
    cost="$(jq -Rn '[inputs | fromjson? | objects | .total_cost_usd? // empty] | last // null' "$log_file" 2>/dev/null || printf 'null')"
  fi
  local fail_reason=""
  fail_reason="$(jq -Rrn '[inputs | fromjson? | objects | select(.type=="result")] | last
    | if . == null then empty
      elif .api_error == "usage_limit_reached" or .api_error_status == 429 then "usage_limit"
      elif .is_error == true then (.api_error // "agent_error")
      else empty end' "$log_file" 2>/dev/null || true)"
  local marker_file="" fails=0
  if (( exit_code != 0 )); then
    result="failed"
    # 사용량 한도·API 오류 같은 일시 실패로 batch를 버리지 않고 다음 sweep이 다시 시도한다.
    # 사용량 한도가 아닌 실패는 횟수를 세어 MAX_FAILS에서 포기한다(트리거가 판단).
    if [[ "$scope" == "sync" ]]; then marker_file="$(sync_marker "$project")"; else marker_file="$(attempt_marker "$project")"; fi
    fails="$(jq -r '.fails // 0' "$marker_file" 2>/dev/null || echo 0)"
    [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
    [[ "$fail_reason" == "usage_limit" ]] || fails=$((fails + 1))
    if [[ "$scope" != "sync" ]]; then
      jq -cn --arg batch_id "$batch_id" --arg at "$(now_iso)" --argjson fails "$fails" \
        '{batch_id:$batch_id,at:$at,result:"failed",fails:$fails}' >"$marker_file" 2>/dev/null || true
    fi
  elif [[ "$scope" == "sync" ]]; then
    if (( ran_agent == 0 )); then
      result="no-change"
    else
      # harness-init --auto는 마지막 응답에 `AI_HARNESS_SYNC_RESULT outcome=<결과> artifact=<PR URL>` 한 줄을 남긴다.
      local line=""
      line="$(jq -Rrn '[inputs | fromjson? | objects | select(.type=="result") | .result // empty] | last // empty' "$log_file" 2>/dev/null \
        | grep -o 'AI_HARNESS_SYNC_RESULT outcome=[a-z_-]*\( artifact=[^[:space:]]*\)\{0,1\}' | tail -n 1)"
      result="$(sed -n 's/.*outcome=\([a-z_-]*\).*/\1/p' <<<"$line")"
      artifact="$(sed -n 's/.* artifact=\([^[:space:]]*\).*/\1/p' <<<"$line")"
      # 실패 횟수 없이 failed로 남으면 매 sweep 다시 띄우므로, 약속한 값이 아니면 사람에게 넘긴다.
      case "$result" in improved|no-change|left_for_user) ;; *) result="left_for_user" ;; esac
    fi
  elif [[ "$scope" == "global" ]]; then
    if [[ -f "$HM_DATA_DIR/applied/applied.jsonl" ]] \
      && jq -e --arg since "$started_at" 'select(.at >= $since)' "$HM_DATA_DIR/applied/applied.jsonl" >/dev/null 2>&1; then
      result="improved"
    else
      result="no-change"
    fi
  elif [[ "$review" == "null" ]]; then
    # 사용자 확인이 필요한 분기 등으로 batch를 남긴 채 끝났다. 수동 /harvest 대상.
    result="left_for_user"
  else
    result="$(printf '%s' "$review" | jq -r '.review.outcome // "reviewed"')"
  fi
  if [[ "$scope" == "sync" ]]; then
    mkdir -p "$SYNC_DIR"
    jq -cn --arg plugin "${batch_id#sync-}" --arg at "$(now_iso)" --arg result "$result" --argjson fails "$fails" \
      '{plugin:$plugin,at:$at,result:$result,fails:$fails}' >"$(sync_marker "$project")" 2>/dev/null || true
  fi
  append_run "$(jq -cn --arg at "$(now_iso)" --arg project "$project" --arg batch "$(batch_key "$batch_id")" \
    --arg scope "$scope" --arg result "$result" --argjson exit_code "$exit_code" \
    --argjson duration_s "$(( $(date +%s) - start_epoch ))" --argjson cost_usd "${cost:-null}" \
    --argjson review "$review" --arg artifact "$artifact" --arg log "$log_file" --arg reason "$fail_reason" \
    --argjson no_agent "$([[ "$scope" == "sync" ]] && (( ran_agent == 0 && exit_code == 0 )) && echo true || echo false)" \
    '{at:$at,event:"finished",project:$project,batch:$batch,scope:$scope,result:$result,exit_code:$exit_code,
      duration_s:$duration_s,cost_usd:$cost_usd,
      artifact:(if $artifact != "" then $artifact else ($review.review.artifact? // null) end),log:$log}
      + (if $no_agent then {no_agent:true} else {} end)
      + (if $reason == "" then {} else {reason:$reason} end)')"
  if (( exit_code == 0 )); then
    "$DIR/health.sh" success "$component" >/dev/null 2>&1 || true
  else
    "$DIR/health.sh" failure "$component" "${fail_reason:-exit_$exit_code}" >/dev/null 2>&1 || true
  fi
  prune_logs

  # 다음 sync 후보를 이어서 띄운다. 동시 실행은 여전히 1개지만, sweep 주기(기본 6시간)마다 1건씩 기다리지 않는다.
  # 사용량 한도로 끝났으면 잇지 않는다 — 한도는 사용자의 작업과 공유한다.
  # 사용자가 다시 작업 중이거나 한도 휴지 중이면 잇지 않고 다음 sweep(유휴 대기 포함)에 넘긴다.
  if [[ "$fail_reason" != "usage_limit" ]]; then
    trap - EXIT
    hm_release_lock "$RUN_LOCK"
    LAUNCHED_NOW=0
    if ! hm_in_usage_backoff "${HM_LLM_BACKOFF_HOURS:-5}" && ! hm_recently_active "${HM_IDLE_MINUTES:-20}"; then
      maybe_sync_run
    fi
  fi
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
  run) [[ $# -eq 4 || $# -eq 5 ]] || usage; command_run "$@" ;;
  runs) command_runs "$@" ;;
  *) usage ;;
esac
