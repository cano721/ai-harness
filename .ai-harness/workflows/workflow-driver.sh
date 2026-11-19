#!/usr/bin/env bash
# 프로젝트 워크플로 그래프(feature-delivery·bug-fix·review·design-polish)를 실행하는 그래프 러너. 모델이 아니라 이 스크립트가 전이를 정한다.
#   - 워크플로: --workflow feature|bug-fix|review|polish(기본 feature)가 실행할 그래프를 고른다. resume·status는 실행 상태의 워크플로를 따른다.
#   - polish(기존 화면 품질 개선): measure(브라우저 캡처·design-audit 채점) → diagnose(독립 비평, 고칠 목록) → approval(사람이 항목 선택,
#     revise --select) → fix → verify → measure → review. 통과 판정(고른 주요 항목 0·audit 기준·기준선보다 나빠진 축 없음)은
#     이 스크립트가 측정 결과로 한다. 측정 뒤 바뀐 파일은 review가, 검토 뒤 바뀐 파일은 publish가 거부하고 verify(검사)부터 다시 돈다.
#   - 노드: 그래프의 nodes. write:false 노드는 읽기 전용 세션(Codex sandbox read-only, Claude는 읽기 도구만)으로 띄우고
#     세션 전후 작업 트리 지문이 다르면 멈춘다. 명령을 실행해야 하는 읽기 노드(commands·network·browser)도 같은 지문 비교로 쓰기를 막는다.
#     actor:human 노드에서는 실행을 멈추고(interrupt) 사람을 기다린다.
#   - 엣지: 노드가 낸 결과(outcome)와 같은 when을 가진 전이만 따른다. 그래프에 없는 전이는 불변식 위반이다.
#   - 상태: 노드마다 state.json에 체크포인트를 남겨 resume이 멈춘 노드부터 이어 간다.
#   - 승인: 사용자가 대화에 직접 입력한 "승인"(Claude·Codex 트랜스크립트의 사용자 메시지) 또는 터미널의 approve.
#     모델이 쓰는 도구 출력·자기 메시지는 사용자 메시지가 아니므로 승인이 되지 않는다.
#     저장소별 HM_APPROVAL_REPOS > HM_APPROVAL > 기본 human 순으로 결정한다. 기존 manifest approval은 무시하고 한 번 안내한다.
#     auto면 Brief가 열린 질문 대신 decisions(추천안과 근거)를 내고, 사람만 정할 수 있는 것
#     (needs_human)이 비어 있을 때 그래프의 auto_approved_by_policy 엣지로 통과한다. decisions는 brief.md와 PR 본문에 남는다.
#     review 그래프에는 승인 노드가 없다. blocking finding을 고치는 repair는 같은 승인(또는 HM_APPROVAL=auto)을 받은 뒤에만 시작한다.
#   - 검증: Brief(review는 수리 범위)에 담겨 함께 승인된 검증 명령을 이 스크립트가 직접 실행해 종료 코드로 판정한다.
#   - git: harness.json의 git_policy가 pr-only·direct면 쓰기 노드 뒤 로컬 체크포인트 커밋을 남기고, publish 노드가
#     커밋·일반 push·PR을 맡는다. 그 밖의 값이면 커밋하지 않는다. review는 publish 노드가 없어 수리를 커밋하지 않고 남긴다.
#     publish 밖에서 이 스크립트가 아닌 누군가 HEAD를 움직이면 멈춘다.
#   - 원격 CI: push했으면 remote_ci 노드가 그 커밋의 원격 CI가 끝날 때까지 본다. 실패는 repair로 돌아가 다시 push하고,
#     볼 수단이 없으면 done이 아니라 사람에게 미확인으로 넘긴다. 로컬에서 같은 명령이 통과해도 원격 CI를 대신하지 못한다.
#   - 병합: 개인 자동화 단계가 merge·deploy면 원격 CI 뒤 merge 노드에서 이 스크립트가 PR 호스트(gh·Bitbucket API)에서 직접 읽은 상태로
#     저장소 호스트 규칙(브랜치 보호의 필수 승인·필수 체크)과 충돌 없음·draft 아님·변경 요청 없음을 판정하고, 모두 맞을 때만 head를 고정해 병합한다.
#     조건이 아직 안 맞으면 exit 30으로 멈추고 resume이 다시 본다. 무인 실행(HM_INTERNAL_SESSION=1)은 병합하지 않는다.
#     병합 뒤 post_merge_verify가 단계에 맞는 검증(타깃 CI·배포 확인 명령·스모크 명령)을 확인한다. 실패는 되돌리지 않고 사람에게 넘긴다.
#     모니터링 재발 확인(monitor)은 관찰 창이 길어 실행 안에서 끝나지 않는다 — start --monitor-error로 받은 에러를 /autofix 추적에 올리는 데까지다.
#   - 자동화 단계: 병합 여부는 사용자 설정(~/.ai-harness/config)의 HM_DELIVERY_LEVEL(pr|merge|deploy, 저장소별은 HM_DELIVERY_LEVEL_REPOS)만
#     정하고, 없으면 PR까지다. git_policy는 커밋·PR 범위만 정한다 — 예전 값 merge는 pr-only로 읽고 안내를 남긴다. 기준 브랜치·배포·스모크
#     명령은 저장소 merge_policy(저장소 사실)에서 읽는다. 병합 조건과 방식은 하네스가 정하지 않고 저장소 호스트 설정을 따른다:
#     필수 승인 수·필수 체크는 기준 브랜치 보호 규칙에서(보호가 없으면 승인 없이 병합), 방식은 저장소가 허용한 방식(GitHub)·기본 전략(Bitbucket).
#     호스트가 강제하지 않는 경우(관리자 우회·Bitbucket 비강제 merge check)에도 러너가 그 규칙을 직접 판정한다. 보호 규칙을 읽지 못하면 사람에게 넘긴다.
#     예전 HM_MERGE_*와 merge_policy의 require·min_approvals·method는 쓰지 않는다.
#   - 화면 검증: 화면 시나리오(ui_scenarios)가 있으면 리뷰 뒤 ui_review 노드가 ui-review 계약대로 화면을 실제로 렌더링·조작한다.
#     캡처는 실행 디렉터리의 ui-review-<시도>/에 남는다. 주요 문제는 repair로 돌아가 다시 리뷰·ui_review를 거치고,
#     검증하지 못하면 done이 아니라 사람에게 미검증으로 넘긴다.
# shellcheck disable=SC2016  # state_set·jq 인자의 $x는 셸이 아니라 jq 변수다
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: workflow-driver.sh <command> [--workflow feature|bug-fix|review|polish] [options]

  start   --request "<요청>" | --request-file <file>   계획 노드를 실행하고 승인 대기에서 멈춘다
          [--check "<검증 명령>"]...                    Brief(review는 수리 범위)가 제안한 검증에 더할 명령
          [--monitor-error <file>]                      고치는 모니터링 에러(/autofix candidates의 한 줄). 단계 deploy에서 merge_policy.verify의 monitor가 병합 뒤 재발 추적에 올린다
          [--investigation <file>]                      bug-fix만: /investigate의 조사 보고. 그래프에 triage → brief 전이가 있으면 triage·reproduce를 건너뛴다
  revise  --feedback "<바꿀 점>"                         승인 대기 중인 Brief를 피드백으로 다시 만든다
          --select "<ID,ID...>"                         polish만: 고칠 목록에서 고칠 항목을 바꾼다(모델을 부르지 않는다). 다시 승인을 기다린다
  resume  [--accept-changes]                            승인을 확인하고 멈춘 노드부터 이어 간다
  approve [--accept-changes]                            터미널에서 사람이 Brief(review는 수리 범위)를 보고 승인한 뒤 이어 간다
          resume·approve·revise는 에이전트를 부르기 전에 러너가 멈춘 때의 기준점(HEAD·작업 트리)과 지금을 대조한다.
          바뀌었으면 차이와 남은 검사를 보이고 20으로 멈춘다. 바뀐 것을 이 실행에 넣을 때만 --accept-changes로 기준점을 옮긴다
  status                                                현재 노드·이력·다음 행동을 보인다
  watch                                                 실행의 노드 전환·도구 호출을 따라 본다. 호출 때의 최근 실행을 계속 보고, 끝나도 대기한다 (Ctrl+C)

  워크플로: feature(기능 개발, 기본) · bug-fix(버그 수정) · review(변경 검토) · polish(기존 화면 품질 개선). start의 --request는 각각 기능 요청·버그 보고·검토 대상(PR, 브랜치, diff)·다듬을 화면이다.
  공통: [--run <id>] (기본: 이 저장소의 최근 실행, --workflow가 있으면 그 워크플로의 최근 실행) [--repo <dir>] [--runtime codex|claude]

  정책: HM_APPROVAL_REPOS(저장소별) > HM_APPROVAL(human|auto, 기본 human)과 git_policy(pr-only|direct|그 밖 — 예전 merge는 pr-only로 읽는다),
        merge_policy(기준 브랜치·배포·스모크 명령 같은 저장소 사실)를 start 때 읽는다.
  자동화 단계: ~/.ai-harness/config의 HM_DELIVERY_LEVEL·HM_DELIVERY_LEVEL_REPOS(pr|merge|deploy)만 병합 여부를 정한다. 없으면 PR까지다.

