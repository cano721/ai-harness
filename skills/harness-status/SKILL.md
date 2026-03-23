---
name: harness-status
description: 하네스 상태 확인 — 설정, 차단 현황, 진단, 미결정 사항
---

<Purpose>현재 프로젝트의 하네스 설정 상태, 차단 현황, 설정 건강 상태를 한 번에 확인합니다.</Purpose>

<Use_When>
- "하네스 상태", "harness status", "현재 설정 보여줘"
- "하네스 진단", "harness doctor", "설정 검사해줘"
- "차단 몇 번 됐어?", "하네스 메트릭"
</Use_When>

<Steps>
1. 설정 확인:
   - .ai-harness/config.yaml Read → 팀, 프로젝트 정보 표시
   - .claude/settings.json Read → 등록된 Hook 목록 표시

2. 차단 현황:
   - .ai-harness/logs/ 에서 오늘 날짜 JSONL Read
   - result가 'blocked'인 이벤트 카운트
   - Hook별 차단 건수 표시

3. 미결정 사항:
   - .ai-harness/pending-decisions.yaml 있으면 Read
   - status가 'pending'인 항목 수 + 목록 표시

4. 진단 (문제 있으면 경고):
   - .ai-harness/config.yaml 파싱 가능 여부
   - Hook 파일 존재 + 실행 권한 확인 (Bash `test -x`)
   - .claude/settings.json에 Hook 등록 여부
   - CLAUDE.md에 harness 구간 존재 여부
   - 문제 발견 시 ⚠ 표시 + 해결 방법 안내

5. 출력 형식:
   ```
   [설정]
     팀: backend
     Hook: block-dangerous, secret-scanner, audit-logger, sql-review, api-compat, entity-review

   [오늘]
     차단: 2건 (sql-review 1건, api-compat 1건)

   [미결정]
     1건 — "DTO 네이밍 패턴 통일 필요"

   ⚠ secret-scanner.sh 실행 권한 없음 → chmod +x 필요
   ```
</Steps>
