#!/usr/bin/env bash
# 회귀 테스트 — 도입 효과(impact)·재작업률·A/B
# 실행: bash tests/run.sh impact
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 재작업 비율: 머지 뒤 window일 안에 같은 이슈 키로 새 PR 작업이 시작되면 재작업이다. 원본 머지 전에 시작한 분할 PR은 세지 않는다.
RW_REMOTE="$TEST_TMP/rework-remote.git"
RW_REPO="$TEST_TMP/rework-repo"
git init -q --bare "$RW_REMOTE"
git init -q -b develop "$RW_REPO"
rw_commit() { # file author epoch
  printf '%s\n' "$1" >>"$RW_REPO/$1"
  git -C "$RW_REPO" add "$1"
  GIT_AUTHOR_NAME="$2" GIT_AUTHOR_EMAIL="$2@example.com" GIT_AUTHOR_DATE="@$3" \
    GIT_COMMITTER_NAME="$2" GIT_COMMITTER_EMAIL="$2@example.com" GIT_COMMITTER_DATE="@$3" \
    git -C "$RW_REPO" commit -q -m "$1"
}
rw_merge() { # branch pr epoch [title]
  local body=()
  [[ -n "${4:-}" ]] && body=(-m "$4")
  GIT_AUTHOR_NAME=bot GIT_AUTHOR_EMAIL=bot@example.com GIT_AUTHOR_DATE="@$3" \
    GIT_COMMITTER_NAME=bot GIT_COMMITTER_EMAIL=bot@example.com GIT_COMMITTER_DATE="@$3" \
    git -C "$RW_REPO" merge -q --no-ff "$1" -m "Merged in $1 (pull request #$2)" ${body[@]+"${body[@]}"}
}
DAY=86400
T0=1790000000
rw_commit base me "$T0"
# PR #1 (NJ-1): 내 PR, 머지 T0+1d. PR #2: 같은 키를 머지 하루 뒤에 시작 → 재작업.
git -C "$RW_REPO" switch -q -c feature/NJ-1; rw_commit a me $((T0 + DAY / 2)); git -C "$RW_REPO" switch -q develop; rw_merge feature/NJ-1 1 $((T0 + DAY)) "Add login form"
git -C "$RW_REPO" switch -q -c feature/NJ-1-fix; rw_commit b me $((T0 + 2 * DAY)); git -C "$RW_REPO" switch -q develop; rw_merge feature/NJ-1-fix 2 $((T0 + 3 * DAY)) "Fix login validation"
# PR #3 (NJ-2)와 #4: #4는 #3 머지 전에 시작한 분할 PR → 재작업 아님.
git -C "$RW_REPO" switch -q -c feature/NJ-2-b; rw_commit c me $((T0 + 3 * DAY)); git -C "$RW_REPO" switch -q develop
git -C "$RW_REPO" switch -q -c feature/NJ-2; rw_commit d me $((T0 + 3 * DAY + 100)); git -C "$RW_REPO" switch -q develop; rw_merge feature/NJ-2 3 $((T0 + 4 * DAY))
rw_merge feature/NJ-2-b 4 $((T0 + 5 * DAY))
# PR #5 (NJ-3): 남의 PR → --author로 제외. PR #6 (NJ-4): 후속이 8일 뒤 → window 밖.
git -C "$RW_REPO" switch -q -c feature/NJ-3; rw_commit e other $((T0 + 5 * DAY)); git -C "$RW_REPO" switch -q develop; rw_merge feature/NJ-3 5 $((T0 + 6 * DAY))
git -C "$RW_REPO" switch -q -c feature/NJ-4; rw_commit f me $((T0 + 6 * DAY)); git -C "$RW_REPO" switch -q develop; rw_merge feature/NJ-4 6 $((T0 + 7 * DAY))
git -C "$RW_REPO" switch -q -c feature/NJ-4-late; rw_commit g me $((T0 + 15 * DAY)); git -C "$RW_REPO" switch -q develop; rw_merge feature/NJ-4-late 7 $((T0 + 16 * DAY))
# PR #8 (NJ-0): 제외 키. PR #9 (NJ-5): 머지 직후라 window가 아직 안 끝남 → pending.
git -C "$RW_REPO" switch -q -c feature/NJ-0; rw_commit h me $((T0 + 16 * DAY)); git -C "$RW_REPO" switch -q develop; rw_merge feature/NJ-0 8 $((T0 + 17 * DAY))
git -C "$RW_REPO" switch -q -c feature/NJ-5; rw_commit i me $((T0 + 17 * DAY)); git -C "$RW_REPO" switch -q develop; rw_merge feature/NJ-5 9 $((T0 + 18 * DAY))
git -C "$RW_REPO" remote add origin "$RW_REMOTE"
git -C "$RW_REPO" push -q origin develop
git -C "$RW_REPO" fetch -q origin
RW="$("$ROOT/scripts/rework.sh" --repo "$RW_REPO" --author '^me@' --exclude-key NJ-0 --until "$(date -u -r $((T0 + 18 * DAY)) +%Y-%m-%d 2>/dev/null || date -u -d @$((T0 + 18 * DAY)) +%Y-%m-%d)" --now $((T0 + 19 * DAY)))"
assert_eq "7" "$(jq -r '.merged_prs' <<<"$RW")" "rework counts my merged PRs except excluded keys and other authors"
assert_eq "2" "$(jq -r '.pending_prs' <<<"$RW")" "PRs whose window is still open are pending"
assert_eq "5" "$(jq -r '.settled_prs' <<<"$RW")" "pending PRs leave the denominator"
assert_eq "1:2" "$(jq -r '[.rework[] | "\(.pr):\(.followups[0].pr)"] | join(",")' <<<"$RW")" "only a same-key PR started after the merge within the window is rework"
assert_eq "20" "$(jq -r '.rework_ratio' <<<"$RW")" "rework ratio is rework over settled PRs"
RW_WIDE="$("$ROOT/scripts/rework.sh" --repo "$RW_REPO" --author '^me@' --exclude-key NJ-0 --window 10 --now $((T0 + 40 * DAY)))"
assert_eq "1:2,6:7" "$(jq -r '[.rework[] | "\(.pr):\(.followups[0].pr)"] | join(",")' <<<"$RW_WIDE")" "a wider window catches the late follow-up"
pass "rework ratio from merge history"

# 재작업 판정: 후속 PR에 제목을 붙이고, 판정 파일(TSV)로 결함 수정(defect)만 재작업으로 센 보정값을 낸다. 판정 없는 후속은 재작업으로 둔다.
assert_eq "Add login form|Fix login validation|Merged in feature/NJ-4 (pull request #6)" \
  "$(jq -r '[.rework[0].title, .rework[0].followups[0].title, .rework[1].title] | join("|")' <<<"$RW_WIDE")" "rework titles come from the merge body first line, else the subject"
assert_eq "false" "$(jq -r 'has("judged_ratio") or has("judged_rework_prs") or has("unjudged")' <<<"$RW_WIDE")" "without --judgments no judged keys appear"
RW_J="$TEST_TMP/rework-judgments.tsv"
printf '# repo\torig\tfollowup\tverdict\tnote\n\nrework-repo\t1\t2\tscope\tagreed extra field\n' >"$RW_J"
RW_JUDGED="$("$ROOT/scripts/rework.sh" --repo "$RW_REPO" --author '^me@' --exclude-key NJ-0 --window 10 --now $((T0 + 40 * DAY)) --judgments "$RW_J")"
assert_eq "28.6|1|14.3|rework-repo:6:7" \
  "$(jq -r '"\(.rework_ratio)|\(.judged_rework_prs)|\(.judged_ratio)|\([.unjudged[] | "\(.repo):\(.pr):\(.followup)"] | join(","))"' <<<"$RW_JUDGED")" "non-defect follow-ups leave judged rework, unjudged ones stay"
