#!/usr/bin/env bash
# 그래프 러너 merge 노드 영역(tests/workflow-merge*.sh)이 source하는 공용 준비: 병합 시나리오를 돌리는 함수.
# tests/lib.sh·tests/lib-driver.sh 다음에 source한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
export HM_SMOKE_RETRY_SECONDS=0
MR_DATA="$DRIVER_TMP/merge-data"
mkdir -p "$MR_DATA"
merge_config() { # merge-settings-json → 개인 config: 검증에 배포·스모크·재발 추적이 있으면 단계 deploy, 아니면 merge
  jq -r '"HM_APPROVAL=auto", "HM_DELIVERY_LEVEL=" + (if (.verify // []) | any(IN("deploy", "smoke", "monitor")) then "deploy" else "merge" end)' <<<"$1" >"$MR_DATA/config"
}
merge_run() { # scenario merge-settings-json [host/owner/repo] → 저장소 사실은 manifest에, 단계는 개인 config에 두고 approval auto로 실행한다
  new_driver_repo "$1"
  with_policy pr-only auto
  as_host_repo "${3:-github.com/acme/app}"
  jq --argjson m "$2" '.merge_policy = ($m | del(.require, .min_approvals, .method))' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" \
    && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  merge_config "$2"
  cp "$MR_DATA/config" "$DRIVER_TMP/data/config"
  DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime "${MERGE_RUNTIME:-codex}" --request "add feature"
}
MP_BASIC='{"verify":["target_ci"],"base":"main"}'
wtc_progress() { # 현재 시나리오 러너 실행의 progress.log
  cat "$(dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)")/progress.log"
}
