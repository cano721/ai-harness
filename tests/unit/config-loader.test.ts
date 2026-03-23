import { describe, it, expect } from 'vitest';
import { join } from 'path';
import { loadConfig, loadLockPolicy, configExists } from '../../src/engine/config-loader.js';

const FIXTURES = join(import.meta.dirname, '..', 'fixtures');

describe('config-loader', () => {
  it('YAML 파일을 로드하고 파싱한다', async () => {
    const config = await loadConfig(join(FIXTURES, 'sample-config.yaml'));
    expect(config.teams).toEqual(['backend', 'frontend']);
    expect(config.guardrails.max_cost_usd).toBe(10.0);
    expect(config.guardrails.max_files_changed).toBe(25);
  });

  it('없는 파일은 기본값을 반환한다', async () => {
    const config = await loadConfig('/nonexistent/path.yaml');
    expect(config.teams).toEqual([]);
    expect(config.guardrails.max_cost_usd).toBe(5.0);
  });

  it('누락된 필드에 기본값을 적용한다', async () => {
    const config = await loadConfig(join(FIXTURES, 'sample-config.yaml'));
    expect(config._schema_version).toBe(1);
  });

  it('lock-policy를 로드한다', async () => {
    const policy = await loadLockPolicy(join(FIXTURES, 'sample-lock-policy.yaml'));
    expect(policy.locked).toContain('hooks.block-dangerous');
    expect(policy.bounded['rules.test_coverage'].min).toBe(60);
  });

  it('configExists는 파일 존재 여부를 반환한다', () => {
    expect(configExists(join(FIXTURES, 'sample-config.yaml'))).toBe(true);
    expect(configExists('/nonexistent')).toBe(false);
  });
});
