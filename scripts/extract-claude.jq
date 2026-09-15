# Claude Code transcript(.jsonl) → 압축 이벤트 스트림
# 사용: jq -c -R -n --argjson event_version .. --arg sid .. --arg project .. -f extract-claude.jq transcript
def utext:
  .message.content
  | if type=="string" then .
    elif type=="array" then (map(select(type=="object" and .type=="text") | .text) | join("\n"))
    else "" end;

def tool_uses: .message.content[]? | select(type=="object" and .type=="tool_use");
def tool_results: .message.content[]? | select(type=="object" and .type=="tool_result");
def result_text: .content | if type=="string" then . elif type=="array" then (map(.text? // "") | join(" ")) else "" end;

def counted(k): group_by(.) | map({kind:k, target:.[0], n:length}) | .[];

# 교정 신호 정의는 Codex 어댑터(scripts/extract-codex.sh)와 같은 목록을 쓴다 — 한쪽만 고치면
# 플랫폼 간 수치 비교가 깨진다.
def is_correction:
  startswith("아니") or startswith("아냐") or startswith("그게 아니라")
  or startswith("그거 말고") or startswith("그렇게 말고") or startswith("틀렸");
# 후보 그물. 접두어가 아니라 문장 어디에 있어도 잡는다.
def correction_hints:
  ["안 되", "안되", "안돼", "안 돼", "이상해", "이상하", "틀려", "틀린",
   "여전히", "제대로", "아직도", "잘못", "왜 안", "왜 아직", "다시 해", "다시해",
   "안 나와", "안나와", "안 뜨", "안뜨", "못 찾", "못찾", "실패했", "빠졌", "빼먹",
   "맞아?", "맞나?", "한 거 맞", "한거 맞",
   "doesn't work", "does not work", "not working", "still fails", "still failing",
   "that's wrong", "thats wrong", "you missed", "didn't work"];
# 긴 턴은 새 지시일 확률이 높다.
def correction_candidate_max_len: 200;
# 발췌는 /metrics가 마크다운 불릿으로 렌더하므로 한 줄로 접는다. 붙여넣기가 섞인 턴은
# 개행이 그대로 들어와 리스트를 깨뜨린다 — 실측 후보 79건 중 23건(29%)이 개행 포함이었다.
def excerpt: gsub("\\s+"; " ") | .[0:60];

# -R 원시 입력 + fromjson? — 손상된 라인은 그 줄만 버리고 나머지 보존 (한 줄 깨짐 = 세션 전체 소실 방지)
[inputs | fromjson? // empty] as $L
| (first($L[] | select(.cwd? != null) | .cwd) // "") as $cwd
| {v:$event_version, src:"claude", sid:$sid, project:$project} as $base
| ($L | length) as $n

| ($L | map(select(.type=="user" and (utext|length)>0 and ((.message.content|type)=="string" or ([.|tool_results]|length)==0)))) as $userMsgs
| ($L | map(select(.type=="assistant" and .message.usage != null))) as $asst
# tool_result → 호출한 툴 이름 (tool_use_id 기준). 신호를 "어느 툴의 결과인가"로 가릴 때 쓴다.
| ($L | [.[] | tool_uses | select(.id != null) | {key:.id, value:.name}] | from_entries) as $toolNames

# ── session 메타 (빈 transcript는 유령 세션 방지 위해 미기록) ──
| (select($n > 0) | $base + {
    kind:"session",
    started: (first($L[] | .timestamp // empty) // null),
    ended:   ([$L[] | .timestamp // empty] | last // null),
    turns:   ($userMsgs|length),
    tok_in:  ([$asst[].message.usage | (.input_tokens//0)] | add // 0),
    tok_out: ([$asst[].message.usage | (.output_tokens//0)] | add // 0),
    cache_read: ([$asst[].message.usage | (.cache_read_input_tokens//0)] | add // 0),
    cache_write: ([$asst[].message.usage | (.cache_creation_input_tokens//0)] | add // 0),
    model:   ([$asst[].message.model // empty | select(startswith("<") | not)] | last // null),
    reason:  (if $reason=="" then null else $reason end),
    cwd: $cwd, transcript: $path, source_mtime:$source_mtime, source_size:$source_size,
    coverage: [
      "workflow", "persona", "doc_read", "file_edit", "bash_cmd", "mcp_tool",
      "jira_issue", "error", "guard_block", "permission_deny", "compact",
      "correction_mark", "correction_candidate"
    ]
  }),

# ── workflow: /커맨드 + Skill 호출 ──
( [ ($userMsgs[] | utext | capture("<command-name>/?(?<c>[a-z0-9:_-]+)</command-name>").c),
    ($userMsgs[] | utext | select(test("^/[a-z]")) | capture("^/(?<c>[a-z0-9:_-]+)").c),
    ($L[] | tool_uses | select(.name=="Skill") | .input.skill // empty)
  ] | counted("workflow") | $base + . ),

# ── persona: 서브에이전트 위임 ──
( [ $L[] | tool_uses | select(.name=="Task" or .name=="Agent") | .input.subagent_type // "general-purpose" ]
  | counted("persona") | $base + . ),

# ── doc_read: 하네스 문서 읽힘 ──
( [ $L[] | tool_uses | select(.name=="Read") | .input.file_path // empty
    | select(type=="string")
    | select(test("\\.ai-harness/|AGENTS\\.md$|CLAUDE\\.md$"))
    | if test("\\.ai-harness/") then ".ai-harness/" + (split(".ai-harness/")[1])
      elif endswith("AGENTS.md") then "AGENTS.md"
      else "CLAUDE.md" end ]
  | counted("doc_read") | $base + . ),

# ── file_edit: 편집 핫스팟 ──
( [ $L[] | tool_uses | select(.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")
    | (.input.file_path // .input.notebook_path // empty) ]
  | counted("file_edit") | $base + . ),

# ── bash_cmd: 명령 첫 토큰 ──
( [ $L[] | tool_uses | select(.name=="Bash") | .input.command // empty
    | select(type=="string")
    | ltrimstr(" ") | split(" ")[0] | select(length>0) ]
  | counted("bash_cmd") | $base + . ),

# ── mcp_tool ──
( [ $L[] | tool_uses | select(.name | startswith("mcp__")) | .name ]
  | counted("mcp_tool") | $base + . ),

# ── jira_issue (패턴은 $issue_re — lib.sh HM_ISSUE_RE) ──
( [ ($userMsgs[] | utext),
    ($L[] | tool_uses | select(.name=="Bash") | .input.command // "" | select(type=="string"))
    | [match($issue_re;"g").string] | .[] ]
  | counted("jira_issue") | $base + . ),

# ── 신호 카운트 ──
# 출력이 없는 실패는 세지 않는다 — `grep -q`·`test`처럼 종료코드를 판정문으로 쓴 호출이라
# 진단할 내용이 없다. 실측: Bash is_error 483건 중 16건(3%)이 본문 없음.
( [$L[] | tool_results | select(.is_error==true)
    | select((result_text | sub("^Exit code [0-9]+";"") | gsub("\\s";"")) != "")] | length
  | select(.>0) | $base + {kind:"error", n:.} ),
# 훅 차단은 편집 툴(Edit/Write/MultiEdit/NotebookEdit)의 is_error 결과로만 온다 — 가드 훅이 그 툴에만 걸린다.
# 같은 문구가 Bash 결과(git log 커밋 메시지, 실패한 cat AGENTS.md)나 Read 출력에 섞여도 차단이 아니다.
# 전 transcript 실측: is_error+문구 4건이 전부 "Exit code 1"로 시작하는 Bash 출력이었다.
# tool_use_id가 없거나($toolNames에 없는 id) 툴을 알 수 없는 결과 — 구형 transcript, tool_use가 압축으로
# 사라진 경우 — 는 줄 시작 접두어만으로 판정해 진짜 차단을 놓치지 않는다. 실측 차단 51건은 전부
# "PreToolUse:<툴> hook error: [<훅 경로>]: [Direct edit guard] ..." 형태이고, 오탐은 전부 줄 중간 문구였다.
( [$L[] | tool_results | select(.is_error==true)
    | (($toolNames[.tool_use_id // ""] // "")) as $tool
    | select($tool == "" or ($tool | IN("Edit","Write","MultiEdit","NotebookEdit")))
    | result_text
    | select(test("(^|\\n)(PreToolUse:[A-Za-z]+ hook error: .*)?\\[Direct edit guard\\]"))] | length
  | select(.>0) | $base + {kind:"guard_block", n:.} ),
# 권한 거부는 is_error 결과이고 거부 문구로 시작한다. 추출기 소스·PR 본문·커밋 메시지 속 같은 문구는 거부가 아니다.
# 실측: 거부 메시지는 "The user doesn't want to proceed with this tool use." 한 형태뿐이라 그것만 센다.
# AskUserQuestion에서 사용자가 "clarify"를 고르면 같은 거부 문구가 오지만 권한 거부가 아님
( [$L[] | tool_results | select(.is_error==true) | result_text
    | select(test("^The user doesn.t want to proceed"))
    | select(test("wants to clarify these questions") | not)] | length
  | select(.>0) | $base + {kind:"permission_deny", n:.} ),
( [$L[] | select(.type=="summary" or .isCompactSummary==true)] | length
  | select(.>0) | $base + {kind:"compact", n:.} ),

# ── correction_mark: 사용자 교정 턴 (LLM 정독 지점 마킹) ──
# 주의: Apple jq(oniguruma)가 한글 alternation 정규식에서 깨져 startswith 사용
( $userMsgs[] | utext
  | select(is_correction)
  | $base + {kind:"correction_mark", target: excerpt, n:1} ),

# ── correction_candidate: 교정일 수 있는 턴 (판정은 /harvest가 격리 컨텍스트에서) ──
# 접두어 매칭은 "아니…"로 시작하는 교정만 잡는다. 실제 불만은 문장 중간에 온다
# ("스웨거 링크 이상해", "둘다 여전히 접근 안되잖아"). 넓게 줍고 판정은 미룬다 —
# 이 이벤트는 그 자체로 교정이 아니라 **읽어볼 지점**이다.
# 긴 턴은 새 지시일 확률이 높아 길이로 자른다. 슬래시 커맨드·붙여넣기는 제외된다.
( $userMsgs[] | utext
  | select(is_correction | not)
  | select(length <= correction_candidate_max_len)
  | select(startswith("/") | not)
  | . as $t
  | select(any(correction_hints[]; . as $h | $t | contains($h)))
  | $base + {kind:"correction_candidate", target: excerpt, n:1} )
