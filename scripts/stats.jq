# events/*.jsonl (slurp) → 마크다운 통계
# 인자: $cutoff (ISO, ""=전체) / $project (""=전체)
def rank(k; top): map(select(.kind==k))
  | group_by(.target) | map({t: .[0].target, n: (map(.n)|add)})
  | sort_by(-.n) | .[0:top];

def coverage_count($sessions; $kind):
  [$sessions[] | select(((.coverage // []) | index($kind)) != null)] | length;

def metric_table($rows; $supported; $total):
  if $supported==0 then
    "_(수집 미지원 — 0회로 해석하면 안 됨)_"
  elif ($rows|length)==0 then
    "_(관측 가능 \($supported)세션에서 없음"
    + (if $supported<$total then "; \($total-$supported)세션 미지원" else "" end)
    + ")_"
  else
    ($rows | map("| \(.t) | \(.n) |") | join("\n"))
    + (if $supported<$total
       then "\n\n_관측 범위: \($supported)/\($total)세션; 나머지는 수집 미지원_"
       else "" end)
  end;

. as $all
| ($all | map(select(.kind=="session"
    and ($project=="" or .project==$project)
    and ($cutoff=="" or ((.ended // .started // "") >= $cutoff))))) as $S
# 배열 index 스캔(세션수×이벤트수)이 아니라 객체 lookup으로 소속 세션을 판정한다.
| ($S | map({(.sid): true}) | add // {}) as $sidset
| ($all | map(select(.kind!="session" and $sidset[.sid // ""] == true))) as $E
| ($S | length) as $total
| (coverage_count($S; "correction_mark")) as $correction_supported

| "# Harness Metrics"
+ "\n\n기간: \(if $cutoff=="" then "전체" else $cutoff + " 이후" end)"
+ (if $project=="" then "" else " / 프로젝트: \($project)" end)

+ "\n\n## 세션 (프로젝트별)\n\n| 프로젝트 | 세션 | 턴 | in tok | out tok | cache read | cache write |\n|---|---|---|---|---|---|---|\n"
+ ($S | group_by(.project) | map({p:.[0].project, s:length,
      t:(map(.turns//0)|add), i:(map(.tok_in//0)|add),
      o:(map(.tok_out//0)|add), c:(map(.cache_read//0)|add),
      w:(map(.cache_write//0)|add)})
   | sort_by(-.s)
   | if length==0 then "| _(없음)_ | 0 | 0 | 0 | 0 | 0 | 0 |"
     else map("| \(.p) | \(.s) | \(.t) | \(.i) | \(.o) | \(.c) | \(.w) |") | join("\n")
     end)

+ "\n\n## 수집 범위\n\n| 소스 | 세션 | 지원 범위 |\n|---|---|---|\n"
+ ($S | group_by(.src) | map({
      src:(.[0].src // "unknown"),
      n:length,
      coverage:([.[].coverage[]?] | unique | join(", "))
    })
   | if length==0 then "| _(없음)_ | 0 | - |"
     else map("| \(.src) | \(.n) | \(if .coverage=="" then "legacy event" else .coverage end) |") | join("\n")
     end)

+ "\n\n## 워크플로/커맨드\n\n| 대상 | 횟수 |\n|---|---|\n"
+ metric_table(($E | rank("workflow"; 15)); coverage_count($S; "workflow"); $total)
+ "\n\n## 하네스 docs 읽힘\n\n| 문서 | 횟수 |\n|---|---|\n"
+ metric_table(($E | rank("doc_read"; 15)); coverage_count($S; "doc_read"); $total)
+ "\n\n## 페르소나 위임\n\n| 페르소나 | 횟수 |\n|---|---|\n"
+ metric_table(($E | rank("persona"; 10)); coverage_count($S; "persona"); $total)
+ "\n\n## Bash 명령 (상위)\n\n| 명령 | 횟수 |\n|---|---|\n"
+ metric_table(($E | rank("bash_cmd"; 10)); coverage_count($S; "bash_cmd"); $total)
+ "\n\n## 편집 핫스팟 (상위)\n\n| 파일 | 횟수 |\n|---|---|\n"
+ metric_table(($E | rank("file_edit"; 10)); coverage_count($S; "file_edit"); $total)
+ "\n\n## MCP 툴\n\n| 툴 | 횟수 |\n|---|---|\n"
+ metric_table(($E | rank("mcp_tool"; 10)); coverage_count($S; "mcp_tool"); $total)
+ "\n\n## Jira 이슈 언급\n\n| 이슈 | 횟수 |\n|---|---|\n"
+ metric_table(($E | rank("jira_issue"; 10)); coverage_count($S; "jira_issue"); $total)

+ "\n\n## 신호\n\n| 종류 | 합계 | 관측 세션 |\n|---|---|---|\n"
+ (["error","guard_block","permission_deny","compact"]
   | map(. as $k
       | (coverage_count($S; $k)) as $supported
       | {k:$k, supported:$supported,
          n:([$E[] | select(.kind==$k) | .n] | add // 0)})
   | map("| \(.k) | \(if .supported==0 then "미지원" else (.n|tostring) end) | \(.supported)/\($total) |")
   | join("\n"))

+ "\n\n## 교정 마크 (LLM 정독 후보)\n\n"
+ (
    if $correction_supported==0 then "_(수집 미지원 — 0회로 해석하면 안 됨)_"
    else (($E | map(select(.kind=="correction_mark"))) as $c
      | if ($c|length)==0 then
          "_(관측 가능 \($correction_supported)세션에서 없음"
          + (if $correction_supported<$total then "; \($total-$correction_supported)세션 미지원" else "" end)
          + ")_"
        else ($c | .[0:20] | map("- [\(.sid[0:8])] \(.target)") | join("\n"))
          + (if $correction_supported<$total
             then "\n\n_관측 범위: \($correction_supported)/\($total)세션_"
             else "" end)
        end)
  end)
+ "\n"
