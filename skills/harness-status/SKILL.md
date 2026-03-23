---
name: harness-status
description: AI Harness 현재 상태를 표시합니다
---

<Purpose>현재 프로젝트의 하네스 설정 상태를 확인합니다.</Purpose>

<Use_When>
- "하네스 상태", "harness status", "현재 설정 보여줘"
</Use_When>

<Steps>
1. .ai-harness/config.yaml을 Read로 읽어서 팀, 가드레일 표시
2. .claude/settings.json을 Read로 읽어서 등록된 Hook 수 표시
3. .ai-harness/logs/ 에서 오늘 날짜 JSONL 파일을 Read로 읽어서 이벤트 수, 차단 수 표시
4. 결과를 표 형식으로 정리하여 출력
</Steps>
