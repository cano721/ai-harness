# AI Harness - Init 플로우 상세

## 전체 흐름도

```
/harness-init
    │
    ▼
[1] 범위 선택 ─────── 글로벌 / 로컬 / 둘 다
    │
    ▼
[2] 환경 감지 ─────── Node.js, Git, Claude Code 확인
    │
    ▼
[3] 팀 선택 ──────── 기술 스택 감지 → 추천 → 사용자 선택
    │
    ▼
[4] 팀별 추천 카탈로그 ─ 선택된 팀의 추천 항목 제시 → 사용자 선택
    │
    ▼
[5] 프로젝트 분석 ──── 선택된 팀 기반으로 코드 구조/패턴 집중 분석
    │
    ▼
[6] 컨벤션 생성 ───── 범용 템플릿 + 실제 패턴 → 맞춤 컨벤션
    │                  패턴 충돌 시 사용자 논의, 미결정은 pending 저장
    ▼
[7] Hook 등록 ─────── scripts/register-hooks.mjs
    │                  .claude/settings.json에 등록
    ▼
[8] 컨텍스트 맵 생성 ── templates/context-map.md 기반
    │                    프로젝트 지도 자동 생성
    ▼
[9] 외부 서비스/플러그인 연동 ── Jira, MCP, 추천 플러그인 (선택)
    │
    ▼
[완료] 적용 요약 + 미결정 사항 안내
```

## 각 단계 상세

### 1단계: 범위 선택

사용자에게 적용 범위를 묻는다.

```
"하네스 적용 범위를 선택하세요:
 [1] 글로벌 — 모든 프로젝트에 적용 (~/.ai-harness/, ~/.claude/settings.json)
 [2] 로컬 — 이 프로젝트만 (./.ai-harness/, ./.claude/settings.json)
 [3] 둘 다

 선택? (기본: 2):"
```

| 범위 | 설정 경로 | Hook 등록 위치 |
|------|-----------|---------------|
| 글로벌 | `~/.ai-harness/` | `~/.claude/settings.json` |
| 로컬 | `./.ai-harness/` | `./.claude/settings.json` |

### 2단계: 환경 감지

`scripts/check-environment.mjs`를 실행하여 필수 환경을 확인한다.

| 항목 | 확인 내용 | 실패 시 |
|------|-----------|---------|
| Node.js | 설치 여부, 버전 | 설치 안내 후 중단 |
| Git | 저장소 여부 | 경고 (계속 가능) |
| Claude Code | 설치 여부 | 경고 (계속 가능) |
| 기존 하네스 | `.ai-harness/` 존재 여부 | "업데이트/초기화" 선택 |

### 3단계: 팀 선택

프로젝트 파일로 기술 스택을 빠르게 감지하고, 적합한 팀을 추천한다.

**기술 스택 감지 규칙:**

| 파일 | 감지 스택 | 추천 팀 |
|------|-----------|---------|
| `build.gradle`, `pom.xml` | Java/Spring | backend |
| `package.json` + `tsconfig.json` | TypeScript/React/Vue/Next.js | frontend |
| `Dockerfile`, `Jenkinsfile`, `*.tf` | Docker/CI/Terraform | devops |
| `cypress.config.*`, `jest.config.*` | 테스트 프레임워크 | qa |
| 복합 스택 | 여러 감지 | 여러 팀 추천 |

**사용자에게 제시하는 화면:**

```
"기술 스택: Java/Spring Boot + React 감지
 추천 팀: backend, frontend

 사용 가능한 팀:
  [1] backend  — Java/Spring, API, DB
  [2] frontend — React/Vue, 컴포넌트, 번들
  [3] devops   — 인프라, CI/CD, 배포
  [4] qa       — 테스트, 커버리지, 회귀
  [5] design   — UI/UX, 접근성, 반응형
  [6] planning — PRD, 유저스토리, 추정

 선택? (쉼표로 복수 선택, 기본: 1,2):"
```

