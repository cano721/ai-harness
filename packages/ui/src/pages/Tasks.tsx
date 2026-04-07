import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { Suspense, lazy, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { api } from '../api/client.js';
import { parseExecutionEvidence } from './taskExecutionEvidence.js';

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
      source?: string;
      separationMode: 'advisory' | 'enforced';
      lastCompletedPhaseId?: string;
      lastCompletedAgentId?: string;
      lastBlockedReason?: string;
      checklist?: string[];
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
        status?: 'pending' | 'in_progress' | 'done' | 'blocked';
        enforceSeparation?: boolean;
      }>;
    };
  };
  status: string;
  createdAt: string;
  updatedAt: string;
}

type TaskWorkflow = NonNullable<NonNullable<Task['metadata']>['workflow']>;
type ChecklistEntry = { id: string; label: string; kind: 'required' | 'advisory' | 'evidence' };

const RunTimelineDrawer = lazy(() => import('../components/RunTimelineDrawer.js'));

interface ActivityEntry {
  id: string;
  projectId?: string;
  eventType: string;
  detail: Record<string, unknown>;
  createdAt: string;
}

interface Agent {
  id: string;
  projectId: string;
  name: string;
  adapterType: string;
  status: string;
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

const statusStyle: Record<string, { bg: string; color: string }> = {
  todo: { bg: 'var(--surface3)', color: 'var(--text2)' },
  in_progress: { bg: 'rgba(116,185,255,0.1)', color: 'var(--blue)' },
  done: { bg: 'rgba(0,206,201,0.1)', color: 'var(--green)' },
  blocked: { bg: 'rgba(255,107,107,0.1)', color: 'var(--red)' },
};

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

function getLatestTaskActivity(events: ActivityEntry[], taskId: string) {
  return events.find((event) => event.detail.taskId === taskId && event.eventType.startsWith('task.'));
}

function getExecutionSnapshotKey(entry: ActivityEntry) {
  const execution = parseExecutionEvidence(entry.detail);
  if (!execution) return null;
  return `${execution.queueState}/${execution.workerStatus}/${execution.workerHealth}/${execution.workerCapacityLabel}`;
}

function hasExecutionEvidence(entry: ActivityEntry) {
  return parseExecutionEvidence(entry.detail) !== null;
}

function getPreferredTimelineEntry(entries: ActivityEntry[]) {
  return entries.find((entry) => hasExecutionEvidence(entry)) ?? entries[0];
}

function getTaskActivityTimeline(events: ActivityEntry[], taskId: string) {
  const taskEvents = events.filter((event) => event.detail.taskId === taskId && event.eventType.startsWith('task.'));
  if (taskEvents.length <= 3) return taskEvents;

  const selected: ActivityEntry[] = [];
  const selectedIds = new Set<string>();
  const remember = (entry: ActivityEntry) => {
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

function getTaskActivitySummary(entry?: ActivityEntry) {
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

function getTaskTimelineLabel(entry: ActivityEntry) {
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

function getTaskTimelineDetail(entry: ActivityEntry) {
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
    createdAt: new Date(entry.createdAt).toLocaleString(),
    runId: typeof entry.detail.runId === 'string' ? entry.detail.runId : undefined,
    executionSummaryLabel: execution?.summaryLabel,
    executionBadges: execution?.badges ?? [],
    executionLines: execution?.lines ?? [],
  };
}

function isReviewTimelineEntry(entry: ActivityEntry) {
  const workflowPhase = entry.detail.workflowPhase as {
    from?: string;
    to?: string;
  } | undefined;
  const label = `${workflowPhase?.from ?? ''} ${workflowPhase?.to ?? ''}`.toLowerCase();
  return label.includes('review');
}

export function Tasks() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { data: tasks, isLoading } = useQuery({ queryKey: ['tasks'], queryFn: () => api.get<Task[]>('/tasks') });
  const { data: agents } = useQuery({ queryKey: ['agents'], queryFn: () => api.get<Agent[]>('/agents') });
  const { data: activity = [] } = useQuery({
    queryKey: ['activity', 'tasks-page'],
    queryFn: () => api.get<ActivityEntry[]>('/activity?limit=100'),
    refetchInterval: 15_000,
    refetchIntervalInBackground: true,
  });
  const [showCreate, setShowCreate] = useState(false);
  const [title, setTitle] = useState('');
  const [projectId, setProjectId] = useState('');
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
  const [, setExecutionEvidenceClock] = useState(() => Date.now());
  const timelineStreamRefs = useRef<Record<string, EventSource | undefined>>({});
  const { data: projects } = useQuery({ queryKey: ['projects'], queryFn: () => api.get<any[]>('/projects') });

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

  const createMutation = useMutation({
    mutationFn: () => api.post('/tasks', { projectId: projectId || (projects?.[0]?.id), title }),
    onSuccess: () => { queryClient.invalidateQueries({ queryKey: ['tasks'] }); setShowCreate(false); setTitle(''); },
  });

  const advanceTaskPhase = useMutation({
    mutationFn: async (task: Task) => {
      const workflow = task.metadata?.workflow;
      if (!workflow) return null;

      const next = advanceWorkflow(workflow);
      return api.patch(`/tasks/${task.id}`, {
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
      const reviewer = mode === 'review' ? pickReviewerAgent(agents ?? [], task) : null;

      const next =
        mode === 'review'
          ? sendWorkflowToReview(workflow)
          : mode === 'block'
            ? blockWorkflow(workflow)
            : resumeWorkflow(workflow);

      return api.patch(`/tasks/${task.id}`, {
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
      if (!workflow) return;
      return api.patch(`/tasks/${task.id}`, {
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
      queryClient.invalidateQueries({ queryKey: ['activity'] });
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
      queryClient.invalidateQueries({ queryKey: ['activity', 'tasks-page'] });
    },
  });

  const retryBlockedReviewMutation = useMutation({
    mutationFn: async (task: Task) => {
      const workflow = task.metadata?.workflow;
      if (!workflow) return null;
      const reviewer = pickReviewerAgent(agents ?? [], task);
      if (!reviewer) return null;
      const resumed = resumeWorkflow(workflow);
      await api.patch(`/tasks/${task.id}`, {
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
      queryClient.invalidateQueries({ queryKey: ['activity', 'tasks-page'] });
    },
  });

  const applyReviewerSetup = useMutation({
    mutationFn: async (task: Task) => (
      api.post(`/projects/${task.projectId}/setup/apply`, {
        axes: ['gear'],
        operationIds: ['gear-reviewer-agent'],
      })
    ),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
      queryClient.invalidateQueries({ queryKey: ['agents'] });
      queryClient.invalidateQueries({ queryKey: ['projects'] });
    },
  });

  const inputStyle = { width: '100%', padding: '8px 12px', background: 'var(--surface3)', border: '1px solid var(--border)', borderRadius: 8, color: 'var(--text)', fontSize: 13, outline: 'none' } as const;

  const openTimelineTail = (entry: ActivityEntry) => {
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
    const retryEvent = activity.find((entry) => (
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
  }, [activity, pendingRetryTailTaskId, retrySourceTimelineEventIds, selectedTimelineEventIds]);

  return (
    <div style={{ padding: '24px 28px' }}>
      <div style={{ padding: '16px 0 24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 style={{ fontSize: 20, fontWeight: 700 }}>Tasks</h1>
        <button onClick={() => setShowCreate(!showCreate)} style={{ padding: '7px 14px', borderRadius: 8, border: '1px solid var(--accent)', background: 'var(--accent)', color: '#fff', fontSize: 12, cursor: 'pointer' }}>+ New Task</button>
      </div>

      {showCreate && (
        <div style={{ padding: 16, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, marginBottom: 16 }}>
          <input style={inputStyle} value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Task description..." />
          <div style={{ display: 'flex', gap: 8, marginTop: 8, justifyContent: 'flex-end' }}>
            <button onClick={() => setShowCreate(false)} style={{ padding: '6px 12px', borderRadius: 6, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 12, cursor: 'pointer' }}>Cancel</button>
            <button onClick={() => createMutation.mutate()} disabled={!title} style={{ padding: '6px 12px', borderRadius: 6, border: 'none', background: 'var(--accent)', color: '#fff', fontSize: 12, cursor: title ? 'pointer' : 'not-allowed', opacity: title ? 1 : 0.5 }}>Create</button>
          </div>
        </div>
      )}

      {isLoading ? <div style={{ color: 'var(--text2)' }}>Loading...</div> : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {(tasks ?? []).length === 0 ? (
            <div style={{ padding: 40, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 12, textAlign: 'center', color: 'var(--text2)' }}>
              <div style={{ fontSize: 32, marginBottom: 8 }}>📋</div>
              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>No tasks yet</div>
            </div>
          ) : (tasks ?? []).map((task) => {
            const s = statusStyle[task.status] ?? statusStyle.todo;
            const workflow = task.metadata?.workflow;
            const nextPhase = getNextPhase(workflow);
            const activePhase = getActivePhase(workflow);
            const blockedPhase = getBlockedPhase(workflow);
            const assignedAgent = (agents ?? []).find((agent) => agent.id === task.agentId);
            const reviewAgent = workflow && canSendToReview(workflow) ? pickReviewerAgent(agents ?? [], task) : null;
            const blockedReviewAgent =
              workflow && blockedPhase?.enforceSeparation
                ? pickReviewerAgent(agents ?? [], task)
                : null;
            const workflowOutcome = getWorkflowOutcomeSummary(task, workflow);
            const taskPhaseBlock = phaseBlockByTaskId[task.id];
            const focusedChecklistItemId = focusedChecklistItemByTaskId[task.id];
            const handoffReady = handoffReadyByTaskId[task.id] === true;
            const recoveredWorkflow = recoveredWorkflowByTaskId[task.id];
            const handoffRetryState = handoffRetryStateByTaskId[task.id];
            const latestActivity = getLatestTaskActivity(activity, task.id);
            const latestActivitySummary = getTaskActivitySummary(latestActivity);
            const taskTimeline = getTaskActivityTimeline(activity, task.id);
            const selectedTimelineEntry = taskTimeline.find((entry) => entry.id === selectedTimelineEventIds[task.id]);
            const selectedTimelineDetail = selectedTimelineEntry ? getTaskTimelineDetail(selectedTimelineEntry) : null;
            const preferredTimelineEntry = getPreferredTimelineEntry(taskTimeline);
            const timelineHistoryEntries = (timelineHistoryEventIds[task.id] ?? [])
              .map((eventId) => taskTimeline.find((entry) => entry.id === eventId))
              .filter((entry): entry is ActivityEntry => !!entry && entry.id !== selectedTimelineEntry?.id);
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
            const inlineChecklistState = getRemainingChecklistState(workflow, currentOrBlockedPhase);
            const inlineChecklistSuffix = getChecklistActionSuffix(inlineChecklistState);
            const inlineChecklistTone = getChecklistActionTone(inlineChecklistState);
            const inlineChecklistStyle =
              inlineChecklistTone === 'red'
                ? { background: 'rgba(255,107,107,0.08)', color: 'var(--red)' }
                : inlineChecklistTone === 'yellow'
                  ? { background: 'rgba(253,203,110,0.12)', color: 'var(--yellow)' }
                  : inlineChecklistTone === 'blue'
                    ? { background: 'rgba(116,185,255,0.12)', color: 'var(--blue)' }
                    : { background: 'var(--surface2)', color: 'var(--text)' };
            const completedChecklist = new Set(workflow?.completedChecklist ?? []);
            const checklistScope = getChecklistScope(workflow, currentOrBlockedPhase);
            const remainingChecklist = getRemainingChecklistState(workflow, currentOrBlockedPhase);
            const checklistActionSuffix = getChecklistActionSuffix(remainingChecklist);
            const checklistActionTone = getChecklistActionTone(remainingChecklist);
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
              <div key={task.id} style={{ display: 'flex', alignItems: 'flex-start', gap: 12, padding: '12px 18px', background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 10 }}>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 13, fontWeight: 500 }}>{task.title}</div>
                  {workflow ? (
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: 4 }}>
                      <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                        <span style={{ padding: '2px 8px', borderRadius: 999, background: 'rgba(116,185,255,0.12)', color: 'var(--blue)', fontSize: 10, fontWeight: 700 }}>
                          {workflow.name}
                        </span>
                        <span style={{ fontSize: 10, color: 'var(--text2)' }}>{workflow.phases.length} phases</span>
                        {nextPhase ? <span style={{ fontSize: 10, color: 'var(--text2)' }}>next: {nextPhase.label}</span> : null}
                        {checklistScope.length ? (
                          <span style={{ fontSize: 10, color: 'var(--text2)' }}>
                            phase checklist: {checklistScope.filter((item) => completedChecklist.has(item.id)).length}/{checklistScope.length}
                          </span>
                        ) : null}
                        {workflow.separationMode === 'enforced' ? (
                          <span style={{ fontSize: 10, color: 'var(--yellow)' }}>separate review required</span>
                        ) : null}
                        {assignedAgent ? <span style={{ fontSize: 10, color: 'var(--text2)' }}>agent: {assignedAgent.name}</span> : null}
                        {reviewAgent ? <span style={{ fontSize: 10, color: 'var(--text2)' }}>reviewer: {reviewAgent.name}</span> : null}
                      </div>
                      {workflow.lastBlockedReason ? (
                        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                          <span style={{ fontSize: 10, color: 'var(--red)' }}>{workflow.lastBlockedReason}</span>
                          {needsReviewerSetup(workflow) ? (
                            <>
                              {blockedReviewAgent ? (
                                <button
                                  onClick={() => retryBlockedReviewMutation.mutate(task)}
                                  disabled={retryBlockedReviewMutation.isPending}
                                  aria-label={`Resume review for task ${task.title}`}
                                  style={{ padding: '3px 8px', borderRadius: 999, border: '1px solid var(--border)', background: 'rgba(0,206,201,0.12)', color: 'var(--green)', fontSize: 10, fontWeight: 700, cursor: retryBlockedReviewMutation.isPending ? 'not-allowed' : 'pointer', opacity: retryBlockedReviewMutation.isPending ? 0.6 : 1 }}
                                >
                                  {retryBlockedReviewMutation.isPending ? 'Resuming Review...' : `Resume Review with ${blockedReviewAgent.name}`}
                                </button>
                              ) : null}
                              <button
                                onClick={() => applyReviewerSetup.mutate(task)}
                                disabled={applyReviewerSetup.isPending}
                                style={{ padding: '3px 8px', borderRadius: 999, border: '1px solid var(--border)', background: 'rgba(116,185,255,0.12)', color: 'var(--blue)', fontSize: 10, fontWeight: 700, cursor: applyReviewerSetup.isPending ? 'not-allowed' : 'pointer', opacity: applyReviewerSetup.isPending ? 0.6 : 1 }}
                              >
                                {applyReviewerSetup.isPending ? 'Applying Reviewer Setup...' : 'Apply Reviewer Setup'}
                              </button>
                              <button
                                onClick={() => navigate(`/projects/${task.projectId}?setupAxes=gear&setupOps=gear-reviewer-agent&setupExpanded=gear`)}
                                style={{ padding: '3px 8px', borderRadius: 999, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 10, fontWeight: 700, cursor: 'pointer' }}
                              >
                                Open Reviewer Setup
                              </button>
                            </>
                          ) : null}
                        </div>
                      ) : null}
                      {workflowOutcome ? (
                        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                          <span style={{ fontSize: 10, color: workflowOutcome.color }}>{workflowOutcome.text}</span>
                        </div>
                      ) : null}
                      {isRetryingReview ? (
                        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                          <span style={{ fontSize: 10, color: 'var(--blue)' }}>retrying review...</span>
                        </div>
                      ) : null}
                      {latestActivitySummary ? (
                        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                          <span style={{ fontSize: 10, color: latestActivitySummary.color }}>{latestActivitySummary.text}</span>
                          <span style={{ fontSize: 10, color: 'var(--text2)' }}>
                            {new Date(latestActivity!.createdAt).toLocaleString()}
                          </span>
                        </div>
                      ) : null}
                      {taskTimeline.length > 0 ? (
                        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
                          <span style={{ fontSize: 10, color: 'var(--text2)' }}>recent run timeline</span>
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
                  <div style={{ fontSize: 11, color: 'var(--text2)', marginTop: 2 }}>{new Date(task.createdAt).toLocaleString()}</div>
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
                            key={`task-block-${task.id}-${item.id}`}
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
                      style={{ padding: '5px 10px', borderRadius: 8, border: '1px solid var(--border)', background: inlineChecklistSuffix ? inlineChecklistStyle.background : 'rgba(253,203,110,0.12)', color: inlineChecklistSuffix ? inlineChecklistStyle.color : 'var(--yellow)', fontSize: 11, fontWeight: 700, cursor: transitionTaskPhase.isPending ? 'not-allowed' : 'pointer', opacity: transitionTaskPhase.isPending ? 0.6 : 1 }}
                    >
                      {reviewAgent
                        ? (inlineChecklistSuffix ? `Send to ${reviewAgent.name} (${inlineChecklistSuffix})` : `Send to ${reviewAgent.name}`)
                        : (inlineChecklistSuffix ? `Send to Review (${inlineChecklistSuffix})` : 'Send to Review')}
                    </button>
                  ) : null}
                  {workflow && activePhase ? (
                    <button
                      onClick={() => transitionTaskPhase.mutate({ task, mode: 'block' })}
                      disabled={transitionTaskPhase.isPending}
                      aria-label={`Block task ${task.title}`}
                      style={{ padding: '5px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'rgba(255,107,107,0.08)', color: 'var(--red)', fontSize: 11, fontWeight: 600, cursor: transitionTaskPhase.isPending ? 'not-allowed' : 'pointer', opacity: transitionTaskPhase.isPending ? 0.6 : 1 }}
                    >
                      Block Phase
                    </button>
                  ) : null}
                  {workflow && blockedPhase ? (
                    <button
                      onClick={() => transitionTaskPhase.mutate({ task, mode: 'resume' })}
                      disabled={transitionTaskPhase.isPending}
                      aria-label={`Resume task ${task.title}`}
                      style={{ padding: '5px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 11, fontWeight: 600, cursor: transitionTaskPhase.isPending ? 'not-allowed' : 'pointer', opacity: transitionTaskPhase.isPending ? 0.6 : 1 }}
                    >
                      Resume Phase
                    </button>
                  ) : null}
                  {workflow && canRunReview(workflow, task) ? (
                    <button
                      onClick={() => runReviewMutation.mutate(task)}
                      disabled={runReviewMutation.isPending}
                      aria-label={`Run review for task ${task.title}`}
                      style={{ padding: '5px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'rgba(116,185,255,0.12)', color: 'var(--blue)', fontSize: 11, fontWeight: 700, cursor: runReviewMutation.isPending ? 'not-allowed' : 'pointer', opacity: runReviewMutation.isPending ? 0.6 : 1 }}
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
                      style={{ padding: '5px 10px', borderRadius: 8, border: '1px solid var(--border)', background: inlineChecklistSuffix ? inlineChecklistStyle.background : 'var(--surface2)', color: inlineChecklistSuffix ? inlineChecklistStyle.color : 'var(--text)', fontSize: 11, fontWeight: 600, cursor: advanceTaskPhase.isPending ? 'not-allowed' : 'pointer', opacity: advanceTaskPhase.isPending ? 0.6 : 1 }}
                    >
                      {nextPhase.status === 'in_progress'
                        ? (inlineChecklistSuffix ? `Complete Phase (${inlineChecklistSuffix})` : 'Complete Phase')
                        : (inlineChecklistSuffix ? `Advance Phase (${inlineChecklistSuffix})` : 'Advance Phase')}
                    </button>
                  ) : null}
                  <span style={{ padding: '3px 10px', borderRadius: 6, fontSize: 10, fontWeight: 600, background: s.bg, color: s.color }}>{task.status}</span>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
