---
name: harness-team
description: 팀을 추가/수정/제거하거나 목록을 표시합니다
---

<Purpose>프로젝트 로컬 팀 프로필을 관리합니다. planning 팀의 글로벌 bundle 설치와 runtime별 변환은 /harness-init 에서 처리합니다.</Purpose>

<Use_When>
- "QA팀 추가해줘", "BE 컨벤션 수정해줘", "디자인팀 제거", "팀 목록"
- 팀을 추가/제거할 때
- 컨벤션을 수정할 때
</Use_When>

<Available_Teams>
로컬 프로젝트 팀: **backend**, **frontend**, **design**
글로벌 bundle: **planning**

각 팀은 고유한 Hook, 스킬, 컨벤션을 포함합니다.
테스트/QA 관련 기능(커버리지 체크, 테스트 시나리오 등)은 각 팀에 내장되어 있습니다.
인프라/배포 관련 기능(infra-change-review, deploy-check 등)은 글로벌로 모든 팀에 자동 적용됩니다.

- planning 요청 시: "planning 팀은 /harness-init 으로 글로벌 planner bundle을 설치합니다." 안내
- planning 관련 파일을 직접 수정해야 하면 `teams/planning/bundle-codex/`, `teams/planning/bundle-claude/`를 기준으로 작업한다
</Available_Teams>

<Steps>
### 팀 추가
1. 사용자가 요청한 팀 확인
2. planning이면 이 스킬에서 처리하지 않고 `/harness-init`으로 안내
   - 필요하면 `teams/planning/README.md` 경로를 같이 알려줘서 bundle/legacy 구분을 명확히 한다
3. backend면 현재 프로젝트를 분석하여 해당 팀에 맞는 컨벤션 생성
4. Bash로 `node scripts/copy-team-resources.mjs {team} ...` 실행 (Hook, 기본 스킬 복사)
5. 분석 기반으로 convention-{team}.md Write로 생성
6. .ai-harness/teams/{team}/CLAUDE.md Write로 생성
7. Bash로 `node scripts/register-hooks.mjs register ...` 실행 (팀 Hook 등록)
8. .ai-harness/config.yaml Read → teams 배열에 추가 → Write

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
3. planning 글로벌 bundle은 별도 항목으로 표시만 하고 로컬 팀 목록에는 포함하지 않는다
4. planning 상태를 보여줄 때는 현재 프로젝트가 아니라 전역 설치 대상(`~/.codex` 또는 `~/.claude`)이라는 점을 명시한다
</Steps>
