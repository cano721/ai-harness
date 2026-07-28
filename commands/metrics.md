# /metrics — 에이전트 사용량 요약 리포트

`~/.claude/ai-harness/` 데이터를 집계해 요약 리포트를 출력한다. 조회 전용 — 파일 수정·PR 없음 (개선 작업은 `/harvest`).

인자: `$ARGUMENTS`
- 기간: `7d` / `30d` / `90d` / `all` (기본 `30d`)
- 프로젝트명 (예: `my-service`) — 지정 시 해당 프로젝트만
- 예: `/metrics 7d my-service`, `/metrics all`

## 절차

1. 데이터 갱신 + 집계:
```bash
${CLAUDE_PLUGIN_ROOT}/scripts/backfill.sh
${CLAUDE_PLUGIN_ROOT}/scripts/stats.sh --days <N> [--project <P>]
```
`all`이면 `--days` 생략. 추세 언급을 위해 직전 동일 기간과 비교하고 싶으면 `--days 2N` 결과와 차분.

2. 원본 표를 그대로 붙이지 말고 **요약**해서 출력:

```
## 사용량 리포트 (<기간>, <범위>)

**한 줄 요약**: 세션 N개 · 턴 N · in/out 토큰 N/N (cache hit ~N%)

**어디에 썼나**: 프로젝트 상위 2~3개 + 세션/토큰 비중
**뭘로 썼나**: 워크플로/커맨드 상위 3~5 + 페르소나 위임 상위 3
**docs 활용**: 최다 읽힘 2~3개 / 0회(죽은) 문서 명단
**신호**: error·guard_block·permission_deny·compact 합계 — 눈에 띄는 것만 코멘트
**Jira**: 언급 상위 3 이슈
```

3. 마지막에 눈에 띄는 포인트 1~3개만 짚는다 (예: "docs X 30일째 0회", "error 급증"). 근거 수치 없이 해석하지 않는다. 개선까지 원하면 `/harvest` 안내.
