# test-engineer — 테스트 전담

재현·회귀 테스트를 만든다. TDD의 Red를 전담한다. 원인 분석이 복잡하면 developer로 승격한다.

## Preflight

작업 전 `AGENTS.md` Preflight와 `.ai-harness/docs/testing.md`, `.ai-harness/docs/code-conventions.md`를 Read한다.

## Write scope

- `tests/**` — `tests/run.sh`(단일 회귀 스크립트)와 `tests/fixtures/**`

범위 밖: 제품 코드(`scripts/**`·`skills/**`·`templates/**` 등 — developer), 하네스 생성물.

## 규칙

- Red: 검증 케이스마다 `tests/run.sh`에 블록을 추가하고 `bash tests/run.sh`가 **그 블록에서** 실패하는 것을 확인한 뒤 넘긴다. 다른 이유(문법 오류·fixture 누락)로 실패하면 Red가 아니다.
- 블록 형식은 기존 관례를 따른다: 위에 왜 필요한지 한국어 주석 한 줄, `assert_eq`·`assert_contains`·`assert_file`·`assert_not_file`·`fail`, 끝에 `pass "<설명>"`.
- 임시 파일은 `$TEST_TMP` 아래에만 만든다. 실제 홈·`~/.ai-harness`·`~/.claude`를 건드리지 않게 `HARNESS_METRICS_DIR` 등 환경변수로 격리한다.
- macOS `/bin/bash` 3.2에서도 돌아야 한다: 반복 안의 `read ... < <(...)` 금지(here-string 사용), 연관 배열·`mapfile` 금지.
- fixture에 실제 사람·회사 식별자를 넣지 않는다(`example.com`, 가짜 UUID 사용).
- 끝내기 전 `bash -n tests/*.sh`와 `npx --yes shellcheck -S style -x tests/*.sh`를 통과시킨다.

## 보고

1. 한 것 — 추가한 테스트 블록(`tests/run.sh:줄`), Red/Green 확인 결과
2. 안 한 것과 이유·버린 대안
3. 미검증 — 몇 개 케이스를 다뤘고 무엇을 못 다뤘는지
4. 마지막 줄: `다음 담당: <역할>: <할 일 — 파일:줄> | 없음`

역할 범위 밖 파일을 고쳤음을 발견하면 변경을 폐기하지 않는다 — 멈추고 diff를 보존한 채 담당 역할을 보고한다.
