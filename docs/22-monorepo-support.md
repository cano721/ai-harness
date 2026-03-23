# AI Harness - 모노레포 지원

## 문제 정의

모노레포에서는 하나의 저장소에 여러 서비스가 있고, 각 서비스마다 다른 팀/규칙이 필요하다.

```
monorepo/
├── apps/
│   ├── web-client/        ← FE팀, React 규칙
│   ├── admin-portal/      ← FE팀, React 규칙 (+ 관리자 전용)
│   ├── api-server/        ← BE팀, Spring Boot 규칙
│   └── batch-worker/      ← BE팀, Spring Boot 규칙 (+ 배치 전용)
├── packages/
│   ├── shared-ui/         ← FE팀, 컴포넌트 라이브러리 규칙
│   └── shared-models/     ← 공통, 타입 정의
└── infra/
    └── terraform/         ← DevOps팀, IaC 규칙
```

---

## 설정 구조

### 루트 + 서비스별 설정

```
monorepo/
├── .ai-harness/
│   ├── config.yaml              # 루트 설정 (공통)
│   └── services/                # 서비스별 오버라이드
│       ├── web-client.yaml
│       ├── api-server.yaml
│       └── terraform.yaml
```

### 루트 설정

```yaml
# .ai-harness/config.yaml

type: "monorepo"

# 서비스 매핑
services:
  web-client:
    path: "apps/web-client"
    teams: ["frontend"]
    stack: "nextjs"

  admin-portal:
    path: "apps/admin-portal"
    teams: ["frontend"]
    stack: "nextjs"

  api-server:
    path: "apps/api-server"
    teams: ["backend"]
    stack: "spring-boot"

  batch-worker:
    path: "apps/batch-worker"
    teams: ["backend"]
    stack: "spring-boot"

  shared-ui:
    path: "packages/shared-ui"
    teams: ["frontend"]

  terraform:
    path: "infra/terraform"
    teams: ["devops"]

# 공통 설정 (모든 서비스에 적용)
common:
  guardrails:
    max_files_changed: 30        # 모노레포는 변경 파일이 많을 수 있음
```

### 서비스별 오버라이드

```yaml
# .ai-harness/services/api-server.yaml

guardrails:
  max_cost_usd: 15.0             # API 서버는 복잡해서 더 높게

hooks:
  db-migration-check:
    enabled: true                 # 이 서비스만 마이그레이션 체크

rules:
  extend:
    forbidden_patterns:
      - "System.exit"             # 이 서비스에서 추가 금지
```

---

## 자동 서비스 감지

```
개발자가 파일을 수정할 때:

Write: apps/api-server/src/main/java/...
    ↓
경로에서 서비스 매칭: api-server
    ↓
해당 서비스의 팀 프로필 적용: backend
    ↓
backend Hook 실행 (sql-review, api-compat)
```

### 경로 매칭 로직

```typescript
function detectService(filePath: string, config: MonorepoConfig): string | null {
  for (const [name, service] of Object.entries(config.services)) {
    if (filePath.startsWith(service.path)) {
      return name;
    }
  }
  return null;  // 루트 레벨 파일 → 공통 규칙만 적용
}
```

### 크로스 서비스 변경

```
하나의 작업에서 여러 서비스를 동시에 수정할 때:

Write: apps/web-client/src/api.ts         → frontend 규칙
Write: apps/api-server/src/UserController  → backend 규칙

→ 양쪽 규칙 모두 적용
→ 크로스 서비스 변경 경고:
  "이 작업은 web-client(FE)와 api-server(BE)를 동시에 수정합니다.
   API 계약 변경이 포함되어 있다면 양쪽 팀 리뷰를 권장합니다."
```

### 복수 팀 규칙 충돌 해소

동일 설정에 대해 여러 팀의 규칙이 충돌하면 **엄격한 쪽을 적용**한다.

```
예시: max_files_changed
  frontend: 20
  backend:  10
  → 적용값: 10 (엄격한 쪽)

예시: test_coverage
  frontend: 80%
  backend:  90%
  → 적용값: 90% (엄격한 쪽)
```

충돌 해소 원칙 (05-team-customization.md의 프로필 충돌 해소와 동일):
1. 스코프가 다르면 → 각각 적용
2. 스코프가 같으면 → 엄격한 쪽 적용
3. 판단 불가하면 → 사용자에게 질문

---

## CLAUDE.md 주입 전략

### 모노레포용 계층 구조

```
monorepo/
├── CLAUDE.md                    # 저장소 공통 (하네스가 관리)
├── apps/
│   ├── web-client/
│   │   └── CLAUDE.md            # FE 팀 규칙 (하네스가 주입)
│   └── api-server/
│       └── CLAUDE.md            # BE 팀 규칙 (하네스가 주입)
```

Claude Code는 자동으로 현재 작업 디렉토리의 CLAUDE.md + 상위 CLAUDE.md를 모두 로드하므로, 서비스 디렉토리에 들어가면 해당 팀 규칙이 자동 적용된다.

---

## Init 플로우 (모노레포)

```
$ ai-harness init

  ━━━ 프로젝트 타입 감지 ━━━━━━━━━━━━━━━━━━━━━━━

  모노레포 감지됨 (apps/ + packages/ 구조)

  서비스 자동 매핑:
  ┌──────────────────┬──────────┬──────────────┐
  │ 서비스            │ 경로      │ 추천 팀      │
  ├──────────────────┼──────────┼──────────────┤
  │ web-client       │ apps/... │ frontend     │
  │ api-server       │ apps/... │ backend      │
  │ shared-ui        │ pkg/...  │ frontend     │
  │ terraform        │ infra/.. │ devops       │
  └──────────────────┴──────────┴──────────────┘

  매핑이 맞나요? (Y/수정): _
```

---

## 모노레포 CLI 확장

```bash
# 서비스 목록
$ ai-harness service list
  web-client     apps/web-client      frontend
  api-server     apps/api-server      backend

# 서비스 추가
$ ai-harness service add mobile-app --path apps/mobile --team mobile

# 서비스별 상태
$ ai-harness status --service api-server

# 서비스별 메트릭
$ ai-harness metrics --service web-client
```