### 4단계: 팀별 추천 카탈로그

선택된 팀마다 init 시 적용할 수 있는 항목을 카탈로그 형태로 제시한다. 보안 Hook은 필수(locked)이고, 나머지는 추천이다.

#### backend 추천 카탈로그

```
"[backend] 적용 항목:

 필수 (변경 불가):
  ✓ block-dangerous — 위험 명령 차단
  ✓ secret-scanner  — 시크릿 감지
  ✓ audit-logger    — 감사 로깅
  ✓ check-architecture — 아키텍처 경계 검증

 추천 Hook:
  [1] ✓ api-compat     — API 호환성 검사 (엔드포인트 변경 시)
  [2] ✓ entity-review  — 엔티티 변경 리뷰 (필드 추가/삭제 시)
  [3] ✓ sql-review     — SQL 검증 (바인딩, SELECT * 체크)

 추천 Skill:
  [4] ✓ convention-backend — 코드 컨벤션 (프로젝트 분석 후 맞춤 생성)
  [5] ✓ api-design         — API 설계 가이드
  [6] ✓ entity             — 엔티티 생성
  [7] ✓ migration          — DB 마이그레이션

 추천 설정:
  [8] ✓ 아키텍처 레이어 검증 — Entity→Config→Repository→Service→Controller
  [9] ✓ 테스트 커버리지 80%

 제외할 항목? (번호 쉼표, enter: 전체 적용):"
```

#### frontend 추천 카탈로그

```
"[frontend] 적용 항목:

 필수 (변경 불가):
  ✓ block-dangerous / secret-scanner / audit-logger / check-architecture

 추천 Hook:
  [1] ✓ bundle-size  — 번들 사이즈 체크 (초기 로드 < 300KB)
  [2] ✓ lighthouse   — Lighthouse 성능 검사

 추천 Skill:
  [3] ✓ convention-frontend — 코드 컨벤션
  [4] ✓ component           — 컴포넌트 생성
  [5] ✓ state-management    — 상태 관리 가이드
  [6] ✓ performance         — 성능 최적화

 추천 설정:
  [7] ✓ moment.js 금지 (dayjs 사용)
  [8] ✓ lodash 전체 import 금지

 제외할 항목? (번호 쉼표, enter: 전체 적용):"
```

#### planning 추천 카탈로그

```
"[planning] 적용 항목:

 필수 (변경 불가):
  ✓ block-dangerous / secret-scanner / audit-logger / check-architecture

 추천 Skill:
  [1] ✓ convention-planning — 문서 작성 컨벤션
  [2] ✓ prd                 — PRD 작성
  [3] ✓ user-story          — 유저스토리 작성 (Given-When-Then)
  [4] ✓ estimation          — 공수 추정

 추천 설정:
  [5] ✓ PRD 필수 항목: 배경/목적/범위/비범위
  [6] ✓ 기술 구현 방식 지정 금지 (개발팀 자율)

 제외할 항목? (번호 쉼표, enter: 전체 적용):"
```

### 5단계: 프로젝트 분석

선택된 팀에 따라 분석 대상이 달라진다.

| 팀 | 분석 대상 | 파악 내용 |
|----|-----------|-----------|
| backend | 패키지 구조, Controller/Service/Repository | 네이밍 패턴, 응답 클래스, 예외 처리, DTO 규칙, API 경로 |
| frontend | 컴포넌트 구조, 상태 관리, 라우팅 | 디렉토리 패턴, CSS 방식, API 호출 패턴 |
| devops | CI/CD, Dockerfile, k8s | 배포 방식, 환경 변수 관리, 인프라 구조 |
| qa | 테스트 프레임워크, 디렉토리 | 커버리지 설정, 테스트 네이밍 |
| design | 디자인 시스템, 토큰 | 컴포넌트 라이브러리, 토큰 구조 |
| planning | 기존 문서, 이슈 추적기 | 문서 형식, 템플릿 |

