# @ai-harness/core

AI 에이전트(Claude Code, Codex 등)를 안전하게 통제하고 효율을 높이는 회사 전용 제어/검증 프레임워크입니다. 에이전트가 자율적으로 업무를 수행할 때 회사 규칙을 자동으로 적용하고, 위험 행동을 차단하며, 모든 액션을 감시합니다.

## 주요 기능

- **보안 Hook** — 위험 명령(rm -rf, DROP, force push) 자동 차단, 민감 정보 유출 방지
- **팀별 규칙** — 기획/디자인/FE/BE/QA/DevOps 6개 팀별 독립 규칙 및 워크플로우 관리
- **비용 추적** — 토큰 비용 실시간 추적, 한도 설정, 최적화 제안
- **워크플로우 자동화** — 승인 게이트, 크로스팀 핸드오프, 표준 프로세스 자동 적용
- **멀티 에이전트 지원** — Claude Code(Tier 1 Full), Codex CLI(Tier 2), Cursor(Tier 3) 동시 지원

## 빠른 시작

### 설치 및 초기화

```bash
npm install @ai-harness/core

# 프로젝트에 하네스 적용
ai-harness init

# 대화형 설정
# 팀 선택 → Hook 등록 → CLAUDE.md 규칙 주입
```

### 설정 확인

```bash
# 현재 상태 확인
ai-harness status

# 환경 검증
ai-harness doctor

# 규칙 확인
ai-harness rules show --team backend
```

## CLI 명령어

| 명령어 | 설명 |
|--------|------|
| `ai-harness init` | 프로젝트에 하네스 설치, 팀 선택, Hook 등록 |
| `ai-harness status` | 현재 팀, Hook, 오늘 로그 요약 표시 |
| `ai-harness doctor` | 환경/하네스/Hook/CLAUDE.md 검증 |
| `ai-harness hook-test [name]` | Hook 단위 테스트 실행 |
| `ai-harness why [hook-name]` | Hook이 어떤 위험을 차단하는지 설명 |
| `ai-harness rules show --team <team>` | 팀별 규칙 표시 |
| `ai-harness cost report --team <team>` | 팀별 비용 리포트 |
| `ai-harness metrics` | 생산성/품질/채택률 메트릭 |
| `ai-harness rollback` | 마지막 하네스 설정으로 롤백 |
| `ai-harness diagnose` | 문제 자동 진단 및 해결 제안 |
| `ai-harness benchmark` | Hook 성능 벤치마크 |

## 팀별 프로필

하네스는 6개 팀을 기본 지원합니다. 각 팀은 고유한 규칙, Hook, Skill, 워크플로우를 갖습니다.

| 팀 | 핵심 역할 | Hook | Skill |
|----|---------|----|-------|
| **기획** | PRD/유저 스토리 작성 | PRD 검증 | `/prd`, `/user-story`, `/estimate` |
| **디자인** | 디자인 시스템 구현 | 토큰 준수 체크 | `/figma-to-code`, `/a11y`, `/responsive` |
| **FE** | React/Next.js 개발 | 번들 사이즈, Lighthouse | `/component`, `/storybook`, `/e2e` |
| **BE** | API/DB 개발 | SQL 리뷰, API 호환 | `/entity`, `/migration`, `/api-design` |
| **QA** | 테스트 및 검증 | 커버리지 체크 | `/test-scenario`, `/regression`, `/smoke-test` |
| **DevOps** | 인프라 및 배포 | IaC 검증 | `/deploy-check`, `/infra-plan`, `/rollback-plan` |

## Hook 시스템

### Global Hook (모든 팀 적용)

```bash
# 3개 필수 Hook이 자동 등록됨

block-dangerous.sh      # 위험 명령 차단
  - rm -rf, DROP TABLE, git push --force 등

audit-logger.sh         # 모든 액션 로깅
  - 누가, 언제, 무엇을 했는지 JSONL 형식으로 기록

secret-scanner.sh       # 민감 정보 유출 방지
  - API 키, 암호, 개인정보 자동 감지 및 마스킹
```

### Team Hook (팀별 추가)

각 팀은 자신의 도메인에 맞는 Hook을 추가로 등록할 수 있습니다.

