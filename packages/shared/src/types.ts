import type { AGENT_ADAPTER_TYPES, TASK_STATUSES, AGENT_STATUSES } from './constants.js';

export type AgentAdapterType = typeof AGENT_ADAPTER_TYPES[number];
export type TaskStatus = typeof TASK_STATUSES[number];
export type AgentStatus = typeof AGENT_STATUSES[number];

// --- Project ---
export interface Project {
  id: string;
  name: string;
  path?: string;
  gitUrl?: string;
  description?: string;
  createdAt: Date;
  updatedAt: Date;
}

export interface ProjectRelation {
  id: string;
  sourceProjectId: string;
  targetProjectId: string;
  type: 'depends_on';
  createdAt: Date;
}

// --- Agent ---
export interface Agent {
  id: string;
  projectId: string;
  name: string;
  adapterType: AgentAdapterType;
  config: Record<string, unknown>;
  status: AgentStatus;
  lastHeartbeat?: Date;
  createdAt: Date;
}

export interface AgentSettings {
  type: AgentAdapterType;
  installed: boolean;
  version?: string;
  model?: string;
  configPath?: string;
  settings: Record<string, unknown>;
  hooks?: string[];
  skills?: string[];
  mcpServers?: string[];
}

// --- Convention ---
export interface Convention {
  id: string;
  projectId: string;
  scope: 'global' | 'project' | 'repo';
  category: string;
  rule: string;
  enabled: boolean;
  createdAt: Date;
}

// --- Guardrail ---
export interface Guardrail {
  id: string;
  projectId: string;
  key: string;
  value: string;
  source: 'db' | 'file';
  createdAt: Date;
}

// --- Task ---
export interface Task {
  id: string;
  projectId: string;
  agentId?: string;
  title: string;
  description?: string;
  status: TaskStatus;
  createdAt: Date;
  updatedAt: Date;
}

export interface TaskRun {
  id: string;
  taskId: string;
  agentId: string;
  runId: string;
  startedAt: Date;
  endedAt?: Date;
  exitCode?: number;
  costUsd?: number;
  tokensIn?: number;
  tokensOut?: number;
}

// --- Cost ---
export interface CostDaily {
  id: string;
  projectId: string;
  agentId: string;
  date: string;
  totalUsd: number;
  tokensIn: number;
  tokensOut: number;
}

// --- Activity ---
export interface ActivityEntry {
  id: string;
  projectId?: string;
  agentId?: string;
  eventType: string;
  detail: Record<string, unknown>;
  createdAt: Date;
}

// --- Adapter ---
export interface DetectResult {
  installed: boolean;
  version?: string;
  configPath?: string;
}

export interface ExecutionContext {
  runId: string;
  agent: Agent;
  task: Task;
  project: Project;
  env: Record<string, string>;
  timeoutSec: number;
  onLog: (stream: 'stdout' | 'stderr', chunk: string) => void;
}

export interface ExecutionResult {
  exitCode: number | null;
  signal?: string;
  timedOut: boolean;
  usage?: {
    inputTokens: number;
    outputTokens: number;
    cachedTokens?: number;
  };
  model?: string;
  provider?: string;
  costUsd?: number;
  summary?: string;
}

// --- API ---
export interface ApiResponse<T = unknown> {
  ok: boolean;
  data?: T;
  error?: string;
}

export interface DashboardSummary {
  activeAgents: number;
  runningAgents: number;
  conventionCompliance: number;
  securityEvents: number;
  monthlyCostUsd: number;
  monthlyBudgetUsd: number;
}
