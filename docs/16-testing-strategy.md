# AI Harness - 하네스 테스트 전략

## 문제 정의

하네스는 AI 에이전트의 모든 액션에 개입하는 **인프라 소프트웨어**다. 하네스 자체의 버그는:
- 개발자 전원의 작업을 차단할 수 있다 (Hook 오동작)
- 보안 정책이 우회될 수 있다 (차단 Hook이 통과시킴)
- 설정이 꼬여 복구 불능 상태가 될 수 있다

따라서 하네스 자체의 품질 보장을 위한 테스트 전략이 필수다.

---

## 테스트 피라미드

```
         ╱╲
        ╱  ╲
       ╱ E2E╲          시나리오 테스트 (실제 에이전트 연동)
      ╱──────╲          느리지만 신뢰도 높음
     ╱        ╲
    ╱통합 테스트╲        Hook 체이닝, 설정 병합, 어댑터 통합
   ╱────────────╲        중간 속도
  ╱              ╲
 ╱  단위 테스트    ╲     개별 Hook, 설정 파서, 변환기
╱──────────────────╲     빠르고 격리됨
```

---

## 1. 단위 테스트

### 대상

| 모듈 | 테스트 항목 | 주요 케이스 |
|------|-----------|------------|
| **config-loader** | YAML 파싱, 기본값 적용 | 유효/무효 YAML, 누락 필드, 타입 불일치 |
| **config-merger** | global + team + project 병합 | 오버라이드, 배열 병합, 깊은 중첩 |
| **lock-enforcer** | 잠금 정책 강제 | locked 변경 시도, bounded 범위 위반, free 변경 |
| **context-transformer** | 표준→에이전트별 변환 | Claude/Codex/Cursor 포맷, 특수문자 이스케이프 |
| **hook-runner** | Hook 실행, 종료코드 해석 | exit 0/1/2, 타임아웃, 비정상 출력 |
| **circuit-breaker** | 서킷 상태 전이 | 연속 실패→개방, 복구→반개방→폐쇄 |

### 예시: config-merger 테스트

```typescript
// tests/unit/config-merger.test.ts

describe('ConfigMerger', () => {
  describe('기본 병합', () => {
    it('team 설정이 global 설정을 오버라이드한다', () => {
      const global = { test_coverage: 80 };
      const team = { test_coverage: 90 };
      const result = merge(global, team);
      expect(result.test_coverage).toBe(90);
    });

    it('project 설정이 team 설정을 오버라이드한다', () => {
      const team = { max_files_changed: 20 };
      const project = { max_files_changed: 30 };
      const result = merge(team, project);
      expect(result.max_files_changed).toBe(30);
    });
  });

  describe('잠금 정책 적용', () => {
    it('locked 항목은 오버라이드할 수 없다', () => {
      const lockPolicy = { locked: ['hooks.audit-logger'] };
      const project = { hooks: { 'audit-logger': { enabled: false } } };
      expect(() => merge(global, project, lockPolicy)).toThrow(LockViolationError);
    });

    it('bounded 항목은 범위 내에서만 변경 가능하다', () => {
      const lockPolicy = {
        bounded: { test_coverage: { min: 60, max: 100 } }
      };
      const project = { test_coverage: 50 };  // 최소값 미만
      expect(() => merge(global, project, lockPolicy)).toThrow(BoundedViolationError);
    });

    it('bounded 범위 내 변경은 허용된다', () => {
      const lockPolicy = {
        bounded: { test_coverage: { min: 60, max: 100 } }
      };
      const project = { test_coverage: 70 };
      const result = merge(global, project, lockPolicy);
      expect(result.test_coverage).toBe(70);
    });
  });

  describe('배열 병합', () => {
    it('forbidden_patterns는 합집합으로 병합된다', () => {
      const global = { forbidden_patterns: ['console.log'] };
      const team = { forbidden_patterns: ['System.out.println'] };
      const result = merge(global, team);
      expect(result.forbidden_patterns).toEqual(['console.log', 'System.out.println']);
    });
  });
});
```

### 예시: lock-enforcer 테스트

```typescript
// tests/unit/lock-enforcer.test.ts

describe('LockEnforcer', () => {
  it('locked 설정 변경을 차단한다', () => {
    const enforcer = new LockEnforcer(lockPolicy);
    const result = enforcer.validate('hooks.block-dangerous.enabled', false);
    expect(result.allowed).toBe(false);
    expect(result.reason).toContain('잠금 설정');
  });

  it('bounded 설정 범위 초과를 차단한다', () => {
    const enforcer = new LockEnforcer(lockPolicy);
    const result = enforcer.validate('cost.per_session_usd', 999);
    expect(result.allowed).toBe(false);
    expect(result.reason).toContain('최대값');
  });

  it('free 설정 변경을 허용한다', () => {
    const enforcer = new LockEnforcer(lockPolicy);
    const result = enforcer.validate('hooks.lighthouse.enabled', false);
    expect(result.allowed).toBe(true);
  });
});
```