assert_eq "scope:agreed extra field|null" "$(jq -r '"\(.rework[0].followups[0].verdict):\(.rework[0].followups[0].note)|\(.rework[1].followups[0].verdict)"' <<<"$RW_JUDGED")" "follow-ups carry their verdict"
printf 'rework-repo\t1\t2\tdefect\nrework-repo\t06\t7\tplanned\n' >"$RW_J"
assert_eq "1|14.3|0" "$("$ROOT/scripts/rework.sh" --repo "$RW_REPO" --author '^me@' --exclude-key NJ-0 --window 10 --now $((T0 + 40 * DAY)) --judgments "$RW_J" | jq -r '"\(.judged_rework_prs)|\(.judged_ratio)|\(.unjudged | length)"')" "a defect follow-up keeps the rework"
printf 'rework-repo\t1\t2\tbug\n' >"$RW_J"
RW_RC=0; "$ROOT/scripts/rework.sh" --repo "$RW_REPO" --judgments "$RW_J" >/dev/null 2>&1 || RW_RC=$?
assert_eq "2" "$RW_RC" "an unknown verdict is a usage error"
RW_RC=0; "$ROOT/scripts/rework.sh" --repo "$RW_REPO" --judgments "$TEST_TMP/no-such.tsv" >/dev/null 2>&1 || RW_RC=$?
assert_eq "2" "$RW_RC" "a missing judgments file is a usage error"
pass "rework judgments"

# harness-impact: 설치일 기준 전후 비교. 설치일은 harness.json initialized → AGENTS.md 첫 커밋 → --at 순으로 정한다. (#197)
IMPACT_DATA="$TEST_TMP/impact-data"
IMPACT_REPO="$TEST_TMP/impact-repo"
mkdir -p "$IMPACT_DATA/events" "$IMPACT_DATA/digests" "$IMPACT_REPO/.ai-harness"
printf '%s\n' '{"project_id":"svc","level":"standard","initialized":"2026-10-01"}' >"$IMPACT_REPO/.ai-harness/harness.json"
impact_session() { # sid date turns model [events-json...]
  local sid="$1" d="$2" turns="$3" model="$4"; shift 4
  {
    jq -cn --arg sid "$sid" --arg d "$d" --argjson t "$turns" --arg m "$model" '{v:3, src:"claude", sid:$sid, project:"svc", kind:"session",
      started:($d+"T01:00:00Z"), ended:($d+"T01:30:00Z"), turns:$t, tok_out:100, ctx_peak:5000, model:$m,
      coverage:["workflow","doc_read","error","guard_block","permission_deny","compact"]}'
    for ev in "$@"; do
      jq -cn --arg sid "$sid" --argjson e "$ev" '{v:3, src:"claude", sid:$sid, project:"svc", n:1} + $e'
    done
  } >"$IMPACT_DATA/events/claude-$sid.jsonl"
}
impact_session b1 2026-09-20 20 claude-opus-5-5 '{"kind":"error","n":3}' '{"kind":"jira_issue","target":"NJ-1","n":2}' '{"kind":"jira_issue","target":"NJ-9","n":1}'
impact_session b2 2026-09-25 22 claude-opus-5-5 '{"kind":"jira_issue","target":"NJ-1","n":1}'
impact_session a1 2026-10-05 8 claude-opus-5-5 '{"kind":"guard_block","n":2}' '{"kind":"doc_read","target":".ai-harness/docs/testing.md"}' '{"kind":"jira_issue","target":"NJ-2","n":1}'
impact_session a2 2026-10-20 10 claude-opus-5-5 '{"kind":"workflow","target":"ai-harness:implement-feature"}' '{"kind":"jira_issue","target":"NJ-3","n":1}'
# 설치 전 구간 밖과 다른 프로젝트·내부 세션은 세지 않는다.
impact_session old 2026-08-01 30 claude-opus-5-5
jq -cn '{v:3, src:"claude", sid:"other", project:"else", kind:"session", started:"2026-10-06T01:00:00Z", ended:"2026-10-06T02:00:00Z", turns:9}' \
  >"$IMPACT_DATA/events/claude-other.jsonl"
jq -cn '{v:3, src:"claude", sid:"int", project:"svc", kind:"session", internal:true, started:"2026-10-06T01:00:00Z", ended:"2026-10-06T02:00:00Z", turns:9}' \
  >"$IMPACT_DATA/events/claude-int.jsonl"
seed_correction_digest "$IMPACT_DATA" "$IMPACT_DATA/events/claude-b1.jsonl" 3
seed_correction_digest "$IMPACT_DATA" "$IMPACT_DATA/events/claude-b2.jsonl" 3
seed_correction_digest "$IMPACT_DATA" "$IMPACT_DATA/events/claude-a1.jsonl" 1
seed_correction_digest "$IMPACT_DATA" "$IMPACT_DATA/events/claude-a2.jsonl" 0
mkdir -p "$IMPACT_DATA/harvest-queue/$(hm_project_key svc)" "$IMPACT_DATA/applied"
jq -cn '{v:1, project:"svc", reviewed_at:"2026-10-10T00:00:00Z", review:{outcome:"improved", summary:"테스트 먼저 규칙 추가", expected:"재발 0", artifact:"https://example.com/pr/1"}},
  {v:1, project:"svc", reviewed_at:"2026-10-12T00:00:00Z", review:{outcome:"no-change", summary:"근거 부족"}}' \
  >"$IMPACT_DATA/harvest-queue/$(hm_project_key svc)/review-history.jsonl"
jq -cn '{at:"2026-10-15T00:00:00Z", event:"applied", id:"g1", scope:"global", project:"_global", text:"전역 규칙"},
  {at:"2026-10-16T00:00:00Z", event:"applied", id:"w1", scope:"workspace", project:"else", text:"남의 규칙"}' \
  >"$IMPACT_DATA/applied/applied.jsonl"

IMPACT_JSON="$(HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root "$IMPACT_REPO" --today 2026-10-30)"
assert_eq "2026-10-01 harness.json svc" "$(jq -r '"\(.installed.date) \(.installed.source) \(.project)"' <<<"$IMPACT_JSON")" "impact reads install date from harness.json"
assert_eq "2026-09-01 2026-10-01 2026-10-01 2026-10-31 30" \
  "$(jq -r '"\(.periods.before.since) \(.periods.before.until) \(.periods.after.since) \(.periods.after.until) \(.window_days)"' <<<"$IMPACT_JSON")" \
  "impact compares equal windows on both sides of the install date"
assert_eq "2 2" "$(jq -r '"\(.periods.before.sessions) \(.periods.after.sessions)"' <<<"$IMPACT_JSON")" "impact counts only this project's non-internal sessions in each window"
assert_eq "21 9" "$(jq -r '"\(.periods.before.turns_median) \(.periods.after.turns_median)"' <<<"$IMPACT_JSON")" "impact reports median turns per active session"
assert_eq "1 42 2 2 9 1" "$(jq -r '[.periods.before.tasks, .periods.before.task_turns_median, .periods.before.task_sessions_median,
  .periods.after.tasks, .periods.after.task_turns_median, .periods.after.task_sessions_median] | map(tostring) | join(" ")' <<<"$IMPACT_JSON")" \
  "impact groups sessions into tasks by their most-mentioned issue key"
