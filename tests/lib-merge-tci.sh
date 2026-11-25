#!/usr/bin/env bash
# 그래프 러너 merge 노드 target_ci 영역(tests/workflow-merge-tci*.sh)이 source하는 공용 준비: 병합 뒤 target_ci(HM_TARGET_CI) 시나리오 함수.
# tests/lib.sh·tests/lib-driver.sh·tests/lib-merge.sh 다음에 source한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
export FAKE_PROTECTION=classic HM_DESKTOP_NOTIFY=0
NOTIFY_BIN="$DRIVER_TMP/notify-bin"
NOTIFY_LOG="$DRIVER_TMP/notify.log"
mkdir -p "$NOTIFY_BIN"
for notifier in osascript notify-send; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >>%q\n' "$notifier" "$NOTIFY_LOG" >"$NOTIFY_BIN/$notifier"
  chmod +x "$NOTIFY_BIN/$notifier"
done
tci_run() { # scenario [config-line] → 단계 merge, target_ci만 검증하는 런
  new_driver_repo "$1"
  with_policy pr-only auto
  as_host_repo github.com/acme/app
  jq '.merge_policy = {"verify":["target_ci"],"base":"main"}' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" \
    && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  printf 'HM_APPROVAL=auto\nHM_DELIVERY_LEVEL=merge\n%s\n' "${2:-}" >"$MR_DATA/config"
  DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "add feature"
}
tci_dir() { dirname "$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"; }
