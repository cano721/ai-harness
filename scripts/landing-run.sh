#!/usr/bin/env bash
# shellcheck disable=SC2016  # save에 넘기는 작은따옴표 인자는 jq 식이다($c·$t 등은 jq 변수)
# /landing-page 그래프 러너. 모델이 아니라 이 스크립트가 다음 노드를 정한다.
#   - 상태: <work>/.landing-run/state.json. 후보마다 노드·측정 횟수·검토 회차·판정을 따로 둔다(후보 서브에이전트가 동시에 써도 잠금으로 직렬화).
#   - submit: 만드는 쪽(maker·human 노드)이 결과를 낸다. 노드 산출물이 없거나, 그래프에 없는 전이면 거부한다.
#   - measure: 측정 스크립트를 직접 돌려 결과(pass·fail·unverified)로 전이를 고른다. 모델이 measured_pass를 낼 수 없다.
#   - review: 검토 JSON을 받아 필수 항목이 다 있는지 보고, 판정과 전이를 계산한다. 항목이 빠진 검토는 회차로 세지 않고 거부한다.
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
  landing-run.sh status  --work DIR
EOF
  exit 2
}

cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift
WORK="" MODE="" GRAPH_ARG="" CAND="" NODE="" OUTCOME="" URL="" FILE=""
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

current() { if [[ -n "$CAND" ]]; then jq -r --arg c "$CAND" '.candidates[$c].node // empty' "$STATE"; else state .node; fi; }

move() {
  local from="$1" outcome="$2" to
  to="$(edge "$from" "$outcome")"
  [[ -n "$to" ]] || die 3 "no edge from '$from' on '$outcome' in $(state .mode) mode"
  local at; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -n "$CAND" ]]; then
    save --arg c "$CAND" --arg t "$to" --arg f "$from" --arg o "$outcome" --arg at "$at" \
      '.candidates[$c].node = $t | .history += [{candidate: $c, from: $f, outcome: $o, to: $t, at: $at}]
       | if $t == "build" then .candidates[$c].previewed_at = $at elif ($t == "done" or $t == "user_decision") then .candidates[$c].finished_at = $at else . end'
  else
    save --arg t "$to" --arg f "$from" --arg o "$outcome" --arg at "$at" \
      '.node = $t | .history += [{from: $f, outcome: $o, to: $t, at: $at}]'
  fi
  # Leaving the shared steps: the candidates listed in candidates.json start their own paths at draft.
  if [[ -z "$CAND" && "$to" == "draft" ]]; then
    [[ -f "$WORK/candidates.json" ]] || die 4 "candidates.json is missing"
    local cands
    cands="$(jq -c '[.candidates[] | {key: .id, value: {dir: .dir, motion_level: (.motion_level // "calm"), node: "draft", measures: 0, reviews: 0, verdict: null}}] | from_entries' "$WORK/candidates.json")" \
      || die 4 "candidates.json must hold {\"candidates\":[{\"id\",\"dir\",\"motion_level\"}]}"
    [[ "$(jq 'length' <<<"$cands")" -ge 1 ]] || die 4 "candidates.json lists no candidate"
    save --argjson cs "$cands" '.candidates = $cs | .node = "candidates"'
  fi
  printf '%s\n' "$to"
}

print_next() {
  local node="$1" c="${2:-}" actor
  actor="$(jq -r --arg n "$node" '.nodes[$n].actor // "runner"' "$GRAPH")"
  local outs
  outs="$(jq -c --arg f "$node" --arg m "$(state .mode)" '[.transitions[] | select(.from == $f and ((.mode // $m) == $m)) | .when] | unique' "$GRAPH")"
  local docs
  docs="$(jq -c --arg n "$node" --arg base "$ROOT/skills/landing-page/" '[.nodes[$n].docs // [] | .[] | $base + .]' "$GRAPH")"
  local arts
  arts="$(artifacts "$node" "$c" | jq -R . | jq -sc --arg w "$WORK/" 'map($w + .)')"
  local how
  case "$actor" in
    maker) how="Do this node's work (read only the docs listed), write the artifacts, then: landing-run.sh submit --work <dir> --node $node --outcome <one of outcomes>${c:+ --candidate $c}" ;;
    human) how="Ask the user (in an interactive session), record their answer in the artifact, then submit with outcome picked${c:+ --candidate $c}" ;;
    runner) case "$node" in
        measure) how="Serve the page, then: landing-run.sh measure --work <dir> --candidate $c --url <served url>" ;;
        *) how="Terminal: report this candidate (landing-run.sh status)" ;;
      esac ;;
    reviewer) how="Start a new design-reviewer with the briefing in verify.md and the required checks below; save its JSON, then: landing-run.sh review --work <dir> --candidate $c --file <review json>" ;;
  esac
  local checks="[]"
  if [[ "$node" == "review" ]]; then checks="$(required_checks)"; fi
  jq -n --arg node "$node" --arg actor "$actor" --arg c "$c" --argjson outcomes "$outs" --argjson docs "$docs" \
    --argjson artifacts "$arts" --arg how "$how" --argjson checks "$checks" \
    '{node: $node, actor: $actor} + (if $c != "" then {candidate: $c} else {} end)
     + {docs: $docs, artifacts: $artifacts, outcomes: $outcomes, how: $how}
     + (if ($checks | length) > 0 then {required_checks: $checks} else {} end)'
}

