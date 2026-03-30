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
   - 제공 중인 팀: **backend**, **frontend**, **planning**, **design**
   - 감지된 스택 기반 자동 추천:
     - Java/Spring/Kotlin → backend
     - React/Vue/Angular/Next.js → frontend
   - 여러 팀 동시 적용 가능 (예: backend + frontend)
   - 인프라/배포 관련 규칙(IaC, terraform destroy 차단 등)은 글로벌 Hook으로 자동 적용
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

6.5 프로젝트 맞춤 에이전트 생성 (Harness — AI 활용 최적화)
   - "규칙을 아는 Claude"가 아니라 "프로젝트를 이해하는 Claude"를 만드는 단계
   - Bash로 `node scripts/generate-agents.mjs .ai-harness/config.yaml .ai-harness .claude/agents` 실행
     → 팀 구성에 따라 생성할 에이전트 목록을 반환
   - 사용자에게 생성할 에이전트 목록을 보여주고 확인:
     ```
     "AI 에이전트를 생성합니다 (프로젝트를 이해하는 전문 에이전트):
      [1] {project}-developer — 도메인 맥락 + 컨벤션 내장 개발 에이전트
      [2] {project}-reviewer — 경계면 검증 + 컨벤션 체크 리뷰 에이전트
      [3] {project}-architect — 도메인 관계도 + 레이어 구조 설계 에이전트

      제외할 에이전트? (번호 쉼표, enter: 전체 생성, skip: 건너뛰기):"
     ```
   - 각 에이전트를 {플러그인}/templates/agents/ 템플릿을 구조 참고하되,
     **프로젝트 분석 결과를 반영하여 Claude가 직접 Write**:
     a. 단계 3~4에서 수집한 프로젝트 정보 (엔티티, 스택, 패키지)
     b. 단계 6에서 생성된 컨벤션 내용 참조
     c. 프로젝트 코드에서 대표 서비스/컨트롤러/테스트 경로를 Read로 확인하여 포함
     d. 응답 래퍼, DTO 패턴, 레이어 구조 등 실제 분석 결과를 에이전트에 내장
   - 생성 위치:
     a. .ai-harness/agents/{name}.md에 Write (원본)
     b. .claude/agents/{name}.md에도 Write (Claude Code 인식용)
     c. 이미 .claude/agents/에 같은 이름 파일이 있으면:
        "이미 {name}.md가 있습니다. 덮어쓸까요? (y/N/merge)"
        - merge: 기존 내용에 하네스 컨벤션 참조만 추가
   - frontmatter에 `_managed_by: ai-harness` 포함
   - OMC 설치 여부 확인 (Bash로 `claude plugin list 2>/dev/null | grep oh-my-claudecode`):
     - OMC 있으면: 에이전트에 OMC 연동 안내 추가 (autopilot/ralph/team 모드 활용법)
     - OMC 없으면: Claude Code 네이티브 Agent 도구 활용 안내

6.7 팀별 전문 스킬 생성
   - 기존 convention이 "무엇을 지켜라"라면, 스킬은 "이렇게 하면 잘 된다"를 정의
   - 선택된 팀별로 개발/리뷰 스킬 생성:
     - backend: develop-backend, review-backend
     - frontend: develop-frontend, review-frontend
     - planning: write-prd, write-story
     - design: design-review, a11y-check
     - 2팀 이상: cross-team-review (공통)
   - Progressive Disclosure 적용:
     a. 메인 스킬 파일 (<500줄): .ai-harness/teams/{team}/skills/{name}.md
        - frontmatter에 pushy description 작성 (트리거 정확도 향상)
        - 핵심 절차와 원칙만 포함
     b. references 디렉토리: .ai-harness/teams/{team}/skills/{name}/references/
        - examples.md: 프로젝트 코드에서 추출한 실제 예시
        - checklist.md: 단계별 체크리스트
   - 각 스킬은 해당 팀의 convention-{team}.md를 명시적으로 참조
   - 기존 스킬(convention-*.md, entity.md 등)과 충돌하지 않도록 네이밍 확인

