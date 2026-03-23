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

4. 프로젝트 정보 수집 (도메인은 프로젝트에 속함, 팀에 속하지 않음)
   - 분석 결과에서 추출 또는 사용자에게 확인:
     - project.name: 프로젝트명
     - project.domain: 도메인 (예: "채용 관리", "이커머스")
     - project.entities: 주요 엔티티 목록
     - project.tech_stack: 기술 스택
     - project.base_package: 베이스 패키지 (Java인 경우)
   - 이 정보는 .ai-harness/config.yaml의 project 섹션에 저장

5. 팀 추천
   - 현재 제공 중인 팀: **backend** (다른 팀은 준비 중)
   - 사용자가 backend 외 팀을 요청하면 "아직 준비 중입니다. 현재는 backend 팀만 사용 가능합니다." 안내
   - 감지된 스택이 Java/Spring이면 backend 자동 추천
   - 사용자 확인 후 결정

6. 팀 리소스 복사 + 컨벤션 생성
   - Bash로 `node scripts/copy-team-resources.mjs ...` 실행 (팀별 Hook, 기본 스킬 복사)
   - 컨벤션은 범용 템플릿을 복사 (도메인 정보는 config.yaml에서 참조)
   - 팀 CLAUDE.md 복사 (범용 규칙 + 스킬 참조 + config.yaml 참조 지시)

7. Hook 등록
   - Bash로 `node scripts/register-hooks.mjs register ...` 실행

8. config.yaml 생성
   - .ai-harness/config.yaml을 Write로 생성
   - project 섹션에 분석된 프로젝트 정보 포함
   - teams 배열에 선택된 팀 포함

9. CLAUDE.md 주입
   - Bash로 `node scripts/inject-claudemd.mjs inject ...` 실행

10. 완료 보고
    - 적용된 팀, Hook 수, 생성된 컨벤션 요약
</Steps>