assert_eq "1" "$(jq -r '.periods.before.task_hours_median' <<<"$IMPACT_JSON")" "impact measures task time as the sum of its session durations"
assert_eq "6 3 1 0.5" "$(jq -r '"\(.periods.before.corrections) \(.periods.before.corrections_per_session) \(.periods.after.corrections) \(.periods.after.corrections_per_session)"' <<<"$IMPACT_JSON")" \
  "impact counts digest corrections per digested session"
assert_eq "0 2 1.5 0" "$(jq -r '"\(.periods.before.guard_blocks) \(.periods.after.guard_blocks) \(.periods.before.errors_per_session) \(.periods.after.errors_per_session)"' <<<"$IMPACT_JSON")" \
  "impact reports guard blocks and errors per session"
assert_eq "6 1 false" "$(jq -r '"\(.corrections.before.items | length) \(.corrections.after.total) \(.corrections.before.truncated)"' <<<"$IMPACT_JSON")" "impact lists correction summaries for grouping"
assert_eq "2026-09-14 2026-09-21 2026-10-05 2026-10-19" "$(jq -r '[.weekly[] | select(.sessions > 0) | .week] | join(" ")' <<<"$IMPACT_JSON")" "impact buckets sessions by Monday week"
assert_eq "harvest:테스트 먼저 규칙 추가 rule:전역 규칙" "$(jq -r '[.timeline[] | "\(.kind):\(.summary)"] | join(" ")' <<<"$IMPACT_JSON")" \
  "impact timeline keeps improved harvests and global or own rules"
assert_eq "2 2" "$(jq -r '"\(.adoption.harness_sessions) \(.adoption.active_sessions)"' <<<"$IMPACT_JSON")" "impact adoption counts sessions that used the harness after install"
assert_contains "$(jq -r '.warnings | join(",")' <<<"$IMPACT_JSON")" "low_sample" "impact warns when either window has few sessions"
case "$(jq -r '.warnings | join(",")' <<<"$IMPACT_JSON")" in *model_shift*) fail "same model mix is not a model shift" ;; esac

# 설치 직후면 지난 날만큼만 양쪽을 맞춘다.
assert_eq "2026-09-21 2026-10-11 10" "$(HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root "$IMPACT_REPO" --today 2026-10-10 \
  | jq -r '"\(.periods.before.since) \(.periods.after.until) \(.window_days)"')" "impact shortens both windows right after install"
# 설치가 오래됐으면 후 구간은 최근 window일이고, 전 구간은 그대로 설치일 직전이다.
assert_eq "2026-09-01 2026-10-01 2026-12-01 2026-12-31 gap" "$(HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root "$IMPACT_REPO" --today 2026-12-30 \
  | jq -r '"\(.periods.before.since) \(.periods.before.until) \(.periods.after.since) \(.periods.after.until) \(.warnings | map(select(. == "gap")) | join(""))"')" \
  "impact compares the latest window with the days just before install"
# --at이 harness.json보다 우선하고, harness.json이 없으면 AGENTS.md 첫 커밋 날짜를 쓴다.
assert_eq "2026-09-25 at" "$(HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root "$IMPACT_REPO" --project svc --at 2026-09-25 --today 2026-10-30 \
  | jq -r '"\(.installed.date) \(.installed.source)"')" "impact --at overrides the recorded install date"
IMPACT_GIT="$TEST_TMP/impact-git"
mkdir -p "$IMPACT_GIT"
git -C "$IMPACT_GIT" init -q
printf 'rules\n' >"$IMPACT_GIT/AGENTS.md"
git -C "$IMPACT_GIT" add AGENTS.md
GIT_AUTHOR_DATE=2026-09-15T00:00:00Z GIT_COMMITTER_DATE=2026-09-15T00:00:00Z \
  git -C "$IMPACT_GIT" -c user.email=t@example.com -c user.name=t commit -q -m harness
assert_eq "2026-09-15 agents_md_commit" "$(HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root "$IMPACT_GIT" --project svc --today 2026-10-30 \
  | jq -r '"\(.installed.date) \(.installed.source)"')" "impact falls back to the first AGENTS.md commit"
if HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root "$TEST_TMP/impact-none" --project svc >/dev/null 2>&1; then
  fail "impact fails without any install date"
fi
assert_contains "$(HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root "$IMPACT_REPO" --project svc --at 2026-08-15 --today 2026-08-20 | jq -r '.warnings | join(",")')" \
  "before_missing" "impact flags an empty before window"
pass "impact compares windows around the install date"

# 리포트: 데이터와 에이전트가 묶은 하이라이트를 오프라인 HTML 한 파일에 싣는다. 데이터 속 </script>로 페이지를 깨지 못한다.
IMPACT_DATA_FILE="$TEST_TMP/impact.json"
jq '.corrections.before.items[0].summary = "</script><script>alert(1)</script>"' <<<"$IMPACT_JSON" >"$IMPACT_DATA_FILE"
printf '%s\n' '{"headline":"같은 지적이 줄었어요","groups":[{"label":"테스트 먼저","before":3,"after":0}],"cases":[]}' >"$TEST_TMP/impact-hl.json"
IMPACT_HTML="$TEST_TMP/impact.html"
HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" render --data "$IMPACT_DATA_FILE" --highlights "$TEST_TMP/impact-hl.json" --out "$IMPACT_HTML" >/dev/null
assert_file "$IMPACT_HTML"
IMPACT_HTML_CONTENT="$(cat "$IMPACT_HTML")"
assert_contains "$IMPACT_HTML_CONTENT" "같은 지적이 줄었어요" "report embeds the headline"
assert_contains "$IMPACT_HTML_CONTENT" '"installed"' "report embeds the compare data"
case "$IMPACT_HTML_CONTENT" in *"</script><script>alert"*) fail "report escapes </script> inside embedded data" ;; esac
# 화면이 밖으로 보내도 되는 요청은 디자인 토큰의 글꼴 파일 하나뿐이다(#287): 버전 고정, 못 받으면 시스템 글꼴.
DS_FONT_URL='https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/packages/pretendard/dist/web/variable/woff2/PretendardVariable.woff2'
case "${IMPACT_HTML_CONTENT//"$DS_FONT_URL"/}" in *"https://cdn"*|*"<script src="*|*"<link rel=\"stylesheet\" href=\"http"*) fail "report loads nothing from the network except the pinned font" ;; esac
assert_eq "1" "$(grep -c '__IMPACT_DATA__' "$ROOT/skills/harness-impact/report-template.html")" "template has one data placeholder"
case "$IMPACT_HTML_CONTENT" in *__IMPACT_DATA__*|*__IMPACT_HIGHLIGHTS__*) fail "report fills every placeholder" ;; esac
HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" render --data "$IMPACT_DATA_FILE" --out "$TEST_TMP/impact-nohl.html" >/dev/null
assert_contains "$(cat "$TEST_TMP/impact-nohl.html")" "const HIGHLIGHTS = null" "report renders without highlights"
pass "impact renders an offline report"

