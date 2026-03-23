---
name: harness-metrics
description: 비용 사용 현황과 메트릭을 표시합니다
---

<Purpose>감사 로그 기반으로 비용과 사용 메트릭을 집계하여 표시합니다.</Purpose>

<Use_When>
- "비용 얼마야?", "하네스 메트릭", "harness cost", "harness metrics"
</Use_When>

<Steps>
1. .ai-harness/logs/ 에서 JSONL 파일들을 Read
2. 비용 계산: cost_usd 필드 합산, 모델별 분류
3. 안전 메트릭: 차단 건수 / 전체 이벤트 = 차단률
4. 기간별 표시: 오늘, 이번 주, 이번 달
5. templates/cost-rates.yaml Read → 모델별 단가 참고
6. 한도 체크: 일/주/월 한도 대비 사용률 표시
</Steps>
