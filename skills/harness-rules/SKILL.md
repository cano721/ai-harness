---
name: harness-rules
description: 적용 중인 규칙과 마지막 차단 사유를 표시합니다
---

<Purpose>현재 적용 중인 보안 규칙과 팀별 규칙을 표시하고, 가장 최근 차단 사유를 알려줍니다.</Purpose>

<Use_When>
- "규칙 보여줘", "왜 차단됐어?", "harness rules", "harness why"
</Use_When>

<Steps>
1. 규칙 조회:
   - .ai-harness/config.yaml Read → hooks, rules 섹션 표시
   - templates/lock-policy.yaml Read → locked/bounded/free 구분 표시
   - 적용된 팀 목록 표시
2. 차단 사유 조회:
   - .ai-harness/logs/ 에서 오늘 날짜 JSONL Read
   - result가 'blocked'인 마지막 이벤트 찾기
   - Hook명, 차단된 도구, 차단 사유 표시
3. 카테고리별로 정리: [Global - 잠금], [팀별], [가드레일]
</Steps>
