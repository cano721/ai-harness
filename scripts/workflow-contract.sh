#!/usr/bin/env bash
# 워크플로 계약 리포트 (읽기 전용). /harness-init --sync 계획에 붙인다.
#   scan --root <dir>  : 보호 파일(워크플로 본문·페르소나·settings)을 관리 생성물(그래프·어댑터)과 대조해 JSON으로 낸다.
# 본문은 초기화 때 LLM이 쓴 보호 파일이라 관리 해시가 일치해도 의미가 어긋난다. 기계로 확인 가능한 토큰만 본다.
set -euo pipefail

usage() {
  printf 'usage: %s scan --root <dir>\n' "$0" >&2
  exit 2
}

command_name="${1:-}"
[[ -n "$command_name" ]] || usage
shift

root=""
while (($#)); do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$command_name" == "scan" ]] || usage
[[ -n "$root" && -d "$root" ]] || usage
root="$(cd "$root" && pwd -P)"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/workflow-contract.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/findings.jsonl"

rel() { printf '%s' "${1#"$root"/}"; }

finding() { # check severity file line token expected message
  jq -cn --arg check "$1" --arg severity "$2" --arg file "$3" --arg line "$4" \
    --arg token "$5" --arg expected "$6" --arg message "$7" \
    '{check:$check, severity:$severity, file:$file, line:($line|tonumber? // null), token:$token,
      expected:(if $expected=="" then null else $expected end), message:$message}' >>"$TMP/findings.jsonl"
}

# grep -n 결과를 "줄번호<TAB>본문"으로. 매치가 없으면 빈 출력.
lines_matching() { # regex file
  grep -n -E -- "$1" "$2" 2>/dev/null | sed 's/:/\t/' || true
}

bodies=()
for f in "$root"/.ai-harness/workflows/*.md; do [[ -f "$f" ]] && bodies+=("$f"); done
personas=()
for f in "$root"/.ai-harness/agents/*.md "$root"/.claude/agents/*.md "$root"/.codex/agents/*.toml; do
  [[ -f "$f" ]] && personas+=("$f")
done

# ── 그래프의 수리 한도 ────────────────────────────────────────────────────────
graph_limit=""
graph="$root/.ai-harness/workflows/feature-delivery-graph.json"
if [[ -f "$graph" ]]; then
  graph_limit="$(jq -r '
    [.transitions[]?.when // empty | (capture("after_(?<n>[a-z0-9]+)_attempts") | .n)?] | first // empty
    | ({"one":"1","two":"2","three":"3","four":"4","five":"5"}[.] // .)' "$graph" 2>/dev/null || true)"
fi

for body in ${bodies[@]+"${bodies[@]}"}; do
  file="$(rel "$body")"
  name="$(basename "$body" .md)"

  # 존재하지 않는 도구: Claude에 /plan·/team 커맨드는 없고, 위임 도구 이름은 Task가 아니라 Agent다.
  while IFS=$'\t' read -r n text; do
    [[ -n "$n" ]] || continue
    while IFS= read -r token; do
      [[ -n "$token" ]] || continue
      finding nonexistent_tool high "$file" "$n" "$token" "" "존재하지 않는 도구를 참조한다 — Claude 위임은 Agent 도구의 subagent_type, 계획은 대화 안의 Brief"
    done < <(grep -o -E '(^|[^A-Za-z0-9_./-])/(plan|team)([^A-Za-z0-9_-]|$)|Task (도구|tool)' <<<"$text" \
               | sed -E 's#^[^/T]*(/(plan|team)|Task (도구|tool)).*$#\1#')
  done < <(lines_matching '(^|[^A-Za-z0-9_./-])/(plan|team)([^A-Za-z0-9_-]|$)|Task (도구|tool)' "$body")

  # 그래프와 다른 반복 한도
  if [[ -n "$graph_limit" ]]; then
    while IFS=$'\t' read -r n text; do
      [[ -n "$n" ]] || continue
      count="$(sed -E 's/.*(최대|[Mm]ax(imum)?|[Uu]p to)[[:space:]]*([0-9]+)[[:space:]]*(회|번|times|attempts|rounds).*/\3/' <<<"$text")"
      [[ "$count" =~ ^[0-9]+$ && "$count" != "$graph_limit" ]] || continue
      finding repair_limit high "$file" "$n" "$count" "$graph_limit" "본문의 반복 한도가 그래프(같은 원인 ${graph_limit}회 뒤 사용자 판단)와 다르다 — 숫자를 본문에 따로 두지 말고 그래프를 따른다"
    done < <(lines_matching '(최대|[Mm]ax(imum)?|[Uu]p to)[[:space:]]*[0-9]+[[:space:]]*(회|번|times|attempts|rounds)' "$body")
  fi

  # 위반 시 폐기
  while IFS=$'\t' read -r n text; do
    [[ -n "$n" ]] || continue
    finding discard_on_violation high "$file" "$n" "폐기" "" "역할 범위 위반 시 변경을 폐기하라고 한다 — 중단·diff 보존·범위 확인 후 재위임"
  # "폐기하지 않는다"처럼 harness-init이 쓰라고 지시하는 부정 문장은 위반이 아니다.
  done < <(lines_matching '폐기.*(위반|재위임)|(위반|재위임).*폐기|[Dd]iscard.*(change|diff)' "$body" \
    | grep -v -E '폐기하지 않|폐기 금지|폐기하지 말|[Dd]o not discard|[Nn]ever discard|[Dd]on.t discard' || true)

  # 범위 없는 codex exec: 기본 sandbox가 읽기 전용이라 쓰기 단계를 수행할 수 없다.
  while IFS=$'\t' read -r n text; do
    [[ -n "$n" ]] || continue
    if grep -q -E -- '(^|[[:space:]])(-C|--cd)[[:space:]]' <<<"$text" && grep -q -E -- '(^|[[:space:]])(-s|--sandbox)[[:space:]]' <<<"$text"; then
      continue
    fi
    finding codex_exec_unbounded high "$file" "$n" "codex exec" "" "codex exec에 대상 저장소(-C)와 sandbox(-s)가 없다 — 기본 sandbox는 읽기 전용"
  done < <(lines_matching 'codex exec' "$body")

  # 어댑터가 금지한 PR 단계를 본문이 필수로 둔다.
  adapter=""
  for a in "$root/.claude/commands/$name.md" "$root/.agents/skills/$name/SKILL.md"; do
    [[ -f "$a" ]] && grep -q 'create a PR' "$a" && { adapter="$(rel "$a")"; break; }
  done
  if [[ -n "$adapter" ]]; then
    while IFS=$'\t' read -r n text; do
      [[ -n "$n" ]] || continue
      finding pr_step_forbidden_by_adapter medium "$file" "$n" "PR" "" "본문이 PR 생성을 단계로 두는데 어댑터($adapter)는 별도 승인 없는 PR 생성을 금지한다 — git 정책과 사용자 승인 조건으로 둔다"
    done < <(lines_matching '^#{2,4} .*(PR (생성|작성|올리)|Pull Request|[Cc]reate (a )?PR)' "$body")
  fi
done

# ── fix-bug 회귀 테스트 역할 ──────────────────────────────────────────────────
fix_body="$root/.ai-harness/workflows/fix-bug.md"
if [[ -f "$fix_body" ]]; then
  dev_bars_tests=""
  for p in "$root/.ai-harness/agents/developer.md" "$root/.claude/agents/developer.md" "$root/.codex/agents/developer.toml"; do
    [[ -f "$p" ]] || continue
    if grep -q -i -E '(금지|forbid|must not|do not|never).*test|test.*(금지|forbid)' "$p"; then dev_bars_tests="$(rel "$p")"; break; fi
  done
  # 본문이 developer 페르소나로 진행하면서 회귀 테스트를 요구하고 test-engineer를 부르지 않으면 충돌이다.
  if [[ -n "$dev_bars_tests" ]] && grep -q 'developer' "$fix_body" && ! grep -q 'test-engineer' "$fix_body"; then
    while IFS=$'\t' read -r n text; do
      [[ -n "$n" ]] || continue
      finding regression_role high "$(rel "$fix_body")" "$n" "developer" "test-engineer" "회귀 테스트를 developer 흐름에 두는데 $dev_bars_tests 는 테스트 편집을 금지한다 — 회귀 테스트는 test-engineer"
    done < <(lines_matching '회귀[^.]{0,8}테스트|[Rr]egression test' "$fix_body")
  fi
fi

# ── 페르소나 쓰기 범위가 실제 파일과 맞는가 ───────────────────────────────────
if ((${#personas[@]})); then
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" ls-files >"$TMP/files.txt"
  else
    (cd "$root" && find . -type f -not -path './.git/*' | sed 's#^\./##') >"$TMP/files.txt"
  fi
  for p in "${personas[@]}"; do
    while IFS=$'\t' read -r n text; do
      [[ -n "$n" ]] || continue
      # shellcheck disable=SC2016  # 정규식·백틱·변수 이름을 문자 그대로 쓴다
      while IFS= read -r glob; do
        [[ "$glob" == *'*'* ]] || continue
        re="$(sed -E 's/[.+?^$(){}|[\]\\]/\\&/g; s#\*\*/#__DSS__#g; s#\*\*#__DS__#g; s#\*#[^/]*#g; s#__DSS__#(.*/)?#g; s#__DS__#.*#g' <<<"$glob")"
        grep -q -E "^${re}$" "$TMP/files.txt" && continue
        finding write_scope_unmatched medium "$(rel "$p")" "$n" "$glob" "" "쓰기 범위가 저장소의 어떤 파일과도 맞지 않는다 — 실측 모듈 경로로 쓴다"
      done < <(grep -o -E '`[^`]+`' <<<"$text" | tr -d '`')
    done < <(lines_matching '[Ww]rite [Ss]cope|쓰기 범위|write_scope' "$p")
  done
fi

# ── 가드 hook 경로 ────────────────────────────────────────────────────────────
for s in "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
  [[ -f "$s" ]] || continue
  while IFS= read -r cmd; do
    [[ "$cmd" == *CLAUDE_PROJECT_DIR* ]] || continue
    finding guard_project_dir medium "$(rel "$s")" "" "CLAUDE_PROJECT_DIR" "" "hook 경로가 CLAUDE_PROJECT_DIR 기준이다 — /cd로 들어온 세션에서 이 변수는 시작 디렉토리를 가리킨다. git root 기준으로 쓴다"
  done < <(jq -r '.hooks // {} | .[][]?.hooks[]?.command // empty' "$s" 2>/dev/null || true)
done

jq -s \
  --arg root "$root" \
  --arg graph_limit "$graph_limit" \
  '{
     root: $root,
     graph_repair_limit: (if $graph_limit=="" then null else ($graph_limit|tonumber) end),
     findings: .,
     contract_drift: (length > 0)
   }' "$TMP/findings.jsonl"
