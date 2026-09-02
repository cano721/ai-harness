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

# -R 원시 입력 + fromjson? — 손상된 라인은 그 줄만 버리고 나머지 보존 (한 줄 깨짐 = 세션 전체 소실 방지)
[inputs | fromjson? // empty] as $L
| (first($L[] | select(.cwd? != null) | .cwd) // "") as $cwd
| {v:$event_version, src:"claude", sid:$sid, project:$project} as $base
| ($L | length) as $n

| ($L | map(select(.type=="user" and (utext|length)>0 and ((.message.content|type)=="string" or ([.|tool_results]|length)==0)))) as $userMsgs
| ($L | map(select(.type=="assistant" and .message.usage != null))) as $asst

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
      "correction_mark"
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
( [$L[] | tool_results | select(.is_error==true)] | length
  | select(.>0) | $base + {kind:"error", n:.} ),
# 훅 차단은 is_error 결과로만 온다. 같은 문구가 git log·PR 본문·AGENTS.md Read 출력(is_error 아님)에
# 섞여도 차단이 아니다 — 이 저장소의 커밋 메시지 자체가 "[Direct edit guard]"를 담고 있다.
( [$L[] | tool_results | select(.is_error==true) | result_text
    | select(test("\\[Direct edit guard\\]"))] | length
  | select(.>0) | $base + {kind:"guard_block", n:.} ),
# AskUserQuestion에서 사용자가 "clarify"를 고르면 같은 거부 문구가 오지만 권한 거부가 아님
( [$L[] | tool_results | result_text
    | select(test("doesn.t want to proceed|user rejected"))
    | select(test("wants to clarify these questions") | not)] | length
  | select(.>0) | $base + {kind:"permission_deny", n:.} ),
( [$L[] | select(.type=="summary" or .isCompactSummary==true)] | length
  | select(.>0) | $base + {kind:"compact", n:.} ),

# ── correction_mark: 사용자 교정 턴 (LLM 정독 지점 마킹) ──
# 주의: Apple jq(oniguruma)가 한글 alternation 정규식에서 깨져 startswith 사용
( $userMsgs[] | utext
  | select(startswith("아니") or startswith("아냐") or startswith("그게 아니라")
           or startswith("그거 말고") or startswith("그렇게 말고") or startswith("틀렸"))
  | $base + {kind:"correction_mark", target: .[0:60], n:1} )
