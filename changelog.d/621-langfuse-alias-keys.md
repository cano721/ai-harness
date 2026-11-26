### 버그 수정
- setup·보드 하네스 설정이 Langfuse 별칭 키(`LANGFUSE_PUBLIC_KEY_<별칭>`·`_CMD_<별칭>`)를 인식합니다. 별칭 키만 있어도 "토큰 없음"이 뜨지 않고, `setup.sh check langfuse`는 기본 키와 별칭마다(`LANGFUSE_HOST_<별칭>` 우선) 연결을 확인해 별칭별 결과를 보입니다. (#621)