```bash
# FE팀 Hook 예시
bundle-size.sh          # 번들 사이즈 증가 감지
lighthouse.sh           # 성능 메트릭 수집

# BE팀 Hook 예시
sql-review.sh           # SQL 쿼리 보안 검증
api-compat.sh           # API 호환성 체크
```

## 멀티 에이전트 지원

하네스는 여러 AI 에이전트를 계층적으로 지원합니다.

### Tier 1: Claude Code (Full Support)

모든 하네스 기능 네이티브 지원:
- 컨텍스트 주입 (CLAUDE.md)
- Hook 시스템 (PreToolUse/PostToolUse)
- MCP 서버 연동
- 감사 로깅
- 비용 추적

### Tier 2: Codex CLI (Context + Partial Hooks)

컨텍스트 완전 지원, Hook은 제한적:
- 컨텍스트: AGENTS.md로 자동 변환
- Hook: 지원 범위 내 매핑
- 감사: CLI 래퍼로 보완

### Tier 3: Cursor (Context Only)

컨텍스트 주입만 지원:
- .cursorrules 자동 생성
- Hook/감사 불가 (에이전트 특성상)

## 프로젝트 구조

```
ai-harness/
├── bin/                        # CLI 진입점
│   └── ai-harness.js
│
├── src/                        # TypeScript 소스
│   ├── cli/                    # 11개 CLI 명령어
│   │   ├── init.ts
│   │   ├── status.ts
│   │   ├── doctor.ts
│   │   ├── hook-test.ts
│   │   ├── why.ts
│   │   ├── rules.ts
│   │   ├── cost.ts
│   │   ├── metrics.ts
│   │   ├── rollback.ts
│   │   ├── diagnose.ts
│   │   └── benchmark.ts
│   ├── adapters/               # 에이전트별 어댑터
│   │   ├── agent-adapter.ts
│   │   ├── claude-adapter.ts
│   │   ├── codex-adapter.ts
│   │   └── cursor-adapter.ts
│   └── types/                  # TypeScript 타입 정의
│
├── hooks/                      # Global Hook 스크립트
│   ├── block-dangerous.sh
│   ├── audit-logger.sh
│   ├── secret-scanner.sh
│   └── *.test.yaml             # Hook 단위 테스트
│
├── global/                     # 회사 공통 규칙
│   ├── CLAUDE.md
│   └── guardrails/
│
├── teams/                      # 팀별 규칙 (6개 팀)
│   ├── planning/
│   ├── design/
│   ├── frontend/
│   ├── backend/
│   ├── qa/
│   └── devops/
│
├── docs/                       # 28개 설계 문서 + 8개 SDD
│   ├── 01-overview.md
│   ├── 02-architecture.md
│   ├── ... (26개 추가)
│   └── sdd/                    # System Design Document
│       ├── 01-system-overview.md
│       └── ... (7개 추가)
│
└── tests/                      # Vitest 테스트 (120개 테스트)
    └── *.test.ts
```

## 개발

### 빌드

```bash
npm run build

# dist/ 디렉토리에 컴파일된 JavaScript 생성
```

### 테스트

```bash
# 전체 테스트 실행 (Vitest)
npm test

# 감시 모드
npm run test:watch
```

### 타입 검증

```bash
npm run typecheck
```

## 설계 문서

프로젝트의 전체 설계는 `docs/` 폴더의 28개 기획 문서와 8개 상세 설계 문서(SDD)에 상세히 기술되어 있습니다.

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

- **설계 검토**: 28개 기획 문서 3회 리뷰 완료
- **상세 설계**: 8개 SDD 완료
- **Phase 1 구현**: 6개 엔진 + 3개 Global Hook + 35개 테스트 통과
- **테스트**: 120개 테스트 모두 통과

### 남은 작업

- CLI 명령어 완성 (기본 구조 완료)
- 팀별 Hook/Skill 확장
- 통합 테스트
- 빌드 및 배포

## 요구사항

- **Node.js**: >= 18
- **Git**: 저장소 필수
- **Claude Code**: 설치 권장 (Tier 1 Full Support)

## 라이선스

MIT

## 저자

Company AI Team
