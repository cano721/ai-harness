#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 승인 모드 출처(human 기본·저장소·전역·오타·legacy)와 push 안 된 publish
# 실행: bash tests/run.sh workflow-publish-approval
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

new_driver_repo human_pr
with_policy pr-only ""
FAKE_CHECK="grep -q fixed feature.txt" driver start --runtime codex --request "add feature"
assert_eq "10:human:default" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "approval defaults to human and records the default source"
say_in_claude "승인"
driver resume
assert_eq "0:done:2" "$DRIVER_RC:$(run_state .status):$(run_state '.checkpoints | length')" "a human-approved pr-only run checkpoints deliver and each repair, then opens a PR"

new_driver_repo approval_repo
with_policy pr-only ""
printf 'HM_APPROVAL=auto\nHM_APPROVAL_REPOS="repo-approval_repo=human,elsewhere=auto"\n' >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "10:human:HM_APPROVAL_REPOS:repo-approval_repo" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "a matching repository approval setting overrides the global setting"

new_driver_repo approval_global
with_policy pr-only ""
printf 'HM_APPROVAL=auto\nHM_APPROVAL_REPOS="another=human"\n' >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "0:auto:HM_APPROVAL" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "the global approval setting applies without a matching repository entry"

new_driver_repo manifest_approval
with_policy pr-only ""
jq '.approval = "auto"' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_REPO/manifest.json" && mv "$DRIVER_REPO/manifest.json" "$DRIVER_REPO/.ai-harness/harness.json"
git -C "$DRIVER_REPO" add .ai-harness && git -C "$DRIVER_REPO" commit -q -m legacy-approval
: >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "10:human:default" "$DRIVER_RC:$(run_state .policy.approval):$(run_state .policy.approval_source)" "a legacy manifest approval value is ignored"
assert_eq "1" "$(grep -c 'notice: .ai-harness/harness.json approval is ignored' <<<"$DRIVER_OUT")" "a legacy manifest approval value produces one migration notice"

# 승인 모드 오타를 human으로 조용히 읽지 않는다 — 시작하지 않고 고칠 키를 알린다.
new_driver_repo approval_invalid
with_policy pr-only ""
printf 'HM_APPROVAL=yes\n' >"$DRIVER_TMP/data/config"
driver start --runtime codex --request "add feature"
assert_eq "2" "$DRIVER_RC" "an invalid personal approval value stops the start"
assert_contains "$DRIVER_OUT" "approval must be human or auto" "the invalid approval value is named"
assert_contains "$DRIVER_OUT" "HM_APPROVAL in $DRIVER_TMP/data/config" "the invalid approval names the config file it came from"
: >"$DRIVER_TMP/data/config"
# 값이 환경변수에서 왔으면 config 파일이 아니라 환경변수라고 말한다(#310).
DRIVER_RC=0
DRIVER_OUT="$(HM_APPROVAL=yes HM_APPROVAL_REPOS='' HM_RUNTIME='' HM_RUNTIME_REPOS='' HARNESS_METRICS_DIR="$DRIVER_TMP/data" HM_FEATURE_RUNS_DIR="$DRIVER_TMP/runs" CLAUDE_CONFIG_DIR="$DRIVER_TMP/claude" CODEX_HOME="$DRIVER_TMP/codex" \
  FAKE_LOG="$FAKE_LOG" FAKE_SCENARIO="$FAKE_SCENARIO" PATH="$ROOT/tests/fixtures/driver:$PATH" \
  bash "$DRIVER" start --runtime codex --request "add feature" --repo "$DRIVER_REPO" 2>&1 </dev/null)" || DRIVER_RC=$?
assert_eq "2" "$DRIVER_RC" "an invalid approval from the environment stops the start"
assert_contains "$DRIVER_OUT" "HM_APPROVAL in the environment" "the invalid approval names the environment as its source"
[[ "$DRIVER_OUT" != *"config is"* ]] || fail "an environment value is not reported as a config file value"

# 업그레이드 전에 시작된 실행에는 approval_source가 없다 — 기본값(default)이 아니라 legacy로 보인다(#310).
new_driver_repo approval_legacy_status
with_policy pr-only ""
driver start --runtime codex --request "add feature"
LEGACY_STATE="$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
jq 'del(.policy.approval_source)' "$LEGACY_STATE" >"$LEGACY_STATE.tmp" && mv "$LEGACY_STATE.tmp" "$LEGACY_STATE"
driver status --workflow feature --run "$(run_state .run_id)"
assert_contains "$DRIVER_OUT" "approval human (legacy)" "a run without a recorded approval source shows legacy"
[[ "$DRIVER_OUT" != *"(default)"* ]] || fail "a legacy run is not shown as using the default approval"

new_driver_repo publish_unpushed
with_policy pr-only auto
driver start --runtime codex --request "add feature"
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a publish the runner cannot verify goes to a person"
assert_contains "$(run_state '.findings | join(";")')" "HEAD is not pushed to its upstream" "publish is judged by git state, not the session report"
assert_contains "$(run_state '.findings | join(";")')" "pr_url is empty" "pr-only without a PR is not done"
pass "approval mode resolution and unverifiable publish go to a person"

finish_tests
