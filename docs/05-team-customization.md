# AI Harness - 팀별 커스터마이징

## 팀별 설정 요약

| 팀 | CLAUDE.md 핵심 | 전용 Hook | 전용 Skill | 전용 MCP |
|----|---------------|-----------|-----------|----------|
| **기획** | PRD 포맷, 유저 스토리 규칙 | PRD 검증 | `/prd`, `/user-story`, `/estimate` | Confluence |
| **디자인** | 디자인 시스템, 토큰 규칙 | 토큰 준수 체크 | `/figma-to-code`, `/a11y`, `/responsive` | Figma |
| **FE** | 컴포넌트 규칙, 성능 기준 | 번들사이즈, Lighthouse | `/component`, `/storybook`, `/e2e` | Storybook |
| **BE** | API 규칙, DB 규칙 | SQL 리뷰, API 호환 | `/entity`, `/migration`, `/api-design` | DB, 모니터링 |
| **QA** | 테스트 전략, AC 검증 규칙 | 테스트 커버리지 체크 | `/test-scenario`, `/regression`, `/smoke-test` | 테스트 관리 도구 |
| **DevOps** | IaC 규칙, CI/CD 정책 | 인프라 변경 검증 | `/deploy-check`, `/infra-plan`, `/rollback-plan` | 모니터링, K8s |

---

## 기획팀

### CLAUDE.md 핵심

- PRD 작성: 배경/목적/범위/비범위 필수
- 유저 스토리: "As a [사용자], I want [기능], so that [가치]"
- 수용 기준: Given-When-Then 형식
- 기술 구현 방식을 지정하지 않음 (개발팀 자율)

### 전용 Skill

- `/prd` : Jira + Confluence 컨텍스트 기반 PRD 초안
- `/user-story` : 유저 스토리 + AC 생성
- `/estimate` : 프론트/백엔드/디자인/QA 분리 공수 산정

---

## 디자인팀

### CLAUDE.md 핵심

- 디자인 토큰 사용 필수 (하드코딩 값 금지)
- WCAG 2.1 AA 접근성 준수
- 모바일 퍼스트 반응형

### 전용 Skill

- `/figma-to-code` : Figma → 코드 컴포넌트 변환
- `/a11y` : 접근성 검증
- `/responsive` : 반응형 브레이크포인트 검증

---

## 프론트엔드팀

### CLAUDE.md 핵심

- 재사용 컴포넌트는 /components/common
- Props는 interface 타입 정의 필수
- LCP < 2.5s, FID < 100ms, CLS < 0.1
- 커버리지 80% 이상

### 전용 Hook/Skill

- Hook: `bundle-size.sh`, `lighthouse.sh`
- `/component`, `/storybook`, `/e2e`

---

## 백엔드팀

### CLAUDE.md 핵심

- RESTful + 버저닝 필수 (/api/v1/...)
- Request/Response DTO 분리
- DDL 변경은 마이그레이션 스크립트로
- SQL 파라미터 바인딩 필수

### 전용 Hook/Skill

- Hook: `sql-review.sh`, `api-compat.sh`
- `/entity`, `/migration`, `/api-design`

---

## QA팀

### CLAUDE.md 핵심

- 수용 기준(AC) 기반 테스트 시나리오 작성 필수
- Given-When-Then 형식의 테스트 케이스
- 회귀 테스트 범위는 변경 영향도에 비례
- 자동 테스트 우선, 수동 테스트는 탐색적 테스트에 한정

### 전용 Hook/Skill

- Hook: `coverage-check.sh` (커버리지 기준 미달 시 경고)
- `/test-scenario` : AC 기반 테스트 시나리오 자동 생성
- `/regression` : 변경 영향 범위 분석 및 회귀 테스트 목록 생성
- `/smoke-test` : 배포 후 스모크 테스트 체크리스트 생성

---

## DevOps팀

### CLAUDE.md 핵심

