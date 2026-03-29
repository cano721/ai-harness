# AI Harness - Init 플로우 상세

## 전체 흐름도

```
/harness-init (프로젝트 디렉토리에서 실행)
    │
    ▼
[1] 팀 선택 ──────── "어떤 팀 설정을 사용할까요?" → 사용자 선택
    │
    ▼
[2] 글로벌 세팅 확인 ── "모든 프로젝트에 보안 Hook을 적용합니다"
    │                     → 사용자 확인 후 진행
    │                     → 이미 있으면 "이미 등록됨" 표시
    ▼
[3] 프로젝트 확인 ──── "현재 프로젝트: /path/to/project"
    │                    "이 프로젝트에 세팅할까요?" → 사용자 확인
    ▼
[4] 프로젝트 세팅 ──── 이미 세팅된 것 / 안 된 것 표시
    │                    → 세팅할 항목 사용자 선택 후 진행
    ▼
[완료] 적용 요약
```

## 핵심 원칙

> **모든 단계에서 사용자에게 "이걸 할 건데, 괜찮아?"라고 확인받는다.**

## 글로벌 vs 로컬 분리

사용자에게 "글로벌/로컬" 선택을 묻지 않는다. **성격에 따라 자동 분리**한다.

| 항목 | 위치 | 이유 |
|------|------|------|
| 보안 Hook (block-dangerous, secret-scanner, check-architecture) | **글로벌** `~/.claude/settings.json` | 모든 프로젝트에서 위험 명령 차단 |
| audit-logger | **글로벌** `~/.claude/settings.json` | 모든 프로젝트에서 로깅 |
| 인증 정보 | **글로벌** `~/.claude/credentials.md` | 프로젝트와 무관 |
| 팀 선택/컨벤션 | **로컬** `./.ai-harness/` | 프로젝트마다 다름 |
| 컨텍스트 맵 | **로컬** `./.ai-harness/context-map.md` | 프로젝트별 구조 |
| 아키텍처 레이어 | **로컬** `./.ai-harness/config.yaml` | 프로젝트마다 다를 수 있음 |
| 팀별 Hook | **로컬** `./.claude/settings.json` | 프로젝트별 팀 특화 |
| 도메인/엔티티 | **로컬** `./.ai-harness/config.yaml` | 프로젝트별 도메인 |

## 각 단계 상세

### 1단계: 팀 선택

가장 먼저 팀을 선택한다. 이후 단계의 분석 범위와 추천 항목이 팀에 따라 달라지기 때문이다.

빌드 파일로 기술 스택을 빠르게 감지하고 추천한다:

```
"기술 스택: Java/Spring Boot 감지
 추천 팀: backend

 사용 가능한 팀:
  [1] backend  — Java/Spring, API, DB
  [2] frontend — React/Vue, 컴포넌트, 번들
  [3] devops   — 인프라, CI/CD, 배포
  [4] qa       — 테스트, 커버리지, 회귀
  [5] design   — UI/UX, 접근성, 반응형
  [6] planning — PRD, 유저스토리, 추정

 선택? (쉼표로 복수 선택, 기본: 1):"
```

### 2단계: 글로벌 세팅 확인

보안 Hook을 모든 프로젝트에 적용할 것을 사용자에게 **안내하고 확인받는다**.

```
"다음 보안 Hook을 모든 프로젝트에 적용합니다:
  ✓ block-dangerous     — 위험 명령 차단 (rm -rf, DROP TABLE 등)
  ✓ secret-scanner      — 시크릿 하드코딩 감지
  ✓ check-architecture  — 아키텍처 경계 위반 검증
  ✓ audit-logger        — 모든 도구 사용 로깅

 등록 위치: ~/.claude/settings.json
 진행할까요? (Y/n):"
```

이미 등록된 Hook이 있으면:

```
"글로벌 보안 세팅 상태:
  ✓ block-dangerous     — 이미 등록됨
  ✓ secret-scanner      — 이미 등록됨
  ★ check-architecture  — 신규 등록
  ✓ audit-logger        — 이미 등록됨

 check-architecture를 추가 등록합니다. 진행할까요? (Y/n):"
```

### 3단계: 프로젝트 확인

현재 디렉토리를 분석하여 프로젝트 정보를 파악하고, 이 프로젝트에 세팅할지 확인받는다.

```
"현재 프로젝트 분석:
  경로: /Users/khb1122/Desktop/projects/my-service
  이름: my-service
  스택: Java 17, Spring Boot 3.2, JPA, MySQL
  팀: backend (1단계에서 선택)

 이 프로젝트에 backend 세팅을 적용할까요? (Y/n):"
```

### 4단계: 프로젝트 세팅

이미 세팅된 항목과 안 된 항목을 구분하여 보여주고, 사용자가 선택한다.

