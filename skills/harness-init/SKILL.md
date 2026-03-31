---
name: harness-init
description: 팀에 맞는 AI Harness를 초기화합니다 — planning은 글로벌 bundle, backend는 글로벌 세팅 + 프로젝트 로컬 세팅
---

<Purpose>
팀을 선택하고, 해당 팀에 맞는 설치 경로와 자산을 세팅합니다.
- planning: Codex 또는 Claude Code에 맞는 글로벌 planner bundle 설치
- backend 등 개발 팀: 보안 Hook + 글로벌 CLAUDE.md 최적화 + 프로젝트 로컬 컨벤션/Hook/컨텍스트맵 세팅
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
   - 빌드 파일로 기술 스택을 빠르게 감지한다 (Glob으로 `build.gradle`, `pom.xml`, `package.json`, `tsconfig.json` 존재 여부만 확인)
   - 감지된 스택 기반으로 팀 추천:
     - Java/Spring → backend 추천
     - React/Vue/Next.js → frontend 추천
     - Terraform/Helm/Docker → devops 추천
   - planning은 기술 스택보다 사용자의 역할이 우선이므로 항상 별도 옵션으로 제시한다.
   - 현재 실제 세팅이 준비된 팀은 `planning`, `backend`다. 다른 팀을 선택하면 준비 중이라고 안내하고 종료한다.
   - 사용 가능한 팀 목록 제시:
     ```
     "기술 스택: Java/Spring Boot 감지
      추천 팀: backend

      역할 기반 옵션:
       - planning — 프로젝트와 무관한 글로벌 planner bundle

      사용 가능한 팀:
       [1] planning — 글로벌 planner bundle (Codex/Claude)
       [2] backend  — Java/Spring, API, DB
       [3] frontend — 준비 중
       [4] devops   — 준비 중
       [5] qa       — 준비 중
       [6] design   — 준비 중

      선택? (기본: 2):"
     ```
   - 준비 중인 로컬 팀이 선택되면:
     ```
     "현재 실제 초기화가 준비된 팀은 planning, backend입니다.
      {선택한 팀}은 아직 init 흐름이 완성되지 않았습니다.
      planning 또는 backend로 진행할까요?"
     ```
   - 사용자 확인 후 결정

2. planning 선택 시: runtime-aware 글로벌 설치
   - 현재 실행 환경이 Codex인지 Claude Code인지 우선 감지한다.
     - Codex 신호: `CODEX_THREAD_ID`, `CODEX_SHELL` 같은 환경 변수
     - Claude 신호: Claude 전용 환경 변수 또는 `.claude` 설정 경로
     - 모호하면 사용자에게 현재 사용하는 에이전트를 확인한다.
   - `teams/planning/bundle/`을 설치 소스로 사용한다.
     - `teams/planning/skills/`와 `teams/planning/CLAUDE.md`는 legacy 초안이므로 planner mode 설치 소스로 쓰지 않는다.
   - 먼저 아래 inspect 명령으로 설치 대상을 미리 보여준다:
     ```bash
     node scripts/install-planner-bundle.mjs inspect --runtime auto
     ```
     ```
     "planning 팀 글로벌 세팅:
       runtime: Codex
       detection: env:codex
       target: ~/.codex
       context: ~/.codex/AGENTS.md
       agents: 16개
       skills: 26개
       templates: 1개

      설치할까요? (Y/n):"
     ```
   - 확인 후 아래 install 명령을 실행한다:
     ```bash
     node scripts/install-planner-bundle.mjs install --runtime auto
     ```
     - Codex: `AGENTS.md`, `agents/`, `skills/`, `planner-templates/` 설치
     - Claude: `CLAUDE.md`, `agents/`, `skills/`, `planner-templates/` 설치
     - 텍스트 자산은 runtime에 맞게 치환한다 (`AGENTS.md → CLAUDE.md`, `~/.codex → ~/.claude` 등)
   - 설치 후 readiness를 비차단으로 점검한다:
     - `~/.claude/credentials.md`에 Atlassian 섹션 존재 여부
     - jira, jira-checklist skill 존재 여부
     - policy template 설치 여부
   - 사용자가 Claude Code를 쓰는 경우에도 planner bundle은 프로젝트 로컬 `.ai-harness/`가 아니라 Claude 전역 디렉토리에 설치한다.
   - planning에서는 프로젝트 분석, `.ai-harness/teams/planning` 생성, Hook 등록을 진행하지 않는다.

