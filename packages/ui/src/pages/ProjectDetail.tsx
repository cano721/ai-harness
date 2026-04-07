import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useParams, useNavigate, useSearchParams } from 'react-router-dom';
import { Suspense, lazy, useState, useRef, useEffect } from 'react';
import type {
  Goal as SharedGoal,
  GoalStatus,
  ProjectAutomationRoutine as SharedProjectAutomationRoutine,
  ProjectAutomationRoutineStatus,
  ProjectAutomationRunResult,
  ProjectAutomationTaskStage,
  TaskGoalAutomationMetadata,
} from '@ddalkak/shared';
import { api } from '../api/client.js';
import { parseExecutionEvidence } from './taskExecutionEvidence.js';

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface ScoreDetail {
  label: string;
  done: boolean;
}

interface AxisScore {
  score: number;
  details: ScoreDetail[];
}

interface ProjectAnalysis {
  techStack: string[];
  git: { isRepo: boolean; url?: string; branch?: string };
  claudeMd: { exists: boolean; content?: string };
  agents: { name: string; path: string }[];
  hooks: { event: string; commands: string[] }[];
  mcpServers: { name: string; command: string; args?: string[] }[];
  docs: { name: string; path: string }[];
  skills: { name: string; path: string }[];
  workflows: { name: string; path: string }[];
  conventions: { category: string; rule: string }[];
  guardrails: Record<string, string | number>;
  installedCLIs: { claude: boolean; codex: boolean; cursor: boolean };
  scores?: {
    guard: AxisScore;
    guide: AxisScore;
    gear: AxisScore;
  };
}

interface Project {
  id: string;
  name: string;
  path?: string;
  gitUrl?: string;
  description?: string;
  createdAt: string;
}

type Goal = Omit<SharedGoal, 'status' | 'createdAt' | 'updatedAt'> & {
  status: GoalStatus;
  createdAt: string;
  updatedAt: string;
};

type ProjectAutomationRoutine = Omit<SharedProjectAutomationRoutine, 'status' | 'lastEvaluatedAt' | 'createdAt' | 'updatedAt'> & {
  status: ProjectAutomationRoutineStatus;
  lastEvaluatedAt?: string | null;
  createdAt: string;
  updatedAt: string;
};

interface Agent {
  id: string;
  projectId: string;
  name: string;
  adapterType: string;
  status: string;
}

interface Task {
  id: string;
  projectId: string;
  agentId?: string;
  title: string;
  description?: string;
  metadata?: {
    workflow?: {
      id: string;
      name: string;
      summary?: string;
      source: 'gear';
      separationMode: 'advisory' | 'enforced';
      lastCompletedPhaseId?: string;
      lastCompletedAgentId?: string;
      lastBlockedReason?: string;
      phaseChecklistMap?: Record<string, Array<string | {
        id: string;
        label: string;
        kind: 'required' | 'advisory' | 'evidence';
      }>>;
      completedChecklist?: string[];
      phases: Array<{
        id: string;
        label: string;
        objective?: string;
        enforceSeparation?: boolean;
        status?: 'pending' | 'in_progress' | 'done' | 'blocked';
      }>;
      checklist: string[];
    };
    goalAutomation?: TaskGoalAutomationMetadata;
  };
  status: string;
  createdAt: string;
}

type TaskWorkflow = NonNullable<NonNullable<Task['metadata']>['workflow']>;
type ChecklistEntry = { id: string; label: string; kind: 'required' | 'advisory' | 'evidence' };

const RunTimelineDrawer = lazy(() => import('../components/RunTimelineDrawer.js'));

interface CostByProject {
  projectId: string;
  projectName: string;
  totalUsd: number;
  tokensIn: number;
  tokensOut: number;
}

interface TaskPhaseBlockInfo {
  phaseId: string;
  phaseLabel: string;
  requiredItems: Array<{ id: string; label: string; kind: 'required' | 'advisory' | 'evidence' }>;
}

interface TaskHandoffRetryState {
  status: 'starting' | 'started' | 'blocked';
  action: 'review' | 'advance';
}

interface Relation {
  id: string;
  type: string;
  sourceProject: { id: string; name: string };
  targetProject: { id: string; name: string };
}

interface ActivityEvent {
  id: string;
  projectId: string;
  eventType: string;
  detail: Record<string, unknown>;
  createdAt: string;
}

type SetupAxis = 'guard' | 'guide' | 'gear';

