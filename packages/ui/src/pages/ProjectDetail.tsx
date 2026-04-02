import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useParams, useNavigate, useSearchParams } from 'react-router-dom';
import { useState, useRef, useEffect } from 'react';
import { api } from '../api/client.js';

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
      phases: Array<{
        id: string;
        label: string;
        objective?: string;
        enforceSeparation?: boolean;
        status?: 'pending' | 'in_progress' | 'done' | 'blocked';
      }>;
      checklist: string[];
    };
  };
  status: string;
  createdAt: string;
}

type TaskWorkflow = NonNullable<NonNullable<Task['metadata']>['workflow']>;

interface CostByProject {
  projectId: string;
  projectName: string;
  totalUsd: number;
  tokensIn: number;
  tokensOut: number;
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

// ─── Utility Functions ────────────────────────────────────────────────────────

function formatUsd(n: number) {
  return `$${n.toFixed(4)}`;
}

function formatTokens(n: number) {
  return n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : n >= 1000 ? `${(n / 1000).toFixed(0)}K` : String(n);
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

function getTaskActivityTimeline(events: ActivityEvent[], taskId: string) {
  return events
    .filter((event) => event.detail.taskId === taskId && event.eventType.startsWith('task.'))
    .slice(0, 3);
}

function getTaskActivitySummary(entry?: ActivityEvent) {
  if (!entry) return null;

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
      text: isReviewRun ? 'Review run started.' : 'Run started.',
      color: 'var(--blue)',
    };
  }

  if (entry.eventType === 'task.completed') {
    return {
      text: isReviewRun ? 'Last review passed.' : 'Last run passed.',
      color: 'var(--green)',
    };
  }

  if (entry.eventType === 'task.failed') {
    return {
      text: isReviewRun ? 'Last review failed.' : 'Last run failed.',
      color: 'var(--red)',
    };
  }

  return null;
}

function getTaskTimelineLabel(entry: ActivityEvent) {
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

  return entry.eventType.replace('task.', '');
}

function getTaskTimelineColor(eventType: string) {
  if (eventType === 'task.started') return { bg: 'rgba(116,185,255,0.12)', color: 'var(--blue)' };
  if (eventType === 'task.completed') return { bg: 'rgba(0,206,201,0.12)', color: 'var(--green)' };
  if (eventType === 'task.failed') return { bg: 'rgba(255,107,107,0.12)', color: 'var(--red)' };
  return { bg: 'var(--surface3)', color: 'var(--text2)' };
}

function getTaskTimelineDetail(entry: ActivityEvent) {
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
    outcome: workflowPhase?.outcome ?? 'unchanged',
    createdAt: relativeTime(entry.createdAt),
    runId: typeof entry.detail.runId === 'string' ? entry.detail.runId : undefined,
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
                {selectedTemplate.checklist.map((item) => (
                  <div key={item} style={{ fontSize: 11, color: 'var(--text2)' }}>
                    - {item}
                  </div>
                ))}
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
  const [selectedTimelineEventIds, setSelectedTimelineEventIds] = useState<Record<string, string | undefined>>({});
  const [timelineLogsByEventId, setTimelineLogsByEventId] = useState<Record<string, string[] | undefined>>({});
  const [timelineDoneByEventId, setTimelineDoneByEventId] = useState<Record<string, { exitCode: number | null; timedOut: boolean } | undefined>>({});
  const [loadingTimelineEventId, setLoadingTimelineEventId] = useState<string | null>(null);
  const timelineStreamRefs = useRef<Record<string, EventSource | undefined>>({});
  const [setupFocusRequest, setSetupFocusRequest] = useState<{ operationIds: string[]; token: number } | undefined>(undefined);

  useEffect(() => {
    return () => {
      Object.values(timelineStreamRefs.current).forEach((stream) => stream?.close());
      timelineStreamRefs.current = {};
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

  // ── Queries ────────────────────────────────────────────────────────────────

  const { data: project, isLoading } = useQuery({
    queryKey: ['project', id],
    queryFn: () => api.get<Project>(`/projects/${id}`),
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

  const { data: allTasks } = useQuery({
    queryKey: ['tasks'],
    queryFn: () => api.get<Task[]>('/tasks'),
  });

  const { data: projectActivity = [] } = useQuery({
    queryKey: ['activity', id, 'task-outcomes'],
    queryFn: () => api.get<ActivityEvent[]>(`/activity?projectId=${id}&limit=20`),
    enabled: !!id,
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
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
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
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
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
      return api.post(`/tasks/${task.id}/run`, { agentId: reviewer.id });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
      queryClient.invalidateQueries({ queryKey: ['agents'] });
    },
  });

  // ── Derived data ───────────────────────────────────────────────────────────

  const agents = (allAgents ?? []).filter((a) => a.projectId === id);
  const tasks = (allTasks ?? []).filter((t) => t.projectId === id).slice(0, 10);
  const cost = (costsByProject ?? []).find((c) => c.projectId === id);

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
  const workflowTaskTemplates: WorkflowTaskTemplate[] = workflowPreview.map((workflow) => ({
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
  }));

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
              const latestActivity = getLatestTaskActivity(projectActivity, task.id);
              const latestActivitySummary = getTaskActivitySummary(latestActivity);
              const taskTimeline = getTaskActivityTimeline(projectActivity, task.id);
              const selectedTimelineEntry = taskTimeline.find((entry) => entry.id === selectedTimelineEventIds[task.id]);
              const selectedTimelineDetail = selectedTimelineEntry ? getTaskTimelineDetail(selectedTimelineEntry) : null;
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
                                  onClick={() => retryBlockedReviewMutation.mutate(task)}
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
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
                    {workflow && canSendToReview(workflow) ? (
                      <button
                        onClick={() => transitionTaskPhase.mutate({ task, mode: 'review' })}
                        disabled={transitionTaskPhase.isPending}
                        aria-label={`Send task ${task.title} to review`}
                        style={{
                          padding: '5px 10px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'rgba(253,203,110,0.12)',
                          color: 'var(--yellow)',
                          fontSize: 11,
                          fontWeight: 700,
                          cursor: transitionTaskPhase.isPending ? 'not-allowed' : 'pointer',
                          opacity: transitionTaskPhase.isPending ? 0.6 : 1,
                        }}
                      >
                        {reviewAgent ? `Send to ${reviewAgent.name}` : 'Send to Review'}
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
                        onClick={() => advanceTaskPhase.mutate(task)}
                        disabled={advanceTaskPhase.isPending}
                        aria-label={`Advance task ${task.title}`}
                        style={{
                          padding: '5px 10px',
                          borderRadius: 8,
                          border: '1px solid var(--border)',
                          background: 'var(--surface2)',
                          color: 'var(--text)',
                          fontSize: 11,
                          fontWeight: 600,
                          cursor: advanceTaskPhase.isPending ? 'not-allowed' : 'pointer',
                          opacity: advanceTaskPhase.isPending ? 0.6 : 1,
                        }}
                      >
                        {nextPhase.status === 'in_progress' ? 'Complete Phase' : 'Advance Phase'}
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
