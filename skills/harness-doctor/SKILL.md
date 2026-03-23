---
name: harness-doctor
description: 환경/설정/Hook 종합 진단을 실행합니다
---

<Purpose>하네스 설정의 건강 상태를 종합 진단합니다.</Purpose>

<Use_When>
- "하네스 진단", "harness doctor", "설정 검사해줘"
- Hook이 동작하지 않을 때
- 설정에 문제가 있을 때
</Use_When>

<Steps>
1. 환경 검증: Bash로 `node scripts/check-environment.mjs` 실행
2. 설정 검증: .ai-harness/config.yaml Read → YAML 파싱 가능 여부
3. Lock-policy 검증: templates/lock-policy.yaml 기준으로 config 값 범위 확인
4. Hook 검증:
   - .ai-harness/hooks/ 의 각 .sh 파일 존재 확인 (Glob)
   - Bash로 `test -x` 실행 권한 확인
   - .claude/settings.json에 등록 여부 확인
   - Bash로 `node scripts/test-hooks.mjs .ai-harness/hooks/` 실행하여 테스트 통과 확인
5. CLAUDE.md 검증: Read → harness:start ~ harness:end 구간 존재 확인
6. 로그 검증: .ai-harness/logs/ 디렉토리 존재, 최근 에러 건수
7. 각 항목을 ✔/⚠/❌로 표시, 종합 점수 출력
8. 문제 발견 시 해결 방법 제안
</Steps>
