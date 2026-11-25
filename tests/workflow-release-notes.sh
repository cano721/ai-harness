#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — release 워크플로(#493): 노트가 없으면 태그 없음·resume 태그 중복 방지
# 실행: bash tests/run.sh workflow-release-notes
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

# 7. 노트가 없으면 태그·릴리스를 만들지 않는다.
for n in 'exit 1' "printf '  \\n'"; do
  rel_repo "rel_nonotes_$( [[ "$n" == 'exit 1' ]] && echo fail || echo blank)" '.' merge
  jq --arg n "$n" '.release_policy.notes_cmd = $n' "$DRIVER_REPO/.ai-harness/harness.json" >"$DRIVER_TMP/m.json" && mv "$DRIVER_TMP/m.json" "$DRIVER_REPO/.ai-harness/harness.json"
  git -C "$DRIVER_REPO" commit -qam notes && git -C "$DRIVER_REPO" push -q origin HEAD:refs/heads/develop
  driver start --runtime codex --workflow release --version 1.3.0
  assert_eq "20:0" "$DRIVER_RC:$(grep -c '^gh release' "$FAKE_LOG" || true)" "notes '$n': no release is created"
  assert_eq "" "$(remote_ref refs/tags/v1.3.0)" "notes '$n': no tag is pushed"
done
pass "a release without notes is not tagged"

# 9. resume: 태그가 이미 있으면 다시 만들지 않는다.
rel_repo rel_resume '.' merge
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "0" "$DRIVER_RC" "the release ran"
state_file="$(find "$DRIVER_TMP/runs" -path "*/$(basename "$DRIVER_REPO")-*/*" -name state.json | head -n 1)"
jq '.node = "release" | .status = "incomplete"' "$state_file" >"$DRIVER_TMP/s.json" && mv "$DRIVER_TMP/s.json" "$state_file"
driver resume
assert_eq "0:1" "$DRIVER_RC:$(grep -c '^gh release create' "$FAKE_LOG")" "an existing tag is not created again"
assert_eq "existing" "$(run_state .release.published.status)" "the existing release is recorded"
rel_repo rel_release_fail '.' merge
driver start --runtime codex --workflow release --version 1.3.0
assert_eq "20:user_decision" "$DRIVER_RC:$(run_state .status)" "a failed release goes to a person"
pass "release resume does not tag twice"

finish_tests
