#!/usr/bin/env bash
# 세션 1개 사용 리포트. 사용: session.sh [sid앞부분|latest]
# latest는 환경의 실제 session/thread ID를 우선하고, 없으면 현재 cwd와 같은 프로젝트에서 찾는다.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"
TARGET="${1:-latest}"
T=""
NEWEST_MTIME=0

all_transcripts() {
  if [[ -d "$HM_CLAUDE_PROJECTS_DIR" ]]; then
    find "$HM_CLAUDE_PROJECTS_DIR" -name '*.jsonl' -type f 2>/dev/null
  fi
  while IFS= read -r codex_root; do
    [[ -d "$codex_root" ]] || continue
    find "$codex_root" -name 'rollout-*.jsonl' -type f 2>/dev/null
  done < <(codex_session_roots)
}

consider() {
  local candidate="$1" candidate_mtime=""
  candidate_mtime="$(mtime "$candidate")"
  [[ -n "$candidate_mtime" ]] || return
  if (( candidate_mtime > NEWEST_MTIME )); then
    T="$candidate"
    NEWEST_MTIME="$candidate_mtime"
  fi
}

select_by_id() {
  local wanted="$1" candidate=""
  T=""
  NEWEST_MTIME=0
  while IFS= read -r candidate; do
    [[ "$(basename "$candidate")" == *"$wanted"* ]] && consider "$candidate"
  done < <(all_transcripts)
  [[ -n "$T" ]]
}

transcript_cwd() {
  local transcript="$1"
  if [[ "$(basename "$transcript")" == rollout-*.jsonl ]]; then
    jq -Rrn 'first(inputs | fromjson? | select(.type=="session_meta") | .payload.cwd // empty) // empty' \
      "$transcript" 2>/dev/null
  else
    jq -Rrn 'first(inputs | fromjson? | select(.cwd? != null) | .cwd) // empty' \
      "$transcript" 2>/dev/null
  fi
}

same_project_as_current() {
  local transcript="$1" candidate_cwd="" candidate_project="" current_project=""
  candidate_cwd="$(transcript_cwd "$transcript")"
  [[ -n "$candidate_cwd" ]] || return 1

  if [[ "$PWD" == "$candidate_cwd" || "$PWD" == "$candidate_cwd"/* || "$candidate_cwd" == "$PWD"/* ]]; then
    return 0
  fi

  current_project="$(project_id_for_cwd "$PWD")"
  candidate_project="$(project_id_for_cwd "$candidate_cwd")"
  [[ -n "$current_project" && "$current_project" == "$candidate_project" ]]
}

select_current_project() {
  local candidate=""
  T=""
  NEWEST_MTIME=0
  while IFS= read -r candidate; do
    same_project_as_current "$candidate" && consider "$candidate"
  done < <(all_transcripts)
  [[ -n "$T" ]]
}

if [[ "$TARGET" != "latest" ]]; then
  select_by_id "$TARGET" || {
    echo "세션을 찾을 수 없음: $TARGET" >&2
    exit 1
  }
elif [[ -n "${CODEX_THREAD_ID:-}" ]] && select_by_id "$CODEX_THREAD_ID"; then
  :
elif [[ -n "${CLAUDE_SESSION_ID:-}" ]] && select_by_id "$CLAUDE_SESSION_ID"; then
  :
elif select_current_project; then
  :
else
  echo "현재 세션을 식별할 수 없음: session/thread ID 또는 같은 프로젝트 transcript가 필요함" >&2
  exit 1
fi

if [[ "$(basename "$T")" == rollout-*.jsonl ]]; then
  "$DIR/extract-codex.sh" "$T" || { echo "추출 실패: $T" >&2; exit 1; }
  FILE_SID="$(basename "$T" .jsonl | sed 's/^rollout-//')"
  EV="$HM_DATA_DIR/events/codex-${FILE_SID}.jsonl"
else
  "$DIR/extract-claude.sh" "$T" || { echo "추출 실패: $T" >&2; exit 1; }
  FILE_SID="$(basename "$T" .jsonl)"
  EV="$HM_DATA_DIR/events/claude-${FILE_SID}.jsonl"
fi

jq -s -r '
  def table(k; title): map(select(.kind==k)) | sort_by(-.n)
    | if length==0 then ""
      else "\n## \(title)\n\n| 대상 | 횟수 |\n|---|---|\n" + (map("| \(.target) | \(.n) |") | join("\n")) + "\n" end;
  (map(select(.kind=="session")) | .[0]) as $s
  | ($s.coverage // []) as $coverage
  | "# 세션 리포트 — \($s.sid[0:8])\n"
  + "\n- 소스: \($s.src)"
  + "\n- 프로젝트: \($s.project) (\($s.cwd))"
  + "\n- 기간: \($s.started // "?") ~ \($s.ended // "진행 중")"
  + "\n- 턴: \($s.turns) · 모델: \($s.model // "?")"
  + (if $s.provider then " · provider: \($s.provider)" else "" end)
  + "\n- 토큰: in \($s.tok_in) / out \($s.tok_out) / cache read \($s.cache_read) / cache write \($s.cache_write // 0)"
  + "\n- 수집 지원: \(if ($coverage|length)==0 then "legacy event" else ($coverage|join(", ")) end)"
  + "\n- transcript: \($s.transcript)\n"
  + table("workflow"; "워크플로/커맨드")
  + table("persona"; "페르소나 위임")
  + table("doc_read"; "하네스 docs 읽힘")
  + table("file_edit"; "편집 파일")
  + table("bash_cmd"; "Bash 명령")
  + table("mcp_tool"; "MCP 툴")
  + table("jira_issue"; "이슈 언급")
  + (map(select(.kind=="error" or .kind=="guard_block" or .kind=="permission_deny" or .kind=="compact"))
     | if length==0 then "" else "\n## 신호\n\n" + (map("- \(.kind): \(.n)") | join("\n")) + "\n" end)
  + (map(select(.kind=="correction_mark"))
     | if length==0 then "" else "\n## 교정 마크\n\n" + (map("- \(.target)") | join("\n")) + "\n" end)
' "$EV"
