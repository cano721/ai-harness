---
name: harness-benchmark
description: Hook 실행 시간을 측정합니다
---

<Purpose>등록된 Hook의 실행 성능을 측정하여 p50/p95/p99를 표시합니다.</Purpose>

<Use_When>
- "Hook 성능 측정", "harness benchmark", "Hook 느린 것 같아"
</Use_When>

<Steps>
1. Bash로 `node scripts/benchmark-hooks.mjs .ai-harness/hooks/ 10` 실행
2. 결과 JSON 파싱
3. Hook별 p50/p95/p99/min/max/avg 표 형식으로 출력
4. p95 > 500ms인 Hook이 있으면 경고
</Steps>
