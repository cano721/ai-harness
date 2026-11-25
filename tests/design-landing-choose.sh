#!/usr/bin/env bash
# 회귀 테스트 — landing-page 그래프 러너 — 무인 초안 선택(약한 초안 접기·재작업·동률), 대화형 재작업, 단일 후보, 세 번째 검토 종료
# 실행: bash tests/run.sh design-landing-choose
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lib-design.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-design.sh"
# shellcheck source=tests/lib-design-run.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-design-run.sh"
export LANDING_PREVIEW_CMD="$TEST_TMP/lp-preview-hook.sh"
# Unattended, both first drafts weak: only the one with the better draft review redraws; the other folds.
LP_W="$TEST_TMP/lp-run-two"; mkdir -p "$LP_W"
lp init --mode unattended >/dev/null
printf '## Tone and manner\ncalm, precise\n' >"$LP_W/brief.md"; cp "$TEST_TMP/lp-tone.json" "$LP_W/tone.json"
lp submit --node brief --outcome brief_ready >/dev/null
cp "$TEST_TMP/lp-refs.json" "$LP_W/references.json"; cp "$TEST_TMP/lp-searches.json" "$LP_W/searches.json"
cp "$TEST_TMP/lp-slots.json" "$LP_W/component-slots.json"; cp "$TEST_TMP/lp-agent-pick.json" "$LP_W/reference-pick.json"
lp submit --node references --outcome references_ready >/dev/null
printf '{"candidates":[{"id":"a","dir":"site/a","motion_level":"calm","first_viewport":"one scene","primary_refs":{"layout":"R3","interaction":"R4","components":{"hero":"R2"}}},{"id":"b","dir":"site/b","motion_level":"calm","first_viewport":"two scenes","primary_refs":{"layout":"R3","interaction":"R4","components":{"hero":"R2"}}}]}\n' >"$LP_W/candidates.json"
lp submit --node direction --outcome direction_ready >/dev/null
mkdir -p "$LP_W/site/a" "$LP_W/site/b" "$LP_W/caps"
for c in a b; do
  touch "$LP_W/site/$c/index.html"; lp submit --node draft --outcome drafted --candidate "$c" >/dev/null
  printf 'png' >"$LP_W/caps/$c-1440.png"; printf 'png' >"$LP_W/caps/$c-390.png"
  printf '{"url":"http://127.0.0.1:9/%s/","captures":["caps/%s-1440.png","caps/%s-390.png"]}\n' "$c" "$c" "$c" >"$LP_W/preview-$c.json"
  lp submit --node preview --outcome previewed --candidate "$c" >/dev/null
