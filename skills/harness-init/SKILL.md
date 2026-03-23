---
name: harness-init
description: 프로젝트에 AI Harness를 초기화합니다 — 프로젝트 분석, 컨벤션 생성, Hook 등록
---

<Purpose>
프로젝트 코드를 Claude가 직접 분석하여 팀별 코드 컨벤션을 자동 생성하고,
보안 Hook을 등록하여 AI 에이전트를 안전하게 제어합니다.
</Purpose>

<Use_When>
- "하네스 초기화해줘", "harness init", "보안 설정해줘"
- 새 프로젝트에서 처음 하네스를 설정할 때
- 팀별 규칙을 처음 적용할 때
</Use_When>

<Do_Not_Use_When>
- 이미 초기화된 프로젝트에서 팀만 추가/제거할 때 → /harness-team 사용
- 컨벤션만 수정할 때 → 직접 파일 수정 또는 "컨벤션 수정해줘"
</Do_Not_Use_When>

<Steps>
1. 범위 선택
   - 사용자에게 글로벌(모든 프로젝트) / 로컬(이 프로젝트만) / 둘 다 중 선택
   - 글로벌: ~/.ai-harness/, ~/.claude/settings.json
   - 로컬: ./.ai-harness/, ./.claude/settings.json

2. 환경 감지
   - Bash로 `node scripts/check-environment.mjs` 실행
   - Node.js, Git, Claude Code 버전 확인

3. 프로젝트 분석 (로컬일 때)
   - Glob으로 프로젝트 파일 탐색 (package.json, build.gradle, pom.xml, tsconfig.json 등)
   - 주요 소스 파일을 Read로 읽어서 패턴 파악:
     - Java: 패키지 구조, Controller/Service 패턴, DTO 네이밍, API 경로
     - React/Vue: 컴포넌트 구조, 상태 관리, API 호출 패턴
     - 테스트: 프레임워크, 디렉토리 구조
   - 분석 결과를 사용자에게 보고하고 확인

4. 팀 추천
   - 현재 제공 중인 팀: **backend** (다른 팀은 준비 중)
   - 사용자가 backend 외 팀을 요청하면 "아직 준비 중입니다. 현재는 backend 팀만 사용 가능합니다." 안내
   - 감지된 스택이 Java/Spring이면 backend 자동 추천
   - 사용자 확인 후 결정

5. 컨벤션 스킬 생성
   - 분석 결과 기반으로 .ai-harness/teams/{team}/skills/convention-{team}.md 작성
   - Write 도구로 직접 생성 (템플릿이 아닌 분석 기반)

6. 팀 CLAUDE.md 생성
   - .ai-harness/teams/{team}/CLAUDE.md — 최소 규칙 + 스킬 참조
   - Write 도구로 직접 생성

7. Hook 등록
   - Bash로 `node scripts/register-hooks.mjs register ...` 실행
   - Bash로 `node scripts/copy-team-resources.mjs ...` 실행 (팀별 Hook 복사)

8. config.yaml 생성
   - .ai-harness/config.yaml을 Write로 생성

9. CLAUDE.md 주입
   - Bash로 `node scripts/inject-claudemd.mjs inject ...` 실행

10. 완료 보고
    - 적용된 팀, Hook 수, 생성된 컨벤션 요약
</Steps>
