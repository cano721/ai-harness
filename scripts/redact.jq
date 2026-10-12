# 오류 발췌·LLM 정리 입력과 결과에서 비밀값을 가린다. extract-claude.jq·extract-codex.sh·digest.sh가 같이 쓴다.
# URL 자격증명, Basic/Bearer 값, --password 류 인자, *TOKEN*/*SECRET*/*PASSWORD*/*KEY* 형태의 key=value,
# 숫자와 문자가 섞인 24자 이상 키형 문자열. 경로는 / 와 . 로 끊겨 보존된다.
def redact:
  gsub("://[^/\\s:@]+:[^@\\s/]+@"; "://***@")
  | gsub("(?<s>(?i)basic|bearer)\\s+[A-Za-z0-9+/=._-]+"; "\(.s) ***")
  | gsub("(?<f>(?i)--(password|passwd|token|secret|api-key|access-key))(?<sep>=|\\s+)[^\\s\"',;]+"; "\(.f)\(.sep)***")
  | gsub("(?<k>(?i)[A-Z0-9_]*(token|password|passwd|secret|api[_-]?key|authorization|access[_-]?key)[A-Z0-9_]*)(?<sep>[\"']?\\s*[=:]\\s*[\"']?)[^\\s\"',;]+"; "\(.k)\(.sep)***")
  | gsub("(?=[A-Za-z+=_-]*[0-9])(?=[0-9+=_-]*[A-Za-z])[A-Za-z0-9+=_-]{24,}"; "***");
