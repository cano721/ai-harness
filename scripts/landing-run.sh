#!/usr/bin/env bash
# shellcheck disable=SC2016  # save에 넘기는 작은따옴표 인자는 jq 식이다($c·$t 등은 jq 변수)
# /landing-page 그래프 러너. 모델이 아니라 이 스크립트가 다음 노드를 정한다.
#   - 상태: <work>/.landing-run/state.json. 후보마다 노드·측정 횟수·검토 회차·판정을 따로 둔다(후보 서브에이전트가 동시에 써도 잠금으로 직렬화).
#   - submit: 만드는 쪽(maker·human 노드)이 결과를 낸다. 노드 산출물이 없거나, 그래프에 없는 전이면 거부한다.
#   - measure: 측정 스크립트를 직접 돌려 결과(pass·fail·unverified)로 전이를 고른다. 모델이 measured_pass를 낼 수 없다.
#   - review: 검토 JSON을 받아 필수 항목이 다 있는지 보고, 판정과 전이를 계산한다. 항목이 빠진 검토는 회차로 세지 않고 거부한다.
#     첫 화면에서 실패한 first_viewport_major 항목은 검토자가 minor로 적어도 주요로 센다.
#   - board: tone.json·references.json으로 레퍼런스 보드(board.html, 탭 5개)를, --kind drafts면 시안 보드(draft-board.html)를
#     만든다. 에이전트가 보드 HTML을 손으로 짜지 않는다. --serve면 보드 서버를 분리 실행해 보드의 시작 버튼이 고른 결과를 쓴다.
#   - wait-pick: 고른 결과 파일이 그 노드 시작 뒤에 생길 때까지 기다린다(세션은 이 명령을 백그라운드로 두고 턴을 끝낸다).
#   - capture: 스크롤 투어·감속·JS 끔 캡처와 밀착 인화지를 만든다. measure 뒤에도 자동으로 돈다(검토자가 다시 찍지 않게).
#   - capture-refs: 레퍼런스 페이지를 한 번에 동시 4개로 캡처한다(봇 확인 화면은 challenge). 녹화는 --background로 분리 실행한다.
#     사이트마다 에이전트가 캡처 스크립트를 짜던 시간이 레퍼런스 단계의 대부분이었다.
#   - 대표 고르기: 레이아웃·인터랙션은 대표 하나, 구성요소는 섹션 칸(component-slots.json)마다 대표 하나를 고른다.
#     에이전트가 references.json의 recommended로 추천을 미리 채우고, reference-pick.json의 primary에 남는다. 후보는
#     primary_refs로 이끄는 레퍼런스를 밝히고, 적어도 한 후보는 고른 대표를 그대로 쓴다(다 참고하면 후보가 섞인다).
#   - draft_choose: 무인 실행은 후보 하나만 완성한다. 모든 시안 검토가 끝난 뒤 에이전트가 이유와 함께 하나를 고르고 나머지는
#     folded로 접는다. 두 번째 후보의 build 진입은 거부한다(둘 다 완성하면 시간·비용이 두 배인데 보고서엔 하나만 쓰인다).
# 종료 코드: 0 성공, 2 사용법, 3 전이 거부, 4 산출물·입력 불충분.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_GRAPH="$ROOT/skills/landing-page/references/landing-page-graph.json"

die() { local code="$1"; shift; printf 'landing-run: %s\n' "$*" >&2; exit "$code"; }
usage() {
  cat >&2 <<'EOF'
usage:
  landing-run.sh init    --work DIR --mode interactive|unattended [--graph FILE]
  landing-run.sh next    --work DIR [--candidate ID]
  landing-run.sh submit  --work DIR --node NODE --outcome OUTCOME [--candidate ID]
  landing-run.sh measure --work DIR --candidate ID --url URL
  landing-run.sh review  --work DIR --candidate ID --file REVIEW.json
  landing-run.sh capture --work DIR --candidate ID --url URL [--label NAME]
  landing-run.sh capture-refs --work DIR --file REFS-TO-CAPTURE.json [--background]
  landing-run.sh operate --work DIR --url URL --file SCRIPT.mjs [--label NAME] [--width PX]
  landing-run.sh board   --work DIR [--kind references|drafts] [--port N --serve]
  landing-run.sh wait-pick --work DIR --node reference_pick|draft_pick [--timeout-min 30]
  landing-run.sh status  --work DIR
EOF
  exit 2
}

cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift
WORK="" MODE="" GRAPH_ARG="" CAND="" NODE="" OUTCOME="" URL="" FILE="" LABEL="" WIDTH="" KIND="references" PORT="" SERVE="" BACKGROUND="" TIMEOUT_MIN=30
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work) WORK="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --graph) GRAPH_ARG="$2"; shift 2 ;;
    --candidate) CAND="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --outcome) OUTCOME="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --file) FILE="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --serve) SERVE=1; shift ;;
    --background) BACKGROUND=1; shift ;;
    --timeout-min) TIMEOUT_MIN="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$WORK" ]] || usage
WORK="$(cd "$WORK" 2>/dev/null && pwd)" || die 2 "work directory not found"
RUN="$WORK/.landing-run"
STATE="$RUN/state.json"

lock() {
  local i=0
  while ! mkdir "$RUN/lock" 2>/dev/null; do
    i=$((i + 1)); [[ $i -lt 300 ]] || die 4 "state is locked ($RUN/lock); remove it if no run is active"
    sleep 0.1
  done
  trap 'rmdir "$RUN/lock" 2>/dev/null || true' EXIT
}
state() { jq -r "$1" "$STATE"; }
save() { local tmp; tmp="$(mktemp "$RUN/state.XXXXXX")"; jq "$@" "$STATE" >"$tmp" && mv "$tmp" "$STATE"; }
graph() { jq -r "$1" "$GRAPH"; }

# A node's artifact templates resolved for a candidate: {dir} {c} {n} {r}.
artifacts() {
  local node="$1" c="${2:-}" dir="" n=0 r=0
  if [[ -n "$c" ]]; then
    dir="$(jq -r --arg c "$c" '.candidates[$c].dir' "$STATE")"
    n="$(jq -r --arg c "$c" '.candidates[$c].measures' "$STATE")"
    r="$(jq -r --arg c "$c" '.candidates[$c].reviews' "$STATE")"
  fi
  jq -r --arg n "$node" '.nodes[$n].artifacts // [] | .[]' "$GRAPH" \
    | sed -e "s#{dir}#$dir#g" -e "s#{c}#$c#g" -e "s#{n}#$n#g" -e "s#{r}#$r#g"
}