exit: 0 done(push했으면 원격 CI 통과까지, 단계 merge·deploy면 병합 후 검증까지. polish는 규칙 문서가 없어 고칠 목록까지만 낸 fix_list 포함) · 10 승인 대기 · 20 사람 판단 필요(원격 CI·화면 미검증, 병합 막힘·병합 후 검증 실패 포함) · 30 미완료(원격 CI 진행 중·병합 조건 대기·배포 미관측이면 resume) · 40 불변식 위반 · 2 사용법
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
MONITOR_ERROR=""
INVESTIGATION_FILE=""
ACCEPT_CHANGES=""
SELECT=""
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || usage; REPO="$2"; shift 2 ;;
    --run) [[ $# -ge 2 ]] || usage; RUN_ID="$2"; shift 2 ;;
    --runtime) [[ $# -ge 2 ]] || usage; RUNTIME="$2"; shift 2 ;;
    --workflow) [[ $# -ge 2 ]] || usage; WORKFLOW="$2"; shift 2 ;;
    --request) [[ $# -ge 2 ]] || usage; REQUEST="$2"; shift 2 ;;
    --request-file) [[ $# -ge 2 && -f "$2" ]] || usage; REQUEST="$(<"$2")"; shift 2 ;;
    --feedback) [[ $# -ge 2 ]] || usage; FEEDBACK="$2"; shift 2 ;;
    --accept-changes) ACCEPT_CHANGES=1; shift ;;
    --select) [[ $# -ge 2 && -n "$2" ]] || usage; SELECT="$2"; shift 2 ;;
    --check) [[ $# -ge 2 ]] || usage; CLI_CHECKS+=("$2"); shift 2 ;;
    --monitor-error) [[ $# -ge 2 && -f "$2" ]] || usage; MONITOR_ERROR="$(<"$2")"; shift 2 ;;
    --investigation) [[ $# -ge 2 && -s "$2" ]] || usage; INVESTIGATION_FILE="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage ;;
  esac
done
case "$WORKFLOW" in
  ""|feature|implement-feature) WORKFLOW="${WORKFLOW:+feature}" ;;
  bug-fix|fix-bug) WORKFLOW=bug-fix ;;
  review) ;;
  polish|design-polish) WORKFLOW=polish ;;
  *) printf 'unknown workflow: %s\n' "$WORKFLOW" >&2; usage ;;
esac
# 조사 보고는 버그 수정을 시작할 때만 받는다. 다른 워크플로에는 그 보고를 대신할 노드가 없다.
[[ -z "$INVESTIGATION_FILE" || ( "$CMD" == start && "$WORKFLOW" == bug-fix ) ]] \
  || { printf -- '--investigation is an option of start --workflow bug-fix\n' >&2; exit 2; }

[[ -z "$ACCEPT_CHANGES" || "$CMD" == resume || "$CMD" == approve ]] \
  || { printf -- '--accept-changes is an option of resume and approve\n' >&2; exit 2; }

command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 2; }
REPO="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || { printf 'not a git repository: %s\n' "$REPO" >&2; exit 2; }

# 실행 상태는 저장소 밖에 둔다. 저장소 안에 쓰면 읽기 전용 노드의 지문 비교가 무의미해진다.
RUNS_DIR="${HM_FEATURE_RUNS_DIR:-$HOME/.ai-harness/runs}/$(basename "$REPO")-$(printf '%s' "$REPO" | git hash-object --stdin | cut -c1-8)"
# 프롬프트·세션 로그에 코드가 담긴다. 실행 디렉토리는 본인만 읽는다.
mkdir -p "$RUNS_DIR"
chmod 700 "$RUNS_DIR" 2>/dev/null || true
# Claude Code는 자기 설정 디렉터리(~/.claude, CLAUDE_CONFIG_DIR) 안의 파일을 무인 세션이 고치거나 읽지 못하게 막는다.
# 저장소나 실행 폴더가 그 안이면 fix 세션의 Edit·캡처 Read가 모두 거부돼 "fix changed nothing"으로 수리 횟수만 쓴다(#411).
claude_config_dir_of() { # path → stdout: 그 경로를 품은 Claude 설정 디렉터리(아니면 1)
  local p d c
  p="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  for d in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
    [[ -n "$d" ]] || continue
    c="$(cd "$d" 2>/dev/null && pwd -P)" || continue
    case "$p/" in "$c"/*) printf '%s' "$c"; return 0 ;; esac
  done
  return 1
}
refuse_claude_protected() { # runtime — claude 런타임만. codex sandbox는 이 경로를 막지 않는다.
  [[ "$1" == claude ]] || return 0
  local dir
  if dir="$(claude_config_dir_of "$REPO")"; then
    printf 'refused: the repository %s is inside the Claude Code configuration directory %s. Claude Code does not let a non-interactive session edit or read files there, so every write node would be denied and use up repair attempts. Work in a clone or worktree outside it (git worktree add <path outside %s> <branch>), or use --runtime codex\n' "$REPO" "$dir" "$dir" >&2
    exit 2
  fi
  if dir="$(claude_config_dir_of "$RUNS_DIR")"; then
    printf 'refused: the run folder %s is inside the Claude Code configuration directory %s, so sessions could not read the captures and notes saved there. Set HM_FEATURE_RUNS_DIR to a folder outside it, or use --runtime codex\n' "$RUNS_DIR" "$dir" >&2
    exit 2
  fi
}
# claude 세션이 권한에 막힌 도구 호출(result의 permission_denials). 모델이 못 한 것이 아니라 환경이 막은 것이다.
session_denials() { # label → stdout: "Edit a.css, Read b.png" (없으면 빈 문자열)
  [[ -s "$RUN/$1.json" ]] || return 0
  jq -rs --arg repo "$REPO/" '[.[] | (.permission_denials // [])[] | "\(.tool_name) \(.tool_input.file_path // .tool_input.path // .tool_input.command // "" | tostring | ltrimstr($repo) | .[-120:])"]
    | unique | .[:5] | join(", ")' "$RUN/$1.json" 2>/dev/null || true
}
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
  polish) GRAPH_NAME=design-polish-graph.json TEMPLATE=design-polish BRIEF_TITLE="Polish fix list" UI_UNVERIFIED="screens unmeasured" ;;
esac
# 고칠 항목 선택은 polish의 고칠 목록에만 있다.
[[ -z "$SELECT" || ( "$CMD" == revise && "$WORKFLOW" == polish ) ]] \
  || { printf -- '--select is an option of revise --workflow polish\n' >&2; exit 2; }

# 프로젝트 그래프가 계약이다. 없으면 이 스크립트 옆(설치본) 또는 저장소 템플릿 배치(templates/<워크플로>/references)의 원본을 쓴다.
GRAPH="$REPO/.ai-harness/workflows/$GRAPH_NAME"
[[ -f "$GRAPH" ]] || GRAPH="$SCRIPT_DIR/$GRAPH_NAME"
[[ -f "$GRAPH" ]] || GRAPH="$SCRIPT_DIR/../$TEMPLATE/references/$GRAPH_NAME"
jq -e '.entry and .nodes and .transitions and .terminals' "$GRAPH" >/dev/null 2>&1 || { printf 'invalid graph: %s\n' "$GRAPH" >&2; exit 2; }
MAX_REPAIR="$(jq -r '.limits.max_repair_attempts // 10' "$GRAPH")"

finish() { # status exit_code message
  local message="$3"
  # 시작 때 남긴 설정 안내(더 이상 쓰지 않는 저장소 병합 설정 등)는 실행 결과에도 붙인다.
  [[ "$2" != 0 && "$2" != 20 ]] || message+="$(state '(.policy.notices // []) | map("; notice: " + .) | join("")')"
  state_set '.status = $s | .message = $m | .finished_at = $t' --arg s "$1" --arg m "$message" --arg t "$(now_utc)"
  log "$1: $message"
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

# 상태에 남긴 트리(measured_tree·reviewed_tree)와 지금 작업 트리가 같은가. 측정·검토 뒤 바뀐 파일을 거부하는 공용 게이트다.
tree_unchanged_since() { # state-key
  local saved
  saved="$(state ".$1 // \"\"")"
  [[ -n "$saved" && "$(worktree_tree)" == "$saved" ]]
}
changed_since() { # state-key → 바뀐 경로를 ", "로 이어서
  local saved
  saved="$(state ".$1 // \"\"")"
  [[ -n "$saved" ]] || { printf 'no %s was recorded' "$1"; return; }
  git -C "$REPO" diff --name-only "$saved" "$(worktree_tree)" | head -n 20 | paste -sd ',' - | sed 's/,/, /g'
}

# git_policy가 커밋을 허용하면 쓰기 노드 뒤 로컬 커밋을 남긴다. worktree가 사라져도 사이클 단위로 남는다. push는 하지 않는다.
checkpoint() { # node
  [[ "$(state '.policy.commits // false')" == true ]] || return 0
  [[ -n "$(git -C "$REPO" status --porcelain --untracked-files=all)" ]] || return 0
  { git -C "$REPO" add -A && git -C "$REPO" commit -q -m "wip($TEMPLATE): $1 · run $RUN_ID"; } >"$RUN/checkpoint.log" 2>&1 \
    || finish incomplete 30 "checkpoint commit after $1 failed; see $RUN/checkpoint.log. Fix the cause and run resume"
  state_set '.head = $h | .checkpoints += [$h]' --arg h "$(git -C "$REPO" rev-parse HEAD)"
  save_baseline
  log "checkpoint commit after $1: $(git -C "$REPO" rev-parse --short HEAD)"
}

# 기준점: 러너가 마지막으로 본 저장소 상태(HEAD·작업 트리 지문, 차이를 보일 트리 객체). 러너가 멈출 때(종료 trap)와
# 러너 자신이 HEAD를 옮길 때(체크포인트·publish) 남긴다. 그 뒤의 변경은 러너가 모르는 변경이다.
save_baseline() {
  state_set '.repo_baseline = {head: $h, fingerprint: $f, tree: $tr, at: $t}' --arg h "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf none)" \
    --arg f "$(fingerprint)" --arg tr "$(worktree_tree 2>/dev/null || true)" --arg t "$(now_utc)"
}

# 이어 가기 전에 기준점과 지금을 대조한다. 같으면 그대로, 다르면 에이전트를 부르기 전에 차이·남은 검사를 보이고 멈춘다.
# 기준점이 없는 이전 버전의 실행은 HEAD만 대조한다. --accept-changes는 진행 중인 실행의 기준점만 옮긴다 — 끝난 실행의 성공은 바뀐 코드를 검사한 것이 아니다.
check_baseline() {
  local saved_head saved_fp saved_tree head node report tree
  saved_head="$(state '.repo_baseline.head // .head // .start_head')"
  saved_fp="$(state '.repo_baseline.fingerprint // ""')"
  saved_tree="$(state '.repo_baseline.tree // ""')"
  head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf none)"
  [[ "$head" != "$saved_head" || ( -n "$saved_fp" && "$(fingerprint)" != "$saved_fp" ) ]] || return 0
  node="$(state .node)"
  report="$RUN/baseline-changes.txt"
  {
    printf 'saved baseline: HEAD %s at %s\n' "$saved_head" "$(state '.repo_baseline.at // "an older run (HEAD only)"')"
    if [[ "$head" != "$saved_head" ]]; then
      printf 'HEAD is now %s\n' "$head"
      if git -C "$REPO" cat-file -e "$saved_head^{commit}" 2>/dev/null; then
        printf 'commits since the baseline:\n'
        git -C "$REPO" log --oneline -n 20 "$saved_head..HEAD" 2>/dev/null | sed 's/^/  + /'
        git -C "$REPO" log --oneline -n 20 "HEAD..$saved_head" 2>/dev/null | sed 's/^/  - /'
      fi
    fi
    printf 'changed files since the baseline:\n'
    tree="$(worktree_tree 2>/dev/null || true)"
    if [[ -n "$saved_tree" && -n "$tree" ]] && git -C "$REPO" cat-file -e "$saved_tree^{tree}" 2>/dev/null; then
      git -C "$REPO" diff --name-status "$saved_tree" "$tree" | sed 's/^/  /'
    else
      git -C "$REPO" status --short --untracked-files=all | sed 's/^/  /'
    fi
    printf 'remaining: node %s · checks: %s\n' "$node" "$(state '(.checks // []) | if length == 0 then "(decided by the brief)" else join(" ; ") end')"
  } >"$report"
  while IFS= read -r line; do log "$line"; done <"$report"
  if jq -e --arg n "$node" '.terminals | index($n)' "$GRAPH" >/dev/null; then
    finish baseline_changed 20 "the repository changed after the run ended at $node, so its result no longer covers the code; undo the change and resume, or start a new run to check it (see $report)"
  fi
  # 리뷰를 지난 변경만 push·병합된다. 그 뒤에 받아들인 변경은 검증·리뷰를 다시 거치지 않으므로 새 실행으로 보낸다.
  case "$node" in
    publish|remote_ci|merge|post_merge_verify)
      finish baseline_changed 20 "the repository changed after the runner stopped at $node, past review; the change would skip verify and review. Undo it and resume, or start a new run for it (see $report)" ;;
  esac
  if [[ -z "$ACCEPT_CHANGES" ]]; then
    # 상태가 running이면 러너가 기준점을 남기지 못하고 끊긴 것이다(강제 종료). 바뀐 것은 러너 자신의 하다 만 작업일 수 있다.
    if [[ "$(state .status)" == running ]]; then
      finish baseline_changed 20 "the runner was cut off at $node without recording where it stopped, so these changes may be its own unfinished work; nothing ran. If they are, take them in with resume --accept-changes; otherwise undo them and resume (see $report)"
    fi
    finish baseline_changed 20 "the repository changed after the runner stopped at $node; nothing ran. Undo the change and resume, or take it into this run with resume --accept-changes (see $report)"
  fi
  state_set '.head = $h | .baseline_accepted += [{from: (.repo_baseline.head // .head), to: $h, at: $t}]' --arg h "$head" --arg t "$(now_utc)"
  save_baseline
  log "accepted the changes since the baseline (--accept-changes); continuing at $node"
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
      # 측정 증거(캡처·채점 보고)를 읽어 판정하는 읽기 노드(reads_run). 읽기 도구만 있고, 측정 디렉터리만 연다 —
      # 수정 쪽 요약(fix-N.out)·이전 판정·state.json을 보지 않아야 독립 판정이다.
      if [[ "$writable" != true && "$commands" != true && "$(jq -r --arg n "$node" '.nodes[$n].reads_run // false' "$GRAPH")" == true ]]; then
        local ev
        while IFS= read -r ev; do
          [[ -n "$ev" && -d "$ev" ]] && args+=(--add-dir "$ev")
        done <<<"$(state '(.measurements // [])[].evidence_dir')"
      fi
      # 답할 사람이 없는 세션이다. 보드 권한 훅이 이 세션의 권한 요청을 보드로 넘겨 붙잡지 않게 표시한다(없으면 바로 거부된다).
      (cd "$REPO" && AI_HARNESS_HEADLESS=1 claude "${args[@]}" <"$RUN/$label.prompt") 2>"$RUN/$label.log" | stream_progress "$label" >"$RUN/$label.json" || rc=$?
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
      printf '\n== 정책 승인 (HM_APPROVAL=auto) ==\n수리 범위는 %s에 남는다. 수리는 커밋하지 않고 작업 트리에 남긴다.\n' "$RUN/brief.md"
    # direct는 PR 없이 push까지 가므로 "병합 전에 뒤집는다"가 성립하지 않는다.
    elif [[ "$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)" == direct ]]; then
      printf '\n== 정책 승인 (HM_APPROVAL=auto) ==\nBrief와 결정 사항은 %s와 마지막 커밋 메시지에 남는다. git_policy direct라 PR 없이 push되므로, 결정을 뒤집으려면 이후 커밋으로 되돌린다.\n' "$RUN/brief.md"
    else
      printf '\n== 정책 승인 (HM_APPROVAL=auto) ==\nBrief와 결정 사항은 %s에 남고 PR 본문에 들어간다. 사람은 병합 전에 PR에서 결정을 뒤집을 수 있다.\n' "$RUN/brief.md"
    fi
    return
  fi
  if [[ "$WORKFLOW" == review ]]; then
    cat <<EOF

== 다음 ==
수리: 대화에 "승인"이라고 입력한 뒤 resume (터미널이면 approve). 위 finding을 고치고 검증·재검토까지 이어 간다
수리하지 않으면 여기서 끝난다: 위 finding이 검토 결과다
EOF
    workspace_hint
    return
  fi
  if [[ "$WORKFLOW" == polish ]]; then
    cat <<EOF

== 다음 ==
승인: 표에서 [x]로 고른 항목을 고친다. 대화에 "승인"이라고 입력한 뒤 resume (터미널이면 approve)
고를 항목 바꾸기: revise --select "P1,P3" (모델을 부르지 않는다. 바꾼 목록을 다시 보여 주고 승인을 기다린다)
다시 진단: 빠진 문제나 틀린 판단을 말하면 revise --feedback "<바꿀 점>"으로 고칠 목록을 다시 만든다
EOF
    workspace_hint
    return
  fi
  cat <<EOF

== 다음 ==
승인: 대화에 "승인"이라고 입력한 뒤 resume (터미널이면 approve)
수정: 바꿀 점을 말하면 revise --feedback "<바꿀 점>"으로 Brief를 다시 만든다
EOF
  workspace_hint
}

# workspace가 인계한 실행이면 멤버 세션 터미널에서 기다리지 말고 조율 세션에 물어 사용자가 workspace 대화에서 답하게 한다(#331).
workspace_hint() {
  local ws
  ws="$(workspace_root)"
  [[ -n "$ws" ]] || return 0
  printf 'workspace 인계: 이 Brief(%s)를 조율 세션에 보내고(SendMessage 등) 답을 기다린다. 사용자가 workspace 대화에 "승인 %s"를 입력하면 resume, 바꿀 점을 주면 revise --feedback\n' "$RUN/brief.md" "${REPO##*/}"
}

# 저장소를 담은 workspace(위로 올라가 .ai-harness/workspace.json이 있는 폴더). 없으면 빈 값.
workspace_root() {
  local d="${REPO%/*}"
  while [[ -n "$d" && "$d" != / ]]; do
    [[ -f "$d/.ai-harness/workspace.json" ]] && { printf '%s' "$d"; return; }
    d="${d%/*}"
  done
}

# 사용자가 직접 입력한 메시지만 본다: Claude는 type=user의 문자열 content(isMeta 제외, origin이 있으면 human만), Codex는 event_msg user_message.
# 도구 결과·모델 메시지·드라이버가 띄운 세션의 프롬프트·다른 세션이 보낸 메시지는 걸리지 않는다.
# workspace가 인계한 멤버 실행이면 사용자가 workspace 대화에서 멤버 이름을 붙여 친 "승인 <멤버>"도 받는다 —
# 이름이 없으면 여러 멤버가 기다릴 때 어느 Brief를 승인했는지 알 수 없다. (#331)
transcript_approval() {
  local since="$1" marker="$RUN/brief.json" f cwd ws name ws_re
  local re='^[[:space:]]*(승인|approve|approved)([[:space:][:punct:]]|$)'
  # 끝의 / 는 심볼릭 링크 폴더(Orca 프로필의 projects → ~/.claude/projects) 안으로 find 가 들어가게 한다.
  local claude_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" codex_root="${CODEX_HOME:-$HOME/.codex}/sessions"
  ws="$(workspace_root)"
  name="$(printf '%s' "${REPO##*/}" | tr '[:upper:]' '[:lower:]' | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  ws_re="^[[:space:]]*(승인|approve|approved)[[:space:]]+${name}([[:space:][:punct:]]|$)"
  if [[ -d "$claude_root" ]]; then
    while IFS= read -r -d '' f; do
      jq -c --arg repo "$REPO" --arg ws "$ws" --arg since "$since" --arg re "$re" --arg wsre "$ws_re" '
        select(.type == "user" and (.isMeta | not) and ((.message.content | type) == "string")
          and ((.origin.kind // "human") == "human")
          and ((.timestamp // "")[:19] > $since)
          and ((.cwd // "") as $c
            | (($c == $repo or ($c | startswith($repo + "/")) or ("/private" + $c) == $repo)
                and (.message.content | ascii_downcase | test($re)))
              or ($ws != "" and ($c == $ws or ("/private" + $c) == $ws)
                and (.message.content | ascii_downcase | test($wsre)))))
        | {source:"claude-transcript", at:.timestamp, text:(.message.content[:200])}' "$f" 2>/dev/null | head -n 1
    done < <(find "$claude_root/" -name '*.jsonl' -newer "$marker" -print0 2>/dev/null)
  fi
  if [[ -d "$codex_root" ]]; then
    while IFS= read -r -d '' f; do
      cwd="$(jq -r 'select(.type == "session_meta") | .payload.cwd // empty' "$f" 2>/dev/null | head -n 1)"
      if [[ "$cwd" == "$REPO" || "$cwd" == "$REPO"/* || "/private$cwd" == "$REPO" ]]; then :
      elif [[ -n "$ws" && ( "$cwd" == "$ws" || "/private$cwd" == "$ws" ) ]]; then cwd=workspace
      else continue; fi
      jq -c --arg since "$since" --arg re "$([[ "$cwd" == workspace ]] && printf '%s' "$ws_re" || printf '%s' "$re")" '
        select(.type == "event_msg" and .payload.type == "user_message"
          and ((.timestamp // "")[:19] > $since)
          and (.payload.message | ascii_downcase | test($re)))
        | {source:"codex-transcript", at:.timestamp, text:(.payload.message[:200])}' "$f" 2>/dev/null | head -n 1
    done < <(find "$codex_root/" -name '*.jsonl' -newer "$marker" -print0 2>/dev/null)
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
# 다시 검토해 범위 밖의 새 finding이 나오면 그 finding을 보여 주고 다시 동의를 받는다. HM_APPROVAL=auto면 정책이 동의한다.
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
  # 검토한 트리와 지금 트리가 다르면 검토 뒤에 누군가 파일을 바꾼 것이다. 그 변경은 측정·검토를 받지 않았으므로
  # 내보내지 않고 검사부터 다시 한다(verify → measure → review, 그 전이를 선언한 그래프만 — 다른 그래프는 아래 커밋 트리 비교가 같은 보장을 한다).
  if has_edge publish changed_after_review && ! tree_unchanged_since reviewed_tree; then
    state_set '.findings = ["files changed after the review: " + $f] | .changed_after_review = ($f | split(", "))' --arg f "$(changed_since reviewed_tree)"
    log "refused: files changed after the review ($(changed_since reviewed_tree)); checking, measuring, and reviewing again"
    go publish changed_after_review
    return
  fi
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
  tree_unchanged_since reviewed_tree \
    || problems="$(jq -c '. + ["the committed tree differs from the reviewed tree"]' <<<"$problems")"
  if [[ "$(state .start_head)" != none ]] && ! git -C "$REPO" merge-base --is-ancestor "$(state .start_head)" HEAD 2>/dev/null; then
    problems="$(jq -c '. + ["history before the run was rewritten"]' <<<"$problems")"
  fi
  [[ "$(git -C "$REPO" rev-parse '@{upstream}' 2>/dev/null || true)" == "$(git -C "$REPO" rev-parse HEAD)" ]] \
    || problems="$(jq -c '. + ["HEAD is not pushed to its upstream"]' <<<"$problems")"
  [[ "$policy" == direct || -n "$pr_url" ]] \
    || problems="$(jq -c --arg g "$policy" '. + ["git_policy \($g) requires a pull request, but pr_url is empty"]' <<<"$problems")"
  state_set '.head = $h | .publish = {pr_url: $u, branch: $b, problems: $p, pushed_at: $t}' --arg t "$(now_utc)" \
    --arg h "$(git -C "$REPO" rev-parse HEAD)" --arg u "$pr_url" \
    --arg b "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" --argjson p "$problems"
  save_baseline
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
  if [[ "$status" == none ]] && repo_has_ci_config; then
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
# 출력: {state: OPEN|MERGED|CLOSED, draft, head, head_ref, base, mergeable: true|false|"pending", ci: passed|failed|pending|none,
#        approvals: [로그인], changes_requested, merge_commit, merged_at}
pr_provider() { # url
  if [[ "$1" =~ ^https://bitbucket\.org/[^/]+/[^/]+/pull-requests/[0-9]+ ]]; then echo bitbucket
  elif [[ "$1" =~ ^https://[^/]+/[^/]+/[^/]+/pull/[0-9]+ ]]; then echo github
  else echo unknown; fi
}
# host/owner/repo (소문자). PR이 이 저장소(origin)의 것인지 비교한다. insteadOf로 바뀌기 전의 설정값을 본다.
repo_slug() { # url
  sed -E 's#^[a-z+]+://##; s#^[^@/]+@##; s#:([^0-9/][^/]*/)#/\1#; s#\.git/?$##; s#/(pull|pull-requests)/[0-9]+.*$##' <<<"$1" | tr '[:upper:]' '[:lower:]'
}
bb_api() { # method path [json-body]
  [[ -n "${ATLASSIAN_USER:-}" && -n "${BITBUCKET_API_TOKEN:-}" ]] || { echo "ATLASSIAN_USER and BITBUCKET_API_TOKEN are not set" >&2; return 1; }
  local args=(-sS --fail --max-time 60 -K - -X "$1" "https://api.bitbucket.org/2.0/repositories/$2")
  [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$3")
  # 자격증명은 ps에 보이는 인자 대신 stdin 설정으로 넘긴다. 설정 문법의 \ 와 " 는 이스케이프한다.
  local user="${ATLASSIAN_USER//\\/\\\\}" token="${BITBUCKET_API_TOKEN//\\/\\\\}"
  printf 'user = "%s:%s"\n' "${user//\"/\\\"}" "${token//\"/\\\"}" | (cd "$REPO" && curl "${args[@]}")
}
bb_path() { # url → workspace/repo/pullrequests/<id>
  sed -E 's#^https://bitbucket\.org/([^/]+)/([^/]+)/pull-requests/([0-9]+).*#\1/\2/pullrequests/\3#' <<<"$1"
}
pr_facts() { # url
  local pr diff statuses
  case "$(pr_provider "$1")" in
    github)
      # 승인은 쓰기 권한이 있는 사람(OWNER·MEMBER·COLLABORATOR)이 지금 head에 남긴 것만, 작성자·봇은 빼고, 리뷰어마다 마지막 판단만 센다.
      (cd "$REPO" && gh pr view "$1" --json state,isDraft,mergeable,headRefOid,headRefName,baseRefName,reviews,author,mergeCommit,mergedAt,statusCheckRollup) | jq -c '
        .author.login as $author | .headRefOid as $head
        | ([.reviews[] | select(.author.login != $author and (.author.login | endswith("[bot]") | not)
              and (.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED")))]
            | group_by(.author.login) | map(max_by(.submittedAt))) as $latest
        | [.statusCheckRollup[]? | if .__typename == "StatusContext" then (.state // "")
            else (if (.status // "") != "COMPLETED" then "PENDING" else (.conclusion // "") end) end] as $checks
        | {state, draft: .isDraft, head: $head, head_ref: .headRefName, base: .baseRefName,
           mergeable: (if .mergeable == "MERGEABLE" then true elif .mergeable == "CONFLICTING" then false else "pending" end),
           ci: (if ($checks | length) == 0 then "none"
                elif any($checks[]; IN("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE")) then "failed"
                elif any($checks[]; IN("PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "")) then "pending" else "passed" end),
           approvals: [$latest[] | select(.state == "APPROVED" and .commit.oid == $head
             and (.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR"))) | .author.login],
           changes_requested: any($latest[]; .state == "CHANGES_REQUESTED"),
           merge_commit: (.mergeCommit.oid // ""), merged_at: (.mergedAt // "")}' ;;
    bitbucket)
      # Bitbucket 승인은 커밋에 묶이지 않는다. 마지막 push 뒤에 참여(participated_on)한 승인만 센다.
      pr="$(bb_api GET "$(bb_path "$1")")" || return 1
      diff="$(bb_api GET "$(bb_path "$1")/diffstat?pagelen=500")" || return 1
      statuses="$(bb_api GET "$(sed -E 's#/pullrequests/[0-9]+$##' <<<"$(bb_path "$1")")/commit/$(jq -r .source.commit.hash <<<"$pr")/statuses?pagelen=100")" || return 1
      jq -c --argjson d "$diff" --argjson s "$statuses" --arg pushed "$(state '.publish.pushed_at // ""')" '
        .author.uuid as $author
        | [$s.values[]?.state] as $checks
        | {state: (if .state == "OPEN" or .state == "MERGED" then .state else "CLOSED" end), draft: (.draft // false),
           head: .source.commit.hash, head_ref: .source.branch.name, base: .destination.branch.name,
           mergeable: (if any($d.values[]?; .status == "merge conflict") then false else true end),
           ci: (if ($checks | length) == 0 then "none" elif any($checks[]; IN("FAILED", "STOPPED")) then "failed"
                elif any($checks[]; . == "INPROGRESS") then "pending" else "passed" end),
           approvals: [.participants[]? | select(.approved and .user.uuid != $author and ((.participated_on // "") > $pushed))
             | (.user.nickname // .user.display_name)],
           changes_requested: any(.participants[]?; .state == "changes_requested"),
           merge_commit: (.merge_commit.hash // ""), merged_at: (if .state == "MERGED" then .updated_on else "" end)}' <<<"$pr" ;;
    *) echo "unsupported pull request host: $1" >&2; return 1 ;;
  esac
}
pr_merge() { # url method head
  case "$(pr_provider "$1")" in
    github) (cd "$REPO" && gh pr merge "$1" "--$2" --match-head-commit "$3") ;;
    bitbucket)
      # Bitbucket merge API는 head를 고정할 수 없다. 판정 직전에 head를 다시 읽었다. 전략을 넘기지 않아 저장소 기본 전략으로 병합한다.
      bb_api POST "$(bb_path "$1")/merge" '{"close_source_branch": false}' >/dev/null ;;
  esac
}
# 저장소가 정한 병합 방식. GitHub는 기본 방식이 없어 저장소가 허용한 방식 중 squash → merge → rebase 순으로 고른다.
# Bitbucket은 전략을 넘기지 않으면 저장소 기본 전략을 쓴다. 허용 방식을 읽지 못하면 실패(stderr에 이유)한다.
merge_method() { # pr-url
  local slug out
  case "$(pr_provider "$1")" in
    github)
      slug="$(repo_slug "$1")"
      out="$(cd "$REPO" && gh api "repos/${slug#*/}" 2>&1)" || { printf '%s\n' "$(head -c 200 <<<"$out")" >&2; return 1; }
      jq -re 'if .allow_squash_merge == true then "squash" elif .allow_merge_commit == true then "merge"
        elif .allow_rebase_merge == true then "rebase" else empty end' <<<"$out" \
        || { echo "the repository settings do not say which merge methods are allowed" >&2; return 1; } ;;
    bitbucket) echo "repository default" ;;
    *) echo "unsupported pull request host: $1" >&2; return 1 ;;
  esac
}
iso_epoch() { jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // empty'; }

# 기준 브랜치의 호스트 보호 규칙: {approvals: 필수 승인 수, checks: 필수 체크 수}. 개인 자동화 단계의 병합 안전장치다.
# 출처 하나라도 필수 승인을 보이면 그것으로 판정한다. 필수 승인이 0인데 읽지 못한 출처가 있으면 실패(stderr에 이유)한다.
branch_protection() { # pr-url base
  local slug ws_repo out model="" a c approvals=0 checks=0 unreadable="" kind value match pattern btype applies
  case "$(pr_provider "$1")" in
    github)
      slug="$(repo_slug "$1")"
      slug="${slug#*/}"
      # 규칙 세트(rulesets)는 읽기 권한으로 보인다. 예전 branch protection은 관리자만 읽을 수 있어 실패할 수 있다.
      if out="$(cd "$REPO" && gh api "repos/$slug/rules/branches/$2" 2>"$RUN/protection.err")"; then
        read -r a c <<<"$(jq -r '[([.[]? | select(.type == "pull_request") | .parameters.required_approving_review_count // 0] | max // 0),
          ([.[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?] | length)] | @tsv' <<<"$out")"
        approvals="$a" checks="$c"
      else
        unreadable="rulesets: $(head -c 200 "$RUN/protection.err")"
      fi
      if out="$(cd "$REPO" && gh api "repos/$slug/branches/$2/protection" 2>"$RUN/protection.err")"; then
        read -r a c <<<"$(jq -r '[(.required_pull_request_reviews.required_approving_review_count // 0),
          ((.required_status_checks.checks // .required_status_checks.contexts // []) | length)] | @tsv' <<<"$out")"
        ((a <= approvals)) || approvals="$a"
        ((c <= checks)) || checks="$c"
      elif ! grep -q 'Branch not protected' "$RUN/protection.err"; then
        unreadable="${unreadable:+$unreadable; }branch protection: $(head -c 200 "$RUN/protection.err")"
      fi ;;
    bitbucket)
      ws_repo="$(sed -E 's#^https://bitbucket\.org/([^/]+)/([^/]+)/.*#\1/\2#' <<<"$1")"
      # branch restrictions는 저장소 관리자 권한이 있어야 읽힌다. 못 읽으면 병합하지 않는다.
      out="$(bb_api GET "$ws_repo/branch-restrictions?pagelen=100" 2>"$RUN/protection.err")" \
        || { printf 'branch restrictions: %s\n' "$(head -c 200 "$RUN/protection.err")" >&2; return 1; }
      if jq -e 'any(.values[]?; .branch_match_kind == "branching_model")' <<<"$out" >/dev/null; then
        model="$(bb_api GET "$ws_repo/branching-model" 2>"$RUN/protection.err")" \
          || unreadable="branching model: $(head -c 200 "$RUN/protection.err")"
      fi
      while IFS=$'\x1f' read -r kind value match pattern btype; do
        applies=""
        if [[ "$match" == glob ]]; then
          # shellcheck disable=SC2053  # pattern은 Bitbucket glob이다
          [[ "$2" == $pattern ]] && applies=1
        elif [[ "$match" == branching_model && -n "$model" ]]; then
          [[ "$(jq -r --arg t "$btype" 'if $t == "development" then .development.branch.name // ""
            elif $t == "production" and .production.enabled != false then .production.branch.name // "" else "" end' <<<"$model")" == "$2" ]] && applies=1
        fi
        [[ -n "$applies" ]] || continue
        case "$kind" in
          require_passing_builds_to_merge) ((value <= checks)) || checks="$value" ;;
          *) ((value <= approvals)) || approvals="$value" ;;
        esac
      done < <(jq -r '.values[]? | select(.kind | IN("require_approvals_to_merge", "require_default_reviewer_approvals_to_merge", "require_passing_builds_to_merge"))
        | [.kind, (.value // 0 | tostring), (.branch_match_kind // "glob"), (.pattern // ""), (.branch_type // "")] | join("\u001f")' <<<"$out") ;;
    *) echo "unsupported pull request host: $1" >&2; return 1 ;;
  esac
  if ((approvals == 0)) && [[ -n "$unreadable" ]]; then
    printf '%s\n' "$unreadable" >&2
    return 1
  fi
  jq -cn --argjson a "$approvals" --argjson c "$checks" '{approvals: $a, checks: $c}'
}

# merge: 저장소 호스트 규칙(기준 브랜치 보호)과 PR 상태를 호스트에서 직접 읽어 판정하고, 모두 맞을 때만 head를 고정해 저장소의 방식으로 병합한다.
merge() {
  local url head facts blocked="[]" unmet="[]" mp err origin method="" i merged_epoch protection
  url="$(state '.publish.pr_url // ""')"
  head="$(state .head)"
  mp="$(jq -c '.policy.merge' "$STATE")"
  [[ "$(state '.policy.git')" == merge && "$mp" != null && "$(state '.policy.unattended // false')" != true ]] \
    || finish invariant_violation 40 "merge node reached although the run has no merge delivery level or is unattended"
  if ! facts="$(pr_facts "$url" 2>"$RUN/merge.err")" || [[ -z "$facts" ]]; then
    err="$(head -c 300 "$RUN/merge.err")"
    state_set '.findings = [$m] | .merge = {blocked: [$m]}' --arg m "cannot read the pull request state from its host: ${err:-no output}"
    go merge merge_blocked
    return
  fi
  printf '%s\n' "$facts" >"$RUN/merge-facts.json"
  # 병합할 PR은 publish가 보고한 URL이다. 이 저장소·이 실행이 push한 브랜치·시작 때 정한 기준 브랜치의 PR인지 확인한다.
  origin="$(git -C "$REPO" config --get remote.origin.url || true)"
  [[ -n "$origin" && "$(repo_slug "$origin")" == "$(repo_slug "$url")" ]] \
    || blocked="$(jq -c --arg u "$url" --arg o "${origin:-none}" '. + ["the pull request \($u) is not in this repository (origin \($o))"]' <<<"$blocked")"
  [[ "$(jq -r .base <<<"$facts")" == "$(jq -r .base <<<"$mp")" ]] \
    || blocked="$(jq -c --argjson f "$facts" --arg b "$(jq -r .base <<<"$mp")" '. + ["the pull request targets \($f.base), not the base branch \($b) the merge policy allows"]' <<<"$blocked")"
  [[ "$(jq -r .head_ref <<<"$facts")" == "$(state '.publish.branch // ""')" ]] \
    || blocked="$(jq -c --argjson f "$facts" --arg b "$(state '.publish.branch // ""')" '. + ["the pull request comes from \($f.head_ref), not the pushed branch \($b)"]' <<<"$blocked")"
  if [[ "$blocked" == "[]" ]]; then
    case "$(jq -r .state <<<"$facts")" in
      MERGED)
        # 사람이 먼저 병합했거나, 지난 시도의 병합이 늦게 반영됐다. 병합 후 검증은 그 병합 커밋으로 이어 간다.
        merged_epoch="$(iso_epoch "$(jq -r .merged_at <<<"$facts")")"
        [[ -n "$(jq -r .merge_commit <<<"$facts")" ]] \
          || finish incomplete 30 "the pull request is merged but the host has not reported the merge commit yet; run resume to check again"
        state_set '.merge = {commit: $f.merge_commit, base: $f.base, method: (if .merge.requested then (.merge.method // "by the runner") else "outside the runner" end),
            approvals: (.merge.approvals // []), merged_at: $f.merged_at, merged_epoch: ($e | tonumber)}' \
          --argjson f "$facts" --arg e "${merged_epoch:-$(date -u +%s)}"
        log "the pull request is merged: $(jq -r .merge_commit <<<"$facts")"
        go merge merged
        return ;;
      CLOSED) blocked='["the pull request was closed without merging"]' ;;
    esac
  fi
  # 병합 조건은 저장소 호스트 규칙이다. 기준 브랜치 보호의 필수 승인 수·필수 체크를 조건으로 쓰고(보호가 없으면 승인 없이 병합),
  # 호스트가 강제하지 않아도 러너가 직접 판정한다. 규칙을 읽지 못하면 모르는 채로 병합하지 않는다. 방식은 저장소 설정을 따른다.
  # 이전 버전이 시작 때 정한 require·min_approvals·method(개인 HM_MERGE_* 또는 기본값)는 resume에서도 쓰지 않는다.
  if [[ "$blocked" == "[]" ]]; then
    if ! protection="$(branch_protection "$url" "$(jq -r .base <<<"$mp")" 2>"$RUN/protection.why")"; then
      blocked="$(jq -c --arg b "$(jq -r .base <<<"$mp")" --arg e "$(head -c 300 "$RUN/protection.why")" \
        '. + ["cannot read the branch protection of \($b) from the host (\($e)); the runner merges only by the rules the repository sets — merge by hand or let the runner read the protection"]' <<<"$blocked")"
    elif ! method="$(merge_method "$url" 2>"$RUN/method.why")"; then
      blocked="$(jq -c --arg e "$(head -c 300 "$RUN/method.why")" \
        '. + ["cannot read which merge methods the repository allows (\($e)); merge by hand"]' <<<"$blocked")"
    else
      state_set '.protection = ($p + {base: $b, checked_at: $t})' --argjson p "$protection" --arg b "$(jq -r .base <<<"$mp")" --arg t "$(now_utc)"
      mp="$(jq -c --argjson p "$protection" '.min_approvals = $p.approvals
        | .require = ([if $p.approvals > 0 then "human_approval" else empty end, if $p.checks > 0 then "remote_ci" else empty end]
            + ["no_conflict", "not_draft"])' <<<"$mp")"
    fi
  fi
  # 리뷰어의 변경 요청은 저장소 규칙과 상관없이 넘어가지 않는다.
  [[ "$(jq -r .changes_requested <<<"$facts")" != true ]] || blocked="$(jq -c '. + ["a reviewer requested changes"]' <<<"$blocked")"
  # 승인·CI는 리뷰하고 push한 그 커밋에 대한 것이어야 한다. head가 움직였으면 누군가 push했다.
  [[ ${#head} -ge 7 && "$(jq -r .head <<<"$facts")" =~ ^[0-9a-f]{7,}$ && "$head" == "$(jq -r .head <<<"$facts")"* ]] \
    || blocked="$(jq -c --arg h "$head" --arg p "$(jq -r .head <<<"$facts")" '. + ["the pull request head \($p) is not the pushed and reviewed commit \($h)"]' <<<"$blocked")"
  while IFS= read -r cond; do
    case "$cond" in
      human_approval)
        if (( $(jq '.approvals | length' <<<"$facts") < $(jq -r '.min_approvals' <<<"$mp") )); then
          unmet="$(jq -c --argjson f "$facts" --argjson n "$(jq -r .min_approvals <<<"$mp")" \
            '. + ["human approval: \($f.approvals | length) of \($n) on the current head\(if ($f.approvals | length) > 0 then " (" + ($f.approvals | join(", ")) + ")" else "" end)"]' <<<"$unmet")"
        fi ;;
      remote_ci)
        # remote_ci 노드의 보고만으로 정하지 않는다. 호스트가 그 head에 대해 보고한 체크도 통과여야 한다.
        if [[ "$(state '.remote_ci.status // ""')" != passed || "$(state '.remote_ci.head // ""')" != "$head" ]]; then
          blocked="$(jq -c --arg s "$(state '.remote_ci.status // "missing"')" '. + ["remote CI for the head is \($s), not passed"]' <<<"$blocked")"
        else
          case "$(jq -r .ci <<<"$facts")" in
            passed) ;;
            pending) unmet="$(jq -c '. + ["the host still reports checks running on the head"]' <<<"$unmet")" ;;
            *) blocked="$(jq -c --arg c "$(jq -r .ci <<<"$facts")" '. + ["the host reports the checks on the head as \($c), not passed"]' <<<"$blocked")" ;;
          esac
        fi ;;
      no_conflict)
        case "$(jq -r .mergeable <<<"$facts")" in
          false) blocked="$(jq -c '. + ["the pull request has merge conflicts with its base"]' <<<"$blocked")" ;;
          pending) unmet="$(jq -c '. + ["the host has not finished checking for conflicts"]' <<<"$unmet")" ;;
        esac ;;
      not_draft)
        [[ "$(jq -r .draft <<<"$facts")" != true ]] || unmet="$(jq -c '. + ["the pull request is a draft"]' <<<"$unmet")" ;;
    esac
  done <<<"$(jq -r '.require[]?' <<<"$mp")"
  if [[ "$blocked" != "[]" ]]; then
    state_set '.findings = $b | .merge = {blocked: $b, facts: $f}' --argjson b "$blocked" --argjson f "$facts"
    go merge merge_blocked
    return
  fi
  if [[ "$unmet" != "[]" ]]; then
    state_set '.merge = {waiting: $u, facts: $f, checked_at: $t}' --argjson u "$unmet" --argjson f "$facts" --arg t "$(now_utc)"
    finish incomplete 30 "waiting for merge conditions on $url: $(jq -r 'join("; ")' <<<"$unmet"); run resume to check again"
  fi
  if ! pr_merge "$url" "$method" "$head" >"$RUN/merge.log" 2>&1; then
    state_set '.findings = [$m] | .merge = {blocked: [$m]}' --arg m "merging failed: $(tail -c 300 "$RUN/merge.log")"
    go merge merge_blocked
    return
  fi
  state_set '.merge = {requested: true, method: $m, approvals: $a, requested_at: $t}' --argjson a "$(jq -c .approvals <<<"$facts")" --arg m "$method" --arg t "$(now_utc)"
  log "merge requested for $url ($method)"
  # 호스트가 병합(과 병합 커밋)을 보고하기까지 잠깐 걸릴 수 있다. 끝내 안 보이면 resume이 다시 읽는다.
  for i in 1 2 3 4 5; do
    facts="$(pr_facts "$url" 2>/dev/null || printf '{}')"
    [[ "$(jq -r '.state // ""' <<<"$facts")" == MERGED && -n "$(jq -r '.merge_commit // ""' <<<"$facts")" ]] && break
    ((i == 5)) || sleep "${HM_MERGE_POLL_SECONDS:-5}"
  done
  [[ "$(jq -r '.state // ""' <<<"$facts")" == MERGED && -n "$(jq -r '.merge_commit // ""' <<<"$facts")" ]] \
    || finish incomplete 30 "the merge of $url was requested but the host does not report it merged yet; run resume to check again"
  state_set '.merge = (.merge + {commit: $f.merge_commit, base: $f.base, method: $m, merged_at: $f.merged_at, merged_epoch: ($e | tonumber)})' \
    --argjson f "$facts" --arg m "$method" --arg e "$(iso_epoch "$(jq -r .merged_at <<<"$facts")" || true)"
  state_set 'if .merge.merged_epoch == null then .merge.merged_epoch = ($n | tonumber) else . end' --arg n "$(date -u +%s)"
  log "merged $url as $(jq -r .merge_commit <<<"$facts") ($method)"
  go merge merged
}

repo_has_ci_config() {
  [[ -n "$(git -C "$REPO" ls-files -- .github/workflows bitbucket-pipelines.yml .gitlab-ci.yml \
    Jenkinsfile .circleci azure-pipelines.yml .buildkite .drone.yml .travis.yml 2>/dev/null)" ]]
}

# 병합 방식에 맞는 되돌리기 안내. 병합 커밋이면 부모가 둘이라 -m 1이 필요하고, rebase는 여러 커밋이 올라간다.
# 플러그인 위치: HM_PLUGIN_ROOT → 설치된 가장 새 버전(업데이트로 옛 캐시가 지워져도 따라간다) → 정기 실행이 기록한 경로.
plugin_root() {
  local dir found=""
  [[ -z "${HM_PLUGIN_ROOT:-}" ]] || { printf '%s' "$HM_PLUGIN_ROOT"; return; }
  found="$(for dir in "$HOME"/.claude/plugins/cache/ai-harness/ai-harness/*/ "$HOME"/.codex/plugins/cache/ai-harness/ai-harness/*/; do
    [[ -f "${dir}scripts/autofix-auto.sh" ]] || continue
    dir="${dir%/}"
    printf '%s\t%s\n' "${dir##*/}" "$dir"
  done | sort -t$'\t' -k1,1V | tail -n 1)"
  found="${found#*$'\t'}"
  [[ -n "$found" ]] || found="$(cat "${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/bin/plugin-root" 2>/dev/null || true)"
  printf '%s' "$found"
}

rollback_hint() { # commit base
  local parents
  git -C "$REPO" fetch -q origin "$2" >/dev/null 2>&1 || true
  parents="$(git -C "$REPO" rev-list --parents -n 1 "$1" 2>/dev/null | wc -w | tr -d ' ')"
  if [[ "$(state .merge.method)" == rebase ]]; then
    printf 'the change is merged and was not reverted. It was rebased onto %s as several commits; to roll it back, revert those commits (git revert --no-edit <first>^..%s) on a new branch and open a pull request' "$2" "$1"
  elif [[ "$parents" -gt 2 || ( -z "$parents" || "$parents" == 0 ) && "$(state .merge.method)" == merge ]]; then
    printf 'the change is merged and was not reverted. To roll it back, revert the merge commit on a new branch (git revert -m 1 %s) and open a pull request' "$1"
  else
    printf 'the change is merged and was not reverted. To roll it back, revert %s on a new branch (git revert %s) and open a pull request' "$1" "$1"
  fi
}

# post_merge_verify: 시작 때 정한 검증(policy.merge.verify)을 순서대로(타깃 CI → 배포 확인 → 스모크) 확인한다. 끝난 단계는 resume에서 다시 하지 않는다.
# 실패해도 되돌리지 않는다. 되돌릴지는 사람이 정한다.
post_merge_verify() {
  local commit base step label out status rc fail="" hint="" cmd waited timeout reported af project
  commit="$(state '.merge.commit // ""')"
  base="$(state '.merge.base // ""')"
  [[ -n "$commit" ]] || fail="the host did not report a merge commit, so nothing can be verified against it"
  for step in $(jq -r '.policy.merge.verify[]' "$STATE"); do
    [[ -z "$fail" ]] || break
    ! [[ "$(jq -r --arg s "$step" '.post_merge[$s].status // ""' "$STATE")" =~ ^(passed|tracked|skipped)$ ]] || continue
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
        reported="$(jq -r .commit "$out")"
        if [[ "$status" == passed || "$status" == none ]] && [[ ${#reported} -lt 7 || ( "$commit" != "$reported"* && "$reported" != "$commit"* ) ]]; then
          status=unverified
          jq '.summary = "the CI result is not for the merge commit"' "$out" >"$out.tmp" && mv "$out.tmp" "$out"
        fi
        if [[ "$status" == none ]] && repo_has_ci_config; then
          status=unverified
          jq '.summary = "the session reported no CI on the base branch, but the repository has CI configuration"' "$out" >"$out.tmp" && mv "$out.tmp" "$out"
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
          if [[ "$step" == deploy && ( "$rc" == 126 || "$rc" == 127 ) ]]; then
            fail="the deploy check could not run (exit $rc — command not found or not executable): $cmd"
          elif [[ "$step" == deploy ]]; then
            waited=$(( ($(date -u +%s) - $(state '.merge.merged_epoch // 0')) / 60 ))
            timeout="$(state '.policy.merge.deploy_timeout_minutes')"
            ((waited >= timeout)) \
              || finish incomplete 30 "the merge commit $commit is not deployed yet (deploy check exit $rc, ${waited} of ${timeout} minutes); run resume to check again"
            fail="the merge commit $commit was not observed as deployed within $timeout minutes (deploy check: $cmd)"
          else
            fail="the smoke check failed twice after the merge (exit $rc): $cmd"
          fi
        fi ;;
      monitor)
        # 재발은 배포 뒤 수 시간~14일을 지켜봐야 알 수 있다. /autofix의 정기 검증이 판정하도록 PR을 추적에 올리는 데까지가 이 단계다.
        if [[ "$(state '.monitor_error // null')" == null ]]; then
          state_set '.post_merge.monitor = {status: "skipped", note: "no monitoring error was given to this run (start --monitor-error)", at: $t}' --arg t "$(now_utc)"
          continue
        fi
        project="$(jq -r '.project_id // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)"
        af="$(plugin_root)/scripts/autofix-auto.sh"
        rc=0
        if [[ -n "$project" && -f "$af" ]]; then
          jq -c '.monitor_error' "$STATE" >"$RUN/monitor-error.json"
          bash "$af" track --project "$project" --candidate "$(<"$RUN/monitor-error.json")" --pr "$(state .publish.pr_url)" \
            >"$RUN/post-merge-monitor.log" 2>&1 </dev/null || rc=$?
        else
          rc=127
          jq -c '.monitor_error' "$STATE" >"$RUN/monitor-error.json"
          printf 'the ai-harness plugin (scripts/autofix-auto.sh) was not found; set HM_PLUGIN_ROOT, or project_id is missing\n' >"$RUN/post-merge-monitor.log"
        fi
        if ((rc == 0)); then
          state_set '.post_merge.monitor = {status: "tracked", signature: .monitor_error.signature, note: ("recurrence of " + .monitor_error.signature + " is handed to /autofix; its scheduled sweep (HM_AUTOFIX_AUTO=1) or /autofix verify decides resolved or regressed"), at: $t}' --arg t "$(now_utc)"
        else
          state_set '.post_merge.monitor = {status: "failed", exit: $rc, tail: $tail, at: $t}' --argjson rc "$rc" --arg tail "$(tail -n 20 "$RUN/post-merge-monitor.log")" --arg t "$(now_utc)"
          fail="the monitoring error could not be registered for recurrence tracking (exit $rc, see $RUN/post-merge-monitor.log)"
          hint="the merge itself is fine and was not reverted. Fix the cause in the log, then register the error by hand: <ai-harness plugin>/scripts/autofix-auto.sh track --project $(printf '%q' "${project:-<project_id>}") --candidate \"\$(cat $(printf '%q' "$RUN/monitor-error.json"))\" --pr $(printf '%q' "$(state .publish.pr_url)")"
        fi ;;
    esac
  done
  if [[ -n "$fail" ]]; then
    [[ -n "$hint" ]] || hint="$(rollback_hint "$commit" "$base")"
    state_set '.findings = [$f, $r] | .post_merge.failed = $f' --arg f "$fail" --arg r "$hint"
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
MEASURE_SCHEMA="$RUN/measure-schema.json"
DIAGNOSE_SCHEMA="$RUN/diagnose-schema.json"
POLISH_REVIEW_SCHEMA="$RUN/polish-review-schema.json"
# 측정 세션이 캡처마다 같은 페이지 상태에서 평가하는 레이아웃 검사. 결과는 측정 JSON의 screens[].layout으로 받는다.
LAYOUT_PROBE="$RUN/layout-probe.js"
LAYOUT_PROBE_ID="layout-probe/1"

UI_SCENARIO_RULE="If the change alters what users see or operate (markup, styles, server-rendered templates, user-facing text, or the behavior of buttons, links, disclosures, forms, and dialogs), put one entry per scenario in ui_scenarios: the user role, entry -> key action -> success check -> return, the states to see (default and collapsed, empty, error, permission), the viewports and themes the project supports, and the mockup source (file, frame, or node) when a mockup exists. Follow the analysis step of the project ui-review skill (.agents/skills/ui-review or .claude/skills/ui-review) when it exists. Leave ui_scenarios empty for changes users cannot see."

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

# ---- polish(기존 화면 품질 개선) ----
# 측정 결과의 캡처가 그 측정의 증거 디렉터리 안에 실제로 있는지. 이름만 적은 캡처는 측정이 아니다.
measure_captures_present() { # measure-output evidence-dir
  local c n=0
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    [[ "$c" == /* ]] || c="$2/$c"
    case "$c" in "$2"/*) ;; *) return 1 ;; esac
    [[ "$c" != *..* && -s "$c" ]] || return 1
    n=$((n + 1))
  done <<<"$(jq -r '.screens[].captures[]' "$1")"
  [[ "$n" -gt 0 ]] && jq -e 'all(.screens[]; (.captures | length) > 0) and any(.screens[]; .role == "target")' "$1" >/dev/null
}

# 규칙 문서·기준 화면이 있고 기준선이 실제로 채점됐을 때만 통과를 판정할 수 있다(design-audit 스킬이 없으면 채점이 없다).
polish_has_rules() { [[ "$(state '(.baseline.rules.document // "") != "" and (.baseline.rules.reference_screen // "") != "" and (.baseline.audit.scored == true)')" == true ]]; }

measure_prompt() { # evidence-dir
  local ev="$1" same=""
  if [[ "$(state '.baseline // null')" != null ]]; then
    same="This is a re-measure after a fix. Render exactly the screens, viewports, and themes of the baseline below (same names), so each capture has a baseline twin, and score them the same way:
$(state '.baseline.screens | map("- \(.role) \(.screen) · \(.viewport) · \(.theme) · \(.url)") | join("\n")')"
  else
    same="This is the baseline before any change. Choose the screens: every target screen the request names, plus the screens that share the components or tokens those screens use (role sibling; .ai-harness/docs/ui.md may list them, otherwise find them in the code) — a later fix to a shared component is checked on them."
  fi
  printf '%s\n\n%s' "$CONTEXT" "You are the measure node of the design-polish graph. Do not edit, create, or delete any file in the repository; save captures, audit reports, and notes only under $ev.
Start the app the way .ai-harness/docs/ui.md (and the project ui-review skill, .agents/skills/ui-review or .claude/skills/ui-review, when it exists) documents, with the local or test configuration, never production credentials; point anything it writes outside the repository and stop any server you started before you finish.
$same
Open each screen in a real browser at every viewport and theme the project supports (ui.md), in its default state before hovering or focusing anything, and save a full-page capture under $ev named <screen>-<viewport>-<theme>.png. Captures are evidence; a screenshot file that does not show the screen is not.
Layout check: in the same page and state, right before each capture and scrolled to the top, evaluate the expression in $LAYOUT_PROBE in the page (for example Playwright: await page.evaluate(fs.readFileSync('$LAYOUT_PROBE', 'utf8'))) and put the object it returns, unchanged, in that screen's layout. Do not edit, filter, or explain away its issues; the driver reads them. A screen without the probe's result is unmeasured.
Rules: find the design rule document and the reference screen (.ai-harness/docs/frontend.md or ui.md section \"## 디자인 점검\", DESIGN.md, docs/design-system.md). Put their paths in rules, or empty strings when missing. When both exist, score every target screen with the project design-audit skill (.agents/skills/design-audit/SKILL.md or .claude/skills/design-audit/SKILL.md) exactly as its rubric says, using the captures for what the rubric marks as needing a render, and save the report as $ev/audit.md. audit.total is the lowest total among the target screens and audit.axes the lowest score per axis A-E (-1 for an axis the rubric leaves 미확인); audit.report is the report path. When either rule source is missing or the skill is absent, set audit.scored false, total -1, every axis -1, report empty.
checks: the exact shell commands the project names for checking screens mechanically (design lint, contrast, token-copy checks, the UI test suite) from ui.md, AGENTS.md, or the testing docs. Do not run them; the driver runs them from the repository root with bash -c.
status: measured when every target screen rendered at every required viewport and theme; otherwise unmeasured with each gap in unmeasured.
Return only JSON matching the schema.

Request (the screens to polish and what to improve):
$(state .request)"
}

# 고칠 목록을 승인 대상으로 만든다. 선택(selected)·검증 명령이 승인에 묶인다 — 하나라도 바뀌면 이전 승인은 무효다.
polish_brief() { # selected-ids-json
  local auto=false
  [[ "$(state '.policy.approval // "human"')" == auto ]] && auto=true
  jq --argjson sel "$1" --argjson checks "$(state '.checks')" --argjson auto "$auto" \
    '{items, needs_decision, selected: $sel, checks: $checks, open_questions: [], needs_human: [],
      decisions: (if $auto then [{question: "고칠 항목", choice: (if ($sel | length) > 0 then ($sel | join(", ")) else "없음" end),
        rationale: "HM_APPROVAL=auto라 사람이 고르지 않는다. 심각도 major 항목만 골랐다 — minor·사람 판단 항목은 고치지 않고 목록으로 남긴다"}] else [] end)}' \
    "$RUN/diagnose.out" >"$RUN/brief.json"
  jq -r --arg base "$(state '"기준선 측정: " + (if .baseline.audit.scored then "design-audit \(.baseline.audit.total)/100 (A \(.baseline.audit.axes.A) · B \(.baseline.audit.axes.B) · C \(.baseline.audit.axes.C) · D \(.baseline.audit.axes.D) · E \(.baseline.audit.axes.E))" else "design-audit 채점 없음" end) + " · 캡처 " + .baseline.evidence_dir')" '
    "## 고칠 목록 (심각도 순)\n\n" + $base + "\n\n| 고침 | ID | 심각도 | 항목 | 근거 | 고칠 방향 |\n|---|---|---|---|---|---|\n"
    + (.selected as $sel | [.items[] | "| " + (if (.id as $id | $sel | index($id)) != null then "[x]" else "[ ]" end)
        + " | \(.id) | \(.severity) | \(.title) | \(.evidence | join("<br>")) | \(.fix)\(if .mechanical then " (기계 검사로 잡을 수 있음 — 그 검사를 더한다)" else "" end) |"] | join("\n"))
    + (if (.needs_decision | length) > 0 then "\n\n## 사람이 정할 점 (고치지 않음)\n\n" + (.needs_decision | map("- " + .) | join("\n")) else "" end)
    + (if (.decisions | length) > 0 then "\n\n## 결정 사항\n\n" + (.decisions | map("- \(.question) → \(.choice) — \(.rationale)") | join("\n")) else "" end)' \
    "$RUN/brief.json" >"$RUN/brief.md"
  printf '\n\n---\n승인 모드: %s (출처: %s)\n' "$(state '.policy.approval // "human"')" "$(state '.policy.approval_source // "legacy"')" >>"$RUN/brief.md"
  state_set '.selected = $s | .presented_at = $t | .feedback = null | .approval = null' --argjson s "$1" --arg t "$(now_utc)"
  state_set '.brief_hash = $h' --arg h "$({ cat "$RUN/brief.md"; state '.checks[]'; } | git hash-object --stdin)"
}

# 측정의 레이아웃 검사 결과를 프롬프트용 문구로. baseline 또는 last(마지막 측정).
polish_layout_text() { # baseline|last
  jq -r --arg w "$1" --arg p "$LAYOUT_PROBE_ID" '
    (if $w == "baseline" then .baseline.layout else (.measurements | last).layout end // [])
    | [.[] as $s | $s.issues[] | "- \($s.role) \($s.screen) · \($s.viewport) · \($s.theme): \(.kind) — \(.detail)"]
    | "Layout check (\($p), run in the live page): " + (if length == 0 then "no issue on any captured screen." else "found\n" + join("\n") end)' "$STATE"
}

polish_findings_text() {
  state '(.findings // []) | if length > 0 then "\nStill to resolve from the last review, check run, or remote CI:\n" + (map("- " + .) | join("\n")) else "" end'
}

# review의 판정은 모델이 아니라 이 스크립트가 측정 결과로 한다. 모델은 남은 항목·회귀·새 문제를 증거로 보고할 뿐이다.
polish_verdict() { # review-output → stdout: 통과를 막는 문제(JSON 배열)
  jq -c --slurpfile s "$STATE" --argjson pass "$(jq -r '.limits.audit_pass_score // 90' "$GRAPH")" --argjson rules "$(polish_has_rules && echo true || echo false)" '
    $s[0] as $st | ($st.measurements | last) as $m | $st.baseline.audit as $b
    | [ (.remaining[] as $r | select($st.selected | index($r)) | "selected item still present: " + $r
          + (first($st.items[]? | select(.id == $r) | " — " + .title) // "")),
        (.regressions[] | "regression: " + .),
        (.new_findings[] | "new issue: " + .),
        # 레이아웃 검사: 대상 화면의 깨짐은 기준선에 있었어도 막는다(다듬은 화면이 깨진 채 통과하지 않게).
        # 형제 화면은 고칠 대상이 아니므로 기준선 같은 화면·뷰포트·테마에 없던 깨짐만 회귀로 막는다.
        (($st.baseline.layout // []) as $bl | ($m.layout // [])[] as $s | $s.issues[] as $i
          | select($s.role == "target"
              or ([$bl[] | select(.screen == $s.screen and .viewport == $s.viewport and .theme == $s.theme) | .issues[].key] | index($i.key) | not))
          | "layout (\($s.role) \($s.screen) · \($s.viewport) · \($s.theme)): \($i.kind) — \($i.detail)"),
        (if $rules then
          (if ($m.audit.scored | not) then "design-audit did not score the screens after the fix"
           elif $m.audit.total < $pass then "design-audit total \($m.audit.total) is below \($pass)" else empty end),
          (["A","B","C","D","E"][] as $a
            | if ($b.axes[$a] >= 0 and $m.audit.axes[$a] >= 0 and $m.audit.axes[$a] < $b.axes[$a]) then "axis \($a) fell below the baseline: \($b.axes[$a]) -> \($m.audit.axes[$a])"
              elif ($b.axes[$a] >= 0 and $m.audit.axes[$a] < 0) then "axis \($a) was scored at the baseline but is 미확인 after the fix" else empty end)
        else empty end) ]' "$1"
}

polish_summary() {
  state '"polished " + ((.selected // []) | join(", ")) + (if .baseline.audit.scored then "; design-audit \(.baseline.audit.total) -> \((.measurements | last).audit.total)" else "" end)
    + "; captures: baseline " + .baseline.evidence_dir + ", after " + ((.measurements | last).evidence_dir)'
}

execute() {
  local node brief
  while :; do
    node="$(state .node)"
    if jq -e --arg n "$node" '.terminals | index($n)' "$GRAPH" >/dev/null; then
      case "$node" in
        fix_list)
          finish fix_list 0 "critique only — the project has no design rule document and reference screen to score against, so nothing was changed. Fix list: $RUN/brief.md (captures: $(state .baseline.evidence_dir)). To polish with scoring, create the rules with /ai-harness:design-system-builder, or when they already exist enable the design-system stack with /harness-init --reconfigure, then start again" ;;
        done)
          if [[ "$WORKFLOW" == polish && "$(state '.polish_outcome // ""')" == nothing_to_fix ]]; then
            finish "done" 0 "nothing to polish$(state 'if (.items // [] | length) > 0 then ": no major item (approval auto selects major items only); the minor items are listed" else ": the critique found nothing to fix" end') in $RUN/brief.md; nothing was changed"
          fi
          if [[ "$WORKFLOW" == review ]]; then
            finish "done" 0 "no blocking findings remain$(state 'if .attempts > 0 then "; \(.attempts) repair round(s) passed the required checks (run by the driver) and re-review; the repairs are left uncommitted — commit and push them as git_policy allows" else "" end')$(state 'if .ui_review then "; UI: verified — " + .ui_review.summary else "" end')"
          fi
          finish "done" 0 "$(if [[ "$WORKFLOW" == polish ]]; then printf '%s; required checks passed (run by the driver) and the independent review found no remaining selected item, regression, or lower audit axis' "$(polish_summary)"; else printf 'required checks passed (run by the driver) and no blocking findings remain'; fi)$(state 'if (.publish.pr_url // "") != "" then "; PR: " + .publish.pr_url elif .publish.skipped then "; " + .publish.skipped else "" end')$(state 'if .remote_ci then (if .remote_ci.status != "not_required" then "; remote CI: " + .remote_ci.status + " — " + .remote_ci.summary else "" end)
          elif (.publish // {} | has("pr_url")) then "; remote CI: unverified — the project graph has no remote_ci node; sync the harness (/harness-init --sync)" else "" end')$(state 'if .merge.commit then "; merged: " + .merge.commit[:12] + " (" + .merge.method + ")"
            + (if (.post_merge // {} | length) > 0 then "; after merge: " + ([.post_merge | to_entries[] | select(.value | type == "object") | .key + " " + .value.status + (if .value.note then " (" + .value.note + ")" else "" end)] | join(", ")) else "" end)
          elif .merge.skipped then "; merge: not done — " + .merge.skipped else "" end')$(state 'if .policy.delivery.note then "; delivery level " + .policy.delivery.level + ": " + .policy.delivery.note else "" end')$(state 'if .ui_review then "; UI: verified — " + .ui_review.summary
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
      measure)
        local m_label m_ev m_out
        if [[ "$(state '.baseline // null')" == null ]]; then m_label=measure-baseline; else m_label="measure-$(state .attempts)-$(state '.measurements // [] | length')"; fi
        m_ev="$RUN/$m_label"
        # resume이 같은 측정을 다시 돌 때 이전 캡처가 이번 근거로 섞이지 않게 한다.
        rm -rf "${RUN:?}/$m_label"
        mkdir -p "$m_ev"
        run_node measure "$m_label" "$(measure_prompt "$m_ev")" "$MEASURE_SCHEMA"
        m_out="$RUN/$m_label.out"
        jq -e '(.status | IN("measured", "unmeasured")) and (.screens | type) == "array" and (.rules.document | type) == "string"
          and (.rules.reference_screen | type) == "string" and (.audit.scored | type) == "boolean" and (.audit.total | type) == "number"
          and (.audit.axes | type) == "object" and (.checks | type) == "array" and (.unmeasured | type) == "array"' "$m_out" >/dev/null 2>&1 \
          || finish incomplete 30 "measure output does not match the schema ($m_out)"
        # 캡처가 없거나 증거 디렉터리 밖이면 측정하지 않은 것이다. 측정 없는 비교·판정은 하지 않는다.
        if [[ "$(jq -r .status "$m_out")" != measured ]] || ! measure_captures_present "$m_out" "$m_ev" \
          || ! jq -e --arg p "$LAYOUT_PROBE_ID" 'all(.screens[]; .layout.probe == $p and .layout.viewport.w > 0)' "$m_out" >/dev/null \
          || ! jq -e --slurpfile s "$STATE" '[.screens[] | [.screen, .viewport, .theme]] as $now
            | all(($s[0].baseline.screens // [])[]; [.screen, .viewport, .theme] as $b | $now | index([$b]) != null)' "$m_out" >/dev/null; then
          state_set '.findings = (["screens unmeasured (or a baseline screen, viewport, or theme was not captured again, or the layout probe did not run on every screen): " + $r[0].summary] + $r[0].unmeasured + ["evidence: " + $e]) | .needs_user_decision = true' \
            --slurpfile r "$m_out" --arg e "$m_ev"
          go measure "$(edge_when measure user_decision)"
          continue
        fi
        state_set '.measurements += [($r[0] | {label: $l, audit, summary, evidence_dir: $e, at: $t,
            layout: [.screens[] | {screen, role, viewport, theme, issues: .layout.issues}]})]' \
          --slurpfile r "$m_out" --arg l "$m_label" --arg e "$m_ev" --arg t "$(now_utc)"
        if [[ "$(state '.baseline // null')" == null ]]; then
          state_set '.baseline = ($r[0] | {rules, audit, screens: [.screens[] | {screen, role, url, viewport, theme}], summary, evidence_dir: $e,
            layout: [.screens[] | {screen, role, viewport, theme, issues: .layout.issues}]})
            | .checks = ([.cli_checks[], $r[0].checks[]] | map(select(length > 0)) | unique)' --slurpfile r "$m_out" --arg e "$m_ev"
          # 검사 명령은 측정 세션이 고른 것이라 승인 전에는 실행하지 않는다. 고칠 목록과 함께 승인받은 뒤 verify가 실행한다.
          go measure baseline_measured
        else
          # 이 트리가 측정한 화면이다. review는 이 트리에서만 시작한다.
          state_set '.measured_tree = $t' --arg t "$(worktree_tree)"
          go measure remeasured
        fi
        ;;
      diagnose)
        local audit_report revise_note=""
        audit_report="$(state '.baseline.audit.report // ""')"
        [[ -n "$audit_report" ]] || audit_report="(none, the screens were not scored)"
        [[ "$(state '.feedback // ""')" == "" ]] \
          || revise_note="$(printf '\n\nPrevious fix list:\n%s\n\nRevise it with this feedback from the person:\n%s' "$(<"$RUN/brief.md")" "$(state .feedback)")"
        run_node diagnose diagnose "$CONTEXT

You are the diagnose node of the design-polish graph. Do not edit any file. You did not make these screens; critique them independently from the evidence of the baseline measurement, as a first-time user and as a design reviewer holding the project's own rules (the design rule document, its tokens and shared components, the reference screen, .ai-harness/docs/ui.md) first and general interface quality second.
Evidence: captures in $(state .baseline.evidence_dir) (read the images), the design-audit report $audit_report, and the project checks the driver will run after the fix: $(state '.checks | join(" ; ")').
Look at every capture for empty bands, horizontal overflow, and clipped or cut-off elements before judging anything else. A full-page capture shows a sticky or fixed element (a sidebar, a header) only where it sits at the top of the page, so its background seems to end at the viewport height; that alone is not a defect (the layout check below already looks at it in the live page).
$(polish_layout_text baseline)
List what to fix as items, most severe first, with ids P1, P2, ... in that order. Each item: severity major (a rule the audit deducted, a broken hierarchy or primary action, unreadable contrast or a missing focus state, a failing project check, a screen that disagrees with its siblings in the rule document, a broken layout at a supported viewport or theme) or minor (everything else worth fixing); a short title; evidence — the capture files that show it and the rule-document section or audit line it breaks (both when they exist); fix — what to change, in tokens and shared components rather than raw values; mechanical — true when a machine check (lint, contrast, token-copy check) could catch it.
Every layout check issue above is a major item with mechanical true (one item may cover the same issue on several viewports or themes); the fix is checked by the same probe after the fix.
Put anything that needs a product or content decision in needs_decision instead of items. Do not list what the screens already do right.
Return only JSON matching the schema.

Baseline summary: $(state .baseline.summary)

Request:
$(state .request)$revise_note" "$DIAGNOSE_SCHEMA"
        jq -e '(.items | type) == "array" and (.needs_decision | type) == "array"
          and all(.items[]; (.id | test("^P[0-9]+$")) and (.severity | IN("major", "minor")) and (.evidence | length) > 0)
          and ([.items[].id] | length == (unique | length))' "$RUN/diagnose.out" >/dev/null 2>&1 \
          || finish incomplete 30 "diagnose output does not match the schema, or an item has no evidence ($RUN/diagnose.out)"
        state_set '.items = $d[0].items' --slurpfile d "$RUN/diagnose.out"
        # 규칙 문서·기준 화면이 없으면 채점 기준이 없어 통과를 판정할 수 없다. 비평과 고칠 목록까지만 낸다.
        if ! polish_has_rules; then
          polish_brief '[]'
          go diagnose no_design_rules
          continue
        fi
        local sel
        sel="$(jq -c '[.items[] | select(.severity == "major") | .id]' "$RUN/diagnose.out")"
        if [[ "$(jq '.items | length' "$RUN/diagnose.out")" -eq 0 ]] \
          || [[ "$(state '.policy.approval // "human"')" == auto && "$sel" == "[]" ]]; then
          polish_brief "$sel"
          state_set '.polish_outcome = "nothing_to_fix"'
          go diagnose nothing_to_fix
          continue
        fi
        polish_brief "$sel"
        go diagnose fix_list_ready
        ;;
      discover)
        run_node discover discover "$CONTEXT

You are the discover node of the feature-delivery graph. Do not edit any file.
Summarize the project contract that matters for the request below: relevant modules and files, conventions, the test policy, and the exact commands that verify a change (build, targeted tests, broad tests, lint).

Request:
$(state .request)"
        go discover ""
        ;;
      triage)
        # /investigate의 조사 보고가 있으면 그 보고가 triage·reproduce 결과다. 같은 조사를 다시 하지 않고 brief로 간다.
        if [[ -f "$RUN/investigation.md" ]] && has_edge triage investigation_report_provided; then
          { printf 'Investigation report from the investigate workflow (%s); it stands in for triage:\n\n' "$(state .investigation)"
            cat "$RUN/investigation.md"; } >"$RUN/triage.out"
          jq -n --arg p "$(state .investigation)" \
            '{status:"evidence_sufficient", summary:("reproduction and evidence from the investigation report " + $p), evidence:["the investigation report above (triage) holds the reproduction or equivalent evidence"], hypothesis:"", needed:[]}' >"$RUN/reproduce.out"
          log "investigation report $(state .investigation) stands in for triage and reproduce"
          go triage investigation_report_provided
          continue
        fi
        [[ ! -f "$RUN/investigation.md" ]] \
          || log "the project graph has no triage -> brief edge for an investigation report; triage and reproduce run again with the report. Sync the harness (/harness-init --sync)"
        run_node triage triage "$CONTEXT

You are the triage node of the bug-fix graph. Do not edit any file.
From the bug report below, state the observed behavior, the expected behavior, the impact, the relevant modules and files, the project test policy, and the exact commands that verify a change (build, targeted tests, broad tests, lint).

Bug report:
$(state .request)$(if [[ -f "$RUN/investigation.md" ]]; then printf '\n\nInvestigation report from the investigate workflow:\n%s' "$(<"$RUN/investigation.md")"; fi)"
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
        printf '\n\n---\n승인 모드: %s (출처: %s)\n' "$(state '.policy.approval // "human"')" "$(state '.policy.approval_source // "legacy"')" >>"$RUN/brief.md"
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
        if [[ "$WORKFLOW" == polish && "$(state '.selected // [] | length')" -eq 0 ]]; then
          state_set '.approval = null | .status = "waiting_approval"'
          print_brief
          log "no item is selected; choose with revise --select \"P1,P3\": run $RUN_ID"
          exit 10
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
        local before_fix denied
        if [[ "$WORKFLOW" == polish ]]; then
          [[ "$(state '.selected | length')" -gt 0 ]] \
            || finish incomplete 30 "no item is selected to fix; choose with revise --select \"P1,P3\" and approve again"
          if [[ "$(state .attempts)" -ge "$MAX_REPAIR" ]]; then
            go fix "$(edge_when fix user_decision)"
            continue
          fi
          state_set '.attempts += 1'
          before_fix="$(fingerprint)"
          run_node fix "fix-$(state .attempts)" "$CONTEXT

You are the fix node of the design-polish graph. Fix the selected items below in the existing screens, and nothing else. Use the project's design rule document, semantic tokens, and shared components; prefer fixing a shared component or token over a one-off override, and when you change one, keep every screen that uses it right (the measure node captures those screens again).
Test-first is not required for spacing, color, or hierarchy changes. Add a check only for a violation a machine can catch (an item marked mechanical): extend the project's existing lint or check script so it fails on the violation, and keep it passing.
Do not commit, push, create a PR, or change scope. After you finish, the driver itself runs these checks: $(state '.checks | join(" ; ")'), then measures the screens again and has an independent reviewer compare them with the baseline.
Return a concise summary of what you changed for each item and the commands you ran.
$(polish_findings_text)

$(brief_context)"
          if [[ "$(fingerprint)" == "$before_fix" ]]; then
            denied="$(session_denials "fix-$(state .attempts)")"
            if [[ -n "$denied" ]]; then
              # 권한에 막혀 아무것도 못 바꾼 세션은 수리 시도가 아니다. 횟수를 되돌려 원인을 고친 뒤 resume이 같은 회차로 다시 고친다.
              state_set '.attempts -= 1'
              finish incomplete 30 "fix changed nothing because the session was denied: $denied. This environment failure does not count as a repair attempt; allow those paths (or move the repository out of a protected folder) and run resume"
            fi
            finish incomplete 30 "fix changed nothing; the selected items cannot be done without a change"
          fi
          checkpoint "fix-$(state .attempts)"
          go fix ""
          continue
        fi
        before_fix="$(fingerprint)"
        run_node fix fix "$CONTEXT

You are the fix node of the bug-fix graph. Fix the cause in production code within the approved scope, delegating to the project's role agents when the workflow says so. Do not weaken, skip, or delete the regression verification.
Do not commit, push, create a PR, or change scope. After you finish, the driver itself runs these checks: $(state '.checks | join(" ; ")')
Return a concise summary of the cause, the changed areas, and the commands you ran.

$(brief_context)"
        if [[ "$(fingerprint)" == "$before_fix" ]]; then
          denied="$(session_denials fix)"
          [[ -z "$denied" ]] || finish incomplete 30 "fix changed nothing because the session was denied: $denied. Allow those paths (or move the repository out of a protected folder) and run resume"
          finish incomplete 30 "fix changed nothing; an approved bug fix cannot be done without a change to the cause"
        fi
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
        if [[ "$WORKFLOW" == polish ]]; then
          # 측정한 트리에서만 검토한다. 측정 뒤 바뀐 파일은 검사·측정을 받지 않았다 — 거부하고 verify부터 다시 돈다.
          if ! tree_unchanged_since measured_tree; then
            log "refused: files changed after the measurement ($(changed_since measured_tree)); checking and measuring again"
            state_set '.changed_after_measure = ($f | split(", "))' --arg f "$(changed_since measured_tree)"
            go review changed_after_measure
            continue
          fi
          local r_label problems
          r_label="review-$(state .attempts)"
          run_node review "$r_label" "$CONTEXT

You are the review node of the design-polish graph. Do not edit any file. You did not make this change; judge it only from the evidence, not from the fixer's summary.
Compare the baseline captures in $(state .baseline.evidence_dir) with the captures after the fix in $(state '(.measurements | last).evidence_dir') — every screen, viewport, and theme pair, the sibling screens as closely as the targets — and read both design-audit reports when they exist. The change is git diff $(state .start_head) (including the driver's checkpoint commits).
Look at each capture first for empty bands (a row or column stretched with no content), horizontal overflow, and clipped or cut-off elements, then for the rest. A defect that was already in the baseline capture is still a defect on a target screen. A full-page capture shows a sticky or fixed element only at the top of the page, so its background seems to end at the viewport height; that alone is not a defect.
$(polish_layout_text last)
The driver blocks the pass on its own for every layout check issue on a target screen and for every new one on a sibling screen; you do not need to repeat them, but report what else the captures show.
remaining: the ids of selected items that are still visible in the captures after the fix. regressions: anything on any captured screen that is worse than its baseline (layout, spacing, hierarchy, contrast, a shared component or token change showing wrong on a screen it was not meant for), each with the capture pair that shows it. new_findings: new major issues the change introduced that are not regressions of a baseline capture. Leave an array empty when you found nothing for it.
Set needs_user_decision to true only when a remaining item or regression needs a product or design-rule decision from a person.
Return only JSON matching the schema.

Selected items:
$(jq -r --argjson s "$(state .selected)" '.items[] | select(.id as $i | $s | index($i)) | "- \(.id) [\(.severity)] \(.title) — \(.fix)"' "$RUN/brief.json")

Design-audit: baseline $(state '.baseline.audit | if .scored then "\(.total) (A \(.axes.A) B \(.axes.B) C \(.axes.C) D \(.axes.D) E \(.axes.E)) " + .report else "not scored" end'); after the fix $(state '(.measurements | last).audit | if .scored then "\(.total) (A \(.axes.A) B \(.axes.B) C \(.axes.C) D \(.axes.D) E \(.axes.E)) " + .report else "not scored" end')" "$POLISH_REVIEW_SCHEMA"
          jq -e '(.remaining | type) == "array" and (.regressions | type) == "array" and (.new_findings | type) == "array"
            and (.needs_user_decision | type) == "boolean"' "$RUN/$r_label.out" >/dev/null 2>&1 \
            || finish incomplete 30 "review output does not match the schema; the polish is not done ($RUN/$r_label.out)"
          problems="$(polish_verdict "$RUN/$r_label.out")"
          state_set '.polish_review = ($r[0] | {summary, remaining, regressions, new_findings}) + {problems: $p, at: $t}' \
            --slurpfile r "$RUN/$r_label.out" --argjson p "$problems" --arg t "$(now_utc)"
          if [[ "$problems" == "[]" ]]; then
            state_set '.findings = [] | .reviewed_tree = $t' --arg t "$(worktree_tree)"
            go review polish_passed
          elif [[ "$(jq -r .needs_user_decision "$RUN/$r_label.out")" == true ]]; then
            state_set '.findings = $p | .needs_user_decision = true' --argjson p "$problems"
            go review "$(edge_when review user_decision)"
          else
            state_set '.findings = $p | .needs_user_decision = false' --argjson p "$problems"
            go review polish_failed
          fi
          continue
        fi
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
        # 분류는 inspect가 낸 finding으로 이 스크립트가 정한다. 수리는 사람이 동의(또는 HM_APPROVAL=auto)해야 시작한다.
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
If the project has a native-ui skill (.agents/skills/native-ui/SKILL.md or .claude/skills/native-ui/SKILL.md) and the screens belong to a native app, follow it: render and operate them in a simulator or emulator instead of a browser, with the same evidence rules.
A code review found no blocking findings. You review the rendered screens, not the code: start the app as the project documents say, open every scenario below in a real browser (a simulator or emulator for native screens, as above), and operate it as a first-time user with mouse, keyboard, and a mobile-width viewport, in each supported theme. Look at the default and collapsed states before hovering or focusing anything.
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
        local before_fix denied
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
        before_fix="$(fingerprint)"
        run_node repair "repair-$(state .attempts)" "$CONTEXT

You are the repair node. Fix only these blocking findings. Follow the project test policy. Do not commit, push, create a PR, or change unrelated files; the driver commits checkpoints itself when git_policy allows.

Blocking findings:
$(state '.findings')

$(brief_context)"
        if [[ "$(fingerprint)" == "$before_fix" ]]; then
          denied="$(session_denials "repair-$(state .attempts)")"
          if [[ -n "$denied" ]]; then
            state_set '.attempts -= 1'
            finish incomplete 30 "repair changed nothing because the session was denied: $denied. This environment failure does not count as a repair attempt; allow those paths (or move the repository out of a protected folder) and run resume"
          fi
        fi
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

# 사용자 설정 값: ~/.ai-harness/config에서 KEY의 마지막 줄, 없으면 같은 이름의 환경변수. lib.sh의 hm_load_config와 같은
# 문법(KEY=VALUE, 따옴표 또는 공백 전까지)만 읽고 셸로 실행하지 않는다. 이 러너는 프로젝트에 복사되어 lib.sh를 쓰지 않는다.
user_config() { # KEY
  local file="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/config" line value="" found="" re_quoted='^"([^"]*)"' re_single="^'([^']*)'"
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z0-9_]+)=(.*)$ && "${BASH_REMATCH[2]}" == "$1" ]] || continue
      value="${BASH_REMATCH[3]}"
      if [[ "$value" =~ $re_quoted || "$value" =~ $re_single ]]; then value="${BASH_REMATCH[1]}"; else value="${value%%[[:space:]]*}"; fi
      found=1
    done <"$file"
  fi
  if [[ -n "$found" ]]; then printf '%s' "$value"; else printf '%s' "${!1:-}"; fi
}
# user_config가 KEY 값을 어디서 읽었는지: config 파일에 줄이 있으면 그 파일, 없으면 환경변수.
config_origin() { # KEY
  local file="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/config" line
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z0-9_]+)= && "${BASH_REMATCH[2]}" == "$1" ]] || continue
      printf 'in %s' "$file"
      return 0
    done <"$file"
  fi
  printf 'in the environment'
}
# /autofix monitor 설정: 개인 로컬 파일(~/.ai-harness/autofix/monitors/<project_id>.json) > manifest의 monitor.
# 이 러너는 플러그인 밖(대상 저장소)에 복사돼 lib.sh를 source하지 못하므로 hm_resolve_monitor와 같은 규칙을 여기 둔다.
# 출력은 monitor 객체 한 줄(없으면 빈 출력). 로컬 파일이 있는데 잘못됐으면 manifest로 넘어가지 않고 실패한다.
monitor_settings() { # $1=project_id
  local file="" monitor=""
  if [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    file="${HARNESS_METRICS_DIR:-$HOME/.ai-harness}/autofix/monitors/$1.json"
  fi
  if [[ -n "$file" && -e "$file" ]]; then
    monitor="$(jq -cs 'if length == 1 and (.[0] | type == "object" and (.provider | type == "string" and length > 0))
      then .[0] else empty end' "$file" 2>/dev/null || true)"
    [[ -n "$monitor" ]] || { printf 'the local monitor settings are invalid (one JSON object with a provider): %s\n' "$file" >&2; return 1; }
    printf '%s\n' "$monitor"
    return 0
  fi
  jq -c '.monitor // empty' "$REPO/.ai-harness/harness.json" 2>/dev/null || true
}
# 저장소별 설정의 키. lib.sh project_id_for_cwd(HM_AUTOFIX_REPOS·/metrics가 쓰는 project_id)와 같은 순서로 정한다.
project_key() {
  local id common
  id="$(jq -r '.project_id // empty' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    id="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
    id="${id%/}"; id="${id##*/}"; id="${id##*:}"; id="${id%.git}"
  fi
  if [[ -z "$id" ]]; then
    common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [[ "${common##*/}" != .git ]] || { id="${common%/.git}"; id="${id##*/}"; }
  fi
  printf '%s' "${id:-${REPO##*/}}"
}
# 저장소별 개인 설정 파서: 저장소별 값은 "<project_id>=<값>"(쉼표·공백 구분), 같은 키가 여러 번 나오면 마지막 값.
repository_setting() { # $1=repo setting key → "<value> <setting-key>:<project_id>" 또는 빈값
  local key entry value="" entries=()
  key="$(project_key)"
  IFS=$', \t' read -r -a entries <<<"$(user_config "$1")"
  for entry in "${entries[@]+"${entries[@]}"}"; do
    [[ "$entry" == *=* && "${entry%%=*}" == "$key" ]] || continue
    value="${entry#*=}"
  done
  [[ -z "$value" ]] || printf '%s %s:%s' "$value" "$1" "$key"
}
# 개인 자동화 단계: 저장소별 값 > HM_DELIVERY_LEVEL.
# 출력: "<단계> <출처>" 또는 빈 문자열(설정 없음 — PR까지).
delivery_level() {
  local setting="" level="" source=""
  setting="$(repository_setting HM_DELIVERY_LEVEL_REPOS)"
  if [[ -n "$setting" ]]; then read -r level source <<<"$setting"; else level="$(user_config HM_DELIVERY_LEVEL)"; [[ -z "$level" ]] || source=HM_DELIVERY_LEVEL; fi
  [[ -z "$level" ]] || printf '%s %s' "$level" "$source"
}
# 개인 승인 모드: 저장소별 설정 > 전체 설정 > human 기본값.
approval_mode() {
  local setting="" mode="" source=""
  setting="$(repository_setting HM_APPROVAL_REPOS)"
  if [[ -n "$setting" ]]; then read -r mode source <<<"$setting"; else mode="$(user_config HM_APPROVAL)"; fi
  if [[ -z "$source" ]]; then if [[ -n "$mode" ]]; then source=HM_APPROVAL; else mode=human; source=default; fi; fi
  [[ "$mode" =~ ^(human|auto)$ ]] || { printf '%s %s is "%s"; approval must be human or auto\n' "$source" "$(config_origin "${source%%:*}")" "$mode" >&2; return 2; }
  printf '%s %s' "$mode" "$source"
}

case "$CMD" in
  start)
    case "${RUNTIME:-}" in
      "") if command -v codex >/dev/null; then RUNTIME=codex; else RUNTIME=claude; fi ;;
      codex|claude) ;;
      *) usage ;;
    esac
    command -v "$RUNTIME" >/dev/null || { printf '%s not found\n' "$RUNTIME" >&2; exit 2; }
    refuse_claude_protected "$RUNTIME"
    git_policy="$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)"
    # 저장소 차원의 "병합까지"는 없다. 예전 git_policy merge는 pr-only와 같은 PR 범위로 읽고, 저장소 merge_policy와 개인 HM_MERGE_*의
    # 병합 조건(require·min_approvals·method)은 쓰지 않는다(병합은 호스트 규칙을 따른다). 시작은 막지 않고 결과에 안내를 남긴다.
    notices="[]"
    if jq -e 'has("approval") and .approval != null' "$REPO/.ai-harness/harness.json" >/dev/null 2>&1; then
      notices="$(jq -c '. + [".ai-harness/harness.json approval is ignored; set HM_APPROVAL or HM_APPROVAL_REPOS in ~/.ai-harness/config (/ai-harness:setup)"]' <<<"$notices")"
    fi
    if [[ "$git_policy" == merge ]]; then
      git_policy="pr-only"
      notices="$(jq -c '. + ["the repository git_policy merge is no longer used and is read as pr-only; choose how far runs go with a personal delivery level (/ai-harness:setup)"]' <<<"$notices")"
    fi
    if [[ "$WORKFLOW" != review ]] && jq -e '.merge_policy | objects | has("require") or has("min_approvals") or has("method")' "$REPO/.ai-harness/harness.json" >/dev/null 2>&1; then
      notices="$(jq -c '. + ["merge_policy require, min_approvals, and method in .ai-harness/harness.json are no longer used; merges follow the branch protection and merge settings on the host"]' <<<"$notices")"
    fi
    if [[ "$WORKFLOW" != review && -n "$(user_config HM_MERGE_REQUIRE)$(user_config HM_MERGE_MIN_APPROVALS)$(user_config HM_MERGE_METHOD)" ]]; then
      notices="$(jq -c '. + ["HM_MERGE_REQUIRE, HM_MERGE_MIN_APPROVALS, and HM_MERGE_METHOD in ~/.ai-harness/config are no longer used; merges follow the branch protection and merge settings on the host"]' <<<"$notices")"
    fi
    approval_setting="$(approval_mode)" || exit 2
    read -r approval approval_source <<<"$approval_setting"
    # 병합 여부는 개인 자동화 단계만 정한다. 없으면 PR까지다. 저장소 git_policy는 커밋·PR 범위만 정한다:
    # pr-only → PR(단계가 merge·deploy면 러너가 병합), direct → PR 없이 push(병합할 PR이 없다), 그 밖 → 커밋하지 않는다.
    delivery=null
    if [[ "$WORKFLOW" != review ]] && read -r level level_source <<<"$(delivery_level)" && [[ -n "$level" ]]; then
      [[ "$level" =~ ^(pr|merge|deploy)$ ]] \
        || { printf '%s in ~/.ai-harness/config is "%s"; the delivery level must be pr, merge, or deploy\n' "${level_source%%:*}" "$level" >&2; exit 2; }
      note=""
      case "$git_policy" in
        pr-only) [[ "$level" == pr ]] || git_policy=merge ;;
        direct) [[ "$level" == pr ]] || note="git_policy direct pushes without a pull request, so there is nothing to merge" ;;
        *) [[ "$level" == pr ]] || note="git_policy '${git_policy:-unset}' does not let the agent commit, so there is nothing to merge" ;;
      esac
      delivery="$(jq -cn --arg l "$level" --arg s "$level_source" --arg g "$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)" --arg n "$note" \
        '{level: $l, source: $s, repo_git_policy: $g} + (if $n == "" then {} else {note: $n} end)')"
    fi
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
          || { printf 'git_policy %s: start on a work branch or worktree, not the base branch %s\n' "$(jq -r '.git_policy // ""' "$REPO/.ai-harness/harness.json")" "${base#origin/}" >&2; exit 2; }
      fi
    fi
    # 병합 조건과 병합 후 검증은 시작 때 정한다. 실행 중 설정·manifest가 바뀌어도 시작 때의 정책을 따른다.
    # 여기서 git_policy merge는 개인 단계가 merge·deploy라는 뜻이다(저장소 값 merge는 위에서 pr-only로 읽었다).
    merge_policy=null
    if [[ "$git_policy" == merge && "$WORKFLOW" != review ]]; then
      # 기준 브랜치·배포·스모크 명령과 쓸 수 있는 검증은 저장소 사실이다. 병합 조건·방식은 merge 노드가 호스트에서 읽는다.
      # merge는 타깃 CI까지, deploy는 저장소에 있는 배포·스모크(·재발 추적)까지.
      merge_policy="$(jq -c --arg lvl "$level" '(.merge_policy // {}) as $r
        | ($r.deploy_check_cmd // "") as $deploy | ($r.smoke_cmd // "") as $smoke
        | (if ($r.verify | type) == "array" then $r.verify
           else [(if $deploy != "" then "deploy" else empty end), (if $smoke != "" then "smoke" else empty end)] end) as $avail
        | [$avail[] | select(IN("deploy", "smoke", "monitor")) | select((. != "deploy" or $deploy != "") and (. != "smoke" or $smoke != ""))] as $post
        | {verify: (["target_ci"] + (if $lvl == "deploy" then $post else [] end)),
           deploy_check_cmd: $deploy, deploy_timeout_minutes: ($r.deploy_timeout_minutes // 60), smoke_cmd: $smoke, base: ($r.base // "")}' \
        "$REPO/.ai-harness/harness.json")"
      if [[ "$level" == deploy ]] && ! jq -e '.verify | index("deploy") or index("smoke")' <<<"$merge_policy" >/dev/null; then
        delivery="$(jq -c '.note = "the repository has no deploy or smoke check (merge_policy.deploy_check_cmd, smoke_cmd), so the run stops after the merge and target CI"' <<<"$delivery")"
      fi
      jq -e '.deploy_timeout_minutes | type == "number" and . > 0' <<<"$merge_policy" >/dev/null \
        || { printf 'merge_policy.deploy_timeout_minutes in .ai-harness/harness.json must be a number above 0; got %s\n' \
          "$(jq -c '.deploy_timeout_minutes' <<<"$merge_policy")" >&2; exit 2; }
    fi
    if [[ "$merge_policy" != null ]]; then
      # 병합할 수 있는 기준 브랜치. manifest에 없으면 origin의 기본 브랜치로 정하고, 둘 다 없으면 시작하지 않는다.
      if [[ "$(jq -r .base <<<"$merge_policy")" == "" ]]; then
        base="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        [[ -n "$base" ]] || { printf 'delivery level %s: set merge_policy.base in .ai-harness/harness.json or the origin default branch (git remote set-head origin --auto) so the runner knows which branch it may merge into\n' "$level" >&2; exit 2; }
        merge_policy="$(jq -c --arg b "${base#origin/}" '.base = $b' <<<"$merge_policy")"
      fi
      # 검증 순서는 고정이다: 병합 커밋의 CI → 배포 → 스모크 → 재발 추적 등록.
      merge_policy="$(jq -c '.verify |= [("target_ci", "deploy", "smoke", "monitor") as $s | select(index($s)) | $s]' <<<"$merge_policy")"
      if jq -e '.verify | index("monitor")' <<<"$merge_policy" >/dev/null; then
        project="$(jq -r '.project_id // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)"
        monitor="$(monitor_settings "$project")" || exit 2
        if [[ -z "$project" ]] || ! jq -e '.provider | type == "string"' <<<"${monitor:-null}" >/dev/null 2>&1; then
          printf 'merge_policy.verify monitor needs the monitor settings (/autofix setup) in ~/.ai-harness/autofix/monitors/<project_id>.json or monitor in .ai-harness/harness.json, and project_id in .ai-harness/harness.json\n' >&2
          exit 2
        fi
      fi
    fi
    monitor_error=null
    if [[ -n "$MONITOR_ERROR" ]]; then
      monitor_error="$(jq -cs 'if length == 1 and (.[0] | type == "object" and (.signature | type == "string") and (.signature | length > 0)) then .[0] else empty end' <<<"$MONITOR_ERROR" 2>/dev/null || true)"
      [[ -n "$monitor_error" ]] || { printf -- '--monitor-error needs one monitoring error as a JSON object with a signature (one line of /autofix candidates)\n' >&2; exit 2; }
      # 관찰 창은 수정 전 빈도(창 안 발생 수)로 늘린다 — 정기 실행처럼 그 창의 길이를 같이 넘긴다.
      monitor="$(monitor_settings "$(jq -r '.project_id // ""' "$REPO/.ai-harness/harness.json" 2>/dev/null || true)")" || exit 2
      monitor_error="$(jq -c --argjson h "$(jq '.window_hours // 24' <<<"${monitor:-null}" 2>/dev/null || echo 24)" '{window_hours: $h} + .' <<<"$monitor_error")"
    fi
    mkdir -p "$RUN"
    # 보고 파일이 실행 중에 바뀌거나 지워져도 같은 내용으로 이어 가게 실행 디렉터리에 복사해 둔다.
    [[ -z "$INVESTIGATION_FILE" ]] || cp "$INVESTIGATION_FILE" "$RUN/investigation.md"
    printf '%s\n' "$RUN_ID" >"$(latest_file)"
    printf '%s\n' "$RUN_ID" >"$(latest_file "$WORKFLOW")"
    jq -n --arg id "$RUN_ID" --arg wf "$WORKFLOW" --arg repo "$REPO" --arg rt "$RUNTIME" --arg req "$REQUEST" --arg graph "$GRAPH" \
      --arg node "$(jq -r .entry "$GRAPH")" --arg head "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf none)" --arg t "$(now_utc)" \
      --arg git "$git_policy" --argjson merge "$merge_policy" --argjson delivery "$delivery" --argjson notices "$notices" --argjson mon "$monitor_error" --arg unattended "${HM_INTERNAL_SESSION:-}" \
      --arg appr "$approval" --arg appr_source "$approval_source" --arg inv "$INVESTIGATION_FILE" \
      --argjson cli "$(printf '%s\n' "${CLI_CHECKS[@]+"${CLI_CHECKS[@]}"}" | jq -R . | jq -s 'map(select(length > 0))')" \
      '{run_id:$id, workflow:$wf, repo:$repo, runtime:$rt, request:$req, graph:$graph, node:$node, start_head:$head, head:$head, started_at:$t,
        policy:{git:$git, approval:$appr, approval_source:$appr_source, commits:(($git | IN("pr-only", "direct", "merge")) and $wf != "review"),
          merge:$merge, delivery:$delivery, notices:$notices, unattended:($unattended == "1")},
        monitor_error:$mon, investigation:(if $inv == "" then null else $inv end), status:"running", attempts:0, cli_checks:$cli, checks:[], checkpoints:[], findings:[], history:[]}' >"$STATE"
    save_baseline
    ;;
  watch)
    [[ -f "$STATE" ]] || { printf 'run not found: %s\n' "$RUN" >&2; exit 2; }
    touch "$RUN/progress.log"
    exec tail -n 50 -f "$RUN/progress.log"
    ;;
  resume|approve|revise|status)
    [[ -f "$STATE" ]] || { printf 'run not found: %s\n' "$RUN" >&2; exit 2; }
    [[ "$CMD" == status ]] || refuse_claude_protected "$(state .runtime)"
    ;;
  *) usage ;;
esac
# 실행을 이어 가는 명령마다 진행 파일 경로를 알린다. 새 세션에서 resume만 부른 에이전트도 모니터할 경로를 얻는다.
if [[ "$CMD" != status ]]; then
  log "run $RUN_ID · progress: $RUN/progress.log · follow with: bash $(printf '%q' "$SCRIPT_DIR/$(basename "$0")") watch --workflow $WORKFLOW --repo $(printf '%q' "$REPO")"
fi
if [[ "$CMD" == start ]]; then
  while IFS= read -r notice; do
    [[ -z "$notice" ]] || log "notice: $notice"
  done <<<"$(state '(.policy.notices // [])[]')"
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
cat >"$MEASURE_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["status","summary","screens","rules","audit","checks","unmeasured"],
 "properties":{"status":{"type":"string","enum":["measured","unmeasured"]},"summary":{"type":"string"},
  "screens":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["screen","role","url","viewport","theme","captures","layout"],
   "properties":{"screen":{"type":"string"},"role":{"type":"string","enum":["target","sibling"]},"url":{"type":"string"},
    "viewport":{"type":"string"},"theme":{"type":"string"},"captures":{"type":"array","items":{"type":"string"}},
    "layout":{"type":"object","additionalProperties":false,"required":["probe","viewport","document","issues"],
     "properties":{"probe":{"type":"string"},
      "viewport":{"type":"object","additionalProperties":false,"required":["w","h"],"properties":{"w":{"type":"number"},"h":{"type":"number"}}},
      "document":{"type":"object","additionalProperties":false,"required":["w","h"],"properties":{"w":{"type":"number"},"h":{"type":"number"}}},
      "issues":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["kind","key","detail"],
       "properties":{"kind":{"type":"string"},"key":{"type":"string"},"detail":{"type":"string"}}}}}}}}},
  "rules":{"type":"object","additionalProperties":false,"required":["document","reference_screen"],
   "properties":{"document":{"type":"string"},"reference_screen":{"type":"string"}}},
  "audit":{"type":"object","additionalProperties":false,"required":["scored","total","axes","report"],
   "properties":{"scored":{"type":"boolean"},"total":{"type":"number"},"report":{"type":"string"},
    "axes":{"type":"object","additionalProperties":false,"required":["A","B","C","D","E"],
     "properties":{"A":{"type":"number"},"B":{"type":"number"},"C":{"type":"number"},"D":{"type":"number"},"E":{"type":"number"}}}}},
  "checks":{"type":"array","items":{"type":"string"}},"unmeasured":{"type":"array","items":{"type":"string"}}}}
EOF
cat >"$DIAGNOSE_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","items","needs_decision"],
 "properties":{"summary":{"type":"string"},
  "items":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","severity","title","evidence","fix","mechanical"],
   "properties":{"id":{"type":"string"},"severity":{"type":"string","enum":["major","minor"]},"title":{"type":"string"},
    "evidence":{"type":"array","items":{"type":"string"}},"fix":{"type":"string"},"mechanical":{"type":"boolean"}}}},
  "needs_decision":{"type":"array","items":{"type":"string"}}}}
EOF
cat >"$POLISH_REVIEW_SCHEMA" <<'EOF'
{"type":"object","additionalProperties":false,"required":["summary","remaining","regressions","new_findings","needs_user_decision"],
 "properties":{"summary":{"type":"string"},"remaining":{"type":"array","items":{"type":"string"}},
  "regressions":{"type":"array","items":{"type":"string"}},"new_findings":{"type":"array","items":{"type":"string"}},
  "needs_user_decision":{"type":"boolean"}}}
EOF
# 레이아웃 probe: 브라우저에서 평가하는 식 하나. 가로 넘침·잘린 글자·본문 앞 빈 띠·배경이 못 채움만 본다(오탐 기준은 주석과
# tests/fixtures/polish-layout). 모델의 눈과 채점이 놓친 깨짐을 측정 결과에 남겨 러너가 통과를 막는다(#409).
[[ "$WORKFLOW" != polish ]] || cat >"$LAYOUT_PROBE" <<'EOF'
(() => {
  // layout-probe/1 — 측정 세션이 캡처 직전 같은 페이지 상태에서 평가한다(workflow-driver.sh가 실행 폴더에 쓴다).
  // 취향이 아니라 기계로 확실한 깨짐만 낸다. 기준은 tests/fixtures/polish-layout의 깨진·정상 페이지로 고정한다.
  const de = document.documentElement, body = document.body;
  const VW = de.clientWidth, VH = innerHeight, SX = scrollX, SY = scrollY;
  const DOC_H = Math.max(de.scrollHeight, body ? body.scrollHeight : 0);
  const issues = [];
  const name = (el) => {
    let s = el.tagName.toLowerCase();
    if (el.id) return s + "#" + el.id;
    const c = [...el.classList].slice(0, 2);
    return c.length ? s + "." + c.join(".") : s;
  };
  const path = (el) => [el.parentElement && el.parentElement !== body ? name(el.parentElement) : "", name(el)].filter(Boolean).join(" > ");
  const box = (el) => { const r = el.getBoundingClientRect(); return { l: r.left + SX, t: r.top + SY, r: r.right + SX, b: r.bottom + SY, w: r.width, h: r.height }; };
  const shown = (el) => { const cs = getComputedStyle(el); return cs.display !== "none" && cs.visibility !== "hidden" && +cs.opacity > 0; };
  const all = body ? [...body.querySelectorAll("*")].filter((el) => !el.closest("script,style,template,noscript")) : [];
  const transparent = (c) => !c || c === "transparent" || /rgba\([^)]*,\s*0\)$/.test(c);

  // 내용: 보이는 글자 줄, 그림·입력 요소, 배경 그림이 있는 상자. 빈 띠·잘림은 이것을 기준으로 본다.
  const content = [];
  const REPLACED = "img,svg,canvas,video,iframe,input,select,textarea,button,picture,object,embed,[role=img]";
  if (body) {
    const tw = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
    for (let n = tw.nextNode(); n; n = tw.nextNode()) {
      if (!n.data.trim() || !n.parentElement || n.parentElement.closest("script,style,template,noscript")) continue;
      if (!shown(n.parentElement)) continue;
      const rg = document.createRange();
      rg.selectNodeContents(n);
      for (const r of rg.getClientRects()) if (r.width > 0 && r.height > 0) content.push({ node: n, l: r.left + SX, t: r.top + SY, r: r.right + SX, b: r.bottom + SY });
    }
  }
  for (const el of all) {
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden") continue;
    if (el.matches(REPLACED) || (cs.backgroundImage && cs.backgroundImage !== "none")) {
      const b = box(el);
      if (b.w > 0 && b.h > 0) content.push({ node: el, ...b });
    }
  }

  // 1. 가로 넘침: 문서가 뷰포트보다 넓어 페이지 전체가 옆으로 밀린다(루트가 숨김이면 스크롤이 생기지 않으므로 보지 않는다).
  const rootClipsX = ["hidden", "clip"].includes(getComputedStyle(de).overflowX) || (body && ["hidden", "clip"].includes(getComputedStyle(body).overflowX));
  if (!rootClipsX && de.scrollWidth > VW + 1) {
    const culprits = all.filter((el) => {
      const b = box(el), p = el.parentElement && box(el.parentElement);
      return b.w > 0 && b.r > VW + 1 && (!p || p.r <= VW + 1) && getComputedStyle(el).position !== "fixed";
    }).slice(0, 3);
    issues.push({ kind: "overflow-x", key: "overflow-x", detail: `document is ${de.scrollWidth}px wide in a ${VW}px viewport` + (culprits.length ? `: ${culprits.map((el) => `${path(el)} reaches ${Math.round(box(el).r)}px`).join("; ")}` : "") });
  }

  // 2. 잘린 글자: 넘침을 숨기는 상자의 경계가 글자 줄을 가로지른다(줄 일부만 보임).
  //    말줄임(text-overflow: ellipsis)·줄 수 제한(line-clamp)·화면 낭독 전용(1~2px 상자)·통째로 숨긴 줄(접힌 영역)은 의도된 숨김이라 보지 않는다.
  for (const el of all) {
    const cs = getComputedStyle(el);
    const hx = ["hidden", "clip"].includes(cs.overflowX), hy = ["hidden", "clip"].includes(cs.overflowY);
    if (!(hx || hy) || !shown(el)) continue;
    const r0 = el.getBoundingClientRect();
    if (r0.width <= 2 || r0.height <= 2) continue;
    const cl = r0.left + SX + el.clientLeft, ct = r0.top + SY + el.clientTop, cr = cl + el.clientWidth, cb = ct + el.clientHeight;
    const ellipsis = cs.textOverflow === "ellipsis";
    const clamp = cs.webkitLineClamp && cs.webkitLineClamp !== "none";
    let hit = null;
    for (const c of content) {
      if (!(c.node.nodeType === 3) || !el.contains(c.node)) continue;
      // 가장 가까운 자르는 상자가 이 상자일 때만(안쪽 스크롤 상자가 있으면 그 상자 몫이다).
      let a = c.node.parentElement, nearest = null;
      for (; a && a !== el.parentElement; a = a.parentElement) {
        const s = getComputedStyle(a);
        if (["hidden", "clip", "auto", "scroll"].includes(s.overflowX) || ["hidden", "clip", "auto", "scroll"].includes(s.overflowY)) { nearest = a; break; }
      }
      if (nearest !== el) continue;
      const cutX = hx && !ellipsis && c.l < cr - 1 && c.r > cr + 1;
      const cutY = hy && !clamp && c.t < cb - 1 && c.b > cb + 1;
      if (cutX || cutY) { hit = { c, axis: cutX ? "right" : "bottom" }; break; }
    }
    if (hit) issues.push({ kind: "clipped", key: "clipped:" + path(el), detail: `${path(el)} cuts the text "${hit.c.node.data.trim().slice(0, 40)}" at its ${hit.axis} edge` });
  }

  // 3. 본문 앞 빈 띠: 본문(main)이 시작하기 전에 화면 전체 폭에 내용이 없는 높은 띠가 있다(늘어난 머리 줄·사이드바 줄).
  //    본문 안의 여백(히어로·섹션 패딩)과 본문 뒤 여백(짧은 페이지의 바닥)은 보지 않는다.
  const main = document.querySelector("main, [role=main]");
  if (main && shown(main)) {
    const mt = box(main).t;
    const band = Math.max(160, Math.round(VH * 0.18));
    const above = content.filter((c) => c.t < mt - 1 && !main.contains(c.node)).map((c) => Math.min(c.b, mt));
    const from = above.length ? Math.max(...above) : 0;
    if (mt - from >= band) {
      issues.push({ kind: "empty-band", key: "empty-band:before-main", detail: `${Math.round(mt - from)}px band with no content from y=${Math.round(from)} to the start of ${name(main)} at y=${Math.round(mt)} (threshold ${band}px)` });
    }
  }

  // 4. 배경이 못 채움: (a) 본문을 감싸 화면 폭 전체를 칠한 뼈대가 뷰포트보다 짧게 끝나 아래로 다른 바탕색이 보인다.
  //    (b) 가장자리 열(사이드바 등)의 배경이 부모보다 먼저 끝나 스크롤하면 열 아래가 비어 보인다.
  //    sticky·fixed 열은 스크롤해도 뷰포트를 따라오므로, 뷰포트 높이를 채우면 통과다(전체 캡처에서만 끊겨 보인다).
  const effBg = (el) => { for (let a = el; a; a = a.parentElement) { const c = getComputedStyle(a).backgroundColor; if (!transparent(c)) return c; } return "rgb(255, 255, 255)"; };
  const canvas = !transparent(getComputedStyle(de).backgroundColor) ? getComputedStyle(de).backgroundColor : body && !transparent(getComputedStyle(body).backgroundColor) ? getComputedStyle(body).backgroundColor : "rgb(255, 255, 255)";
  for (const el of all) {
    const cs = getComputedStyle(el);
    if (transparent(cs.backgroundColor) || !shown(el) || el === main) continue;
    const b = box(el);
    const frame = main ? el.contains(main) : el.parentElement === body;
    if (frame && b.w >= VW * 0.95 && b.t <= 1 && b.b < VH - 8 && DOC_H <= VH + 1 && cs.backgroundColor !== canvas) {
      issues.push({ kind: "bg-short", key: "bg-short:" + path(el), detail: `${path(el)} paints the page but ends at y=${Math.round(b.b)} in a ${VH}px viewport; below it the page shows ${canvas}` });
      continue;
    }
    const p = el.parentElement;
    if (!p || p === de) continue;
    const pb = box(p);
    const edge = b.l - SX <= 1 || b.r - SX >= VW - 1;
    if (!edge || b.w >= VW * 0.5 || b.h < VH * 0.5 || b.t - pb.t > 2 || cs.backgroundColor === effBg(p)) continue;
    const pinned = ["sticky", "fixed"].includes(cs.position);
    const short = pinned ? b.h < Math.min(VH, pb.h) - 1 : pb.b - b.b >= 24;
    if (short) issues.push({ kind: "bg-short", key: "bg-short:" + path(el), detail: `${path(el)} column background ends at y=${Math.round(b.b)} while its container runs to y=${Math.round(pb.b)}${pinned ? " and it does not fill the viewport" : ""}` });
  }

  return { probe: "layout-probe/1", viewport: { w: VW, h: VH }, document: { w: de.scrollWidth, h: DOC_H }, issues };
})()
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

# 이어 가는 명령은 에이전트를 부르기 전에(approve는 묻기 전에, approve·revise는 그 명령의 진입 조건을 본 뒤) 기준점을 대조한다.
[[ "$CMD" != resume ]] || check_baseline

case "$CMD" in
  status)
    jq -r '"run \(.run_id) · workflow \(.workflow // "feature") · node \(.node) · status \(.status) · repair \(.attempts) · approval \(.policy.approval // "human") (\(.policy.approval_source // "legacy")) · git_policy \(.policy.git // "")\n" + (.history | map("  \(.from) --\(if .outcome == "" then "next" else .outcome end)--> \(.to)") | join("\n"))' "$STATE"
    [[ "$(state .status)" == waiting_approval && -f "$RUN/brief.json" ]] && print_brief
    exit 0
    ;;
  revise)
    [[ -n "$FEEDBACK" || -n "$SELECT" ]] || usage
    [[ "$(state .node)" == approval ]] || { printf 'revise works only while waiting for approval of a brief (node: %s)\n' "$(state .node)" >&2; exit 2; }
    [[ -z "$SELECT" || -z "$FEEDBACK" ]] || { printf -- '--select and --feedback are separate revisions; run one, then the other\n' >&2; exit 2; }
    check_baseline
    if [[ -n "$SELECT" ]]; then
      # 고칠 항목 선택은 결정적이다: 목록에 있는 ID만 받고, 바뀐 목록을 다시 보여 주며 새 승인을 기다린다.
      sel="$(jq -cn --arg s "$SELECT" '[$s | splits("[,[:space:]]+") | select(length > 0) | ascii_upcase] | unique')"
      unknown="$(jq -r --argjson s "$sel" '[$s[] as $i | select([.items[].id] | index($i) | not) | $i] | join(", ")' "$RUN/diagnose.out")"
      [[ -z "$unknown" ]] || { printf 'not in the fix list: %s (ids: %s)\n' "$unknown" "$(jq -r '[.items[].id] | join(", ")' "$RUN/diagnose.out")" >&2; exit 2; }
      [[ "$sel" != "[]" ]] || { printf -- '--select needs at least one id from the fix list\n' >&2; exit 2; }
      polish_brief "$sel"
      state_set '.status = "waiting_approval"'
      print_brief
      log "selection changed to $(jq -r 'join(", ")' <<<"$sel"); waiting for approval: run $RUN_ID"
      exit 10
    fi
    state_set '.feedback = $f' --arg f "$FEEDBACK"
    go approval brief_changed_or_not_approved
    ;;
  approve)
    [[ "$(state .status)" == waiting_approval ]] || { printf 'nothing to approve (node: %s)\n' "$(state .node)" >&2; exit 2; }
    check_baseline
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

# 러너가 어떻게 멈추든(완료·대기·실패·중단) 그때의 상태를 기준점으로 남긴다. 불변식 위반은 러너가 허용하지 않은 변경이라
# 기준점으로 삼지 않는다 — 다음 resume이 에이전트를 부르기 전에 그 차이로 멈춘다.
trap '[[ "$(state .status 2>/dev/null)" == invariant_violation ]] || save_baseline || true' EXIT
state_set '.status = "running"'
execute