done
cp -R "$LP_W" "$TEST_TMP/lp-run-two-i"
jq '.mode = "interactive"' "$LP_W/.landing-run/state.json" >"$TEST_TMP/lp-run-two-i/.landing-run/state.json"
jq '.checks |= map(if .check == "template_look" or .check == "copied_composition" then .status = "fail" | .first_viewport = true else . end)' "$(lp_review craft 0)" >"$TEST_TMP/lp-review-a3.json"
assert_eq draft_hold "$(lp review --candidate a --file "$TEST_TMP/lp-review-a3.json")" "the first weak draft waits for the other first draft review"
assert_contains "$(lp next --candidate a)" "Waiting" "next says the held draft waits for the runner"
assert_eq draft "$(lp review --candidate b --file "$(lp_review craft 0 b)")" "with every first draft review in, the draft with fewer majors redraws"
assert_eq folded "$(jq -r '.candidates.a.node' "$LP_W/.landing-run/state.json")" "the other weak draft folds instead of redrawing"
assert_eq "runner b a" "$(jq -r '[.via, .kept[0], .dropped[0]] | join(" ")' "$LP_W/redo-pick.json")" "redo-pick.json records the runner's pick"
assert_eq "3 1" "$(jq -r '[.scores.a.majors, .scores.b.majors] | join(" ")' "$LP_W/redo-pick.json")" "redo-pick.json keeps the draft review scores behind the pick"
assert_contains "$(lp status | jq -r '.candidates.a.folded_reason')" "b was chosen to redraw" "status carries why the other draft folded"
touch "$LP_W/site/b/index.html"; lp submit --node draft --outcome drafted --candidate b >/dev/null
touch "$LP_W/preview-b.json"; lp submit --node preview --outcome previewed --candidate b >/dev/null
assert_eq build "$(lp review --candidate b --file "$(lp_review craft 0 b)")" "the redrawn draft, the only one left, goes on to build"
assert_contains "$(jq -r '.chosen | "\(.via) \(.reason)"' "$LP_W/.landing-run/state.json")" "runner the only candidate left after the redo pick" "the runner records why it chose without draft_choose"
# Ties fall to candidates.json order.
LP_W="$TEST_TMP/lp-run-two-t"; cp -R "$TEST_TMP/lp-run-two-i" "$LP_W"
jq '.mode = "unattended"' "$TEST_TMP/lp-run-two-i/.landing-run/state.json" >"$LP_W/.landing-run/state.json"
lp review --candidate b --file "$(lp_review craft 0 b)" >/dev/null
lp review --candidate a --file "$(lp_review craft 0 a)" >/dev/null
assert_eq "draft folded" "$(jq -r '[.candidates.a.node, .candidates.b.node] | join(" ")' "$LP_W/.landing-run/state.json")" "on equal scores the first candidate in candidates.json redraws"
# Unattended, one draft passed and the other needs a redo: draft_choose must take the passed one, so the weak one folds.
LP_W="$TEST_TMP/lp-run-two-p"; cp -R "$TEST_TMP/lp-run-two-i" "$LP_W"
jq '.mode = "unattended"' "$TEST_TMP/lp-run-two-i/.landing-run/state.json" >"$LP_W/.landing-run/state.json"
assert_eq draft_hold "$(lp review --candidate a --file "$(lp_review craft 0 a)")" "a weak draft waits while the other is unreviewed"
assert_eq build "$(lp review --candidate b --file "$(lp_review none 0 b)")" "the passed draft, the only one left, goes on to build"
assert_eq folded "$(jq -r '.candidates.a.node' "$LP_W/.landing-run/state.json")" "the weak draft folds without a redo when another passed"
assert_eq "runner b a" "$(jq -r '[.via, .kept[0], .dropped[0]] | join(" ")' "$LP_W/redo-pick.json")" "redo-pick.json records why the weak draft folded"
assert_contains "$(jq -r '.reason' "$LP_W/redo-pick.json")" "draft_choose must take a passed draft" "the fold names the passed draft as the reason"
assert_eq 0 "$(jq '[.history[] | select(.candidate == "a" and .to == "draft" and .from == "draft_hold")] | length' "$LP_W/.landing-run/state.json")" "the folded draft never redraws"
LP_W="$TEST_TMP/lp-run-two-q"; cp -R "$TEST_TMP/lp-run-two-i" "$LP_W"
jq '.mode = "unattended"' "$TEST_TMP/lp-run-two-i/.landing-run/state.json" >"$LP_W/.landing-run/state.json"
assert_eq draft_choose "$(lp review --candidate b --file "$(lp_review none 0 b)")" "a passed draft waits while the other is unreviewed"
assert_eq folded "$(lp review --candidate a --file "$(lp_review craft 0 a)")" "a weak draft reviewed after a passed one folds at once"
assert_eq build "$(jq -r '.candidates.b.node' "$LP_W/.landing-run/state.json")" "the passed draft left alone goes on to build"
LP_W="$TEST_TMP/lp-run-two-r"; cp -R "$TEST_TMP/lp-run-two-i" "$LP_W"
assert_eq draft "$(lp review --candidate a --file "$(lp_review craft 0 a)")" "interactive: a weak draft redraws even when the other may pass"
assert_eq build "$(lp review --candidate b --file "$(lp_review none 0 b)")" "interactive: a passed draft goes on to build"
assert_eq draft "$(jq -r '.candidates.a.node' "$LP_W/.landing-run/state.json")" "interactive: the weak draft is not folded"
# An interactive run is unchanged: each weak draft redraws at once.
LP_W="$TEST_TMP/lp-run-two-i"
assert_eq draft "$(lp review --candidate a --file "$TEST_TMP/lp-review-a3.json")" "interactive: a weak draft redraws at once"
assert_eq draft "$(lp review --candidate b --file "$(lp_review craft 0 b)")" "interactive: both weak drafts redraw, none folds"
assert_not_file "$LP_W/redo-pick.json"
# A lone unattended candidate has nothing to be chosen against: it goes from its draft review straight to build.
LP_W="$TEST_TMP/lp-run-one"; mkdir -p "$LP_W"
lp init --mode unattended >/dev/null
printf '## Tone and manner\ncalm, precise\n' >"$LP_W/brief.md"; cp "$TEST_TMP/lp-tone.json" "$LP_W/tone.json"
lp submit --node brief --outcome brief_ready >/dev/null
cp "$TEST_TMP/lp-refs.json" "$LP_W/references.json"; cp "$TEST_TMP/lp-searches.json" "$LP_W/searches.json"
cp "$TEST_TMP/lp-slots.json" "$LP_W/component-slots.json"; cp "$TEST_TMP/lp-agent-pick.json" "$LP_W/reference-pick.json"
lp submit --node references --outcome references_ready >/dev/null
printf '{"candidates":[{"id":"c","dir":"site/c","motion_level":"calm","first_viewport":"one scene","primary_refs":{"layout":"R3","interaction":"R4","components":{"hero":"R2"}}}]}\n' >"$LP_W/candidates.json"
lp submit --node direction --outcome direction_ready >/dev/null
mkdir -p "$LP_W/site/c" "$LP_W/caps"; touch "$LP_W/site/c/index.html"; lp submit --node draft --outcome drafted --candidate c >/dev/null
printf 'png' >"$LP_W/caps/c-1440.png"; printf 'png' >"$LP_W/caps/c-390.png"
printf '{"url":"http://127.0.0.1:9/c/","captures":["caps/c-1440.png","caps/c-390.png"]}\n' >"$LP_W/preview-c.json"
lp submit --node preview --outcome previewed --candidate c >/dev/null
assert_eq build "$(lp review --candidate c --file "$(lp_review none 0 c)")" "a lone unattended candidate goes on to build without a choice"
assert_eq runner "$(jq -r '.chosen.via' "$LP_W/.landing-run/state.json")" "the runner records that it chose the only candidate"
touch "$LP_W/site/c/index.html" "$LP_W/source-facts-c.md" "$LP_W/needs-input-c.json"
lp submit --node build --outcome built --candidate c >/dev/null; lp measure --candidate c --url http://127.0.0.1:9/ >/dev/null
for r in 1 2 3; do
  out="$(lp review --candidate c --file "$(lp_review flow 0 c)" || true)"
  [[ $r -lt 3 ]] && { touch "$LP_W/repair-c-$r.md"; lp submit --node repair --outcome repaired --candidate c >/dev/null; lp measure --candidate c --url http://127.0.0.1:9/ >/dev/null; }
done
assert_eq user_decision "$out" "a third review with a major left ends at user_decision"
pass "landing-page graph runner: unattended draft choice, interactive redraws, a lone candidate, and the review limit"

finish_tests
