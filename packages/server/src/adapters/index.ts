import type { AgentAdapter } from './adapter.interface.js';
import { ClaudeLocalAdapter } from './claude-local.js';
import { CodexLocalAdapter } from './codex-local.js';

export type { AgentAdapter, AdapterDetectResult, AdapterExecuteOptions, AdapterExecuteResult } from './adapter.interface.js';

const adapters: Record<string, AgentAdapter> = {
  claude_local: new ClaudeLocalAdapter(),
  codex_local: new CodexLocalAdapter(),
};

export function getAdapter(type: string): AgentAdapter | undefined {
  return adapters[type];
}

export function getAllAdapters(): AgentAdapter[] {
  return Object.values(adapters);
}