# The edge from NODE for OUTCOME in this run's mode, or nothing.
edge() {
  jq -r --arg f "$1" --arg w "$2" --arg m "$(state .mode)" \
    'first(.transitions[] | select(.from == $f and .when == $w and ((.mode // $m) == $m)) | .to) // empty' "$GRAPH"
}

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
entered_epoch() {
  local at
  if [[ -n "$CAND" ]]; then at="$(jq -r --arg c "$CAND" '.candidates[$c].entered_at // empty' "$STATE")"; else at="$(state '.entered_at // empty')"; fi
  [[ -n "$at" ]] || { printf '0\n'; return; }
  jq -rn --arg a "$at" '$a | fromdateiso8601'
}

# Tell the person a draft is up, whatever channel the run has: LANDING_PREVIEW_CMD (called with the URL and the preview
# file; "none" turns it off), otherwise open the URL in the default browser and post a desktop notification.
notify_preview() {
  local url="$1" file="$2"
  if [[ -n "${LANDING_PREVIEW_CMD:-}" ]]; then
    [[ "$LANDING_PREVIEW_CMD" == none ]] && return 0
    read -r -a hook <<<"$LANDING_PREVIEW_CMD"
    "${hook[@]}" "$url" "$file" >/dev/null 2>&1 || printf 'landing-run: preview hook failed\n' >&2
    return 0
  fi
  if [[ "$(uname)" == Darwin ]] && command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
    osascript -e "display notification \"$url\" with title \"랜딩 페이지 첫 시안\"" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

# Captures every later step reads: LANDING_CAPTURE_CMD replaces the script ("none" turns it off). Prints the folder, relative to WORK.
run_capture() {
  local url="$1" label="$2" dir="captures/$2"
  [[ "${LANDING_CAPTURE_CMD:-}" == none ]] && return 0
  read -r -a capture_cmd <<<"${LANDING_CAPTURE_CMD:-node $ROOT/scripts/landing-capture.mjs}"
  "${capture_cmd[@]}" --url "$url" --out "$WORK/$dir" >&2 || printf 'landing-run: capture failed\n' >&2
  printf '%s\n' "$dir"
}

current() { if [[ -n "$CAND" ]]; then jq -r --arg c "$CAND" '.candidates[$c].node // empty' "$STATE"; else state .node; fi; }

move() {
  local from="$1" outcome="$2" to
  to="$(edge "$from" "$outcome")"
  [[ -n "$to" ]] || die 3 "no edge from '$from' on '$outcome' in $(state .mode) mode"
  local at; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Leaving the shared steps: the candidates listed in candidates.json start their own paths at draft (checked before anything is saved).
  local cands=""
  if [[ -z "$CAND" && "$to" == "draft" ]]; then
    [[ -f "$WORK/candidates.json" ]] || die 4 "candidates.json is missing"
    cands="$(jq -c '[.candidates[] | {key: .id, value: {dir: .dir, motion_level: (.motion_level // "calm"), node: "draft", entered_at: $at, measures: 0, reviews: 0, verdict: null}}] | from_entries' --arg at "$at" "$WORK/candidates.json")" \
      || die 4 "candidates.json must hold {\"candidates\":[{\"id\",\"dir\",\"motion_level\",\"first_viewport\"}]}"
    [[ "$(jq 'length' <<<"$cands")" -ge 1 ]] || die 4 "candidates.json lists no candidate"
    jq -e '[.candidates[] | (.first_viewport // "") | type == "string" and length > 0] | all' "$WORK/candidates.json" >/dev/null \
      || die 4 "each candidate needs first_viewport: its first-viewport composition in one line (direction.md, Not the stock hero)"
  fi
  # An unattended run finishes one candidate (limits.unattended_builds): a second one never enters build.
  if [[ -n "$CAND" && "$to" == build && "$(state .mode)" == unattended ]]; then
    local built; built="$(jq -r --arg c "$CAND" '[.history[] | select(.to == "build" and .candidate != $c) | .candidate] | unique | join(", ")' "$STATE")"
    [[ -z "$built" ]] || die 3 "an unattended run finishes one candidate; '$built' already entered build"
  fi
  if [[ -n "$CAND" ]]; then
    save --arg c "$CAND" --arg t "$to" --arg f "$from" --arg o "$outcome" --arg at "$at" \
      '.candidates[$c].node = $t | .candidates[$c].entered_at = $at | .history += [{candidate: $c, from: $f, outcome: $o, to: $t, at: $at}]
       | if $f == "preview" and (.candidates[$c].previewed_at == null) then .candidates[$c].previewed_at = $at elif ($t == "done" or $t == "user_decision" or $t == "folded") then .candidates[$c].finished_at = $at else . end'
  else
    save --arg t "$to" --arg f "$from" --arg o "$outcome" --arg at "$at" \
      '.node = $t | .entered_at = $at | .history += [{from: $f, outcome: $o, to: $t, at: $at}]'
  fi
  [[ -z "$cands" ]] || save --argjson cs "$cands" '.candidates = $cs | .node = "candidates"'
  printf '%s\n' "$to"
}

print_next() {
  local node="$1" c="${2:-}" actor
  actor="$(jq -r --arg n "$node" '.nodes[$n].actor // "runner"' "$GRAPH")"
  local outs
  outs="$(jq -c --arg f "$node" --arg m "$(state .mode)" '[.transitions[] | select(.from == $f and ((.mode // $m) == $m)) | .when] | unique' "$GRAPH")"
  [[ "$node" != draft_choose ]] || outs='["chosen"]'
  local docs
  docs="$(jq -c --arg n "$node" --arg base "$ROOT/skills/landing-page/" '[.nodes[$n].docs // [] | .[] | $base + .]' "$GRAPH")"
  local arts
  arts="$(artifacts "$node" "$c" | jq -R . | jq -sc --arg w "$WORK/" 'map($w + .)')"
  local how
  case "$actor" in
    maker) if [[ "$node" == draft_choose ]]; then
        how="Once every candidate's draft review is done (landing-run.sh next shows each node), choose one candidate to finish — one whose draft passed (draft_pass) when there is one — and write draft-pick.json {kept: [id], dropped: [ids], via: \"agent\", reason}; then: landing-run.sh submit --work <dir> --node draft_choose --outcome chosen (no --candidate). The others fold; put the reason in the report."
      else how="Do this node's work (read only the docs listed), write the artifacts, then: landing-run.sh submit --work <dir> --node $node --outcome <one of outcomes>${c:+ --candidate $c}"; fi ;;
    human) how="Ask the user (in an interactive session), record their answer in the artifact, then submit with outcome picked${c:+ --candidate $c}" ;;
    runner) case "$node" in
        measure) how="Serve the page, then: landing-run.sh measure --work <dir> --candidate $c --url <served url>" ;;
        folded) how="Not finished: another candidate was chosen at draft_choose (status holds the reason); report it" ;;
        *) how="Terminal: report this candidate (landing-run.sh status)" ;;
      esac ;;
    reviewer) if [[ "$node" == draft_review ]]; then
        how="Start a new design-reviewer on the draft's first viewport only: the preview captures (preview-$c.json), the served URL, the references with their captures and take-lines, and the required checks below (verify.md, Draft review); three minutes. Save its JSON, then: landing-run.sh review --work <dir> --candidate $c --file <review json>"
      else how="Start a new design-reviewer with the briefing in verify.md, the required checks below, the latest measure JSON, and the capture folder $(jq -r --arg c "$c" '.candidates[$c].captures // "(run landing-run.sh capture)"' "$STATE"); it operates the page only through landing-run.sh operate (scripts in $WORK/operate/); save its JSON, then: landing-run.sh review --work <dir> --candidate $c --file <review json>"; fi ;;
  esac
  local checks="[]"
  if [[ "$node" == "review" ]]; then checks="$(required_checks)"; fi
  if [[ "$node" == "draft_review" ]]; then checks="$(jq -c '.review_checks.draft' "$GRAPH")"; fi
  jq -n --arg node "$node" --arg actor "$actor" --arg c "$c" --argjson outcomes "$outs" --argjson docs "$docs" \
    --argjson artifacts "$arts" --arg how "$how" --argjson checks "$checks" \
    '{node: $node, actor: $actor} + (if $c != "" then {candidate: $c} else {} end)
     + {docs: $docs, artifacts: $artifacts, outcomes: $outcomes, how: $how}
     + (if ($checks | length) > 0 then {required_checks: $checks} else {} end)'
}

