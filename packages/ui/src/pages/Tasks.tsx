import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { Suspense, lazy, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { api } from '../api/client.js';

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
      phases: Array<{ id: string; label: string; status?: 'pending' | 'in_progress' | 'done' | 'blocked'; enforceSeparation?: boolean }>;
    };
  };
  status: string;
  createdAt: string;
  updatedAt: string;
}

type TaskWorkflow = NonNullable<NonNullable<Task['metadata']>['workflow']>;

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

function getLatestTaskActivity(events: ActivityEntry[], taskId: string) {
  return events.find((event) => event.detail.taskId === taskId && event.eventType.startsWith('task.'));
}

function getTaskActivityTimeline(events: ActivityEntry[], taskId: string) {
  return events
    .filter((event) => event.detail.taskId === taskId && event.eventType.startsWith('task.'))
    .slice(0, 3);
}

function getTaskActivitySummary(entry?: ActivityEntry) {
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

function getTaskTimelineLabel(entry: ActivityEntry) {
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

function getTaskTimelineDetail(entry: ActivityEntry) {
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
    createdAt: new Date(entry.createdAt).toLocaleString(),
    runId: typeof entry.detail.runId === 'string' ? entry.detail.runId : undefined,
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
  const { data: activity = [] } = useQuery({ queryKey: ['activity', 'tasks-page'], queryFn: () => api.get<ActivityEntry[]>('/activity?limit=100') });
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
  const timelineStreamRefs = useRef<Record<string, EventSource | undefined>>({});
  const { data: projects } = useQuery({ queryKey: ['projects'], queryFn: () => api.get<any[]>('/projects') });

  useEffect(() => {
    return () => {
      Object.values(timelineStreamRefs.current).forEach((stream) => stream?.close());
      timelineStreamRefs.current = {};
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
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tasks'] });
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
            const latestActivity = getLatestTaskActivity(activity, task.id);
            const latestActivitySummary = getTaskActivitySummary(latestActivity);
            const taskTimeline = getTaskActivityTimeline(activity, task.id);
              const selectedTimelineEntry = taskTimeline.find((entry) => entry.id === selectedTimelineEventIds[task.id]);
              const selectedTimelineDetail = selectedTimelineEntry ? getTaskTimelineDetail(selectedTimelineEntry) : null;
            const timelineHistoryEntries = (timelineHistoryEventIds[task.id] ?? [])
              .map((eventId) => taskTimeline.find((entry) => entry.id === eventId))
              .filter((entry): entry is ActivityEntry => !!entry && entry.id !== selectedTimelineEntry?.id);
            const supersededIds = supersededTimelineEventIds[task.id] ?? [];
            const isRetryingReview = retryingTaskIds[task.id] === true;
            const phaseOwnerLabel = (blockedPhase?.enforceSeparation || activePhase?.enforceSeparation)
              ? (blockedReviewAgent?.name ?? reviewAgent?.name ?? assignedAgent?.name ?? 'unassigned')
              : (assignedAgent?.name ?? reviewAgent?.name ?? 'unassigned');
            const selectedRunStatusLabel =
              selectedTimelineEntry && timelineDoneByEventId[selectedTimelineEntry.id]
                ? `exitCode ${String(timelineDoneByEventId[selectedTimelineEntry.id]?.exitCode ?? 'null')}${timelineDoneByEventId[selectedTimelineEntry.id]?.timedOut ? ', timed out' : ''}`
                : loadingTimelineEventId === selectedTimelineEntry?.id
                  ? 'opening logs'
                  : 'live or not loaded';
            const drawerPhaseActions = [];
            if (workflow && canSendToReview(workflow)) {
              drawerPhaseActions.push({
                key: 'review',
                label: reviewAgent ? `Send to ${reviewAgent.name}` : 'Send to Review',
                ariaLabel: `Send task ${task.title} to review from drawer`,
                onClick: () => transitionTaskPhase.mutate({ task, mode: 'review' }),
                disabled: transitionTaskPhase.isPending,
                tone: 'yellow' as const,
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
                label: nextPhase.status === 'in_progress' ? 'Complete Phase' : 'Advance Phase',
                ariaLabel: `Advance task ${task.title} from drawer`,
                onClick: () => advanceTaskPhase.mutate(task),
                disabled: advanceTaskPhase.isPending,
                tone: 'neutral' as const,
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
                outcome: detail.outcome,
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
                              if (!selectedTimelineEntry && taskTimeline[0]) {
                                setSelectedTimelineEventIds((current) => ({
                                  ...current,
                                  [task.id]: taskTimeline[0]!.id,
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
                            separationModeLabel={workflow?.separationMode ?? 'n/a'}
                            currentPhaseLabel={activePhase?.label ?? blockedPhase?.label ?? 'n/a'}
                            phaseOwnerLabel={phaseOwnerLabel}
                            agentName={assignedAgent?.name ?? 'unassigned'}
                            reviewerName={reviewAgent?.name ?? 'n/a'}
                            selectedEventLabel={selectedTimelineEntry ? getTaskTimelineLabel(selectedTimelineEntry) : 'none'}
                            runStatusLabel={selectedRunStatusLabel}
                            phases={workflow?.phases ?? []}
                            checklist={workflow?.checklist ?? []}
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
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
                  {workflow && canSendToReview(workflow) ? (
                    <button
                      onClick={() => transitionTaskPhase.mutate({ task, mode: 'review' })}
                      disabled={transitionTaskPhase.isPending}
                      aria-label={`Send task ${task.title} to review`}
                      style={{ padding: '5px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'rgba(253,203,110,0.12)', color: 'var(--yellow)', fontSize: 11, fontWeight: 700, cursor: transitionTaskPhase.isPending ? 'not-allowed' : 'pointer', opacity: transitionTaskPhase.isPending ? 0.6 : 1 }}
                    >
                      {reviewAgent ? `Send to ${reviewAgent.name}` : 'Send to Review'}
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
                      onClick={() => advanceTaskPhase.mutate(task)}
                      disabled={advanceTaskPhase.isPending}
                      aria-label={`Advance task ${task.title}`}
                      style={{ padding: '5px 10px', borderRadius: 8, border: '1px solid var(--border)', background: 'var(--surface2)', color: 'var(--text)', fontSize: 11, fontWeight: 600, cursor: advanceTaskPhase.isPending ? 'not-allowed' : 'pointer', opacity: advanceTaskPhase.isPending ? 0.6 : 1 }}
                    >
                      {nextPhase.status === 'in_progress' ? 'Complete Phase' : 'Advance Phase'}
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
