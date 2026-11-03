# 오류 발췌·LLM 정리 입력과 결과에서 비밀값을 가린다. extract-claude.jq·extract-codex.sh·digest.sh가 같이 쓴다.
# URL 자격증명, Basic/Bearer 값, --password 류 인자, *TOKEN*/*SECRET*/*PASSWORD*/*KEY* 형태의 key=value,
# 잘 알려진 토큰 접두(sk-·ghp_·xoxb-·AKIA·JWT 등), 숫자와 문자가 섞인 24자 이상 키형 문자열.
# 키형 규칙은 경로 세그먼트(앞뒤가 / \ 이거나 뒤에 .확장자)를 건너뛴다 — 2026-10-05-add-user-index-migration.sql 같은 파일 이름.
def redact:
  gsub("://[^/\\s:@]+:[^@\\s/]+@"; "://***@")
  | gsub("(?<s>(?i)basic|bearer)\\s+[A-Za-z0-9+/=._-]+"; "\(.s) ***")
  | gsub("(?<f>(?i)--(password|passwd|token|secret|api-key|access-key))(?<sep>=|\\s+)[^\\s\"',;]+"; "\(.f)\(.sep)***")
  | gsub("(?<k>(?i)[A-Z0-9_]*(token|password|passwd|secret|api[_-]?key|authorization|access[_-]?key)[A-Z0-9_]*)(?<sep>[\"']?\\s*[=:]\\s*[\"']?)[^\\s\"',;]+"; "\(.k)\(.sep)***")
  | gsub("(?<![A-Za-z0-9_-])(sk-[A-Za-z0-9_-]{16,}|sk_(live|test)_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}(\\.[A-Za-z0-9_-]+)?)"; "***")
  | gsub("(?<![A-Za-z0-9+=_/\\\\-])(?=[A-Za-z+=_-]*[0-9])(?=[0-9+=_-]*[A-Za-z])[A-Za-z0-9+=_-]{24,}(?![A-Za-z0-9+=_/\\\\-]|\\.[A-Za-z0-9]{1,5}(?![A-Za-z0-9+=_-]))"; "***");
# 리포트에 실리는 경로: 세션 작업 폴더는 상대 경로로, 홈 아래 절대 경로(/Users/<이름>, /home/<이름>, /root,
# C:\Users\<이름>)는 ~로 줄여 사용자 이름을 남기지 않는다.
def redact_path($cwd):
  ($cwd | rtrimstr("/") | rtrimstr("\\")) as $c
  | (if $c == "" then . else split($c + "/") | join("") | split($c + "\\") | join("") end)
  | gsub("(?:/(?:Users|home)/[^/\\s\"'),;:]+|/root)(?=[/\\s\"'),;:]|$)"; "~")
  | gsub("[A-Za-z]:[\\\\/]Users[\\\\/][^\\\\/\\s\"'),;:]+(?=[\\\\/\\s\"'),;:]|$)"; "~");
# 가드 차단 사례: 차단 문구 줄에서 Claude 훅 래퍼("PreToolUse:<툴> hook error: [<훅>]: ")를 떼고 경로·비밀값을 가린다.
def guard_excerpt($cwd):
  (split("\n") | map(select(test("\\[[A-Za-z ]+ guard\\]"))) | first) // .
  | sub("^PreToolUse:[A-Za-z]+ hook error: \\[[^\\]]*\\]: "; "")
  | redact_path($cwd) | gsub("\\s+"; " ") | ltrimstr(" ") | redact | .[0:200];
