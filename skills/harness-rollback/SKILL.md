---
name: harness-rollback
description: 설정을 이전 스냅샷으로 복원합니다
---

<Purpose>하네스 설정을 이전 상태로 되돌립니다.</Purpose>

<Use_When>
- "하네스 롤백", "이전 설정으로 복원", "harness rollback"
</Use_When>

<Steps>
1. Bash로 `node scripts/snapshot.mjs list .ai-harness` 실행 → 스냅샷 목록 표시
2. 사용자가 복원할 스냅샷 선택 (또는 최신)
3. Bash로 `node scripts/snapshot.mjs restore .ai-harness [snapshotId]` 실행
4. 복원 결과 확인
</Steps>