- Infrastructure as Code 원칙 (수동 변경 금지)
- Terraform/Helm 변경은 plan 먼저, apply는 승인 후
- 시크릿은 Vault/SecretsManager 사용 (하드코딩 금지)
- 모니터링 알림 설정 변경 시 oncall 팀 확인 필수

### 전용 Hook/Skill

- Hook: `infra-change-review.sh` (인프라 변경 시 plan 출력 검증)
- `/deploy-check` : 배포 전 체크리스트 (헬스체크, 롤백 계획, 모니터링)
- `/infra-plan` : Terraform plan 실행 및 변경 사항 요약
- `/rollback-plan` : 배포 롤백 계획 자동 생성

---

## 복수 팀 프로필 충돌 해소

`--team frontend,backend`처럼 복수 팀을 선택하면 규칙이 충돌할 수 있다.

### 충돌 해소 원칙

1. **스코프가 다르면** → 각각 적용 (대부분 이 경우. FE의 번들 사이즈와 BE의 SQL 리뷰는 서로 무관)
2. **스코프가 같으면** → 엄격한 쪽 적용 (예: FE `max_files: 20` vs BE `max_files: 10` → 10 적용)
3. **판단 불가하면** → 사용자에게 질문

```
예시:
  test_coverage: FE 80% vs BE 90% → 90% (엄격)
  max_cost_usd: FE $10 vs BE $5 → $5 (엄격)
  hooks: FE bundle-size + BE sql-review → 둘 다 실행 (스코프 다름)
```

---

## 팀 프로필 적용

### 기본: 복수 팀 동시 적용 (권장)

대부분의 경우 **여러 팀 규칙을 동시에 적용**하는 것이 자연스럽다. 굳이 전환할 필요 없이 모든 규칙이 함께 동작한다.

```bash
$ ai-harness init --team frontend,backend   # 복수 동시 적용
$ ai-harness init --preset fullstack        # FE + BE
$ ai-harness init --preset product          # 기획 + 디자인 + FE + BE
$ ai-harness init --preset all              # 전체 6팀
```

동시 적용 시: AI가 Java 파일을 수정하면 BE Hook 동작, React 파일을 수정하면 FE Hook 동작. 컨텍스트에 맞는 규칙이 자동 적용된다.

### 팀 전환 (선택, 우선순위 낮음)

규칙 충돌로 동시 적용이 불편한 드문 경우에만 사용한다.

```bash
$ ai-harness team switch frontend           # 전환
$ ai-harness team add devops                # 추가
```

---

## 팀별 CLAUDE.md에 넣을 내용

각 팀의 CLAUDE.md는 단순 코딩 규칙을 넘어 **도메인 지식, 아키텍처 결정, 컨벤션**을 포함한다. AI가 처음부터 팀에 맞는 코드를 생성하게 하는 핵심 레이어.

```markdown
# 예: BE팀 CLAUDE.md

## 도메인 지식
- ATS(Applicant Tracking System): 채용 지원자 관리 시스템
- 지원자 상태 흐름: 지원완료 → 서류심사 → 면접 → 합격/불합격
- 주요 엔티티: Applicant, JobPosting, Interview, Evaluation

## 코드 컨벤션
- 패키지: com.company.ats.{도메인}.{controller|service|repository}
- DTO 네이밍: {Action}{Entity}Request/Response (예: CreateApplicantRequest)
- 예외: BusinessException(code, message) 사용
- 로깅: @Slf4j + log.info/warn/error (System.out 금지)

## API 규칙
- 버저닝: /api/v1/...
- 응답 포맷: { "code": 0, "message": "success", "data": {} }
- 페이징: page, size, sort 파라미터 통일

## 아키텍처 결정
- MSA 구조: 서비스 간 통신은 REST + 이벤트 기반
- 공통 모듈(common-lib) 우선 활용
- 캐시: Redis 사용, TTL은 서비스별 판단
```

이렇게 도메인 정보를 넣으면 AI가 "ATS에서 지원자 목록 API 만들어줘"라고 했을 때 도메인 용어, 패키지 구조, 응답 포맷, 네이밍 규칙을 모두 반영한 코드를 바로 생성한다.
