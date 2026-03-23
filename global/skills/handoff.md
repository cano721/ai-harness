---
name: handoff
description: 크로스팀 핸드오프 — 현재 단계 산출물 검증 후 다음 팀으로 전달
trigger: "핸드오프|handoff|다음 단계"
---

# /handoff <target_phase>

## 사용법
/handoff design    — 디자인팀으로 핸드오프
/handoff dev       — 개발팀으로 핸드오프
/handoff qa        — QA팀으로 핸드오프
/handoff deploy    — 배포로 핸드오프

## 실행 내용
1. 현재 단계의 필수 산출물 존재 확인
2. .ai-harness/handoffs/{issue_key}.yaml에 핸드오프 이력 기록
3. Jira 이슈 상태 변경 (가능한 경우)
4. 다음 단계 담당 팀에 알림

## 필수 산출물
- planning → design: PRD URL, Jira 이슈
- design → dev: Figma URL, 디자인 토큰
- dev → qa: PR URL, 테스트 커버리지
- qa → deploy: 테스트 리포트, QA 승인
