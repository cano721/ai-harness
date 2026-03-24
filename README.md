# AI Harness — Claude Code 플러그인

AI 에이전트(Claude Code, Codex, Cursor 등)를 안전하게 제어하고 회사 규칙을 자동으로 적용하는 Claude Code 플러그인입니다. 별도 CLI 설치 없이 자연어 명령어로 프로젝트 분석, 팀별 컨벤션 생성, 보안 Hook 관리를 할 수 있습니다.

## 핵심 기능

**보안 Hook** — 위험한 명령(rm -rf, DROP TABLE, force push) 자동 차단, 민감 정보 유출 방지, 모든 액션 감사 로깅

**팀별 컨벤션** — Claude가 프로젝트 코드를 분석하여 팀별(기획/디자인/FE/BE/QA/DevOps) 코드 스타일 자동 생성

**상태 진단** — 설정 상태, 차단 현황, 문제 자동 감지

**팀 관리** — 팀 추가/제거, 컨벤션 수정, Hook 관리를 자연어로 수행

## 유저 플로우

### 최초 셋업 (1회)

```
1. 플러그인 설치
   claude plugin install ai-harness
       ↓
2. 글로벌 초기화 (모든 프로젝트에 보안 적용)
   "하네스 글로벌 초기화해줘"
       ↓
   → ~/.ai-harness/ 생성
   → ~/.claude/settings.json에 보안 Hook 등록
   → 이후 어떤 프로젝트에서든 rm -rf, 시크릿 등 자동 차단
```

### 프로젝트별 셋업

```
1. 프로젝트 디렉토리에서
   "이 프로젝트에 하네스 초기화해줘"
       ↓
2. Claude가 프로젝트 자동 분석
   "Spring Boot 3.x + React 18 프로젝트입니다.
    BE: com.company.ats 패키지, /api/v1 버저닝, Flyway 사용
    FE: src/components 구조, Zustand + React Query
    backend, frontend 팀을 적용할까요?"
       ↓
3. 확인
   "응"
       ↓
4. 자동 완료
   → .ai-harness/ 생성 (config, hooks, teams)
   → convention-backend.md, convention-frontend.md 자동 작성
   → 팀별 Hook 등록 (sql-review, bundle-size 등)
   → CLAUDE.md에 보안 규칙 주입
```

### 일상 사용 (개발자)

```
평소처럼 Claude Code를 사용하면 됩니다.
하네스는 백그라운드에서 투명하게 동작합니다.

개발자: "지원자 목록 조회 API 만들어줘"
    ↓
Claude: convention-backend.md 참고하여 코드 생성
    → /api/v1/applicants (버저닝 적용)
    → CommonResponse<T> (공통 응답 포맷)
    → CreateApplicantRequest (DTO 네이밍)
    ↓
[Hook] 코드 작성 시 자동 검증
    → SELECT * 사용? → 차단 + "컬럼을 명시하세요" 안내
    → 시크릿 하드코딩? → 차단 + "환경 변수 사용하세요" 안내
    → 정상 코드? → 통과 (지연 ~200ms, 체감 없음)
    ↓
[감사 로그] 모든 액션 .ai-harness/logs/ 에 자동 기록
```

### 관리 (필요할 때)

```
"QA팀 추가해줘"          → /harness-team → Hook + 컨벤션 자동 설정
"BE 컨벤션에 캐시 규칙 추가해줘" → convention-backend.md 자동 수정
"왜 차단됐어?"           → /harness-rules → 마지막 차단 사유 + 대안
"하네스 상태 보여줘"     → /harness-status → 설정 + 차단 현황 + 진단
```

### 전체 흐름 요약

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  플러그인 설치 │ →   │  글로벌 초기화  │ →   │ 프로젝트 초기화│
│  (1회)       │     │  (1회)        │     │ (프로젝트당 1회)│
└─────────────┘     └──────────────┘     └──────┬──────┘
                                                 ↓
                    ┌────────────────────────────────────────┐
                    │           일상 사용 (매일)              │
                    │                                        │
                    │  개발자 요청 → [Pre Hook 검증] → 실행   │
                    │                → [Post Hook 로깅]       │
                    │                                        │
                    │  컨벤션 참고 → 일관된 코드 생성          │
                    │  위험 차단 → 안전한 환경                 │
                    │  감사 로깅 → 추적 가능                   │
                    └────────────────────────────────────────┘
                                                 ↓
                    ┌────────────────────────────────────────┐
                    │         관리 (필요할 때)                 │
                    │  팀 추가/제거, 컨벤션 수정, 제외 관리        │
                    └────────────────────────────────────────┘
