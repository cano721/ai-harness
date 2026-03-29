# AI Harness — 팀별 AI 에이전트 셋업 시스템

플러그인을 설치하고 `/harness-init`을 실행하면, 프로젝트를 분석하여 팀에 맞는 보안 Hook, 코드 컨벤션, 스킬을 자동으로 구성합니다. 세팅이 끝나면 하네스는 빠지고, Claude Code가 알아서 동작합니다.

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

```
[1] 팀 선택 ──── "어떤 팀 설정을 사용할까요?"
                  기술 스택 감지 → 추천 → 사용자 선택
    ↓
[2] 글로벌 세팅 ── "보안 Hook을 모든 프로젝트에 적용합니다"
                    → 사용자 확인 후 ~/.claude/settings.json에 등록
    ↓
[3] 프로젝트 확인 ── "현재 프로젝트: my-service (Java/Spring)"
                      → "이 프로젝트에 세팅할까요?" 확인
    ↓
[4] 프로젝트 세팅 ── 이미 세팅된 것 / 안 된 것 표시
                      → 세팅할 항목 사용자 선택 후 진행
    ↓
[완료] 적용 요약
```

### 일상 사용

```
평소처럼 Claude Code를 사용하면 됩니다.
하네스는 세팅만 해주고 빠져있습니다. Claude Code가 동작합니다.

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

프로젝트에 Claude를 처음 설정할 때:

```
"하네스 초기화해줘"
또는
"이 프로젝트 분석해서 컨벤션 만들고 보안 설정해줘"
```

Claude가 4단계로 세팅합니다 (모든 단계에서 사용자 확인):

1. **팀 선택** — 기술 스택 감지 → 팀 추천 → 선택
2. **글로벌 세팅** — 보안 Hook 4개를 모든 프로젝트에 적용 (확인 후)
3. **프로젝트 확인** — 현재 프로젝트 분석 → 세팅 대상 확인
4. **프로젝트 세팅** — 미세팅 항목 선택 → 컨벤션/Hook/컨텍스트맵 등 적용

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
| **harness-init** | "하네스 초기화해줘" | 프로젝트 분석 → 팀 추천 → 컨벤션 생성 → Hook 등록 |
| **harness-status** | "하네스 상태 보여줘" | 설정 상태 + 차단 현황 + 진단 + 미결정 사항 |
| **harness-rules** | "적용된 규칙 보여줘" | 현재 보안 규칙 목록, 마지막 차단 사유 |
| **harness-team** | "QA팀 추가해줘" | 팀 추가/제거, 컨벤션 수정 |
| **harness-exclude** | "이 프로젝트 제외해줘" | 글로벌 하네스 제외 프로젝트 관리 |
| **harness-metrics** | "메트릭 분석해줘" | 에이전트 작업 효율 메트릭 분석 + 개선 제안 |
| **harness-scaffold** | "CRUD 만들어줘" | 컨벤션 기반 코드 보일러플레이트 생성 |

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

4개 필수 Hook이 자동으로 등록됩니다:

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

```
ai-harness/
├── skills/                     # 7개 스킬 디렉토리
│   ├── harness-init/
│   ├── harness-status/
│   ├── harness-rules/
│   ├── harness-team/
│   ├── harness-exclude/
│   ├── harness-metrics/
│   └── harness-scaffold/
│
├── scripts/                    # 헬퍼 스크립트 (스킬이 내부적으로 호출)
│   ├── check-environment.mjs   # Node.js, Git, Claude Code 버전 확인
│   ├── register-hooks.mjs      # Hook 등록/해제
│   ├── copy-team-resources.mjs # 팀별 Hook/스킬 복사
│   ├── inject-claudemd.mjs     # CLAUDE.md에 하네스 규칙 주입
│   ├── test-hooks.mjs          # Hook 단위 테스트
│   ├── check-architecture-ci.sh # CI용 아키텍처 검증
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
│   ├── config.yaml             # 프로젝트 설정 템플릿
│   ├── context-map.md          # 컨텍스트 맵 템플릿
│   ├── lock-policy.yaml        # 규칙 잠금 정책
│   ├── presets/                # 작업 프리셋 (CRUD, 버그수정, 리팩토링)
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

## 라이선스

MIT

## 저자

cano721
