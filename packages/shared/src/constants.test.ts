import { describe, it, expect } from 'vitest';
import { APP_NAME, DEFAULT_PORT, DEFAULT_HOST, AGENT_ADAPTER_TYPES, TASK_STATUSES, AGENT_STATUSES, API_PREFIX } from './constants.js';

describe('constants', () => {
  it('APP_NAME is ddalkak', () => {
    expect(APP_NAME).toBe('ddalkak');
  });

  it('DEFAULT_PORT is 7777', () => {
    expect(DEFAULT_PORT).toBe(7777);
  });

  it('DEFAULT_HOST is localhost', () => {
    expect(DEFAULT_HOST).toBe('127.0.0.1');
  });

  it('has 3 agent adapter types', () => {
    expect(AGENT_ADAPTER_TYPES).toHaveLength(3);
    expect(AGENT_ADAPTER_TYPES).toContain('claude_local');
    expect(AGENT_ADAPTER_TYPES).toContain('codex_local');
    expect(AGENT_ADAPTER_TYPES).toContain('cursor_local');
  });

  it('has 4 task statuses', () => {
    expect(TASK_STATUSES).toHaveLength(4);
    expect(TASK_STATUSES).toContain('todo');
    expect(TASK_STATUSES).toContain('done');
  });

  it('has 5 agent statuses', () => {
    expect(AGENT_STATUSES).toHaveLength(5);
    expect(AGENT_STATUSES).toContain('running');
    expect(AGENT_STATUSES).toContain('idle');
  });

  it('API_PREFIX starts with /', () => {
    expect(API_PREFIX).toBe('/api');
  });
});