3. backend 등 개발 팀 선택 시: 기존 프로젝트 로컬 세팅
   - 현재 로컬 init이 실제 준비된 팀은 backend다. 다른 개발 팀은 추후 catalog/Hook/템플릿이 준비되면 확장한다.

   a. 글로벌 세팅 확인
      - 2가지를 세팅한다: **보안 Hook 등록** + **글로벌 CLAUDE.md 최적화**

      1) 보안 Hook 등록
         - `~/.claude/settings.json`에 보안 Hook 4개가 등록되어 있는지 확인
         - 이미 등록된 Hook은 "이미 등록됨"으로 표시하고, 신규만 추가
         - 사용자에게 안내하고 확인받은 후 진행:
           ```
           "보안 Hook을 모든 프로젝트에 적용합니다:
             ✓ block-dangerous     — 위험 명령 차단
             ✓ secret-scanner      — 시크릿 하드코딩 감지
             ★ check-architecture  — 아키텍처 경계 위반 검증 (신규)
             ✓ audit-logger        — 이미 등록됨

            등록 위치: ~/.claude/settings.json
            진행할까요? (Y/n):"
           ```
         - Hook 경로는 플러그인 설치 경로를 기준으로 동적 탐색한다.
           ```bash
           HARNESS_ROOT=$(find ~/.claude/plugins/cache/ai-harness -name "hooks" -type d 2>/dev/null | head -1 | sed 's|/hooks||')
           ```
         - 찾은 경로로 Hook 등록:
           ```bash
           node "$HARNESS_ROOT/scripts/register-hooks.mjs" register ~/.claude/settings.json \
             PreToolUse "Bash|Write|Edit" "bash $HARNESS_ROOT/hooks/block-dangerous.sh"
           ```
         - `$HARNESS_ROOT`를 찾지 못하면 사용자에게 플러그인 설치 확인을 요청하거나 현재 repo 경로를 직접 지정해 진행한다.

      2) 글로벌 CLAUDE.md 최적화
         - `~/.claude/CLAUDE.md`를 Read하여 기존 내용 분석
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
           - 유사 규칙 병합
           - 불필요하게 긴 설명 압축
           - 변경 전/후 비교 미리보기 제시
         - 최종 확인 후 `<!-- harness:start -->` ~ `<!-- harness:end -->` 구간으로 주입
         - 기존 내용은 구간 밖에서 보존

   b. 프로젝트 확인
      - 현재 디렉토리를 분석하여 프로젝트 정보를 파악
      - 멀티 모듈 감지: `settings.gradle` 또는 하위 디렉토리에 `build.gradle`이 여러 개 있으면 멀티 모듈로 판단
      - 멀티 모듈이면 각 모듈의 역할을 파악해 분석 대상을 사용자에게 확인:
        ```
        "멀티 모듈 프로젝트 감지:
          [1] llm           — API 서버 (Controller, Facade, Service)
          [2] llm-core      — 핵심 도메인 (Entity, Repository, 공통)
          [3] llm-scheduler — 스케줄러/배치

         컨벤션 분석 대상 모듈? (쉼표 구분, 기본: 1,2):"
        ```
      - 단일 모듈이면 이 질문은 생략
      - 사용자에게 확인받은 후 진행:
        ```
        "현재 프로젝트 분석:
          경로: /Users/.../ats-retention
          이름: ats-retention
          스택: Java 21, Spring Boot 3.5
          모듈: llm, llm-core, llm-scheduler
          분석 대상: llm, llm-core
          도메인: 22개 (agent, applicant, calendar, interview ...)
          팀: backend

         이 프로젝트에 backend 세팅을 적용할까요? (Y/n):"
        ```
      - 도메인이 많으면 대표 3~5개만 집중 분석하고 나머지는 패턴 일관성만 확인
      - 도메인 분석 시 불명확한 부분은 사용자에게 질문
        - 예: "User와 Member가 둘 다 있는데, 같은 개념인가요?"
      - 즉시 결정하기 어려운 사항은 `.ai-harness/pending-decisions.yaml`에 저장

   c. 프로젝트 CLAUDE.md 최적화
      - 프로젝트 루트의 `CLAUDE.md`가 존재하면 Read하여 기존 내용 분석
      - 하네스가 주입할 규칙과 중복/충돌되는 내용 식별:
        - 이미 있는 규칙 → 추가 안 함
        - 충돌하는 규칙 → 사용자와 논의 (어느 쪽을 우선할지)
        - 없는 규칙 → 최소한으로 추가
      - 분석 결과를 사용자에게 보고:
        ```
        "프로젝트 CLAUDE.md 분석:
          현재: 120줄
          컨벤션 관련 규칙: 8줄 발견

         하네스 팀 규칙과 비교:
          ✓ 이미 있음: 'REST API 버저닝' — 추가 안 함
          ⚠ 충돌: 'DTO는 class 사용' ↔ 하네스 'DTO는 Record 권장'
          ★ 신규: 'context-map.md 참조' — 1줄 추가

         충돌 규칙을 논의할까요? (Y/n):"
        ```
      - 충돌 논의 시:
        - 기존 프로젝트 규칙을 우선할지, 하네스 추천을 따를지 사용자에게 확인
        - 결정된 내용은 컨벤션 생성 시 반영
      - 정리 선택 시 (글로벌과 동일):
        - 중복 규칙 제거
        - 유사 규칙 병합
        - 변경 전/후 비교 미리보기 제시
      - 최종 확인 후 `<!-- harness:start -->` ~ `<!-- harness:end -->` 구간으로 주입
      - 기존 내용은 구간 밖에서 보존
      - `CLAUDE.md`가 없으면 이 단계는 건너뛴다

   d. 프로젝트 세팅
      - `teams/{선택된 팀}/catalog.yaml`을 Read하여 추천 항목 목록을 로드
      - `scope: global` 항목은 제외한다. 글로벌 세팅은 이미 3-a에서 처리했기 때문이다.
      - `scope: local` 항목만 대상으로, 이미 세팅되어 있는지 확인:
        - `type: hook` → `.claude/settings.json`에 해당 Hook이 등록되어 있는지
        - `type: skill` → `.ai-harness/teams/{team}/skills/`에 해당 파일이 있는지
        - `type: config` → `.ai-harness/config.yaml`에 해당 설정이 있는지
        - `type: integration` → `.ai-harness/config.yaml`의 `integrations`에 있는지
        - `type: mcp` → `.claude/.mcp.json`에 해당 서버가 있는지
        - `type: plugin` → `claude plugin list`에 해당 플러그인이 있는지
      - `required: true` 항목은 필수로 표시하고, `required: false` 항목은 추천으로 표시
      - 미세팅 항목만 번호 매겨 사용자에게 표시:
        ```
        "[backend] 프로젝트 세팅 상태:

         이미 세팅됨:
          ✓ 컨벤션 (convention-backend.md)

         미세팅 (추천):
          [1] ✗ {catalog 항목 description}
          [2] ✗ {catalog 항목 description}
          ...

         세팅할 항목? (번호 쉼표, all: 전체, skip: 건너뛰기):"
        ```
      - 선택된 항목에 대해 type별로 세팅 진행:
        - `skill (컨벤션)`:
          - 범용 템플릿 + 프로젝트 코드 분석으로 맞춤 컨벤션 생성
          - 패턴 충돌 시 사용자와 논의하고 임의 결정하지 않는다
          - 미결정 사항은 `pending-decisions.yaml`에 저장
        - `config (컨텍스트 맵)`:
          - `templates/context-map.md` 기반으로 프로젝트 지도 생성
        - `hook`:
          - `node scripts/register-hooks.mjs register ...`로 등록
        - `config`:
          - `.ai-harness/config.yaml`에 설정 추가
        - `integration`:
          - 대화형 인증 정보 수집 후 `~/.claude/credentials.md`에 저장
        - `mcp`:
          - 연결 정보 수집 후 `.claude/.mcp.json`에 설정
        - `plugin`:
          - `claude plugin install {install 값}` 실행
      - 로컬 팀 컨텍스트가 필요하면 `node scripts/inject-claudemd.mjs inject ...`로 팀 규칙 구간을 주입한다

