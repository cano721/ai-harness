# 공용: 데이터 디렉토리·설정 결정. 스크립트는 플러그인에, 데이터는 홈에.
HM_DATA_DIR="${HARNESS_METRICS_DIR:-$HOME/.claude/ai-harness}"
# 구 경로(~/.claude/harness-metrics) 자동 마이그레이션
if [[ ! -e "$HM_DATA_DIR" && -d "$HOME/.claude/harness-metrics" ]]; then
  mv "$HOME/.claude/harness-metrics" "$HM_DATA_DIR"
fi
mkdir -p "$HM_DATA_DIR/events"

# 사용자 설정 (있으면 로드): HM_ISSUE_RE 등 override 가능
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
days_ago_iso() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%S; }
