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
  metadata?: TaskMetadata;
  status: TaskStatus;
  createdAt: Date;
  updatedAt: Date;
}

export interface TaskWorkflowPhase {
  id: string;
  label: string;
  objective?: string;
  enforceSeparation?: boolean;
  status?: 'pending' | 'in_progress' | 'done' | 'blocked';
}

export interface TaskChecklistEntry {
  id: string;
  label: string;
  kind: 'required' | 'advisory' | 'evidence';
}

export interface TaskWorkflowMetadata {
  id: string;
  name: string;
  summary?: string;
  source: 'gear';
  separationMode: 'advisory' | 'enforced';
  phases: TaskWorkflowPhase[];
  checklist: string[];
  phaseChecklistMap?: Record<string, Array<string | TaskChecklistEntry>>;
  completedChecklist?: string[];
  lastCompletedPhaseId?: string;
  lastCompletedAgentId?: string;
  lastBlockedReason?: string;
}

export interface TaskMetadata {
  workflow?: TaskWorkflowMetadata;
  goalAutomation?: TaskGoalAutomationMetadata;
}

export type GoalStatus = 'planned' | 'active' | 'achieved' | 'blocked';
export type ProjectAutomationRoutineStatus = 'active' | 'paused';
export type ProjectAutomationTaskStage = 'implement' | 'review' | 'verify';

export interface TaskGoalAutomationMetadata {
  goalId: string;
  goalTitle: string;
  stage: ProjectAutomationTaskStage;
  routineId?: string;
  createdBy: 'goal-automation';
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

// --- Project Analysis ---
export interface ProjectAnalysis {
  techStack: string[];
  git: { isRepo: boolean; url?: string; branch?: string };
  claudeMd: { exists: boolean; content?: string };
  agents: { name: string; path: string }[];
  hooks: { event: string; commands: string[] }[];
  mcpServers: { name: string; command: string; args?: string[] }[];
  docs: { name: string; path: string }[];  // .ddalkak/docs/*.md
  skills: { name: string; path: string }[];
  workflows: { name: string; path: string }[];  // .ddalkak/workflows/*.md
  conventions: { category: string; rule: string }[];
  guardrails: Record<string, string | number>;
  installedCLIs: { claude: boolean; codex: boolean; cursor: boolean };
  claudeMdQuality: {
    score: number;
    missingSections: string[];
    suggestions: string[];
  };
  scores: {
    guard: { score: number; details: { label: string; done: boolean }[] };
    guide: { score: number; details: { label: string; done: boolean }[] };
    gear: { score: number; details: { label: string; done: boolean }[] };
  };
}

// --- Claude MD Analysis ---
export interface ClaudeMdAnalysis {
  score: number;
  strengths: string[];
  improvements: string[];
  summary: string;
}

// --- Setup Analysis ---
export interface SetupImprovement {
  message: string;
  target: string;
  action: string;
}

export interface SetupAnalysis {
  score: number;
  guard: { strengths: string[]; improvements: SetupImprovement[] };
  guide: { strengths: string[]; improvements: SetupImprovement[] };
  gear: { strengths: string[]; improvements: SetupImprovement[] };
  summary: string;
}

export type SetupAxis = 'guard' | 'guide' | 'gear';

export interface ProjectSetupOperation {
  id: string;
  axis: SetupAxis;
  title: string;
  description: string;
  path?: string;
  scope: 'project';
  status: 'pending' | 'ready';
  preview?: {
    kind: 'file' | 'config';
    summary: string;
    excerpt?: string[];
    diffSummary?: {
      additions: number;
      removals: number;
      summary: string;
      additionsSample?: string[];
      removalsSample?: string[];
    };
    comparePreview?: {
      baseline: string[];
      current: string[];
    };
  };
  drift?: {
    state: 'aligned' | 'drifted' | 'missing';
    summary: string;
  };
}

export interface ProjectSetupAxisStatus {
  axis: SetupAxis;
  label: string;
  ready: boolean;
  readiness: number;
  summary: string;
  operations: ProjectSetupOperation[];
}

export interface ProjectSetupStatus {
  projectId: string;
  ready: boolean;
  mode: 'workspace';
  axes: ProjectSetupAxisStatus[];
  summary: string;
}

export interface ProjectSetupPlan {
  projectId: string;
  axes: ProjectSetupAxisStatus[];
  totals: {
    ready: number;
    pending: number;
  };
  summary: string;
}

export interface ProjectSetupRequest {
  axes?: SetupAxis[];
  operationIds?: string[];
  force?: boolean;
}

export interface ProjectSetupApplyResult {
  projectId: string;
  appliedAxes: SetupAxis[];
  results: Array<{
    id: string;
    axis: SetupAxis;
    title: string;
    outcome: 'created' | 'updated' | 'skipped' | 'error';
    detail: string;
    path?: string;
  }>;
}

// --- Goals / Automation ---
export interface Goal {
  id: string;
  projectId: string;
  parentGoalId?: string | null;
  title: string;
  description?: string | null;
  status: GoalStatus;
  createdAt: Date;
  updatedAt: Date;
}

export interface ProjectAutomationRoutine {
  id: string;
  projectId: string;
  name: string;
  description?: string | null;
  status: ProjectAutomationRoutineStatus;
  heartbeatMinutes: number;
  developerAgentId?: string | null;
  reviewerAgentId?: string | null;
  verifierAgentId?: string | null;
  lastEvaluatedAt?: Date | null;
  createdAt: Date;
  updatedAt: Date;
}

export interface ProjectAutomationRunResult {
  projectId: string;
  routineId?: string | null;
  evaluatedAt: string;
  createdTasks: Array<{
    taskId: string;
    goalId: string;
    goalTitle: string;
    stage: ProjectAutomationTaskStage;
    agentId?: string | null;
    title: string;
  }>;
  updatedGoals: Array<{
    goalId: string;
    status: GoalStatus;
  }>;
  skippedGoals: Array<{
    goalId: string;
    reason: string;
  }>;
  summary: string;
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