**프로젝트 정보 수집** (도메인은 프로젝트에 속함, 팀에 속하지 않음):
- `project.name` — 프로젝트명
- `project.domain` — 도메인 (예: "채용 관리", "이커머스")
- `project.entities` — 주요 엔티티 목록
- `project.tech_stack` — 기술 스택
- `project.base_package` — 베이스 패키지 (Java인 경우)

**도메인 분석 시 불명확한 부분 처리:**
- 엔티티 간 관계가 불명확하면 사용자에게 질문
  - 예: "User와 Member가 둘 다 있는데, 같은 개념인가요?"
- 도메인 용어가 혼재되면 표준 용어 확인
  - 예: "Applicant, Candidate 둘 다 쓰고 있는데 어떤 걸로 통일할까요?"
- 즉시 결정하기 어려운 사항은 `.ai-harness/pending-decisions.yaml`에 저장

```yaml
pending_decisions:
  - id: 1
    category: domain
    question: "User와 Member의 관계 정리 필요"
    context: "User(12곳), Member(5곳) 혼재"
    created_at: "2026-03-28"
    status: pending
```

### 6단계: 컨벤션 생성

init의 핵심 단계. 범용 템플릿을 프로젝트 실제 코드에 맞춰 수정한다.

**절차:**
1. `teams/{team}/skills/convention-{team}.md` 범용 템플릿 읽기
2. 프로젝트 코드 추가 분석:
   - 기존 응답 클래스 (CommonResponse? ApiResult? 커스텀?)
   - 실제 패키지 구조 (Glob + Read)
   - 마이그레이션 도구 (Flyway? Liquibase?)
   - DTO 네이밍, 예외 클래스, 테스트 프레임워크
3. **패턴 충돌 시 사용자와 논의** (임의 결정하지 않음):
   ```
   "응답 클래스가 CommonResponse(15곳), ApiResult(3곳) 2개 발견.
    CommonResponse로 통일할까요?"

   "DTO 네이밍이 CreateUserDto(8개), UserCreateRequest(5개) 혼재.
    어떤 패턴으로 통일할까요?"
   ```
4. 사용자가 "나중에 결정"하면 `pending-decisions.yaml`에 저장, 빈도 높은 패턴을 임시 기본값으로 사용 (컨벤션에 "(임시)" 표기)
5. 패턴이 하나뿐이면 그대로 채택, 확인만 받음
6. 패턴이 없으면 (신규 프로젝트) 범용 템플릿 기본값 제안
7. `.ai-harness/teams/{team}/skills/convention-{team}.md`에 맞춤 컨벤션 저장

**기존 컨벤션이 있으면 덮어쓰지 않고 사용자에게 확인한다.**

### 7단계: Hook 등록

`scripts/register-hooks.mjs`로 `.claude/settings.json`에 Hook을 등록한다.

```bash
node scripts/register-hooks.mjs register .claude/settings.json \
  PreToolUse "Bash|Write|Edit" \
  "bash /path/to/hooks/block-dangerous.sh"
```

**비파괴적 등록 원칙:**
- 기존 Hook은 건드리지 않음
- `_managed_by: "ai-harness"` 마커로 하네스 Hook 식별
- 중복 등록 방지 (같은 event + command면 스킵)

### 8단계: 컨텍스트 맵 생성

`templates/context-map.md` 템플릿의 플레이스홀더를 프로젝트 분석 결과로 채운다.

| 플레이스홀더 | 채워지는 값 |
|-------------|-------------|
| `{project.name}` | 프로젝트명 |
| `{project.domain}` | 도메인 |
| `{project.tech_stack}` | 기술 스택 |
| `{project.base_package}` | 베이스 패키지 |
| 핵심 진입점 | 실제 디렉토리 구조 기반 |
| 주요 엔티티 | 분석된 Entity 목록 + 관계 |
| 공통 패턴 | 감지된 응답 클래스, 예외, DTO 패턴 |
| 자주 수정 파일 | `git log` 분석 결과 |