---

## 2. Hook 테스트

### Hook 단독 테스트 프레임워크

```bash
# CLI로 개별 Hook 테스트
$ ai-harness hook test block-dangerous

  ━━━ Hook 테스트: block-dangerous ━━━━━━━━━━━━━━

  [테스트 1] rm -rf / 명령 차단
    입력: Bash, "rm -rf /"
    기대: exit 2 (차단)
    결과: ✅ exit 2 — "BLOCKED: rm -rf 명령은..."

  [테스트 2] 정상 rm 명령 통과
    입력: Bash, "rm temp.txt"
    기대: exit 0 (통과)
    결과: ✅ exit 0

  [테스트 3] git push --force 차단
    입력: Bash, "git push --force origin main"
    기대: exit 2 (차단)
    결과: ✅ exit 2 — "BLOCKED: force push는..."

  [테스트 4] 정상 git push 통과
    입력: Bash, "git push origin feature/login"
    기대: exit 0 (통과)
    결과: ✅ exit 0

  [테스트 5] DROP TABLE 차단
    입력: Bash, "psql -c 'DROP TABLE users'"
    기대: exit 2 (차단)
    결과: ✅ exit 2

  ━━━ 결과: 5/5 통과 ✅ ━━━━━━━━━━━━━━━━━━━━━━━━
```

### Hook 테스트 정의 파일

```yaml
# global/hooks/block-dangerous.test.yaml

name: block-dangerous
tests:
  - name: "rm -rf 차단"
    tool: "Bash"
    input: "rm -rf /"
    expect_exit: 2
    expect_output_contains: "BLOCKED"

  - name: "정상 rm 통과"
    tool: "Bash"
    input: "rm temp.txt"
    expect_exit: 0

  - name: "git push --force 차단"
    tool: "Bash"
    input: "git push --force origin main"
    expect_exit: 2

  - name: "DROP TABLE 차단"
    tool: "Bash"
    input: "psql -c 'DROP TABLE users'"
    expect_exit: 2

  - name: "SELECT 통과"
    tool: "Bash"
    input: "psql -c 'SELECT * FROM users'"
    expect_exit: 0

  - name: "Edit 도구는 검사하지 않음"
    tool: "Edit"
    input: '{"file": "test.js", "content": "rm -rf"}'
    expect_exit: 0
```

### 전체 Hook 테스트

```bash
# 모든 Hook 일괄 테스트
$ ai-harness hook test --all

  block-dangerous:  5/5 ✅
  audit-logger:     3/3 ✅
  secret-scanner:   8/8 ✅
  bundle-size:      4/4 ✅
  sql-review:       6/6 ✅
  api-compat:       5/5 ✅

  전체: 31/31 통과 ✅
```

---

## 3. 통합 테스트

### Hook 체이닝 테스트

```typescript
// tests/integration/hook-chain.test.ts

describe('Hook Chain', () => {
  it('PreToolUse: harness/global → harness/team → OMC 순서로 실행', async () => {
    const executionOrder: string[] = [];

    // Mock hooks that record execution order
    mockHook('global/block-dangerous', () => executionOrder.push('global'));
    mockHook('team/sql-review', () => executionOrder.push('team'));
    mockHook('omc/state-manager', () => executionOrder.push('omc'));

    await runHookChain('PreToolUse', 'Bash', 'SELECT 1');

    expect(executionOrder).toEqual(['global', 'team', 'omc']);
  });

  it('앞 Hook이 차단하면 뒤 Hook은 실행되지 않는다', async () => {
    const executionOrder: string[] = [];

    mockHook('global/block-dangerous', () => {
      executionOrder.push('global');
      return { exit: 2, message: 'BLOCKED' };  // 차단
    });
    mockHook('team/sql-review', () => executionOrder.push('team'));

    const result = await runHookChain('PreToolUse', 'Bash', 'rm -rf /');

    expect(executionOrder).toEqual(['global']);  // team은 실행 안 됨
    expect(result.blocked).toBe(true);
  });

  it('Hook 실패 시 에러 정책에 따라 동작한다', async () => {
    mockHook('team/bundle-size', () => { throw new Error('crash'); });

    // free Hook → warn_and_pass
    const result = await runHookChain('PostToolUse', 'Write', '...');
    expect(result.warnings).toHaveLength(1);
    expect(result.blocked).toBe(false);
  });
});
```

### 설정 병합 통합 테스트

