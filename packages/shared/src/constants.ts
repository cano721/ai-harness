export const APP_NAME = 'ddalkak';
export const APP_VERSION = '3.0.0-alpha.0';
export const DEFAULT_PORT = 7777;
export const DEFAULT_HOST = '127.0.0.1';

export const DATA_DIR_NAME = '.ddalkak';
export const CONFIG_FILE = 'config.yaml';
export const CONVENTIONS_FILE = 'conventions.yaml';
export const RELATIONS_FILE = 'relations.yaml';

export const PGLITE_PORT = 54329;

export const AGENT_ADAPTER_TYPES = ['claude_local', 'codex_local', 'cursor_local'] as const;

export const TASK_STATUSES = ['todo', 'in_progress', 'done', 'blocked'] as const;
export const AGENT_STATUSES = ['idle', 'running', 'paused', 'error', 'terminated'] as const;

export const HEARTBEAT_INTERVAL_MS = 10_000;
export const HEARTBEAT_TIMEOUT_MS = 30_000;

export const API_PREFIX = '/api';
