# AI Harness - 설정 호환성 전략

## 문제 정의

두 개의 독립 패키지가 함께 동작한다:
- `@ai-harness/core` (프레임워크) — CLI, 엔진, Hook 런타임
- `@{company}/harness-config` (설정 패키지) — 규칙, Hook, 스킬

이 둘의 버전이 맞지 않으면 문제가 발생한다.

| 상황 | 증상 |
|------|------|
| core가 config보다 오래됨 | 새 설정 필드를 인식 못 함 |
| config가 core보다 오래됨 | core가 필수 필드를 요구하는데 config에 없음 |
| 메이저 버전 불일치 | 플러그인 인터페이스 자체가 바뀜 |

---

## 버전 호환성 매트릭스

### Semantic Versioning 규칙

```
@ai-harness/core:

  Major (1.x → 2.x):
    - 플러그인 인터페이스 변경
    - CLI 명령어 구조 변경
    - 설정 파일 스키마 근본적 변경
    → config 패키지도 메이저 업데이트 필요

  Minor (1.1 → 1.2):
    - 새 기능 추가 (기존 기능 유지)
    - 새 설정 필드 추가 (기본값 있음)
    - 새 Hook 타입 지원
    → config 패키지 변경 불필요 (하위호환)

  Patch (1.1.0 → 1.1.1):
    - 버그 수정
    - 성능 개선
    → config 패키지 영향 없음

@{company}/harness-config:

  Major: 잠금 정책 대폭 변경, 팀 구조 변경
  Minor: 새 팀/Hook/규칙 추가
  Patch: 규칙 오탈자 수정, Hook 버그 수정
```

### 호환성 매트릭스

```
              config v1.x    config v2.x    config v3.x
core v1.x     ✅ 호환        ❌ 비호환       ❌ 비호환
core v2.x     ⚠ 레거시 모드   ✅ 호환        ❌ 비호환
core v3.x     ❌ 비호환       ⚠ 레거시 모드   ✅ 호환

✅ 호환: 정상 동작
⚠ 레거시 모드: 동작하지만 새 기능 사용 불가, 경고 표시
❌ 비호환: 실행 거부, 업데이트 안내
```

---

## 호환성 검증

### 플러그인 인터페이스 버전

```typescript
// src/plugins/plugin-interface.ts (정본 정의)

export interface HarnessConfigPlugin {
  /** 패키지 이름 */
  name: string;

  /** 버전 */
  version: string;

  /** 이 config가 요구하는 최소 core 버전 */
  minCoreVersion: string;        // 예: ">=1.2.0"

  /** 플러그인 인터페이스 버전 (메이저 호환용) */
  interfaceVersion: number;      // 예: 1 (core v1.x와 호환)

  /** 회사 공통 규칙 디렉토리 */
  globalDir: string;

  /** 팀 프로필 디렉토리 */
  teamsDir: string;

  /** 잠금 정책 파일 경로 (패키지 루트 기준) */
  lockPolicyPath: string;

  /** 사용 가능한 팀 목록 */
  availableTeams: string[];

  /** 프리셋 정의 */
  presets: Record<string, string[]>;

  /** 커스텀 에이전트 디렉토리 (선택) */
  customAgentsDir?: string;

  /** 커스텀 스킬 디렉토리 (선택) */
  customSkillsDir?: string;

  /** MCP 서버 디렉토리 (선택) */
  mcpDir?: string;
}
```

> 이 정의가 HarnessConfigPlugin의 정본이다. 08-distribution.md와 13-plugin-guide.md는 이 정의를 참조한다.

### 런타임 호환성 체크

```typescript
// src/engine/compatibility-checker.ts

function checkCompatibility(core: CoreInfo, config: ConfigPlugin): CompatResult {
  // 1. 인터페이스 버전 체크 (메이저 호환)
  if (config.interfaceVersion !== core.interfaceVersion) {
    return {
      status: 'incompatible',
      message: `config 인터페이스 v${config.interfaceVersion}은 core v${core.version}과 호환되지 않습니다.`,
      action: 'core 또는 config를 업데이트하세요.'
    };
  }

  // 2. 최소 버전 체크
  if (!semver.satisfies(core.version, config.minCoreVersion)) {
    return {
      status: 'incompatible',
      message: `config가 core ${config.minCoreVersion}을 요구하지만, 현재 core는 ${core.version}입니다.`,
      action: `npm update -g @ai-harness/core`
    };
  }

  // 3. 레거시 체크 (config가 오래된 경우)
  if (semver.major(core.version) > semver.major(config.version)) {
    return {
      status: 'legacy',
      message: `config v${config.version}은 레거시 모드로 동작합니다. 새 기능을 사용하려면 config를 업데이트하세요.`,
      action: 'ai-harness update'
    };
  }

  return { status: 'compatible' };
}
```

