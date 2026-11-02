#!/usr/bin/env bash
# shellcheck disable=SC2016  # set_sig·state_update에 넘기는 작은따옴표 인자는 jq 식이다($cur·$now는 jq 변수)
# 모니터링 도구의 에러를 자동으로 고치고, 고친 뒤 그 에러가 더 나오지 않는지까지 확인한다 (opt-in: HM_AUTOFIX_AUTO=1).
# 저장소 manifest의 `monitor` 설정이 있는 하네스 저장소만 대상이다. 에러 시그니처마다 상태를 남긴다:
#   attempting → pr_open → verifying(병합·배포 뒤 관찰) → resolved | regressed(재시도) | gave_up
#   그 밖: skipped(코드 버그 아님·재현 불가, 유예 뒤 다시 봄) · declined(사람이 PR을 닫음) · failed(일시 실패)
# 수정은 작업 전용 worktree의 headless 에이전트가 draft PR까지만 만든다. 병합은 사람이 한다.
# 검증(PR 상태·배포 반영·재발 확인)은 LLM 없이 이 스크립트가 sweep마다 한다.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

AF_DIR="$HM_DATA_DIR/autofix"
RUNS_FILE="$AF_DIR/runs.jsonl"
LOG_DIR="$AF_DIR/logs"
# 무인 에이전트는 한 번에 하나다 — 자동 harvest·sync와 같은 lock을 쓴다.
RUN_LOCK="$HM_DATA_DIR/harvest-auto/running.lock"
WORK_TREES_DIR="${HM_AUTO_WORKTREE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ai-harness/worktrees}"
case "$WORK_TREES_DIR/" in "$HM_DATA_DIR"/*) WORK_TREES_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ai-harness/worktrees" ;; esac
int_env() { local v="${!1:-}"; [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v" || printf '%s\n' "$2"; }
DAILY_MAX="$(int_env HM_AUTOFIX_DAILY_MAX 3)"
MAX_ATTEMPTS="$(int_env HM_AUTOFIX_MAX_ATTEMPTS 2)"
MAX_FAILS="$(int_env HM_AUTOFIX_MAX_FAILS 3)"
SKIP_COOLDOWN_DAYS="$(int_env HM_AUTOFIX_SKIP_COOLDOWN_DAYS 7)"
TIMEOUT_MIN="$(int_env HM_AUTOFIX_TIMEOUT_MIN 60)"
DEPLOY_WAIT_DAYS="$(int_env HM_AUTOFIX_DEPLOY_WAIT_DAYS 14)"
BUDGET_USD="${HM_AUTOFIX_BUDGET_USD:-10}"
[[ "$BUDGET_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || BUDGET_USD=10
LOG_KEEP=50

usage() {
  cat >&2 <<'EOF'
usage:
  autofix-auto.sh sweep                         # 검증 → 새 에러 1건 수정 실행 (HM_AUTOFIX_AUTO=1일 때)
  autofix-auto.sh verify [--project <id>]       # 검증만: PR 병합·배포 반영·재발 여부를 갱신
  autofix-auto.sh candidates --project <id>     # 지금 수정 대상이 될 에러(JSON lines)
  autofix-auto.sh status [--project <id>]       # 시그니처별 상태
  autofix-auto.sh track --project <id> --candidate <json> --pr <url>   # 수동으로 연 PR도 검증 대상에 올린다
  autofix-auto.sh run <project> <repo> <candidate-json-file>   # sweep이 띄우는 detached worker
  autofix-auto.sh runs [--limit N]
EOF
  exit 2
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
append_run() { mkdir -p "$AF_DIR"; printf '%s\n' "$1" >>"$RUNS_FILE"; }
log_event() { # $1=project $2=event $3=signature [$4=extra json]
  local extra="${4:-}"
  [[ -n "$extra" ]] || extra='{}'
  append_run "$(jq -cn --arg at "$(now_iso)" --arg p "$1" --arg e "$2" --arg s "$3" --argjson x "$extra" \
    '{at:$at,event:$e,project:$p,signature:$s} + $x')"
}

state_file() { printf '%s/%s/state.json\n' "$AF_DIR" "$(hm_short_key "$1")"; }

# 상태 갱신은 worker와 sweep이 겹칠 수 있어 lock 안에서 읽고 쓴다. $1=project $2=jq filter, 나머지는 jq 인자.
state_update() {
  local project="$1" filter="$2" file="" lock=""
  shift 2
  file="$(state_file "$project")"
  lock="${file%/*}/.lock"
  mkdir -p "${file%/*}"
  hm_acquire_lock "$lock" 250 || { printf 'state lock 실패: %s\n' "$file" >&2; return 1; }
  { [[ -s "$file" ]] && cat "$file" || jq -cn --arg p "$project" '{project:$p,signatures:{}}'; } \
    | jq --arg now "$(now_iso)" "$@" "$filter" >"$file.tmp" && mv "$file.tmp" "$file"
  local rc=$?
  hm_release_lock "$lock"
  return "$rc"
}
state_get() { jq -c '.' "$(state_file "$1")" 2>/dev/null || jq -cn --arg p "$1" '{project:$p,signatures:{}}'; }
set_sig() { # $1=project $2=signature $3=jq 객체 식(현재 값은 $cur) [나머지 jq 인자]
  local project="$1" sig="$2" expr="$3" try=0
  shift 3
  # PR을 연 뒤 기록에 실패하면 같은 에러로 PR이 또 열린다 — 몇 번 다시 시도한다(남은 실패는 recover_attempts가 실행 기록으로 복구).
  for try in 1 2 3; do
    state_update "$project" '.signatures[$sig] as $cur | .signatures[$sig] = (($cur // {}) + ('"$expr"') + {updated_at:$now})' \
      --arg sig "$sig" "$@" && return 0
    sleep "$try"
  done
  return 1
}

# 대상은 사용자가 config의 HM_AUTOFIX_REPOS(프로젝트 ID, 쉼표·공백 구분)에 적은 저장소뿐이다. 세션 기록에 나온
# 아무 저장소나 자기 manifest로 무인 실행·자격증명 사용을 일으키지 못하게 한다.
monitored_repos() { # [$1=project] → JSON lines(repo, project, base, manifest) 중 monitor 설정이 있고 허용된 것
  local allowed=""
  allowed="$(printf '%s' "${HM_AUTOFIX_REPOS:-}" | jq -Rsc '[splits("[,[:space:]]+")] | map(select(. != ""))')"
  [[ "$allowed" != "[]" ]] || return 0
  if [[ -n "${HM_AUTOFIX_REPOS_CMD:-}" ]]; then
    local -a cmd=(); read -r -a cmd <<<"$HM_AUTOFIX_REPOS_CMD"; "${cmd[@]}"
  else
    "$DIR/sync-auto.sh" repos
  fi | jq -c --arg p "${1:-}" --argjson allowed "$allowed" \
    'select(.manifest.monitor.provider? and (.project as $x | $allowed | index($x)) and ($p == "" or .project == $p))'
}

mcfg() { jq -r --arg k "$2" '.manifest.monitor[$k] // empty | tostring' <<<"$1"; }

pr_status() { # $1=url
  if [[ -n "${HM_AUTOFIX_PR_STATUS_CMD:-}" ]]; then
    local -a cmd=(); read -r -a cmd <<<"$HM_AUTOFIX_PR_STATUS_CMD"; "${cmd[@]}" "$1"
  else
    "$DIR/open-pr.sh" --status "$1"
  fi
}

# 실행 기록에 PR까지 남았는데 상태가 attempting에 머문 시그니처를 PR 상태로 되돌린다(상태 기록 실패 복구).
recover_attempts() { # $1=project
  local project="$1" sig="" launched="" pr=""
  while IFS=$'\t' read -r sig launched; do
    pr="$(jq -Rrn --arg p "$project" --arg s "$sig" --arg since "$launched" '[inputs | fromjson? | select(.event=="finished"
        and .project==$p and .signature==$s and .outcome=="pr_opened" and (.at // "") >= $since) | .artifact] | last // empty' "$RUNS_FILE" 2>/dev/null)"
    [[ -n "$pr" ]] || continue
    set_sig "$project" "$sig" '{status:"pr_open",pr:$u,pr_opened_at:($cur.pr_opened_at // $now)}' --arg u "$pr"
    log_event "$project" recovered "$sig" "$(jq -cn --arg u "$pr" '{artifact:$u}')"
  done < <(state_get "$project" | jq -r '.signatures | to_entries[] | select(.value.status == "attempting") | [.key, (.value.launched_at // "")] | @tsv')
}

# ── 검증 ─────────────────────────────────────────────────────────────────────
# 병합 → 배포 반영(deploy_branch에 병합 커밋이 들어간 첫 관찰) → 유예(grace_hours) → 관찰(quiet_hours) 순이다.
# 관찰 창은 수정 전 빈도로 늘린다: 하루 2건짜리 에러를 6시간 조용하다고 해결로 보지 않게, 고치지 않았다면
# 평균 3건은 나왔을 시간만큼은 지켜본다(최대 14일).
verify_repo() { # $1=repo json
  local row="$1" project="" repo="" grace=24 quiet=72 deploy_branch="" sig="" rec="" status="" now_e=0
  project="$(jq -r '.project' <<<"$row")"; repo="$(jq -r '.repo' <<<"$row")"
  grace="$(mcfg "$row" grace_hours)"; [[ "$grace" =~ ^[0-9]+$ ]] || grace=24
  quiet="$(mcfg "$row" quiet_hours)"; [[ "$quiet" =~ ^[0-9]+$ ]] || quiet=72
  deploy_branch="$(mcfg "$row" deploy_branch)"
  [[ -z "$deploy_branch" || ( "$deploy_branch" =~ ^[A-Za-z0-9._/-]+$ && "$deploy_branch" != -* && "$deploy_branch" != *..* ) ]] || deploy_branch=""
  local fetched=0 state_json=""
  now_e="$(date +%s)"
  recover_attempts "$project"
  state_json="$(state_get "$project")"
  while IFS= read -r sig; do
    rec="$(jq -c --arg s "$sig" '.signatures[$s]' <<<"$state_json")"
    status="$(jq -r '.status' <<<"$rec")"
    case "$status" in
      pr_open)
        local st="" state="" merged_at="" commit=""
        st="$(pr_status "$(jq -r '.pr' <<<"$rec")" 2>/dev/null)" || { log_event "$project" verify_error "$sig" '{"reason":"pr_status"}'; continue; }
        state="$(jq -r '.state // empty' <<<"$st")"
        case "$state" in
          merged)
            merged_at="$(jq -r '.merged_at // empty' <<<"$st")"; [[ -n "$merged_at" ]] || merged_at="$(now_iso)"
            commit="$(jq -r '.merge_commit // empty' <<<"$st")"
            # 배포 브랜치를 정하지 않았으면 병합 시각을 배포 시각으로 본다.
            set_sig "$project" "$sig" '{status:"verifying",merged_at:$m,merge_commit:(if $c == "" then null else $c end),
              deployed_at:(if $d == "" or $c == "" then $m else null end)}' --arg m "$merged_at" --arg c "$commit" --arg d "$deploy_branch"
            log_event "$project" merged "$sig"
            ;;
          closed)
            set_sig "$project" "$sig" '{status:"declined"}'
            log_event "$project" declined "$sig"
            ;;
        esac
        ;;
      verifying)
        local deployed_at="" from_e=0 need=0 base_count=0 window=24 res="" since=""
        deployed_at="$(jq -r '.deployed_at // empty' <<<"$rec")"
        if [[ -z "$deployed_at" ]]; then
          (( fetched == 1 )) || { hm_run_with_timeout "${HM_FETCH_TIMEOUT_SEC:-60}" git -C "$repo" fetch -q origin >/dev/null 2>&1; fetched=1; }
          if git -C "$repo" merge-base --is-ancestor "$(jq -r '.merge_commit' <<<"$rec")" "origin/$deploy_branch" 2>/dev/null; then
            deployed_at="$(now_iso)"
            set_sig "$project" "$sig" '{deployed_at:$d}' --arg d "$deployed_at"
            log_event "$project" deployed "$sig" "$(jq -cn --arg b "$deploy_branch" '{branch:$b}')"
          else
            # 배포 브랜치로 squash 릴리스를 하면 병합 커밋이 끝내 보이지 않는다. 기다림에 상한을 두고 사람에게 넘긴다.
            local merged_e=""
            merged_e="$(iso_to_epoch "$(jq -r '.merged_at // empty' <<<"$rec")")"
            if [[ "$merged_e" =~ ^[0-9]+$ ]] && (( now_e - merged_e > DEPLOY_WAIT_DAYS * 86400 )); then
              set_sig "$project" "$sig" '{status:"gave_up",outcome:"deploy_unobserved"}'
              log_event "$project" gave_up "$sig" "$(jq -cn --arg b "$deploy_branch" '{reason:"deploy_unobserved",branch:$b}')"
            fi
            continue
          fi
        fi
        from_e="$(iso_to_epoch "$deployed_at")"
        # 시각을 못 읽으면 since가 1970이 되어 옛 이벤트로 거짓 재발이 난다 — 판정하지 않는다.
        [[ "$from_e" =~ ^[0-9]+$ ]] || { log_event "$project" verify_error "$sig" '{"reason":"bad_time"}'; continue; }
        from_e=$(( from_e + grace * 3600 ))
        (( now_e >= from_e )) || continue
        base_count="$(jq -r '.baseline.count // 0' <<<"$rec")"; [[ "$base_count" =~ ^[0-9]+$ ]] || base_count=0
        window="$(jq -r '.baseline.window_hours // 24' <<<"$rec")"; [[ "$window" =~ ^[0-9]+$ ]] || window=24
        need="$quiet"
        if (( base_count > 0 )); then
          local by_rate=$(( (3 * window + base_count - 1) / base_count ))
          (( by_rate > need )) && need="$by_rate"
        fi
        (( need > 336 )) && need=336
        since="$(epoch_iso "$from_e")"
        res="$("$DIR/monitor-fetch.sh" count --root "$repo" --meta "$(jq -c '.meta // {}' <<<"$rec")" --since "$since" 2>/dev/null)" \
          || { log_event "$project" verify_error "$sig" '{"reason":"monitor_count"}'; continue; }
        # 빈 출력·형식 오류를 "재발 없음"으로 읽으면 거짓 해결이 된다.
        jq -e '.seen | type == "boolean"' <<<"$res" >/dev/null 2>&1 \
          || { log_event "$project" verify_error "$sig" '{"reason":"monitor_count_format"}'; continue; }
        if [[ "$(jq -r '.seen' <<<"$res")" == "true" ]]; then
          local attempts=0 next="regressed"
          attempts="$(jq -r '.attempts // 0' <<<"$rec")"
          (( attempts >= MAX_ATTEMPTS )) && next="gave_up"
          set_sig "$project" "$sig" '{status:$s,regressions:(($cur.regressions // []) + [{at:$now,since:$since,pr:$cur.pr} + $r])}' \
            --arg s "$next" --arg since "$since" --argjson r "$res"
          log_event "$project" regressed "$sig" "$(jq -c --arg s "$next" '{next:$s} + .' <<<"$res")"
        elif (( now_e >= from_e + need * 3600 )); then
          set_sig "$project" "$sig" '{status:"resolved",resolved_at:$now,verified_window:{since:$since,hours:$h}}' \
            --arg since "$since" --argjson h "$need"
          log_event "$project" resolved "$sig" "$(jq -cn --arg since "$since" --argjson h "$need" '{since:$since,quiet_hours:$h}')"
        else
          set_sig "$project" "$sig" '{last_check_at:$now,verify_until:$u}' --arg u "$(epoch_iso $(( from_e + need * 3600 )))"
        fi
        ;;
    esac
  done < <(jq -r '.signatures | to_entries[] | select(.value.status == "pr_open" or .value.status == "verifying") | .key' <<<"$state_json")
}

command_verify() {
  local project="" row=""
  [[ "${1:-}" == "--project" ]] && project="${2:-}"
  while IFS= read -r row; do verify_repo "$row"; done < <(monitored_repos "$project")
}

# ── 후보 선정 ─────────────────────────────────────────────────────────────────
# 새 에러, 재발한 에러(시도 횟수 남음), 일시 실패(횟수 남음), 유예가 끝난 skipped, 해결 뒤 다시 목록에 오른 에러.
candidates_for() { # $1=repo json → JSON lines
  local row="$1" project="" repo=""
  project="$(jq -r '.project' <<<"$row")"; repo="$(jq -r '.repo' <<<"$row")"
  "$DIR/monitor-fetch.sh" list --root "$repo" 2>/dev/null \
    | jq -c --argjson st "$(state_get "$project")" --argjson max_attempts "$MAX_ATTEMPTS" --argjson max_fails "$MAX_FAILS" \
        --arg cooldown "$(days_ago_iso "$SKIP_COOLDOWN_DAYS")" --arg stale "$(epoch_iso $(( $(date +%s) - TIMEOUT_MIN * 120 )))" '
      . as $c | ($st.signatures[$c.signature] // null) as $r
      | if $r == null then $c + {reason:"new"}
        elif $r.status == "regressed" and (($r.attempts // 0) < $max_attempts) then $c + {reason:"regressed"}
        elif $r.status == "resolved" and (($r.attempts // 0) < $max_attempts) then $c + {reason:"reappeared"}
        elif $r.status == "failed" and (($r.fails // 0) < $max_fails) then $c + {reason:"retry"}
        elif $r.status == "attempting" and (($r.launched_at // "") < $stale) and (($r.fails // 0) < $max_fails)
          and (($r.attempts // 0) < $max_attempts) then $c + {reason:"stale_attempt"}
        elif $r.status == "skipped" and (($r.skipped_at // "") < $cooldown) then $c + {reason:"cooldown_over"}
        else empty end'
}

command_candidates() {
  [[ "${1:-}" == "--project" && -n "${2:-}" ]] || usage
  local row=""
  while IFS= read -r row; do candidates_for "$row"; done < <(monitored_repos "$2")
}

started_today() {
  [[ -f "$RUNS_FILE" ]] || { printf '0\n'; return; }
  jq -Rn --arg day "$(date -u +%Y-%m-%d)" '[inputs | fromjson? | select(.event=="started" and ((.at // "") | startswith($day)))] | length' \
    "$RUNS_FILE" 2>/dev/null || printf '999999\n'
}
lock_busy() { [[ -d "$RUN_LOCK" ]] && kill -0 "$(sed -n '1p' "$RUN_LOCK/pid" 2>/dev/null || echo x)" 2>/dev/null; }

command_sweep() {
  [[ "${HM_AUTOFIX_AUTO:-0}" == "1" && -z "${HM_HARVEST_RUNNING:-}" ]] || return 0
  local repos="" row="" cand="" project="" repo="" file="" sig=""
  repos="$(monitored_repos)"
  [[ -n "$repos" ]] || return 0
  while IFS= read -r row; do verify_repo "$row"; done <<<"$repos"

  while IFS= read -r row; do
    project="$(jq -r '.project' <<<"$row")"; repo="$(jq -r '.repo' <<<"$row")"
    cand="$(candidates_for "$row" | head -n 1)"
    [[ -n "$cand" ]] || continue
    sig="$(jq -r '.signature' <<<"$cand")"
    # 상한·동시 실행 제한은 상태를 바꾸지 않는다 — 다음 sweep에서 같은 후보를 다시 고른다.
    (( $(started_today) < DAILY_MAX )) || { log_event "$project" skipped "$sig" '{"reason":"daily_max"}'; return 0; }
    lock_busy && { log_event "$project" skipped "$sig" '{"reason":"busy"}'; return 0; }
    # Codex 샌드박스는 .git이 읽기 전용이라 브랜치·커밋·PR까지 갈 수 없다.
    if [[ -z "${HM_AUTOFIX_CMD:-}" ]] && ! command -v claude >/dev/null 2>&1; then
      log_event "$project" skipped "$sig" '{"reason":"needs_claude"}'
      return 0
    fi
    mkdir -p "$AF_DIR/pending"
    file="$AF_DIR/pending/$(hm_short_key "$project")-$(date +%s).json"
    jq -c --argjson h "$(jq -r '.manifest.monitor.window_hours // 24' <<<"$row")" '. + {window_hours:$h}' <<<"$cand" >"$file"
    if [[ "${HM_AUTOFIX_FOREGROUND:-0}" == "1" ]]; then
      "$DIR/autofix-auto.sh" run "$project" "$repo" "$file"
    else
      nohup "$DIR/autofix-auto.sh" run "$project" "$repo" "$file" </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
    return 0
  done <<<"$repos"
}

# ── 수정 실행 ────────────────────────────────────────────────────────────────
# 무인 에이전트의 Bash는 프로젝트 빌드·테스트 명령과 좁은 git 명령만 허용한다(dontAsk: 그 밖은 묻지 않고 거부).
# 에러 본문은 외부 입력이라, 지시가 섞여 들어와도 임의 명령·네트워크 전송으로 이어지지 않게 한다.
# 테스트 러너는 저장소 코드를 실행하므로 이 경계가 완전하지는 않다 — 그래서 모니터링 자격증명은 에이전트 환경에서 뺀다.
BUILD_TOOLS=("./gradlew *" "gradle *" "./mvnw *" "mvn *" "npm test*" "npm run *" "pnpm test*" "pnpm run *" "yarn test*" "yarn run *"
  "go test*" "go build*" "go vet*" "pytest*" "python -m pytest*" "python3 -m pytest*" "uv run pytest*" "make test*" "make check*"
  "cargo test*" "cargo build*" "cargo check*" "bundle exec rspec*" "dotnet test*")
MONITOR_SECRETS=(SENTRY_AUTH_TOKEN HM_SENTRY_TOKEN DATADOG_API_KEY DATADOG_APP_KEY DD_API_KEY DD_APP_KEY HM_DATADOG_API_KEY HM_DATADOG_APP_KEY)

agent_command() { # $1=work_dir $2=base $3=error file(작업 트리 상대 경로)
  if [[ -n "${HM_AUTOFIX_CMD:-}" ]]; then
    read -r -a AGENT_CMD <<<"$HM_AUTOFIX_CMD"
    AGENT_CMD+=("$3")
    return
  fi
  local tool="" extra="" name="" scrub="{}"
  local -a bash_allow=() unset_env=()
  for tool in "${BUILD_TOOLS[@]}"; do bash_allow+=("Bash($tool)"); done
  # 프로젝트 고유 검증 명령은 config의 HM_AUTOFIX_BASH_ALLOW(세미콜론 구분 패턴, 예: "./scripts/ci.sh*")로 더한다.
  while IFS= read -r extra; do [[ -n "$extra" ]] && bash_allow+=("Bash($extra)"); done < <(printf '%s' "${HM_AUTOFIX_BASH_ALLOW:-}" | tr ';' '\n')
  for name in "${MONITOR_SECRETS[@]}"; do unset_env+=(-u "$name"); done
  # Claude Code는 settings.json env를 도구 프로세스에 넣는다. 같은 키를 빈 값으로 덮어 에이전트 쪽에서는 비운다.
  scrub="$(printf '%s\n' "${MONITOR_SECRETS[@]}" | jq -Rsc 'split("\n") | map(select(. != "")) | {env: (map({(.): ""}) | add)}')"
  AGENT_ENV=(env "${unset_env[@]}")
  AGENT_CMD=(claude -p "/ai-harness:autofix --auto --base $2 --error $3"
    --plugin-dir "$ROOT" --no-session-persistence
    --settings "$scrub"
    --permission-mode dontAsk
    --allowedTools "Read" "Grep" "Glob" "Edit" "Write" "Agent"
    "${bash_allow[@]}"
    "Bash(git status*)" "Bash(git diff*)" "Bash(git log*)" "Bash(git show*)" "Bash(git add *)"
    "Bash(git commit *)" "Bash(git switch -c *)" "Bash(git checkout -b *)" "Bash(git rev-parse*)" "Bash(git branch --show-current*)"
    "Bash(git push -u origin fix/*)" "Bash(git push origin fix/*)" "Bash(git push origin --delete fix/*)"
    "Bash(jq *)" "Bash($ROOT/scripts/open-pr.sh*)"
    --disallowedTools "Edit(/$HM_DATA_DIR/**)" "Write(/$HM_DATA_DIR/**)" "Read(/$HM_DATA_DIR/config)"
    "Read(~/.claude/settings.json)" "Read(~/.claude/settings.local.json)" "Read(~/.claude.json)" "Read(~/.ssh/**)" "Read(~/.config/gh/**)"
    --max-budget-usd "$BUDGET_USD"
    --output-format json)
}

# PR URL이 이 저장소 origin의 PR인지(owner/repo 일치). 무관한 PR의 병합으로 해결 판정이 나지 않게 한다.
pr_belongs_to() { # $1=repo $2=url
  local remote="" slug=""
  remote="$(git -C "$1" config --get remote.origin.url 2>/dev/null)" || return 1
  slug="${remote%.git}"; slug="${slug%/}"
  case "$slug" in
    git@*:*) slug="${slug#*:}" ;;
    *://*) slug="${slug#*://}"; slug="${slug#*/}" ;;
    *) return 1 ;;
  esac
  [[ -n "$slug" ]] || return 1
  case "$2" in
    https://github.com/"$slug"/pull/[0-9]*|https://bitbucket.org/"$slug"/pull-requests/[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

