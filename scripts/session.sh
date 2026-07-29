#!/usr/bin/env bash
# 세션 1개 사용 리포트. 사용: session.sh [sid앞부분|latest]
# latest = 전체 transcript 중 mtime 최신 (= 호출한 현재 세션)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
TARGET="${1:-latest}"

# head가 먼저 닫혀 ls가 SIGPIPE(141)로 죽어도 pipefail이 스크립트를 못 죽이게 || true
if [[ "$TARGET" == "latest" ]]; then
  T="$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -1 || true)"
else
  T="$(ls -t "$HOME"/.claude/projects/*/*"$TARGET"*.jsonl 2>/dev/null | head -1 || true)"
fi
[[ -n "${T:-}" && -f "$T" ]] || { echo "세션을 찾을 수 없음: $TARGET" >&2; exit 1; }

"$DIR/extract-claude.sh" "$T" || { echo "추출 실패: $T" >&2; exit 1; }
SID="$(basename "$T" .jsonl)"
EV="$HM_DATA_DIR/events/claude-${SID}.jsonl"

jq -s -r '
  def table(k; title): map(select(.kind==k)) | sort_by(-.n)
    | if length==0 then ""
      else "\n## \(title)\n\n| 대상 | 횟수 |\n|---|---|\n" + (map("| \(.target) | \(.n) |") | join("\n")) + "\n" end;
  (map(select(.kind=="session")) | .[0]) as $s
  | "# 세션 리포트 — \($s.sid[0:8])\n"
  + "\n- 프로젝트: \($s.project) (\($s.cwd))"
  + "\n- 기간: \($s.started // "?") ~ \($s.ended // "진행 중")"
  + "\n- 턴: \($s.turns) · 모델: \($s.model // "?")"
  + "\n- 토큰: in \($s.tok_in) / out \($s.tok_out) / cache read \($s.cache_read) / cache write \($s.cache_write // 0)"
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