```

## 빠른 시작

### 설치

```bash
# 마켓플레이스 등록
claude plugin marketplace add https://github.com/cano721/ai-harness.git

# 플러그인 설치
claude plugin install ai-harness
```

### 초기화

프로젝트에 Claude를 처음 설정할 때:

```
"하네스 초기화해줘"
또는
"이 프로젝트 분석해서 컨벤션 만들고 보안 설정해줘"
```

Claude가 다음을 자동으로 수행합니다:

1. 글로벌/로컬 범위 선택
2. 프로젝트 코드 분석 (패키지 구조, API 패턴, DTO 네이밍 등)
3. 프로젝트 도메인 정보 수집 (엔티티, 용어 — 충돌 시 사용자와 논의)
4. 팀 추천 + 맞춤 컨벤션 생성 (패턴 충돌 시 사용자와 논의)
5. 보안 Hook 등록
6. 외부 서비스 스킬 설정 (Jira, Confluence, Figma, Datadog — 대화형 인증)
7. MCP 서버 설정 (MySQL, Figma — 대화형 연결 정보)
8. 완료 보고

### 상태 확인

```
"하네스 상태 보여줘"
```

현재 적용된 팀, Hook, 오늘의 이벤트 요약을 표시합니다.

### 문제 해결

왜 차단됐는지 알고 싶을 때:

```
"왜 차단됐어?"
```

## 스킬 목록

5개 스킬로 하네스를 완전히 제어합니다. 모두 자연어로 호출 가능합니다.

| 스킬 | 사용 예시 | 기능 |
|------|----------|------|
| **harness-init** | "하네스 초기화해줘" | 프로젝트 분석 → 팀 추천 → 컨벤션 생성 → Hook 등록 |
| **harness-status** | "하네스 상태 보여줘" | 설정 상태 + 차단 현황 + 진단 + 미결정 사항 |
| **harness-rules** | "적용된 규칙 보여줘" | 현재 보안 규칙 목록, 마지막 차단 사유 |
| **harness-team** | "QA팀 추가해줘" | 팀 추가/제거, 컨벤션 수정 |
| **harness-exclude** | "이 프로젝트 제외해줘" | 글로벌 하네스 제외 프로젝트 관리 |

## 팀 프로필

현재 **Backend 팀**이 제공됩니다. 다른 팀은 고도화 후 순차 제공 예정입니다.

### 제공 중

| 팀 | 핵심 역할 | 컨벤션 | Hook | 스킬 |
|----|---------|--------|------|------|
| **BE** | API/DB 개발 | 패키지 구조, DTO 네이밍, REST 규칙 | sql-review, api-compat | entity, migration, api-design, convention |

### 준비 중 (향후 제공)

| 팀 | 핵심 역할 | 상태 |
|----|---------|------|
| FE | React/Vue 개발 | 준비 중 |
| QA | 테스트/검증 | 준비 중 |
| DevOps | 인프라/배포 | 준비 중 |
| 기획 | PRD/유저 스토리 | 준비 중 |
| 디자인 | 디자인 시스템 | 준비 중 |

각 팀은 초기화 후 다음 파일을 받습니다:

- `.ai-harness/teams/{team}/skills/convention-{team}.md` — 팀별 코드 스타일
- `.ai-harness/teams/{team}/CLAUDE.md` — 팀별 최소 규칙 + 스킬 참조

## Hook 시스템

### 글로벌 Hook (모든 팀에 적용)

3개 필수 Hook이 자동으로 등록됩니다:

**block-dangerous.sh** — 위험 패턴 차단

- `rm -rf` (rm과 -r, -f 플래그 조합)
- `DROP TABLE/DATABASE/INDEX`
- `TRUNCATE TABLE`
- `git push --force`
- `chmod 777`
- `sudo` 명령

차단 시 안내: "BLOCKED: [사유]. 대안: [권장 방법]"

**audit-logger.sh** — 모든 액션 감사 로깅

- 누가, 언제, 무엇을 했는지 JSONL 형식으로 기록
- `.ai-harness/logs/{YYYY-MM-DD}.jsonl`
- 민감 정보(API 키, 암호) 자동 마스킹

**secret-scanner.sh** — 민감 정보 유출 방지

- API 키, 암호, 개인정보 감지
- 커밋 전 자동 마스킹
- 시크릿 문자열을 `.env` 등에 저장하도록 안내

### 팀별 Hook

팀 추가 시 팀별 Hook도 함께 등록됩니다. 예를 들어 FE팀은:

- `bundle-size.sh` — 번들 사이즈 증가 감지
- `lighthouse.sh` — 성능 메트릭 수집

차단된 경우:

```
"왜 차단됐어?"
```

최근 차단 사유를 확인하세요.

## Hook 예시 시나리오

### 시나리오 1: rm -rf 시도

```
Claude: "모든 로그 파일을 삭제합니다"
bash: rm -rf logs/