prune_logs() {
  local logs=() i
  shopt -s nullglob; logs=("$LOG_DIR"/*.log); shopt -u nullglob
  (( ${#logs[@]} > LOG_KEEP )) || return 0
  for (( i = 0; i < ${#logs[@]} - LOG_KEEP; i++ )); do find "${logs[$i]}" -maxdepth 0 -type f -delete; done
}

command_run() {
  local project="$1" repo="$2" cand_file="$3" cand="" sig="" base="" work_dir="" log_file="" exit_code=0
  local start_epoch=0 detail="{}" rel=".ai-harness-stage/autofix/error.json" line="" outcome="" artifact="" cost="null" fail_reason=""
  cand="$(jq -c . "$cand_file" 2>/dev/null)" || { echo "후보 파일을 읽을 수 없습니다: $cand_file" >&2; return 2; }
  find "$cand_file" -delete 2>/dev/null
  sig="$(jq -r '.signature' <<<"$cand")"
  mkdir -p "$LOG_DIR" "${RUN_LOCK%/*}"
  hm_acquire_lock "$RUN_LOCK" 1 || { log_event "$project" skipped "$sig" '{"reason":"busy"}'; return 0; }
  trap 'hm_release_lock "$RUN_LOCK"' EXIT

  start_epoch="$(date +%s)"
  log_file="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$(hm_short_key "$project").log"
  set_sig "$project" "$sig" '{status:"attempting",launched_at:$now,title:$c.title,provider:$c.provider,meta:$c.meta,link:$c.link,
      attempts:(($cur.attempts // 0) + 1),first_detected_at:($cur.first_detected_at // $now),
      fails:(if $cur.status == "attempting" then ($cur.fails // 0) + 1 else ($cur.fails // 0) end),
      baseline:{count:$c.count,window_hours:($c.window_hours // 24)}}' --argjson c "$cand"
  log_event "$project" started "$sig" "$(jq -cn --arg r "$(jq -r '.reason' <<<"$cand")" --arg log "$log_file" '{reason:$r,log:$log}')"

  base="$(hm_resolve_base "$repo")"
  work_dir="$WORK_TREES_DIR/autofix-$(hm_short_key "$project")-$(date +%s)"
  mkdir -p "$WORK_TREES_DIR"
  if ! git -C "$repo" worktree add -q --detach "$work_dir" "$base" >/dev/null 2>&1; then
    printf 'worktree 생성 실패: %s (%s)\n' "$repo" "$base" >"$log_file"
    exit_code=70
  else
    detail="$("$DIR/monitor-fetch.sh" detail --root "$repo" --meta "$(jq -c '.meta // {}' <<<"$cand")" 2>/dev/null)"
    jq -e 'type == "object"' <<<"$detail" >/dev/null 2>&1 || detail="{}"
    mkdir -p "$work_dir/${rel%/*}"
    # 지난 시도(PR·재발 기록)를 같이 넘긴다 — 재발한 에러는 같은 수정을 반복하지 않고 원인을 다시 본다.
    jq -n --argjson c "$cand" --argjson d "$detail" --argjson r "$(state_get "$project" | jq -c --arg s "$sig" '.signatures[$s] // {}')" \
      '$c + {detail:$d, previous:{attempts:($r.attempts // 1), prs:([$r.pr // empty] + [($r.regressions // [])[].pr // empty] | unique),
        regressions:($r.regressions // [])}}' >"$work_dir/$rel"
    AGENT_ENV=(env)
    agent_command "$work_dir" "${base#origin/}" "$rel"
    (cd "$work_dir" && hm_run_with_timeout "$((TIMEOUT_MIN * 60))" \
      "${AGENT_ENV[@]}" HM_HARVEST_RUNNING=1 HM_INTERNAL_SESSION=1 "${AGENT_CMD[@]}") </dev/null >"$log_file" 2>&1 || exit_code=$?
    git -C "$repo" worktree remove --force "$work_dir" >/dev/null 2>&1 || find "$work_dir" -depth -delete 2>/dev/null || true
  fi

  cost="$(jq -Rn '[inputs | fromjson? | objects | .total_cost_usd? // empty] | last // null' "$log_file" 2>/dev/null || printf 'null')"
  fail_reason="$(jq -Rrn '[inputs | fromjson? | objects | select(.type=="result")] | last
    | if . == null then empty elif .api_error == "usage_limit_reached" or .api_error_status == 429 then "usage_limit"
      elif .is_error == true then (.api_error // "agent_error") else empty end' "$log_file" 2>/dev/null || true)"
  # 스킬은 마지막에 `AI_HARNESS_AUTOFIX_RESULT outcome=<결과> artifact=<PR URL>` 한 줄을 남긴다.
  # 에러 본문에 심긴 같은 문구에 속지 않게 에이전트의 최종 응답에서만 읽는다(사용자 정의 실행기는 마지막 줄).
  line="$({ jq -Rrn '[inputs | fromjson? | objects | select(.type=="result") | .result // empty] | last // empty' "$log_file" 2>/dev/null
      [[ -n "${HM_AUTOFIX_CMD:-}" ]] && tail -n 1 "$log_file"; } \
    | grep -o 'AI_HARNESS_AUTOFIX_RESULT outcome=[a-z_-]*\( artifact=[^[:space:]"]*\)\{0,1\}' | tail -n 1)"
  outcome="$(sed -n 's/.*outcome=\([a-z_-]*\).*/\1/p' <<<"$line")"
  artifact="$(sed -n 's/.* artifact=\([^[:space:]"]*\).*/\1/p' <<<"$line")"

  if (( exit_code != 0 )) || [[ -z "$outcome" && -n "$fail_reason" ]]; then
    # 사용량 한도는 시도·실패로 세지 않는다.
    if [[ "$fail_reason" == "usage_limit" ]]; then
      set_sig "$project" "$sig" '{status:"failed",attempts:(($cur.attempts // 1) - 1)}'
    else
      set_sig "$project" "$sig" '{status:"failed",fails:(($cur.fails // 0) + 1),attempts:(($cur.attempts // 1) - 1)}'
    fi
    outcome="failed"
  else
    case "$outcome" in
      pr_opened)
        if [[ "$artifact" =~ ^https:// ]] && pr_belongs_to "$repo" "$artifact"; then
          set_sig "$project" "$sig" '{status:"pr_open",pr:$u,pr_opened_at:$now,fails:0}' --arg u "$artifact"
        else
          set_sig "$project" "$sig" '{status:"failed",fails:(($cur.fails // 0) + 1),attempts:(($cur.attempts // 1) - 1)}'
          outcome="failed"; fail_reason="missing_pr_url"
        fi
        ;;
      not_code_bug|not_reproducible|left_for_user)
        set_sig "$project" "$sig" '{status:"skipped",skipped_at:$now,outcome:$o,attempts:(($cur.attempts // 1) - 1)}' --arg o "$outcome"
        ;;
      *)
        set_sig "$project" "$sig" '{status:"skipped",skipped_at:$now,outcome:"no_result",attempts:(($cur.attempts // 1) - 1)}'
        outcome="no_result"
        ;;
    esac
  fi
  log_event "$project" finished "$sig" "$(jq -cn --arg o "$outcome" --arg a "$artifact" --argjson e "$exit_code" \
    --argjson d "$(( $(date +%s) - start_epoch ))" --argjson cost "${cost:-null}" --arg r "$fail_reason" --arg log "$log_file" \
    '{outcome:$o,exit_code:$e,duration_s:$d,cost_usd:$cost,log:$log} + (if $a == "" then {} else {artifact:$a} end)
      + (if $r == "" then {} else {reason:$r} end)')"
  if [[ "$outcome" == "failed" ]]; then
    "$DIR/health.sh" failure autofix_auto "${fail_reason:-exit_$exit_code}" >/dev/null 2>&1 || true
  else
    "$DIR/health.sh" success autofix_auto >/dev/null 2>&1 || true
  fi
  prune_logs
}

