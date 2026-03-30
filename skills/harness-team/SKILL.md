---
name: harness-team
description: 팀을 추가/수정/제거하거나 목록을 표시합니다
---

<Purpose>프로젝트에 적용된 팀 프로필을 관리합니다.</Purpose>

<Use_When>
- "QA팀 추가해줘", "BE 컨벤션 수정해줘", "디자인팀 제거", "팀 목록"
- 팀을 추가/제거할 때
- 컨벤션을 수정할 때
</Use_When>

<Available_Teams>
제공 중: **backend**, **frontend**, **planning**, **design**

각 팀은 고유한 Hook, 스킬, 컨벤션을 포함합니다.
테스트/QA 관련 기능(커버리지 체크, 테스트 시나리오 등)은 각 팀에 내장되어 있습니다.
인프라/배포 관련 기능(infra-change-review, deploy-check, rollback-plan 등)은 글로벌로 모든 팀에 자동 적용됩니다.
</Available_Teams>

<Steps>
### 팀 추가
1. 사용자가 요청한 팀 확인
2. 프로젝트를 분석하여 해당 팀에 맞는 컨벤션 생성
3. Bash로 `node scripts/copy-team-resources.mjs {team} ...` 실행 (Hook, 기본 스킬 복사)
4. 분석 기반으로 convention-{team}.md Write로 생성
5. .ai-harness/teams/{team}/CLAUDE.md Write로 생성
6. Bash로 `node scripts/register-hooks.mjs register ...` 실행 (팀 Hook 등록)
7. .ai-harness/config.yaml Read → teams 배열에 추가 → Write

### 팀 제거
1. .ai-harness/teams/{team}/ 삭제 (Bash rm -r)
2. Bash로 `node scripts/register-hooks.mjs unregister-team ...` 실행
3. .ai-harness/config.yaml Read → teams 배열에서 제거 → Write

### 컨벤션 수정
1. .ai-harness/teams/{team}/skills/convention-{team}.md Read
2. 사용자 요청에 따라 내용 수정
3. Edit 도구로 수정 적용

### 팀 목록
1. .ai-harness/config.yaml Read → teams 배열 표시
2. 각 팀의 Hook 수, Skill 수 표시
</Steps>
