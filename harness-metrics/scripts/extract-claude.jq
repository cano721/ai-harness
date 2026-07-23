# Claude Code transcript(.jsonl) → 압축 이벤트 스트림
# 사용: jq -c -n --arg sid .. --arg path .. --arg reason .. -f extract-claude.jq <transcript>
def utext:
  .message.content
  | if type=="string" then .
    elif type=="array" then (map(select(type=="object" and .type=="text") | .text) | join("\n"))
    else "" end;

def tool_uses: .message.content[]? | select(type=="object" and .type=="tool_use");
def tool_results: .message.content[]? | select(type=="object" and .type=="tool_result");
def result_text: .content | if type=="string" then . elif type=="array" then (map(.text? // "") | join(" ")) else "" end;

def counted(k): group_by(.) | map({kind:k, target:.[0], n:length}) | .[];

[inputs] as $L
| (first($L[] | select(.cwd? != null) | .cwd) // "") as $cwd
| ($cwd | split("/") | last | sub("-wt-[0-9]+$";"")) as $proj
| {v:1, src:"claude", sid:$sid, project:$proj} as $base

| ($L | map(select(.type=="user" and (utext|length)>0 and ((.message.content|type)=="string" or ([.|tool_results]|length)==0)))) as $userMsgs
| ($L | map(select(.type=="assistant" and .message.usage != null))) as $asst

# ── session 메타 ──
| ($base + {
    kind:"session",
    started: (first($L[] | .timestamp // empty) // null),
    ended:   ([$L[] | .timestamp // empty] | last // null),
    turns:   ($userMsgs|length),
    tok_in:  ([$asst[].message.usage | (.input_tokens//0)] | add // 0),
    tok_out: ([$asst[].message.usage | (.output_tokens//0)] | add // 0),
    cache_read: ([$asst[].message.usage | (.cache_read_input_tokens//0)] | add // 0),
    model:   ([$asst[].message.model // empty] | last // null),
    reason:  (if $reason=="" then null else $reason end),
    cwd: $cwd, transcript: $path
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
    | ltrimstr(" ") | split(" ")[0] | select(length>0) ]
  | counted("bash_cmd") | $base + . ),

# ── mcp_tool ──
( [ $L[] | tool_uses | select(.name | startswith("mcp__")) | .name ]
  | counted("mcp_tool") | $base + . ),

# ── jira_issue ──
( [ ($userMsgs[] | utext), ($L[] | tool_uses | select(.name=="Bash") | .input.command // "")
    | [match("(NJ|JDA|OP)-[0-9]+";"g").string] | .[] ]
  | counted("jira_issue") | $base + . ),

# ── 신호 카운트 ──
( [$L[] | tool_results | select(.is_error==true)] | length
  | select(.>0) | $base + {kind:"error", n:.} ),
( [$L[] | tool_results | result_text | select(test("Direct edit guard"))] | length
  | select(.>0) | $base + {kind:"guard_block", n:.} ),
( [$L[] | tool_results | result_text | select(test("doesn.t want to proceed|user rejected"))] | length
  | select(.>0) | $base + {kind:"permission_deny", n:.} ),
( [$L[] | select(.type=="summary" or .isCompactSummary==true)] | length
  | select(.>0) | $base + {kind:"compact", n:.} ),

# ── correction_mark: 사용자 교정 턴 (LLM 정독 지점 마킹) ──
# 주의: Apple jq(oniguruma)가 한글 alternation 정규식에서 깨져 startswith 사용
( $userMsgs[] | utext
  | select(startswith("아니") or startswith("아냐") or startswith("그게 아니라")
           or startswith("그거 말고") or startswith("그렇게 말고") or startswith("틀렸"))
  | $base + {kind:"correction_mark", target: .[0:60], n:1} )
