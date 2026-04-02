import type { AgentAdapter } from './adapter.interface.js';
import { ClaudeLocalAdapter } from './claude-local.js';
import { CodexLocalAdapter } from './codex-local.js';
import { CursorLocalAdapter } from './cursor-local.js';

export type { AgentAdapter, AdapterDetectResult, AdapterExecuteOptions, AdapterExecuteResult } from './adapter.interface.js';

const adapters: Record<string, AgentAdapter> = {
  claude_local: new ClaudeLocalAdapter(),
  codex_local: new CodexLocalAdapter(),
  cursor_local: new CursorLocalAdapter(),
};

export function getAdapter(type: string): AgentAdapter | undefined {
  return adapters[type];
}

export function getAllAdapters(): AgentAdapter[] {
  return Object.values(adapters);
}