# 판단 근거: 개선별 재발 추적(근거 batch → 반영 뒤 세션), 가드 차단 사례, missing_context 추이. (#209)
EV_DATA="$TEST_TMP/impact-ev-data"
EV_REPO="$TEST_TMP/impact-ev-repo"
mkdir -p "$EV_DATA/events" "$EV_DATA/digests" "$EV_REPO/.ai-harness" "$EV_DATA/harvest-queue/$(hm_project_key ev)"
printf '%s\n' '{"project_id":"ev","initialized":"2026-10-01"}' >"$EV_REPO/.ai-harness/harness.json"
ev_session() { # sid date coverage-json findings-json|"" [events-json...]
  local sid="$1" d="$2" cov="$3" findings="$4"; shift 4
  {
    jq -cn --arg sid "$sid" --arg d "$d" --argjson cov "$cov" '{v:3, src:"claude", sid:$sid, project:"ev", kind:"session",
      started:($d+"T01:00:00Z"), ended:($d+"T01:30:00Z"), turns:6, model:"m", coverage:$cov}'
    for ev in "$@"; do jq -cn --arg sid "$sid" --argjson e "$ev" '{v:3, src:"claude", sid:$sid, project:"ev", n:1} + $e'; done
  } >"$EV_DATA/events/claude-$sid.jsonl"
  [[ -z "$findings" ]] || jq -cn --argjson f "$findings" '{v:2, findings:$f}' >"$EV_DATA/digests/claude-$sid.json"
}
EV_OLD='["error","guard_block"]'
EV_NEW='["error","guard_block","guard_sample"]'
ev_session b1 2026-10-03 "$EV_OLD" '[{"category":"correction","summary":"커버리지 게이트를 CI에서야 발견"},{"category":"missing_context","summary":"테스트 TZ를 모름"}]' '{"kind":"guard_block","n":2}'
ev_session b2 2026-10-04 "$EV_OLD" '[{"category":"workflow_gap","summary":"커버리지 100% 게이트 늦게 확인"}]'
ev_session b3 2026-10-05 "$EV_OLD" ""
ev_session a1 2026-10-11 "$EV_NEW" '[{"category":"missing_context","summary":"배포 절차를 모름"}]' \
  '{"kind":"guard_block","n":1}' '{"kind":"guard_sample","target":"Edit: [Direct edit guard] src/a.ts 수정 전에 docs를 먼저 Read 하세요.","n":1}'
for i in 2 3 4; do ev_session "a$i" "2026-10-1$i" "$EV_NEW" '[]'; done
ev_session a5 2026-10-15 "$EV_NEW" '[{"category":"correction","summary":"또 커버리지 게이트를 PR에서 발견"}]'
jq -cn '{v:1, project:"ev", reviewed_at:"2026-10-10T00:00:00Z", markers:["claude-b1.json","claude-b2.json","claude-b3.json"],
    review:{outcome:"improved", summary:"커버리지 게이트 선검증", expected:"재발 0", artifact:"https://example.com/pr/7", change:"add"}},
  {v:1, project:"ev", reviewed_at:"2026-10-20T00:00:00Z", review:{outcome:"improved", summary:"마커 없는 옛 기록", expected:"재발 0"}}' \
  >"$EV_DATA/harvest-queue/$(hm_project_key ev)/review-history.jsonl"
EV_JSON="$(HARNESS_METRICS_DIR="$EV_DATA" "$ROOT/scripts/impact.sh" compare --root "$EV_REPO" --today 2026-10-30)"
assert_eq "h1 batch 3 2 3 5 2" "$(jq -r '.improvements[0] | "\(.id) \(.before.basis) \(.before.batch_sessions) \(.before.observed) \(.before.candidates.items | length) \(.after.observed) \(.after.candidates.items | length)"' <<<"$EV_JSON")" \
  "impact tracks each improvement from its evidence batch to the digested sessions after it"
assert_eq "claude-b2#0 claude-b1#1 claude-b1#0" "$(jq -r '[.improvements[0].before.candidates.items[].id] | join(" ")' <<<"$EV_JSON")" \
  "impact candidate ids point at a finding in a session digest, newest first"
assert_eq "2026-09-10 2 3 null" "$(jq -r '"\(.improvements[0].before.window | "\(.since) \(.observed) \(.candidates.items | length)") \(.improvements[1].before.window)"' <<<"$EV_JSON")" \
  "impact adds a 30-day window baseline of all digested sessions next to a batch baseline"
assert_eq "h2 window 2026-09-20 0" "$(jq -r '.improvements[1] | "\(.id) \(.before.basis) \(.before.since) \(.after.observed)"' <<<"$EV_JSON")" \
  "impact falls back to the days before an improvement that has no batch markers"
assert_eq "2 0.29" "$(jq -r '.periods.after | "\(.missing_context) \(.missing_context_per_session)"' <<<"$EV_JSON")" \
  "impact counts missing-context findings per digested session"
assert_eq "테스트 TZ를 모름" "$(jq -r '.missing_context.after.items | last | .summary' <<<"$EV_JSON")" "impact lists missing-context summaries"
assert_eq "true" "$(jq -r '[.weekly[] | has("missing_context_per_session")] | all' <<<"$EV_JSON")" "impact weekly series carries missing context"
assert_eq "1 2 Edit: [Direct edit guard] src/a.ts" "$(jq -r '.periods.after | "\(.guard_samples | length) \(.guard_blocks_unsampled) \(.guard_samples[0].target | .[0:34])"' <<<"$EV_JSON")" \
  "impact shows what the guard blocked and counts blocks recorded before samples existed"

# 판정은 render가 계산한다: 후보에 없는 id는 버리고, 세션 단위로 세며, 관측이 적으면 보류한다.
EV_FILE="$TEST_TMP/impact-ev.json"
printf '%s\n' "$EV_JSON" >"$EV_FILE"
ev_verdict() { # highlights-json → "verdict before after" per improvement
  printf '%s\n' "$1" >"$TEST_TMP/impact-ev-hl.json"
  HARNESS_METRICS_DIR="$EV_DATA" "$ROOT/scripts/impact.sh" render --data "$EV_FILE" --highlights "$TEST_TMP/impact-ev-hl.json" --out "$TEST_TMP/impact-ev.html" >/dev/null
  sed -n 's/^const DATA = \(.*\);$/\1/p' "$TEST_TMP/impact-ev.html" | jq -r '[.improvements[].result | "\(.verdict):\(.before_hits // "-"):\(.after_hits // "-")"] | join(" ")'
}
# 맞춰 보지 않은 h2는 반영 뒤 관측 세션이 0이라 "판단 보류"다(5개 이상이면 "판정 안 함").
assert_eq "reduced:2:1 hold:-:-" "$(ev_verdict '{"improvements":[{"id":"h1","label":"커버리지 게이트","before":["claude-b1#0","claude-b2#0","claude-b1#0","claude-zz#9"],"after":["claude-a5#0"]}]}')" \
  "impact verdict counts sessions, ignores unknown ids, and holds unmatched improvements with few sessions"
assert_eq "unmatched hold" "$(jq -rn -L "$ROOT/scripts" 'include "impact-evidence"; [pending_verdict(5), pending_verdict(4)] | join(" ")')" \
  "an unmatched improvement is held below the observed minimum and left unjudged above it"
assert_eq "gone:2:0 no_baseline:0:0" "$(ev_verdict '{"improvements":[{"id":"h1","before":["claude-b1#0","claude-b2#0"],"after":[]},{"id":"h2","before":[],"after":[]}]}')" \
  "impact verdict says gone only with a baseline"
assert_eq "hold recurred recurred reduced" "$(jq -rn -L "$ROOT/scripts" 'include "impact-evidence"; [verdict(2; 0; 3; 10), verdict(2; 1; 3; 10), verdict(1; 3; 5; 2), verdict(5; 1; 5; 10)] | join(" ")')" \
  "impact holds judgment on few observed sessions unless the pattern recurred, and compares rates otherwise"
