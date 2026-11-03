# orders-service — AI 작업 규칙

작업 전에 관련 문서를 읽는다.

| 작업 | 먼저 읽을 문서 |
|---|---|
| 주문 상태·금액을 바꾸는 코드 | `.ai-harness/docs/domain.md` |
| 코드 작성 전반 | `.ai-harness/docs/code-conventions.md` |
| 테스트 | `.ai-harness/docs/testing.md` |

## 검증

- `python3 -m unittest discover -s tests -t .` 가 통과해야 완료다.
