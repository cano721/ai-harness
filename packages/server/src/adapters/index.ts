import type { AgentAdapter } from '@ddalkak/adapter-utils';
import { ClaudeLocalAdapter } from '@ddalkak/adapter-claude-local';
import { CodexLocalAdapter } from '@ddalkak/adapter-codex-local';
import { CursorLocalAdapter } from '@ddalkak/adapter-cursor-local';

export type { AgentAdapter, AdapterDetectResult, AdapterExecuteOptions, AdapterExecuteResult } from '@ddalkak/adapter-utils';

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
