#!/usr/bin/env bash
# 회귀 테스트 — 자동 병합: 검증된 무인 PR의 opt-in 병합
# 실행: bash tests/run.sh automation-merge
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"


# 자동 병합(opt-in): 내용 판정은 로컬 git 객체로, 병합은 호스트 상태(같은 head·대상 브랜치·CI 통과·사람 활동 없음)를 본 뒤에.
AM_REPO="$TEST_TMP/am-repo"
make_repo "$AM_REPO" https://github.com/acme/am.git
git -C "$AM_REPO" checkout -q -b develop
mkdir -p "$AM_REPO/.ai-harness/workflows" "$AM_REPO/.ai-harness/docs"
# 저장소 auto_merge 설정 없이 사용자 설정만으로 동작한다(#250).
jq -n '{project_id:"am-svc",harness_version:"0.1.0",git_policy:"pr-only",managed_files:{}}' >"$AM_REPO/.ai-harness/harness.json"
printf '# rules\n' >"$AM_REPO/AGENTS.md"
printf '# testing\n' >"$AM_REPO/.ai-harness/docs/testing.md"
printf 'x\n' >"$AM_REPO/app.js"
git -C "$AM_REPO" add -A && git -C "$AM_REPO" commit -q -m base
git -C "$AM_REPO" update-ref refs/remotes/origin/develop develop
am_sha() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | awk '{print $1}'; }
am_branch() { git -C "$AM_REPO" checkout -q -B "$1" develop; }
am_commit() { git -C "$AM_REPO" add -A && git -C "$AM_REPO" commit -q -m "$1" && git -C "$AM_REPO" rev-parse HEAD; }
am_manifest() { jq "$1" "$AM_REPO/.ai-harness/harness.json" >"$AM_REPO/.ai-harness/hj" && mv "$AM_REPO/.ai-harness/hj" "$AM_REPO/.ai-harness/harness.json"; }
am_check() { "$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/develop "$@"; }
AM_RUNNER=".ai-harness/workflows/workflow-driver.sh"
am_sync_head() { # 러너를 템플릿 그대로 넣고 manifest 해시를 맞춘 sync 커밋
  am_branch "$1"
  mkdir -p "$AM_REPO/.ai-harness/workflows"
  cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
  am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
}
am_sync_head s-ok
AM_SYNC_OK="$(am_commit sync)"
assert_eq "ok" "$(am_check --scope sync --head "$AM_SYNC_OK")" "a copy-only sync PR passes"
assert_eq "partial_sync" "$(am_check --scope sync --head "$AM_SYNC_OK" --result partial)" "partial sync needs its own opt-in"
AM_REVIEW='{"review":{"first_pass":"pass","expected":"재발 0"}}'
# 저장소 조정값은 기준 브랜치 manifest에서만 읽고, 플러그인 상한을 넘지 못한다.
am_base_with() { # name jq-filter → origin/<name>: develop에 manifest 조정값을 바꾼 기준 브랜치
  git -C "$AM_REPO" checkout -q -B "$1" develop && am_manifest "$2" && git -C "$AM_REPO" commit -q -am "$1"
  git -C "$AM_REPO" update-ref "refs/remotes/origin/$1" "$1"
}
am_on() { # base-name branch → base 위에서 새 브랜치
  git -C "$AM_REPO" checkout -q -B "$2" "$1"
}
am_base_with partial-on '.auto_merge.sync_partial = true'
am_on partial-on s-partial
mkdir -p "$AM_REPO/.ai-harness/workflows"
cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
AM_PARTIAL="$(am_commit partial)"
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/partial-on --scope sync --head "$AM_PARTIAL" --result partial)" "partial sync passes when the base manifest allows it"
am_base_with lines-60 '.auto_merge.harvest_max_lines = 60'
am_on lines-60 h-60 && seq 1 60 >>"$AM_REPO/AGENTS.md"
AM_H60="$(am_commit h60)"
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/lines-60 --scope project --head "$AM_H60" --review "$AM_REVIEW")" "the repo can raise the harvest line cap"
am_base_with lines-999 '.auto_merge.harvest_max_lines = 999'
am_on lines-999 h-999 && seq 1 101 >>"$AM_REPO/AGENTS.md"
assert_eq "too_many_lines:101" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/lines-999 --scope project --head "$(am_commit h999)" --review "$AM_REVIEW")" "the plugin cap still applies"
am_base_with files-big '.auto_merge.harvest_max_files = 1e20'
am_on files-big h-files && for f in a b c d e f; do printf 'x\n' >"$AM_REPO/.ai-harness/docs/$f.md"; done
assert_eq "too_many_files:6" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/files-big --scope project --head "$(am_commit hfiles)" --review "$AM_REVIEW")" "a huge cap is clamped to the plugin cap"
am_base_with lines-bad '.auto_merge.harvest_max_lines = "999"'
am_on lines-bad h-bad && seq 1 41 >>"$AM_REPO/AGENTS.md"
assert_eq "too_many_lines:41" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/lines-bad --scope project --head "$(am_commit hbad)" --review "$AM_REVIEW")" "a non-number value falls back to the default"
# 조정값은 사용자 설정 HM_AUTO_MERGE_*로도 정한다. 저장소 값이 함께 있으면 안전한 쪽(작은 상한·엄격한 불리언)을 쓴다.
assert_eq "ok" "$(HM_AUTO_MERGE_SYNC_PARTIAL=1 am_check --scope sync --head "$AM_SYNC_OK" --result partial)" "the user setting allows partial sync without a repo setting"
am_base_with partial-off '.auto_merge.sync_partial = false'
am_on partial-off s-partial-off
mkdir -p "$AM_REPO/.ai-harness/workflows"
cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
AM_PARTIAL_OFF="$(am_commit partialoff)"
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/partial-off --scope sync --head "$AM_PARTIAL_OFF")" "the strict fixture itself passes as a full sync"
assert_eq "partial_sync" "$(HM_AUTO_MERGE_SYNC_PARTIAL=1 "$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/partial-off --scope sync --head "$AM_PARTIAL_OFF" --result partial)" "a repo that refuses partial sync stays strict"
assert_eq "partial_sync" "$(HM_AUTO_MERGE_SYNC_PARTIAL=0 "$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/partial-on --scope sync --head "$AM_PARTIAL" --result partial)" "a user who refuses partial sync stays strict"
am_branch h-u60 && seq 1 60 >>"$AM_REPO/AGENTS.md"
AM_HU60="$(am_commit hu60)"
assert_eq "ok" "$(HM_AUTO_MERGE_HARVEST_MAX_LINES=60 am_check --scope project --head "$AM_HU60" --review "$AM_REVIEW")" "the user setting raises the harvest line cap"
assert_eq "too_many_lines:60" "$(HM_AUTO_MERGE_HARVEST_MAX_LINES=50 "$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/lines-60 --scope project --head "$AM_H60" --review "$AM_REVIEW")" "with both set the smaller cap wins"
am_branch h-u999 && seq 1 101 >>"$AM_REPO/AGENTS.md"
assert_eq "too_many_lines:101" "$(HM_AUTO_MERGE_HARVEST_MAX_LINES=999 am_check --scope project --head "$(am_commit hu999)" --review "$AM_REVIEW")" "the plugin cap applies to the user setting"
assert_eq "too_many_lines:60" "$(HM_AUTO_MERGE_HARVEST_MAX_LINES=abc am_check --scope project --head "$AM_HU60" --review "$AM_REVIEW")" "a bad user value falls back to the default"
am_sync_head s-bytes
printf '# edited\n' >>"$AM_REPO/$AM_RUNNER"
am_manifest ".managed_files[\"$AM_RUNNER\"].content_sha256 = \"$(am_sha "$AM_REPO/$AM_RUNNER")\""
assert_eq "copy_differs:$AM_RUNNER" "$(am_check --scope sync --head "$(am_commit bytes)")" "a copy that differs from the template is refused"
am_sync_head s-mode
chmod 644 "$AM_REPO/$AM_RUNNER"
assert_eq "bad_mode:100644:$AM_RUNNER" "$(am_check --scope sync --head "$(am_commit mode)")" "a copy must keep the template's executable bit"
am_sync_head s-hash
am_manifest ".managed_files[\"$AM_RUNNER\"].content_sha256 = \"0000\""
assert_eq "manifest_hash_mismatch:$AM_RUNNER" "$(am_check --scope sync --head "$(am_commit hash)")" "a manifest hash that does not match is refused"
am_sync_head s-policy
am_manifest '.git_policy = "merge"'
assert_eq "manifest_policy_changed" "$(am_check --scope sync --head "$(am_commit policy)")" "a sync that changes policy fields is refused"
am_sync_head s-render
mkdir -p "$AM_REPO/.claude/commands" && printf 'x\n' >"$AM_REPO/.claude/commands/review.md"
assert_eq "render_file:.claude/commands/review.md" "$(am_check --scope sync --head "$(am_commit render)")" "a render artifact needs a person"
# render 파일도 스크립트 결과와 바이트 같으면 기계적으로 검증된다(#316). 한 글자라도 다르면 지금처럼 사람에게.
am_sync_head s-render-ok
mkdir -p "$AM_REPO/.claude/commands"
"$ROOT/scripts/render-managed-file.sh" --path .claude/commands/review.md >"$AM_REPO/.claude/commands/review.md"
am_manifest ".managed_files[\".claude/commands/review.md\"] = {content_sha256:\"$(am_sha "$AM_REPO/.claude/commands/review.md")\"}"
assert_eq "render_unmarked:.claude/commands/review.md" "$(am_check --scope sync --head "$(am_commit renderunmarked)")" "a new render must be recorded with the renderer mark"
am_manifest ".managed_files[\".claude/commands/review.md\"].renderer = 1"
assert_eq "ok" "$(am_check --scope sync --head "$(am_commit renderok)")" "a render artifact equal to the render script passes"
am_sync_head s-render-edit
mkdir -p "$AM_REPO/.claude/commands"
"$ROOT/scripts/render-managed-file.sh" --path .claude/commands/review.md >"$AM_REPO/.claude/commands/review.md"
printf ' ' >>"$AM_REPO/.claude/commands/review.md"
am_manifest ".managed_files[\".claude/commands/review.md\"] = {content_sha256:\"$(am_sha "$AM_REPO/.claude/commands/review.md")\"}"
assert_eq "render_file:.claude/commands/review.md" "$(am_check --scope sync --head "$(am_commit renderedit)")" "a render artifact one byte off needs a person"
# 예전 손 렌더(저장소 맞춤 포함)가 기록된 저장소: 해시가 맞아도 base manifest에 renderer 표시가 없으면 첫 결정적
# render PR은 사람이 본다. 표시는 base(대상 브랜치) 것만 믿는다 — head에 표시를 넣어도 통과하지 않는다.
am_render_base() { # name renderer-mark(0|1) → origin/<name>: 옛 진입점이 기록된 기준 브랜치
  git -C "$AM_REPO" checkout -q -B "$1" develop
  mkdir -p "$AM_REPO/.claude/commands"
  # shellcheck disable=SC2016  # $ARGUMENTS는 옛 진입점의 자리표시자 문자열이다
  printf -- '---\ndescription: old\n---\n\n- team routing line\n\n요청: $ARGUMENTS\n' >"$AM_REPO/.claude/commands/review.md"
  am_manifest ".managed_files[\".claude/commands/review.md\"] = {content_sha256:\"$(am_sha "$AM_REPO/.claude/commands/review.md")\"} + (if $2 == 1 then {renderer: 1} else {} end)"
  git -C "$AM_REPO" add -A && git -C "$AM_REPO" commit -q -m "$1"
  git -C "$AM_REPO" update-ref "refs/remotes/origin/$1" "$1"
}
am_render_head() { # base branch → 옛 진입점을 스크립트 결과로 바꾼 sync 커밋
  am_on "$1" "$2"
  "$ROOT/scripts/render-managed-file.sh" --path .claude/commands/review.md >"$AM_REPO/.claude/commands/review.md"
  am_manifest ".harness_version = \"9.9.9\" | .managed_files[\".claude/commands/review.md\"] = {content_sha256:\"$(am_sha "$AM_REPO/.claude/commands/review.md")\", renderer: 1}"
  am_commit "$2"
}
am_render_base render-unmarked 0
assert_eq "render_first:.claude/commands/review.md" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/render-unmarked --scope sync --head "$(am_render_head render-unmarked s-render-first)")" "the first deterministic render over an unmarked hand render needs a person"
am_render_base render-marked 1
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/render-marked --scope sync --head "$(am_render_head render-marked s-render-next)")" "a render over a marked deterministic render passes"
# 표시가 있어도 base 파일을 사람이 고치고 다시 기록하지 않았으면 사람이 본다.
am_render_base render-drift 1
printf -- '- edited later\n' >>"$AM_REPO/.claude/commands/review.md"
git -C "$AM_REPO" commit -q -am render-drift-edit && git -C "$AM_REPO" update-ref refs/remotes/origin/render-drift render-drift
assert_eq "render_modified:.claude/commands/review.md" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/render-drift --scope sync --head "$(am_render_head render-drift s-render-drift)")" "a marked render a person edited after recording needs a person"
am_sync_head s-del
git -C "$AM_REPO" rm -q app.js
assert_eq "unsupported_change:D:app.js" "$(am_check --scope sync --head "$(am_commit del)")" "a deletion is refused"
# 기준 브랜치에 이미 관리 항목이 있는 저장소(실제 저장소는 모두 그렇다): 남아 있으면 통과, 지우면 거부.
am_base_with managed '.managed_files["AGENTS.md"] = {content_sha256:"aaaa"}'
am_on managed s-keep
mkdir -p "$AM_REPO/.ai-harness/workflows" && cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/managed --scope sync --head "$(am_commit keep)")" "existing managed entries that stay are fine"
am_manifest '.managed_files["AGENTS.md"].template_version = "9.9.9"'
assert_eq "ok" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/managed --scope sync --head "$(am_commit tv)")" "recording a new template_version for an untouched file is fine"
am_manifest '.managed_files["app.js"] = {template_version:"x"}'
assert_eq "manifest_hash_changed_without_file:app.js" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/managed --scope sync --head "$(am_commit newkey)")" "a new entry without its file is refused"
am_manifest 'del(.managed_files["app.js"]) | del(.managed_files["AGENTS.md"])'
assert_eq "manifest_entry_removed" "$("$ROOT/scripts/auto-merge.sh" check --repo "$AM_REPO" --base origin/managed --scope sync --head "$(am_commit drop)")" "removing a managed entry is refused"
am_sync_head s-otherhash
am_manifest '.managed_files["AGENTS.md"] = {content_sha256:"1111"}'
assert_eq "manifest_hash_changed_without_file:AGENTS.md" "$(am_check --scope sync --head "$(am_commit otherhash)")" "hashes of untouched files cannot change"
am_sync_head s-tab
printf 'x\n' >"$AM_REPO/$AM_RUNNER"$'\t'
assert_eq "bad_path" "$(am_check --scope sync --head "$(am_commit tab)")" "a path with a tab cannot pose as a managed file"
# harvest PR: 문서만, 작게, 일반 파일 모드, 1회차 독립 검토 통과·기대효과 기록.
am_hcheck() { am_check --scope project --head "$1" --review "${2:-$AM_REVIEW}"; }
am_branch h-ok
printf -- '- 새 규칙\n' >>"$AM_REPO/AGENTS.md"
AM_HARVEST_OK="$(am_commit harvest)"
assert_eq "ok" "$(am_hcheck "$AM_HARVEST_OK")" "a small doc-only harvest PR passes"
assert_eq "review_not_first_pass" "$(am_hcheck "$AM_HARVEST_OK" '{"review":{"first_pass":"revised","expected":"x"}}')" "a revised proposal needs a person"
assert_eq "no_expected_effect" "$(am_hcheck "$AM_HARVEST_OK" '{"review":{"first_pass":"pass"}}')" "an improvement without expected effect needs a person"
am_branch h-ko
printf -- '- 규칙\n' >"$AM_REPO/.ai-harness/docs/한글-규칙.md"
assert_eq "ok" "$(am_hcheck "$(am_commit ko)")" "Korean doc paths are read as they are"
am_branch h-newline
printf -- '- r\n' >>"$AM_REPO/AGENTS.md"
printf 'x\n' >"$AM_REPO/.ai-harness/docs/a.md"$'\n'"zz" && printf 'y\n' >>"$AM_REPO/app.js"
assert_eq "bad_path" "$(am_hcheck "$(am_commit newline)")" "a path with a newline cannot hide other entries"
am_branch h-rename
git -C "$AM_REPO" mv app.js .ai-harness/docs/app.md
assert_eq "unsupported_change:D:app.js" "$(am_hcheck "$(am_commit rename)")" "a rename cannot hide the deleted source"
am_branch h-link
rm "$AM_REPO/AGENTS.md" && ln -s /etc/hosts "$AM_REPO/AGENTS.md"
assert_eq "unsupported_change:T:AGENTS.md" "$(am_hcheck "$(am_commit link)")" "a doc turned into a symlink is refused"
am_branch h-exec
printf -- '- r\n' >>"$AM_REPO/.ai-harness/docs/testing.md" && chmod 755 "$AM_REPO/.ai-harness/docs/testing.md"
assert_eq "bad_mode:100755:.ai-harness/docs/testing.md" "$(am_hcheck "$(am_commit exec)")" "an executable doc is refused"
am_branch h-code
printf 'y\n' >>"$AM_REPO/app.js"
assert_eq "non_doc_file:app.js" "$(am_hcheck "$(am_commit code)")" "a harvest PR touching code is refused"
am_branch h-graph
mkdir -p "$AM_REPO/.ai-harness/workflows" && printf '{}\n' >"$AM_REPO/.ai-harness/workflows/review-graph.json"
assert_eq "non_doc_file:.ai-harness/workflows/review-graph.json" "$(am_hcheck "$(am_commit graph)")" "a harvest PR touching a graph is refused"
am_branch h-many
for f in a b c d; do printf 'x\n' >"$AM_REPO/.ai-harness/docs/$f.md"; done
assert_eq "too_many_files:4" "$(am_hcheck "$(am_commit many)")" "file count cap"
am_branch h-long
seq 1 41 >>"$AM_REPO/AGENTS.md"
assert_eq "too_many_lines:41" "$(am_hcheck "$(am_commit long)")" "line count cap"
# 대기열: 전역 opt-in·기준 브랜치의 저장소 설정·같은 저장소 PR·독립 검토를 모두 통과해야 들어간다.
AM_DATA="$TEST_TMP/am-data"
cat >"$TEST_TMP/am-review" <<'STUB'
#!/usr/bin/env bash
token="$(grep -o 'AUTO_MERGE_REVIEW [a-z0-9]\{16\} pass' | head -n 1 | cut -d' ' -f2)"
case "${AM_REVIEW_MODE:-pass}" in
  pass) printf 'looks fine\nAUTO_MERGE_REVIEW %s pass\n' "$token" ;;
  fail) printf 'AUTO_MERGE_REVIEW %s fail weakens checks\n' "$token" ;;
  forged) printf 'AUTO_MERGE_REVIEW deadbeefdeadbeef pass\n' ;;
