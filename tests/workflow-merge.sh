#!/usr/bin/env bash
# 회귀 테스트 — 그래프 러너 — merge 노드: 병합 성공·승인 대기·현재 head/작성자/권한 승인 조건·러너 노드 실행 비용
# 실행: bash tests/run.sh workflow-merge
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-driver.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-driver.sh"
# shellcheck source=tests/lib-merge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-merge.sh"

# 병합 노드: 병합 조건·방식은 저장소 호스트 규칙(브랜치 보호·허용 병합 방식), 기준 브랜치·검증 명령은 저장소 사실이고, 러너가 PR 호스트에서 직접 읽은 상태로 판정한다.
# 병합 조건은 호스트 보호 규칙이다. 여기서는 승인 1·체크 1의 classic 보호를 둔다.
export FAKE_PROTECTION=classic
merge_run merge_ok "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "merge policy merges and verifies when every condition holds"
assert_contains "$(<"$FAKE_LOG")" "gh merge https://github.com/acme/app/pull/7 --squash --match-head-commit $(git -C "$DRIVER_REPO" rev-parse HEAD)" "the runner merges with the head pinned to the reviewed, pushed commit"
assert_contains "$(<"$FAKE_LOG")" "gh api repos/acme/app" "the merge method is read from the repository settings"
assert_eq "remote_ci,merge,post_merge_verify" "$(run_state '[.history[] | select(.from | IN("remote_ci", "merge", "post_merge_verify")) | .from] | join(",")')" "merge follows remote CI and is verified after"
assert_eq "1111111111111111111111111111111111111111:alice:passed" "$(run_state '"\(.merge.commit):\(.merge.approvals | join(",")):\(.post_merge.target_ci.status)"')" "the merge commit and the approvers are recorded"
assert_contains "$DRIVER_OUT" "merged: 111111111111 (squash); after merge: target_ci passed" "done reports the merge and the post-merge checks"
assert_contains "$(<"$FAKE_LOG.publish.prompt")" "Never merge (under merge the driver merges later" "the publish node still never merges by itself"
# 승인이 아직 없으면 병합하지 않고 기다리며, resume이 다시 본다.
merge_run merge_wait "$MP_BASIC"
assert_eq "30:incomplete:merge" "$DRIVER_RC:$(run_state .status):$(run_state .node)" "missing human approval waits at merge"
assert_contains "$DRIVER_OUT" "human approval: 0 of 1 on the current head" "the wait names the unmet condition"
assert_eq "0" "$(grep -c '^gh merge' "$FAKE_LOG" || true)" "nothing is merged while a condition is unmet"
touch "$FAKE_LOG.approved"
driver resume
assert_eq "0:done:1" "$DRIVER_RC:$(run_state .status):$(grep -c '^gh merge' "$FAKE_LOG")" "resume merges once the approval arrives"
# 승인은 지금 head에 대한 것이고 작성자 본인이 아니어야 한다.
merge_run merge_stale "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval of an older commit does not count"
merge_run merge_self "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "the author's own approval does not count"
merge_run merge_outsider "$MP_BASIC"
assert_eq "30:merge" "$DRIVER_RC:$(run_state .node)" "an approval from an account without write access does not count"
unset FAKE_PROTECTION
pass "merge node: host rules, repository facts, merge by the runner (approval conditions)"

# 러너 노드 실행 비용(#569): merge_ok와 같은 시나리오에서 러너(workflow-driver.sh와 그 서브셸)가 띄우는 jq 수에 상한을 둔다.
# 상태·그래프를 노드마다 jq 한 번으로 묶어 읽은 것이 다시 늘지 않게 한다. 가짜 CLI·테스트 준비가 부르는 jq는 세지 않는다.
# 기준값: 변경 전 원본 303회. 상한은 그 50%인 151회(변경 후 실측 145회). 폴링 없이 끝나는 시나리오라 실행마다 같은 수가 나온다.
JQ_COUNT_BIN="$DRIVER_TMP/jq-count-bin"
JQ_COUNT_LOG="$DRIVER_TMP/jq-count.log"
mkdir -p "$JQ_COUNT_BIN"
# shellcheck disable=SC2016  # $(...)·$PPID·$@는 만들어지는 래퍼가 실행될 때 펼친다
printf '#!/usr/bin/env bash\ncase "$(ps -o command= -p "$PPID" 2>/dev/null)" in *workflow-driver.sh*) printf "x\\n" >>%q ;; esac\nexec %q "$@"\n' \
  "$JQ_COUNT_LOG" "$(command -v jq)" >"$JQ_COUNT_BIN/jq"
chmod +x "$JQ_COUNT_BIN/jq"
export FAKE_PROTECTION=classic
: >"$JQ_COUNT_LOG"
PATH="$JQ_COUNT_BIN:$PATH" merge_run merge_jq_count "$MP_BASIC"
assert_eq "0:done" "$DRIVER_RC:$(run_state .status)" "the counted run merges and verifies like merge_ok"
JQ_CALLS="$(wc -l <"$JQ_COUNT_LOG" | tr -d ' ')"
((JQ_CALLS <= 151)) || fail "the runner starts at most 151 jq processes in the merge scenario (actual=$JQ_CALLS; 303 before #569)"
unset FAKE_PROTECTION
pass "the runner reads state and graph with few jq processes per node"

finish_tests
