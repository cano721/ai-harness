#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — 재개 기준선(같은 기준선·미커밋·다른 커밋)
# 실행: bash tests/run.sh workflow-runs-baseline
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"

new_driver_repo baseline_same
driver start --runtime codex --request "add feature"
assert_eq "10:$(git -C "$DRIVER_REPO" rev-parse HEAD)" "$DRIVER_RC:$(run_state .repo_baseline.head)" "the runner keeps the baseline where it stopped"
[[ -n "$(run_state '.repo_baseline.fingerprint // ""')" ]] || fail "the baseline keeps the working tree fingerprint"
say_in_claude "승인"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a resume from the same baseline continues as before"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a finished run resumed with nothing changed still reports done"
echo later >"$DRIVER_REPO/later.txt"
driver resume
assert_eq "20" "$DRIVER_RC" "a finished run whose working tree changed does not report success"
[[ "$(run_state .status)" != "done" ]] || fail "a changed finished run is not left as done"
assert_contains "$DRIVER_OUT" "later.txt" "the stop names the changed file"
driver resume --accept-changes
assert_eq "20" "$DRIVER_RC" "a finished run does not take changes in; they need a new run"
assert_contains "$DRIVER_OUT" "start a new run" "the finished run says how to check the change"
rm "$DRIVER_REPO/later.txt"
driver resume
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "back at the baseline, the finished run reports done again"
git -C "$DRIVER_REPO" add -A && git -C "$DRIVER_REPO" commit -q --allow-empty -m "after done"
driver resume
assert_eq "20" "$DRIVER_RC" "a commit after a finished run also stops it"

new_driver_repo baseline_dirty
driver start --runtime codex --request "add feature"
echo hand >"$DRIVER_REPO/hand.txt"
say_in_claude "승인"
driver resume
assert_eq "20:approval" "$DRIVER_RC:$(run_state .node)" "an uncommitted change after the stop halts resume"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "no agent writes when the baseline moved"
assert_contains "$DRIVER_OUT" "hand.txt" "the stop names the uncommitted file"
assert_contains "$DRIVER_OUT" "node approval" "the stop names where the run would continue"
assert_contains "$DRIVER_OUT" "checks: true" "the stop names the remaining required checks"
assert_contains "$DRIVER_OUT" "resume --accept-changes" "the stop says how to take the change in on purpose"
driver resume
assert_eq "20" "$DRIVER_RC" "a plain resume keeps stopping until the change is accepted or undone"
driver resume --accept-changes
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an explicit --accept-changes moves the baseline and continues"
assert_eq "1" "$(run_state '.baseline_accepted | length')" "the accepted change is recorded"
driver status --accept-changes
assert_eq "2" "$DRIVER_RC" "--accept-changes belongs to resume and approve only"

new_driver_repo baseline_commit
driver start --runtime codex --request "add feature"
echo other >"$DRIVER_REPO/other.txt"
git -C "$DRIVER_REPO" add -A && git -C "$DRIVER_REPO" commit -q -m "someone else's commit"
say_in_claude "승인"
driver resume
assert_eq "20:approval" "$DRIVER_RC:$(run_state .node)" "a different commit after the stop halts resume"
[[ "$(<"$FAKE_LOG")" != *deliver* ]] || fail "no agent writes when HEAD moved"
assert_contains "$DRIVER_OUT" "someone else's commit" "the stop lists the new commits"
driver resume --accept-changes
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "an accepted commit becomes the run's head, so the write nodes do not see HEAD as moved"
pass "resume compares the saved baseline before any agent runs (same, uncommitted, and other-commit baselines)"

# 러너는 한 프로세스 안에서 외부 실행이 없는 동안 지문을 재사용하고, 미추적 파일 해시를 한 번에 구한다(#585).
# 재사용이 쓰기 감시를 약하게 만들지 않고, 지문 값은 예전 구현(파일마다 hash-object)과 같아 저장된 기준점과 resume이 맞는다.
old_fingerprint() { # repo → 예전 구현의 지문
  {
    git -C "$1" rev-parse HEAD 2>/dev/null || true
    git -C "$1" diff HEAD --binary 2>/dev/null || true
    git -C "$1" ls-files --others --exclude-standard -z \
      | while IFS= read -r -d '' f; do printf '%s\0' "$f"; git -C "$1" hash-object -- "$f"; done
  } | git hash-object --stdin
}
# (i) deliver가 이미 있던 미추적 파일의 내용만 바꿔도 변경으로 본다.
new_driver_repo fp_deliver_edit
echo v0 >"$DRIVER_REPO/feature.txt"
start_and_approve fp_deliver_edit
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a deliver that only rewrites an untracked file counts as a change"
assert_eq "v1" "$(<"$DRIVER_REPO/feature.txt")" "deliver rewrote the untracked file"
# (ii) read-only 노드가 이미 있던 미추적 파일 내용을 바꾸면 시작 기준점 지문을 재사용한 앞 지문과 달라 멈춘다.
for fp_node in fp_discover_edits fp_review_edits; do
  new_driver_repo "$fp_node"
  echo orig >"$DRIVER_REPO/scratch.txt"
  start_and_approve "$fp_node"
  assert_eq "40" "$DRIVER_RC" "$fp_node: a read-only node that rewrites an untracked file stops the run"
  assert_contains "$DRIVER_OUT" "changed the working tree" "$fp_node: the stop names the read-only write"
done
# (iii) 노드 사이에 사람이 미추적 파일 내용만 바꾼 뒤 resume하면 기준점 대조가 막는다.
new_driver_repo fp_hand_edit
echo orig >"$DRIVER_REPO/notes.txt"
driver start --runtime codex --request "add feature"
assert_eq "10" "$DRIVER_RC" "the run waits for approval"
echo edited >"$DRIVER_REPO/notes.txt"
say_in_claude "승인"
driver resume
assert_eq "20:approval" "$DRIVER_RC:$(run_state .node)" "an untracked file edited between nodes halts resume"
assert_contains "$DRIVER_OUT" "notes.txt" "the stop names the edited untracked file"
# (iv) 미추적 파일 여러 개(공백·줄바꿈이 든 이름 포함)의 지문 값이 예전 구현과 같다.
new_driver_repo fp_same_value
mkdir -p "$DRIVER_REPO/dir"
echo a >"$DRIVER_REPO/a.txt"
echo b >"$DRIVER_REPO/b c.txt"
echo d >"$DRIVER_REPO/dir/d.txt"
start_and_approve fp_same_value
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a run over several untracked files reaches done"
assert_eq "$(old_fingerprint "$DRIVER_REPO")" "$(run_state .repo_baseline.fingerprint)" "the saved fingerprint equals the per-file implementation"
new_driver_repo fp_newline_value
echo a >"$DRIVER_REPO/a.txt"
echo n >"$DRIVER_REPO/line"$'\n'"break.txt"
start_and_approve fp_newline_value
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "a run with a newline in an untracked name reaches done"
assert_eq "$(old_fingerprint "$DRIVER_REPO")" "$(run_state .repo_baseline.fingerprint)" "a newline name falls back to the per-file value"
echo changed >"$DRIVER_REPO/line"$'\n'"break.txt"
driver resume
assert_eq "20" "$DRIVER_RC" "rewriting the newline-named file is a change"
pass "the runner reuses the fingerprint only between outside runs and keeps its value"

finish_tests
