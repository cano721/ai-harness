# 공용: 데이터 디렉토리 결정. 스크립트는 플러그인에, 데이터는 홈에.
HM_DATA_DIR="${HARNESS_METRICS_DIR:-$HOME/.claude/harness-metrics}"
mkdir -p "$HM_DATA_DIR/events"
