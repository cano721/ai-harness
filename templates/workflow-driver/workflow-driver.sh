#!/usr/bin/env bash
# 프로젝트 워크플로 그래프(feature-delivery·bug-fix·review)를 실행하는 그래프 러너. 모델이 아니라 이 스크립트가 전이를 정한다.
#   - 워크플로: --workflow feature|bug-fix|review(기본 feature)가 실행할 그래프를 고른다. resume·status는 실행 상태의 워크플로를 따른다.
#   - 노드: 그래프의 nodes. write:false 노드는 읽기 전용 세션(Codex sandbox read-only, Claude는 읽기 도구만)으로 띄우고
#     세션 전후 작업 트리 지문이 다르면 멈춘다. 명령을 실행해야 하는 읽기 노드(commands·network·browser)도 같은 지문 비교로 쓰기를 막는다.
#     actor:human 노드에서는 실행을 멈추고(interrupt) 사람을 기다린다.
#   - 엣지: 노드가 낸 결과(outcome)와 같은 when을 가진 전이만 따른다. 그래프에 없는 전이는 불변식 위반이다.
#   - 상태: 노드마다 state.json에 체크포인트를 남겨 resume이 멈춘 노드부터 이어 간다.
#   - 승인: 사용자가 대화에 직접 입력한 "승인"(Claude·Codex 트랜스크립트의 사용자 메시지) 또는 터미널의 approve.
#     모델이 쓰는 도구 출력·자기 메시지는 사용자 메시지가 아니므로 승인이 되지 않는다.
#     .ai-harness/harness.json의 approval이 auto면 Brief가 열린 질문 대신 decisions(추천안과 근거)를 내고, 사람만 정할 수 있는 것
#     (needs_human)이 비어 있을 때 그래프의 auto_approved_by_policy 엣지로 통과한다. decisions는 brief.md와 PR 본문에 남는다.
#     review 그래프에는 승인 노드가 없다. blocking finding을 고치는 repair는 같은 승인(또는 approval: auto)을 받은 뒤에만 시작한다.
#   - 검증: Brief(review는 수리 범위)에 담겨 함께 승인된 검증 명령을 이 스크립트가 직접 실행해 종료 코드로 판정한다.
#   - git: harness.json의 git_policy가 pr-only·direct·merge면 쓰기 노드 뒤 로컬 체크포인트 커밋을 남기고, publish 노드가
#     커밋·일반 push·PR을 맡는다. 그 밖의 값이면 커밋하지 않는다. review는 publish 노드가 없어 수리를 커밋하지 않고 남긴다.
#     publish 밖에서 이 스크립트가 아닌 누군가 HEAD를 움직이면 멈춘다.
#   - 원격 CI: push했으면 remote_ci 노드가 그 커밋의 원격 CI가 끝날 때까지 본다. 실패는 repair로 돌아가 다시 push하고,
#     볼 수단이 없으면 done이 아니라 사람에게 미확인으로 넘긴다. 로컬에서 같은 명령이 통과해도 원격 CI를 대신하지 못한다.
#   - 병합: git_policy가 merge면 원격 CI 뒤 merge 노드에서 이 스크립트가 PR 호스트(gh·Bitbucket API)에서 직접 읽은 상태로
#     merge_policy.require 조건(사람 승인·원격 CI·충돌 없음·draft 아님)을 판정하고, 모두 맞을 때만 head를 고정해 병합한다.
#     조건이 아직 안 맞으면 exit 30으로 멈추고 resume이 다시 본다. 무인 실행(HM_INTERNAL_SESSION=1)은 병합하지 않는다.
#     병합 뒤 post_merge_verify가 merge_policy.verify(타깃 CI·배포 확인 명령·스모크 명령)를 확인한다. 실패는 되돌리지 않고 사람에게 넘긴다.
#   - 화면 검증: 화면 시나리오(ui_scenarios)가 있으면 리뷰 뒤 ui_review 노드가 ui-review 계약대로 화면을 실제로 렌더링·조작한다.
#     캡처는 실행 디렉터리의 ui-review-<시도>/에 남는다. 주요 문제는 repair로 돌아가 다시 리뷰·ui_review를 거치고,
#     검증하지 못하면 done이 아니라 사람에게 미검증으로 넘긴다.
# shellcheck disable=SC2016  # state_set·jq 인자의 $x는 셸이 아니라 jq 변수다
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: workflow-driver.sh <command> [--workflow feature|bug-fix|review] [options]

  start   --request "<요청>" | --request-file <file>   계획 노드를 실행하고 승인 대기에서 멈춘다
          [--check "<검증 명령>"]...                    Brief(review는 수리 범위)가 제안한 검증에 더할 명령
  revise  --feedback "<바꿀 점>"                         승인 대기 중인 Brief를 피드백으로 다시 만든다
  resume                                                승인을 확인하고 멈춘 노드부터 이어 간다
  approve                                               터미널에서 사람이 Brief(review는 수리 범위)를 보고 승인한 뒤 이어 간다
  status                                                현재 노드·이력·다음 행동을 보인다
  watch                                                 실행의 노드 전환·도구 호출을 따라 본다. 호출 때의 최근 실행을 계속 보고, 끝나도 대기한다 (Ctrl+C)

  워크플로: feature(기능 개발, 기본) · bug-fix(버그 수정) · review(변경 검토). start의 --request는 각각 기능 요청·버그 보고·검토 대상(PR, 브랜치, diff)이다.
  공통: [--run <id>] (기본: 이 저장소의 최근 실행, --workflow가 있으면 그 워크플로의 최근 실행) [--repo <dir>] [--runtime codex|claude]

  정책: .ai-harness/harness.json의 approval(human|auto, 기본 human)과 git_policy(pr-only|direct|merge|그 밖), merge_policy를 start 때 읽는다.

exit: 0 done(push했으면 원격 CI 통과까지, merge면 병합 후 검증까지) · 10 승인 대기 · 20 사람 판단 필요(원격 CI·화면 미검증, 병합 막힘·병합 후 검증 실패 포함) · 30 미완료(원격 CI 진행 중·병합 조건 대기·배포 미관측이면 resume) · 40 불변식 위반 · 2 사용법
EOF
  exit 2
}

