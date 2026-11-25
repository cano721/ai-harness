#!/usr/bin/env bash
# 그래프 러너 feature 영역(tests/workflow-feature*.sh)이 source하는 공용 준비: 실행 디렉토리·Brief 이력 조회, 원격 CI 관문 시나리오 함수.
# tests/lib.sh·tests/lib-driver.sh 다음에 source한다. 단독 실행하지 않는다.
run_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
brief_history() { run_state '.history | map("\(.from) --\(if .outcome == "" then "next" else .outcome end)--> \(.to)") | join(";")'; }
GATE_LOG="$DRIVER_TMP/final-gate.log"
gate_repo() { # scenario git_policy(빈 값이면 manifest 없음) ci(yes면 CI 설정 파일을 커밋)
  new_driver_repo "$1"
  [[ -z "$2" ]] || with_policy "$2" ""
  if [[ "$3" == yes ]]; then
    mkdir -p "$DRIVER_REPO/.github/workflows"
    printf 'on: push\n' >"$DRIVER_REPO/.github/workflows/test.yml"
    git -C "$DRIVER_REPO" add .github && git -C "$DRIVER_REPO" commit -qm ci
  fi
  : >"$GATE_LOG"
}
gate_run() {
  FAKE_FINAL_CHECK="printf 'final\\n' >>'$GATE_LOG'" driver start --runtime codex --request "add feature"
  say_in_claude "승인"
  FAKE_FINAL_CHECK="printf 'final\\n' >>'$GATE_LOG'" driver resume
}
gradle_failure() { # test-name line → Gradle 테스트 실패 출력
  printf '%s() FAILED\n    org.opentest4j.AssertionFailedError at %s.java:%s\n\n3 tests completed, 1 failed\n\nFAILURE: Build failed with an exception.\n\n* What went wrong:\nExecution failed for task '"'"':test'"'"'.\n> There were failing tests. See the report at: file:///home/u/proj/build/reports/tests/test/index.html\n\nBUILD FAILED in 4s\n' "$1" "$1" "$2"
}
