---
name: harness-metrics
description: 사용 메트릭을 표시합니다 — 도구 호출, 차단률, 팀별 분포
---

<Purpose>감사 로그 기반으로 도구 사용 현황과 안전 메트릭을 집계하여 표시합니다.</Purpose>

<Use_When>
- "하네스 메트릭", "harness metrics", "차단 몇 번 됐어?", "사용 현황"
</Use_When>

<Steps>
1. .ai-harness/logs/ 에서 JSONL 파일들을 Read
2. 사용 메트릭 집계:
   - 도구 호출 횟수 (오늘 / 이번 주 / 이번 달)
   - 도구별 호출 빈도 (Bash, Write, Edit, Read 등)
3. 안전 메트릭 집계:
   - 차단 건수 (result: 'blocked')
   - 차단률 (차단 / 전체)
   - Hook별 차단 건수 (block-dangerous, sql-review 등)
4. 팀별 분포 (config.yaml의 teams 참고):
   - 팀별 Hook 트리거 건수
5. 기간별 표시: 오늘, 이번 주, 이번 달
6. 결과를 표 형식으로 출력
</Steps>
