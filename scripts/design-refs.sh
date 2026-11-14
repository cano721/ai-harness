#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq 식은 작은따옴표 그대로 넘긴다($refs·$min 등은 jq 변수)
# /design-references 공용 스크립트. 레퍼런스를 모으는 단계의 캡처·검사·보드를 한 곳에 두고, /landing-page 러너
# (landing-run.sh)도 같은 명령을 부른다 — 혼자 부른 스킬과 랜딩 실행이 같은 검사를 통과해야 같은 보드가 나온다.
#   - capture: refs-to-capture.json의 페이지를 한 번에 동시 4개로 캡처한다(봇 확인 화면은 challenge). 녹화는 --background로 분리.
#   - retake:  challenge·failed 캡처를 실제 브라우저에서 다시 찍은 PNG로 바꾸고 capture.json을 ok(via browser)로 고친다.
#   - check:   references.json·searches.json·component-slots.json을 검사한다. 종류별 개수(refs-rules.json), 검색 근거,
#              경쟁사 서로 다른 도메인 2곳 이상, 한 도메인은 한 kind에만, challenge·failed 캡처가 남은 레퍼런스 거부.
#              v0.69.0 무인 실행이 bot check 사이트를 다시 열지 않고 빼고, 같은 사이트를 여러 탭에 돌려 써서 실제 사이트
#              4곳으로 "다섯 종류 각 1개"를 통과했다.
#   - board:   tone.json·references.json으로 탭 5개 보드(board.html)를 그리고(--kind drafts면 시안 보드), --serve면 보드
#              서버를 분리 실행한다. 레퍼런스 보드를 만들 때마다 실행 기록을 <data>/board/references/<run-id>.json에 남긴다.
# 종료 코드: 0 성공, 2 사용법, 4 산출물·입력 불충분.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES="${DESIGN_REFS_RULES:-$ROOT/skills/design-references/references/refs-rules.json}"
DATA_DIR="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}"

die() { local code="$1"; shift; printf 'design-refs: %s\n' "$*" >&2; exit "$code"; }
usage() {
  cat >&2 <<'EOF'
usage:
  design-refs.sh capture --work DIR --file REFS-TO-CAPTURE.json [--background]
  design-refs.sh retake  --work DIR --id CAPTURE_ID --shot WIDTH:PNG [--shot WIDTH:PNG]
  design-refs.sh check   --work DIR [--mode interactive|unattended]
  design-refs.sh board   --work DIR [--kind references|drafts] [--topic TEXT] [--port N --serve]
  design-refs.sh run-id  --work DIR
EOF
  exit 2
}

cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift
WORK="" FILE="" BACKGROUND="" ID="" MODE="interactive" KIND="references" TOPIC="" PORT="" SERVE=""
SHOTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work) WORK="$2"; shift 2 ;;
    --file) FILE="$2"; shift 2 ;;
    --background) BACKGROUND=1; shift ;;
    --id) ID="$2"; shift 2 ;;
    --shot) SHOTS+=("$2"); shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --topic) TOPIC="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --serve) SERVE=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$WORK" ]] || usage
WORK="$(cd "$WORK" 2>/dev/null && pwd)" || die 2 "work directory not found"

# Same id for the same work folder: a board drawn again updates its record instead of adding one.
run_id() { printf '%s' "$WORK" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12; }