interface SetupOperation {
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

interface SetupAxisStatus {
  axis: SetupAxis;
  label: string;
  ready: boolean;
  readiness: number;
  summary: string;
  operations: SetupOperation[];
}

interface ProjectSetupStatus {
  projectId: string;
  ready: boolean;
  mode: 'workspace';
  axes: SetupAxisStatus[];
  summary: string;
}

interface ProjectSetupPlan {
  projectId: string;
  axes: SetupAxisStatus[];
  totals: {
    ready: number;
    pending: number;
  };
  summary: string;
}

interface ProjectSetupRequest {
  axes?: SetupAxis[];
  operationIds?: string[];
  force?: boolean;
}

interface ProjectSetupApplyResult {
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

interface TaskRun {
  id: string;
  taskId: string;
  status: string;
}

interface WorkflowTaskTemplate {
  id: string;
  name: string;
  summary: string;
  titleSuggestion: string;
  phases: Array<{
    id: string;
    label: string;
    objective?: string;
    enforceSeparation?: boolean;
    status?: 'pending' | 'in_progress' | 'done' | 'blocked';
  }>;
  checklist: string[];
  phaseChecklistMap?: Record<string, ChecklistEntry[]>;
  separationMode: 'advisory' | 'enforced';
  separationNote?: string;
  descriptionLines: string[];
}

// ─── Constants ────────────────────────────────────────────────────────────────

const statusStyle: Record<string, { bg: string; color: string }> = {
  todo: { bg: 'var(--surface3)', color: 'var(--text2)' },
  in_progress: { bg: 'rgba(116,185,255,0.1)', color: 'var(--blue)' },
  done: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  blocked: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
};

const agentStatusColors: Record<string, { bg: string; color: string }> = {
  running: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  idle: { bg: 'var(--surface3)', color: 'var(--text2)' },
  error: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
};

const adapterIcons: Record<string, { icon: string; color: string }> = {
  claude_local: { icon: 'C', color: '#d4a574' },
  codex_local: { icon: 'X', color: '#74b9ff' },
  cursor_local: { icon: 'Cu', color: '#a29bfe' },
};

const setupSearchParamKeys = {
  axes: 'setupAxes',
  operations: 'setupOps',
  expanded: 'setupExpanded',
  query: 'setupQuery',
} as const;

const MAX_GOAL_TREE_DEPTH = 24;

// ─── Utility Functions ────────────────────────────────────────────────────────

function formatUsd(n: number) {
  return `$${n.toFixed(4)}`;
}

function formatTokens(n: number) {
  return n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : n >= 1000 ? `${(n / 1000).toFixed(0)}K` : String(n);
}

function getGoalStatusColor(status: Goal['status']): 'blue' | 'green' | 'gray' | 'yellow' | 'orange' | 'red' {
  if (status === 'achieved') return 'green';
  if (status === 'active') return 'blue';
  if (status === 'blocked') return 'red';
  return 'gray';
}

function getGoalAutomationTaskMeta(task: Task) {
  return task.metadata?.goalAutomation;
}

function getGoalStageSummary(tasks: Task[], goalId: string) {
  const goalTasks = tasks
    .filter((task) => getGoalAutomationTaskMeta(task)?.goalId === goalId)
    .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
  const stages: ProjectAutomationTaskStage[] = ['implement', 'review', 'verify'];

  return stages.map((stage) => {
    const task = goalTasks.find((candidate) => getGoalAutomationTaskMeta(candidate)?.stage === stage);
    return {
      stage,
      task,
      status: task?.status ?? 'missing',
    };
  });
}

function pickDefaultAutomationAgents(projectAgents: Agent[]) {
  const reviewer = projectAgents.find((agent) => /review/i.test(agent.name));
  const verifier = projectAgents.find((agent) => /verif|qa|test/i.test(agent.name));
  const developer = projectAgents.find((agent) => agent.id !== reviewer?.id && agent.id !== verifier?.id)
    ?? projectAgents[0]
    ?? null;

  return {
    developerAgentId: developer?.id ?? '',
    reviewerAgentId: reviewer?.id ?? '',
    verifierAgentId: verifier?.id ?? '',
  };
}

function relativeTime(dateStr: string): string {
  const diff = Date.now() - new Date(dateStr).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return '방금';
  if (mins < 60) return `${mins}분 전`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}시간 전`;
  const days = Math.floor(hours / 24);
  return `${days}일 전`;
}

function getNextPhase(workflow?: TaskWorkflow) {
  return workflow?.phases.find((phase) => phase.status === 'in_progress' || phase.status === 'pending');
}

function getActivePhase(workflow?: TaskWorkflow) {
  return workflow?.phases.find((phase) => phase.status === 'in_progress');
}

function getBlockedPhase(workflow?: TaskWorkflow) {
  return workflow?.phases.find((phase) => phase.status === 'blocked');
}

function normalizeChecklistEntry(entry: string | ChecklistEntry): ChecklistEntry {
  if (typeof entry === 'string') {
    return { id: entry, label: entry, kind: 'required' };
  }
  return entry;
}

function getChecklistScope(workflow?: TaskWorkflow, phase?: TaskWorkflow['phases'][number]) {
  if (!workflow) return [];
  const phaseScoped = phase?.id ? workflow.phaseChecklistMap?.[phase.id] : undefined;
  return (phaseScoped?.length ? phaseScoped : (workflow.checklist ?? [])).map(normalizeChecklistEntry);
}

function getRemainingChecklistState(workflow?: TaskWorkflow, phase?: TaskWorkflow['phases'][number]) {
  const remaining = getChecklistScope(workflow, phase).filter((item) => !(workflow?.completedChecklist ?? []).includes(item.id));
  return {
    remaining,
    required: remaining.filter((item) => item.kind === 'required'),
    evidence: remaining.filter((item) => item.kind === 'evidence'),
    advisory: remaining.filter((item) => item.kind === 'advisory'),
  };
}

function getChecklistActionTone(state: ReturnType<typeof getRemainingChecklistState>) {
  if (state.required.length > 0) return 'red' as const;
  if (state.evidence.length > 0) return 'yellow' as const;
  if (state.advisory.length > 0) return 'blue' as const;
  return 'neutral' as const;
}

function getChecklistActionSuffix(state: ReturnType<typeof getRemainingChecklistState>) {
  if (state.required.length > 0) return `${state.required.length} required open`;
  if (state.evidence.length > 0) return `${state.evidence.length} evidence open`;
  if (state.advisory.length > 0) return `${state.advisory.length} advisory open`;
  return null;
}

function parseTaskPhaseBlockInfo(error: unknown): TaskPhaseBlockInfo | null {
  if (!error || typeof error !== 'object') return null;
  const maybeBody = (error as { body?: unknown }).body;
  if (!maybeBody || typeof maybeBody !== 'object') return null;
  const data = (maybeBody as { data?: unknown }).data;
  if (!data || typeof data !== 'object') return null;
  const phaseId = typeof (data as { phaseId?: unknown }).phaseId === 'string' ? (data as { phaseId: string }).phaseId : null;
  const phaseLabel = typeof (data as { phaseLabel?: unknown }).phaseLabel === 'string' ? (data as { phaseLabel: string }).phaseLabel : null;
  const requiredItems = Array.isArray((data as { requiredItems?: unknown }).requiredItems)
    ? (data as { requiredItems: Array<{ id?: unknown; label?: unknown; kind?: unknown }> }).requiredItems
        .filter((item) => typeof item?.id === 'string' && typeof item?.label === 'string' && typeof item?.kind === 'string')
        .map((item) => ({
          id: item.id as string,
          label: item.label as string,
          kind: item.kind as 'required' | 'advisory' | 'evidence',
        }))
    : [];

  if (!phaseId || !phaseLabel || requiredItems.length === 0) return null;
  return { phaseId, phaseLabel, requiredItems };
}

function getApiErrorStatus(error: unknown): number | null {
  if (!error || typeof error !== 'object') return null;
  const status = (error as { status?: unknown }).status;
  return typeof status === 'number' ? status : null;
}

function getApiErrorMessage(error: unknown, fallback: string) {
  if (!error || typeof error !== 'object') return fallback;
  const message = (error as { message?: unknown }).message;
  if (typeof message === 'string' && message.trim().length > 0) {
    return message;
  }
  return fallback;
}

function canSendToReview(workflow?: TaskWorkflow) {
  if (!workflow || workflow.separationMode !== 'enforced') return false;
  const activeIndex = workflow.phases.findIndex((phase) => phase.status === 'in_progress');
  const reviewIndex = workflow.phases.findIndex((phase) => phase.enforceSeparation && phase.status === 'pending');
  return activeIndex >= 0 && reviewIndex === activeIndex + 1;
}

function canRunReview(workflow?: TaskWorkflow, task?: Task) {
  if (!workflow || !task?.agentId) return false;
  return workflow.phases.some((phase) => phase.enforceSeparation && phase.status === 'in_progress');
}

function needsReviewerSetup(workflow?: TaskWorkflow) {
  return workflow?.lastBlockedReason?.includes('reviewer agent') ?? false;
}

function pickReviewerAgent(agents: Agent[], task: Task) {
  const projectAgents = agents.filter((agent) => agent.projectId === task.projectId && agent.id !== task.agentId);
  const reviewer = projectAgents.find((agent) => /review/i.test(agent.name) && agent.status === 'idle');
  if (reviewer) return reviewer;
  return projectAgents.find((agent) => agent.status === 'idle') ?? null;
}

function buildAgentCapabilities(agent: Agent | null | undefined, phase?: TaskWorkflow['phases'][number], workflow?: TaskWorkflow) {
  const values = new Set<string>();
  const phaseText = `${phase?.id ?? ''} ${phase?.label ?? ''} ${phase?.objective ?? ''}`.toLowerCase();
  const agentText = `${agent?.name ?? ''} ${agent?.adapterType ?? ''}`.toLowerCase();

  if (agentText.includes('claude')) values.add('analysis');
  if (agentText.includes('codex')) values.add('code changes');
  if (agentText.includes('cursor')) values.add('editor workflow');
  if (phaseText.match(/implement|fix|refactor|boundary|context/)) values.add('implementation');
  if (phaseText.match(/validate|verify|regression|protect|test/)) values.add('validation');
  if (phaseText.match(/review/)) values.add('review pass');
  if (phase?.enforceSeparation || workflow?.separationMode === 'enforced') values.add('separate context');
  if (agentText.includes('review')) values.add('review pass');
  if (agentText.includes('develop') || agentText.includes('builder')) values.add('implementation');
  if (values.size === 0) values.add('general purpose');

  return [...values];
}

function buildSetupOrigins(workflow?: TaskWorkflow, phase?: TaskWorkflow['phases'][number]) {
  const values = new Set<string>();
  if (workflow?.source === 'gear') values.add('gear workflow');
  values.add('CLAUDE.md');
  values.add('context map');

  const phaseText = `${phase?.id ?? ''} ${phase?.label ?? ''}`.toLowerCase();
  if (phaseText.match(/implement|fix|refactor|boundary/)) values.add('developer agent asset');
  if (phaseText.match(/review/) || workflow?.separationMode === 'enforced') values.add('reviewer agent asset');
  if (phaseText.match(/validate|verify|regression|protect|test/)) values.add('review guide');

  return [...values];
}

function buildPhasePolicyLines(workflow?: TaskWorkflow, phase?: TaskWorkflow['phases'][number], reviewAgent?: Agent | null) {
  const lines = new Set<string>();
  const phaseText = `${phase?.id ?? ''} ${phase?.label ?? ''}`.toLowerCase();
  const remainingChecklist = getRemainingChecklistState(workflow, phase);

  if (workflow?.separationMode === 'enforced' || phase?.enforceSeparation) {
    lines.add('Use a different agent than the previous completed phase.');
  }
  if (phaseText.match(/review/)) {
    lines.add(reviewAgent ? `Reviewer handoff is ready for ${reviewAgent.name}.` : 'Reviewer assignment is required before running review.');
  }
  if (phaseText.match(/validate|verify|regression|protect|test/)) {
    lines.add('Collect verification evidence before advancing the workflow.');
  }
  if (phaseText.match(/implement|fix|refactor|boundary/)) {
    lines.add('Keep the scope small and hand off cleanly to validation or review.');
  }
  if (remainingChecklist.required.length > 0) {
    lines.add(`Complete ${remainingChecklist.required.length} required checklist item(s) before phase handoff.`);
  }
  if (remainingChecklist.evidence.length > 0) {
    lines.add(`Capture evidence for ${remainingChecklist.evidence.length} checklist item(s) before phase handoff.`);
  }
  if (remainingChecklist.advisory.length > 0) {
    lines.add(`${remainingChecklist.advisory.length} advisory checklist reminder(s) are still open.`);
  }
  if (phase?.status === 'blocked') {
    lines.add('Resolve the blocking condition before resuming this phase.');
  }
  if (lines.size === 0) {
    lines.add('No additional orchestration policy is required for this phase.');
  }

  return [...lines];
}

function buildOrchestrationAlerts(
  task: Task,
  workflow?: TaskWorkflow,
  phase?: TaskWorkflow['phases'][number],
  assignedAgent?: Agent | null,
  reviewAgent?: Agent | null,
) {
  const alerts: Array<{ label: string; tone: 'blue' | 'green' | 'yellow' | 'red' }> = [];
  const phaseText = `${phase?.id ?? ''} ${phase?.label ?? ''}`.toLowerCase();
  const remainingChecklist = getRemainingChecklistState(workflow, phase);

  if (assignedAgent) {
    alerts.push({ label: `Agent assigned: ${assignedAgent.name}`, tone: 'blue' });
  } else {
    alerts.push({ label: 'Primary agent unassigned', tone: 'yellow' });
  }
  if (phase?.status === 'blocked' || task.status === 'blocked') {
    alerts.push({ label: 'Phase blocked', tone: 'red' });
  }
  if (workflow?.separationMode === 'enforced' || phase?.enforceSeparation) {
    alerts.push({ label: 'Separation enforced', tone: 'yellow' });
  }
  if (phaseText.match(/review/)) {
    alerts.push(reviewAgent
      ? { label: `Reviewer ready: ${reviewAgent.name}`, tone: 'green' }
      : { label: 'Reviewer missing', tone: 'red' });
  }
  if (phaseText.match(/validate|verify|regression|protect|test/) && task.status !== 'done') {
    alerts.push({ label: 'Validation evidence needed', tone: 'yellow' });
  }
  if (remainingChecklist.required.length > 0) {
    alerts.push({ label: `${remainingChecklist.required.length} required checklist item(s) open`, tone: 'red' });
  }
  if (remainingChecklist.evidence.length > 0) {
    alerts.push({ label: `${remainingChecklist.evidence.length} evidence item(s) still needed`, tone: 'yellow' });
  }
  if (remainingChecklist.advisory.length > 0) {
    alerts.push({ label: `${remainingChecklist.advisory.length} advisory reminder(s) open`, tone: 'blue' });
  }

  return alerts;
}

function toggleWorkflowChecklist(workflow: TaskWorkflow, itemId: string) {
  const completed = new Set(workflow.completedChecklist ?? []);
  if (completed.has(itemId)) {
    completed.delete(itemId);
  } else {
    completed.add(itemId);
  }

  return {
    ...workflow,
    completedChecklist: [...completed],
  };
}

function confirmChecklistHandoff(workflow: TaskWorkflow | undefined, actionLabel: string) {
  const activePhase = getActivePhase(workflow) ?? getBlockedPhase(workflow) ?? workflow?.phases.find((phase) => phase.status === 'pending');
  const remaining = getRemainingChecklistState(workflow, activePhase);
  if (remaining.remaining.length === 0) return true;

  const sections = [
    remaining.required.length > 0 ? `Required:\n- ${remaining.required.map((item) => item.label).join('\n- ')}` : null,
    remaining.evidence.length > 0 ? `Evidence:\n- ${remaining.evidence.map((item) => item.label).join('\n- ')}` : null,
    remaining.advisory.length > 0 ? `Advisory:\n- ${remaining.advisory.map((item) => item.label).join('\n- ')}` : null,
  ].filter(Boolean).join('\n\n');

  return window.confirm(
    `${actionLabel} before leaving ${remaining.remaining.length} checklist item(s) open?\n\n${sections}`,
  );
}

function clearBlockedReason(workflow: TaskWorkflow) {
  if (!workflow.lastBlockedReason) return workflow;
  const { lastBlockedReason: _lastBlockedReason, ...rest } = workflow;
  return rest;
}

function advanceWorkflow(workflow: TaskWorkflow) {
  const currentIndex = workflow.phases.findIndex((phase) => phase.status === 'in_progress');
  const fallbackIndex = workflow.phases.findIndex((phase) => phase.status === 'pending');
  const activeIndex = currentIndex >= 0 ? currentIndex : fallbackIndex;

  if (activeIndex < 0) {
    return {
      workflow,
      status: 'done' as const,
    };
  }

  const phases = workflow.phases.map((phase, index) => {
    if (index < activeIndex) return { ...phase, status: 'done' as const };
    if (index === activeIndex) return { ...phase, status: 'done' as const };
    if (index === activeIndex + 1) return { ...phase, status: 'in_progress' as const };
    return { ...phase, status: phase.status ?? 'pending' as const };
  });

  return {
    workflow: { ...workflow, phases },
    status: activeIndex === phases.length - 1 ? 'done' as const : 'in_progress' as const,
  };
}

function sendWorkflowToReview(workflow: TaskWorkflow) {
  const nextWorkflow = clearBlockedReason(workflow);
  const activeIndex = workflow.phases.findIndex((phase) => phase.status === 'in_progress');
  const reviewIndex = workflow.phases.findIndex((phase) => phase.enforceSeparation && phase.status === 'pending');

  if (activeIndex < 0 || reviewIndex !== activeIndex + 1) {
    return {
      workflow,
      status: 'in_progress' as const,
    };
  }

  const phases = workflow.phases.map((phase, index) => {
    if (index < activeIndex) return { ...phase, status: 'done' as const };
    if (index === activeIndex) return { ...phase, status: 'done' as const };
    if (index === reviewIndex) return { ...phase, status: 'in_progress' as const };
    return { ...phase, status: phase.status ?? 'pending' as const };
  });

  return {
    workflow: { ...nextWorkflow, phases },
    status: 'in_progress' as const,
  };
}

function blockWorkflow(workflow: TaskWorkflow) {
  const activeIndex = workflow.phases.findIndex((phase) => phase.status === 'in_progress');
  if (activeIndex < 0) {
    return { workflow, status: 'blocked' as const };
  }

  const phases = workflow.phases.map((phase, index) => (
    index === activeIndex ? { ...phase, status: 'blocked' as const } : phase
  ));

  return {
    workflow: { ...workflow, phases },
    status: 'blocked' as const,
  };
}

function resumeWorkflow(workflow: TaskWorkflow) {
  const nextWorkflow = clearBlockedReason(workflow);
  const blockedIndex = workflow.phases.findIndex((phase) => phase.status === 'blocked');
  if (blockedIndex < 0) {
    return { workflow: nextWorkflow, status: 'in_progress' as const };
  }

  const phases = workflow.phases.map((phase, index) => (
    index === blockedIndex ? { ...phase, status: 'in_progress' as const } : phase
  ));

  return {
    workflow: { ...nextWorkflow, phases },
    status: 'in_progress' as const,
  };
}

function getWorkflowOutcomeSummary(task: Task, workflow?: TaskWorkflow) {
  if (!workflow) return null;

  const blockedPhase = getBlockedPhase(workflow);
  if (blockedPhase?.enforceSeparation && !workflow.lastBlockedReason) {
    return {
      text: 'Review blocked again. Inspect the reviewer run or retry with another reviewer.',
      color: 'var(--red)',
    };
  }

  const completedPhase = workflow.lastCompletedPhaseId
    ? workflow.phases.find((phase) => phase.id === workflow.lastCompletedPhaseId)
    : undefined;
  if (!completedPhase?.enforceSeparation) return null;

  return {
    text: task.status === 'done'
      ? 'Review completed. Workflow is done.'
      : `Review completed. Next: ${getNextPhase(workflow)?.label ?? 'follow-up ready'}.`,
    color: 'var(--green)',
  };
}

function getLatestTaskActivity(events: ActivityEvent[], taskId: string) {
  return events.find((event) => event.detail.taskId === taskId && event.eventType.startsWith('task.'));
}

function getExecutionSnapshotKey(entry: ActivityEvent) {
  const execution = parseExecutionEvidence(entry.detail);
  if (!execution) return null;
  return `${execution.queueState}/${execution.workerStatus}/${execution.workerHealth}/${execution.workerCapacityLabel}`;
}

function hasExecutionEvidence(entry: ActivityEvent) {
  return parseExecutionEvidence(entry.detail) !== null;
}

function getPreferredTimelineEntry(entries: ActivityEvent[]) {
  return entries.find((entry) => hasExecutionEvidence(entry)) ?? entries[0];
}

function getTaskActivityTimeline(events: ActivityEvent[], taskId: string) {
  const taskEvents = events.filter((event) => event.detail.taskId === taskId && event.eventType.startsWith('task.'));
  if (taskEvents.length <= 3) return taskEvents;

  const selected: ActivityEvent[] = [];
  const selectedIds = new Set<string>();
  const remember = (entry: ActivityEvent) => {
    if (selected.length >= 3 || selectedIds.has(entry.id)) return;
    selected.push(entry);
    selectedIds.add(entry.id);
  };

  const latestEvent = taskEvents[0];
  if (latestEvent) remember(latestEvent);

  for (const entry of taskEvents) {
    if (entry.eventType === 'task.worker.heartbeat') continue;
    if (!hasExecutionEvidence(entry)) continue;
    remember(entry);
    if (selected.length >= 3) return selected;
  }

  for (const entry of taskEvents) {
    if (entry.eventType === 'task.worker.heartbeat') continue;
    remember(entry);
    if (selected.length >= 3) return selected;
  }

  const seenSnapshots = new Set<string>();
  for (const entry of selected) {
    const snapshot = getExecutionSnapshotKey(entry);
    if (snapshot) seenSnapshots.add(snapshot);
  }

  for (const entry of taskEvents) {
    if (entry.eventType !== 'task.worker.heartbeat') continue;
    if (selectedIds.has(entry.id)) continue;
    const snapshot = getExecutionSnapshotKey(entry);
    if (snapshot && seenSnapshots.has(snapshot)) continue;
    remember(entry);
    if (snapshot) seenSnapshots.add(snapshot);
    if (selected.length >= 3) return selected;
  }

  for (const entry of taskEvents) {
    remember(entry);
    if (selected.length >= 3) return selected;
  }

  return selected;
}

function getTaskActivitySummary(entry?: ActivityEvent) {
  if (!entry) return null;

  const execution = parseExecutionEvidence(entry.detail);
  const executionSuffix = execution ? ` (${execution.summaryLabel})` : '';
  const checklistItem = typeof entry.detail.checklistItem === 'string' ? entry.detail.checklistItem : undefined;
  const checklistState = typeof entry.detail.state === 'string' ? entry.detail.state : undefined;
  const checklistKind = typeof entry.detail.checklistKind === 'string' ? entry.detail.checklistKind : undefined;
  const checklistSuffix = checklistKind ? ` (${checklistKind})` : '';

  const workflowPhase = entry.detail.workflowPhase as {
    from?: string;
    to?: string;
    outcome?: 'advanced' | 'completed' | 'blocked' | 'unchanged';
  } | undefined;
  const fromLabel = workflowPhase?.from?.toLowerCase();
  const toLabel = workflowPhase?.to?.toLowerCase();
  const isReviewRun = fromLabel?.includes('review') || toLabel?.includes('review');

  if (entry.eventType === 'task.started') {
    return {
      text: `${isReviewRun ? 'Review run started.' : 'Run started.'}${executionSuffix}`,
      color: 'var(--blue)',
    };
  }

  if (entry.eventType === 'task.completed') {
    return {
      text: `${isReviewRun ? 'Last review passed.' : 'Last run passed.'}${executionSuffix}`,
      color: 'var(--green)',
    };
  }

  if (entry.eventType === 'task.failed') {
    return {
      text: `${isReviewRun ? 'Last review failed.' : 'Last run failed.'}${executionSuffix}`,
      color: 'var(--red)',
    };
  }

  if (entry.eventType === 'task.dispatch.accepted') {
    return {
      text: `Dispatch accepted.${executionSuffix}`,
      color: 'var(--blue)',
    };
  }

  if (entry.eventType === 'task.worker.leased') {
    return {
      text: `Worker lease acquired.${executionSuffix}`,
      color: 'var(--blue)',
    };
  }

  if (entry.eventType === 'task.worker.completed') {
    return {
      text: `Worker completed queued run.${executionSuffix}`,
      color: 'var(--green)',
    };
  }

  if (entry.eventType === 'task.worker.failed' || entry.eventType === 'task.worker.cancelled') {
    return {
      text: `Worker run ended with ${entry.eventType.endsWith('cancelled') ? 'cancellation' : 'failure'}.${executionSuffix}`,
      color: 'var(--red)',
    };
  }

  if (entry.eventType === 'task.worker.capacity_blocked') {
    return {
      text: `Worker capacity blocked retry.${executionSuffix}`,
      color: 'var(--yellow)',
    };
  }

  if (entry.eventType === 'task.worker.heartbeat') {
    return {
      text: `Worker heartbeat refreshed.${executionSuffix}`,
      color: 'var(--blue)',
    };
  }

  if (entry.eventType === 'task.checklist.toggled' && checklistItem) {
    return {
      text: checklistState === 'reopened'
        ? `Checklist reopened: ${checklistItem}${checklistSuffix}.`
        : `Checklist completed: ${checklistItem}${checklistSuffix}.`,
      color: checklistState === 'reopened' ? 'var(--yellow)' : 'var(--green)',
    };
  }

  return null;
}

function getTaskTimelineLabel(entry: ActivityEvent) {
  const execution = parseExecutionEvidence(entry.detail);
  const checklistItem = typeof entry.detail.checklistItem === 'string' ? entry.detail.checklistItem : undefined;
  const checklistState = typeof entry.detail.state === 'string' ? entry.detail.state : undefined;
  const checklistKind = typeof entry.detail.checklistKind === 'string' ? entry.detail.checklistKind : undefined;
  const checklistSuffix = checklistKind ? ` (${checklistKind})` : '';
  const workflowPhase = entry.detail.workflowPhase as {
    from?: string;
    to?: string;
    outcome?: 'advanced' | 'completed' | 'blocked' | 'unchanged';
  } | undefined;
  const phaseLabel = workflowPhase?.to ?? workflowPhase?.from;

  if (entry.eventType === 'task.started') {
    return phaseLabel ? `started ${phaseLabel}` : 'started';
  }

  if (entry.eventType === 'task.completed') {
    return phaseLabel ? `passed ${phaseLabel}` : 'passed';
  }

  if (entry.eventType === 'task.failed') {
    return phaseLabel ? `failed ${phaseLabel}` : 'failed';
  }

  if (entry.eventType === 'task.checklist.toggled') {
    if (!checklistItem) return 'checklist updated';
    return checklistState === 'reopened' ? `reopened ${checklistItem}${checklistSuffix}` : `checked ${checklistItem}${checklistSuffix}`;
  }

  if (entry.eventType === 'task.dispatch.accepted') {
    return `dispatch ${execution?.queueState ?? 'accepted'}`;
  }
  if (entry.eventType === 'task.worker.leased') return 'worker leased';
  if (entry.eventType === 'task.worker.completed') return 'worker completed';
  if (entry.eventType === 'task.worker.failed') return 'worker failed';
  if (entry.eventType === 'task.worker.cancelled') return 'worker cancelled';
  if (entry.eventType === 'task.worker.capacity_blocked') return 'worker capacity blocked';
  if (entry.eventType === 'task.worker.heartbeat') return 'worker heartbeat';

  return entry.eventType.replace('task.', '');
}

function getTaskTimelineColor(eventType: string) {
  if (eventType === 'task.started') return { bg: 'rgba(116,185,255,0.12)', color: 'var(--blue)' };
  if (eventType === 'task.completed') return { bg: 'rgba(0,206,201,0.12)', color: 'var(--green)' };
  if (eventType === 'task.failed') return { bg: 'rgba(255,107,107,0.12)', color: 'var(--red)' };
  if (eventType === 'task.dispatch.accepted') return { bg: 'rgba(116,185,255,0.12)', color: 'var(--blue)' };
  if (eventType === 'task.worker.leased') return { bg: 'rgba(116,185,255,0.12)', color: 'var(--blue)' };
  if (eventType === 'task.worker.completed') return { bg: 'rgba(0,206,201,0.12)', color: 'var(--green)' };
  if (eventType === 'task.worker.failed' || eventType === 'task.worker.cancelled') return { bg: 'rgba(255,107,107,0.12)', color: 'var(--red)' };
  if (eventType === 'task.worker.capacity_blocked') return { bg: 'rgba(253,203,110,0.12)', color: 'var(--yellow)' };
  if (eventType === 'task.worker.heartbeat') return { bg: 'rgba(116,185,255,0.12)', color: 'var(--blue)' };
  if (eventType === 'task.checklist.toggled') return { bg: 'rgba(0,206,201,0.12)', color: 'var(--green)' };
  return { bg: 'var(--surface3)', color: 'var(--text2)' };
}

function getTaskTimelineDetail(entry: ActivityEvent) {
  const execution = parseExecutionEvidence(entry.detail);
  const checklistItem = typeof entry.detail.checklistItem === 'string' ? entry.detail.checklistItem : undefined;
  const checklistState = typeof entry.detail.state === 'string' ? entry.detail.state : undefined;
  const checklistKind = typeof entry.detail.checklistKind === 'string' ? entry.detail.checklistKind : undefined;
  const checklistSuffix = checklistKind ? ` (${checklistKind})` : '';
  const workflowPhase = entry.detail.workflowPhase as {
    from?: string;
    to?: string;
    outcome?: 'advanced' | 'completed' | 'blocked' | 'unchanged';
  } | undefined;

  const phaseLine = workflowPhase?.from || workflowPhase?.to
    ? `${workflowPhase?.from ?? 'unknown'} -> ${workflowPhase?.to ?? workflowPhase?.from ?? 'unknown'}`
    : 'No phase transition detail';

  return {
    eventLabel: entry.eventType,
    phaseLine,
    outcome: checklistItem
      ? `${checklistState === 'reopened' ? 'reopened' : 'completed'} ${checklistItem}${checklistSuffix}`
      : (workflowPhase?.outcome ?? 'unchanged'),
    createdAt: relativeTime(entry.createdAt),
    runId: typeof entry.detail.runId === 'string' ? entry.detail.runId : undefined,
    executionSummaryLabel: execution?.summaryLabel,
    executionBadges: execution?.badges ?? [],
    executionLines: execution?.lines ?? [],
  };
}

function isReviewTimelineEntry(entry: ActivityEvent) {
  const workflowPhase = entry.detail.workflowPhase as {
    from?: string;
    to?: string;
  } | undefined;
  const label = `${workflowPhase?.from ?? ''} ${workflowPhase?.to ?? ''}`.toLowerCase();
  return label.includes('review');
}

function formatActivityDetail(detail: Record<string, unknown>) {
  const message = detail.message;
  if (typeof message === 'string') return message;
  const title = detail.title;
  if (typeof title === 'string') return title;
  return 'Activity event';
}

// ─── Shared Components ────────────────────────────────────────────────────────

function InfoRow({ label, value }: { label: string; value?: string }) {
  if (!value) return null;
  return (
    <div style={{ display: 'flex', gap: 12, padding: '8px 0', borderBottom: '1px solid var(--border)' }}>
      <span style={{ fontSize: 12, color: 'var(--text2)', width: 90, flexShrink: 0 }}>{label}</span>
      <span style={{ fontSize: 12, color: 'var(--text)', wordBreak: 'break-all' }}>{value}</span>
    </div>
  );
}

function SectionCard({ title, titleExtra, children }: { title: string; titleExtra?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, overflow: 'hidden' }}>
      <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', display: 'flex', justifyContent: 'space-between', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        <span style={{ fontSize: 14, fontWeight: 600 }}>{title}</span>
        {titleExtra}
      </div>
      <div style={{ padding: '12px 18px' }}>{children}</div>
    </div>
  );
}

function Badge({ children, color = 'blue' }: { children: React.ReactNode; color?: 'blue' | 'green' | 'gray' | 'yellow' | 'orange' | 'red' }) {
  const colorMap = {
    blue: { bg: 'rgba(116,185,255,0.15)', color: 'var(--blue)' },
    green: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
    gray: { bg: 'var(--surface3)', color: 'var(--text2)' },
    yellow: { bg: 'rgba(253,203,110,0.15)', color: 'var(--yellow)' },
    orange: { bg: 'rgba(253,150,60,0.15)', color: '#fd963c' },
    red: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
  };
  const s = colorMap[color];
  return (
    <span
      style={{
        padding: '2px 8px',
        borderRadius: 6,
        fontSize: 11,
        fontWeight: 600,
        background: s.bg,
        color: s.color,
        display: 'inline-block',
      }}
    >
      {children}
    </span>
  );
}

function axisBadgeColor(axis: SetupAxis): 'green' | 'blue' | 'orange' {
  if (axis === 'guard') return 'green';
  if (axis === 'guide') return 'blue';
  return 'orange';
}

function findSetupOperation(setupStatus: ProjectSetupStatus | undefined, operationId: string) {
  return setupStatus?.axes.flatMap((axis) => axis.operations).find((operation) => operation.id === operationId);
}

function findApplyResult(lastApplyResult: ProjectSetupApplyResult | null, operationId: string) {
  return lastApplyResult?.results.find((result) => result.id === operationId);
}

function summarizeApplyResults(
  lastApplyResult: ProjectSetupApplyResult | null,
  operationIds: string[],
): string | null {
  if (!lastApplyResult) {
    return null;
  }

  const matches = lastApplyResult.results.filter((result) => operationIds.includes(result.id));
  if (matches.length === 0) {
    return null;
  }

  const summary = matches
    .map((result) => `${result.outcome} ${result.title}`)
    .join(', ');

  return `Last apply: ${summary}`;
}

function buildApplyResolutionSummary(
  lastApplyResult: ProjectSetupApplyResult | null,
  setupStatus?: ProjectSetupStatus,
) {
  if (!lastApplyResult) {
    return null;
  }

  const operations = setupStatus?.axes.flatMap((axis) => axis.operations) ?? [];
  const operationMap = new Map(operations.map((operation) => [operation.id, operation]));
  const changedResults = lastApplyResult.results.filter((result) => result.outcome === 'created' || result.outcome === 'updated');
  const skippedCount = lastApplyResult.results.filter((result) => result.outcome === 'skipped').length;
  const errorCount = lastApplyResult.results.filter((result) => result.outcome === 'error').length;

  let alignedCount = 0;
  let driftedCount = 0;
  let missingCount = 0;
  const changedTitles: string[] = [];
  const alignedTitles: string[] = [];
  const driftedTitles: string[] = [];
  const missingTitles: string[] = [];
  const changedItems: Array<{ id: string; title: string; axis: SetupAxis }> = [];
  const alignedItems: Array<{ id: string; title: string; axis: SetupAxis }> = [];
  const driftedItems: Array<{ id: string; title: string; axis: SetupAxis }> = [];
  const missingItems: Array<{ id: string; title: string; axis: SetupAxis }> = [];

  for (const result of changedResults) {
    const operation = operationMap.get(result.id);
    const title = operation?.title ?? result.title;
    const axis = operation?.axis ?? result.axis;
    changedTitles.push(title);
    changedItems.push({ id: result.id, title, axis });
    if (!operation) {
      continue;
    }
    if (operation.drift?.state === 'drifted') {
      driftedCount += 1;
      driftedTitles.push(title);
      driftedItems.push({ id: result.id, title, axis });
      continue;
    }
    if (operation.drift?.state === 'missing' || operation.status === 'pending') {
      missingCount += 1;
      missingTitles.push(title);
      missingItems.push({ id: result.id, title, axis });
      continue;
    }
    alignedCount += 1;
    alignedTitles.push(title);
    alignedItems.push({ id: result.id, title, axis });
  }

  return {
    changedCount: changedResults.length,
    skippedCount,
    errorCount,
    alignedCount,
    driftedCount,
    missingCount,
    changedTitles,
    alignedTitles,
    driftedTitles,
    missingTitles,
    changedItems,
    alignedItems,
    driftedItems,
    missingItems,
  };
}

function isManagedDoc(name: string) {
  return ['convention', 'architecture', 'review'].includes(name);
}

function isManagedAgentAsset(name: string) {
  return ['developer', 'reviewer'].includes(name);
}

function isManagedWorkflowAsset(name: string) {
  return ['implement-feature', 'fix-bug', 'refactor'].includes(name);
}

function SetupPanelMeta({ axis, operation }: { axis: SetupAxis; operation?: SetupOperation }) {
  const status =
    operation?.drift?.state === 'drifted'
      ? { label: 'Drifted', color: 'orange' as const }
      : operation?.status === 'ready'
        ? { label: 'Ready', color: 'green' as const }
        : operation?.status === 'pending'
          ? { label: 'Missing', color: 'yellow' as const }
          : { label: 'Managed by Setup', color: 'gray' as const };

  return (
    <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
      <Badge color={axisBadgeColor(axis)}>{axis.toUpperCase()}</Badge>
      <Badge color={status.color}>{status.label}</Badge>
    </div>
  );
}

function SetupManagedBanner({
  axis,
  operation,
  summary,
  hint,
  lastApplySummary,
  focusActionLabel,
  onFocusAction,
  focusActionDisabled,
  actionLabel,
  onAction,
  actionDisabled,
  secondaryActionLabel,
  onSecondaryAction,
  secondaryActionDisabled,
}: {
  axis: SetupAxis;
  operation?: SetupOperation;
  summary: string;
  hint?: string;
  lastApplySummary?: string | null;
  focusActionLabel?: string;
  onFocusAction?: () => void;
  focusActionDisabled?: boolean;
  actionLabel?: string;
  onAction?: () => void;
  actionDisabled?: boolean;
  secondaryActionLabel?: string;
  onSecondaryAction?: () => void;
  secondaryActionDisabled?: boolean;
}) {
  const state =
    operation?.drift?.state === 'drifted'
      ? 'Drifted'
      : operation?.status === 'ready'
        ? 'Ready'
        : operation?.status === 'pending'
          ? 'Missing'
          : 'Managed by Setup';

  return (
    <div
      style={{
        marginBottom: 12,
        padding: 12,
        borderRadius: 10,
        border: '1px solid var(--border)',
        background: 'var(--surface2)',
        display: 'flex',
        justifyContent: 'space-between',
        gap: 12,
        alignItems: 'flex-start',
        flexWrap: 'wrap',
      }}
    >
      <div style={{ minWidth: 0 }}>
        <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap', marginBottom: 6 }}>
          <Badge color={axisBadgeColor(axis)}>{axis.toUpperCase()}</Badge>
          <Badge color={operation?.drift?.state === 'drifted' ? 'orange' : operation?.status === 'ready' ? 'green' : operation?.status === 'pending' ? 'yellow' : 'gray'}>{state}</Badge>
          <span style={{ fontSize: 11, color: 'var(--text2)' }}>Managed by Setup</span>
        </div>
        <div style={{ fontSize: 12, color: 'var(--text)', lineHeight: 1.5 }}>{summary}</div>
        {operation?.drift && (
          <div style={{ fontSize: 11, color: operation.drift.state === 'drifted' ? '#fd963c' : 'var(--text2)', marginTop: 6 }}>
            {operation.drift.summary}
          </div>
        )}
        {hint && (
          <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 6 }}>{hint}</div>
        )}
        {lastApplySummary && (
          <div style={{ fontSize: 11, color: 'var(--blue)', marginTop: 6 }}>{lastApplySummary}</div>
        )}
      </div>
      {(focusActionLabel && onFocusAction) || (actionLabel && onAction) || (secondaryActionLabel && onSecondaryAction) ? (
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', flexShrink: 0 }}>
          {focusActionLabel && onFocusAction && (
            <button
              onClick={onFocusAction}
              disabled={focusActionDisabled}
              style={{
                padding: '7px 12px',
                borderRadius: 8,
                border: '1px solid var(--border)',
                background: 'transparent',
                color: 'var(--text2)',
                fontSize: 12,
                fontWeight: 600,
                cursor: focusActionDisabled ? 'not-allowed' : 'pointer',
                opacity: focusActionDisabled ? 0.6 : 1,
              }}
            >
              {focusActionLabel}
            </button>
          )}
          {secondaryActionLabel && onSecondaryAction && (
            <button
              onClick={onSecondaryAction}
              disabled={secondaryActionDisabled}
              style={{
                padding: '7px 12px',
                borderRadius: 8,
                border: '1px solid var(--border)',
                background: 'transparent',
                color: 'var(--text2)',
                fontSize: 12,
                fontWeight: 600,
                cursor: secondaryActionDisabled ? 'not-allowed' : 'pointer',
                opacity: secondaryActionDisabled ? 0.6 : 1,
              }}
            >
              {secondaryActionLabel}
            </button>
          )}
          {actionLabel && onAction && (
            <button
              onClick={onAction}
              disabled={actionDisabled}
              style={{
                padding: '7px 12px',
                borderRadius: 8,
                border: '1px solid var(--border)',
                background: 'var(--surface)',
                color: 'var(--text)',
                fontSize: 12,
                fontWeight: 600,
                cursor: actionDisabled ? 'not-allowed' : 'pointer',
                opacity: actionDisabled ? 0.6 : 1,
              }}
            >
              {actionLabel}
            </button>
          )}
        </div>
      ) : null}
    </div>
  );
}

function SkeletonBlock({ width = '100%', height = 16 }: { width?: string | number; height?: number }) {
  return (
    <div
      style={{
        width,
        height,
        borderRadius: 6,
        background: 'var(--surface3)',
        animation: 'pulse 1.5s ease-in-out infinite',
      }}
    />
  );
}

// ─── Feature 1: Guard/Guide/Gear Score Panel ──────────────────────────────────

const axisConfig = {
  guard: { label: 'Guard', fill: 'var(--green)', textColor: '#00cec9' },
  guide: { label: 'Guide', fill: 'var(--blue)', textColor: '#74b9ff' },
  gear: { label: 'Gear', fill: '#fd963c', textColor: '#fd963c' },
} as const;

function ScorePanel({ scores }: { scores: ProjectAnalysis['scores'] }) {
  if (!scores) return null;

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 10,
        padding: '12px 14px',
        background: 'var(--surface2)',
        borderRadius: 10,
        border: '1px solid var(--border)',
        marginBottom: 14,
      }}
    >
      {(['guard', 'guide', 'gear'] as const).map((axis) => {
        const cfg = axisConfig[axis];
        const { score, details } = scores[axis];
        return (
          <div key={axis}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
              <span style={{ fontSize: 12, fontWeight: 600, color: cfg.textColor, width: 40 }}>{cfg.label}</span>
              <span style={{ fontSize: 11, color: 'var(--text2)', width: 36 }}>{score}%</span>
              <div
                style={{
                  flex: 1,
                  height: 8,
                  background: 'var(--surface3)',
                  borderRadius: 4,
                  overflow: 'hidden',
                }}
              >
                <div
                  style={{
                    width: `${score}%`,
                    height: '100%',
                    background: cfg.fill,
                    borderRadius: 4,
                    transition: 'width 0.4s ease',
                  }}
                />
              </div>
            </div>
            <div style={{ paddingLeft: 84, fontSize: 11, color: 'var(--text2)' }}>
              {details.map((d) => (
                <span key={d.label} style={{ marginRight: 10 }}>
                  {d.done ? '✓' : '✗'} {d.label}
                </span>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ─── Feature 2: Guard Status Section ─────────────────────────────────────────

function GuardSection({ projectId, guardScore }: { projectId: string; guardScore?: number }) {
  const { data: activity = [] } = useQuery({
    queryKey: ['activity', projectId],
    queryFn: () => api.get<ActivityEvent[]>(`/activity?projectId=${projectId}&limit=20`),
    enabled: !!projectId,
  });

  const securityEvents = activity.filter((e) => e.eventType.startsWith('security.'));

  const statusColor =
    guardScore === undefined ? 'var(--text2)'
    : guardScore >= 80 ? 'var(--green)'
    : guardScore >= 50 ? 'var(--yellow)'
    : 'var(--red)';

  const statusLabel =
    guardScore === undefined ? '정보 없음'
    : guardScore >= 80 ? '안전'
    : guardScore >= 50 ? '주의'
    : '위험';

  return (
    <SectionCard title="Guard 상태">
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12 }}>
        <div
          style={{
            width: 10,
            height: 10,
            borderRadius: '50%',
            background: statusColor,
            flexShrink: 0,
          }}
        />
        <span style={{ fontSize: 13, fontWeight: 600, color: statusColor }}>{statusLabel}</span>
        {guardScore !== undefined && (
          <span style={{ fontSize: 11, color: 'var(--text2)' }}>({guardScore}%)</span>
        )}
      </div>

      <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 6 }}>최근 차단 이벤트</div>
      {securityEvents.length === 0 ? (
        <div style={{ fontSize: 12, color: 'var(--green)' }}>최근 차단 이벤트 없음 ✓</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          {securityEvents.map((e) => (
            <div
              key={e.id}
              style={{
                fontSize: 12,
                color: 'var(--text)',
                padding: '5px 10px',
                background: 'rgba(255,107,107,0.07)',
                borderRadius: 6,
                border: '1px solid rgba(255,107,107,0.2)',
              }}
            >
              {formatActivityDetail(e.detail)} <span style={{ color: 'var(--text2)', marginLeft: 6 }}>({relativeTime(e.createdAt)})</span>
            </div>
          ))}
        </div>
      )}
    </SectionCard>
  );
}

function SetupCenter({
  projectId,
  hasPath,
  setupStatus,
  isLoading,
  analysis,
  lastApplyResult,
  onApplySuccess,
  onOpenSettings,
  focusRequest,
}: {
  projectId: string;
  hasPath: boolean;
  setupStatus?: ProjectSetupStatus;
  isLoading: boolean;
  analysis?: ProjectAnalysis;
  lastApplyResult: ProjectSetupApplyResult | null;
  onApplySuccess: (result: ProjectSetupApplyResult) => void;
  onOpenSettings: () => void;
  focusRequest?: { operationIds: string[]; token: number };
}) {
  const queryClient = useQueryClient();
  const [searchParams, setSearchParams] = useSearchParams();
  const [selectedAxes, setSelectedAxes] = useState<SetupAxis[]>([]);
  const [selectedOperationIds, setSelectedOperationIds] = useState<string[]>([]);
  const [expandedAxis, setExpandedAxis] = useState<SetupAxis | null>(null);
  const [operationQuery, setOperationQuery] = useState(() => searchParams.get(setupSearchParamKeys.query) ?? '');
  const [selectionHydrated, setSelectionHydrated] = useState(false);

  useEffect(() => {
    if (!setupStatus || selectedAxes.length > 0 || selectedOperationIds.length > 0) {
      if (setupStatus && !selectionHydrated && (selectedAxes.length > 0 || selectedOperationIds.length > 0)) {
        setSelectionHydrated(true);
      }
      return;
    }

    const validAxes = setupStatus.axes.map((axis) => axis.axis);
    const validOperationIds = new Set(setupStatus.axes.flatMap((axis) => axis.operations.map((operation) => operation.id)));
    const urlAxes = (searchParams.get(setupSearchParamKeys.axes) ?? '')
      .split(',')
      .filter((value): value is SetupAxis => validAxes.includes(value as SetupAxis));
    const urlOperationIds = (searchParams.get(setupSearchParamKeys.operations) ?? '')
      .split(',')
      .filter((value) => validOperationIds.has(value));
    const urlExpanded = searchParams.get(setupSearchParamKeys.expanded);

    if (urlAxes.length > 0 && urlOperationIds.length > 0) {
      setSelectionHydrated(true);
      setSelectedAxes(urlAxes);
      setSelectedOperationIds(urlOperationIds);
      if (urlExpanded && validAxes.includes(urlExpanded as SetupAxis)) {
        setExpandedAxis(urlExpanded as SetupAxis);
      }
      return;
    }

    const incomplete = setupStatus.axes.filter((axis) => !axis.ready).map((axis) => axis.axis);
    const defaultAxes = incomplete.length > 0 ? incomplete : setupStatus.axes.map((axis) => axis.axis);
    const defaultOperationIds = setupStatus.axes
      .filter((axis) => defaultAxes.includes(axis.axis))
      .flatMap((axis) => {
        const pending = axis.operations.filter((operation) => operation.status === 'pending');
        return (pending.length > 0 ? pending : axis.operations).map((operation) => operation.id);
      });

    setSelectionHydrated(true);
    setSelectedAxes(defaultAxes);
    setSelectedOperationIds(defaultOperationIds);
  }, [searchParams, selectedAxes.length, selectedOperationIds.length, selectionHydrated, setupStatus]);

  useEffect(() => {
    if (!setupStatus || !selectionHydrated) {
      return;
    }

    const nextParams = new URLSearchParams(searchParams);
    if (selectedAxes.length > 0 && selectedOperationIds.length > 0) {
      nextParams.set(setupSearchParamKeys.axes, selectedAxes.join(','));
      nextParams.set(setupSearchParamKeys.operations, selectedOperationIds.join(','));
    } else {
      nextParams.delete(setupSearchParamKeys.axes);
      nextParams.delete(setupSearchParamKeys.operations);
    }
    if (expandedAxis) {
      nextParams.set(setupSearchParamKeys.expanded, expandedAxis);
    } else {
      nextParams.delete(setupSearchParamKeys.expanded);
    }
    if (operationQuery.trim()) {
      nextParams.set(setupSearchParamKeys.query, operationQuery.trim());
    } else {
      nextParams.delete(setupSearchParamKeys.query);
    }

    const current = searchParams.toString();
    const next = nextParams.toString();
    if (current !== next) {
      setSearchParams(nextParams, { replace: true });
    }
  }, [expandedAxis, operationQuery, searchParams, selectedAxes, selectedOperationIds, selectionHydrated, setSearchParams, setupStatus]);

  useEffect(() => {
    if (!setupStatus || !focusRequest || focusRequest.operationIds.length === 0) {
      return;
    }

    const operations = setupStatus.axes
      .flatMap((axis) => axis.operations)
      .filter((operation) => focusRequest.operationIds.includes(operation.id));
    if (operations.length === 0) {
      return;
    }

    const uniqueIds = Array.from(new Set(operations.map((operation) => operation.id)));
    const uniqueAxes = Array.from(new Set(operations.map((operation) => operation.axis)));
    setSelectedOperationIds(uniqueIds);
    setSelectedAxes(uniqueAxes);
    setExpandedAxis(operations[0].axis);
    setOperationQuery('');
  }, [focusRequest, setupStatus]);

  const planMutation = useMutation({
    mutationFn: ({ axes, operationIds }: ProjectSetupRequest) =>
      api.post<ProjectSetupPlan>(`/projects/${projectId}/setup/plan`, { axes, operationIds }),
  });

  const applyMutation = useMutation({
    mutationFn: ({ axes, operationIds }: ProjectSetupRequest) =>
      api.post<ProjectSetupApplyResult>(`/projects/${projectId}/setup/apply`, { axes, operationIds }),
    onSuccess: (result) => {
      queryClient.invalidateQueries({ queryKey: ['project-analysis', projectId] });
      queryClient.invalidateQueries({ queryKey: ['project-setup-status', projectId] });
      queryClient.invalidateQueries({ queryKey: ['db-conventions', projectId] });
      onApplySuccess(result);
    },
  });

  const getAxisOperationIds = (axis: SetupAxis) => {
    const axisStatus = setupStatus?.axes.find((item) => item.axis === axis);
    return axisStatus ? axisStatus.operations.map((operation) => operation.id) : [];
  };

  const toggleAxis = (axis: SetupAxis) => {
    const axisOperationIds = getAxisOperationIds(axis);
    const axisSelected = axisOperationIds.length > 0 && axisOperationIds.every((operationId) => selectedOperationIds.includes(operationId));

    if (axisSelected) {
      setSelectedAxes((prev) => prev.filter((value) => value !== axis));
      setSelectedOperationIds((prev) => prev.filter((operationId) => !axisOperationIds.includes(operationId)));
      return;
    }

    setSelectedAxes((prev) => prev.includes(axis) ? prev : [...prev, axis]);
    setSelectedOperationIds((prev) => Array.from(new Set([...prev, ...axisOperationIds])));
  };

  const toggleExpandedAxis = (axis: SetupAxis) => {
    setExpandedAxis((prev) => prev === axis ? null : axis);
  };

  const toggleOperation = (axis: SetupAxis, operationId: string) => {
    const axisOperationIds = getAxisOperationIds(axis);
    const isSelected = selectedOperationIds.includes(operationId);

    if (isSelected) {
      const nextOperationIds = selectedOperationIds.filter((value) => value !== operationId);
      setSelectedOperationIds(nextOperationIds);
      if (!nextOperationIds.some((value) => axisOperationIds.includes(value))) {
        setSelectedAxes((prev) => prev.filter((value) => value !== axis));
      }
      return;
    }

    setSelectedOperationIds((prev) => [...prev, operationId]);
    setSelectedAxes((prev) => prev.includes(axis) ? prev : [...prev, axis]);
  };

  const selectOperations = (predicate: (operation: SetupOperation) => boolean) => {
    if (!setupStatus) {
      return;
    }

    const selected = setupStatus.axes
      .flatMap((axis) => axis.operations)
      .filter(predicate);

    setSelectedOperationIds(selected.map((operation) => operation.id));
    setSelectedAxes(Array.from(new Set(selected.map((operation) => operation.axis))));
  };

  const selectPendingOnly = () => {
    selectOperations((operation) => operation.status === 'pending');
  };

  const selectDriftedOnly = () => {
    selectOperations((operation) => operation.drift?.state === 'drifted');
  };

  const clearSelection = () => {
    setSelectedAxes([]);
    setSelectedOperationIds([]);
  };

  const focusChangedOperations = () => {
    if (!lastApplyResult) {
      return;
    }

    const changedIds = lastApplyResult.results
      .filter((result) => result.outcome === 'created' || result.outcome === 'updated')
      .map((result) => result.id);
    if (changedIds.length === 0) {
      return;
    }

    const changedOperations = setupStatus?.axes
      .flatMap((axis) => axis.operations)
      .filter((operation) => changedIds.includes(operation.id)) ?? [];

    setSelectedOperationIds(changedIds);
    setSelectedAxes(Array.from(new Set(changedOperations.map((operation) => operation.axis))));
    if (changedOperations.length > 0) {
      setExpandedAxis(changedOperations[0].axis);
    }
  };

  const focusSingleOperation = (operationId: string) => {
    const operation = setupStatus?.axes.flatMap((axis) => axis.operations).find((item) => item.id === operationId);
    if (!operation) {
      return;
    }

    setSelectedOperationIds([operationId]);
    setSelectedAxes([operation.axis]);
    setExpandedAxis(operation.axis);
  };

  const focusOperationGroup = (operationIds: string[]) => {
    if (!setupStatus || operationIds.length === 0) {
      return;
    }

    const operations = setupStatus.axes
      .flatMap((axis) => axis.operations)
      .filter((operation) => operationIds.includes(operation.id));
    if (operations.length === 0) {
      return;
    }

    const uniqueIds = Array.from(new Set(operations.map((operation) => operation.id)));
    const uniqueAxes = Array.from(new Set(operations.map((operation) => operation.axis)));
    setSelectedOperationIds(uniqueIds);
    setSelectedAxes(uniqueAxes);
    setExpandedAxis(operations[0].axis);
  };

  const keepSelectedOperations = (predicate: (operation: SetupOperation) => boolean) => {
    const nextOperations = selectedOperations.filter(predicate);
    if (nextOperations.length === 0) {
      return;
    }

    const uniqueIds = Array.from(new Set(nextOperations.map((operation) => operation.id)));
    const uniqueAxes = Array.from(new Set(nextOperations.map((operation) => operation.axis)));
    setSelectedOperationIds(uniqueIds);
    setSelectedAxes(uniqueAxes);
    setExpandedAxis(nextOperations[0].axis);
  };

  const setOperationSelection = (operations: SetupOperation[]) => {
    if (operations.length === 0) {
      return;
    }

    const uniqueIds = Array.from(new Set(operations.map((operation) => operation.id)));
    const uniqueAxes = Array.from(new Set(operations.map((operation) => operation.axis)));
    setSelectedOperationIds(uniqueIds);
    setSelectedAxes(uniqueAxes);
    setExpandedAxis(operations[0].axis);
  };

  const activeAxes = selectedAxes.filter((axis, index, values) => values.indexOf(axis) === index)
    .filter((axis) => getAxisOperationIds(axis).some((operationId) => selectedOperationIds.includes(operationId)));
  const allOperations = setupStatus?.axes.flatMap((axis) => axis.operations) ?? [];
  const selectedOperations = allOperations.filter((operation) => selectedOperationIds.includes(operation.id));
  const normalizedOperationQuery = operationQuery.trim().toLowerCase();
  const matchesOperationQuery = (operation: SetupOperation) => {
    if (!normalizedOperationQuery) {
      return true;
    }
    return [operation.title, operation.description, operation.path ?? '', operation.id]
      .some((value) => value.toLowerCase().includes(normalizedOperationQuery));
  };
  const visibleOperations = allOperations.filter(matchesOperationQuery);
  const selectedByAxis = activeAxes.map((axis) => ({
    axis,
    count: selectedOperations.filter((operation) => operation.axis === axis).length,
  }));
  const visibleSelectedOperations = selectedOperations.filter(matchesOperationQuery);
  const visibleOperationCount = visibleOperations.length;
  const visibleSelectedIds = new Set(visibleSelectedOperations.map((operation) => operation.id));
  const hiddenSelectedOperations = selectedOperations.filter((operation) => !visibleSelectedIds.has(operation.id));
  const selectedPendingCount = selectedOperations.filter((operation) => operation.status === 'pending').length;
  const selectedAlignedCount = selectedOperations.filter((operation) => operation.drift?.state === 'aligned').length;
  const selectedDriftedCount = selectedOperations.filter((operation) => operation.drift?.state === 'drifted').length;
  const selectedMissingCount = selectedOperations.filter((operation) => operation.drift?.state === 'missing' || operation.status === 'pending').length;

  const previewPlan = () => {
    if (activeAxes.length === 0 || selectedOperationIds.length === 0) {
      return;
    }
    planMutation.mutate({ axes: activeAxes, operationIds: selectedOperationIds });
  };

  const applySetup = () => {
    if (activeAxes.length === 0 || selectedOperationIds.length === 0) {
      return;
    }
    applyMutation.mutate({ axes: activeAxes, operationIds: selectedOperationIds });
  };

  const axisColor: Record<SetupAxis, string> = {
    guard: 'var(--green)',
    guide: 'var(--blue)',
    gear: '#fd963c',
  };
  const cliInstalled = analysis ? Object.values(analysis.installedCLIs).some(Boolean) : true;
  const applyResolutionSummary = buildApplyResolutionSummary(lastApplyResult, setupStatus);

  const renderDiffSamples = (diffSummary?: NonNullable<SetupOperation['preview']>['diffSummary']) => {
    if (!diffSummary || (diffSummary.additionsSample?.length ?? 0) === 0 && (diffSummary.removalsSample?.length ?? 0) === 0) {
      return null;
    }

    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: 6 }}>
        {diffSummary.additionsSample && diffSummary.additionsSample.length > 0 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <span style={{ fontSize: 10, color: 'var(--green)', fontWeight: 700 }}>Baseline sample</span>
            <pre
              style={{
                fontSize: 10,
                color: 'var(--green)',
                background: 'rgba(0,206,201,0.08)',
                border: '1px solid rgba(0,206,201,0.2)',
                borderRadius: 6,
                padding: 8,
                margin: 0,
                whiteSpace: 'pre-wrap',
                wordBreak: 'break-word',
              }}
            >
              {diffSummary.additionsSample.map((line: string) => `+ ${line}`).join('\n')}
            </pre>
          </div>
        )}
        {diffSummary.removalsSample && diffSummary.removalsSample.length > 0 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <span style={{ fontSize: 10, color: '#fd963c', fontWeight: 700 }}>Current sample</span>
            <pre
              style={{
                fontSize: 10,
                color: '#fd963c',
                background: 'rgba(253,150,60,0.08)',
                border: '1px solid rgba(253,150,60,0.2)',
                borderRadius: 6,
                padding: 8,
                margin: 0,
                whiteSpace: 'pre-wrap',
                wordBreak: 'break-word',
              }}
            >
              {diffSummary.removalsSample.map((line: string) => `- ${line}`).join('\n')}
            </pre>
          </div>
        )}
      </div>
    );
  };

  const renderComparePreview = (
    comparePreview?: NonNullable<SetupOperation['preview']>['comparePreview'],
    driftState?: NonNullable<SetupOperation['drift']>['state'],
  ) => {
    if (!comparePreview || driftState === 'aligned') {
      return null;
    }

    return (
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(2, minmax(0, 1fr))',
          gap: 8,
          marginTop: 8,
        }}
      >
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          <span style={{ fontSize: 10, color: 'var(--green)', fontWeight: 700 }}>Baseline</span>
          <pre
            style={{
              fontSize: 10,
              color: 'var(--green)',
              background: 'rgba(0,206,201,0.08)',
              border: '1px solid rgba(0,206,201,0.2)',
              borderRadius: 6,
              padding: 8,
              margin: 0,
              minHeight: 88,
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
            }}
          >
            {comparePreview.baseline.length > 0 ? comparePreview.baseline.join('\n') : '(missing)'}
          </pre>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          <span style={{ fontSize: 10, color: '#fd963c', fontWeight: 700 }}>Current</span>
          <pre
            style={{
              fontSize: 10,
              color: '#fd963c',
              background: 'rgba(253,150,60,0.08)',
              border: '1px solid rgba(253,150,60,0.2)',
              borderRadius: 6,
              padding: 8,
              margin: 0,
              minHeight: 88,
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
            }}
          >
            {comparePreview.current.length > 0 ? comparePreview.current.join('\n') : '(missing)'}
          </pre>
        </div>
      </div>
    );
  };

  return (
    <SectionCard title="Project Setup Center">
      {!hasPath ? (
        <div style={{ fontSize: 13, color: 'var(--text2)' }}>
          프로젝트 경로가 있어야 setup 상태를 계산할 수 있습니다.
        </div>
      ) : isLoading ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <SkeletonBlock height={16} />
          <SkeletonBlock width="80%" height={16} />
          <SkeletonBlock width="60%" height={16} />
        </div>
      ) : setupStatus ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, alignItems: 'flex-start', flexWrap: 'wrap' }}>
            <div>
              <div style={{ fontSize: 16, fontWeight: 700, marginBottom: 6 }}>
                {setupStatus.ready ? 'Workspace ready' : 'Setup required'}
              </div>
              <div style={{ fontSize: 12, color: 'var(--text2)', maxWidth: 720 }}>
                {setupStatus.summary}
              </div>
              <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 6 }}>
                Project-local assets are managed here. Global runtime settings remain in Settings.
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              <button
                onClick={selectPendingOnly}
                disabled={!setupStatus.axes.some((axis) => axis.operations.some((operation) => operation.status === 'pending'))}
                style={{
                  padding: '8px 12px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'transparent',
                  color: 'var(--text2)',
                  fontSize: 12,
                  fontWeight: 600,
                  cursor: !setupStatus.axes.some((axis) => axis.operations.some((operation) => operation.status === 'pending')) ? 'not-allowed' : 'pointer',
                  opacity: !setupStatus.axes.some((axis) => axis.operations.some((operation) => operation.status === 'pending')) ? 0.5 : 1,
                }}
              >
                Pending Only
              </button>
              <button
                onClick={selectDriftedOnly}
                disabled={!setupStatus.axes.some((axis) => axis.operations.some((operation) => operation.drift?.state === 'drifted'))}
                style={{
                  padding: '8px 12px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'transparent',
                  color: 'var(--text2)',
                  fontSize: 12,
                  fontWeight: 600,
                  cursor: !setupStatus.axes.some((axis) => axis.operations.some((operation) => operation.drift?.state === 'drifted')) ? 'not-allowed' : 'pointer',
                  opacity: !setupStatus.axes.some((axis) => axis.operations.some((operation) => operation.drift?.state === 'drifted')) ? 0.5 : 1,
                }}
              >
                Drifted Only
              </button>
              <button
                onClick={clearSelection}
                disabled={selectedOperationIds.length === 0}
                style={{
                  padding: '8px 12px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'transparent',
                  color: 'var(--text2)',
                  fontSize: 12,
                  fontWeight: 600,
                  cursor: selectedOperationIds.length === 0 ? 'not-allowed' : 'pointer',
                  opacity: selectedOperationIds.length === 0 ? 0.5 : 1,
                }}
              >
                Clear
              </button>
              <button
                onClick={previewPlan}
                disabled={activeAxes.length === 0 || selectedOperationIds.length === 0 || planMutation.isPending}
                style={{
                  padding: '8px 14px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'var(--surface2)',
                  color: 'var(--text)',
                  fontSize: 12,
                  fontWeight: 600,
                  cursor: activeAxes.length === 0 || selectedOperationIds.length === 0 || planMutation.isPending ? 'not-allowed' : 'pointer',
                  opacity: activeAxes.length === 0 || selectedOperationIds.length === 0 || planMutation.isPending ? 0.6 : 1,
                }}
              >
                {planMutation.isPending ? 'Planning...' : 'Preview Plan'}
              </button>
              <button
                onClick={applySetup}
                disabled={activeAxes.length === 0 || selectedOperationIds.length === 0 || applyMutation.isPending}
                style={{
                  padding: '8px 14px',
                  borderRadius: 8,
                  border: 'none',
                  background: 'var(--accent)',
                  color: '#fff',
                  fontSize: 12,
                  fontWeight: 700,
                  cursor: activeAxes.length === 0 || selectedOperationIds.length === 0 || applyMutation.isPending ? 'not-allowed' : 'pointer',
                  opacity: activeAxes.length === 0 || selectedOperationIds.length === 0 || applyMutation.isPending ? 0.6 : 1,
                }}
              >
                {applyMutation.isPending ? 'Applying...' : 'Apply Setup'}
              </button>
            </div>
          </div>

          {!cliInstalled && (
            <div
              style={{
                border: '1px solid rgba(253, 203, 110, 0.35)',
                borderRadius: 12,
                background: 'rgba(253,203,110,0.08)',
                padding: 12,
                display: 'flex',
                justifyContent: 'space-between',
                gap: 12,
                alignItems: 'center',
                flexWrap: 'wrap',
              }}
            >
              <div>
                <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--yellow)', marginBottom: 4 }}>
                  Runtime CLI not detected
                </div>
                <div style={{ fontSize: 12, color: 'var(--text2)' }}>
                  Setup stays project-local, but task execution will remain limited until Claude, Codex, or Cursor CLI is configured in Settings.
                </div>
              </div>
              <button
                onClick={onOpenSettings}
                style={{
                  padding: '7px 12px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'var(--surface)',
                  color: 'var(--text)',
                  fontSize: 12,
                  fontWeight: 600,
                  cursor: 'pointer',
                }}
              >
                Open Settings
              </button>
            </div>
          )}

          <div
            style={{
              border: '1px solid var(--border)',
              borderRadius: 12,
              background: 'var(--surface2)',
              padding: 12,
              display: 'flex',
              justifyContent: 'space-between',
              gap: 12,
              alignItems: 'center',
              flexWrap: 'wrap',
            }}
          >
            <div style={{ minWidth: 240, flex: '1 1 280px' }}>
              <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Operation Filter</div>
              <input
                type="text"
                value={operationQuery}
                onChange={(event) => setOperationQuery(event.target.value)}
                placeholder="Search by title, path, or operation id"
                aria-label="Filter setup operations"
                style={{
                  width: '100%',
                  padding: '8px 10px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'var(--surface)',
                  color: 'var(--text)',
                  fontSize: 12,
                }}
              />
            </div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              <Badge color="gray">{visibleOperationCount} visible op(s)</Badge>
              <button
                onClick={() => setOperationSelection(visibleOperations)}
                disabled={visibleOperationCount === 0}
                style={{
                  padding: '7px 12px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'var(--surface)',
                  color: 'var(--text)',
                  fontSize: 12,
                  fontWeight: 600,
                  cursor: visibleOperationCount === 0 ? 'not-allowed' : 'pointer',
                  opacity: visibleOperationCount === 0 ? 0.5 : 1,
                }}
              >
                Select Visible
              </button>
              <button
                onClick={() => setOperationSelection(visibleSelectedOperations)}
                disabled={visibleSelectedOperations.length === 0}
                style={{
                  padding: '7px 12px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'var(--surface)',
                  color: 'var(--text)',
                  fontSize: 12,
                  fontWeight: 600,
                  cursor: visibleSelectedOperations.length === 0 ? 'not-allowed' : 'pointer',
                  opacity: visibleSelectedOperations.length === 0 ? 0.5 : 1,
                }}
              >
                Focus Visible
              </button>
              <button
                onClick={() => {
                  const remainingOperations = selectedOperations.filter((operation) => !matchesOperationQuery(operation));
                  if (remainingOperations.length === 0) {
                    clearSelection();
                    return;
                  }
                  setOperationSelection(remainingOperations);
                }}
                disabled={visibleSelectedOperations.length === 0}
                style={{
                  padding: '7px 12px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'transparent',
                  color: 'var(--text2)',
                  fontSize: 12,
                  fontWeight: 600,
                  cursor: visibleSelectedOperations.length === 0 ? 'not-allowed' : 'pointer',
                  opacity: visibleSelectedOperations.length === 0 ? 0.5 : 1,
                }}
              >
                Deselect Visible
              </button>
              {operationQuery.trim() && (
                <button
                  onClick={() => setOperationQuery('')}
                  style={{
                    padding: '7px 12px',
                    borderRadius: 8,
                    border: '1px solid var(--border)',
                    background: 'transparent',
                    color: 'var(--text2)',
                    fontSize: 12,
                    fontWeight: 600,
                    cursor: 'pointer',
                  }}
                >
                  Clear Filter
                </button>
              )}
            </div>
          </div>

          <div
            style={{
              border: '1px solid var(--border)',
              borderRadius: 12,
              background: 'var(--surface2)',
              padding: 12,
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
              <div style={{ fontSize: 12, fontWeight: 700 }}>Selected Scope</div>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                <Badge color="blue">{selectedOperationIds.length} operation(s)</Badge>
                <Badge color="gray">{activeAxes.length} axis(es)</Badge>
              </div>
            </div>
            {selectedOperations.length > 0 ? (
              <>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {selectedByAxis.map((item) => (
                    <Badge key={item.axis} color={axisBadgeColor(item.axis)}>
                      {item.axis.toUpperCase()} {item.count}
                    </Badge>
                  ))}
                  {selectedPendingCount > 0 && <Badge color="yellow">{selectedPendingCount} pending</Badge>}
                  {selectedAlignedCount > 0 && <Badge color="green">{selectedAlignedCount} aligned</Badge>}
                  {selectedDriftedCount > 0 && <Badge color="orange">{selectedDriftedCount} drifted</Badge>}
                  {selectedMissingCount > 0 && <Badge color="yellow">{selectedMissingCount} missing</Badge>}
                  {visibleSelectedOperations.length > 0 && <Badge color="blue">{visibleSelectedOperations.length} visible selected</Badge>}
                  {hiddenSelectedOperations.length > 0 && <Badge color="gray">{hiddenSelectedOperations.length} hidden selected</Badge>}
                </div>
                {hiddenSelectedOperations.length > 0 && (
                  <div
                    style={{
                      padding: '10px 12px',
                      borderRadius: 10,
                      border: '1px solid rgba(253, 203, 110, 0.35)',
                      background: 'rgba(253,203,110,0.08)',
                      display: 'flex',
                      justifyContent: 'space-between',
                      gap: 10,
                      alignItems: 'center',
                      flexWrap: 'wrap',
                    }}
                  >
                    <div style={{ fontSize: 11, color: 'var(--text2)', lineHeight: 1.5 }}>
                      {hiddenSelectedOperations.length} selected operation(s) are hidden by the current filter. Preview and apply still include them until you scope the selection down.
                    </div>
                    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                      <button
                        onClick={() => setOperationSelection(visibleSelectedOperations)}
                        disabled={visibleSelectedOperations.length === 0}
                        style={{
                          padding: '6px 10px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'var(--surface)',
                          color: 'var(--text)',
                          fontSize: 11,
                          fontWeight: 600,
                          cursor: visibleSelectedOperations.length === 0 ? 'not-allowed' : 'pointer',
                          opacity: visibleSelectedOperations.length === 0 ? 0.5 : 1,
                        }}
                      >
                        Scope to Visible
                      </button>
                      <button
                        onClick={() => setOperationQuery('')}
                        style={{
                          padding: '6px 10px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'transparent',
                          color: 'var(--text2)',
                          fontSize: 11,
                          fontWeight: 600,
                          cursor: 'pointer',
                        }}
                      >
                        Show All
                      </button>
                    </div>
                  </div>
                )}
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  <button
                    onClick={() => keepSelectedOperations((operation) => operation.status === 'pending')}
                    disabled={selectedPendingCount === 0}
                    style={{
                      padding: '4px 8px',
                      borderRadius: 999,
                      border: '1px solid var(--border)',
                      background: 'var(--surface)',
                      color: 'var(--text)',
                      fontSize: 11,
                      fontWeight: 600,
                      cursor: selectedPendingCount === 0 ? 'not-allowed' : 'pointer',
                      opacity: selectedPendingCount === 0 ? 0.5 : 1,
                    }}
                  >
                    Keep Pending
                  </button>
                  <button
                    onClick={() => keepSelectedOperations((operation) => operation.drift?.state === 'aligned')}
                    disabled={selectedAlignedCount === 0}
                    style={{
                      padding: '4px 8px',
                      borderRadius: 999,
                      border: '1px solid var(--border)',
                      background: 'var(--surface)',
                      color: 'var(--text)',
                      fontSize: 11,
                      fontWeight: 600,
                      cursor: selectedAlignedCount === 0 ? 'not-allowed' : 'pointer',
                      opacity: selectedAlignedCount === 0 ? 0.5 : 1,
                    }}
                  >
                    Keep Aligned
                  </button>
                  <button
                    onClick={() => keepSelectedOperations((operation) => operation.drift?.state === 'drifted')}
                    disabled={selectedDriftedCount === 0}
                    style={{
                      padding: '4px 8px',
                      borderRadius: 999,
                      border: '1px solid var(--border)',
                      background: 'var(--surface)',
                      color: 'var(--text)',
                      fontSize: 11,
                      fontWeight: 600,
                      cursor: selectedDriftedCount === 0 ? 'not-allowed' : 'pointer',
                      opacity: selectedDriftedCount === 0 ? 0.5 : 1,
                    }}
                  >
                    Keep Drifted
                  </button>
                  <button
                    onClick={() => keepSelectedOperations((operation) => operation.drift?.state === 'missing' || operation.status === 'pending')}
                    disabled={selectedMissingCount === 0}
                    style={{
                      padding: '4px 8px',
                      borderRadius: 999,
                      border: '1px solid var(--border)',
                      background: 'var(--surface)',
                      color: 'var(--text)',
                      fontSize: 11,
                      fontWeight: 600,
                      cursor: selectedMissingCount === 0 ? 'not-allowed' : 'pointer',
                      opacity: selectedMissingCount === 0 ? 0.5 : 1,
                    }}
                  >
                    Keep Missing
                  </button>
                </div>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {visibleSelectedOperations.map((operation) => (
                    <button
                      key={operation.id}
                      onClick={() => focusSingleOperation(operation.id)}
                      aria-label={`Focus selected ${operation.title}`}
                      style={{
                        padding: '4px 8px',
                        borderRadius: 999,
                        border: '1px solid var(--border)',
                        background: 'var(--surface)',
                        color: 'var(--text)',
                        fontSize: 11,
                        fontWeight: 600,
                        cursor: 'pointer',
                      }}
                    >
                      {operation.title}
                    </button>
                  ))}
                </div>
                {visibleSelectedOperations.length === 0 && (
                  <div style={{ fontSize: 11, color: 'var(--text2)' }}>
                    Current filter hides all selected operations. Clear the filter to inspect the full scope.
                  </div>
                )}
              </>
            ) : (
              <div style={{ fontSize: 11, color: 'var(--text2)' }}>
                No setup items selected. Choose one or more operations to preview or apply.
              </div>
            )}
          </div>

          {applyResolutionSummary && (
            <div
              style={{
                border: '1px solid var(--border)',
                borderRadius: 12,
                background: 'var(--surface2)',
                padding: 12,
                display: 'flex',
                flexDirection: 'column',
                gap: 8,
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
                <div style={{ fontSize: 12, fontWeight: 700 }}>Apply Impact</div>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  <Badge color="blue">{applyResolutionSummary.changedCount} changed</Badge>
                  {applyResolutionSummary.alignedCount > 0 && (
                    <Badge color="green">{applyResolutionSummary.alignedCount} aligned</Badge>
                  )}
                  {applyResolutionSummary.driftedCount > 0 && (
                    <Badge color="orange">{applyResolutionSummary.driftedCount} drifted</Badge>
                  )}
                  {applyResolutionSummary.missingCount > 0 && (
                    <Badge color="yellow">{applyResolutionSummary.missingCount} missing</Badge>
                  )}
                  {applyResolutionSummary.skippedCount > 0 && (
                    <Badge color="gray">{applyResolutionSummary.skippedCount} skipped</Badge>
                  )}
                  {applyResolutionSummary.errorCount > 0 && (
                    <Badge color="red">{applyResolutionSummary.errorCount} error</Badge>
                  )}
                </div>
              </div>
              <div style={{ fontSize: 11, color: 'var(--text2)' }}>
                {applyResolutionSummary.changedCount > 0
                  ? `${applyResolutionSummary.changedCount} setup item(s) changed. ${applyResolutionSummary.alignedCount} are currently aligned, ${applyResolutionSummary.driftedCount} still drifted, ${applyResolutionSummary.missingCount} still missing.`
                  : `No setup items changed. ${applyResolutionSummary.skippedCount} item(s) were skipped${applyResolutionSummary.errorCount > 0 ? ` and ${applyResolutionSummary.errorCount} error(s) remain.` : '.'}`}
              </div>
              {applyResolutionSummary.changedTitles.length > 0 && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <div>
                    <button
                      onClick={focusChangedOperations}
                      style={{
                        padding: '6px 10px',
                        borderRadius: 8,
                        border: '1px solid var(--border)',
                        background: 'var(--surface)',
                        color: 'var(--text)',
                        fontSize: 11,
                        fontWeight: 600,
                        cursor: 'pointer',
                      }}
                    >
                      Focus Changed
                    </button>
                  </div>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                    <div style={{ fontSize: 11, color: 'var(--text2)' }}>
                      Changed now: {applyResolutionSummary.changedTitles.join(', ')}
                    </div>
                    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                      {applyResolutionSummary.changedItems.map((item) => (
                        <button
                          key={item.id}
                          onClick={() => focusSingleOperation(item.id)}
                          aria-label={`Focus changed ${item.title}`}
                          style={{
                            padding: '4px 8px',
                            borderRadius: 999,
                            border: '1px solid var(--border)',
                            background: 'var(--surface)',
                            color: 'var(--text)',
                            fontSize: 11,
                            fontWeight: 600,
                            cursor: 'pointer',
                          }}
                        >
                          {item.title}
                        </button>
                      ))}
                    </div>
                  </div>
                  {applyResolutionSummary.alignedTitles.length > 0 && (
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                      <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                        <div style={{ fontSize: 11, color: 'var(--green)' }}>
                          Aligned: {applyResolutionSummary.alignedTitles.join(', ')}
                        </div>
                        <button
                          onClick={() => focusOperationGroup(applyResolutionSummary.alignedItems.map((item) => item.id))}
                          style={{
                            padding: '4px 8px',
                            borderRadius: 999,
                            border: '1px solid var(--border)',
                            background: 'var(--surface)',
                            color: 'var(--green)',
                            fontSize: 11,
                            fontWeight: 600,
                            cursor: 'pointer',
                          }}
                        >
                          Focus Aligned
                        </button>
                      </div>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                        {applyResolutionSummary.alignedItems.map((item) => (
                          <button
                            key={item.id}
                            onClick={() => focusSingleOperation(item.id)}
                            aria-label={`Focus aligned ${item.title}`}
                            style={{
                              padding: '4px 8px',
                              borderRadius: 999,
                              border: '1px solid var(--border)',
                              background: 'var(--surface)',
                              color: 'var(--text)',
                              fontSize: 11,
                              fontWeight: 600,
                              cursor: 'pointer',
                            }}
                          >
                            {item.title}
                          </button>
                        ))}
                      </div>
                    </div>
                  )}
                  {applyResolutionSummary.driftedTitles.length > 0 && (
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                      <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                        <div style={{ fontSize: 11, color: '#fd963c' }}>
                          Still drifted: {applyResolutionSummary.driftedTitles.join(', ')}
                        </div>
                        <button
                          onClick={() => focusOperationGroup(applyResolutionSummary.driftedItems.map((item) => item.id))}
                          style={{
                            padding: '4px 8px',
                            borderRadius: 999,
                            border: '1px solid var(--border)',
                            background: 'var(--surface)',
                            color: '#fd963c',
                            fontSize: 11,
                            fontWeight: 600,
                            cursor: 'pointer',
                          }}
                        >
                          Focus Drifted
                        </button>
                      </div>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                        {applyResolutionSummary.driftedItems.map((item) => (
                          <button
                            key={item.id}
                            onClick={() => focusSingleOperation(item.id)}
                            aria-label={`Focus drifted ${item.title}`}
                            style={{
                              padding: '4px 8px',
                              borderRadius: 999,
                              border: '1px solid var(--border)',
                              background: 'var(--surface)',
                              color: 'var(--text)',
                              fontSize: 11,
                              fontWeight: 600,
                              cursor: 'pointer',
                            }}
                          >
                            {item.title}
                          </button>
                        ))}
                      </div>
                    </div>
                  )}
                  {applyResolutionSummary.missingTitles.length > 0 && (
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                      <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                        <div style={{ fontSize: 11, color: 'var(--yellow)' }}>
                          Still missing: {applyResolutionSummary.missingTitles.join(', ')}
                        </div>
                        <button
                          onClick={() => focusOperationGroup(applyResolutionSummary.missingItems.map((item) => item.id))}
                          style={{
                            padding: '4px 8px',
                            borderRadius: 999,
                            border: '1px solid var(--border)',
                            background: 'var(--surface)',
                            color: 'var(--yellow)',
                            fontSize: 11,
                            fontWeight: 600,
                            cursor: 'pointer',
                          }}
                        >
                          Focus Missing
                        </button>
                      </div>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                        {applyResolutionSummary.missingItems.map((item) => (
                          <button
                            key={item.id}
                            onClick={() => focusSingleOperation(item.id)}
                            aria-label={`Focus missing ${item.title}`}
                            style={{
                              padding: '4px 8px',
                              borderRadius: 999,
                              border: '1px solid var(--border)',
                              background: 'var(--surface)',
                              color: 'var(--text)',
                              fontSize: 11,
                              fontWeight: 600,
                              cursor: 'pointer',
                            }}
                          >
                            {item.title}
                          </button>
                        ))}
                      </div>
                    </div>
                  )}
                </div>
              )}
            </div>
          )}

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, minmax(0, 1fr))', gap: 12 }}>
            {setupStatus.axes.map((axis) => {
              const selectedCount = axis.operations.filter((operation) => selectedOperationIds.includes(operation.id)).length;
              const checked = selectedCount === axis.operations.length && axis.operations.length > 0;
              const partiallySelected = selectedCount > 0 && selectedCount < axis.operations.length;
              const readyCount = axis.operations.filter((operation) => operation.status === 'ready').length;
              const pendingCount = axis.operations.length - readyCount;
              const previewAxis = planMutation.data?.axes.find((item) => item.axis === axis.axis);
              const visibleAxisOperations = axis.operations.filter(matchesOperationQuery);
              return (
                <div
                  key={axis.axis}
                  style={{
                    padding: 14,
                    borderRadius: 12,
                    border: checked ? `1px solid ${axisColor[axis.axis]}` : '1px solid var(--border)',
                    background: checked ? 'var(--surface2)' : 'var(--surface)',
                  }}
                >
                  <button
                    onClick={() => toggleAxis(axis.axis)}
                    style={{
                      textAlign: 'left',
                      background: 'transparent',
                      border: 'none',
                      padding: 0,
                      width: '100%',
                      cursor: 'pointer',
                    }}
                  >
                  <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, alignItems: 'center', marginBottom: 10 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                      <input type="checkbox" readOnly checked={checked} style={{ pointerEvents: 'none' }} />
                      <span style={{ fontSize: 13, fontWeight: 700, color: axisColor[axis.axis] }}>{axis.label}</span>
                    </div>
                    <Badge color={axis.ready ? 'green' : 'yellow'}>{axis.readiness}%</Badge>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--text2)', lineHeight: 1.5, minHeight: 54 }}>
                    {axis.summary}
                  </div>
                  <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 10, flexWrap: 'wrap' }}>
                    <span style={{ fontSize: 11, color: 'var(--text2)' }}>{pendingCount} pending</span>
                    <span style={{ fontSize: 11, color: 'var(--text2)' }}>{readyCount} ready</span>
                    <span style={{ fontSize: 11, color: partiallySelected ? axisColor[axis.axis] : 'var(--text2)' }}>
                      {selectedCount} selected
                    </span>
                  </div>
                  <div style={{ marginTop: 10, display: 'flex', flexDirection: 'column', gap: 4 }}>
                    {visibleAxisOperations.slice(0, 3).map((operation) => (
                      <div key={operation.id} style={{ fontSize: 11, color: operation.status === 'ready' ? 'var(--green)' : 'var(--text2)' }}>
                        {operation.status === 'ready' ? '✓' : '•'} {operation.title}
                      </div>
                    ))}
                    {visibleAxisOperations.length > 3 && (
                      <div style={{ fontSize: 11, color: 'var(--text2)' }}>
                        + {visibleAxisOperations.length - 3} more
                      </div>
                    )}
                    {visibleAxisOperations.length === 0 && (
                      <div style={{ fontSize: 11, color: 'var(--text2)' }}>
                        No operations match the current filter
                      </div>
                    )}
                  </div>
                  </button>
                  <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, alignItems: 'center', marginTop: 10 }}>
                    <span style={{ fontSize: 11, color: 'var(--text2)' }}>
                      {previewAxis ? 'Using current preview plan' : 'Using current setup status'}
                    </span>
                    <button
                      onClick={() => toggleExpandedAxis(axis.axis)}
                      style={{
                        padding: '4px 8px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'var(--surface)',
                        color: 'var(--text2)',
                        fontSize: 11,
                        cursor: 'pointer',
                      }}
                    >
                      {expandedAxis === axis.axis ? 'Hide Ops' : 'Show Ops'}
                    </button>
                  </div>

                  {expandedAxis === axis.axis && (
                    <div
                      style={{
                        marginTop: 10,
                        display: 'flex',
                        flexDirection: 'column',
                        gap: 6,
                        borderTop: '1px solid var(--border)',
                        paddingTop: 10,
                      }}
                    >
                      {visibleAxisOperations.length === 0 && (
                        <div style={{ fontSize: 11, color: 'var(--text2)' }}>
                          No operations match the current filter in this axis.
                        </div>
                      )}
                      {visibleAxisOperations.map((operation) => {
                        const previewOperation = previewAxis?.operations.find((item) => item.id === operation.id);
                        const effectiveOperation = previewOperation ?? operation;
                        const applyResult = findApplyResult(lastApplyResult, operation.id);
                        const operationSelected = selectedOperationIds.includes(operation.id);
                        return (
                          <div
                            key={operation.id}
                            style={{
                              padding: '8px 10px',
                              borderRadius: 8,
                              background: 'var(--surface)',
                              border: '1px solid var(--border)',
                            }}
                          >
                            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
                              <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                                <label style={{ display: 'inline-flex', alignItems: 'center', gap: 6, cursor: 'pointer' }}>
                                  <input
                                    type="checkbox"
                                    checked={operationSelected}
                                    onChange={() => toggleOperation(axis.axis, operation.id)}
                                    aria-label={`Select ${operation.title}`}
                                  />
                                  <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--text)' }}>{operation.title}</span>
                                </label>
                              </div>
                              <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                                <Badge color={operationSelected ? axisBadgeColor(axis.axis) : 'gray'}>
                                  {operationSelected ? 'selected' : 'not selected'}
                                </Badge>
                                <Badge color={operation.status === 'ready' ? 'green' : 'yellow'}>
                                  {operation.status === 'ready' ? 'ready' : operationSelected && previewAxis ? 'will apply' : 'pending'}
                                </Badge>
                                {effectiveOperation.drift && (
                                  <Badge color={effectiveOperation.drift.state === 'drifted' ? 'orange' : effectiveOperation.drift.state === 'aligned' ? 'green' : 'yellow'}>
                                    {effectiveOperation.drift.state}
                                  </Badge>
                                )}
                                {applyResult && (
                                  <Badge color={applyResult.outcome === 'error' ? 'red' : applyResult.outcome === 'skipped' ? 'gray' : 'blue'}>
                                    {applyResult.outcome}
                                  </Badge>
                                )}
                              </div>
                            </div>
                            <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 6, lineHeight: 1.5 }}>{effectiveOperation.description}</div>
                            {effectiveOperation.preview?.summary && (
                              <div style={{ fontSize: 11, color: 'var(--text)', marginTop: 6 }}>{effectiveOperation.preview.summary}</div>
                            )}
                            {effectiveOperation.preview?.diffSummary && (
                              <div style={{ fontSize: 11, color: effectiveOperation.preview.diffSummary.removals > 0 ? '#fd963c' : 'var(--text2)', marginTop: 6 }}>
                                {effectiveOperation.preview.diffSummary.summary}
                              </div>
                            )}
                            {renderDiffSamples(effectiveOperation.preview?.diffSummary)}
                            {renderComparePreview(effectiveOperation.preview?.comparePreview, effectiveOperation.drift?.state)}
                            {effectiveOperation.drift && (
                              <div style={{ fontSize: 11, color: effectiveOperation.drift.state === 'drifted' ? '#fd963c' : 'var(--text2)', marginTop: 6 }}>
                                {effectiveOperation.drift.summary}
                              </div>
                            )}
                            {effectiveOperation.path && (
                              <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 6, fontFamily: 'monospace' }}>{effectiveOperation.path}</div>
                            )}
                            {effectiveOperation.preview?.excerpt && effectiveOperation.preview.excerpt.length > 0 && (
                              <pre
                                style={{
                                  fontSize: 10,
                                  color: 'var(--text2)',
                                  background: 'var(--surface2)',
                                  border: '1px solid var(--border)',
                                  borderRadius: 6,
                                  padding: 8,
                                  marginTop: 6,
                                  whiteSpace: 'pre-wrap',
                                  wordBreak: 'break-word',
                                }}
                              >
                                {effectiveOperation.preview.excerpt.join('\n')}
                              </pre>
                            )}
                            {applyResult && (
                              <div style={{ fontSize: 11, color: 'var(--blue)', marginTop: 6 }}>{applyResult.detail}</div>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>
              );
            })}
          </div>

          {planMutation.data && (
            <div style={{ border: '1px solid var(--border)', borderRadius: 12, background: 'var(--surface2)', padding: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, alignItems: 'center', marginBottom: 10, flexWrap: 'wrap' }}>
                <strong style={{ fontSize: 13 }}>Setup Plan</strong>
                <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                  <span style={{ fontSize: 11, color: 'var(--text2)' }}>
                    {planMutation.data.totals.pending} pending, {planMutation.data.totals.ready} already ready
                  </span>
                  <button
                    onClick={() => {
                      const planOperations = planMutation.data.axes.flatMap((axis) => axis.operations);
                      setOperationSelection(planOperations);
                    }}
                    style={{
                      padding: '6px 10px',
                      borderRadius: 8,
                      border: '1px solid var(--border)',
                      background: 'var(--surface)',
                      color: 'var(--text)',
                      fontSize: 11,
                      fontWeight: 600,
                      cursor: 'pointer',
                    }}
                  >
                    Focus Plan
                  </button>
                  <button
                    onClick={() => {
                      const pendingPlanOperations = planMutation.data.axes.flatMap((axis) =>
                        axis.operations.filter((operation) => operation.status === 'pending'),
                      );
                      setOperationSelection(pendingPlanOperations);
                    }}
                    disabled={planMutation.data.totals.pending === 0}
                    style={{
                      padding: '6px 10px',
                      borderRadius: 8,
                      border: '1px solid var(--border)',
                      background: 'var(--surface)',
                      color: 'var(--text)',
                      fontSize: 11,
                      fontWeight: 600,
                      cursor: planMutation.data.totals.pending === 0 ? 'not-allowed' : 'pointer',
                      opacity: planMutation.data.totals.pending === 0 ? 0.5 : 1,
                    }}
                  >
                    Keep Pending from Plan
                  </button>
                </div>
              </div>
              <div style={{ fontSize: 12, color: 'var(--text2)', marginBottom: 12 }}>{planMutation.data.summary}</div>
              <div style={{ fontSize: 11, color: 'var(--text2)', marginBottom: 12 }}>
                {selectedOperationIds.length} selected operation(s) across {activeAxes.length} axis(es)
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                {planMutation.data.axes.map((axis) => (
                  <div key={axis.axis}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, alignItems: 'center', marginBottom: 6, flexWrap: 'wrap' }}>
                      <div style={{ fontSize: 12, fontWeight: 700, color: axisColor[axis.axis] }}>{axis.label}</div>
                      <button
                        onClick={() => setOperationSelection(axis.operations)}
                        style={{
                          padding: '4px 8px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'var(--surface)',
                          color: 'var(--text)',
                          fontSize: 11,
                          fontWeight: 600,
                          cursor: 'pointer',
                        }}
                      >
                        Focus {axis.label} Plan
                      </button>
                    </div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                      {axis.operations.map((operation) => (
                        <div
                          key={operation.id}
                          style={{
                            display: 'flex',
                            justifyContent: 'space-between',
                            gap: 10,
                            fontSize: 11,
                            color: 'var(--text2)',
                            alignItems: 'flex-start',
                            flexWrap: 'wrap',
                          }}
                        >
                          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                            <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                              <span>{operation.title}</span>
                              {selectedOperationIds.includes(operation.id) && <Badge color={axisBadgeColor(axis.axis)}>selected</Badge>}
                            </div>
                            {operation.preview?.diffSummary && (
                              <span style={{ color: operation.preview.diffSummary.removals > 0 ? '#fd963c' : 'var(--text2)' }}>
                                {operation.preview.diffSummary.summary}
                              </span>
                            )}
                            {operation.preview?.diffSummary && (
                              <span style={{ color: 'var(--text2)', fontSize: 10 }}>
                                {[...(operation.preview.diffSummary.additionsSample ?? []).map((line) => `+ ${line}`), ...(operation.preview.diffSummary.removalsSample ?? []).map((line) => `- ${line}`)].slice(0, 2).join(' | ')}
                              </span>
                            )}
                            {operation.preview?.comparePreview && operation.drift?.state !== 'aligned' && (
                              <span style={{ color: 'var(--text2)', fontSize: 10 }}>
                                baseline: {operation.preview.comparePreview.baseline[0] ?? '(missing)'} | current: {operation.preview.comparePreview.current[0] ?? '(missing)'}
                              </span>
                            )}
                          </div>
                          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                            <span>{operation.status === 'ready' ? 'already ready' : 'will apply'}</span>
                            <button
                              onClick={() => setOperationSelection([operation])}
                              aria-label={`Focus plan item ${operation.title}`}
                              style={{
                                padding: '4px 8px',
                                borderRadius: 8,
                                border: '1px solid var(--border)',
                                background: 'var(--surface)',
                                color: 'var(--text)',
                                fontSize: 11,
                                fontWeight: 600,
                                cursor: 'pointer',
                              }}
                            >
                              Focus
                            </button>
                            <button
                              onClick={() => applyMutation.mutate({ axes: [axis.axis], operationIds: [operation.id] })}
                              aria-label={`Apply plan item ${operation.title}`}
                              disabled={applyMutation.isPending}
                              style={{
                                padding: '4px 8px',
                                borderRadius: 8,
                                border: '1px solid var(--border)',
                                background: 'var(--surface)',
                                color: 'var(--text)',
                                fontSize: 11,
                                fontWeight: 600,
                                cursor: applyMutation.isPending ? 'not-allowed' : 'pointer',
                                opacity: applyMutation.isPending ? 0.6 : 1,
                              }}
                            >
                              {applyMutation.isPending ? 'Applying...' : 'Apply This'}
                            </button>
                          </div>
                        </div>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {lastApplyResult && (
            <div style={{ border: '1px solid var(--border)', borderRadius: 12, background: 'var(--surface2)', padding: 14 }}>
              <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}>Apply Result</div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                {lastApplyResult.results.map((result) => (
                  <div
                    key={result.id}
                    style={{
                      display: 'flex',
                      justifyContent: 'space-between',
                      gap: 12,
                      fontSize: 11,
                      color: 'var(--text2)',
                      alignItems: 'center',
                      flexWrap: 'wrap',
                    }}
                  >
                    <span>
                      <strong style={{ color: axisColor[result.axis] }}>{result.axis.toUpperCase()}</strong> {result.title}
                    </span>
                    <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                      <span>{result.outcome}</span>
                      <button
                        onClick={() => focusSingleOperation(result.id)}
                        aria-label={`Focus apply result ${result.title}`}
                        style={{
                          padding: '4px 8px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'var(--surface)',
                          color: 'var(--text)',
                          fontSize: 11,
                          fontWeight: 600,
                          cursor: 'pointer',
                        }}
                      >
                        Focus in Setup
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      ) : null}
    </SectionCard>
  );
}

// ─── Feature 3: Inline Task Input + Log Panel ─────────────────────────────────

function TaskInputBar({
  projectId,
  workflowTemplates,
}: {
  projectId: string;
  workflowTemplates: WorkflowTaskTemplate[];
}) {
  const [input, setInput] = useState('');
  const [description, setDescription] = useState('');
  const [selectedTemplateId, setSelectedTemplateId] = useState<string | null>(null);
  const [descriptionOpen, setDescriptionOpen] = useState(false);
  const [running, setRunning] = useState(false);
  const [logs, setLogs] = useState<string[]>([]);
  const [logOpen, setLogOpen] = useState(false);
  const [exitCode, setExitCode] = useState<number | null>(null);
  const logRef = useRef<HTMLDivElement>(null);
  const esRef = useRef<EventSource | null>(null);
  const selectedTemplate = workflowTemplates.find((template) => template.id === selectedTemplateId) ?? null;

  useEffect(() => {
    if (logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight;
    }
  }, [logs]);

  useEffect(() => {
    return () => {
      esRef.current?.close();
    };
  }, []);

  const run = async () => {
    if (!input.trim() || running) return;
    setRunning(true);
    setLogs([]);
    setExitCode(null);
    setLogOpen(true);

    try {
      const task = await api.post<Task>('/tasks', {
        projectId,
        title: input.trim(),
        description: description.trim() || undefined,
        metadata: selectedTemplate
          ? {
              workflow: {
                id: selectedTemplate.id,
                name: selectedTemplate.name,
                summary: selectedTemplate.summary,
                source: 'gear' as const,
                separationMode: selectedTemplate.separationMode,
                phases: selectedTemplate.phases.map((phase, index) => ({
                  ...phase,
                  status: index === 0 ? 'in_progress' : 'pending',
                })),
                checklist: selectedTemplate.checklist,
                phaseChecklistMap: selectedTemplate.phaseChecklistMap,
              },
            }
          : undefined,
      });
      const runResult = await api.post<TaskRun>(`/tasks/${task.id}/run`, {});

      const es = new EventSource(`/api/tasks/runs/${runResult.id}/stream`);
      esRef.current = es;

      es.onmessage = (e) => {
        try {
          const data = JSON.parse(e.data);
          if (data.type === 'log') {
            setLogs((prev) => [...prev, data.message]);
          } else if (data.type === 'done') {
            setExitCode(data.exitCode ?? 0);
            setRunning(false);
            es.close();
          }
        } catch {
          setLogs((prev) => [...prev, e.data]);
        }
      };

      es.onerror = () => {
        setExitCode(1);
        setRunning(false);
        es.close();
      };

      setInput('');
      setDescription('');
      setSelectedTemplateId(null);
      setDescriptionOpen(false);
    } catch {
      setLogs(['실행 중 오류가 발생했습니다.']);
      setExitCode(1);
      setRunning(false);
    }
  };

  const applyWorkflowTemplate = (template: WorkflowTaskTemplate) => {
    setSelectedTemplateId(template.id);
    setInput((prev) => prev.trim().length > 0 ? prev : template.titleSuggestion);
    setDescription(template.descriptionLines.join('\n'));
    setDescriptionOpen(true);
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') run();
  };

  return (
    <div
      style={{
        position: 'sticky',
        bottom: 0,
        background: 'var(--surface)',
        borderTop: '1px solid var(--border)',
        zIndex: 50,
      }}
    >
      {logOpen ? (
        <div
          ref={logRef}
          style={{
            height: 300,
            overflowY: 'auto',
            background: '#1a1a2e',
            color: '#e0e0e0',
            fontFamily: 'monospace',
            fontSize: 12,
            padding: '10px 14px',
            borderTop: '1px solid var(--border)',
          }}
        >
          {logs.map((line, index) => (
            <div key={`${index}-${line}`} style={{ lineHeight: 1.6 }}>
              {line}
            </div>
          ))}
          {exitCode !== null ? (
            <div
              style={{
                marginTop: 8,
                fontWeight: 600,
                color: exitCode === 0 ? '#00cec9' : '#ff6b6b',
              }}
            >
              {exitCode === 0 ? '완료 (exit code: 0)' : `실패 (exit code: ${exitCode})`}
            </div>
          ) : null}
        </div>
      ) : null}

      <div
        style={{
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
          padding: '12px 18px',
        }}
      >
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <span style={{ fontSize: 11, color: 'var(--text2)' }}>Workflow template</span>
          {workflowTemplates.map((template) => {
            const active = template.id === selectedTemplateId;

            return (
              <button
                key={template.id}
                onClick={() => applyWorkflowTemplate(template)}
                disabled={running}
                style={{
                  padding: '5px 10px',
                  borderRadius: 999,
                  border: active ? '1px solid var(--accent)' : '1px solid var(--border)',
                  background: active ? 'rgba(116,185,255,0.12)' : 'var(--surface2)',
                  color: active ? 'var(--text)' : 'var(--text2)',
                  fontSize: 11,
                  fontWeight: 600,
                  cursor: running ? 'not-allowed' : 'pointer',
                  opacity: running ? 0.6 : 1,
                }}
              >
                {template.name}
              </button>
            );
          })}
          {selectedTemplate ? (
            <button
              onClick={() => {
                setSelectedTemplateId(null);
                setDescription('');
                setDescriptionOpen(false);
              }}
              disabled={running}
              style={{
                padding: '5px 10px',
                borderRadius: 999,
                border: '1px solid var(--border)',
                background: 'transparent',
                color: 'var(--text2)',
                fontSize: 11,
                fontWeight: 600,
                cursor: running ? 'not-allowed' : 'pointer',
                opacity: running ? 0.6 : 1,
              }}
            >
              Clear Template
            </button>
          ) : null}
        </div>

        {selectedTemplate ? (
          <div
            style={{
              border: '1px solid var(--border)',
              borderRadius: 10,
              background: 'var(--surface2)',
              padding: 12,
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              <div>
                <div style={{ fontSize: 12, fontWeight: 700 }}>{selectedTemplate.name}</div>
                <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 2 }}>{selectedTemplate.summary}</div>
              </div>
              {selectedTemplate.separationNote ? (
                <span
                  style={{
                    padding: '2px 8px',
                    borderRadius: 999,
                    background: 'rgba(253,203,110,0.12)',
                    color: 'var(--yellow)',
                    fontSize: 10,
                    fontWeight: 700,
                  }}
                >
                  {selectedTemplate.separationNote}
                </span>
              ) : null}
            </div>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {selectedTemplate.phases.map((phase) => (
                <span
                  key={phase.id}
                  style={{
                    padding: '3px 8px',
                    borderRadius: 999,
                    background: 'var(--surface3)',
                    color: 'var(--text2)',
                    fontSize: 10,
                    fontWeight: 700,
                  }}
                >
                  {phase.label}
                </span>
              ))}
            </div>
            {selectedTemplate.checklist.length > 0 ? (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--text2)' }}>Task Checklist</div>
                {selectedTemplate.phases.map((phase) => {
                  const items = (selectedTemplate.phaseChecklistMap?.[phase.id] ?? []).map(normalizeChecklistEntry);
                  if (!items.length) return null;
                  return (
                    <div key={`template-checklist-${phase.id}`} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                      <div style={{ fontSize: 10, color: 'var(--text2)' }}>{phase.label}</div>
                      {items.map((item) => (
                        <div key={`${phase.id}-${item.id}`} style={{ fontSize: 11, color: 'var(--text2)' }}>
                          - {item.label} ({item.kind})
                        </div>
                      ))}
                    </div>
                  );
                })}
              </div>
            ) : null}
          </div>
        ) : null}

        {descriptionOpen ? (
          <textarea
            value={description}
            onChange={(event) => setDescription(event.target.value)}
            disabled={running}
            aria-label="Task description"
            placeholder="Task description"
            style={{
              width: '100%',
              minHeight: 110,
              fontSize: 12,
              fontFamily: 'monospace',
              background: 'var(--surface2)',
              border: '1px solid var(--border)',
              borderRadius: 8,
              padding: 12,
              color: 'var(--text)',
              resize: 'vertical',
              boxSizing: 'border-box',
              opacity: running ? 0.6 : 1,
            }}
          />
        ) : null}

        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            width: '100%',
          }}
        >
          <input
            value={input}
            onChange={(event) => setInput(event.target.value)}
            onKeyDown={handleKeyDown}
            disabled={running}
            placeholder="에이전트에게 지시..."
            style={{
              flex: 1,
              padding: '9px 14px',
              borderRadius: 8,
              border: '1px solid var(--border)',
              background: 'var(--surface2)',
              color: 'var(--text)',
              fontSize: 13,
              outline: 'none',
              opacity: running ? 0.6 : 1,
            }}
          />
          {!descriptionOpen ? (
            <button
              onClick={() => setDescriptionOpen(true)}
              disabled={running}
              style={{
                padding: '9px 12px',
                borderRadius: 8,
                border: '1px solid var(--border)',
                background: 'var(--surface2)',
                color: 'var(--text2)',
                fontSize: 12,
                cursor: running ? 'not-allowed' : 'pointer',
                opacity: running ? 0.6 : 1,
              }}
            >
              Description
            </button>
          ) : null}
          <button
            onClick={run}
            disabled={running || !input.trim()}
            style={{
              padding: '9px 18px',
              borderRadius: 8,
              border: 'none',
              background: running || !input.trim() ? 'var(--surface3)' : 'var(--accent)',
              color: '#fff',
              fontSize: 13,
              fontWeight: 600,
              cursor: running || !input.trim() ? 'not-allowed' : 'pointer',
            }}
          >
            {running ? '실행 중...' : '실행'}
          </button>
          {logs.length > 0 ? (
            <button
              onClick={() => setLogOpen((value) => !value)}
              style={{
                padding: '9px 12px',
                borderRadius: 8,
                border: '1px solid var(--border)',
                background: 'var(--surface2)',
                color: 'var(--text2)',
                fontSize: 12,
                cursor: 'pointer',
              }}
            >
              {logOpen ? '접기' : '로그'}
            </button>
          ) : null}
        </div>
      </div>
    </div>
  );
}

// ─── Main Component ───────────────────────────────────────────────────────────

export function ProjectDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const [claudeMdExpanded, setClaudeMdExpanded] = useState(false);
  const [claudeMdEditing, setClaudeMdEditing] = useState(false);
  const [claudeMdDraft, setClaudeMdDraft] = useState('');
  const [expandedDoc, setExpandedDoc] = useState<string | null>(null);
  const [editingDoc, setEditingDoc] = useState<string | null>(null);
  const [docDraft, setDocDraft] = useState('');
  const [docContents, setDocContents] = useState<Record<string, string>>({});
  const [addingDoc, setAddingDoc] = useState(false);
  const [newDocName, setNewDocName] = useState('');
  const [newDocContent, setNewDocContent] = useState('');
  const [lastApplyResult, setLastApplyResult] = useState<ProjectSetupApplyResult | null>(null);
  const [expandedTimelineTaskIds, setExpandedTimelineTaskIds] = useState<Record<string, boolean | undefined>>({});
  const [drawerTimelineTaskIds, setDrawerTimelineTaskIds] = useState<Record<string, boolean | undefined>>({});
  const [selectedTimelineEventIds, setSelectedTimelineEventIds] = useState<Record<string, string | undefined>>({});
  const [timelineHistoryEventIds, setTimelineHistoryEventIds] = useState<Record<string, string[] | undefined>>({});
  const [retrySourceTimelineEventIds, setRetrySourceTimelineEventIds] = useState<Record<string, string | undefined>>({});
  const [supersededTimelineEventIds, setSupersededTimelineEventIds] = useState<Record<string, string[] | undefined>>({});
  const [replacementTimelineEventIds, setReplacementTimelineEventIds] = useState<Record<string, string | undefined>>({});
  const [timelineLogsByEventId, setTimelineLogsByEventId] = useState<Record<string, string[] | undefined>>({});
  const [timelineDoneByEventId, setTimelineDoneByEventId] = useState<Record<string, { exitCode: number | null; timedOut: boolean } | undefined>>({});
  const [loadingTimelineEventId, setLoadingTimelineEventId] = useState<string | null>(null);
  const [pendingRetryTailTaskId, setPendingRetryTailTaskId] = useState<string | null>(null);
  const [retryingTaskIds, setRetryingTaskIds] = useState<Record<string, boolean>>({});
  const [phaseBlockByTaskId, setPhaseBlockByTaskId] = useState<Record<string, TaskPhaseBlockInfo | undefined>>({});
  const [focusedChecklistItemByTaskId, setFocusedChecklistItemByTaskId] = useState<Record<string, string | undefined>>({});
  const [handoffReadyByTaskId, setHandoffReadyByTaskId] = useState<Record<string, boolean | undefined>>({});
  const [recoveredWorkflowByTaskId, setRecoveredWorkflowByTaskId] = useState<Record<string, TaskWorkflow | undefined>>({});
  const [handoffRetryStateByTaskId, setHandoffRetryStateByTaskId] = useState<Record<string, TaskHandoffRetryState | undefined>>({});
  const [newGoalTitle, setNewGoalTitle] = useState('');
  const [newGoalDescription, setNewGoalDescription] = useState('');
  const [newGoalParentId, setNewGoalParentId] = useState('');
  const [automationDraft, setAutomationDraft] = useState({
    name: 'Project Goal Automation',
    description: '',
    status: 'paused' as 'active' | 'paused',
    heartbeatMinutes: 2,
    developerAgentId: '',
    reviewerAgentId: '',
    verifierAgentId: '',
  });
  const [lastAutomationRun, setLastAutomationRun] = useState<ProjectAutomationRunResult | null>(null);
  const [, setExecutionEvidenceClock] = useState(() => Date.now());
  const timelineStreamRefs = useRef<Record<string, EventSource | undefined>>({});
  const [setupFocusRequest, setSetupFocusRequest] = useState<{ operationIds: string[]; token: number } | undefined>(undefined);

  useEffect(() => {
    return () => {
      Object.values(timelineStreamRefs.current).forEach((stream) => stream?.close());
      timelineStreamRefs.current = {};
    };
  }, []);

  useEffect(() => {
    const timer = setInterval(() => {
      setExecutionEvidenceClock(Date.now());
    }, 15_000);
    return () => {
      clearInterval(timer);
    };
  }, []);

  // ── Mutations ──────────────────────────────────────────────────────────────

  const updateClaudeMd = useMutation({
    mutationFn: (content: string) => api.patch(`/projects/${id}/setup/claudemd`, { content }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
      queryClient.invalidateQueries({ queryKey: ['project-setup-status', id] });
      setClaudeMdEditing(false);
    },
  });
  const deleteClaudeMd = useMutation({
    mutationFn: () => api.delete(`/projects/${id}/setup/claudemd`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
      queryClient.invalidateQueries({ queryKey: ['project-setup-status', id] });
    },
  });
  const deleteHooks = useMutation({
    mutationFn: () => api.delete(`/projects/${id}/setup/hooks`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
      queryClient.invalidateQueries({ queryKey: ['project-setup-status', id] });
    },
  });
  const updateDoc = useMutation({
    mutationFn: ({ name, content }: { name: string; content: string }) =>
      api.put(`/projects/${id}/docs/${name}`, { content }),
    onSuccess: (_data, { name, content }) => {
      setDocContents((prev) => ({ ...prev, [name]: content }));
      setEditingDoc(null);
      queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
      queryClient.invalidateQueries({ queryKey: ['project-setup-status', id] });
    },
  });
  const addDoc = useMutation({
    mutationFn: async ({ name, content }: { name: string; content: string }) => {
      await api.put(`/projects/${id}/docs/${name}`, { content });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
      queryClient.invalidateQueries({ queryKey: ['project-setup-status', id] });
      setAddingDoc(false);
      setNewDocName('');
      setNewDocContent('');
    },
  });
  const deleteDoc = useMutation({
    mutationFn: (name: string) => api.delete(`/projects/${id}/docs/${name}`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['project-analysis'] });
      queryClient.invalidateQueries({ queryKey: ['project-setup-status', id] });
    },
  });
  const applySetupAxis = useMutation({
    mutationFn: ({ axes, operationIds, force = false }: ProjectSetupRequest) =>
      api.post<ProjectSetupApplyResult>(`/projects/${id}/setup/apply`, { axes, operationIds, force }),
    onSuccess: (result) => {
      setLastApplyResult(result);
      queryClient.invalidateQueries({ queryKey: ['project-analysis', id] });
      queryClient.invalidateQueries({ queryKey: ['project-setup-status', id] });
      queryClient.invalidateQueries({ queryKey: ['db-conventions', id] });
    },
  });
  const createGoalMutation = useMutation({
    mutationFn: (payload: { title: string; description?: string; parentGoalId?: string | null; status?: Goal['status'] }) =>
      api.post<Goal>(`/projects/${id}/goals`, payload),
    onSuccess: () => {
      setNewGoalTitle('');
      setNewGoalDescription('');
      setNewGoalParentId('');
      queryClient.invalidateQueries({ queryKey: ['project-goals', id] });
    },
  });
  const updateGoalMutation = useMutation({
    mutationFn: ({ goalId, payload }: { goalId: string; payload: Partial<Pick<Goal, 'status' | 'title' | 'description' | 'parentGoalId'>> }) =>
      api.patch<Goal>(`/projects/${id}/goals/${goalId}`, payload),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['project-goals', id] });
    },
  });
  const saveAutomationMutation = useMutation({
    mutationFn: () => api.put<ProjectAutomationRoutine>(`/projects/${id}/automation`, {
      name: automationDraft.name,
      description: automationDraft.description || undefined,
      status: automationDraft.status,
      heartbeatMinutes: Number(automationDraft.heartbeatMinutes),
      developerAgentId: automationDraft.developerAgentId || null,
      reviewerAgentId: automationDraft.reviewerAgentId || null,
      verifierAgentId: automationDraft.verifierAgentId || null,
    }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['project-automation', id] });
    },
  });
  const runAutomationMutation = useMutation({
    mutationFn: () => api.post<ProjectAutomationRunResult>(`/projects/${id}/automation/run`, {}),
    onSuccess: (result) => {
      setLastAutomationRun(result);
      queryClient.invalidateQueries({ queryKey: ['project-goals', id] });
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
      queryClient.invalidateQueries({ queryKey: ['activity', id, 'task-outcomes'] });
    },
  });

  // ── Queries ────────────────────────────────────────────────────────────────

  const { data: project, isLoading } = useQuery({
    queryKey: ['project', id],
    queryFn: () => api.get<Project>(`/projects/${id}`),
    enabled: !!id,
  });

  const {
    data: projectGoals = [],
    isLoading: projectGoalsLoading,
    isError: projectGoalsFailed,
    error: projectGoalsError,
  } = useQuery({
    queryKey: ['project-goals', id],
    queryFn: () => api.get<Goal[]>(`/projects/${id}/goals`),
    enabled: !!id,
  });

  const {
    data: automationRoutine,
    isLoading: automationRoutineLoading,
    isError: automationRoutineFailed,
    error: automationRoutineError,
  } = useQuery({
    queryKey: ['project-automation', id],
    queryFn: () => api.get<ProjectAutomationRoutine | null>(`/projects/${id}/automation`),
    enabled: !!id,
  });

  const { data: analysis, isLoading: analysisLoading } = useQuery({
    queryKey: ['project-analysis', id, project?.path],
    queryFn: () => api.post<ProjectAnalysis>('/projects/analyze', { path: project!.path }),
    enabled: !!project?.path,
  });
  const { data: setupStatus, isLoading: setupStatusLoading } = useQuery({
    queryKey: ['project-setup-status', id],
    queryFn: () => api.get<ProjectSetupStatus>(`/projects/${id}/setup/status`),
    enabled: !!id && !!project?.path,
  });

  const { data: allAgents } = useQuery({
    queryKey: ['agents'],
    queryFn: () => api.get<Agent[]>('/agents'),
  });

  useEffect(() => {
    const projectAgents = (allAgents ?? []).filter((agent) => agent.projectId === id);
    const defaults = pickDefaultAutomationAgents(projectAgents);
    if (automationRoutine) {
      setAutomationDraft({
        name: automationRoutine.name,
        description: automationRoutine.description ?? '',
        status: automationRoutine.status,
        heartbeatMinutes: automationRoutine.heartbeatMinutes,
        developerAgentId: automationRoutine.developerAgentId ?? '',
        reviewerAgentId: automationRoutine.reviewerAgentId ?? '',
        verifierAgentId: automationRoutine.verifierAgentId ?? '',
      });
      return;
    }

    setAutomationDraft((current) => ({
      ...current,
      developerAgentId: current.developerAgentId || defaults.developerAgentId,
      reviewerAgentId: current.reviewerAgentId || defaults.reviewerAgentId,
      verifierAgentId: current.verifierAgentId || defaults.verifierAgentId,
    }));
  }, [allAgents, automationRoutine, id]);

  const { data: allTasks } = useQuery({
    queryKey: ['tasks'],
    queryFn: () => api.get<Task[]>('/tasks'),
  });

  const { data: projectActivity = [] } = useQuery({
    queryKey: ['activity', id, 'task-outcomes'],
    queryFn: () => api.get<ActivityEvent[]>(`/activity?projectId=${id}&limit=100`),
    enabled: !!id,
    refetchInterval: 15_000,
    refetchIntervalInBackground: true,
  });

  const { data: costsByProject } = useQuery({
    queryKey: ['costs-by-project'],
    queryFn: () => api.get<CostByProject[]>('/costs/by-project'),
  });

  const { data: relations } = useQuery({
    queryKey: ['relations', id],
    queryFn: () => api.get<Relation[]>(`/relations/${id}`),
    enabled: !!id,
  });

  const advanceTaskPhase = useMutation({
    mutationFn: async (task: Task) => {
      const workflow = task.metadata?.workflow;
      if (!workflow) return null;

      const next = advanceWorkflow(workflow);
      return api.patch<Task>(`/tasks/${task.id}`, {
        status: next.status,
        metadata: {
          workflow: next.workflow,
        },
      });
    },
    onSuccess: (_data, task) => {
      setPhaseBlockByTaskId((current) => ({ ...current, [task.id]: undefined }));
      setHandoffReadyByTaskId((current) => ({ ...current, [task.id]: undefined }));
      setRecoveredWorkflowByTaskId((current) => ({ ...current, [task.id]: undefined }));
      setHandoffRetryStateByTaskId((current) => {
        const retryState = current[task.id];
        if (!retryState) return current;
        return {
          ...current,
          [task.id]: {
            ...retryState,
            status: 'started',
          },
        };
      });
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
    },
    onError: (error, task) => {
      const block = parseTaskPhaseBlockInfo(error);
      if (!block) return;
      setPhaseBlockByTaskId((current) => ({ ...current, [task.id]: block }));
      setFocusedChecklistItemByTaskId((current) => ({ ...current, [task.id]: block.requiredItems[0]?.id }));
      setHandoffReadyByTaskId((current) => ({ ...current, [task.id]: undefined }));
      setRecoveredWorkflowByTaskId((current) => ({ ...current, [task.id]: undefined }));
      setHandoffRetryStateByTaskId((current) => {
        const retryState = current[task.id];
        if (!retryState) return current;
        return {
          ...current,
          [task.id]: {
            ...retryState,
            status: 'blocked',
          },
        };
      });
      setDrawerTimelineTaskIds((current) => ({ ...current, [task.id]: true }));
    },
  });

  const transitionTaskPhase = useMutation({
    mutationFn: async ({ task, mode }: { task: Task; mode: 'review' | 'block' | 'resume' }) => {
      const workflow = task.metadata?.workflow;
      if (!workflow) return null;
      const reviewer = mode === 'review' ? pickReviewerAgent(allAgents ?? [], task) : null;

      const next =
        mode === 'review'
          ? sendWorkflowToReview(workflow)
          : mode === 'block'
            ? blockWorkflow(workflow)
            : resumeWorkflow(workflow);

      return api.patch<Task>(`/tasks/${task.id}`, {
        status: next.status,
        agentId: mode === 'review' ? reviewer?.id ?? null : task.agentId ?? null,
        metadata: {
          workflow: next.workflow,
        },
      });
    },
    onSuccess: (_data, variables) => {
      setPhaseBlockByTaskId((current) => ({ ...current, [variables.task.id]: undefined }));
      setHandoffReadyByTaskId((current) => ({ ...current, [variables.task.id]: undefined }));
      setRecoveredWorkflowByTaskId((current) => ({ ...current, [variables.task.id]: undefined }));
      setHandoffRetryStateByTaskId((current) => {
        const retryState = current[variables.task.id];
        if (!retryState) return current;
        return {
          ...current,
          [variables.task.id]: {
            ...retryState,
            status: 'started',
          },
        };
      });
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
    },
    onError: (error, variables) => {
      const block = parseTaskPhaseBlockInfo(error);
      if (!block) return;
      setPhaseBlockByTaskId((current) => ({ ...current, [variables.task.id]: block }));
      setFocusedChecklistItemByTaskId((current) => ({ ...current, [variables.task.id]: block.requiredItems[0]?.id }));
      setHandoffReadyByTaskId((current) => ({ ...current, [variables.task.id]: undefined }));
      setRecoveredWorkflowByTaskId((current) => ({ ...current, [variables.task.id]: undefined }));
      setHandoffRetryStateByTaskId((current) => {
        const retryState = current[variables.task.id];
        if (!retryState) return current;
        return {
          ...current,
          [variables.task.id]: {
            ...retryState,
            status: 'blocked',
          },
        };
      });
      setDrawerTimelineTaskIds((current) => ({ ...current, [variables.task.id]: true }));
    },
  });

  const toggleChecklistMutation = useMutation({
    mutationFn: async ({ task, item }: { task: Task; item: string }) => {
      const workflow = task.metadata?.workflow;
      if (!workflow) return null;
      return api.patch<Task>(`/tasks/${task.id}`, {
        metadata: {
          workflow: toggleWorkflowChecklist(workflow, item),
        },
      });
    },
    onSuccess: (_data, variables) => {
      const wasCompleted = (variables.task.metadata?.workflow?.completedChecklist ?? []).includes(variables.item);
      const nextWorkflow = variables.task.metadata?.workflow
        ? toggleWorkflowChecklist(variables.task.metadata.workflow, variables.item)
        : undefined;
      setPhaseBlockByTaskId((current) => {
        const block = current[variables.task.id];
        if (!block || wasCompleted) return { ...current, [variables.task.id]: undefined };
        const remainingItems = block.requiredItems.filter((item) => item.id !== variables.item);
        return {
          ...current,
          [variables.task.id]: remainingItems.length > 0 ? { ...block, requiredItems: remainingItems } : undefined,
        };
      });
      setFocusedChecklistItemByTaskId((current) => ({ ...current, [variables.task.id]: wasCompleted ? undefined : variables.item }));
      setHandoffReadyByTaskId((current) => {
        const block = phaseBlockByTaskId[variables.task.id];
        if (wasCompleted || !block) return { ...current, [variables.task.id]: undefined };
        return { ...current, [variables.task.id]: block.requiredItems.length === 1 ? true : undefined };
      });
      setRecoveredWorkflowByTaskId((current) => {
        const block = phaseBlockByTaskId[variables.task.id];
        if (wasCompleted || !block || block.requiredItems.length !== 1 || !nextWorkflow) {
          return { ...current, [variables.task.id]: undefined };
        }
        return { ...current, [variables.task.id]: nextWorkflow };
      });
      setHandoffRetryStateByTaskId((current) => ({ ...current, [variables.task.id]: undefined }));
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
      queryClient.invalidateQueries({ queryKey: ['activity', id, 'task-outcomes'] });
    },
  });

  const runReviewMutation = useMutation({
    mutationFn: async (task: Task) => {
      if (!task.agentId) return null;
      return api.post(`/tasks/${task.id}/run`, { agentId: task.agentId });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
      queryClient.invalidateQueries({ queryKey: ['agents'] });
    },
  });

  const retryBlockedReviewMutation = useMutation({
    mutationFn: async (task: Task) => {
      const workflow = task.metadata?.workflow;
      if (!workflow) return null;
      const reviewer = pickReviewerAgent(allAgents ?? [], task);
      if (!reviewer) return null;
      const resumed = resumeWorkflow(workflow);
      await api.patch<Task>(`/tasks/${task.id}`, {
        status: resumed.status,
        agentId: reviewer.id,
        metadata: {
          workflow: resumed.workflow,
        },
      });
      await api.post(`/tasks/${task.id}/run`, { agentId: reviewer.id });
      return { taskId: task.id };
    },
    onSuccess: (result) => {
      if (result?.taskId) {
        setPendingRetryTailTaskId(result.taskId);
      }
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
      queryClient.invalidateQueries({ queryKey: ['agents'] });
      queryClient.invalidateQueries({ queryKey: ['activity', id, 'task-outcomes'] });
    },
  });

  const openTimelineTail = (entry: ActivityEvent) => {
    const detail = getTaskTimelineDetail(entry);
    if (!detail.runId) return;

    timelineStreamRefs.current[entry.id]?.close();
    setTimelineLogsByEventId((current) => ({ ...current, [entry.id]: [] }));
    setTimelineDoneByEventId((current) => ({ ...current, [entry.id]: undefined }));
    setLoadingTimelineEventId(entry.id);

    const es = new EventSource(`/api/tasks/runs/${detail.runId}/stream`);
    timelineStreamRefs.current[entry.id] = es;

    const appendLog = (line: string) => {
      setTimelineLogsByEventId((current) => ({
        ...current,
        [entry.id]: [...(current[entry.id] ?? []), line],
      }));
    };

    const onLogPayload = (payload: { line?: string; stream?: string; chunk?: string }) => {
      if (payload.line) {
        appendLog(payload.line);
        return;
      }
      if (payload.chunk) {
        appendLog(`[${payload.stream ?? 'stdout'}] ${payload.chunk}`.trimEnd());
      }
    };

    const handleLogEvent = (event: MessageEvent<string>) => {
      try {
        onLogPayload(JSON.parse(event.data) as { line?: string; stream?: string; chunk?: string });
      } catch {
        appendLog(event.data);
      }
    };

    const handleDone = (event?: Event) => {
      const messageEvent = event as MessageEvent<string> | undefined;
      if (messageEvent?.data) {
        try {
          const payload = JSON.parse(messageEvent.data) as { exitCode: number | null; timedOut: boolean };
          setTimelineDoneByEventId((current) => ({ ...current, [entry.id]: payload }));
        } catch {
          setTimelineDoneByEventId((current) => ({ ...current, [entry.id]: { exitCode: null, timedOut: false } }));
        }
      } else {
        setTimelineDoneByEventId((current) => ({ ...current, [entry.id]: { exitCode: null, timedOut: false } }));
      }
      setLoadingTimelineEventId((current) => (current === entry.id ? null : current));
      timelineStreamRefs.current[entry.id]?.close();
      delete timelineStreamRefs.current[entry.id];
    };

    es.onmessage = handleLogEvent;
    es.onerror = handleDone;
    if ('addEventListener' in es) {
      es.addEventListener('log', handleLogEvent as EventListener);
      es.addEventListener('done', handleDone as EventListener);
    }
    setLoadingTimelineEventId(null);
  };

  useEffect(() => {
    if (!pendingRetryTailTaskId) return;
    const retryEvent = projectActivity.find((entry) => (
      entry.detail.taskId === pendingRetryTailTaskId
      && entry.eventType === 'task.started'
      && isReviewTimelineEntry(entry)
    ));
    if (!retryEvent) return;
    const previousEventId = retrySourceTimelineEventIds[pendingRetryTailTaskId] ?? selectedTimelineEventIds[pendingRetryTailTaskId];
    if (previousEventId && previousEventId !== retryEvent.id) {
      setTimelineHistoryEventIds((current) => ({
        ...current,
        [pendingRetryTailTaskId]: [previousEventId, ...(current[pendingRetryTailTaskId] ?? [])]
          .filter((eventId, index, list) => eventId !== retryEvent.id && list.indexOf(eventId) === index)
          .slice(0, 3),
      }));
      setSupersededTimelineEventIds((current) => ({
        ...current,
        [pendingRetryTailTaskId]: [previousEventId, ...(current[pendingRetryTailTaskId] ?? [])]
          .filter((eventId, index, list) => list.indexOf(eventId) === index)
          .slice(0, 3),
      }));
      setReplacementTimelineEventIds((current) => ({
        ...current,
        [previousEventId]: retryEvent.id,
      }));
    }

    setSelectedTimelineEventIds((current) => ({
      ...current,
      [pendingRetryTailTaskId]: retryEvent.id,
    }));
    setRetrySourceTimelineEventIds((current) => ({
      ...current,
      [pendingRetryTailTaskId]: undefined,
    }));
    setRetryingTaskIds((current) => ({ ...current, [pendingRetryTailTaskId]: false }));
    openTimelineTail(retryEvent);
    setPendingRetryTailTaskId(null);
  }, [projectActivity, pendingRetryTailTaskId, retrySourceTimelineEventIds, selectedTimelineEventIds]);

  // ── Derived data ───────────────────────────────────────────────────────────

  const agents = (allAgents ?? []).filter((a) => a.projectId === id);
  const tasks = (allTasks ?? []).filter((t) => t.projectId === id).slice(0, 10);
  const projectTasks = (allTasks ?? []).filter((t) => t.projectId === id);
  const topLevelGoals = projectGoals.filter((goal) => !goal.parentGoalId);
  const cost = (costsByProject ?? []).find((c) => c.projectId === id);
  const automationDefaults = pickDefaultAutomationAgents(agents);
  const recommendedDeveloperAgent = agents.find((agent) => agent.id === automationDefaults.developerAgentId) ?? null;
  const recommendedReviewerAgent = agents.find((agent) => agent.id === automationDefaults.reviewerAgentId) ?? null;
  const recommendedVerifierAgent = agents.find((agent) => agent.id === automationDefaults.verifierAgentId) ?? null;
  const goalAutomationLoadError = [
    projectGoalsFailed ? getApiErrorMessage(projectGoalsError, 'Failed to load project goals.') : null,
    automationRoutineFailed ? getApiErrorMessage(automationRoutineError, 'Failed to load automation routine.') : null,
  ].filter((message): message is string => !!message).join(' ');
  const saveAutomationErrorMessage = saveAutomationMutation.isError
    ? getApiErrorMessage(saveAutomationMutation.error, 'Failed to save automation routine.')
    : null;
  const runAutomationErrorMessage = runAutomationMutation.isError
    ? getApiErrorMessage(runAutomationMutation.error, 'Failed to run goal check.')
    : null;
  const runAutomationErrorStatus = runAutomationMutation.isError ? getApiErrorStatus(runAutomationMutation.error) : null;
  const goalMutationErrorMessage = createGoalMutation.isError
    ? getApiErrorMessage(createGoalMutation.error, 'Failed to add goal.')
    : updateGoalMutation.isError
      ? getApiErrorMessage(updateGoalMutation.error, 'Failed to update goal.')
      : null;

  // ── Early returns ──────────────────────────────────────────────────────────

  if (isLoading) {
    return <div style={{ padding: '24px 28px', color: 'var(--text2)' }}>Loading...</div>;
  }

  if (!project) {
    return <div style={{ padding: '24px 28px', color: 'var(--text2)' }}>Project not found.</div>;
  }

  const hasPath = !!project.path;
  const guideClaudeOperation = findSetupOperation(setupStatus, 'guide-claude');
  const guardHooksOperation = findSetupOperation(setupStatus, 'guard-hooks');
  const guideContextMapOperation = findSetupOperation(setupStatus, 'guide-context-map');
  const guideConventionDocOperation = findSetupOperation(setupStatus, 'guide-convention-doc');
  const guideArchitectureDocOperation = findSetupOperation(setupStatus, 'guide-architecture-doc');
  const guideReviewDocOperation = findSetupOperation(setupStatus, 'guide-review-doc');
  const gearDeveloperAgentOperation = findSetupOperation(setupStatus, 'gear-developer-agent');
  const gearReviewerAgentOperation = findSetupOperation(setupStatus, 'gear-reviewer-agent');
  const gearWorkflowFeatureOperation = findSetupOperation(setupStatus, 'gear-workflow-feature');
  const gearWorkflowBugOperation = findSetupOperation(setupStatus, 'gear-workflow-bug');
  const gearWorkflowRefactorOperation = findSetupOperation(setupStatus, 'gear-workflow-refactor');
  const missingGuideDocs = [
    { label: 'context-map.md', operation: guideContextMapOperation },
    { label: 'convention.md', operation: guideConventionDocOperation },
    { label: 'architecture.md', operation: guideArchitectureDocOperation },
    { label: 'review.md', operation: guideReviewDocOperation },
  ].filter((item) => item.operation?.status !== 'ready');
  const missingGearAgentAssets = [
    { label: 'developer.md', operation: gearDeveloperAgentOperation },
    { label: 'reviewer.md', operation: gearReviewerAgentOperation },
  ].filter((item) => item.operation?.status !== 'ready');
  const missingGearWorkflowAssets = [
    { label: 'implement-feature.md', operation: gearWorkflowFeatureOperation },
    { label: 'fix-bug.md', operation: gearWorkflowBugOperation },
    { label: 'refactor.md', operation: gearWorkflowRefactorOperation },
  ].filter((item) => item.operation?.status !== 'ready');
  const guideDocsPanelOperation =
    missingGuideDocs.length === 0
      ? guideConventionDocOperation ?? guideContextMapOperation
      : guideContextMapOperation
        ? { ...guideContextMapOperation, status: 'pending' as const }
        : guideConventionDocOperation
          ? { ...guideConventionDocOperation, status: 'pending' as const }
          : undefined;
  const gearAgentsPanelOperation =
    missingGearAgentAssets.length === 0
      ? gearDeveloperAgentOperation ?? gearReviewerAgentOperation
      : gearDeveloperAgentOperation
        ? { ...gearDeveloperAgentOperation, status: 'pending' as const }
        : gearReviewerAgentOperation
          ? { ...gearReviewerAgentOperation, status: 'pending' as const }
          : undefined;
  const gearWorkflowsPanelOperation =
    missingGearWorkflowAssets.length === 0
      ? gearWorkflowFeatureOperation ?? gearWorkflowBugOperation ?? gearWorkflowRefactorOperation
      : gearWorkflowFeatureOperation
        ? { ...gearWorkflowFeatureOperation, status: 'pending' as const }
        : gearWorkflowBugOperation
          ? { ...gearWorkflowBugOperation, status: 'pending' as const }
          : gearWorkflowRefactorOperation
          ? { ...gearWorkflowRefactorOperation, status: 'pending' as const }
            : undefined;
  const claudeApplySummary = summarizeApplyResults(lastApplyResult, ['guide-claude']);
  const hooksApplySummary = summarizeApplyResults(lastApplyResult, ['guard-hooks', 'guard-config']);
  const guideDocsApplySummary = summarizeApplyResults(lastApplyResult, [
    'guide-context-map',
    'guide-convention-doc',
    'guide-architecture-doc',
    'guide-review-doc',
    'guide-conventions-data',
  ]);
  const gearAgentsApplySummary = summarizeApplyResults(lastApplyResult, [
    'gear-developer-agent',
    'gear-reviewer-agent',
  ]);
  const gearWorkflowsApplySummary = summarizeApplyResults(lastApplyResult, [
    'gear-workflow-feature',
    'gear-workflow-bug',
    'gear-workflow-refactor',
  ]);
  const requestSetupFocus = (operationIds: string[]) => {
    setSetupFocusRequest({ operationIds, token: Date.now() });
  };
  const managedDocOperationIds: Record<string, string> = {
    context: 'guide-context-map',
    convention: 'guide-convention-doc',
    architecture: 'guide-architecture-doc',
    review: 'guide-review-doc',
  };
  const managedAgentOperationIds: Record<string, string> = {
    developer: 'gear-developer-agent',
    reviewer: 'gear-reviewer-agent',
  };
  const managedWorkflowOperationIds: Record<string, string> = {
    'implement-feature': 'gear-workflow-feature',
    'fix-bug': 'gear-workflow-bug',
    refactor: 'gear-workflow-refactor',
  };
  const guardPanelOperationIds = ['guard-hooks', 'guard-config'];
  const claudePanelOperationIds = ['guide-claude'];
  const guideDocsPanelOperationIds = [
    'guide-context-map',
    'guide-convention-doc',
    'guide-architecture-doc',
    'guide-review-doc',
    'guide-conventions-data',
  ];
  const gearAgentPanelOperationIds = ['gear-developer-agent', 'gear-reviewer-agent'];
  const gearWorkflowPanelOperationIds = ['gear-workflow-feature', 'gear-workflow-bug', 'gear-workflow-refactor'];
  const applySetupOperations = (axis: SetupAxis, operationIds: string[], force = false) => {
    applySetupAxis.mutate({ axes: [axis], operationIds, force });
  };
  const workflowPreview = [
    {
      id: 'implement-feature',
      name: 'Implement Feature',
      steps: [
        'Read context map and convention docs.',
        'Define the target layer and interface.',
        'Implement the smallest coherent slice.',
        'Validate behavior and request review.',
      ],
    },
    {
      id: 'fix-bug',
      name: 'Fix Bug',
      steps: [
        'Reproduce the issue and isolate the failing path.',
        'Apply the smallest safe fix.',
        'Add or update a regression check.',
        'Verify adjacent flows remain stable.',
      ],
    },
    {
      id: 'refactor',
      name: 'Refactor',
      steps: [
        'Document the boundary being refactored.',
        'Keep behavior locked with tests or targeted verification.',
        'Refactor in small checkpoints.',
        'Review for architecture leaks and regressions.',
      ],
    },
  ];
  const renderGoalRow = (goal: Goal, depth = 0, ancestry: Set<string> = new Set()): React.ReactNode => {
    if (depth > MAX_GOAL_TREE_DEPTH || ancestry.has(goal.id)) {
      return (
        <div
          key={`${goal.id}-guard-${depth}`}
          style={{
            border: '1px dashed var(--border)',
            borderRadius: 10,
            background: 'var(--surface2)',
            padding: 12,
            marginLeft: Math.max(0, depth - 1) * 18,
            fontSize: 12,
            color: 'var(--text2)',
          }}
        >
          Goal tree guard prevented recursive rendering.
        </div>
      );
    }

    const nextAncestry = new Set(ancestry);
    nextAncestry.add(goal.id);
    const stageSummary = getGoalStageSummary(projectTasks, goal.id);
    const allChildGoals = projectGoals.filter((candidate) => candidate.parentGoalId === goal.id);
    const childGoals = allChildGoals.filter((candidate) => !nextAncestry.has(candidate.id));
    const hasCircularChild = childGoals.length !== allChildGoals.length;

    return (
      <div key={goal.id} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        <div
          style={{
            border: '1px solid var(--border)',
            borderRadius: 10,
            background: 'var(--surface2)',
            padding: 12,
            marginLeft: depth * 18,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6, minWidth: 0 }}>
              <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                <span style={{ fontSize: 13, fontWeight: 700 }}>{goal.title}</span>
                <Badge color={getGoalStatusColor(goal.status)}>{goal.status}</Badge>
                {allChildGoals.length > 0 ? <Badge color="gray">{allChildGoals.length} child goal{allChildGoals.length === 1 ? '' : 's'}</Badge> : null}
              </div>
              {goal.description ? (
                <div style={{ fontSize: 12, color: 'var(--text2)', lineHeight: 1.5 }}>{goal.description}</div>
              ) : null}
              {hasCircularChild ? (
                <div style={{ fontSize: 11, color: '#f59e0b' }}>
                  Circular child goal references were skipped to keep rendering stable.
                </div>
              ) : null}
            </div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              <select
                aria-label={`Goal status ${goal.title}`}
                value={goal.status}
                onChange={(event) => updateGoalMutation.mutate({ goalId: goal.id, payload: { status: event.target.value as Goal['status'] } })}
                style={{
                  padding: '6px 10px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: 'var(--surface)',
                  color: 'var(--text)',
                  fontSize: 12,
                }}
              >
                <option value="planned">planned</option>
                <option value="active">active</option>
                <option value="achieved">achieved</option>
                <option value="blocked">blocked</option>
              </select>
            </div>
          </div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 10 }}>
            {stageSummary.map((item) => (
              <Badge
                key={`${goal.id}-${item.stage}`}
                color={
                  item.status === 'done'
                    ? 'green'
                    : item.status === 'in_progress'
                      ? 'blue'
                      : item.status === 'blocked'
                        ? 'red'
                        : item.status === 'todo'
                          ? 'yellow'
                          : 'gray'
                }
              >
                {item.stage}: {item.status}
              </Badge>
            ))}
          </div>
        </div>
        {childGoals.map((childGoal) => renderGoalRow(childGoal, depth + 1, nextAncestry))}
      </div>
    );
  };
  const workflowTaskTemplates: WorkflowTaskTemplate[] = workflowPreview.map((workflow) => {
    const phaseChecklistMap: Record<string, ChecklistEntry[]> =
      workflow.id === 'implement-feature'
        ? {
            context: [{ id: 'context-map', label: 'Read context map and conventions first', kind: 'required' }],
            validate: [{ id: 'validate-user-path', label: 'Verify the user-facing path before finishing', kind: 'evidence' }],
            review: [{ id: 'review-separation', label: 'Keep review in a separate agent', kind: 'required' }],
          }
        : workflow.id === 'fix-bug'
          ? {
              reproduce: [{ id: 'repro-steps', label: 'Record reproduction steps', kind: 'required' }],
              regression: [{ id: 'regression-check', label: 'Add a regression check', kind: 'evidence' }],
              verify: [{ id: 'verify-adjacent', label: 'Verify adjacent flows remain stable', kind: 'required' }],
            }
          : {
              boundary: [{ id: 'boundary-scope', label: 'Describe the boundary before changes', kind: 'required' }],
              protect: [{ id: 'protect-behavior', label: 'Protect behavior with tests or checks', kind: 'evidence' }],
              review: [{ id: 'review-pass', label: 'Use a separate review pass before marking done', kind: 'required' }],
            };

    return {
      id: workflow.id,
      name: workflow.name,
      summary:
        workflow.id === 'implement-feature'
          ? 'Use the standard feature delivery path with context, implementation, validation, and review.'
          : workflow.id === 'fix-bug'
            ? 'Bias toward reproduction, the smallest safe fix, and regression coverage.'
            : 'Keep behavior stable while improving structure in small checkpoints.',
      titleSuggestion:
        workflow.id === 'implement-feature'
          ? 'Implement feature: '
          : workflow.id === 'fix-bug'
            ? 'Fix bug: '
            : 'Refactor: ',
      phases:
        workflow.id === 'implement-feature'
          ? [
              { id: 'context', label: 'Context', objective: 'Read project setup assets before coding.' },
              { id: 'implement', label: 'Implement', objective: 'Ship the smallest coherent slice.' },
              { id: 'validate', label: 'Validate', objective: 'Verify behavior and regression safety.' },
              { id: 'review', label: 'Review', objective: 'Request a separate review pass.', enforceSeparation: true },
            ]
          : workflow.id === 'fix-bug'
            ? [
                { id: 'reproduce', label: 'Reproduce', objective: 'Capture the failing path first.' },
                { id: 'fix', label: 'Fix', objective: 'Apply the smallest safe fix.' },
                { id: 'regression', label: 'Regression', objective: 'Add or update a regression check.' },
                { id: 'verify', label: 'Verify', objective: 'Re-check adjacent flows.' },
              ]
            : [
                { id: 'boundary', label: 'Boundary', objective: 'Document the refactor boundary.' },
                { id: 'protect', label: 'Protect', objective: 'Lock behavior with tests or checks.' },
                { id: 'refactor', label: 'Refactor', objective: 'Change the internals in small checkpoints.' },
                { id: 'review', label: 'Review', objective: 'Run architecture and regression review separately.', enforceSeparation: true },
              ],
      checklist:
        workflow.id === 'implement-feature'
          ? ['Read context map and conventions first', 'Keep review in a separate agent', 'Verify the user-facing path before finishing']
          : workflow.id === 'fix-bug'
            ? ['Record reproduction steps', 'Add a regression check', 'Verify adjacent flows remain stable']
            : ['Describe the boundary before changes', 'Protect behavior with tests or checks', 'Use a separate review pass before marking done'],
      phaseChecklistMap,
      separationMode: workflow.id === 'implement-feature' || workflow.id === 'refactor' ? 'enforced' : 'advisory',
      separationNote: workflow.id === 'implement-feature' || workflow.id === 'refactor' ? 'Review in separate agent' : undefined,
      descriptionLines: [
      `Workflow: ${workflow.name}`,
      '',
      'Phases:',
      ...(
        workflow.id === 'implement-feature'
          ? [
              '1. Context - Read project setup assets before coding.',
              '2. Implement - Ship the smallest coherent slice.',
              '3. Validate - Verify behavior and regression safety.',
              '4. Review - Request a separate review pass.',
            ]
          : workflow.id === 'fix-bug'
            ? [
                '1. Reproduce - Capture the failing path first.',
                '2. Fix - Apply the smallest safe fix.',
                '3. Regression - Add or update a regression check.',
                '4. Verify - Re-check adjacent flows.',
              ]
            : [
                '1. Boundary - Document the refactor boundary.',
                '2. Protect - Lock behavior with tests or checks.',
                '3. Refactor - Change the internals in small checkpoints.',
                '4. Review - Run architecture and regression review separately.',
              ]
      ),
      '',
      'Checklist:',
      ...(
        workflow.id === 'implement-feature'
          ? [
              '- Read context map and conventions first',
              '- Keep review in a separate agent',
              '- Verify the user-facing path before finishing',
            ]
          : workflow.id === 'fix-bug'
            ? [
                '- Record reproduction steps',
                '- Add a regression check',
                '- Verify adjacent flows remain stable',
              ]
            : [
                '- Describe the boundary before changes',
                '- Protect behavior with tests or checks',
                '- Use a separate review pass before marking done',
              ]
      ),
      '',
      ...workflow.steps.map((step, index) => `${index + 1}. ${step}`),
      ],
    };
  });

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <div style={{ padding: '24px 28px', paddingBottom: 0 }}>
      {/* 1. Header */}
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', gap: 12 }}>
        <button
          onClick={() => navigate('/projects')}
          style={{
            padding: '6px 10px',
            borderRadius: 8,
            border: '1px solid var(--border)',
            background: 'var(--surface2)',
            color: 'var(--text2)',
            fontSize: 12,
            cursor: 'pointer',
          }}
        >
          ← Back
        </button>
        <div
          style={{
            width: 36,
            height: 36,
            background: 'var(--surface3)',
            borderRadius: 8,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 18,
          }}
        >
          📦
        </div>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>{project.name}</h1>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>

        {id && (
          <SetupCenter
            projectId={id}
            hasPath={hasPath}
            setupStatus={setupStatus}
            isLoading={setupStatusLoading}
            analysis={analysis}
            lastApplyResult={lastApplyResult}
            onApplySuccess={setLastApplyResult}
            onOpenSettings={() => navigate('/settings')}
            focusRequest={setupFocusRequest}
          />
        )}

        {/* 3 + 4. 프로젝트 개요 (with Score Panel) */}
        <SectionCard title="프로젝트 개요">
          {/* Feature 1: Guard/Guide/Gear scores at the top */}
          {analysis?.scores && <ScorePanel scores={analysis.scores} />}

          <InfoRow label="Name" value={project.name} />
          <InfoRow label="Path" value={project.path} />
          <InfoRow label="Git URL" value={project.gitUrl} />
          <InfoRow label="Description" value={project.description} />
          <InfoRow label="Created" value={new Date(project.createdAt).toLocaleDateString()} />

          {hasPath && (
            <div style={{ marginTop: 12 }}>
              {analysisLoading ? (
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  <SkeletonBlock width={60} height={22} />
                  <SkeletonBlock width={80} height={22} />
                  <SkeletonBlock width={50} height={22} />
                </div>
              ) : analysis ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                  {analysis.techStack.length > 0 && (
                    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
                      <span style={{ fontSize: 11, color: 'var(--text2)', width: 60 }}>스택</span>
                      {analysis.techStack.map((t) => (
                        <Badge key={t} color="blue">{t}</Badge>
                      ))}
                    </div>
                  )}
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span style={{ fontSize: 11, color: 'var(--text2)', width: 60 }}>Git</span>
                    {analysis.git.isRepo ? (
                      <Badge color="green">✓ {analysis.git.branch ?? 'repo'}</Badge>
                    ) : (
                      <Badge color="gray">not a repo</Badge>
                    )}
                  </div>
                </div>
              ) : null}
            </div>
          )}
        </SectionCard>

        <SectionCard title="Goal Automation Center">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div
              style={{
                border: '1px solid var(--border)',
                borderRadius: 10,
                background: 'var(--surface2)',
                padding: 12,
                display: 'flex',
                flexDirection: 'column',
                gap: 12,
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', alignItems: 'center' }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <div style={{ fontSize: 13, fontWeight: 700 }}>Paperclip-style project loop</div>
                  <div style={{ fontSize: 12, color: 'var(--text2)', lineHeight: 1.5 }}>
                    Goals stay attached to this project. The automation routine checks progress, creates the next implementation/review/verify task, and keeps the project moving without manual triage.
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                  <Badge color={automationDraft.status === 'active' ? 'green' : 'gray'}>
                    {automationDraft.status === 'active' ? 'active' : 'paused'}
                  </Badge>
                  {automationRoutine?.lastEvaluatedAt ? (
                    <span style={{ fontSize: 11, color: 'var(--text2)' }}>
                      last check {relativeTime(automationRoutine.lastEvaluatedAt)}
                    </span>
                  ) : null}
                </div>
              </div>
              {(automationRoutineLoading || projectGoalsLoading) ? (
                <div style={{ fontSize: 12, color: 'var(--text2)' }}>
                  Loading goal automation settings...
                </div>
              ) : null}
              {goalAutomationLoadError ? (
                <div
                  style={{
                    border: '1px solid var(--red)',
                    borderRadius: 8,
                    background: 'rgba(255,107,107,0.08)',
                    color: 'var(--red)',
                    fontSize: 12,
                    padding: '8px 10px',
                  }}
                >
                  {goalAutomationLoadError}
                </div>
              ) : null}
              {!automationRoutineLoading && !automationRoutineFailed && !automationRoutine ? (
                <div style={{ fontSize: 12, color: 'var(--text2)' }}>
                  No saved routine yet. Review recommended agents, then save automation to activate this loop.
                </div>
              ) : null}
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 10 }}>
                <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <span style={{ fontSize: 11, color: 'var(--text2)' }}>Routine Name</span>
                  <input
                    value={automationDraft.name}
                    onChange={(event) => setAutomationDraft((current) => ({ ...current, name: event.target.value }))}
                    style={{ padding: '8px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12 }}
                  />
                </label>
                <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <span style={{ fontSize: 11, color: 'var(--text2)' }}>Heartbeat (minutes)</span>
                  <input
                    type="number"
                    min={1}
                    max={60}
                    value={automationDraft.heartbeatMinutes}
                    onChange={(event) => setAutomationDraft((current) => ({
                      ...current,
                      heartbeatMinutes: Number(event.target.value || 2),
                    }))}
                    style={{ padding: '8px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12 }}
                  />
                </label>
                <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <span style={{ fontSize: 11, color: 'var(--text2)' }}>Developer Agent</span>
                  {recommendedDeveloperAgent ? (
                    <span style={{ fontSize: 10, color: 'var(--text2)' }}>
                      Recommended: {recommendedDeveloperAgent.name}
                    </span>
                  ) : null}
                  <select
                    value={automationDraft.developerAgentId}
                    onChange={(event) => setAutomationDraft((current) => ({ ...current, developerAgentId: event.target.value }))}
                    style={{ padding: '8px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12 }}
                  >
                    <option value="">Unassigned</option>
                    {agents.map((agent) => (
                      <option key={agent.id} value={agent.id}>{agent.name}</option>
                    ))}
                  </select>
                </label>
                <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <span style={{ fontSize: 11, color: 'var(--text2)' }}>Reviewer Agent</span>
                  {recommendedReviewerAgent ? (
                    <span style={{ fontSize: 10, color: 'var(--text2)' }}>
                      Recommended: {recommendedReviewerAgent.name}
                    </span>
                  ) : null}
                  <select
                    value={automationDraft.reviewerAgentId}
                    onChange={(event) => setAutomationDraft((current) => ({ ...current, reviewerAgentId: event.target.value }))}
                    style={{ padding: '8px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12 }}
                  >
                    <option value="">Unassigned</option>
                    {agents.map((agent) => (
                      <option key={agent.id} value={agent.id}>{agent.name}</option>
                    ))}
                  </select>
                </label>
                <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <span style={{ fontSize: 11, color: 'var(--text2)' }}>Verifier Agent</span>
                  {recommendedVerifierAgent ? (
                    <span style={{ fontSize: 10, color: 'var(--text2)' }}>
                      Recommended: {recommendedVerifierAgent.name}
                    </span>
                  ) : null}
                  <select
                    value={automationDraft.verifierAgentId}
                    onChange={(event) => setAutomationDraft((current) => ({ ...current, verifierAgentId: event.target.value }))}
                    style={{ padding: '8px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12 }}
                  >
                    <option value="">Unassigned</option>
                    {agents.map((agent) => (
                      <option key={agent.id} value={agent.id}>{agent.name}</option>
                    ))}
                  </select>
                </label>
                <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <span style={{ fontSize: 11, color: 'var(--text2)' }}>Routine Status</span>
                  <select
                    value={automationDraft.status}
                    onChange={(event) => setAutomationDraft((current) => ({ ...current, status: event.target.value as 'active' | 'paused' }))}
                    style={{ padding: '8px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12 }}
                  >
                    <option value="paused">paused</option>
                    <option value="active">active</option>
                  </select>
                </label>
              </div>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <span style={{ fontSize: 11, color: 'var(--text2)' }}>Routine Description</span>
                <textarea
                  value={automationDraft.description}
                  onChange={(event) => setAutomationDraft((current) => ({ ...current, description: event.target.value }))}
                  style={{ minHeight: 84, padding: '10px 12px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12, resize: 'vertical', boxSizing: 'border-box' }}
                />
              </label>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                <button
                  onClick={() => saveAutomationMutation.mutate()}
                  disabled={saveAutomationMutation.isPending}
                  style={{
                    padding: '8px 14px',
                    borderRadius: 8,
                    border: 'none',
                    background: 'var(--accent)',
                    color: '#fff',
                    fontSize: 12,
                    fontWeight: 700,
                    cursor: saveAutomationMutation.isPending ? 'not-allowed' : 'pointer',
                    opacity: saveAutomationMutation.isPending ? 0.6 : 1,
                  }}
                >
                  {saveAutomationMutation.isPending ? 'Saving...' : 'Save Automation'}
                </button>
                <button
                  onClick={() => runAutomationMutation.mutate()}
                  disabled={runAutomationMutation.isPending}
                  style={{
                    padding: '8px 14px',
                    borderRadius: 8,
                    border: '1px solid var(--border)',
                    background: 'var(--surface)',
                    color: 'var(--text)',
                    fontSize: 12,
                    fontWeight: 700,
                    cursor: runAutomationMutation.isPending ? 'not-allowed' : 'pointer',
                    opacity: runAutomationMutation.isPending ? 0.6 : 1,
                  }}
                >
                  {runAutomationMutation.isPending ? 'Running...' : 'Run Goal Check Now'}
                </button>
              </div>
              {saveAutomationErrorMessage ? (
                <div
                  style={{
                    border: '1px solid var(--red)',
                    borderRadius: 8,
                    background: 'rgba(255,107,107,0.08)',
                    color: 'var(--red)',
                    fontSize: 12,
                    padding: '8px 10px',
                  }}
                >
                  Save failed: {saveAutomationErrorMessage}
                </div>
              ) : null}
              {runAutomationErrorMessage ? (
                <div
                  style={{
                    border: `1px solid ${runAutomationErrorStatus === 409 ? 'var(--yellow)' : 'var(--red)'}`,
                    borderRadius: 8,
                    background: runAutomationErrorStatus === 409 ? 'rgba(253,203,110,0.16)' : 'rgba(255,107,107,0.08)',
                    color: runAutomationErrorStatus === 409 ? 'var(--yellow)' : 'var(--red)',
                    fontSize: 12,
                    padding: '8px 10px',
                  }}
                >
                  {runAutomationErrorStatus === 409 ? `Blocked: ${runAutomationErrorMessage}` : `Run failed: ${runAutomationErrorMessage}`}
                </div>
              ) : null}
              {lastAutomationRun ? (
                <div style={{ fontSize: 12, color: 'var(--text2)', lineHeight: 1.5 }}>
                  <div style={{ fontWeight: 600, color: 'var(--text)' }}>Last automation run</div>
                  <div>{lastAutomationRun.summary}</div>
                  {lastAutomationRun.createdTasks.length > 0 ? (
                    <div style={{ marginTop: 6 }}>
                      Created: {lastAutomationRun.createdTasks.map((task) => `${task.goalTitle} (${task.stage})`).join(', ')}
                    </div>
                  ) : null}
                  {lastAutomationRun.skippedGoals.length > 0 ? (
                    <div style={{ marginTop: 6, color: 'var(--yellow)' }}>
                      Waiting on: {lastAutomationRun.skippedGoals.map((item) => item.reason).join(' / ')}
                    </div>
                  ) : null}
                </div>
              ) : null}
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
                <div style={{ fontSize: 13, fontWeight: 700 }}>Goal Tree</div>
                <div style={{ fontSize: 11, color: 'var(--text2)' }}>
                  Attach goals here and the routine will keep creating the next task chain.
                </div>
              </div>
              {projectGoalsLoading ? (
                <div style={{ fontSize: 12, color: 'var(--text2)' }}>Loading goal tree...</div>
              ) : null}
              {goalMutationErrorMessage ? (
                <div
                  style={{
                    border: '1px solid var(--red)',
                    borderRadius: 8,
                    background: 'rgba(255,107,107,0.08)',
                    color: 'var(--red)',
                    fontSize: 12,
                    padding: '8px 10px',
                  }}
                >
                  {goalMutationErrorMessage}
                </div>
              ) : null}
              {!projectGoalsLoading && topLevelGoals.length > 0 ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  {topLevelGoals.map((goal) => renderGoalRow(goal))}
                </div>
              ) : !projectGoalsLoading ? (
                <div style={{ fontSize: 12, color: 'var(--text2)' }}>
                  No goals yet. Add a top-level goal or child milestone and attach automation agents above.
                </div>
              ) : null}
            </div>

            <div
              style={{
                border: '1px dashed var(--border)',
                borderRadius: 10,
                padding: 12,
                display: 'flex',
                flexDirection: 'column',
                gap: 10,
              }}
            >
              <div style={{ fontSize: 13, fontWeight: 700 }}>Add Goal</div>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <span style={{ fontSize: 11, color: 'var(--text2)' }}>Title</span>
                <input
                  value={newGoalTitle}
                  onChange={(event) => setNewGoalTitle(event.target.value)}
                  placeholder="Production-grade execution v2"
                  style={{ padding: '8px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12 }}
                />
              </label>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <span style={{ fontSize: 11, color: 'var(--text2)' }}>Description</span>
                <textarea
                  value={newGoalDescription}
                  onChange={(event) => setNewGoalDescription(event.target.value)}
                  placeholder="Describe the expected outcome, completion signal, and any review criteria."
                  style={{ minHeight: 84, padding: '10px 12px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12, resize: 'vertical', boxSizing: 'border-box' }}
                />
              </label>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <span style={{ fontSize: 11, color: 'var(--text2)' }}>Parent Goal</span>
                <select
                  value={newGoalParentId}
                  onChange={(event) => setNewGoalParentId(event.target.value)}
                  style={{ padding: '8px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface)', color: 'var(--text)', fontSize: 12 }}
                >
                  <option value="">No parent (top-level goal)</option>
                  {projectGoals.map((goal) => (
                    <option key={goal.id} value={goal.id}>{goal.title}</option>
                  ))}
                </select>
              </label>
              <div>
                <button
                  onClick={() => createGoalMutation.mutate({
                    title: newGoalTitle.trim(),
                    description: newGoalDescription.trim() || undefined,
                    parentGoalId: newGoalParentId || null,
                    status: 'planned',
                  })}
                  disabled={!newGoalTitle.trim() || createGoalMutation.isPending}
                  style={{
                    padding: '8px 14px',
                    borderRadius: 8,
                    border: 'none',
                    background: !newGoalTitle.trim() ? 'var(--surface3)' : 'var(--accent)',
                    color: '#fff',
                    fontSize: 12,
                    fontWeight: 700,
                    cursor: !newGoalTitle.trim() || createGoalMutation.isPending ? 'not-allowed' : 'pointer',
                    opacity: !newGoalTitle.trim() || createGoalMutation.isPending ? 0.6 : 1,
                  }}
                >
                  {createGoalMutation.isPending ? 'Adding...' : 'Add Goal'}
                </button>
              </div>
            </div>
          </div>
        </SectionCard>

        {/* 5. Guard Status */}
        {id && (
          <GuardSection
            projectId={id}
            guardScore={analysis?.scores?.guard.score}
          />
        )}

        {/* 7. CLAUDE.md */}
        <SectionCard
          title="CLAUDE.md Detail Panel"
          titleExtra={<SetupPanelMeta axis="guide" operation={guideClaudeOperation} />}
        >
          {!hasPath ? (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>프로젝트 경로를 설정하면 CLAUDE.md 상태를 확인할 수 있습니다.</div>
          ) : analysisLoading ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <SkeletonBlock height={14} />
              <SkeletonBlock width="70%" height={14} />
            </div>
          ) : analysis?.claudeMd.exists ? (
            <div>
              <SetupManagedBanner
                axis="guide"
                operation={guideClaudeOperation}
                summary="CLAUDE.md는 Guide 축의 핵심 요약 문서입니다. 내용이 이미 있으면 여기서 직접 수정하고, 구조적인 누락은 Setup Center에서 다시 맞춥니다."
                hint="직접 편집은 유지되지만, 새로 만드는 흐름은 Setup Center를 기준으로 관리합니다."
                lastApplySummary={claudeApplySummary}
                focusActionLabel="Focus CLAUDE.md in Setup"
                onFocusAction={() => requestSetupFocus(claudePanelOperationIds)}
                secondaryActionLabel="Reset via Setup"
                onSecondaryAction={() => applySetupOperations('guide', claudePanelOperationIds, true)}
                secondaryActionDisabled={applySetupAxis.isPending}
              />
              {claudeMdEditing ? (
                <div>
                  <textarea
                    value={claudeMdDraft}
                    onChange={(e) => setClaudeMdDraft(e.target.value)}
                    style={{
                      width: '100%',
                      minHeight: 200,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      borderRadius: 8,
                      padding: 12,
                      color: 'var(--text)',
                      resize: 'vertical',
                      boxSizing: 'border-box',
                    }}
                  />
                  <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                    <button
                      onClick={() => updateClaudeMd.mutate(claudeMdDraft)}
                      disabled={updateClaudeMd.isPending}
                      style={{
                        padding: '5px 12px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'var(--surface2)',
                        color: 'var(--text)',
                        fontSize: 12,
                        cursor: updateClaudeMd.isPending ? 'not-allowed' : 'pointer',
                      }}
                    >
                      {updateClaudeMd.isPending ? '저장 중...' : '저장'}
                    </button>
                    <button
                      onClick={() => setClaudeMdEditing(false)}
                      style={{
                        padding: '5px 12px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'transparent',
                        color: 'var(--text2)',
                        fontSize: 12,
                        cursor: 'pointer',
                      }}
                    >
                      취소
                    </button>
                  </div>
                </div>
              ) : (
                <div>
                  <div
                    style={{
                      fontSize: 12,
                      color: 'var(--text)',
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      borderRadius: 8,
                      padding: 12,
                      whiteSpace: 'pre-wrap',
                      wordBreak: 'break-all',
                      maxHeight: claudeMdExpanded ? 'none' : 120,
                      overflow: 'hidden',
                    }}
                  >
                    {analysis.claudeMd.content ?? ''}
                  </div>
                  <div style={{ display: 'flex', gap: 8, marginTop: 8, alignItems: 'center' }}>
                    {(analysis.claudeMd.content?.length ?? 0) > 200 && (
                      <button
                        onClick={() => setClaudeMdExpanded((v) => !v)}
                        style={{
                          padding: '4px 10px',
                          borderRadius: 6,
                          border: '1px solid var(--border)',
                          background: 'transparent',
                          color: 'var(--text2)',
                          fontSize: 11,
                          cursor: 'pointer',
                        }}
                      >
                        {claudeMdExpanded ? '접기' : '전체 보기'}
                      </button>
                    )}
                    <button
                      onClick={() => {
                        setClaudeMdDraft(analysis.claudeMd.content ?? '');
                        setClaudeMdEditing(true);
                      }}
                      style={{
                        padding: '4px 10px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'var(--surface2)',
                        color: 'var(--text)',
                        fontSize: 12,
                        cursor: 'pointer',
                      }}
                    >
                      수정
                    </button>
                    <button
                      onClick={() => {
                        if (window.confirm('CLAUDE.md를 삭제하시겠습니까?')) {
                          deleteClaudeMd.mutate();
                        }
                      }}
                      disabled={deleteClaudeMd.isPending}
                      style={{
                        padding: '4px 10px',
                        borderRadius: 6,
                        border: '1px solid var(--red)',
                        background: 'transparent',
                        color: 'var(--red)',
                        fontSize: 12,
                        cursor: deleteClaudeMd.isPending ? 'not-allowed' : 'pointer',
                      }}
                    >
                      {deleteClaudeMd.isPending ? '삭제 중...' : '삭제'}
                    </button>
                  </div>

                </div>
              )}
            </div>
          ) : (
            <div>
              <SetupManagedBanner
                axis="guide"
                operation={guideClaudeOperation}
                summary="이 자산은 Setup Center가 프로젝트 로컬에 생성합니다."
                hint="직접 생성 대신 Setup Center 또는 아래 버튼으로 Guide 축을 적용하세요."
                lastApplySummary={claudeApplySummary}
                focusActionLabel="Focus CLAUDE.md in Setup"
                onFocusAction={() => requestSetupFocus(claudePanelOperationIds)}
                actionLabel={applySetupAxis.isPending ? 'Applying Setup...' : 'Create via Setup'}
                onAction={() => applySetupOperations('guide', claudePanelOperationIds)}
                actionDisabled={applySetupAxis.isPending}
              />
              <div style={{ fontSize: 13, color: 'var(--text2)', marginBottom: 10 }}>
                이 프로젝트에 CLAUDE.md가 없습니다. CLAUDE.md를 추가하면 Claude가 프로젝트 컨텍스트를 자동으로 이해합니다.
              </div>
              <button
                onClick={() => applySetupOperations('guide', claudePanelOperationIds)}
                disabled={applySetupAxis.isPending}
                style={{
                  padding: '8px 16px',
                  borderRadius: 8,
                  border: 'none',
                  background: applySetupAxis.isPending ? 'var(--surface3)' : 'var(--accent)',
                  color: '#fff',
                  fontSize: 13,
                  fontWeight: 600,
                  cursor: applySetupAxis.isPending ? 'not-allowed' : 'pointer',
                  opacity: applySetupAxis.isPending ? 0.6 : 1,
                }}
              >
                {applySetupAxis.isPending ? '적용 중...' : 'Create via Setup'}
              </button>
              {applySetupAxis.isError && (
                <span style={{ fontSize: 11, color: 'var(--red)', marginLeft: 8 }}>생성 실패</span>
              )}
            </div>
          )}
        </SectionCard>

        {/* 7. Hooks */}
        <SectionCard
          title="Hook Detail Panel"
          titleExtra={<SetupPanelMeta axis="guard" operation={guardHooksOperation} />}
        >
          {!hasPath ? (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>프로젝트 경로를 설정하면 Hook 상태를 확인할 수 있습니다.</div>
          ) : analysisLoading ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <SkeletonBlock height={14} />
              <SkeletonBlock width="80%" height={14} />
            </div>
          ) : analysis && analysis.hooks.length > 0 ? (
            <div>
              <SetupManagedBanner
                axis="guard"
                operation={guardHooksOperation}
                summary="Workspace-local hooks와 .ddalkak/config.yaml은 Guard 축에서 함께 관리합니다. 현재 Hook 설정은 여기서 검토하고, 정책 누락은 Setup Center에서 보완합니다."
                hint="Hook 삭제는 detail action으로 남겨두되, 다시 적용하는 기준은 Setup Center입니다."
                lastApplySummary={hooksApplySummary}
                focusActionLabel="Focus Hooks in Setup"
                onFocusAction={() => requestSetupFocus(guardPanelOperationIds)}
                secondaryActionLabel="Reset via Setup"
                onSecondaryAction={() => applySetupOperations('guard', guardPanelOperationIds, true)}
                secondaryActionDisabled={applySetupAxis.isPending}
              />
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                {analysis.hooks.map((hook, i) => (
                  <div
                    key={i}
                    style={{
                      padding: '10px 12px',
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      borderRadius: 8,
                    }}
                  >
                    <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 4 }}>
                      <Badge color="yellow">{hook.event}</Badge>
                    </div>
                    {hook.commands.map((cmd, j) => (
                      <div key={j} style={{ fontSize: 11, color: 'var(--text2)', fontFamily: 'monospace', marginTop: 2 }}>
                        {cmd}
                      </div>
                    ))}
                  </div>
                ))}
              </div>
              <div style={{ marginTop: 10 }}>
                <button
                  onClick={() => {
                    if (window.confirm('모든 Hook 설정을 초기화하시겠습니까?')) {
                      deleteHooks.mutate();
                    }
                  }}
                  disabled={deleteHooks.isPending}
                  style={{
                    padding: '5px 12px',
                    borderRadius: 6,
                    border: '1px solid var(--red)',
                    background: 'transparent',
                    color: 'var(--red)',
                    fontSize: 12,
                    cursor: deleteHooks.isPending ? 'not-allowed' : 'pointer',
                  }}
                >
                  {deleteHooks.isPending ? '초기화 중...' : 'Hook 초기화'}
                </button>
              </div>
            </div>
          ) : (
            <div>
              <SetupManagedBanner
                axis="guard"
                operation={guardHooksOperation}
                summary="이 프로젝트에는 아직 Guard hook이 없습니다."
                hint="보안 Hook 생성은 Setup Center에서 Guard 축을 적용하는 것이 기본 경로입니다."
                lastApplySummary={hooksApplySummary}
                focusActionLabel="Focus Hooks in Setup"
                onFocusAction={() => requestSetupFocus(guardPanelOperationIds)}
                actionLabel={applySetupAxis.isPending ? 'Applying Setup...' : 'Create via Setup'}
                onAction={() => applySetupOperations('guard', guardPanelOperationIds)}
                actionDisabled={applySetupAxis.isPending}
              />
              <div style={{ fontSize: 13, color: 'var(--text2)', marginBottom: 10 }}>
                보안 Hook을 적용하면 위험 명령을 자동 차단합니다.
              </div>
              <button
                onClick={() => applySetupOperations('guard', guardPanelOperationIds)}
                disabled={applySetupAxis.isPending}
                style={{
                  padding: '8px 16px',
                  borderRadius: 8,
                  border: 'none',
                  background: applySetupAxis.isPending ? 'var(--surface3)' : 'var(--accent)',
                  color: '#fff',
                  fontSize: 13,
                  fontWeight: 600,
                  cursor: applySetupAxis.isPending ? 'not-allowed' : 'pointer',
                  opacity: applySetupAxis.isPending ? 0.6 : 1,
                }}
              >
                {applySetupAxis.isPending ? '적용 중...' : 'Create via Setup'}
              </button>
              {applySetupAxis.isError && (
                <span style={{ fontSize: 11, color: 'var(--red)', marginLeft: 8 }}>적용 실패</span>
              )}
            </div>
          )}
        </SectionCard>

        {/* 8. 프로젝트 문서 */}
        <SectionCard
          title="프로젝트 문서 Detail Panel"
          titleExtra={
            <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
              <Badge color="blue">GUIDE</Badge>
              <Badge color={missingGuideDocs.length === 0 ? 'green' : 'yellow'}>
                {missingGuideDocs.length === 0 ? 'Ready' : 'Missing'}
              </Badge>
            </div>
          }
        >
          {!hasPath ? (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>프로젝트 경로를 설정하면 문서 목록을 확인할 수 있습니다.</div>
          ) : analysisLoading ? (
            <div style={{ display: 'flex', gap: 6 }}>
              <SkeletonBlock width={70} height={22} />
              <SkeletonBlock width={90} height={22} />
            </div>
          ) : analysis && analysis.docs.length > 0 ? (
            <div>
              <SetupManagedBanner
                axis="guide"
                operation={guideDocsPanelOperation}
                summary={
                  missingGuideDocs.length === 0
                    ? 'Guide 표준 문서와 context map이 준비되어 있습니다. 기존 문서는 여기서 직접 수정하고, 구조 문서 누락은 Setup Center에서 다시 맞춥니다.'
                    : `Guide 표준 자산 중 ${missingGuideDocs.map((item) => item.label).join(', ')} 이(가) 아직 없습니다.`
                }
                hint="표준 Guide 문서는 Setup Center가 생성하고, 커스텀 문서는 아래에서 직접 추가할 수 있습니다."
                lastApplySummary={guideDocsApplySummary}
                focusActionLabel="Focus Guide Docs in Setup"
                onFocusAction={() => requestSetupFocus(guideDocsPanelOperationIds)}
                secondaryActionLabel={missingGuideDocs.length === 0 ? 'Reset via Setup' : undefined}
                onSecondaryAction={missingGuideDocs.length === 0 ? (() => applySetupOperations('guide', guideDocsPanelOperationIds, true)) : undefined}
                secondaryActionDisabled={applySetupAxis.isPending}
                actionLabel={missingGuideDocs.length > 0 ? (applySetupAxis.isPending ? 'Applying Setup...' : 'Create via Setup') : undefined}
                onAction={missingGuideDocs.length > 0 ? (() => applySetupOperations('guide', guideDocsPanelOperationIds)) : undefined}
                actionDisabled={applySetupAxis.isPending}
              />
              {analysis.docs.map((d) => (
                <div key={d.name} style={{ borderBottom: '1px solid var(--border)' }}>
                  <div
                    style={{ display: 'flex', justifyContent: 'space-between', cursor: 'pointer', padding: '8px 0', alignItems: 'center' }}
                    onClick={async () => {
                      if (expandedDoc === d.name) {
                        setExpandedDoc(null);
                        setEditingDoc(null);
                      } else {
                        setExpandedDoc(d.name);
                        setEditingDoc(null);
                        if (!docContents[d.name]) {
                          try {
                            const result = await api.get<{ name: string; content: string }>(`/projects/${id}/docs/${d.name}`);
                            setDocContents((prev) => ({ ...prev, [d.name]: result.content }));
                          } catch {
                            setDocContents((prev) => ({ ...prev, [d.name]: '(불러오기 실패)' }));
                          }
                        }
                      }
                    }}
                  >
                    <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                      <span style={{ fontSize: 13, fontWeight: 500 }}>{d.name}</span>
                      <Badge color={isManagedDoc(d.name) ? 'blue' : 'gray'}>
                        {isManagedDoc(d.name) ? 'managed' : 'custom'}
                      </Badge>
                      {isManagedDoc(d.name) && managedDocOperationIds[d.name] && (
                        <button
                          onClick={(event) => {
                            event.stopPropagation();
                            requestSetupFocus([managedDocOperationIds[d.name]]);
                          }}
                          aria-label={`Focus ${d.name} in Setup`}
                          style={{
                            padding: '3px 8px',
                            borderRadius: 999,
                            border: '1px solid var(--border)',
                            background: 'var(--surface)',
                            color: 'var(--text2)',
                            fontSize: 11,
                            fontWeight: 600,
                            cursor: 'pointer',
                          }}
                        >
                          Focus in Setup
                        </button>
                      )}
                    </div>
                    <span style={{ fontSize: 11, color: 'var(--text2)' }}>{expandedDoc === d.name ? '▼' : '▶'}</span>
                  </div>
                  {expandedDoc === d.name && (
                    <div style={{ paddingBottom: 10 }}>
                      {editingDoc === d.name ? (
                        <div>
                          <textarea
                            value={docDraft}
                            onChange={(e) => setDocDraft(e.target.value)}
                            style={{
                              width: '100%',
                              minHeight: 200,
                              fontSize: 12,
                              fontFamily: 'monospace',
                              background: 'var(--surface2)',
                              border: '1px solid var(--border)',
                              borderRadius: 8,
                              padding: 12,
                              color: 'var(--text)',
                              resize: 'vertical',
                              boxSizing: 'border-box',
                            }}
                          />
                          <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                            <button
                              onClick={() => updateDoc.mutate({ name: d.name, content: docDraft })}
                              disabled={updateDoc.isPending}
                              style={{
                                padding: '5px 12px',
                                borderRadius: 6,
                                border: '1px solid var(--border)',
                                background: 'var(--surface2)',
                                color: 'var(--text)',
                                fontSize: 12,
                                cursor: updateDoc.isPending ? 'not-allowed' : 'pointer',
                              }}
                            >
                              {updateDoc.isPending ? '저장 중...' : '저장'}
                            </button>
                            <button
                              onClick={() => setEditingDoc(null)}
                              style={{
                                padding: '5px 12px',
                                borderRadius: 6,
                                border: '1px solid var(--border)',
                                background: 'transparent',
                                color: 'var(--text2)',
                                fontSize: 12,
                                cursor: 'pointer',
                              }}
                            >
                              취소
                            </button>
                          </div>
                        </div>
                      ) : (
                        <div>
                          <div
                            style={{
                              fontSize: 12,
                              fontFamily: 'monospace',
                              background: 'var(--surface2)',
                              border: '1px solid var(--border)',
                              borderRadius: 8,
                              padding: 12,
                              whiteSpace: 'pre-wrap',
                              maxHeight: 200,
                              overflowY: 'auto',
                            }}
                          >
                            {docContents[d.name] ?? '불러오는 중...'}
                          </div>
                          <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                            <button
                              onClick={() => {
                                setDocDraft(docContents[d.name] ?? '');
                                setEditingDoc(d.name);
                              }}
                              style={{
                                padding: '4px 10px',
                                borderRadius: 6,
                                border: '1px solid var(--border)',
                                background: 'var(--surface2)',
                                color: 'var(--text)',
                                fontSize: 12,
                                cursor: 'pointer',
                              }}
                            >
                              수정
                            </button>
                            <button
                              onClick={() => {
                                if (window.confirm(`'${d.name}.md'를 삭제하시겠습니까?`)) {
                                  deleteDoc.mutate(d.name);
                                }
                              }}
                              disabled={deleteDoc.isPending}
                              style={{
                                padding: '4px 10px',
                                borderRadius: 6,
                                border: '1px solid var(--red)',
                                background: 'transparent',
                                color: 'var(--red)',
                                fontSize: 12,
                                cursor: deleteDoc.isPending ? 'not-allowed' : 'pointer',
                              }}
                            >
                              {deleteDoc.isPending ? '삭제 중...' : '삭제'}
                            </button>
                          </div>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              ))}
              {!addingDoc && (
                <button
                  onClick={() => setAddingDoc(true)}
                  style={{ marginTop: 8, padding: '5px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12, cursor: 'pointer' }}
                >
                  + 문서 추가
                </button>
              )}
              {addingDoc && (
                <div style={{ marginTop: 8, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <input
                    placeholder="문서 이름 (예: testing)"
                    value={newDocName}
                    onChange={(e) => setNewDocName(e.target.value.replace(/[^a-zA-Z0-9_-]/g, ''))}
                    style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12 }}
                  />
                  <textarea
                    placeholder="문서 내용 (마크다운)"
                    value={newDocContent}
                    onChange={(e) => setNewDocContent(e.target.value)}
                    style={{ width: '100%', minHeight: 150, fontSize: 12, fontFamily: 'monospace', background: 'var(--surface2)', border: '1px solid var(--border)', borderRadius: 8, padding: 12, color: 'var(--text)', resize: 'vertical', boxSizing: 'border-box' }}
                  />
                  <div style={{ display: 'flex', gap: 8 }}>
                    <button
                      onClick={() => {
                        if (newDocName.trim()) {
                          addDoc.mutate({ name: newDocName.trim(), content: newDocContent });
                        }
                      }}
                      disabled={!newDocName.trim() || addDoc.isPending}
                      style={{ padding: '5px 12px', borderRadius: 6, border: 'none', background: !newDocName.trim() ? 'var(--surface3)' : 'var(--accent)', color: '#fff', fontSize: 12, fontWeight: 600, cursor: !newDocName.trim() ? 'not-allowed' : 'pointer', opacity: !newDocName.trim() ? 0.6 : 1 }}
                    >
                      {addDoc.isPending ? '추가 중...' : '추가'}
                    </button>
                    <button
                      onClick={() => { setAddingDoc(false); setNewDocName(''); setNewDocContent(''); }}
                      style={{ padding: '5px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'transparent', color: 'var(--text2)', fontSize: 12, cursor: 'pointer' }}
                    >
                      취소
                    </button>
                  </div>
                </div>
              )}
            </div>
          ) : (
            <div>
              <SetupManagedBanner
                axis="guide"
                operation={guideDocsPanelOperation}
                summary="표준 Guide 문서와 context map은 Setup Center가 프로젝트 로컬에 생성합니다."
                hint={
                  missingGuideDocs.length > 0
                    ? `현재 누락: ${missingGuideDocs.map((item) => item.label).join(', ')}`
                    : '커스텀 문서는 아래에서 직접 추가할 수 있습니다.'
                }
                lastApplySummary={guideDocsApplySummary}
                focusActionLabel="Focus Guide Docs in Setup"
                onFocusAction={() => requestSetupFocus(guideDocsPanelOperationIds)}
                actionLabel={applySetupAxis.isPending ? 'Applying Setup...' : 'Create via Setup'}
                onAction={() => applySetupOperations('guide', guideDocsPanelOperationIds)}
                actionDisabled={applySetupAxis.isPending}
              />
              <div style={{ fontSize: 13, color: 'var(--text2)', marginBottom: 8 }}>
                프로젝트 셋업을 실행하면 자동으로 생성됩니다. (.ddalkak/docs/)
              </div>
              <button
                onClick={() => setAddingDoc(true)}
                style={{ padding: '5px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12, cursor: 'pointer' }}
              >
                + 문서 추가
              </button>
              {addingDoc && (
                <div style={{ marginTop: 8, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <input
                    placeholder="문서 이름 (예: testing)"
                    value={newDocName}
                    onChange={(e) => setNewDocName(e.target.value.replace(/[^a-zA-Z0-9_-]/g, ''))}
                    style={{ padding: '6px 10px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12 }}
                  />
                  <textarea
                    placeholder="문서 내용 (마크다운)"
                    value={newDocContent}
                    onChange={(e) => setNewDocContent(e.target.value)}
                    style={{ width: '100%', minHeight: 150, fontSize: 12, fontFamily: 'monospace', background: 'var(--surface2)', border: '1px solid var(--border)', borderRadius: 8, padding: 12, color: 'var(--text)', resize: 'vertical', boxSizing: 'border-box' }}
                  />
                  <div style={{ display: 'flex', gap: 8 }}>
                    <button
                      onClick={() => {
                        if (newDocName.trim()) {
                          addDoc.mutate({ name: newDocName.trim(), content: newDocContent });
                        }
                      }}
                      disabled={!newDocName.trim() || addDoc.isPending}
                      style={{ padding: '5px 12px', borderRadius: 6, border: 'none', background: !newDocName.trim() ? 'var(--surface3)' : 'var(--accent)', color: '#fff', fontSize: 12, fontWeight: 600, cursor: !newDocName.trim() ? 'not-allowed' : 'pointer', opacity: !newDocName.trim() ? 0.6 : 1 }}
                    >
                      {addDoc.isPending ? '추가 중...' : '추가'}
                    </button>
                    <button
                      onClick={() => { setAddingDoc(false); setNewDocName(''); setNewDocContent(''); }}
                      style={{ padding: '5px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'transparent', color: 'var(--text2)', fontSize: 12, cursor: 'pointer' }}
                    >
                      취소
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}
        </SectionCard>

        {/* 10. 스킬 */}
        <SectionCard title="스킬">
          {!hasPath ? (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>프로젝트 경로를 설정하면 스킬 목록을 확인할 수 있습니다.</div>
          ) : analysisLoading ? (
            <div style={{ display: 'flex', gap: 6 }}>
              <SkeletonBlock width={70} height={22} />
              <SkeletonBlock width={90} height={22} />
            </div>
          ) : analysis && analysis.skills.length > 0 ? (
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {analysis.skills.map((s) => (
                <Badge key={s.name} color="blue">{s.name}</Badge>
              ))}
            </div>
          ) : (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>
              .ddalkak/skills/ 디렉토리에 스킬을 추가하세요.
            </div>
          )}
        </SectionCard>

        {/* 10. 에이전트 */}
        <SectionCard
          title={`에이전트 Detail Panel (${agents.length})`}
          titleExtra={<SetupPanelMeta axis="gear" operation={gearAgentsPanelOperation} />}
        >
          <SetupManagedBanner
            axis="gear"
            operation={gearAgentsPanelOperation}
            summary={
              missingGearAgentAssets.length === 0
                ? 'Project-local agent profiles are ready. Runtime-attached agents remain a separate operational layer below.'
                : `Gear agent assets are missing: ${missingGearAgentAssets.map((item) => item.label).join(', ')}.`
            }
            hint="Gear in this phase prepares reusable project-local execution assets. Runtime registration and execution stay in the existing agent/task flow."
            lastApplySummary={gearAgentsApplySummary}
            focusActionLabel="Focus Gear Agents in Setup"
            onFocusAction={() => requestSetupFocus(gearAgentPanelOperationIds)}
            secondaryActionLabel={missingGearAgentAssets.length === 0 ? 'Reset via Setup' : undefined}
            onSecondaryAction={missingGearAgentAssets.length === 0 ? (() => applySetupOperations('gear', gearAgentPanelOperationIds, true)) : undefined}
            secondaryActionDisabled={applySetupAxis.isPending}
            actionLabel={missingGearAgentAssets.length > 0 ? (applySetupAxis.isPending ? 'Applying Setup...' : 'Create via Setup') : undefined}
            onAction={missingGearAgentAssets.length > 0 ? (() => applySetupOperations('gear', gearAgentPanelOperationIds)) : undefined}
            actionDisabled={applySetupAxis.isPending}
          />
          {hasPath && analysis && (
            <>
              {analysis.agents.length > 0 && (
                <div style={{ marginBottom: 12 }}>
                  <div style={{ fontSize: 11, color: 'var(--text2)', marginBottom: 6 }}>.claude/agents/</div>
                  <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                    {analysis.agents.map((a) => (
                      <span key={a.name} style={{ display: 'inline-flex', gap: 6, alignItems: 'center' }}>
                        <Badge color="blue">{a.name}</Badge>
                        <Badge color={isManagedAgentAsset(a.name) ? 'blue' : 'gray'}>
                          {isManagedAgentAsset(a.name) ? 'managed' : 'custom'}
                        </Badge>
                        {isManagedAgentAsset(a.name) && managedAgentOperationIds[a.name] && (
                          <button
                            onClick={() => requestSetupFocus([managedAgentOperationIds[a.name]])}
                            aria-label={`Focus ${a.name} agent in Setup`}
                            style={{
                              padding: '3px 8px',
                              borderRadius: 999,
                              border: '1px solid var(--border)',
                              background: 'var(--surface)',
                              color: 'var(--text2)',
                              fontSize: 11,
                              fontWeight: 600,
                              cursor: 'pointer',
                            }}
                          >
                            Focus in Setup
                          </button>
                        )}
                      </span>
                    ))}
                  </div>
                </div>
              )}
              <div style={{ marginBottom: 12 }}>
                <div style={{ fontSize: 11, color: 'var(--text2)', marginBottom: 6 }}>설치된 CLI</div>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {(['claude', 'codex', 'cursor'] as const).map((key) => {
                    const labels: Record<string, string> = { claude: 'Claude', codex: 'Codex', cursor: 'Cursor' };
                    const installed = analysis.installedCLIs[key];
                    return (
                      <Badge key={key} color={installed ? 'green' : 'gray'}>
                        {labels[key]} {installed ? '✓' : '✗'}
                      </Badge>
                    );
                  })}
                </div>
              </div>
            </>
          )}
          {agents.length === 0 && !analysis?.agents.length ? (
            <div style={{ padding: '8px 0', textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No agents</div>
          ) : agents.length > 0 && (
            <div>
              <div style={{ fontSize: 11, color: 'var(--text2)', marginBottom: 6 }}>등록된 에이전트</div>
              {agents.map((agent) => {
                const adapter = adapterIcons[agent.adapterType] ?? { icon: '?', color: '#888' };
                const status = agentStatusColors[agent.status] ?? agentStatusColors.idle;
                return (
                  <div
                    key={agent.id}
                    style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid var(--border)' }}
                  >
                    <div
                      style={{
                        width: 28,
                        height: 28,
                        borderRadius: 6,
                        background: `linear-gradient(135deg, ${adapter.color}, ${adapter.color}88)`,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        fontSize: 11,
                        fontWeight: 700,
                        color: '#fff',
                      }}
                    >
                      {adapter.icon}
                    </div>
                    <div style={{ flex: 1 }}>
                      <div style={{ fontSize: 13, fontWeight: 500 }}>{agent.name}</div>
                      <div style={{ fontSize: 11, color: 'var(--text2)' }}>{agent.adapterType.replace('_', ' ')}</div>
                    </div>
                    <span
                      style={{
                        padding: '2px 8px',
                        borderRadius: 6,
                        fontSize: 11,
                        fontWeight: 600,
                        background: status.bg,
                        color: status.color,
                      }}
                    >
                      {agent.status}
                    </span>
                  </div>
                );
              })}
            </div>
          )}
        </SectionCard>

        {/* 11. 워크플로우 */}
        <SectionCard
          title="워크플로우 Detail Panel"
          titleExtra={<SetupPanelMeta axis="gear" operation={gearWorkflowsPanelOperation} />}
        >
          <SetupManagedBanner
            axis="gear"
            operation={gearWorkflowsPanelOperation}
            summary={
              missingGearWorkflowAssets.length === 0
                ? 'Project-local execution workflows are ready for feature, bug, and refactor work.'
                : `Gear workflow assets are missing: ${missingGearWorkflowAssets.map((item) => item.label).join(', ')}.`
            }
            hint="These workflows prepare execution patterns only. They do not replace the current task runner or runtime attach flow."
            lastApplySummary={gearWorkflowsApplySummary}
            focusActionLabel="Focus Gear Workflows in Setup"
            onFocusAction={() => requestSetupFocus(gearWorkflowPanelOperationIds)}
            secondaryActionLabel={missingGearWorkflowAssets.length === 0 ? 'Reset via Setup' : undefined}
            onSecondaryAction={missingGearWorkflowAssets.length === 0 ? (() => applySetupOperations('gear', gearWorkflowPanelOperationIds, true)) : undefined}
            secondaryActionDisabled={applySetupAxis.isPending}
            actionLabel={missingGearWorkflowAssets.length > 0 ? (applySetupAxis.isPending ? 'Applying Setup...' : 'Create via Setup') : undefined}
            onAction={missingGearWorkflowAssets.length > 0 ? (() => applySetupOperations('gear', gearWorkflowPanelOperationIds)) : undefined}
            actionDisabled={applySetupAxis.isPending}
          />
          {hasPath && analysis ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {analysis.workflows && analysis.workflows.length > 0 ? (
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {analysis.workflows.map((w) => (
                    <span key={w.name} style={{ display: 'inline-flex', gap: 6, alignItems: 'center' }}>
                      <Badge color="orange">{w.name}</Badge>
                      <Badge color={isManagedWorkflowAsset(w.name) ? 'orange' : 'gray'}>
                        {isManagedWorkflowAsset(w.name) ? 'managed' : 'custom'}
                      </Badge>
                      {isManagedWorkflowAsset(w.name) && managedWorkflowOperationIds[w.name] && (
                        <button
                          onClick={() => requestSetupFocus([managedWorkflowOperationIds[w.name]])}
                          aria-label={`Focus ${w.name} workflow in Setup`}
                          style={{
                            padding: '3px 8px',
                            borderRadius: 999,
                            border: '1px solid var(--border)',
                            background: 'var(--surface)',
                            color: 'var(--text2)',
                            fontSize: 11,
                            fontWeight: 600,
                            cursor: 'pointer',
                          }}
                        >
                          Focus in Setup
                        </button>
                      )}
                    </span>
                  ))}
                </div>
              ) : (
                <div style={{ fontSize: 13, color: 'var(--text2)' }}>
                  프로젝트 셋업을 실행하면 자동으로 생성됩니다.
                </div>
              )}

              <div
                style={{
                  display: 'grid',
                  gridTemplateColumns: 'repeat(3, minmax(0, 1fr))',
                  gap: 10,
                }}
              >
                {workflowPreview.map((workflow) => (
                  <div
                    key={workflow.name}
                    style={{
                      border: '1px solid var(--border)',
                      borderRadius: 10,
                      background: 'var(--surface2)',
                      padding: 12,
                    }}
                  >
                    <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 8 }}>{workflow.name}</div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                      {workflow.steps.map((step, index) => (
                        <div key={step} style={{ fontSize: 11, color: 'var(--text2)', lineHeight: 1.5 }}>
                          {index + 1}. {step}
                        </div>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ) : (
            <div style={{ fontSize: 13, color: 'var(--text2)' }}>
              프로젝트 경로를 설정하세요.
            </div>
          )}
        </SectionCard>

        {/* 12. 비용 요약 */}
        <SectionCard title="Cost Summary">
          {cost ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 12, color: 'var(--text2)' }}>Total Spend</span>
                <span style={{ fontSize: 18, fontWeight: 700 }}>{formatUsd(cost.totalUsd)}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 12, color: 'var(--text2)' }}>Input Tokens</span>
                <span style={{ fontSize: 13 }}>{formatTokens(cost.tokensIn)}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 12, color: 'var(--text2)' }}>Output Tokens</span>
                <span style={{ fontSize: 13 }}>{formatTokens(cost.tokensOut)}</span>
              </div>
            </div>
          ) : (
            <div style={{ color: 'var(--text2)', fontSize: 13 }}>No cost data yet</div>
          )}
        </SectionCard>

        {/* 12. 최근 태스크 */}
        <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12 }}>
          <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', fontSize: 14, fontWeight: 600 }}>
            Recent Tasks ({tasks.length})
          </div>
          <div style={{ padding: '8px 18px' }}>
            {tasks.length === 0 ? (
              <div style={{ padding: 16, textAlign: 'center', color: 'var(--text2)', fontSize: 13 }}>No tasks</div>
            ) : tasks.map((task) => {
              const s = statusStyle[task.status] ?? statusStyle.todo;
              const workflow = task.metadata?.workflow;
              const nextPhase = getNextPhase(workflow);
              const activePhase = getActivePhase(workflow);
              const blockedPhase = getBlockedPhase(workflow);
              const assignedAgent = agents.find((agent) => agent.id === task.agentId);
              const reviewAgent = workflow && canSendToReview(workflow) ? pickReviewerAgent(agents, task) : null;
              const blockedReviewAgent =
                workflow && blockedPhase?.enforceSeparation
                  ? pickReviewerAgent(agents, task)
                  : null;
              const workflowOutcome = getWorkflowOutcomeSummary(task, workflow);
              const taskPhaseBlock = phaseBlockByTaskId[task.id];
              const focusedChecklistItemId = focusedChecklistItemByTaskId[task.id];
              const handoffReady = handoffReadyByTaskId[task.id] === true;
              const recoveredWorkflow = recoveredWorkflowByTaskId[task.id];
              const handoffRetryState = handoffRetryStateByTaskId[task.id];
              const latestActivity = getLatestTaskActivity(projectActivity, task.id);
              const latestActivitySummary = getTaskActivitySummary(latestActivity);
              const taskTimeline = getTaskActivityTimeline(projectActivity, task.id);
              const selectedTimelineEntry = taskTimeline.find((entry) => entry.id === selectedTimelineEventIds[task.id]);
              const selectedTimelineDetail = selectedTimelineEntry ? getTaskTimelineDetail(selectedTimelineEntry) : null;
              const preferredTimelineEntry = getPreferredTimelineEntry(taskTimeline);
              const timelineHistoryEntries = (timelineHistoryEventIds[task.id] ?? [])
                .map((eventId) => taskTimeline.find((entry) => entry.id === eventId))
                .filter((entry): entry is ActivityEvent => !!entry && entry.id !== selectedTimelineEntry?.id);
              const supersededIds = supersededTimelineEventIds[task.id] ?? [];
              const isRetryingReview = retryingTaskIds[task.id] === true;
              const phaseOwnerLabel = (blockedPhase?.enforceSeparation || activePhase?.enforceSeparation)
                ? (blockedReviewAgent?.name ?? reviewAgent?.name ?? assignedAgent?.name ?? 'unassigned')
                : (assignedAgent?.name ?? reviewAgent?.name ?? 'unassigned');
              const currentOrBlockedPhase = activePhase ?? blockedPhase;
              const reviewPhase = workflow?.phases.find((phase) => phase.enforceSeparation)
                ?? workflow?.phases.find((phase) => /review/i.test(`${phase.id} ${phase.label}`));
              const phaseObjectiveLabel = currentOrBlockedPhase?.objective ?? 'No explicit objective';
              const setupOriginLabels = buildSetupOrigins(workflow, currentOrBlockedPhase);
              const phasePolicyLines = buildPhasePolicyLines(workflow, currentOrBlockedPhase, blockedReviewAgent ?? reviewAgent);
              const orchestrationAlerts = buildOrchestrationAlerts(
                task,
                workflow,
                currentOrBlockedPhase,
                assignedAgent,
                blockedReviewAgent ?? reviewAgent,
              );
              const effectivePhasePolicyLines = taskPhaseBlock
                ? [
                    `Server blocked handoff until ${taskPhaseBlock.phaseLabel} required items are complete.`,
                    ...taskPhaseBlock.requiredItems.map((item) => `Required: ${item.label}`),
                    ...phasePolicyLines,
                  ]
                : phasePolicyLines;
              const effectiveOrchestrationAlerts = taskPhaseBlock
                ? [{ label: `${taskPhaseBlock.requiredItems.length} required item(s) blocking handoff`, tone: 'red' as const }, ...orchestrationAlerts]
                : orchestrationAlerts;
              const agentCapabilityLabels = buildAgentCapabilities(assignedAgent, currentOrBlockedPhase, workflow);
              const reviewerCapabilityLabels = buildAgentCapabilities(
                blockedReviewAgent ?? reviewAgent ?? (currentOrBlockedPhase?.enforceSeparation ? assignedAgent : null),
                reviewPhase ?? currentOrBlockedPhase,
                workflow,
              );
              const selectedRunStatusLabel =
                selectedTimelineEntry && timelineDoneByEventId[selectedTimelineEntry.id]
                  ? `exitCode ${String(timelineDoneByEventId[selectedTimelineEntry.id]?.exitCode ?? 'null')}${timelineDoneByEventId[selectedTimelineEntry.id]?.timedOut ? ', timed out' : ''}`
                  : loadingTimelineEventId === selectedTimelineEntry?.id
                    ? 'opening logs'
                    : selectedTimelineDetail?.executionSummaryLabel ?? 'live or not loaded';
              const completedChecklist = new Set(workflow?.completedChecklist ?? []);
              const checklistScope = getChecklistScope(workflow, currentOrBlockedPhase);
              const remainingChecklist = getRemainingChecklistState(workflow, currentOrBlockedPhase);
              const checklistActionSuffix = getChecklistActionSuffix(remainingChecklist);
              const checklistActionTone = getChecklistActionTone(remainingChecklist);
              const inlineChecklistStyle =
                checklistActionTone === 'red'
                  ? { background: 'rgba(255,107,107,0.08)', color: 'var(--red)' }
                  : checklistActionTone === 'yellow'
                    ? { background: 'rgba(253,203,110,0.12)', color: 'var(--yellow)' }
                    : checklistActionTone === 'blue'
                      ? { background: 'rgba(116,185,255,0.12)', color: 'var(--blue)' }
                      : { background: 'var(--surface2)', color: 'var(--text)' };
              const checklistItems = checklistScope.map((item) => ({
                label: item.label,
                kind: item.kind,
                done: completedChecklist.has(item.id),
                highlighted: focusedChecklistItemId === item.id,
                ariaLabel: `${completedChecklist.has(item.id) ? 'Mark' : 'Complete'} checklist item ${item.label} for task ${task.title}`,
                onToggle: () => toggleChecklistMutation.mutate({ task, item: item.id }),
                disabled: toggleChecklistMutation.isPending,
              }));
              const drawerPhaseActions = [];
              if (workflow && canSendToReview(workflow)) {
                drawerPhaseActions.push({
                  key: 'review',
                  label: reviewAgent
                    ? (checklistActionSuffix ? `Send to ${reviewAgent.name} with ${checklistActionSuffix}` : `Send to ${reviewAgent.name}`)
                    : (checklistActionSuffix ? `Send to Review with ${checklistActionSuffix}` : 'Send to Review'),
                  ariaLabel: `Send task ${task.title} to review from drawer`,
                  onClick: () => {
                    if (!confirmChecklistHandoff(workflow, 'Send to review')) return;
                    transitionTaskPhase.mutate({ task, mode: 'review' });
                  },
                  disabled: transitionTaskPhase.isPending,
                  tone: checklistActionSuffix ? checklistActionTone : 'yellow' as const,
                });
              }
              if (workflow && activePhase) {
                drawerPhaseActions.push({
                  key: 'block',
                  label: 'Block Phase',
                  ariaLabel: `Block task ${task.title} from drawer`,
                  onClick: () => transitionTaskPhase.mutate({ task, mode: 'block' }),
                  disabled: transitionTaskPhase.isPending,
                  tone: 'red' as const,
                });
              }
              if (workflow && blockedPhase) {
                drawerPhaseActions.push({
                  key: 'resume',
                  label: 'Resume Phase',
                  ariaLabel: `Resume task ${task.title} from drawer`,
                  onClick: () => transitionTaskPhase.mutate({ task, mode: 'resume' }),
                  disabled: transitionTaskPhase.isPending,
                  tone: 'neutral' as const,
                });
              }
              if (workflow && canRunReview(workflow, task)) {
                drawerPhaseActions.push({
                  key: 'run-review',
                  label: 'Run Review',
                  ariaLabel: `Run review for task ${task.title} from drawer`,
                  onClick: () => runReviewMutation.mutate(task),
                  disabled: runReviewMutation.isPending,
                  tone: 'blue' as const,
                });
              }
              if (workflow && nextPhase) {
                drawerPhaseActions.push({
                  key: 'advance',
                  label: nextPhase.status === 'in_progress'
                    ? (checklistActionSuffix ? `Complete Phase (${checklistActionSuffix})` : 'Complete Phase')
                    : (checklistActionSuffix ? `Advance Phase (${checklistActionSuffix})` : 'Advance Phase'),
                  ariaLabel: `Advance task ${task.title} from drawer`,
                  onClick: () => {
                    if (!confirmChecklistHandoff(workflow, 'Advance phase')) return;
                    advanceTaskPhase.mutate(task);
                  },
                  disabled: advanceTaskPhase.isPending,
                  tone: checklistActionSuffix ? checklistActionTone : 'neutral' as const,
                });
              }
              const drawerRows = taskTimeline.map((entry) => {
                const detail = getTaskTimelineDetail(entry);
                const doneState = timelineDoneByEventId[entry.id];
                const replacementEntry = taskTimeline.find((candidate) => candidate.id === replacementTimelineEventIds[entry.id]);
                const actions = [];
                actions.push({
                  key: 'open',
                  label: 'Open',
                  ariaLabel: `Open drawer timeline event ${getTaskTimelineLabel(entry)} for task ${task.title}`,
                  onClick: () => setSelectedTimelineEventIds((current) => ({ ...current, [task.id]: entry.id })),
                  tone: 'neutral' as const,
                });
                if (detail.runId) {
                  actions.push({
                    key: 'logs',
                    label: 'Logs',
                    ariaLabel: `Load logs for drawer timeline event ${getTaskTimelineLabel(entry)} for task ${task.title}`,
                    onClick: () => openTimelineTail(entry),
                    tone: 'neutral' as const,
                  });
                }
                if (replacementEntry) {
                  actions.push({
                    key: 'jump',
                    label: 'Jump',
                    ariaLabel: `Jump to replacement drawer timeline event ${getTaskTimelineLabel(replacementEntry)} for task ${task.title}`,
                    onClick: () => setSelectedTimelineEventIds((current) => ({ ...current, [task.id]: replacementEntry.id })),
                    tone: 'blue' as const,
                  });
                }
                return {
                  id: entry.id,
                  label: getTaskTimelineLabel(entry),
                  outcome: detail.executionSummaryLabel ? `${detail.outcome} · ${detail.executionSummaryLabel}` : detail.outcome,
                  createdAt: detail.createdAt,
                  replacementLabel: supersededIds.includes(entry.id)
                    ? `replaced by ${replacementEntry ? getTaskTimelineLabel(replacementEntry) : 'retry'}`
                    : undefined,
                  doneText: doneState
                    ? `exitCode ${String(doneState.exitCode ?? 'null')}${doneState.timedOut ? ', timed out' : ''}`
                    : undefined,
                  isSelected: selectedTimelineEntry?.id === entry.id,
                  actions,
                };
              });
              return (
                <div
                  key={task.id}
                  style={{
                    display: 'flex',
                    alignItems: 'flex-start',
                    justifyContent: 'space-between',
                    padding: '8px 0',
                    borderBottom: '1px solid var(--border)',
                    gap: 12,
                  }}
                >
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontSize: 13, fontWeight: 600 }}>{task.title}</div>
                    {workflow ? (
                      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: 4 }}>
                        <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                        <span
                          style={{
                            padding: '2px 8px',
                            borderRadius: 999,
                            background: 'rgba(116,185,255,0.12)',
                            color: 'var(--blue)',
                            fontSize: 10,
                            fontWeight: 700,
                          }}
                        >
                          {workflow.name}
                        </span>
                        <span style={{ fontSize: 11, color: 'var(--text2)' }}>
                          {workflow.phases.length} phase{workflow.phases.length === 1 ? '' : 's'}
                        </span>
                        {checklistScope.length ? (
                          <span style={{ fontSize: 11, color: 'var(--text2)' }}>
                            phase checklist: {checklistScope.filter((item) => completedChecklist.has(item.id)).length}/{checklistScope.length}
                          </span>
                        ) : null}
                        {nextPhase ? <span style={{ fontSize: 11, color: 'var(--text2)' }}>next: {nextPhase.label}</span> : null}
                        {workflow.separationMode === 'enforced' ? (
                          <span style={{ fontSize: 11, color: 'var(--yellow)' }}>separate review required</span>
                        ) : null}
                        {assignedAgent ? <span style={{ fontSize: 11, color: 'var(--text2)' }}>agent: {assignedAgent.name}</span> : null}
                        {reviewAgent ? <span style={{ fontSize: 11, color: 'var(--text2)' }}>reviewer: {reviewAgent.name}</span> : null}
                        </div>
                        {workflow.lastBlockedReason ? (
                          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                            <span style={{ fontSize: 11, color: 'var(--red)' }}>{workflow.lastBlockedReason}</span>
                            {needsReviewerSetup(workflow) ? (
                              <>
                                {blockedReviewAgent ? (
                                  <button
                                    onClick={() => retryBlockedReviewMutation.mutate(task)}
                                    disabled={retryBlockedReviewMutation.isPending}
                                    aria-label={`Resume review for task ${task.title}`}
                                    style={{
                                      padding: '3px 8px',
                                      borderRadius: 999,
                                      border: '1px solid var(--border)',
                                      background: 'rgba(0,206,201,0.12)',
                                      color: 'var(--green)',
                                      fontSize: 10,
                                      fontWeight: 700,
                                      cursor: retryBlockedReviewMutation.isPending ? 'not-allowed' : 'pointer',
                                      opacity: retryBlockedReviewMutation.isPending ? 0.6 : 1,
                                    }}
                                  >
                                    {retryBlockedReviewMutation.isPending ? 'Resuming Review...' : `Resume Review with ${blockedReviewAgent.name}`}
                                  </button>
                                ) : null}
                                <button
                                  onClick={() => applySetupOperations('gear', ['gear-reviewer-agent'])}
                                  disabled={applySetupAxis.isPending}
                                  style={{
                                    padding: '3px 8px',
                                    borderRadius: 999,
                                    border: '1px solid var(--border)',
                                    background: 'rgba(116,185,255,0.12)',
                                    color: 'var(--blue)',
                                    fontSize: 10,
                                    fontWeight: 700,
                                    cursor: applySetupAxis.isPending ? 'not-allowed' : 'pointer',
                                    opacity: applySetupAxis.isPending ? 0.6 : 1,
                                  }}
                                >
                                  {applySetupAxis.isPending ? 'Applying Reviewer Setup...' : 'Apply Reviewer Setup'}
                                </button>
                                <button
                                  onClick={() => requestSetupFocus(['gear-reviewer-agent'])}
                                  style={{
                                    padding: '3px 8px',
                                    borderRadius: 999,
                                    border: '1px solid var(--border)',
                                    background: 'var(--surface2)',
                                    color: 'var(--text)',
                                    fontSize: 10,
                                    fontWeight: 700,
                                    cursor: 'pointer',
                                  }}
                                >
                                  Focus Reviewer Setup
                                </button>
                              </>
                            ) : null}
                          </div>
                        ) : null}
                        {workflowOutcome ? (
                          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                            <span style={{ fontSize: 11, color: workflowOutcome.color }}>{workflowOutcome.text}</span>
                          </div>
                        ) : null}
                        {isRetryingReview ? (
                          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                            <span style={{ fontSize: 11, color: 'var(--blue)' }}>retrying review...</span>
                          </div>
                        ) : null}
                        {latestActivitySummary ? (
                          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                            <span style={{ fontSize: 11, color: latestActivitySummary.color }}>{latestActivitySummary.text}</span>
                            <span style={{ fontSize: 11, color: 'var(--text2)' }}>{relativeTime(latestActivity!.createdAt)}</span>
                          </div>
                        ) : null}
                        {taskTimeline.length > 0 ? (
                          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
                            <span style={{ fontSize: 11, color: 'var(--text2)' }}>recent run timeline</span>
                            {taskTimeline.map((entry) => {
                              const tone = getTaskTimelineColor(entry.eventType);
                              return (
                                <button
                                  key={entry.id}
                                  onClick={() => setSelectedTimelineEventIds((current) => ({
                                    ...current,
                                    [task.id]: current[task.id] === entry.id ? undefined : entry.id,
                                  }))}
                                  aria-label={`Open timeline event ${getTaskTimelineLabel(entry)} for task ${task.title}`}
                                  style={{
                                    padding: '2px 8px',
                                    borderRadius: 999,
                                    background: tone.bg,
                                    color: tone.color,
                                    fontSize: 10,
                                    fontWeight: 700,
                                    border: selectedTimelineEventIds[task.id] === entry.id ? `1px solid ${tone.color}` : '1px solid transparent',
                                    cursor: 'pointer',
                                  }}
                                >
                                  {getTaskTimelineLabel(entry)}
                                </button>
                              );
                            })}
                            <button
                              onClick={() => setExpandedTimelineTaskIds((current) => ({
                                ...current,
                                [task.id]: !current[task.id],
                              }))}
                              aria-label={`${expandedTimelineTaskIds[task.id] ? 'Hide' : 'Open'} full timeline for task ${task.title}`}
                              style={{
                                padding: '2px 8px',
                                borderRadius: 999,
                                border: '1px solid var(--border)',
                                background: 'var(--surface2)',
                                color: 'var(--text2)',
                                fontSize: 10,
                                fontWeight: 700,
                                cursor: 'pointer',
                              }}
                            >
                              {expandedTimelineTaskIds[task.id] ? 'Hide Full Timeline' : 'Open Full Timeline'}
                            </button>
                            <button
                              onClick={() => {
                                if (!selectedTimelineEntry && preferredTimelineEntry) {
                                  setSelectedTimelineEventIds((current) => ({
                                    ...current,
                                    [task.id]: preferredTimelineEntry.id,
                                  }));
                                }
                                setDrawerTimelineTaskIds((current) => ({
                                  ...current,
                                  [task.id]: !current[task.id],
                                }));
                              }}
                              aria-label={`${drawerTimelineTaskIds[task.id] ? 'Close' : 'Open'} run drawer for task ${task.title}`}
                              style={{
                                padding: '2px 8px',
                                borderRadius: 999,
                                border: '1px solid var(--border)',
                                background: 'rgba(116,185,255,0.12)',
                                color: 'var(--blue)',
                                fontSize: 10,
                                fontWeight: 700,
                                cursor: 'pointer',
                              }}
                            >
                              {drawerTimelineTaskIds[task.id] ? 'Close Run Drawer' : 'Open Run Drawer'}
                            </button>
                          </div>
                        ) : null}
                        {expandedTimelineTaskIds[task.id] ? (
                          <div
                            style={{
                              display: 'flex',
                              flexDirection: 'column',
                              gap: 6,
                              padding: '8px 10px',
                              borderRadius: 8,
                              background: 'var(--surface2)',
                              border: '1px solid var(--border)',
                            }}
                          >
                            <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--text)' }}>Full Timeline</div>
                            {taskTimeline.map((entry) => {
                              const detail = getTaskTimelineDetail(entry);
                              const doneState = timelineDoneByEventId[entry.id];
                              const replacementEntry = taskTimeline.find((candidate) => candidate.id === replacementTimelineEventIds[entry.id]);
                              const isSelected = selectedTimelineEntry?.id === entry.id;
                              return (
                                <div
                                  key={`full-${entry.id}`}
                                  style={{
                                    display: 'flex',
                                    justifyContent: 'space-between',
                                    alignItems: 'center',
                                    gap: 8,
                                    padding: '6px 8px',
                                    borderRadius: 8,
                                    border: `1px solid ${isSelected ? 'var(--accent)' : 'var(--border)'}`,
                                    background: 'var(--surface)',
                                    color: 'var(--text)',
                                    fontSize: 10,
                                  }}
                                >
                                  <button
                                    onClick={() => setSelectedTimelineEventIds((current) => ({
                                      ...current,
                                      [task.id]: entry.id,
                                    }))}
                                    aria-label={`Open full timeline event ${getTaskTimelineLabel(entry)} for task ${task.title}`}
                                    style={{
                                      display: 'flex',
                                      flex: 1,
                                      justifyContent: 'space-between',
                                      alignItems: 'center',
                                      gap: 8,
                                      border: 'none',
                                      background: 'transparent',
                                      color: 'inherit',
                                      padding: 0,
                                      fontSize: 10,
                                      cursor: 'pointer',
                                      textAlign: 'left',
                                    }}
                                  >
                                    <span style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
                                      <span style={{ fontWeight: 700 }}>{getTaskTimelineLabel(entry)}</span>
                                      <span style={{ color: 'var(--text2)' }}>{detail.outcome}</span>
                                      <span style={{ color: 'var(--text2)' }}>{detail.createdAt}</span>
                                      {detail.executionSummaryLabel ? (
                                        <span style={{ color: 'var(--blue)' }}>{detail.executionSummaryLabel}</span>
                                      ) : null}
                                      {supersededIds.includes(entry.id) ? (
                                        <span style={{ color: 'var(--blue)' }}>
                                          replaced by {replacementEntry ? getTaskTimelineLabel(replacementEntry) : 'retry'}
                                        </span>
                                      ) : null}
                                    </span>
                                    {doneState ? (
                                      <span style={{ color: 'var(--text2)' }}>
                                        exitCode {String(doneState.exitCode ?? 'null')}
                                        {doneState.timedOut ? ', timed out' : ''}
                                      </span>
                                    ) : null}
                                  </button>
                                  <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                                    {detail.runId ? (
                                      <button
                                        onClick={() => openTimelineTail(entry)}
                                        aria-label={`Load logs for full timeline event ${getTaskTimelineLabel(entry)} for task ${task.title}`}
                                        style={{
                                          padding: '3px 8px',
                                          borderRadius: 999,
                                          border: '1px solid var(--border)',
                                          background: 'var(--surface2)',
                                          color: 'var(--text)',
                                          fontSize: 10,
                                          fontWeight: 700,
                                          cursor: 'pointer',
                                        }}
                                      >
                                        Logs
                                      </button>
                                    ) : null}
                                    {entry.eventType === 'task.failed' && isReviewTimelineEntry(entry) ? (
                                      <button
                                        onClick={() => {
                                          setRetrySourceTimelineEventIds((current) => ({ ...current, [task.id]: entry.id }));
                                          setRetryingTaskIds((current) => ({ ...current, [task.id]: true }));
                                          retryBlockedReviewMutation.mutate(task);
                                        }}
                                        aria-label={`Retry full timeline review for task ${task.title}`}
                                        style={{
                                          padding: '3px 8px',
                                          borderRadius: 999,
                                          border: '1px solid var(--border)',
                                          background: 'rgba(0,206,201,0.12)',
                                          color: 'var(--green)',
                                          fontSize: 10,
                                          fontWeight: 700,
                                          cursor: 'pointer',
                                        }}
                                      >
                                        Retry
                                      </button>
                                    ) : null}
                                    {replacementEntry ? (
                                      <button
                                        onClick={() => setSelectedTimelineEventIds((current) => ({
                                          ...current,
                                          [task.id]: replacementEntry.id,
                                        }))}
                                        aria-label={`Jump to replacement full timeline event ${getTaskTimelineLabel(replacementEntry)} for task ${task.title}`}
                                        style={{
                                          padding: '3px 8px',
                                          borderRadius: 999,
                                          border: '1px solid var(--border)',
                                          background: 'rgba(116,185,255,0.12)',
                                          color: 'var(--blue)',
                                          fontSize: 10,
                                          fontWeight: 700,
                                          cursor: 'pointer',
                                        }}
                                      >
                                        Jump
                                      </button>
                                    ) : null}
                                  </div>
                                </div>
                              );
                            })}
                          </div>
                        ) : null}
                        {selectedTimelineEntry ? (
                          <div
                            style={{
                              display: 'flex',
                              flexDirection: 'column',
                              gap: 4,
                              padding: '8px 10px',
                              borderRadius: 8,
                              background: 'var(--surface2)',
                              border: '1px solid var(--border)',
                            }}
                          >
                            <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--text)' }}>
                              Timeline Detail: {getTaskTimelineLabel(selectedTimelineEntry)}
                            </div>
                            <div style={{ fontSize: 10, color: 'var(--text2)' }}>
                              event: {selectedTimelineDetail?.eventLabel}
                            </div>
                            <div style={{ fontSize: 10, color: 'var(--text2)' }}>
                              phase: {selectedTimelineDetail?.phaseLine}
                            </div>
                            <div style={{ fontSize: 10, color: 'var(--text2)' }}>
                              outcome: {selectedTimelineDetail?.outcome}
                            </div>
                            <div style={{ fontSize: 10, color: 'var(--text2)' }}>
                              at: {selectedTimelineDetail?.createdAt}
                            </div>
                            {selectedTimelineDetail?.executionLines?.map((line) => (
                              <div key={`timeline-detail-execution-${line}`} style={{ fontSize: 10, color: 'var(--text2)' }}>
                                {line}
                              </div>
                            ))}
                            {timelineHistoryEntries.length > 0 ? (
                              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                                <span style={{ fontSize: 10, color: 'var(--text2)' }}>previous runs</span>
                                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                                  {timelineHistoryEntries.map((entry) => {
                                    const detail = getTaskTimelineDetail(entry);
                                    const doneState = timelineDoneByEventId[entry.id];
                                    const replacementEntry = taskTimeline.find((candidate) => candidate.id === replacementTimelineEventIds[entry.id]);
                                    return (
                                      <div
                                        key={entry.id}
                                        style={{
                                          display: 'flex',
                                          justifyContent: 'space-between',
                                          alignItems: 'center',
                                          gap: 8,
                                          padding: '6px 8px',
                                          borderRadius: 8,
                                          border: '1px solid var(--border)',
                                          background: 'var(--surface)',
                                          color: 'var(--text)',
                                          fontSize: 10,
                                          cursor: 'pointer',
                                          textAlign: 'left',
                                        }}
                                      >
                                        <button
                                          onClick={() => setSelectedTimelineEventIds((current) => ({
                                            ...current,
                                            [task.id]: entry.id,
                                          }))}
                                          aria-label={`Open previous timeline event ${getTaskTimelineLabel(entry)} for task ${task.title}`}
                                          style={{
                                            display: 'flex',
                                            flex: 1,
                                            justifyContent: 'space-between',
                                            alignItems: 'center',
                                            gap: 8,
                                            border: 'none',
                                            background: 'transparent',
                                            color: 'inherit',
                                            padding: 0,
                                            fontSize: 10,
                                            cursor: 'pointer',
                                            textAlign: 'left',
                                          }}
                                        >
                                          <span style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
                                          <span style={{ fontWeight: 700 }}>{getTaskTimelineLabel(entry)}</span>
                                          <span style={{ color: 'var(--text2)' }}>{detail.outcome}</span>
                                          {detail.executionSummaryLabel ? (
                                            <span style={{ color: 'var(--blue)' }}>{detail.executionSummaryLabel}</span>
                                          ) : null}
                                          {supersededIds.includes(entry.id) ? (
                                            <span style={{ color: 'var(--blue)' }}>
                                              replaced by {replacementEntry ? getTaskTimelineLabel(replacementEntry) : 'retry'}
                                              </span>
                                            ) : null}
                                          </span>
                                          {doneState ? (
                                            <span style={{ color: 'var(--text2)' }}>
                                              exitCode {String(doneState.exitCode ?? 'null')}
                                              {doneState.timedOut ? ', timed out' : ''}
                                            </span>
                                          ) : null}
                                        </button>
                                        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                                          {detail.runId ? (
                                            <button
                                              onClick={() => openTimelineTail(entry)}
                                              aria-label={`Load logs for previous timeline event ${getTaskTimelineLabel(entry)} for task ${task.title}`}
                                              style={{
                                                padding: '3px 8px',
                                                borderRadius: 999,
                                                border: '1px solid var(--border)',
                                                background: 'var(--surface2)',
                                                color: 'var(--text)',
                                                fontSize: 10,
                                                fontWeight: 700,
                                                cursor: 'pointer',
                                              }}
                                            >
                                              Logs
                                            </button>
                                          ) : null}
                                          {entry.eventType === 'task.failed' && isReviewTimelineEntry(entry) ? (
                                            <button
                                              onClick={() => {
                                                setRetrySourceTimelineEventIds((current) => ({ ...current, [task.id]: entry.id }));
                                                setRetryingTaskIds((current) => ({ ...current, [task.id]: true }));
                                                retryBlockedReviewMutation.mutate(task);
                                              }}
                                              aria-label={`Retry previous review for task ${task.title}`}
                                              style={{
                                                padding: '3px 8px',
                                                borderRadius: 999,
                                                border: '1px solid var(--border)',
                                                background: 'rgba(0,206,201,0.12)',
                                                color: 'var(--green)',
                                                fontSize: 10,
                                                fontWeight: 700,
                                                cursor: 'pointer',
                                              }}
                                            >
                                              Retry
                                            </button>
                                          ) : null}
                                          {replacementEntry ? (
                                            <button
                                              onClick={() => setSelectedTimelineEventIds((current) => ({
                                                ...current,
                                                [task.id]: replacementEntry.id,
                                              }))}
                                              aria-label={`Jump to replacement timeline event ${getTaskTimelineLabel(replacementEntry)} for task ${task.title}`}
                                              style={{
                                                padding: '3px 8px',
                                                borderRadius: 999,
                                                border: '1px solid var(--border)',
                                                background: 'rgba(116,185,255,0.12)',
                                                color: 'var(--blue)',
                                                fontSize: 10,
                                                fontWeight: 700,
                                                cursor: 'pointer',
                                              }}
                                            >
                                              Jump
                                            </button>
                                          ) : null}
                                        </div>
                                      </div>
                                    );
                                  })}
                                </div>
                              </div>
                            ) : null}
                            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                              {selectedTimelineDetail?.runId ? (
                                <button
                                  onClick={() => openTimelineTail(selectedTimelineEntry)}
                                  style={{
                                    padding: '4px 8px',
                                    borderRadius: 8,
                                    border: '1px solid var(--border)',
                                    background: 'var(--surface)',
                                    color: 'var(--text)',
                                    fontSize: 10,
                                    fontWeight: 700,
                                    cursor: 'pointer',
                                  }}
                                >
                                  {loadingTimelineEventId === selectedTimelineEntry.id ? 'Opening Run Tail...' : 'Load Run Logs'}
                                </button>
                              ) : null}
                              {selectedTimelineEntry.eventType === 'task.failed' && isReviewTimelineEntry(selectedTimelineEntry) ? (
                                <button
                                  onClick={() => {
                                    setRetrySourceTimelineEventIds((current) => ({ ...current, [task.id]: selectedTimelineEntry.id }));
                                    setRetryingTaskIds((current) => ({ ...current, [task.id]: true }));
                                    retryBlockedReviewMutation.mutate(task);
                                  }}
                                  style={{
                                    padding: '4px 8px',
                                    borderRadius: 8,
                                    border: '1px solid var(--border)',
                                    background: 'rgba(0,206,201,0.12)',
                                    color: 'var(--green)',
                                    fontSize: 10,
                                    fontWeight: 700,
                                    cursor: 'pointer',
                                  }}
                                >
                                  Retry Review
                                </button>
                              ) : null}
                            </div>
                            {timelineLogsByEventId[selectedTimelineEntry.id]?.length ? (
                              <div
                                style={{
                                  display: 'flex',
                                  flexDirection: 'column',
                                  gap: 4,
                                  padding: '8px 10px',
                                  borderRadius: 8,
                                  background: '#111',
                                  color: '#dfe6e9',
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  maxHeight: 120,
                                  overflow: 'auto',
                                }}
                              >
                                {timelineLogsByEventId[selectedTimelineEntry.id]!.map((line, index) => (
                                  <div key={`${selectedTimelineEntry.id}-${index}`}>{line}</div>
                                ))}
                              </div>
                            ) : null}
                            {timelineDoneByEventId[selectedTimelineEntry.id] ? (
                              <div style={{ fontSize: 10, color: 'var(--text2)' }}>
                                run finished: exitCode {String(timelineDoneByEventId[selectedTimelineEntry.id]?.exitCode ?? 'null')}
                                {timelineDoneByEventId[selectedTimelineEntry.id]?.timedOut ? ', timed out' : ''}
                              </div>
                            ) : null}
                          </div>
                        ) : null}
                        {drawerTimelineTaskIds[task.id] ? (
                          <Suspense fallback={<div style={{ fontSize: 11, color: 'var(--text2)' }}>Loading run drawer...</div>}>
                            <RunTimelineDrawer
                              title={task.title}
                              closeAriaLabel={`Close run drawer for task ${task.title}`}
                              onClose={() => setDrawerTimelineTaskIds((current) => ({ ...current, [task.id]: false }))}
                              description={task.description ?? 'No description'}
                              workflowName={workflow?.name ?? 'No workflow'}
                              workflowSourceLabel={workflow?.source ?? 'local'}
                              setupOriginLabels={setupOriginLabels}
                              separationModeLabel={workflow?.separationMode ?? 'n/a'}
                              alerts={effectiveOrchestrationAlerts}
                              currentPhaseLabel={activePhase?.label ?? blockedPhase?.label ?? 'n/a'}
                              phaseObjectiveLabel={phaseObjectiveLabel}
                              phasePolicyLines={effectivePhasePolicyLines}
                              phaseOwnerLabel={phaseOwnerLabel}
                              agentName={assignedAgent?.name ?? 'unassigned'}
                              agentCapabilityLabels={agentCapabilityLabels}
                              reviewerName={reviewAgent?.name ?? 'n/a'}
                              reviewerCapabilityLabels={reviewerCapabilityLabels}
                              selectedEventLabel={selectedTimelineEntry ? getTaskTimelineLabel(selectedTimelineEntry) : 'none'}
                              runStatusLabel={selectedRunStatusLabel}
                              executionBadges={selectedTimelineDetail?.executionBadges ?? []}
                              executionSummaryLines={selectedTimelineDetail?.executionLines ?? []}
                              phases={workflow?.phases ?? []}
                              checklistItems={checklistItems}
                              phaseActions={drawerPhaseActions}
                              rows={drawerRows}
                            />
                          </Suspense>
                        ) : null}
                        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                          {workflow.phases.map((phase) => (
                            <span
                              key={phase.id}
                              style={{
                                padding: '2px 8px',
                                borderRadius: 999,
                                background:
                                  phase.status === 'done'
                                    ? 'rgba(0,206,201,0.1)'
                                    : phase.status === 'in_progress'
                                      ? 'rgba(116,185,255,0.12)'
                                      : phase.status === 'blocked'
                                        ? 'rgba(255,107,107,0.12)'
                                        : 'var(--surface3)',
                                color:
                                  phase.status === 'done'
                                    ? 'var(--green)'
                                    : phase.status === 'in_progress'
                                      ? 'var(--blue)'
                                      : phase.status === 'blocked'
                                        ? 'var(--red)'
                                        : 'var(--text2)',
                                fontSize: 10,
                                fontWeight: 700,
                              }}
                            >
                              {phase.label}
                            </span>
                          ))}
                        </div>
                      </div>
                    ) : null}
                  </div>
                  {taskPhaseBlock ? (
                    <div
                      style={{
                        marginTop: 10,
                        padding: '10px 12px',
                        borderRadius: 10,
                        border: '1px solid rgba(255,107,107,0.18)',
                        background: 'rgba(255,107,107,0.08)',
                        display: 'flex',
                        flexDirection: 'column',
                        gap: 6,
                      }}
                    >
                      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--red)' }}>
                        Required checklist items are blocking {taskPhaseBlock.phaseLabel} handoff.
                      </div>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                        {taskPhaseBlock.requiredItems.map((item) => (
                          <button
                            key={`project-task-block-${task.id}-${item.id}`}
                            onClick={() => {
                              setDrawerTimelineTaskIds((current) => ({ ...current, [task.id]: true }));
                              setFocusedChecklistItemByTaskId((current) => ({ ...current, [task.id]: item.id }));
                              toggleChecklistMutation.mutate({ task, item: item.id });
                            }}
                            aria-label={`Complete required blocker ${item.label} for task ${task.title}`}
                            disabled={toggleChecklistMutation.isPending}
                            style={{
                              padding: '2px 8px',
                              borderRadius: 999,
                              border: '1px solid rgba(255,107,107,0.18)',
                              background: 'rgba(255,107,107,0.12)',
                              color: 'var(--red)',
                              fontSize: 10,
                              fontWeight: 700,
                              cursor: toggleChecklistMutation.isPending ? 'not-allowed' : 'pointer',
                              opacity: toggleChecklistMutation.isPending ? 0.6 : 1,
                            }}
                          >
                            {item.label}
                          </button>
                        ))}
                    </div>
                  </div>
                ) : null}
                  {handoffRetryState ? (
                    <div
                      style={{
                        marginTop: 10,
                        padding: '10px 12px',
                        borderRadius: 10,
                        border:
                          handoffRetryState.status === 'blocked'
                            ? '1px solid rgba(255,107,107,0.18)'
                            : handoffRetryState.status === 'started'
                              ? '1px solid rgba(0,206,201,0.18)'
                              : '1px solid rgba(116,185,255,0.18)',
                        background:
                          handoffRetryState.status === 'blocked'
                            ? 'rgba(255,107,107,0.08)'
                            : handoffRetryState.status === 'started'
                              ? 'rgba(0,206,201,0.08)'
                              : 'rgba(116,185,255,0.08)',
                        color:
                          handoffRetryState.status === 'blocked'
                            ? 'var(--red)'
                            : handoffRetryState.status === 'started'
                              ? 'var(--green)'
                              : 'var(--blue)',
                        fontSize: 11,
                        fontWeight: 700,
                      }}
                    >
                      {handoffRetryState.status === 'blocked'
                        ? 'Handoff blocked again. Resolve the remaining required checklist items.'
                        : handoffRetryState.status === 'started'
                          ? 'Handoff started. Follow the active phase or review run.'
                          : `Retrying ${handoffRetryState.action === 'review' ? 'review handoff' : 'phase advance'}...`}
                    </div>
                  ) : null}
                  {handoffReady ? (
                    <div
                      style={{
                        marginTop: 10,
                        padding: '10px 12px',
                        borderRadius: 10,
                        border: '1px solid rgba(0,206,201,0.18)',
                        background: 'rgba(0,206,201,0.08)',
                        display: 'flex',
                        justifyContent: 'space-between',
                        gap: 8,
                        alignItems: 'center',
                        flexWrap: 'wrap',
                      }}
                    >
                      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--green)' }}>
                        Required blockers cleared. Retry the handoff when ready.
                      </div>
                      <button
                        onClick={() => setDrawerTimelineTaskIds((current) => ({ ...current, [task.id]: true }))}
                        aria-label={`Open run drawer recovery for task ${task.title}`}
                        style={{
                          padding: '4px 8px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'var(--surface)',
                          color: 'var(--text)',
                          fontSize: 10,
                          fontWeight: 700,
                          cursor: 'pointer',
                        }}
                      >
                        Open Recovery
                      </button>
                      {recoveredWorkflow && canSendToReview(recoveredWorkflow) ? (
                        <button
                          onClick={() => {
                            setHandoffRetryStateByTaskId((current) => ({
                              ...current,
                              [task.id]: { status: 'starting', action: 'review' },
                            }));
                            transitionTaskPhase.mutate({
                              task: { ...task, metadata: { ...task.metadata, workflow: recoveredWorkflow } },
                              mode: 'review',
                            });
                          }}
                          aria-label={`Retry handoff to review for task ${task.title}`}
                          style={{
                            padding: '4px 8px',
                            borderRadius: 8,
                            border: '1px solid rgba(253,203,110,0.18)',
                            background: 'rgba(253,203,110,0.12)',
                            color: 'var(--yellow)',
                            fontSize: 10,
                            fontWeight: 700,
                            cursor: 'pointer',
                          }}
                        >
                          Retry Send to Review
                        </button>
                      ) : recoveredWorkflow && getNextPhase(recoveredWorkflow) ? (
                        <button
                          onClick={() => {
                            setHandoffRetryStateByTaskId((current) => ({
                              ...current,
                              [task.id]: { status: 'starting', action: 'advance' },
                            }));
                            advanceTaskPhase.mutate({
                              ...task,
                              metadata: { ...task.metadata, workflow: recoveredWorkflow },
                            });
                          }}
                          aria-label={`Retry phase advance for task ${task.title}`}
                          style={{
                            padding: '4px 8px',
                            borderRadius: 8,
                            border: '1px solid rgba(0,206,201,0.18)',
                            background: 'rgba(0,206,201,0.08)',
                            color: 'var(--green)',
                            fontSize: 10,
                            fontWeight: 700,
                            cursor: 'pointer',
                          }}
                        >
                          Retry Advance Phase
                        </button>
                      ) : null}
                    </div>
                  ) : null}
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
                    {workflow && canSendToReview(workflow) ? (
                      <button
                        onClick={() => {
                          if (!confirmChecklistHandoff(workflow, 'Send to review')) return;
                          transitionTaskPhase.mutate({ task, mode: 'review' });
                        }}
                        disabled={transitionTaskPhase.isPending}
                        aria-label={`Send task ${task.title} to review`}
                        style={{
                          padding: '5px 10px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: checklistActionSuffix ? inlineChecklistStyle.background : 'rgba(253,203,110,0.12)',
                          color: checklistActionSuffix ? inlineChecklistStyle.color : 'var(--yellow)',
                          fontSize: 11,
                          fontWeight: 700,
                          cursor: transitionTaskPhase.isPending ? 'not-allowed' : 'pointer',
                          opacity: transitionTaskPhase.isPending ? 0.6 : 1,
                        }}
                      >
                        {reviewAgent
                          ? (checklistActionSuffix ? `Send to ${reviewAgent.name} (${checklistActionSuffix})` : `Send to ${reviewAgent.name}`)
                          : (checklistActionSuffix ? `Send to Review (${checklistActionSuffix})` : 'Send to Review')}
                      </button>
                    ) : null}
                    {workflow && activePhase ? (
                      <button
                        onClick={() => transitionTaskPhase.mutate({ task, mode: 'block' })}
                        disabled={transitionTaskPhase.isPending}
                        aria-label={`Block task ${task.title}`}
                        style={{
                          padding: '5px 10px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'rgba(255,107,107,0.08)',
                          color: 'var(--red)',
                          fontSize: 11,
                          fontWeight: 600,
                          cursor: transitionTaskPhase.isPending ? 'not-allowed' : 'pointer',
                          opacity: transitionTaskPhase.isPending ? 0.6 : 1,
                        }}
                      >
                        Block Phase
                      </button>
                    ) : null}
                    {workflow && blockedPhase ? (
                      <button
                        onClick={() => transitionTaskPhase.mutate({ task, mode: 'resume' })}
                        disabled={transitionTaskPhase.isPending}
                        aria-label={`Resume task ${task.title}`}
                        style={{
                          padding: '5px 10px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'var(--surface2)',
                          color: 'var(--text)',
                          fontSize: 11,
                          fontWeight: 600,
                          cursor: transitionTaskPhase.isPending ? 'not-allowed' : 'pointer',
                          opacity: transitionTaskPhase.isPending ? 0.6 : 1,
                        }}
                      >
                        Resume Phase
                      </button>
                    ) : null}
                    {workflow && canRunReview(workflow, task) ? (
                      <button
                        onClick={() => runReviewMutation.mutate(task)}
                        disabled={runReviewMutation.isPending}
                        aria-label={`Run review for task ${task.title}`}
                        style={{
                          padding: '5px 10px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'rgba(116,185,255,0.12)',
                          color: 'var(--blue)',
                          fontSize: 11,
                          fontWeight: 700,
                          cursor: runReviewMutation.isPending ? 'not-allowed' : 'pointer',
                          opacity: runReviewMutation.isPending ? 0.6 : 1,
                        }}
                      >
                        Run Review
                      </button>
                    ) : null}
                    {workflow && nextPhase ? (
                      <button
                        onClick={() => {
                          if (!confirmChecklistHandoff(workflow, 'Advance phase')) return;
                          advanceTaskPhase.mutate(task);
                        }}
                        disabled={advanceTaskPhase.isPending}
                        aria-label={`Advance task ${task.title}`}
                        style={{
                          padding: '5px 10px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: checklistActionSuffix ? inlineChecklistStyle.background : 'var(--surface2)',
                          color: checklistActionSuffix ? inlineChecklistStyle.color : 'var(--text)',
                          fontSize: 11,
                          fontWeight: 600,
                          cursor: advanceTaskPhase.isPending ? 'not-allowed' : 'pointer',
                          opacity: advanceTaskPhase.isPending ? 0.6 : 1,
                        }}
                      >
                        {nextPhase.status === 'in_progress'
                          ? (checklistActionSuffix ? `Complete Phase (${checklistActionSuffix})` : 'Complete Phase')
                          : (checklistActionSuffix ? `Advance Phase (${checklistActionSuffix})` : 'Advance Phase')}
                      </button>
                    ) : null}
                    <span
                      style={{
                        padding: '2px 8px',
                        borderRadius: 6,
                        fontSize: 11,
                        fontWeight: 600,
                        background: s.bg,
                        color: s.color,
                        whiteSpace: 'nowrap',
                      }}
                    >
                      {task.status}
                    </span>
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        {/* 13. 관련 프로젝트 */}
        {(relations ?? []).length > 0 && (
          <div style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12 }}>
            <div style={{ padding: '14px 18px', borderBottom: '1px solid var(--border)', fontSize: 14, fontWeight: 600 }}>
              Related Projects
            </div>
            <div style={{ padding: '8px 18px' }}>
              {(relations ?? []).map((rel) => {
                const other = rel.sourceProject.id === id ? rel.targetProject : rel.sourceProject;
                const direction = rel.sourceProject.id === id ? '→' : '←';
                return (
                  <div
                    key={rel.id}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 8,
                      padding: '8px 0',
                      borderBottom: '1px solid var(--border)',
                      cursor: 'pointer',
                    }}
                    onClick={() => navigate(`/projects/${other.id}`)}
                  >
                    <span style={{ fontSize: 13, color: 'var(--text2)' }}>{direction}</span>
                    <span style={{ fontSize: 13, fontWeight: 500 }}>{other.name}</span>
                    <span
                      style={{
                        padding: '2px 8px',
                        borderRadius: 6,
                        fontSize: 11,
                        background: 'var(--surface3)',
                        color: 'var(--text2)',
                      }}
                    >
                      {rel.type}
                    </span>
                  </div>
                );
              })}
            </div>
          </div>
        )}
      </div>

      {/* 14. Feature 5: Inline Task Input Bar (sticky bottom) */}
      {id && <TaskInputBar projectId={id} workflowTemplates={workflowTaskTemplates} />}

    </div>
  );
}
