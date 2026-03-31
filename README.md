# AI Harness — 팀별 AI 에이전트 셋업 시스템

> [English README](README.en.md)

플러그인을 설치하고 `/harness-init`을 실행하면, 팀에 맞는 AI 작업 환경을 자동으로 구성합니다.

- **backend** 프로젝트를 분석하여 팀에 맞는 보안 Hook, 코드 컨벤션, 스킬을 자동으로 구성합니다.
- **planning** 팀은 현재 runtime이 Codex인지 Claude Code인지 감지한 뒤 글로벌 planner bundle을 세팅합니다.

세팅이 끝나면 하네스는 빠지고, Claude Code / Codex 에이전트가 설치된 규칙과 스킬을 사용합니다.

## 아키텍처

### Three-Pillar Architecture

Guard(안전) + Guide(컨벤션) + Harness(AI 최적화) 3축으로 구성됩니다.

![Three-Pillar Architecture](docs/images/1-three-pillar.png)

| 축 | 역할 | 구성 요소 |
|----|------|----------|
| **Guard** | 보안 — 위험 명령 차단, 시크릿 유출 방지 | 6개 글로벌 Hook |
| **Guide** | 컨벤션 — 팀별 코드 스타일, 아키텍처 규칙 | CLAUDE.md, convention-*.md, context-map.md |
| **Harness** | AI 최적화 — 프로젝트 맞춤 에이전트/스킬/워크플로우 | Project-Aware Agents, Domain Skills, Presets |

### OMC 연동

oh-my-claudecode와 `harness-hook-bridge.js`로 Hook을 체이닝합니다. 양쪽 모두 통과해야 실행이 허용됩니다.

![OMC Integration](docs/images/6-omc-integration.png)

## 설계 철학

| 철학 | 설명 |
|------|------|
| **추천 + 선택** | 베스트 프랙티스를 추천하고, 팀이 선택한다 |
| **셋업 후 빠지기** | init 시 세팅해주고, 이후엔 Claude Code가 동작. 하네스는 개입하지 않는다 |
| **차단이 아닌 안내** | 위반 시 구체적 대안 코드를 제시한다 |
| **팀 자율성** | 각 팀이 자기 도메인, 컨벤션, 스킬을 자유롭게 구성한다 |
| **최소 강제** | 필수는 보안 Hook 4개뿐. 나머지는 모두 opt-in이다 |

## 유저 플로우

### 초기화 (`/harness-init`)

팀에 따라 다른 경로로 초기화됩니다.

![Init Flow](docs/images/4-init-flow.png)

| 경로 | 단계 |
|------|------|
| **Planning** | Runtime 감지 → Planner Bundle 설치 → AGENTS.md/CLAUDE.md 변환 → 26+ Skills 등록 |
| **Backend** | Global Hooks 등록 → 코드 분석 → Convention 생성 → Team Hooks → context-map → Agents → Workflow → 검증 |
| **Frontend** | Global Hooks 등록 → 프론트엔드 분석 → Convention 생성 → Team Hooks 등록 |

### 일상 사용

```
평소처럼 사용하는 에이전트에서 바로 작업하면 됩니다.

개발자: "지원자 목록 조회 API 만들어줘"
    ↓
Claude: convention-backend.md 참고하여 코드 생성
    → /api/v1/applicants (버저닝 적용)
    → CommonResponse<T> (공통 응답 포맷)
    ↓
[Claude Code Hook] 코드 작성 시 자동 검증
    → SELECT * 사용? → 차단 + "컬럼을 명시하세요" 안내
    → 시크릿 하드코딩? → 차단 + "환경 변수 사용하세요" 안내
    ↓
[감사 로그] 모든 액션 .ai-harness/logs/ 에 자동 기록
```

```
기획자: "jira NMRS-15863 보여줘"
    ↓
planner bundle의 jira skill 사용
    ↓
"create-prd" / "user-stories" / "jira-checklist" 같은 글로벌 스킬로 후속 작업
```

### 관리 (필요할 때)