REFS_CHECK='
  def str: type == "string" and length > 0;
  ["tone", "component", "layout", "interaction", "competitor"] as $kinds
  | if type != "array" then "must be an array of references" else
    . as $refs
    | [ (.[] | select((.kind as $k | $kinds | index($k)) == null) | "\(.id // "?"): kind must be one of \($kinds | join("|")) (got \(.kind // "none"))"),
      ([.[].id] | group_by(.)[] | select(length > 1) | "id \(.[0]) is used twice"),
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

# One site is evidence for one kind: a board whose tabs repeat the same few sites gives the user nothing to choose from.
# The product's own site is no exception — it is the brand source behind tone.json, so at most it is a tone reference.
# Domain: the host without www and port, cut to its registrable part (two labels; three under co.kr-style suffixes and
# hosting suffixes such as pages.dev or vercel.app, where each subdomain is someone else's site).
DOMAIN_CHECK='
  def domain: ascii_downcase | sub("^[a-z][a-z0-9+.-]*://"; "") | sub("[/?#].*$"; "") | sub("^[^@]*@"; "")
    | if test("^[0-9.]+(:[0-9]+)?$") or test("^localhost(:[0-9]+)?$") then . else
        sub(":[0-9]+$"; "") | sub("^www\\."; "") | split(".") as $p
        | if ($p | length) >= 3 and ((($p[-1] | length) == 2
               and (["co","or","go","ac","ne","re","pe","com","net","org","gov","edu"] | index($p[-2])) != null)
             or ($p[-2:] | join(".") | IN("pages.dev","vercel.app","netlify.app","lovable.app","github.io","web.app",
               "firebaseapp.com","herokuapp.com","webflow.io","framer.website","framer.app","notion.site","wixsite.com",
               "onrender.com","fly.dev","glitch.me","replit.app","surge.sh")))
          then $p[-3:] | join(".") elif ($p | length) >= 2 then $p[-2:] | join(".") else $p | join(".") end end;
  if type != "array" then empty else
  [ ( [.[] | select((.url | type) == "string" and (.url | test("^https?://"))) | {d: (.url | domain), kind, id}]
      | group_by(.d)[] | select(([.[].kind] | unique | length) > 1)
      | "\(.[0].d) is used in \([.[].kind] | unique | join(" and ")) (\([.[].id] | join(", "))); one site serves one kind — find another site for the rest"),
    ([.[] | select(.kind == "competitor" and (.url | type) == "string") | .url | domain] | unique | length) as $n
      | (if $n >= ($min.competitor_domains // 2) then empty
         else "competitor covers \($n) site(s), needs at least \($min.competitor_domains // 2) different domains" end)
  ] | join("; ") end'

# A reference whose capture hit a bot check or failed shows nothing on the board: reopen it in a real browser and retake,
# or swap in another site. $caps maps each refs/<id>/ folder to its capture.json status.
CAPTURE_CHECK='
  if type != "array" then empty else
  [ .[] | . as $r
    | ([$r.id] + [((($r.captures // []) | if type == "array" then . else [] end)[]), ($r.video // empty) | strings
         | capture("(^|/)refs/(?<c>[^/]+)/").c?]) | unique[] as $c
    | ($caps[$c] // empty) as $s | select($s == "challenge" or $s == "failed")
    | "\($r.id): refs/\($c) is \($s) — reopen it in a real browser and retake it (design-refs.sh retake), or swap in another site"
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

# The recommendation, starred on the board before the user looks: one layout, one interaction, one component per slot at most.
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

RULES_CHECK='
  ["interactive", "unattended"] | all(. as $m | $rules[0][$m] as $r
    | ($r | type) == "object"
    and (["tone","component","layout","interaction","competitor"] | all(. as $k | ($r.per_kind[$k] | type) == "number" and $r.per_kind[$k] >= 1))
    and ($r.interaction_video | type) == "number" and $r.interaction_video <= $r.per_kind.interaction
    and ($r.competitor_max | type) == "number" and $r.competitor_max >= $r.per_kind.competitor
    and ($r.competitor_domains | type) == "number" and $r.competitor_domains >= 2 and $r.competitor_domains <= $r.competitor_max)'

capture_statuses() {
  local f d out="{}"
  for f in "$WORK"/refs/*/capture.json; do
    [[ -f "$f" ]] || continue
    d="$(basename "$(dirname "$f")")"
    out="$(jq -c --arg d "$d" --slurpfile c "$f" '. + {($d): ($c[0].status // "ok")}' <<<"$out" 2>/dev/null || printf '%s' "$out")"
  done
  printf '%s\n' "$out"
}

# Print every problem, one "file: problems" line each; nothing when the reference set passes.
run_check() {
  local min bad caps f
  jq -e -n --slurpfile rules "$RULES" "$RULES_CHECK" >/dev/null 2>&1 || die 2 "invalid rules file: $RULES"
  [[ "$MODE" == interactive || "$MODE" == unattended ]] || die 2 "mode is interactive or unattended"
  min="$(jq -c --arg m "$MODE" '.[$m]' "$RULES")"
  for f in references.json searches.json component-slots.json; do
    [[ -f "$WORK/$f" ]] || printf '%s: missing\n' "$f"
  done
  [[ -f "$WORK/references.json" && -f "$WORK/searches.json" && -f "$WORK/component-slots.json" ]] || return 0
  bad="$(jq -r --argjson min "$min" "$REFS_CHECK" "$WORK/references.json" 2>/dev/null)" || bad="not valid JSON"
  [[ -z "$bad" ]] || printf 'references.json: %s\n' "$bad"
  bad="$(jq -r --argjson min "$min" "$DOMAIN_CHECK" "$WORK/references.json" 2>/dev/null)" || bad=""
  [[ -z "$bad" ]] || printf 'references.json: %s\n' "$bad"
  caps="$(capture_statuses)"
  bad="$(jq -r --argjson caps "$caps" "$CAPTURE_CHECK" "$WORK/references.json" 2>/dev/null)" || bad=""
  [[ -z "$bad" ]] || printf 'references.json: %s\n' "$bad"
  bad="$(jq -r --slurpfile refs "$WORK/references.json" "$SEARCH_CHECK" "$WORK/searches.json" 2>/dev/null)" || bad="not valid JSON"
  [[ -z "$bad" ]] || printf 'searches.json: %s\n' "$bad"
  bad="$(jq -r "$SLOTS_CHECK" "$WORK/component-slots.json" 2>/dev/null)" || bad="not valid JSON"
  [[ -z "$bad" ]] || printf 'component-slots.json: %s\n' "$bad"
  bad="$(jq -r --slurpfile slots "$WORK/component-slots.json" "$RECO_CHECK" "$WORK/references.json" 2>/dev/null)" || bad=""
  [[ -z "$bad" ]] || printf 'references.json: %s\n' "$bad"
  return 0
}

# The run record a dashboard reads to list reference boards: one file per work folder, rewritten on every draw.
write_record() {
  local dir file id topic created status now tmp
  id="$(run_id)"; dir="$DATA_DIR/board/references"; file="$dir/$id.json"
  mkdir -p "$dir"; chmod 700 "$DATA_DIR" 2>/dev/null || true
  topic="$TOPIC"
  if [[ -z "$topic" && -f "$file" ]]; then topic="$(jq -r '.topic // ""' "$file" 2>/dev/null || true)"; fi
  if [[ -z "$topic" && -f "$WORK/brief.md" ]]; then topic="$(grep -m1 -v '^[[:space:]]*$' "$WORK/brief.md" | sed 's/^#* *//' | cut -c1-200)"; fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  created="$(jq -r '.created_at // empty' "$file" 2>/dev/null || true)"
  status=ready
  if [[ -f "$file" && -f "$WORK/reference-pick.json" ]] && [[ "$(jq -r '.status // ""' "$file" 2>/dev/null)" == picked ]]; then status=picked; fi
  tmp="$dir/.$id.$$.tmp"
  jq -n --arg id "$id" --arg w "$WORK" --arg t "$topic" --arg s "$status" --arg c "${created:-$now}" --arg u "$now" \
    --arg r "$WORK/references.json" --arg b "$WORK/board.html" --arg p "$PORT" \
    '{run_id: $id, work: $w, topic: $t, status: $s, created_at: $c, updated_at: $u, references: $r, board: $b}
     + (if $p != "" then {url: "http://127.0.0.1:\($p)/board.html"} else {} end)' >"$tmp"
  mv "$tmp" "$file"
  printf '%s\n' "$file"
}

case "$cmd" in
  run-id) run_id; printf '\n' ;;
  capture)
    [[ -n "$FILE" ]] || usage
    [[ -f "$FILE" ]] || die 2 "refs list not found: $FILE"
    list="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
    recs="$(jq '[.[]? | select(.record == true)] | length' "$list" 2>/dev/null)" || die 2 "$FILE is not valid JSON"
    mkdir -p "$WORK/refs"
    read -r -a refs_cmd <<<"${LANDING_CAPTURE_REFS_CMD:-node $ROOT/scripts/landing-capture-refs.mjs}"
    if [[ -n "$BACKGROUND" && "$recs" -gt 0 ]]; then
      "${refs_cmd[@]}" --work "$WORK" --file "$list" --phase stills
      # Recording takes about ten seconds a page: detached, so the take-lines get written meanwhile.
      rm -f "$WORK/refs/record.done"
      nohup "${refs_cmd[@]}" --work "$WORK" --file "$list" --phase record >"$WORK/refs/record.log" 2>&1 </dev/null &
      printf '{"recording":"background","count":%s,"done_when":"%s"}\n' "$recs" "$WORK/refs/record.done" >&2
    else
      "${refs_cmd[@]}" --work "$WORK" --file "$list" --phase all
    fi
    ;;
  retake)
    [[ "$ID" =~ ^[A-Za-z0-9._-]+$ && "$ID" != .* ]] || die 2 "--id is a capture id (letters, digits, dot, dash, underscore)"
    [[ ${#SHOTS[@]} -gt 0 ]] || die 2 "--shot WIDTH:PNG is required (the page as the real browser showed it)"
    cdir="$WORK/refs/$ID"; mkdir -p "$cdir"
    prev="$(jq -r '.status // "none"' "$cdir/capture.json" 2>/dev/null || printf 'none')"
    caps=()
    for s in "${SHOTS[@]}"; do
      w="${s%%:*}"; src="${s#*:}"
      [[ "$w" =~ ^[0-9]+$ && "$w" -ge 200 && "$w" -le 3000 ]] || die 2 "shot width must be pixels: $s"
      [[ -s "$src" ]] || die 4 "shot not found or empty: $src"
      [[ "$(head -c 8 "$src" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]] || die 4 "shot is not a PNG: $src"
      cp "$src" "$cdir/w$w-00.png"; caps+=("refs/$ID/w$w-00.png")
    done
    tmp="$cdir/.capture.$$.tmp"
    jq -n --arg id "$ID" --arg prev "$prev" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson old "$(jq -c 'objects' "$cdir/capture.json" 2>/dev/null || printf '{}')" \
      --args '($old // {}) + {id: $id, status: "ok", captures: $ARGS.positional, retaken: {via: "browser", from: ($old.retaken.from // $prev), at: $at}} | del(.reason)' \
      "${caps[@]}" >"$tmp"
    mv "$tmp" "$cdir/capture.json"
    printf '%s\n' "$cdir/capture.json"
    ;;
  check)
    out="$(run_check)"
    if [[ -n "$out" ]]; then printf '%s\n' "$out" >&2; exit 4; fi
    printf 'ok\n'
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
    if [[ "$KIND" == references ]]; then write_record >/dev/null; fi
    if [[ -n "$SERVE" ]]; then
      # Already serving this folder on this port (the references step served it, the pick step asks again): keep it.
      if ! pgrep -f "landing-board-server.mjs --work $WORK --port $PORT" >/dev/null 2>&1; then
        # Detached, not a background task of the session: a session task keeps a scripted run alive and is stopped later.
        nohup node "$ROOT/scripts/landing-board-server.mjs" --work "$WORK" --port "$PORT" >"$WORK/board-server.log" 2>&1 </dev/null &
        for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'board server:' "$WORK/board-server.log" 2>/dev/null && break; sleep 0.3; done
        grep -q 'board server:' "$WORK/board-server.log" || die 4 "board server did not start: $(tail -3 "$WORK/board-server.log")"
      fi
    fi
    [[ -z "$PORT" ]] || printf 'http://127.0.0.1:%s/%s\n' "$PORT" "$page"
    ;;
  *) usage ;;
esac
