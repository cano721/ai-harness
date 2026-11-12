# claude --output-format stream-json 출력을 한 줄씩(jq -R -c -f) 받아 진행 기록만 남긴다.
# 원본은 파일 내용이 담긴 도구 입출력이라 디스크에 쓰지 않는다 — workflow-driver.sh의 stream_progress와 같은 원칙이다.
# - assistant의 tool_use마다 {"type":"progress","at","tool","target"} (Bash는 description 또는 실행어 이름만,
#   Grep·Glob은 검색어 60자 + path, 그 밖은 file_path/path/description, 160자까지. Write·Edit 본문·Agent 프롬프트는 없음)
# - result 이벤트는 그대로(비용·결과 파싱이 그대로 동작한다)
# - JSON이 아닌 줄(stderr 안내)은 {"type":"stderr","text":앞 300자}
# - 그 밖(system·user·tool_result·assistant 문장)은 버린다.
. as $line
| (try ($line | fromjson) catch null) as $ev
| if ($ev | type) == "object" then
    if $ev.type == "assistant" then
      ($ev.message.content // [] | if type == "array" then .[] else empty end)
      | select(type == "object" and .type == "tool_use") | (.input // {}) as $in
      | {type: "progress", at: (now | todate), tool: .name,
         target: ((
           if .name == "Bash" then
             ($in.description // ($in.command // "" | [scan("\\S+")]
               | map(select(test("^[A-Za-z_][A-Za-z0-9_]*=") | not)) | .[0] // "" | split("/") | last))
           elif .name == "Grep" or .name == "Glob" then
             (($in.pattern // "" | tostring | .[:60]) as $pat
              | ($in.path // "" | tostring) as $p
              | if $p == "" then $pat else $pat + " in " + $p end)
           else ($in.file_path // $in.path // $in.description // "" | tostring)
           end | tostring | gsub("[\t\n]"; " ")) | .[:160])}
    elif $ev.type == "result" then $ev
    else empty end
  elif ($line | length) > 0 then
    {type: "stderr", text: $line[:300]}
  else empty end
