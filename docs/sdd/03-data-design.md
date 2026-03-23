# SDD 03 - 데이터 설계

## 1. config.yaml 스키마

```yaml
# .ai-harness/config.yaml
_schema_version: 1

# 설정 패키지 (선택)
config_package: "@company/harness-config"
config_version: "1.0.0"

# 팀 목록
teams:
  - backend
  - frontend

# Guardrails
guardrails:
  max_files_changed: 20
  max_cost_usd: 5.0
  max_execution_minutes: 30

# Hook 오버라이드
hooks:
  lighthouse:
    enabled: false
    reason: "SSR 프로젝트라 불필요"

# 규칙 오버라이드
rules:
  test_coverage: 80
```

### TypeScript 타입

```typescript
interface HarnessConfig {
  _schema_version: number;
  config_package?: string;
  config_version?: string;
  teams: string[];
  guardrails: {
    max_files_changed: number;
    max_cost_usd: number;
    max_execution_minutes: number;
  };
  hooks: Record<string, {
    enabled: boolean;
    reason?: string;
    [key: string]: unknown;
  }>;
  rules: Record<string, unknown>;
}
```

## 2. lock-policy.yaml 스키마

```yaml
locked:
  - "hooks.block-dangerous"
  - "hooks.audit-logger"
  - "hooks.secret-scanner"

bounded:
  test_coverage:
    min: 60
    max: 100
    default: 80
  "guardrails.max_cost_usd":
    max: 50.0
    default: 5.0
  "guardrails.max_files_changed":
    max: 50
    default: 20

free:
  - "hooks.lighthouse"
  - "hooks.bundle-size"
```

### TypeScript 타입

```typescript
interface LockPolicy {
  locked: string[];
  bounded: Record<string, {
    min?: number;
    max?: number;
    default: number;
  }>;
  free: string[];
}
```

## 3. 감사 로그 스키마 (JSONL)

```typescript
interface AuditLogEntry {
  timestamp: string;          // ISO 8601
  session_id: string;
  event_type: 'tool_use' | 'hook_trigger' | 'error';
  tool?: string;              // Bash, Write, Edit 등
  action: string;             // 수행한 액션 요약
  result: 'success' | 'blocked' | 'warning' | 'error';
  reason?: string;            // 차단/경고 사유
  hook?: string;              // 트리거된 Hook명
  user: string;
  project: string;
  team: string[];
  duration_ms?: number;
  metadata?: Record<string, unknown>;
}
```

## 4. Hook 테스트 정의 스키마 (YAML)

```yaml
name: "block-dangerous"
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
```

### TypeScript 타입

```typescript
interface HookTestDef {
  name: string;
  tests: {
    name: string;
    tool: string;
    input: string;
    expect_exit: number;
    expect_output_contains?: string;
  }[];
}
```

## 5. .claude/settings.json Hook 등록 형식

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "command": "/path/to/hooks/block-dangerous.sh \"$TOOL_NAME\" \"$TOOL_INPUT\"",
        "_managed_by": "ai-harness"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "command": "/path/to/hooks/audit-logger.sh \"$TOOL_NAME\" \"$TOOL_INPUT\"",
        "_managed_by": "ai-harness"
      }
    ]
  }
}
```