# Shape checks: each prints the problems found, nothing when the file is good.
TONE_CHECK='
  def str: type == "string" and length > 0;
  [ (if type != "object" then "must be an object" else empty end),
    (if (.mood | type) == "array" and (.mood | length) == 3 and all(.mood[]; str) then empty else "mood needs exactly three words" end),
    (if (.palette | type) == "array" and (.palette | length) > 0
          and all(.palette[]; (.name | str) and (.role | str) and ((.hex // "") | test("^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")))
       then empty else "palette needs [{name, hex: \"#rrggbb\", role}]" end),
    (if (.type | type) == "object" and all(.type.display, .type.body, .type.display_sample, .type.body_sample; str) then empty
       else "type needs display, body, display_sample, body_sample" end),
    (["avoid", "voice", "imagery"][] as $k | if (.[$k] | str) then empty else "\($k) is missing" end)
  ] | join("; ")'
REFS_CHECK='
  def str: type == "string" and length > 0;
  ["tone", "component", "layout", "interaction", "competitor"] as $kinds
  | if type != "array" then "must be an array of references" else
    . as $refs
    | [ (.[] | select((.kind as $k | $kinds | index($k)) == null) | "\(.id // "?"): kind must be one of \($kinds | join("|")) (got \(.kind // "none"))"),
      ([.[].id] | group_by(.)[] | select(length > 1) | "id \(.[0]) is used twice (one site in several kinds takes a separate id each)"),
      ($kinds[] as $k | ($min.per_kind[$k] // 1) as $n | ([$refs[] | select(.kind == $k)] | length) as $have
         | if $have >= $n then empty else "\($k) has \($have), needs at least \($n)" end),
      ([.[] | select(.kind == "competitor")] | length) as $c | (if $c > ($min.competitor_max // 4) then "competitor has \($c), at most \($min.competitor_max // 4)" else empty end),
      ([.[] | select(.kind == "interaction" and (.video | str))] | length) as $v
         | (if $v >= ($min.interaction_video // 0) then empty else "interaction has \($v) with a video, needs at least \($min.interaction_video)" end),
      (.[] | select(.kind == "competitor" and ((.analysis | type) != "object" or ([.analysis.leads_with, .analysis.claim, .analysis.cta, .analysis.gap] | all(str) | not)))
           | "\(.id // "?"): competitor needs analysis {leads_with, claim, cta, gap}"),
      (.[] | select(.kind == "interaction" and ((.video | str) | not) and (((.captures // []) | length) == 0))
           | "\(.id // "?"): interaction needs a video (recording URL or path) or captures")
    ] | join("; ") end'

# The references come from a search, not from memory: a category search and a gallery search at least, and every
# competitor (unless the user named it) among the results. $refs is references.json.
SEARCH_CHECK='
  def str: type == "string" and length > 0;
  def norm: ascii_downcase | sub("^https?://"; "") | sub("^www\\."; "") | sub("/+$"; "");
  if type != "array" then "must be an array of searches" else
    ([.[] | .results // [] | .[] | strings | norm]) as $found
    | [ (if length >= 2 then empty else "\(length) searches, needs at least 2" end),
        (.[] | select(((.query | str) and (.engine_or_gallery | str) and ((.results // []) | length) > 0) | not)
             | "\(.query // "?"): a search needs query, engine_or_gallery, and its results"),
        (.[] | select((.purpose | IN("category", "gallery")) | not) | "\(.query // "?"): purpose must be category or gallery"),
        (if any(.[]; .purpose == "category") then empty else "no category search (pages in the same category)" end),
        (if any(.[]; .purpose == "gallery") then empty else "no gallery search (interaction references)" end),
        ($refs[0][] | select(.kind == "competitor" and .source != "user" and (((.url // "") | norm) as $u | $found | index($u)) == null)
             | "\(.id // "?"): competitor \(.url // "?") is not among the search results (only a site the user named may skip search)")
      ] | join("; ") end'

# The sections that need a reference of their own (component-slots.json): each becomes a column in the components tab.
SLOTS_CHECK='
  def str: type == "string" and length > 0;
  if type != "array" or length == 0 then "must list the sections that need a reference: [{id, label}]" else
  [ (.[] | select(((.id | str) and (.id | test("^[a-z0-9][a-z0-9_-]*$")) and (.label | str)) | not)
         | "\(.id // "?"): a slot needs id (lowercase letters, digits, - or _) and label"),
    ([.[].id] | group_by(.)[] | select(length > 1) | "slot \(.[0]) is listed twice"),
    (.[] | select(.id == "layout" or .id == "interaction") | "slot id \(.id) is reserved")
  ] | join("; ") end'
# The agent's recommendation, starred on the board before the user looks: one layout, one interaction, one component per slot at most.
RECO_CHECK='
  ($slots[0] | map(.id)) as $sids
  | [ (.[] | select(.recommended != null)
           | select(((.recommended == "layout" and .kind == "layout") or (.recommended == "interaction" and .kind == "interaction")
                     or (.kind == "component" and (.recommended as $r | $sids | index($r)) != null)) | not)
           | "\(.id): recommended must be layout (on a layout reference), interaction (on an interaction reference), or a slot id from component-slots.json (on a component reference)"),
      (if ([.[] | select(.recommended == "layout")] | length) == 1 then empty else "recommend exactly one layout reference (recommended: \"layout\")" end),
      (if ([.[] | select(.recommended == "interaction")] | length) == 1 then empty else "recommend exactly one interaction reference (recommended: \"interaction\")" end),
      ([.[] | select(.kind == "component" and .recommended != null) | .recommended] | group_by(.)[] | select(length > 1)
         | "slot \(.[0]) has more than one recommended component")
    ] | join("; ")'
# reference-pick.json primary: the layout and interaction that lead, and one component per slot (or none); never an excluded one.
PRIMARY_CHECK='
  def str: type == "string" and length > 0;
  ($refs[0]) as $all | (.dropped // []) as $out | (.primary // null) as $p
  | def ok($id; $k): ($id | str) and ($all | any(.id == $id and .kind == $k)) and (($out | index($id)) == null);
  if ($p | type) != "object" then "primary is missing: {layout, interaction, components: {<slot id>: id|null}, added_slots: [{id, label}]}" else
    (($p.added_slots // []) | if type == "array" then . else [] end) as $added
    | (($slots[0] | map(.id)) + [$added[] | .id?]) as $sids
    | [ (if ok($p.layout; "layout") then empty else "primary.layout must be a layout reference that is not excluded (got \($p.layout // "none"))" end),
        (if ok($p.interaction; "interaction") then empty else "primary.interaction must be an interaction reference that is not excluded (got \($p.interaction // "none"))" end),
        (if ($p.components | type) == "object" then empty else "primary.components must map each slot id to a component id or null" end),
        (($p.components // {}) | objects | to_entries[] | select(.key as $k | ($sids | index($k)) == null) | "primary.components: \(.key) is not a slot"),
        (($p.components // {}) | objects | to_entries[] | select(.value != null and (ok(.value; "component") | not))
           | "primary.components.\(.key): \(.value) must be a component reference that is not excluded"),
        (if (($p.added_slots // []) | type) == "array" and all($added[]; (.id | str) and (.id | test("^[a-z0-9][a-z0-9_-]*$")) and (.label | str)) then empty
           else "primary.added_slots must be [{id, label}]" end),
        ($added[] | .id? | select(. as $a | $slots[0] | map(.id) | index($a)) | "added slot \(.) already exists")
      ] | join("; ") end'
# Each candidate names the references it leads with; at least one leads with the picked primary as it is.
CAND_PRIMARY_CHECK='
  def str: type == "string" and length > 0;
  def norm: {layout, interaction, components: ((.components // {}) | with_entries(select(.value != null)))};
  ($pick[0].primary) as $p | ($pick[0].dropped // []) as $out | ($refs[0]) as $all
  | def ok($id; $k): ($id | str) and ($all | any(.id == $id and .kind == $k)) and (($out | index($id)) == null);
  [ (.candidates[] | select((.primary_refs | type) != "object") | "\(.id): primary_refs is missing (its layout, interaction, and component per slot)"),
    (.candidates[] | . as $c | (.primary_refs | objects)
       | ((if ok(.layout; "layout") then empty else "\($c.id): primary_refs.layout \(.layout // "none") is not a kept layout reference" end),
          (if ok(.interaction; "interaction") then empty else "\($c.id): primary_refs.interaction \(.interaction // "none") is not a kept interaction reference" end),
          ((.components // {}) | to_entries[] | select(.value != null and (ok(.value; "component") | not))
             | "\($c.id): primary_refs.components.\(.key) \(.value) is not a kept component reference"))),
    (if [.candidates[] | (.primary_refs | objects | norm)] | any(. == ($p | norm)) then empty
       else "no candidate leads with the picked primary (reference-pick.json primary); at least one must use it as it is" end)
  ] | join("; ")'

check_primary() {
  local bad
  bad="$(jq -r --slurpfile refs "$WORK/references.json" --slurpfile slots "$WORK/component-slots.json" "$PRIMARY_CHECK" "$WORK/reference-pick.json" 2>/dev/null)" \
    || bad="not valid JSON"
  [[ -z "$bad" ]] || die 4 "reference-pick.json: $bad (direction.md, Picking the primary references)"
}

required_checks() {
  local multi; multi="$(jq '[.candidates[] | select(.node != "folded")] | length' "$STATE")"
  jq -c --argjson multi "$multi" '.review_checks.public_page + (if $multi > 1 then .review_checks.multi_candidate else [] end)' "$GRAPH"
}

case "$cmd" in
  init)
    [[ "$MODE" == interactive || "$MODE" == unattended ]] || usage
    GRAPH="${GRAPH_ARG:-$DEFAULT_GRAPH}"
    "$ROOT/scripts/validate-landing-page-graph.sh" "$GRAPH" >/dev/null
    [[ ! -f "$STATE" ]] || die 3 "a run already exists in $RUN"
    # A run moved aside or a brief already written means this folder had a run: changing mode or starting over must not be silent.
    prior="$(find "$WORK" -maxdepth 2 -name state.json -path '*landing-run*' 2>/dev/null | head -1)"
    [[ -z "$prior" && ! -f "$WORK/brief.md" ]] || die 3 "this folder already holds a run (${prior:-brief.md}); do not move or delete it to start over. In interactive mode without a question tool, ask in plain text and wait for the reply. To start a new run, use a new folder and tell the user why."
    mkdir -p "$RUN"
    jq -n --arg g "$GRAPH" --arg m "$MODE" --arg e "$(jq -r .entry "$GRAPH")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{graph: $g, mode: $m, node: $e, started_at: $at, entered_at: $at, candidates: {}, history: []}' >"$STATE"
    print_next "$(state .node)"
    ;;
  next)
    [[ -f "$STATE" ]] || die 4 "no run in $WORK (init first)"
    GRAPH="$(state .graph)"
    if [[ -z "$CAND" && "$(state .node)" == candidates ]] && jq -e '[.candidates[] | select(.node != "folded") | .node] | length > 0 and all(. == "draft_choose")' "$STATE" >/dev/null; then
      print_next draft_choose
    elif [[ -z "$CAND" && "$(state .node)" == candidates ]]; then
      jq '{node: "candidates", candidates: (.candidates | with_entries(.value |= {node, measures, reviews, verdict})), how: "Each candidate runs its own path: landing-run.sh next --work <dir> --candidate <id>"}' "$STATE"
    else
      node="$(current)"; [[ -n "$node" ]] || die 4 "unknown candidate '$CAND'"
      print_next "$node" "$CAND"
    fi
    ;;
  submit)
    [[ -f "$STATE" && -n "$NODE" && -n "$OUTCOME" ]] || usage
    GRAPH="$(state .graph)"
    lock
    if [[ "$NODE" == draft_choose ]]; then
      [[ -z "$CAND" ]] || die 2 "draft_choose is one choice across the candidates; submit it without --candidate"
      [[ "$(state .mode)" == unattended ]] || die 3 "draft_choose belongs to unattended runs; an interactive run picks at draft_pick"
      [[ "$OUTCOME" == chosen ]] || die 3 "submit draft_choose with outcome chosen; the runner folds the others"
      waiting="$(jq -r '[.candidates | to_entries[] | select(.value.node | IN("draft", "preview", "draft_review")) | "\(.key) at \(.value.node)"] | join(", ")' "$STATE")"
      [[ -z "$waiting" ]] || die 3 "choose once every candidate's draft review is done: $waiting"
      at_choose="$(jq -r '[.candidates | to_entries[] | select(.value.node == "draft_choose") | .key] | join(" ")' "$STATE")"
      [[ -n "$at_choose" ]] || die 3 "no candidate is at draft_choose"
      pickf="$WORK/draft-pick.json"
      [[ -f "$pickf" ]] || die 4 "missing artifacts for draft_choose: draft-pick.json"
      since="$(jq '[.candidates[] | select(.node == "draft_choose") | .entered_at | fromdateiso8601] | max' "$STATE")"
      [[ "$(mtime "$pickf")" -ge "$since" ]] || die 4 "artifacts older than this node (write or update them in draft_choose): draft-pick.json"
      pick_bad="$(jq -r --arg ids "$at_choose" '
        def str: type == "string" and length > 0;
        ($ids | split(" ")) as $ids
        | [ (if (.kept | type) == "array" and (.kept | length) == 1 then empty else "kept must name exactly one candidate" end),
            (if .via == "agent" then empty else "via must be \"agent\"" end),
            (if (.reason | str) then empty else "reason is missing (why this candidate, and why not the others)" end),
            ((.kept // [])[] | select(($ids | index(.)) == null) | "\(.) is not a candidate at draft_choose")
          ] | join("; ")' "$pickf" 2>/dev/null)" || pick_bad="not valid JSON"
      [[ -z "$pick_bad" ]] || die 4 "draft-pick.json: $pick_bad"
      kept="$(jq -r '.kept[0]' "$pickf")"
      passed="$(jq -r '[.candidates | to_entries[] | select(.value.node == "draft_choose" and ((.value.draft_rounds // [])[-1].outcome == "draft_pass")) | .key] | join(" ")' "$STATE")"
      if [[ -n "$passed" && " $passed " != *" $kept "* ]]; then
        die 4 "draft-pick.json: choose a candidate whose draft passed ($passed); '$kept' was kept after its redo"
      fi
      reason="$(jq -r '.reason' "$pickf")"
      for c in $at_choose; do
        CAND="$c"
        if [[ "$c" == "$kept" ]]; then move draft_choose chosen >/dev/null; fi
      done
      save --arg k "$kept" --arg r "$reason" '.chosen = {candidate: $k, via: "agent", reason: $r}'
      for c in $at_choose; do
        [[ "$c" == "$kept" ]] && continue
        CAND="$c"; move draft_choose folded >/dev/null
        save --arg c "$c" --arg k "$kept" --arg r "$reason" '.candidates[$c].folded_reason = "\($k) was chosen: \($r)"'
      done
      printf 'build\n'
      exit 0
    fi
    node="$(current)"
    [[ "$node" == "$NODE" ]] || die 3 "current node is '${node:-none}', not '$NODE'"
    actor="$(graph ".nodes[\"$NODE\"].actor")"
    [[ "$actor" == maker || "$actor" == human ]] || die 3 "'$NODE' outcomes come from the runner (use measure or review)"
    per="$(graph ".nodes[\"$NODE\"].per_candidate // false")"
    if [[ "$per" == true && -z "$CAND" ]]; then die 2 "'$NODE' needs --candidate"; fi
    absent=()
    while IFS= read -r a; do
      [[ -z "$a" || -e "$WORK/$a" ]] || absent+=("$a")
    done < <(artifacts "$NODE" "$CAND")
    [[ ${#absent[@]} -eq 0 ]] || die 4 "missing artifacts for $NODE: ${absent[*]}"
    # Artifacts must be made in this node, not before it: work done ahead and submitted in a burst skips the node's purpose.
    since="$(entered_epoch)"; stale=()
    while IFS= read -r a; do
      [[ -z "$a" ]] && continue
      [[ "$(mtime "$WORK/$a")" -ge "$since" ]] || stale+=("$a")
    done < <(artifacts "$NODE" "$CAND")
    [[ ${#stale[@]} -eq 0 ]] || die 4 "artifacts older than this node (write or update them in $NODE): ${stale[*]}"
    # The tone and manner is decided in the brief and confirmed with the references, not left implicit.
    if [[ "$NODE" == brief ]]; then
      grep -q '^## Tone and manner' "$WORK/brief.md" || die 4 "brief.md needs a '## Tone and manner' section (direction.md, Brief)"
      tone_bad="$(jq -r "$TONE_CHECK" "$WORK/tone.json" 2>/dev/null)" || tone_bad="tone.json is not valid JSON"
      [[ -z "$tone_bad" ]] || die 4 "tone.json: $tone_bad (direction.md, Brief)"
    fi
    # The board's tabs are drawn from these: enough of every kind for the mode (references_min in the graph; an interactive
    # board is looked at, an unattended one only backs the report), competitors analysed, interactions recorded.
    if [[ "$NODE" == references && "$OUTCOME" == references_ready ]]; then
      refs_min="$(jq -c --arg m "$(state .mode)" '.references_min[$m] // {}' "$GRAPH")"
      refs_bad="$(jq -r --argjson min "$refs_min" "$REFS_CHECK" "$WORK/references.json" 2>/dev/null)" || refs_bad="references.json is not valid JSON"
      [[ -z "$refs_bad" ]] || die 4 "references.json: $refs_bad (direction.md, References)"
      search_bad="$(jq -r --slurpfile refs "$WORK/references.json" "$SEARCH_CHECK" "$WORK/searches.json" 2>/dev/null)" || search_bad="searches.json is not valid JSON"
      [[ -z "$search_bad" ]] || die 4 "searches.json: $search_bad (direction.md, References)"
      slots_bad="$(jq -r "$SLOTS_CHECK" "$WORK/component-slots.json" 2>/dev/null)" || slots_bad="component-slots.json is not valid JSON"
      [[ -z "$slots_bad" ]] || die 4 "component-slots.json: $slots_bad (direction.md, References)"
      reco_bad="$(jq -r --slurpfile slots "$WORK/component-slots.json" "$RECO_CHECK" "$WORK/references.json")"
      [[ -z "$reco_bad" ]] || die 4 "references.json: $reco_bad (direction.md, Picking the primary references)"
      # Unattended: no board, so the agent writes the pick in the same shape.
      if [[ "$(state .mode)" == unattended ]]; then
        [[ -f "$WORK/reference-pick.json" ]] || die 4 "reference-pick.json is missing: an unattended run writes its own pick with primary and via: \"agent\""
        jq -e '.via == "agent"' "$WORK/reference-pick.json" >/dev/null 2>&1 || die 4 "reference-pick.json: an unattended pick says via: \"agent\""
        check_primary
      fi
    fi
    if [[ "$NODE" == reference_pick ]]; then
      jq -e '(.tone // "") | type == "string" and length > 0' "$WORK/reference-pick.json" >/dev/null \
        || die 4 "reference-pick.json needs tone: the user's answer on the tone and manner shown at the top of the board"
      check_primary
    fi
    if [[ "$NODE" == direction && "$OUTCOME" == direction_ready && -f "$WORK/reference-pick.json" ]] && jq -e '.primary' "$WORK/reference-pick.json" >/dev/null 2>&1; then
      cp_bad="$(jq -r --slurpfile pick "$WORK/reference-pick.json" --slurpfile refs "$WORK/references.json" "$CAND_PRIMARY_CHECK" "$WORK/candidates.json" 2>/dev/null)" \
        || cp_bad="candidates.json is not valid JSON"
      [[ -z "$cp_bad" ]] || die 4 "candidates.json: $cp_bad (direction.md, Direction candidates)"
    fi
    purl="" pf=""
    if [[ "$NODE" == preview ]]; then
      pf="$WORK/preview-$CAND.json"
      purl="$(jq -r '.url // empty' "$pf" 2>/dev/null || true)"
      [[ "$purl" =~ ^https?:// ]] || die 4 "preview-$CAND.json needs the served url"
      caps=0; nocap=()
      while IFS= read -r cpath; do
        [[ -z "$cpath" ]] && continue
        caps=$((caps + 1)); [[ "$cpath" == /* ]] || cpath="$WORK/$cpath"
        [[ -s "$cpath" ]] || nocap+=("$cpath")
      done < <(jq -r '.captures // [] | .[]' "$pf")
      [[ $caps -ge 2 && ${#nocap[@]} -eq 0 ]] || die 4 "preview-$CAND.json needs its 1440 and 390 captures as files: ${nocap[*]:-none listed}"
    fi
    move "$NODE" "$OUTCOME"
    if [[ "$NODE" == preview ]]; then notify_preview "$purl" "$pf"; fi
    ;;
  measure)
    [[ -f "$STATE" && -n "$CAND" && -n "$URL" ]] || usage
    GRAPH="$(state .graph)"
    lock
    [[ "$(current)" == measure ]] || die 3 "candidate '$CAND' is at '$(current)', not measure"
    n=$(( $(jq -r --arg c "$CAND" '.candidates[$c].measures' "$STATE") + 1 ))
    out="$WORK/measure-$CAND-$n.json"
    level="$(jq -r --arg c "$CAND" '.candidates[$c].motion_level' "$STATE")"
    # The lock is released while the browser runs; the candidate stays at measure, so no other command can move it.
    rmdir "$RUN/lock"; trap - EXIT
    read -r -a measure_cmd <<<"${LANDING_MEASURE_CMD:-node $ROOT/scripts/landing-measure.mjs}"
    "${measure_cmd[@]}" --url "$URL" --out "$out" --graph "$GRAPH" --motion-level "$level" >&2 || true
    lock
    [[ -f "$out" ]] || jq -n '{result: "unverified", reason: "measure script wrote no result"}' >"$out"
    result="$(jq -r '.result // "unverified"' "$out")"
    save --arg c "$CAND" --argjson n "$n" --arg r "$result" '.candidates[$c].measures = $n | .candidates[$c].measure = $r'
    max="$(graph '.limits.max_measure_repairs')"
    case "$result" in
      pass) outcome=measured_pass ;;
      fail) if [[ $n -gt $max ]]; then outcome=measure_limit_reached; else outcome=measured_fail; fi ;;
      *) outcome=measured_unverified ;;
    esac
    jq -c '{result, failed: [.checks[]? | select(.status == "fail") | .id]}' "$out" >&2 || true
    if [[ "$result" == pass ]]; then
      rmdir "$RUN/lock"; trap - EXIT
      cdir="$(run_capture "$URL" "$CAND-m$n")"
      lock
      [[ -z "$cdir" ]] || save --arg c "$CAND" --arg d "$cdir" '.candidates[$c].captures = $d'
      [[ -z "$cdir" ]] || printf '{"captures":"%s"}\n' "$WORK/$cdir" >&2
    fi
    move measure "$outcome"
    ;;
  review)
    [[ -f "$STATE" && -n "$CAND" && -n "$FILE" ]] || usage
    GRAPH="$(state .graph)"
    lock
    rnode="$(current)"
    [[ "$rnode" == review || "$rnode" == draft_review ]] || die 3 "candidate '$CAND' is at '$rnode', not review or draft_review"
    [[ -f "$FILE" ]] || die 4 "review file not found: $FILE"
    jq -e '(.checks | type) == "array"' "$FILE" >/dev/null 2>&1 || die 4 "review JSON needs a checks array"
    if [[ "$rnode" == draft_review ]]; then req="$(jq -c '.review_checks.draft' "$GRAPH")"; else req="$(required_checks)"; fi
    missing="$(jq -r --argjson req "$req" '[$req[] as $id | select(([.checks[] | .check] | index($id)) == null) | $id] | join(", ")' "$FILE")"
    [[ -z "$missing" ]] || die 4 "review is missing required checks: $missing (not counted; brief a new reviewer with every check)"
    bad="$(jq -r '[.checks[] | select((.status | IN("pass","fail","unverified")) | not) | .check] | join(", ")' "$FILE")"
    [[ -z "$bad" ]] || die 4 "checks with a status other than pass|fail|unverified: $bad"
    fvm="$(jq -c '.first_viewport_major // []' "$GRAPH")"
    nofv="$(jq -r --argjson fvm "$fvm" '[.checks[] | select(.status == "fail" and (.check as $c | $fvm | index($c)) and ((.first_viewport | type) != "boolean")) | .check] | join(", ")' "$FILE")"
    [[ -z "$nofv" ]] || die 4 "failed checks need \"first_viewport\": true|false: $nofv (not counted)"
    # A later round may carry a check that passed in an earlier round; never a first-viewport check, never one that did not pass.
    badcarry="$(jq -r --argjson fvm "$fvm" '[.checks[] | select(.carried != null) | select((.status != "pass") or (.check as $c | $fvm | index($c))) | .check] | join(", ")' "$FILE")"
    [[ -z "$badcarry" ]] || die 4 "carried checks must be passes outside first_viewport_major: $badcarry (not counted)"
    while IFS=$'\t' read -r cc cr; do
      [[ -z "$cc" ]] && continue
      prev="$WORK/review-$CAND-$cr.json"
      if [[ ! -f "$prev" ]] || ! jq -e --arg c "$cc" '.checks[] | select(.check == $c and .status == "pass")' "$prev" >/dev/null; then
        die 4 "check $cc is carried from round $cr, where it did not pass (not counted)"
      fi
    done < <(jq -r '.checks[] | select(.carried != null) | [.check, (.carried | tostring)] | @tsv' "$FILE")
    majors="$(jq --argjson fvm "$fvm" '[.checks[] | select(.status == "fail" and ((.severity // "major") == "major" or (.first_viewport == true and (.check as $c | $fvm | index($c)))))] | length' "$FILE")"
    if [[ "$rnode" == draft_review ]]; then
      # The draft's first viewport: redraw it once when it is weak, rather than finish it for an hour.
      k=$(( $(jq -r --arg c "$CAND" '.candidates[$c].draft_reviews // 0' "$STATE") + 1 ))
      cp "$FILE" "$WORK/draft-review-$CAND-$k.json"
      redos="$(jq -r --arg c "$CAND" '[.candidates[$c].draft_rounds // [] | .[] | select(.outcome == "draft_redo")] | length' "$STATE")"
      if [[ $majors -eq 0 ]]; then outcome=draft_pass
      elif [[ $redos -lt "$(graph '.limits.max_draft_redos // 1')" ]]; then outcome=draft_redo
      else outcome=draft_kept
      fi
      save --arg c "$CAND" --argjson k "$k" --arg o "$outcome" --argjson m "$majors" \
        '.candidates[$c].draft_reviews = $k | .candidates[$c].draft_rounds += [{round: $k, outcome: $o, majors: $m}]'
      printf '{"draft_round":%s,"outcome":"%s","majors":%s}\n' "$k" "$outcome" "$majors" >&2
      to="$(move draft_review "$outcome")"
      # A lone candidate has nothing to be chosen against: it goes on to build without a draft-pick.json.
      if [[ "$to" == draft_choose && "$(jq '.candidates | length' "$STATE")" -eq 1 ]]; then
        save --arg c "$CAND" '.chosen = {candidate: $c, via: "runner", reason: "the only candidate"}'
        to="$(move draft_choose chosen)"
      fi
      printf '%s\n' "$to"
      exit 0
    fi
    r=$(( $(jq -r --arg c "$CAND" '.candidates[$c].reviews' "$STATE") + 1 ))
    cp "$FILE" "$WORK/review-$CAND-$r.json"
    unverified="$(jq --argjson req "$req" '[.checks[] | select(.status == "unverified" and (.check as $c | $req | index($c)))] | length' "$FILE")"
    rendered="$(jq -r 'if .rendered == false then "no" else "yes" end' "$FILE")"
    inputs="$(jq '(.needs_input // []) | length' "$FILE")"
    measured="$(jq -r --arg c "$CAND" '.candidates[$c].measure // "unverified"' "$STATE")"
    max="$(graph '.limits.max_reviews')"
    if [[ "$rendered" == no ]]; then outcome=review_unverified; verdict=unverified
    elif [[ $majors -gt 0 ]]; then
      verdict=issues
      if [[ $r -ge $max ]]; then outcome=review_limit_reached; else outcome=review_issues; fi
    elif [[ $unverified -gt 0 || "$measured" != pass ]]; then outcome=review_unverified; verdict=unverified
    elif [[ $inputs -gt 0 ]]; then outcome=review_input_wait; verdict="issues (공개 불가: 입력 대기)"
    else outcome=review_verified; verdict=verified
    fi
    save --arg c "$CAND" --argjson r "$r" --arg v "$verdict" --argjson m "$majors" \
      '.candidates[$c].reviews = $r | .candidates[$c].verdict = $v | .candidates[$c].rounds += [{round: $r, verdict: $v, majors: $m}]'
    printf '{"round":%s,"verdict":"%s","majors":%s,"unverified_checks":%s,"needs_input":%s}\n' "$r" "$verdict" "$majors" "$unverified" "$inputs" >&2
    move review "$outcome"
    ;;
  capture)
    [[ -f "$STATE" && -n "$CAND" && -n "$URL" ]] || usage
    label="${LABEL:-$CAND-$(date +%H%M%S)}"
    [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die 2 "label may hold letters, digits, dot, dash, underscore"
    cdir="$(run_capture "$URL" "$label")"
    printf '%s\n' "${cdir:+$WORK/$cdir}"
    ;;
  capture-refs)
    [[ -n "$FILE" ]] || usage
    [[ -f "$FILE" ]] || die 2 "refs list not found: $FILE"
    list="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
    recs="$(jq '[.[]? | select(.record == true)] | length' "$list" 2>/dev/null)" || die 2 "$FILE is not valid JSON"
    mkdir -p "$WORK/refs"
    read -r -a refs_cmd <<<"${LANDING_CAPTURE_REFS_CMD:-node $ROOT/scripts/landing-capture-refs.mjs}"
    if [[ -n "$BACKGROUND" && "$recs" -gt 0 ]]; then
      "${refs_cmd[@]}" --work "$WORK" --file "$list" --phase stills
      # Recording takes about ten seconds a page: detached, so the take-lines and tone tags get written meanwhile.
      rm -f "$WORK/refs/record.done"
      nohup "${refs_cmd[@]}" --work "$WORK" --file "$list" --phase record >"$WORK/refs/record.log" 2>&1 </dev/null &
      printf '{"recording":"background","count":%s,"done_when":"%s"}\n' "$recs" "$WORK/refs/record.done" >&2
    else
      "${refs_cmd[@]}" --work "$WORK" --file "$list" --phase all
    fi
    ;;
  operate)
    [[ -f "$STATE" && -n "$URL" && -n "$FILE" ]] || usage
    [[ -f "$FILE" ]] || die 2 "script not found: $FILE"
    script="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
    [[ "$script" == "$WORK"/* ]] || die 4 "keep operate scripts inside the work folder ($WORK/operate/); an unattended run cannot write elsewhere"
    label="${LABEL:-$(basename "$script" .mjs)}"
    [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die 2 "label may hold letters, digits, dot, dash, underscore"
    [[ -z "$WIDTH" || "$WIDTH" =~ ^[0-9]+$ ]] || die 2 "width is a number of pixels"
    read -r -a operate_cmd <<<"${LANDING_OPERATE_CMD:-node $ROOT/scripts/landing-operate.mjs}"
    "${operate_cmd[@]}" --url "$URL" --script "$script" --out "$WORK/operate/out-$label" ${WIDTH:+--width "$WIDTH"}
    ;;
  board)
    case "$KIND" in
      references) [[ -f "$WORK/references.json" ]] || die 4 "references.json is missing in $WORK"; page=board.html ;;
      drafts) [[ -f "$WORK/candidates.json" ]] || die 4 "candidates.json is missing in $WORK"; page=draft-board.html ;;
      *) usage ;;
    esac
    [[ -z "$PORT" || "$PORT" =~ ^[0-9]+$ ]] || die 2 "port is a number"
    [[ -z "$SERVE" || -n "$PORT" ]] || die 2 "--serve needs --port"
    read -r -a board_cmd <<<"${LANDING_BOARD_CMD:-node $ROOT/scripts/landing-board.mjs}"
    if [[ -n "$PORT" ]]; then "${board_cmd[@]}" --work "$WORK" --kind "$KIND" >&2; else "${board_cmd[@]}" --work "$WORK" --kind "$KIND"; fi
    if [[ -n "$SERVE" ]]; then
      # Detached, not a background task of the session: a session task keeps a scripted run alive and is stopped later.
      nohup node "$ROOT/scripts/landing-board-server.mjs" --work "$WORK" --port "$PORT" >"$WORK/board-server.log" 2>&1 </dev/null &
      for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'board server:' "$WORK/board-server.log" 2>/dev/null && break; sleep 0.3; done
      grep -q 'board server:' "$WORK/board-server.log" || die 4 "board server did not start: $(tail -3 "$WORK/board-server.log")"
    fi
    [[ -z "$PORT" ]] || printf 'http://127.0.0.1:%s/%s\n' "$PORT" "$page"
    ;;
  wait-pick)
    [[ -f "$STATE" ]] || die 4 "no run in $WORK"
    case "$NODE" in reference_pick) pickf="$WORK/reference-pick.json" ;; draft_pick) pickf="$WORK/draft-pick.json" ;; *) usage ;; esac
    [[ "$TIMEOUT_MIN" =~ ^[0-9]+$ ]] || die 2 "timeout-min is a number of minutes"
    [[ "$(state .node)" == "$NODE" ]] || die 3 "current node is '$(state .node)', not '$NODE'"
    since="$(entered_epoch)"
    end=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
    while :; do
      # A pick from before this node started is an old answer, not this one.
      if [[ -s "$pickf" && "$(mtime "$pickf")" -ge "$since" ]]; then printf '%s\n' "$pickf"; exit 0; fi
      [[ "$(date +%s)" -lt "$end" ]] || die 4 "no pick in $TIMEOUT_MIN min; ask the user in plain text and wait for the reply"
      sleep 2
    done
    ;;
  status)
    [[ -f "$STATE" ]] || die 4 "no run in $WORK"
    GRAPH="$(state .graph)"
    jq --slurpfile g "$GRAPH" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      def mins($a; $b): if $a == null or $b == null then null else ((($b | fromdateiso8601) - ($a | fromdateiso8601)) / 60 | floor) end;
      .started_at as $s | ($g[0].budget_minutes // {}) as $bud
      | {mode, node, elapsed_min: mins($s; $now), chosen,
         candidates: (.candidates | with_entries(.value |= (
           {node, motion_level, measures, measure, reviews, verdict, rounds, folded_reason,
            preview_min: mins($s; .previewed_at), finished_min: mins($s; .finished_at)}
           | .over_budget = ([ (if $bud.preview != null and ((.preview_min // mins($s; $now)) > $bud.preview) and (.preview_min != null or .node == "draft" or .node == "preview") then "preview" else empty end),
                               (if $bud.done != null and ((.finished_min // mins($s; $now)) > $bud.done) then "done" else empty end) ])
         )))}' "$STATE"
    ;;
  *) usage ;;
esac