6.9 워크플로우 패턴 생성
   - AI를 효율적으로 쓰는 방법을 프로젝트에 맞게 자동 세팅
   - 팀 구성에 따라 아키텍처 패턴 자동 선택:
     - 단일 팀 → Pipeline (분석→구현→리뷰→테스트 순차)
     - backend + frontend → Fan-out/Fan-in (BE/FE 병렬 → 통합 검증)
     - planning + 개발 팀 → Producer-Reviewer (기획→리뷰→구현)
     - 3팀 이상 → Supervisor (중앙 조율 + 동적 분배)
   - 선택된 패턴을 사용자에게 보고하고 확인/변경 가능:
     ```
     "팀 구성에 따라 {패턴명} 패턴을 추천합니다.
      {패턴 설명 한 줄}. 다른 패턴으로 변경할까요? (enter: 수락)"
     ```
   - {플러그인}/templates/workflows/{pattern}.md.tmpl을 참고하여
     프로젝트 맞춤 워크플로우를 Claude가 .ai-harness/workflow.md에 Write
   - 워크플로우에 포함되는 내용:
     a. 기능 개발 파이프라인 (어떤 에이전트가 어떤 순서로)
     b. AI 활용 팁 (어떻게 요청하면 좋은지)
     c. 팀 간 핸드오프 순서
     d. 경계면 체크리스트 (Fan-out/Fan-in 시)

7. Hook 등록
   - Bash로 `node scripts/register-hooks.mjs register ...` 실행

8. config.yaml 생성
   - .ai-harness/config.yaml을 Write로 생성
   - project 섹션에 분석된 프로젝트 정보 포함
   - teams 배열에 선택된 팀 포함
   - agents 섹션에 생성된 에이전트 목록 포함
   - workflow 섹션에 선택된 패턴과 경로 포함

9. 외부 서비스 연동 스킬 설정 (선택)
   - 사용자에게 외부 서비스 스킬 목록을 제시:
     ```
     "외부 서비스 연동 스킬을 설정할 수 있습니다:
      [1] Jira — 이슈 관리 (+ 체크리스트)
      [2] Confluence — 문서 관리
      [3] Figma — 디자인 조회
      [4] Datadog — 모니터링

      설치할 스킬을 선택하세요 (번호 쉼표 구분, all: 전체, skip: 건너뛰기):"
     ```
   - 선택한 스킬마다 대화형으로 인증 정보 수집:
     a. 해당 서비스의 Base URL 질문
        예: "Jira URL? (예: https://company.atlassian.net): "
     b. 계정/이메일 질문
        예: "Jira 계정 이메일?: "
     c. API Token/Key 질문
        예: "Jira API Token? (Atlassian에서 발급, https://id.atlassian.com/manage-profile/security/api-tokens): "
     d. 서비스별 추가 정보 (필요 시)
        - Jira: 프로젝트 키 (예: "주로 사용하는 Jira 프로젝트 키? (예: PROJ): ")
        - Confluence: 스페이스 키 (예: "주로 사용하는 Confluence 스페이스? (예: DEV): ")
        - Datadog: Site (예: "Datadog Site? (예: datadoghq.com): ")
   - ~/.claude/credentials.md 확인:
     - 이미 해당 서비스 인증 정보가 있으면 "이미 설정되어 있습니다. 덮어쓸까요? (y/N)" 확인
     - 없으면 새로 추가
   - ~/.claude/credentials.md에 인증 정보 Write (또는 Edit으로 추가)
     ```markdown
     ## Atlassian (Jira & Confluence)
     - **Base URL**: https://midastech.atlassian.net
     - **User**: khb1122@midasin.com
     - **API Token**: `{입력받은 토큰}`
     ```
   - ~/.claude/skills/{스킬명}/SKILL.md 생성
     - 하네스 내장 스킬 템플릿에서 복사 또는 직접 생성
   - .ai-harness/config.yaml의 integrations 섹션에 설정된 서비스 기록
     ```yaml
     integrations:
       - name: jira
         base_url: https://midastech.atlassian.net
         project_key: PROJ
       - name: confluence
         base_url: https://midastech.atlassian.net/wiki
         space_key: DEV
     ```

