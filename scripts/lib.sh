#!/usr/bin/env bash
# shellcheck disable=SC2034  # source되는 공용 변수
# 공용: 데이터 디렉토리·설정 결정. 스크립트는 플러그인에, 데이터는 홈에.
# 도구 중립 경로 — Claude/Codex 어느 쪽 사용자든 자기 도구 폴더 밖(~/.ai-harness)에 쌓인다.
umask 077
# v3 adds detailed Codex activity extraction; stale v2 Codex events must be
# re-extracted during backfill so their coverage metadata is refreshed.
HM_EVENT_VERSION=3
HM_DATA_DIR="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}"
HM_CLAUDE_PROJECTS_DIR="${HARNESS_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
# 구 경로 자동 마이그레이션 (구버전 순서대로)
if [[ ! -e "$HM_DATA_DIR" ]]; then
  for old in "$HOME/.claude/ai-harness" "$HOME/.claude/harness-metrics"; do
    [[ -d "$old" ]] && { mv "$old" "$HM_DATA_DIR"; break; }
  done
fi
mkdir -p "$HM_DATA_DIR/events"
chmod 700 "$HM_DATA_DIR" "$HM_DATA_DIR/events" 2>/dev/null || true

# 사용자 설정 (있으면 로드): HM_ISSUE_RE 등 override 가능
# 셸로 source하지 않고 HM_·HARNESS_ 변수의 KEY=VALUE만 읽는다. 이 파일이 바뀌어도(예: 자동 실행 중인
# 에이전트) 이후 모든 스크립트에서 임의 코드가 돌지 않게. 값은 따옴표로 감싸거나, 공백 전까지(줄 끝 # 주석 허용).
hm_load_config() {
  local file="$1" line="" key="" value="" re_quoted='^"([^"]*)"' re_single="^'([^']*)'"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?((HM|HARNESS)_[A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[4]}"
    if [[ "$value" =~ $re_quoted || "$value" =~ $re_single ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value="${value%%[[:space:]]*}"
    fi
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done <"$file"
}
hm_load_config "$HM_DATA_DIR/config"

# 이슈 트래커 키 패턴 (Jira 등). 필요 시 config에서 좁혀서 override (예: "(NJ|JDA|OP)-[0-9]+")
# 기본: 대문자 2자 이상 프리픽스 — 1자 허용 시 본문 속 정규식 텍스트([A-Z0-9]+ 등)를 오인함
# 주의: ${VAR:-기본값} 안에 {2,}를 넣으면 안의 `}`가 확장을 조기 종료시켜 패턴이 찢어진다 (실측) → if 할당
if [[ -z "${HM_ISSUE_RE:-}" ]]; then
  HM_ISSUE_RE='[A-Z]{2,}[0-9]*-[0-9]+'
fi

# OS 호환 헬퍼 (macOS=BSD / Linux=GNU)
# 순서 주의: GNU 먼저 — BSD에서 `stat -c`는 깨끗이 실패하지만, GNU에서 `stat -f %m`은
# exit 1이면서도 stdout에 파일시스템 정보를 뱉어 출력을 오염시킨다 (실측).
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
filesize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null; }
days_ago_iso() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%S; }
iso_to_epoch() {
  local value="${1:-}" normalized=""
  [[ -n "$value" ]] || return 0
  date -u -d "$value" +%s 2>/dev/null && return
  normalized="${value%%.*}"
  normalized="${normalized%Z}"
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$normalized" +%s 2>/dev/null || true
}

# 무인 실행(launchd·백그라운드)에서 git이 자격증명·passphrase 입력을 기다리며 lock을 쥔 채 멈추지 않게 한다.
export GIT_TERMINAL_PROMPT=0
[[ -n "${GIT_SSH_COMMAND:-}" ]] || export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=20"

# 명령을 최대 $1초만 실행한다(macOS에는 timeout이 없다). 시간이 지나면 TERM, 10초 뒤 KILL. 종료 코드를 돌려준다.
hm_run_with_timeout() {
  local secs="$1" pid=0 watchdog=0 rc=0
  shift
  "$@" &
  pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 10; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

# 하네스를 고칠 기준 브랜치. origin/HEAD가 하네스 없는 초기 브랜치(master)이고 실제 개발은 develop인
# 저장소가 많아서(실측 jobda-*), 하네스 파일이 실제로 들어 있는 브랜치를 고른다.
# 순서: harness.json의 base_branch → develop → origin/HEAD → main → master. origin이 없으면 HEAD.
hm_resolve_base() { # $1=repo_root [$2=--no-fetch] → "origin/<branch>" 또는 "HEAD"
  local repo_root="$1" candidate="" head="" configured=""
  git -C "$repo_root" remote get-url origin >/dev/null 2>&1 || { printf 'HEAD\n'; return; }
  # 응답 없는 원격이 무인 실행의 lock을 쥔 채 멈추지 않게 시간을 제한한다.
  [[ "${2:-}" == "--no-fetch" ]] || hm_run_with_timeout "${HM_FETCH_TIMEOUT_SEC:-60}" git -C "$repo_root" fetch -q origin >/dev/null 2>&1 || true
  configured="$(jq -r '.base_branch // empty' "$repo_root/.ai-harness/harness.json" 2>/dev/null)"
  # 저장소가 정한 값이 무인 에이전트의 지시문(--base)까지 가므로 브랜치 이름 형태만 받는다.
  [[ "$configured" =~ ^[A-Za-z0-9._/-]+$ && "$configured" != -* && "$configured" != *..* ]] || configured=""
  head="$(git -C "$repo_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  for candidate in ${configured:+"origin/$configured"} origin/develop ${head:+"$head"} origin/main origin/master; do
    if git -C "$repo_root" cat-file -e "$candidate:.ai-harness/harness.json" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  printf '%s\n' "${head:-HEAD}"
}

# 최근 $1분 안에 Claude·Codex 대화 기록이 갱신됐으면 사용자가 작업 중이다.
# 무인 실행 자신의 transcript(작업 worktree 경로 `…harvest-auto-worktrees…`)는 사용자 활동이 아니다.
hm_recently_active() { # $1=minutes
  local mins="${1:-20}" root=""
  [[ "$mins" =~ ^[0-9]+$ ]] || mins=20
  (( mins > 0 )) || return 1
  if [[ -n "$(find "$HM_CLAUDE_PROJECTS_DIR" -maxdepth 2 -name '*.jsonl' -mmin "-$mins" ! -path '*harvest-auto-worktrees*' -print -quit 2>/dev/null)" ]]; then
    return 0
  fi
  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    [[ -n "$(find "$root" -name 'rollout-*.jsonl' -mmin "-$mins" -print -quit 2>/dev/null)" ]] && return 0
  done < <(codex_session_roots)
  return 1
}

# 사용량 한도에 막힌 직후($1시간)에는 LLM 단계를 쉰다 — 사용자의 작업 한도를 같이 쓰기 때문이다.
hm_in_usage_backoff() { # $1=hours
  local hours="${1:-5}" runs="$HM_DATA_DIR/harvest-auto/runs.jsonl" since=""
  [[ "$hours" =~ ^[0-9]+$ ]] || hours=5
  (( hours > 0 )) || return 1
  [[ -f "$runs" ]] || return 1
  since="$(date -u -v-"${hours}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$hours hours ago" +%Y-%m-%dT%H:%M:%SZ)"
  jq -Rn -e --arg since "$since" '[inputs | fromjson? | select(.event=="finished" and .reason=="usage_limit" and .at >= $since)] | length > 0' "$runs" >/dev/null 2>&1
}

# MAJOR.MINOR.PATCH 비교(접두 v·pre-release 꼬리 무시). $1이 $2보다 낮으면 참.
hm_version_lt() {
  local a="${1#v}" b="${2#v}" i
  local -a pa pb
  IFS=. read -r -a pa <<<"${a%%[-+]*}"
  IFS=. read -r -a pb <<<"${b%%[-+]*}"
  for i in 0 1 2; do
    [[ "${pa[i]:-0}" =~ ^[0-9]+$ && "${pb[i]:-0}" =~ ^[0-9]+$ ]] || return 1
    (( 10#${pa[i]:-0} < 10#${pb[i]:-0} )) && return 0
    (( 10#${pa[i]:-0} > 10#${pb[i]:-0} )) && return 1
  done
  return 1
}

# 프로젝트 이름 → 파일시스템 안전 키. prefix가 '.', '..' 같은 인자의 경로 탈출을 막는다.
hm_project_key() {
  printf 'p-%s\n' "$(printf '%s' "$1" | jq -sRr '@uri')"
}

# 파일·폴더 이름용 짧은 키. 한글 프로젝트명은 퍼센트 인코딩으로 글자당 9바이트가 되어 255바이트 한도를 넘을 수 있다.
hm_short_key() { # $1=project
  local key=""
  key="$(hm_project_key "$1")"
  (( ${#key} <= 60 )) || key="${key:0:40}-$(printf '%s' "$key" | { shasum 2>/dev/null || sha1sum; } | cut -c1-12)"
  printf '%s\n' "$key"
}

# mkdir 원자성 기반 디렉토리 lock. 소유 pid가 죽었으면 stale로 회수한다.
hm_acquire_lock() { # $1=lock_dir $2=max_attempts(기본 50)
  local lock_dir="$1" max_attempts="${2:-50}" attempt=0 unowned_attempts=0 owner="" lock_mt=""
  while (( attempt < max_attempts )); do
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" >"$lock_dir/pid"
      return 0
    fi
    if [[ -f "$lock_dir/pid" ]]; then
      owner="$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)"
    else
      owner=""
    fi
    if [[ ! "$owner" =~ ^[0-9]+$ ]]; then
      # mkdir 직후 pid 파일을 쓰기 전인 정상 소유자를 stale lock으로 오인하지 않는다. 저우선순위(nice)
      # 실행에서는 pid 기록이 늦을 수 있어, pid 없는 lock은 5초 넘게 지났을 때만 버려진 것으로 본다.
      unowned_attempts=$((unowned_attempts + 1))
      lock_mt="$(mtime "$lock_dir" 2>/dev/null || echo 0)"
      if (( unowned_attempts >= 5 )) && [[ "$lock_mt" =~ ^[0-9]+$ ]] && (( $(date +%s) - lock_mt > 5 )); then
        find "$lock_dir" -depth -delete 2>/dev/null || true
        unowned_attempts=0
      else
        sleep 0.02
        attempt=$((attempt + 1))
      fi
      continue
    fi
    unowned_attempts=0
    if ! kill -0 "$owner" 2>/dev/null; then
      find "$lock_dir" -depth -delete 2>/dev/null || true
      continue
    fi
    sleep 0.02
    attempt=$((attempt + 1))
  done
  return 1
}

hm_release_lock() {
  find "$1" -depth -delete 2>/dev/null || true
}

# Codex는 실행 환경에 따라 CODEX_HOME과 ~/.codex 양쪽에 세션을 둘 수 있다.
# 테스트/특수 환경은 HARNESS_CODEX_SESSIONS_DIR로 단일 루트를 명시한다.
codex_session_roots() {
  if [[ -n "${HARNESS_CODEX_SESSIONS_DIR:-}" ]]; then
    printf '%s\n' "$HARNESS_CODEX_SESSIONS_DIR"
    return
  fi

  if [[ -n "${CODEX_HOME:-}" && -d "$CODEX_HOME/sessions" ]]; then
    printf '%s\n' "$CODEX_HOME/sessions"
  fi
  if [[ -d "$HOME/.codex/sessions" && "${CODEX_HOME:-}/sessions" != "$HOME/.codex/sessions" ]]; then
    printf '%s\n' "$HOME/.codex/sessions"
  fi
}

# macOS 파일명은 NFD로 올 수 있어 같은 한글 이름이 NFC와 다른 프로젝트 키로 갈라진다.
hm_nfc() {
  local value="$1" LC_ALL=C
  if [[ "$value" == *[$'\x80'-$'\xff']* ]] && command -v perl >/dev/null 2>&1; then
    perl -CSA -MUnicode::Normalize -e 'print NFC($ARGV[0])' "$value" 2>/dev/null && return
  fi
  printf '%s' "$value"
}

repo_name_from_url() {
  local url="${1%/}" name=""
  name="${url##*/}"
  name="${name##*:}"
  printf '%s' "${name%.git}"
}

# worktree·하위 디렉토리에서도 같은 저장소는 하나의 프로젝트로 집계한다.
# 우선순위: harness 명시 ID → origin 저장소명 → git common-dir → 기록된 저장소 URL → 경로 휴리스틱.
# $2(선택): transcript가 기록한 저장소 URL. 삭제된 worktree처럼 cwd를 더 볼 수 없을 때 쓴다.
project_id_for_cwd() {
  local project_id=""
  project_id="$(project_id_for_cwd_raw "$@")"
  [[ -n "$project_id" ]] || return 0
  printf '%s\n' "$(hm_nfc "$project_id")"
}

project_id_for_cwd_raw() {
  local cwd="${1:-}" recorded_url="${2:-}" root="" manifest="" project_id="" remote_url="" common_dir=""
  local leaf="" parent="" key_re='[A-Z]{2,}[0-9]*-[0-9]+'
  [[ -n "$cwd" ]] || return 0

  # workspace 루트(여러 저장소를 담는 폴더)는 git 저장소가 아니므로 git 판정보다 먼저 본다.
  if [[ -f "$cwd/.ai-harness/workspace.json" ]]; then
    project_id="$(jq -r '.workspace_id // empty' "$cwd/.ai-harness/workspace.json" 2>/dev/null || true)"
    if [[ -n "$project_id" ]]; then
      printf '%s\n' "$project_id"
      return
    fi
  fi

  if [[ -d "$cwd" ]]; then
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$root" ]]; then
      manifest="$root/.ai-harness/harness.json"
      if [[ -f "$manifest" ]]; then
        project_id="$(jq -r '.project_id // empty' "$manifest" 2>/dev/null || true)"
        if [[ -n "$project_id" ]]; then
          printf '%s\n' "$project_id"
          return
        fi
      fi

      remote_url="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
      if [[ -n "$remote_url" ]]; then
        project_id="$(repo_name_from_url "$remote_url")"
        if [[ -n "$project_id" ]]; then
          printf '%s\n' "$project_id"
          return
        fi
      fi

      common_dir="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
      if [[ -n "$common_dir" && "${common_dir##*/}" == ".git" ]]; then
        project_id="${common_dir%/.git}"
        project_id="${project_id##*/}"
        if [[ -n "$project_id" ]]; then
          printf '%s\n' "$project_id"
          return
        fi
      fi

      project_id="${root##*/}"
      if [[ -n "$project_id" ]]; then
        printf '%s\n' "$project_id"
        return
      fi
    fi
  fi

  if [[ -n "$recorded_url" ]]; then
    project_id="$(repo_name_from_url "$recorded_url")"
    if [[ -n "$project_id" ]]; then
      printf '%s\n' "$project_id"
      return
    fi
  fi

  leaf="${cwd%/}"
  leaf="${leaf##*/}"
  parent="${cwd%/}"
  parent="${parent%/*}"
  parent="${parent##*/}"
  # 이슈별 worktree 컨테이너 이름은 저장소명이 아니다.
  [[ "$parent" =~ ^(worktrees|workspaces|tmp)$ ]] && parent=""
  if [[ "$leaf" =~ ^(.+)-wt-[0-9]+$ ]]; then
    leaf="${BASH_REMATCH[1]}"
  elif [[ "$leaf" =~ ^(feature|feat|fix|bugfix|hotfix|chore|refactor|release|docs|test)-${key_re}(-.*)?$ && -n "$parent" ]]; then
    # <repo>/feature-NJ-612: 브랜치 유형 접두어는 저장소명이 아니다.
    leaf="$parent"
  elif [[ "$leaf" =~ ^(.+)-${key_re}$ ]]; then
    leaf="${BASH_REMATCH[1]}"
  elif [[ "$leaf" =~ ^${key_re}(-.+)?$ && -n "$parent" ]]; then
    # <repo>/NJ-290, <repo>/NJ-1866-embedding
    leaf="$parent"
  fi
  printf '%s\n' "$leaf"
}

# workspace 멤버를 절대경로로 돌려준다. workspace가 아니면 빈 배열.
# 계측이 편집 경로를 멤버 project_id로 귀속할 때 prefix 매칭에 쓴다.
workspace_members_for_cwd() {
  local cwd="${1:-}" manifest=""
  cwd="${cwd%/}"
  manifest="$cwd/.ai-harness/workspace.json"
  if [[ -z "$cwd" || ! -f "$manifest" ]]; then
    printf '[]\n'
    return 0
  fi
  jq -c --arg root "$cwd" '[.members[]? | {path: ($root + "/" + .path), project_id}]' "$manifest" 2>/dev/null \
    || printf '[]\n'
}
