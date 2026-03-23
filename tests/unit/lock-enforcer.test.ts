import { describe, it, expect } from 'vitest';
import { join } from 'path';
import { validateSetting, validateConfig } from '../../src/engine/lock-enforcer.js';
import { loadLockPolicy } from '../../src/engine/config-loader.js';
import type { LockPolicy, HarnessConfig } from '../../src/types/index.js';

const FIXTURES = join(import.meta.dirname, '..', 'fixtures');

describe('lock-enforcer', () => {
  let policy: LockPolicy;

  beforeAll(async () => {
    policy = await loadLockPolicy(join(FIXTURES, 'sample-lock-policy.yaml'));
  });

  describe('validateSetting', () => {
    it('locked 설정 변경을 차단한다', () => {
      const result = validateSetting('hooks.block-dangerous', false, policy);
      expect(result.allowed).toBe(false);
      expect(result.level).toBe('locked');
    });

    it('bounded 범위 내 변경을 허용한다', () => {
      const result = validateSetting('rules.test_coverage', 70, policy);
      expect(result.allowed).toBe(true);
      expect(result.level).toBe('bounded');
    });

    it('bounded 최소값 미만을 차단한다', () => {
      const result = validateSetting('rules.test_coverage', 50, policy);
      expect(result.allowed).toBe(false);
      expect(result.reason).toContain('최소값');
    });

    it('bounded 최대값 초과를 차단한다', () => {
      const result = validateSetting('guardrails.max_cost_usd', 100, policy);
      expect(result.allowed).toBe(false);
      expect(result.reason).toContain('최대값');
    });

    it('free 설정 변경을 허용한다', () => {
      const result = validateSetting('hooks.lighthouse', false, policy);
      expect(result.allowed).toBe(true);
      expect(result.level).toBe('free');
    });

    it('정의되지 않은 설정은 free로 허용한다', () => {
      const result = validateSetting('some.unknown.key', 'value', policy);
      expect(result.allowed).toBe(true);
      expect(result.level).toBe('free');
    });
  });

  describe('validateConfig', () => {
    it('잠금 Hook 비활성화 시 위반을 감지한다', () => {
      const config = {
        _schema_version: 1,
        teams: [],
        guardrails: { max_files_changed: 20, max_cost_usd: 5.0, max_execution_minutes: 30 },
        hooks: { 'block-dangerous': { enabled: false } },
        rules: {},
      } as HarnessConfig;

      const violations = validateConfig(config, policy);
      expect(violations.length).toBeGreaterThan(0);
      expect(violations[0].key).toBe('hooks.block-dangerous');
    });

    it('bounded 범위 초과 시 위반을 감지한다', () => {
      const config = {
        _schema_version: 1,
        teams: [],
        guardrails: { max_files_changed: 100, max_cost_usd: 5.0, max_execution_minutes: 30 },
        hooks: {},
        rules: { test_coverage: 80 },
      } as HarnessConfig;

      const violations = validateConfig(config, policy);
      expect(violations.some(v => v.key === 'guardrails.max_files_changed')).toBe(true);
    });

    it('정상 설정은 위반 없음', () => {
      const config = {
        _schema_version: 1,
        teams: ['backend'],
        guardrails: { max_files_changed: 20, max_cost_usd: 5.0, max_execution_minutes: 30 },
        hooks: {},
        rules: { test_coverage: 80 },
      } as HarnessConfig;

      const violations = validateConfig(config, policy);
      expect(violations.length).toBe(0);
    });
  });
});