```
"QA팀 추가해줘"          → /harness-team
"왜 차단됐어?"           → /harness-rules
"하네스 상태 보여줘"     → /harness-status
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

개발 팀:

```
"하네스 초기화해줘"
또는
"이 프로젝트 분석해서 컨벤션 만들고 보안 설정해줘"
```

기획 팀:

```
"planning 팀으로 하네스 초기화해줘"
또는
"기획자 모드로 글로벌 planner bundle 설치해줘"
```

초기화 흐름:

1. **팀 선택** — planning / backend 등 팀 선택
2. **planning** — 현재 runtime 감지 후 `teams/planning/bundle/`을 글로벌 위치에 설치
   - 설치 전 `inspect`로 runtime, 대상 경로, 설치 개수를 먼저 보여줍니다.
   - 설치 중 텍스트 자산은 runtime에 맞게 자동 변환됩니다. 예: `AGENTS.md → CLAUDE.md`, `~/.codex → ~/.claude`
3. **backend** — 보안 Hook 확인 후 현재 프로젝트 분석 및 로컬 `.ai-harness/` 세팅
4. **완료 요약** — 설치된 자산 수, readiness, 다음 추천 명령 표시

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

7개 스킬로 하네스를 완전히 제어합니다. 모두 자연어로 호출 가능합니다.

| 스킬 | 사용 예시 | 기능 |
|------|----------|------|
| **harness-init** | "하네스 초기화해줘" | planning은 글로벌 planner bundle 설치, backend는 프로젝트 로컬 하네스 세팅 |
| **harness-status** | "하네스 상태 보여줘" | 설정 상태 + 차단 현황 + 진단 + 미결정 사항 |
| **harness-rules** | "적용된 규칙 보여줘" | 현재 보안 규칙 목록, 마지막 차단 사유 |
| **harness-team** | "backend 팀 추가해줘" | 로컬 프로젝트 팀 추가/제거, 컨벤션 수정 |
| **harness-exclude** | "이 프로젝트 제외해줘" | 글로벌 하네스 제외 프로젝트 관리 |
| **harness-metrics** | "메트릭 분석해줘" | 에이전트 작업 효율 메트릭 분석 + 개선 제안 |
| **harness-scaffold** | "CRUD 만들어줘" | 컨벤션 기반 코드 보일러플레이트 생성 |

## 팀 프로필

현재 **Backend 팀**과 **Planning 팀(beta)** 이 제공됩니다. 다른 팀은 고도화 후 순차 제공 예정입니다.

![Team Structure](docs/images/3-team-structure.png)

### 제공 중

| 팀 | 핵심 역할 | 컨벤션 | Hook | 스킬 |
|----|---------|--------|------|------|
| **BE** | API/DB 개발 | 패키지 구조, DTO 네이밍, REST 규칙 | sql-review, api-compat, entity-review, coverage-check | entity, migration, api-design, convention, agent-map |
| **Planning** | PRD, Jira, 유저 스토리, 체크리스트 | 글로벌 AGENTS/CLAUDE + planner bundle | 없음 | create-prd, user-stories, jira, jira-checklist 포함 26개 skill + 16개 agent |

### 준비 중 (향후 제공)

| 팀 | 핵심 역할 | 상태 |
|----|---------|------|
| FE | React/Vue 개발 | 준비 중 |
| QA | 테스트/검증 | 준비 중 |
| DevOps | 인프라/배포 | 준비 중 |
| 디자인 | 디자인 시스템 | 준비 중 |

개발 팀은 초기화 후 다음 파일을 받습니다:

- `.ai-harness/teams/{team}/skills/convention-{team}.md` — 팀별 코드 스타일
- `.ai-harness/teams/{team}/CLAUDE.md` — 팀별 최소 규칙 + 스킬 참조

planning 팀은 로컬 프로젝트 대신 `teams/planning/bundle/`을 설치 소스로 사용합니다:

- `teams/planning/skills/` 와 `teams/planning/CLAUDE.md` 는 아직 검토 중인 legacy planning 자산
- `teams/planning/bundle/common/` 은 실제 설치되는 planner bundle
- `teams/planning/bundle/runtimes/` 는 Codex/Claude별 파일명과 경로 매핑 규칙
- `teams/planning/README.md` 는 legacy와 bundle의 역할 분리를 설명하는 planner 전용 안내서

## Hook 시스템

### Hook 실행 흐름

PreToolUse/PostToolUse 트리거에 따라 Global Hook(필수)과 Team Hook(선택)이 실행됩니다.

![Hook System](docs/images/2-hook-system.png)

### 글로벌 Hook (모든 팀에 적용)

6개 글로벌 Hook이 자동으로 등록됩니다:

**block-dangerous.sh** — 위험 패턴 차단

- `rm -rf` (rm과 -r, -f 플래그 조합)
- `DROP TABLE/DATABASE/INDEX`
- `TRUNCATE TABLE`
- `git push --force` (`--force-with-lease`는 허용)
- `chmod 777`
- `sudo` 명령

차단 시 안내: "BLOCKED: [사유]. 대안: [권장 방법]"

**secret-scanner.sh** — 민감 정보 유출 방지

- API 키, 암호, 개인정보 감지
- 커밋 전 자동 마스킹
- 시크릿 문자열을 `.env` 등에 저장하도록 안내

**check-architecture.sh** — 아키텍처 경계 위반 검증

- 의존성 방향 위반 감지 (Types/Entity → Config → Repository → Service → Controller)
- 하위 레이어에서 상위 레이어 import 시 차단 + 대안 안내

![Layer Enforcement](docs/images/5-layer-enforcement.png)

**guardrails-check.sh** — 변경 범위 제한

- 한 번에 변경 가능한 파일 수 제한 (config.yaml의 `max_files_changed`)
- 실행 시간 제한 초과 감지
- 과도한 변경 시 차단 + 분할 작업 안내

**infra-change-review.sh** — 인프라 변경 안전 검증

- `terraform destroy`, `kubectl delete ns`, `aws` 삭제 명령 차단
- 인프라 파괴 명령 실행 전 확인 요구
- 안전한 대안 제시

**audit-logger.sh** — 모든 액션 감사 로깅

- 누가, 언제, 무엇을 했는지 JSONL 형식으로 기록
- `.ai-harness/logs/{YYYY-MM-DD}.jsonl`
- 민감 정보(API 키, 암호) 자동 마스킹

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

![File Structure](docs/images/7-file-structure.png)

```
ai-harness/
├── hooks/          # 6개 글로벌 보안 Hook (.sh)
├── skills/         # 7개 코어 관리 스킬 (harness-init, status, rules, team, exclude, metrics, scaffold)
├── teams/          # 6개 팀 (planning, backend, frontend, design, devops, qa)
│   ├── planning/bundle/   # Planner Bundle (16 agents + 26 skills)
│   ├── backend/           # Hooks 4, Skills 5, Conventions
│   └── frontend/          # Hooks 3, Skills 4, Conventions
├── scripts/        # 10개 헬퍼 유틸리티 (Node.js + Bash)
├── templates/      # 설정, 에이전트, 스킬, 워크플로우 템플릿
├── global/         # 8개 공통 스킬 (test-scenario, deploy-check, onboard 등)
├── custom-agents/  # 회사 커스텀 에이전트
├── omc-integration/# OMC 연동 (hook bridge + mode configs)
├── docs/           # 설계 문서 (28개 기획 + 8개 SDD)
├── .ai-harness/    # 런타임 상태 (init 후 생성)
├── CLAUDE.md       # 플러그인 컨텍스트 (자동 주입)
└── package.json
```

## 헬퍼 스크립트

스킬들이 내부적으로 호출하는 Node.js 유틸리티입니다. 사용자가 직접 호출할 일은 거의 없습니다.

| 스크립트 | 역할 |
|---------|------|
| `check-environment.mjs` | Node.js, Git, Claude Code 버전 확인 |
| `install-planner-bundle.mjs` | planner bundle을 현재 runtime(Codex/Claude)에 맞게 inspect/install/변환 |
| `register-hooks.mjs` | Hook을 `.claude/settings.json`에 등록/해제 |
| `copy-team-resources.mjs` | 팀별 Hook, 기본 스킬, 컨벤션 템플릿 복사 |
| `inject-claudemd.mjs` | CLAUDE.md에 `harness:start ~ harness:end` 구간 주입 |
| `test-hooks.mjs` | Hook을 `.test.yaml`에 정의된 케이스로 테스트 |
| `generate-agents.mjs` | 프로젝트 분석 기반 맞춤 에이전트 생성 (v2) |
| `validate-generated.mjs` | 생성된 자산 유효성 검증 |
| `validate-yaml.mjs` | YAML 스키마 유효성 검증 |
| `check-architecture-ci.sh` | CI용 아키텍처 경계 위반 검증 |

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
| 09 | [Init 플로우 상세](docs/09-init-flow.md) | 4단계 init 플로우 |
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
- **OS**: macOS, Linux (Windows는 WSL 필수)

> [English README](README.en.md)

## 라이선스

MIT

## 저자

cano721
