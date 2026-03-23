export interface HarnessConfig {
  _schema_version: number;
  config_package?: string;
  config_version?: string;
  teams: string[];
  guardrails: {
    max_files_changed: number;
    max_cost_usd: number;
    max_execution_minutes: number;
  };
  hooks: Record<string, HookOverride>;
  rules: Record<string, unknown>;
}

export interface HookOverride {
  enabled: boolean;
  reason?: string;
  [key: string]: unknown;
}

export interface LockPolicy {
  locked: string[];
  bounded: Record<string, BoundedRule>;
  free: string[];
}

export interface BoundedRule {
  min?: number;
  max?: number;
  default: number;
}

export interface AuditLogEntry {
  timestamp: string;
  session_id: string;
  event_type: 'tool_use' | 'hook_trigger' | 'error';
  tool?: string;
  action: string;
  result: 'success' | 'blocked' | 'warning' | 'error';
  reason?: string;
  hook?: string;
  user: string;
  project: string;
  team: string[];
  duration_ms?: number;
  metadata?: Record<string, unknown>;
}

export interface HookTestDef {
  name: string;
  tests: HookTestCase[];
}

export interface HookTestCase {
  name: string;
  tool: string;
  input: string;
  expect_exit: number;
  expect_output_contains?: string;
}

export interface HookTestResult {
  name: string;
  tool: string;
  input: string;
  expectedExit: number;
  actualExit: number;
  passed: boolean;
  output?: string;
}

export interface ValidationResult {
  key: string;
  allowed: boolean;
  reason?: string;
  level: 'locked' | 'bounded' | 'free';
}

export interface HookConfig {
  matcher: string;
  command: string;
  _managed_by?: string;
}

export const DEFAULT_CONFIG: HarnessConfig = {
  _schema_version: 1,
  teams: [],
  guardrails: {
    max_files_changed: 20,
    max_cost_usd: 5.0,
    max_execution_minutes: 30,
  },
  hooks: {},
  rules: {},
};

export const DEFAULT_LOCK_POLICY: LockPolicy = {
  locked: [
    'hooks.block-dangerous',
    'hooks.audit-logger',
    'hooks.secret-scanner',
  ],
  bounded: {
    'rules.test_coverage': { min: 60, max: 100, default: 80 },
    'guardrails.max_cost_usd': { max: 50.0, default: 5.0 },
    'guardrails.max_files_changed': { max: 50, default: 20 },
  },
  free: [
    'hooks.lighthouse',
    'hooks.bundle-size',
  ],
};
