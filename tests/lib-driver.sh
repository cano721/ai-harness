#!/usr/bin/env bash
# 그래프 러너 영역(tests/workflow*.sh)이 source하는 공용 준비: 러너 경로와, 가짜 CLI(tests/fixtures/driver)로 러너를 돌리는 함수.
# tests/lib.sh 다음에 source한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
FEATURE_GRAPH="$ROOT/templates/implement-feature/references/feature-delivery-graph.json"
FEATURE_SKILL="$ROOT/templates/implement-feature/SKILL.md"
DRIVER="$ROOT/templates/workflow-driver/workflow-driver.sh"
DRIVER_SHIM="$ROOT/templates/implement-feature/references/implement-feature-driver.sh"
DRIVER_TMP="$TEST_TMP/driver"
mkdir -p "$DRIVER_TMP"
driver() { # args... → DRIVER_RC, DRIVER_OUT
  DRIVER_RC=0
  DRIVER_DATA="${DRIVER_DATA_OVERRIDE:-$DRIVER_TMP/data}"
  mkdir -p "$DRIVER_DATA"
  DRIVER_OUT="$(HM_APPROVAL='' HM_APPROVAL_REPOS='' HARNESS_METRICS_DIR="$DRIVER_DATA" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" CLAUDE_CONFIG_DIR="$DRIVER_TMP/claude" CODEX_HOME="$DRIVER_TMP/codex" \
    FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO="$FAKE_SCENARIO" FAKE_CHECK="${FAKE_CHECK:-true}" PATH="$ROOT/tests/fixtures/driver:$PATH" \
    bash "$DRIVER" "$@" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
}
new_driver_repo() { # scenario → DRIVER_REPO, FAKE_LOG, FAKE_SCENARIO
  FAKE_SCENARIO="$1"
  DRIVER_REPO="$DRIVER_TMP/repo-$1"
  FAKE_LOG="$DRIVER_TMP/$1.log"
  mkdir -p "$DRIVER_TMP/data"
  : >"$DRIVER_TMP/data/config"
  mkdir -p "$DRIVER_REPO"
  git -C "$DRIVER_REPO" init -q
  git -C "$DRIVER_REPO" config user.email t@t
  git -C "$DRIVER_REPO" config user.name t
  git -C "$DRIVER_REPO" commit -q --allow-empty -m init
  DRIVER_REPO="$(git -C "$DRIVER_REPO" rev-parse --show-toplevel)"
  if [[ -n "${NEW_REPO_LINKED:-}" ]]; then # 병합 뒤 worktree 판정 테스트용: 작업 저장소를 링크된 worktree로 둔다(원본은 DRIVER_MAIN)
    DRIVER_MAIN="$DRIVER_REPO"
    git -C "$DRIVER_MAIN" worktree add -q -b "wt-$1" "$DRIVER_TMP/wt-$1"
    DRIVER_REPO="$(git -C "$DRIVER_TMP/wt-$1" rev-parse --show-toplevel)"
  fi
  : >"$FAKE_LOG"
}
run_state() { jq -r "$1" "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
say_in_claude() { # text [cwd] — Claude 트랜스크립트에 사용자 메시지를 남긴다
  mkdir -p "$DRIVER_TMP/claude/projects/p"
  jq -nc --arg c "${2:-$DRIVER_REPO}" --arg m "$1" '{type:"user", cwd:$c, timestamp:"2999-01-01T00:00:00.000Z", message:{role:"user", content:$m}}' \
    >>"$DRIVER_TMP/claude/projects/p/$FAKE_SCENARIO.jsonl"
}
start_and_approve() { # scenario [start args...]
  new_driver_repo "$1"
  shift
  driver start --runtime codex --request "add feature" "$@"
  [[ "$DRIVER_RC" == 10 ]] || return 0
  say_in_claude "승인"
  driver resume
}
with_policy() { # git_policy 개인 승인 모드 → 저장소 manifest와 개인 설정을 준비한다
  mkdir -p "$DRIVER_REPO/.ai-harness"
  jq -n --arg g "$1" --arg id "$(basename "$DRIVER_REPO")" '{project_id:$id, level:"standard", git_policy:$g}' >"$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m manifest
  git init -q --bare "$DRIVER_TMP/remote-$FAKE_SCENARIO.git"
  git -C "$DRIVER_REPO" remote add origin "$DRIVER_TMP/remote-$FAKE_SCENARIO.git"
  if [[ -n "$2" ]]; then printf 'HM_APPROVAL=%s\n' "$2" >"$DRIVER_TMP/data/config"; else : >"$DRIVER_TMP/data/config"; fi
}
as_host_repo() { # host/owner/repo → origin을 그 호스트 주소로 두고 실제 push는 bare 저장소로 보낸다(insteadOf)
  git -C "$DRIVER_REPO" config remote.origin.url "https://$1.git"
  git -C "$DRIVER_REPO" config "url.$DRIVER_TMP/remote-$FAKE_SCENARIO.git.insteadOf" "https://$1.git"
}