Hook 응답:
BLOCKED: rm -rf 명령은 하네스 보안 정책에 의해 차단됩니다.
대안: 개별 파일 삭제 또는 rimraf 사용
```

### 시나리오 2: 민감 정보 감지

```
Claude: "DB 연결 정보를 .env에 저장합니다"
PLAINTEXT: DATABASE_URL="postgres://user:password@host"

Hook 응답:
BLOCKED: 평문 암호가 감지되었습니다.
대안: 환경 변수로 로드하거나 secrets.json 사용
마스킹됨: DATABASE_URL="postgres://user:***@host"
```

### 시나리오 3: 팀별 Hook

```
Claude: "React 컴포넌트를 작성합니다"
번들 크기: 450KB → 480KB (+30KB)

Hook 응답:
경고: 번들 크기가 30KB 증가했습니다 (한도: 100KB).
분석: 새 라이브러리 @emotion/core (25KB)
권장: 동적 임포트 고려
```

## 프로젝트 구조

```
ai-harness/
├── skills/                     # 5개 스킬 디렉토리
│   ├── harness-init/
│   ├── harness-status/
│   ├── harness-rules/
│   ├── harness-team/
│   └── harness-exclude/
│
├── scripts/                    # 헬퍼 스크립트 (스킬이 내부적으로 호출)
│   ├── check-environment.mjs   # Node.js, Git, Claude Code 버전 확인
│   ├── register-hooks.mjs      # Hook 등록/해제
│   ├── copy-team-resources.mjs # 팀별 Hook/스킬 복사
│   ├── inject-claudemd.mjs     # CLAUDE.md에 하네스 규칙 주입
│   ├── test-hooks.mjs          # Hook 단위 테스트
│
├── hooks/                      # 글로벌 Hook 스크립트
│   ├── block-dangerous.sh      # 위험 명령 차단
│   ├── audit-logger.sh         # 감사 로깅
│   ├── secret-scanner.sh       # 민감 정보 유출 방지
│   └── *.test.yaml             # Hook 단위 테스트
│
├── teams/                      # 6개 팀 (기획/디자인/FE/BE/QA/DevOps)
│   ├── planning/
│   │   ├── skills/             # 팀별 스킬
│   │   └── hooks/              # 팀별 Hook
│   ├── design/
│   ├── frontend/
│   ├── backend/
│   ├── qa/
│   └── devops/
│
├── templates/                  # 설정/정책 템플릿
│   ├── lock-policy.yaml        # 규칙 잠금 정책
│   └── global/
│       ├── CLAUDE.md           # 글로벌 CLAUDE.md 템플릿
│       └── skills/convention.md # 기본 컨벤션 템플릿
│
├── global/                     # 글로벌 스킬
│   └── skills/                 # 공통 스킬
│       ├── handoff.md          # 인수인계 스킬
│       └── onboard.md          # 온보딩 스킬
│
├── docs/                       # 설계 문서 (28개 기획 + 8개 SDD)
│   ├── 00-index.md             # 문서 목차
│   ├── 01-overview.md          # 정의/목표
│   ├── 02-architecture.md      # 5대 구성요소, 계층 상속
│   ├── ... (26개 추가 문서)
│   └── sdd/                    # 상세 설계 문서 (8개)
│       ├── 01-system-overview.md
│       └── ... (7개 추가)
│
├── custom-agents/              # 회사 커스텀 에이전트
│   ├── company-reviewer.md
│   └── company-architect.md
│
├── omc-integration/            # OMC(oh-my-claudecode) 연동
│   └── ...
│
├── CLAUDE.md                   # 플러그인 컨텍스트 (자동 주입)
└── package.json
```

## 헬퍼 스크립트

스킬들이 내부적으로 호출하는 Node.js 유틸리티입니다. 사용자가 직접 호출할 일은 거의 없습니다.

| 스크립트 | 역할 |
|---------|------|
| `check-environment.mjs` | Node.js, Git, Claude Code 버전 확인 |
| `register-hooks.mjs` | Hook을 `.claude/settings.json`에 등록/해제 |
| `copy-team-resources.mjs` | 팀별 Hook, 기본 스킬, 컨벤션 템플릿 복사 |
| `inject-claudemd.mjs` | CLAUDE.md에 `# harness:start ~ harness:end` 구간 주입 |
| `test-hooks.mjs` | Hook을 `.test.yaml`에 정의된 케이스로 테스트 |