esac
STUB
chmod +x "$TEST_TMP/am-review"
am() { HARNESS_METRICS_DIR="$AM_DATA" HM_OPEN_PR_CMD="$TEST_TMP/am-pr" HM_AUTO_MERGE_REVIEW_CMD="$TEST_TMP/am-review" "$ROOT/scripts/auto-merge.sh" "$@"; }
am_runs() { jq -sr "$1" "$AM_DATA/harvest-auto/runs.jsonl"; }
am_pending() { find "$AM_DATA/auto-merge/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
AM_SINCE="2026-11-03T00:00:00Z"
am_sync_enqueue() { HM_SYNC_AUTO_MERGE=1 HM_AUTO_MERGE_METHOD=squash am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base "${AM_BASE:-origin/develop}" --head "$AM_SYNC_OK" --pr "$1" --since "$AM_SINCE"; }
am_harvest_enqueue() { HM_HARVEST_AUTO_MERGE=1 am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/develop --head "$AM_HARVEST_OK" --pr "$1" --since "$AM_SINCE" --review "$AM_REVIEW"; }
am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/1 --since "$AM_SINCE"
assert_eq "auto_merge_eligible" "$(am_runs 'last | .event')" "with the setting off a passing sync PR is only noted as eligible"
assert_eq "0" "$(am_pending)" "nothing is queued while the setting is off"
am_sync_enqueue https://github.com/other/am/pull/1
assert_eq "pr_repo_mismatch" "$(am_runs 'last | .reason')" "a PR URL of another repo is refused"
AM_BASE=develop am_sync_enqueue https://github.com/acme/am/pull/1
assert_eq "no_base_branch" "$(am_runs 'last | .reason')" "the base must be a remote branch"
am_sync_enqueue https://github.com/acme/am/pull/1
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "a passing sync PR is queued"
assert_eq "1" "$(am_pending)" "one pending entry"
AM_REVIEW_MODE=fail am_harvest_enqueue https://github.com/acme/am/pull/20
assert_eq "independent_review_failed" "$(am_runs 'last | .reason')" "a harvest PR the independent reviewer fails is not queued"
AM_REVIEW_MODE=forged am_harvest_enqueue https://github.com/acme/am/pull/21
assert_eq "independent_review_failed" "$(am_runs 'last | .reason')" "a verdict without this run's token is not accepted"
am_harvest_enqueue https://github.com/acme/am/pull/22
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "a harvest PR passing the independent review is queued"
assert_eq "0" "$(am_runs '[.[] | select(.event == "auto_merge_legacy_switch")] | length')" "no legacy notice for a repo without auto_merge"
# 저장소 허용 스위치는 더 이상 막지 않는다(#250): auto_merge.harvest:false·auto_merge:false여도 사용자 설정이 켜져 있으면 대상이다.
am_base_with off '.auto_merge.harvest = false | .auto_merge.method = "merge"'
am_on off h-off && printf -- '- 새 규칙\n' >>"$AM_REPO/AGENTS.md"
AM_HARVEST_OFF="$(am_commit hoff)"
HM_HARVEST_AUTO_MERGE=1 am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/off --head "$AM_HARVEST_OFF" --pr https://github.com/acme/am/pull/23 --since "$AM_SINCE" --review "$AM_REVIEW"
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "a repo switch set to false no longer blocks"
assert_eq "auto_merge_legacy_switch" "$(am_runs '.[-2].event')" "the old repo switch is recorded for a notice"
assert_eq "merge" "$(jq -r 'select(.pr == "https://github.com/acme/am/pull/23") | .method' "$AM_DATA"/auto-merge/pending/*.json)" "the repo method is used when the user sets none"
am_base_with off-all '.auto_merge = false'
am_on off-all h-offall && printf -- '- 새 규칙\n' >>"$AM_REPO/AGENTS.md"
HM_HARVEST_AUTO_MERGE=1 HM_AUTO_MERGE_METHOD=squash am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/off-all --head "$(am_commit hoffall)" --pr https://github.com/acme/am/pull/24 --since "$AM_SINCE" --review "$AM_REVIEW"
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "auto_merge: false no longer blocks"
assert_eq "squash" "$(jq -r 'select(.pr == "https://github.com/acme/am/pull/24") | .method' "$AM_DATA"/auto-merge/pending/*.json)" "the user method comes first"
rm -f "$AM_DATA"/auto-merge/pending/*.json
am_sync_enqueue https://github.com/acme/am/pull/1
am_harvest_enqueue https://github.com/acme/am/pull/22
# sweep: 호스트 상태 스텁. CI 진행 중이면 기다리고, 통과하면 head를 고정해 병합한다.
cat >"$TEST_TMP/am-pr" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --status) id="${2##*/}"; cat "$AM_PR_STATE_DIR/$id.json" 2>/dev/null || cat "$AM_PR_STATE_DIR/default.json" ;;
  --merge) printf '%s|%s|%s\n' "$2" "$4" "$6" >>"$AM_PR_LOG"; exit "$(cat "$AM_PR_STATE_DIR/merge-rc" 2>/dev/null || echo 0)" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TEST_TMP/am-pr"
