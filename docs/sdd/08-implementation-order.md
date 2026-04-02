# SDD 08 - 구현 순서

## 빌드 가능한 단위로 순서 정의

### Step 1: 프로젝트 초기화
```
- package.json (name: @ai-harness/core)
- tsconfig.json
- vitest.config.ts
- .gitignore
- bin/ai-harness.js (stub)
```
**검증**: `pnpm install` + `pnpm exec tsc --noEmit` 성공

### Step 2: 타입 정의
```
- src/types/index.ts
  - HarnessConfig
  - LockPolicy
  - AuditLogEntry
  - HookTestDef
  - HookTestResult
```
**검증**: 타입 컴파일 성공

### Step 3: Hook 스크립트 3개 + 테스트 정의
```
- hooks/block-dangerous.sh + .test.yaml
- hooks/secret-scanner.sh + .test.yaml
- hooks/audit-logger.sh + .test.yaml
```
**검증**: 각 Hook을 수동으로 실행하여 동작 확인

### Step 4: 유틸리티
```
- src/utils/logger.ts
```
**검증**: 단위 테스트

### Step 5: config-loader + 테스트
```
- src/engine/config-loader.ts
- tests/unit/config-loader.test.ts
- tests/fixtures/sample-config.yaml
```
**검증**: `pnpm test -- config-loader` 통과

### Step 6: config-merger + 테스트
```
- src/engine/config-merger.ts
- tests/unit/config-merger.test.ts
```
**검증**: `pnpm test -- config-merger` 통과

### Step 7: lock-enforcer + 테스트
```
- src/engine/lock-enforcer.ts
- tests/unit/lock-enforcer.test.ts
- tests/fixtures/sample-lock-policy.yaml
```
**검증**: `pnpm test -- lock-enforcer` 통과

### Step 8: claudemd-injector + 테스트
```
- src/engine/claudemd-injector.ts
- tests/unit/claudemd-injector.test.ts
- tests/fixtures/sample-claude.md
```
**검증**: `pnpm test -- claudemd-injector` 통과

### Step 9: settings-manager + 테스트
```
- src/engine/settings-manager.ts
- tests/unit/settings-manager.test.ts
- tests/fixtures/sample-settings.json
```
**검증**: `pnpm test -- settings-manager` 통과

### Step 10: hook-tester + 테스트
```
- src/engine/hook-tester.ts
- tests/unit/hook-tester.test.ts
```
**검증**: `npm test -- hook-tester` 통과

### Step 11: CLI 명령어
```
- src/cli/index.ts (commander 설정)
- src/cli/init.ts
- src/cli/status.ts
- src/cli/doctor.ts
- src/cli/hook-test.ts
```
**검증**: `npm run build` + `./bin/ai-harness.js --help` 동작

### Step 12: 템플릿
```
- templates/global/CLAUDE.md
- templates/config.yaml
- templates/lock-policy.yaml
```

### Step 13: 통합 테스트
```
- tests/integration/init-flow.test.ts
  - 임시 디렉토리에서 ai-harness init 실행
  - config.yaml, CLAUDE.md, settings.json 생성 확인
  - Hook 등록 확인
  - doctor 통과 확인
```
**검증**: `npm test` 전체 통과

### Step 14: 빌드 & 패키징
```
- tsup으로 빌드
- bin/ai-harness.js가 빌드된 코드를 로드
- npm pack으로 패키지 확인
```
**최종 검증**: `npm run build && npm test` 모두 통과