## 설계 문서

프로젝트의 완전한 설계는 `docs/` 폴더의 28개 기획 문서와 8개 상세 설계 문서(SDD)에 상세히 기술되어 있습니다.

### 기획 문서 (v1~v2)

| # | 문서 | 내용 |
|---|------|------|
| 01 | [개요](docs/01-overview.md) | 정의, 목표, 기존 도구와의 관계 |
| 02 | [아키텍처](docs/02-architecture.md) | 5대 구성요소, 계층 상속 모델 |
| 03 | [디렉토리 구조](docs/03-directory-structure.md) | 파일/폴더 구조 상세 |
| 04 | [OMC/OMX 연동](docs/04-omc-integration.md) | Hook 체이닝, 모드별 설정 |
| 05 | [팀별 커스터마이징](docs/05-team-customization.md) | 6개 팀 설정 및 충돌 해소 |
| 06 | [로드맵](docs/06-roadmap.md) | Phase 1~3 단계별 작업 |
| 07 | [설정 관리 & 업데이트](docs/07-configuration.md) | 버전 업데이트, 잠금 정책 |
| 08 | [배포 & 패키지 구조](docs/08-distribution.md) | 하이브리드 배포, npm/GitHub 구성 |
| 09 | [Init 플로우 상세](docs/09-init-flow.md) | 6단계 설치 프로세스 |
| 10 | [감사 로깅 설계](docs/10-audit-logging.md) | 로그 포맷, 보존 정책 |
| 11 | [크로스팀 워크플로우](docs/11-cross-team-workflow.md) | 기획→디자인→개발→QA 파이프라인 |
| 12 | [비용 추적 모델](docs/12-cost-tracking.md) | 토큰 비용, 한도, 최적화 |
| 13 | [플러그인 개발 가이드](docs/13-plugin-guide.md) | 설정 패키지 작성, 배포 |
| 14 | [멀티 에이전트 추상화](docs/14-multi-agent-abstraction.md) | 어댑터 패턴, Tier별 전략 |
| 15 | [에러 핸들링 & 복원력](docs/15-error-handling.md) | Hook 실패/타임아웃 대응 |
| 16 | [하네스 테스트 전략](docs/16-testing-strategy.md) | Hook 단위 테스트, E2E 시나리오 |
| 17 | [롤백 & 복구](docs/17-rollback-recovery.md) | 업데이트 롤백, 설정 스냅샷 |
| 18 | [거버넌스 모델](docs/18-governance.md) | 규칙 변경 프로세스, RFC |
| 19 | [품질 & 채택 메트릭](docs/19-quality-metrics.md) | KPI, 대시보드 설계 |
| 20 | [마이그레이션 경로](docs/20-migration-path.md) | 점진적 전환, 호환성 보장 |
| 21 | [온보딩 & 개발자 경험](docs/21-onboarding-dx.md) | 신규 팀원 온보딩 |
| 22 | [모노레포 지원](docs/22-monorepo-support.md) | 모노레포 감지, 서비스별 팀 매핑 |
| 23 | [보안 모델 심화](docs/23-security-deep-dive.md) | 네트워크 제어, 샌드박싱 |
| 24 | [설정 호환성 전략](docs/24-config-compatibility.md) | 버전 매트릭스, 마이그레이션 스크립트 |
| 25 | [컴플라이언스 & 데이터 거버넌스](docs/25-compliance.md) | GDPR, 개인정보보호법, 마스킹 |
| 26 | [트러블슈팅 가이드](docs/26-troubleshooting.md) | 증상별 해결법, FAQ |
| 27 | [AI 모델 변화 대응](docs/27-ai-model-adaptation.md) | 모델 업그레이드, 프롬프트 드리프트 |
| 28 | [성능 벤치마크 & 최적화](docs/28-performance-benchmark.md) | Hook 프로파일링, 성능 예산 |

