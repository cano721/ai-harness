#!/usr/bin/env bash
set -euo pipefail
# Direct edit guard 예시 — harness-init이 SOURCE_RE·TEST_RE를 실측 경로로 바꿔 .ai-harness/hooks/direct-edit-guard.sh로 생성한다.
# 소스 파일을 고치기 전에 이 세션이 code-conventions.md(테스트면 testing.md도)를 실제로 읽었는지 transcript로 확인한다.
# '읽음'은 jq로 줄을 파싱해, 짝 결과(tool_result)가 성공인 호출 중 다음만 인정한다:
#   - assistant tool_use name == "Read"의 file_path
#   - 읽기 형태 셸 명령(cat·head·tail·nl·less·more·bat·grep·rg·sed -n)이 그 문서를 대상으로 할 때 — Claude는 Bash, Codex는 exec_command·shell.
#     문서로 쓸 수 있는 형태(리다이렉트·tee·sponge·sed -i·명령 연결·명령 치환)는 읽음이 아니다.
# Edit·Write·MultiEdit·apply_patch, 실패한 읽기는 읽음이 아니다. transcript를 문자열로 grep하면 쓰기 도구의 file_path,
# 사용자 메시지 속 경로에도 맞아 문서를 쓰기만 한 세션이 통과한다.
# 서브에이전트(입력에 agent_id)는 부모 transcript와 자기 transcript(<세션>/subagents/agent-<id>.jsonl)를 함께 본다.
# 기준 경로는 CLAUDE_PROJECT_DIR이 아니라 hook 입력 cwd의 git root다. jq·git root·transcript가 없으면 막지 않는다(fail-open).
# 경로는 NFC로 맞춰 비교한다(macOS는 폴더 이름을 NFD로 보존해 git과 도구 입력의 정규화가 다르다). python3가 없으면 그대로 비교한다.

SOURCE_RE='^(src|lib|app)/'
TEST_RE='(^|/)(tests?|__tests__)/|\.(test|spec)\.[^/]+$'

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)"
field() { jq -r "$1 // empty" <<<"$input" 2>/dev/null || true; }

case "$(field .tool_name)" in
  Edit | Write | MultiEdit | NotebookEdit) ;;
  *) exit 0 ;;
esac
file="$(field '.tool_input.file_path // .tool_input.notebook_path')"
cwd="$(field .cwd)"
transcript="$(field .transcript_path)"
agent="$(field .agent_id)"
[[ -n "$file" && -n "$cwd" ]] || exit 0

nfc() { # 비ASCII 경로만 NFC로 바꾼다. 파일시스템 조회는 원래 값으로 하고 비교할 출력에만 쓴다(Linux에선 NFC 경로가 다른 경로다).
  local LC_ALL=C
  if [[ "$1" == *[$'\x80'-$'\xff']* ]] && command -v python3 >/dev/null 2>&1; then
    python3 -I -X utf8 -c 'import sys,unicodedata;sys.stdout.write(unicodedata.normalize("NFC",sys.argv[1]))' "$1" 2>/dev/null && return
  fi
  printf '%s' "$1"
}

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
root="$(cd "$root" && pwd -P)" || exit 0
root="$(nfc "$root")"

