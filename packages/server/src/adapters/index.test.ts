import { describe, expect, it } from 'vitest';
import { getAdapter, getAllAdapters } from './index.js';

describe('adapter registry', () => {
  it('returns all registered adapters', () => {
    const adapters = getAllAdapters();
    const types = adapters.map((adapter) => adapter.type).sort();

    expect(types).toEqual(['claude_local', 'codex_local', 'cursor_local']);
  });

  it('returns adapter by type', () => {
    expect(getAdapter('claude_local')?.type).toBe('claude_local');
    expect(getAdapter('codex_local')?.type).toBe('codex_local');
    expect(getAdapter('cursor_local')?.type).toBe('cursor_local');
  });

  it('returns undefined for unknown adapter type', () => {
    expect(getAdapter('unknown_adapter')).toBeUndefined();
  });
});