### 시작 시 체크

```
$ claude

  [하네스] ⚠ 호환성 경고
  core: v2.1.0 / config: v1.5.0
  상태: 레거시 모드 (동작하지만 v2 기능 사용 불가)
  조치: ai-harness update 로 config를 업데이트하세요.
```

---

## 설정 스키마 마이그레이션

### 스키마 버전 관리

```yaml
# .ai-harness/config.yaml

_schema_version: 2              # 설정 파일 스키마 버전
version: "1.3.0"                # config 패키지 버전
```

### 자동 마이그레이션

```typescript
// src/engine/schema-migrator.ts

const migrations: Record<number, MigrationFn> = {
  // v1 → v2: guardrails 구조 변경
  2: (config) => {
    if (config.max_cost_usd) {
      config.guardrails = config.guardrails || {};
      config.guardrails.max_cost_usd = config.max_cost_usd;
      delete config.max_cost_usd;
    }
    return config;
  },

  // v2 → v3: teams를 배열에서 객체로
  3: (config) => {
    if (Array.isArray(config.teams)) {
      const teamsObj: Record<string, TeamConfig> = {};
      for (const team of config.teams) {
        teamsObj[team] = { enabled: true };
      }
      config.teams = teamsObj;
    }
    return config;
  },
};

function migrateConfig(config: any, fromVersion: number, toVersion: number) {
  let current = config;
  for (let v = fromVersion + 1; v <= toVersion; v++) {
    if (migrations[v]) {
      current = migrations[v](current);
      current._schema_version = v;
    }
  }
  return current;
}
```

### 마이그레이션 실행

```
$ ai-harness update

  설정 스키마 마이그레이션이 필요합니다.
  현재: v1 → 대상: v2

  변경 사항:
  - guardrails.max_cost_usd로 이동 (기존 max_cost_usd)
  - 새 필드: guardrails.max_execution_minutes (기본값: 30)

  마이그레이션을 실행할까요? (Y/n): Y

  ✔ 스냅샷 생성 (롤백용)
  ✔ 스키마 v1 → v2 마이그레이션 완료
  ✔ 검증 통과
```

---

## 하위호환 규칙

### Core 개발 시 규칙

```
1. 새 설정 필드 추가 시 → 반드시 기본값 제공
2. 기존 필드 제거 시 → 1 minor 버전 동안 deprecated 경고
3. 필드 타입 변경 시 → 마이그레이션 스크립트 필수
4. CLI 명령어 제거 시 → 1 minor 버전 동안 alias 유지
5. Hook 인터페이스 변경 시 → major 버전에서만 허용
```

### Config 패키지 개발 시 규칙

```
1. minCoreVersion을 정확히 명시
2. 새 기능 사용 시 → 해당 기능이 있는 core 버전 확인
3. 잠금 정책 변경 시 → RFC 프로세스 필수
4. 호환성 테스트 실행 후 배포
```

---

## 호환성 테스트

```yaml
# .github/workflows/compat-test.yml (config 패키지)

name: Compatibility Test
on: [push, pull_request]
jobs:
  test-matrix:
    strategy:
      matrix:
        core-version: ["1.0.0", "1.1.0", "1.2.0", "latest"]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm install -g @ai-harness/core@${{ matrix.core-version }}
      - run: ai-harness validate-config ./
      - run: ai-harness hook test --all
```

```bash
# 로컬에서 호환성 테스트
$ ai-harness compat-test
  core v1.0.0: ✅ 호환
  core v1.1.0: ✅ 호환
  core v1.2.0: ✅ 호환
  core v2.0.0: ❌ 비호환 (interfaceVersion 불일치)
```