case "$(cat "$TEST_TMP/impact-ev.html")" in *'"candidates"'*) fail "report drops the candidate pool and keeps only matched examples" ;; esac
# batch는 문제로 뽑힌 표본이다: window를 맞췄으면 같은 정의(정리된 세션 전부)의 비율로 판정한다.
# window 2세션 중 1 → 0.5, 반영 뒤 5세션 중 1 → 0.2 = reduced. batch 기준(2/2=1.0)이었어도 reduced지만 baseline이 바뀐다.
ev_baseline() {
  printf '%s\n' "$1" >"$TEST_TMP/impact-ev-hl.json"
  HARNESS_METRICS_DIR="$EV_DATA" "$ROOT/scripts/impact.sh" render --data "$EV_FILE" --highlights "$TEST_TMP/impact-ev-hl.json" --out "$TEST_TMP/impact-ev.html" >/dev/null
  sed -n 's/^const DATA = \(.*\);$/\1/p' "$TEST_TMP/impact-ev.html" | jq -r '.improvements[0].result | "\(.verdict) \(.baseline) \(.window_hits)"'
}
assert_eq "reduced window 1" "$(ev_baseline '{"improvements":[{"id":"h1","before":["claude-b1#0","claude-b2#0"],"window":["claude-b1#0"],"after":["claude-a5#0"]}]}')" \
  "impact compares against the window baseline when the agent matched it"
assert_eq "reduced batch null" "$(ev_baseline '{"improvements":[{"id":"h1","before":["claude-b1#0","claude-b2#0"],"after":["claude-a5#0"]}]}')" \
  "impact falls back to the batch baseline and says so"
assert_contains "$(cat "$TEST_TMP/impact-ev.html")" "문제로 뽑힌 표본" "impact report states the selection bias of the evidence batch"
pass "impact evidence per improvement, guard cases, and missing context"

# 후보 상한은 최신을 남기고, 반영 뒤가 잘리면 "사라짐"을 "판단 보류"로 내린다.
CAP_DATA="$TEST_TMP/impact-cap-data"
mkdir -p "$CAP_DATA/events" "$CAP_DATA/digests" "$CAP_DATA/harvest-queue/$(hm_project_key ev)"
cp "$EV_DATA/harvest-queue/$(hm_project_key ev)/review-history.jsonl" "$CAP_DATA/harvest-queue/$(hm_project_key ev)/"
cp "$EV_DATA/events/claude-b1.jsonl" "$EV_DATA/events/claude-b2.jsonl" "$CAP_DATA/events/"
cp "$EV_DATA/digests/claude-b1.json" "$EV_DATA/digests/claude-b2.json" "$CAP_DATA/digests/"
for i in $(seq 1 31); do
  d="2026-10-$((10 + (i % 20)))"
  jq -cn --arg sid "c$i" --arg d "$d" '{v:3, src:"claude", sid:$sid, project:"ev", kind:"session",
    started:($d+"T02:00:00Z"), ended:($d+"T02:30:00Z"), turns:6, model:"m", coverage:["error"]}' >"$CAP_DATA/events/claude-c$i.jsonl"
  jq -cn --arg d "$d" '{v:2, findings:[range(10) | {category:"workflow_gap", summary:"잡일 \(.) \($d)"}]}' >"$CAP_DATA/digests/claude-c$i.json"
done
CAP_JSON="$(HARNESS_METRICS_DIR="$CAP_DATA" "$ROOT/scripts/impact.sh" compare --root "$EV_REPO" --today 2026-10-30)"
assert_eq "true 300 2026-10-29" "$(jq -r '.improvements[0].after.candidates | "\(.truncated) \(.items | length) \(.items[0].date)"' <<<"$CAP_JSON")" \
  "impact keeps the newest candidates when more than 300 findings follow an improvement"
printf '%s\n' "$CAP_JSON" >"$TEST_TMP/impact-cap.json"
printf '%s\n' '{"improvements":[{"id":"h1","before":["claude-b1#0"],"after":[]}]}' >"$TEST_TMP/impact-cap-hl.json"
HARNESS_METRICS_DIR="$CAP_DATA" "$ROOT/scripts/impact.sh" render --data "$TEST_TMP/impact-cap.json" --highlights "$TEST_TMP/impact-cap-hl.json" --out "$TEST_TMP/impact-cap.html" >/dev/null
assert_eq "hold true" "$(sed -n 's/^const DATA = \(.*\);$/\1/p' "$TEST_TMP/impact-cap.html" | jq -r '.improvements[0].result | "\(.verdict) \(.after_truncated)"')" \
  "impact holds a gone verdict when the after list was truncated"
pass "impact candidate cap keeps the newest findings"

# 하이라이트가 객체가 아니면 없는 것으로 보고 리포트를 만든다. 옛 compare JSON(improvements 없음)도 그린다.
printf '%s\n' '[1,2]' >"$TEST_TMP/impact-bad-hl.json"
HARNESS_METRICS_DIR="$EV_DATA" "$ROOT/scripts/impact.sh" render --data "$EV_FILE" --highlights "$TEST_TMP/impact-bad-hl.json" --out "$TEST_TMP/impact-bad.html" >/dev/null 2>&1 \
  || fail "impact render accepts non-object highlights"
assert_contains "$(cat "$TEST_TMP/impact-bad.html")" "const HIGHLIGHTS = null" "impact render ignores array highlights"
printf '%s\n' '"text"' >"$TEST_TMP/impact-bad-hl.json"
HARNESS_METRICS_DIR="$EV_DATA" "$ROOT/scripts/impact.sh" render --data "$EV_FILE" --highlights "$TEST_TMP/impact-bad-hl.json" --out "$TEST_TMP/impact-bad.html" >/dev/null 2>&1 \
  || fail "impact render accepts string highlights"
jq 'del(.improvements, .missing_context, .timeline)' "$EV_FILE" >"$TEST_TMP/impact-old.json"
HARNESS_METRICS_DIR="$EV_DATA" "$ROOT/scripts/impact.sh" render --data "$TEST_TMP/impact-old.json" --out "$TEST_TMP/impact-old.html" >/dev/null \
  || fail "impact render draws an old compare JSON without improvements"
assert_eq "[]" "$(sed -n 's/^const DATA = \(.*\);$/\1/p' "$TEST_TMP/impact-old.html" | jq -c '.improvements')" "impact render treats missing improvements as none"
pass "impact render tolerates odd inputs"

# 비교 가능성·추세·저장소 상태는 집계 쪽(impact-assess.jq)이 정한다. 보드와 리포트는 그 값을 그대로 쓴다. (#260)
# 설치 전 정리된 세션이 없으면 0 → N을 비교하지 않고 이유를 낸다. 표본이 충분할 때만 증감을 낸다.
assess_q() { jq -rn -L "$ROOT/scripts" --argjson d "$1" "include \"impact-assess\"; \$d | $2"; }
ASSESS_P='{"periods":{"before":{"sessions":12,"digested_sessions":0,"corrections_per_session":null,"missing_context_per_session":null,"guard_blocks":0},
  "after":{"sessions":30,"digested_sessions":18,"corrections_per_session":0.8,"missing_context_per_session":6.4,"guard_blocks":4}},"weekly":[],"rework":null}'