3.5 [v2] 프로젝트 맞춤 에이전트 생성 (Harness — AI 활용 최적화)
   - "규칙을 아는 Claude"가 아니라 "프로젝트를 이해하는 Claude"를 만드는 단계
   - planning 팀은 이 단계를 건너뛴다 (planning은 글로벌 bundle로 별도 관리)
   - Bash로 `node scripts/generate-agents.mjs .ai-harness/config.yaml .ai-harness .claude/agents` 실행
   - 사용자에게 생성할 에이전트 목록을 보여주고 확인:
     ```
     "AI 에이전트를 생성합니다 (프로젝트를 이해하는 전문 에이전트):
      [1] {project}-developer — 도메인 맥락 + 컨벤션 내장 개발 에이전트
      [2] {project}-reviewer — 경계면 검증 + 컨벤션 체크 리뷰 에이전트
      [3] {project}-architect — 도메인 관계도 + 레이어 구조 설계 에이전트

      제외할 에이전트? (번호 쉼표, enter: 전체 생성, skip: 건너뛰기):"
     ```
   - 각 에이전트를 {플러그인}/templates/agents/ 템플릿을 구조 참고하되,
     프로젝트 분석 결과를 반영하여 Claude가 직접 Write
   - .ai-harness/agents/{name}.md + .claude/agents/{name}.md 에 생성
   - 이미 .claude/agents/에 같은 이름 파일이 있으면 사용자에게 확인
   - frontmatter에 `_managed_by: ai-harness` 포함

