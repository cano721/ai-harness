# SDD 02 - 모듈 설계

## 모듈 의존성 다이어그램

```
CLI Commands
  │
  ├── init ──────▶ config-loader ──▶ config-merger ──▶ lock-enforcer
  │                                                         │
  │                                        claudemd-injector ◀┘
  │                                        settings-manager
  │
  ├── status ───▶ config-loader
  │
  ├── doctor ───▶ config-loader ──▶ lock-enforcer
  │               settings-manager
  │               hook-tester
  │
  └── hook test ▶ hook-tester
```

## 모듈별 상세

### 1. config-loader
```typescript
// 책임: YAML 설정 파일을 읽어 타입 안전한 객체로 반환
// 입력: 파일 경로
// 출력: HarnessConfig 객체

interface ConfigLoader {
  load(configPath: string): Promise<HarnessConfig>;
  loadLockPolicy(policyPath: string): Promise<LockPolicy>;
  exists(configPath: string): boolean;
}
```

### 2. config-merger
```typescript
// 책임: global + team + project 설정을 우선순위대로 병합
// 규칙: project > team > global (하위가 상위 오버라이드)
// 배열은 합집합 병합 (forbidden_patterns 등)

interface ConfigMerger {
  merge(global: Partial<HarnessConfig>,
        team: Partial<HarnessConfig>[],
        project: Partial<HarnessConfig>): HarnessConfig;
}
```

### 3. lock-enforcer
```typescript
// 책임: 잠금 정책 위반 여부 검증
// locked → 변경 불가
// bounded → min/max 범위 내만 허용
// free → 자유 변경

interface LockEnforcer {
  validate(key: string, value: unknown, policy: LockPolicy): ValidationResult;
  validateConfig(config: HarnessConfig, policy: LockPolicy): ValidationResult[];
}

interface ValidationResult {
  key: string;
  allowed: boolean;
  reason?: string;         // 위반 시 사유
  level: 'locked' | 'bounded' | 'free';
}
```

### 4. claudemd-injector
```typescript
// 책임: CLAUDE.md에 <!-- harness:start --> ~ <!-- harness:end --> 구간 관리
// 기존 내용 보존, 하네스 구간만 업데이트

interface ClaudeMdInjector {
  inject(claudeMdPath: string, content: string): Promise<void>;
  remove(claudeMdPath: string): Promise<void>;
  hasHarnessSection(claudeMdPath: string): Promise<boolean>;
}
```

### 5. settings-manager
```typescript
// 책임: .claude/settings.json에 Hook 등록/제거
// _managed_by: "ai-harness" 마커로 하네스 항목 식별

interface SettingsManager {
  registerHooks(settingsPath: string, hooks: HookConfig[]): Promise<void>;
  unregisterHooks(settingsPath: string): Promise<void>;
  getRegisteredHooks(settingsPath: string): Promise<HookConfig[]>;
}
```

### 6. hook-tester
```typescript
// 책임: Hook 스크립트를 테스트 케이스에 대해 실행하고 결과 판정
// 입력: Hook 경로 + 테스트 정의 (YAML)
// 출력: 테스트 결과 (pass/fail per case)

interface HookTester {
  testHook(hookPath: string, testDefPath: string): Promise<HookTestResult[]>;
  testAll(hooksDir: string): Promise<HookTestSummary>;
}

interface HookTestResult {
  name: string;
  tool: string;
  input: string;
  expectedExit: number;
  actualExit: number;
  passed: boolean;
  output?: string;
}
```
