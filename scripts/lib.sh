#!/usr/bin/env bash
# shellcheck disable=SC2034  # source되는 공용 변수
# 공용: 데이터 디렉토리·설정 결정. 스크립트는 플러그인에, 데이터는 홈에.
# 도구 중립 경로 — Claude/Codex 어느 쪽 사용자든 자기 도구 폴더 밖(~/.ai-harness)에 쌓인다.
umask 077
HM_EVENT_VERSION=2
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
# shellcheck source=/dev/null
[[ -f "$HM_DATA_DIR/config" ]] && source "$HM_DATA_DIR/config"

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

# worktree·하위 디렉토리에서도 같은 저장소는 하나의 프로젝트로 집계한다.
# 우선순위: harness 명시 ID → origin 저장소명 → git common-dir → 경로 휴리스틱.
project_id_for_cwd() {
  local cwd="${1:-}" root="" manifest="" project_id="" remote_url="" common_dir=""
  local leaf="" parent=""
  [[ -n "$cwd" ]] || return 0

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
        remote_url="${remote_url%/}"
        project_id="${remote_url##*/}"
        project_id="${project_id##*:}"
        project_id="${project_id%.git}"
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

  leaf="${cwd%/}"
  leaf="${leaf##*/}"
  parent="${cwd%/}"
  parent="${parent%/*}"
  parent="${parent##*/}"
  if [[ "$leaf" =~ ^(.+)-wt-[0-9]+$ ]]; then
    leaf="${BASH_REMATCH[1]}"
  elif [[ "$leaf" =~ ^(.+)-[A-Z]{2,}[0-9]*-[0-9]+$ ]]; then
    leaf="${BASH_REMATCH[1]}"
  elif [[ "$leaf" =~ ^[A-Z]{2,}[0-9]*-[0-9]+$ && -n "$parent" ]]; then
    leaf="$parent"
  fi
  printf '%s\n' "$leaf"
}