3.6 [v2] 팀별 전문 스킬 생성
   - 기존 convention이 "무엇을 지켜라"라면, 스킬은 "이렇게 하면 잘 된다"를 정의
   - 선택된 팀별로 개발/리뷰 스킬 생성 (templates/skills/ 참조)
   - Progressive Disclosure: 메인 파일 <500줄 + references/ 분리
   - 각 스킬은 convention-{team}.md를 명시적으로 참조
   - pushy description으로 트리거 정확도 향상

3.7 [v2] 워크플로우 패턴 생성
   - 팀 구성에 따라 아키텍처 패턴 자동 선택:
     - 단일 팀 → Pipeline
     - backend + frontend → Fan-out/Fan-in
     - planning + 개발 팀 → Producer-Reviewer
     - 3팀 이상 → Supervisor
   - templates/workflows/{pattern}.md.tmpl 참고하여 .ai-harness/workflow.md 생성

3.8 [v2] 검증
   - Bash로 `node scripts/validate-generated.mjs .ai-harness .claude/agents` 실행
   - 에러가 있으면 수정 후 재검증

4. 완료 보고
   - planning:
     - 설치 runtime
     - 대상 경로
     - 설치된 skill/agent/template 수
     - Jira readiness 요약
   - backend 등 개발 팀:
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
     - 미결정 사항이 있으면 건수 안내
</Steps>