저장 위치: `.ai-harness/context-map.md`

**이 파일은 에이전트를 위한 지도다. 전체 매뉴얼이 아닌 핵심만 담는다.**

### 9단계: 외부 서비스/플러그인 연동

세 가지 선택적 연동을 순서대로 진행한다.

#### 9-1. 외부 서비스 스킬 설정

```
"외부 서비스 연동 스킬을 설정할 수 있습니다:
 [1] Jira       — 이슈 관리 (+ 체크리스트)
 [2] Confluence — 문서 관리
 [3] Figma      — 디자인 조회
 [4] Datadog    — 모니터링

 설치할 스킬? (번호 쉼표, all: 전체, skip: 건너뛰기):"
```

선택 시 대화형으로 인증 정보를 수집한다:
- Base URL, 계정/이메일, API Token
- `~/.claude/credentials.md`에 저장 (이미 있으면 덮어쓸지 확인)
- `.ai-harness/config.yaml`의 `integrations` 섹션에 기록

#### 9-2. MCP 서버 설정

```
"MCP 서버를 설정할 수 있습니다:
 [1] MySQL — DB 조회 (read-only)
 [2] Figma — 디자인 파일 조회

 설치할 MCP? (번호 쉼표, all: 전체, skip: 건너뛰기):"
```

선택 시 연결 정보를 수집하여 `.claude/.mcp.json`에 설정 추가한다.

#### 9-3. 추천 플러그인

팀 기반으로 유용한 Claude Code 플러그인을 추천한다.

| 대상 | 플러그인 | 설명 |
|------|---------|------|
| 공통 | oh-my-claudecode@omc | AI 오케스트레이션 (autopilot, ralph, team) |
| backend | pm-execution@pm-skills | 유저스토리, PRD, 테스트 시나리오 |

미설치 플러그인만 제시하고, 선택 시 `claude plugin install`로 설치한다.

## init 후 프로젝트에 생성되는 파일

```
프로젝트/
├── .ai-harness/
│   ├── config.yaml                              # 프로젝트 설정
│   ├── context-map.md                           # 에이전트용 프로젝트 지도
│   ├── pending-decisions.yaml                   # 미결정 사항 (있는 경우만)
│   ├── logs/                                    # 감사 로그 디렉토리
│   └── teams/
│       └── {선택한 팀}/
│           ├── CLAUDE.md                        # 팀 규칙
│           ├── hooks/                           # 팀 Hook (있는 경우)
│           │   └── *.sh
│           └── skills/
│               ├── convention-{team}.md         # 맞춤 컨벤션 (핵심)
│               └── *.md                         # 팀 스킬
├── .claude/
│   ├── CLAUDE.md                                # 하네스 규칙 주입 (기존 보존)
│   ├── settings.json                            # Hook 등록 (기존 보존)
│   └── .mcp.json                                # MCP 설정 (선택한 경우)
```

**비파괴적 원칙:**
- `CLAUDE.md`: `<!-- harness:start -->` ~ `<!-- harness:end -->` 구간만 관리, 기존 내용 보존
- `settings.json`: `_managed_by: "ai-harness"` 마커로 하네스 항목만 식별, 기존 Hook 보존
- `.mcp.json`: 기존 MCP 서버 유지, 새 서버만 추가

## init 이후 사용

| 명령 | 용도 |
|------|------|
| `/harness-status` | 적용 상태 + 차단 현황 + 미결정 사항 확인 |
| `/harness-rules` | 현재 적용 중인 규칙 확인 |
| `/harness-team` | 팀 추가/제거 (재init 없이) |
| `/harness-scaffold` | 컨벤션 기반 보일러플레이트 생성 |
| `/harness-metrics` | 차단 패턴 분석 + 개선 제안 |
