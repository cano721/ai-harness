#!/usr/bin/env bash
# 회귀 테스트 — stale reset 가드(#601): PreToolUse(Bash)가 HEAD의 조상이 아닌 ref 위 git reset --soft를 막는다
# 실행: bash tests/run.sh stale-reset-guard
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# #594 모양 저장소: wip 커밋 두 개가 있는 작업 브랜치, 그사이 develop에 남의 변경(shared.txt 수정·changelog 조각 추가)이 들어와 fetch됐다.
SR="$TEST_TMP/stale-reset"
mkdir -p "$SR"
git init -q --bare "$SR/remote.git"
git init -q "$SR/seed"
git -C "$SR/seed" config user.email test@example.com
git -C "$SR/seed" config user.name test
echo v1 >"$SR/seed/shared.txt"
git -C "$SR/seed" add shared.txt
git -C "$SR/seed" commit -qm base
git -C "$SR/seed" push -q "$SR/remote.git" HEAD:refs/heads/develop
git clone -q -b develop "$SR/remote.git" "$SR/work"
git -C "$SR/work" config user.email test@example.com
git -C "$SR/work" config user.name test
git -C "$SR/work" checkout -q -b feat/601-guard
for n in 1 2; do
  echo "wip $n" >"$SR/work/feature.txt"
  git -C "$SR/work" add feature.txt
  git -C "$SR/work" commit -qm "wip $n"
done
git clone -q -b develop "$SR/remote.git" "$SR/other"
git -C "$SR/other" config user.email test@example.com
git -C "$SR/other" config user.name test
echo v2 >"$SR/other/shared.txt"
mkdir -p "$SR/other/changelog.d"
echo '- other' >"$SR/other/changelog.d/999-other.md"
git -C "$SR/other" add -A
git -C "$SR/other" commit -qm "other: shared v2 (#999)"
git -C "$SR/other" push -q origin HEAD:refs/heads/develop
git -C "$SR/work" fetch -q origin
SR_MB="$(git -C "$SR/work" merge-base HEAD origin/develop)"

STALE_HOOK="$(jq -c '.hooks.PreToolUse[] | select(.matcher == "Bash" and (.hooks[0].command | contains("stale-reset-guard")))' "$ROOT/hooks/hooks.json")"
[[ -n "$STALE_HOOK" ]] || fail "hooks.json registers no PreToolUse(Bash) stale reset guard"
STALE_CMD="$(jq -r '.hooks[0].command' <<<"$STALE_HOOK")"
SR_DATA="$TEST_TMP/stale-data"
mkdir -p "$SR_DATA"
: >"$SR_DATA/config"
run_stale_guard() { # command [cwd] → 출력(차단이면 JSON)
  jq -cn --arg c "$1" --arg d "${2-$SR/work}" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' \
    | CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$SR_DATA" /bin/sh -c "$STALE_CMD"
}

# H3: 플러그인 hook으로 등록되고 짧은 시간 안에 끝난다. 기존 PreToolUse 네 개에 하나가 더해진다.
assert_eq "3" "$(jq -r '.hooks[0].timeout' <<<"$STALE_HOOK")" "stale reset guard stays inside a short budget"
assert_contains "$STALE_CMD" "$LITERAL_PLUGIN_ROOT" "stale reset guard runs from the quoted plugin root"
assert_contains "$STALE_CMD" "scripts/stale-reset-guard.sh" "Bash PreToolUse hook runs the stale reset guard"
assert_eq "5" "$(jq '.hooks.PreToolUse | length' "$ROOT/hooks/hooks.json")" "PreToolUse has five hooks with the stale reset guard"
pass "stale reset guard is registered as a plugin PreToolUse(Bash) hook"

# H1: #594처럼 HEAD의 조상이 아닌 origin/develop 위로 soft reset하면 막고 rebase를 안내한다.
for c in "git reset --soft origin/develop" "git fetch origin && git reset --soft origin/develop" "git -C $SR/work reset -q --soft origin/develop"; do
  cwd="$SR/work"
  [[ "$c" != "git -C"* ]] || cwd="$TEST_TMP"
  out="$(run_stale_guard "$c" "$cwd")"
  assert_eq "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" "stale reset guard denies: $c"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
  assert_eq "[Stale reset guard] " "${reason:0:20}" "the reason starts with the guard prefix: $c"
  assert_contains "$reason" "git rebase origin/develop" "the reason points at rebase: $c"
  # shellcheck disable=SC2016  # 안내 문구의 $(...)를 문자 그대로 찾는다
  assert_contains "$reason" 'git reset --soft $(git merge-base HEAD origin/develop)' "the reason shows the safe squash: $c"
done
pass "soft reset onto a commit that is not an ancestor of HEAD is denied"

# H2: 자기 커밋을 합치는 reset --soft(merge-base 치환·sha·HEAD~N), rebase·hard reset·다른 명령, 풀 수 없는 경우는 통과한다.
while IFS=$'\t' read -r label command cwd; do
  [[ -n "$label" ]] || continue
  out="$(run_stale_guard "$command" "${cwd:-$SR/work}")"
  assert_eq "" "$out" "stale reset guard allows: $label"
done <<CASES
merge-base substitution	git reset --soft \$(git merge-base HEAD origin/develop)
merge-base backticks	git reset --soft \`git merge-base HEAD origin/develop\`
merge-base sha	git reset --soft $SR_MB
own wip commits	git reset --soft HEAD~2
rebase	git rebase origin/develop
hard reset	git reset --hard origin/develop
other command	ls
missing ref	git reset --soft origin/nope
reset with paths	git reset --soft origin/develop -- shared.txt
not a repository	git reset --soft origin/develop	$TEST_TMP
CASES
assert_eq "" "$(HM_STALE_RESET_GUARD=0 run_stale_guard "git reset --soft origin/develop")" "HM_STALE_RESET_GUARD=0 turns the guard off"
printf 'HM_STALE_RESET_GUARD=0\n' >"$SR_DATA/config"
assert_eq "" "$(run_stale_guard "git reset --soft origin/develop")" "the switch is read from the user config"
: >"$SR_DATA/config"
out="$(printf 'not json' | CLAUDE_PLUGIN_ROOT="$ROOT" HARNESS_METRICS_DIR="$SR_DATA" /bin/sh -c "$STALE_CMD")" && rc=0 || rc=$?
assert_eq "0:" "$rc:$out" "broken input passes (fail-open)"
pass "own squashes, rebase, other commands, and unresolvable refs pass"

finish_tests
