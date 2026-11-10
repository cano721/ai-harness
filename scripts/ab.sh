#!/usr/bin/env bash
# 통제 실험(A/B): 같은 과제를 프로젝트 하네스가 있는 저장소와 없는 저장소에서 실제 에이전트로 돌려 숨긴 검사로 채점한다.
#   ab.sh run [--suite <dir>] [--case <name>]... [--runs N] [--model M] [--max-cost USD] [--run-budget USD]
#             [--timeout SECS] [--out <json>] [--keep]
#   ab.sh estimate [--suite <dir>] [--case <name>]... [--runs N]   실행 횟수만 출력
# suite: <suite>/fixtures/<f>/{base,harness}, <suite>/cases/<case>/{task.md,check.py,fixture(선택, 기본 orders-service)}
# 하네스 arm = base + harness 덮어쓰기(AGENTS.md·CLAUDE.md·.ai-harness), bare arm = base만. 두 arm 모두 같은 플러그인 환경이다.
# 에이전트 실행은 HM_INTERNAL_SESSION=1·--no-session-persistence라 사용 기록(metrics·harvest)에 섞이지 않는다.
# HM_AB_AGENT_CMD가 있으면 claude 대신 그 명령을 작업 폴더에서 "<cmd> <task_file>"로 부른다(테스트용).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DIR/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$DIR/lib.sh"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
need_value() { (($# >= 2)) || usage; }

SUITE="$ROOT_DIR/evals/ab"
CASES=()
RUNS=2
MODEL=""
MAX_COST=10
RUN_BUDGET=3
TIMEOUT=1200
OUT=""
KEEP=0

parse() {
  while (($#)); do
    case "$1" in
      --suite) need_value "$@"; SUITE="$2"; shift 2 ;;
      --case) need_value "$@"; CASES+=("$2"); shift 2 ;;
      --runs) need_value "$@"; RUNS="$2"; shift 2 ;;
      --model) need_value "$@"; MODEL="$2"; shift 2 ;;
      --max-cost) need_value "$@"; MAX_COST="$2"; shift 2 ;;
      --run-budget) need_value "$@"; RUN_BUDGET="$2"; shift 2 ;;
      --timeout) need_value "$@"; TIMEOUT="$2"; shift 2 ;;
      --out) need_value "$@"; OUT="$2"; shift 2 ;;
      --keep) KEEP=1; shift ;;
      *) usage ;;
    esac
  done
  [[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "잘못된 --runs: $RUNS" >&2; exit 2; }
  [[ "$MAX_COST" =~ ^[0-9]+(\.[0-9]+)?$ && "$RUN_BUDGET" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "비용은 숫자" >&2; exit 2; }
  [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "잘못된 --timeout: $TIMEOUT" >&2; exit 2; }
  [[ -d "$SUITE/cases" ]] || { echo "suite 없음: $SUITE" >&2; exit 2; }
  if ((${#CASES[@]} == 0)); then
    local d=""
    for d in "$SUITE"/cases/*/; do CASES+=("$(basename "$d")"); done
  fi
  ((${#CASES[@]} > 0)) || { echo "케이스 없음: $SUITE/cases" >&2; exit 2; }
  local c=""
  for c in "${CASES[@]}"; do
    [[ -f "$SUITE/cases/$c/task.md" && -f "$SUITE/cases/$c/check.py" ]] || { echo "케이스 없음: $c" >&2; exit 2; }
  done
}

prepare_ws() { # case arm → 작업 폴더 경로
  local case_dir="$SUITE/cases/$1" arm="$2" fixture="orders-service" ws=""
  [[ -f "$case_dir/fixture" ]] && fixture="$(tr -d '[:space:]' <"$case_dir/fixture")"
  ws="$(mktemp -d "${TMPDIR:-/tmp}/ai-harness-ab.XXXXXX")"
  cp -R "$SUITE/fixtures/$fixture/base/." "$ws/"
  [[ "$arm" == "harness" ]] && cp -R "$SUITE/fixtures/$fixture/harness/." "$ws/"
  git -C "$ws" init -q
  git -C "$ws" add -A
  git -C "$ws" -c user.email=ab@example.invalid -c user.name=ab commit -q -m fixture
  printf '%s\n' "$ws"
}

run_agent() { # ws task_file out_json
  local ws="$1" task="$2" out="$3" rc=0
  local -a agent_cmd
  if [[ -n "${HM_AB_AGENT_CMD:-}" ]]; then
    agent_cmd=("$HM_AB_AGENT_CMD" "$task")
  else
    agent_cmd=(claude -p "$(cat "$task")" --output-format json --no-session-persistence
      --permission-mode acceptEdits --max-budget-usd "$RUN_BUDGET")
    [[ -n "$MODEL" ]] && agent_cmd+=(--model "$MODEL")
    # 두 조건 모두 플러그인을 로드하므로, 플러그인 폴더의 하네스 문서·채점기를 읽어 bare 조건이 규칙을 알게 되지 않게 막는다.
    agent_cmd+=(--disallowedTools "Read(/$ROOT_DIR/**)" "Glob(/$ROOT_DIR/**)" "Grep(/$ROOT_DIR/**)"
      "Read(~/.claude/plugins/**)" "Glob(~/.claude/plugins/**)" "Grep(~/.claude/plugins/**)"
      --allowedTools "Read" "Edit" "Write" "Glob" "Grep" "Bash(python3 -m unittest:*)" "Bash(git diff:*)" "Bash(git status:*)")
  fi
  (cd "$ws" && HM_INTERNAL_SESSION=1 AI_HARNESS_HEADLESS=1 hm_run_with_timeout "$TIMEOUT" "${agent_cmd[@]}" </dev/null >"$out" 2>"$out.err") || rc=$?
  return "$rc"
}

command_estimate() {
  parse "$@"
  jq -cn --argjson cases "${#CASES[@]}" --argjson runs "$RUNS" \
    '{cases: $cases, arms: 2, runs_per_arm: $runs, agent_runs: ($cases * 2 * $runs)}'
}

command_run() {
  parse "$@"
  [[ -n "${HM_AB_AGENT_CMD:-}" ]] || command -v claude >/dev/null || { echo "claude CLI가 없음 — A/B 실험은 Claude Code에서만 돈다" >&2; exit 3; }
  if ! command -v python3 >/dev/null || ! command -v git >/dev/null; then echo "python3·git이 필요함" >&2; exit 3; fi
  [[ -n "$OUT" ]] || OUT="$HM_DATA_DIR/reports/ab-$(date -u +%Y%m%dT%H%M%SZ).json"
  mkdir -p "$(dirname "$OUT")"
  AB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-harness-ab-run.XXXXXX")"
  trap 'find "$AB_TMP" -depth -delete 2>/dev/null || true' EXIT
  local rec="$AB_TMP/records.jsonl" spent="0" partial=false c="" arm="" r=0 ws="" rc=0 checks="" diff="" agent_json=""
  : >"$rec"
  for c in "${CASES[@]}"; do
    for r in $(seq 1 "$RUNS"); do
      # 같은 회차의 두 arm을 이어 돌려 시간대·모델 상태 차이가 한쪽에 몰리지 않게 한다.
      # 한 회차(두 조건)를 다 돌 예산이 없으면 시작하지 않는다 — 한쪽만 돈 회차가 비교를 기울이지 않게.
      if ! jq -en --argjson s "$spent" --argjson m "$MAX_COST" --argjson b "$RUN_BUDGET" '$s + 2 * $b <= $m' >/dev/null; then
        partial=true; break 2
      fi
      for arm in harness bare; do
        printf '[ab] %s · %s · %d/%d\n' "$c" "$arm" "$r" "$RUNS" >&2
        ws="$(prepare_ws "$c" "$arm")"
        rc=0
        run_agent "$ws" "$SUITE/cases/$c/task.md" "$AB_TMP/agent.json" || rc=$?
        # json 출력이 이벤트 배열이면 마지막 result를 쓴다.
        agent_json="$(jq -c 'if type == "array" then (map(select(type == "object" and .type == "result")) | last // {})
          elif type == "object" then . else {} end' "$AB_TMP/agent.json" 2>/dev/null || true)"
        [[ -n "$agent_json" ]] || { agent_json='{}'; printf '[ab] 에이전트 결과 JSON 없음 (%s)\n' "$c/$arm/$r" >&2; }
        # diff는 채점 전에 뜬다(채점이 만드는 캐시 파일이 섞이지 않게). 큰 diff의 SIGPIPE가 실험을 멈추지 않게 한다.
        diff="$( { git -C "$ws" add -A >/dev/null 2>&1; git -C "$ws" diff --cached --no-color 2>/dev/null | head -c 20000; } || true)"
        checks="$( { PYTHONDONTWRITEBYTECODE=1 hm_run_with_timeout 300 python3 -B -I "$SUITE/cases/$c/check.py" "$ws" </dev/null 2>/dev/null | tail -1; } || true)"
        jq -e '.checks | type == "array" and length > 0' >/dev/null 2>&1 <<<"$checks" || checks='{"checks":[],"check_error":true}'
        jq -cn --arg c "$c" --arg arm "$arm" --argjson r "$r" --argjson rc "$rc" --argjson a "$agent_json" \
          --argjson k "$checks" --arg diff "$diff" --arg ws "$( ((KEEP)) && printf '%s' "$ws")" --argjson budget "$RUN_BUDGET" '
          ($k.checks) as $ch
          | {case: $c, arm: $arm, run: $r, exit_code: $rc,
             error: (if $rc != 0 then "agent exit \($rc)" elif ($a.is_error // false) then ($a.subtype // "error")
                     elif ($k.check_error // false) then "check failed" else null end),
             turns: ($a.num_turns // null),
             # 비용을 모르는 실행(타임아웃 등)은 실행당 예산만큼 쓴 것으로 센다 — 상한이 무력해지지 않게.
             cost_usd: ($a.total_cost_usd // $budget), cost_known: ($a.total_cost_usd != null),
             duration_s: (if $a.duration_ms then ($a.duration_ms / 1000 | round) else null end),
             tokens: {in: ($a.usage.input_tokens // null), out: ($a.usage.output_tokens // null),
                      cache_read: ($a.usage.cache_read_input_tokens // null)},
             checks: $ch,
             score: (if ($ch | length) == 0 then 0 else (($ch | map(select(.pass)) | length) / ($ch | length) * 100 | round) / 100 end),
             diff: $diff, workspace: (if $ws == "" then null else $ws end)}' >>"$rec"
        spent="$(jq -sr 'map(.cost_usd) | add // 0' "$rec")"
        ((KEEP)) || find "$ws" -depth -delete 2>/dev/null || true
      done
    done
  done
  jq -s --arg model "${MODEL:-default}" --argjson runs "$RUNS" --argjson partial "$partial" --argjson max "$MAX_COST" \
    --arg agent "$([[ -n "${HM_AB_AGENT_CMD:-}" ]] && printf stub || printf claude)" '
    def mean: if length == 0 then null else (add / length * 100 | round) / 100 end;
    def kind_score($kinds): map(select(.error == null) | [.checks[] | select(.kind as $k | $kinds | index($k))]
      | select(length > 0) | (map(select(.pass)) | length) / length) | mean;
    def arm_summary: {
      runs: .,
      scored_runs: (map(select(.error == null)) | length),
      # 오류 난 실행(예산 초과·타임아웃·채점 실패)은 점수 평균에서 뺀다 — 한쪽에 오류가 몰려 효과처럼 보이지 않게.
      mean_score: (map(select(.error == null) | .score) | mean),
      score_by_kind: {basic: kind_score(["correct"]), project_rule: kind_score(["project_rule"]),
                      convention: kind_score(["convention"]), process: kind_score(["process"])},
      full_pass_runs: (map(select(.error == null and (.checks | length) > 0 and all(.checks[]; .pass))) | length),
      mean_turns: (map(.turns | numbers) | mean),
      mean_cost_usd: (map(.cost_usd) | mean),
      errors: (map(select(.error != null)) | length),
      checks: ((map(.checks | map(.name)) | add // [] | reduce .[] as $n ([]; if index([$n]) then . else . + [$n] end)) as $order
        | map(.checks[]) | group_by(.name)
        | map({name: .[0].name, kind: .[0].kind, passed: (map(select(.pass)) | length), total: length})
        | sort_by(.name as $n | $order | index([$n])))
    };
    {v: 1, generated_at: (now | todate), agent: $agent, model: $model, runs_per_arm: $runs,
     partial: $partial, max_cost_usd: $max, total_cost_usd: ((map(.cost_usd) | add // 0) * 10000 | round / 10000),
     arms: {harness: "프로젝트 하네스(AGENTS.md·CLAUDE.md·.ai-harness/docs)가 있는 저장소", bare: "같은 코드, 하네스 파일 없음"},
     cases: (group_by(.case) | map({name: .[0].case,
       arms: {harness: (map(select(.arm == "harness")) | arm_summary), bare: (map(select(.arm == "bare")) | arm_summary)}}))}' \
    "$rec" >"$OUT"
  printf '%s\n' "$OUT"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  run) command_run "$@" ;;
  estimate) command_estimate "$@" ;;
  *) usage ;;
esac
