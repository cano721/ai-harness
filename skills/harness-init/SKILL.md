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
   - 2가지를 세팅: **보안 Hook 등록** + **글로벌 CLAUDE.md 최적화**

   a. 보안 Hook 등록
      - ~/.claude/settings.json에 보안 Hook 4개가 등록되어 있는지 확인
      - 이미 등록된 Hook은 "이미 등록됨"으로 표시, 신규만 추가
      - 사용자에게 안내하고 **확인받은 후 진행**:
        ```
        "보안 Hook을 모든 프로젝트에 적용합니다:
          ✓ block-dangerous     — 위험 명령 차단
          ✓ secret-scanner      — 시크릿 하드코딩 감지
          ★ check-architecture  — 아키텍처 경계 위반 검증 (신규)
          ✓ audit-logger        — 이미 등록됨

         등록 위치: ~/.claude/settings.json
         진행할까요? (Y/n):"
        ```
      - **Hook 경로 동적 탐색**: 플러그인 설치 경로는 사용자마다 다르므로 동적으로 찾는다
        ```bash
        # 플러그인 루트 경로 찾기
        HARNESS_ROOT=$(find ~/.claude/plugins/cache/ai-harness -name "hooks" -type d 2>/dev/null | head -1 | sed 's|/hooks||')
        ```
      - 찾은 경로로 Hook 등록:
        ```bash
        node "$HARNESS_ROOT/scripts/register-hooks.mjs" register ~/.claude/settings.json \
          PreToolUse "Bash|Write|Edit" "bash $HARNESS_ROOT/hooks/block-dangerous.sh"
        ```
      - `$HARNESS_ROOT`를 찾지 못하면 사용자에게 플러그인 설치 확인 요청

   b. 글로벌 CLAUDE.md 최적화
      - ~/.claude/CLAUDE.md를 Read하여 기존 내용 분석
      - 하네스 보안 규칙과 중복되는 내용 식별:
        - 이미 있는 규칙 → 추가 안 함
        - 없는 규칙 → 최소한으로 추가
      - 분석 결과를 사용자에게 보고:
        ```
        "글로벌 CLAUDE.md 분석:
          현재: 45줄
          보안 관련 규칙: 3줄 발견

         하네스 보안 규칙과 비교:
          ✓ 이미 있음: '위험 명령 금지' — 추가 안 함
          ★ 신규: '시크릿 하드코딩 금지' — 1줄 추가
          ★ 신규: '.env 직접 쓰기 금지' — 1줄 추가

         기존 규칙 정리도 도와드릴까요? (Y/n):"
        ```
      - 정리 선택 시:
        - 중복 규칙 제거
        - 유사한 규칙 병합
        - 불필요하게 긴 설명 압축
        - 변경 전/후 비교 미리보기 제시
      - 최종 확인 후 `<!-- harness:start -->` ~ `<!-- harness:end -->` 구간으로 주입
      - 기존 내용은 구간 밖에서 보존

3. 프로젝트 확인
   - 현재 디렉토리를 분석하여 프로젝트 정보를 파악
   - **멀티 모듈 감지**: settings.gradle 또는 하위 디렉토리에 build.gradle이 여러 개 있으면 멀티 모듈
     - 각 모듈의 역할을 파악하여 사용자에게 표시
     - **어느 모듈을 분석 대상으로 할지 확인**:
       ```
       "멀티 모듈 프로젝트 감지:
         [1] llm          — API 서버 (Controller, Facade, Service)
         [2] llm-core     — 핵심 도메인 (Entity, Repository, 공통)
         [3] llm-scheduler — 스케줄러/배치

        컨벤션 분석 대상 모듈? (쉼표 구분, 기본: 1,2):"
       ```
     - 단일 모듈이면 이 질문 스킵
   - 사용자에게 **확인받은 후 진행**:
     ```
     "현재 프로젝트 분석:
       경로: /Users/.../ats-retention
       이름: ats-retention
       스택: Java 21, Spring Boot 3.5
       모듈: llm, llm-core, llm-scheduler
       분석 대상: llm, llm-core
       도메인: 22개 (agent, applicant, calendar, interview ...)
       팀: backend (1단계에서 선택)

      이 프로젝트에 backend 세팅을 적용할까요? (Y/n):"
     ```
   - **도메인이 많으면 대표 샘플링**: 10개 이상 도메인 시 대표 3~5개만 집중 분석하고 나머지는 패턴 일관성 확인
   - 도메인 분석 시 불명확한 부분은 사용자에게 질문:
     - 예: "User와 Member가 둘 다 있는데, 같은 개념인가요?"
     - 즉시 결정하기 어려우면 `.ai-harness/pending-decisions.yaml`에 저장

4. 프로젝트 세팅
   - `teams/{선택된 팀}/catalog.yaml`을 Read하여 추천 항목 목록을 로드
   - **scope: global 항목은 제외** (2단계에서 이미 처리했으므로 중복 표시하지 않음)
   - scope: local 항목만 대상으로, 이미 세팅되어 있는지 확인:
     - type: hook → .claude/settings.json에 해당 Hook이 등록되어 있는지
     - type: skill → .ai-harness/teams/{team}/skills/에 해당 파일이 있는지
     - type: config → .ai-harness/config.yaml에 해당 설정이 있는지
     - type: integration → .ai-harness/config.yaml의 integrations에 있는지
     - type: mcp → .claude/.mcp.json에 해당 서버가 있는지
     - type: plugin → `claude plugin list`에 해당 플러그인이 있는지
   - required: true 항목은 ✓ 필수로 표시, required: false 항목은 ✗/✓로 표시
   - 미세팅 항목만 번호 매겨서 사용자에게 표시:
     ```
     "[{team}] 프로젝트 세팅 상태:

      이미 세팅됨:
       ✓ 컨벤션 (convention-backend.md)

      미세팅 (추천):
       [1] ✗ {catalog 항목 description}
       [2] ✗ {catalog 항목 description}
       ...

      세팅할 항목? (번호 쉼표, all: 전체, skip: 건너뛰기):"
     ```
   - 선택된 항목에 대해 type별로 세팅 진행:
     a. **skill (컨벤션)**: 범용 템플릿 + 프로젝트 코드 분석 → 맞춤 컨벤션 생성
        - 패턴 충돌 시 사용자와 논의 (임의 결정하지 않음)
        - 미결정 사항은 pending-decisions.yaml에 저장
     b. **config (컨텍스트 맵)**: templates/context-map.md 기반으로 프로젝트 지도 생성
     c. **hook**: `node scripts/register-hooks.mjs register ...`로 등록
     d. **config**: .ai-harness/config.yaml에 설정 추가
     e. **integration**: 대화형 인증 정보 수집 → ~/.claude/credentials.md에 저장
     f. **mcp**: 연결 정보 수집 → .claude/.mcp.json에 설정
     g. **plugin**: `claude plugin install {install 값}` 실행
   - CLAUDE.md 주입: `node scripts/inject-claudemd.mjs inject ...`

5. 완료 보고
   - 적용된 팀, Hook 수, 생성된 컨벤션 요약
   - 미결정 사항이 있으면 건수 안내
</Steps>
