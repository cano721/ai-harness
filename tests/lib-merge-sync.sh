#!/usr/bin/env bash
# sync_base 영역(tests/workflow-merge-sync*.sh)이 source하는 공용 준비: 병합 단계 config, sync_repo·base_commit·sync_start 등 헬퍼.
# tests/lib.sh·tests/lib-driver.sh 다음에 source한다. 단독 실행하지 않는다.
# shellcheck disable=SC2034  # 여기서 정한 값은 영역 파일이 쓴다
# 병합 단계 사용자(HM_DELIVERY_LEVEL=merge), 승인 auto, 호스트 보호는 승인 1·체크 1(classic).
export HM_SMOKE_RETRY_SECONDS=0 FAKE_PROTECTION=classic
SY_DATA="$DRIVER_TMP/sync-data"
mkdir -p "$SY_DATA"
printf 'HM_APPROVAL=auto\nHM_DELIVERY_LEVEL=merge\n' >"$SY_DATA/config"
sync_repo() { # scenario → 병합 정책이 있는 저장소. 원격 main은 작업 시작 커밋이다.
  new_driver_repo "$1"
  with_policy pr-only auto
  as_host_repo github.com/acme/app
  jq '.merge_policy = {"verify":["target_ci"],"base":"main"}' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" \
    && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/main
}
sy_remote() { printf '%s' "$DRIVER_TMP/remote-$FAKE_SCENARIO.git"; }
base_commit() { # file content → 원격 main에만 커밋 하나를 더한다(작업 브랜치에는 없다)
  local clone="$DRIVER_TMP/base-$FAKE_SCENARIO"
  rm -rf "$clone"
  git clone -q -b main "$(sy_remote)" "$clone"
  git -C "$clone" config user.email t@t
  git -C "$clone" config user.name t
  printf '%s\n' "$2" >"$clone/$1"
  git -C "$clone" add "$1"
  git -C "$clone" commit -qm "base: $1"
  git -C "$clone" push -q origin HEAD:refs/heads/main
}
sync_start() { # [workflow]
  DRIVER_DATA_OVERRIDE="$SY_DATA" HARNESS_METRICS_DIR="$SY_DATA" driver start --workflow "${1:-feature}" --runtime codex --request "add feature"
}
remote_head() { git --git-dir "$(sy_remote)" rev-parse "refs/heads/feat/add-feature${1:-}" 2>/dev/null || true; }
sync_path() { run_state '[.history[] | select(.from | IN("remote_ci", "merge", "sync_base", "post_merge_verify")) | .from] | join(",")'; }