```typescript
// tests/integration/config-merge.test.ts

describe('Config Merge (전체 파이프라인)', () => {
  it('global + team + project 설정이 올바르게 병합된다', async () => {
    const config = await loadAndMerge({
      configPackage: './fixtures/test-config',
      teams: ['frontend', 'backend'],
      projectConfig: './fixtures/project-config.yaml',
      lockPolicy: './fixtures/lock-policy.yaml',
    });

    // Global 규칙 적용 확인
    expect(config.hooks['block-dangerous'].enabled).toBe(true);

    // Team 규칙 합산 확인
    expect(config.teams).toContain('frontend');
    expect(config.teams).toContain('backend');

    // Project 오버라이드 확인
    expect(config.guardrails.max_cost_usd).toBe(10.0);  // project override

    // 잠금 정책 유지 확인
    expect(config.hooks['audit-logger'].enabled).toBe(true);  // locked
  });
});
```

---

## 4. E2E 시나리오 테스트

### 실제 에이전트 연동 테스트

```typescript
// tests/e2e/claude-integration.test.ts

describe('Claude Code E2E', () => {
  beforeAll(async () => {
    // 테스트 프로젝트에 하네스 설치
    await exec('ai-harness init --preset fullstack --non-interactive');
  });

  it('위험 명령이 실제로 차단된다', async () => {
    // Claude Code를 --no-interactive로 실행하여
    // "rm -rf /" 명령을 시도하고 차단 확인
    const result = await exec('claude --no-interactive "run rm -rf /"');
    expect(result.output).toContain('BLOCKED');
  });

  it('감사 로그가 실제로 기록된다', async () => {
    await exec('claude --no-interactive "read package.json"');

    const today = new Date().toISOString().split('T')[0];
    const logFile = `.ai-harness/logs/${today}.jsonl`;
    const logs = readJsonl(logFile);

    expect(logs.some(l => l.tool === 'Read')).toBe(true);
  });

  it('CLAUDE.md에 하네스 규칙이 주입되어 있다', () => {
    const claudeMd = readFile('.claude/CLAUDE.md');
    expect(claudeMd).toContain('<!-- harness:start -->');
    expect(claudeMd).toContain('보안 필수 규칙');
    expect(claudeMd).toContain('<!-- harness:end -->');
  });

  afterAll(async () => {
    await exec('ai-harness uninstall --force');
  });
});
```

### 시나리오 매트릭스

| 시나리오 | 검증 항목 |
|---------|----------|
| **신규 init** | 설정 생성, Hook 등록, CLAUDE.md 주입, MCP 등록 |
| **기존 프로젝트에 init** | 기존 CLAUDE.md 보존, 병합, 비파괴적 설치 |
| **팀 전환** | Hook 교체, CLAUDE.md 업데이트, Skill 교체 |
| **업데이트** | 선택 적용, 잠금 항목 강제 적용, 로컬 커스텀 보존 |
| **uninstall** | 하네스 항목만 제거, 기존 설정 복원 |
| **바이패스** | 모든 Hook 비활성화, 감사 로그 기록, 자동 복구 |

---

## 5. CI 통합

### GitHub Actions 워크플로우

```yaml
# .github/workflows/test.yml

name: Harness Tests
on: [push, pull_request]

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm ci
      - run: npm run test:unit
      - run: npm run test:hooks    # Hook 테스트 파일 기반

  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm ci
      - run: npm run test:integration

  e2e:
    runs-on: ubuntu-latest
    needs: [unit, integration]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm install -g @anthropic-ai/claude-code  # 또는 mock
      - run: npm ci
      - run: npm run test:e2e

  hook-validation:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          # 모든 Hook 스크립트의 테스트 파일 존재 확인
          for hook in global/hooks/*.sh teams/*/hooks/*.sh; do
            test_file="${hook%.sh}.test.yaml"
            if [ ! -f "$test_file" ]; then
              echo "❌ 테스트 파일 없음: $test_file"
              exit 1
            fi
          done
      - run: npm run test:hooks
```

### 커버리지 기준

| 모듈 | 최소 커버리지 | 근거 |
|------|-------------|------|
| config-merger | 95% | 설정 병합 오류는 전사 영향 |
| lock-enforcer | 100% | 보안 정책 우회 방지 |
| hook-runner | 90% | Hook 실행 신뢰성 |
| context-transformer | 85% | 에이전트별 변환 정확성 |
| circuit-breaker | 95% | 장애 대응 정확성 |
| CLI 명령어 | 80% | 사용자 인터페이스 |

---

## 6. 설정 패키지(Config Plugin) 테스트

### validate-config 명령

```bash
# 설정 패키지 유효성 검증 (배포 전 필수)
$ ai-harness validate-config ./

  [구조] ✔
  [Hook 테스트] 31/31 ✔
  [잠금 정책 일관성] ✔
  [CLAUDE.md 구문] ✔
  [프리셋 유효성] ✔

  배포 준비 완료 ✅
```

### CI에서 자동 검증

```yaml
# harness-config 저장소의 CI
name: Validate Config
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm install -g @ai-harness/core
      - run: ai-harness validate-config ./
      - run: ai-harness hook test --all
```
