# 공용: 데이터 디렉토리·설정 결정. 스크립트는 플러그인에, 데이터는 홈에.
HM_DATA_DIR="${HARNESS_METRICS_DIR:-$HOME/.claude/harness-metrics}"
mkdir -p "$HM_DATA_DIR/events"

# 사용자 설정 (있으면 로드): HM_ISSUE_RE 등 override 가능
[[ -f "$HM_DATA_DIR/config" ]] && source "$HM_DATA_DIR/config"

# 이슈 트래커 키 패턴 (Jira 등). 필요 시 config에서 좁혀서 override (예: "(NJ|JDA|OP)-[0-9]+")
# 기본: 대문자 2자 이상 프리픽스 — 1자 허용 시 본문 속 정규식 텍스트([A-Z0-9]+ 등)를 오인함
HM_ISSUE_RE="${HM_ISSUE_RE:-[A-Z]{2,}[0-9]*-[0-9]+}"
