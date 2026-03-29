---
name: harness-init
description: 프로젝트에 AI Harness를 초기화합니다 — 팀 선택 → 글로벌 세팅 → 프로젝트 세팅
---

<Purpose>
팀을 선택하고, 보안 Hook을 글로벌에 등록하고, 프로젝트에 맞는 컨벤션/Hook/컨텍스트맵을 세팅합니다.
모든 단계에서 사용자에게 확인받은 후 진행합니다.
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
1. 팀 선택 (가장 먼저 — 이후 단계의 분석 범위와 추천 항목이 팀에 따라 달라짐)
   - 빌드 파일로 기술 스택 빠른 감지 (Glob으로 build.gradle, pom.xml, package.json, tsconfig.json 존재 여부만 확인)
   - 감지된 스택 기반으로 팀 추천:
     - Java/Spring → backend 추천
     - React/Vue/Next.js → frontend 추천
     - Terraform/Helm/Docker → devops 추천
     - 복합 스택 → 여러 팀 추천
   - 사용 가능한 팀 목록 제시:
     ```
     "기술 스택: Java/Spring Boot 감지
      추천 팀: backend

      사용 가능한 팀:
       [1] backend — Java/Spring, API, DB
       [2] frontend — React/Vue, 컴포넌트, 번들
       [3] devops — 인프라, CI/CD, 배포
       [4] qa — 테스트, 커버리지, 회귀
       [5] design — UI/UX, 접근성, 반응형
       [6] planning — PRD, 유저스토리, 추정

      선택? (쉼표로 복수 선택 가능, 기본: 1):"
     ```
   - 사용자 확인 후 결정

2. 글로벌 세팅 확인
   - ~/.claude/settings.json에 보안 Hook 4개가 등록되어 있는지 확인
   - 상태를 사용자에게 안내하고 **확인받은 후 진행**:
     ```
     "다음 보안 Hook을 모든 프로젝트에 적용합니다:
       ✓ block-dangerous     — 위험 명령 차단
       ✓ secret-scanner      — 시크릿 하드코딩 감지
       ✓ check-architecture  — 아키텍처 경계 위반 검증
       ✓ audit-logger        — 모든 도구 사용 로깅

      등록 위치: ~/.claude/settings.json
      진행할까요? (Y/n):"
     ```
   - 이미 등록된 Hook은 "이미 등록됨"으로 표시, 신규만 추가
   - Bash로 `node scripts/register-hooks.mjs register ~/.claude/settings.json ...` 실행

3. 프로젝트 확인
   - 현재 디렉토리를 분석하여 프로젝트 정보를 파악
   - 사용자에게 **확인받은 후 진행**:
     ```
     "현재 프로젝트 분석:
       경로: /Users/khb1122/Desktop/projects/my-service
       이름: my-service
       스택: Java 17, Spring Boot 3.2, JPA, MySQL
       팀: backend (1단계에서 선택)

      이 프로젝트에 backend 세팅을 적용할까요? (Y/n):"
     ```
   - 도메인 분석 시 불명확한 부분은 사용자에게 질문:
     - 예: "User와 Member가 둘 다 있는데, 같은 개념인가요?"
     - 즉시 결정하기 어려우면 `.ai-harness/pending-decisions.yaml`에 저장

4. 프로젝트 세팅
   - 이미 세팅된 것과 안 된 것을 구분하여 보여주고 **사용자가 선택**:
     ```
     "[backend] 프로젝트 세팅 상태:

      이미 세팅됨:
       ✓ 컨벤션 (convention-backend.md)

      미세팅 (추천):
       [1] ✗ 컨텍스트 맵 — 에이전트용 프로젝트 지도
       [2] ✗ 팀 Hook: api-compat — API 호환성 검사
       [3] ✗ 팀 Hook: entity-review — 엔티티 변경 리뷰
       [4] ✗ 팀 Hook: sql-review — SQL 검증
       [5] ✗ 아키텍처 레이어 검증 설정
       [6] ✗ 외부 서비스 연동 (Jira, Confluence 등)
       [7] ✗ MCP 서버 (MySQL, Figma)
       [8] ✗ 추천 플러그인 (OMC, pm-skills)

      세팅할 항목? (번호 쉼표, all: 전체, skip: 건너뛰기):"
     ```
   - 선택된 항목에 대해 순서대로 세팅:
     a. **컨벤션 생성**: 범용 템플릿 + 프로젝트 코드 분석 → 맞춤 컨벤션
        - 패턴 충돌 시 사용자와 논의 (임의 결정하지 않음)
        - 미결정 사항은 pending-decisions.yaml에 저장
     b. **컨텍스트 맵**: templates/context-map.md 기반으로 프로젝트 지도 생성
     c. **팀 Hook 등록**: .claude/settings.json에 팀별 Hook 등록
     d. **config.yaml 생성**: 프로젝트 설정 (팀, 도메인, 엔티티, 아키텍처)
     e. **CLAUDE.md 주입**: `node scripts/inject-claudemd.mjs inject ...`
     f. **외부 서비스**: 대화형 인증 정보 수집 → ~/.claude/credentials.md에 저장
     g. **MCP 서버**: 연결 정보 수집 → .claude/.mcp.json에 설정
     h. **추천 플러그인**: `claude plugin install` 실행

5. 완료 보고
   - 적용된 팀, Hook 수, 생성된 컨벤션 요약
   - 미결정 사항이 있으면 건수 안내
</Steps>
