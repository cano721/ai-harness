# events/*.jsonl (slurp) → 마크다운 통계
# 인자: $cutoff (ISO, ""=전체) / $project (""=전체)
def fmt: tostring;
def rank(k; top): map(select(.kind==k))
  | group_by(.target) | map({t: .[0].target, n: (map(.n)|add)})
  | sort_by(-.n) | .[0:top];
def table(rows): if (rows|length)==0 then "_(없음)_" else
  (rows | map("| \(.t) | \(.n) |") | join("\n")) end;

. as $all
| ($all | map(select(.kind=="session"
    and ($project=="" or .project==$project)
    and ($cutoff=="" or ((.ended // .started // "") >= $cutoff))))) as $S
| ($S | map(.sid)) as $sids
| ($all | map(select(.kind!="session" and (.sid as $s | $sids | index($s))))) as $E

| "# Harness Metrics"
+ "\n\n기간: \(if $cutoff=="" then "전체" else $cutoff + " 이후" end)"
+ (if $project=="" then "" else " / 프로젝트: \($project)" end)

+ "\n\n## 세션 (프로젝트별)\n\n| 프로젝트 | 세션 | 턴 | in tok | out tok | cache read |\n|---|---|---|---|---|---|\n"
+ ($S | group_by(.project) | map({p:.[0].project, s:length,
      t:(map(.turns//0)|add), i:(map(.tok_in//0)|add),
      o:(map(.tok_out//0)|add), c:(map(.cache_read//0)|add)})
   | sort_by(-.s)
   | map("| \(.p) | \(.s) | \(.t) | \(.i) | \(.o) | \(.c) |") | join("\n"))

+ "\n\n## 워크플로/커맨드\n\n| 대상 | 횟수 |\n|---|---|\n" + table($E | rank("workflow"; 15))
+ "\n\n## 하네스 docs 읽힘\n\n| 문서 | 횟수 |\n|---|---|\n" + table($E | rank("doc_read"; 15))
+ "\n\n## 페르소나 위임\n\n| 페르소나 | 횟수 |\n|---|---|\n" + table($E | rank("persona"; 10))
+ "\n\n## Bash 명령 (상위)\n\n| 명령 | 횟수 |\n|---|---|\n" + table($E | rank("bash_cmd"; 10))
+ "\n\n## 편집 핫스팟 (상위)\n\n| 파일 | 횟수 |\n|---|---|\n" + table($E | rank("file_edit"; 10))
+ "\n\n## MCP 툴\n\n| 툴 | 횟수 |\n|---|---|\n" + table($E | rank("mcp_tool"; 10))
+ "\n\n## Jira 이슈 언급\n\n| 이슈 | 횟수 |\n|---|---|\n" + table($E | rank("jira_issue"; 10))

+ "\n\n## 신호\n\n| 종류 | 합계 |\n|---|---|\n"
+ (["error","guard_block","permission_deny","compact"]
   | map(. as $k | "| \($k) | \([$E[] | select(.kind==$k) | .n] | add // 0) |") | join("\n"))

+ "\n\n## 교정 마크 (LLM 정독 후보)\n\n"
+ (($E | map(select(.kind=="correction_mark"))) as $c
   | if ($c|length)==0 then "_(없음)_"
     else ($c | .[0:20] | map("- [\(.sid[0:8])] \(.target)") | join("\n")) end)
+ "\n"