export AM_PR_STATE_DIR="$TEST_TMP/am-state" AM_PR_LOG="$TEST_TMP/am-merged"
mkdir -p "$AM_PR_STATE_DIR"
am_state() { jq -n --arg h "${2:-$AM_SYNC_OK}" "{state:\"open\",head:\$h,base:\"develop\",created:\"2026-11-03T00:05:00\",activity:0,mergeable:\"mergeable\",ci:\"success\",draft:true} | ${3:-.}" >"$AM_PR_STATE_DIR/$1.json"; }
am_state 1 "$AM_SYNC_OK" '.ci = "pending"'
am_state 22 "$AM_HARVEST_OK" '.ci = "pending"'
HM_SYNC_AUTO_MERGE=1 HM_HARVEST_AUTO_MERGE=1 am sweep
assert_eq "2" "$(am_pending)" "pending CI keeps the entries"
assert_not_file "$AM_PR_LOG"
am_state 1
am_state 22 "$AM_HARVEST_OK"
HM_SYNC_AUTO_MERGE=1 HM_HARVEST_AUTO_MERGE=1 am sweep
assert_eq "https://github.com/acme/am/pull/1|$AM_SYNC_OK|squash" "$(sort "$AM_PR_LOG" | sed -n 1p)" "green CI merges with the pinned head and the user method"
assert_eq "https://github.com/acme/am/pull/22|$AM_HARVEST_OK|default" "$(sort "$AM_PR_LOG" | sed -n 2p)" "without any method setting the host default is used"
assert_eq "2" "$(wc -l <"$AM_PR_LOG" | tr -d ' ')" "both queued PRs are merged"
assert_eq "auto_merged" "$(am_runs 'last | .event')" "the merge is recorded"
assert_eq "0" "$(am_pending)" "merged entries leave the queue"
AM_NOTICE="$(am notify | jq -r '.systemMessage')"
assert_contains "$AM_NOTICE" "2건 병합" "SessionStart reports auto merges"
assert_contains "$AM_NOTICE" "auto_merge 허용 스위치(sync·harvest)는 더 이상 쓰지 않습니다" "SessionStart says the repo switch is no longer used"
assert_contains "$AM_NOTICE" "남아 있는 저장소: am-svc." "the notice names the repo"
assert_eq "" "$(am notify)" "the notice is shown once"
HM_HARVEST_AUTO_MERGE=1 am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/off --head "$AM_HARVEST_OFF" --pr https://github.com/acme/am/pull/25 --since "$AM_SINCE" --review "$AM_REVIEW"
assert_eq "auto_merge_queued" "$(am_runs 'last | .event')" "after the notice the old switch is not recorded again"
rm -f "$AM_DATA"/auto-merge/pending/*.json
: >"$AM_PR_LOG"
for AM_CASE in 'head|.head = "0000000000000000"|head_moved' 'short|.head = "'"${AM_SYNC_OK:0:6}"'"|head_moved' 'base|.base = "main"|pr_base_mismatch' \
  'activity|.activity = 1|human_activity' 'ci|.ci = "failure"|ci_failed' 'conflict|.mergeable = "conflicting"|conflict' 'closed|.state = "closed"|closed' \
  'old|.created = "2026-11-02T23:59:59"|pr_not_from_this_run'; do
  IFS='|' read -r AM_N AM_F AM_R <<<"$AM_CASE"
  am_sync_enqueue "https://github.com/acme/am/pull/$AM_N"
  am_state "$AM_N" "$AM_SYNC_OK" "$AM_F"
  HM_SYNC_AUTO_MERGE=1 am sweep
  assert_eq "auto_merge_skipped|$AM_R" "$(am_runs 'last | "\(.event)|\(.reason)"')" "sweep hands $AM_N to a person"
done
am_sync_enqueue https://github.com/acme/am/pull/30
am_state 30
am sweep
assert_eq "auto_merge_skipped|opted_out" "$(am_runs 'last | "\(.event)|\(.reason)"')" "turning the setting off drops queued PRs"
assert_eq "0" "$(wc -l <"$AM_PR_LOG" | tr -d ' ')" "nothing else was merged"
# 병합 결과 종료 코드: 7은 병합됨(head 다름), 8은 실패 뒤 draft 복구 실패.
for AM_CASE in '7|auto_merged|head_mismatch' '8|auto_merge_skipped|merge_failed_not_redrafted' '5|auto_merge_skipped|merge_failed'; do
  IFS='|' read -r AM_RC AM_E AM_R <<<"$AM_CASE"
  printf '%s\n' "$AM_RC" >"$AM_PR_STATE_DIR/merge-rc"
  am_sync_enqueue "https://github.com/acme/am/pull/4$AM_RC"
  am_state "4$AM_RC"
  HM_SYNC_AUTO_MERGE=1 am sweep
  assert_eq "$AM_E|$AM_R" "$(am_runs 'last | "\(.event)|\(.reason)"')" "merge exit $AM_RC is recorded as $AM_R"
done
rm -f "$AM_PR_STATE_DIR/merge-rc"
assert_contains "$(am notify | jq -r '.systemMessage')" "head_mismatch" "a merge with a different head is surfaced"
# 병합 요청 형태(dry-run).
assert_eq "github|squash|abc1234" "$(HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --merge https://github.com/acme/svc/pull/3 --head abc1234 | jq -r '"\(.provider)|\(.method)|\(.head)"')" "GitHub merge request"
assert_eq "bitbucket|merge_commit" "$(HM_OPEN_PR_DRY_RUN=1 "$ROOT/scripts/open-pr.sh" --merge https://bitbucket.org/ws/r/pull-requests/4 --head abc1234 --method merge | jq -r '"\(.provider)|\(.merge_strategy)"')" "Bitbucket merge request"
if "$ROOT/scripts/open-pr.sh" --merge https://github.com/acme/svc/pull/3 --head 'x; rm' >/dev/null 2>&1; then fail "merge requires a commit hash head"; fi
if HARNESS_METRICS_DIR="$AM_DATA" "$ROOT/scripts/harvest-queue.sh" mark-reviewed --project am-svc --first-pass maybe >/dev/null 2>&1; then fail "first-pass accepts only pass|revised"; fi
# 꺼져 있을 때: 켰다면 병합됐을 sync PR이 30일에 3건 이상이면 켜는 방법을 30일에 한 번 안내한다. harvest는 권하지 않는다.
AM_DATA="$TEST_TMP/am-hint"
for AM_N in 61 62; do am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr "https://github.com/acme/am/pull/$AM_N" --since "$AM_SINCE"; done
assert_eq "" "$(am notify)" "two eligible PRs are not enough for a hint"
am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/63 --since "$AM_SINCE"
am enqueue --project am-svc --scope project --repo "$AM_REPO" --base origin/develop --head "$AM_HARVEST_OK" --pr https://github.com/acme/am/pull/64 --since "$AM_SINCE" --review "$AM_REVIEW"
assert_eq "3" "$(am_runs '[.[] | select(.event == "auto_merge_eligible")] | length')" "harvest PRs are not judged in the background"
assert_eq "" "$(HM_AUTO_MERGE_HINT=0 am notify)" "the hint can be turned off"
assert_eq "" "$(HM_SYNC_AUTO_MERGE=1 am notify)" "no hint once auto merge is on"
AM_HINT="$(am notify | jq -r '.systemMessage')"
assert_contains "$AM_HINT" "3건" "the hint shows the evidence"
assert_contains "$AM_HINT" "HM_SYNC_AUTO_MERGE" "the hint names the user setting"
[[ "$AM_HINT" != *'auto_merge'* ]] || fail "the hint no longer asks for a repo setting"
assert_eq "" "$(am notify)" "the hint is shown once per 30 days"
assert_contains "$(<"$ROOT/skills/setup/SKILL.md")" "HM_SYNC_AUTO_MERGE" "setup offers the auto merge options"
# 대화형 /setup 고르기 단계가 디자인 스킬도 묻는다(#220). 설치는 기존 design install 경로를 쓴다.
SETUP_PICK="$(awk '/^## 2\. 고르기/{f=1;next} /^## 4\./{f=0} f' "$ROOT/skills/setup/SKILL.md")"
assert_contains "$SETUP_PICK" "**디자인 스킬**" "interactive setup asks about design skills"
assert_contains "$SETUP_PICK" "\`core\` (권장)" "design question recommends core"
assert_contains "$SETUP_PICK" "review.runs\`·\`review.network" "extra choices show what runs and what network is used"
assert_contains "$SETUP_PICK" "건너뛰기" "design question can be skipped"
assert_contains "$SETUP_PICK" "도구별로 판단해 알린다" "design question handles tools with different states"
assert_contains "$(awk '/^## 1\. 현재 상태/{f=1;next} /^## 2\./{f=0} f' "$ROOT/skills/setup/SKILL.md")" "직접 둔 사본(\`foreign\`)" "design status summary names user-placed copies"
assert_contains "$SETUP_PICK" "\`current\`거나 \`foreign\`" "design question treats a user-placed skill as already present"
assert_contains "$SETUP_PICK" "setup.sh design install --tool" "design choice reuses design install"
assert_contains "$(sed -n '8p' "$ROOT/skills/setup/SKILL.md")" "디자인 스킬 상태 요약" "setup status includes design skill status"
assert_contains "$(awk '/^description:/{print; exit}' "$ROOT/skills/setup/SKILL.md")" "대화형 셋업에서 함께 묻는다" "setup description says interactive setup asks about design"
# CI가 없는 저장소: 기본은 기다리다 사람에게, require_ci:false면 병합. 실패한 CI는 어느 설정에서도 막는다.
AM_DATA="$TEST_TMP/am-noci"
: >"$AM_PR_LOG"
am_base_with noci '.auto_merge.require_ci = false'
am_on noci s-noci
mkdir -p "$AM_REPO/.ai-harness/workflows"
cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
AM_NOCI="$(am_commit noci)"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/71 --since "$AM_SINCE"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/noci --head "$AM_NOCI" --pr https://github.com/acme/am/pull/72 --since "$AM_SINCE"
am_state 71 "$AM_SYNC_OK" '.ci = "none"'
am_state 72 "$AM_NOCI" '.ci = "none" | .base = "noci"'
HM_SYNC_AUTO_MERGE=1 am sweep
assert_eq "https://github.com/acme/am/pull/72" "$(cut -d'|' -f1 "$AM_PR_LOG")" "only the repo that does not require CI merges without CI"
assert_eq "1" "$(am_pending)" "the repo that requires CI keeps waiting"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/noci --head "$AM_NOCI" --pr https://github.com/acme/am/pull/73 --since "$AM_SINCE"
am_state 73 "$AM_NOCI" '.ci = "failure" | .base = "noci"'
HM_SYNC_AUTO_MERGE=1 am sweep
assert_eq "auto_merge_skipped|ci_failed" "$(am_runs '[.[] | select(.artifact == "https://github.com/acme/am/pull/73")] | last | "\(.event)|\(.reason)"')" "failed CI blocks even without require_ci"
# require_ci도 사용자 설정으로 끌 수 있지만, 기준 브랜치가 require_ci:true면 그쪽이 이긴다. 실패한 CI는 여전히 막는다.
rm -f "$AM_DATA"/auto-merge/pending/*.json && : >"$AM_PR_LOG"
am_base_with ci-on '.auto_merge.require_ci = true'
am_on ci-on s-cion
mkdir -p "$AM_REPO/.ai-harness/workflows"
cp "$ROOT/templates/workflow-driver/workflow-driver.sh" "$AM_REPO/$AM_RUNNER" && chmod 755 "$AM_REPO/$AM_RUNNER"
am_manifest ".harness_version = \"9.9.9\" | .managed_files[\"$AM_RUNNER\"] = {content_sha256:\"$(am_sha "$AM_REPO/$AM_RUNNER")\"}"
AM_CION="$(am_commit cion)"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/74 --since "$AM_SINCE"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/ci-on --head "$AM_CION" --pr https://github.com/acme/am/pull/75 --since "$AM_SINCE"
HM_SYNC_AUTO_MERGE=1 am enqueue --project am-svc --scope sync --repo "$AM_REPO" --base origin/develop --head "$AM_SYNC_OK" --pr https://github.com/acme/am/pull/76 --since "$AM_SINCE"
am_state 74 "$AM_SYNC_OK" '.ci = "none"'
am_state 75 "$AM_CION" '.ci = "none" | .base = "ci-on"'
am_state 76 "$AM_SYNC_OK" '.ci = "failure"'
HM_SYNC_AUTO_MERGE=1 HM_AUTO_MERGE_REQUIRE_CI=0 am sweep
assert_eq "https://github.com/acme/am/pull/74" "$(cut -d'|' -f1 "$AM_PR_LOG")" "the user setting merges a repo without CI and without a repo value"
assert_eq "1" "$(am_pending)" "a repo that requires CI keeps waiting despite the user setting"
assert_eq "auto_merge_skipped|ci_failed" "$(am_runs '[.[] | select(.artifact == "https://github.com/acme/am/pull/76")] | last | "\(.event)|\(.reason)"')" "failed CI blocks with the user setting too"
pass "opt-in auto merge of verified unattended PRs"

finish_tests