required_checks() {
  local multi; multi="$(jq '.candidates | length' "$STATE")"
  jq -c --argjson multi "$multi" '.review_checks.public_page + (if $multi > 1 then .review_checks.multi_candidate else [] end)' "$GRAPH"
}

case "$cmd" in
  init)
    [[ "$MODE" == interactive || "$MODE" == unattended ]] || usage
    GRAPH="${GRAPH_ARG:-$DEFAULT_GRAPH}"
    "$ROOT/scripts/validate-landing-page-graph.sh" "$GRAPH" >/dev/null
    [[ ! -f "$STATE" ]] || die 3 "a run already exists in $RUN"
    mkdir -p "$RUN"
    jq -n --arg g "$GRAPH" --arg m "$MODE" --arg e "$(jq -r .entry "$GRAPH")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{graph: $g, mode: $m, node: $e, started_at: $at, candidates: {}, history: []}' >"$STATE"
    print_next "$(state .node)"
    ;;
  next)
    [[ -f "$STATE" ]] || die 4 "no run in $WORK (init first)"
    GRAPH="$(state .graph)"
    if [[ -z "$CAND" && "$(state .node)" == candidates ]]; then
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
    move "$NODE" "$OUTCOME"
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
    move measure "$outcome"
    ;;
  review)
    [[ -f "$STATE" && -n "$CAND" && -n "$FILE" ]] || usage
    GRAPH="$(state .graph)"
    lock
    [[ "$(current)" == review ]] || die 3 "candidate '$CAND' is at '$(current)', not review"
    [[ -f "$FILE" ]] || die 4 "review file not found: $FILE"
    jq -e '(.checks | type) == "array"' "$FILE" >/dev/null 2>&1 || die 4 "review JSON needs a checks array"
    req="$(required_checks)"
    missing="$(jq -r --argjson req "$req" '[$req[] as $id | select(([.checks[] | .check] | index($id)) == null) | $id] | join(", ")' "$FILE")"
    [[ -z "$missing" ]] || die 4 "review is missing required checks: $missing (not counted; brief a new reviewer with every check)"
    bad="$(jq -r '[.checks[] | select((.status | IN("pass","fail","unverified")) | not) | .check] | join(", ")' "$FILE")"
    [[ -z "$bad" ]] || die 4 "checks with a status other than pass|fail|unverified: $bad"
    r=$(( $(jq -r --arg c "$CAND" '.candidates[$c].reviews' "$STATE") + 1 ))
    cp "$FILE" "$WORK/review-$CAND-$r.json"
    majors="$(jq '[.checks[] | select(.status == "fail" and (.severity // "major") == "major")] | length' "$FILE")"
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
  status)
    [[ -f "$STATE" ]] || die 4 "no run in $WORK"
    GRAPH="$(state .graph)"
    jq --slurpfile g "$GRAPH" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      def mins($a; $b): if $a == null or $b == null then null else ((($b | fromdateiso8601) - ($a | fromdateiso8601)) / 60 | floor) end;
      .started_at as $s | ($g[0].budget_minutes // {}) as $bud
      | {mode, node, elapsed_min: mins($s; $now),
         candidates: (.candidates | with_entries(.value |= (
           {node, motion_level, measures, measure, reviews, verdict, rounds,
            preview_min: mins($s; .previewed_at), finished_min: mins($s; .finished_at)}
           | .over_budget = ([ (if $bud.preview != null and ((.preview_min // mins($s; $now)) > $bud.preview) and (.preview_min != null or .node == "draft" or .node == "preview") then "preview" else empty end),
                               (if $bud.done != null and ((.finished_min // mins($s; $now)) > $bud.done) then "done" else empty end) ])
         )))}' "$STATE"
    ;;
  *) usage ;;
esac