CMD="${1:-}"
[[ -n "$CMD" ]] || usage
shift
REPO="."
RUN_ID=""
RUNTIME=""
REQUEST=""
FEEDBACK=""
WORKFLOW=""
CLI_CHECKS=()
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || usage; REPO="$2"; shift 2 ;;
    --run) [[ $# -ge 2 ]] || usage; RUN_ID="$2"; shift 2 ;;
    --runtime) [[ $# -ge 2 ]] || usage; RUNTIME="$2"; shift 2 ;;
    --workflow) [[ $# -ge 2 ]] || usage; WORKFLOW="$2"; shift 2 ;;
    --request) [[ $# -ge 2 ]] || usage; REQUEST="$2"; shift 2 ;;
    --request-file) [[ $# -ge 2 && -f "$2" ]] || usage; REQUEST="$(<"$2")"; shift 2 ;;
    --feedback) [[ $# -ge 2 ]] || usage; FEEDBACK="$2"; shift 2 ;;
    --check) [[ $# -ge 2 ]] || usage; CLI_CHECKS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage ;;
  esac
done
case "$WORKFLOW" in
  ""|feature|implement-feature) WORKFLOW="${WORKFLOW:+feature}" ;;
  bug-fix|fix-bug) WORKFLOW=bug-fix ;;
  review) ;;
  *) printf 'unknown workflow: %s\n' "$WORKFLOW" >&2; usage ;;
esac

command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 2; }
REPO="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || { printf 'not a git repository: %s\n' "$REPO" >&2; exit 2; }

# 실행 상태는 저장소 밖에 둔다. 저장소 안에 쓰면 읽기 전용 노드의 지문 비교가 무의미해진다.
RUNS_DIR="${HM_FEATURE_RUNS_DIR:-$HOME/.ai-harness/runs}/$(basename "$REPO")-$(printf '%s' "$REPO" | git hash-object --stdin | cut -c1-8)"
# 프롬프트·세션 로그에 코드가 담긴다. 실행 디렉토리는 본인만 읽는다.
mkdir -p "$RUNS_DIR"
chmod 700 "$RUNS_DIR" 2>/dev/null || true
# latest는 워크플로와 무관한 최근 실행, latest-<워크플로>는 그 워크플로의 최근 실행이다. --workflow 없는 resume은 latest를 잇는다.
latest_file() { # [workflow]
  if [[ -z "${1:-}" ]]; then printf '%s/latest' "$RUNS_DIR"; else printf '%s/latest-%s' "$RUNS_DIR" "$1"; fi
}

# 진행 줄은 stderr와 $RUN/progress.log에 함께 남긴다. watch와 백그라운드 실행의 모니터가 이 파일을 따라 읽는다.
log() {
  printf '[%s] %s\n' "${TEMPLATE:-workflow-driver}" "$*" >&2
  [[ -n "${RUN:-}" && -d "$RUN" ]] && printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$RUN/progress.log"
  return 0
}

if [[ "$CMD" == start ]]; then
  [[ -n "$REQUEST" ]] || usage
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
elif [[ -z "$RUN_ID" ]]; then
  latest="$(latest_file "$WORKFLOW")"
  if [[ -f "$latest" ]]; then
    RUN_ID="$(<"$latest")"
  elif [[ "$WORKFLOW" == feature ]]; then
    # 이 구분 전의 실행에는 latest-feature가 없다. 옛 latest가 feature 실행이면 그것을, 아니면 가장 최근의 feature 실행
    # (.workflow가 없으면 feature)을 잇는다 — 수정 시각만 보면 끝난 실행이 승인 대기 중인 실행을 가린다.
    if [[ -f "$RUNS_DIR/latest" ]] \
      && [[ "$(jq -r '.workflow // "feature"' "$RUNS_DIR/$(<"$RUNS_DIR/latest")/state.json" 2>/dev/null)" == feature ]]; then
      RUN_ID="$(<"$RUNS_DIR/latest")"
    fi
    [[ -n "$RUN_ID" ]] || while IFS= read -r f; do
      [[ "$(jq -r '.workflow // "feature"' "$f" 2>/dev/null)" == feature ]] || continue
      RUN_ID="$(basename "$(dirname "$f")")"
      break
    done < <(ls -t "$RUNS_DIR"/*/state.json 2>/dev/null)
  fi
  [[ -n "$RUN_ID" ]] \
    || { printf 'no %srun for %s; use start\n' "${WORKFLOW:+$WORKFLOW }" "$REPO" >&2; exit 2; }
fi
RUN="$RUNS_DIR/$RUN_ID"
STATE="$RUN/state.json"

state() { jq -r "$1" "$STATE"; }
state_set() { # jq-filter [jq args...]
  local filter="$1"
  shift
  jq "$@" "$filter" "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 이어 가는 실행은 그 실행의 워크플로를 따른다. 워크플로를 바꾸면 다른 그래프로 같은 상태를 해석하게 된다.
if [[ "$CMD" != start && -f "$STATE" ]]; then
  run_workflow="$(state '.workflow // "feature"')"
  [[ -z "$WORKFLOW" || "$WORKFLOW" == "$run_workflow" ]] \
    || { printf 'run %s is a %s run, not %s\n' "$RUN_ID" "$run_workflow" "$WORKFLOW" >&2; exit 2; }
  WORKFLOW="$run_workflow"
fi
WORKFLOW="${WORKFLOW:-feature}"
case "$WORKFLOW" in
  feature) GRAPH_NAME=feature-delivery-graph.json TEMPLATE=implement-feature BRIEF_TITLE="Implementation Brief" UI_UNVERIFIED="implementation done, UI unverified" ;;
  bug-fix) GRAPH_NAME=bug-fix-graph.json TEMPLATE=fix-bug BRIEF_TITLE="Bug Fix Brief" UI_UNVERIFIED="implementation done, UI unverified" ;;
  review) GRAPH_NAME=review-graph.json TEMPLATE=review BRIEF_TITLE="Repair scope" UI_UNVERIFIED="code review clean, UI unverified" ;;
esac

# 프로젝트 그래프가 계약이다. 없으면 이 스크립트 옆(설치본) 또는 저장소 템플릿 배치(templates/<워크플로>/references)의 원본을 쓴다.
GRAPH="$REPO/.ai-harness/workflows/$GRAPH_NAME"
[[ -f "$GRAPH" ]] || GRAPH="$SCRIPT_DIR/$GRAPH_NAME"
[[ -f "$GRAPH" ]] || GRAPH="$SCRIPT_DIR/../$TEMPLATE/references/$GRAPH_NAME"
jq -e '.entry and .nodes and .transitions and .terminals' "$GRAPH" >/dev/null 2>&1 || { printf 'invalid graph: %s\n' "$GRAPH" >&2; exit 2; }
MAX_REPAIR="$(jq -r '.limits.max_repair_attempts // 10' "$GRAPH")"

finish() { # status exit_code message
  state_set '.status = $s | .message = $m | .finished_at = $t' --arg s "$1" --arg m "$3" --arg t "$(now_utc)"
  log "$1: $3"
  log "run: $RUN_ID ($RUN)"
  exit "$2"
}

# 추적 파일 diff + 미추적 파일 내용까지 포함한 작업 트리 지문. .gitignore 대상(빌드 산출물)은 제외된다.
fingerprint() {
  {
    git -C "$REPO" rev-parse HEAD 2>/dev/null || true
    git -C "$REPO" diff HEAD --binary 2>/dev/null || true
    git -C "$REPO" ls-files --others --exclude-standard -z \
      | while IFS= read -r -d '' f; do printf '%s\0' "$f"; git -C "$REPO" hash-object -- "$f"; done
  } | git hash-object --stdin
}

guard_head() {
  local head
  head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf 'none')"
  [[ "$head" == "$(state '.head // .start_head')" ]] || finish invariant_violation 40 "HEAD moved during $1; only the driver's checkpoints and the publish node may commit"
}

# 화면을 그리는 파일(템플릿·스타일·컴포넌트)이 바뀌었는지. Brief가 화면 변경을 놓쳐도 화면 검증을 건너뛰지 않게 하는 결정적 백스톱이다.
# review는 검토 대상의 기준(diff_base)부터, 나머지는 실행 시작 커밋부터 본다.
ui_files_changed() {
  { git -C "$REPO" diff --name-only "$(state '.diff_base // .start_head')"; git -C "$REPO" ls-files --others --exclude-standard; } \
    | grep -E '\.(html?|jinja2?|j2|jsp|erb|haml|hbs|mustache|njk|twig|ftl|ejs|pug|cshtml|razor|blade\.php|vue|svelte|astro|tsx|jsx|svg|css|scss|sass|less)$' \
    | grep -vE '(^|/)(__tests__|tests?|spec)/|\.(test|spec)\.' | sort -u || true
}

has_edge() { # from outcome
  jq -e --arg f "$1" --arg o "$2" 'any(.transitions[]; .from == $f and (.when // "") == $o)' "$GRAPH" >/dev/null
}

edge_when() { # from to → 그 전이의 when. 결과 이름은 그래프마다 다르므로(ui_issues, ui_issues_and_repair_authorized 등) 목적지로 찾는다.
  jq -r --arg f "$1" --arg t "$2" 'first(.transitions[] | select(.from == $f and .to == $t) | .when // "") // empty' "$GRAPH"
}

# 작업 트리 전체(미추적 포함, .gitignore 제외)를 트리 객체로. 리뷰한 내용과 publish가 커밋한 내용을 비교한다.
worktree_tree() {
  local idx="$RUN/tree.index"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$REPO" read-tree HEAD 2>/dev/null || true
  GIT_INDEX_FILE="$idx" git -C "$REPO" add -A
  GIT_INDEX_FILE="$idx" git -C "$REPO" write-tree
  rm -f "$idx"
}

# git_policy가 커밋을 허용하면 쓰기 노드 뒤 로컬 커밋을 남긴다. worktree가 사라져도 사이클 단위로 남는다. push는 하지 않는다.
checkpoint() { # node
  [[ "$(state '.policy.commits // false')" == true ]] || return 0
  [[ -n "$(git -C "$REPO" status --porcelain --untracked-files=all)" ]] || return 0
  { git -C "$REPO" add -A && git -C "$REPO" commit -q -m "wip($TEMPLATE): $1 · run $RUN_ID"; } >"$RUN/checkpoint.log" 2>&1 \
    || finish incomplete 30 "checkpoint commit after $1 failed; see $RUN/checkpoint.log. Fix the cause and run resume"
  state_set '.head = $h | .checkpoints += [$h]' --arg h "$(git -C "$REPO" rev-parse HEAD)"
  log "checkpoint commit after $1: $(git -C "$REPO" rev-parse --short HEAD)"
}

go() { # from outcome → 그래프에 선언된 전이만 따른다
  local from="$1" outcome="$2" to
  to="$(jq -r --arg f "$from" --arg o "$outcome" \
    'first(.transitions[] | select(.from == $f and ((.when // "") == $o)) | .to) // empty' "$GRAPH")"
  [[ -n "$to" ]] || finish invariant_violation 40 "graph declares no transition from '$from' on '${outcome:-<always>}'"
  # 어떤 전이든 수리 동의 대기를 끝낸다. 같은 노드를 다시 지날 때(re_review) 남은 대기가 노드 실행을 건너뛰게 하지 않는다.
  state_set '.node = $to | .awaiting = null | .history += [{from:$f, outcome:$o, to:$to, at:$t}]' \
    --arg to "$to" --arg f "$from" --arg o "$outcome" --arg t "$(now_utc)"
  log "$from --${outcome:-next}--> $to"
}

# claude stream-json 이벤트에서 도구 호출 한 줄과 최종 result만 남긴다. 원본은 파일 내용이 담긴 도구 입출력이라 디스크에 쓰지 않는다.
# Bash는 명령 대신 description(없으면 앞의 VAR=값을 건너뛴 실행어 이름)만 보인다. 명령 인자·환경 대입에 토큰이 들어갈 수 있다.
# Write·Edit 본문, Agent 프롬프트는 보이지 않는다. Grep·Glob은 검색어를 60자까지 보인다.
stream_progress() { # label → stdout: result 이벤트 한 줄
  local label="$1" kind line
  jq --unbuffered -rR --arg repo "$REPO/" 'fromjson? |
    if .type == "assistant" then
      .message.content[]? | select(.type == "tool_use") | .input as $in
      | "P\t" + .name + (
          if .name == "Bash" then ": " + ($in.description // ($in.command // "" | [scan("\\S+")]
            | map(select(test("^[A-Za-z_][A-Za-z0-9_]*=") | not)) | .[0] // "" | split("/") | last))
          elif .name == "Grep" or .name == "Glob" then
            " " + ($in.pattern // "" | tostring | .[:60]) + (($in.path // "" | tostring | ltrimstr($repo)) as $p | if $p == "" then "" else " in " + $p end)
          else ($in.file_path // $in.path // $in.description // "" | tostring | ltrimstr($repo)) as $a
            | if $a == "" then "" else " " + $a end
          end | gsub("[\t\n]"; " ") | .[:160])
    elif .type == "result" then "R\t" + tojson
    else empty end' |
  while IFS=$'\t' read -r kind line; do
    case "$kind" in
      P) log "$label · $line" ;;
      R) printf '%s\n' "$line" ;;
    esac
  done
}
# run_agent <node> <label> <prompt> [schema] → $RUN/<label>.out. 쓰기 권한은 그래프의 nodes.<node>.write가 정한다.
run_agent() {
  local node="$1" label="$2" prompt="$3" schema="${4:-}" rc=0 writable
  local out="$RUN/$label.out" network browser commands
  writable="$(jq -r --arg n "$node" '.nodes[$n].write' "$GRAPH")"
  # 화면 검증(browser)은 앱 서버를 띄우고 브라우저를 조종해야 하므로 네트워크 노드처럼 명령과 로컬 네트워크를 연다.
  # 재현(commands)은 테스트·명령을 실행해야 하므로 명령만 연다. 둘 다 쓰기는 지문 비교가 막는다.
  browser="$(jq -r --arg n "$node" '.nodes[$n].browser // false' "$GRAPH")"
  network="$(jq -r --arg n "$node" '.nodes[$n].network // .nodes[$n].browser // false' "$GRAPH")"
  commands="$(jq -r --arg n "$node" '.nodes[$n].commands // .nodes[$n].network // .nodes[$n].browser // false' "$GRAPH")"
  # 같은 label을 다시 쓰는 노드(publish 재실행·resume)가 이전 결과를 이번 결과로 읽지 않게 한다.
  rm -f "$out"
  printf '%s\n' "$prompt" >"$RUN/$label.prompt"
  # 명령을 실행하는 읽기 노드의 산출물(캡처·로그·임시 스크립트)은 저장소가 아니라 이 노드의 증거 디렉터리에 남긴다.
  [[ "$writable" != true && "$commands" == true && "$network" != true || "$browser" == true ]] && mkdir -p "$RUN/$label"
  log "$label ($([[ "$writable" == true ]] && echo write || echo read-only), $(state .runtime))"
  case "$(state .runtime)" in
    codex)
      # read-only sandbox는 명령의 쓰기·네트워크를 열 수 없다. 명령을 실행하는 읽기 노드는 workspace-write로 띄우고 run_node의 지문 비교로 쓰기를 막는다.
      local args=(exec -C "$REPO" -s "$([[ "$writable" == true || "$commands" == true ]] && echo workspace-write || echo read-only)" -o "$out")
      [[ -n "$schema" ]] && args+=(--output-schema "$schema")
      # push·PR·원격 CI 노드는 네트워크가 필요하다. workspace-write sandbox는 기본으로 네트워크를 막는다.
      [[ "$network" == true ]] && args+=(-c sandbox_workspace_write.network_access=true)
      [[ -d "$RUN/$label" ]] && args+=(--add-dir "$RUN/$label")
      # codex 출력은 원본(명령 출력·파일 내용)이다. 사람이 보는 터미널일 때만 함께 흘리고, 에이전트가 받는 stderr에는 넣지 않는다.
      if [[ -t 2 ]]; then
        codex "${args[@]}" - <"$RUN/$label.prompt" 2>&1 | tee "$RUN/$label.log" >&2 || rc=$?
      else
        codex "${args[@]}" - <"$RUN/$label.prompt" >"$RUN/$label.log" 2>&1 || rc=$?
      fi
      ;;
    claude)
      # --tools는 내장 도구만 제한한다. MCP 도구(IDE 파일 편집 등)는 --strict-mcp-config로 함께 끈다.
      # 쓰기 노드는 Agent로 프로젝트 페르소나에 위임할 수 있다.
      local args=(-p --strict-mcp-config --output-format stream-json --verbose)
      if [[ "$writable" == true ]]; then
        args+=(--tools "Read,Grep,Glob,Edit,Write,Bash,Agent" --permission-mode acceptEdits --allowedTools "Bash")
      elif [[ "$commands" == true ]]; then
        # 재현·원격 CI 조회·화면 검증은 명령이 필요하다. 작업 트리를 바꾸면 run_node의 지문 비교가 멈춘다.
        args+=(--tools "Read,Grep,Glob,Bash" --permission-mode dontAsk --allowedTools "Bash")
      else
        args+=(--tools "Read,Grep,Glob" --permission-mode dontAsk)
      fi
      [[ -n "$schema" ]] && args+=(--json-schema "$(<"$schema")")
      [[ -d "$RUN/$label" ]] && args+=(--add-dir "$RUN/$label")
      (cd "$REPO" && claude "${args[@]}" <"$RUN/$label.prompt") 2>"$RUN/$label.log" | stream_progress "$label" >"$RUN/$label.json" || rc=$?
      if ((rc == 0)); then
        jq -r 'if .structured_output then (.structured_output | tojson) else (.result // empty) end' \
          "$RUN/$label.json" >"$out" 2>/dev/null || rc=1
      fi
      ;;
  esac
  ((rc == 0)) && [[ -s "$out" ]] || finish incomplete 30 "$label session failed (exit $rc); see $RUN/$label.log. Fix the cause and run resume"
}

run_node() { # node label prompt [schema]: 읽기 전용 노드는 지문으로, 쓰기 노드는 승인으로 지킨다
  local node="$1" before writable
  writable="$(jq -r --arg n "$node" '.nodes[$n].write' "$GRAPH")"
  if [[ "$writable" == true ]]; then
    [[ "$(state '.approval.brief_hash // ""')" == "$(state .brief_hash)" ]] \
      || finish invariant_violation 40 "write node '$node' reached without approval of the current brief"
    run_agent "$@"
  else
    before="$(fingerprint)"
    run_agent "$@"
    [[ "$(fingerprint)" == "$before" ]] \
      || finish invariant_violation 40 "read-only node '$node' changed the working tree: $(git -C "$REPO" status --porcelain | head -n 10 | paste -sd ';' -). Remove those changes before starting again"
  fi
  guard_head "$node"
}

run_checks() { # label → $RUN/<label>.checks.json, 하나라도 실패하면 1
  local label="$1" i=0 failed=0 cmd rc results="[]"
  while IFS= read -r cmd; do
    i=$((i + 1))
    rc=0
    (cd "$REPO" && bash -c "$cmd") >"$RUN/$label.check$i.log" 2>&1 </dev/null || rc=$?
    results="$(jq --arg cmd "$cmd" --argjson rc "$rc" --arg tail "$(tail -n 40 "$RUN/$label.check$i.log")" \
      '. + [{command:$cmd, exit:$rc, tail:$tail}]' <<<"$results")"
    if ((rc != 0)); then failed=1; log "check failed: $cmd (exit $rc)"; else log "check passed: $cmd"; fi
  done < <(state '.checks[]')
  printf '%s\n' "$results" >"$RUN/$label.checks.json"
  return "$failed"
}

check_findings() {
  jq -c '[.[] | select(.exit != 0) | "required check failed: \(.command) (exit \(.exit))\n\(.tail)"]' "$RUN/$1.checks.json"
}

# 리뷰·수리·화면 검증 노드가 받는 기준 문서. review는 승인된 Brief 대신 검토 범위다.
brief_context() {
  if [[ "$WORKFLOW" == review ]]; then
    printf 'Review scope:\n%s' "$(<"$RUN/scope.md")"
  else
    printf 'Approved %s:\n%s' "$BRIEF_TITLE" "$(<"$RUN/brief.md")"
  fi
}

print_brief() {
  printf '== %s · run %s ==\n\n' "$BRIEF_TITLE" "$RUN_ID"
  cat "$RUN/brief.md"
  printf '\n== 드라이버가 직접 실행할 검증 ==\n'
  state '.checks[] | "- " + .'
  jq -r 'if (.open_questions // [] | length) > 0 then "\n== 확인이 필요한 점 ==\n" + (.open_questions | map("- " + .) | join("\n")) else empty end' "$RUN/brief.json"
  jq -r 'if (.needs_human // [] | length) > 0 then "\n== 사람이 정할 점 ==\n" + (.needs_human | map("- " + .) | join("\n")) else empty end' "$RUN/brief.json"
  if [[ "${1:-}" == auto ]]; then
    if [[ "$WORKFLOW" == review ]]; then
      printf '\n== 정책 승인 (approval: auto) ==\n수리 범위는 %s에 남는다. 수리는 커밋하지 않고 작업 트리에 남긴다.\n' "$RUN/brief.md"
    # direct는 PR 없이 push까지 가므로 "병합 전에 뒤집는다"가 성립하지 않는다.
    elif [[ "$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)" == direct ]]; then
      printf '\n== 정책 승인 (approval: auto) ==\nBrief와 결정 사항은 %s와 마지막 커밋 메시지에 남는다. git_policy direct라 PR 없이 push되므로, 결정을 뒤집으려면 이후 커밋으로 되돌린다.\n' "$RUN/brief.md"
    else
      printf '\n== 정책 승인 (approval: auto) ==\nBrief와 결정 사항은 %s에 남고 PR 본문에 들어간다. 사람은 병합 전에 PR에서 결정을 뒤집을 수 있다.\n' "$RUN/brief.md"
    fi
    return
  fi
  if [[ "$WORKFLOW" == review ]]; then
    cat <<EOF

== 다음 ==
수리: 대화에 "승인"이라고 입력한 뒤 resume (터미널이면 approve). 위 finding을 고치고 검증·재검토까지 이어 간다
수리하지 않으면 여기서 끝난다: 위 finding이 검토 결과다
EOF
    return
  fi
  cat <<EOF

== 다음 ==
승인: 대화에 "승인"이라고 입력한 뒤 resume (터미널이면 approve)
수정: 바꿀 점을 말하면 revise --feedback "<바꿀 점>"으로 Brief를 다시 만든다
EOF
}

# 사용자가 직접 입력한 메시지만 본다: Claude는 type=user의 문자열 content(isMeta 제외), Codex는 event_msg user_message.
# 도구 결과·모델 메시지·드라이버가 띄운 세션의 프롬프트는 "승인"으로 시작하지 않으므로 걸리지 않는다.
transcript_approval() {
  local since="$1" marker="$RUN/brief.json" f cwd
  local re='^[[:space:]]*(승인|approve|approved)([[:space:][:punct:]]|$)'
  local claude_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" codex_root="${CODEX_HOME:-$HOME/.codex}/sessions"
  if [[ -d "$claude_root" ]]; then
    while IFS= read -r -d '' f; do
      jq -c --arg repo "$REPO" --arg since "$since" --arg re "$re" '
        select(.type == "user" and (.isMeta | not) and ((.message.content | type) == "string")
          and ((.cwd // "") as $c | $c == $repo or ($c | startswith($repo + "/")) or ("/private" + $c) == $repo)
          and ((.timestamp // "")[:19] > $since)
          and (.message.content | ascii_downcase | test($re)))
        | {source:"claude-transcript", at:.timestamp, text:(.message.content[:200])}' "$f" 2>/dev/null | head -n 1
    done < <(find "$claude_root" -name '*.jsonl' -newer "$marker" -print0 2>/dev/null)
  fi
  if [[ -d "$codex_root" ]]; then
    while IFS= read -r -d '' f; do
      cwd="$(jq -r 'select(.type == "session_meta") | .payload.cwd // empty' "$f" 2>/dev/null | head -n 1)"
      [[ "$cwd" == "$REPO" || "$cwd" == "$REPO"/* || "/private$cwd" == "$REPO" ]] || continue
      jq -c --arg since "$since" --arg re "$re" '
        select(.type == "event_msg" and .payload.type == "user_message"
          and ((.timestamp // "")[:19] > $since)
          and (.payload.message | ascii_downcase | test($re)))
        | {source:"codex-transcript", at:.timestamp, text:(.payload.message[:200])}' "$f" 2>/dev/null | head -n 1
    done < <(find "$codex_root" -name '*.jsonl' -newer "$marker" -print0 2>/dev/null)
  fi
}

# verified의 캡처는 이름만 적은 것이 아니라 그 시도의 증거 디렉터리 안에 실제로 있어야 한다.
captures_present() { # ui-review-output evidence-dir
  local c n=0
  while IFS= read -r c; do
    [[ "$c" == /* ]] || c="$2/$c"
    case "$c" in "$2"/*) ;; *) return 1 ;; esac
    [[ "$c" != *..* && -s "$c" ]] || return 1
    n=$((n + 1))
  done <<<"$(jq -r '.scenarios[].captures[]' "$1")"
  [[ "$n" -gt 0 ]]
}

record_approval() { # evidence-json
  state_set '.approval = ($e + {brief_hash: .brief_hash, recorded_at: $t})' --argjson e "$1" --arg t "$(now_utc)"
  log "approved by $(jq -r .source <<<"$1")"
}

# review: 승인 노드가 없는 그래프에서 repair(쓰기)로 가기 전에 사람의 동의를 받는다. 동의는 보여 준 수리 범위(finding·검증 명령)에 묶인다.
# 다시 검토해 범위 밖의 새 finding이 나오면 그 finding을 보여 주고 다시 동의를 받는다. approval: auto면 정책이 동의한다.
# 기다리는 동안 노드와 갈 엣지를 상태에 남겨, resume이 같은 노드를 다시 실행하지 않고 이어 가게 한다.
repair_covered() { # 현재 finding이 동의받은 수리 범위 안인가
  [[ -f "$RUN/brief.json" && -n "$(state '.brief_hash // ""')" && "$(state '.approval.brief_hash // ""')" == "$(state '.brief_hash // ""')" ]] \
    && jq -e --slurpfile b "$RUN/brief.json" '(.findings - ($b[0].findings // [])) | length == 0' "$STATE" >/dev/null
}
await_repair() { # node edge
  local node="$1" edge="$2" evidence
  if ! repair_covered; then
    if [[ "$(state '.awaiting.node // ""')" != "$node" ]] \
      || ! jq -e --slurpfile b "$RUN/brief.json" '(.findings - ($b[0].findings // [])) | length == 0' "$STATE" >/dev/null 2>&1; then
      [[ "$(state '.checks | length')" -gt 0 ]] \
        || finish incomplete 30 "blocking findings need repair, but there is no verification command to run after it; start again with --check"
      state_set '.awaiting = {node: $n, edge: $e}' --arg n "$node" --arg e "$edge"
      state '{findings, checks}' >"$RUN/brief.json"
      state '"## 수리할 blocking finding\n\n" + (.findings | map("- " + (split("\n") | first)) | join("\n"))' >"$RUN/brief.md"
      state_set '.presented_at = $t | .brief_hash = $h' --arg t "$(now_utc)" \
        --arg h "$({ cat "$RUN/brief.md"; state '.checks[]'; } | git hash-object --stdin)"
    fi
    if [[ "$(state '.policy.approval // "human"')" == auto ]]; then
      print_brief auto >&2
      record_approval "$(jq -n --arg t "$(now_utc)" --arg b "$RUN/brief.md" '{source:"auto-policy", at:$t, brief:$b}')"
    else
      evidence="$(transcript_approval "$(state .presented_at | cut -c1-19)" | head -n 1)"
      [[ -n "$evidence" ]] && record_approval "$evidence"
    fi
  fi
  if repair_covered; then
    go "$node" "$edge"
  else
    state_set '.status = "waiting_approval"'
    print_brief
    log "waiting for approval to repair: run $RUN_ID"
    exit 10
  fi
}

# Brief가 화면 시나리오를 놓쳤는데 화면 파일이 바뀌었으면 파일마다 시나리오를 넣는다.
ui_backstop() {
  local ui_files
  [[ "$(state '.findings | length')" -eq 0 && "$(state '.ui_scenarios // [] | length')" -eq 0 ]] || return 0
  ui_files="$(ui_files_changed)"
  [[ -n "$ui_files" ]] || return 0
  log "no UI scenarios were listed, but screen files changed; verifying them anyway"
  state_set '.ui_scenarios = ($f | split("\n") | map(select(length > 0)
    | "Screen rendered by \(.): open the page that uses it; derive the user role, entry -> key action -> success check -> return, and the states from the brief or review scope"))' --arg f "$ui_files"
}

# 리뷰 노드(review·classify·re_review)의 출구. findings·needs_user_decision·ui_scenarios는 상태에 있다.
route_review() { # node
  local node="$1"
  ui_backstop
  if [[ "$(state '.findings | length')" -gt 0 ]]; then
    case "$node" in
      classify)
        if [[ "$(state '.needs_user_decision // false')" == true ]]; then
          go classify "$(edge_when classify user_decision)"
        else
          await_repair classify "$(edge_when classify repair)"
        fi
        ;;
      re_review)
        if [[ "$(state '.needs_user_decision // false')" == true || "$(state .attempts)" -ge "$MAX_REPAIR" ]]; then
          go re_review "$(edge_when re_review user_decision)"
        else
          await_repair re_review "$(edge_when re_review repair)"
        fi
        ;;
      *) go "$node" "$(edge_when "$node" repair)" ;;
    esac
  elif [[ "$(state '.ui_scenarios // [] | length')" -gt 0 ]]; then
    # 화면 검증 노드가 없는 그래프(동기화 전)로는 화면을 검증할 수 없다. 코드가 끝났어도 done이 아니다.
    if ! has_edge "$node" no_blocking_findings_ui_affected; then
      local legacy="$UI_UNVERIFIED: the project graph has no ui_review node, so the screens were not verified; nothing was published. Sync the harness (/harness-init --sync), then start a new run or verify the screens and publish by hand"
      jq -n --arg m "$legacy" '[$m]' >"$RUN/unresolved.json"
      state_set '.node = "user_decision"'
      finish user_decision 20 "$legacy"
    fi
    go "$node" no_blocking_findings_ui_affected
  else
    state_set '.reviewed_tree = $t' --arg t "$(worktree_tree)"
    go "$node" no_blocking_findings
  fi
}

review_output() { # out-file → 상태의 findings·needs_user_decision(·ui_scenarios)
  jq -e '(.blocking_findings | type) == "array" and (.needs_user_decision | type) == "boolean"' "$1" >/dev/null 2>&1 \
    || finish incomplete 30 "review output does not match the schema; the change is not done ($1)"
  state_set '.findings = $r[0].blocking_findings | .needs_user_decision = $r[0].needs_user_decision
    | if ($r[0].ui_scenarios | type) == "array" then .ui_scenarios = ($r[0].ui_scenarios | map(select(length > 0))) else . end' --slurpfile r "$1"
}

# publish: git_policy가 허용할 때만 세션을 띄워 커밋·일반 push·PR을 맡기고, 결과를 이 스크립트가 git으로 확인한다.
publish() {
  local policy problems="[]" out pr_url
  policy="$(state '.policy.git // ""')"
  case "$policy" in
    pr-only|direct|merge) ;;
    *)
      state_set '.publish = {skipped: $m}' --arg m "git_policy '${policy:-unset}' does not allow the agent to commit; changes are left uncommitted"
      go publish published_or_not_required
      return
      ;;
  esac
  [[ "$(state '.approval.brief_hash // ""')" == "$(state .brief_hash)" ]] \
    || finish invariant_violation 40 "write node 'publish' reached without approval of the current brief"
  run_agent publish publish "$CONTEXT

You are the publish node. The approved change below passed the checks the driver ran and a review with no blocking findings. git_policy in .ai-harness/harness.json is \"$policy\". Deliver it without asking anyone anything:
- Use the git conventions, base branch, and PR tool that AGENTS.md and the project workflow name (for example /bitbucket or gh). Reviewers, labels, and similar settings come from the project's default rules.
- Commit any remaining change. The driver's unpushed checkpoint commits (wip($TEMPLATE): ...) may be squashed or reworded into the project's commit convention; never rewrite $(state .start_head) or anything before it.
- pr-only or merge: push the work branch with a normal push that sets its upstream, then open a pull request against the base branch. Put the approved brief and the checks below in the PR body. If a pull request for this branch is already open (a repair after remote CI failed), push to it and return its URL instead of opening another.
- direct: push the current branch with a normal push that sets its upstream; open a pull request only when the project workflow requires one.
- If the brief has a \"결정 사항\" section, the agent made those choices without asking a person. Copy it unchanged into a PR body section titled \"결정 사항\" so a person can overturn them before merging; when no PR is opened, put it in the body of the last commit message instead.
- Never merge (under merge the driver merges later, once the merge conditions hold), never force-push, never push to the base branch under pr-only or merge, and do not change file contents: the committed tree must equal the reviewed one.
Return only JSON matching the schema; pr_url is empty when no PR was opened.

Checks the driver ran: $(state '.checks | join(" ; ")')

$(brief_context)" "$PUBLISH_SCHEMA"
  out="$RUN/publish.out"
  jq -e '(.pr_url | type) == "string" and (.branch | type) == "string"' "$out" >/dev/null 2>&1 \
    || problems="$(jq -c '. + ["publish output does not match the schema"]' <<<"$problems")"
  pr_url="$(jq -r '.pr_url // ""' "$out" 2>/dev/null || true)"
  # 세션의 보고가 아니라 git 상태로 판정한다.
  [[ -z "$(git -C "$REPO" status --porcelain --untracked-files=all)" ]] \
    || problems="$(jq -c '. + ["uncommitted changes remain after publish"]' <<<"$problems")"
  [[ "$(worktree_tree)" == "$(state '.reviewed_tree // ""')" ]] \
    || problems="$(jq -c '. + ["the committed tree differs from the reviewed tree"]' <<<"$problems")"
  if [[ "$(state .start_head)" != none ]] && ! git -C "$REPO" merge-base --is-ancestor "$(state .start_head)" HEAD 2>/dev/null; then
    problems="$(jq -c '. + ["history before the run was rewritten"]' <<<"$problems")"
  fi
  [[ "$(git -C "$REPO" rev-parse '@{upstream}' 2>/dev/null || true)" == "$(git -C "$REPO" rev-parse HEAD)" ]] \
    || problems="$(jq -c '. + ["HEAD is not pushed to its upstream"]' <<<"$problems")"
  [[ "$policy" == direct || -n "$pr_url" ]] \
    || problems="$(jq -c --arg g "$policy" '. + ["git_policy \($g) requires a pull request, but pr_url is empty"]' <<<"$problems")"
  state_set '.head = $h | .publish = {pr_url: $u, branch: $b, problems: $p}' \
    --arg h "$(git -C "$REPO" rev-parse HEAD)" --arg u "$pr_url" \
    --arg b "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" --argjson p "$problems"
  if [[ "$problems" == "[]" ]]; then
    go publish published_or_not_required
  else
    state_set '.findings = $p' --argjson p "$problems"
    go publish publish_failed
  fi
}

# remote_ci: push한 커밋의 원격 CI가 끝날 때까지 본다. 로컬과 원격 환경(OS·DB·시각 정밀도)이 달라 로컬 통과가 원격 통과를 보장하지 않는다.
remote_ci() {
  local head branch pr_url label out status commit
  if [[ "$(state '.publish.skipped // ""')" != "" ]]; then
    state_set '.remote_ci = {status: "not_required", summary: "nothing was pushed"}'
    go remote_ci remote_ci_passed_or_not_required
    return
  fi
  head="$(git -C "$REPO" rev-parse HEAD)"
  branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  pr_url="$(state '.publish.pr_url // ""')"
  label="remote-ci-$(state .attempts)"
  run_node remote_ci "$label" "$CONTEXT

You are the remote_ci node. Do not edit any file, commit, or push. The publish node pushed commit $head on branch $branch${pr_url:+ (pull request $pr_url)}. Find out whether the remote CI for exactly that commit passed, without asking anyone anything:
- Use the PR or CI tool that AGENTS.md and the project workflow name (for example gh pr checks --watch, or the Bitbucket pipelines API through /bitbucket).
- Wait until every check or pipeline for the commit reaches a final state, polling about once a minute. A freshly pushed commit can take a few minutes before its checks appear.
- passed: every check finished successfully. failed: any check failed; put each failing check in failures with the decisive lines of its log, enough to repair it without rerunning CI. none: the repository defines no remote CI (no CI configuration in the repository and no checks reported after waiting). pending: checks are still running after about 60 minutes. unverified: you cannot read the CI result (no tool, no access); say why in summary.
- A local run of the CI commands is not a remote result. Never report passed from it.
Return only JSON matching the schema; commit is the SHA the result belongs to." "$REMOTE_CI_SCHEMA"
  out="$RUN/$label.out"
  jq -e '(.status | IN("passed", "failed", "none", "pending", "unverified")) and (.commit | type) == "string"
    and (.summary | type) == "string" and (.failures | type) == "array"' "$out" >/dev/null 2>&1 \
    || finish incomplete 30 "remote CI output does not match the schema ($out); run resume to check again"
  # 읽기 노드지만 네트워크·Bash가 있다. push한 브랜치가 원격에서 움직였으면(push·force push) 멈춘다.
  [[ "$(git -C "$REPO" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)" == "$head" ]] \
    || finish invariant_violation 40 "remote branch $branch moved during remote_ci; the node may only read CI"
  status="$(jq -r .status "$out")"
  commit="$(jq -r .commit "$out")"
  unverified_because() { # reason
    jq --arg r "$1" '.status = "unverified" | .summary = $r' "$out" >"$out.tmp" && mv "$out.tmp" "$out"
    status=unverified
  }
  # 세션의 보고가 push한 커밋의 것인지 확인한다. 이전 push의 결과는 이 커밋의 결과가 아니다.
  if [[ "$status" == passed || "$status" == failed || "$status" == none ]] && [[ ${#commit} -lt 7 || "$head" != "$commit"* ]]; then
    unverified_because "the CI result is for ${commit:-no commit}, not the pushed commit $head"
  fi
  # "원격 CI 없음"은 저장소에 CI 설정이 없을 때만 믿는다. 설정이 있는데 체크가 안 보이면 아직 등록 전이거나 볼 수단이 없는 것이다.
  if [[ "$status" == none && -n "$(git -C "$REPO" ls-files -- .github/workflows bitbucket-pipelines.yml .gitlab-ci.yml \
    Jenkinsfile .circleci azure-pipelines.yml .buildkite .drone.yml .travis.yml 2>/dev/null)" ]]; then
    unverified_because "the session reported no remote CI, but the repository has CI configuration"
  fi
  state_set '.remote_ci = ($r[0] + {head: $h, pr_url: $u, at: $t})' --slurpfile r "$out" --arg h "$head" --arg u "$pr_url" --arg t "$(now_utc)"
  case "$status" in
    passed|none)
      if [[ "$(state '.policy.git')" == merge && -n "$pr_url" ]]; then
        if [[ "$(state '.policy.unattended // false')" == true ]]; then
          state_set '.merge = {skipped: "unattended run; merging is left to a person"}'
        elif [[ -n "$(edge_when remote_ci merge)" ]]; then
          go remote_ci "$(edge_when remote_ci merge)"
          return
        else
          state_set '.merge = {skipped: "the project graph has no merge node; sync the harness (/harness-init --sync)"}'
        fi
      fi
      go remote_ci remote_ci_passed_or_not_required
      ;;
    failed)
      state_set '.findings = (.remote_ci | if (.failures | length) > 0 then .failures else [.summary] end | map("remote CI failed: " + .))
        | .needs_user_decision = false'
      go remote_ci remote_ci_failed
      ;;
    pending) finish incomplete 30 "remote CI for $head is still running${pr_url:+ ($pr_url)}; run resume to check again" ;;
    *)
      state_set '.findings = ["remote CI unverified: " + .remote_ci.summary]'
      go remote_ci remote_ci_unverified
      ;;
  esac
}

# PR 호스트에서 PR 상태를 직접 읽는다. 병합 조건은 모델의 보고가 아니라 이 결과로 판정한다.
# 출력: {state: OPEN|MERGED|CLOSED, draft, head, base, mergeable: true|false|"pending"|"unknown", approvals: [로그인], changes_requested, merge_commit}
pr_provider() { # url
  if [[ "$1" =~ ^https://bitbucket\.org/[^/]+/[^/]+/pull-requests/[0-9]+ ]]; then echo bitbucket
  elif [[ "$1" =~ ^https://[^/]+/[^/]+/[^/]+/pull/[0-9]+ ]]; then echo github
  else echo unknown; fi
}
bb_api() { # method path [json-body]
  [[ -n "${ATLASSIAN_USER:-}" && -n "${BITBUCKET_API_TOKEN:-}" ]] || { echo "ATLASSIAN_USER and BITBUCKET_API_TOKEN are not set" >&2; return 1; }
  local args=(-sS --fail-with-body --max-time 60 -K - -X "$1" "https://api.bitbucket.org/2.0/repositories/$2")
  [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$3")
  # 자격증명은 ps에 보이는 인자 대신 stdin 설정으로 넘긴다.
  printf 'user = "%s:%s"\n' "$ATLASSIAN_USER" "$BITBUCKET_API_TOKEN" | curl "${args[@]}"
}
bb_path() { # url → workspace/repo/pullrequests/<id>
  sed -E 's#^https://bitbucket\.org/([^/]+)/([^/]+)/pull-requests/([0-9]+).*#\1/\2/pullrequests/\3#' <<<"$1"
}
pr_facts() { # url
  case "$(pr_provider "$1")" in
    github)
      (cd "$REPO" && gh pr view "$1" --json state,isDraft,mergeable,headRefOid,baseRefName,reviews,author,mergeCommit) | jq -c '
        .author.login as $author | .headRefOid as $head
        | ([.reviews[] | select(.author.login != $author and (.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED")))]
            | group_by(.author.login) | map(max_by(.submittedAt))) as $latest
        | {state, draft: .isDraft, head: $head, base: .baseRefName,
           mergeable: (if .mergeable == "MERGEABLE" then true elif .mergeable == "CONFLICTING" then false else "pending" end),
           approvals: [$latest[] | select(.state == "APPROVED" and .commit.oid == $head) | .author.login],
           changes_requested: any($latest[]; .state == "CHANGES_REQUESTED"),
           merge_commit: (.mergeCommit.oid // "")}' ;;
    bitbucket)
      bb_api GET "$(bb_path "$1")" | jq -c '
        .author.uuid as $author
        | {state: (if .state == "OPEN" or .state == "MERGED" then .state else "CLOSED" end), draft: (.draft // false),
           head: .source.commit.hash, base: .destination.branch.name, mergeable: "unknown",
           approvals: [.participants[]? | select(.approved and .user.uuid != $author) | (.user.nickname // .user.display_name)],
           changes_requested: any(.participants[]?; .state == "changes_requested"),
           merge_commit: (.merge_commit.hash // "")}' ;;
    *) echo "unsupported pull request host: $1" >&2; return 1 ;;
  esac
}
pr_merge() { # url method head
  case "$(pr_provider "$1")" in
    github) (cd "$REPO" && gh pr merge "$1" "--$2" --match-head-commit "$3") ;;
    bitbucket)
      bb_api POST "$(bb_path "$1")/merge" \
        "$(jq -cn --arg m "$2" '{merge_strategy: ({squash: "squash", merge: "merge_commit", rebase: "fast_forward"}[$m]), close_source_branch: false}')" >/dev/null ;;
  esac
}

# merge: manifest merge_policy.require의 조건을 PR 호스트에서 읽은 상태로 판정하고, 모두 맞을 때만 head를 고정해 병합한다.
merge() {
  local url head facts blocked="[]" unmet="[]" mp err
  url="$(state '.publish.pr_url // ""')"
  head="$(state .head)"
  mp="$(jq -c '.policy.merge' "$STATE")"
  [[ "$(state '.policy.git')" == merge && "$mp" != null && "$(state '.policy.unattended // false')" != true ]] \
    || finish invariant_violation 40 "merge node reached although git_policy is not merge or the run is unattended"
  if ! facts="$(pr_facts "$url" 2>"$RUN/merge.err")" || [[ -z "$facts" ]]; then
    err="$(head -c 300 "$RUN/merge.err")"
    state_set '.findings = [$m] | .merge = {blocked: [$m]}' --arg m "cannot read the pull request state from its host: ${err:-no output}"
    go merge merge_blocked
    return
  fi
  printf '%s\n' "$facts" >"$RUN/merge-facts.json"
  case "$(jq -r .state <<<"$facts")" in
    MERGED)
      # 사람이 먼저 병합했다. 병합 후 검증은 그 병합 커밋으로 이어 간다.
      state_set '.merge = {commit: $f.merge_commit, base: $f.base, method: "outside the runner", merged_at: $t, merged_epoch: ($e | tonumber)}' \
        --argjson f "$facts" --arg t "$(now_utc)" --arg e "$(date -u +%s)"
      log "the pull request was already merged outside the runner: $(jq -r .merge_commit <<<"$facts")"
      go merge merged
      return ;;
    CLOSED) blocked='["the pull request was closed without merging"]' ;;
  esac
  # 승인·CI는 리뷰하고 push한 그 커밋에 대한 것이어야 한다. head가 움직였으면 누군가 push했다.
  [[ -n "$(jq -r .head <<<"$facts")" && "$head" == "$(jq -r .head <<<"$facts")"* ]] \
    || blocked="$(jq -c --arg h "$head" --arg p "$(jq -r .head <<<"$facts")" '. + ["the pull request head \($p) is not the pushed and reviewed commit \($h)"]' <<<"$blocked")"
  while IFS= read -r cond; do
    case "$cond" in
      human_approval)
        if [[ "$(jq -r .changes_requested <<<"$facts")" == true ]]; then
          blocked="$(jq -c '. + ["a reviewer requested changes"]' <<<"$blocked")"
        elif (( $(jq '.approvals | length' <<<"$facts") < $(jq -r '.min_approvals' <<<"$mp") )); then
          unmet="$(jq -c --argjson f "$facts" --argjson n "$(jq -r .min_approvals <<<"$mp")" \
            '. + ["human approval: \($f.approvals | length) of \($n) on the current head\(if ($f.approvals | length) > 0 then " (" + ($f.approvals | join(", ")) + ")" else "" end)"]' <<<"$unmet")"
        fi ;;
      remote_ci)
        [[ "$(state '.remote_ci.status // ""')" == passed && "$(state '.remote_ci.head // ""')" == "$head" ]] \
          || blocked="$(jq -c --arg s "$(state '.remote_ci.status // "missing"')" '. + ["remote CI for the head is \($s), not passed"]' <<<"$blocked")" ;;
      no_conflict)
        case "$(jq -r .mergeable <<<"$facts")" in
          false) blocked="$(jq -c '. + ["the pull request has merge conflicts with its base"]' <<<"$blocked")" ;;
          pending) unmet="$(jq -c '. + ["the host has not finished checking for conflicts"]' <<<"$unmet")" ;;
        esac ;;
      not_draft)
        [[ "$(jq -r .draft <<<"$facts")" != true ]] || unmet="$(jq -c '. + ["the pull request is a draft"]' <<<"$unmet")" ;;
    esac
  done <<<"$(jq -r '.require[]' <<<"$mp")"
  if [[ "$blocked" != "[]" ]]; then
    state_set '.findings = $b | .merge = {blocked: $b, facts: $f}' --argjson b "$blocked" --argjson f "$facts"
    go merge merge_blocked
    return
  fi
  if [[ "$unmet" != "[]" ]]; then
    state_set '.merge = {waiting: $u, facts: $f, checked_at: $t}' --argjson u "$unmet" --argjson f "$facts" --arg t "$(now_utc)"
    finish incomplete 30 "waiting for merge conditions on $url: $(jq -r 'join("; ")' <<<"$unmet"); run resume to check again"
  fi
  if ! pr_merge "$url" "$(jq -r .method <<<"$mp")" "$head" >"$RUN/merge.log" 2>&1; then
    state_set '.findings = [$m] | .merge = {blocked: [$m]}' --arg m "merging failed: $(tail -c 300 "$RUN/merge.log")"
    go merge merge_blocked
    return
  fi
  facts="$(pr_facts "$url" 2>/dev/null || printf '{}')"
  [[ "$(jq -r '.state // ""' <<<"$facts")" == MERGED ]] || {
    state_set '.findings = [$m] | .merge = {blocked: [$m]}' --arg m "the merge command succeeded but the host does not report the pull request as merged"
    go merge merge_blocked
    return
  }
  state_set '.merge = {commit: $f.merge_commit, base: $f.base, method: $m, approvals: $a, merged_at: $t, merged_epoch: ($e | tonumber)}' \
    --argjson f "$facts" --arg m "$(jq -r .method <<<"$mp")" --argjson a "$(jq -c .approvals "$RUN/merge-facts.json")" \
    --arg t "$(now_utc)" --arg e "$(date -u +%s)"
  log "merged $url as $(jq -r .merge_commit <<<"$facts") ($(jq -r .method <<<"$mp"))"
  go merge merged
}

# post_merge_verify: merge_policy.verify를 순서대로(타깃 CI → 배포 확인 → 스모크) 확인한다. 끝난 단계는 resume에서 다시 하지 않는다.
# 실패해도 되돌리지 않는다. 되돌릴지는 사람이 정한다.
post_merge_verify() {
  local commit base step label out status rc fail="" cmd waited timeout
  commit="$(state '.merge.commit // ""')"
  base="$(state '.merge.base // ""')"
  [[ -n "$commit" ]] || fail="the host did not report a merge commit, so nothing can be verified against it"
  for step in $(jq -r '.policy.merge.verify[]' "$STATE"); do
    [[ -z "$fail" ]] || break
    [[ "$(jq -r --arg s "$step" '.post_merge[$s].status // ""' "$STATE")" != passed ]] || continue
    case "$step" in
      target_ci)
        label="post-merge-ci"
        run_node post_merge_verify "$label" "$CONTEXT

You are the post_merge_verify node. Do not edit any file, commit, or push. The pull request $(state .publish.pr_url) was merged into $base as commit $commit. Find out whether the remote CI for exactly that commit on $base passed, without asking anyone anything:
- Use the PR or CI tool that AGENTS.md and the project workflow name (for example gh run list --commit, or the Bitbucket pipelines API through /bitbucket).
- Wait until every check or pipeline for the commit reaches a final state, polling about once a minute. A fresh merge commit can take a few minutes before its checks appear.
- passed: every check finished successfully. failed: any check failed; put each failing check in failures with the decisive lines of its log. none: the repository runs no CI on $base. pending: checks are still running after about 60 minutes. unverified: you cannot read the CI result; say why in summary.
- A local run of the CI commands is not a remote result. Never report passed from it.
Return only JSON matching the schema; commit is the SHA the result belongs to." "$REMOTE_CI_SCHEMA"
        out="$RUN/$label.out"
        jq -e '(.status | IN("passed", "failed", "none", "pending", "unverified")) and (.commit | type) == "string" and (.summary | type) == "string"' \
          "$out" >/dev/null 2>&1 || finish incomplete 30 "post-merge CI output does not match the schema ($out); run resume to check again"
        status="$(jq -r .status "$out")"
        if [[ "$status" == passed || "$status" == none ]] && [[ "$(jq -r .commit "$out")" == "" || ( "$commit" != "$(jq -r .commit "$out")"* && "$(jq -r .commit "$out")" != "$commit"* ) ]]; then
          status=unverified
          jq '.summary = "the CI result is not for the merge commit"' "$out" >"$out.tmp" && mv "$out.tmp" "$out"
        fi
        state_set '.post_merge.target_ci = ($r[0] + {status: $s, at: $t})' --slurpfile r "$out" --arg s "$status" --arg t "$(now_utc)"
        case "$status" in
          passed|none) state_set '.post_merge.target_ci.status = "passed" | .post_merge.target_ci.reported = $s' --arg s "$status" ;;
          pending) finish incomplete 30 "CI for the merge commit $commit is still running; run resume to check again" ;;
          *) fail="CI on $base for the merge commit $commit is $status: $(jq -r '.summary + (if (.failures // []) | length > 0 then " — " + (.failures | join("; ")) else "" end)' "$out")" ;;
        esac ;;
      deploy|smoke)
        cmd="$(jq -r --arg s "$step" 'if $s == "deploy" then .policy.merge.deploy_check_cmd else .policy.merge.smoke_cmd end' "$STATE")"
        rc=0
        (cd "$REPO" && HM_MERGE_COMMIT="$commit" HM_BASE_BRANCH="$base" HM_PR_URL="$(state .publish.pr_url)" bash -c "$cmd") \
          >"$RUN/post-merge-$step.log" 2>&1 </dev/null || rc=$?
        if ((rc != 0)) && [[ "$step" == smoke ]]; then
          # 배포 직후의 일시 실패와 실제 실패를 가르려 한 번만 다시 본다.
          sleep "${HM_SMOKE_RETRY_SECONDS:-30}"
          rc=0
          (cd "$REPO" && HM_MERGE_COMMIT="$commit" HM_BASE_BRANCH="$base" HM_PR_URL="$(state .publish.pr_url)" bash -c "$cmd") \
            >"$RUN/post-merge-$step.log" 2>&1 </dev/null || rc=$?
        fi
        state_set '.post_merge[$s] = {status: (if $rc == 0 then "passed" else "failed" end), command: $c, exit: $rc, tail: $tail, at: $t}' \
          --arg s "$step" --arg c "$cmd" --argjson rc "$rc" --arg tail "$(tail -n 20 "$RUN/post-merge-$step.log")" --arg t "$(now_utc)"
        if ((rc != 0)); then
          if [[ "$step" == deploy ]]; then
            waited=$(( ($(date -u +%s) - $(state '.merge.merged_epoch // 0')) / 60 ))
            timeout="$(state '.policy.merge.deploy_timeout_minutes')"
            ((waited >= timeout)) \
              || finish incomplete 30 "the merge commit $commit is not deployed yet (deploy check exit $rc, ${waited} of ${timeout} minutes); run resume to check again"
            fail="the merge commit $commit was not observed as deployed within $timeout minutes (deploy check: $cmd)"
          else
            fail="the smoke check failed twice after the merge (exit $rc): $cmd"
          fi
        fi ;;
    esac
  done
  if [[ -n "$fail" ]]; then
    state_set '.findings = [$f, $r] | .post_merge.failed = $f' --arg f "$fail" \
      --arg r "the change is merged and was not reverted. To roll it back, revert $commit on a new branch (git revert $([[ "$(state .merge.method)" == merge ]] && echo '-m 1 ' || true)$commit) and open a pull request"
    go post_merge_verify "$(edge_when post_merge_verify user_decision)"
    return
  fi
  go post_merge_verify post_merge_verified
}

CONTEXT="Read AGENTS.md, .ai-harness/workflows/$TEMPLATE.md, .ai-harness/workflows/$GRAPH_NAME and the project docs they select before anything else."

BRIEF_SCHEMA="$RUN/brief-schema.json"
REVIEW_SCHEMA="$RUN/review-schema.json"
INSPECT_SCHEMA="$RUN/inspect-schema.json"
SCOPE_SCHEMA="$RUN/scope-schema.json"
REPRODUCE_SCHEMA="$RUN/reproduce-schema.json"
PUBLISH_SCHEMA="$RUN/publish-schema.json"
REMOTE_CI_SCHEMA="$RUN/remote-ci-schema.json"
UI_REVIEW_SCHEMA="$RUN/ui-review-schema.json"

UI_SCENARIO_RULE="If the change alters what users see or operate (markup, styles, server-rendered templates, user-facing text, or the behavior of buttons, links, disclosures, forms, and dialogs), put one entry per scenario in ui_scenarios: the user role, entry -> key action -> success check -> return, the states to see (default and collapsed, empty, error, permission), and the viewports and themes the project supports. Follow the analysis step of the project ui-review skill (.agents/skills/ui-review or .claude/skills/ui-review) when it exists. Leave ui_scenarios empty for changes users cannot see."

brief_prompt() {
  local role inputs
  if [[ "$WORKFLOW" == bug-fix ]]; then
    role="You are the brief node of the bug-fix graph. Do not edit any file.
Write a Bug Fix Brief in Markdown: observed and expected behavior, impact, the reproduction evidence below, the cause hypothesis and what would prove it wrong, the regression verification the project test policy calls for (a regression test, or equivalent evidence when the policy allows it), and the smallest change scope.
Put the exact shell commands that must pass before the fix is done in checks, including the regression check. They run from the repository root with bash -c. Prefer targeted tests plus the project's required broad check."
    inputs="Bug report:
$(state .request)

Triage from the triage node:
$(cat "$RUN/triage.out")

Reproduction from the reproduce node:
$(cat "$RUN/reproduce.out")"
  else
    role="You are the brief node of the feature-delivery graph. Do not edit any file.
Write an Implementation Brief in Markdown: scope, out of scope, observable acceptance cases, expected change areas, and verification.
Put the exact shell commands that must pass before the feature is done in checks. They run from the repository root with bash -c. Prefer targeted tests plus the project's required broad check."
    inputs="Request:
$(state .request)

Project contract from the discover node:
$(cat "$RUN/discover.out")"
  fi
  printf '%s\n\n%s\n%s\n%s\n\n%s\n%s' "$CONTEXT" "$role" "$UI_SCENARIO_RULE" "$(if [[ "$(state '.policy.approval // "human"')" == auto ]]; then cat <<'EOF'
approval is auto: no person reads this brief before the change is made, so do not leave open questions. Wherever reasonable options diverge, choose the recommended one, write the brief to follow it, and record it in decisions as {question, choice, rationale}.
Put in needs_human only what a person alone can decide: a product judgment that changes the scope of the request; a hard-to-reverse choice such as deleting data, a migration, creating or dropping an index, or a deployment; a write to an external system. Leave needs_human empty otherwise. Any entry stops the run until a person approves.
EOF
else printf 'Put anything the person must decide in open_questions.\n'; fi)" "$inputs" \
    "$(if [[ "$(state '.feedback // ""')" != "" ]]; then printf '\nPrevious brief:\n%s\n\nRevise it with this feedback from the person:\n%s\n' "$(<"$RUN/brief.md")" "$(state .feedback)"; fi)"
}

execute() {
  local node brief
  while :; do
    node="$(state .node)"
    if jq -e --arg n "$node" '.terminals | index($n)' "$GRAPH" >/dev/null; then
      case "$node" in
        done)
          if [[ "$WORKFLOW" == review ]]; then
            finish "done" 0 "no blocking findings remain$(state 'if .attempts > 0 then "; \(.attempts) repair round(s) passed the required checks (run by the driver) and re-review; the repairs are left uncommitted — commit and push them as git_policy allows" else "" end')$(state 'if .ui_review then "; UI: verified — " + .ui_review.summary else "" end')"
          fi
          finish "done" 0 "required checks passed (run by the driver) and no blocking findings remain$(state 'if (.publish.pr_url // "") != "" then "; PR: " + .publish.pr_url elif .publish.skipped then "; " + .publish.skipped else "" end')$(state 'if .remote_ci then (if .remote_ci.status != "not_required" then "; remote CI: " + .remote_ci.status + " — " + .remote_ci.summary else "" end)
          elif (.publish // {} | has("pr_url")) then "; remote CI: unverified — the project graph has no remote_ci node; sync the harness (/harness-init --sync)" else "" end')$(state 'if .merge.commit then "; merged: " + .merge.commit[:12] + " (" + .merge.method + ")"
            + (if (.post_merge // {} | length) > 0 then "; after merge: " + ([.post_merge | to_entries[] | select(.value | type == "object") | .key + " " + .value.status] | join(", ")) else "" end)
          elif .merge.skipped then "; merge: not done — " + .merge.skipped else "" end')$(state 'if .ui_review then "; UI: verified — " + .ui_review.summary
          elif (.ui_scenarios // [] | length) > 0 then "; UI: unverified — the project graph has no ui_review node; sync the harness (/harness-init --sync)" else "" end')" ;;
        *) printf '%s\n' "$(state '.findings')" >"$RUN/unresolved.json"
           finish "$node" 20 "a person must decide$(state 'if .post_merge.failed then " (merged as " + .merge.commit[:12] + ", post-merge check failed: " + .post_merge.failed + "; not reverted)" elif .merge.blocked then " (merge blocked: " + (.merge.blocked | join("; ")) + ")" else "" end')$(state 'if .remote_ci.status == "unverified" then " (remote CI unverified: " + .remote_ci.summary + (if (.remote_ci.pr_url // "") != "" then "; PR: " + .remote_ci.pr_url else "" end) + ")" else "" end')$(jq -r --arg u "$UI_UNVERIFIED" 'if .ui_review.status == "unverified" then " (" + $u + ": " + .ui_review.summary + "; evidence: " + .ui_review.evidence_dir + "; nothing was published — make verification possible, then start a new run or verify and publish by hand)" else "" end' "$STATE"); see $RUN/unresolved.json" ;;
      esac
    fi
    # review가 수리 동의를 기다리던 노드면 그 노드를 다시 실행하지 않고 동의만 확인한다.
    if [[ "$(state '.awaiting.node // ""')" == "$node" ]]; then
      await_repair "$node" "$(state .awaiting.edge)"
      continue
    fi
    case "$node" in
      discover)
        run_node discover discover "$CONTEXT

You are the discover node of the feature-delivery graph. Do not edit any file.
Summarize the project contract that matters for the request below: relevant modules and files, conventions, the test policy, and the exact commands that verify a change (build, targeted tests, broad tests, lint).

Request:
$(state .request)"
        go discover ""
        ;;
      triage)
        run_node triage triage "$CONTEXT

You are the triage node of the bug-fix graph. Do not edit any file.
From the bug report below, state the observed behavior, the expected behavior, the impact, the relevant modules and files, the project test policy, and the exact commands that verify a change (build, targeted tests, broad tests, lint).

Bug report:
$(state .request)"
        go triage ""
        ;;
      reproduce)
        local repro
        repro="$RUN/reproduce"
        rm -rf "${RUN:?}/reproduce"
        mkdir -p "$repro"
        jq -e '.nodes.reproduce.commands == true' "$GRAPH" >/dev/null \
          || log "the project graph does not let reproduce run commands; it reads code and logs only. Sync the harness (/harness-init --sync)"
        run_node reproduce reproduce "$CONTEXT

You are the reproduce node of the bug-fix graph. Do not edit, create, or delete any file in the repository; keep scratch scripts, logs, and notes under $repro.
Reproduce the bug below with the smallest safe steps: a test or command run, or a request against a local server started with the local or test configuration the project documents. Never use production data or credentials, and point anything the app writes at $repro or a temporary directory: a new file in the repository stops the run. Stop any server you started before you finish.
status: reproduced when you observed the failure yourself; evidence_sufficient when you could not run it but logs, a stack trace, or code reading with a falsifiable hypothesis show the failure, or a safe observation plan will confirm the fix; blocked when neither is possible. Put what you observed (commands and their decisive output, or the log lines and code paths) in evidence. When blocked, put in needed what a person must provide: an environment, logs, or the expected behavior.
Return only JSON matching the schema.

Bug report:
$(state .request)

Triage from the triage node:
$(cat "$RUN/triage.out")" "$REPRODUCE_SCHEMA"
        jq -e '(.status | IN("reproduced", "evidence_sufficient", "blocked")) and (.evidence | type) == "array" and (.needed | type) == "array"' \
          "$RUN/reproduce.out" >/dev/null 2>&1 || finish incomplete 30 "reproduce output does not match the schema ($RUN/reproduce.out)"
        # 근거 없는 "재현됨"은 재현이 아니다. 근거가 비면 사람에게 넘긴다.
        if jq -e '.status != "blocked" and (.evidence | length) > 0' "$RUN/reproduce.out" >/dev/null; then
          go reproduce "$(edge_when reproduce brief)"
        else
          state_set '.findings = (["could not reproduce: " + $r[0].summary] + $r[0].needed) | .needs_user_decision = true' --slurpfile r "$RUN/reproduce.out"
          go reproduce "$(edge_when reproduce user_decision)"
        fi
        ;;
      brief)
        run_node brief "brief-$(state '.history | length')" "$(brief_prompt)" "$BRIEF_SCHEMA"
        brief="$RUN/brief-$(state '.history | length').out"
        # human은 open_questions, auto는 decisions·needs_human을 낸다. auto에서 예전 형식이 오면 승인 노드가 사람을 기다린다.
        jq -e '(.brief | type) == "string" and (.checks | type) == "array"
          and ((.open_questions | type) == "array"
            or ((.needs_human | type) == "array" and (.decisions | type) == "array"
              and all(.decisions[]; (.question | type) == "string" and (.choice | type) == "string" and (.rationale | type) == "string")))' \
          "$brief" >/dev/null 2>&1 || finish incomplete 30 "brief output does not match the schema ($brief)"
        cp "$brief" "$RUN/brief.json"
        jq -r '.brief + if (.decisions // [] | length) > 0
          then "\n\n## 결정 사항\n\n" + (.decisions | map("- \(.question) → \(.choice) — \(.rationale)") | join("\n")) else "" end
          + if (.ui_scenarios // [] | length) > 0
          then "\n\n## 화면 검증 시나리오\n\n" + (.ui_scenarios | map("- " + .) | join("\n")) else "" end' "$brief" >"$RUN/brief.md"
        # 승인 대상은 Brief 본문(결정 사항 포함)과 검증 명령 전체다. 둘 중 하나라도 바뀌면 이전 승인은 무효다.
        state_set '.checks = ([.cli_checks[], $b[0].checks[]] | map(select(length > 0)) | unique)
          | .ui_scenarios = ($b[0].ui_scenarios // [] | map(select(length > 0)))
          | .presented_at = $t | .feedback = null | .approval = null' --slurpfile b "$RUN/brief.json" --arg t "$(now_utc)"
        state_set '.brief_hash = $h' --arg h "$({ cat "$RUN/brief.md"; state '.checks[]'; } | git hash-object --stdin)"
        [[ "$(state '.checks | length')" -gt 0 ]] \
          || finish incomplete 30 "the brief has no verification command; revise with a check or start again with --check"
        go brief ""
        ;;
      approval)
        if [[ "$(state '.approval.brief_hash // ""')" != "$(state .brief_hash)" && "$(state '.policy.approval // "human"')" == auto ]]; then
          # auto는 사람 대신 정책이 승인한다. 사람만 정할 것이 있거나, 결정을 남기지 않은 예전 형식이거나, 그래프가 auto 엣지를 지웠으면 사람을 기다린다.
          if [[ "$(jq '.needs_human // [] | length' "$RUN/brief.json")" -gt 0 ]]; then
            log "approval is auto, but the brief lists decisions only a person can make; waiting for a person"
          elif ! jq -e '(.decisions | type) == "array" and (.open_questions // [] | length) == 0' "$RUN/brief.json" >/dev/null; then
            log "approval is auto, but the brief left open questions instead of recording decisions; waiting for a person"
          elif ! has_edge approval auto_approved_by_policy; then
            log "approval is auto, but the graph declares no auto_approved_by_policy edge; waiting for a person"
          else
            print_brief auto >&2
            record_approval "$(jq -n --arg t "$(now_utc)" --arg b "$RUN/brief.md" '{source:"auto-policy", at:$t, brief:$b}')"
            go approval auto_approved_by_policy
            continue
          fi
        fi
        if [[ "$(state '.approval.brief_hash // ""')" != "$(state .brief_hash)" ]]; then
          local evidence
          evidence="$(transcript_approval "$(state .presented_at | cut -c1-19)" | head -n 1)"
          [[ -n "$evidence" ]] && record_approval "$evidence"
        fi
        if [[ "$(state '.approval.brief_hash // ""')" == "$(state .brief_hash)" ]]; then
          go approval user_explicitly_approved
        else
          state_set '.status = "waiting_approval"'
          print_brief
          log "waiting for approval: run $RUN_ID"
          exit 10
        fi
        ;;
      deliver)
        local before
        before="$(fingerprint)"
        run_node deliver deliver "$CONTEXT

You are the deliver node. Implement the approved Implementation Brief below in this repository. Follow the project workflow and test policy (Red -> Green -> Refactor only when TDD is required), delegating to the project's role agents when the workflow says so.
Do not commit, push, create a PR, or change scope. After you finish, the driver itself runs these checks: $(state '.checks | join(" ; ")')
Return a concise summary of changed areas and the commands you ran.

$(brief_context)"
        [[ "$(fingerprint)" != "$before" ]] || finish incomplete 30 "deliver changed nothing; an approved feature cannot be done without a change"
        checkpoint deliver
        go deliver ""
        ;;
      regression)
        run_node regression regression "$CONTEXT

You are the regression node of the bug-fix graph. Establish the regression verification the approved brief names, following the project test policy: add or change tests (or the equivalent verification the policy allows), not production code. When the policy expects a failing test first, run it, confirm it fails for the reported reason, and say so. Delegate test work to the project's test role when the workflow says so.
Do not commit, push, create a PR, or change scope; the driver commits checkpoints itself.
Return a concise summary of the regression evidence and the commands you ran.

$(brief_context)"
        checkpoint regression
        go regression ""
        ;;
      fix)
        local before_fix
        before_fix="$(fingerprint)"
        run_node fix fix "$CONTEXT

You are the fix node of the bug-fix graph. Fix the cause in production code within the approved scope, delegating to the project's role agents when the workflow says so. Do not weaken, skip, or delete the regression verification.
Do not commit, push, create a PR, or change scope. After you finish, the driver itself runs these checks: $(state '.checks | join(" ; ")')
Return a concise summary of the cause, the changed areas, and the commands you ran.

$(brief_context)"
        [[ "$(fingerprint)" != "$before_fix" ]] || finish incomplete 30 "fix changed nothing; an approved bug fix cannot be done without a change to the cause"
        checkpoint fix
        go fix ""
        ;;
      verify)
        # 검증은 모델이 아니라 이 스크립트가 직접 실행한다.
        if run_checks "verify-$(state .attempts)"; then
          go verify required_checks_pass
        else
          state_set '.findings = $f | .needs_user_decision = false' --argjson f "$(check_findings "verify-$(state .attempts)")"
          if ! has_edge verify required_checks_fail; then
            # 실패 엣지가 없는 그래프(동기화 전)는 실패를 고칠 경로가 없다.
            printf '%s\n' "$(state '.findings')" >"$RUN/unresolved.json"
            state_set '.node = "user_decision"'
            finish user_decision 20 "required checks failed and the project graph has no verify -> repair edge; sync the harness (/harness-init --sync) or fix the failures by hand; see $RUN/unresolved.json"
          fi
          go verify required_checks_fail
        fi
        ;;
      review)
        # 그래프에 verify 노드가 있으면 검증은 이미 그 노드가 했다. 없으면(feature) 리뷰 전에 이 스크립트가 실행한다.
        if ! jq -e '.nodes | has("verify")' "$GRAPH" >/dev/null && ! run_checks "review-$(state .attempts)"; then
          state_set '.findings = $f | .needs_user_decision = false' --argjson f "$(check_findings "review-$(state .attempts)")"
        else
          run_node review "review-$(state .attempts)" "$CONTEXT

You are the review node. Do not edit any file. Review every change since $(state .start_head) (git diff $(state .start_head), which includes the driver's checkpoint commits, and untracked files) against the approved brief. The driver already ran the required checks and they passed.
$(if [[ "$WORKFLOW" == bug-fix ]]; then
  printf 'A blocking finding is incorrect or missing behavior, missing or unconvincing reproduction or regression evidence, a regression, security or data risk, or a material scope violation. Everything else is non-blocking.'
else
  printf 'A blocking finding is incorrect or missing behavior, a regression, security or data risk, or a material scope violation. Everything else is non-blocking.'
fi)
Set needs_user_decision to true only when a blocking finding needs a product or scope decision from a person.
Return only JSON matching the schema.

$(brief_context)" "$REVIEW_SCHEMA"
          review_output "$RUN/review-$(state .attempts).out"
        fi
        route_review review
        ;;
      scope)
        run_node scope scope "$CONTEXT

You are the scope node of the change-review graph. Do not edit any file.
Identify the change to review from the request below: what it is meant to do (summary), the changed files, and the base it is measured against (base: a ref or SHA that git rev-parse accepts in this repository, such as origin/develop for a branch or pull request, or HEAD for uncommitted work). Put the exact shell commands the project docs require to verify such a change in checks; they run from the repository root with bash -c after any repair.
Return only JSON matching the schema.

Request:
$(state .request)" "$SCOPE_SCHEMA"
        jq -e '(.summary | type) == "string" and (.base | type) == "string" and (.files | type) == "array" and (.checks | type) == "array"' \
          "$RUN/scope.out" >/dev/null 2>&1 || finish incomplete 30 "scope output does not match the schema ($RUN/scope.out)"
        local base diff_base
        base="$(jq -r .base "$RUN/scope.out")"
        diff_base="$(git -C "$REPO" merge-base "$base" HEAD 2>/dev/null)" \
          || finish incomplete 30 "the review base '$base' is not a commit in this repository; fetch it or start again with a clearer request"
        # 기준이 HEAD와 같아 검토할 변경이 없으면 finding 없음이 곧 통과가 된다. 대상 브랜치를 체크아웃하지 않은 경우다.
        if git -C "$REPO" diff --quiet "$diff_base" && [[ -z "$(git -C "$REPO" ls-files --others --exclude-standard)" ]]; then
          finish incomplete 30 "nothing to review: no changes since '$base' ($diff_base); check out the branch under review or start again with the right base"
        fi
        jq -r --arg d "$diff_base" '.summary + "\n\nBase: \(.base) (\($d))\nChanged files:\n" + (.files | map("- " + .) | join("\n"))
          + "\n\nRequest:\n"' "$RUN/scope.out" >"$RUN/scope.md"
        state .request >>"$RUN/scope.md"
        state_set '.diff_base = $d | .checks = ([.cli_checks[], $s[0].checks[]] | map(select(length > 0)) | unique)' \
          --arg d "$diff_base" --slurpfile s "$RUN/scope.out"
        go scope ""
        ;;
      inspect)
        run_node inspect inspect "$CONTEXT

You are the inspect node of the change-review graph. Do not edit any file. Review every change since $(state .diff_base) (git diff $(state .diff_base), including uncommitted changes and untracked files) against the review scope below.
Check behavior, required checks, security and data, compatibility, scope, and generated files. A blocking finding is incorrect or missing behavior, a regression, security or data risk, a broken required check, or a material scope violation; give each with its file and line. Everything else is non-blocking.
Set needs_user_decision to true only when a blocking finding needs a product or scope decision from a person.
$UI_SCENARIO_RULE
Return only JSON matching the schema.

$(brief_context)" "$INSPECT_SCHEMA"
        review_output "$RUN/inspect.out"
        go inspect ""
        ;;
      classify)
        # 분류는 inspect가 낸 finding으로 이 스크립트가 정한다. 수리는 사람이 동의(또는 approval: auto)해야 시작한다.
        route_review classify
        ;;
      re_review)
        run_node re_review "re-review-$(state .attempts)" "$CONTEXT

You are the re_review node of the change-review graph. Do not edit any file. The blocking findings below were repaired and the driver's required checks passed. Review every change since $(state .diff_base) (git diff $(state .diff_base), including uncommitted changes and untracked files) again: confirm each previous blocking finding is resolved and look for new ones the repair introduced.
A blocking finding is incorrect or missing behavior, a regression, security or data risk, a broken required check, or a material scope violation. Everything else is non-blocking.
Set needs_user_decision to true only when a blocking finding needs a product or scope decision from a person.
Return only JSON matching the schema.

Previous blocking findings:
$(state '.repaired_findings // []')

$(brief_context)" "$REVIEW_SCHEMA"
        review_output "$RUN/re-review-$(state .attempts).out"
        route_review re_review
        ;;
      ui_review)
        local ui_label ui_out evidence
        ui_label="ui-review-$(state .attempts)"
        evidence="$RUN/$ui_label"
        # resume이 같은 시도를 다시 돌 때 이전 캡처가 이번 근거로 섞이지 않게 한다.
        rm -rf "${RUN:?}/$ui_label"
        mkdir -p "$evidence"
        run_node ui_review "$ui_label" "$CONTEXT

You are the ui_review node. Do not edit, create, or delete any file in the repository. Follow the project ui-review skill (.agents/skills/ui-review/SKILL.md or .claude/skills/ui-review/SKILL.md, with its references/checklist.md) and .ai-harness/docs/ui.md when they exist; project design documents, semantic tokens, shared components, and reference screens come first.
A code review found no blocking findings. You review the rendered screens, not the code: start the app as the project documents say, open every scenario below in a real browser, and operate it as a first-time user with mouse, keyboard, and a mobile-width viewport, in each supported theme. Look at the default and collapsed states before hovering or focusing anything.
Save captures and notes only under $evidence. Run the app with the local or test configuration the project documents, never production credentials, and point anything it writes (database files, uploads, logs, browser profiles) at $evidence or a temporary directory: a new file in the repository stops the run. Stop any server you started before you finish.
If the change added or changed a design-system example or reference screen, open and operate that example too.
These are not evidence of a usable screen: a test that found and clicked an element by its text, a shared class or token in the markup, an attribute such as data-theme or aria-expanded being set, a screenshot file existing, or an earlier claim that something was fixed.
Report one scenarios entry per scenario, viewport, and theme you actually rendered and operated, with the URL you opened and the capture files you saved under $evidence.
status: verified when you rendered and operated every scenario, found no blocking UI issue, and have nothing in unverified; issues when there is at least one; unverified when you could not start the app, could not use a browser, or could not check any required scenario, viewport, or theme. A blocking UI issue means a user cannot find or misreads a key action, an action's name does not match its result, a required input or an error cannot be recovered from, a scenario cannot be finished with a keyboard or in a supported viewport or theme, a shared component exists for the role but a one-off was built, or a hard-to-reverse action has no confirmation.
Return only JSON matching the schema.

UI scenarios:
$(state '.ui_scenarios | map("- " + .) | join("\n")')

$(brief_context)" "$UI_REVIEW_SCHEMA"
        ui_out="$RUN/$ui_label.out"
        jq -e '(.status | IN("verified", "issues", "unverified")) and (.blocking_findings | type) == "array" and (.unverified | type) == "array"' "$ui_out" >/dev/null 2>&1 \
          || finish incomplete 30 "ui_review output does not match the schema; the change is not done ($ui_out)"
        state_set '.ui_review = ($r[0] | {status, summary, unverified, evidence_dir: $e})' --slurpfile r "$ui_out" --arg e "$evidence"
        # 검증하지 못했는데 문제만 적은 경우도 사람에게 넘긴다. issues인데 발견 사항이 비면 검증 근거가 없는 것이다.
        # verified는 발견 없음·미검증 없음·시나리오마다 조작 기록이 있을 때만 믿는다. 기록 없는 verified는 근거 없는 통과다.
        if [[ "$(state .ui_review.status)" == verified ]] \
          && jq -e --argjson n "$(state '.ui_scenarios | length')" \
            '(.blocking_findings | length) == 0 and (.unverified | length) == 0 and (.scenarios | length) >= $n
              and all(.scenarios[]; (.captures | length) > 0)' "$ui_out" >/dev/null \
          && captures_present "$ui_out" "$evidence"; then
          state_set '.reviewed_tree = $t' --arg t "$(worktree_tree)"
          go ui_review ui_verified
        elif [[ "$(state .ui_review.status)" == issues && "$(jq '.blocking_findings | length' "$ui_out")" -gt 0 ]]; then
          state_set '.findings = ($r[0].blocking_findings + ($r[0].unverified | map("not yet verified: " + .))) | .needs_user_decision = false' --slurpfile r "$ui_out"
          if [[ "$WORKFLOW" != review ]]; then
            go ui_review "$(edge_when ui_review repair)"
          elif [[ "$(state .attempts)" -ge "$MAX_REPAIR" ]]; then
            go ui_review "$(edge_when ui_review user_decision)"
          else
            await_repair ui_review "$(edge_when ui_review repair)"
          fi
        else
          state_set '.ui_review.status = "unverified" | .ui_review.summary = (if $r[0].status == "verified" then "reported verified without a record for every scenario or with unverified items: " else "" end + $r[0].summary)
            | .findings = ($r[0].blocking_findings + $r[0].unverified + [$e])' --slurpfile r "$ui_out" --arg e "evidence: $evidence"
          go ui_review "$(edge_when ui_review user_decision)"
        fi
        ;;
      repair)
        # 수리 한도·제품 판단으로 사람에게 넘기는 엣지는 그래프가 정한다(review는 re_review가 한도를 본다).
        if [[ "$(state '.needs_user_decision // false')" == true || "$(state .attempts)" -ge "$MAX_REPAIR" ]]; then
          local escalate
          escalate="$(edge_when repair user_decision)"
          if [[ -z "$escalate" ]]; then
            # review 그래프는 repair에서 사람에게 가는 엣지가 없다(한도는 re_review가 본다). 검증 실패가 한도까지 반복되면 여기서 넘긴다.
            printf '%s\n' "$(state '.findings')" >"$RUN/unresolved.json"
            state_set '.node = "user_decision"'
            finish user_decision 20 "a person must decide: the repair limit ($MAX_REPAIR) was reached with blocking findings left; see $RUN/unresolved.json"
          fi
          go repair "$escalate"
          continue
        fi
        state_set '.attempts += 1 | .repaired_findings = .findings'
        run_node repair "repair-$(state .attempts)" "$CONTEXT

You are the repair node. Fix only these blocking findings. Follow the project test policy. Do not commit, push, create a PR, or change unrelated files; the driver commits checkpoints itself when git_policy allows.

Blocking findings:
$(state '.findings')

$(brief_context)"
        checkpoint "repair-$(state .attempts)"
        # 그래프가 repair 뒤 verify 노드로 가면(bug-fix·review) 검증은 그 노드가 한다. 아니면(feature) 여기서 실행한다.
        if has_edge repair ""; then
          go repair ""
        elif run_checks "repair-$(state .attempts)"; then
          go repair required_checks_pass
        else
          state_set '.findings = $f' --argjson f "$(check_findings "repair-$(state .attempts)")"
          go repair required_checks_fail
        fi
        ;;
      publish)
        publish
        ;;
      remote_ci)
        remote_ci
        ;;
      merge)
        merge
        ;;
      post_merge_verify)
        post_merge_verify
        ;;
      *) finish invariant_violation 40 "the driver has no handler for graph node '$node'" ;;
    esac
  done
}

case "$CMD" in
  start)
    case "${RUNTIME:-}" in
      "") if command -v codex >/dev/null; then RUNTIME=codex; else RUNTIME=claude; fi ;;
      codex|claude) ;;
      *) usage ;;
    esac
    command -v "$RUNTIME" >/dev/null || { printf '%s not found\n' "$RUNTIME" >&2; exit 2; }
    git_policy="$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)"
    # 체크포인트는 git add -A로 커밋한다. 실행 전 변경이 섞이거나 기준 브랜치에 커밋이 쌓이지 않게 시작 조건을 막는다.
    # review는 커밋하지 않으며, 커밋 전의 변경이 곧 검토 대상일 수 있다.
    if [[ "$WORKFLOW" != review ]]; then
      case "$git_policy" in
        pr-only|direct|merge)
          [[ -z "$(git -C "$REPO" status --porcelain --untracked-files=all)" ]] \
            || { printf 'git_policy lets the runner commit; commit or stash the existing changes first so they do not mix into the run\n' >&2; exit 2; }
          ;;
      esac
      if [[ "$git_policy" == pr-only || "$git_policy" == merge ]]; then
        base="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        [[ -z "$base" || "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" != "${base#origin/}" ]] \
          || { printf 'git_policy %s: start on a work branch or worktree, not the base branch %s\n' "$git_policy" "${base#origin/}" >&2; exit 2; }
      fi
    fi
    # merge 조건과 병합 후 검증은 사람이 init에서 정한다. 실행 중 manifest가 바뀌어도 시작 때의 정책을 따른다.
    merge_policy=null
    if [[ "$git_policy" == merge && "$WORKFLOW" != review ]]; then
      merge_policy="$(jq -c '.merge_policy // {} | {
          require: (.require // []), min_approvals: (.min_approvals // 1), method: (.method // "squash"), verify: (.verify // []),
          deploy_check_cmd: (.deploy_check_cmd // ""), deploy_timeout_minutes: (.deploy_timeout_minutes // 60), smoke_cmd: (.smoke_cmd // "")}' \
        "$REPO/.ai-harness/harness.json")"
      jq -e '(.require | type == "array" and length > 0 and all(.[]; IN("human_approval", "remote_ci", "no_conflict", "not_draft")))
          and (.min_approvals | type == "number" and . >= 1) and (.method | IN("squash", "merge", "rebase"))
          and (.verify | type == "array" and all(.[]; IN("target_ci", "deploy", "smoke")))
          and ((.verify | index("deploy") | not) or (.deploy_check_cmd | length > 0))
          and ((.verify | index("smoke") | not) or (.smoke_cmd | length > 0))
          and (.deploy_timeout_minutes | type == "number" and . > 0)' <<<"$merge_policy" >/dev/null \
        || { printf 'git_policy merge needs a valid merge_policy in .ai-harness/harness.json: require (one or more of human_approval, remote_ci, no_conflict, not_draft), method squash|merge|rebase, verify (target_ci, deploy, smoke) with deploy_check_cmd or smoke_cmd for deploy or smoke. Rerun /harness-init to set it\n' >&2; exit 2; }
    fi
    mkdir -p "$RUN"
    printf '%s\n' "$RUN_ID" >"$(latest_file)"
    printf '%s\n' "$RUN_ID" >"$(latest_file "$WORKFLOW")"
    jq -n --arg id "$RUN_ID" --arg wf "$WORKFLOW" --arg repo "$REPO" --arg rt "$RUNTIME" --arg req "$REQUEST" --arg graph "$GRAPH" \
      --arg node "$(jq -r .entry "$GRAPH")" --arg head "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf none)" --arg t "$(now_utc)" \
      --arg git "$git_policy" --argjson merge "$merge_policy" --arg unattended "${HM_INTERNAL_SESSION:-}" \
      --arg appr "$(jq -r '.approval // "human"' "$REPO/.ai-harness/harness.json" 2>/dev/null || printf human)" \
      --argjson cli "$(printf '%s\n' "${CLI_CHECKS[@]+"${CLI_CHECKS[@]}"}" | jq -R . | jq -s 'map(select(length > 0))')" \
      '{run_id:$id, workflow:$wf, repo:$repo, runtime:$rt, request:$req, graph:$graph, node:$node, start_head:$head, head:$head, started_at:$t,
        policy:{git:$git, approval:(if $appr == "auto" then "auto" else "human" end), commits:(($git | IN("pr-only", "direct", "merge")) and $wf != "review"),
          merge:$merge, unattended:($unattended == "1")},
        status:"running", attempts:0, cli_checks:$cli, checks:[], checkpoints:[], findings:[], history:[]}' >"$STATE"
    ;;
  watch)
    [[ -f "$STATE" ]] || { printf 'run not found: %s\n' "$RUN" >&2; exit 2; }
    touch "$RUN/progress.log"
    exec tail -n 50 -f "$RUN/progress.log"
    ;;
  resume|approve|revise|status)
    [[ -f "$STATE" ]] || { printf 'run not found: %s\n' "$RUN" >&2; exit 2; }
    ;;
  *) usage ;;
esac
# 실행을 이어 가는 명령마다 진행 파일 경로를 알린다. 새 세션에서 resume만 부른 에이전트도 모니터할 경로를 얻는다.
if [[ "$CMD" != status ]]; then
  log "run $RUN_ID · progress: $RUN/progress.log · follow with: bash $(printf '%q' "$SCRIPT_DIR/$(basename "$0")") watch --workflow $WORKFLOW --repo $(printf '%q' "$REPO")"
fi

if [[ "$(state '.policy.approval // "human"')" == auto ]]; then
  cat >"$BRIEF_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["brief","checks","ui_scenarios","decisions","needs_human"],
 "properties":{"brief":{"type":"string"},"checks":{"type":"array","items":{"type":"string"}},"ui_scenarios":{"type":"array","items":{"type":"string"}},
  "decisions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["question","choice","rationale"],
   "properties":{"question":{"type":"string"},"choice":{"type":"string"},"rationale":{"type":"string"}}}},
  "needs_human":{"type":"array","items":{"type":"string"}}}}
EOF
else
  cat >"$BRIEF_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["brief","checks","ui_scenarios","open_questions"],
 "properties":{"brief":{"type":"string"},"checks":{"type":"array","items":{"type":"string"}},"ui_scenarios":{"type":"array","items":{"type":"string"}},
  "open_questions":{"type":"array","items":{"type":"string"}}}}
EOF
fi
cat >"$REVIEW_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","blocking_findings","non_blocking_findings","needs_user_decision"],
 "properties":{"summary":{"type":"string"},"blocking_findings":{"type":"array","items":{"type":"string"}},
  "non_blocking_findings":{"type":"array","items":{"type":"string"}},"needs_user_decision":{"type":"boolean"}}}
EOF
cat >"$INSPECT_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","blocking_findings","non_blocking_findings","needs_user_decision","ui_scenarios"],
 "properties":{"summary":{"type":"string"},"blocking_findings":{"type":"array","items":{"type":"string"}},
  "non_blocking_findings":{"type":"array","items":{"type":"string"}},"needs_user_decision":{"type":"boolean"},
  "ui_scenarios":{"type":"array","items":{"type":"string"}}}}
EOF
cat >"$SCOPE_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","base","files","checks"],
 "properties":{"summary":{"type":"string"},"base":{"type":"string"},"files":{"type":"array","items":{"type":"string"}},
  "checks":{"type":"array","items":{"type":"string"}}}}
EOF
cat >"$REPRODUCE_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["status","summary","evidence","hypothesis","needed"],
 "properties":{"status":{"type":"string","enum":["reproduced","evidence_sufficient","blocked"]},"summary":{"type":"string"},
  "evidence":{"type":"array","items":{"type":"string"}},"hypothesis":{"type":"string"},"needed":{"type":"array","items":{"type":"string"}}}}
EOF
cat >"$UI_REVIEW_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["status","summary","scenarios","blocking_findings","non_blocking_findings","unverified"],
 "properties":{"status":{"type":"string","enum":["verified","issues","unverified"]},"summary":{"type":"string"},
  "scenarios":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["scenario","viewport","theme","actions","captures","result"],
   "properties":{"scenario":{"type":"string"},"viewport":{"type":"string"},"theme":{"type":"string"},"actions":{"type":"string"},
    "captures":{"type":"array","items":{"type":"string"}},"result":{"type":"string"}}}},
  "blocking_findings":{"type":"array","items":{"type":"string"}},"non_blocking_findings":{"type":"array","items":{"type":"string"}},
  "unverified":{"type":"array","items":{"type":"string"}}}}
EOF
cat >"$PUBLISH_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","branch","pr_url"],
 "properties":{"summary":{"type":"string"},"branch":{"type":"string"},"pr_url":{"type":"string"}}}
EOF
cat >"$REMOTE_CI_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["status","commit","summary","failures"],
 "properties":{"status":{"type":"string","enum":["passed","failed","none","pending","unverified"]},"commit":{"type":"string"},
  "summary":{"type":"string"},"failures":{"type":"array","items":{"type":"string"}}}}
EOF

case "$CMD" in
  status)
    jq -r '"run \(.run_id) · workflow \(.workflow // "feature") · node \(.node) · status \(.status) · repair \(.attempts) · approval \(.policy.approval // "human") · git_policy \(.policy.git // "")\n" + (.history | map("  \(.from) --\(if .outcome == "" then "next" else .outcome end)--> \(.to)") | join("\n"))' "$STATE"
    [[ "$(state .status)" == waiting_approval && -f "$RUN/brief.json" ]] && print_brief
    exit 0
    ;;
  revise)
    [[ -n "$FEEDBACK" ]] || usage
    [[ "$(state .node)" == approval ]] || { printf 'revise works only while waiting for approval of a brief (node: %s)\n' "$(state .node)" >&2; exit 2; }
    state_set '.feedback = $f' --arg f "$FEEDBACK"
    go approval brief_changed_or_not_approved
    ;;
  approve)
    [[ "$(state .status)" == waiting_approval ]] || { printf 'nothing to approve (node: %s)\n' "$(state .node)" >&2; exit 2; }
    # 에이전트의 Bash 도구·codex exec에는 제어 터미널이 없어 여기서 열리지 않는다.
    (exec 3<>/dev/tty) 2>/dev/null || { printf 'approve needs a terminal; in a conversation, type "승인" and run resume\n' >&2; exit 10; }
    exec 3<>/dev/tty
    print_brief >&3
    printf '\nApprove this and allow file changes? [y/N] ' >&3
    answer=""
    IFS= read -r answer <&3 || true
    exec 3>&-
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]] || { log "not approved; revise or start again"; exit 10; }
    record_approval "$(jq -n --arg t "$(now_utc)" '{source:"terminal", at:$t}')"
    ;;
esac

state_set '.status = "running"'
execute
