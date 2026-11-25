#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 모니터링 재발 확인·merge 노드 없는 옛 그래프
# 실행: bash tests/run.sh workflow-merge-monitor
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
# 모니터링 재발 확인: 관찰 창이 길어 러너는 고친 에러를 /autofix 추적에 올리는 데까지 한다.
monitor_run() { # scenario [--monitor-error 파일] → monitor 설정·project_id가 있는 저장소에서 단계 deploy·verify monitor로 실행한다
  local scenario="$1"
  shift
  new_driver_repo "$scenario"
  with_policy pr-only auto
  as_host_repo github.com/acme/app
  jq --arg local "${MONITOR_LOCAL:-}" '.project_id = "acme-app" | .monitor = {provider: "command", command: "bin/errors", window_hours: 168}
    | .merge_policy = {verify: ["monitor", "target_ci"], base: "main"} | if $local == "1" then del(.monitor) else . end' \
    "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam "repository facts"
  merge_config '{"verify":["monitor"]}'
  cp "$MR_DATA/config" "$DRIVER_TMP/data/config"
  DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "fix the crash" "$@"
}
mkdir -p "$DRIVER_TMP/plugin/scripts"
cat >"$DRIVER_TMP/plugin/scripts/autofix-auto.sh" <<'EOF'
printf 'autofix %s\n' "$*" >>"$FAKE_LOG"
[[ "$FAKE_SCENARIO" != pm_monitor_fail ]] || { echo "state lock failed" >&2; exit 1; }
EOF
printf '%s\n' '{"signature":"sig-42","title":"NullPointerException in Checkout","count":12,"meta":{"id":"42"}}' >"$DRIVER_TMP/monitor-error.json"
export HM_PLUGIN_ROOT="$DRIVER_TMP/plugin"
monitor_run pm_monitor --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "the monitor step finishes the run once the error is tracked"
assert_contains "$(<"$FAKE_LOG")" "autofix track --project acme-app --candidate {\"window_hours\":168,\"signature\":\"sig-42\"" "the fixed error is registered with /autofix, with the manifest's observation window"
assert_contains "$(<"$FAKE_LOG")" "--pr https://github.com/acme/app/pull/7" "the tracked pull request is the merged one"
assert_eq "target_ci,monitor" "$(run_state '.post_merge | keys_unsorted | join(",")')" "post-merge checks run in the fixed order whatever order the manifest lists"
assert_contains "$DRIVER_OUT" "monitor tracked (recurrence of sig-42 is handed to /autofix" "done says the recurrence check continues in /autofix"
monitor_run pm_monitor_none
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^autofix ' "$FAKE_LOG" || true)" "a run without a monitoring error has nothing to track"
assert_contains "$DRIVER_OUT" "monitor skipped (no monitoring error was given" "the skip is reported, not hidden"
monitor_run pm_monitor_fail --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a failed registration goes to a person"
assert_contains "$(run_state '.findings[1]')" "register the error by hand: <ai-harness plugin>/scripts/autofix-auto.sh track --project acme-app --candidate" "the person gets the track command, not rollback advice"
# 개인 로컬 monitor 설정(~/.ai-harness/autofix/monitors/<project_id>.json)만 있어도 시작하고, 그 관찰 창을 쓴다.
mkdir -p "$MR_DATA/autofix/monitors"
printf '%s\n' '{"provider":"command","command":"bin/errors","window_hours":48}' >"$MR_DATA/autofix/monitors/acme-app.json"
MONITOR_LOCAL=1 monitor_run pm_monitor_local --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a local monitor file satisfies verify monitor"
assert_contains "$(<"$FAKE_LOG")" "autofix track --project acme-app --candidate {\"window_hours\":48," "the local file's observation window is used"
printf 'not json\n' >"$MR_DATA/autofix/monitors/acme-app.json"
monitor_run pm_monitor_local_bad --monitor-error "$DRIVER_TMP/monitor-error.json"
assert_eq "2" "$DRIVER_RC" "a broken local monitor file does not start, even with a manifest monitor"
assert_contains "$DRIVER_OUT" "autofix/monitors/acme-app.json" "the error names the broken local file"
find "$MR_DATA/autofix/monitors/acme-app.json" -delete
unset HM_PLUGIN_ROOT
printf '%s\n' '{"title":"no signature"}' >"$DRIVER_TMP/bad-error.json"
monitor_run pm_monitor_bad --monitor-error "$DRIVER_TMP/bad-error.json"
assert_eq "2" "$DRIVER_RC" "a monitoring error without a signature does not start"
cat "$DRIVER_TMP/monitor-error.json" "$DRIVER_TMP/monitor-error.json" >"$DRIVER_TMP/two-errors.json"
monitor_run pm_monitor_two --monitor-error "$DRIVER_TMP/two-errors.json"
assert_eq "2:no run" "$DRIVER_RC:$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*" -name state.json | grep -q . && echo run || echo "no run")" "several monitoring errors in one file are refused before a run is created"
merge_run pm_monitor_noconfig '{"verify":["monitor"],"base":"main"}'
assert_eq "2" "$DRIVER_RC" "verify monitor without the monitor settings does not start"
assert_contains "$DRIVER_OUT" "needs the monitor settings (/autofix setup)" "the error points at /autofix setup"
# merge 노드가 없는 옛 그래프는 병합하지 않고 PR까지로 끝낸다.
new_driver_repo merge_oldgraph
with_policy pr-only auto
as_host_repo github.com/acme/app
jq '.merge_policy = {base: "main"}' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/m.json" && mv "$DRIVER_REPO/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
mkdir -p "$DRIVER_REPO/.ai-harness/workflows"
jq 'del(.nodes.merge, .nodes.post_merge_verify) | .transitions |= map(select(.from != "merge" and .from != "post_merge_verify" and .to != "merge"))' \
  "$FEATURE_GRAPH" >"$DRIVER_REPO/.ai-harness/workflows/feature-delivery-graph.json"
git -C "$DRIVER_REPO" add -A && git -C "$DRIVER_REPO" commit -qm "old graph"
merge_config "$MP_BASIC"
cp "$MR_DATA/config" "$DRIVER_TMP/data/config"
DRIVER_DATA_OVERRIDE="$MR_DATA" HARNESS_METRICS_DIR="$MR_DATA" driver start --runtime codex --request "add feature"
assert_eq "0:done:0" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh ' "$FAKE_LOG" || true)" "a project graph without the merge node never merges"
assert_contains "$DRIVER_OUT" "the project graph has no merge node" "the outcome asks for a harness sync"
rm -f "$MR_DATA/config"
unset FAKE_PROTECTION
pass "merge node: host rules, repository facts, merge by the runner, post-merge checks"

finish_tests