assert_eq "false no_baseline_digests null|false after_only|false no_rework" \
  "$(assess_q "$ASSESS_P" 'assess.metrics | "\(.corrections_per_session | "\(.comparable) \(.reason) \(.change)")|\(.guard_blocks | "\(.comparable) \(.reason)")|\(.rework | "\(.comparable) \(.reason)")"')" \
  "impact does not compare a metric whose before window has no digested sessions"
assert_eq "false no_baseline_sessions" \
  "$(assess_q "$ASSESS_P" '.periods.before.sessions = 0 | assess.metrics.corrections_per_session | "\(.comparable) \(.reason)"')" \
  "impact says the before window had no sessions at all"
assert_eq "false few_digests" \
  "$(assess_q "$ASSESS_P" '.periods.before.digested_sessions = 3 | .periods.before.corrections_per_session = 0.5 | assess.metrics.corrections_per_session | "\(.comparable) \(.reason)"')" \
  "impact does not compare a metric with few digested sessions on either side"
assert_eq "true null down|true null flat|true null up" \
  "$(assess_q "$ASSESS_P" '.periods.before.digested_sessions = 10 | [.periods.before.corrections_per_session = (1.3, 0.8, 0.3)
    | assess.metrics.corrections_per_session | "\(.comparable) \(.reason) \(.change)"] | join("|")')" \
  "impact compares a metric when both windows have enough digested sessions"
assert_eq "false few_prs null|true null down" \
  "$(assess_q "$ASSESS_P" '[.rework = ({before:{rework_ratio:0, settled_prs:3}, after:{rework_ratio:40, settled_prs:20}}, {before:{rework_ratio:40, settled_prs:12}, after:{rework_ratio:10, settled_prs:20}})
    | assess.metrics.rework | "\(.comparable) \(.reason) \(.change)"] | join("|")')" \
  "impact compares rework only with enough settled PRs on both sides"

# 추세: 설치 후 최근 주에서 정리된 세션이 있는 주의 앞 절반과 뒤 절반 비율을 맞댄다. 설치 전 주와 정리 1개뿐인 주는 빼고, 모자라면 데이터 부족.
assess_week() { jq -cn --arg w "$1" --argjson a "$2" --argjson d "$3" --argjson c "$4" \
  '{week:$w, after_install:$a, sessions:$d, digested_sessions:$d, corrections:$c, corrections_per_session:(if $d == 0 then null else $c / $d end), missing_context:0, missing_context_per_session:0}'; }
ASSESS_W="[$(assess_week 2026-09-28 false 4 40),$(assess_week 2026-10-05 true 4 4),$(assess_week 2026-10-12 true 1 9),$(assess_week 2026-10-19 true 4 4),$(assess_week 2026-10-26 true 4 1),$(assess_week 2026-11-02 true 4 0)]"
assert_eq "down 4 16 1 0.13 2026-10-05" \
  "$(assess_q "$ASSESS_P" ".weekly = $ASSESS_W | assess.trends.corrections_per_session | \"\(.verdict) \(.weeks) \(.digested) \(.first) \(.last) \(.series[0].week)\"")" \
  "impact trend compares the first and last half of digested after-install weeks"