10. MCP 서버 설정 (선택)
    - 사용자에게 MCP 서버 목록을 제시:
      ```
      "MCP 서버를 설정할 수 있습니다:
       [1] MySQL — DB 조회 (read-only SQL, 테이블 스키마)
       [2] Figma — 디자인 파일 조회/이미지 다운로드

       설치할 MCP를 선택하세요 (번호 쉼표 구분, all: 전체, skip: 건너뛰기):"
      ```
    - **MySQL MCP** 선택 시:
      a. 대화형으로 연결 정보 수집:
         - "MySQL Host?: " (예: db.company.com)
         - "MySQL User?: " (예: readonly)
         - "MySQL Password?: "
         - "MySQL Port? (기본: 3306): "
         - "기본 Database? (선택): "
      b. .claude/.mcp.json에 설정 추가 (또는 ~/.claude/.mcp.json):
         ```json
         {
           "mcpServers": {
             "mysql": {
               "command": "npx",
               "args": ["-y", "@nichochar/mysql-mcp-server"],
               "env": {
                 "MYSQL_HOST": "{입력값}",
                 "MYSQL_USER": "{입력값}",
                 "MYSQL_PASSWORD": "{입력값}",
                 "MYSQL_PORT": "{입력값}",
                 "MYSQL_DATABASE": "{입력값}"
               }
             }
           }
         }
         ```
      c. GitHub: cano721/mysql-mcp-server
      d. 도구: list_databases, list_tables, describe_table, execute_query (read-only)

    - **Figma MCP** 선택 시:
      a. 대화형으로 인증 정보 수집:
         - "Figma Personal Access Token?: " (Figma Settings > Personal access tokens에서 발급)
      b. .claude/.mcp.json에 설정 추가:
         ```json
         {
           "mcpServers": {
             "figma": {
               "command": "npx",
               "args": ["-y", "figma-developer-mcp"],
               "env": {
                 "FIGMA_API_KEY": "{입력값}"
               }
             }
           }
         }
         ```
      c. GitHub: nichochar/figma-developer-mcp
      d. 도구: get_figma_data, download_figma_images

    - .mcp.json이 이미 있으면 기존 설정에 merge (기존 MCP 서버 유지)
    - 이미 해당 MCP가 설정되어 있으면 "이미 설정됨. 덮어쓸까요? (y/N)" 확인
    - .ai-harness/config.yaml의 mcp 섹션에 기록:
      ```yaml
      mcp:
        - name: mysql
          host: db.company.com
        - name: figma
      ```

11. CLAUDE.md 주입
    - Bash로 `node scripts/inject-claudemd.mjs inject ...` 실행

12. 검증
    - Bash로 `node scripts/validate-generated.mjs .ai-harness .claude/agents` 실행
    - 에러가 있으면 수정 후 재검증
    - 경고는 사용자에게 안내

13. 완료 보고
    - 적용된 팀, Hook 수, 생성된 컨벤션 요약
    - [NEW] 생성된 에이전트 목록 + 각 에이전트의 핵심 역할
    - [NEW] 생성된 스킬 목록 (팀별)
    - [NEW] 워크플로우 패턴 + AI 활용 팁
    - 설치된 외부 서비스 스킬 목록
    - 미결정 사항이 있으면 건수 안내
    - 출력 형식:
      ```
      [Guard] 보안 Hook
        ✅ block-dangerous, secret-scanner, guardrails-check, audit-logger

      [Guide] 컨벤션
        ✅ convention-backend (패키지 구조, DTO 네이밍, API 규칙)

      [Harness] AI 활용 최적화
        ✅ 에이전트: {project}-developer, {project}-reviewer, {project}-architect
        ✅ 스킬: develop-backend, review-backend
        ✅ 워크플로우: Pipeline (분석→구현→리뷰→테스트)

      워크플로우 상세: .ai-harness/workflow.md
      ```

14. 추천 플러그인 (팀 기반)
    - Bash로 `claude plugin list` 실행하여 현재 설치된 플러그인 확인
    - 팀별 추천 목록에서 미설치 플러그인만 제시:

    **공통 (모든 팀):**
    | 플러그인 | 설명 |
    |---------|------|
    | oh-my-claudecode@omc | AI 오케스트레이션 (autopilot, ralph, team) |

    **backend:**
    | 플러그인 | 설명 |
    |---------|------|
    | pm-execution@pm-skills | 유저스토리, PRD, 테스트 시나리오 생성 |

    **qa (향후):**
    | 플러그인 | 설명 |
    |---------|------|
    | pm-execution@pm-skills | 테스트 시나리오, 체크리스트 생성 |

    - 미설치 플러그인이 있으면:
      ```
      "다음 플러그인이 backend 개발에 유용합니다:
       [1] OMC — AI 오케스트레이션 (autopilot, ralph)
       [2] pm-execution — 유저스토리, PRD, 테스트 시나리오
       설치할 플러그인? (번호 쉼표, all: 전체, skip: 건너뛰기)"
      ```
    - 선택한 플러그인 설치: Bash로 `claude plugin install {플러그인}` 실행
    - OMC 설치 시: "새 세션에서 `omc setup`을 실행하세요" 안내
    - 모두 설치되어 있으면 스킵
</Steps>