```
"[backend] 프로젝트 세팅 상태:

 이미 세팅됨:
  ✓ 컨벤션 (convention-backend.md)
  ✓ 팀 Hook: sql-review

 미세팅 (추천):
  [1] ✗ 컨텍스트 맵 — 에이전트용 프로젝트 지도
  [2] ✗ 팀 Hook: api-compat — API 호환성 검사
  [3] ✗ 팀 Hook: entity-review — 엔티티 변경 리뷰
  [4] ✗ 아키텍처 레이어 검증 설정
  [5] ✗ 외부 서비스 연동 (Jira, Confluence 등)
  [6] ✗ MCP 서버 (MySQL, Figma)
  [7] ✗ 추천 플러그인 (OMC, pm-skills)

 세팅할 항목? (번호 쉼표, all: 전체, skip: 건너뛰기):"
```

선택된 항목에 대해 순서대로 세팅을 진행한다:
- 컨벤션이 없으면 → 프로젝트 분석 후 맞춤 컨벤션 생성 (패턴 충돌 시 사용자 논의)
- 컨텍스트 맵이 없으면 → 프로젝트 분석 후 자동 생성
- 팀 Hook이 없으면 → .claude/settings.json에 등록
- 외부 서비스 → 대화형으로 인증 정보 수집 후 설정
- MCP 서버 → 연결 정보 수집 후 .claude/.mcp.json에 설정
- 추천 플러그인 → `claude plugin install` 실행

## 4단계 하위 절차 상세

### 프로젝트 분석 (4단계에서 컨벤션/컨텍스트 맵 세팅 시 수행)

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

### 컨벤션 생성 (4단계에서 컨벤션 세팅 시 수행)

범용 템플릿을 프로젝트 실제 코드에 맞춰 수정한다.

**절차:**
1. `teams/{team}/skills/convention-{team}.md` 범용 템플릿 읽기
2. 프로젝트 코드 추가 분석 (응답 클래스, 패키지 구조, DTO 네이밍 등)
3. **패턴 충돌 시 사용자와 논의** (임의 결정하지 않음):
   ```
   "응답 클래스가 CommonResponse(15곳), ApiResult(3곳) 2개 발견.
    CommonResponse로 통일할까요?"
   ```
4. 사용자가 "나중에 결정"하면 `pending-decisions.yaml`에 저장
5. `.ai-harness/teams/{team}/skills/convention-{team}.md`에 맞춤 컨벤션 저장

### Hook 등록 (2단계 글로벌 + 4단계 팀별)

`scripts/register-hooks.mjs`로 Hook을 등록한다.

**비파괴적 등록 원칙:**
- 기존 Hook은 건드리지 않음
- `_managed_by: "ai-harness"` 마커로 하네스 Hook 식별
- 중복 등록 방지 (같은 event + command면 스킵)

### 외부 서비스/플러그인 연동 (4단계에서 선택 시 수행)

```
"외부 서비스 연동을 설정할 수 있습니다:
 [1] Jira       — 이슈 관리
 [2] Confluence — 문서 관리
 [3] Figma      — 디자인 조회
 [4] MCP 서버   — DB 조회 등

 설치할 항목? (번호 쉼표, all: 전체, skip: 건너뛰기):"
```

선택 시 대화형으로 인증 정보를 수집하여 `~/.claude/credentials.md`에 저장한다.

## 팀별 추천 카탈로그 예시

4단계에서 팀 세팅 시 표시되는 추천 항목. 이미 세팅된 것은 ✓, 미세팅은 ✗로 표시.

### backend

```
 ✗ 컨벤션 — 코드 컨벤션 (프로젝트 분석 후 맞춤 생성)
 ✗ 컨텍스트 맵 — 에이전트용 프로젝트 지도
 ✗ Hook: api-compat — API 호환성 검사
 ✗ Hook: entity-review — 엔티티 변경 리뷰
 ✗ Hook: sql-review — SQL 검증
 ✗ Skill: api-design — API 설계 가이드
 ✗ Skill: entity — 엔티티 생성
 ✗ Skill: migration — DB 마이그레이션
 ✗ 아키텍처 레이어 검증
 ✗ 외부 서비스 연동 (Jira, Confluence 등)
```

### frontend

```
 ✗ 컨벤션 — 코드 컨벤션
 ✗ 컨텍스트 맵
 ✗ Hook: bundle-size — 번들 사이즈 체크
 ✗ Hook: lighthouse — Lighthouse 성능 검사
 ✗ Skill: component — 컴포넌트 생성
 ✗ Skill: performance — 성능 최적화
```

### planning

```
 ✗ 컨벤션 — 문서 작성 컨벤션
 ✗ Skill: prd — PRD 작성
 ✗ Skill: user-story — 유저스토리 작성
 ✗ Skill: estimate — 공수 추정
```

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
