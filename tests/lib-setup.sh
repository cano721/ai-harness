#!/usr/bin/env bash
# setup 영역(tests/setup*.sh)이 source하는 공용 준비: 카탈로그 스킬 이름과, 격리 환경으로 scripts/setup.sh를 부르는 함수.
# SETUP_T·SETUP_CATALOG는 블록마다 정한다. tests/lib.sh 다음에 source한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
CATALOG_NAMES="$(jq -r '.skills[].name' "$ROOT/catalog/catalog.json" | sort | paste -sd' ' -)"
# 카탈로그가 읽는 모든 자격 증명 키. 실행하는 셸에 값이 있으면(예: CONFLUENCE_BASE_URL) 결과가 바뀌므로 setup_cmd가 지운다(#629).
SETUP_UNSET=()
while IFS= read -r k; do SETUP_UNSET+=(-u "$k"); done < <(jq -r '[.skills[].env[]?.any[]?] | unique[]' "$ROOT/catalog/catalog.json")
setup_cmd() {
  # LANGFUSE_*·GA_PROPERTY_* 별칭 키(LANGFUSE_PUBLIC_KEY_<S>·GA_PROPERTY_<S>)는 이름을 고정할 수 없어 실행할 때마다 찾아 비운다(#621·#639).
  local k env_unset=("${SETUP_UNSET[@]}")
  for k in $(compgen -e | grep -E '^(LANGFUSE|GA_PROPERTY)_' || true); do env_unset+=(-u "$k"); done
  env "${env_unset[@]}" \
    HARNESS_METRICS_DIR="$SETUP_T/data" HM_SETUP_CATALOG_DIR="$SETUP_CATALOG" HARNESS_CLAUDE_SETTINGS="$SETUP_T/settings.json" \
    HM_CLAUDE_SKILLS_DIR="$SETUP_T/claude" HM_CODEX_SKILLS_DIR="$SETUP_T/codex" HM_SETUP_HINT=1 \
    "${SETUP_ENV[@]+"${SETUP_ENV[@]}"}" "$ROOT/scripts/setup.sh" "$@"
}
setup_status() { setup_cmd list | jq -r --arg n "$1" --arg t "$2" 'select(.name == $n) | .status[$t]'; }
SETUP_ENV=()