command_status() {
  local project="" files=()
  [[ "${1:-}" == "--project" ]] && project="${2:-}"
  if [[ -n "$project" ]]; then
    files=("$(state_file "$project")")
  else
    shopt -s nullglob; files=("$AF_DIR"/*/state.json); shopt -u nullglob
  fi
  (( ${#files[@]} > 0 )) || return 0
  jq -c '.project as $p | .signatures | to_entries[] | {project:$p, signature:.key} + (.value
    | {status, title, attempts, fails, pr, merged_at, deployed_at, verify_until, resolved_at, outcome,
       regressions:((.regressions // []) | length), updated_at})' "${files[@]}" 2>/dev/null
}

command_track() {
  local project="" cand="" pr=""
  while (( $# > 0 )); do
    case "$1" in
      --project) project="${2:-}"; shift 2 ;;
      --candidate) cand="${2:-}"; shift 2 ;;
      --pr) pr="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "$project" && "$pr" =~ ^https:// ]] || usage
  jq -e '.signature | type == "string"' <<<"$cand" >/dev/null 2>&1 || { echo "--candidate에 signature가 필요합니다" >&2; exit 2; }
  set_sig "$project" "$(jq -r '.signature' <<<"$cand")" '{status:"pr_open",pr:$u,pr_opened_at:$now,title:$c.title,provider:$c.provider,
      meta:($c.meta // {}),link:$c.link,attempts:(($cur.attempts // 0) + 1),first_detected_at:($cur.first_detected_at // $now),
      baseline:{count:($c.count // 0),window_hours:($c.window_hours // 24)},manual:true}' --arg u "$pr" --argjson c "$cand"
  log_event "$project" tracked "$(jq -r '.signature' <<<"$cand")" "$(jq -cn --arg u "$pr" '{artifact:$u}')"
}

command_runs() {
  local limit=20
  [[ "${1:-}" == "--limit" && "${2:-}" =~ ^[0-9]+$ ]] && limit="$2"
  [[ -f "$RUNS_FILE" ]] && tail -n "$limit" "$RUNS_FILE"
  return 0
}

command="${1:-}"
shift || true
case "$command" in
  sweep) command_sweep ;;
  verify) command_verify "$@" ;;
  candidates) command_candidates "$@" ;;
  status) command_status "$@" ;;
  track) command_track "$@" ;;
  run) [[ $# -eq 3 ]] || usage; command_run "$@" ;;
  runs) command_runs "$@" ;;
  *) usage ;;
esac
