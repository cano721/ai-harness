import { describe, it, expect } from 'vitest';
import { mergeConfigs } from '../../src/engine/config-merger.js';
import type { HarnessConfig } from '../../src/types/index.js';

describe('config-merger', () => {
  const global: Partial<HarnessConfig> = {
    _schema_version: 1,
    teams: [],
    guardrails: { max_files_changed: 20, max_cost_usd: 5.0, max_execution_minutes: 30 },
    hooks: {},
    rules: { test_coverage: 80 },
  };

  it('team 설정이 global을 오버라이드한다', () => {
    const team: Partial<HarnessConfig> = {
      guardrails: { max_files_changed: 15, max_cost_usd: 5.0, max_execution_minutes: 30 },
    };
    const result = mergeConfigs(global, [team], {});
    expect(result.guardrails.max_files_changed).toBe(15);
  });

  it('project 설정이 team을 오버라이드한다', () => {
    const team: Partial<HarnessConfig> = {
      rules: { test_coverage: 90 },
    };
    const project: Partial<HarnessConfig> = {
      rules: { test_coverage: 70 },
    };
    const result = mergeConfigs(global, [team], project);
    expect(result.rules.test_coverage).toBe(70);
  });

  it('teams 배열은 합집합으로 병합된다', () => {
    const team1: Partial<HarnessConfig> = { teams: ['frontend'] };
    const team2: Partial<HarnessConfig> = { teams: ['backend'] };
    const result = mergeConfigs(global, [team1, team2], {});
    expect(result.teams).toContain('frontend');
    expect(result.teams).toContain('backend');
    expect(result.teams.length).toBe(2);
  });

  it('중복 팀은 제거된다', () => {
    const team1: Partial<HarnessConfig> = { teams: ['frontend'] };
    const team2: Partial<HarnessConfig> = { teams: ['frontend', 'backend'] };
    const result = mergeConfigs(global, [team1, team2], {});
    expect(result.teams.length).toBe(2);
  });

  it('hooks는 병합된다', () => {
    const team: Partial<HarnessConfig> = {
      hooks: { 'sql-review': { enabled: true } },
    };
    const project: Partial<HarnessConfig> = {
      hooks: { lighthouse: { enabled: false, reason: 'SSR' } },
    };
    const result = mergeConfigs(global, [team], project);
    expect(result.hooks['sql-review'].enabled).toBe(true);
    expect(result.hooks.lighthouse.enabled).toBe(false);
  });

  it('빈 override는 기본값을 유지한다', () => {
    const result = mergeConfigs(global, [], {});
    expect(result.guardrails.max_cost_usd).toBe(5.0);
    expect(result.rules.test_coverage).toBe(80);
  });
});