assert_eq "up flat insufficient" \
  "$(assess_q "$ASSESS_P" ".weekly = $ASSESS_W | [(.weekly | map(.corrections = (if .week >= \"2026-10-26\" then 4 else 1 end))), (.weekly | map(.corrections = 2)), (.weekly | .[0:4])] as \$v
    | [\$v[] as \$w | .weekly = \$w | assess.trends.corrections_per_session.verdict] | join(\" \")")" \
  "impact trend says up, flat, or not enough data"
# 3주(3·3·4세션)면 앞·뒤 절반이 각 1주라 표본이 작다 — 판정하지 않는다. 비율 값이 비면 비교하지 않는다.
assert_eq "insufficient no_value" "$(assess_q "$ASSESS_P" "(${ASSESS_W}[1:5] | .[1].digested_sessions = 0 | .[0].digested_sessions = 3 | .[2].digested_sessions = 3) as \$w
  | (.weekly = \$w | assess.trends.corrections_per_session.verdict),
    (.periods.before.digested_sessions = 10 | assess.metrics.corrections_per_session.reason)" | tr '\n' ' ' | sed 's/ $//')" \
  "impact trend needs enough sessions in each half, and a metric needs values on both sides"
assert_eq "5" "$(assess_q "$ASSESS_P" ".weekly = $ASSESS_W | assess.trends.corrections_per_session.series | length")" "impact trend series lists the recent after-install weeks it looked at"

# 저장소 상태: 효과(개선 사라짐·줄어듦, 줄어드는 추세, 비교 가능한 감소)와 나쁜 신호(재발, 느는 추세)로 정하고, 신호가 없으면 왜 모르는지 남긴다.
assert_eq "effective mixed attention watching insufficient no_sessions" \
  "$(assess_q "$ASSESS_P" "[
    (.weekly = $ASSESS_W | .improvements = []),
    (.weekly = $ASSESS_W | .improvements = [{result:{verdict:\"recurred\"}}]),
    (.improvements = [{result:{verdict:\"recurred\"}}]),
    (.weekly = (\$d.weekly + [${ASSESS_W}[] | .corrections = 2]) | .improvements = [{result:{verdict:\"hold\"}}]),
    (.improvements = [{result:{verdict:\"unmatched\"}}]),
    (.periods.after.sessions = 0 | .improvements = [])]
    | map(assess_status.key) | join(\" \")")" \
  "impact sums each repo into effective, mixed, attention, watching, insufficient, or no recent sessions"
assert_eq "no_baseline few_recent_digests unmatched_improvements:1" \
  "$(assess_q "$ASSESS_P" '.improvements = [{result:{verdict:"unmatched"}}] | assess_status.gaps | map(if .n then "\(.why):\(.n)" else .why end) | join(" ")')" \
  "impact says why a repo has no answer yet"
assert_eq "insufficient no_baseline_improvements:1" \
  "$(assess_q "$ASSESS_P" '.improvements = [{result:{verdict:"no_baseline"}}] | assess_status | "\(.key) \(.gaps | map(select(.why == "no_baseline_improvements")) | map("\(.why):\(.n)") | join(""))"')" \
  "impact does not count an improvement without a baseline as being watched"

# compare·render·view가 같은 값을 싣는다. EV는 설치 전 정리된 세션이 없다.
assert_eq "false no_baseline_sessions false after_only" \
  "$(jq -r '.assessment.metrics | "\(.corrections_per_session.comparable) \(.corrections_per_session.reason) \(.guard_blocks.comparable) \(.guard_blocks.reason)"' <<<"$EV_JSON")" \
  "impact compare carries comparability per metric"
assert_eq "few_digests" "$(jq -r '.assessment.metrics.missing_context_per_session.reason' <<<"$IMPACT_JSON")" "impact compare flags few digested sessions"
EV_VIEW="$(HARNESS_METRICS_DIR="$EV_DATA" "$ROOT/scripts/impact.sh" view --data "$EV_FILE")"
HARNESS_METRICS_DIR="$EV_DATA" "$ROOT/scripts/impact.sh" render --data "$EV_FILE" --highlights "$(jq -r '.highlights.file' <<<"$EV_VIEW")" --out "$TEST_TMP/impact-assess.html" >/dev/null
assert_eq "$(jq -c '.assessment' <<<"$EV_VIEW")" "$(sed -n 's/^const DATA = \(.*\);$/\1/p' "$TEST_TMP/impact-assess.html" | jq -c '.assessment')" \
  "impact report and view carry the same assessment"
assert_eq "effective" "$(jq -r '.assessment.status.key' <<<"$EV_VIEW")" "impact view adds the repo status"
# 옛 캐시(assessment 없음)도 view가 같은 규칙으로 채운다.
assert_eq "$(jq -c '.assessment' <<<"$EV_VIEW")" "$(jq 'del(.assessment)' "$EV_FILE" >"$TEST_TMP/impact-noassess.json"; HARNESS_METRICS_DIR="$EV_DATA" "$ROOT/scripts/impact.sh" view --data "$TEST_TMP/impact-noassess.json" | jq -c '.assessment')" \
  "impact view assesses an old compare JSON the same way"
assert_contains "$(<"$ROOT/skills/harness-impact/report-template.html")" "비교 불가" "impact report says when a metric cannot be compared"
pass "impact assessment: comparability, after-install trend, repo status"

# digest가 null·깨짐이면 건너뛰고, 세션 0건·이력 없음이어도 compare가 JSON을 낸다.
ODD_DATA="$TEST_TMP/impact-odd-data"
mkdir -p "$ODD_DATA/events" "$ODD_DATA/digests"
cp "$EV_DATA/events/claude-a1.jsonl" "$ODD_DATA/events/"
printf 'null\n' >"$ODD_DATA/digests/claude-a1.json"
printf '{"v":2, "findings":[\n' >"$ODD_DATA/digests/claude-zz.json"
ODD_JSON="$(HARNESS_METRICS_DIR="$ODD_DATA" "$ROOT/scripts/impact.sh" compare --root "$EV_REPO" --today 2026-10-30)"
assert_eq "1 0 [] []" "$(jq -c '[.periods.after.sessions, .periods.after.digested_sessions, .improvements, .timeline]' <<<"$ODD_JSON" | jq -r 'map(tojson) | join(" ")')" \
  "impact skips null and broken digests and runs without harvest history"
EMPTY_DATA="$TEST_TMP/impact-empty-data"
mkdir -p "$EMPTY_DATA"
assert_eq "0 0" "$(HARNESS_METRICS_DIR="$EMPTY_DATA" "$ROOT/scripts/impact.sh" compare --root "$EV_REPO" --today 2026-10-30 | jq -r '"\(.periods.before.sessions) \(.periods.after.sessions)"')" \
  "impact compare works with no sessions at all"
pass "impact compare tolerates missing data"

# 경로 가림: 홈·/root·Windows 홈·끝 슬래시 없는 홈·끝 슬래시 있는 cwd. 날짜가 든 긴 파일 이름은 지우지 않는다.
TILDE='~'
redact_case() { jq -rn -L "$ROOT/scripts" --arg s "$1" --arg cwd "$2" 'include "redact"; $s | redact_path($cwd) | redact'; }
assert_eq "$TILDE/.ssh/config" "$(redact_case "/root/.ssh/config" "")" "redact_path hides /root"
assert_eq '~\proj\a.ts' "$(redact_case 'C:\Users\bob\proj\a.ts' "")" "redact_path hides a Windows home"
assert_eq "ls $TILDE" "$(redact_case "ls /Users/bob" "")" "redact_path hides a home without trailing slash"
assert_eq "src/a.ts" "$(redact_case "/Users/bob/app/src/a.ts" "/Users/bob/app/")" "redact_path strips a cwd given with a trailing slash"
assert_eq "$TILDE/x /rootfs/y" "$(redact_case "/home/al/x /rootfs/y" "")" "redact_path leaves paths that only start like /root"
assert_eq "db/2026-10-05-add-user-index-migration.sql" "$(redact_case "db/2026-10-05-add-user-index-migration.sql" "")" "redact keeps long dated file names"
assert_eq "see 2026-10-05-add-user-index-migration.sql" "$(redact_case "see 2026-10-05-add-user-index-migration.sql" "")" "redact keeps a bare long file name"
assert_eq "x *** y" "$(redact_case "x abcd1234efgh5678ijkl9012mnop y" "")" "redact still hides a bare key-like string"
assert_eq "src/*** ***" "$(redact_case "src/sk-abcDEF1234567890xyzw eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJlc2lnbmF0dXJl" "")" \
  "redact hides known token prefixes and JWTs even inside a path"
pass "redact covers home paths and keeps file names"

# 설치 30일 뒤 SessionStart에서 한 번만 안내한다.
IMPACT_HINT_INPUT="$(jq -cn --arg cwd "$IMPACT_REPO" '{cwd:$cwd, transcript_path:"/x/s.jsonl"}')"
assert_eq "" "$(HM_IMPACT_HINT=1 HM_IMPACT_TODAY=2026-10-20 HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" notify <<<"$IMPACT_HINT_INPUT")" "no impact hint before 30 days"
IMPACT_HINT="$(HM_IMPACT_HINT=1 HM_IMPACT_TODAY=2026-10-31 HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" notify <<<"$IMPACT_HINT_INPUT")"
assert_contains "$(jq -r '.systemMessage' <<<"$IMPACT_HINT")" "하네스 효과 보여줘" "impact hint suggests the natural-language request"
assert_eq "" "$(HM_IMPACT_HINT=1 HM_IMPACT_TODAY=2026-11-01 HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" notify <<<"$IMPACT_HINT_INPUT")" "impact hint shows once per project"
assert_eq "" "$(HM_IMPACT_HINT=0 HM_IMPACT_TODAY=2026-12-31 HARNESS_METRICS_DIR="$TEST_TMP/impact-hint-off" "$ROOT/scripts/impact.sh" notify <<<"$IMPACT_HINT_INPUT")" "HM_IMPACT_HINT=0 turns the hint off"
assert_eq "" "$(HM_IMPACT_HINT=1 HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" notify <<<'{"cwd":"/nonexistent/x"}')" "impact hint is silent outside a harness project"
pass "impact hint after 30 days"

# 리뷰 회귀: 오늘이 속한 주가 주간 추이에서 빠지지 않고, 깨진 이벤트 줄·digest 파일이 compare를 멈추지 않는다.
assert_eq "2026-11-02" "$(HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root "$IMPACT_REPO" --at 2026-09-01 --window 60 --today 2026-11-04 \
  | jq -r '.weekly | last | .week')" "impact weekly series ends with the current week"
printf '{"v":3,"src":"claude","sid":"a2","project":"svc","kind":"error","n":1}\n{"v":3,"kind":"err' >>"$IMPACT_DATA/events/claude-a2.jsonl"
printf '{"v":2,"findings":[{"category":"correction"' >"$IMPACT_DATA/digests/claude-broken.json"
assert_eq "2 1" "$(HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root "$IMPACT_REPO" --today 2026-10-30 \
  | jq -r '"\(.periods.after.sessions) \(.periods.after.corrections)"')" "impact skips a truncated event line and a broken digest"
# notify는 어떤 실패에도 조용히 0으로 끝난다.
IMPACT_BAD="$TEST_TMP/impact-bad"
mkdir -p "$IMPACT_BAD/.ai-harness"
printf '%s\n' '{"initialized":"2026-13-45"}' >"$IMPACT_BAD/.ai-harness/harness.json"
IMPACT_BAD_OUT="$(HM_IMPACT_HINT=1 HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" notify <<<"{\"cwd\":\"$IMPACT_BAD\"}"; echo "rc=$?")"
assert_eq "rc=0" "$IMPACT_BAD_OUT" "impact notify exits 0 quietly on an invalid install date"
set +e
HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" compare --root >/dev/null 2>&1
IMPACT_RC=$?
set -e
assert_eq "2" "$IMPACT_RC" "impact rejects an option without its value"
pass "impact review regressions"

# A/B: 하네스 있는 저장소와 없는 저장소에서 같은 과제를 돌려 숨긴 검사로 채점한다. 가짜 에이전트로 채점·집계·비용 상한을 검사한다.
AB_DATA="$TEST_TMP/ab-data"
AB_STUB="$ROOT/tests/fixtures/ab/stub-agent.sh"
assert_eq "12" "$(HARNESS_METRICS_DIR="$AB_DATA" "$ROOT/scripts/ab.sh" estimate --runs 2 | jq -r '.agent_runs')" "ab estimate counts cases x 2 arms x runs"
AB_OUT="$(HARNESS_METRICS_DIR="$AB_DATA" HM_AB_AGENT_CMD="$AB_STUB" "$ROOT/scripts/ab.sh" run --runs 1 --out "$TEST_TMP/ab.json" 2>/dev/null)"
assert_eq "$TEST_TMP/ab.json" "$AB_OUT" "ab run prints the result path"
assert_eq "apply-coupon:1:0.25 archive-stale-docs:1:0.5 cancel-order:1:0.43" "$(jq -r '[.cases[] | "\(.name):\(.arms.harness.mean_score):\(.arms.bare.mean_score)"] | join(" ")' "$TEST_TMP/ab.json")" \
  "ab grades the rule-following implementation fully and the naive one partially"
assert_eq "0 0 2.1 stub false" "$(jq -r '"\([.cases[].arms[].errors] | add) \([.cases[].arms.bare.full_pass_runs] | add) \(.total_cost_usd) \(.agent) \(.partial)"' "$TEST_TMP/ab.json")" \
  "ab runs the agent as an internal session and sums cost"
assert_eq "7일 뒤 환불 90% 내림:0" "$(jq -r '.cases[] | select(.name == "cancel-order") | .arms.bare.checks[] | select(.kind == "project_rule") | "\(.name):\(.passed)"' "$TEST_TMP/ab.json" | head -1)" \
  "ab keeps the case's check order and marks project rules"
assert_contains "$(jq -r '.cases[0].arms.bare.runs[0].diff' "$TEST_TMP/ab.json")" "def cancel_order" "ab keeps the agent's diff for the report"
HARNESS_METRICS_DIR="$AB_DATA" HM_AB_AGENT_CMD="$AB_STUB" "$ROOT/scripts/ab.sh" run --runs 1 --max-cost 0.5 --run-budget 0.2 --out "$TEST_TMP/ab-partial.json" >/dev/null 2>&1
assert_eq "true 1 1" "$(jq -r '"\(.partial) \(.cases[0].arms.harness.runs | length) \(.cases[0].arms.bare.runs | length)"' "$TEST_TMP/ab-partial.json")" \
  "ab stops at the cost ceiling only between rounds so both arms keep the same runs"
assert_eq "1 0" "$(jq -r '.cases[] | select(.name == "cancel-order") | "\(.arms.harness.score_by_kind.project_rule) \(.arms.bare.score_by_kind.project_rule)"' "$TEST_TMP/ab.json")" \
  "ab reports scores by check kind"
# 오류 난 실행(예산 초과·타임아웃)은 점수 평균에서 빠진다.
AB_FAIL_STUB="$TEST_TMP/ab-fail-stub.sh"
printf '#!/usr/bin/env bash\nif [[ -f AGENTS.md ]]; then exec %q "$@"; fi\nexit 7\n' "$AB_STUB" >"$AB_FAIL_STUB"
chmod +x "$AB_FAIL_STUB"
HARNESS_METRICS_DIR="$AB_DATA" HM_AB_AGENT_CMD="$AB_FAIL_STUB" "$ROOT/scripts/ab.sh" run --runs 1 --case cancel-order --run-budget 1 --out "$TEST_TMP/ab-err.json" >/dev/null 2>&1
assert_eq "1 0 null 1 1" "$(jq -r '.cases[0].arms.bare | "\(.errors) \(.scored_runs) \(.mean_score) \(.runs[0].cost_usd) \(.runs | length)"' "$TEST_TMP/ab-err.json")" \
  "ab leaves errored runs out of the score and counts unknown cost as the run budget"
if HARNESS_METRICS_DIR="$AB_DATA" "$ROOT/scripts/ab.sh" run --case nope >/dev/null 2>&1; then fail "ab rejects an unknown case"; fi
HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" render --data "$IMPACT_DATA_FILE" --ab "$TEST_TMP/ab.json" --out "$TEST_TMP/impact-ab.html" >/dev/null
IMPACT_AB_HTML="$(cat "$TEST_TMP/impact-ab.html")"
assert_contains "$IMPACT_AB_HTML" '"runs_per_arm":1' "report embeds the A/B result"
case "$IMPACT_AB_HTML" in *__IMPACT_AB__*) fail "report fills the A/B placeholder" ;; esac
assert_contains "$(cat "$TEST_TMP/impact-nohl.html")" "const AB = null" "report renders without A/B"
HARNESS_METRICS_DIR="$IMPACT_DATA" "$ROOT/scripts/impact.sh" render --ab "$TEST_TMP/ab.json" --out "$TEST_TMP/ab-only.html" >/dev/null
assert_contains "$(cat "$TEST_TMP/ab-only.html")" "const DATA = null" "report renders A/B alone when there is no install date"
pass "ab experiment runner"

# harness-impact는 전역 Skill이다: 도입 효과 요청을 받고, 사용량·개선 요청은 metrics·harvest로 보낸다.
IMPACT_SKILL_CONTENT="$(<"$ROOT/skills/harness-impact/SKILL.md")"
assert_file "$ROOT/skills/harness-impact/agents/openai.yaml"
assert_contains "$IMPACT_SKILL_CONTENT" "impact.sh compare" "harness-impact runs the compare script"
assert_contains "$IMPACT_SKILL_CONTENT" "impact.sh render" "harness-impact renders the report"
assert_contains "$IMPACT_SKILL_CONTENT" "토큰 총량이나 절약 시간은 헤드라인에 쓰지 않는다" "harness-impact keeps token totals out of the headline"
assert_contains "$IMPACT_SKILL_CONTENT" "원인을 증명하지 않는다" "harness-impact does not claim causation"
assert_contains "$(sed -n '1,5p' "$ROOT/skills/harness-impact/SKILL.md")" "that is metrics" "harness-impact description hands usage reports to metrics"
assert_contains "$(sed -n '1,5p' "$ROOT/skills/metrics/SKILL.md")" "harness-impact" "metrics description hands impact requests to harness-impact"
assert_contains "$(<"$ROOT/scripts/session-start.sh")" 'impact.sh" notify' "SessionStart carries the impact hint"
assert_contains "$IMPACT_SKILL_CONTENT" "ab.sh estimate" "harness-impact shows the A/B size first"
assert_contains "$IMPACT_SKILL_CONTENT" "실행 전에 확인을 받는다" "harness-impact asks before spending on A/B runs"
# plugin eval이 A/B 과제를 트리거 케이스로 잘못 읽지 않게 prompt.md를 두지 않는다.
assert_eq "0" "$(find "$ROOT/evals/ab" -name prompt.md | wc -l | tr -d ' ')" "A/B tasks are not plugin eval cases"
for c in ko-show-effect ko-before-after ko-report ko-ab-request en-impact ko-token-usage ko-improve-harness; do
  assert_file "$ROOT/evals/harness-impact/$c/prompt.md"
done
pass "harness-impact plugin skill"

finish_tests