### 상세 설계 문서 (SDD)

| # | 문서 | 내용 |
|---|------|------|
| 01 | [System Overview](docs/sdd/01-system-overview.md) | 시스템 개요 |
| 02 | [Module Design](docs/sdd/02-module-design.md) | 모듈 설계 |
| 03 | [Data Design](docs/sdd/03-data-design.md) | 데이터 모델 |
| 04 | [Hook Engine](docs/sdd/04-hook-engine.md) | Hook 엔진 구현 |
| 05 | [CLI Spec](docs/sdd/05-cli-spec.md) | CLI 명령어 스펙 |
| 06 | [Tech Stack](docs/sdd/06-tech-stack.md) | 기술 스택 |
| 07 | [Directory Structure](docs/sdd/07-directory-structure.md) | 구조 상세 |
| 08 | [Implementation Order](docs/sdd/08-implementation-order.md) | Phase별 구현 순서 |

## 구현 현황

| 단계 | 내용 | 상태 |
|------|------|------|
| 설계 | 28개 기획 문서 + 8개 SDD, 3회 리뷰 완료 | ✅ |
| Phase 1 | 엔진 6개 + Hook 3개 + 템플릿 3개 (플러그인 전환으로 CLI 제거) | ✅ |
| Phase 2 | 팀별 CLAUDE.md 6개, Hook 6개, Skill 18개, OMC 연동 | ✅ |
| Phase 3 | 어댑터 3개, 메트릭, 워크플로우, 온보딩 | ✅ |
| 추가 구현 | 에러 핸들링, 트러블슈팅 | ✅ |
| 플러그인 전환 | CLI → Claude Code 플러그인 (스킬 5개 + 스크립트 5개) | ✅ |

## 향후 계획

### 문서/가이드 (필요 시 작성)

| 설계 문서 | 내용 | 필요 시점 |
|-----------|------|-----------|
| [13. 플러그인 가이드](docs/13-plugin-guide.md) | 커뮤니티 어댑터 개발 가이드 | 외부 개발자가 어댑터 만들 때 |
| [18. 거버넌스](docs/18-governance.md) | Champion 역할, 규칙 변경 프로세스 | 조직 전체 배포 시 |
| [20. 마이그레이션](docs/20-migration-path.md) | 버전 업그레이드 자동화 가이드 | v2 출시 시 |
| [25. 컴플라이언스](docs/25-compliance.md) | SOC2/ISO27001 매핑 | 보안 감사 시 |

### 향후 확장 (현재 불필요)

| 설계 문서 | 내용 | 필요 시점 |
|-----------|------|-----------|
| [22. 모노레포 지원](docs/22-monorepo-support.md) | 워크스페이스별 독립 config | 모노레포 프로젝트 적용 시 |
| [23. 보안 심화](docs/23-security-deep-dive.md) | RBAC, 감사 로그 암호화 | 대규모 조직 운영 시 |
| [24. 설정 호환성](docs/24-config-compatibility.md) | 스키마 버전 마이그레이션 | config v2 도입 시 |
| [27. AI 모델 적응](docs/27-ai-model-adaptation.md) | 모델별 프롬프트 최적화 | 운영 데이터 축적 후 |

## 요구사항

- **Node.js**: >= 18
- **Git**: 저장소 필수
- **Claude Code**: 플러그인으로 등록

## 라이선스

MIT

## 저자

cano721
