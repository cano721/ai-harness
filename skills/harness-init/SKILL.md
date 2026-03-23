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
   - **도메인 분석 시 불명확한 부분 처리**:
     - 엔티티 간 관계가 불명확하면 사용자에게 질문
       예: "User와 Member가 둘 다 있는데, 같은 개념인가요 다른 역할인가요?"
     - 도메인 용어가 혼재되면 표준 용어 확인
       예: "지원자를 Applicant, Candidate 둘 다 쓰고 있는데 어떤 걸로 통일할까요?"
     - 즉시 결정하기 어려운 사항은 `.ai-harness/pending-decisions.yaml`에 저장
       ```yaml
       pending_decisions:
         - id: 1
           category: domain
           question: "User와 Member의 관계 정리 필요"
           context: "User(12곳), Member(5곳) 혼재"
           created_at: "2026-03-23"
           status: pending
       ```
     - 사용자가 "나중에 결정할게"라고 하면 pending에 저장하고 init은 계속 진행
     - 이후 `/harness-rules` 또는 `/harness-status`에서 미결정 사항 안내
   - 이 정보는 .ai-harness/config.yaml의 project 섹션에 저장

5. 팀 추천
   - 현재 제공 중인 팀: **backend** (다른 팀은 준비 중)
   - 사용자가 backend 외 팀을 요청하면 "아직 준비 중입니다. 현재는 backend 팀만 사용 가능합니다." 안내
   - 감지된 스택이 Java/Spring이면 backend 자동 추천
   - 사용자 확인 후 결정

6. 팀 리소스 복사 + 맞춤 컨벤션 생성
   - Bash로 `node scripts/copy-team-resources.mjs ...` 실행 (팀별 Hook, 기본 스킬 복사)
   - 팀 CLAUDE.md 복사 (범용 규칙 + 스킬 참조)
   - 컨벤션 생성 (핵심):
     a. 범용 템플릿(teams/{team}/skills/convention-{team}.md)을 Read로 읽기
     b. 프로젝트 코드를 추가 분석:
        - 기존 응답 클래스 (CommonResponse? ApiResult? 커스텀?)
        - 실제 패키지 구조 (Glob + Read)
        - 마이그레이션 도구 (Flyway? Liquibase? build.gradle/pom.xml에서 확인)
        - 기존 DTO 네이밍 패턴, 예외 클래스, 테스트 프레임워크
     c. **패턴 충돌 시 사용자와 논의** (중요):
        - 같은 역할의 클래스/패턴이 2개 이상 발견되면 임의로 정하지 않는다
        - 각 패턴의 사용 빈도를 분석하여 보고한다
        - 예: "응답 클래스가 CommonResponse(15곳), ApiResult(3곳) 2개 발견. CommonResponse로 통일할까요?"
        - 예: "DTO 네이밍이 CreateUserDto(8개), UserCreateRequest(5개) 혼재. 어떤 패턴으로 통일할까요?"
        - 예: "예외 클래스가 BusinessException, CustomException 2개 발견. 어떤 걸 표준으로 할까요?"
        - 사용자가 결정하면 그 결정을 컨벤션에 반영한다
        - 사용자가 "나중에 결정할게"라고 하면 `.ai-harness/pending-decisions.yaml`에 저장
          ```yaml
          - id: 2
            category: convention
            question: "DTO 네이밍 패턴 통일 필요"
            context: "CreateUserDto(8개) vs UserCreateRequest(5개)"
            options: ["CreateUserDto", "UserCreateRequest", "{Action}{Entity}Request"]
            created_at: "2026-03-23"
            status: pending
          ```
        - 미결정 상태에서는 빈도가 높은 패턴을 임시 기본값으로 사용 (컨벤션에 "(임시)" 표기)
     d. 패턴이 하나뿐이면 그대로 채택하고 사용자에게 확인만 받는다
     e. 패턴이 아예 없으면 (신규 프로젝트) 범용 템플릿 기본값을 제안한다
     f. 범용 템플릿을 프로젝트 실제 패턴으로 수정하여 맞춤 컨벤션 작성
     g. .ai-harness/teams/{team}/skills/convention-{team}.md 에 Write로 저장
   - 기존 컨벤션이 이미 있으면 덮어쓰지 않고 사용자에게 확인

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