physical() { # 경로의 디렉토리를 실제 경로로 푼다(없으면 그대로). 출력은 NFC
  local p="$1" d
  [[ "$p" == /* ]] || p="$cwd/$p"
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || {
    printf '%s\n' "$(nfc "$p")"
    return
  }
  printf '%s\n' "$(nfc "$d/$(basename "$p")")"
}

target="$(physical "$file")"
[[ "$target" == "$root/"* ]] || exit 0
rel="${target#"$root/"}"
[[ "$rel" =~ $SOURCE_RE ]] || exit 0

need=("code-conventions.md")
[[ "$rel" =~ $TEST_RE ]] && need+=("testing.md")

transcripts=()
[[ -n "$transcript" && -r "$transcript" ]] && transcripts+=("$transcript")
if [[ -n "$transcript" && -n "$agent" ]]; then
  sub="${transcript%.jsonl}/subagents/agent-$agent.jsonl"
  [[ -r "$sub" ]] && transcripts+=("$sub")
fi
((${#transcripts[@]})) || exit 0

# shellcheck disable=SC2016  # jq 프로그램이다
read_paths="$(jq -nrR '
  # 읽기 형태 셸 명령의 대상 후보. 문서로 쓸 수 있는 형태(리다이렉트·tee·sponge·sed -i·sed w·명령 연결·치환)는 통째로 뺀다.
  # grep·rg는 마지막 인자만 대상으로 본다 — 검색어·옵션 값 자리에 문서 경로를 넣어 찾기만 한 것은 읽음이 아니다. rg --files는 내용을 보이지 않는다.
  def read_targets($w):
    if type == "array" then (if length >= 3 and (.[1] == "-lc" or .[1] == "-c") then .[-1] else join(" ") end) else . end
    | select(type == "string")
    | select(test("^\\s*(cat|head|tail|nl|less|more|bat|grep|rg|sed\\s+-n)\\s")
        and (test(">|\\b(tee|sponge)\\b|[;&`]|\\|\\||\\$\\(|\\n") | not)
        and ((test("^\\s*sed\\s") and test("\\s(-[a-zA-Z]*i|--in-place)|[wW]\\s")) | not)
        and (test("^\\s*rg\\s.*--files\\b") | not))
    | [splits("\\s+") | gsub("^[\"'\'']+|[\"'\'']+$"; "") | select(length > 0)] as $t
    | (if $t[0] | test("^(grep|rg)$") then [$t[-1]] else $t[1:] end)[]
    | select(endswith(".md"))
    | if startswith("/") or $w == "" then . else $w + "/" + . end;
  [inputs | fromjson? // empty] as $rows
  # 짝 결과가 성공인 호출만 센다 — 없는 파일을 읽으려다 실패한 호출은 읽음이 아니다.
  | ([$rows[] | select(.type == "user") | .message.content[]?
      | select(type == "object" and .type == "tool_result")
      | {key: (.tool_use_id // ""), value: (.is_error != true)}] | from_entries) as $ok
  | ([$rows[] | select(.type == "response_item") | .payload
      | select(.type == "function_call_output")
      | {key: (.call_id // ""), value: ((.output // "") | (if type == "string" then . else tojson end)
          | (test("(^|\\n)(Process exited with code|Exit code:?) *[1-9]|\"exit_code\": *[1-9]") | not))}] | from_entries) as $cok
  | $rows[]
  | ( select(.type == "assistant")
      | (.cwd // "") as $cwd
      | .message.content[]?
      | select(type == "object" and .type == "tool_use" and $ok[.id // ""] == true)
      | if .name == "Read" then (.input.file_path // empty)
        elif .name == "Bash" then (.input.command // empty | read_targets($cwd))
        else empty end ),
    ( select(.type == "response_item")
      | .payload
      | select(.type == "function_call" and ((.name // "") | test("^(exec_command|shell|local_shell)$"))
          and $cok[.call_id // ""] == true)
      | (.arguments | fromjson? // {}) as $a
      | ($a.cmd // $a.command // empty)
      | read_targets($a.workdir // "") )
' "${transcripts[@]}" 2>/dev/null)" || exit 0

missing=()
for doc in "${need[@]}"; do
  found=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ "$(physical "$p")" == "$(physical "$root/.ai-harness/docs/$doc")" ]]; then
      found=1
      break
    fi
  done <<<"$read_paths"
  ((found)) || missing+=(".ai-harness/docs/$doc")
done
((${#missing[@]})) || exit 0

{
  printf '[Direct edit guard] %s 를 고치기 전에 Read 도구로 %s 를 읽으세요.\n' "$rel" "${missing[*]}"
  printf '문서를 쓰거나 고친 것은 읽은 것으로 보지 않습니다. 읽은 뒤 같은 편집을 다시 시도하세요.\n'
} >&2
exit 2
